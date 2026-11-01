#!/bin/bash
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# flow/librelane/scripts/efpga_sta.sh — static timing of a stitched eFPGA
# fabric macro (the --out of `efpga_gen.py --stitch`), which FABulous's tile and
# fabric flows do not analyse. OpenSTA, from `nix develop .#physical`, reads the
# macro's netlist, the netlists of its tiles and each tile's extracted
# parasitics, at the nine corners of GF180MCU (nom, min and max wires; tt
# 25 C 5.0 V, ss 125 C 4.5 V, ff -40 C 5.5 V). The top level has no cells and
# no extraction: the tiles abut. OpenSTA drops a tile's parasitics of a net
# that reaches one of the tile's ports, so each net between tiles gets the
# wire capacitance of its two parts (no tile net reaches two ports) as a
# lumped load on the top-level net.
# ponytail: lumped, no RC along the wire: exact for the capacitance check,
# pessimistic for delay; a flat SPEF stitched from the tiles' would be exact.
#
# Only what holds for every configuration:
#   - max slew, max capacitance and max fanout, against the library's limits
#   - the skew of UserCLK across the fabric (reported, not judged: what it does
#     depends on a design)
#   - the configuration write: the latest FrameStrobe and FrameData at any
#     configuration latch. The loader holds FrameData from the cycle before a
#     strobe rises until the cycle after it falls (hw/efpga/mosaic_efpga.sv),
#     so a write is safe while the latest strobe plus the latch's hold time is
#     under EFPGA_STA_PERIOD ns (default 50, the 20 MHz of the synthesis)
#
# A design's own paths depend on its configuration: the switch matrices' loops
# leave OpenSTA blind to them. Each design named after the run is timed with its
# configuration applied (util/mosaic_gen/efpga_timing.py): setup and hold of the
# flops it uses and of the wrapper's window it routes, at the same nine corners,
# with the wrapper's clock period EFPGA_STA_PERIOD and the fabric's clock pulsing
# one cycle in EFPGA_STA_DIV (default 4, the reset value of hw/efpga/mosaic_efpga.sv).
# The pads are not timed, since what drives them is outside the chip.
#
# Pass: "STA PASS run=<run> ...", then one "STA DESIGN PASS design=<design> ..."
# per design: any violation, a used flop no path reaches, or a loop OpenSTA cut
# on a used path fails it. Usage:
#   flow/librelane/scripts/efpga_sta.sh build/efpga_harden/small_fabric [design ...]
# GF180_PDK_ROOT: as for efpga_synth.sh. Logs: build/efpga_sta/<run>/.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO"
RUN="$(cd "${1:?usage: efpga_sta.sh <the --out of efpga_gen.py --stitch>}" && pwd)"
PERIOD="${EFPGA_STA_PERIOD:-50}"
DIV="${EFPGA_STA_DIV:-4}"
PDK="${GF180_PDK_ROOT:-$REPO/flow/librelane/gf180mcu}"
LIB="$PDK/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__"
OUT="$REPO/build/efpga_sta/$(basename "$RUN")"
fail() { echo "STA FAIL run=$(basename "$RUN"): $*"; exit 1; }
[ -f "${LIB}tt_025C_5v00.lib" ] || fail "no GF180MCU library at ${LIB}*.lib (make -C flow/librelane clone-pdk)"
rm -rf "$OUT"
mkdir -p "$OUT"

# The tiles' netlists and parasitics, from the macros the run stitched.
python3 - "$RUN" "$OUT/tiles.tcl" <<'EOF' || fail "not a clean stitched run: $RUN"
import json, re, sys
from pathlib import Path
run, out = Path(sys.argv[1]), Path(sys.argv[2])
manifest = json.loads((run / "manifest.json").read_text())
assert manifest["fabric_macro"]["clean"]
lines = [f"set nl(eFPGA) {run}/macro/fabric/final_views/nl/eFPGA.nl.v"]
for tile, views in sorted(manifest["tile_macros"].items()):
    lines += [f"set nl({tile}) {views}/nl/{tile}.nl.v", f"set spef({tile}) {views}/spef/$::env(RC)/{tile}.$::env(RC).spef"]
    # The wire capacitance of each net that reaches a port: pcap(<rc>,<tile>,<port>).
    for rc in ("nom", "min", "max"):
        text = (Path(views) / "spef" / rc / f"{tile}.{rc}.spef").read_text()
        names = dict(re.findall(r"^(\*\d+) (\S+)$", text.split("*NAME_MAP")[1].split("*PORTS")[0], re.M))
        for net in text.split("*D_NET ")[1:]:
            ports = re.findall(r"^\*P (\S+)", net.split("*CONN")[1].split("*CAP")[0], re.M)
            assert len(ports) <= 1, f"{tile}: a net reaches {len(ports)} ports"
            lines += [f"set {{pcap({rc},{tile},{names.get(p, p)})}} {net.split()[1]}" for p in ports]
