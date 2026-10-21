#!/bin/bash
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# tb/mosaic_soc/run_efpga.sh — firmware on a generated SoC with an eFPGA
# loads the fabric and uses a register of the user design.
#
# The configuration's `soc.efpga` puts hw/efpga/mosaic_efpga.sv and the fabric
# of its preset in mosaic_soc: registers and user window at the addresses of
# the generated mosaic_memory_map.inc. Hart 0 runs prog_efpga/efpga.S five
# times, each in a new simulation:
#   regs        the design with two registers: they must read back; after it
#               has run, its unload removes it and it is loaded again
#   silent      a design that never acknowledges: the wrapper must answer for it
#   control     the checks of `regs` on the silent design: they must fail, at
#               the first read of a register
#   bad_crc     the stream of `regs` with a wrong CRC word: the loader must
#               refuse it, and the firmware fail where it expects `configured`
#   bad_unload  the unload of `regs` with the tag word of the other design: the
#               loader must refuse it, and the firmware fail where it expects
#               the design removed
# Then the production firmware (sw/firmware) boots from flash with a stream in
# its deployment table (sw/firmware/DEPLOYMENT.md):
#   boot_bad_crc  the stream of `regs` with a wrong CRC word: the loader must
#                 refuse it, the workers still run, and the exit value is the
#                 STATUS of the refusal with bit 31 set
#   boot_test     `regs`, with the user's check tb/efpga/bus_regs_test.c, which
#                 returns 7 when it reads R0's reset value: the exit value
#                 must be 0x40000007 (stops after the cold boot)
# The sweep step efpga_design boots it with a design the loader takes
# (tb/mosaic_soc/run_fw.sh with EFPGA_DESIGN).
#
# Only three of the firmware's ten checks have such a control, the fourth, the
# fifth and the ninth; the wrapper's own bench (tb/efpga/run_wrapper.sh) has
# the others.
#
# Pass criterion: "### RESULT: EXIT SUCCESS", printed once, after the seven
# runs ended as expected. Usage: tb/mosaic_soc/run_efpga.sh   (inside
# `nix develop .#sim`). MOSAIC_CFG must be a design with `soc.efpga: {preset:
# small}` and an SRAM pool whose hart 0 runs free; the default is the wake
# demonstration with the fabric.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"
source "$REPO/tb/tools.sh"
mosaic_need_riscv_tc
mosaic_need_verilator
source "$REPO/tb/efpga/common.sh"
MOSAIC_CFG="${MOSAIC_CFG:-configs/mosaic_efpga_demo.yaml}"
OBJ="$HERE/obj_dir_efpga"
PY="$REPO/.venv/bin/python"
[ -x "$PY" ] || PY=python3
fail() { echo "### RESULT: FAILED: $*"; exit 1; }

echo "### [1/6] generating the streams ..."
efpga_generate

echo "### [2/6] generating the SoC and its fabric ($MOSAIC_CFG) ..."
TPLS=$(mosaic_templates)
"$PY" util/mosaic_gen/mcu_gen.py --mosaic_config "$MOSAIC_CFG" \
    --base_config configs/general.hjson --pads_cfg configs/pad_cfg.py \
    --output-root build/mosaic --outtpl "$TPLS" --externaltpl "" > "$HERE/mcu-gen-efpga.log" 2>&1 \
    || fail "RTL generation, see $HERE/mcu-gen-efpga.log"
MANIFEST="$("$PY" util/mosaic_gen/build_manifest.py locate --config "$MOSAIC_CFG" \
    --base-config configs/general.hjson --pads-cfg configs/pad_cfg.py \
    --repo-root "$REPO")"
MOSAIC_SW="$("$PY" -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["generated_root"])' "$MANIFEST")/sw"
# The streams are for the fabric in the SoC: efpga_gen.py generated both from
# the same preset, and every file of the SoC's fabric must be the same.
"$PY" - "$(dirname "$MOSAIC_SW")/efpga/manifest.json" "$OUT/manifest.json" <<'EOF' \
    || fail "$MOSAIC_CFG: no fabric, or not the one the streams were made for"
import json, sys
soc, streams = (json.load(open(path))["outputs"] for path in sys.argv[1:])
sys.exit(not soc or any(streams.get(name) != digest for name, digest in soc.items()))
EOF
RISCV_XHEEP="${RISCV_XHEEP:-$(dirname "$(dirname "$TC")")}" \
COMPILER_PREFIX="${COMPILER_PREFIX:-$(basename "$TC" | sed 's/elf$//')}" \
    scripts/fusesoc-setup.sh --manifest "$MANIFEST" > "$HERE/fusesoc-setup-efpga.log" 2>&1 \
    || fail "FuseSoC setup, see $HERE/fusesoc-setup-efpga.log"
