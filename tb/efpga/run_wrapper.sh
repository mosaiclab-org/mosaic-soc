#!/bin/bash
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# tb/efpga/run_wrapper.sh — hw/efpga/mosaic_efpga.sv alone: the loader, the
# unload, the isolation, the user window and the worker slot, with real
# bitstreams.
#
#   1. Generate the `small` fabric preset and the streams that load and unload
#      the three user designs (efpga_generate in tb/efpga/common.sh), and derive
#      the streams the loader must refuse.
#   2. Build tb_mosaic_efpga.sv around the wrapper and the fabric with Icarus
#      and with the pinned Verilator. Icarus starts every latch and flip-flop
#      at x, Verilator 5.050 at 0: the result must not depend on either.
#   3. In each simulator: one run per user design that must pass, and
#      negative controls that must each fail for the reason expected of it. A
#      control is a stream in the wrong role, or a fault forced into the
#      design under test. The designs run again with the fabric's clock at one
#      cycle in four, where the window must keep off that clock's edge.
#
# With EFPGA_NETLIST=<the --out of efpga_gen.py --stitch>, the same runs on
# the hardened fabric instead of the RTL, in Verilator only (efpga_fabric in
# tb/efpga/common.sh). Then the loader loads each design once more and every
# latch is read back, against what the timing of that design assumes it holds
# (util/mosaic_gen/efpga_timing.py).
#
# Pass criterion: "TB PASS" on stdout, printed once, after every run gave the
# expected result. Usage: tb/efpga/run_wrapper.sh   (inside `nix develop .#sim`)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

cd "$REPO"
source "$REPO/tb/tools.sh"
mosaic_need_verilator
source "$REPO/tb/efpga/common.sh"
OBJ="$REPO/build/efpga_wrapper_obj"
REGS="$OUT/bitstream/bus_regs.hex"
SILENT="$OUT/bitstream/counter8_en.hex"
REGS_UNLOAD="$OUT/bitstream/bus_regs.unload.hex"
SILENT_UNLOAD="$OUT/bitstream/counter8_en.unload.hex"

echo "### [1/3] generating the fabric and the streams ..."
efpga_generate

rm -rf "$OBJ"
mkdir -p "$OBJ"
python3 - "$OUT/manifest.json" "$REGS" "$OBJ" "$REGS_UNLOAD" "$OUT/load_order/tagged.bin" <<'EOF'
import json, sys
sys.path.insert(0, "util/mosaic_gen")
from efpga_gen import SYNC, _frames, seal
geometry = json.load(open(sys.argv[1]))["geometry"]
size, obj = 1 + geometry["rows"], sys.argv[3]  # the words of a frame, its check word left out

def read(path):
    return [int(line, 16) for line in open(path)]

def write(name, words):
    open(f"{obj}/{name}.hex", "w").write("".join(f"{word:08x}\n" for word in words))

def damaged(words, head, frame):
    """The stream up to the check word of `frame`, one bit of that frame flipped."""
    at = head + frame * (size + 1)
    words = words[:at + size + 1]
    words[at + 1] ^= 1
    return words

good = read(sys.argv[2])
body = good[1:-2]
frames, end = [body[i:i + size] for i in range(0, len(body), size + 1)], good[-2]
if seal([SYNC], frames, end) != good:
    sys.exit("bus_regs.hex is not one sync word, frames with their checks, the end word and the CRC")
# Frames the design leaves empty, each the only one of its strobe line.
empty = [i for i, frame in enumerate(frames) if not any(frame[1:])
         and [f[0] for f in frames].count(frame[0]) == 1]
write("crc_fault", damaged(good, 1, empty[0]))
# The last strobe line of the last column, so that every line must be counted.
last = geometry["cols"] - 1 << 27 | 1 << geometry["max_frames_per_col"] - 1
if frames[empty[-1]][0] != last or frames[empty[0]][0] != 1:
    sys.exit("bus_regs uses the frame of the first or the last strobe line: pick others")
write("coverage_fault", seal([SYNC], frames[:empty[-1]] + frames[empty[-1] + 1:], end))
write("coverage_first", seal([SYNC], frames[:empty[0]] + frames[empty[0] + 1:], end))  # column 0, line 0
write("empty", seal([SYNC], [], end))                                                 # no frame at all
other = [list(frame) for frame in frames]                    # the first column that is not there
other[0][0] = other[0][0] & (1 << 27) - 1 | geometry["cols"] << 27
write("column_fault", seal([SYNC], other, end))
unload = read(sys.argv[4])
write("unload_fault", damaged(unload, 2, 40))                # 40 frames of the unload go in first
body = unload[2:-2]
write("unload_cov", seal(unload[:2], [body[i:i + size] for i in range(0, len(body), size + 1)][:-1],
                         unload[-2]))                         # without its last frame