out.write_text("\n".join(lines) + "\n")
EOF

cat > "$OUT/load.tcl" <<EOF
read_liberty ${LIB}\$::env(LIBC).lib
source $OUT/tiles.tcl
foreach tile [array names nl] { read_verilog \$nl(\$tile) }
link_design eFPGA
foreach inst [get_cells *] { read_spef -path [get_name \$inst] \$spef([get_property \$inst ref_name]) }
foreach net [get_nets *] {
  set c 0.0
  foreach pin [get_pins -quiet -of_objects \$net] {
    set k "\$::env(RC),[get_property [get_cells -of_objects \$pin] ref_name],[regsub {^.*/} [get_full_name \$pin] {}]"
    if {[info exists pcap(\$k)]} { set c [expr {\$c + \$pcap(\$k)}] }
  }
  if {\$c > 0} { set_load \$c \$net }
}
EOF

cat > "$OUT/sta.tcl" <<EOF
source $OUT/load.tcl
create_clock -name UserCLK -period 20 [get_ports UserCLK]
set_propagated_clock [get_clocks UserCLK]
puts "### DRV"
report_check_types -max_slew -max_capacitance -max_fanout -violators -digits 3
puts "### SKEW"
report_clock_skew -setup -digits 3
# The configuration write: a path delay from the ports to every latch, whose
# slack gives the latest arrival.
set d {}; set e {}
foreach c [get_cells -hierarchical -filter "ref_name == gf180mcu_fd_sc_mcu7t5v0__latq_1"] {
  lappend d [get_pins [get_full_name \$c]/D]; lappend e [get_pins [get_full_name \$c]/E]
}
create_clock -name cfg -period $PERIOD
set_input_delay 0 -clock cfg [get_ports {FrameData* FrameStrobe*}]
set_max_delay $PERIOD -from [get_ports FrameData*] -to \$d
set_max_delay $PERIOD -from [get_ports FrameStrobe*] -to \$e
foreach {name to} [list FrameData \$d FrameStrobe \$e] {
  set p [find_timing_paths -from [get_ports \$name*] -to \$to -path_delay max]
  puts "### \$name [format %.3f [expr {$PERIOD - [get_property \$p slack]}]] at [get_full_name [get_property \$p endpoint]]"
}
puts "### LATCHES [llength \$d]"
EOF

echo "### the nine corners ..."
nix develop "$REPO#physical" --option warn-dirty false --command bash -c "
  set -e
  for lib in tt_025C_5v00 ss_125C_4v50 ff_n40C_5v50; do for rc in nom min max; do
    LIBC=\$lib RC=\$rc sta -no_init -exit $OUT/sta.tcl > $OUT/\${rc}_\$lib.log 2>&1
  done; done
