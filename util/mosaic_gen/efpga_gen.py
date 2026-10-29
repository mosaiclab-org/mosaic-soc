#!/usr/bin/env python3
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""efpga_gen.py — generate an eFPGA fabric preset with the pinned FABulous.

A preset is a FABulous fabric.csv under ``configs/efpga/``. This script copies
it over the fabric.csv of a fresh FABulous project, runs the fabric flow, and
optionally compiles user designs to bitstreams for that fabric (Yosys
``synth_fabulous``, ``nextpnr-generic --uarch fabulous``, ``bit_gen``). With
``--fabric`` instead of ``--preset`` it compiles the designs for a fabric it
generated before, such as the one in a SoC's bundle, and writes no fabric.
A design comes with its own top_wrapper (``--design``/``--wrapper``), or is
bound by the shell of the preset, a top_wrapper generated from its ports
(``--shell``; SHELL, shell_wrapper). With ``--fabric`` and ``--harden TILE``
it hardens tiles of that fabric for GF180MCU with FABulous's tile macro flow
instead (harden; `nix develop .#fabric`).

Everything is written under ``--out`` (a directory below ``build/``, never
committed), which is deleted first so that every file in it comes from this
run:

    proj/           the FABulous project: Fabric/eFPGA.v, Tile/, .FABulous/
    fabric.f        the Verilog files of the fabric core `eFPGA`, one per line
    efpga_inst.vh   the instance of the core, cut from eFPGA_top.v, for `include
    bitstream/      per design: <design>.json, .fasm (nextpnr's, then the
                    design's tag), .bin, the tools' logs, <design>.hex, the
                    words hw/efpga/mosaic_efpga.sv loads (see stream_words),
                    one per line, and <design>.unload.fasm, .unload.bin and
                    .unload.hex, the stream that removes it (see unload_fasm);
                    for --shell also <design>.ports.json and .shell.v, the
                    generated top_wrapper
    load_order/     registered.bin, the bitstream that only switches every
                    logic cell to its flip-flop output, and tagged.bin, the one
                    that sets every latch of a tag and its check (with --design)
    manifest.json   the sha256 of the inputs (preset, designs, wrappers, the
                    requirements file), the path of each tool that ran and the
                    version it reported (bit_gen reports none), the geometry,
                    the tag of each design, and the sha256 of every file in
                    fabric.f, of eFPGA_top.v, of efpga_inst.vh, of
                    registered.bin, of tagged.bin and of each .bin and .hex
    *.log           the output of FABulous
    home/           the HOME the tools ran with
    .efpga_gen      the mark by which this script recognises a directory it made

The script stops unless FABulous, Yosys and nextpnr-generic report the pinned
versions and bit_gen is on PATH (`nix develop .#efpga`), before it deletes
anything.
Standard library only: it runs under whatever python3 that shell is entered
from.

FABulous installs a PDK through ciel into $PDK_ROOT on any project command
once FAB_PDK is set, and `create-project` always sets it. No PDK is needed to
generate or simulate a fabric, so every tool runs without the inherited PDK*,
FAB_* and XDG_* variables, with HOME inside --out, and the FAB_PDK line is
removed from the project.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

FABULOUS = "2.2.0"  # util/efpga-requirements.txt pins the same release (tested)
# Tool -> (command that prints its version, the line that output must contain).
# Yosys and nextpnr come from flake.lock; bit_gen has no version flag and is
# covered by the hash-locked requirements file.
PINS = {
    "FABulous": (["FABulous", "--version"], rf"^FABulous CLI {re.escape(FABULOUS)}$"),
    "yosys": (["yosys", "-V"], r"^Yosys 0\.62 .*$"),
    "nextpnr-generic": (["nextpnr-generic", "--version"], r"^.*nextpnr-0\.9\)$"),
}
FIX = "nix develop .#efpga   (see docs/efpga.md)"
REPO = Path(__file__).resolve().parents[2]
LOCK = REPO / "util" / "efpga-requirements.txt"
STAMP = ".efpga_gen"  # holds the path of a directory this script made, and may delete
SYNC = 0xFAB0FAB1  # the word before the first frame of a bit_gen bitstream, and of a stream
UNLOAD = 0xFAB20000  # the word after it in an unload stream, with the tag in bits [15:0]
# The cells stream_words() was written for. FABULOUS_LC is the only one with a
# function: a LUT, whose output the feature <tile>.<bel>.FF takes from its
# flip-flop instead. The others pass or select signals; MUX8LUT can invert one
# only when its data inputs differ, which they do not while every cell output
# is 0 (the pad cell inverts its output enable on the way out).
CELLS = {"FABULOUS_LC", "MUX8LUT_frame_config_mux", "IO_1_bidirectional_frame_config_pass",
         "InPass4_frame_config_mux", "OutPass4_frame_config_mux", "Config_access"}


def tool_env(environ, home):
    """The environment of every tool: no PDK, no FABulous setting, own HOME.

    FABulous reads its FAB_* settings in any letter case, and Yosys writes its
    history under XDG_STATE_HOME before it falls back to HOME.
    """
    env = {k: v for k, v in environ.items()
           if not k.upper().startswith(("PDK", "FAB_", "XDG_"))}
    env["HOME"] = str(home)
    return env


