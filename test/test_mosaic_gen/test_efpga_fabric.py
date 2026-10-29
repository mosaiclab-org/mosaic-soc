# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""The eFPGA fabric generator runs only the pinned FABulous, and never near a PDK.

FABulous installs a PDK through ciel into $PDK_ROOT on any project command once
FAB_PDK is set, and `create-project` always sets it: a run with the shell's own
environment downloaded 782 MB into a PDK checkout. efpga_gen.py therefore runs
every tool without the PDK variables and with its own HOME, and removes the
FAB_PDK line from the project. The first version of these tests checked the two
helpers and not that generate() uses them: a fake FABulous now records what it
is really run with.

The FABulous release is named in three places (the hash-locked requirements
file, the script that writes it, efpga_gen.FABULOUS), which must agree.

Nothing here runs FABulous. The simulated check is the sweep step
`efpga_fabric` (tb/efpga/run.sh).
"""

import json
import os
import re
import sys
import zlib

import pytest

from harness.core import REPO_ROOT

sys.path.append(str(REPO_ROOT / "util" / "mosaic_gen"))

import efpga_gen  # noqa: E402

REQUIREMENTS = REPO_ROOT / "util/efpga-requirements.txt"

# What the pinned tools print (nextpnr on stderr); bit_gen has no version flag.
PINNED = {
    "FABulous": (1, "FABulous CLI 2.2.0"),
    "yosys": (1, "Yosys 0.62 (git sha1 7326bb7d, clang++ 21.1.2 -fPIC -O3)"),
    "nextpnr-generic": (2, '"nextpnr-generic" -- Next Generation Place and Route '
                           "(Version nextpnr-refs/tags/nextpnr-0.9)"),
    "bit_gen": (1, ""),
}


def _fake_tools(bin_dir, **replaced):
    for name, (stream, line) in {**PINNED, **replaced}.items():
        tool = bin_dir / name
        tool.write_text(f"#!/bin/sh\necho '{line}' >&{stream}\n")
        tool.chmod(0o755)
    return {"PATH": str(bin_dir)}


# FABulous reads FAB_* in any letter case; Yosys prefers XDG_STATE_HOME to HOME.
HOSTILE = {"HOME": "/home/user", "PDK_ROOT": "/pdk", "PDK": "ihp-sg13g2",
           "PDKPATH": "/pdk/ihp-sg13g2", "FAB_PDK": "ihp-sg13g2", "FAB_PDK_ROOT": "/pdk",
           "fab_pdk": "ihp-sg13g2", "Fab_Pdk_Root": "/pdk", "pdk_root": "/pdk",
           "XDG_STATE_HOME": "/home/user/.local/state"}

# What generate() needs from FABulous, and a record of how each call was made.
FAKE_FABULOUS = r"""#!/bin/sh
{ echo "CALL $*"; env; } >> "$RECORD"
case "$1" in
  --version) echo "FABulous CLI 2.2.0" ;;
  create-project)
    mkdir -p "$2/.FABulous" "$2/Fabric"
    printf "FAB_PROJ_LANG='verilog'\\nFAB_PDK='ihp-sg13g2'\\n" > "$2/.FABulous/.env" ;;
  -p)
    echo "CALL env-file $(tr '\\n' ' ' < "$2/.FABulous/.env")" >> "$RECORD"
    for name in NumberOfRows NumberOfCols FrameBitsPerRow MaxFramesPerCol; do
      echo "parameter $name=4,"
    done > "$2/Fabric/eFPGA_top.v"
    printf 'eFPGA eFPGA_inst (\n);\n' >> "$2/Fabric/eFPGA_top.v"
    echo "X1Y1,X1,Y1,A,MYSTERY_CELL,x" > "$2/.FABulous/bel.txt"
    touch "$2/Fabric/eFPGA.v" "$2/Fabric/models_pack.v" ;;
