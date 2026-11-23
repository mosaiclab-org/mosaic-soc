// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Binds counter8_en to the pads and the clock of the `small` preset. Adapted
// from the top_wrapper.v of FABulous's project template (Apache-2.0, see
// UPSTREAM.md): FABulous's gen_user_design_wrapper leaves the ports of a
// design that is not its template's unconnected.
`default_nettype none

module top_wrapper;
    wire [7:0] io_in, io_out, io_oeb;
    (* keep, BEL="X0Y1.A" *) IO_1_bidirectional_frame_config_pass io7_i (.O(io_in[7]), .I(io_out[7]), .T(io_oeb[7]));
    (* keep, BEL="X0Y1.B" *) IO_1_bidirectional_frame_config_pass io6_i (.O(io_in[6]), .I(io_out[6]), .T(io_oeb[6]));
    (* keep, BEL="X0Y2.A" *) IO_1_bidirectional_frame_config_pass io5_i (.O(io_in[5]), .I(io_out[5]), .T(io_oeb[5]));
    (* keep, BEL="X0Y2.B" *) IO_1_bidirectional_frame_config_pass io4_i (.O(io_in[4]), .I(io_out[4]), .T(io_oeb[4]));
    (* keep, BEL="X0Y3.A" *) IO_1_bidirectional_frame_config_pass io3_i (.O(io_in[3]), .I(io_out[3]), .T(io_oeb[3]));
    (* keep, BEL="X0Y3.B" *) IO_1_bidirectional_frame_config_pass io2_i (.O(io_in[2]), .I(io_out[2]), .T(io_oeb[2]));
    (* keep, BEL="X0Y4.A" *) IO_1_bidirectional_frame_config_pass io1_i (.O(io_in[1]), .I(io_out[1]), .T(io_oeb[1]));
    (* keep, BEL="X0Y4.B" *) IO_1_bidirectional_frame_config_pass io0_i (.O(io_in[0]), .I(io_out[0]), .T(io_oeb[0]));

    wire clk;
    (* keep *) Global_Clock clk_i (.CLK(clk));

    counter8_en top_i (.clk(clk), .io_in(io_in), .io_out(io_out), .io_oeb(io_oeb));
endmodule
`default_nettype wire
