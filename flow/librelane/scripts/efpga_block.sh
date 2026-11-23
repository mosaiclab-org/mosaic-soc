#!/bin/bash
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# flow/librelane/scripts/efpga_block.sh — a stitched eFPGA fabric as a hard macro
# placed in MOSAIC's signoff flow (flow/librelane/signoff_template.yaml, through
# experimental/run_signoff.sh: nothing skipped, nothing waived): with the wrapper
# hw/efpga/mosaic_efpga.sv alone as one block, or, given a SoC configuration with
# soc.efpga, in that SoC's delivery wrapper flow/librelane/experimental/<soc.name>.sv
# with the RTL of its bundle (make mosaic-gen). This needs the user's approval and
# takes hours.
#
# The macro's liberty has pins and no arcs (util/mosaic_gen/efpga_timing.py lib),
# so the flow's own timing covers the rest of the design, and the paths through
# the fabric are timed per design on this layout by efpga_block_sta.sh.
#
# Pass: "BLOCK PASS ...", from the run's final metrics and its disconnected pins,
# and for a SoC the verdict of `mosaic physical-intent ppa`.
# Usage: flow/librelane/scripts/efpga_block.sh <the --out of efpga_gen.py --stitch> [tag] [SoC configuration]
# EFPGA_CHIP=<slot>, with a SoC configuration, hardens a chip instead: the top the
# slot names (a file of flow/librelane/slots/; its DESIGN_NAME, whose source is
# flow/librelane/experimental/<DESIGN_NAME>.sv) in that slot's die with its pad
# ring, by LibreLane's Chip flow: the same steps and checks, with the pads, the seal
# ring, the fill and the density check added.
# EFPGA_BLOCK_WRITE_ONLY=1 writes the config and stops. Run:
# flow/librelane/experimental/runs/<tag>/. docs/efpga.md is the reference.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO"
RUN="$(cd "${1:?usage: efpga_block.sh <the --out of efpga_gen.py --stitch> [tag] [SoC configuration]}" && pwd)"
TAG="${2:-efpga_block}"
SOC="${3:-}"
OUT="$REPO/build/efpga_block/$TAG"
FLOW="$REPO/flow/librelane"
fail() { echo "BLOCK FAIL tag=$TAG: $*"; exit 1; }
mkdir -p "$OUT/lib"

DESIGN=mosaic_efpga
MANIFEST=
CHIP="${EFPGA_CHIP:+$(cd "$(dirname "$EFPGA_CHIP")" && pwd)/$(basename "$EFPGA_CHIP")}"
[ -z "$CHIP" ] || [ -n "$SOC" ] || fail "EFPGA_CHIP needs a SoC configuration"
if [ -n "$SOC" ]; then
  DESIGN="$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["soc"]["name"])' "$SOC")"
  [ -z "$CHIP" ] || DESIGN="$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["DESIGN_NAME"])' "$CHIP")"
  # MOSAIC_MANIFEST pins the bundle across a series of runs, as in run_signoff.sh:
  # an edit under flow/ moves the hash of the sources, not the RTL.
  MANIFEST="${MOSAIC_MANIFEST:-$(.venv/bin/python util/mosaic_gen/build_manifest.py locate --config "$SOC" \
      --base-config configs/general.hjson --pads-cfg configs/pad_cfg.py --repo-root "$REPO" 2>/dev/null)}"
  [ -f "$MANIFEST" ] || fail "no bundle of $SOC for these sources: make mosaic-gen MOSAIC_CFG=$SOC"
  BUILD_ROOT="$(ls -dt "$(dirname "$MANIFEST")"/runs/fusesoc.*/build | head -n 1)"
  python3 flow/librelane/scripts/gen_filelist.py "$REPO" --manifest "$MANIFEST" \
      --build-root "$BUILD_ROOT" --efpga-macro --wrapper "flow/librelane/experimental/$DESIGN.sv" \
      --output "$OUT/filelist.yaml" > /dev/null || fail "no source list"
fi
CONFIG="experimental/.generated_$DESIGN.yaml"

[ -f "$REPO/build/efpga_sta/$(basename "$RUN")/lib/eFPGA__tt_025C_5v00.lib" ] \
    || flow/librelane/scripts/efpga_sta.sh "$RUN" > "$OUT/sta.log" 2>&1 \
    || fail "the macro does not pass efpga_sta.sh, see $OUT/sta.log"
