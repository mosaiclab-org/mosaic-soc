// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// A design whose path is longer than four cycles of the fabric's clock allow,
// for a fabric's clock of its own (EFPGA_DIV, mosaic_efpga_design in tb/tools.sh;
// sweep step efpga_timed). A write takes, into a flip-flop, the parity of
// wdata[31] and wdata[23:0], through a chain of 24 XORs, one per bit; a read of
// any word returns it in bit 0. At 50 ns the chain needs about 11 cycles at the
// slow corner, where one of 40 needed 16, all CLKDIV gives. Each XOR is a LUT2 of the fabric
// instantiated as such, since synthesis folds a chain written as logic into a
// tree a few LUTs deep. nextpnr does not time a path from the window, so it
// places this one; the timing of the flow gives it its N.
`default_nettype none
module long_chain (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid,
    input  wire        we,
    input  wire [31:0] wdata,
    output wire        ack,
    output wire [31:0] rdata
);
    reg        q, ack_q;
    wire [24:0] link;

    assign link[0] = wdata[31];
    genvar i;
    generate
        for (i = 0; i < 24; i = i + 1) begin : g_link
            LUT2 #(.INIT(4'b0110)) xor_i (.O(link[i+1]), .I0(link[i]), .I1(wdata[i]));
        end
    endgenerate

    always @(posedge clk) begin
        if (!rst_n) begin
            ack_q <= 1'b0;
            q     <= 1'b0;
        end else begin
            ack_q <= valid;  // rises after valid, falls after it
            if (valid && !ack_q && we) q <= link[24];
        end
    end

    assign ack   = ack_q;
    assign rdata = {31'd0, q};
endmodule
`default_nettype wire
