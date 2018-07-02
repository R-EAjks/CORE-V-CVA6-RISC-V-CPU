/* Copyright 2018 ETH Zurich and University of Bologna.
 * Copyright and related rights are licensed under the Solderpad Hardware
 * License, Version 0.51 (the “License”); you may not use this file except in
 * compliance with the License.  You may obtain a copy of the License at
 * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
 * or agreed to in writing, software, hardware and materials distributed under
 * this License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * File:   axi_riscv_debug_module.sv
 * Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>
 * Date:   30.6.2018
 *
 * Description: Debug CSRs. Communication over Debug Transport Module (DTM)
 */

module dm_csrs #(
    parameter int NrHarts = -1
)(
    input  logic                        clk_i,              // Clock
    input  logic                        rst_ni,             // Asynchronous reset active low
    input  logic                        dmi_rst_ni,         // Debug Module Interface reset, active-low
    input  logic                        dmi_req_valid_i,
    output logic                        dmi_req_ready_o,
    input  logic [ 6:0]                 dmi_req_bits_addr_i,
    input  logic [ 1:0]                 dmi_req_bits_op_i,  // 0 = nop, 1 = read, 2 = write
    input  logic [31:0]                 dmi_req_bits_data_i,
    // every request needs a response one cycle later
    output logic                        dmi_resp_valid_o,
    input  logic                        dmi_resp_ready_i,
    output logic [ 1:0]                 dmi_resp_bits_resp_o,
    output logic [31:0]                 dmi_resp_bits_data_o,
    // global ctrl
    output logic                        ndmreset_o,      // non-debug module reset, active-high
    output logic                        dmactive_o,      // 1 -> debug-module is active, 0 -> synchronous re-set
    // hart ctrl communication
    output logic [NrHarts-1:0]          halt_req_o,      // request to halt a hart
    output logic [NrHarts-1:0]          resume_req_o,    // request hart to resume
    // hart status
    input  dm::hartinfo_t [NrHarts-1:0] hartinfo_i,      // static hartinfo
    input  logic [NrHarts-1:0]          halted_i,        // hart is halted
    input  logic [NrHarts-1:0]          running_i,       // hart is running
    input  logic [NrHarts-1:0]          unavailable_i,   // e.g.: powered down
    input  logic [NrHarts-1:0]          havereset_i,     // hart has reset
    input  logic [NrHarts-1:0]          resumeack_i,     // hart acknowledged resume request
    // hart control
    output logic                        command_write_o, // debugger is writing to the command field
    input  dm::command_t                command_o,       // abstract command
    input  logic [NrHarts-1:0]          set_cmderror_i,  // an error occured
    input  dm::cmderr_t [NrHarts-1:0]   cmderror_i,      // this error occured
    input  logic [NrHarts-1:0]          cmdbusy_i,       // cmd is currently busy executing
    output [dm::ProgBufSize-1:0][31:0]  progbuf_o        // to system bus
);
    // the amount of bits we need to represent all harts
    localparam HartSelLen = (NrHarts == 1) ? 1 : $clog2(NrHarts);

    logic        resp_queue_full;
    logic        resp_queue_empty;
    logic        resp_queue_push;
    logic [31:0] resp_queue_data;

    logic [10:0] hartsel;
    assign hartsel    = {dmcontrol_q.hartselhi, dmcontrol_q.hartsello};

    logic [31:0] haltsum0, haltsum1, haltsum2, haltsum3;
    for (genvar i = 0; i < 32; i++) begin
        assign haltsum0[i] = halted_i[hartsel[HartSelLen-1:5]];
        assign haltsum1[i] = (NrHarts > 32)    ? &halted_i[hartsel[HartSelLen-1:10] +: 32]    : 1'b0;
        assign haltsum2[i] = (NrHarts > 1024)  ? &halted_i[hartsel[HartSelLen-1:15] +: 1024]  : 1'b0;
        assign haltsum3[i] = (NrHarts > 32768) ? &halted_i[hartsel[HartSelLen-1:15] +: 32768] : 1'b0;
    end

    dm::dmstatus_t      dmstatus;
    dm::dmcontrol_t     dmcontrol_d, dmcontrol_q;
    dm::abstractcs_t    abstractcs;
    dm::cmderr_t        cmderr_d, cmderr_q;
    dm::command_t       command_d, command_q;
    // program buffer
    logic [dm::ProgBufSize-1:0][31:0] progbuf_d, progbuf_q;
    logic [dm::DataCount-1:0][31:0]   data_d,    data_q;

    logic [NrHarts-1:0] selected_hart;

    // a successful response returns zero
    assign dmi_resp_bits_resp_o = DTM_SUCCESS;
    assign dmi_resp_valid_o     = ~resp_queue_empty;
    assign dmi_req_ready_o      = ~resp_queue_full;
    assign resp_queue_push      = dmi_req_valid_i & dmi_req_ready_o;

    always_comb begin : csr_read_write
        // default assignments
        dmcontrol_d = dmcontrol_q;
        cmderr_d    = cmderr_q;
        command_d   = command_q;
        progbuf_d   = progbuf_q;

        resp_queue_data = 32'0;
        command_write_o = 1'b0;

        // read
        if (dmi_req_valid_i && dmi_req_bits_op_i == DTM_READ) begin
            unique case (dm_csr_t'({1'b0, dmi_req_bits_addr_i})) inside
                [(dm::Data0):(dm::Data0 + dm::DataCount << 2)]: begin
                    resp_queue_data = data_q[dmi_req_bits_addr_i[4:0]];
                end
                dm::DMControl:  resp_queue_data = dmcontrol_q;
                dm::DMStatus:   resp_queue_data = dmstatus;
                dm::Hartinfo:   resp_queue_data = hartinfo_i[selected_hart];
                dm::AbstractCS: resp_queue_data = abstractcs;
                dm::Command:    resp_queue_data = command_q;
                [(dm::ProgBuf0):(dm::ProgBuf0 + dm::ProgBufSize << 2)]: begin
                    resp_queue_data = progbuf_q[dmi_req_bits_addr_i[4:0]];
                end
                dm::HaltSum0: resp_queue_data = haltsum0;
                dm::HaltSum1: resp_queue_data = haltsum1;
                dm::HaltSum2: resp_queue_data = haltsum2;
                dm::HaltSum3: resp_queue_data = haltsum3;
                default:;
            endcase
        end

        // write
        if (dmi_req_valid_i && dmi_req_bits_op_i == DTM_WRITE) begin
            unique case (dm_csr_t'({1'b0, dmi_req_bits_addr_i})) inside
                [(dm::Data0):(dm::Data0 + dm::DataCount << 2)]: begin
                    // attempts to write them while busy is set does not change their value
                    if (!cmdbusy_i) begin
                        data_d[dmi_req_bits_addr_i[4:0]] = dmi_req_bits_data_i;
                    end
                end
                dm::DMControl: dmcontrol_d = dmi_req_bits_data_i;
                dm::DMStatus:; // write are ignored to R/O register
                dm::Hartinfo:; // hartinfo is R/O
                // only command error is write-able
                dm::AbstractCS: begin
                    automatic dm::abstractcs_t abstractcs;
                    abstractcs = dm::abstractcs_t'(dmi_req_bits_data_i);
                    cmderr_d = abstractcs.cmderr;
                end
                dm::Command: begin
                    command_write_o = 1'b1;
                    command_d = dmi_req_bits_data_i;
                end
                [dm::ProgBuf0:dm::ProgBuf15]: begin
                    // attempts to write them while busy is set does not change their value
                    if (!cmdbusy_i) begin
                        probuf_d[dmi_req_bits_addr_i[4:0]] = dmi_req_bits_data_i;
                    end
                end
                default:;
            endcase
        end
        // hart threw a command error and has precedence over bus writes
        if (set_cmderror_i[selected_hart]) begin
            cmderr_d = cmderror_i[selected_hart];
        end
        // --------------------
        // Static Values (R/O)
        // --------------------
        // dmstatus
        dmstatus    = '0;
        dmstatus.version = DbgVersion013;
        // no authentication implemented
        dmstatus.authenticated = 1'b1;
        // we do not support halt-on-reset sequence
        dmstatus.hasresethaltreq = 1'b0;
        // TODO(zarubaf) things need to change here if we implement the array mask
        dmstatus.allhavereset = havereset_i[hartsel[HartSelLen-1:0]];
        dmstatus.anyhavereset = havereset_i[hartsel[HartSelLen-1:0]];

        dmstatus.allresumeack = resumeack_i[hartsel[HartSelLen-1:0]];
        dmstatus.anyresumeack = resumeack_i[hartsel[HartSelLen-1:0]];

        dmstatus.allunavail   = unavailable_i[hartsel[HartSelLen-1:0]];
        dmstatus.anyunavail   = unavailable_i[hartsel[HartSelLen-1:0]];

        dmstatus.allnonexistent = (hartsel > NrHarts - 1) ? 1'b1 : 1'b0;
        dmstatus.anynonexsstent = (hartsel > NrHarts - 1) ? 1'b1 : 1'b0;

        dmstatus.allhalted    = halted_i[hartsel[HartSelLen-1:0]];
        dmstatus.anyhalted    = halted_i[hartsel[HartSelLen-1:0]];

        dmstatus.allrunning   = running_i[hartsel[HartSelLen-1:0]];
        dmstatus.anyrunning   = running_i[hartsel[HartSelLen-1:0]];

        // dmcontrol
        // determine how how many harts we actually want to select
        // and tie-off (through constant propagation the remaining harts)
        {dmcontrol_d.hartselhi, dmcontrol_d.hartsello} = hartsel[19:HartSelLen];
        // TODO(zarubaf) we currently do not implement the hartarry mask
        dmcontrol_d.hasel           = 1'b0;
        // we do not support resetting an individual hart
        dmcontrol_d.hartreset       = 1'b0;
        // we only allow 1024 harts
        dmcontrol_d.hartselhi       = '0;
        dmcontrol_d.setresethaltreq = 1'b0;
        dmcontrol_d.clrresethaltreq = 1'b0;
        dmcontrol_d.zero1           = '0;
        dmcontrol_d.zero0           = '0;

        // abstractcs
        abstractcs = '0;
        abstractcs.datacount = dm::DataCount;
        abstractcs.progbufsize = dm::ProgBufSize;
        abstractcs.busy = cmdbusy_i[selected_hart];
        abstractcs.cmderr = cmderr_q;
    end

    // output multiplexer
    always_comb begin
        selected_hart = hartsel[NrHarts-1:0];
        // default assignment
        halt_req_o = '0;
        resume_req_o = '0;
        halt_req[selected_hart] = dmcontrol_q.haltreq;
        resume_req_o[selected_hart] = dmcontrol_q.resumereq;
    end

    assign dmactive_o = dmcontrol_q.dmactive;
    assign ndmreset_o = dmcontrol_q.ndmreset;
    assign command_o  = command_q;

    // response FIFO
    fifo #(
        .dtype            ( logic [31:0]         ),
        .DEPTH            ( 2                    )
    ) i_fifo (
        .clk_i            ( clk_i                ),
        .rst_ni           ( dmi_rst_ni           ), // reset only when system is re-set
        .flush_i          ( 1'b0                 ), // we do not need to flush this queue
        .full_o           ( resp_queue_full      ),
        .empty_o          ( resp_queue_empty     ),
        .single_element_o (                      ),
        .data_i           ( resp_queue_data      ),
        .push_i           ( resp_queue_push      ),
        .data_o           ( dmi_resp_bits_data_o ),
        .pop_i            ( dmi_resp_ready_i     )
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            dmcontrol_q <= '0;
        end else begin
            // synchronous re-set, active-low, except for dmactive
            if (!dmcontrol_q.dmactive) begin
                dmcontrol_q.haltreq          <= '0;
                dmcontrol_q.resumereq        <= '0;
                dmcontrol_q.hartreset        <= '0;
                dmcontrol_q.ackhavereset     <= '0;
                dmcontrol_q.zero1            <= '0;
                dmcontrol_q.hasel            <= '0;
                dmcontrol_q.hartsello        <= '0;
                dmcontrol_q.hartselhi        <= '0;
                dmcontrol_q.zero0            <= '0;
                dmcontrol_q.setresethaltreq  <= '0;
                dmcontrol_q.clrresethaltreq  <= '0;
                dmcontrol_q.ndmreset         <= '0;
                dmcontrol_q.dmactive         <= dmcontrol_d.dmactive;
                cmderr_q                     <= dm::CmdErrNone;
                command_q                    <= '0;
                progbuf_q                    <= '0;
            end else begin
                dmcontrol_q                  <= dmcontrol_d;
                cmderr_q                     <= cmderr_d;
                command_q                    <= command_q;
                progbuf_q                    <= progbuf_d;
            end
        end
    end
endmodule
