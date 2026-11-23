// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// The user design of the wrapper test: two registers behind the user window of
// hw/efpga/mosaic_efpga.sv, which describes the handshake.
//   word 0  R0, 32 bits, R0_RESET after the user reset
//   word 1  R1,  4 bits, 0 after the user reset. Only the low four bits of
//           the read data are decoded: bits 31:4 of word 1 read as R0's. A
//           read multiplexer on all 32 bits does not fit the 64 logic cells
//           of the `small` preset.
`default_nettype none
module bus_regs #(
    parameter [31:0] R0_RESET = 32'h600D_F00D
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid,
    input  wire        we,
    input  wire        addr0,  // the word address: only one bit is decoded
    input  wire [31:0] wdata,
    output wire        ack,
    output wire [31:0] rdata
);
    reg [31:0] r0;
    reg [ 3:0] r1;
    reg        ack_q;

    always @(posedge clk) begin
        if (!rst_n) begin
            ack_q <= 1'b0;
            r0    <= R0_RESET;
            r1    <= 4'd0;
        end else begin
            ack_q <= valid;  // rises after valid, falls after it
            if (valid && !ack_q && we) begin  // once per request
                if (addr0) r1 <= wdata[3:0];
                else r0 <= wdata;
            end
        end
    end

    assign ack   = ack_q;
    assign rdata = {r0[31:4], addr0 ? r1 : r0[3:0]};
endmodule
`default_nettype wire
