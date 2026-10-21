#!/bin/bash
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# flow/librelane/scripts/efpga_synth.sh — synthesis of the eFPGA wrapper,
# hw/efpga/mosaic_efpga.sv, and of the fabric of a preset for GF180MCU
# (gf180mcu_fd_sc_mcu7t5v0, typical corner, 5 V), with the Yosys and OpenSTA of
# the LibreLane shell. Not a hardening: no placement and no wires, so the area
# is that of the standard cells and the timing is before layout.
#   1. the fabric of the preset, without designs (util/mosaic_gen/efpga_gen.py)
#   2. the wrapper and the fabric, flattened: every cell must map to the
#      library, the configuration latches to latq (gf180_latch_map.v), and
#      Yosys's check must find no problem
#   3. the wrapper alone, the fabric a black box: its area, and its paths at a
#      clock of EFPGA_SYNTH_PERIOD ns (default 50: the 20 MHz of the GF180MCU
#      reference design), which must have no negative slack
#
# Pass: "SYNTH PASS preset=<preset> ...", printed last. Usage:
#   flow/librelane/scripts/efpga_synth.sh [small|medium]
# GF180_PDK_ROOT: the gf180mcu clone; by default flow/librelane/gf180mcu, made by
# `make -C flow/librelane clone-pdk`. Outputs and logs: build/efpga_synth/<preset>.
#
# The fabric's switch matrices are full of structural loops, which only a
# configuration breaks. The check inside synth would print every one of them,
# gigabytes for `small`: the full run turns that warning into a message, which
# -q drops, synth stops before its last check (-run :check), and the check that
# decides runs on the mapped netlist, whose library cells it does not look into.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO"
PRESET="${1:-small}"
PERIOD="${EFPGA_SYNTH_PERIOD:-50}"
PDK="${GF180_PDK_ROOT:-$REPO/flow/librelane/gf180mcu}"
LIB="$PDK/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__tt_025C_5v00.lib"
OUT="$REPO/build/efpga_synth/$PRESET"
fail() { echo "SYNTH FAIL preset=$PRESET: $*"; exit 1; }
[ -f "configs/efpga/$PRESET.csv" ] || fail "no preset configs/efpga/$PRESET.csv"
[ -f "$LIB" ] || fail "no GF180MCU library at $LIB (make -C flow/librelane clone-pdk)"
mkdir -p "$OUT"

echo "### [1/3] the fabric of $PRESET ..."
gen=(python3 util/mosaic_gen/efpga_gen.py --preset "configs/efpga/$PRESET.csv" --out "$OUT/fabric")
if command -v FABulous >/dev/null; then
  "${gen[@]}" > "$OUT/efpga_gen.log" 2>&1
else
  nix develop "$REPO#efpga" --option warn-dirty false --command "${gen[@]}" > "$OUT/efpga_gen.log" 2>&1
fi || fail "fabric generation, see $OUT/efpga_gen.log"
# The geometry as the wrapper's parameters, and a black box of the fabric core:
# its module header, cut from the generated eFPGA.v.
GEOMETRY=$(python3 - "$OUT" <<'EOF'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
g = json.loads((out / "fabric" / "manifest.json").read_text())["geometry"]
text = (out / "fabric" / "proj" / "Fabric" / "eFPGA.v").read_text()
head = text[:text.index(");", text.index("(", text.index("#(") + 2)) + 2]
(out / "eFPGA_stub.v").write_text("(* blackbox *)\n" + head + "\nendmodule\n")
print(f"-G ROWS={g['rows']} -G COLS={g['cols']} -G FBPR={g['frame_bits_per_row']} "
      f"-G MFPC={g['max_frames_per_col']}")
EOF
)
FABRIC=$(tr '\n' ' ' < "$OUT/fabric/fabric.f")
WRAPPER="hw/mosaic_soc/include/reg_pkg.sv hw/mosaic_soc/include/obi_pkg.sv hw/asic/gf180/tc_clk.sv hw/efpga/mosaic_efpga.sv"
SLANG="--top mosaic_efpga -I $OUT/fabric --allow-use-before-declare --relax-enum-conversions --compat vcs $GEOMETRY"
MAP="techmap -map flow/librelane/scripts/gf180_latch_map.v
dfflibmap -liberty $LIB
abc -liberty $LIB
opt_clean"
cat > "$OUT/full.ys" <<EOF
read_liberty -lib $LIB
read_slang $SLANG $WRAPPER $FABRIC
logger -nowarn "found logic loop"
synth -top mosaic_efpga -flatten -run :check
$MAP
tee -q -o $OUT/full_stat.txt stat -liberty $LIB
tee -q -o $OUT/full_check.txt check
EOF
cat > "$OUT/wrapper.ys" <<EOF
read_liberty -lib $LIB
read_slang $SLANG $WRAPPER $OUT/eFPGA_stub.v
synth -top mosaic_efpga -flatten -run :check
$MAP
tee -q -o $OUT/wrapper_stat.txt stat -liberty $LIB
write_verilog -noattr $OUT/wrapper.v
EOF
cat > "$OUT/sta.tcl" <<EOF
read_liberty $LIB
read_verilog $OUT/wrapper_sta.v
link_design mosaic_efpga
create_clock -name clk -period $PERIOD [get_ports clk_i]
set_input_delay 0 -clock clk [delete_from_list [all_inputs] [get_ports clk_i]]
set_output_delay 0 -clock clk [all_outputs]
report_checks -path_delay max -digits 2
report_wns -digits 2
exit
EOF

