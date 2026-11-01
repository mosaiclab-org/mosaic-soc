# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""What static timing assumes of a design on the fabric, on small netlists.

efpga_timing.py decides which latch holds which bit, which LUT pins cannot
matter, and when a design passes. A wrong answer in any of these makes the
timing of a design pass or fail for the wrong reason, and OpenSTA would not
say so. The check on the real fabric is the sweep step `efpga_netlist`.
"""

import sys

import pytest

from harness.core import REPO_ROOT

sys.path.append(str(REPO_ROOT / "util" / "mosaic_gen"))

import efpga_timing  # noqa: E402

LIB = """
cell("gf180mcu_fd_sc_mcu7t5v0__mux2_2") { pin(Z) { function : "((I0&(!S))|(I1&S))" ; } }
cell("gf180mcu_fd_sc_mcu7t5v0__buf_1") { pin(Z) { function : "I" ; } }
cell("gf180mcu_fd_sc_mcu7t5v0__clkinv_1") { pin(ZN) { function : "(!I)" ; } }
cell("gf180mcu_fd_sc_mcu7t5v0__xnor2_1") { pin(ZN) { function : "(!(A1^A2))" ; } }
"""
FUNCS = efpga_timing.liberty_functions(LIB)
A = "Inst_LA_LUT4c_frame_config_dffesr."


def cell(kind, name, **pins):
    body = ", ".join(f".{pin}({net})" for pin, net in pins.items())
    return f" gf180mcu_fd_sc_mcu7t5v0__{kind} {name} ({body});\n"


def lut_netlist(extra=""):
    """A LUT as a tree of mux2: latch i holds truth-table bit i, frame 0 bit i; c_out_mux is frame 1 bit 0."""
    text = "".join(
        cell("latq_1", f"lat{i}", D=f"FrameData[{i}]", E="FrameStrobe[0]", Q=rf"\{A}inst_cus_mux161.A{i} ")
        for i in range(16)
    )
    text += cell("latq_1", "lat_o", D="FrameData[0]", E="FrameStrobe[1]", Q=rf"\{A}c_out_mux ")
    nets = [rf"\{A}inst_cus_mux161.A{i} " for i in range(16)]
    for level in range(4):
        above = []
        for i in range(0, len(nets), 2):
            out = f"n{level}_{i // 2}"
            text += cell("mux2_2", f"m{level}_{i // 2}", I0=nets[i], I1=nets[i + 1], S=f"sel{level}", Z=out)
            above.append(out)
        nets = above
    text += cell("dffq_1", "flop", D=nets[0], CLK="clk", Q=rf"\{A}LUT_flop ")
    text += cell("mux2_2", "out", I0=nets[0], I1=rf"\{A}LUT_flop ", S=rf"\{A}c_out_mux ", Z="O")
    return text + extra


def loaded(init, c_out_mux=0):
    return lambda latch: c_out_mux if latch == "lat_o" else init >> int(latch[3:]) & 1


def select_pins(pins):
    """{the level of the tree, as the LUT input} of the unobservable S pins."""
    return sorted({int(name[1]) for name, pin in pins if name.startswith("m") and pin == "S"})


def test_a_latch_is_found_through_buffers_on_its_data_and_strobe():
    text = cell("buf_1", "b1", I="FrameData[7]", Z="d") + cell("buf_1", "b2", I="d", Z="d2")
    text += cell("buf_1", "b3", I="FrameStrobe[3]", Z="e")
    text += cell("latq_1", "_1_", D="d2", E="e", Q="net9")
    assert efpga_timing.latch_map(efpga_timing.parse_cells(text)) == {(3, 7): "_1_"}


def test_a_latch_on_something_else_is_refused_and_so_are_two_on_one_bit():
    bad = cell("latq_1", "_1_", D="some_net", E="FrameStrobe[0]", Q="q")
    with pytest.raises(ValueError, match="_1_"):
        efpga_timing.latch_map(efpga_timing.parse_cells(bad))
    twice = cell("latq_1", "_1_", D="FrameData[0]", E="FrameStrobe[0]", Q="q")
    twice += cell("latq_1", "_2_", D="FrameData[0]", E="FrameStrobe[0]", Q="r")
    with pytest.raises(ValueError, match="frame 0 bit 0"):
        efpga_timing.latch_map(efpga_timing.parse_cells(twice))


def test_the_bit_table_reads_each_frame_from_its_top_bit():
    text = "X1Y2,LUT4AB,1,2\nframe0,0,4,1000\nframe1,1,4,0001\n"
    assert efpga_timing.bit_table(text) == {
        "X1Y2": ("LUT4AB", {(0, 3): 1, (0, 2): 0, (0, 1): 0, (0, 0): 0, (1, 3): 0, (1, 2): 0, (1, 1): 0, (1, 0): 1})
    }


def test_the_library_functions_read_with_a_negated_group():
    names, func = FUNCS["xnor2_1"]
    assert names == ["A1", "A2"]
    assert [func(a, b) for a in (0, 1) for b in (0, 1)] == [1, 0, 0, 1]


def test_no_lut_input_is_false_when_the_truth_table_uses_all_four():
    xor = sum(bin(i).count("1") % 2 << i for i in range(16))
    cells = efpga_timing.parse_cells(lut_netlist())
    assert select_pins(efpga_timing.lut_false_arcs(cells, "A", FUNCS, loaded(xor))[0]) == []


def test_the_inputs_a_truth_table_ignores_are_false_and_only_those():
    only_i0 = 0xAAAA
    cells = efpga_timing.parse_cells(lut_netlist())
    assert select_pins(efpga_timing.lut_false_arcs(cells, "A", FUNCS, loaded(only_i0))[0]) == [1, 2, 3]
    only_i3 = 0xFF00
    assert select_pins(efpga_timing.lut_false_arcs(cells, "A", FUNCS, loaded(only_i3))[0]) == [0, 1, 2]


def test_a_select_that_matters_for_part_of_a_table_is_false_only_where_it_cannot():
    # I0 selects only within the first pair of truth-table bits; the rest are 0.
    cells = efpga_timing.parse_cells(lut_netlist())
    pins = efpga_timing.lut_false_arcs(cells, "A", FUNCS, loaded(0b10))[0]
    assert ("m0_0", "S") not in pins and ("m1_0", "S") not in pins


def test_two_inputs_routed_from_one_source_are_one_input():
    # I1 is a copy of I0: their xor is 0, whatever the source does, though each
    # of the two matters when the other is held.
    extra = cell("buf_1", "copy", I="sel0", Z="sel1")
    cells = efpga_timing.parse_cells(lut_netlist(extra))
    xor01 = sum(((i & 1) ^ (i >> 1 & 1)) << i for i in range(16))
    assert select_pins(efpga_timing.lut_false_arcs(cells, "A", FUNCS, loaded(xor01))[0]) == [0, 1, 2, 3]
    separate = efpga_timing.parse_cells(lut_netlist())
    assert select_pins(efpga_timing.lut_false_arcs(separate, "A", FUNCS, loaded(xor01))[0]) == [2, 3]


def test_a_routing_mux_held_by_a_latch_is_followed_to_its_source():
    latch = cell("latq_1", "lat_r", D="FrameData[1]", E="FrameStrobe[1]", Q="r")
    route = cell("mux2_2", "route", I0="in0", I1="in1", S="r", Z="sel3")
    cells = efpga_timing.parse_cells(lut_netlist(latch + route))
    only_i3 = 0xFF00

    def latches(name):
        return 0 if name == "lat_r" else loaded(only_i3)(name)

    assert select_pins(efpga_timing.lut_false_arcs(cells, "A", FUNCS, latches)[0]) == [0, 1, 2]


def test_a_cone_that_escapes_into_the_routing_is_refused():
    # Without its output mux the walk from the truth table has no end but the flop;
    # a chain of gates after it stands for the routing the walk would then enter.
    text = lut_netlist().replace(rf"\{A}c_out_mux ", "other_net")
    chain = "".join(cell("buf_1", f"r{i}", I="O" if i == 0 else f"w{i - 1}", Z=f"w{i}") for i in range(120))
    with pytest.raises(ValueError, match="not the gates of a LUT"):
        efpga_timing.lut_cone(efpga_timing.parse_cells(text + chain), "A")


def test_a_lut_with_a_constant_table_has_nothing_to_time_and_its_output_is_fixed():
    cells = efpga_timing.parse_cells(lut_netlist())
    pins, fixed = efpga_timing.lut_false_arcs(cells, "A", FUNCS, loaded(0))
    assert select_pins(pins) == [0, 1, 2, 3]
    assert ("m3_0", "Z", 0) in fixed


def test_a_select_and_its_complement_that_cancel_are_false_together():
    # An AND-OR mux whose two data inputs are the same: flipping one branch shows,
    # flipping the select as a net never can.
    lib = LIB + """
