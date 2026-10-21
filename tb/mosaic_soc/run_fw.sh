#!/bin/bash
# MOSAIC full-SoC PRODUCTION-FIRMWARE simulation (Verilator).
#
# Builds the COMPLETE PoC SoC from the default config (mosaic.yaml: 1 cv32e20
# TITAN + 2 fazyrv ATLAS + 4 serv NANO + TDU + system_bus + peripherals +
# debug) and runs the deployable SPI-flash image (sw/firmware -> mosaic_fw.hex):
#   - The immutable boot ROM enables the memory-mapped SPI window and jumps to
#     the TITAN XIP image. TITAN validates the topology-bound deployment table,
#     copies and CRC32-checks every worker image into its SRAM boot slot, then
#     configures the TDU
#     (DYNAMIC mode, CPI estimates), queues all 6 task descriptors in the TDU
#     FIFO, then arms the wake mask and releases every worker with one
#     WAKE_REQ pulse (push-all-then-wake: a woken worker reaches TASK_POP in
#     a few instructions, so descriptors must be queued first).
#   - Each worker (atlas_worker.S / nano_worker.S) pops a UNIQUE descriptor
#     from TDU TASK_POP (hardware-atomic dequeue), runs its workload (MAC /
#     CRC loop), stores its result at 0x3100+slot*4 and its sentinel at
#     0x3000+slot*4 — slot = the popped descriptor's core_hint, so completion
#     reporting is correct no matter which worker pops which task.
#   - TITAN polls the 6 sentinel slots and signals soc_ctrl exit 0.
# So "EXIT SUCCESS" proves the full production stack: C runtime + TDU driver +
# task dispatch + 6 heterogeneous workers + completion protocol, in the real SoC.
#
# Needs: Verilator + a RISC-V GCC (rv32i, ld-linked, no multilib).
# Usage: tb/mosaic_soc/run_fw.sh   (MOSAIC_CFG / RISCV_TC override)
#
# EFPGA_DESIGN=<design>.v, on a configuration with soc.efpga: the user design
# for its eFPGA, a module named after its file whose ports are those of the
# shell (docs/efpga.md). It is compiled for the SoC's fabric
# (util/mosaic_gen/efpga_gen.py --shell, in `nix develop .#efpga`, entered
# here) and packed into the flash image, and TITAN loads it at cold boot
# before it wakes the workers: EXIT SUCCESS then also means the design was
# configured. A design the loader refuses ends the run with its STATUS.
# EFPGA_TEST=<test>.c, with EFPGA_DESIGN: the user's check of that design, a C
# function `uint32_t efpga_test(void)` that TITAN calls once the workers ran
# (sw/firmware/Makefile). 0 passes; any other value ends the run with
# 0x40000000 | that value.
# WARM_REBOOTS=<n>: reset the SoC after each of the first n successful boots
# (tb/tb_top.sv +warm_reboots), with the flash and an eFPGA's latches kept.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
if [ -n "${EFPGA_DESIGN:-}" ]; then  # relative to the caller
  EFPGA_DESIGN="$(realpath -e "$EFPGA_DESIGN")" || { echo "EFPGA_DESIGN: no such file"; exit 1; }
fi
EFPGA_DESIGN="${EFPGA_DESIGN:-}"
if [ -n "${EFPGA_TEST:-}" ]; then
  [ -n "$EFPGA_DESIGN" ] || { echo "EFPGA_TEST checks the design of EFPGA_DESIGN"; exit 1; }
  EFPGA_TEST="$(realpath -e "$EFPGA_TEST")" || { echo "EFPGA_TEST: no such file"; exit 1; }
fi
EFPGA_TEST="${EFPGA_TEST:-}"
WARM_REBOOTS="${WARM_REBOOTS:-0}"
cd "$REPO"
source "$REPO/tb/tools.sh"
mosaic_need_riscv_tc
mosaic_need_verilator
MOSAIC_CFG="${MOSAIC_CFG:-mosaic.yaml}"
OBJ="$HERE/obj_dir_fw"
PY="$REPO/.venv/bin/python"
[ -x "$PY" ] || PY=python3

echo "### [1/4] generating RTL ($MOSAIC_CFG) ..."
TPLS=$(mosaic_templates)
"$PY" util/mosaic_gen/mcu_gen.py --mosaic_config "$MOSAIC_CFG" --base_config configs/general.hjson \
    --pads_cfg configs/pad_cfg.py --output-root build/mosaic --outtpl "$TPLS" --externaltpl "" \
    > "$HERE/mcu-gen.log" 2>&1 || { echo "RTL gen failed — see $HERE/mcu-gen.log"; exit 1; }
MANIFEST="$("$PY" util/mosaic_gen/build_manifest.py locate --config "$MOSAIC_CFG" \
    --base-config configs/general.hjson --pads-cfg configs/pad_cfg.py --repo-root "$REPO")" || exit 1
MOSAIC_GENERATED_ROOT="$("$PY" -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["generated_root"])' \
    "$MANIFEST")" || exit 1
[ -f "$MOSAIC_GENERATED_ROOT/sw/make/mosaic_isa.mk" ] \
    || { echo "generated software contract missing"; exit 1; }
"$PY" util/mosaic_gen/software_gen.py \
    --validate-production-demo "$MOSAIC_GENERATED_ROOT/sw/boot_images.json" \
    --isa-makefile "$MOSAIC_GENERATED_ROOT/sw/make/mosaic_isa.mk" \
    || exit 1
