// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// The example of the user flow (docs/efpga.md): a design written against the
// shell of the preset alone, with no top_wrapper of its own. One register
// behind the user window of hw/efpga/mosaic_efpga.sv, which describes the
// handshake, and its low byte on the pads:
//   every word  R, 32 bits, written byte by byte (be), 0 after the user reset
//   pads 7:0    R[7:0], driven
`default_nettype none
module shell_regs (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid,
    input  wire        we,
    input  wire [ 3:0] be,
    input  wire [31:0] wdata,
    output wire        ack,
    output wire [31:0] rdata,
    output wire [ 7:0] io_out,
    output wire [ 7:0] io_oeb
);
    reg [31:0] r;
    reg        ack_q;
    integer    k;

    always @(posedge clk) begin
        if (!rst_n) begin
            ack_q <= 1'b0;
            r     <= 32'd0;
        end else begin
            ack_q <= valid;  // rises after valid, falls after it
            if (valid && !ack_q && we) begin  // once per request
                for (k = 0; k < 4; k = k + 1) if (be[k]) r[8*k+:8] <= wdata[8*k+:8];
            end
        end
    end

    assign ack    = ack_q;
    assign rdata  = r;
    assign io_out = r[7:0];
    assign io_oeb = 8'h00;
endmodule
`default_nettype wire