BUILD_ROOT="$(sed -n 's/^FUSESOC_BUILD_ROOT=//p' "$HERE/fusesoc-setup-efpga.log" | tail -1)"
[ -d "$BUILD_ROOT" ] || fail "FuseSoC build root missing"

echo "### [3/6] building the firmware ..."
# Under the bundle, not under tb/: the source closure may not move between the
# generation and the staging above and the build below.
FW_DIR="$(dirname "$MOSAIC_SW")/efpga_fw"
rm -rf "$FW_DIR"
mkdir -p "$FW_DIR"
# The image hart 0 boots, and its ISA: this test needs a 32-bit hart that runs
# from reset, alone on its image, and loads its program into SRAM.
read -r IMAGE MARCH ABI < <("$PY" - "$MOSAIC_SW/boot_images.json" <<'EOF'
import json, sys
boot = json.load(open(sys.argv[1]))
hart = next(h for h in boot["harts"] if int(h["hart_id"]) == 0)
image = next(i for i in boot["images"] if i["image_id"] == hart["image_id"])
abi = "ilp32e" if "ilp32e" in image.get("abis", []) else "ilp32"
ok = (hart["role"] == "titan" and image.get("harts") == [0] and image.get("xlens") == [32]
      and not image.get("execute_in_place") and set(image.get("abis", [])) <= {"ilp32", "ilp32e"})
print(image["image_id"], "rv32e_zicsr" if abi == "ilp32e" else "rv32i_zicsr", abi if ok else "none")
EOF
)
[ "$ABI" != none ] || fail "$MOSAIC_CFG: hart 0 is not a free-running RV32 hart with an SRAM image of its own"
for stream in bus_regs counter8_en bus_regs.unload counter8_en.unload; do
  sed 's/^/    .word 0x/' "$OUT/bitstream/$stream.hex" > "$FW_DIR/$stream.inc"
done
# The CRC word is the last one, and no CRC of this stream is one below itself.
sed '$s/.*/    .word 0x'"$(printf %08x $(( (0x$(tail -n 1 "$OUT/bitstream/bus_regs.hex") - 1) & 0xFFFFFFFF )))"'/' \
    "$FW_DIR/bus_regs.inc" > "$FW_DIR/bus_regs_bad_crc.inc"
# The second word carries the tag: the tag of the other design.
sed '2s/.*/    .word 0x'"$(sed -n 2p "$OUT/bitstream/counter8_en.unload.hex")"'/' \
    "$FW_DIR/bus_regs.unload.inc" > "$FW_DIR/bus_regs_bad_unload.inc"
TAG=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["tags"]["bus_regs"])' \
    "$OUT/manifest.json")
while read -r name stream unload silent; do
  "$TC"-gcc -march="$MARCH" -mabi="$ABI" -nostdlib -ffreestanding \
      -DMOSAIC_USE_BUILD_GENERATED_HEADERS -DEFPGA_SILENT="$silent" -DEFPGA_TAG="$TAG" \
      -DEFPGA_STREAM="\"$stream.inc\"" -DEFPGA_UNLOAD="\"$unload.inc\"" \
      -I "$MOSAIC_SW/include" -I "$FW_DIR" \
      -c "$HERE/prog_efpga/efpga.S" -o "$FW_DIR/$name.o"
  "$TC"-ld -T "$MOSAIC_SW/linker/image_${IMAGE}.ld" "$FW_DIR/$name.o" -o "$FW_DIR/$name.elf"
  "$TC"-objcopy -O verilog "$FW_DIR/$name.elf" "$FW_DIR/$name.hex"