def check_tools(env):
    """{tool: {version, path}} of the pinned tools; RuntimeError if one is not."""
    found = {}
    for name, (argv, pattern) in PINS.items():
        try:
            out = subprocess.run(argv, env=env, capture_output=True, text=True,
                                 stdin=subprocess.DEVNULL)
            text = (out.stdout + out.stderr).strip()
        except OSError:
            text = ""
        match = re.search(pattern, text, re.M)
        if not match:
            raise RuntimeError(
                f"{name}: need /{pattern}/, found {text.splitlines()[:1] or 'nothing'}. "
                f"fix: {FIX}"
            )
        found[name] = {"version": match.group(0)}
    found["bit_gen"] = {}
    for name, tool in found.items():
        tool["path"] = shutil.which(name, path=env.get("PATH"))
        if not tool["path"]:
            raise RuntimeError(f"{name}: not found. fix: {FIX}")
    return found


FABRIC_FIX = "nix develop .#fabric   (see docs/efpga.md)"
OPENROAD = "dcf36133a369abc8f3c5e5738cd4d82e4903c0e0"  # LibreLane 3.0.0's and 3.0.11's
GF180 = REPO / "flow" / "librelane" / "gf180mcu"  # make -C flow/librelane clone-pdk
# The metrics of a hardened tile that must all be 0. A metric the flow did not
# report fails the tile: not measured is not clean.
TILE_GATE = ("magic__drc_error__count", "klayout__drc_error__count",
             "design__lvs_error__count", "antenna__violating__nets")

# Run by FABulous's own interpreter (MOSAIC_FABULOUS_PYTHON): its tile macro
# flow on one tile, as its gen_tile_macro command runs it. That command's
# settings validate the PDK, which enables it through ciel, a download; here
# the settings are built without validation (model_construct) and hold the PDK
# clone. One worker: the flow's trials would otherwise run side by side. The
# tools it starts get MOSAIC_FABRIC_PYTHONPATH, LibreLane built for their own
# Python: its scripts inside OpenROAD import librelane. LibreLane runs its own
# helper scripts as `python3` with its interpreter's sys.path, so a `python3`
# that is this interpreter goes first on their PATH. FABulous runs Magic DRC
# only when KLayout's found errors; MOSAIC's signoff runs both, so here Magic
# runs whatever KLayout found.
# Yosys's loop check stays on: the switch matrices' loops close between tiles,
# not inside one (docs/efpga.md).
HARDEN = '''
import os
import sys
from pathlib import Path
from fabulous import fabulous_settings
from fabulous.fabric_definition.define import HDLType
from fabulous.fabulous_api import FABulous_API
from fabulous.fabric_generator.code_generator.code_generator_Verilog import VerilogCodeGenerator
from fabulous.fabric_generator.gds_generator.steps.tile_area_opt import OptMode
from fabulous.fabric_generator.gds_generator.steps.condition_magic_drc import ConditionalMagicDRC
from librelane.steps.magic import DRC
ConditionalMagicDRC.run = DRC.run
proj, tile, pdk, pdk_root, out = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4]), Path(sys.argv[5])
fabulous_settings._context_instance = fabulous_settings.FABulousSettings.model_construct(
    proj_dir=proj, proj_lang=HDLType.VERILOG, models_pack=proj / "Fabric" / "models_pack.v",
    pdk=pdk, pdk_root=pdk_root, max_worker=1)
os.environ["PYTHONPATH"] = os.environ["MOSAIC_FABRIC_PYTHONPATH"]
shims = out / "bin"
shims.mkdir(exist_ok=True)
(shims / "python3").write_text(f'#!/bin/sh\\nexec "{sys.executable}" "$@"\\n')
(shims / "python3").chmod(0o755)
os.environ["PATH"] = f"{shims}:{os.environ['PATH']}"
api = FABulous_API(VerilogCodeGenerator(), str(proj / "fabric.csv"))
pins = out / f"{tile}_io_pin_order.yaml"
api.gen_io_pin_order_config(api.getTile(tile, raises_on_miss=True), pins)
api.genTileMacro(proj / "Tile" / tile, pins, out, pdk, pdk_root, final_view=out / "final_views",
                 optimisation=OptMode.NO_OPT,
                 base_config_path=proj / "Tile" / "include" / "gds_config.yaml",
                 config_override_path=proj / "Tile" / tile / "gds_config.yaml")
'''


def _git_state(path):
    """HEAD and the changed files of a git checkout, to see that nothing wrote in it."""
    git = ["git", "-C", str(path)]
    return [subprocess.run(git + args, capture_output=True, text=True).stdout
            for args in (["rev-parse", "HEAD"], ["status", "--porcelain", "--ignored"])]


