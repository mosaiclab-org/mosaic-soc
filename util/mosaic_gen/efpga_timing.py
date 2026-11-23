#!/usr/bin/env python3
# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""efpga_timing.py — what static timing must know of one design on a hardened fabric.

A fabric's netlist has no timing of its own: which paths exist depends on its
configuration. From a stitched run (the --out of ``efpga_gen.py --stitch``) and
a design compiled for the same fabric, this writes the OpenSTA commands that
flow/librelane/scripts/efpga_sta.sh applies (docs/efpga.md, Timing of a design):

  - every configuration latch at the value the design loads, by tracing the
    latch's D and E back through buffers to FrameData and FrameStrobe: its
    instance name is anonymous, and the name of its Q net is not reliable
  - the flops the design uses, from its FASM: a flop it does not use still has
    a D, and would report violations that do nothing
  - the ports of the wrapper's window the design routes
  - the arcs that cannot carry a change, which are taken out of the netlist
    OpenSTA reads: OpenSTA levelizes before case analysis or set_disable_timing
    apply, and cuts each loop of the routing at an edge of its own choosing,
    which may be on the path a design uses. Dead are the pins a gate's output
    does not depend on once the latches are applied (dead_pins), the pins of a
    LUT, or of two that share their inputs, that no end they reach depends on
    under the truth tables (lut_false_arcs, by evaluating the mapped gates with
    the library's functions: ABC maps each LUT differently, so no structure can
    be assumed), and every arc of a gate that then reaches no flop and no tile
    output something reads, across the fabric (live_loads). Each tile becomes
    its own module, whose gates with dead pins are variants of their cells
    without those arcs (``fabric.nl.v`` and ``arcs_<corner>.lib`` beside the
    commands); the connectivity, and so the parasitics, are the layout's.

``latches`` writes the concatenation of all latches for the netlist bench, and
``bits`` the values the design should leave in them, so that a simulation with
the wrapper's own loader can check what this assumes (tb/efpga/run_wrapper.sh).

``verdict`` reads the nine logs of each design that efpga_sta.sh leaves.

``lib`` writes the macro's liberty for the flow that places it, one per process
corner, from the port capacitances in efpga_sta.sh's logs: pins and no arcs.

A <design> is the name of one compiled with the fabric, or <out>/<name> for one
compiled into <out> for it (efpga_gen.py --fabric <the fabric> --out <out>).
Usage: efpga_timing.py tcl <run> <design> <liberty of tt> <out.tcl>   (also fabric.nl.v, arcs_*.lib)
       efpga_timing.py latches <run> <out.vh> <hierarchical path of the fabric>
       efpga_timing.py bits <run> <design>
       efpga_timing.py verdict <dir of the logs> <period ns> <cycles per fabric clock> <design> ...
       efpga_timing.py lib <dir of the logs> <macro.lef> <out dir>
"""

import collections
import hashlib
import heapq
import json
import math
import re
import sys
from pathlib import Path

CELL = re.compile(r"^\s*gf180mcu_fd_sc_mcu7t5v0__(\w+)\s+(\S+)\s*\((.*?)\);", re.M | re.S)
PIN = re.compile(r"\.(\w+)\(\s*([^)]*?)\s*\)")
BUFFER = re.compile(r"(clk)?buf_\d+")
INVERTER = re.compile(r"(clk)?inv_\d+")
OUTPUTS = ("Z", "ZN", "Q")
LUT = "Inst_L{}_LUT4c_frame_config_dffesr."
LATCH, FLOP = "latq_1", "dffq_1"


def parse_cells(netlist):
    """{instance: (cell, {pin: net})} of a tile's netlist, without physical-only cells."""
    cells = {}
    for cell, name, body in CELL.findall(netlist):
        pins = {pin: net.lstrip("\\").strip() for pin, net in PIN.findall(body)}
        if any(pin in pins for pin in OUTPUTS):
            cells[name] = (cell, pins)
    return cells


def _output(pins):
    return next(pins[pin] for pin in OUTPUTS if pin in pins)


def latch_map(cells):
    """{(frame, bit): latch instance}, from what each latch's E and D are wired to."""
    driver = {pins["Z"]: pins["I"] for cell, pins in cells.values() if BUFFER.fullmatch(cell) and pins.get("Z")}

    def root(net):
        while net in driver:
            net = driver[net]
        return net

    found = {}
    for name, (cell, pins) in cells.items():
        if cell != LATCH:
            continue
        strobe = re.fullmatch(r"FrameStrobe\[(\d+)\]", root(pins["E"]))
        data = re.fullmatch(r"FrameData\[(\d+)\]", root(pins["D"]))
        if not strobe or not data:
            raise ValueError(f"latch {name}: E is {root(pins['E'])}, D is {root(pins['D'])}")
        key = int(strobe[1]), int(data[1])
        if key in found:
            raise ValueError(f"latches {found[key]} and {name} hold frame {key[0]} bit {key[1]}")
        found[key] = name
    return found


def bit_table(text):
    """{tile: (type, {(frame, bit): value})} of bit_gen's .csv, whose bit strings start at the top bit."""
    table, values = {}, {}
    for row in text.splitlines():
        head = re.fullmatch(r"(X\d+Y\d+),(\w+),\d+,\d+", row)
        frame = re.fullmatch(r"frame\d+,(\d+),(\d+),([01]+)", row)
        if head:
            values = {}
            table[head[1]] = head[2], values
        elif frame:
            for i, value in enumerate(frame[3]):
                values[int(frame[1]), int(frame[2]) - 1 - i] = int(value)
    return table


