# Reproducing results: the pinned toolchain

Two runtimes are supported. **Nix is the reference**: every signoff and
simulation result the project reports is produced there. The IIC-OSIC-TOOLS
container is a convenience runtime, and its results are labelled as such.

`mosaic doctor` checks a machine against the pins and tells you what to fix.

## Nix (reference)

```bash
nix develop .#sim        # simulation: Verilator 5.050, RISC-V GCC, Icarus, cocotb,
                         # kepler-formal, verible  (also the default shell)
nix develop .#physical   # the LibreLane 3.0.0 shell (same as flow/librelane's)
nix develop .#efpga      # the eFPGA fabric tools: FABulous 2.2.0, Yosys 0.62,
                         # nextpnr-generic 0.9
```

| Tool | Version | Source |
|---|---|---|
| LibreLane | 3.0.0 | `github:librelane/librelane/3.0.0` |
| nix-eda / nixpkgs | 6.11.0 (`8f990fb`) / 25.11 (`b3aad46`) | LibreLane 3.0.0's own lock |
| Verilator (sims) | **5.050** | nix-eda's package, re-pinned |
| RISC-V GCC | 14.3.0, `riscv32-none-elf-` | nixpkgs `pkgsCross.riscv32-embedded` |
| kepler-formal | nix-eda 7.5.0 | the revision `run_lec.sh` last resolved |
| Icarus, cocotb, verible | nix-eda 6.11 / nixpkgs 25.11 | |
| FABulous (eFPGA) | 2.2.0 | PyPI, by hash: `util/efpga-requirements.txt` |
| Yosys, nextpnr-generic (eFPGA) | 0.62 / 0.9 | nix-eda 6.11 / nixpkgs 25.11 |

Why these pins:

- **LibreLane's own nix-eda and nixpkgs.** The signoff results in
  [physical-flow.md](physical-flow.md) were produced under exactly these
  binaries (`flow/librelane/flake.lock`). The root `flake.lock` pins the same
  three revisions, and `test/test_mosaic_gen/test_toolchain_pin.py` fails if the
  two ever disagree.
- **Verilator 5.050, not nix-eda's 5.044.** A 5.047 development build
  miscompiles the load-use hazard logic of cv32e40x, so that core computes wrong
  results in simulation with no warning. 5.050 is the release the full-SoC
  regression passed on. 5.044 was never checked.
- **Separate shells, not one.** LibreLane puts nix-eda's Verilator (5.044) on its
  PATH, and its lint step calls `verilator` by name. Merging the sim shell into
  it would silently change a tool inside the signoff flow.

The first `nix develop .#sim` builds Verilator 5.050 locally (about 10 minutes).
Everything else is a binary-cache hit.

**Disk.** A flake inside a git repository is evaluated from a store copy of the
tracked tree. A dirty tree makes a new copy each time its content changes.
Reclaim the space with `nix-collect-garbage` when no run is in progress.

### The eFPGA shell

`nix develop .#efpga` adds no flake input: Yosys and nextpnr are the locked
nix-eda and nixpkgs packages. Neither nix-eda nor nixpkgs packages FABulous,
so its Python layer is a separate environment, `build/efpga_env/venv`, which
the shell builds on first entry with
`uv pip sync --no-build --require-hashes` from `util/efpga-requirements.txt`.
That file is FABulous 2.2.0's own lock, exported by `util/efpga-lock.sh`, with
one substitution (`sdf-timing`, see [efpga.md](efpga.md)). uv runs with
`--require-hashes`, which rejects a wheel whose hash differs. The first entry
needs network access to PyPI and about 540 MB under `build/`. Enter the shell
from the repository root: elsewhere it builds nothing.

The environment contains a LibreLane wheel that FABulous depends on. It must
never meet the signoff flow, so of that environment the shell puts only two
entry points on `PATH`, `FABulous` and `bit_gen`, and no Python; `uv`, Yosys
and nextpnr come from Nix. Do not activate the environment. Entered from
inside the sim shell it adds no Verilator, so Verilator stays 5.050.

