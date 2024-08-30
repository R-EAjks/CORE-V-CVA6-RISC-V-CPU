// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 08.02.2018
// Description: Ariane Instruction Fetch Frontend
//
// This module interfaces with the instruction cache, handles control
// change request from the back-end and does branch prediction.

module frontend
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bp_resolve_t = logic,
    parameter type fetch_entry_t = logic,
    parameter type fetch_dreq_t = logic,
    parameter type fetch_drsp_t = logic,
    parameter type fetch_areq_t = logic,
    parameter type fetch_arsp_t = logic,
    parameter type obi_fetch_req_t = logic,
    parameter type obi_fetch_rsp_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Next PC when reset - SUBSYSTEM
    input logic [CVA6Cfg.VLEN-1:0] boot_addr_i,
    // Flush branch prediction - zero
    input logic flush_bp_i,
    // Flush requested by FENCE, mis-predict and exception - CONTROLLER
    input logic flush_i,
    // Halt requested by WFI and Accelerate port - CONTROLLER
    input logic halt_i,
    // Set COMMIT PC as next PC requested by FENCE, CSR side-effect and Accelerate port - CONTROLLER
    input logic set_pc_commit_i,
    // COMMIT PC - COMMIT
    input logic [CVA6Cfg.VLEN-1:0] pc_commit_i,
    // Exception event - COMMIT
    input logic ex_valid_i,
    // Mispredict event and next PC - EXECUTE
    input bp_resolve_t resolved_branch_i,
    // Return from exception event - CSR
    input logic eret_i,
    // Next PC when returning from exception - CSR
    input logic [CVA6Cfg.VLEN-1:0] epc_i,
    // Next PC when jumping into exception - CSR
    input logic [CVA6Cfg.VLEN-1:0] trap_vector_base_i,
    // Debug event - CSR
    input logic set_debug_pc_i,
    // Debug mode state - CSR
    input logic debug_mode_i,
    // address translation request chanel - EXECUTE
    input fetch_arsp_t arsp_i,
    // address translation response chanel - EXECUTE
    output fetch_areq_t areq_o,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    output fetch_dreq_t fetch_dreq_o,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    input fetch_drsp_t fetch_dreq_i,
    // OBI Fetch Request channel - CACHES
    output obi_fetch_req_t fetch_obi_req_o,
    // OBI Fetch Response channel - CACHES
    input obi_fetch_rsp_t fetch_obi_rsp_i,
    // Handshake's data between fetch and decode - ID_STAGE
    output fetch_entry_t [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_o,
    // Handshake's valid between fetch and decode - ID_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_valid_o,
    // Handshake's ready between fetch and decode - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_ready_i
);

  localparam type bht_update_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] pc;     // update at PC
    logic                    taken;
  };

  localparam type btb_prediction_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] target_address;
  };

  localparam type btb_update_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] pc;              // update at PC
    logic [CVA6Cfg.VLEN-1:0] target_address;
  };

  localparam type ras_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] ra;
  };

  // Instruction Cache Registers, from I$
  logic                            [    CVA6Cfg.FETCH_WIDTH-1:0] fetch_data_q;
  logic                                                          fetch_valid_q;
  ariane_pkg::frontend_exception_t                               fetch_ex_valid_q;
  logic                            [           CVA6Cfg.VLEN-1:0] fetch_vaddr_q;
  logic                            [          CVA6Cfg.GPLEN-1:0] fetch_gpaddr_q;
  logic                            [                       31:0] fetch_tinst_q;
  logic                                                          fetch_gva_q;
  logic                                                          instr_queue_ready;
  logic                            [CVA6Cfg.INSTR_PER_FETCH-1:0] instr_queue_consumed;
  // upper-most branch-prediction from last cycle
  btb_prediction_t                                               btb_q;
  bht_prediction_t                                               bht_q;
  // instruction fetch is ready
  logic                                                          if_ready;
  logic [CVA6Cfg.VLEN-1:0] npc_d, npc_q;  // next PC

  // indicates whether we come out of reset (then we need to load boot_addr_i)
  logic                    npc_rst_load_q;

  logic                    replay;
  logic [CVA6Cfg.VLEN-1:0] replay_addr;

  logic [CVA6Cfg.VLEN-1:0]
      npc_fetch_address, vaddr_d, obi_vaddr_q, obi_vaddr_d, vaddr_q, fetch_vaddr_d;
  logic [CVA6Cfg.PLEN-1:0] paddr_d, paddr_q;

  // shift amount
  logic [$clog2(CVA6Cfg.INSTR_PER_FETCH)-1:0] shamt;
  // address will always be 16 bit aligned, make this explicit here
  if (CVA6Cfg.RVC) begin : gen_shamt
    assign shamt = fetch_vaddr_d[$clog2(CVA6Cfg.INSTR_PER_FETCH):1];
  end else begin
    assign shamt = 1'b0;
  end

  // -----------------------
  // Ctrl Flow Speculation
  // -----------------------
  // RVI ctrl flow prediction
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] rvi_return, rvi_call, rvi_branch, rvi_jalr, rvi_jump;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] rvi_imm;
  // RVC branching
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] rvc_branch, rvc_jump, rvc_jr, rvc_return, rvc_jalr, rvc_call;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] rvc_imm;
  // re-aligned instruction and address (coming from cache - combinationally)
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][            31:0] instr;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] addr;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0]                   instruction_valid;
  // BHT, BTB and RAS prediction
  bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   bht_prediction;
  btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   btb_prediction;
  bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   bht_prediction_shifted;
  btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   btb_prediction_shifted;
  ras_t                                                            ras_predict;
  logic            [           CVA6Cfg.VLEN-1:0]                   vpc_btb;

  // branch-predict update
  logic                                                            is_mispredict;
  logic ras_push, ras_pop;
  logic [           CVA6Cfg.VLEN-1:0] ras_update;

  // Instruction FIFO
  logic [           CVA6Cfg.VLEN-1:0] predict_address;
  cf_t  [CVA6Cfg.INSTR_PER_FETCH-1:0] cf_type;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] taken_rvi_cf;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] taken_rvc_cf;

  logic kill_s1, kill_s2;

  logic serving_unaligned;
  // Re-align instructions
  instr_realign #(
      .CVA6Cfg(CVA6Cfg)
  ) i_instr_realign (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (kill_s2),
      .valid_i            (fetch_valid_q),
      .serving_unaligned_o(serving_unaligned),
      .address_i          (fetch_vaddr_q),
      .data_i             (fetch_data_q),
      .valid_o            (instruction_valid),
      .addr_o             (addr),
      .instr_o            (instr)
  );
  // --------------------
  // Branch Prediction
  // --------------------
  // select the right branch prediction result
  // in case we are serving an unaligned instruction in instr[0] we need to take
  // the prediction we saved from the previous fetch
  if (CVA6Cfg.RVC) begin : gen_btb_prediction_shifted
    assign bht_prediction_shifted[0] = (serving_unaligned) ? bht_q : bht_prediction[addr[0][$clog2(
        CVA6Cfg.INSTR_PER_FETCH
    ):1]];
    assign btb_prediction_shifted[0] = (serving_unaligned) ? btb_q : btb_prediction[addr[0][$clog2(
        CVA6Cfg.INSTR_PER_FETCH
    ):1]];

    // for all other predictions we can use the generated address to index
    // into the branch prediction data structures
    for (genvar i = 1; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_prediction_address
      assign bht_prediction_shifted[i] = bht_prediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
      assign btb_prediction_shifted[i] = btb_prediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
    end
  end else begin
    assign bht_prediction_shifted[0] = (serving_unaligned) ? bht_q : bht_prediction[addr[0][1]];
    assign btb_prediction_shifted[0] = (serving_unaligned) ? btb_q : btb_prediction[addr[0][1]];
  end
  ;

  // for the return address stack it doens't matter as we have the
  // address of the call/return already
  logic bp_valid;

  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_branch;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_call;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_jump;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_return;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_jalr;

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
    // branch history table -> BHT
    assign is_branch[i] = instruction_valid[i] & (rvi_branch[i] | rvc_branch[i]);
    // function calls -> RAS
    assign is_call[i] = instruction_valid[i] & (rvi_call[i] | rvc_call[i]);
    // function return -> RAS
    assign is_return[i] = instruction_valid[i] & (rvi_return[i] | rvc_return[i]);
    // unconditional jumps with known target -> immediately resolved
    assign is_jump[i] = instruction_valid[i] & (rvi_jump[i] | rvc_jump[i]);
    // unconditional jumps with unknown target -> BTB
    assign is_jalr[i] = instruction_valid[i] & ~is_return[i] & (rvi_jalr[i] | rvc_jalr[i] | rvc_jr[i]);
  end

  // taken/not taken
  always_comb begin
    taken_rvi_cf = '0;
    taken_rvc_cf = '0;
    predict_address = '0;

    for (int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) cf_type[i] = ariane_pkg::NoCF;

    ras_push = 1'b0;
    ras_pop = 1'b0;
    ras_update = '0;

    // lower most prediction gets precedence
    for (int i = CVA6Cfg.INSTR_PER_FETCH - 1; i >= 0; i--) begin
      unique case ({
        is_branch[i], is_return[i], is_jump[i], is_jalr[i]
      })
        4'b0000: ;  // regular instruction e.g.: no branch
        // unconditional jump to register, we need the BTB to resolve this
        4'b0001: begin
          ras_pop  = 1'b0;
          ras_push = 1'b0;
          if (CVA6Cfg.BTBEntries && btb_prediction_shifted[i].valid) begin
            predict_address = btb_prediction_shifted[i].target_address;
            cf_type[i] = ariane_pkg::JumpR;
          end
        end
        // its an unconditional jump to an immediate
        4'b0010: begin
          ras_pop = 1'b0;
          ras_push = 1'b0;
          taken_rvi_cf[i] = rvi_jump[i];
          taken_rvc_cf[i] = rvc_jump[i];
          cf_type[i] = ariane_pkg::Jump;
        end
        // return
        4'b0100: begin
          // make sure to only alter the RAS if we actually consumed the instruction
          ras_pop = ras_predict.valid & instr_queue_consumed[i];
          ras_push = 1'b0;
          predict_address = ras_predict.ra;
          cf_type[i] = ariane_pkg::Return;
        end
        // branch prediction
        4'b1000: begin
          ras_pop  = 1'b0;
          ras_push = 1'b0;
          // if we have a valid dynamic prediction use it
          if (bht_prediction_shifted[i].valid) begin
            taken_rvi_cf[i] = rvi_branch[i] & bht_prediction_shifted[i].taken;
            taken_rvc_cf[i] = rvc_branch[i] & bht_prediction_shifted[i].taken;
            // otherwise default to static prediction
          end else begin
            // set if immediate is negative - static prediction
            taken_rvi_cf[i] = rvi_branch[i] & rvi_imm[i][CVA6Cfg.VLEN-1];
            taken_rvc_cf[i] = rvc_branch[i] & rvc_imm[i][CVA6Cfg.VLEN-1];
          end
          if (taken_rvi_cf[i] || taken_rvc_cf[i]) begin
            cf_type[i] = ariane_pkg::Branch;
          end
        end
        default: ;
        // default: $error("Decoded more than one control flow");
      endcase
      // if this instruction, in addition, is a call, save the resulting address
      // but only if we actually consumed the address
      if (is_call[i]) begin
        ras_push   = instr_queue_consumed[i];
        ras_update = addr[i] + (rvc_call[i] ? 2 : 4);
      end
      // calculate the jump target address
      if (taken_rvc_cf[i] || taken_rvi_cf[i]) begin
        predict_address = addr[i] + (taken_rvc_cf[i] ? rvc_imm[i] : rvi_imm[i]);
      end
    end
  end
  // or reduce struct
  always_comb begin
    bp_valid = 1'b0;
    // BP cannot be valid if we have a return instruction and the RAS is not giving a valid address
    // Check that we encountered a control flow and that for a return the RAS
    // contains a valid prediction.
    for (int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++)
    bp_valid |= ((cf_type[i] != NoCF & cf_type[i] != Return) | ((cf_type[i] == Return) & ras_predict.valid));
  end
  assign is_mispredict = resolved_branch_i.valid & resolved_branch_i.is_mispredict;

  logic spec_req_non_idempot;

  // MMU interface
  assign areq_o.fetch_vaddr = (vaddr_q >> CVA6Cfg.FETCH_ALIGN_BITS) << CVA6Cfg.FETCH_ALIGN_BITS;

  // CHECK PMA regions

  logic paddr_is_cacheable, paddr_is_cacheable_q;  // asserted if physical address is non-cacheable
  assign paddr_is_cacheable = config_pkg::is_inside_cacheable_regions(
      CVA6Cfg, {{64 - CVA6Cfg.PLEN{1'b0}}, fetch_obi_req_o.a.addr}  //TO DO CHECK GRANULARITY
  );

  logic paddr_nonidempotent;
  assign paddr_nonidempotent = config_pkg::is_inside_nonidempotent_regions(
      CVA6Cfg, {{64 - CVA6Cfg.PLEN{1'b0}}, fetch_obi_req_o.a.addr}  //TO DO CHECK GRANULARITY
  );

  // Caches optimisation signals

  typedef enum logic [1:0] {
    WAIT_NEW_REQ,
    WAIT_ATRANS,
    WAIT_OBI,
    WAIT_FLUSH
  } custom_state_e;
  custom_state_e custom_state_d, custom_state_q;

  // Address translation signals
  logic atrans_req;
  logic atrans_kill;
  logic atrans_ready;
  logic atrans_valid;
  logic atrans_ex;

  typedef enum logic [1:0] {
    IDLE,
    READ,
    KILL_ATRANS
  } atrans_state_e;
  atrans_state_e atrans_state_d, atrans_state_q;

  // OBI signals
  logic obi_a_req;
  logic obi_a_ready;

  typedef enum logic [1:0] {
    TRANSPARENT,
    REGISTRED
  } obi_a_state_e;
  obi_a_state_e obi_a_state_d, obi_a_state_q;

  // OBI signals
  logic obi_r_req;
  logic data_valid_obi;
  logic data_valid_under_ex;

  typedef enum logic [1:0] {
    OBI_R_IDLE,
    OBI_R_PENDING,
    OBI_R_KILLED
  } obi_r_state_e;
  obi_r_state_e obi_r_state_d, obi_r_state_q;

  // We need to flush the cache pipeline if:
  // 1. We mispredicted
  // 2. Want to flush the whole processor front-end
  // 3. Need to replay an instruction because the fetch-fifo was full
  assign kill_s1 = is_mispredict | flush_i | replay;
  // if we have a valid branch-prediction we need to only kill the last cache request
  // also if we killed the first stage we also need to kill the second stage (inclusive flush)
  assign kill_s2 = kill_s1 | bp_valid;

  assign fetch_dreq_o.vaddr = vaddr_d;
  assign fetch_dreq_o.kill_req = kill_s1 | kill_s2 | atrans_ex;

  // Common clocked process
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      custom_state_q <= WAIT_NEW_REQ;
      atrans_state_q <= IDLE;
      obi_a_state_q <= TRANSPARENT;
      obi_r_state_q <= OBI_R_IDLE;
      vaddr_q <= '0;
      paddr_q <= '0;
      obi_vaddr_q <= '0;
      paddr_is_cacheable_q <= '0;
    end else begin
      custom_state_q <= custom_state_d;
      atrans_state_q <= atrans_state_d;
      obi_a_state_q <= obi_a_state_d;
      obi_r_state_q <= obi_r_state_d;
      vaddr_q <= vaddr_d;
      paddr_q <= paddr_d;
      obi_vaddr_q <= obi_vaddr_d;
      paddr_is_cacheable_q <= paddr_is_cacheable;
    end
  end

  // custom protocol FSM (combi) 

  always_comb begin : p_fsm_common
    // default assignment
    custom_state_d = custom_state_q;
    atrans_req = '0;
    atrans_kill = '0;
    obi_a_req = '0;
    obi_vaddr_d = obi_vaddr_q;
    fetch_dreq_o.req = '0;
    data_valid_under_ex = '0;
    if_ready = '0;
    vaddr_d = vaddr_q;

    unique case (custom_state_q)
      WAIT_NEW_REQ: begin
        vaddr_d = npc_fetch_address;
        if ((obi_a_state_q == TRANSPARENT || obi_r_req == '1) && instr_queue_ready && atrans_ready && !kill_s2) begin
          fetch_dreq_o.req = '1;
          if (fetch_dreq_i.ready) begin
            if_ready = '1;
            atrans_req = '1;
            custom_state_d = WAIT_ATRANS;
          end
        end
      end

      WAIT_ATRANS: begin
        if (atrans_valid) begin
          if (kill_s2) begin
            vaddr_d = npc_fetch_address;
            if (instr_queue_ready && atrans_ready && !kill_s1) begin
              fetch_dreq_o.req = '1;
              if (fetch_dreq_i.ready) begin
                if_ready   = '1;
                atrans_req = '1;
              end else begin
                custom_state_d = WAIT_NEW_REQ;
              end
            end else begin
              custom_state_d = WAIT_NEW_REQ;
            end
          end else if (atrans_ex) begin
            obi_vaddr_d = vaddr_d;
            data_valid_under_ex = '1;
            custom_state_d = WAIT_FLUSH;
          end else if (obi_a_ready && !spec_req_non_idempot) begin
            obi_a_req = '1;
            obi_vaddr_d = vaddr_d;
            vaddr_d = npc_fetch_address;
            if (obi_r_req && instr_queue_ready && atrans_ready && !kill_s1) begin
              fetch_dreq_o.req = '1;
              if (fetch_dreq_i.ready) begin
                if_ready   = '1;
                atrans_req = '1;
              end else begin
                custom_state_d = WAIT_NEW_REQ;
              end
            end else begin
              custom_state_d = WAIT_NEW_REQ;
            end
          end else begin
            custom_state_d = WAIT_OBI;
          end
        end
        if (kill_s2) begin
          atrans_kill = '1;
          vaddr_d = npc_fetch_address;
          if (instr_queue_ready && atrans_ready && !kill_s1) begin
            fetch_dreq_o.req = '1;
            if (fetch_dreq_i.ready) begin
              if_ready   = '1;
              atrans_req = '1;
            end else begin
              custom_state_d = WAIT_NEW_REQ;
            end
          end else begin
            custom_state_d = WAIT_NEW_REQ;
          end
        end
      end

      WAIT_OBI: begin
        if (kill_s2) begin
          vaddr_d = npc_fetch_address;
          if ((obi_a_state_q == TRANSPARENT || obi_r_req == '1) && instr_queue_ready && atrans_ready && !kill_s1) begin
            fetch_dreq_o.req = '1;
            if (fetch_dreq_i.ready) begin
              if_ready = '1;
              atrans_req = '1;
              custom_state_d = WAIT_ATRANS;
            end else begin
              custom_state_d = WAIT_NEW_REQ;
            end
          end else begin
            custom_state_d = WAIT_NEW_REQ;
          end
        end else if (obi_a_ready && !spec_req_non_idempot) begin
          obi_a_req = '1;
          obi_vaddr_d = vaddr_d;
          vaddr_d = npc_fetch_address;
          if (obi_r_req && instr_queue_ready && atrans_ready && !kill_s1) begin
            fetch_dreq_o.req = '1;
            if (fetch_dreq_i.ready) begin
              if_ready = '1;
              atrans_req = '1;
              custom_state_d = WAIT_ATRANS;
            end else begin
              custom_state_d = WAIT_NEW_REQ;
            end
          end else begin
            custom_state_d = WAIT_NEW_REQ;
          end
        end
      end

      WAIT_FLUSH: begin
        if (kill_s1) begin
          custom_state_d = WAIT_NEW_REQ;
        end
      end

      default: begin
        // we should never get here
        custom_state_d = WAIT_NEW_REQ;
      end

    endcase
  end

  // Address translation protocol FSM (combi)

  always_comb begin : p_fsm_atrans
    // default assignment
    atrans_state_d = atrans_state_q;
    areq_o.fetch_req = 1'b0;
    atrans_ready = 1'b0;
    atrans_valid = 1'b0;
    paddr_d = paddr_q;
    atrans_ex = 1'b0;

    unique case (atrans_state_q)
      IDLE: begin
        atrans_ready = 1'b1;
        if (atrans_req) begin
          atrans_state_d = READ;
        end
      end

      READ: begin
        areq_o.fetch_req = '1;
        if (arsp_i.fetch_valid) begin
          atrans_ready = 1'b1;
          if (!atrans_kill) begin
            atrans_valid = 1'b1;
            paddr_d = arsp_i.fetch_paddr;
            atrans_ex = arsp_i.fetch_exception.valid;
          end
          if (!atrans_req) begin
            atrans_state_d = IDLE;
          end
        end else if (atrans_kill) begin
          atrans_state_d = KILL_ATRANS;
        end
      end

      KILL_ATRANS: begin
        areq_o.fetch_req = '1;
        if (arsp_i.fetch_valid) begin
          atrans_ready = 1'b1;
          if (atrans_req) begin
            atrans_state_d = READ;
          end else begin
            atrans_state_d = IDLE;
          end
        end
      end

      default: begin
        // we should never get here
        atrans_state_d = IDLE;
      end
    endcase
  end

  // OBI CHANNEL A protocol FSM (combi)

  always_comb begin : p_fsm_obi_a
    // default assignment
    obi_a_state_d = obi_a_state_q;
    obi_a_ready = 1'b0;
    obi_r_req = '0;
    //default obi state registred
    fetch_obi_req_o.req    = 1'b1;
    fetch_obi_req_o.reqpar = 1'b0;
    fetch_obi_req_o.a.addr = paddr_q;
    fetch_obi_req_o.a.we   = '0;
    fetch_obi_req_o.a.be   = '1;
    fetch_obi_req_o.a.wdata= '0;
    fetch_obi_req_o.a.aid  = '0;
    fetch_obi_req_o.a.a_optional.auser= '0;
    fetch_obi_req_o.a.a_optional.wuser= '0;
    fetch_obi_req_o.a.a_optional.atop= '0;
    fetch_obi_req_o.a.a_optional.memtype[0]='0;
    fetch_obi_req_o.a.a_optional.memtype[1]=paddr_is_cacheable_q;
    fetch_obi_req_o.a.a_optional.mid= '0;
    fetch_obi_req_o.a.a_optional.prot= '0;
    fetch_obi_req_o.a.a_optional.dbg= '0;
    fetch_obi_req_o.a.a_optional.achk= '0;

    unique case (obi_a_state_q)
      TRANSPARENT: begin
        obi_a_ready = '1;
        if (obi_a_req) begin
          if (fetch_obi_rsp_i.gnt) begin
            obi_r_req = '1;  //push pending request
          end else begin
            obi_a_state_d = REGISTRED;
          end
        end
        fetch_obi_req_o.req    = obi_a_req;
        fetch_obi_req_o.reqpar = !obi_a_req;
        fetch_obi_req_o.a.addr = paddr_d;
        fetch_obi_req_o.a.we   = '0;
        fetch_obi_req_o.a.be   = '1;
        fetch_obi_req_o.a.wdata= '0;
        fetch_obi_req_o.a.aid  = '0;
        fetch_obi_req_o.a.a_optional.auser= '0;
        fetch_obi_req_o.a.a_optional.wuser= '0;
        fetch_obi_req_o.a.a_optional.atop= '0;
        fetch_obi_req_o.a.a_optional.memtype[0]='0;
        fetch_obi_req_o.a.a_optional.memtype[1]=paddr_is_cacheable;
        fetch_obi_req_o.a.a_optional.mid= '0;
        fetch_obi_req_o.a.a_optional.prot= '0;
        fetch_obi_req_o.a.a_optional.dbg= '0;
        fetch_obi_req_o.a.a_optional.achk= '0;
      end

      REGISTRED: begin
        if (fetch_obi_rsp_i.gnt) begin
          obi_r_req = '1;  //push pending request
          obi_a_state_d = TRANSPARENT;
        end
      end

      default: begin
        // we should never get here
        obi_a_state_d = TRANSPARENT;
      end
    endcase
  end

  // OBI CHANNEL R protocol FSM (combi)

  always_comb begin : p_fsm_obi_r
    // default assignment
    obi_r_state_d  = obi_r_state_q;
    data_valid_obi = '0;

    unique case (obi_r_state_q)
      OBI_R_IDLE: begin
        if (obi_r_req) begin
          if (kill_s2) begin
            obi_r_state_d = OBI_R_KILLED;
          end else begin
            obi_r_state_d = OBI_R_PENDING;
          end
        end
      end

      OBI_R_PENDING: begin
        if (fetch_obi_req_o.rready && fetch_obi_rsp_i.rvalid) begin
          data_valid_obi = !kill_s2;
          if (!obi_r_req) begin
            obi_r_state_d = OBI_R_IDLE;
          end
        end else if (kill_s2) begin
          obi_r_state_d = OBI_R_KILLED;
        end
      end

      OBI_R_KILLED: begin
        if (fetch_obi_req_o.rready && fetch_obi_rsp_i.rvalid) begin
          if (obi_r_req) begin
            if (!kill_s2) begin
              obi_r_state_d = OBI_R_PENDING;
            end
          end else begin
            obi_r_state_d = OBI_R_IDLE;
          end
        end
      end

      default: begin
        // we should never get here
        obi_r_state_d = OBI_R_IDLE;
      end
    endcase
  end

  //always ready to get data
  assign fetch_obi_req_o.rready = '1;
  assign fetch_obi_req_o.rreadypar = !fetch_obi_req_o.rready;

  // Update Control Flow Predictions
  bht_update_t bht_update;
  btb_update_t btb_update;

  logic speculative_q, speculative_d;
  assign speculative_d = (speculative_q && !resolved_branch_i.valid || |is_branch || |is_return || |is_jalr) && !flush_i;

  assign spec_req_non_idempot = CVA6Cfg.NonIdemPotenceEn ? speculative_d && paddr_nonidempotent : 1'b0;


  assign bht_update.valid = resolved_branch_i.valid
                                & (resolved_branch_i.cf_type == ariane_pkg::Branch);
  assign bht_update.pc = resolved_branch_i.pc;
  assign bht_update.taken = resolved_branch_i.is_taken;
  // only update mispredicted branches e.g. no returns from the RAS
  assign btb_update.valid = resolved_branch_i.valid
                                & resolved_branch_i.is_mispredict
                                & (resolved_branch_i.cf_type == ariane_pkg::JumpR);
  assign btb_update.pc = resolved_branch_i.pc;
  assign btb_update.target_address = resolved_branch_i.target_address;

  // -------------------
  // Next PC
  // -------------------
  // next PC (NPC) can come from (in order of precedence):
  // 0. Default assignment/replay instruction
  // 1. Branch Predict taken
  // 2. Control flow change request (misprediction)
  // 3. Return from environment call
  // 4. Exception/Interrupt
  // 5. Pipeline Flush because of CSR side effects
  // Mis-predict handling is a little bit different
  // select PC a.k.a PC Gen
  always_comb begin : npc_select
    automatic logic [CVA6Cfg.VLEN-1:0] fetch_address;
    // check whether we come out of reset
    // this is a workaround. some tools have issues
    // having boot_addr_i in the asynchronous
    // reset assignment to npc_q, even though
    // boot_addr_i will be assigned a constant
    // on the top-level.
    if (npc_rst_load_q) begin
      npc_d         = boot_addr_i;
      fetch_address = boot_addr_i;
    end else begin
      fetch_address = npc_q;
      // keep stable by default
      npc_d         = npc_q;
    end
    // 0. Branch Prediction
    if (bp_valid) begin
      fetch_address = predict_address;
      npc_d = predict_address;
    end
    // 1. Default assignment
    if (if_ready) begin
      npc_d = {
        fetch_address[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1, {CVA6Cfg.FETCH_ALIGN_BITS{1'b0}}
      };
    end
    // 2. Replay instruction fetch
    if (replay) begin
      npc_d = replay_addr;
    end
    // 3. Control flow change request
    if (is_mispredict) begin
      npc_d = resolved_branch_i.target_address;
    end
    // 4. Return from environment call
    if (eret_i) begin
      npc_d = epc_i;
    end
    // 5. Exception/Interrupt
    if (ex_valid_i) begin
      npc_d = trap_vector_base_i;
    end
    // 6. Pipeline Flush because of CSR side effects
    // On a pipeline flush start fetching from the next address
    // of the instruction in the commit stage
    // we either came here from a flush request of a CSR instruction or AMO,
    // so as CSR or AMO instructions do not exist in a compressed form
    // we can unconditionally do PC + 4 here
    // or if the commit stage is halted, just take the current pc of the
    // instruction in the commit stage
    // TODO(zarubaf) This adder can at least be merged with the one in the csr_regfile stage
    if (set_pc_commit_i) begin
      npc_d = pc_commit_i + (halt_i ? '0 : {{CVA6Cfg.VLEN - 3{1'b0}}, 3'b100});
    end
    // 7. Debug
    // enter debug on a hard-coded base-address
    if (CVA6Cfg.DebugEn && set_debug_pc_i)
      npc_d = CVA6Cfg.DmBaseAddress[CVA6Cfg.VLEN-1:0] + CVA6Cfg.HaltAddress[CVA6Cfg.VLEN-1:0];
    npc_fetch_address = fetch_address;
  end

  logic [CVA6Cfg.FETCH_WIDTH-1:0] fetch_data;
  logic fetch_valid_d;

  // re-align the cache line
  assign fetch_data = data_valid_under_ex ? '0 : fetch_obi_rsp_i.r.rdata >> {shamt, 4'b0};
  assign fetch_valid_d = data_valid_under_ex || data_valid_obi;
  assign fetch_vaddr_d = data_valid_under_ex ? vaddr_q : obi_vaddr_q;


  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      npc_rst_load_q   <= 1'b1;
      npc_q            <= '0;
      speculative_q    <= '0;
      fetch_data_q     <= '0;
      fetch_valid_q    <= 1'b0;
      fetch_vaddr_q    <= 'b0;
      fetch_gpaddr_q   <= 'b0;
      fetch_tinst_q    <= 'b0;
      fetch_gva_q      <= 1'b0;
      fetch_ex_valid_q <= ariane_pkg::FE_NONE;
      btb_q            <= '0;
      bht_q            <= '0;
    end else begin
      npc_rst_load_q <= 1'b0;
      npc_q <= npc_d;
      speculative_q <= speculative_d;
      fetch_valid_q <= fetch_valid_d;
      if (fetch_valid_d) begin
        fetch_data_q  <= fetch_data;
        fetch_vaddr_q <= fetch_vaddr_d;
        if (CVA6Cfg.RVH) begin
          fetch_gpaddr_q <= arsp_i.fetch_exception.tval2[CVA6Cfg.GPLEN-1:0];
          fetch_tinst_q  <= arsp_i.fetch_exception.tinst;
          fetch_gva_q    <= arsp_i.fetch_exception.gva;
        end else begin
          fetch_gpaddr_q <= 'b0;
          fetch_tinst_q  <= 'b0;
          fetch_gva_q    <= 1'b0;
        end

        // Map the only three exceptions which can occur in the frontend to a two bit enum
        if (CVA6Cfg.MmuPresent && arsp_i.fetch_exception.cause == riscv::INSTR_GUEST_PAGE_FAULT) begin
          fetch_ex_valid_q <= ariane_pkg::FE_INSTR_GUEST_PAGE_FAULT;
        end else if (CVA6Cfg.MmuPresent && arsp_i.fetch_exception.cause == riscv::INSTR_PAGE_FAULT) begin
          fetch_ex_valid_q <= ariane_pkg::FE_INSTR_PAGE_FAULT;
        end else if (arsp_i.fetch_exception.cause == riscv::INSTR_ACCESS_FAULT) begin
          fetch_ex_valid_q <= ariane_pkg::FE_INSTR_ACCESS_FAULT;
        end else begin
          fetch_ex_valid_q <= ariane_pkg::FE_NONE;
        end
        // save the uppermost prediction
        btb_q <= btb_prediction[CVA6Cfg.INSTR_PER_FETCH-1];
        bht_q <= bht_prediction[CVA6Cfg.INSTR_PER_FETCH-1];
      end
    end
  end

  if (CVA6Cfg.RASDepth == 0) begin
    assign ras_predict = '0;
  end else begin : ras_gen
    ras #(
        .CVA6Cfg(CVA6Cfg),
        .ras_t  (ras_t),
        .DEPTH  (CVA6Cfg.RASDepth)
    ) i_ras (
        .clk_i,
        .rst_ni,
        .flush_bp_i(flush_bp_i),
        .push_i(ras_push),
        .pop_i(ras_pop),
        .data_i(ras_update),
        .data_o(ras_predict)
    );
  end

  //For FPGA, BTB is implemented in read synchronous BRAM
  //while for ASIC, BTB is implemented in D flip-flop
  //and can be read at the same cycle.
  assign vpc_btb = (CVA6Cfg.FpgaEn) ? vaddr_q : fetch_vaddr_q;

  if (CVA6Cfg.BTBEntries == 0) begin
    assign btb_prediction = '0;
  end else begin : btb_gen
    btb #(
        .CVA6Cfg   (CVA6Cfg),
        .btb_update_t(btb_update_t),
        .btb_prediction_t(btb_prediction_t),
        .NR_ENTRIES(CVA6Cfg.BTBEntries)
    ) i_btb (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (vpc_btb),
        .btb_update_i    (btb_update),
        .btb_prediction_o(btb_prediction)
    );
  end

  if (CVA6Cfg.BHTEntries == 0) begin
    assign bht_prediction = '0;
  end else begin : bht_gen
    bht #(
        .CVA6Cfg   (CVA6Cfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES(CVA6Cfg.BHTEntries)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (fetch_vaddr_q),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end

  // we need to inspect up to CVA6Cfg.INSTR_PER_FETCH instructions for branches
  // and jumps
  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_instr_scan
    instr_scan #(
        .CVA6Cfg(CVA6Cfg)
    ) i_instr_scan (
        .instr_i     (instr[i]),
        .rvi_return_o(rvi_return[i]),
        .rvi_call_o  (rvi_call[i]),
        .rvi_branch_o(rvi_branch[i]),
        .rvi_jalr_o  (rvi_jalr[i]),
        .rvi_jump_o  (rvi_jump[i]),
        .rvi_imm_o   (rvi_imm[i]),
        .rvc_branch_o(rvc_branch[i]),
        .rvc_jump_o  (rvc_jump[i]),
        .rvc_jr_o    (rvc_jr[i]),
        .rvc_return_o(rvc_return[i]),
        .rvc_jalr_o  (rvc_jalr[i]),
        .rvc_call_o  (rvc_call[i]),
        .rvc_imm_o   (rvc_imm[i])
    );
  end

  instr_queue #(
      .CVA6Cfg(CVA6Cfg),
      .fetch_entry_t(fetch_entry_t)
  ) i_instr_queue (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .instr_i            (instr),                 // from re-aligner
      .addr_i             (addr),                  // from re-aligner
      .exception_i        (fetch_ex_valid_q),      // from I$
      .exception_addr_i   (fetch_vaddr_q),
      .exception_gpaddr_i (fetch_gpaddr_q),
      .exception_tinst_i  (fetch_tinst_q),
      .exception_gva_i    (fetch_gva_q),
      .predict_address_i  (predict_address),
      .cf_type_i          (cf_type),
      .valid_i            (instruction_valid),     // from re-aligner
      .consumed_o         (instr_queue_consumed),
      .ready_o            (instr_queue_ready),
      .replay_o           (replay),
      .replay_addr_o      (replay_addr),
      .fetch_entry_o      (fetch_entry_o),         // to back-end
      .fetch_entry_valid_o(fetch_entry_valid_o),   // to back-end
      .fetch_entry_ready_i(fetch_entry_ready_i)    // to back-end
  );

  // pragma translate_off
`ifndef VERILATOR
  initial begin
    assert (CVA6Cfg.FETCH_WIDTH == 32 || CVA6Cfg.FETCH_WIDTH == 64)
    else $fatal(1, "[frontend] fetch width != not supported");
  end
`endif
  // pragma translate_on
endmodule