def liberty_functions(text):
    """{cell: (input pins, function of those pins)} of the library's first output of each cell."""
    funcs, cell = {}, None
    for m in re.finditer(r'\bcell\s*\(\s*"?gf180mcu_fd_sc_mcu7t5v0__(\w+)"?\s*\)|\bfunction\s*:\s*"([^"]+)"', text):
        if m[1]:
            cell = m[1]
        elif cell not in funcs:
            pins = sorted(set(re.findall(r"[A-Za-z]\w*", m[2])))
            funcs[cell] = pins, eval(f"lambda {','.join(pins)}: ({m[2].replace('!', '~')}) & 1")  # the PDK's library
            funcs[cell][1].expr = m[2]
    return funcs


def _wide(func, count):
    """``func`` of 0 and 1 as a function of truth tables: (mask, *tables), each table an int."""
    if hasattr(func, "expr"):
        names = sorted(set(re.findall(r"[A-Za-z]\w*", func.expr)))
        return eval(f"lambda M, {','.join(names)}: ({func.expr.replace('!', '~')}) & M")
    ones = [k for k in range(2 ** count) if func(*[k >> j & 1 for j in range(count)])]

    def wide(mask, *tables):
        out = 0
        for k in ones:
            term = mask
            for j, table in enumerate(tables):
                term &= table if k >> j & 1 else ~table
            out |= term
        return out & mask

    return wide


def lut_cone(cells, letter):
    """The gates of a LUT, in the order of evaluation, and the nets it ends in.

    They start at the 16 truth-table latches and end at the D of its flop and
    at the gate that takes c_out_mux, which is the LUT's output mux or a part
    of it: beyond that lie the routing and the rest of the tile.
    """
    prefix = LUT.format(letter)
    loads = collections.defaultdict(list)
    for name, (cell, pins) in cells.items():
        for pin, net in pins.items():
            if pin not in OUTPUTS:
                loads[net].append(name)
    cone, sinks, stop = set(), set(), prefix + "c_out_mux"
    todo = [f"{prefix}inst_cus_mux161.A{i}" for i in range(16)]
    while todo:
        net = todo.pop()
        for name in loads[net]:
            cell, pins = cells[name]
            if cell == FLOP:
                sinks.add(net)
            elif cell != LATCH and name not in cone:
                cone.add(name)
                if stop in pins.values():
                    sinks.add(_output(pins))
                else:
                    todo.append(_output(pins))
    if len(cone) > 100 or not sinks:
        raise ValueError(f"LUT {letter}: {len(cone)} gates and {len(sinks)} ends, not the gates of a LUT")
    order, done = [], {_output(cells[name][1]): name for name in cone}
    placed = set()

    def place(name):
        if name in placed:
            return
        placed.add(name)
        for pin, net in cells[name][1].items():
            if pin not in OUTPUTS and net in done:
                place(done[net])
        order.append(name)

    for name in sorted(cone):
        place(name)
    return order, sorted(sinks)


