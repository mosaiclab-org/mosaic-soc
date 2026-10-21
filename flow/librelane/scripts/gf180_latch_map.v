// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Yosys techmap: a positive-enable latch on GF180MCU's latq cell, which holds
// !D and drives Q from its inverted store, so Q = D while E is high. The
// configuration latches of an eFPGA fabric need it: dfflibmap maps no latch
// (flow/librelane/scripts/efpga_synth.sh).
module \$_DLATCH_P_ (
    input  E,
    input  D,
    output Q
);
  gf180mcu_fd_sc_mcu7t5v0__latq_1 _TECHMAP_REPLACE_ (
      .E(E),
      .D(D),
      .Q(Q)
  );
endmodule
