#!/bin/bash
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# flow/librelane/scripts/efpga_block_sta.sh — what a block hardened with the
# fabric as a macro (flow/librelane/scripts/efpga_block.sh: the wrapper alone, or a
# SoC) adds to the timing of its macro, which the flow's own STA cannot see: the
# macro's liberty has no arcs. At the nine corners, on the block's netlist and
# extraction:
#   - the wrapper's side of the window, measured: when its flops launch into the
#     macro's RAM2FAB pins and when it needs FAB2RAM back, in ns from the macro's
#     UserCLK pin. efpga_sta.sh then times each design with these in place of its
#     estimates, the worst port at each corner for every port.
#   - slew, capacitance and fan-out with the macro's real cells in place: a wire
#     of the top level that a tile drives has no driver in the liberty.
#   - the configuration write: the wrapper's latest strobe at the macro's pin, on
#     top of the latest strobe inside it (efpga_sta.sh).
# The pads are not timed, since what drives them is outside the chip.
#
# Pass: "BLOCK STA PASS ...", after efpga_sta.sh's "STA DESIGN PASS" per design.
# Usage: efpga_block_sta.sh <the --out of efpga_gen.py --stitch> <block's final views> <design> ...
# Logs: build/efpga_block_sta/<the block's top module>/.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO"
RUN="$(cd "${1:?usage: efpga_block_sta.sh <stitched run> <final views> <design> ...}" && pwd)"
VIEWS="$(cd "${2:?usage: efpga_block_sta.sh <stitched run> <final views> <design> ...}" && pwd)"
shift 2
PERIOD="${EFPGA_STA_PERIOD:-50}"
PDK="${GF180_PDK_ROOT:-$REPO/flow/librelane/gf180mcu}"
LIB="$PDK/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__"
# A chip's pad cells, as the flow reads them (gf180mcu_fd_io and gf180mcu_ws_io).
IO="$PDK/gf180mcuD/libs.ref/gf180mcu_fd_io/lib"
fail() { echo "BLOCK STA FAIL: $*"; exit 1; }
# The block's top module and the macro's instance in it, from its netlist.
NETLIST="$(ls "$VIEWS"/nl/*.nl.v)"
TOP="$(basename "$NETLIST" .nl.v)"
INST="$(sed -nE 's/^ *eFPGA +\\?([^ (]+) .*/\1/p' "$NETLIST")"
[ "$(wc -w <<< "$INST")" -eq 1 ] || fail "not one eFPGA instance in $NETLIST: $INST"
# A chip's clock arrives on its pad (flow/librelane/experimental/mosaic_chip_efpga.sv).
CLK=clk_i
! grep -qw clk_PAD "$NETLIST" || CLK=clk_PAD
OUT="$REPO/build/efpga_block_sta/$TOP"
STA="$REPO/build/efpga_sta/$(basename "$RUN")"
[ -f "$STA/lib/eFPGA__tt_025C_5v00.lib" ] && [ -f "$STA/tiles.tcl" ] \
    || flow/librelane/scripts/efpga_sta.sh "$RUN" > /dev/null \
    || fail "the macro does not pass efpga_sta.sh"
rm -rf "$OUT"
mkdir -p "$OUT/lib"
cp "$STA"/lib/*.lib "$STA/tiles.tcl" "$OUT/lib/"

# The macro as a liberty whose window pins have arcs of no delay to UserCLK. With
# the clock's real arrival at the macro on one side and the wrapper's flops on the
# other, a slack at one period is then the window's value: from the macro's
# UserCLK pin, launch is (period - setup slack), launch_min the hold slack, capture
# (period - setup slack), capture_min the hold slack. The worst pin of each.
cat > "$OUT/window.tcl" <<EOF
read_liberty ${LIB}\$::env(LIBC).lib
foreach io [glob -nocomplain $IO/*__\$::env(LIBC).lib] { read_liberty \$io }
read_liberty $OUT/lib/eFPGA__\$::env(LIBC).window.lib
read_verilog $NETLIST
link_design $TOP
read_spef $VIEWS/spef/\$::env(RC)/$TOP.\$::env(RC).spef
create_clock -name clk -period $PERIOD [get_ports $CLK]
set_propagated_clock [get_clocks clk]
set in [get_pins {$INST/Tile_*RAM2FAB_D*}]
set out {}
foreach p [concat [get_pins {$INST/Tile_*FAB2RAM_C_*}] [get_pins {$INST/Tile_*FAB2RAM_D*}]] {
  if {[llength [get_fanout -from \$p -flat -endpoints_only]]} { lappend out \$p }
}
proc slack {args} { return [get_property [find_timing_paths {*}\$args] slack] }
proc worst {property pins} {
  set w 0.0
  foreach p \$pins { set w [expr {max(\$w, [get_property \$p \$property])}] }
  return \$w
}
set launch [expr {$PERIOD - [slack -to \$in -path_delay max]}]
set launch_min [slack -to \$in -path_delay min]
set capture [expr {$PERIOD - [slack -through \$out -path_delay max]}]
set capture_min [slack -through \$out -path_delay min]
set load 0.0
foreach p \$out { set load [expr {max(\$load, [[get_nets -of_objects \$p] capacitance [sta::cmd_corner] max] * 1e12)}] }
set in_slew [expr {max([worst slew_max_rise \$in], [worst slew_max_fall \$in])}]
set clk_slew [get_property [get_pins {$INST/UserCLK}] slew_max_rise]
set strobes [get_pins {$INST/FrameStrobe*}]
set_max_delay 1000 -to \$strobes
set strobe [expr {1000 - [slack -to \$strobes -path_delay max]}]
set f [open $OUT/window_\$::env(RC)_\$::env(LIBC).tcl w]
foreach name {launch launch_min capture capture_min load in_slew clk_slew} { puts \$f "set \$name [set \$name]" }
close \$f
puts "### WINDOW \$launch \$launch_min \$capture \$capture_min \$load \$in_slew \$clk_slew \$strobe"
EOF

# The whole block, the macro as its tiles (efpga_sta.sh): only the limits.
cat > "$OUT/drv.tcl" <<EOF
read_liberty ${LIB}\$::env(LIBC).lib
foreach io [glob -nocomplain $IO/*__\$::env(LIBC).lib] { read_liberty \$io }
source $OUT/lib/tiles.tcl
read_verilog $NETLIST
foreach tile [array names nl] { read_verilog \$nl(\$tile) }
link_design $TOP
read_spef $VIEWS/spef/\$::env(RC)/$TOP.\$::env(RC).spef
foreach inst [get_cells {$INST/*}] { read_spef -path [get_full_name \$inst] \$spef([get_property \$inst ref_name]) }
foreach net [get_nets {$INST/*}] {
  set c 0.0
  foreach pin [get_pins -quiet -of_objects \$net] {
    set k "\$::env(RC),[get_property [get_cells -of_objects \$pin] ref_name],[regsub {^.*/} [get_full_name \$pin] {}]"
    if {[info exists pcap(\$k)]} { set c [expr {\$c + \$pcap(\$k)}] }
  }
  if {\$c > 0} { set_load \$c \$net }
}
create_clock -name clk -period $PERIOD [get_ports $CLK]
set_propagated_clock [get_clocks clk]
puts "### DRV"
report_check_types -max_slew -max_capacitance -max_fanout -violators -digits 3
puts "### END"
EOF