def lut_false_arcs(cells, letter, funcs, loaded, ports=frozenset(), loads=None):
    """What cannot reach an end of a LUT: ([(gate, input pin)], [(gate, output pin, value)]).

    ``letter`` may name several LUTs, analysed as one: two that share input
    wires share the gates that decode them.

    ``loaded(latch instance)`` is the latch's value, ``ports`` the tile's outputs that lead somewhere,
    ``loads`` {net: gates} the gates a net reaches by an arc that is there
    (live_loads), all of them if None. A gate's output that is the
    same for every value of the LUT's inputs, its flop's output among them, is
    constant. An input pin is false if flipping it changes no end for any value,
    and so are all the pins on a net if flipping them together changes none: a
    select and its complement cancel only together.
    """
    order, sinks = [], []
    for one in letter:
        gates_of, ends_of = lut_cone(cells, one)
        order += [name for name in gates_of if name not in order]
        sinks += [net for net in ends_of if net not in sinks]
    made = {_output(cells[name][1]): name for name in order}
    placed_gates, ordered = set(), []

    def topological(name):
        if name in placed_gates:
            return
        placed_gates.add(name)
        for pin, net in cells[name][1].items():
            if pin not in OUTPUTS and net in made:
                topological(made[net])
        ordered.append(name)

    for name in order:
        topological(name)
    order = ordered
    driver = {_output(pins): name for name, (_, pins) in cells.items()}
    internal = {_output(cells[name][1]) for name in order}
    seen = {}

    def canonical(net):
        """(None, value) of a net the latches fix, (root, inverted) of one that follows a single other."""
        if net in seen:
            return seen[net]
        seen[net] = net, 0  # a port, a flop, a gate's output, or a loop of the routing: a root
        name = driver.get(net)
        if name is None or net in internal or cells[name][0] == FLOP:
            return seen[net]
        cell, pins = cells[name]
        if cell == LATCH:
            seen[net] = None, loaded(name)
            return seen[net]
        names, func = funcs[cell]
        inputs = [canonical(pins[pin]) for pin in names]
        live = sorted({root for root, _ in inputs if root is not None})
        table = [
            func(*[value if root is None else i >> live.index(root) & 1 ^ value for root, value in inputs])
            for i in range(2 ** len(live))
        ]
        matter = [k for k in range(len(live)) if any(v != table[i ^ 1 << k] for i, v in enumerate(table))]
        if len(matter) <= 1:
            seen[net] = (live[matter[0]] if matter else None), table[0]
        return seen[net]

    # ABC decodes the selects in gates shared by the LUT's truth-table bits, and
    # only together do they mean one thing: the gates right behind the LUT count
    # as part of it, two levels, and whatever comes through the routing is an input.
    producers, constant, free = {}, {}, set()
    levels = 2

    def behind(net):
        while net in driver:
            cell, pins = cells[driver[net]]
            if not BUFFER.fullmatch(cell) and not INVERTER.fullmatch(cell):
                break
            net = pins["I"]
        return net

    # Breadth first: a net reached by two routes counts at the shorter, whatever
    # the order the LUT's pins come in.
    todo = []

    def need(net, depth):
        heapq.heappush(todo, (depth, net))

    cone = []
    for name in order:
        cell, pins = cells[name]
        names, func = funcs[cell]
        for pin in names:
            need(pins[pin], 0)
        cone.append((name, func, [(pin, pins[pin]) for pin in names], _output(pins)))
    while todo:
        depth, net = heapq.heappop(todo)
        if net in producers or net in internal or net in constant or net in free:
            continue
        root, value = canonical(net)
        if root is None:
            constant[net] = value
        elif root in internal:
            # The LUT's own output, routed back to it: an input of its own, one
            # for every net that carries it, which may reach the LUT by several.
            fed = f"{root} (fed back)"
            producers[net] = None, lambda a, inverted=value: a ^ inverted, [("I", fed)], net
            free.add(fed)
        elif root != net:
            producers[net] = None, lambda a, inverted=value: a ^ inverted, [("I", root)], net
            need(root, depth if behind(net) == root else levels)
        elif depth < levels and net in driver and cells[driver[net]][0] not in (LATCH, FLOP):
            cell, pins = cells[driver[net]]
            names, func = funcs[cell]
            producers[net] = driver[net], func, [(pin, pins[pin]) for pin in names], net
            for pin in names:
                need(pins[pin], depth + 1)
        else:
            free.add(net)

    gates, placed, open_nets = [], set(), set()

    def place(net):
        """A routing loop among those gates ends in an input."""
        if net in placed or net not in producers:
            return
        if net in open_nets:
            del producers[net]
            free.add(net)
            return
        open_nets.add(net)
        for _, input_net in producers[net][2]:
            place(input_net)
        open_nets.discard(net)
        if net in producers:
            placed.add(net)
            gates.append(producers[net])

    for net in list(producers):
        place(net)
    gates += cone
    roots = sorted(free)
    if len(roots) > 18:
        raise ValueError(f"LUT {letter}: {len(roots)} inputs")
    # The gates behind the LUT whose outputs go nowhere else are part of it: ABC
    # merges an input the truth table ignores with one it uses there.
    loads = live_loads(cells, set(), ports) if loads is None else loads
    region = {name for name, _, _, _ in cone}
    behind = {name: out for name, _, _, out in gates if name and name not in region and out not in ports}

    def beyond(net):
        """The gates a net reaches, through those that only pass it on (a buffer, a mux the latches set)."""
        found, todo, passed = set(), [net], set()
        while todo:
            for name in loads.get(todo.pop(), ()):
                out = _output(cells[name][1])
                if (name in region or name in behind or cells[name][0] in (LATCH, FLOP) or out in ports
                        or canonical(out)[0] in (None, out)):
                    found.add(name)
                elif name not in passed:
                    passed.add(name)
                    todo.append(out)
        return found

    reached = {name: beyond(out) for name, out in behind.items()}
    while True:
        closed = {name for name in behind if reached[name] <= region | set(behind)}
        if closed == set(behind):
            break
        behind = {name: behind[name] for name in closed}
    region |= set(behind)
    # A pin held by a latch is no arc: OpenSTA's case analysis has it.
    on_net = collections.defaultdict(set)
    for name, _, ins, _ in (g for g in gates if g[0] in region):
        for pin, net in ins:
            if net not in constant:
                on_net[net if net in internal else canonical(net)[0]].add((name, pin))
    groups = {frozenset({one}) for pins in on_net.values() for one in pins}
    groups |= {frozenset(pins) for pins in on_net.values()}

    # Every assignment of the inputs at once: a net's value is a truth table, an
    # int whose bit k is its value when root i is bit i of k.
    size = 1 << len(roots)
    mask = (1 << size) - 1

    def pattern(i):
        table, width = ((1 << (1 << i)) - 1) << (1 << i), 1 << (i + 1)
        while width < size:
            table, width = table | table << width, width * 2
        return table & mask

    columns = [pattern(i) for i in range(len(roots))]
    wide = [(name, _wide(func, len(ins)) if name is None else _wide(funcs[cells[name][0]][1], len(ins)), ins, out)
            for name, func, ins, out in gates]

    def run(flip=frozenset()):
        values = {net: mask if value else 0 for net, value in constant.items()}
        values.update(zip(roots, columns))
        for name, func, ins, out in wide:
            values[out] = func(mask, *[values[net] ^ (mask if (name, pin) in flip else 0) for pin, net in ins])
        return values

    base = run()
    outputs = {out: {base[out] & 1} if base[out] in (0, mask) else {0, 1} for _, _, _, out in cone}
    carries = collections.defaultdict(set)
    for net, table in base.items():
        for i, root in enumerate(roots):
            if (table ^ table >> (1 << i)) & ~columns[i] & mask:
                carries[net].add(root)
    groups = {g for g in groups if all(run(g)[net] == base[net] for net in sinks)}
    # An input the truth table ignores can reach the LUT's gates by several pins
    # that the routing's loops leave with no common net: a pin is false if none
    # of the ends it reaches depends on anything it carries, whatever else it
    # shares a net with. Of two LUTs, one may use an input the other ignores.
    reach = collections.defaultdict(set)
    for net in sinks:
        reach[net].add(net)
    for name, _, ins, out in reversed(gates):
        if name in region:
            for _, net in ins:
                reach[net] |= reach[out]
    idle = set()
    for name, _, ins, out in gates:
        if name in region:
            ends = set().union(*(carries[sink] for sink in reach[out]))
            idle |= {(name, pin) for pin, net in ins if carries[net] and not carries[net] & ends}
    false_pins = sorted(idle.union(*groups))
    fixed = sorted(
        (name, next(pin for pin in OUTPUTS if pin in cells[name][1]), outputs[out].copy().pop())
        for name, _, _, out in cone
        if len(outputs[out]) == 1
    )
    return false_pins, fixed


