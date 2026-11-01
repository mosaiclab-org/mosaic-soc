#!/bin/bash
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# tb/efpga/run_powerup.sh — hw/efpga/mosaic_efpga.sv out of power-up, with a
# stand-in for the fabric whose outputs toggle at random (tb_efpga_powerup.sv).
#
#   1. Generate the `small` fabric preset (efpga_generate in tb/efpga/common.sh)
#      and, from its port list, the stand-in: every output noise, the
#      configuration outputs random until a clear.
#   2. Build the bench with Icarus and with the pinned Verilator.
#   3. In each simulator: four seeds that must pass, one fabric that names a
#      design by chance, and two controls that must each fail for the reason
#      expected of them.
#
# Pass criterion: "TB PASS" on stdout, printed once, after every run gave the
# expected result. Usage: tb/efpga/run_powerup.sh   (inside `nix develop .#sim`)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

cd "$REPO"
source "$REPO/tb/tools.sh"
mosaic_need_verilator
source "$REPO/tb/efpga/common.sh"
OBJ="$REPO/build/efpga_powerup_obj"

echo "### [1/3] generating the fabric and its stand-in ..."
efpga_generate
rm -rf "$OBJ"
mkdir -p "$OBJ"
python3 - "$OUT/proj/Fabric/eFPGA.v" "$OBJ/fabric_noise.sv" <<'EOF'
import re, sys
from pathlib import Path
head = Path(sys.argv[1]).read_text().split(");", 1)[0]
ports = re.findall(r"^\s*(input|output)\s+(?:\[[^\]]*\]\s*)?(\w+)\s*,?", head, re.M)
widths = {name: width for width, name in re.findall(r"^\s*input\s+(\[[^\]]*\])\s*(\w+)", head, re.M)}
out = [name for kind, name in ports if kind == "output"]
assert len(out) > 100 and "FrameData" in widths and "FrameStrobe" in widths and "UserCLK" in dict((n, k) for k, n in ports)
held = [i for i, name in enumerate(out) if "config_C_bit" in name or "Config_accessC_bit" in name]
assert len(held) == 48, f"{len(held)} configuration outputs"
lines = ["`timescale 1ns / 1ps", "module eFPGA #(parameter MaxFramesPerCol = 20, parameter FrameBitsPerRow = 32) ("]
lines += [",\n".join(f"  {kind} {widths.get(name, '')} {name}" for kind, name in ports), ");"]
lines += [
    f"  localparam int N = {len(out)};",
    "  int seed = 1;",
    "  longint unsigned lcg;",
    "  logic [N-1:0] noise, cfg;",
    "  initial begin",
    '    void\'($value$plusargs("seed=%d", seed));',
    "    lcg = 64'(seed) * 64'd6364136223846793005 + 64'd1442695040888963407;",
    "    for (int i = 0; i < N; i++) begin",
    "      lcg = lcg * 64'd6364136223846793005 + 64'd1442695040888963407;",
    "      cfg[i] = lcg[62];",
    "      noise[i] = lcg[61];",
    "    end",
    "  end",
    "  always #1 begin",  # faster than the clock, and unrelated to it
    "    for (int i = 0; i < N; i += 32) begin",
    "      lcg = lcg * 64'd6364136223846793005 + 64'd1442695040888963407;",
    "      for (int j = 0; j < 32 && i + j < N; j++) noise[i+j] <= noise[i+j] ^ lcg[32+j];",
    "    end",
    "  end",
    "  always @* if (&FrameStrobe && FrameData == '0) cfg = '0;",
]
lines += [f"  assign {name} = {'cfg' if i in held else 'noise'}[{i}];" for i, name in enumerate(out)]
lines += ["endmodule"]
Path(sys.argv[2]).write_text("\n".join(lines) + "\n")
EOF
SRC="$OBJ/fabric_noise.sv hw/mosaic_soc/include/obi_pkg.sv hw/mosaic_soc/include/reg_pkg.sv
  hw/vendor/pulp_platform/tech_cells_generic/src/rtl/tc_clk.sv hw/efpga/mosaic_efpga.sv
  tb/efpga/tb_efpga_powerup.sv"

echo "### [2/3] building the bench ($DEFS) ..."
iverilog -V | sed -n 1p
# shellcheck disable=SC2086
iverilog -g2012 -s tb_efpga_powerup $DEFS -I "$OUT" -o "$OBJ/tb.vvp" $SRC
# shellcheck disable=SC2086
verilator --binary -j "${VJOBS:-0}" --timing --timescale 1ns/1ps --top-module tb_efpga_powerup \
  --Mdir "$OBJ/verilator" -o Vtb_efpga_powerup $DEFS -I"$OUT" \
  -Wno-fatal -Werror-USERFATAL -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
  -MAKEFLAGS OPT_FAST=-O0 -CFLAGS -Wno-cpp $SRC

echo "### [3/3] running ..."
RUNS=0
for sim in icarus verilator; do
  case $sim in
    icarus) RUN=(vvp -n "$OBJ/tb.vvp") ;;
    verilator) RUN=("$OBJ/verilator/Vtb_efpga_powerup") ;;
  esac
  while read -r name want arg; do
    # shellcheck disable=SC2086
    run_case $sim "$name" "$want" "${RUN[@]}" $arg
    RUNS=$((RUNS + 1))
  done <<EOF
seed1         pass                       +seed=1
seed2         pass                       +seed=2
seed3         pass                       +seed=3
seed4         pass                       +seed=4
tag_match     pass                       +seed=5 +tag_match
fab_en_stuck  pads_driven_while_cut_off  +seed=1 +fault=fab_en_stuck
no_clear      no_clear_after_power_up    +seed=1 +fault=no_clear
EOF
done
[ $FAILED -eq 0 ] && [ $RUNS -eq 14 ] || { echo "TB FAIL reason=a_run_did_not_give_the_expected_result"; exit 1; }
echo "TB PASS powerup=mosaic_efpga fabric=noise simulators=icarus,verilator runs=$RUNS"