cp "$REPO/build/efpga_sta/$(basename "$RUN")"/lib/*.lib "$OUT/lib/"

# The macro in the middle of the wrapper's cells: the configuration's FrameData
# leaves its west edge, with the pads, the strobes and UserCLK its south edge, and
# the window its east edge. On tracks, which are 0.56 um apart on both layers of
# its pins, so that its pins lie on the top level's. The west channel is the widest:
# the loader's wires run its whole height, 2.4 times the wire of the east one, and
# 100 um there left no track free. A SoC's cells go east of it, beside the window.
python3 - "$RUN" "$OUT" "$FLOW/$CONFIG" "$DESIGN" "$SOC" "$MANIFEST" "$CHIP" <<'EOF'
import hashlib, json, re, sys
from pathlib import Path
sys.path.insert(0, ".")
run, out, config, design, soc, manifest, chip = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), *sys.argv[4:]
macro = json.loads((run / "manifest.json").read_text())
assert macro["fabric_macro"]["clean"], f"{run}: the macro is not clean"
views = run / "macro/fabric/final_views"
width, height = map(float, re.search(r"SIZE ([\d.]+) BY ([\d.]+)", (views / "lef/eFPGA.lef").read_text()).groups())
PITCH, MARGIN = 0.56, 15
track = lambda um: round(round(um / PITCH) * PITCH, 2)
west, south, east, north = track(200), track(150), track(100), track(40)
period, instance = 50, "eFPGA_inst"
root = Path.cwd()
if soc:
    import yaml
    from harness.physical.floorplan import clock_period_ns, estimate_logic_area
    # The fabric in the SoC is the one the macro was hardened from, file for file.
    def sources(proj):
        return {p.relative_to(proj).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(proj.glob("[FT]*/**/*.v"))}
    bundle = Path(json.loads(Path(manifest).read_text())["generated_root"]) / "efpga/proj"
    assert sources(bundle) == sources(run / "proj") and sources(bundle), \
        f"the fabric of {soc} is not the one of {run}"
    intent = yaml.safe_load(Path(soc).read_text())["soc"]
    period, instance = clock_period_ns(intent), "i_mosaic_soc.mosaic_efpga_i.eFPGA_inst"
    estimate = estimate_logic_area(intent)
    assert estimate.ok and period, f"{soc}: {estimate.reason}"
    # The SoC's cells by the area model, the wrapper's as efpga_block measured them
    # (696 hold buffers among them), at the 40 % of the channels they took there,
    # rounded up. What the macro's other channels leave is added to the east one.
    block = json.loads((root / "flow/librelane/experimental/runs/efpga_block/final/metrics.json").read_text())
    cells = estimate.logic_um2 + block["design__instance__area__stdcell"]
    tall = south + height + north
    free = (west + width + east) * tall - width * height
    east = track(east + max(0.0, cells / 0.40 - free) / tall)
die = (track(west + width + east), track(south + height + north))
floorplan = f"""DESIGN_NAME: {design}
FP_SIZING: absolute
DIE_AREA: [0, 0, {die[0]}, {die[1]}]
CORE_AREA: [{MARGIN}, {MARGIN}, {round(die[0] - MARGIN, 2)}, {round(die[1] - MARGIN, 2)}]"""
if chip:
    # The slot fixes the die, the core and the pads. The macro keeps its west
    # channel from the core's edge and is centred in the core's height; the SoC's
    # cells, at the 40 % above, must fit east of it.
    slot = yaml.safe_load(Path(chip).read_text())
    x0, y0, x1, y1 = slot["CORE_AREA"]
    west, south = track(x0 + west), track(y0 + (y1 - y0 - height) / 2)
    assert west + width + east <= x1 and south >= y0, f"{chip}: the macro does not fit the core"
    assert cells / 0.40 <= (x1 - west - width) * (y1 - y0), f"{chip}: the SoC's cells do not fit east of the macro"
    die = tuple(slot["DIE_AREA"][2:])
    floorplan = "FP_SIZING: absolute\n" + Path(chip).read_text()
    # pdngen's via repair stretches a pad's Metal3 strap along a same-net core
    # stripe over it until something stops it: on 2026-11-09 a VSS strap ran
    # 1,282 um up a Metal4 stripe to the macro's halo, and its one via, 2466 x 9
    # cuts at the single cut's spacing, broke V3.2b 41,913 times. Six straps fill
    # each power pad, so no offset of the stripes misses them all. Metal3 bands just
    # inside the core, there for the PDN step only, stop them at the ring: across
    # it at mid-row, clear of the rails' vias, and down its sides, before the first
    # stripe. The rows sit on the site height from the die's origin.
    row = 3.92  # gf180mcu_fd_sc_mcu7t5v0
    s, n = (-(-y0 // row) + 0.5) * row, (y1 // row - 0.5) * row
    bands = [(x0, s - 0.25, x1, s + 0.25), (x0, n - 0.25, x1, n + 0.25),
             (x0 + 2.75, y0, x0 + 3.25, y1), (x1 - 3.25, y0, x1 - 2.75, y1)]
    floorplan += "\nPDN_OBSTRUCTIONS:\n" + "".join(
        f"- [Metal3, {', '.join(f'{v:.2f}' for v in band)}]\n" for band in bands)
over =f"{round(west + 2, 2)}, {round(south + 2, 2)}, {round(west + width - 2, 2)}, {round(south + height - 2, 2)}"
corners = {"tt_025C_5v00", "ss_125C_4v50", "ff_n40C_5v50"}
libs = "\n".join(f'      "*_{c}":\n      - {out}/lib/eFPGA__{c}.lib' for c in sorted(corners))
# The template's density is for a block that fills its die. Here the cells take
# about a third of the channels, and at 76% they crowd the window's pins so that
# placement cannot legalise the buffers of the repair after global routing.
template = (root / "flow/librelane/signoff_template.yaml").read_text()
CHANGES = [("PL_TARGET_DENSITY_PCT: 76", "PL_TARGET_DENSITY_PCT: 50"),
           ("GRT_RESIZER_HOLD_SLACK_MARGIN: 0.05", "GRT_RESIZER_HOLD_SLACK_MARGIN: 0.6")]
# A chip: the Chip flow; the clock through its pad, pads driven by the board, not
# by a standard cell, and the flash's data timed against its SCK
# (experimental/chip.sdc says why); the grid fed from the power pads by a core ring
# as wide as wafer-space/gf180mcu-project-template's, tied to them on Metal3, not
# Metal2 as there (experimental/pdn_chip.tcl says why), and no power pins
# of its own. As in that template, Magic flattens the pad cells' contact cells,
# and extracts the power pads, several on each net, without merging ports.
# The output-only pads leave Y, their readback, open: LibreLane calls that a dead
# cell and stops. Here it records them and the verdict below, and the waiver of
# the PPA gate, accept exactly those eleven by name, where the template ignores
# the pad cell, every instance of it, with IGNORE_DISCONNECTED_MODULES.
# The density deck's rules are whole-die area ratios, of COMP, Poly2 and each metal.
# In the PDK's mode, tiling, it first flattens every layer, the contacts and vias no
# rule reads among them, and on this chip that passes 9 GB (killed in Metal4,
# 2026-11-08). In deep mode KLayout takes the same areas on the hierarchy: on the
# macro of small both modes give every ratio to the last digit and the same five
# errors, deep in 0.49 GB against 1.15 GB.
if chip:
    CHANGES += [("flow: Classic", "flow: Chip"),
                ("CLOCK_PORT: clk_i",
                 "CLOCK_PORT: clk_PAD\nCLOCK_NET: clk_pad/Y\nFALLBACK_SDC: dir::chip.sdc\n"
                 "ERROR_ON_DISCONNECTED_PINS: false\nKLAYOUT_DENSITY_OPTIONS:\n  run_mode: deep"),
                ("PDN_CORE_RING_VWIDTH: 3", "PDN_CORE_RING_VWIDTH: 25"),
                ("PDN_CORE_RING_HWIDTH: 3",
                 "PDN_CORE_RING_HWIDTH: 25\nPDN_CORE_RING_CONNECT_TO_PADS: true\nPDN_ENABLE_PINS: false\n"
                 "PDN_CFG: dir::pdn_chip.tcl"),
                ('- "via1_*"', '- "via1_*"\n- "M1_N*"\n- "M1_P*"\n- "M2_M1*"\n- "M3_M2*"\nMAGIC_EXT_UNIQUE: notopports')]
for old, new in CHANGES:
    assert template.count(old) == 1, old
    template = template.replace(old, new)
config.write_text(template + f"""
# ---- The block: efpga_block.sh ------------------------------------------------
CLOCK_PERIOD: {period:g}
{floorplan}
MACROS:
  eFPGA:
    gds:
    - {views}/gds/eFPGA.gds
    lef:
    - {views}/lef/eFPGA.lef
    vh:
    - {views}/vh/eFPGA.vh
    lib:
{libs}
    instances:
      {instance}:
        location: [{west}, {south}]
        orientation: N
PDN_MACRO_CONNECTIONS:
- "{instance} VDD VSS VDD VSS"
# No signal in the macro's layers: the gaps its LEF leaves between its pins and
# power stripes count as tracks for the global router, and wires sent through them
# short to the macro. Metal5 stays open, so a net can cross it straight and turn
# outside it. 2 um in from its edge, for the vias onto its pins.
ROUTING_OBSTRUCTIONS:
- [Metal2, {over}]
- [Metal3, {over}]
- [Metal4, {over}]
# The clock tree balances sinks without regard to the macro: a leaf with cells on
# both sides of it is 3 mm and 1 pF of wire, its far flops up to 0.6 ns late. Only
# a repair of hold after global routing can see that wire, and it misjudges it: with
# the margin above at 0.4 ns, a flop it counted as met failed signoff by 0.06 ns.
RUN_POST_GRT_RESIZER_TIMING: true
""")
if not soc:
    sources = ["hw/mosaic_soc/include/reg_pkg.sv", "hw/mosaic_soc/include/obi_pkg.sv", "hw/asic/gf180/tc_clk.sv", "hw/efpga/mosaic_efpga.sv"]
    (out / "filelist.yaml").write_text("VERILOG_FILES:\n" + "".join(f"- {root / s}\n" for s in sources)
                                       + f"VERILOG_INCLUDE_DIRS:\n- {macro['fabric']['path']}\n")
print(f"### {design}: die {die[0]} x {die[1]} um, east channel {east} um, clock {period:g} ns")
EOF
[ -z "${EFPGA_BLOCK_WRITE_ONLY:-}" ] || exit 0

# A tag's run starts from nothing: LibreLane would add its steps to an old one's.
rm -rf "$FLOW/experimental/runs/$TAG" "$FLOW/experimental/final_$TAG"

# The PDK is the clone's, named on the flow's command line; the user's shell's
# variables name another.
env -u PDK_ROOT -u PDK MOSAIC_FILELIST="$OUT/filelist.yaml" \
    MOSAIC_RESOURCE_CONFIG=experimental/resources_lowmem.yaml \
    flow/librelane/experimental/run_signoff.sh "$TAG" "$CONFIG"

python3 - "$FLOW/experimental/runs/$TAG" "$TAG" "$SOC" "$CHIP" <<'EOF'
import json, subprocess, sys
from pathlib import Path
sys.path.insert(0, ".")
from harness.evidence.librelane import disconnected_pins
run, tag, soc, chip = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
metrics = json.loads((run / "final/metrics.json").read_text())
CHECKS = ("route__drc_errors", "magic__drc_error__count", "klayout__drc_error__count", "design__lvs_error__count",
          "design__xor_difference__count", "antenna__violating__nets",
          "design__max_slew_violation__count", "design__max_cap_violation__count",
          "timing__setup_vio__count", "timing__hold_vio__count",
          # in a chip the pins below are critical, a cell with its one output open
          *(("klayout__antenna_error__count", "klayout__density_error__count") if chip
            else ("design__critical_disconnected_pin__count",)))
bad = {name: metrics[name] for name in CHECKS if metrics[name] != 0}
# The address bits the wrapper does not read have no load: of each port's addr, bits
# 63:32 of the struct, it reads 9:2 of obi_req_i and 4:2 of reg_req_i. A port is
# critical to LibreLane only when all its bits are unconnected, so a data bit left
# unconnected would pass above: the names must be exactly these. This is not the
# verdict of `mosaic physical-intent ppa`, which rejects any such pin without a
# waiver (docs/efpga.md, The wrapper and the macro as one block). In a SoC the bus
# drives those bits, so none may be left, and the gate's verdict is required.
# In a chip, the input of each output-only pad: the GF180MCU pads have no cell
# without one, and its Y has no load (mosaic_chip_efpga.sv). OpenROAD escapes the
# brackets of generated names, so the names are compared without escapes.
UNREAD = set() if soc else ({f"obi_req_i[{b}]" for b in (32, 33, *range(42, 64))}
                            | {f"reg_req_i[{b}]" for b in (32, 33, *range(37, 64))})
if chip:
    UNREAD = {f"outputs[{i}].pad/Y" for i in range(11)}
pins = {pin.replace("\\", "") for pin in disconnected_pins(run) or ()}
if pins != UNREAD:
    bad["disconnected_pins"] = ",".join(sorted(pins ^ UNREAD)) or "no table"
if soc and subprocess.run([sys.executable, "-m", "harness", "physical-intent", "ppa", "--run-dir", str(run)]).returncode:
    bad["ppa"] = "rejected"
print(f"BLOCK {'FAIL' if bad else 'PASS'} tag={tag} " + (" ".join(f"{k}={v}" for k, v in bad.items()) or f"checks={len(CHECKS) + 1 + bool(soc)} {'unloaded_pad_inputs' if chip else 'unread_address_bits'}={len(UNREAD)}")
      + f" setup_ns={metrics['timing__setup__ws']:.2f} hold_ns={metrics['timing__hold__ws']:.2f}")
sys.exit(1 if bad else 0)
EOF