def dead_pins(cells, funcs, held):
    """The input pins of a tile's gates that cannot change the gate's output: {(gate, pin)}.

    ``held`` is {net: value} of the nets the configuration fixes: the latches'
    outputs and the LUTs' constant ones. Each net is followed back while it is
    a function of one other, as in lut_false_arcs, so that two pins that carry
    the same signal count as one: a pin is dead if the gate's output does not
    depend on what it carries. A mux's unselected inputs, every pin of a gate
    whose output is constant, and an input that reconverges and cancels.
    """
    driver = {_output(pins): name for name, (_, pins) in cells.items()}
    seen = {net: (None, value) for net, value in held.items()}

    def evaluate(cell, pins):
        names, func = funcs[cell]
        inputs = [canonical(pins[pin]) for pin in names]
        live = sorted({root for root, _ in inputs if root is not None})
        table = [func(*[v if root is None else i >> live.index(root) & 1 ^ v for root, v in inputs])
                 for i in range(2 ** len(live))]
        matter = {live[k] for k in range(len(live)) if any(v != table[i ^ 1 << k] for i, v in enumerate(table))}
        return names, inputs, live, table, matter

    def canonical(net):
        if net in seen:
            return seen[net]
        seen[net] = net, 0  # a port, a flop, or a loop: a root
        name = driver.get(net)
        if name is None or cells[name][0] not in funcs or not all(p in cells[name][1] for p in funcs[cells[name][0]][0]):
            return seen[net]
        _, _, live, table, matter = evaluate(*cells[name])
        if len(matter) <= 1:
            seen[net] = (next(iter(matter)) if matter else None), table[0]
        return seen[net]

    limit = sys.getrecursionlimit()
    sys.setrecursionlimit(max(limit, 20000))
    try:
        dead = set()
        for name, (cell, pins) in cells.items():
            if cell in funcs and all(pin in pins for pin in funcs[cell][0]):
                names, inputs, _, _, matter = evaluate(cell, pins)
                dead |= {(name, pin) for pin, (root, _) in zip(names, inputs) if root is not None and root not in matter}
    finally:
        sys.setrecursionlimit(limit)
    return dead


def lut_pins(cells, letters, funcs, loaded, ports, loads):
    """The false pins of lut_false_arcs, none for LUTs together with too many inputs to try."""
    try:
        return set(lut_false_arcs(cells, letters, funcs, loaded, ports, loads)[0])
    except ValueError:
        if len(letters) == 1:
            raise
        return set()


def live_loads(cells, off, ports):
    """{net: the gates it reaches by an arc not in ``off``}, and ``off`` grown by
    every arc of a gate that reaches nothing: no live load, no flop, none of the
    output bits ``ports`` (those that lead somewhere outside the tile)."""
    loads = collections.defaultdict(set)
    for name, (cell, pins) in cells.items():
        for pin, net in pins.items():
            if pin not in OUTPUTS and (name, pin) not in off:
                loads[net].add(name)
    todo = list(cells)
    while todo:
        name = todo.pop()
        cell, pins = cells[name]
        out = _output(pins)
        if cell in (LATCH, FLOP) or loads.get(out) or out in ports:
            continue
        for pin, net in pins.items():
            if pin not in OUTPUTS and (name, pin) not in off:
                off.add((name, pin))
                loads[net].discard(name)
                if not loads[net] and net in _drivers(cells):
                    todo.append(_drivers(cells)[net])
    return loads


_DRIVERS = {}


def _drivers(cells):
    key = id(cells)
    if key not in _DRIVERS:
        _DRIVERS[key] = {_output(pins): name for name, (_, pins) in cells.items()}
    return _DRIVERS[key]


def port_bits(text):
    """{port: (direction, [its bits, the first the highest])} of a netlist's first module."""
    ports = {}
    for direction, msb, lsb, name in re.findall(r"^\s*(input|output|inout)\s+(?:\[(\d+):(\d+)\]\s*)?(\w+)\s*;",
                                               text.split("endmodule")[0], re.M):
        step = 1 if msb and int(msb) < int(lsb) else -1
        ports[name] = direction, ([f"{name}[{i}]" for i in range(int(msb), int(lsb) + step, step)] if msb else [name])
    return ports


def wiring(top, bits):
    """{tile instance: {port bit: net of the top}} of the fabric's netlist, ``bits`` the ports of each tile."""
    links = {}
    kinds = "|".join(bits)
    for kind, instance, body in re.findall(rf"^\s*({kinds})\s+(Tile_X\d+Y\d+_\1)\s*\((.*?)\);", top, re.M | re.S):
        links[instance] = {}
        for port, expr in re.findall(r"\.(\w+)\(\s*(\{[^}]*\}|[^()]*?)\s*\)", body):
            nets = [n.strip().lstrip("\\").strip() for n in expr.strip("{} ").split(",")] if expr else []
            if len(nets) != len(bits[kind][port][1]):
                raise ValueError(f"{instance}.{port}: {len(nets)} nets for {len(bits[kind][port][1])} bits")
            links[instance].update(zip(bits[kind][port][1], nets))
    return links


def _group_end(text, start):
    """The index after the brace that closes the group opened at text[start]."""
    depth = 0
    for m in re.finditer(r"[{}]", text[start:]):
        depth += 1 if m[0] == "{" else -1
        if depth == 0:
            return start + m.end()
    raise ValueError("an unclosed group in the liberty")


def without_arcs(cell, pins):
    """The liberty group of a cell, without its arcs from these input pins, and without power."""
    parts, pos = [], 0
    for m in re.finditer(r"\b(?:timing|internal_power|leakage_power)\s*\(\s*\)\s*\{", cell):
        if m.start() < pos:
            continue
        end = _group_end(cell, m.end() - 1)
        related = re.search(r'related_pin\s*:\s*"(\w+)"', cell[m.start():end])
        if not m[0].startswith("timing") or related and related[1] in pins:
            parts.append(cell[pos:m.start()])
            pos = end
    return "".join(parts) + cell[pos:]