done <<EOF
regs       bus_regs         bus_regs.unload            0
silent     counter8_en      counter8_en.unload         1
control    counter8_en      counter8_en.unload         0
bad_crc    bus_regs_bad_crc bus_regs.unload            0
bad_unload bus_regs         bus_regs_bad_unload        0
EOF
# The production firmware, with the stream of bad_crc in its flash image.
sed 's/^    \.word 0x//' "$FW_DIR/bus_regs_bad_crc.inc" > "$FW_DIR/bus_regs_bad_crc.hex"
make -C sw/firmware RISCV_TC="$TC" MOSAIC_GENERATED_ROOT="$(dirname "$MOSAIC_SW")" \
    BUILD="$FW_DIR/boot_bad_crc" EFPGA_STREAM="$FW_DIR/bus_regs_bad_crc.hex" \
    EFPGA_UNLOAD="$OUT/bitstream/bus_regs.unload.hex" \
    > "$FW_DIR/boot_bad_crc.log" 2>&1 || fail "boot_bad_crc: firmware build, see $FW_DIR/boot_bad_crc.log"
make -C sw/firmware RISCV_TC="$TC" MOSAIC_GENERATED_ROOT="$(dirname "$MOSAIC_SW")" \
    BUILD="$FW_DIR/boot_test" EFPGA_STREAM="$OUT/bitstream/bus_regs.hex" \
    EFPGA_TEST="$REPO/tb/efpga/bus_regs_test.c" MOSAIC_FIRMWARE_CPPFLAGS=-DMOSAIC_COLD_BOOT_SMOKE \
    > "$FW_DIR/boot_test.log" 2>&1 || fail "boot_test: firmware build, see $FW_DIR/boot_test.log"

echo "### [4/6] building the full-SoC Verilator model ..."
rm -rf "$OBJ"
"$PY" "$HERE/gen_filelist.py" "$REPO" --manifest "$MANIFEST" \
    --build-root "$BUILD_ROOT" > "$FW_DIR/soc.f"
verilator --binary -j 0 --top-module tb_top --Mdir "$OBJ" -o Vtb_top \
    --timescale 1ns/1ps -GUSE_EXTERNAL_DEVICE_EXAMPLE=1 -GJTAG_DPI=0 \
    -f "$FW_DIR/soc.f" -Werror-USERFATAL > "$HERE/build-efpga.log" 2>&1 \
    || fail "Verilator build, see $HERE/build-efpga.log"

echo "### [5/6] running the firmware of hart 0 ..."
# <firmware> <the exit value the testbench must report>
RUNS=0
while read -r name want; do
  rc=0
  "$OBJ/Vtb_top" +firmware="$FW_DIR/$name.hex" +boot_sel=0 +maxcycles=400000 \
      < /dev/null > "$HERE/sim-efpga-$name.log" 2>&1 || rc=$?
  RUNS=$((RUNS + 1))
  if [ "$want" = 0 ]; then
    [ $rc -eq 0 ] && grep -q '^EXIT SUCCESS' "$HERE/sim-efpga-$name.log" \
        || fail "$name: no EXIT SUCCESS (exit $rc), see $HERE/sim-efpga-$name.log"
  else
    [ $rc -ne 0 ] && grep -Eq "EXIT FAILURE: +$want\$" "$HERE/sim-efpga-$name.log" \
        || fail "$name: not the failure of check $want, see $HERE/sim-efpga-$name.log"
  fi
  echo "ok     $name: exit value $want"
done <<EOF
regs       0
silent     0
control    5
bad_crc    4
bad_unload 9
EOF
echo "### [6/6] booting the production firmware from flash ..."
# A cold boot: the testbench writes only the flash model (sw/firmware/DEPLOYMENT.md).
# boot_bad_crc: STATUS = error | CAUSE_CRC (3) << 8, with bit 31 set.
# boot_test: 0x40000000 | the 7 the user's check returns.
while read -r name want; do
  rc=0
  "$OBJ/Vtb_top" +firmware="$FW_DIR/$name/mosaic_fw.hex" +boot_sel=1 +execute_from_flash=1 \
      +maxcycles=20000000 < /dev/null > "$HERE/sim-efpga-$name.log" 2>&1 || rc=$?
  RUNS=$((RUNS + 1))
  [ $rc -ne 0 ] && grep -Eq "EXIT FAILURE: +$want\$" "$HERE/sim-efpga-$name.log" \
      || fail "$name: not the exit value $want, see $HERE/sim-efpga-$name.log"
  echo "ok     $name: exit value $want"
done <<EOF
boot_bad_crc $(( 0x80000000 | 0x4 | 3 << 8 ))
boot_test    $(( 0x40000000 | 7 ))
EOF
[ $RUNS -eq 7 ] || fail "$RUNS of 7 runs were made"
echo "### RESULT: EXIT SUCCESS: hart 0 loaded, used, unloaded and reloaded the fabric, and booted past a refused stream and into the user's check (7 runs)"
