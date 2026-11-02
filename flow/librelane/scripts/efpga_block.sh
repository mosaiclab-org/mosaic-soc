#!/bin/bash
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# flow/librelane/scripts/efpga_block.sh — the wrapper hw/efpga/mosaic_efpga.sv and
# a stitched eFPGA fabric as one hardened block, the fabric a hard macro placed
# in MOSAIC's signoff flow (flow/librelane/signoff_template.yaml, through
# experimental/run_signoff.sh: nothing skipped, nothing waived). This needs the
# user's approval and takes hours.
#
# The macro's liberty has pins and no arcs (util/mosaic_gen/efpga_timing.py lib),
# so the flow's own timing covers the wrapper, and the paths through the fabric
# are timed per design on this layout by efpga_sta.sh.
#
# Pass: "BLOCK PASS ...", from the run's final metrics and its disconnected pins.
# Usage: flow/librelane/scripts/efpga_block.sh <the --out of efpga_gen.py --stitch> [tag]
# EFPGA_BLOCK_WRITE_ONLY=1 writes the config and stops. Run:
# flow/librelane/experimental/runs/<tag>/. docs/efpga.md is the reference.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO"
RUN="$(cd "${1:?usage: efpga_block.sh <the --out of efpga_gen.py --stitch> [tag]}" && pwd)"
TAG="${2:-efpga_block}"
OUT="$REPO/build/efpga_block/$TAG"
FLOW="$REPO/flow/librelane"
CONFIG="experimental/.generated_mosaic_efpga.yaml"
fail() { echo "BLOCK FAIL tag=$TAG: $*"; exit 1; }
mkdir -p "$OUT/lib"

[ -f "$REPO/build/efpga_sta/$(basename "$RUN")/lib/eFPGA__tt_025C_5v00.lib" ] \
    || flow/librelane/scripts/efpga_sta.sh "$RUN" > "$OUT/sta.log" 2>&1 \
    || fail "the macro does not pass efpga_sta.sh, see $OUT/sta.log"