def variant(cell, pins):
    """The name of a cell with no arcs from these pins."""
    return f"{cell}__no_{'_'.join(sorted(pins))}"


def arcs_liberty(text, variants, name):
    """A liberty named `name` of the cells ``variants``, {(cell, pins)}, from the library ``text``.

    OpenSTA levelizes the graph before case analysis or set_disable_timing apply,
    and cuts each loop it finds at an edge of its own choosing, which may be on
    the path a design uses: the loops of the routing are cut only if the dead
    arcs are not there at all.
    """
    first = text.index("\n  cell(")
    out = [re.sub(r"\blibrary\s*\([^)]*\)", f"library({name})", text[:first], count=1)]
    for cell, pins in sorted(variants):
        m = re.search(rf'\n  cell\(\s*"?gf180mcu_fd_sc_mcu7t5v0__{cell}"?\s*\)\s*\{{', text)
        group = text[m.start():_group_end(text, m.end() - 1)]
        group = group.replace(f"__{cell}", f"__{variant(cell, pins)}", 1)
        out.append(without_arcs(group, pins))
    return "".join(out) + "\n}\n"


def fasm_uses(fasm):
    """What a design's FASM uses: {tile: letters of flops}, routed window ports.

    A RAM_IO pass register would be a flop in use that nothing here times, so a
    design that sets one is refused until one needs it.
    """
    if re.search(r"\.[IO]\d_reg$", fasm, re.M):
        raise ValueError("a registered pass of RAM_IO: not modelled")
    flops = collections.defaultdict(set)
    for tile, letter in re.findall(r"^(X\d+Y\d+)\.([A-H])\.FF$", fasm, re.M):
        flops[tile].add(letter)
    # The bel's output O<n> is the fabric's input I<n>, and its input I<n> the fabric's output O<n>.
    inputs = re.findall(r"^(X\d+Y\d+)\.(RAM2FAB_D\d_)O(\d+)\.", fasm, re.M)
    outputs = re.findall(r"^(X\d+Y\d+)\.[^.\s]+\.(FAB2RAM_(?:D\d_|C_))I(\d+)$", fasm, re.M)
    return (
        flops,
        sorted({f"Tile_{tile}_{name}I{i}" for tile, name, i in inputs}),
        sorted({f"Tile_{tile}_{name}O{i}" for tile, name, i in outputs}),
    )


def _flop_of(cells, letter):
    q = LUT.format(letter) + "LUT_flop"
    found = [name for name, (cell, pins) in cells.items() if cell == FLOP and pins["Q"] == q]
    if len(found) != 1:
        raise ValueError(f"{len(found)} flops drive {q}")
    return found[0]


def same_fabric(fabric, compiled):
    """Whether the fabric a design was compiled for, `compiled` the fabric entry of
    its manifest, is `fabric`. The fabric of a SoC's bundle is generated with no
    design in it, so their manifests differ: it is the same when it has not changed
    since the design was compiled, and has the same geometry, tools and RTL, which
    the tiles were hardened from and the bitstream's bits are placed by."""
    other = Path(compiled.get("path", "")) / "manifest.json"
    if not other.is_file() or hashlib.sha256(other.read_bytes()).hexdigest() != compiled["manifest_sha256"]:
        return False
    a, b = (json.loads(f.read_text()) for f in (Path(fabric) / "manifest.json", other))
    rtl = [{f: d for f, d in m["outputs"].items() if f.startswith("proj/")} for m in (a, b)]
    return bool(rtl[0]) and rtl[0] == rtl[1] and a["geometry"] == b["geometry"] and a["tools"] == b["tools"]