" > "$OUT/tools.log" 2>&1 || fail "OpenSTA, see $OUT/*.log"

# The verdict, from the nine logs.
python3 - "$OUT" "$(basename "$RUN")" "$PERIOD" "$LIB" <<'EOF'
import re, sys
from pathlib import Path
out, run, period, lib = Path(sys.argv[1]), sys.argv[2], float(sys.argv[3]), sys.argv[4]

def latch_hold(corner):
    """The largest hold time of latq_1's D after E falls, in the corner's library."""
    text = Path(lib + corner.split("_", 1)[1] + ".lib").read_text()
    cell = text.split("cell(gf180mcu_fd_sc_mcu7t5v0__latq_1)")[1].split("\n  cell(")[0]
    tables = [t for t in cell.split("timing()")[1:] if "timing_type : hold_falling" in t]
    return max(float(v) for t in tables for v in re.findall(r"-?\d+\.\d+", " ".join(re.findall(r'values\(([^)]*)\)', t))))

rows, errors = [], []
for log in sorted(out.glob("*_*.log")):
    text, corner = log.read_text(), log.stem
    # A kind with no violator prints no header.
    count, kind = {"slew": 0, "cap": 0, "fanout": 0}, None
    for line in text.split("### DRV")[1].split("### SKEW")[0].splitlines():
        kind = {"max slew": "slew", "max capacitance": "cap", "max fanout": "fanout"}.get(line.strip(), kind)
        if kind and "VIOLATED" in line:
            count[kind] += 1
    skew = -float(re.search(r"^\s*(-?[\d.]+) setup skew", text, re.M).group(1))
    data, strobe = (float(re.search(rf"^### {n} ([\d.]+) at", text, re.M).group(1)) for n in ("FrameData", "FrameStrobe"))
    latches, hold = re.search(r"^### LATCHES (\d+)", text, re.M).group(1), latch_hold(corner)
    rows.append((corner, count["slew"], count["cap"], count["fanout"], skew, data, strobe))
    if any(count.values()):
        errors.append(f"{corner}: {count['slew']} slew, {count['cap']} capacitance, {count['fanout']} fanout violations")
    if strobe + hold >= period:
        errors.append(f"{corner}: FrameStrobe {strobe} ns + hold {hold} ns is not under {period} ns")
(out / "summary.tsv").write_text("corner\tslew\tcap\tfanout\tuserclk_skew_ns\tframedata_ns\tframestrobe_ns\n"
                                 + "".join("\t".join(map(str, r)) + "\n" for r in rows))
assert len(rows) == 9, f"{len(rows)} corner logs"
worst = lambda i: max(r[i] for r in rows)
print("\n".join(errors))
print(f"STA {'FAIL' if errors else 'PASS'} run={run} corners=9 latches={latches} slew={worst(1)} cap={worst(2)} "
      f"fanout={worst(3)} userclk_skew_ns={worst(4):.2f} framestrobe_ns={worst(6):.2f} period_ns={period:g}")
sys.exit(1 if errors else 0)
EOF

[ $# -gt 1 ] || exit 0
shift
# The wrapper is not laid out yet, so its side of the window is an estimate from
# the fabric's own dffq_1 and an and2, with its flops on the clock at UserCLK:
# launch at most these ns after the edge, and capture this long before it. A
# launch at the edge bounds hold from below, which also covers the clock gate.
# With a divided clock the wrapper's edge is one period after the fabric's pulse.
cat > "$OUT/design.tcl" <<EOF
source $OUT/load.tcl
source \$::env(DESIGN_TCL)
create_clock -name UserCLK -period [expr {$DIV * $PERIOD}] [get_ports UserCLK]
set_propagated_clock [get_clocks UserCLK]
set offset [expr {$DIV > 1 ? $PERIOD : 0}]
set launch [dict get {tt_025C_5v00 1.2 ss_125C_4v50 2.0 ff_n40C_5v50 0.8} \$::env(LIBC)]
set capture [dict get {tt_025C_5v00 0.5 ss_125C_4v50 1.0 ff_n40C_5v50 0.3} \$::env(LIBC)]
set flops [all_registers -edge_triggered -clock_pins]
set dat {}
foreach f \$used { lappend dat [get_pins \$f/D] }
set in {}
foreach p \$bound_in { lappend in [get_ports \$p] }
set out {}
foreach p \$bound_out { lappend out [get_ports \$p] }
proc group {name args} {
  foreach d {max min} {
    puts "### \$name \$d"
    report_checks -path_delay \$d -format end -group_path_count 5000 -unique_paths_to_endpoint -digits 3 {*}\$args
  }
}
group reg2reg -from \$flops -to \$dat
if {[llength \$in]} {
  set_input_delay -clock UserCLK -max [expr {\$offset + \$launch}] \$in
  set_input_delay -clock UserCLK -min \$offset \$in
  group in2reg -from \$in -to \$dat
}
if {[llength \$out]} {
  set_output_delay -clock UserCLK -max \$capture \$out
  set_output_delay -clock UserCLK -min 0 \$out
  group reg2out -from \$flops -to \$out
}
if {[llength \$in] && [llength \$out]} { group in2out -from \$in -to \$out }
puts "### CONE"
foreach p [get_fanin -to [concat \$dat \$out] -flat -trace_arcs enabled] { puts [get_full_name \$p] }
puts "### LOOPS"
check_setup -verbose -loops
EOF

for design in "$@"; do
  mkdir -p "$OUT/$design"
  python3 util/mosaic_gen/efpga_timing.py tcl "$RUN" "$design" "${LIB}tt_025C_5v00.lib" "$OUT/$design/design.tcl" \
    > "$OUT/$design/summary.txt" || fail "$design: efpga_timing.py"
done
echo "### the designs ..."
nix develop "$REPO#physical" --option warn-dirty false --command bash -c "
  set -e
  for design in $*; do for lib in tt_025C_5v00 ss_125C_4v50 ff_n40C_5v50; do for rc in nom min max; do
    DESIGN_TCL=$OUT/\$design/design.tcl LIBC=\$lib RC=\$rc sta -no_init -exit $OUT/design.tcl \
      > $OUT/\$design/\${rc}_\$lib.log 2>&1
  done; done; done
" > "$OUT/tools_designs.log" 2>&1 || fail "OpenSTA on a design, see $OUT/*/*.log"
python3 util/mosaic_gen/efpga_timing.py verdict "$OUT" "$PERIOD" "$DIV" "$@"
