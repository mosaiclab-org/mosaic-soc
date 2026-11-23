#!/bin/bash
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# tb/efpga/run.sh — the eFPGA fabric alone, configured with a real bitstream.
#
#   1. Generate the `small` fabric preset and the bitstream of counter8_en.v
#      with the pinned FABulous flow (efpga_generate in tb/efpga/common.sh).
#   2. Build tb_efpga_fabric.sv around the generated fabric core with Icarus
#      and with the pinned Verilator. Icarus starts every latch and flip-flop
#      at x, Verilator 5.050 at 0: the result must not depend on either.
#   3. In each simulator: two runs that must pass, and six negative controls
#      that must each fail for the reason expected of it, not for another one.
#      Three of them show their fault only in the cycle where the bench holds,
#      resets or mask-resets the counter, so a bench that stops earlier fails.
#
# With EFPGA_NETLIST=<the --out of efpga_gen.py --stitch>, the same bench runs
# on the hardened fabric instead of the RTL: the stitched macro's netlist, the
# tiles' netlists and GF180MCU's cell models (-DFUNCTIONAL), in Verilator only,
# eight runs, with every flip-flop at 1 and every latch at 0 at power-up.
#
# Pass criterion: "TB PASS" on stdout, printed once, after all sixteen (eight)
# runs gave the expected result. Usage: tb/efpga/run.sh   (inside `nix develop
# .#sim`)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

cd "$REPO"
source "$REPO/tb/tools.sh"
mosaic_need_verilator
source "$REPO/tb/efpga/common.sh"
OBJ="$REPO/build/efpga_fabric_obj"
BIT="$OUT/bitstream/counter8_en.bin"

echo "### [1/3] generating the fabric and the counter bitstream ..."
efpga_generate

rm -rf "$OBJ"
mkdir -p "$OBJ"
# The negative controls: the real bitstream with one fault.
# ponytail: the four bits are fixed positions in this bitstream, which the pinned
# tools reproduce bit for bit; after a tool change the asserts or the expected
# reasons fail, and the positions are then chosen again from the FASM.
python3 - "$OUT/manifest.json" "$BIT" "$OBJ" <<'EOF'
import json, sys
geometry = json.load(open(sys.argv[1]))["geometry"]
bits, obj = open(sys.argv[2], "rb").read(), sys.argv[3]

def flipped(byte, mask, was, name):
    assert bool(bits[byte] & mask) == was, f"{name}: the bitstream changed, choose the bit again"
    out = bytearray(bits)
    out[byte] ^= mask
    open(f"{obj}/{name}.bin", "wb").write(out)

# Truth-table bits of three counter LUTs. Each is read only in one part of the
# stimulus: while en is low (first mismatch in cycle 100), at the reset (cycle
# 400), and at the reset that a low en masks (cycle 450).
flipped(1194, 0x08, True, "hold_fault")          # X2Y2.A.INIT[8]
flipped(973, 0x04, False, "reset_fault")         # X2Y2.G.INIT[7]
flipped(772, 0x20, True, "masked_reset_fault")   # X1Y2.F.INIT[10]
flipped(24, 0x80, True, "pad_oe_fault")          # a select bit of a pad's output-enable mux (X0Y4)
frame = 4 * (1 + geometry["rows"])       # a header word and one data word per row
open(f"{obj}/last_frame_missing.bin", "wb").write(bits[:-frame - 4] + bits[-4:])
EOF
efpga_fabric
SRC="$FABRIC tb/efpga/counter8_en.v tb/efpga/tb_efpga_fabric.sv"

echo "### [2/3] building the bench ($DEFS) ..."
if [ "$SIMS" != verilator ]; then
  iverilog -V | sed -n 1p
  iverilog -g2012 -s tb_efpga_fabric $DEFS -I "$OUT" -o "$OBJ/tb.vvp" $SRC
fi
# -O0 for the model's C++: each run lasts under a second, -O1 triples the build.
# -Wno-cpp: glibc's "_FORTIFY_SOURCE requires compiling with optimization".
verilator --binary -j "${VJOBS:-0}" --timing --timescale 1ns/1ps \
  --top-module tb_efpga_fabric --Mdir "$OBJ/verilator" -o Vtb_efpga_fabric $DEFS -I"$OUT" \
  -Wno-fatal -Wno-UNOPTFLAT -Wno-TIMESCALEMOD -MAKEFLAGS OPT_FAST=-O0 -CFLAGS -Wno-cpp $SRC

echo "### [3/3] running ..."
RUNS=0
for sim in $SIMS; do
  case $sim in
    icarus) RUN=(vvp -n "$OBJ/tb.vvp") ;;
    verilator) RUN=("$OBJ/verilator/Vtb_efpga_fabric") ;;
  esac
  run_case $sim clk_gated pass "${RUN[@]}" "+bitstream=$BIT"
  run_case $sim clk_running pass "${RUN[@]}" "+bitstream=$BIT" +clk_during_cfg
  run_case $sim no_bitstream output_mismatch "${RUN[@]}" +no_bitstream
  for fault in hold_fault reset_fault masked_reset_fault; do
    run_case $sim $fault output_mismatch "${RUN[@]}" "+bitstream=$OBJ/$fault.bin"
  done
  run_case $sim pad_oe_fault output_enable_mismatch "${RUN[@]}" "+bitstream=$OBJ/pad_oe_fault.bin"
  run_case $sim last_frame_missing strobe_lines_not_all_pulsed "${RUN[@]}" "+bitstream=$OBJ/last_frame_missing.bin"
  RUNS=$((RUNS + 8))
done
[ $FAILED -eq 0 ] || { echo "TB FAIL reason=a_run_did_not_give_the_expected_result"; exit 1; }
echo "TB PASS fabric=small ${EFPGA_NETLIST:+netlist=$(basename "$EFPGA_NETLIST") }simulators=${SIMS// /,} runs=$RUNS"