class Run:
    """The tiles of a stitched run, and the designs of the fabric it was stitched from."""

    def __init__(self, path):
        self.path = Path(path).resolve()
        manifest = json.loads((self.path / "manifest.json").read_text())
        self.fabric = Path(manifest["fabric"]["path"])
        self.digest = hashlib.sha256((self.fabric / "manifest.json").read_bytes()).hexdigest()
        if self.digest != manifest["fabric"]["manifest_sha256"]:
            raise ValueError(f"{self.path}: stitched from another fabric than {self.fabric}")
        texts = {tile: (Path(views) / "nl" / f"{tile}.nl.v").read_text() for tile, views in manifest["tile_macros"].items()}
        self.cells = {tile: parse_cells(text) for tile, text in texts.items()}
        self.bits = {tile: port_bits(text) for tile, text in texts.items()}
        top = (self.path / "macro" / "fabric" / "final_views" / "nl" / "eFPGA.nl.v").read_text()
        self.top_outputs = {bit for direction, bits in port_bits(top).values() if direction == "output" for bit in bits}
        self.wiring = wiring(top, self.bits)
        self.latches = {tile: latch_map(cells) for tile, cells in self.cells.items()}
        self.instances = bit_table((self.fabric / "load_order" / "registered.csv").read_text())

    def design_file(self, design, suffix):
        """A file of a design of the fabric, or of `<out>/<name>`: one compiled
        into <out> for the same fabric (efpga_gen.py --fabric <it> --out <out>)."""
        out, name = Path(design).parent, Path(design).name
        if out == Path("."):
            return self.fabric / "bitstream" / f"{name}.{suffix}"
        compiled = json.loads((out / "manifest.json").read_text())["fabric"]
        if compiled["manifest_sha256"] != self.digest and not same_fabric(self.fabric, compiled):
            raise ValueError(f"{design}: compiled for another fabric than {self.fabric}")
        return out / "bitstream" / f"{name}.{suffix}"

    def table(self, design):
        return bit_table(self.design_file(design, "csv").read_text())

    def latch_values(self, table):
        """[(<tile instance>/<latch>, value)] of every latch, in the bench's order."""
        rows = []
        for tile, (kind, values) in sorted(table.items()):
            for key, latch in sorted(self.latches[kind].items()):
                rows.append((f"Tile_{tile}_{kind}/{latch}", values[key]))
        return rows

    def tcl(self, design, liberty):
        table = self.table(design)
        rows = self.latch_values(table)
        for tile, (kind, values) in table.items():
            stray = [k for k, v in values.items() if v and k not in self.latches[kind]]
            if stray:
                raise ValueError(f"{design}: {tile} sets {stray}, which no latch holds")
        fasm = self.design_file(design, "fasm").read_text()
        flops, inputs, outputs = fasm_uses(fasm)
        funcs = liberty_functions(Path(liberty).read_text())
        lines = [f"set_case_analysis {value} {latch}/Q" for latch, value in rows]
        used, tiles = [], {}
        for instance in sorted(self.wiring):
            tile, kind = re.fullmatch(r"Tile_(X\d+Y\d+)_(\w+)", instance).groups()
            cells, latches = self.cells[kind], self.latches[kind]
            if latches and table.get(tile, ("",))[0] != kind:
                raise ValueError(f"{design}: the bitstream has no {kind} at {tile}")
            values = table[tile][1] if latches else {}
            by_name = {name: values[key] for key, name in latches.items()}
            held = {cells[name][1]["Q"]: value for name, value in by_name.items()}
            nets = {net for _, pins in cells.values() for net in pins.values()}
            letters = [c for c in "ABCDEFGH" if LUT.format(c) + "LUT_flop" in nets]
            outs = {bit for direction, bits in self.bits[kind].values() if direction == "output" for bit in bits}
            luts = set()
            for letter in letters:
                pins, fixed = lut_false_arcs(cells, letter, funcs, by_name.__getitem__, outs)
                luts.update(pins)
                held.update({cells[name][1][pin]: value for name, pin, value in fixed})
                lines += [f"set_case_analysis {value} Tile_{tile}_{kind}/{name}/{pin}" for name, pin, value in fixed]
                if letter in flops.get(tile, ()):
                    used.append(f"Tile_{tile}_{kind}/{_flop_of(cells, letter)}")
            tiles[instance] = cells, by_name, letters, luts, luts | dead_pins(cells, funcs, held), outs
        # What the case analysis kills, and what then reaches nothing in the whole
        # fabric, is no load: a gate behind a LUT that feeds only it is part of it.
        # The carry chain is the reason: every LUT's carry reaches the tile's Co.
        readers = collections.defaultdict(list)
        for instance, links in self.wiring.items():
            kind = instance.split("_", 2)[2]
            for bit, net in links.items():
                if self.bits[kind][bit.split("[")[0]][0] == "input":
                    readers[net].append((instance, bit))
        live = {instance: outs for instance, (*_, outs) in tiles.items()}
        while True:
            loads = {instance: live_loads(cells, off, live[instance])
                     for instance, (cells, _, _, _, off, _) in tiles.items()}
            reached = {instance: {bit for bit in outs if self.wiring[instance][bit] in self.top_outputs
                                  or any(loads[r].get(b) for r, b in readers[self.wiring[instance][bit]])}
                       for instance, (*_, outs) in tiles.items()}
            more = False
            for instance, (cells, by_name, letters, luts, off, _) in tiles.items():
                # A pair of LUTs reads the same input wires, and ABC decodes them once.
                groups = letters + [pair for pair in ("AB", "CD", "EF", "GH") if set(pair) <= set(letters)]
                found = set().union(*(lut_pins(cells, group, funcs, by_name.__getitem__, reached[instance],
                                               loads[instance]) for group in groups)) - off
                luts |= found
                off |= found
                more = more or bool(found)
            if reached == live and not more:
                break
            live = reached
        arcs, false_pins, dead = {}, 0, 0
        for instance, (_, _, _, luts, off, _) in tiles.items():
            false_pins += len(luts)
            dead += len(off - luts)
            arcs[instance] = by_gate = collections.defaultdict(set)
            for name, pin in off:
                by_gate[name].add(pin)
        self.arcs = arcs
        lines += [
            f"set used {{{' '.join(used)}}}",
            f"set bound_in {{{' '.join(inputs)}}}",
            f"set bound_out {{{' '.join(outputs)}}}",
        ]
        return lines, {"latches": len(rows), "flops": len(used), "false_pins": false_pins, "dead_pins": dead,
                       "inputs": len(inputs), "outputs": len(outputs)}

    def netlist(self, arcs):
        """The fabric's netlist with each tile its own module, whose gates of ``arcs``
        ({tile instance: {gate: pins}}) are the variants without those pins' arcs."""
        top = (self.path / "macro" / "fabric" / "final_views" / "nl" / "eFPGA.nl.v").read_text()
        kinds = "|".join(self.cells)
        parts = [re.sub(rf"^(\s*)({kinds})(\s+)(Tile_(X\d+Y\d+)_\2)\b", r"\1\2__\5\3\4", top, flags=re.M)]
        texts = {kind: (Path(views) / "nl" / f"{kind}.nl.v").read_text()
                 for kind, views in json.loads((self.path / "manifest.json").read_text())["tile_macros"].items()}
        for kind, tile in sorted(set(re.findall(rf"^\s*({kinds})\s+Tile_(X\d+Y\d+)_\1\b", top, re.M))):
            by_gate = arcs.get(f"Tile_{tile}_{kind}", {})

            def swap(m, by_gate=by_gate):
                pins = by_gate.get(m[3])
                return m[0] if not pins else f"{m[1]}gf180mcu_fd_sc_mcu7t5v0__{variant(m[2], pins)}{m[0][m.end(2) - m.start(0):]}"

            text = re.sub(rf"^module {kind}\b", f"module {kind}__{tile}", texts[kind], count=1, flags=re.M)
            parts.append(re.sub(r"^(\s*)gf180mcu_fd_sc_mcu7t5v0__(\w+)\s+(\S+)", swap, text, flags=re.M))
        return "\n".join(parts)

    def variants(self, arcs):
        return {(self.cells[re.fullmatch(r"Tile_X\d+Y\d+_(\w+)", instance)[1]][gate][0], frozenset(pins))
                for instance, by_gate in arcs.items() for gate, pins in by_gate.items()}


