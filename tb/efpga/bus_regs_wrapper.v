// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Binds bus_regs to the east edge of the `small` preset as
// hw/efpga/mosaic_efpga.sv drives it: row g of that module is the RAM_IO tile
// at Y<4-g>, which has four BELs of 4 inputs (RAM2FAB_D0..D3) and seven of 4
// outputs (FAB2RAM_D0..D3, A0, A1, C). nextpnr names these BELs after their
// ports, not by the letter FABulous's bel.txt gives them. The byte enables
// and the upper address bits are not used by this design.
`default_nettype none
module top_wrapper;
    wire clk, rst_n, valid, we, addr0, ack;
    wire [31:0] wdata, rdata;
    (* keep, BEL="X3Y4.RAM2FAB_D0" *) InPass4_frame_config_mux wdata0_i (.O0(wdata[0]), .O1(wdata[1]), .O2(wdata[2]), .O3(wdata[3]));
    (* keep, BEL="X3Y4.RAM2FAB_D1" *) InPass4_frame_config_mux wdata4_i (.O0(wdata[4]), .O1(wdata[5]), .O2(wdata[6]), .O3(wdata[7]));
    (* keep, BEL="X3Y3.RAM2FAB_D0" *) InPass4_frame_config_mux wdata8_i (.O0(wdata[8]), .O1(wdata[9]), .O2(wdata[10]), .O3(wdata[11]));
    (* keep, BEL="X3Y3.RAM2FAB_D1" *) InPass4_frame_config_mux wdata12_i (.O0(wdata[12]), .O1(wdata[13]), .O2(wdata[14]), .O3(wdata[15]));
    (* keep, BEL="X3Y2.RAM2FAB_D0" *) InPass4_frame_config_mux wdata16_i (.O0(wdata[16]), .O1(wdata[17]), .O2(wdata[18]), .O3(wdata[19]));
    (* keep, BEL="X3Y2.RAM2FAB_D1" *) InPass4_frame_config_mux wdata20_i (.O0(wdata[20]), .O1(wdata[21]), .O2(wdata[22]), .O3(wdata[23]));
    (* keep, BEL="X3Y1.RAM2FAB_D0" *) InPass4_frame_config_mux wdata24_i (.O0(wdata[24]), .O1(wdata[25]), .O2(wdata[26]), .O3(wdata[27]));
    (* keep, BEL="X3Y1.RAM2FAB_D1" *) InPass4_frame_config_mux wdata28_i (.O0(wdata[28]), .O1(wdata[29]), .O2(wdata[30]), .O3(wdata[31]));
    (* keep, BEL="X3Y4.RAM2FAB_D2" *) InPass4_frame_config_mux ctl0_i (.O0(valid), .O1(we), .O2(rst_n));
    (* keep, BEL="X3Y4.RAM2FAB_D3" *) InPass4_frame_config_mux ctl4_i (.O3(addr0));
    (* keep, BEL="X3Y4.FAB2RAM_D0" *) OutPass4_frame_config_mux rdata0_i (.I0(rdata[0]), .I1(rdata[1]), .I2(rdata[2]), .I3(rdata[3]));
    (* keep, BEL="X3Y4.FAB2RAM_D1" *) OutPass4_frame_config_mux rdata4_i (.I0(rdata[4]), .I1(rdata[5]), .I2(rdata[6]), .I3(rdata[7]));
    (* keep, BEL="X3Y3.FAB2RAM_D0" *) OutPass4_frame_config_mux rdata8_i (.I0(rdata[8]), .I1(rdata[9]), .I2(rdata[10]), .I3(rdata[11]));
    (* keep, BEL="X3Y3.FAB2RAM_D1" *) OutPass4_frame_config_mux rdata12_i (.I0(rdata[12]), .I1(rdata[13]), .I2(rdata[14]), .I3(rdata[15]));
    (* keep, BEL="X3Y2.FAB2RAM_D0" *) OutPass4_frame_config_mux rdata16_i (.I0(rdata[16]), .I1(rdata[17]), .I2(rdata[18]), .I3(rdata[19]));
    (* keep, BEL="X3Y2.FAB2RAM_D1" *) OutPass4_frame_config_mux rdata20_i (.I0(rdata[20]), .I1(rdata[21]), .I2(rdata[22]), .I3(rdata[23]));
    (* keep, BEL="X3Y1.FAB2RAM_D0" *) OutPass4_frame_config_mux rdata24_i (.I0(rdata[24]), .I1(rdata[25]), .I2(rdata[26]), .I3(rdata[27]));
    (* keep, BEL="X3Y1.FAB2RAM_D1" *) OutPass4_frame_config_mux rdata28_i (.I0(rdata[28]), .I1(rdata[29]), .I2(rdata[30]), .I3(rdata[31]));
    (* keep, BEL="X3Y4.FAB2RAM_C" *) OutPass4_frame_config_mux ack_i (.I0(ack));
    (* keep *) Global_Clock clk_i (.CLK(clk));
    bus_regs top_i (
        .clk(clk), .rst_n(rst_n), .valid(valid), .we(we), .addr0(addr0),
        .wdata(wdata), .ack(ack), .rdata(rdata)
    );
endmodule
`default_nettype wire