def harden(fabric, out, tiles, pdk_root=GF180, environ=None):
    """Each tile of ``tiles`` of a fabric this script generated, hardened for
    GF180MCU (gf180mcuD) by FABulous's tile macro flow, in ``out``: proj/, a copy
    of the fabric's project, which the flow runs in; macro/<tile>/ with the
    final views, metrics.json and the flow's log; and manifest.json, whose
    "tiles" holds the TILE_GATE metrics of each tile and whether all are 0. The
    fabric is not changed, and the PDK clone must not be either. A tile whose
    flow fails is recorded with the first line of the error, and the next one
    runs; one that touched a PDK, or changed the clone, stops them all."""
    fabric, out, pdk_root = Path(fabric).resolve(), Path(out).resolve(), Path(pdk_root).resolve()
    environ = os.environ if environ is None else environ
    if not (fabric / "manifest.json").is_file() or not (fabric / "proj").is_dir():
        raise RuntimeError(f"{fabric}: not a fabric this script generated")
    if fabric == out or fabric in out.parents or out in fabric.parents:
        raise RuntimeError(f"{out}: neither inside {fabric} nor around it")
    python = environ.get("MOSAIC_FABULOUS_PYTHON")
    if (environ.get("MOSAIC_FABRIC_SHELL") != "librelane-3.0.11" or not python
            or not environ.get("MOSAIC_FABRIC_PYTHONPATH")):
        raise RuntimeError(f"the tile flow runs in the fabric shell. fix: {FABRIC_FIX}")
    if not (pdk_root / "gf180mcuD" / "libs.tech" / "librelane").is_dir():
        raise RuntimeError(f"{pdk_root}: no gf180mcuD in it (make -C flow/librelane clone-pdk)")
    tools, env = _prepare(out, [fabric / "manifest.json"], environ)
    version = subprocess.run(["openroad", "-version"], env=env, capture_output=True, text=True,
                             stdin=subprocess.DEVNULL).stdout.strip()
    if OPENROAD not in version:
        raise RuntimeError(f"openroad: need {OPENROAD[:10]}, found {version[:40] or 'nothing'}. "
                           f"fix: {FABRIC_FIX}")
    tools["openroad"] = {"version": version, "path": shutil.which("openroad", path=env.get("PATH"))}
    shutil.copytree(fabric / "proj", out / "proj", symlinks=True)
    pdk_state, gates = _git_state(pdk_root), {}
    for tile in tiles:
        macro = out / "macro" / tile
        macro.mkdir(parents=True)
        error = None
        try:
            # In the project: FABulous resolves its files against the working
            # directory, whatever the context is given.
            _run([python, "-c", HARDEN, str(out / "proj"), tile, "gf180mcuD", str(pdk_root),
                  str(macro)], env, macro / "flow.log", cwd=out / "proj")
        except RuntimeError as err:
            if "touched a PDK" in str(err):
                raise
            error = str(err).splitlines()[0]
        if _git_state(pdk_root) != pdk_state:
            raise RuntimeError(f"{pdk_root}: the tile flow changed the PDK clone")
        if error:
            gates[tile] = {"clean": False, "error": error}
            continue
        metrics = json.loads((macro / "final_views" / "metrics.json").read_text())
        gate = {key: metrics.get(key) for key in TILE_GATE}
        gates[tile] = {"gate": gate, "clean": all(value == 0 for value in gate.values()),
                       "die_area_um2": metrics.get("design__die__area")}
    files = sorted(f for f in (out / "macro").rglob("*") if f.is_file())
    geometry = json.loads((fabric / "manifest.json").read_text())["geometry"]
    _manifest(out, [fabric / "manifest.json"], tools, geometry, {}, files,
              fabric={"path": str(fabric), "manifest_sha256": _sha256(fabric / "manifest.json")},
              pdk={"path": str(pdk_root), "rev": pdk_state[0].strip(), "variant": "gf180mcuD"},
              tiles=gates)
    return gates


def drop_pdk(env_file):
    """Remove the FAB_PDK* lines `FABulous create-project` writes."""
    kept = [l for l in env_file.read_text().splitlines()
            if not re.match(r"\s*(export\s+)?FAB_PDK", l, re.I)]
    env_file.write_text("\n".join(kept) + "\n")