echo "### the nine corners of the block ..."
nix develop "$REPO#physical" --option warn-dirty false --command bash -c "
  set -e
  for lib in tt_025C_5v00 ss_125C_4v50 ff_n40C_5v50; do for rc in nom min max; do
    LIBC=\$lib RC=\$rc sta -no_init -exit $OUT/window.tcl > $OUT/window_\${rc}_\$lib.log 2>&1
    LIBC=\$lib RC=\$rc sta -no_init -exit $OUT/drv.tcl > $OUT/drv_\${rc}_\$lib.log 2>&1
  done; done
" > "$OUT/tools.log" 2>&1 || fail "OpenSTA, see $OUT/*.log"

python3 - "$OUT" "$STA/summary.tsv" "$PERIOD" <<'EOF'
import csv, re, sys
from pathlib import Path
out, inside, period = Path(sys.argv[1]), Path(sys.argv[2]), float(sys.argv[3])
strobes = {row["corner"]: float(row["framestrobe_ns"]) for row in csv.DictReader(inside.open(), delimiter="\t")}
# The library's hold of latq_1 is 1.1 ns at worst (efpga_sta.sh).
LATCH_HOLD = 1.1
rows, errors = [], []
for log in sorted(out.glob("window_*.log")):
    corner = log.stem.removeprefix("window_")
    found = re.search(r"^### WINDOW (.*)$", log.read_text(), re.M)
    assert found, f"{log}: no window"
    launch, launch_min, capture, capture_min, load, in_slew, clk_slew, strobe = map(float, found.group(1).split())
    drv = (out / f"drv_{corner}.log").read_text().split("### DRV")[1].split("### END")[0]
    violated = drv.count("VIOLATED")
    margin = period - strobes[corner] - strobe - LATCH_HOLD
    rows.append((corner, launch, launch_min, capture, capture_min, load, in_slew, clk_slew, strobe, violated, margin))
    if violated:
        errors.append(f"{corner}: {violated} slew, capacitance or fan-out violations")
    if margin <= 0:
        errors.append(f"{corner}: the configuration write has {margin:.2f} ns to spare")
assert len(rows) == 9, f"{len(rows)} corners"
head = "corner launch launch_min capture capture_min load_pf in_slew clk_slew strobe drv write_margin".split()
(out / "summary.tsv").write_text("\t".join(head) + "\n" + "".join("\t".join(map(str, r)) + "\n" for r in rows))
print("\n".join(errors), end="\n" if errors else "")
print(f"BLOCK WINDOW {'FAIL' if errors else 'PASS'} corners=9 drv={max(r[9] for r in rows)} "
      f"launch_ns={min(r[2] for r in rows):.2f}..{max(r[1] for r in rows):.2f} "
      f"capture_ns={min(r[4] for r in rows):.2f}..{max(r[3] for r in rows):.2f} "
      f"load_pf={max(r[5] for r in rows):.3f} write_margin_ns={min(r[10] for r in rows):.2f}")
sys.exit(1 if errors else 0)
EOF

[ $# -gt 0 ] || { echo "BLOCK STA PASS designs=0"; exit 0; }
EFPGA_STA_WINDOW="$OUT" flow/librelane/scripts/efpga_sta.sh "$RUN" "$@"
echo "BLOCK STA PASS designs=$# window=measured"
