# Verification

This page describes the checks that ship with the repository, from the smallest
to the largest, and how to run each one. The simulation tools must be the pinned
versions; `nix develop .#sim` provides them ([reproducing.md](reproducing.md)).
The runners refuse a Verilator other than 5.050 instead of using whatever is on
`PATH`.

## One rule: the exit code is not the verdict

Several runners exit 0 after printing a failure. Every full-SoC bench therefore
ends by printing a marker line, and a run passes only if that line is present:

```
EXIT SUCCESS
```

The simulated program reaches this by writing an exit value of zero to the SoC
controller, through the real bus. The `mosaic flow-runner` command requires the
marker at the start of a line and treats its absence as a failure even when the
process exits 0. The regression sweep requires exit status 0 and the marker; for
the full-SoC steps other than the seven eFPGA ones its marker also matches the
line a runner prints on failure, so there the exit status decides.

## Testbench tiers under `tb/`

| Directory | What is tested | Simulator | Entry point |
|---|---|---|---|
| `hw/tdu/tb/` | the TDU and the CLINT alone, at register level | Verilator | testbench sources `tdu_tb.sv`, `mosaic_clint_tb.sv`; no script runs them |
| `tb/tdu/soc/` | the TDU at its SoC address, through the always-on peripheral bus tap | cocotb + Verilator | `tb/tdu/soc/cocotb/run.sh` |
| `tb/idma/` | the iDMA wrapper: 1D, 2D and 3D copies, stream ownership, interrupt | cocotb + Verilator | `tb/idma/cocotb/run.sh` |
| `tb/log_xbar/` | the logarithmic bus fabric | Verilator | `tb/log_xbar/run.sh` |
| `tb/floonoc/` | the OBI and AXI bridges, then the generated network on chip | cocotb + Verilator | `tb/floonoc/cocotb/run.sh`, `tb/floonoc/cocotb/run.sh stage2` |
| `tb/tl_obi/` | the TileLink to OBI bridge used by Rocket and BOOM | Verilator | `tb/tl_obi/run.sh` |
| `tb/sci/<core>/` | one SCI wrapper with its core: dormancy, wake, execution | Verilator | `tb/sci/<core>/run.sh` (serv, fazyrv, picorv32, hazard3) |
| `tb/efpga/` | a generated eFPGA fabric alone, configured with a real bitstream; then the wrapper that makes it a bus peripheral and a worker of the TDU, with the bench as bus master and as the TDU ([efpga.md](efpga.md)); with `EFPGA_NETLIST`, both on the hardened fabric macro, in Verilator only (`efpga_netlist`, [efpga.md](efpga.md#hardening-for-gf180mcu)) | Icarus Verilog and Verilator | `tb/efpga/run.sh`, `tb/efpga/run_wrapper.sh` |
| `tb/mosaic/` | the generated `cpu_subsystem` with three serial cores and per-hart memories | Verilator; cocotb for the wake loop | `tb/mosaic/run.sh`, `tb/mosaic/cocotb/run.sh` |
| `tb/mosaic_soc/` | the complete generated SoC | Verilator | see below |
| `tb/gls/` | the placed-and-routed netlist | Icarus Verilog | `tb/gls/run_gls.sh` |

cocotb is a Python testbench framework that drives a simulator.

## Full-SoC benches

Each runner in `tb/mosaic_soc/` generates the RTL for the configuration named by
the `MOSAIC_CFG` environment variable, builds firmware, builds a Verilator model
of the whole SoC inside X-HEEP's test harness, and runs it.

| Runner | Flow name | What it proves |
|---|---|---|
| `run_generic.sh` | `tb-soc-generic` | Works for any configuration. Reads the generated `boot_images.json`, builds one liveness image per boot slot, wakes every worker through the TDU, and prints `EXIT SUCCESS` only after every configured hart has written its own value `hart + 1` to its sentinel word. |
| `run.sh` | `tb-soc-wake` | The three-hart wake demonstration: the `titan` boots from the boot ROM, wakes two workers through the TDU, each worker runs its own program and reports. |
| `run_titan.sh` | `tb-soc-titan` | Four `titan` harts as a symmetric multiprocessor running one program that branches on the hart identifier. |
| `run_fw.sh` | `tb-soc-fw` | The deployable firmware image on the default seven-hart design, loaded only through the SPI flash model: boot ROM hand-off, execution in place, worker image copy with checksum, TDU dispatch. With `EFPGA_DESIGN=<design>.v`, on a design with `soc.efpga`, the user design compiled for the fabric and loaded at cold boot, and with `EFPGA_TEST=<test>.c` the user's C check of it; with `WARM_REBOOTS=1` again after a reset that keeps power, through its unload (sweep step `efpga_design`, with `tb/efpga/shell_regs.v` and `shell_regs_test.c`, and without a reboot on the LOG and FlooNoC buses with a SERV hart 0 and on the 8x8 preset, `efpga_log`, `efpga_floonoc`, `efpga_serv` and `efpga_medium`; [efpga.md](efpga.md#a-users-design)); with `tb/efpga/task_count.v` and `task_count_test.c`, tasks given to the fabric through the TDU (`efpga_task`, [efpga.md](efpga.md#as-a-worker-of-the-tdu)). |
| `run_uart.sh` | (sweep only) | The UART of a design whose only peripheral is the UART. |
| `run_efpga.sh` | (sweep only) | The wake-demonstration SoC generated with `soc.efpga`: hart 0 loads a bitstream through the wrapper's registers, uses the user design in its window, unloads it and loads it again; then the production firmware boots from flash past a stream its loader refuses, and into a user's check that must report its value. Seven firmware runs, five of which must fail with a named exit value ([efpga.md](efpga.md)). |

Run one directly or through the tool:

```bash
MOSAIC_CFG=configs/mosaic_picorv32.yaml tb/mosaic_soc/run_generic.sh

./mosaic flow-runner run mosaic-gen-config --config configs/mosaic_picorv32.yaml
./mosaic flow-runner run tb-soc-generic    --config configs/mosaic_picorv32.yaml
```

`./mosaic flow-runner list` prints all 21 registered flows. A flow run outside a
Nix shell enters `nix develop .#sim` by itself, except the hardening flows, the
Python suite and gate-level simulation.

## The regression sweep

`scripts/run_sweep.sh` runs every suite in sequence: the Python suite, the
`tb-matrix` validation tier, the subsystem benches, the wrapper benches, the
ten eFPGA steps, the wake demonstration on each fabric and for each wrapped
core, the multiprocessor demonstration on each fabric, the firmware run, and
the Block A checks including gate-level simulation. It has 44 steps. One of
them, `efpga_netlist`, runs only when named: it hardens the fabric of `small`,
times it at nine corners and simulates its netlist, 3.7 hours. Each step has a success marker that must
appear in its log, and the script exits non-zero if any step fails.

```bash
scripts/run_sweep.sh --list                 # print the step names
scripts/run_sweep.sh --only wake            # steps whose name matches
scripts/run_sweep.sh --only efpga_netlist   # a step run only when named, in full
scripts/run_sweep.sh                        # everything else; logs under build/sweep/
```

The gate-level step, `efpga_synth` and `efpga_netlist` need the GF180MCU PDK
clone on disk (`make -C flow/librelane clone-pdk`), the gate-level step also a
hardened run; see below. The `efpga_*` steps enter `nix develop .#efpga` by themselves, and
the first entry downloads its Python environment from PyPI
([reproducing.md](reproducing.md#the-efpga-shell)); `efpga_synth` also enters
`nix develop .#physical`, and `efpga_netlist` both `.#fabric` and `.#physical`.

## tb-matrix: coverage of the design space

The shipped configurations are examples. `tb-matrix` tests the space the
generator accepts. It derives 11 axes from the core registry (topology shape,
orchestrator core, worker core, second worker, counts, instruction-set and
parameter variants, bus, scheduler mode, SRAM size, peripheral set) and builds:

- a **pairwise covering array**: a set of configurations in which every legal
  pair of values of every two axes appears at least once. It currently has 248
  configurations. Pairs that no legal configuration can contain are reported as
  blocked, each with the rule that blocks it (68 at present), never dropped
  silently;
- a **curated simulation set** of 30 configurations: every core as a woken
  worker, each fabric with each port shape, and the corner cases.

Each configuration then passes through tiers of increasing cost:

```bash
./mosaic tb-matrix axes                      # the derived axes
./mosaic tb-matrix plan --tier render        # list the configurations
./mosaic tb-matrix run --tier validate       # schema check, seconds for all
./mosaic tb-matrix run --tier render --limit 20   # generate RTL for each
./mosaic tb-matrix run --tier sim --limit 5       # run_generic.sh on each
./mosaic tb-matrix report
```

Results accumulate in `build/tb_matrix/report.json`, and a rerun skips what
already passed. The `validate` tier covers all 248 configurations; the `sim`
tier covers the 30 curated ones. A failure in the report is a defect in the
generator for a combination nobody had tried.

## Gate-level simulation

Gate-level simulation (GLS) runs the netlist produced by place and route, with
the PDK's own cell models, instead of the RTL. `tb/gls/run_gls.sh` boots the
netlist from a behavioural SPI flash model and observes only the pins of the
delivery wrapper: no memory is preloaded and no internal signal is forced.

```bash
GLS_RUN=flow/librelane/experimental/runs/<tag> tb/gls/run_gls.sh
./mosaic gls-triage flow/librelane/experimental/runs/<tag>
```

It needs the run's `final/` netlist and the PDK clone, neither of which is in
version control, so it can be run only after a hardening run on the same
machine.

What it does and does not establish:

- It is a functional check. The GF180MCU cell models cannot be timing-annotated
  under Icarus, so the runner refuses `--sdf` rather than run without delays and
  call the result timing-annotated. Timing is established by static timing
  analysis at nine corners.
- Flip-flops without reset start with a deposited value, from a per-design list
  written by `tb/gls/gen_powerup_init.py`. Without it the unknown state
  propagates and the netlist never fetches an instruction.
- A pass is reported in the run's metrics but is not one of the signoff hard
  checks.

Details are in `tb/gls/README.md`. `gls-triage` reads a GLS log and states what
the verdict can support.

Equivalence checking between the netlist and the RTL is wired as the `lec` flow
(`flow/librelane/scripts/run_lec.sh`, using kepler-formal). It does not yet
produce a usable verdict on these designs.

## The Python suite

```bash
make venv                                  # once
make test                                  # or:
python3 -m pytest test/test_mosaic_gen -q
```

The suite covers configuration validation, template rendering, the software
layout, the harness gates, the physical models, the evidence parsers, and the
eFPGA generator's tool pins, PDK isolation and frame order (with fake tools:
no test runs FABulous). The
measured result on this tree is **1875 passed and 94 skipped**. Most skipped
tests need hardening run trees or a PDK clone that are not in version control.
One is skipped when no `riscv64-unknown-elf-gcc` is on the host, and
`test_socview.py` adds one test per bundle under `build/mosaic/` whose
configuration file is unchanged (56 here), so the counts depend on the
machine.
Tests marked `slow` build or run an RTL simulator.

Run one file while working:

```bash
python3 -m pytest test/test_mosaic_gen/test_bus_types.py -q
```