echo "### [2/3] the wrapper and the fabric, flattened ..."
echo "### [3/3] the wrapper alone, and its timing at $PERIOD ns ..."
nix develop "$REPO#physical" --option warn-dirty false --command bash -c "
  set -e
  yosys -m slang -q -s $OUT/full.ys > $OUT/full.log 2>&1
  yosys -m slang -q -s $OUT/wrapper.ys > $OUT/wrapper.log 2>&1
  # OpenSTA takes no parameters on an instance, and the fabric is a black box.
  python3 -c 'import re, sys; s = open(sys.argv[1]).read(); open(sys.argv[2], \"w\").write(re.sub(r\"eFPGA #\\(.*?\\) eFPGA_inst \\(\", \"eFPGA eFPGA_inst (\", s, flags=re.S))' $OUT/wrapper.v $OUT/wrapper_sta.v
  sta -no_init -exit $OUT/sta.tcl > $OUT/sta.log 2>&1
" > "$OUT/tools.log" 2>&1 || fail "Yosys or OpenSTA, see $OUT/*.log"

# The verdict, from the reports.
python3 - "$OUT" "$PRESET" "$PERIOD" <<'EOF'
import re, sys
from pathlib import Path
out, preset, period = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
full, wrapper = (out / "full_stat.txt").read_text(), (out / "wrapper_stat.txt").read_text()
check, sta = (out / "full_check.txt").read_text(), (out / "sta.log").read_text()
area = lambda stat: float(re.search(r"Chip area for module '\\mosaic_efpga': ([\d.]+)", stat).group(1))
cells = lambda stat, name: sum(int(n) for n, cell in re.findall(r"^\s+(\d+)\s+\S+\s+(\S+)$", stat, re.M)
                               if name in cell)
unmapped = re.findall(r"Area for cell type (\S+) is unknown", full)
latches = cells(full, "latq")
wns = float(re.search(r"wns max (-?[\d.]+)", sta).group(1))
arrival = max(float(t) for t in re.findall(r"^\s+([\d.]+)\s+data arrival time", sta, re.M))
problems = re.search(r"Found and reported (\d+) problems", check)
errors = []
if unmapped:
    errors.append(f"cells outside the library: {sorted(set(unmapped))}")
if not latches:
    errors.append("no configuration latch mapped to latq")
if not problems or problems.group(1) != "0":
    errors.append("Yosys's check found problems")
if wns < 0:
    errors.append(f"negative slack at {period} ns: {wns} ns")
verdict = "FAIL" if errors else "PASS"
print(f"SYNTH {verdict} preset={preset} area_um2={area(full):.0f} latches={latches} "
      f"wrapper_um2={area(wrapper):.0f} period_ns={period} worst_arrival_ns={arrival:.2f} "
      f"wns_ns={wns:.2f}" + ("" if not errors else ": " + "; ".join(errors)))
sys.exit(1 if errors else 0)
EOF
