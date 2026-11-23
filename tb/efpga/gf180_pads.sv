// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// The GF180MCU pad cells of flow/librelane/experimental/mosaic_chip_efpga.sv, for
// its netlist bench in Verilator (tb/efpga/run_soc_block.sh). The PDK's models
// (libs.ref/gf180mcu_fd_io/verilog) pull a released pad with rnmos switches,
// which Verilator does not support (a comment line must not start with that
// word: Verilator reads it as a directive). These pull with a weak drive and
// otherwise behave as those models, without their delays: an input pad's Y is
// its PAD, pulls ignored, as there; bi_t drives PAD with A while OE and gives
// Y = PAD & IE; the power pads have no function.
`default_nettype none

module gf180mcu_fd_io__in_c (
    input  wire PU, PD, PAD,
    output wire Y,
    inout  wire DVDD, DVSS, VDD, VSS
);
  assign Y = PAD;
endmodule

module gf180mcu_fd_io__in_s (
    input  wire PU, PD, PAD,
    output wire Y,
    inout  wire DVDD, DVSS, VDD, VSS
);
  assign Y = PAD;
endmodule

module gf180mcu_fd_io__bi_t (
    input  wire CS, SL, IE, OE, PU, PD, A, PDRV0, PDRV1,
    inout  wire PAD,
    output wire Y,
    inout  wire DVDD, DVSS, VDD, VSS
);
  assign PAD = OE ? A : 1'bz;
  assign (weak0, weak1) PAD = OE ? 1'bz : (PD && !PU) ? 1'b0 : (PU && !PD) ? 1'b1 : 1'bz;
  assign Y = PAD & IE;
endmodule

module gf180mcu_ws_io__dvdd (
    inout wire DVDD, DVSS, VSS
);
endmodule

module gf180mcu_ws_io__dvss (
    inout wire DVDD, DVSS, VDD
);
endmodule

// The corner and the fillers of the ring: no function, no pin in the netlist.
module gf180mcu_fd_io__cor; endmodule
module gf180mcu_fd_io__fill1; endmodule
module gf180mcu_fd_io__fill5; endmodule
module gf180mcu_fd_io__fill10; endmodule

`default_nettype wire