esac
"""


def test_the_tools_run_without_a_pdk_and_with_their_own_home(tmp_path):
    env = efpga_gen.tool_env({"PATH": "/bin", **HOSTILE}, tmp_path)
    assert env == {"PATH": "/bin", "HOME": str(tmp_path)}


def test_the_fab_pdk_line_of_a_new_project_is_removed(tmp_path):
    env_file = tmp_path / ".env"
    env_file.write_text("FAB_PROJ_LANG='verilog'\nFAB_PDK='ihp-sg13g2'\n"
                        "export fab_pdk_root=/pdk\nFAB_PROJ_VERSION='2.2.0'\n")
    efpga_gen.drop_pdk(env_file)
    assert env_file.read_text() == "FAB_PROJ_LANG='verilog'\nFAB_PROJ_VERSION='2.2.0'\n"


def test_generate_runs_fabulous_without_a_pdk(tmp_path):
    bin_dir, out, record = tmp_path / "bin", tmp_path / "out", tmp_path / "record"
    bin_dir.mkdir()
    _fake_tools(bin_dir)
    (bin_dir / "FABulous").write_text(FAKE_FABULOUS)
    environ = {**HOSTILE, "RECORD": str(record),
               "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}
    manifest = efpga_gen.generate(REPO_ROOT / "configs/efpga/small.csv", out, environ=environ)

    calls = record.read_text().split("CALL ")[1:]
    assert [call.split()[0] for call in calls] == ["--version", "create-project", "-p", "env-file"]
    for call in calls[:3]:
        names = [line.split("=")[0] for line in call.splitlines()[1:]]
        assert not [n for n in names if n.upper().startswith(("PDK", "FAB_", "XDG_"))]
        assert "HOME=/home/user" not in call.splitlines()
    for call in calls[1:3]:  # the two project commands
        assert f"HOME={out}/home" in call.splitlines()
    assert "FAB_PDK" not in calls[3]  # the project's .env when the fabric flow starts
    assert manifest["geometry"]["rows"] == 4
    assert json.loads((out / "manifest.json").read_text()) == manifest


@pytest.mark.parametrize("script", [
    "echo 'INFO | Using PDK at /pdk/ihp-sg13g2'",
    "echo 'not found locally, attempting to download'",
    'mkdir "$HOME/.ciel"',
])
def test_a_tool_that_touches_a_pdk_fails_the_run(tmp_path, script):
    tool = tmp_path / "tool"
    tool.write_text(f"#!/bin/sh\n{script}\n")
    tool.chmod(0o755)
    env = {"PATH": os.environ["PATH"], "HOME": str(tmp_path)}
    with pytest.raises(RuntimeError, match="touched a PDK"):
        efpga_gen._run([str(tool)], env, tmp_path / "tool.log")


def test_the_pinned_tools_are_accepted(tmp_path):
    found = efpga_gen.check_tools(_fake_tools(tmp_path))
    assert {name: tool.get("version") for name, tool in found.items()} == {
        name: line or None for name, (_, line) in PINNED.items()}
    assert all(tool["path"] == str(tmp_path / name) for name, tool in found.items())


@pytest.mark.parametrize("tool, prints", [
    ("FABulous", "FABulous CLI 2.1.0"),
    ("yosys", "Yosys 0.53 (git sha1 53c22ab7, g++ 15.1.1 -fPIC -O3)"),  # this host's
    ("nextpnr-generic", "(Version nextpnr-0.8)"),
])
def test_a_tool_of_another_version_is_refused(tmp_path, tool, prints):
    env = _fake_tools(tmp_path, **{tool: (1, prints)})
    with pytest.raises(RuntimeError, match=rf"^{tool}: .*nix develop \.#efpga"):
        efpga_gen.check_tools(env)


@pytest.mark.parametrize("tool", sorted(PINNED))
def test_a_missing_tool_is_refused(tmp_path, tool):
    env = _fake_tools(tmp_path)
    (tmp_path / tool).unlink()
    with pytest.raises(RuntimeError, match=rf"^{tool}: .*nix develop \.#efpga"):
        efpga_gen.check_tools(env)


@pytest.mark.parametrize("stamp", [None, "", "/some/other/directory"])
def test_a_directory_the_generator_did_not_make_is_not_deleted(tmp_path, stamp):
    (tmp_path / "keep.txt").write_text("not a fabric bundle")
    if stamp is not None:
        (tmp_path / efpga_gen.STAMP).write_text(stamp)  # a copied stamp names another place
    with pytest.raises(RuntimeError, match="refusing to delete"):
        efpga_gen.generate(REPO_ROOT / "configs/efpga/small.csv", tmp_path, environ={})
    assert (tmp_path / "keep.txt").exists()


def test_a_refused_run_leaves_the_previous_bundle(tmp_path):
    (tmp_path / efpga_gen.STAMP).write_text(str(tmp_path))
    (tmp_path / "manifest.json").write_text("{}")
    for out in (tmp_path, tmp_path / "fresh"):
        with pytest.raises(RuntimeError, match="FABulous: .*nix develop"):
            efpga_gen.generate(REPO_ROOT / "configs/efpga/small.csv", out,
                               environ={"PATH": str(tmp_path / "no-tools")})
    assert sorted(p.name for p in tmp_path.iterdir()) == [efpga_gen.STAMP, "manifest.json"]


def test_an_input_that_is_missing_or_inside_the_output_is_refused(tmp_path):
    inside = tmp_path / "out" / "preset.csv"
    inside.parent.mkdir()
    inside.write_text("FabricBegin\nFabricEnd\n")
    for preset in (tmp_path / "missing.csv", inside):
        with pytest.raises(RuntimeError, match="not a file outside"):
            efpga_gen.generate(preset, tmp_path / "out", environ={})
    assert inside.exists()


def test_the_requirements_file_locks_the_pinned_fabulous_by_hash():
    lines = [line for line in REQUIREMENTS.read_text().replace("\\\n", " ").splitlines()
             if line and not line.startswith("#")]
    assert len(lines) > 50
    for line in lines:
        assert "==" in line and "--hash=sha256:" in line, line
        assert "git+" not in line and " @ " not in line, line
    pin = f"fabulous-fpga=={efpga_gen.FABULOUS} "
    assert [line for line in lines if line.startswith(pin)]
    assert pin in (REPO_ROOT / "util/efpga-lock.sh").read_text()


def test_the_efpga_shell_installs_only_from_the_hash_locked_file():
    flake = (REPO_ROOT / "flake.nix").read_text()
    assert "inherit sim efpga fabric;" in flake
    assert '--no-build --python "$efpga_dir/venv/bin/python" --require-hashes "$efpga_req"' in flake
    assert 'efpga_req="$PWD/util/efpga-requirements.txt"' in flake
    # Of the venv only the wrapper directory is on PATH, and the wrapper drops
    # the PDK variables and does not pass a PYTHONPATH on.
    assert 'export PATH="$efpga_dir/bin:$PATH"' in flake
    assert flake.count("export PATH=") == 2  # this one and the sim shell's .venv
    assert "unset PDK_ROOT PDK PDKPATH FAB_PDK FAB_PDK_ROOT" in flake
    assert "PYTHONPATH= exec" in flake


def _bitstream(frames):
    """A bit_gen bitstream of one-row frames: {header: data word}."""
    words = [0x00AAFF01, 1, 0, 0, efpga_gen.SYNC]
    for header, data in frames.items():
        words += [header, data]
    return b"".join(word.to_bytes(4, "big") for word in words + [1 << 20])


def _sealed(head, frames, end):
    """What the loader expects: a check word after each frame and the end word,
    each the CRC-32 of the words from the sync word on, check words left out."""
    plain, words = list(head), list(head)
    for part in frames + [[end]]:
        plain += part
        words += part + [zlib.crc32(b"".join(w.to_bytes(4, "big") for w in plain))]
    return words


def test_the_stream_keeps_every_cell_registered_until_the_third_pass_and_the_tag_to_the_last():
    design = _bitstream({0x1: 0xA0, 0x2: 0x0B, 0x4: 0x3C})
    registered = _bitstream({0x1: 0x00, 0x2: 0xF0, 0x4: 0x00})
    tagged = _bitstream({0x1: 0x00, 0x2: 0x00, 0x4: 0x30})
    words = efpga_gen.stream_words(design, registered, tagged, rows=1, cells=4)
    assert words == _sealed([efpga_gen.SYNC], [
        [0x2, 0xF0],                            # the flip-flop outputs alone
        [0x1, 0xA0], [0x2, 0xFB], [0x4, 0x0C],  # the design, those bits still set, no tag
        [0x2, 0x0B],                            # as designed
        [0x4, 0x3C]], 1 << 20)                  # the tag


def test_a_tag_bit_that_selects_a_flip_flop_is_refused():
    with pytest.raises(RuntimeError, match="also a flip-flop output selection"):
        efpga_gen.stream_words(_bitstream({0x1: 0x1}), _bitstream({0x1: 0x1}),
                               _bitstream({0x1: 0x1}), rows=1, cells=1)


def test_the_unload_registers_every_cell_before_any_function_changes():
    design = _bitstream({0x1: 0xA0, 0x2: 0x0B, 0x4: 0x3C})
    unload = _bitstream({0x1: 0x80, 0x2: 0xF0, 0x4: 0x3C})  # INIT bits gone, every cell registered
    registered = _bitstream({0x1: 0x00, 0x2: 0xF0, 0x4: 0x00})
    words = efpga_gen.unload_words(design, unload, registered, rows=1, tag=0x1234)
    assert words == _sealed([efpga_gen.SYNC, 0xFAB21234], [
        [0x2, 0xFB],                            # the frame of the flip-flop outputs, the rest as designed
        [0x1, 0x80], [0x2, 0xF0], [0x4, 0x3C]], 1 << 20)
    with pytest.raises(RuntimeError, match="every cell on its flip-flop"):
        efpga_gen.unload_words(design, design, registered, rows=1, tag=1)


def test_the_unload_keeps_the_routes_and_puts_every_cell_on_its_flip_flop():
    fasm = ("# routing for net 'x'\n"
            "X1Y1.A.INIT[15:0] = 16'b1010101000000000\n"
            "X1Y1.A.FF\n"
            "X1Y1.A.IOmux\n"
            "X1Y1.B.SET_NORESET\n"
            "X1Y1.J_EN_END0.LA_EN\n"
            "X1Y1.J_SR_END0.LB_SR\n"
            "X1Y1.LA_O.E1BEG0\n"
            "X3Y4.L.C_bit1\n")
    flops = [["X1Y1", "X1", "Y1", bel, "FABULOUS_LC", ""] for bel in "AB"]
    assert efpga_gen.unload_fasm(fasm, flops).splitlines() == [
        "# routing for net 'x'", "X1Y1.A.IOmux", "X1Y1.LA_O.E1BEG0", "X3Y4.L.C_bit1",
        "X1Y1.A.FF", "X1Y1.B.FF"]


def test_the_tag_and_its_check_are_the_configuration_outputs_of_the_edges():
    inst = "".join(f"    .Tile_X3Y{4 - k // 4}_Config_accessC_bit{k % 4}(Config_accessC[{k}]),\n"
                   f"    .Tile_X0Y{4 - k // 4}_A_config_C_bit{k % 4}(A_config_C[{k}]),\n"
                   f"    .Tile_X0Y{4 - k // 4}_B_config_C_bit{k % 4}(B_config_C[{k}]),\n"
                   for k in range(16))
    bels = "".join(f"BelBegin,X3Y{y},L,Config_access,Config_access\n"
                   f"BelBegin,X0Y{y},C,Config_access,A_config_\n"
                   f"BelBegin,X0Y{y},D,Config_access,B_config_\n" for y in range(1, 5))
    tag, a, b = efpga_gen.tag_features(inst, bels)
    assert tag[0] == "X3Y4.L.C_bit0" and tag[5] == "X3Y3.L.C_bit1" and tag[15] == "X3Y1.L.C_bit3"
    assert a[0] == "X0Y4.C.C_bit0" and b[15] == "X0Y1.D.C_bit3"
    lines = efpga_gen.tag_lines(0x0001, (tag, a, b))
    assert lines == [tag[0]] + a[1:] + b[1:]  # the tag, then its complement twice
    with pytest.raises(RuntimeError, match="lacks 16 configuration outputs"):
        efpga_gen.tag_features(inst, bels.replace("BelBegin,X0Y1,D,Config_access,B_config_\n", ""))


@pytest.mark.parametrize("design, registered", [
    (_bitstream({0x1: 1, 0x2: 2, 0x4: 3}), _bitstream({0x1: 0, 0x2: 0})),          # a frame short
    (_bitstream({0x1: 1, 0x2: 2, 0x4: 3}), _bitstream({0x1: 0, 0x4: 0, 0x2: 0})),  # another order
    (b"\0" * 16, b"\0" * 16),                                                      # no sync word
    (b"", b""),
])
def test_a_stream_is_refused_when_the_two_bitstreams_differ_in_shape(design, registered):
    with pytest.raises(RuntimeError, match="not frames of the same fabric"):
        efpga_gen.stream_words(design, registered, registered, rows=1, cells=0)


def test_a_stream_is_refused_when_a_cell_would_stay_combinational():
    design = _bitstream({0x1: 0xA0, 0x2: 0x0B})
    with pytest.raises(RuntimeError, match="one bit per cell"):
        efpga_gen.stream_words(design, _bitstream({0x1: 0x00, 0x2: 0x70}), design, rows=1, cells=4)


def test_two_designs_of_the_same_name_are_refused_before_anything_runs(tmp_path):
    for name in ("a/d.v", "b/d.v", "w.v"):
        (tmp_path / name).parent.mkdir(exist_ok=True)
        (tmp_path / name).write_text("")
    pairs = [(tmp_path / "a/d.v", tmp_path / "w.v"), (tmp_path / "b/d.v", tmp_path / "w.v")]
    with pytest.raises(RuntimeError, match="same file name"):
        efpga_gen.generate(REPO_ROOT / "configs/efpga/small.csv", tmp_path / "out", pairs, environ={})
    assert not (tmp_path / "out").exists()


def test_a_fabric_with_a_cell_the_frame_order_does_not_cover_gets_no_bitstream(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _fake_tools(bin_dir)
    (bin_dir / "FABulous").write_text(FAKE_FABULOUS)
    for name in ("d.v", "w.v"):
        (tmp_path / name).write_text("")
    environ = {**HOSTILE, "RECORD": str(tmp_path / "record"),
               "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"}
    with pytest.raises(RuntimeError, match="MYSTERY_CELL"):
        efpga_gen.generate(REPO_ROOT / "configs/efpga/small.csv", tmp_path / "out",
                           [(tmp_path / "d.v", tmp_path / "w.v")], environ=environ)
    assert not (tmp_path / "out" / "bitstream").exists()


# ── the shell: a top_wrapper generated from a design's ports ─────────

SMALL = {"rows": 4, "cols": 4, "frame_bits_per_row": 32, "max_frames_per_col": 20}
MEDIUM = {"rows": 8, "cols": 8, "frame_bits_per_row": 32, "max_frames_per_col": 20}


def _all_ports(geometry):
    """Every port of the shell, the pads as wide as the preset has them."""
    return {name: (direction, width or 2 * geometry["rows"])
            for name, (direction, width) in efpga_gen.SHELL.items()}
INSTANCE = re.compile(r'\(\* keep(?:, BEL="([^"]*)")? \*\) (\w+) \w+ \((.*)\);')


def _pins(wrapper_text, rename=None):
    """{signal bit: (BEL, cell, pin)} of a top_wrapper's cell instances."""
    pins = {}
    for bel, cell, connections in INSTANCE.findall(wrapper_text):
        for pin, signal in re.findall(r"\.(\w+)\(([^)]+)\)", connections):
            if signal[0].isdigit():  # a constant the shell holds
                continue
            signal = (rename or {}).get(signal, signal)
            assert signal not in pins, signal
            pins[signal] = (bel, cell, pin)
    return pins