def read_log(text):
    """What one OpenSTA log of efpga_sta.sh says: {(group, max|min): {endpoint: slack}}, the loops, the used pins."""
    parts = re.split(r"^### (.+)$", text, flags=re.M)
    groups, cone, loops = {}, set(), []
    for head, body in zip(parts[1::2], parts[2::2]):
        if head == "CONE":
            cone = set(body.split())
        elif head == "LOOPS":
            loops = [re.findall(r"^\s+(Tile_\S+)", loop, re.M) for loop in re.split(r"-{10,}", body)]
        else:
            name, delay = head.split()
            groups[name, delay] = {
                end: float(slack)
                for end, slack in re.findall(r"^(\S+) \(.*?(-?\d+\.\d+) \((?:VIOLATED|MET)\)$", body, re.M)
            }
    return groups, [loop for loop in loops if loop], cone


def judge(logs, used, period):
    """(errors, worst hold, worst setup, shortest period), over a design's corners {corner: text of its log}.

    A loop OpenSTA finds on a used path fails: the arcs no configuration lets
    through are not in the netlist it reads, so the loop is one the analysis
    could not cut, and OpenSTA's own cut may fall on the path.
    """
    errors, hold, setup = [], [], []
    for corner, text in sorted(logs.items()):
        groups, loops, cone = read_log(text)
        if not groups:
            errors.append(f"{corner}: no timing in the log")
        for (name, delay), slacks in sorted(groups.items()):
            for end, slack in slacks.items():
                (setup if delay == "max" else hold).append(slack)
                if slack < 0:
                    errors.append(f"{corner}: {'setup' if delay == 'max' else 'hold'} of {name} at {end}: {slack} ns")
        timed = set(groups.get(("reg2reg", "max"), {})) | set(groups.get(("in2reg", "max"), {}))
        untimed = [flop for flop in used if f"{flop}/D" not in timed]
        if untimed:
            errors.append(f"{corner}: no path reaches {' '.join(untimed)}")
        touching = sum(1 for loop in loops if cone.intersection(loop))
        if touching:
            errors.append(f"{corner}: {touching} loops on a used path")
    if not setup or not hold:
        errors.append("nothing timed")
        return errors, 0.0, 0.0, 0.0
    return errors, min(hold), min(setup), period - min(setup)


def verdict(out, period, div, designs):
    """Prints one line per design, and returns whether all passed.

    From div 2 up, each cycle more per fabric clock gives every setup path one
    more period, window or not, so min_div is what setup asks. From a check at
    div 1 it is only a lower bound: going to 2, the window's paths gain nothing.
    Hold asks for 2 at least, and only the check at the given div says that it
    is enough.
    """
    good = True
    for design in designs:
        here = Path(out) / design
        logs = {log.stem: log.read_text() for log in here.glob("*_*.log")}
        commands = (here / "design.tcl").read_text()
        used = re.search(r"^set used \{(.*)\}$", commands, re.M)[1].split()
        errors, hold, setup, shortest = judge(logs, used, period * div)
        if len(logs) != 9:
            errors.append(f"{len(logs)} corner logs")
        rows = ["corner\tgroup\tcheck\tendpoints\tviolators\tworst_slack_ns"]
        for corner, text in sorted(logs.items()):
            for (name, delay), slacks in sorted(read_log(text)[0].items()):
                if slacks:
                    bad = sum(slack < 0 for slack in slacks.values())
                    rows.append(f"{corner}\t{name}\t{'setup' if delay == 'max' else 'hold'}\t"
                                f"{len(slacks)}\t{bad}\t{min(slacks.values())}")
        (here / "summary.tsv").write_text("\n".join(rows) + "\n")
        (here / "errors.txt").write_text("\n".join(errors) + "\n")
        fmax = 1000 / shortest if shortest > 0 else 0
        min_div = max(2, math.ceil(div - setup / period))
        print(f"STA DESIGN {'FAIL' if errors else 'PASS'} design={design} corners={len(logs)} flops={len(used)} "
              f"hold_ns={hold:.2f} setup_ns={setup:.2f} period_ns={period:g} div={div} min_div={min_div} "
              f"fabric_min_period_ns={shortest:.2f} fabric_fmax_mhz={fmax:.1f} violations={len(errors)}")
        good = good and not errors
    return good


# The limit the library declares on an input pin, per corner (signoff_template.yaml).
MAX_TRANSITION = {"tt_025C_5v00": 4.0, "ss_125C_4v50": 7.0, "ff_n40C_5v50": 2.6}


