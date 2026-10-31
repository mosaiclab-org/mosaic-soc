# AGENTS.md

Instructions for AI coding agents working in this repository. Read this file
before changing anything.

## What this project is

MOSAIC-SoC is a generator. One YAML file describes a multi-core RISC-V system on
chip, and the generator produces its RTL, boot images, a simulation testbench
and the inputs of a GF180MCU physical flow. It is a fork of X-HEEP and keeps
X-HEEP's build system (FuseSoC, Mako templates). The SoC module is
`mosaic_soc` and its pad-ring wrapper is `mosaic_system`; in X-HEEP they are
`core_v_mini_mcu` and `x_heep_system`.

Start with [docs/architecture.md](docs/architecture.md). The other pages in
`docs/` are the reference for configuration, cores, verification, the physical
flow and current status.

## Rules that prevent damage

1. **Never commit generated RTL.** Files rendered from `*.sv.tpl` templates are
   build products. Only the templates and the generator are version controlled.
   Generated bundles go to `build/mosaic/`, which is ignored.
2. **Regenerate after every template or generator change.** Run
   `make mosaic-gen MOSAIC_CFG=<config>` before any simulation or hardening.
   Stale generated RTL produces failures that point away from their cause.
3. **Never bypass a signoff check.** Do not add `--skip`, do not null or
   substitute a flow step, do not use the `*-nodrc` targets for a result, and do
   not use `git commit --no-verify`. `flow/librelane/experimental/run_signoff.sh`
   has no skip option on purpose.
4. **A waiver is a decision about silicon.** Do not add or widen an entry in
   `flow/librelane/signoff_waivers.yaml` to make a run pass. Fix the violation,
   or ask the user.
5. **An exit code of 0 is not a pass.** A full-SoC simulation passes only when
   its log contains `EXIT SUCCESS`. Use `./mosaic flow-runner run <flow>`, which
   checks the marker.
6. **Do not edit vendored code** under `hw/vendor/` except `hw/vendor/mosaic/`,
   and record any local change to a vendored core in its `UPSTREAM` or `.core`
   file.
7. **Do not hand-write configurations or wrappers from nothing.** Use
   `./mosaic config-author` and `./mosaic wrapper-smith`, then edit their
   output.
8. **Do not change `soc.target: tapeout` rules** in `core_registry.py` without a
   hardened design that justifies it. That matrix states what has physical
   evidence.
9. **Report what you ran.** State the command and its real result. Do not claim
   a simulation or hardening result you did not observe.
10. **Never run the `FABulous` command directly.** It can download a PDK: into
    `~/.ciel` through the efpga shell's command, which unsets `PDK_ROOT`, and
    into `$PDK_ROOT` if the environment's own entry point is called. Generate
    an eFPGA fabric only through `util/mosaic_gen/efpga_gen.py` or its
    callers: `mcu_gen.py` (`make mosaic-gen` on a configuration with
    `soc.efpga`), `tb/efpga/run.sh`, `tb/efpga/run_wrapper.sh`,
    `tb/mosaic_soc/run_efpga.sh`, `tb/mosaic_soc/run_fw.sh` with
    `EFPGA_DESIGN`, `tb/efpga/run_netlist.sh` and
    `flow/librelane/scripts/efpga_synth.sh`. It removes
    the PDK variables and gives the tools their own `HOME`
    ([docs/efpga.md](docs/efpga.md)).

## The three things a new core needs

1. A registry entry: a `CoreSpec` in `util/mosaic_gen/core_registry.py`, and the
   name in `AVAILABLE_CPUS` in `util/mosaic_gen/cpu/cpu.py`.
2. A wrapper `hw/sci/<core>_sci.sv` that converts the core's native bus to OBI,
   listed in `hw/sci/sci.core`, with the core's RTL vendored under
   `hw/vendor/mosaic/<core>/`.
3. A branch `% elif group.name == "<core>":` in
   `hw/mosaic_soc/cpu_subsystem.sv.tpl`.