def test_the_shell_binds_every_signal_where_the_tested_wrappers_do():
    """bus_regs_wrapper.v and counter8_en_wrapper.v were written by hand and
    simulated (efpga_wrapper, efpga_soc): the shell puts each of their
    signals on the same cell and pin."""
    bus = _pins((REPO_ROOT / "tb/efpga/bus_regs_wrapper.v").read_text(), {"addr0": "addr[0]"})
    assert len(bus) == 70  # wdata, rdata, valid, we, rst_n, addr0, ack, clk
    shell = _pins(efpga_gen.shell_wrapper("bus_regs", {
        "clk": ("input", 1), "rst_n": ("input", 1), "valid": ("input", 1), "we": ("input", 1),
        "addr": ("input", 8), "wdata": ("input", 32), "ack": ("output", 1),
        "rdata": ("output", 32)}, SMALL))
    assert {signal: shell[signal] for signal in bus} == bus
    assert len(set(shell.values())) == len(shell)  # one pin per signal

    pads = _pins((REPO_ROOT / "tb/efpga/counter8_en_wrapper.v").read_text())
    assert len(pads) == 25
    assert _pins(efpga_gen.shell_wrapper("counter8_en", {
        "clk": ("input", 1), "io_in": ("input", 8), "io_out": ("output", 8),
        "io_oeb": ("output", 8)}, SMALL)) == pads