# FuseSoC setup regenerates the config-dependent regtool outputs (power
# manager banks etc.) — skipping it leaves stale per-bank RTL behind.
echo "###       running FuseSoC setup (register generators + filelist) ..."
RISCV_XHEEP="${RISCV_XHEEP:-$(dirname "$(dirname "$TC")")}" \
COMPILER_PREFIX="${COMPILER_PREFIX:-$(basename "$TC" | sed 's/elf$//')}" \
    scripts/fusesoc-setup.sh --manifest "$MANIFEST" > "$HERE/fusesoc-setup.log" 2>&1 \
    || { echo "FuseSoC setup failed — see $HERE/fusesoc-setup.log"; exit 1; }
BUILD_ROOT="$(sed -n 's/^FUSESOC_BUILD_ROOT=//p' "$HERE/fusesoc-setup.log" | tail -1)"
[ -n "$BUILD_ROOT" ] && [ -d "$BUILD_ROOT" ] || { echo "FuseSoC build root missing"; exit 1; }

EFPGA_STREAM=
if [ -n "$EFPGA_DESIGN" ]; then
  echo "###       compiling $EFPGA_DESIGN for the eFPGA ..."
  [ -f "$MOSAIC_GENERATED_ROOT/efpga/manifest.json" ] \
      || { echo "$MOSAIC_CFG has no eFPGA (soc.efpga)"; exit 1; }
  gen=(python3 util/mosaic_gen/efpga_gen.py --fabric "$MOSAIC_GENERATED_ROOT/efpga"
       --out "$MOSAIC_GENERATED_ROOT/efpga_design" --shell "$EFPGA_DESIGN")
  if command -v FABulous >/dev/null; then
    "${gen[@]}" > "$HERE/efpga-design.log" 2>&1
  else
    nix develop "$REPO#efpga" --option warn-dirty false --command "${gen[@]}" \
        > "$HERE/efpga-design.log" 2>&1
  fi || { echo "eFPGA compilation failed — see $HERE/efpga-design.log"; exit 1; }
  EFPGA_STREAM="$MOSAIC_GENERATED_ROOT/efpga_design/bitstream/$(basename "${EFPGA_DESIGN%.*}").hex"
fi

echo "### [2/4] building the production firmware (sw/firmware, rv32i) ..."
make -C sw/firmware clean >/dev/null
make -C sw/firmware RISCV_TC="$TC" EFPGA_STREAM="$EFPGA_STREAM" EFPGA_TEST="$EFPGA_TEST" \
    MOSAIC_GENERATED_ROOT="$MOSAIC_GENERATED_ROOT" > "$HERE/fw-build.log" 2>&1 \
    || { echo "firmware build failed — see $HERE/fw-build.log"; exit 1; }
echo "    flash image: sw/firmware/build/mosaic_fw.hex"
echo "    deployment:  sw/firmware/build/mosaic_flash.json"

echo "### [3/4] building the full-SoC Verilator model (this takes a few minutes) ..."
rm -rf "$OBJ"
"$PY" "$HERE/gen_filelist.py" "$REPO" --manifest "$MANIFEST" --build-root "$BUILD_ROOT" \
    > "$HERE/soc.f" || { echo "filelist gen failed"; exit 1; }
verilator --binary -j 0 --top-module tb_top \
    --Mdir "$OBJ" -o Vtb_top --timescale 1ns/1ps \
    -GUSE_EXTERNAL_DEVICE_EXAMPLE=1 -GJTAG_DPI=0 \
    -f "$HERE/soc.f" > "$HERE/build-fw.log" 2>&1
[ -x "$OBJ/Vtb_top" ] || { echo "### BUILD FAILED (no Vtb_top) — see $HERE/build-fw.log"; grep -iE "%Error|error:|undefined" "$HERE/build-fw.log" | head; exit 1; }

echo "### [4/4] running the simulation (production firmware) ..."
# SPI XIP makes TITAN fetches deliberately slow; worker loading plus the serv
# CRC loops remain bounded by the 20M-cycle cold-boot watchdog.
# This is a real cold boot: the testbench initializes only the external flash
# model. boot_sel=1 prevents tb_loadHEX from touching SRAM; execute_from_flash=1
# selects the same SPI-memory-mapped path used by silicon straps.
"$OBJ/Vtb_top" +firmware="$REPO/sw/firmware/build/mosaic_fw.hex" +boot_sel=1 \
    +execute_from_flash=1 +warm_reboots="$WARM_REBOOTS" \
    +maxcycles=20000000 2>&1 | tee "$HERE/sim-fw.log" | tail -20
SIM_RC=${PIPESTATUS[0]}
REBOOTS=$(grep -c '^\[TESTBENCH\].*: warm reboot$' "$HERE/sim-fw.log")
echo ""
if [ "$SIM_RC" -eq 0 ] && grep -q "EXIT SUCCESS" "$HERE/sim-fw.log" && [ "$REBOOTS" -eq "$WARM_REBOOTS" ]; then
  echo "### RESULT: EXIT SUCCESS — production firmware ran on $MOSAIC_CFG${EFPGA_DESIGN:+ with $(basename "$EFPGA_DESIGN") in its eFPGA}${EFPGA_TEST:+, checked by $(basename "$EFPGA_TEST")}, warm reboots: $REBOOTS ✓"
else
  echo "### RESULT: simulation failed or no EXIT SUCCESS (see $HERE/sim-fw.log)"
  exit 1
fi
