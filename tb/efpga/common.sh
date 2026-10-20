# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# tb/efpga/common.sh — sourced by the runners that need the eFPGA fabric, with
# REPO set and the working directory at the repository root.

OUT="$REPO/build/efpga/small"

# Generate the `small` fabric preset and the streams of the two user designs
# with the pinned FABulous flow (util/mosaic_gen/efpga_gen.py, which needs
# `nix develop .#efpga`; entered here when its tools are not on PATH). Sets
# DEFS, the geometry as the -D options of the benches.
efpga_generate() {
  local gen=(python3 util/mosaic_gen/efpga_gen.py --preset configs/efpga/small.csv --out "$OUT"
             --design tb/efpga/counter8_en.v --wrapper tb/efpga/counter8_en_wrapper.v
             --design tb/efpga/bus_regs.v --wrapper tb/efpga/bus_regs_wrapper.v)
  if command -v FABulous >/dev/null; then
    "${gen[@]}"
  else
    nix develop "$REPO#efpga" --option warn-dirty false --command "${gen[@]}"
  fi
  DEFS=$(python3 -c 'import json, sys
print("-DROWS=%(rows)d -DCOLS=%(cols)d -DFBPR=%(frame_bits_per_row)d "
      "-DMFPC=%(max_frames_per_col)d" % json.load(open(sys.argv[1]))["geometry"])' "$OUT/manifest.json")
}

# One simulation, which must end as expected: `pass`, or the reason of the
# TB FAIL a negative control is there to provoke. Logs go to $OBJ.
FAILED=0
run_case() {  # <simulator> <case> <pass | reason of the expected TB FAIL> <command...>
  local name="$1_$2" want="$3" rc=0 got
  shift 3
  # A wrong configuration can oscillate in zero simulated time, which a bench's
  # own watchdog never sees: a run that takes seconds is cut at 120 s.
  timeout 120 "$@" < /dev/null > "$OBJ/$name.log" 2>&1 || rc=$?
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