@pytest.mark.parametrize("geometry", [SMALL, MEDIUM])
def test_the_whole_shell_uses_each_pin_once(geometry):
    ports = _all_ports(geometry)
    shell = _pins(efpga_gen.shell_wrapper("all", ports, geometry))
    assert len(shell) == sum(width for _, width in ports.values())
    assert len(set(shell.values())) == len(shell)
    assert "all top_i (.clk(clk), .rst_n(rst_n)" in efpga_gen.shell_wrapper("all", ports, geometry)


def test_the_shell_holds_ack_low_and_the_pads_released_when_unbound():
    held = efpga_gen.shell_wrapper("leds", {"clk": ("input", 1)}, SMALL)
    assert held.count(".T(1'b1)") == 8
    assert held.count(".I0(1'b0)") == 1 and '"X3Y4.FAB2RAM_C"' in held
    bound = efpga_gen.shell_wrapper("all", _all_ports(SMALL), SMALL)
    assert "1'b" not in bound
    # On the 16 pads of `medium`, a design that drives 8 leaves the other 8 released.
    narrow = efpga_gen.shell_wrapper("leds", {"io_out": ("output", 8), "io_oeb": ("output", 8)},
                                     MEDIUM)
    assert narrow.count(".T(1'b1)") == 8 and narrow.count(".T(io_oeb[") == 8
    assert '"X0Y8.B"' in narrow and '"X0Y1.A"' in narrow  # pad 0, pad 15


