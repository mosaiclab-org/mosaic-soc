#!/bin/bash
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# tb/efpga/run_block.sh — the hardened block of flow/librelane/scripts/efpga_block.sh
# in simulation: its netlist around the fabric's netlist, no delays (the timing is
# flow/librelane/scripts/efpga_block_sta.sh), in Verilator (efpga_fabric in
# tb/efpga/common.sh says why). tb_efpga_block.sv loads each of the three designs
# through the wrapper's own loader on the netlist, and then:
#
#   - every latch must read back as the timing of that design assumes
#     (util/mosaic_gen/efpga_timing.py), and three designs must read back apart
#   - each design must work, through the ports only
#   - controls: a stream of another design must not pass as bus_regs, and one
#     configuration wire held low between two tiles, data and strobe, must show
#     in the latches
#
# Pass criterion: "TB PASS" on stdout, printed once, after every run gave the
# expected result. Usage, inside `nix develop .#sim`:
#   tb/efpga/run_block.sh <the --out of efpga_gen.py --stitch> <block's final views>
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
EFPGA_NETLIST="$(cd "${1:?usage: run_block.sh <stitched run> <final views>}" && pwd)"
VIEWS="$(cd "${2:?usage: run_block.sh <stitched run> <final views>}" && pwd)"

cd "$REPO"
source "$REPO/tb/tools.sh"
mosaic_need_verilator
source "$REPO/tb/efpga/common.sh"
OBJ="$REPO/build/efpga_block_obj"

echo "### [1/3] generating the fabric and the streams ..."
efpga_generate

rm -rf "$OBJ"
mkdir -p "$OBJ"
efpga_fabric
python3 util/mosaic_gen/efpga_timing.py latches "$EFPGA_NETLIST" "$OBJ/efpga_latches.vh" dut.eFPGA_inst

echo "### [2/3] building the bench ($DEFS) ..."
# -O0 for the model's C++ (tb/efpga/run_wrapper.sh), -Wno-cpp its warning.
# shellcheck disable=SC2086
verilator --binary -j "${VJOBS:-2}" --timing --timescale 1ns/1ps --top-module tb_efpga_block \
  --Mdir "$OBJ/model" -o Vtb $DEFS -I"$OBJ" \
  -Wno-fatal -Werror-USERFATAL -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
  -MAKEFLAGS OPT_FAST=-O0 -CFLAGS -Wno-cpp \
  $FABRIC "$VIEWS/nl/mosaic_efpga.nl.v" hw/mosaic_soc/include/obi_pkg.sv hw/mosaic_soc/include/reg_pkg.sv \
  tb/efpga/counter8_en.v tb/efpga/tb_efpga_block.sv > "$OBJ/build.log" 2>&1 \
  || { tail -n 20 "$OBJ/build.log"; echo "TB FAIL reason=the_model_did_not_build"; exit 1; }
RUN=("$OBJ/model/Vtb")

echo "### [3/3] running ..."
STREAMS=("+regs=$OUT/bitstream/bus_regs.hex" "+silent=$OUT/bitstream/counter8_en.hex" "+task=$OUT/bitstream/task_count.hex")
last=
for pair in silent:counter8_en regs:bus_regs task:task_count; do
  name=${pair%%:*}
  run_case verilator "$name" pass "${RUN[@]}" "+design=$name" "${STREAMS[@]}"
  grep -q "^TB PASS design=$name " "$OBJ/verilator_$name.log" \
    || { echo "WRONG  $name: not the run of that design"; FAILED=1; }
  got=$(sed -n 's/^LATCHES //p' "$OBJ/verilator_$name.log")
  want=$(python3 util/mosaic_gen/efpga_timing.py bits "$EFPGA_NETLIST" "${pair##*:}")
  if [ -n "$got" ] && [ "$got" = "$want" ] && [ "$got" != "$last" ]; then
    echo "ok     latches of ${pair##*:}: ${#got} as its timing assumes"
  else
    echo "WRONG  latches of ${pair##*:}: not what its timing assumes"
    FAILED=1
  fi
  last=$got
done
run_case verilator regs_is_silent reset_value "${RUN[@]}" +design=regs "+regs=$OUT/bitstream/counter8_en.hex" "${STREAMS[@]}"
want=$(python3 util/mosaic_gen/efpga_timing.py bits "$EFPGA_NETLIST" bus_regs)
for fault in data_stuck strobe_stuck; do
  got=$("${RUN[@]}" +design=regs +latches_only "+fault=$fault" "${STREAMS[@]}" | sed -n 's/^LATCHES //p') || true
  if [ -n "$got" ] && [ "$got" != "$want" ]; then
    echo "ok     $fault: the latches show it"
  else
    echo "WRONG  $fault: the latches do not show it"
    FAILED=1
  fi
done
[ "$FAILED" -eq 0 ] || { echo "TB FAIL reason=a_run_did_not_give_the_expected_result"; exit 1; }
echo "TB PASS block=mosaic_efpga fabric=small netlist=$(basename "$EFPGA_NETLIST") simulators=$SIMS designs=3 controls=3 latch_tables=3"
