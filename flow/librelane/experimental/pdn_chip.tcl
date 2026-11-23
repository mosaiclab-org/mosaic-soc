# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# The power grid of a chip with a GF180MCU pad ring (PDN_CFG of
# flow/librelane/scripts/efpga_block.sh with EFPGA_CHIP): LibreLane's own,
# scripts/openroad/common/pdn_cfg.tcl, with its core ring tied to the pads on
# Metal3.
#
# WHY. The pads carry VDD and VSS as rails along the ring, inside the cells, from
# 246 to 325 um of their 350: no rail reaches the side that faces the core. What
# does is a tab on the power pads of wafer-space's gf180mcu_ws_io, 350 to 357 um,
# out of the cell towards the core. PDN_CORE_RING_CONNECT_TO_PADS alone ties the
# ring to pads on the ring's own layers, Metal4 and Metal5, where there is nothing
# to reach, and the grid then had no source: every shape of VDD and of VSS
# unconnected (PSM-0069), on the first try (2026-11-08). Pad layers then, as in
# wafer-space/gf180mcu-project-template, whose LibreLane takes them as a variable;
# 3.0.0 does not.
#
# WHY METAL3. The tab is six fingers of Metal2 and the same six of Metal3, joined
# in the pad's GDS by 1034 Via2 cuts that its LEF does not show. Tied on Metal2,
# as that template does, pdngen put its own Via2 over them wherever a Metal4 stripe
# of the core crossed a pad of its net, on another grid: Magic DRC 4048 (V2.1,
# V2.2a) at the four such pads of the chip of slot_1x1_efpga.yaml (2026-11-08). On
# Metal3 its vias up to the ring are Via3 and Via4, and the tab has neither: Magic
# DRC 0 (2026-11-09). A strap under a Metal4 stripe of its net, though, is now
# parallel to it, and pdngen stretched one along it into the core; the Metal3 bands
# of PDN_OBSTRUCTIONS in efpga_block.sh stop that at the ring.
#
# HOW. Not a copy, which would drift from the script every other run uses: the
# ring command is wrapped for the time the script is read.
rename add_pdn_ring _mosaic_add_pdn_ring
proc add_pdn_ring {args} {
    _mosaic_add_pdn_ring {*}$args -connect_to_pad_layers Metal3
}
source [file join $::env(SCRIPTS_DIR) openroad common pdn_cfg.tcl]
rename add_pdn_ring {}
rename _mosaic_add_pdn_ring add_pdn_ring
# And vias from those Metal3 straps up to the ring's two layers, as that template
# adds them: without a connection pdngen trims the straps as dangling.
add_pdn_connect -grid stdcell_grid -layers "$::env(PDN_VERTICAL_LAYER) Metal3"
add_pdn_connect -grid stdcell_grid -layers "$::env(PDN_HORIZONTAL_LAYER) Metal3"