def test_the_task_ports_are_where_the_wrapper_drives_them():
    """hw/efpga/mosaic_efpga.sv puts task_valid on ctl[15] and task_id on
    ctl[31:16] of the east edge, reads task_result from the second byte of
    each row's outputs and task_done from FAB2RAM_C.I1 of the first row."""
    pins = _pins(efpga_gen.shell_wrapper("all", _all_ports(SMALL), SMALL))
    assert pins["task_valid"] == ("X3Y3.RAM2FAB_D3", "InPass4_frame_config_mux", "O3")
    assert pins["task_id[0]"] == ("X3Y2.RAM2FAB_D2", "InPass4_frame_config_mux", "O0")
    assert pins["task_id[15]"] == ("X3Y1.RAM2FAB_D3", "InPass4_frame_config_mux", "O3")
    assert pins["task_result[0]"] == ("X3Y4.FAB2RAM_D2", "OutPass4_frame_config_mux", "I0")
    assert pins["task_result[31]"] == ("X3Y1.FAB2RAM_D3", "OutPass4_frame_config_mux", "I3")
    assert pins["task_done"] == ("X3Y4.FAB2RAM_C", "OutPass4_frame_config_mux", "I1")
    wrapper = (REPO_ROOT / "hw/efpga/mosaic_efpga.sv").read_text()
    assert "{task_q[31:16], t_valid_q, u_addr_q, u_be_q, ~user_rst_q, u_we_q," in wrapper
    assert "assign result_x[8*g+:8] = FAB2RAM_D_O[16*g+8+:8];" in wrapper
    assert "done_q <= fab_en & FAB2RAM_C_O[1];" in wrapper
    # Without task_done the shell holds it low: no task ends.
    held = efpga_gen.shell_wrapper("leds", {"clk": ("input", 1)}, SMALL)
    assert held.count(".I1(1'b0)") == 1