The eFPGA runners (`tb/efpga/run.sh`, `tb/efpga/run_wrapper.sh`,
`tb/mosaic_soc/run_efpga.sh`, `tb/mosaic_soc/run_fw.sh` with
`EFPGA_DESIGN`, and the synthesis, `flow/librelane/scripts/efpga_synth.sh`)
enter this shell by themselves. `util/mosaic_gen/efpga_gen.py`
checks the three versions before it runs anything and refuses others;
`mosaic doctor` does not check them. [efpga.md](efpga.md) describes what the
tools produce.

### The testbench runners refuse, they don't guess

Every runner that calls Verilator sources `tb/tools.sh`:

- **Verilator:** `$VERILATOR_PIN` (an install prefix, `bin/` or `usr/bin/`)
  if set. Otherwise `verilator` on `PATH`, but only if it reports 5.050.
  Otherwise the runner **stops** and names the fix.
- **RISC-V GCC:** `$RISCV_TC` (e.g. `<dir>/bin/riscv32-unknown-elf`) if
  set, otherwise the first `riscv32-*-elf-gcc` on `PATH`, otherwise stop.

A silent fallback to whatever is on `PATH` would let an unchecked Verilator
decide a verdict, and nothing in a simulation log says which Verilator built the
model.

`mosaic flow-runner run <flow>` enters `nix develop <repo>#sim` by itself
when it is not already inside a nix shell. It does not do this for three flows:
- `harden-*`, where LibreLane brings its own environment;
- `pytest`, which runs the harness's own Python;
- `gls`, whose recorded results were produced with Icarus Verilog 13.0 from the
  host. nix-eda ships a different Icarus snapshot, so moving gate-level
  simulation into the shell means re-running those results.

### Python

`.venv/` (from `make venv`) stays the Python layer. `util/python-requirements.txt`
pins every git dependency to an exact commit:
- FuseSoC is pinned to commit `c36dffc` of the X-HEEP fork.
- edalize is pinned to 0.6.8 from PyPI.

## IIC-OSIC-TOOLS (convenience)

```bash
tools/iic-osic.sh                    # shell in hpretl/iic-osic-tools:2026.09
tools/iic-osic.sh klayout run.gds    # one command
```

This mounts the repo root at `/workspace`, runs as your user, and exports
`MOSAIC_TOOLCHAIN=iic:2026.09`. The tag is pinned; `latest` is never used.

It is not the reference because its tools are other versions:

| | IIC 2026.09 | Nix reference |
|---|---|---|
| Magic / KLayout / Netgen | 8.3.684 / 0.30.12 / 1.5.323 | 8.3.623 / 0.30.7 / 1.5.316 |
| Yosys | 0.69 | 0.62 |
| Verilator | 5.052 | 5.050 |

Different signoff tools can give different DRC/LVS verdicts. So:
- `mosaic doctor` reports the `iic:<tag>` runtime.
- The evidence store folds the runtime into the tool digest
  (`harness/evidence/store.py`), so a run recorded there never shares a key
  with a nix-made run.

Use the container for viewing layouts and for machines without Nix. Make
claims from Nix runs only.

## Checking a machine

```bash
mosaic doctor           # human-readable
mosaic --json doctor    # for scripts; exits 1 when a required tool is off-pin
```

`doctor` reports:
- the runtime;
- each tool, required or advisory, with its version and the fix;
- where each open PDK is installed: `gf180mcuD` in the repository clone made by
  `make -C flow/librelane clone-pdk`, and `sky130A` and `ihp-sg13g2` under
  `~/.ciel`.

It warns when the shell exports `PDK_ROOT`/`PDK`, because
`flow/librelane/Makefile` uses `?=` and yields to them. (`run_signoff.sh`
passes `--pdk-root` explicitly and is unaffected.)
