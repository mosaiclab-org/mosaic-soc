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
# With no delay at all a flop races the flop it resets: in the flash controller one
# clears, in the edge that should sample it, the input of a third, and the controller
# stops after its first byte (2026-11-03). So the SoC's flip-flops get 1 ns on their
# output gate, as tb/gls/run_gls.sh gives Icarus (Verilator takes no delay on a UDP),
# from a copy of the cell models renamed `_d1` that only its netlist names. The
# fabric's netlists keep the models without delay, as tb/efpga/run_block.sh has them:
# delays on its 6,696 latches as well take Verilator past this machine's memory, and
# the wrapper drives and samples the fabric away from its clock's pulse. The clock
# gates' outputs stay ideal, as every clock does.
CELLS="$REPO/flow/librelane/gf180mcu/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog/gf180mcu_fd_sc_mcu7t5v0.v"
SEQ_OUT='^([[:space:]]*)(not|buf)([[:space:]]+[A-Za-z_][A-Za-z0-9_]*\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*,[[:space:]]*IQ[A-Za-z0-9_]*[[:space:]]*\);)'
RENAME='s/gf180mcu_fd_sc_mcu7t5v0__((udp_)?[A-Za-z0-9_]+)/gf180mcu_fd_sc_mcu7t5v0__\1_d1/g; s/__udp_([A-Za-z0-9_]+)_d1/__udp_\1/g'
# Each cell has its include guard, which the copy must not share with the original.
sed -E "$RENAME; s/(GF180MCU_FD_SC_MCU7T5V0__[A-Z0-9_]+)_V\b/\1_D1_V/g; s/$SEQ_OUT/\1\2 #1\3/" "$CELLS" > "$OBJ/cells_d1.v"
[ "$(grep -cE '^[[:space:]]*(not|buf) #1 ' "$OBJ/cells_d1.v")" -eq 17 ] \
  || { echo "TB FAIL reason=the_clock_to_q_patch_did_not_match_17_cells"; exit 1; }
sed -E "$RENAME" "$NETLIST" > "$OBJ/$TOP.d1.nl.v"
[ -z "$(grep -E '^ *gf180mcu_fd_sc_mcu7t5v0__' "$OBJ/$TOP.d1.nl.v" | grep -v '_d1 ')" ] \
  || { echo "TB FAIL reason=a_cell_of_the_netlist_was_not_renamed"; exit 1; }
# The C++ first and then its compiling, so that Verilator's 2.3 GB and the compilers'
# are not held at once; in small files, for the same reason.
# shellcheck disable=SC2086
verilator --cc --exe --main --timing --timescale 1ns/1ps --top-module tb_efpga_soc \
  --Mdir "$OBJ/model" -o Vtb --output-split 5000 --output-split-cfuncs 2000 $DEFS -DTOP="$TOP" \
  -Wno-fatal -Werror-USERFATAL -Wno-UNOPTFLAT -Wno-TIMESCALEMOD -CFLAGS -Wno-cpp \
  $FABRIC "$OBJ/cells_d1.v" "$OBJ/$TOP.d1.nl.v" "$FLASH" tb/efpga/tb_efpga_soc.sv > "$OBJ/build.log" 2>&1 \
  && make -j "${VJOBS:-2}" -C "$OBJ/model" -f Vtb_efpga_soc.mk OPT_FAST=-O2 >> "$OBJ/build.log" 2>&1 \
  || { tail -n 20 "$OBJ/build.log"; echo "TB FAIL reason=the_model_did_not_build"; exit 1; }
# The RTL exits after 461,000 cycles, most of them the stream written from flash by a
# bit-serial hart; the bench's watchdog is half as many again. The two images run
# side by side: 3 hours 10 minutes on 2026-11-03, and twice that is the limit.
echo "### [4/4] running, about 3 hours: progress every 20,000 cycles in $OBJ/verilator_*.log ..."
RUN_TIMEOUT=21600
run_case verilator shell_regs pass "$OBJ/model/Vtb" "+firmware=$OBJ/shell_regs.hex" +maxcycles=700000 > "$OBJ/case_shell_regs.txt" &
run_case verilator task_count exit_value "$OBJ/model/Vtb" "+firmware=$OBJ/task_count.hex" +maxcycles=700000 > "$OBJ/case_task_count.txt" &
wait
cat "$OBJ/case_shell_regs.txt" "$OBJ/case_task_count.txt"
! grep -q "^WRONG" "$OBJ/case_shell_regs.txt" "$OBJ/case_task_count.txt" \
  || { echo "TB FAIL reason=a_run_ended_otherwise_than_expected"; exit 1; }
echo "TB PASS block=$TOP fabric=small netlist=fabric simulators=verilator images=2 controls=1 $(grep -o 'cycles=[0-9]*' "$OBJ/verilator_shell_regs.log" | tail -n 1)"