@pytest.mark.parametrize("ports, error", [
    ({"irq": ("output", 1)}, "port irq .* is not in the shell"),
    ({"addr": ("input", 30)}, "port addr .* is not in the shell"),
    ({"ack": ("input", 1)}, "port ack .* is not in the shell"),
    ({"io_out": ("output", 8)}, "io_out and io_oeb go together"),
    ({"io_out": ("output", 8), "io_oeb": ("output", 4)}, "io_out and io_oeb go together"),
    ({"io_in": ("input", 9)}, "port io_in .* is not in the shell"),
])
def test_a_port_outside_the_shell_is_refused(ports, error):
    with pytest.raises(RuntimeError, match=f"^mine: {error}"):
        efpga_gen.shell_wrapper("mine", ports, SMALL)


def test_designs_compile_only_for_a_fabric_of_this_script(tmp_path):
    design = tmp_path / "mine.v"
    design.write_text("module mine; endmodule\n")
    with pytest.raises(RuntimeError, match="not a fabric this script generated"):
        efpga_gen.compile_designs(tmp_path / "nothing", tmp_path / "out", [(design, None)])
    fabric = tmp_path / "fabric"
    (fabric / "proj").mkdir(parents=True)
    (fabric / "manifest.json").write_text("{}")
    with pytest.raises(RuntimeError, match="neither inside"):
        efpga_gen.compile_designs(fabric, fabric / "out", [(design, None)], environ={})