# The last pass holds the tag (east column) and its check (west column).
tags = {f[0]: f[1:] for f in _frames(open(sys.argv[5], "rb").read(), geometry["rows"])[0] if any(f[1:])}
first = len(frames) - len(tags)
if [f[0] for f in frames[first:]] != list(tags):
    sys.exit("bus_regs.hex does not end with the frames of its tag")
write("regs_head", good[:1 + first * (size + 1)])
# no_tag: the tag 0 with its own check (every check latch 1), refused only for
# being 0; bad_check: the tag of bus_regs with no check.
EAST = {"no_tag": lambda d, t: d & ~t, "bad_check": lambda d, t: d}
WEST = {"no_tag": lambda d, t: d | t, "bad_check": lambda d, t: d & ~t}
for name in ("no_tag", "bad_check"):
    cut = [list(f) for f in frames]
    for f in cut[first:]:
        side = EAST if f[0] >> 27 == geometry["cols"] - 1 else WEST
        f[1:] = [side[name](d, t) for d, t in zip(f[1:], tags[f[0]])]
    write(name, seal([SYNC], cut, end))
write("stray", [0])
EOF
efpga_fabric
if [ -n "${EFPGA_NETLIST:-}" ]; then
  python3 util/mosaic_gen/efpga_timing.py latches "$EFPGA_NETLIST" "$OBJ/efpga_latches.vh" dut.eFPGA_inst
  DEFS="$DEFS -DEFPGA_LATCHES -I$OBJ"
fi
SRC="$FABRIC hw/mosaic_soc/include/obi_pkg.sv hw/mosaic_soc/include/reg_pkg.sv
  hw/vendor/pulp_platform/tech_cells_generic/src/rtl/tc_clk.sv hw/efpga/mosaic_efpga.sv
  tb/efpga/counter8_en.v tb/efpga/tb_mosaic_efpga.sv"

echo "### [2/3] building the bench ($DEFS) ..."
# Twice: with the fabric's clock on every cycle, where each latency the bench
# checks is exact, and at the module's reset value, one cycle in four.
build_bench() {
  if [ "$SIMS" != verilator ]; then
    [ "$1" != 4 ] || iverilog -V | sed -n 1p
    # shellcheck disable=SC2086
    iverilog -g2012 -s tb_mosaic_efpga $DEFS -DFABRIC_DIV=$1 -I "$OUT" -o "$OBJ/tb$1.vvp" $SRC
  fi
  # -O0 for the model's C++: each run lasts seconds, -O1 triples the build.
  # -Wno-cpp: glibc's "_FORTIFY_SOURCE requires compiling with optimization".
  # shellcheck disable=SC2086
  verilator --binary -j "${VJOBS:-0}" --timing --timescale 1ns/1ps --top-module tb_mosaic_efpga \
    --Mdir "$OBJ/verilator$1" -o Vtb_mosaic_efpga $DEFS -DFABRIC_DIV=$1 -I"$OUT" \
    -Wno-fatal -Werror-USERFATAL -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
    -MAKEFLAGS OPT_FAST=-O0 -CFLAGS -Wno-cpp $SRC
}
build_bench 1
build_bench 4

echo "### [3/3] running ..."
# The first plusarg that matches is the one a bench reads, so a control puts
# its own stream or fault in front of these.
STREAMS=("+silent=$SILENT" "+regs=$REGS" "+silent_unload=$SILENT_UNLOAD"
         "+regs_unload=$REGS_UNLOAD" "+crc_fault=$OBJ/crc_fault.hex"
         "+coverage_fault=$OBJ/coverage_fault.hex" "+column_fault=$OBJ/column_fault.hex"
         "+coverage_first=$OBJ/coverage_first.hex" "+empty=$OBJ/empty.hex"
         "+unload_fault=$OBJ/unload_fault.hex" "+unload_cov=$OBJ/unload_cov.hex"
         "+no_tag=$OBJ/no_tag.hex" "+bad_check=$OBJ/bad_check.hex" "+regs_head=$OBJ/regs_head.hex"
         "+stray=$OBJ/stray.hex" "+task=$OUT/bitstream/task_count.hex"
         "+task_unload=$OUT/bitstream/task_count.unload.hex")
