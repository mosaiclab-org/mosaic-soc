# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# The timing constraints of a chip with a GF180MCU pad ring (FALLBACK_SDC of
# flow/librelane/scripts/efpga_block.sh with EFPGA_CHIP, so also what
# signoff_library_limits.sdc sources at signoff): LibreLane's own base.sdc, without
# its driving cells.
#
# WHY. base.sdc drives every input port with a standard cell, SYNTH_DRIVING_CELL
# (inv_1), and the clock port with SYNTH_CLK_DRIVING_CELL (inv_4). On a block that
# stands for the logic in front of it. On a chip a port is a pad's PAD pin, 3.2 pF,
# and the board drives it: at ss_125C_4v50 the inv_1 took 49 ns into uart_rx_PAD
# with an 88 ns edge, and the inv_4 put 7.7 ns and a 12.9 ns edge in front of the
# clock pad. Every path that failed after global routing on the first chip run
# (2026-11-08, worst -32.8 ns, five paths, reg-to-reg +7.3 ns) went through them.
# Here the ports are undriven, an ideal edge at the pin, as in
# wafer-space/gf180mcu-project-template's chip_top.sdc.
#
# The clock stays where base.sdc puts it, on the port, so the clock pad's own
# delay counts in each launch and capture, as it does on the board; the input and
# output delays are base.sdc's, relative to it, but for the flash's data out (THE
# FLASH, below). That template creates the clock at the pad's output (CLOCK_NET)
# instead, which leaves the clock pad out of every path to and from a pad.
#
# HOW. Not a copy, which would drift from what every other run uses: the command is
# set aside while base.sdc is read, as pdn_chip.tcl does with add_pdn_ring.
#
# openroad/common/io.tcl greps the SDC it is given for the next two names and
# propagates the clocks itself if neither is there; base.sdc does it, so they stay
# (see signoff_library_limits.sdc):
#     set_propagated_clock / unset_propagated_clock
rename set_driving_cell _mosaic_set_driving_cell
proc set_driving_cell {args} {}
source [file join $::env(SCRIPTS_DIR) base.sdc]
rename set_driving_cell {}
rename _mosaic_set_driving_cell set_driving_cell

# THE FLASH. Its four data pads are timed against the clock that reaches the flash,
# the chip's SCK, not against clk_PAD. spimemio moves the data on an edge of the clk
# that moves SCK, through the same tree and the same kind of pad, so the two delays
# meet at the flash: a source-synchronous output. In SDR modes the data changes as
# SCK falls and the flash takes it as SCK rises, one cycle of clk later; in DDR the
# negedge flops xfer_io*_90 move it half a cycle after an edge of SCK and the flash
# takes it on both, half a cycle later. SCK is a flop's output toggled at most
# every cycle, flash_clk (or spi_host's, slower): a clock generated from clk_PAD,
# divided by 2, whose latency OpenSTA traces from clk_PAD to the SCK pad, and
# base.sdc's output delay against both of its edges. Against clk_PAD the first
# chip run missed by 0.825 ns at max_ss on sd[1] (2026-11-08): the clock pad and
# tree counted against the data and not against SCK; against SCK, on that run's
# routed state, setup +14.47 ns and hold +4.81 ns at worst, of the nine corners.
# The pads' inputs and the SCK and CS pads keep base.sdc's constraints.
create_generated_clock -name flash_sck -source [get_ports $::clock_port] -divide_by 2 \
    [get_ports spi_flash_sck_PAD]
set flash_sd [get_ports {spi_flash_sd_PAD[*]}]
unset_output_delay -clock $clocks $flash_sd
set_output_delay $output_delay_value -clock flash_sck $flash_sd
set_output_delay $output_delay_value -clock flash_sck -clock_fall -add_delay $flash_sd
set_clock_uncertainty $::env(CLOCK_UNCERTAINTY_CONSTRAINT) [get_clocks flash_sck]
if { ![info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] || !$::env(OPENLANE_SDC_IDEAL_CLOCKS) } {
    set_propagated_clock [get_clocks flash_sck]
}