# ── hardening tiles for GF180MCU (harden; `nix develop .#fabric`) ──────


def _fabric_dir(tmp_path):
    fabric = tmp_path / "fabric"
    (fabric / "proj").mkdir(parents=True)
    (fabric / "manifest.json").write_text(json.dumps({"geometry": SMALL}))
    return fabric


def test_the_tile_flow_runs_only_in_the_fabric_shell(tmp_path):
    with pytest.raises(RuntimeError, match=r"fabric shell. fix: nix develop \.#fabric"):
        efpga_gen.harden(_fabric_dir(tmp_path), tmp_path / "out", ["LUT4AB"], environ={})
    assert not (tmp_path / "out").exists()


def test_the_tile_flow_refuses_a_directory_it_did_not_generate_or_no_pdk(tmp_path):
    shell = {"MOSAIC_FABRIC_SHELL": "librelane-3.0.11", "MOSAIC_FABULOUS_PYTHON": "python",
             "MOSAIC_FABRIC_PYTHONPATH": "site-packages"}
    with pytest.raises(RuntimeError, match="not a fabric this script generated"):
        efpga_gen.harden(tmp_path, tmp_path / "out", ["LUT4AB"], environ=shell)
    with pytest.raises(RuntimeError, match="no gf180mcuD in it"):
        efpga_gen.harden(_fabric_dir(tmp_path), tmp_path / "out", ["LUT4AB"],
                         pdk_root=tmp_path / "nopdk", environ=shell)
    assert not (tmp_path / "out").exists()


def test_the_tile_flow_gets_the_pdk_itself_and_skips_only_the_loop_check():
    """FABulous's settings enable a PDK through ciel (a download) whenever
    FAB_PDK names a family ciel knows: the driver keeps that check out of the
    context and hands the clone to the flow. The loop check is the only one
    turned off, by the decision of 2026-10-29 (docs/efpga.md)."""
    driver = efpga_gen.HARDEN
    compile(driver, "harden", "exec")  # it runs under another interpreter: check it parses
    assert "FABulousSettings.model_construct(" in driver  # no validation: no ciel
    assert "init_context" not in driver and "FAB_PDK" not in driver and "ciel." not in driver
    assert re.findall(r'custom_config_overrides=(\{.*?\})', driver) == [
        '{"ERROR_ON_SYNTH_CHECKS": False}']
    assert "ConditionalMagicDRC.run = DRC.run" in driver  # Magic DRC always runs
    assert efpga_gen.TILE_GATE == ("magic__drc_error__count", "klayout__drc_error__count",
                                   "design__lvs_error__count", "antenna__violating__nets")


def test_the_fabric_shell_takes_librelane_3_0_11_on_the_signoff_nix_eda():
    flake = (REPO_ROOT / "flake.nix").read_text()
    assert 'librelane-fabric.url = "github:librelane/librelane/3.0.11";' in flake
    assert 'librelane-fabric.inputs.nix-eda.follows = "librelane/nix-eda";' in flake
    assert 'librelane.url = "github:librelane/librelane/3.0.0";' in flake  # signoff unchanged
    assert "unset PDK_ROOT PDK PDKPATH FAB_PDK FAB_PDK_ROOT" in flake
    lock = json.loads((REPO_ROOT / "flake.lock").read_text())["nodes"]
    assert lock["librelane-fabric"]["inputs"]["nix-eda"] == ["librelane", "nix-eda"]
    assert lock["librelane-fabric"]["locked"]["rev"].startswith("33ab64861c55")
