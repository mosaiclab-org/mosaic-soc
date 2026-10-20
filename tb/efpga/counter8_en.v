// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// User design of the eFPGA fabric bench: an 8-bit counter on the 8 pads of the
// `small` preset. The same file is compiled to the bitstream and simulated as
// the reference the fabric is compared with.
`default_nettype none

module counter8_en (
    input  wire       clk,
    input  wire [7:0] io_in,
    output wire [7:0] io_out,
    output wire [7:0] io_oeb
);
    wire rst = io_in[0];
    wire en = io_in[1];
    reg [7:0] ctr;

    always @(posedge clk)
        if (en) begin
            if (rst) ctr <= 0;
            else ctr <= ctr + 1'b1;
        end

    assign io_out = ctr;
    assign io_oeb = 8'b0000_0001;
endmodule
`default_nettype wire
