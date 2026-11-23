# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# tb/efpga/common.sh — sourced by the runners that need the eFPGA fabric, with
# REPO set and the working directory at the repository root.

OUT="$REPO/build/efpga/small"

# Generate the `small` fabric preset and the streams of the three user designs
# with the pinned FABulous flow (util/mosaic_gen/efpga_gen.py, which needs
# `nix develop .#efpga`; entered here when its tools are not on PATH). Sets
# DEFS, the geometry as the -D options of the benches.
efpga_generate() {
  local gen=(python3 util/mosaic_gen/efpga_gen.py --preset configs/efpga/small.csv --out "$OUT"
             --design tb/efpga/counter8_en.v --wrapper tb/efpga/counter8_en_wrapper.v
             --design tb/efpga/bus_regs.v --wrapper tb/efpga/bus_regs_wrapper.v
             --shell tb/efpga/task_count.v)
  if command -v FABulous >/dev/null; then
    "${gen[@]}"
  else
    nix develop "$REPO#efpga" --option warn-dirty false --command "${gen[@]}"
  fi
  DEFS=$(python3 -c 'import json, sys
print("-DROWS=%(rows)d -DCOLS=%(cols)d -DFBPR=%(frame_bits_per_row)d "
      "-DMFPC=%(max_frames_per_col)d" % json.load(open(sys.argv[1]))["geometry"])' "$OUT/manifest.json")
}

# The fabric a bench compiles: FABRIC, the generated RTL, or with
# EFPGA_NETLIST=<the --out of efpga_gen.py --stitch> the hardened fabric: the
# stitched macro's netlist, the tiles' netlists and GF180MCU's cell models
# (-DFUNCTIONAL), in Verilator only (SIMS). Call after efpga_generate, with
# $OBJ made.
efpga_fabric() {
  FABRIC="-f $OUT/fabric.f"
  SIMS="icarus verilator"
  [ -n "${EFPGA_NETLIST:-}" ] || return 0
  # The netlists of the macro and of its tiles, for the fabric the streams
  # were just generated for: the generator is deterministic, so its manifest is
  # the one the tiles were hardened from, or the netlist is of another fabric.
  local netlists cells="$REPO/flow/librelane/gf180mcu/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog" seq
  netlists=$(python3 - "$EFPGA_NETLIST" "$OUT/manifest.json" <<'EOF'
import hashlib, json, sys
from pathlib import Path
run, fabric = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
manifest = json.loads((run / "manifest.json").read_text())
if manifest["fabric"]["manifest_sha256"] != hashlib.sha256(fabric.read_bytes()).hexdigest():
    sys.exit(f"{run}: stitched from another fabric than {fabric}")
if not manifest["fabric_macro"]["clean"]:
    sys.exit(f"{run}: the fabric macro is not clean")
files = [run / "macro/fabric/final_views/nl/eFPGA.nl.v"]
files += [Path(path) / "nl" / f"{tile}.nl.v" for tile, path in sorted(manifest["tile_macros"].items())]
print(" ".join(str(f) for f in files))
EOF
  )
  # Power-up: every latch at 0, the cleared configuration the wrapper's loader
  # starts each load from (random latches close loops of the routing that
  # oscillate, and the model never settles), every flip-flop at 1, which a
  # design's reset or the loader's clear must undo. dffq_1 and latq_1, the
  # only sequential cells of the fabric, hold D inverted in their UDP, so the
  # UDP's initial value is the opposite.
  # shellcheck disable=SC2086
  seq=$(grep -ohE 'gf180mcu_fd_sc_mcu7t5v0__(dff|lat|sdff|icg)[a-z0-9]*_[0-9]+' $netlists | sort -u | tr '\n' ' ')
  [ "$seq" = "gf180mcu_fd_sc_mcu7t5v0__dffq_1 gf180mcu_fd_sc_mcu7t5v0__latq_1 " ] \
    || { echo "TB FAIL reason=sequential_cells_other_than_dffq_1_latq_1: $seq"; exit 1; }
  awk '/^primitive gf180mcu_fd_sc_mcu7t5v0__udp_n_iq_ff\(/{v=0} /^primitive gf180mcu_fd_sc_mcu7t5v0__udp_n_iq_latch\(/{v=1}
       /^table/ && v != "" {print "initial Q = 1'"'"'b" v ";"; v=""} {print}' \
    "$cells/primitives.v" > "$OBJ/primitives_powerup.v"
  [ "$(grep -c '^initial Q' "$OBJ/primitives_powerup.v")" -eq 2 ] \
    || { echo "TB FAIL reason=power_up_not_applied_to_the_cell_models"; exit 1; }
  FABRIC="$netlists $OBJ/primitives_powerup.v $cells/gf180mcu_fd_sc_mcu7t5v0.v"
  DEFS="$DEFS -DFUNCTIONAL"
  # Verilator only. In Icarus the loops of the routing that the cleared
  # configuration closes hold x, and a LUT's gates pass on an x input that its
  # RTL masks: 9,700 of the 23,806 nets of small were x at the clear
  # (2026-10-29), each held by a loop. Two-valued Verilator has none.
  SIMS="verilator"
  VJOBS=2  # the netlist's C++ takes 1.5 GB to build with two jobs
  RUN_TIMEOUT=1800
}

# One simulation, which must end as expected: `pass`, or the reason of the
# TB FAIL a negative control is there to provoke. Logs go to $OBJ.
FAILED=0
run_case() {  # <simulator> <case> <pass | reason of the expected TB FAIL> <command...>
  local name="$1_$2" want="$3" rc=0 got
  shift 3
  # A wrong configuration can oscillate in zero simulated time, which a bench's
  # own watchdog never sees: a run that takes seconds is cut at 120 s
  # (RUN_TIMEOUT, longer for a gate-level netlist).
  timeout "${RUN_TIMEOUT:-120}" "$@" < /dev/null > "$OBJ/$name.log" 2>&1 || rc=$?
  if [ $rc -eq 0 ] && grep -q '^TB PASS' "$OBJ/$name.log" && ! grep -q 'TB FAIL' "$OBJ/$name.log"; then
    got=pass
  elif [ $rc -eq 1 ]; then  # $fatal: the bench's own verdict
    got=$(sed -n '/^TB FAIL reason=/{s/^TB FAIL reason=\([^ ]*\).*/\1/p;q}' "$OBJ/$name.log")
    got=${got:-crash}
  else  # a time-out, a signal, or a failure printed with exit status 0
    got=crash
  fi
  if [ "$got" = "$want" ]; then
    echo "ok     $name: $got"
  else
    echo "WRONG  $name: wanted $want, got $got (exit $rc), log $OBJ/$name.log:"
    { grep -v 'TB PASS' "$OBJ/$name.log" || true; } | tail -n 15
    FAILED=1
  fi
}
