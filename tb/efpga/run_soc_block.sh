#!/bin/bash
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# tb/efpga/run_soc_block.sh — a SoC hardened with the eFPGA fabric as a macro
# (flow/librelane/scripts/efpga_block.sh with a SoC configuration) in simulation:
# its netlist around the fabric's netlist, no delays (the timing is
# flow/librelane/scripts/efpga_block_sta.sh), in Verilator (efpga_fabric in
# tb/efpga/common.sh says why). tb_efpga_soc.sv boots it from flash through its
# pins, and hart 0 loads a design into the fabric and checks it
# (tb/mosaic_soc/run_generic.sh with EFPGA_DESIGN):
#
#   - tb/efpga/shell_regs.v must pass, and the fabric's pads carry what it drives
#   - the control: the image of tb/efpga/task_count.v must fail on its exit value
#
# Pass criterion: "TB PASS" on stdout, printed once, after both gave the expected
# result. Usage, inside `nix develop .#sim`:
#   tb/efpga/run_soc_block.sh <the --out of efpga_gen.py --stitch> <SoC configuration> <the SoC's final views>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
usage="usage: run_soc_block.sh <stitched run> <SoC configuration> <final views>"
EFPGA_NETLIST="$(cd "${1:?$usage}" && pwd)"
SOC="$(realpath -e "${2:?$usage}")"
VIEWS="$(cd "${3:?$usage}" && pwd)"
cd "$REPO"
source "$REPO/tb/tools.sh"
mosaic_need_verilator
source "$REPO/tb/efpga/common.sh"
OBJ="$REPO/build/efpga_soc_obj"
NETLIST="$(ls "$VIEWS"/nl/*.nl.v)"
TOP="$(basename "$NETLIST" .nl.v)"
# sed reads it all: `head` would end ls with SIGPIPE, which pipefail makes fatal.
FLASH="$(ls -t "$REPO"/build/mosaic/*/runs/fusesoc.*/build/src/x-heep__tb-utils_0/yosys_spiflash.sv | sed -n 1p)"
echo "### [1/4] generating the fabric ..."
efpga_generate
rm -rf "$OBJ"
mkdir -p "$OBJ"
efpga_fabric
echo "### [2/4] the images of $(basename "$SOC") ..."
for design in shell_regs task_count; do
  MOSAIC_CFG="$SOC" EFPGA_DESIGN="tb/efpga/$design.v" GENERIC_FW_ONLY=1 tb/mosaic_soc/run_generic.sh \
      > "$OBJ/image_$design.log" 2>&1 \
    || { tail -n 5 "$OBJ/image_$design.log"; echo "TB FAIL reason=no_image_of_$design"; exit 1; }
  cp "$(sed -n 's/.*flash image: \([^ ]*\) .*/\1/p' "$OBJ/image_$design.log")" "$OBJ/$design.hex"
done
echo "### [3/4] building the bench ($TOP, $DEFS) ..."
# -O0 for the model's C++ (tb/efpga/run_wrapper.sh), -Wno-cpp its warning.
# shellcheck disable=SC2086
verilator --binary -j "${VJOBS:-2}" --timing --timescale 1ns/1ps --top-module tb_efpga_soc \
  --Mdir "$OBJ/model" -o Vtb $DEFS -DTOP="$TOP" \
  -Wno-fatal -Werror-USERFATAL -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
  -MAKEFLAGS OPT_FAST=-O0 -CFLAGS -Wno-cpp \
  $FABRIC "$NETLIST" "$FLASH" tb/efpga/tb_efpga_soc.sv > "$OBJ/build.log" 2>&1 \
  || { tail -n 20 "$OBJ/build.log"; echo "TB FAIL reason=the_model_did_not_build"; exit 1; }
# About 460,000 cycles to the exit, most of them the stream written from flash by a
# bit-serial hart, at about 50 a second (2026-11-02): over two hours each, so the
# two run side by side.
echo "### [4/4] running, about 2.5 hours ..."
RUN_TIMEOUT=14400
run_case verilator shell_regs pass "$OBJ/model/Vtb" "+firmware=$OBJ/shell_regs.hex" > "$OBJ/case_shell_regs.txt" &
run_case verilator task_count exit_value "$OBJ/model/Vtb" "+firmware=$OBJ/task_count.hex" > "$OBJ/case_task_count.txt" &
wait
cat "$OBJ/case_shell_regs.txt" "$OBJ/case_task_count.txt"
! grep -q "^WRONG" "$OBJ/case_shell_regs.txt" "$OBJ/case_task_count.txt" \
  || { echo "TB FAIL reason=a_run_ended_otherwise_than_expected"; exit 1; }
echo "TB PASS block=$TOP fabric=small netlist=fabric simulators=verilator images=2 controls=1 $(grep -o 'cycles=[0-9]*' "$OBJ/verilator_shell_regs.log" | tail -n 1)"