def macro_lib(log, corner, area, window=False):
    """The macro's liberty: pins, their capacitance, UserCLK a clock pin, no arcs.

    Which paths the fabric has depends on its configuration, so no arc holds for
    the macro alone. The flow needs this to size what drives the macro; the paths
    through it are timed per design, on the layout, by efpga_sta.sh.

    With window, the pins of the wrapper's window also have arcs of no delay to
    UserCLK, so that the slacks of the top level are the wrapper's side of the
    window (efpga_block_sta.sh). Never for the flow: they would be checks that
    the wrapper keeps off with its clock's division, which it knows nothing of.
    """
    temp, volts, tenths = re.fullmatch(r"\w\w_(n?\d+)C_(\d)v(\d\d)", corner).groups()
    temp, volts = temp.replace("n", "-"), f"{volts}.{tenths}"
    limit = MAX_TRANSITION[corner]

    def arcs(name):
        checks = "rise_constraint(scalar) { values(\"0\"); } fall_constraint(scalar) { values(\"0\"); }"
        launch = ("cell_rise(scalar) { values(\"0\"); } rise_transition(scalar) { values(\"0\"); } "
                  "cell_fall(scalar) { values(\"0\"); } fall_transition(scalar) { values(\"0\"); }")
        if window and "RAM2FAB_D" in name:
            return "".join(f"timing() {{ related_pin : UserCLK ; timing_type : {kind} ; {checks} }} "
                           for kind in ("setup_rising", "hold_rising"))
        if window and re.search(r"FAB2RAM_[CD]", name):
            return f"timing() {{ related_pin : UserCLK ; timing_type : rising_edge ; {launch} }} "
        return ""

    def pin(name, direction, cap):
        clock = "clock : true ; " if name == "UserCLK" else ""
        load = f"capacitance : {float(cap) * 1e12:.6f} ; max_transition : {limit} ; " if direction == "input" else ""
        return f'pin({name}) {{ direction : {direction} ; {clock}{load}{arcs(name)}}}'

    scalars, buses = [], collections.defaultdict(list)
    for line in log.split("### PORTS\n")[1].splitlines():
        name, direction, cap = (line.split() + ["", "", ""])[:3]
        if direction not in ("input", "output"):
            continue
        bus = re.fullmatch(r"(\w+)\[(\d+)\]", name)
        if bus:
            buses[bus.group(1)].append((int(bus.group(2)), direction, cap))
        else:
            scalars.append(pin(name, direction, cap))
    types, groups = [], []
    for bus, bits in sorted(buses.items()):
        top = max(bit for bit, _, _ in bits)
        assert sorted(bit for bit, _, _ in bits) == list(range(top + 1)), f"{bus}: not a whole bus"
        types.append(f"type({bus}_t) {{ base_type : array ; data_type : bit ; bit_width : {top + 1} ; "
                     f"bit_from : {top} ; bit_to : 0 ; downto : true ; }}")
        pins = "\n".join(f"      {pin(f'{bus}[{bit}]', direction, cap)}" for bit, direction, cap in sorted(bits))
        groups.append(f"    bus({bus}) {{ bus_type : {bus}_t ; direction : {bits[0][1]} ;\n{pins}\n    }}")
    assert scalars or groups, "no ports in the log"
    newline = "\n"
    return f"""library(eFPGA__{corner}) {{
  delay_model : table_lookup ;
  time_unit : 1ns ;
  voltage_unit : 1V ;
  current_unit : 1mA ;
  capacitive_load_unit(1, pf);
  pulling_resistance_unit : 1ohm ;
  leakage_power_unit : 1uW ;
  input_threshold_pct_fall : 50 ;
  input_threshold_pct_rise : 50 ;
  output_threshold_pct_fall : 50 ;
  output_threshold_pct_rise : 50 ;
  slew_lower_threshold_pct_fall : 30 ;
  slew_lower_threshold_pct_rise : 30 ;
  slew_upper_threshold_pct_fall : 70 ;
  slew_upper_threshold_pct_rise : 70 ;
  nom_process : 1 ;
  nom_temperature : {temp} ;
  nom_voltage : {volts} ;
  operating_conditions({corner}) {{ process : 1 ; temperature : {temp} ; voltage : {volts} ; }}
  default_operating_conditions : {corner} ;
  {(newline + "  ").join(types)}
  cell(eFPGA) {{
    area : {area:.2f} ;
    {(newline + "    ").join(scalars)}
{newline.join(groups)}
  }}
}}
"""


def main(argv):
    command, *args = argv
    if command == "verdict":
        sys.exit(0 if verdict(args[0], float(args[1]), int(args[2]), args[3:]) else 1)
    if command == "lib":
        width, height = re.search(r"SIZE ([\d.]+) BY ([\d.]+)", Path(args[1]).read_text()).groups()
        Path(args[2]).mkdir(parents=True, exist_ok=True)
        for corner in MAX_TRANSITION:
            log = (Path(args[0]) / f"max_{corner}.log").read_text()
            area = float(width) * float(height)
            (Path(args[2]) / f"eFPGA__{corner}.lib").write_text(macro_lib(log, corner, area))
            (Path(args[2]) / f"eFPGA__{corner}.window.lib").write_text(macro_lib(log, corner, area, window=True))
        return
    run = Run(args[0])
    if command == "tcl":
        lines, summary = run.tcl(args[1], args[2])
        out = Path(args[3])
        out.write_text("\n".join(lines) + "\n")
        (out.parent / "fabric.nl.v").write_text(run.netlist(run.arcs))
        variants = run.variants(run.arcs)
        for corner in MAX_TRANSITION:
            text = Path(args[2].replace("tt_025C_5v00", corner)).read_text()
            (out.parent / f"arcs_{corner}.lib").write_text(arcs_liberty(text, variants, f"efpga_arcs_{corner}"))
        summary["variants"] = len(variants)
        print(" ".join(f"{k}={v}" for k, v in summary.items()))
    elif command == "latches":
        rows = run.latch_values(run.instances)
        wires = ",\n    ".join(f"{args[2]}.{latch.replace('/', '.')}.Q" for latch, _ in rows)
        Path(args[1]).write_text(f"wire [{len(rows) - 1}:0] latches = {{\n    {wires}\n}};\n")
    elif command == "bits":
        print("".join(str(value) for _, value in run.latch_values(run.table(args[1]))))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