cell("gf180mcu_fd_sc_mcu7t5v0__oai22_1") { pin(ZN) { function : "(((!A1)&(!A2))|((!B1)&(!B2)))" ; } }
"""
    funcs = efpga_timing.liberty_functions(lib)
    text = lut_netlist().replace(cell("mux2_2", "m3_0", I0="n2_0", I1="n2_1", S="sel3", Z="n3_0"), "")
    text += cell("clkinv_1", "not_s", I="sel3", ZN="sel3n")
    text += cell("clkinv_1", "not_a", I="n2_0", ZN="a_n")
    text += cell("clkinv_1", "not_b", I="n2_1", ZN="b_n")
    text += cell("oai22_1", "top", A1="sel3", A2="a_n", B1="sel3n", B2="b_n", ZN="top_n")
    text += cell("clkinv_1", "not_top", I="top_n", ZN="n3_0")
    cells = efpga_timing.parse_cells(text)
    only_i0 = 0xAAAA
    pins, _ = efpga_timing.lut_false_arcs(cells, "A", funcs, loaded(only_i0))
    assert ("top", "A1") in pins and ("top", "B1") in pins


def test_the_fasm_gives_the_flops_and_the_window_it_routes():
    fasm = "\n".join(
        [
            "X1Y2.F.FF",
            "X1Y2.F.INIT[15:0] = 16'b1010101010101010",
            "X2Y3.B.INIT[15:0] = 16'b1111000011110000",
            "X0Y1.A.C_bit0",
            "X3Y1.RAM2FAB_D1_O3.W2BEG7",
            "X3Y4.J_NS4_END3.FAB2RAM_D0_I3",
            "X3Y4.J_NS4_END1.FAB2RAM_C_I1",
        ]
    )
    flops, inputs, outputs = efpga_timing.fasm_uses(fasm)
    assert dict(flops) == {"X1Y2": {"F"}}
    assert inputs == ["Tile_X3Y1_RAM2FAB_D1_I3"]
    assert outputs == ["Tile_X3Y4_FAB2RAM_C_O1", "Tile_X3Y4_FAB2RAM_D0_O3"]


def test_a_registered_pass_is_refused_rather_than_left_untimed():
    with pytest.raises(ValueError, match="registered pass"):
        efpga_timing.fasm_uses("X3Y1.RAM2FAB_D0_.I0_reg\n")


FLOP = "Tile_X1Y2_LUT4AB/_1_"


def log(setup=5.0, hold=2.0, end=f"{FLOP}/D", extra=""):
    def row(slack):
        word = "VIOLATED" if slack < 0 else "MET"
        return f"{end} (gf180mcu_fd_sc_mcu7t5v0__dffq_1)    55.0   50.0   {slack:.3f} ({word})\n"

    return (
        "### reg2reg max\nmax_delay/setup group UserCLK\n\n"
        + row(setup)
        + "### reg2reg min\nmin_delay/hold group UserCLK\n\n"
        + row(hold)
        + f"### CONE\n{FLOP}/D\nTile_X1Y2_LUT4AB/_2_/Z\n### LOOPS\n{extra}"
    )


def test_a_design_with_every_flop_timed_and_met_passes_and_gives_its_period():
    errors, hold, setup, shortest = efpga_timing.judge({"c1": log(), "c2": log(setup=-0.0, hold=1.5)}, [FLOP], 50)
    assert errors == []
    assert (hold, setup, shortest) == (1.5, -0.0, 50)


def test_a_hold_violation_fails_at_any_clock():
    errors, *_ = efpga_timing.judge({"c1": log(hold=-0.5)}, [FLOP], 50)
    assert len(errors) == 1 and "hold" in errors[0] and "-0.5" in errors[0]


def test_a_setup_violation_fails_and_lengthens_the_period():
    errors, _, setup, shortest = efpga_timing.judge({"c1": log(setup=-7.0)}, [FLOP], 50)
    assert len(errors) == 1 and "setup" in errors[0]
    assert (setup, shortest) == (-7.0, 57.0)


def test_a_used_flop_no_path_reaches_fails_rather_than_passing_unseen():
    errors, *_ = efpga_timing.judge({"c1": log(end="Tile_X9Y9_LUT4AB/_9_/D")}, [FLOP], 50)
    assert any("no path reaches" in error for error in errors)


def test_a_log_with_no_timing_fails():
    errors, *_ = efpga_timing.judge({"c1": "OpenSTA 2.7.0\n"}, [FLOP], 50)
    assert errors


def test_a_loop_on_a_used_path_fails_and_one_elsewhere_does_not():
    on = "  Tile_X1Y2_LUT4AB/_2_/Z\n  | loop cut point\n  --------------------\n"
    off = "  Tile_X8Y8_LUT4AB/_7_/Z\n  | loop cut point\n  --------------------\n"
    assert any("loops on a used path" in e for e in efpga_timing.judge({"c": log(extra=on)}, [FLOP], 50)[0])
    assert efpga_timing.judge({"c": log(extra=off)}, [FLOP], 50)[0] == []


def test_a_single_arc_from_a_pin_it_disabled_is_no_loop():
    arc = f"  {FLOP}/D\n  | loop cut point\n  Tile_X1Y2_LUT4AB/_2_/Z\n  --------------------\n"
    assert any("loops on a used path" in e for e in efpga_timing.judge({"c": log(extra=arc)}, [FLOP], 50)[0])
    assert efpga_timing.judge({"c": log(extra=arc)}, [FLOP], 50, {f"{FLOP}/D"})[0] == []


def test_the_verdict_names_the_division_setup_asks_for_and_fails_on_a_violation(tmp_path, capsys):
    here = tmp_path / "d"
    here.mkdir()
    (here / "design.tcl").write_text(f"set used {{{FLOP}}}\n")
    for i in range(9):
        (here / f"c{i}_x.log").write_text(log(setup=-60.0))
    assert not efpga_timing.verdict(tmp_path, 50, 2, ["d"])
    line = capsys.readouterr().out
    assert line.startswith("STA DESIGN FAIL design=d ") and " min_div=4 " in line
    assert "fabric_min_period_ns=160.00" in line
    for i in range(9):
        (here / f"c{i}_x.log").write_text(log(setup=30.0))
    assert efpga_timing.verdict(tmp_path, 50, 4, ["d"])
    line = capsys.readouterr().out
    assert line.startswith("STA DESIGN PASS design=d ") and " min_div=4 " in line


def test_too_few_logs_fail_the_verdict(tmp_path, capsys):
    here = tmp_path / "d"
    here.mkdir()
    (here / "design.tcl").write_text(f"set used {{{FLOP}}}\n")
    (here / "c1_x.log").write_text(log())
    assert not efpga_timing.verdict(tmp_path, 50, 4, ["d"])
    assert "corners=1 " in capsys.readouterr().out


def test_the_sta_script_times_a_design_only_through_this_module():
    script = (REPO_ROOT / "flow" / "librelane" / "scripts" / "efpga_sta.sh").read_text()
    assert "efpga_timing.py tcl" in script and "efpga_timing.py verdict" in script
    assert "set_false_path" not in script  # a path it must not hide is hidden nowhere else