def _run(argv, env, log, cwd=None):
    out = subprocess.run(argv, env=env, cwd=cwd, text=True, stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text(out.stdout)
    # What keeps a PDK download away from the user's files is tool_env; this
    # only reports one, after the fact (it would be under <out>/home/.ciel).
    if (Path(env["HOME"]) / ".ciel").exists() or re.search(
            r"Using PDK at|attempting to download", out.stdout):
        raise RuntimeError(f"{argv[0]} touched a PDK, see {log}")
    if out.returncode != 0:
        raise RuntimeError(
            f"{argv[0]} failed (exit {out.returncode}), see {log}:\n"
            + "\n".join(out.stdout.splitlines()[-20:])
        )


def _sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _frames(bitstream, rows):
    """The frames of a bit_gen bitstream, each [header, data words], and its
    end word; None if it is not one for a fabric of ``rows`` rows."""
    words = [int.from_bytes(bitstream[i:i + 4], "big") for i in range(0, len(bitstream), 4)]
    start, size = words.index(SYNC) + 1 if SYNC in words else len(words), 1 + rows
    if len(bitstream) % 4 or (len(words) - start - 1) % size or not words[-1] >> 20 & 1:
        return None
    return [words[i:i + size] for i in range(start, len(words) - 1, size)], words[-1]


def seal(head, frames, end):
    """A stream as mosaic_efpga's loader takes it: ``head`` (the sync word, and
    the tag word of an unload), each frame followed by its check word, the end
    word and the CRC. A check word, like the CRC, is the CRC-32 (zlib) of the
    words from the sync word on, check words left out: the loader writes a
    frame into the latches only once its check word matched."""
    words, crc = [], 0
    for part in [head, *frames, [end]]:
        words += part
        crc = zlib.crc32(b"".join(word.to_bytes(4, "big") for word in part), crc)
        if part is not head:
            words.append(crc)
    return words


def stream_words(bitstream, registered, tagged, rows, cells):
    """The words mosaic_efpga's loader takes for one bit_gen bitstream.

    A configuration is written one frame at a time, so the fabric passes
    through configurations nobody designed, and one of them can oscillate: a
    LUT whose function or inputs are half written can feed itself. Seen with
    tb/efpga/bus_regs.v, where both simulators stop at the 36th frame.

    ``registered`` is the bitstream that only switches each of the ``cells``
    logic cells to its flip-flop output, ``tagged`` the one that sets every
    latch of the tag and of its check (tag_features). The frames go out in
    four passes: the frames of ``registered`` alone; every frame of the
    design with those bits still set and the tag bits at 0; the frames that
    hold such a bit, as designed but for the tag; then the frames of the tag,
    as designed. No cell output is combinational while a function or a route
    is incomplete. The loader has put every flip-flop at 0 and keeps the clock
    stopped, so until the third pass every cell output is 0 and nothing inside
    the fabric can invert a signal. The tag comes last, so a fabric whose tag
    and check are set holds a whole design. Sealed by seal(), without
    bit_gen's header words.
    """
    design, mask, tags = (_frames(data, rows) for data in (bitstream, registered, tagged))
    if not design or not mask or not tags or not (
            [f[0] for f in design[0]] == [f[0] for f in mask[0]] == [f[0] for f in tags[0]]):
        raise RuntimeError("the bitstreams are not frames of the same fabric")
    (design, end), mask, tags = design, mask[0], tags[0]
    held = [i for i, frame in enumerate(mask) if any(frame[1:])]
    if sum(bin(word).count("1") for i in held for word in mask[i][1:]) != cells:
        raise RuntimeError("the bitstream of the flip-flop outputs does not set one bit per cell")
    if any(m & t for mf, tf in zip(mask, tags) for m, t in zip(mf[1:], tf[1:])):
        raise RuntimeError("a bit of the tag is also a flip-flop output selection")
    untagged = [d[:1] + [a & ~t for a, t in zip(d[1:], tf[1:])] for d, tf in zip(design, tags)]
    frames = [mask[i] for i in held]
    frames += [d[:1] + [a | b for a, b in zip(d[1:], m[1:])] for d, m in zip(untagged, mask)]
    frames += [untagged[i] for i in held]
    frames += [design[i] for i, tf in enumerate(tags) if any(tf[1:])]
    return seal([SYNC], frames, end)


def unload_words(bitstream, unload, registered, rows, tag):
    """The words that remove the design of ``bitstream`` (its unload_fasm in
    ``unload``) from the fabric: the tag word, then the frames that hold a
    flip-flop output selection, as the design has them but with every cell on
    its flip-flop, then every frame of ``unload``. The first part only removes
    paths; once every cell output comes from a flip-flop, a LUT function or an
    enable reaches nothing but a flip-flop, whose clock is stopped."""
    design, gone, mask = (_frames(data, rows) for data in (bitstream, unload, registered))
    if not design or not gone or not mask or not (
            [f[0] for f in design[0]] == [f[0] for f in gone[0]] == [f[0] for f in mask[0]]):
        raise RuntimeError("the bitstreams are not frames of the same fabric")
    if any(m & ~u for uf, mf in zip(gone[0], mask[0]) for u, m in zip(uf[1:], mf[1:])):
        raise RuntimeError("the unload does not put every cell on its flip-flop")
    first = [d[:1] + [a | b for a, b in zip(d[1:], m[1:])]
             for d, m in zip(design[0], mask[0]) if any(m[1:])]
    return seal([SYNC, UNLOAD | tag], first + gone[0], gone[1])


def unload_fasm(fasm, flops):
    """The configuration that takes a design out of the fabric safely.

    Clearing a design that has run can oscillate: its flip-flops hold values,
    and a half-cleared LUT or route can then feed itself. This is the design
    with every one of the ``flops`` logic cells switched to its flip-flop
    output, its LUT functions and reset values at 0, and each flip-flop's
    enable and reset back on their constants (LUT4AB tiles: VCC and GND).
    Nothing else changes, the routes and the tag included. Written after
    unload_words' first part, once every cell output comes from its
    flip-flop, none of these bits reaches anything but a flip-flop, whose
    clock is stopped. A pulse then puts every flip-flop of the logic cells at
    0, and with every LUT and every such flip-flop at 0 the loader can clear.
    """
    cells = tuple(f"{cell[0]}.{cell[3]}." for cell in flops)
    kept = [line for line in fasm.splitlines()
            if not (line.startswith(cells) and line.split(".", 2)[2].startswith(
                ("INIT[", "FF", "SET_NORESET")) or re.search(r"\.L[A-H]_(EN|SR)$", line))]
    return "".join(f"{line}\n" for line in kept + [f"{cell}FF" for cell in cells])


def tag_features(inst, bels):
    """The FASM features of the 16 latches of a design's tag and of the 32 of
    its check, which hold the complement of the tag twice: the configuration
    outputs Config_accessC, A_config_C and B_config_C of efpga_inst.vh, bit k
    of each its own latch, found through the cell prefixes of bel.v2.txt
    (``bels``). They drive nothing inside the fabric; the wrapper reads them."""
    found = {}
    for tile, bel, prefix in re.findall(r"^BelBegin,(X\d+Y\d+),(\w+),Config_access,(\w+)$",
                                        bels, re.M):
        for bit in range(4):
            port = re.search(rf"\.Tile_{tile}_{prefix}C_bit{bit}\((\w+)\[(\d+)\]\)", inst)
            if port:
                found[port.group(1), int(port.group(2))] = f"{tile}.{bel}.C_bit{bit}"
    try:
        return [[found[vector, k] for k in range(16)]
                for vector in ("Config_accessC", "A_config_C", "B_config_C")]
    except KeyError:
        raise RuntimeError("the fabric lacks 16 configuration outputs in each of Config_accessC, "
                           "A_config_C and B_config_C for a tag and its check") from None


def tag_lines(tag, features):
    """The FASM lines that set ``tag`` and its check (the features of tag_features)."""
    tag_bits, *checks = features
    return [bit for k, bit in enumerate(tag_bits) if tag >> k & 1] + [
        bit for check in checks for k, bit in enumerate(check) if not tag >> k & 1]


# The shell (docs/efpga.md): the ports a design bound by a generated
# top_wrapper may have, each with its direction and width. A design has any of
# them and no other. addr is the word address (byte address [9:2]), be its
# byte enables; io_* are the pads, io_oeb low driving one, as many as the
# design binds of the preset's two per row (width None); task_* are the
# fabric's slot of the TDU: task_id of a task, under task_valid until
# task_done, with task_result.
SHELL = {
    "clk": ("input", 1), "rst_n": ("input", 1), "valid": ("input", 1), "we": ("input", 1),
    "be": ("input", 4), "addr": ("input", 8), "wdata": ("input", 32),
    "ack": ("output", 1), "rdata": ("output", 32),
    "io_in": ("input", None), "io_out": ("output", None), "io_oeb": ("output", None),
    "task_valid": ("input", 1), "task_id": ("input", 16),
    "task_done": ("output", 1), "task_result": ("output", 32),
}
CTL = (["valid", "we", "rst_n"] + [f"be[{k}]" for k in range(4)] + [f"addr[{k}]" for k in range(8)]
       + ["task_valid"] + [f"task_id[{k}]" for k in range(16)])


def _shell_pins(geometry):
    """(port bit) -> (BEL, cell, pin) of the shell, as hw/efpga/mosaic_efpga.sv
    drives the edges: row g of the east edge is the RAM_IO tile at
    Y<rows - g>, whose input n of 16 is RAM2FAB_D<n // 4>.O<n % 4> (wdata[8g +:
    8], then ctl[8g +: 8], ctl = CTL) and output n FAB2RAM_D<n // 4>.I<n % 4>
    (rdata[8g +: 8], then task_result[8g +: 8]); ack and task_done are
    FAB2RAM_C.I0 and I1 of row 0. Pad k is the W_IO BEL B (k even) or A of the
    tile at Y<rows - k // 2>."""
    east, rows = f"X{geometry['cols'] - 1}Y", geometry["rows"]
    out = "OutPass4_frame_config_mux"
    pins = {"clk": ("", "Global_Clock", "CLK"), "ack": (f"{east}{rows}.FAB2RAM_C", out, "I0"),
            "task_done": (f"{east}{rows}.FAB2RAM_C", out, "I1")}
    for bit in range(32):
        row, n = divmod(bit, 8)
        pins[f"wdata[{bit}]"] = (f"{east}{rows - row}.RAM2FAB_D{n // 4}",
                                 "InPass4_frame_config_mux", f"O{n % 4}")
        pins[f"rdata[{bit}]"] = (f"{east}{rows - row}.FAB2RAM_D{n // 4}", out, f"I{n % 4}")
        pins[f"task_result[{bit}]"] = (f"{east}{rows - row}.FAB2RAM_D{2 + n // 4}", out,
                                       f"I{n % 4}")
    for bit, name in enumerate(CTL):
        row, n = divmod(bit, 8)
        pins[name] = (f"{east}{rows - row}.RAM2FAB_D{2 + n // 4}",
                      "InPass4_frame_config_mux", f"O{n % 4}")
    for pad in range(2 * rows):
        bel = f"X0Y{rows - pad // 2}.{'AB'[pad % 2 == 0]}"
        for port, pin in (("io_in", "O"), ("io_out", "I"), ("io_oeb", "T")):
            pins[f"{port}[{pad}]"] = (bel, "IO_1_bidirectional_frame_config_pass", pin)
    return pins


def shell_wrapper(module, ports, geometry):
    """The top_wrapper that binds ``module``, whose ``ports`` are {name:
    (direction, width)}, to the edges of the fabric through the shell. Without
    ack, the shell holds it low (the wrapper's timeout answers), and task_done
    too (no task ends; the TDU parks it); without io_oeb, it holds every pad
    released, and every pad beyond its width: an unbound output of the fabric
    would follow whatever its default route carries."""
    pads = 2 * geometry["rows"]
    for name, (direction, width) in ports.items():
        expected = SHELL.get(name, (None, 0))
        if expected[0] != direction or (width != expected[1] if expected[1] else width > pads):
            raise RuntimeError(
                f"{module}: port {name} ({direction}, {width} bits) is not in the shell: "
                + ", ".join(f"{d} {n}[{(w or pads) - 1}:0]" for n, (d, w) in SHELL.items()))
    if ports.get("io_out", (0, 0))[1] != ports.get("io_oeb", (0, 0))[1]:
        raise RuntimeError(f"{module}: io_out and io_oeb go together, as wide")
    pins, cells = _shell_pins(geometry), {}
    for name, (_, width) in ports.items():
        for bit in range(width):
            signal = f"{name}[{bit}]" if width > 1 else name
            bel, cell, pin = pins[f"{name}[{bit}]" if signal not in pins else signal]
            cells.setdefault((bel, cell), []).append(f".{pin}({signal})")
    held = [(name, "1'b0") for name in ("ack", "task_done") if name not in ports]
    held += [(f"io_oeb[{pad}]", "1'b1") for pad in range(ports.get("io_oeb", (0, 0))[1], pads)]
    for signal, value in held:
        bel, cell, pin = pins[signal]
        cells.setdefault((bel, cell), []).append(f".{pin}({value})")
    lines = ["// Generated by util/mosaic_gen/efpga_gen.py (shell_wrapper). Do not edit.",
             "`default_nettype none", "module top_wrapper;"]
    lines += [f"    wire {f'[{width - 1}:0] ' if width > 1 else ''}{name};"
              for name, (_, width) in ports.items()]
    for (bel, cell), connections in sorted(cells.items()):
        attribute = f'(* keep, BEL="{bel}" *)' if bel else "(* keep *)"
        instance = re.sub(r"\W", "_", bel) if bel else "clk_i"
        lines.append(f"    {attribute} {cell} {instance} ({', '.join(connections)});")
    lines.append(f"    {module} top_i ({', '.join(f'.{n}({n})' for n in ports)});")
    lines += ["endmodule", "`default_nettype wire", ""]
    return "\n".join(lines)


def _prepare(out, sources, environ):
    """Check the inputs and the tools, then give ``out`` its first contents."""
    for path in sources:
        if not path.is_file() or out in path.parents:
            raise RuntimeError(f"{path}: not a file outside {out}")
    stamp, home = out / STAMP, out / "home"
    if out.exists() and any(out.iterdir()) and not (
            stamp.is_file() and stamp.read_text() == str(out)):
        raise RuntimeError(f"refusing to delete {out}: this script did not make it")
    environ = os.environ if environ is None else environ
    with tempfile.TemporaryDirectory() as tmp:  # a refusal creates and deletes nothing
        tools = check_tools(tool_env(environ, tmp))
    if out.exists():
        shutil.rmtree(out)
    home.mkdir(parents=True)
    stamp.write_text(str(out))
    return tools, tool_env(environ, home)


def _designs(designs):
    """(design, wrapper or None) pairs, resolved; the design files, wrappers included."""
    designs = [(Path(d).resolve(), w and Path(w).resolve()) for d, w in designs]
    if len({design.stem for design, _ in designs}) != len(designs):
        raise RuntimeError("two designs have the same file name")
    return designs, [f for pair in designs for f in pair if f]


def _manifest(out, sources, tools, geometry, tags, files, **extra):
    manifest = {
        "inputs": {os.path.relpath(p, REPO): _sha256(p) for p in sources + [LOCK]},
        "tools": tools,
        "geometry": geometry,
        "tags": tags,
        "outputs": {str(f.relative_to(out)): _sha256(f) for f in files},
        **extra,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def generate(preset, out, designs=(), environ=None):
    """Generate the fabric of ``preset`` into ``out``, and one bitstream for
    each (design, wrapper) pair of ``designs``; a wrapper None means the shell
    (shell_wrapper)."""
    out, preset = Path(out).resolve(), Path(preset).resolve()
    designs, inputs = _designs(designs)
    tools, env = _prepare(out, [preset, *inputs], environ)

    proj = out / "proj"
    _run(["FABulous", "create-project", str(proj)], env, out / "create-project.log")
    drop_pdk(proj / ".FABulous" / ".env")
    shutil.copyfile(preset, proj / "fabric.csv")
    _run(["FABulous", "-p", str(proj), "run", "load_fabric; run_fab"], env, out / "run_fab.log")

    top = proj / "Fabric" / "eFPGA_top.v"
    geometry = {
        key: int(re.search(rf"parameter {name}=(\d+)", top.read_text()).group(1))
        for key, name in (("rows", "NumberOfRows"), ("cols", "NumberOfCols"),
                          ("frame_bits_per_row", "FrameBitsPerRow"),
                          ("max_frames_per_col", "MaxFramesPerCol"))
    }
    # The fabric core only: the tiles the preset names, the cell models and
    # eFPGA.v. Not eFPGA_top.v and FABulous's own configuration logic. W_IO/
    # and RAM_IO/ each carry a Config_access.v: the same module, laid out
    # differently, so a repeated file name must be the same code.
    text = re.sub(r"#.*", "", preset.read_text())
    tiles = re.findall(r"^(?:Supert|T)ile,\./(.+)/[^/]+\.csv", text, re.M)
    if len(tiles) != len(re.findall(r"^(?:Supert|T)ile,", text, re.M)):
        raise RuntimeError(f"{preset}: a Tile line is not `Tile,./<dir>/<name>.csv`")
    files, seen = [], {}
    for path in sorted(v for tile in tiles for v in (proj / tile).rglob("*.v")):
        code = re.sub(r"//.*|\s+", "", path.read_text())
        if path.name not in seen:
            seen[path.name] = code
            files.append(path)
        elif seen[path.name] != code:
            raise RuntimeError(f"{path}: another tile has a different {path.name}")
    files += [proj / "Fabric" / "models_pack.v", proj / "Fabric" / "eFPGA.v"]
    (out / "fabric.f").write_text("".join(f"{f}\n" for f in files))
    # The instance of the core, port map included, as FABulous wrote it: what
    # includes it (mosaic_efpga, the fabric bench) cannot drift from the fabric.
    inst = re.search(r"^eFPGA eFPGA_inst \(.*?^\);\n", top.read_text(), re.M | re.S)
    if not inst:
        raise RuntimeError(f"{top}: no instance of eFPGA")
    (out / "efpga_inst.vh").write_text(inst.group(0))
    files += [top, out / "efpga_inst.vh"]  # hashed, not in fabric.f

    tags = _compile(proj, geometry, inst.group(0), out, designs, env, files, preset)
    return _manifest(out, [preset, *inputs], tools, geometry, tags, files)


def compile_designs(fabric, out, designs, environ=None):
    """One bitstream for each design of ``designs``, as generate() makes them,
    for the fabric an earlier run made in ``fabric``: for instance the one in a
    SoC's bundle (soc_fabric). ``out`` then holds bitstream/, load_order/ and a
    manifest.json that names that fabric."""
    fabric, out = Path(fabric).resolve(), Path(out).resolve()
    designs, inputs = _designs(designs)
    if not (fabric / "manifest.json").is_file() or not (fabric / "proj").is_dir():
        raise RuntimeError(f"{fabric}: not a fabric this script generated")
    if fabric == out or fabric in out.parents or out in fabric.parents:
        raise RuntimeError(f"{out}: neither inside {fabric} nor around it")
    tools, env = _prepare(out, inputs, environ)
    geometry = json.loads((fabric / "manifest.json").read_text())["geometry"]
    files = []
    tags = _compile(fabric / "proj", geometry, (fabric / "efpga_inst.vh").read_text(), out,
                    designs, env, files, fabric)
    return _manifest(out, inputs, tools, geometry, tags, files, fabric={
        "path": str(fabric), "manifest_sha256": _sha256(fabric / "manifest.json")})


def _compile(proj, geometry, inst, out, designs, env, files, label):
    """Compile ``designs`` for the fabric of ``proj`` into ``out``; returns their
    tags, and appends what it writes to ``files``."""
    tags = {}
    if not designs:
        return tags
    spec = str(proj / ".FABulous" / "bitStreamSpec.bin")
    cells = [line.split(",") for line in
             (proj / ".FABulous" / "bel.txt").read_text().splitlines()
             if line.count(",") >= 4 and not line.startswith("#")]
    if {cell[4] for cell in cells} - CELLS:
        raise RuntimeError(f"{label}: no loading order for the cells "
                           f"{sorted({cell[4] for cell in cells} - CELLS)}, see stream_words")
    order = out / "load_order"
    order.mkdir()
    flops = [cell for cell in cells if cell[4] == "FABULOUS_LC"]
    (order / "registered.fasm").write_text("".join(
        f"{cell[0]}.{cell[3]}.FF\n" for cell in flops))
    features = tag_features(inst, (proj / ".FABulous" / "bel.v2.txt").read_text())
    (order / "tagged.fasm").write_text("".join(f"{bit}\n" for bits in features for bit in bits))
    for name in ("registered", "tagged"):
        _run(["bit_gen", "-genBitstream", str(order / f"{name}.fasm"), spec,
              str(order / f"{name}.bin")], env, order / f"{name}.bit_gen.log")
        files.append(order / f"{name}.bin")
    (out / "bitstream").mkdir()
    for design, wrapper in designs:
        stem = out / "bitstream" / design.stem
        if wrapper is None:  # the shell: from the ports of the module named after the file
            _run(["yosys", "-q", "-p", f"hierarchy -top {design.stem}; proc; "
                  f"write_json {stem}.ports.json", str(design)], env, Path(f"{stem}.ports.log"))
            module = json.loads(Path(f"{stem}.ports.json").read_text())["modules"][design.stem]
            wrapper = Path(f"{stem}.shell.v")
            wrapper.write_text(shell_wrapper(design.stem, {
                name: (port["direction"], len(port["bits"]))
                for name, port in module["ports"].items()}, geometry))
            files.append(wrapper)
        _run(["yosys", "-q", "-p",
              f"synth_fabulous -top top_wrapper -json {stem}.json "
              f"-extra-plib {proj}/user_design/custom_prims.v",
              str(wrapper), str(design)], env, Path(f"{stem}.yosys.log"))
        _run(["nextpnr-generic", "--uarch", "fabulous", "--json", f"{stem}.json",
              "-o", f"fasm={stem}.fasm"], {**env, "FAB_ROOT": str(proj)},
             Path(f"{stem}.nextpnr.log"))
        # The tag names the design in the fabric's own latches, where the
        # loader finds it after a reset; an unload stream must carry it.
        fasm = Path(f"{stem}.fasm").read_text()
        tag = int(hashlib.sha256(fasm.encode()).hexdigest()[:4], 16) or 1
        if set(fasm.split()) & {bit for bits in features for bit in bits} or tag in tags.values():
            raise RuntimeError(f"{design}: uses a bit of the tag, or another design has its tag")
        tags[design.stem] = tag
        fasm += f"# the tag of this design, {tag:#06x}, and its check\n" + "".join(
            f"{line}\n" for line in tag_lines(tag, features))
        Path(f"{stem}.fasm").write_text(fasm)
        Path(f"{stem}.unload.fasm").write_text(unload_fasm(fasm, flops))
        for name in (stem, f"{stem}.unload"):
            _run(["bit_gen", "-genBitstream", f"{name}.fasm", spec, f"{name}.bin"],
                 env, Path(f"{name}.bit_gen.log"))
        bitstream, registered = Path(f"{stem}.bin").read_bytes(), (order / "registered.bin").read_bytes()
        words = stream_words(bitstream, registered, (order / "tagged.bin").read_bytes(),
                             geometry["rows"], len(flops))
        unload = unload_words(bitstream, Path(f"{stem}.unload.bin").read_bytes(), registered,
                              geometry["rows"], tag)
        for name, stream in ((stem, words), (f"{stem}.unload", unload)):
            Path(f"{name}.hex").write_text("".join(f"{word:08x}\n" for word in stream))
        files += [Path(f"{stem}{ext}") for ext in (".bin", ".hex", ".unload.bin", ".unload.hex")]
    return tags


def preset_pads(preset):
    """The pads of a preset (configs/efpga/<preset>.csv): two per W_IO tile of
    its west edge."""
    text = re.sub(r"#.*", "", Path(preset).read_text())
    grid = text.split("FabricBegin", 1)[1].split("FabricEnd", 1)[0]
    return 2 * sum(line.split(",")[0].strip() == "W_IO" for line in grid.splitlines())


def soc_fabric(preset, out):
    """The fabric of the preset ``configs/efpga/<preset>.csv`` for a generated
    SoC (``soc.efpga``), in ``out`` inside its bundle; mcu_gen calls this.

    A fabric already there is kept: the bundle's key covers the preset, this
    script and the requirements file, so the same key means the same fabric,
    and manifest.json is written last. ``out``/soc.f lists the Verilog of the
    fabric core and of hw/efpga/mosaic_efpga.sv, which the SoC compiles.
    Returns the manifest.
    """
    out = Path(out).resolve()
    if not (out / "manifest.json").is_file():
        gen = [sys.executable, str(Path(__file__).resolve()),
               "--preset", str(REPO / "configs" / "efpga" / f"{preset}.csv"), "--out", str(out)]
        if shutil.which("FABulous") is None:  # looked up, not run
            gen = ["nix", "develop", f"{REPO}#efpga", "--option", "warn-dirty", "false",
                   "--command", "python3", *gen[1:]]
        if subprocess.run(gen, cwd=REPO).returncode:
            raise RuntimeError(f"efpga_gen: the fabric of preset {preset!r} was not generated")
    manifest = json.loads((out / "manifest.json").read_text())
    files = (out / "fabric.f").read_text().split()
    if not all(f.startswith(f"{out}/") for f in files):  # generated before a move
        raise RuntimeError(f"{out}: a fabric generated at another path; delete it to "
                           "generate it again")
    files.append(str(REPO / "hw" / "efpga" / "mosaic_efpga.sv"))
    (out / "soc.f").write_text("".join(f"{f}\n" for f in files))
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    fabric = parser.add_mutually_exclusive_group(required=True)
    fabric.add_argument("--preset", help="configs/efpga/<name>.csv: generate its fabric")
    fabric.add_argument("--fabric", help="the directory of a fabric this script generated "
                        "(a SoC's: <bundle>/generated/efpga): compile the designs for it")
    parser.add_argument("--out", required=True, help="output directory (deleted first)")
    parser.add_argument("--design", action="append", default=[],
                        help="user design (Verilog) to compile to a bitstream; repeatable")
    parser.add_argument("--wrapper", action="append", default=[],
                        help="its top_wrapper, which binds it to the preset; one per --design")
    parser.add_argument("--harden", action="append", default=[], metavar="TILE",
                        help="with --fabric: harden this tile type for GF180MCU with FABulous's "
                        "tile macro flow (`nix develop .#fabric`); repeatable")
    parser.add_argument("--shell", action="append", default=[],
                        help="user design bound by the shell (docs/efpga.md): a module named "
                        "after its file, whose ports are among SHELL's; repeatable")
    args = parser.parse_args()
    if len(args.design) != len(args.wrapper):
        parser.error("--design and --wrapper go together")
    designs = list(zip(args.design, args.wrapper)) + [(shell, None) for shell in args.shell]
    if args.harden and (not args.fabric or designs):
        parser.error("--harden takes --fabric and no design")
    try:
        if args.harden:
            results = harden(args.fabric, args.out, args.harden)
            for tile, result in results.items():
                print(f"efpga_gen: {tile} {'clean' if result['clean'] else 'NOT CLEAN'} "
                      + (f"{result['gate']} die {result['die_area_um2']} um2" if "gate" in result
                         else result["error"]))
            return 0 if all(result["clean"] for result in results.values()) else 1
        if args.fabric:
            manifest = compile_designs(args.fabric, args.out, designs)
        else:
            manifest = generate(args.preset, args.out, designs)
    except (RuntimeError, OSError) as err:
        print(f"ERROR: {err}", file=sys.stderr)
        return 1
    print(f"efpga_gen: {args.out}/manifest.json  "
          f"{manifest['geometry']['rows']} rows x {manifest['geometry']['cols']} columns, "
          f"{len(manifest['outputs'])} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
