# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""soc.efpga: the key that puts an eFPGA fabric in the generated SoC.

What is checked here, without FABulous: the key is validated, parsed and
carried to the templates, the software headers and the build manifest, and
the fabric step of efpga_gen keeps a fabric it already made. The fabric in a
simulated SoC is the sweep step `efpga_soc` (tb/mosaic_soc/run_efpga.sh).
"""

import binascii
import json
import re
import struct
import subprocess
import sys
from pathlib import Path

import hjson
import pytest
import yaml
from mako.template import Template

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "util" / "mosaic_gen"))

import efpga_gen  # noqa: E402
import pack_flash  # noqa: E402
import software_gen  # noqa: E402
from build_manifest import resolved_manifest  # noqa: E402
from core_registry import (  # noqa: E402
    EFPGA_WINDOW_BASE,
    VALID_EFPGA_PRESETS,
    target_capability_errors,
    validate_soc_config,
)
from mosaic_config import MosaicConfig, load_mosaic_yaml, mosaic_to_xheep_kwargs  # noqa: E402

DEMO = REPO / "configs" / "mosaic_efpga_demo.yaml"
PLAIN = REPO / "configs" / "mosaic_wake_demo.yaml"
# What mcu_gen adds from the generated fabric's manifest.json.
GEOMETRY = {"rows": 4, "cols": 4, "frame_bits_per_row": 32, "max_frames_per_col": 20}


def _demo(efpga=None):
    cfg = yaml.safe_load(DEMO.read_text())
    if efpga is not None:
        cfg["soc"]["efpga"] = efpga
    return cfg


def _render(path, kwargs):
    return Template(filename=str(REPO / path), strict_undefined=True).render_unicode(**kwargs)


def _kwargs(path, geometry=True):
    kwargs = mosaic_to_xheep_kwargs(load_mosaic_yaml(path))
    efpga = kwargs["xheep"].get_extension("efpga")
    if efpga and geometry:
        kwargs["xheep"].add_extension("efpga", {**efpga, **GEOMETRY})
    return kwargs


# ── the key ──────────────────────────────────────────────────────────


def test_the_presets_are_the_files_under_configs_efpga():
    assert VALID_EFPGA_PRESETS == {p.stem for p in (REPO / "configs" / "efpga").glob("*.csv")}


def test_the_demo_validates_and_omitting_the_key_is_valid():
    assert validate_soc_config(_demo()) == []
    cfg = _demo()
    del cfg["soc"]["efpga"]
    assert validate_soc_config(cfg) == []
    assert MosaicConfig().efpga is None


@pytest.mark.parametrize(
    "value, error",
    [
        ({"preset": "big"}, "soc.efpga.preset 'big' not in ['medium', 'small']"),
        ({}, "soc.efpga.preset None not in ['medium', 'small']"),
        ({"preset": "small", "pads": 8}, "soc.efpga.pads: unknown key"),
        ("small", "soc.efpga must be a mapping"),
        ({"preset": ["small"]}, "soc.efpga.preset ['small'] not in ['medium', 'small']"),
    ],
)
def test_a_wrong_value_is_refused_by_name(value, error):
    assert error in validate_soc_config(_demo(value))


@pytest.mark.parametrize("bus", ["log", "floonoc"])
def test_the_log_and_floonoc_tier_has_the_slave(bus):
    path = REPO / "configs" / f"mosaic_efpga_demo_{bus}.yaml"
    assert validate_soc_config(yaml.safe_load(path.read_text())) == []
    kwargs = _kwargs(path)
    package = _render("hw/mosaic_soc/include/mosaic_soc_pkg.sv.tpl", kwargs)
    xbar = _render("hw/mosaic_soc/system_xbar.sv.tpl", kwargs)
    assert "NONMEM_TIER_NSLAVE = 6;" in package
    assert "'{ idx: NONMEM_EFPGA_WIN_IDX, start_addr: EFPGA_WIN_START_ADDRESS" in package
    assert re.search(r"slave_req_o\[EFPGA_WIN_IDX\][^\n]*= nonmem_\w+\[5\]", xbar)
    assert bus == "log" or "1-to-6 demux" in xbar


def test_a_tapeout_target_leaves_the_fabric_to_the_physical_flow():
    """The tapeout rules do not name the key (the user's decision,
    2026-10-20); the physical flow refuses a design with a fabric
    (test_the_physical_flow_refuses_a_design_with_an_efpga)."""
    soc = _demo()["soc"]
    soc["target"] = "tapeout"
    assert not any("efpga" in e for e in target_capability_errors(soc))


# ── what the generator makes of it ───────────────────────────────────


def test_the_registers_are_an_always_on_peripheral_only_with_the_key():
    def ao(path):
        domain = _kwargs(path)["xheep"].get_base_peripheral_domain()
        return {p.get_name(): p.get_address() for p in domain.get_peripherals()}

    with_fabric, without = ao(DEMO), ao(PLAIN)
    assert with_fabric.pop("efpga") == 0x000C_0000
    assert "efpga" not in without
    assert with_fabric == without  # no other peripheral moves


def test_the_software_headers_and_the_hjson_agree():
    hjson_offset = int(hjson.loads((REPO / "configs" / "general.hjson").read_text())
                       ["ao_peripherals"]["efpga"]["offset"], 0)
    assert software_gen.EFPGA_OFFSET == hjson_offset
    with_fabric, without = load_mosaic_yaml(DEMO), load_mosaic_yaml(PLAIN)
    for writer in (software_gen._memory_map_header, software_gen._assembler_memory_map):
        assert "EFPGA" not in writer(without, 0x3000, 0x200)
        text = writer(with_fabric, 0x3000, 0x200)
        assert re.search(r"EFPGA_BASE 0x200C0000u?\n", text)
        assert re.search(rf"EFPGA_WINDOW_BASE 0x{EFPGA_WINDOW_BASE:08X}u?\n", text)


def test_the_templates_put_the_wrapper_in_the_soc():
    kwargs = _kwargs(DEMO)
    package = _render("hw/mosaic_soc/include/mosaic_soc_pkg.sv.tpl", kwargs)
    bus = _render("hw/mosaic_soc/system_bus.sv.tpl", kwargs)
    ao = _render("hw/mosaic_soc/ao_peripheral_subsystem.sv.tpl", kwargs)
    top = _render("hw/mosaic_soc/mosaic_soc.sv.tpl", kwargs)

    banks = kwargs["xheep"].memory_ss().ram_numbanks()
    assert f"SYSTEM_XBAR_NSLAVE = {banks + 6};" in package
    assert f"EFPGA_WIN_IDX = 32'd{banks + 5};" in package
    assert "EFPGA_WIN_START_ADDRESS = 32'h50000000;" in package
    assert "'{ idx: EFPGA_WIN_IDX, start_addr: EFPGA_WIN_START_ADDRESS" in package
    assert "assign efpga_slave_req_o = int_slave_req[mosaic_soc_pkg::EFPGA_WIN_IDX];" in bus
    assert "assign efpga_req_o = ao_peripheral_slv_req[mosaic_soc_pkg::EFPGA_IDX];" in ao
    instance = re.search(r"mosaic_efpga #\((.*?)\) mosaic_efpga_i \((.*?)\);", top, re.S)
    assert instance, "no mosaic_efpga instance"
    assert re.findall(r"\.(\w+)\((\d+)\)", instance.group(1)) == [
        ("ROWS", "4"), ("COLS", "4"), ("FBPR", "32"), ("MFPC", "20")]
    for port in (".reg_req_i(efpga_reg_req)", ".obi_req_i(efpga_win_req)",
                 ".rst_ni(rst_n_sync && debug_reset_n)"):
        assert port in instance.group(2)
    assert ".efpga_slave_req_o(efpga_win_req)" in top
    assert ".efpga_req_o(efpga_reg_req)" in top


def test_the_fabric_is_the_tdu_slot_after_the_harts():
    kwargs = _kwargs(DEMO)
    package = _render("hw/mosaic_soc/include/mosaic_soc_pkg.sv.tpl", kwargs)
    ao = _render("hw/mosaic_soc/ao_peripheral_subsystem.sv.tpl", kwargs)
    top = _render("hw/mosaic_soc/mosaic_soc.sv.tpl", kwargs)
    assert "EFPGA_TDU_SLOT = NUM_HARTS;" in package and "TDU_SLOTS = NUM_HARTS + 1;" in package
    assert ".NUM_HARTS(mosaic_soc_pkg::TDU_SLOTS)" in ao
    assert ".hw_pop_req_i   (tdu_hw_pop_req_i)" in ao
    assert "assign tdu_slot_sleep = {efpga_task_sleep, core_sleep};" in top
    assert "assign core_wake = tdu_slot_wake[NRHARTS-1:0];" in top
    instance = re.search(r"mosaic_efpga #\(.*?\) mosaic_efpga_i \((.*?)\);", top, re.S).group(1)
    for port in (".task_wake_i(efpga_task_wake)", ".task_pop_o(efpga_task_pop)",
                 ".task_pop_data_i(efpga_task_pop_data)"):
        assert port in instance
    header = software_gen._memory_map_header(load_mosaic_yaml(DEMO), 0x3000, 0x200)
    assert "#define MOSAIC_EFPGA_TDU_SLOT 3u\n" in header  # harts 0 to 2
    # Without the key the TDU has a slot per hart and pops for none.
    ao = _render("hw/mosaic_soc/ao_peripheral_subsystem.sv.tpl", _kwargs(PLAIN))
    assert ".NUM_HARTS(mosaic_soc_pkg::NUM_HARTS)" in ao and ".hw_pop_req_i   (1'b0)" in ao


@pytest.mark.parametrize("harts, refused", [(15, False), (16, True)])
def test_with_the_tdu_the_fabric_leaves_slots_for_15_harts(harts, refused):
    cfg = _demo()
    cfg["soc"]["cores"][2]["count"] = harts - 2
    errors = [e for e in validate_soc_config(cfg) if "TDU's last worker slot" in e]
    assert bool(errors) == refused


def test_without_the_key_the_templates_name_no_efpga():
    kwargs = _kwargs(PLAIN)
    for path in ("hw/mosaic_soc/include/mosaic_soc_pkg.sv.tpl", "hw/mosaic_soc/system_bus.sv.tpl",
                 "hw/mosaic_soc/ao_peripheral_subsystem.sv.tpl", "hw/mosaic_soc/mosaic_soc.sv.tpl"):
        assert "efpga" not in _render(path, kwargs).lower(), path


def test_the_manifest_compiles_the_fabric_from_the_bundle(tmp_path):
    def manifest(path):
        return resolved_manifest(
            kwargs=_kwargs(path), config_path=path, base_config=REPO / "configs" / "general.hjson",
            pads_cfg=REPO / "configs" / "pad_cfg.py", repo_root=REPO, output_root=tmp_path,
            generated_files=[])

    with_fabric = manifest(DEMO)
    efpga = Path(with_fabric["generated_root"]) / "efpga"
    assert "mosaic_efpga" in with_fabric["build"]["flags"]
    assert str(efpga) in with_fabric["build"]["include_roots"]
    assert with_fabric["build"]["ordered_filelist_fallbacks"] == [str(efpga / "soc.f")]
    assert with_fabric["resolved"]["platform"]["efpga"] == {"preset": "small"}
    without = manifest(PLAIN)
    assert "mosaic_efpga" not in without["build"]["flags"]
    assert without["build"]["ordered_filelist_fallbacks"] == []
    assert without["resolved"]["platform"]["efpga"] is None


# ── the fabric step ──────────────────────────────────────────────────


def test_a_fabric_already_in_the_bundle_is_kept(tmp_path, monkeypatch):
    out = tmp_path / "efpga"
    out.mkdir()
    (out / "fabric.f").write_text(f"{out}/proj/a.v\n{out}/proj/eFPGA.v\n")
    (out / "manifest.json").write_text('{"geometry": {"rows": 4}}')
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: pytest.fail("generated again"))
    assert efpga_gen.soc_fabric("small", out) == {"geometry": {"rows": 4}}
    assert (out / "soc.f").read_text().splitlines() == [
        f"{out}/proj/a.v", f"{out}/proj/eFPGA.v", str(REPO / "hw" / "efpga" / "mosaic_efpga.sv")]


def test_a_fabric_generated_at_another_path_is_not_kept(tmp_path, monkeypatch):
    """A bundle moved with the checkout: its fabric.f names the old place."""
    out = tmp_path / "efpga"
    out.mkdir()
    (out / "fabric.f").write_text("/old/place/efpga/proj/a.v\n")
    (out / "manifest.json").write_text('{"geometry": {"rows": 4}}')
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: pytest.fail("generated again"))
    with pytest.raises(RuntimeError, match="generated at another path"):
        efpga_gen.soc_fabric("small", out)


def test_a_base_config_without_the_efpga_peripheral_is_refused():
    with pytest.raises(RuntimeError, match="needs the always-on peripheral `efpga`"):
        mosaic_to_xheep_kwargs(load_mosaic_yaml(DEMO), base_config="configs/minimal.hjson")


def test_the_physical_flow_refuses_a_design_with_an_efpga(tmp_path):
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "ll_gen_filelist_efpga", REPO / "flow" / "librelane" / "scripts" / "gen_filelist.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({"build": {"flags": ["mosaic_efpga"]}}))
    with pytest.raises(SystemExit, match="eFPGA"):
        module.collect(REPO, manifest, tmp_path)


def test_a_missing_fabric_is_generated_through_the_efpga_shell(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(efpga_gen.shutil, "which", lambda name: None)
    monkeypatch.setattr(subprocess, "run",
                        lambda cmd, **k: calls.append(cmd) or subprocess.CompletedProcess(cmd, 1))
    with pytest.raises(RuntimeError, match="preset 'small' was not generated"):
        efpga_gen.soc_fabric("small", tmp_path / "efpga")
    (cmd,) = calls
    assert cmd[:3] == ["nix", "develop", f"{REPO}#efpga"]
    assert "FABulous" not in cmd  # only efpga_gen.py runs it
    assert cmd[cmd.index("--preset") + 1] == str(REPO / "configs" / "efpga" / "small.csv")


# ── the bitstream in the flash image ─────────────────────────────────


def _packed(tmp_path, config, stream=None, unload=None):
    artifacts = software_gen.generate_software_artifacts(load_mosaic_yaml(config), tmp_path / "sw")
    images = {}
    for image in json.loads(artifacts.boot_manifest.read_text())["images"]:
        path = tmp_path / f"image_{image['image_id']}.bin"
        path.write_bytes(bytes([image["image_id"]]) * 8)
        images[int(image["image_id"])] = path
    output = tmp_path / "flash.bin"
    return artifacts, pack_flash.pack(artifacts.boot_manifest, images, output, stream, unload), output


def _hex(path, words):
    path.write_text("".join(f"{word:08x}\n" for word in words))
    return path


def test_the_boot_manifest_names_the_efpga_only_with_the_key(tmp_path):
    def efpga(config):
        artifacts = software_gen.generate_software_artifacts(load_mosaic_yaml(config), tmp_path / config.stem)
        assert "#define MOSAIC_DEPLOYMENT_VERSION 2u" in artifacts.deployment_header.read_text()
        return json.loads(artifacts.boot_manifest.read_text()).get("efpga")

    assert efpga(DEMO) == {"preset": "small", "registers": "0x200C0000", "window": "0x50000000"}
    assert efpga(PLAIN) is None


def test_the_unload_then_the_stream_are_the_last_entries_of_the_table(tmp_path):
    words, unload_words = [0xFAB0FAB1, 0x12345678, 0xFFFFFFFF], [0xFAB0FAB1, 0xFAB2ABCD]
    _, deployment, output = _packed(tmp_path, DEMO, _hex(tmp_path / "d.hex", words),
                                    _hex(tmp_path / "d.unload.hex", unload_words))

    raw = output.read_bytes()
    header = pack_flash.HEADER.unpack_from(raw)
    assert header[1] == pack_flash.VERSION == 2
    count = header[3]
    entries = [pack_flash.ENTRY.unpack_from(raw, pack_flash.HEADER.size + k * pack_flash.ENTRY.size)
               for k in range(count)]
    assert [entry[0] for entry in entries] == (
        [pack_flash.KIND_COPY] * (count - 2) + [pack_flash.KIND_EFPGA_UNLOAD, pack_flash.KIND_EFPGA])
    for (kind, destination, size, offset, crc), expected in zip(entries[-2:], (unload_words, words)):
        blob = struct.pack(f"<{len(expected)}I", *expected)
        assert (destination, size, raw[offset:offset + size]) == (0x200C_0000, len(blob), blob)
        assert crc == binascii.crc32(blob) & 0xFFFF_FFFF
        assert offset % 0x1000 == 0
    assert entries[-1][3] > entries[-2][3] > max(e[3] for e in entries[:-2])
    assert deployment["efpga_bitstream"]["flash_offset"] == f"0x{entries[-1][3]:08X}"
    assert deployment["efpga_unload"]["source"] == "d.unload.hex"


def test_the_clock_a_design_was_timed_at_comes_between_its_unload_and_its_stream(tmp_path):
    artifacts = software_gen.generate_software_artifacts(load_mosaic_yaml(DEMO), tmp_path / "sw")
    images = {}
    for image in json.loads(artifacts.boot_manifest.read_text())["images"]:
        path = tmp_path / f"image_{image['image_id']}.bin"
        path.write_bytes(bytes([image["image_id"]]) * 8)
        images[int(image["image_id"])] = path
    stream, unload = _hex(tmp_path / "d.hex", [0xFAB0FAB1]), _hex(tmp_path / "d.unload.hex", [0xFAB0FAB1])
    output = tmp_path / "flash.bin"
    deployment = pack_flash.pack(artifacts.boot_manifest, images, output, stream, unload, 13)

    raw = output.read_bytes()
    count = pack_flash.HEADER.unpack_from(raw)[3]
    entries = [pack_flash.ENTRY.unpack_from(raw, pack_flash.HEADER.size + k * pack_flash.ENTRY.size)
               for k in range(count)]
    assert [entry[0] for entry in entries[-3:]] == [
        pack_flash.KIND_EFPGA_UNLOAD, pack_flash.KIND_EFPGA_CLKDIV, pack_flash.KIND_EFPGA]
    kind, destination, size, offset, crc = entries[-2]
    word = struct.pack("<I", 12)  # CLKDIV is N - 1
    assert (destination, size, raw[offset:offset + 4]) == (0x200C_0018, 4, word)
    assert crc == binascii.crc32(word) & 0xFFFF_FFFF
    assert deployment["efpga_clkdiv"]["source"] == "one cycle in 13"
    for bad in (0, 17):
        with pytest.raises(pack_flash.PackError, match="one cycle in 1 to 16"):
            pack_flash.pack(artifacts.boot_manifest, images, output, stream, unload, bad)
    with pytest.raises(pack_flash.PackError, match="the design of --efpga"):
        pack_flash.pack(artifacts.boot_manifest, images, output, None, None, 4)
    assert pack_flash.pack(artifacts.boot_manifest, images, output, stream, unload)["efpga_clkdiv"] is None


def test_a_stream_is_refused_without_an_efpga_its_unload_or_when_malformed(tmp_path):
    stream, unload = _hex(tmp_path / "d.hex", [0xFAB0FAB1]), _hex(tmp_path / "u.hex", [0xFAB0FAB1])
    with pytest.raises(pack_flash.PackError, match="no eFPGA"):
        _packed(tmp_path, PLAIN, stream, unload)
    with pytest.raises(pack_flash.PackError, match="go together"):
        _packed(tmp_path, DEMO, stream)
    (tmp_path / "bad.hex").write_text("1fab0fab1\n")
    with pytest.raises(pack_flash.PackError, match="not a stream of 32-bit words"):
        _packed(tmp_path, DEMO, tmp_path / "bad.hex", unload)
    _, deployment, _ = _packed(tmp_path, DEMO)
    assert deployment["efpga_bitstream"] is None and deployment["efpga_unload"] is None


def test_the_table_holds_no_more_entries_than_cold_boot_takes(tmp_path, monkeypatch):
    cold_boot = (REPO / "sw/firmware/common/cold_boot.c").read_text()
    assert f"#define MOSAIC_DEPLOY_MAX_ENTRIES {pack_flash.MAX_ENTRIES}u" in cold_boot
    monkeypatch.setattr(pack_flash, "MAX_ENTRIES", 1)  # two workers, then the eFPGA
    with pytest.raises(pack_flash.PackError, match="the cold-boot loader takes 1"):
        _packed(tmp_path, DEMO)


# ── the pads ─────────────────────────────────────────────────────────


def test_the_fabric_pads_are_the_last_option_of_gpio_0_to_7_only_with_the_key():
    def options(path):
        ring = _kwargs(path)["xheep"].get_padring()
        return {pad.name: [pin.name for pin in pad.pins] for pad in ring.pad_list}

    with_fabric, without = options(DEMO), options(PLAIN)
    for k in range(8):
        assert with_fabric[f"gpio_{k}"][0] == f"gpio_{k}"  # what pad_control selects out of reset
        assert with_fabric[f"gpio_{k}"][-1] == f"efpga_pad_{k}"
        assert with_fabric[f"gpio_{k}"][:-1] == without[f"gpio_{k}"]
    assert not any(n.startswith("efpga") for pins in without.values() for n in pins)
    assert {p: v for p, v in with_fabric.items() if not p.startswith("gpio_")} == {
        p: v for p, v in without.items() if not p.startswith("gpio_")}


def test_the_software_names_each_pad_mux_and_the_wrapper_reaches_the_pads():
    kwargs = _kwargs(DEMO)
    table = software_gen.efpga_pad_mux(kwargs["xheep"])
    assert table == [(0x2008_0000 + 4 * k, v) for k, v in enumerate([1, 2, 2, 2, 1, 1, 2, 2])]
    header = software_gen._memory_map_header(load_mosaic_yaml(DEMO), 0x3000, 0x200, table)
    assert "#define MOSAIC_EFPGA_PADS 8u" in header
    assert "#define MOSAIC_EFPGA_PAD_MUX_FABRIC {1u, 2u, 2u, 2u, 1u, 1u, 2u, 2u}" in header
    top = _render("hw/mosaic_soc/mosaic_soc.sv.tpl", kwargs)
    assert ".pad_in_i({efpga_pad_7_i, " in top and "efpga_pad_0_oe_o})" in top
    assert "output logic efpga_pad_0_oe_o," in top


def test_the_medium_preset_has_16_pads_on_the_pads_of_gpio_0_to_15():
    path = REPO / "configs" / "mosaic_efpga_medium.yaml"
    assert validate_soc_config(yaml.safe_load(path.read_text())) == []
    xheep = _kwargs(path)["xheep"]
    assert xheep.get_extension("efpga")["pads"] == 16
    owner = {pin.name: [p.name for p in pad.pins] for pad in xheep.get_padring().pad_list
             for pin in pad.pins}
    for k in range(16):
        assert owner[f"efpga_pad_{k}"][-1] == f"efpga_pad_{k}"
        assert f"gpio_{k}" in owner[f"efpga_pad_{k}"]
    assert owner["efpga_pad_14"][0] == "spi_slave_sck"  # the pad of gpio_14 is the SPI slave's
    assert len(software_gen.efpga_pad_mux(xheep)) == 16