cp "$REPO/build/efpga_sta/$(basename "$RUN")"/lib/*.lib "$OUT/lib/"

# The macro in the middle of the wrapper's cells: the configuration's FrameData
# leaves its west edge, with the pads, the strobes and UserCLK its south edge, and
# the window its east edge. On tracks, which are 0.56 um apart on both layers of
# its pins, so that its pins lie on the top level's. The west channel is the widest:
# the loader's wires run its whole height, 2.4 times the wire of the east one, and
# 100 um there left no track free.
python3 - "$RUN" "$OUT" "$FLOW/$CONFIG" "$OUT/filelist.yaml" <<'EOF'
import json, re, sys
from pathlib import Path
run, out, config, filelist = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
manifest = json.loads((run / "manifest.json").read_text())
assert manifest["fabric_macro"]["clean"], f"{run}: the macro is not clean"
views = run / "macro/fabric/final_views"
width, height = map(float, re.search(r"SIZE ([\d.]+) BY ([\d.]+)", (views / "lef/eFPGA.lef").read_text()).groups())
PITCH, MARGIN = 0.56, 15
track = lambda um: round(round(um / PITCH) * PITCH, 2)
west, south, east, north = track(200), track(150), track(100), track(40)
die = (track(west + width + east), track(south + height + north))
over = f"{round(west + 2, 2)}, {round(south + 2, 2)}, {round(west + width - 2, 2)}, {round(south + height - 2, 2)}"
corners = {"tt_025C_5v00", "ss_125C_4v50", "ff_n40C_5v50"}
libs = "\n".join(f'      "*_{c}":\n      - {out}/lib/eFPGA__{c}.lib' for c in sorted(corners))
root = Path.cwd()
# The template's density is for a block that fills its die. Here the cells take
# about 30% of the channels, and at 76% they crowd the window's pins so that
# placement cannot legalise the buffers of the repair after global routing.
template = (root / "flow/librelane/signoff_template.yaml").read_text()
for old, new in (("PL_TARGET_DENSITY_PCT: 76", "PL_TARGET_DENSITY_PCT: 50"),
                 ("GRT_RESIZER_HOLD_SLACK_MARGIN: 0.05", "GRT_RESIZER_HOLD_SLACK_MARGIN: 0.6")):
    assert old in template
    template = template.replace(old, new)
config.write_text(template + f"""
# ---- The block: efpga_block.sh ------------------------------------------------
DESIGN_NAME: mosaic_efpga
CLOCK_PERIOD: 50
FP_SIZING: absolute
DIE_AREA: [0, 0, {die[0]}, {die[1]}]
CORE_AREA: [{MARGIN}, {MARGIN}, {round(die[0] - MARGIN, 2)}, {round(die[1] - MARGIN, 2)}]
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
      eFPGA_inst:
        location: [{west}, {south}]
        orientation: N
PDN_MACRO_CONNECTIONS:
- "eFPGA_inst VDD VSS VDD VSS"
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
sources = ["hw/mosaic_soc/include/reg_pkg.sv", "hw/mosaic_soc/include/obi_pkg.sv", "hw/asic/gf180/tc_clk.sv", "hw/efpga/mosaic_efpga.sv"]
filelist.write_text("VERILOG_FILES:\n" + "".join(f"- {root / s}\n" for s in sources)
                    + f"VERILOG_INCLUDE_DIRS:\n- {manifest['fabric']['path']}\n")
EOF
[ -z "${EFPGA_BLOCK_WRITE_ONLY:-}" ] || exit 0

# A tag's run starts from nothing: LibreLane would add its steps to an old one's.
rm -rf "$FLOW/experimental/runs/$TAG" "$FLOW/experimental/final_$TAG"

# The PDK is the clone's, named on the flow's command line; the user's shell's
# variables name another.
env -u PDK_ROOT -u PDK MOSAIC_FILELIST="$OUT/filelist.yaml" \
    MOSAIC_RESOURCE_CONFIG=experimental/resources_lowmem.yaml \
    flow/librelane/experimental/run_signoff.sh "$TAG" "$CONFIG"

python3 - "$FLOW/experimental/runs/$TAG" "$TAG" <<'EOF'
import json, sys
from pathlib import Path
sys.path.insert(0, ".")
from harness.evidence.librelane import disconnected_pins
run, tag = Path(sys.argv[1]), sys.argv[2]
metrics = json.loads((run / "final/metrics.json").read_text())
CHECKS = ("route__drc_errors", "magic__drc_error__count", "klayout__drc_error__count", "design__lvs_error__count",
          "design__xor_difference__count", "antenna__violating__nets",
          "design__max_slew_violation__count", "design__max_cap_violation__count",
          "timing__setup_vio__count", "timing__hold_vio__count", "design__critical_disconnected_pin__count")
bad = {name: metrics[name] for name in CHECKS if metrics[name] != 0}
# The address bits the wrapper does not read have no load: of each port's addr, bits
# 63:32 of the struct, it reads 9:2 of obi_req_i and 4:2 of reg_req_i. A port is
# critical to LibreLane only when all its bits are unconnected, so a data bit left
# unconnected would pass above: the names must be exactly these. This is not the
# verdict of `mosaic physical-intent ppa`, which rejects any such pin without a
# waiver (docs/efpga.md, The wrapper and the macro as one block).
UNREAD = {f"obi_req_i[{b}]" for b in (32, 33, *range(42, 64))} | {f"reg_req_i[{b}]" for b in (32, 33, *range(37, 64))}
pins = set(disconnected_pins(run) or ())
if pins != UNREAD:
    bad["disconnected_pins"] = ",".join(sorted(pins ^ UNREAD)) or "no table"
print(f"BLOCK {'FAIL' if bad else 'PASS'} tag={tag} " + (" ".join(f"{k}={v}" for k, v in bad.items()) or f"checks={len(CHECKS) + 1} unread_address_bits={len(UNREAD)}")
      + f" setup_ns={metrics['timing__setup__ws']:.2f} hold_ns={metrics['timing__hold__ws']:.2f}")
sys.exit(1 if bad else 0)
EOF