`./mosaic wrapper-smith analyze` and `scaffold` do the mechanical part. The core
is not integrated until `./mosaic tb-smith run <core>` prints `TB PASS` and
`./mosaic tb-smith wake-demo <core>` reaches `EXIT SUCCESS`. See
[docs/cores.md](docs/cores.md).

## Where things live

| Path | Contents |
|---|---|
| `mosaic.yaml`, `configs/` | configurations; `configs/efpga/` holds the eFPGA fabric presets |
| `util/mosaic_gen/` | the generator. `core_registry.py` is the single source of supported cores, buses, PDKs and configuration rules. `efpga_gen.py` generates an eFPGA fabric and its bitstreams, and the fabric of `soc.efpga` into a bundle |
| `hw/mosaic_soc/*.sv.tpl` | SoC templates |
| `hw/sci/` | core wrappers |
| `hw/tdu/` | Task Dispatch Unit and CLINT |
| `hw/efpga/` | the wrapper that makes an eFPGA fabric a bus peripheral; `soc.efpga` puts it in `mosaic_soc` |
| `hw/vendor/mosaic/` | vendored cores, iDMA, FlooNoC, bus bridges |
| `sw/` | device libraries and firmware |
| `tb/` | testbenches; `tb/mosaic_soc/` is the full-SoC bench, `tb/efpga/` holds the benches of the eFPGA fabric and of its wrapper |
| `flow/librelane/` | the physical flow, the signoff template and the waivers |
| `harness/` | the `mosaic` command-line tool and its gates |
| `.claude/skills/` | one card per `mosaic` skill: when to use it, the command, the failure playbook |
| `plugins/mosaic/`, `.omp/` | agent host integration |
| `test/test_mosaic_gen/` | the Python suite |
| `build/` | all generated output, never committed |

## How to run the checks

Environment (see [docs/reproducing.md](docs/reproducing.md)):

```bash
make venv              # Python environment in .venv/
nix develop .#sim      # Verilator 5.050, RISC-V GCC, Icarus, cocotb
nix develop .#efpga    # FABulous 2.2.0, Yosys 0.62, nextpnr 0.9; the eFPGA runners enter it themselves
./mosaic doctor        # verify the tools against the pins
```

Cheap checks, in order of cost:

```bash
./mosaic config-author validate <config>         # schema and topology rules
./mosaic topo-viz check <config>                 # derived-design checks
python3 -m pytest test/test_mosaic_gen/<file>.py -q   # one test file
./mosaic tb-matrix run --tier validate           # every pairwise combination
make test                                        # the whole Python suite
```

Generation and simulation:

```bash
./mosaic flow-runner run mosaic-gen-config --config <config>
./mosaic flow-runner run tb-soc-generic    --config <config>   # every hart must report
./mosaic flow-runner list                                      # all flows
scripts/run_sweep.sh --only <regex>                            # part of the regression sweep
```

Physical flow (hours; needs the user's approval):

```bash
./mosaic flow-preflight harden --soc-config <config> --tag <tag>
./mosaic physical-intent ppa --run-dir <run>
./mosaic waiver-author
```

## Working through the gated tools

When this repository is installed as a plugin or driven by `mosaic agent`, use
the `mosaic` MCP tools rather than a shell:

1. `session_new` with the user's request, verbatim.
2. `request_scope` with a scope the installation allows.
3. The tools for the task, in gate order: `topology_check` before generation,
   generation before simulation.
4. `session_status` before reporting success, and report its verdict.

`physical` and `integration` actions need a person to run
`mosaic approve <scope>` in a terminal. Do not try to obtain that approval
yourself. See [docs/agent-harness.md](docs/agent-harness.md).

## Conventions

- SystemVerilog: `lowercase_snake_case`, explicit types, packed structs, no
  hard-coded bus master or slave indices (use the constants in
  `mosaic_soc_pkg`).
- Mako: a `%` control line must be the first non-blank character on its line. An
  inline `% if` is emitted as literal text.
- Python: follow the surrounding module; `make format-python` runs `black`.
- New MOSAIC files are licensed `Apache-2.0 WITH SHL-2.1` (see `LICENSE`) and
  say so in an SPDX header. Upstream files keep their own licence.
- The DMA default is `soc.dma: idma`. Do not change the default.