RUNS=0
for sim in $SIMS; do
  case $sim in
    icarus) RUN=(vvp -n "$OBJ/tb1.vvp") RUN4=(vvp -n "$OBJ/tb4.vvp") ;;
    verilator) RUN=("$OBJ/verilator1/Vtb_mosaic_efpga") RUN4=("$OBJ/verilator4/Vtb_mosaic_efpga") ;;
  esac
  while read -r name want arg; do
    run_case $sim "$name" "$want" "${RUN[@]}" $arg "${STREAMS[@]}"
    RUNS=$((RUNS + 1))
    # A passing run must be the run of the design its row names.
    [ "$want" != pass ] || grep -q "^TB PASS design=$name " "$OBJ/${sim}_$name.log" \
      || { echo "WRONG  ${sim}_$name: not the run of that design"; FAILED=1; }
  done <<EOF
silent                  pass                     +silent_run
silent_is_regs          silent_design_answered   +silent_run +silent=$REGS
pad_stuck               pad_mismatch             +silent_run +fault=pad_stuck
regs                    pass
regs_is_silent          unexpected_timeout       +regs=$SILENT +regs_unload=$SILENT_UNLOAD
crc_fault_is_good       crc_fault_accepted       +crc_fault=$REGS
coverage_fault_is_good  coverage_fault_accepted  +coverage_fault=$REGS
column_fault_is_good    column_fault_accepted    +column_fault=$REGS
not_truncated           truncated_accepted       +no_truncate
fab_en_stuck            not_blocked              +fault=fab_en_stuck
clock_leak              not_isolated_after_reset +fault=clock_leak
wdata_pin               readback                 +fault=wdata_pin
addr_pin                address_decode           +fault=addr_pin
no_user_reset           user_reset               +fault=no_user_reset
no_clear_pulse          clear_without_clock_pulse +fault=no_clear_pulse
connect_while_loading   connected_while_loading  +fault=connect_while_loading
connect_after_pause     strobe_while_connected   +fault=connect_after_pause
be_pin                  east_edge_pins           +fault=be_pin
frame_check_ignored     check_bit_not_compared   +fault=frame_check_ignored
tag_ignored             load_over_a_design       +fault=tag_ignored
no_flush                unload_without_flush     +fault=no_flush
reset_forgets           warm_reset_cleared       +fault=reset_forgets
check_forgets           warm_reset_cleared       +fault=check_forgets
check_b_forgets         warm_reset_cleared       +fault=check_b_forgets
no_tag_is_good          untagged_design_accepted +no_tag=$REGS
task                    pass                     +task_run
no_park                 park_ignored             +task_run +fault=no_park
cut_ignored             task_without_a_design    +task_run +fault=cut_ignored
task_result_pin         task_result              +task_run +fault=task_result_pin
sleep_stuck             slot_asleep_with_a_task  +task_run +fault=sleep_stuck
EOF
  while read -r name want arg; do
    run_case $sim "div4_$name" "$want" "${RUN4[@]}" $arg "${STREAMS[@]}"
    RUNS=$((RUNS + 1))
  done <<EOF
regs                    pass                          
silent                  pass                          +silent_run
task                    pass                          +task_run
east_on_the_pulse       east_edge_moved_on_the_pulse  +fault=east_on_the_pulse
EOF
done
TABLES=
if [ -n "${EFPGA_NETLIST:-}" ]; then
  last=
  for pair in silent:counter8_en regs:bus_regs task:task_count; do
    got=$("${RUN[@]}" "+latches=${pair%%:*}" "${STREAMS[@]}" | sed -n 's/^LATCHES //p') || true
    want=$(python3 util/mosaic_gen/efpga_timing.py bits "$EFPGA_NETLIST" "${pair##*:}")
    # Two designs that read back alike would mean the bench saw neither.
    if [ -n "$got" ] && [ "$got" = "$want" ] && [ "$got" != "$last" ]; then
      echo "ok     latches of ${pair##*:}: ${#got} as its timing assumes"
    else
      echo "WRONG  latches of ${pair##*:}: not what its timing assumes"
      FAILED=1
    fi
    last=$got
  done
  TABLES=" latch_tables=3"
fi
[ $FAILED -eq 0 ] && [ $RUNS -eq $((34 * $(wc -w <<< "$SIMS"))) ] \
  || { echo "TB FAIL reason=a_run_did_not_give_the_expected_result"; exit 1; }
echo "TB PASS wrapper=mosaic_efpga fabric=small ${EFPGA_NETLIST:+netlist=$(basename "$EFPGA_NETLIST") }simulators=${SIMS// /,} runs=$RUNS$TABLES"
