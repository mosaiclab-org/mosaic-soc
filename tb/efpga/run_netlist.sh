#!/bin/bash
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# tb/efpga/run_netlist.sh — the benches of the fabric and of the wrapper on the
# fabric of `small` hardened for GF180MCU, from nothing (docs/efpga.md,
# Hardening for GF180MCU):
#
#   1. Generate the fabric (efpga_generate in tb/efpga/common.sh).
#   2. Harden every tile type it places, then stitch the fabric macro, with
#      efpga_gen.py in `nix develop .#fabric`: about 70 minutes. Each fails
#      unless DRC, LVS and antenna are 0 and the PDK clone is unchanged.
#   3. Static timing at nine corners (flow/librelane/scripts/efpga_sta.sh): of
#      the macro, and of the bench designs with their configuration applied,
#      after a wrapper that moves on the fabric's own clock edge failed hold on
#      bus_regs: about 25 minutes.
#   4. tb/efpga/run.sh and tb/efpga/run_wrapper.sh with EFPGA_NETLIST: 8 and
#      34 runs in Verilator, and every latch read back after the loader, about
#      3 hours.
#
# Pass criterion: "TB PASS" on stdout, printed once, after the timing and both
# benches on the netlist passed. Usage: tb/efpga/run_netlist.sh   (inside `nix develop
# .#sim`; sweep step efpga_netlist, which runs only when named)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

cd "$REPO"
source "$REPO/tb/tools.sh"
mosaic_need_verilator
source "$REPO/tb/efpga/common.sh"
RUN="$REPO/build/efpga_netlist"

echo "### [1/4] generating the fabric ..."
efpga_generate

echo "### [2/4] hardening the tiles and stitching the fabric ..."
mapfile -t HARDEN < <(python3 -c 'import sys; from pathlib import Path
sys.path.insert(0, "util/mosaic_gen")
from efpga_gen import _fabric_tiles
for tile in sorted(_fabric_tiles(Path(sys.argv[1]))): print("--harden"); print(tile)' "$OUT")
gen=(nix develop "$REPO#fabric" --option warn-dirty false --command python3 util/mosaic_gen/efpga_gen.py --fabric "$OUT")
"${gen[@]}" "${HARDEN[@]}" --out "$RUN/tiles"
"${gen[@]}" --stitch "$RUN/tiles" --out "$RUN/fabric"

echo "### [3/4] static timing of the macro and of the bench designs ..."
same_edge=$(EFPGA_STA_DIV=1 flow/librelane/scripts/efpga_sta.sh "$RUN/fabric" bus_regs) || true
grep -E '^STA DESIGN FAIL design=bus_regs .* hold_ns=-' <<< "$same_edge" \
  || { echo "TB FAIL reason=hold_on_the_fabrics_own_edge_not_seen"; exit 1; }
flow/librelane/scripts/efpga_sta.sh "$RUN/fabric" counter8_en bus_regs task_count

echo "### [4/4] the benches on the netlist ..."
for bench in run run_wrapper; do
  EFPGA_NETLIST="$RUN/fabric" tb/efpga/$bench.sh | tee "$RUN/$bench.log" | grep -E '^(###|WRONG|TB )' || true
  grep -q "^TB PASS .*netlist=fabric " "$RUN/$bench.log" \
    || { echo "TB FAIL reason=${bench}_on_the_netlist, log $RUN/$bench.log"; exit 1; }
done
echo "TB PASS netlist=small tiles=$((${#HARDEN[@]} / 2)) sta=9_corners designs=3 benches=run,run_wrapper"
