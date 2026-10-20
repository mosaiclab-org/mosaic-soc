# MOSAIC-SoC pinned toolchain (see docs/reproducing.md).
#
#   nix develop .#sim        simulation: Verilator 5.050, RISC-V GCC, Icarus,
#                            cocotb, kepler-formal, verible  (also `default`)
#   nix develop .#physical   the LibreLane 3.0.0 shell, identical to
#                            flow/librelane/flake.nix's
#   nix develop .#efpga      the eFPGA fabric tools: FABulous 2.2.0, Yosys 0.62,
#                            nextpnr-generic 0.9 (see docs/efpga.md)
#
# Separate shells, never one merged shell: LibreLane puts nix-eda's own Verilator
# (5.044) on PATH and its lint step calls `verilator` by name. Putting 5.050
# in the same shell would silently change a tool inside the signoff flow,
# which the existing Block A/B/C evidence was not produced with.
#
# Every revision is LibreLane 3.0.0's own: librelane -> nix-eda 6.11.0 ->
# nixpkgs 25.11. flow/librelane/flake.lock pins the same three, and
# test/test_mosaic_gen/test_toolchain_pin.py fails if the two locks disagree.
{
  nixConfig = {
    extra-substituters = [
      "https://nix-cache.fossi-foundation.org"
    ];
    extra-trusted-public-keys = [
      "nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs="
    ];
  };

  inputs = {
    librelane.url = "github:librelane/librelane/3.0.0";
    # Not used by the outputs: `nix develop` takes bashInteractive from an input
    # named `nixpkgs`, and without one it fetched the UNPINNED registry
    # nixpkgs-unstable on every first use.
    nixpkgs.follows = "librelane/nix-eda/nixpkgs";
    # kepler-formal is not in nix-eda 6.11. 7.5.0 is the revision run_lec.sh
    # last resolved from nix-eda HEAD (2026-08-12); pinning it replaces that
    # unpinned `nix shell github:fossi-foundation/nix-eda#kepler-formal`.
    nix-eda-lec.url = "github:fossi-foundation/nix-eda/7.5.0";
  };

  outputs =
    {
      self,
      librelane,
      nix-eda-lec,
      ...
    }:
    let
      nix-eda = librelane.inputs.nix-eda;
      devshell = librelane.inputs.devshell;
      nixpkgs = nix-eda.inputs.nixpkgs;
    in
    {
      legacyPackages = nix-eda.forAllSystems (
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            nix-eda.overlays.default
            devshell.overlays.default
            librelane.overlays.default
          ];
        }
      );

      packages = nix-eda.forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};
          # Plain nixpkgs: the EDA overlays do not touch GCC, and leaving them
          # out keeps the cross toolchain a binary-cache hit where one exists.
          cross = (import nixpkgs { inherit system; }).pkgsCross.riscv32-embedded.buildPackages;
        in
        {
          # The 5.047 devel DFG optimizer miscompiles cv32e40x's
          # load-use hazard. 5.050 is the release the full-SoC regression
          # passed on; nix-eda 6.11 ships 5.044, which was never checked.
          verilator =
            (pkgs.verilator.override {
              version = "5.050";
              sha256 = "sha256-ZOwBBbVNP0PaYUvrjdvbWu88fZOZ6IJ8BHAiajcOjP8=";
            }).overrideAttrs
              {
                VERILATOR_SRC_VERSION = "v5.050";
                # nixpkgs' postPatch rewrites a /bin/echo that 5.050's
                # bin/verilator no longer contains (--replace-fail aborts).
                postPatch = ''
                  patchShebangs bin src nodist docs/bin ci test_regress/driver.py
                '';
                # ponytail: upstream's regression suite is skipped (it doubles
                # the build); the full-SoC testbenches are the acceptance test.
                doCheck = false;
              };

          # One bin/ with gcc AND binutils: the boot ROM Makefile calls
          # $(RISCV_XHEEP)/bin/$(COMPILER_PREFIX)elf-{gcc,objcopy,objdump}.
          riscv-toolchain = pkgs.symlinkJoin {
            name = "riscv32-none-elf-toolchain";
            paths = [
              cross.gcc
              cross.binutils
            ];
          };

          kepler-formal = nix-eda-lec.packages.${system}.kepler-formal;
        }
      );

      devShells = nix-eda.forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};
          own = self.packages.${system};
          sim = pkgs.mkShell {
            packages = [
              own.verilator
              own.riscv-toolchain
              own.kepler-formal
              pkgs.iverilog
              pkgs.gtkwave
              pkgs.verible
              pkgs.gnumake
              (pkgs.python3.withPackages (ps: [ ps.cocotb ]))
            ];
            # tb/tools.sh reads RISCV_TC instead of guessing from PATH; the boot
            # ROM Makefile (via `make mosaic-gen`) reads the other two.
            RISCV_TC = "${own.riscv-toolchain}/bin/riscv32-none-elf";
            RISCV_XHEEP = "${own.riscv-toolchain}";
            COMPILER_PREFIX = "riscv32-none-";
            MOSAIC_TOOLCHAIN = "nix";
            # The Python layer stays the repo's .venv (util/python-requirements.txt):
            # FuseSoC's generators call a bare `python` that needs pyyaml, hjson
            # and mako, which the cocotb-only interpreter above lacks. cocotb's
            # Makefiles find their own interpreter through cocotb-config.
            # mkShell exports the HOST binutils as OBJCOPY/OBJDUMP, and the boot
            # ROM Makefile's `OBJCOPY?=` keeps them: host objcopy then fails on
            # the RISC-V ELF ("Unable to recognise the format"). Unset, the
            # Makefile picks $(RISCV_XHEEP)/bin/...-objcopy, and the boot ROM
            # is byte-identical to the one the /opt toolchain built for Block A.
            shellHook = ''
              unset OBJCOPY OBJDUMP
              if [ -x "$PWD/.venv/bin/python" ]; then
                export PATH="$PWD/.venv/bin:$PATH"
              else
                echo "note: no $PWD/.venv -- run 'make venv' for the generator's Python" >&2
              fi
            '';
          };

          # FABulous 2.2.0 and its user flow: Yosys synth_fabulous, nextpnr-generic
          # --uarch fabulous, bit_gen. Entered on its own or from inside the sim
          # shell (`nix develop .#efpga --command ...`), where it only adds tools:
          # no python goes on PATH, so .venv's stays in front. No new flake input:
          # every binary is from the locked nixpkgs and nix-eda.
          # util/mosaic_gen/efpga_gen.py checks the three versions before it runs.
          efpga =
            let
              python = pkgs.python312; # FABulous needs >= 3.12; its CI runs 3.12
              # numpy's manylinux wheel loads libstdc++ and libz from the system.
              libs = pkgs.lib.makeLibraryPath [
                pkgs.stdenv.cc.cc.lib
                pkgs.zlib
              ];
            in
            pkgs.mkShell {
              packages = [
                pkgs.uv
                pkgs.yosys # nix-eda 6.11: Yosys 0.62, the one LibreLane runs
                pkgs.nextpnr # nixpkgs 25.11: nextpnr-generic 0.9
              ];
              UV_PYTHON_DOWNLOADS = "never";
              # The Python layer is build/efpga_env/venv, synced from the
              # hash-locked util/efpga-requirements.txt. The stamp names the
              # interpreter, the lock's hash and the checkout path, so a change
              # to any of them rebuilds it. It holds a librelane wheel (a
              # FABulous dependency) that must never meet the signoff flow, so
              # of the venv only two entry points (FABulous, bit_gen) go on
              # PATH, through one wrapper that scopes LD_LIBRARY_PATH to them.
              # The wrapper also drops the PDK variables: with them FABulous
              # downloads a PDK into $PDK_ROOT (docs/efpga.md). FABulous
              # imports tkinter at start-up, which nixpkgs builds apart: the
              # .pth file gives it to this venv.
              # Nothing is built or put on PATH unless the requirements file is
              # there, so entering from another directory litters nothing.
              shellHook = ''
                unset OBJCOPY OBJDUMP # as in the sim shell: this shell re-exports them
                efpga_req="$PWD/util/efpga-requirements.txt"
                efpga_dir="$PWD/build/efpga_env"
                if [ ! -f "$efpga_req" ]; then
                  echo "efpga: no $efpga_req: enter this shell from the repository root" >&2
                else
                  efpga_want="${python} $(sha256sum "$efpga_req")"
                  if [ "$(cat "$efpga_dir/venv/.lock-sha256" 2>/dev/null)" != "$efpga_want" ]; then
                    echo "efpga: building $efpga_dir/venv from $efpga_req" >&2
                    rm -rf "$efpga_dir/bin"
                    mkdir -p "$efpga_dir" &&
                      uv venv --quiet --clear --python ${python.interpreter} "$efpga_dir/venv" &&
                      uv pip sync --quiet --no-build --python "$efpga_dir/venv/bin/python" --require-hashes "$efpga_req" &&
                      echo "${python.pkgs.tkinter}/${python.sitePackages}" \
                        > "$efpga_dir/venv/${python.sitePackages}/nix-tkinter.pth" &&
                      echo "$efpga_want" > "$efpga_dir/venv/.lock-sha256" ||
                      echo "efpga: the venv was NOT built; FABulous is not available" >&2
                  fi
                  if [ "$(cat "$efpga_dir/venv/.lock-sha256" 2>/dev/null)" = "$efpga_want" ]; then
                    mkdir -p "$efpga_dir/bin"
                    printf '#!/bin/sh\nunset PDK_ROOT PDK PDKPATH FAB_PDK FAB_PDK_ROOT\nLD_LIBRARY_PATH=%s PYTHONPATH= exec "%s/$(basename "$0")" "$@"\n' \
                      "${libs}" "$efpga_dir/venv/bin" > "$efpga_dir/bin/FABulous"
                    chmod +x "$efpga_dir/bin/FABulous"
                    ln -sf FABulous "$efpga_dir/bin/bit_gen"
                    export PATH="$efpga_dir/bin:$PATH"
                  fi
                fi
              '';
            };
        in
        {
          inherit sim efpga;
          default = sim;

          physical = pkgs.librelane-shell.override {
            extra-packages = with pkgs; [
              gnumake
              gnugrep
              gawk
              iverilog
              verilator
              gtkwave
              surfer
            ];
            extra-python-packages =
              ps: with ps; [
                cocotb
                docopt
                pillow
              ];
          };
        }
      );
    };
}
