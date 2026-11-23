# tb/tools.sh -- sourced by every testbench runner; resolves Verilator and the
# RISC-V toolchain, and REFUSES instead of falling back to whatever is on PATH.
#
# A silent fallback to PATH is unsafe: a Verilator 5.047 development build
# miscompiles cv32e40x, and nothing in the simulation log says which Verilator
# produced the model.
#
# The reference toolchain is the root flake: `nix develop .#sim` provides both
# tools and sets RISCV_TC. harness/toolchain.py PINS must name the same version
# (test_toolchain_pin.py checks it).

MOSAIC_VERILATOR_VERSION="5.050"

# Verilator: $VERILATOR_PIN (an install prefix, bin/ or usr/bin/) if set;
# else PATH's verilator, only when it IS the pinned release.
mosaic_need_verilator() {
  if [ -n "${VERILATOR_PIN:-}" ]; then
    local bin
    for bin in "$VERILATOR_PIN/usr/bin" "$VERILATOR_PIN/bin"; do
      if [ -x "$bin/verilator" ]; then
        export PATH="$bin:$PATH"
        [ -d "$bin/../share/verilator" ] && export VERILATOR_ROOT="$(cd "$bin/../share/verilator" && pwd)"
        echo "verilator: $bin/verilator [$(verilator --version)] (VERILATOR_PIN)"
        return 0
      fi
    done
    echo "ERROR: VERILATOR_PIN=$VERILATOR_PIN has no bin/verilator or usr/bin/verilator" >&2
    exit 2
  fi
  local found
  found="$(verilator --version 2>/dev/null)"
  case "$found" in
    "Verilator $MOSAIC_VERILATOR_VERSION "*)
      echo "verilator: $(command -v verilator) [$found]"
      return 0 ;;
  esac
  echo "ERROR: Verilator $MOSAIC_VERILATOR_VERSION required; PATH has: ${found:-none}" >&2
  echo "  fix: nix develop .#sim          (the pinned toolchain)" >&2
  echo "   or: export VERILATOR_PIN=<install prefix of a $MOSAIC_VERILATOR_VERSION build>" >&2
  exit 2
}

# RISC-V GCC: sets TC to the tool prefix (".../bin/riscv32-<vendor>-elf").
# $RISCV_TC if set; else the first riscv32-*-elf-gcc on PATH.
mosaic_need_riscv_tc() {
  if [ -n "${RISCV_TC:-}" ]; then
    TC="$RISCV_TC"
  else
    local dir gcc
    TC=""
    IFS=: read -ra _mosaic_path <<< "$PATH"
    for dir in "${_mosaic_path[@]}"; do
      for gcc in "$dir"/riscv32-*-elf-gcc; do
        if [ -x "$gcc" ]; then TC="${gcc%-gcc}"; break 2; fi
      done
    done
  fi
  if [ -z "$TC" ] || [ ! -x "$TC-gcc" ]; then
    echo "ERROR: no RISC-V toolchain (RISCV_TC=${RISCV_TC:-unset}, no riscv32-*-elf-gcc on PATH)" >&2
    echo "  fix: nix develop .#sim          (the pinned toolchain)" >&2
    echo "   or: export RISCV_TC=<dir>/bin/riscv32-unknown-elf" >&2
    exit 2
  fi
}

# EFPGA_DESIGN of run_fw.sh and run_generic.sh, with the bundle's generated root
# in $1 and a log in $2: the design compiled for the bundle's fabric
# (efpga_gen.py --shell, in `nix develop .#efpga`, entered here) into
# $1/efpga_design, then timed, since nextpnr places it without knowing the
# fabric's timing (docs/efpga.md). EFPGA_MACRO=<the --out of efpga_gen.py
# --stitch> is that fabric hardened, and efpga_timing.py refuses another;
# EFPGA_VIEWS=<the final views of this SoC hardened with it> has the wrapper's
# side of the window measured on that layout (efpga_block_sta.sh), not
# estimated (efpga_sta.sh). The SoC's clock is its objectives.target_clock_mhz,
# else 50 ns. The fabric's clock is one cycle in N: EFPGA_DIV, else the least
# the design meets, from a check at 2 and, if setup asks for more, a second
# at what it asks (each cycle more gives every path one more period, up to
# the 16 of CLKDIV). A design that fails at its N is refused. EFPGA_DIV is
# then that N, which the firmware sets before it loads the design (with no
# EFPGA_MACRO, what was asked, if anything: the reset value is 4).
# EFPGA_TIMING says, for the result line, how the design was timed, or that
# it was not.
mosaic_efpga_design() {
  local root="$1" log="$2" name cfg period top sta window line div least rc errors
  name="$(basename "${EFPGA_DESIGN%.*}")"
  case "${EFPGA_DIV:-2}" in
    [1-9]|1[0-6]) ;;
    *) echo "EFPGA_DIV=$EFPGA_DIV: the fabric's clock is one cycle in 1 to 16"; return 1 ;;
  esac
  echo "###       compiling $EFPGA_DESIGN for the eFPGA ..."
  [ -f "$root/efpga/manifest.json" ] || { echo "$MOSAIC_CFG has no eFPGA (soc.efpga)"; return 1; }
  local gen=(python3 util/mosaic_gen/efpga_gen.py --fabric "$root/efpga" --out "$root/efpga_design"
             --shell "$EFPGA_DESIGN")
  if command -v FABulous >/dev/null; then
    "${gen[@]}"
  else
    nix develop "$REPO#efpga" --option warn-dirty false --command "${gen[@]}"
  fi > "$log" 2>&1 || { echo "eFPGA compilation failed — see $log"; return 1; }
  if [ -z "${EFPGA_MACRO:-}" ]; then
    EFPGA_TIMING="not timed (no EFPGA_MACRO)${EFPGA_DIV:+, one cycle in $EFPGA_DIV}"
    return 0
  fi
  cfg="$("$PY" -c 'import sys, yaml
from harness.physical.floorplan import clock_period_ns
soc = yaml.safe_load(open(sys.argv[1]))["soc"]
print("%g %s" % (clock_period_ns(soc) or 50, soc["name"]))' "$MOSAIC_CFG")" || return 1
  period="${cfg% *}" top="${cfg#* }"
  sta=(flow/librelane/scripts/efpga_sta.sh "$EFPGA_MACRO") window=estimated
  if [ -n "${EFPGA_VIEWS:-}" ]; then
    [ "$(basename "$(ls "$EFPGA_VIEWS"/nl/*.nl.v)" .nl.v)" = "$top" ] \
        || { echo "EFPGA_VIEWS: not the final views of $top"; return 1; }
    sta=(flow/librelane/scripts/efpga_block_sta.sh "$EFPGA_MACRO" "$EFPGA_VIEWS") window=measured
  fi
  div="${EFPGA_DIV:-2}"
  errors="$REPO/build/efpga_sta/$(basename "$EFPGA_MACRO")/$name/errors.txt"
  : > "${log%.log}-sta.log"
  while :; do
    echo "###       timing $name on $EFPGA_MACRO at $period ns, one cycle in $div, the window $window (about 15 minutes) ..."
    env -u EFPGA_STA_WINDOW EFPGA_STA_PERIOD="$period" EFPGA_STA_DIV="$div" "${sta[@]}" "$root/efpga_design/$name" \
        >> "${log%.log}-sta.log" 2>&1
    rc=$?
    line="$(grep -E "^STA DESIGN (PASS|FAIL) design=$name " "${log%.log}-sta.log" | tail -n 1)"
    case "$rc:$line" in
      "0:STA DESIGN PASS "*) break ;;
      *":STA DESIGN FAIL "*)
        least="$(sed -E 's/.* min_div=([0-9]+) .*/\1/' <<< "$line")"
        # Chosen, not asked, and only setup fails: once more at the N it asks for.
        if [ -z "${EFPGA_DIV:-}" ] && [ "$least" -gt "$div" ] && [ "$least" -le 16 ] \
            && ! grep -qv ": setup of " "$errors"; then
          div="$least"
          continue
        fi
        echo "$line"
        head -n 3 "$errors"
        [ "$least" -le 16 ] || echo "setup asks for one cycle in $least; CLKDIV gives 16 at most"
        echo "### RESULT: refused — $name fails timing at $period ns, one cycle in $div (see ${log%.log}-sta.log)"
        return 1 ;;
      *) tail -n 5 "${log%.log}-sta.log"; echo "eFPGA timing failed — see ${log%.log}-sta.log"; return 1 ;;
    esac
  done
  EFPGA_DIV="$div"
  EFPGA_TIMING="timed at nine corners, $period ns, one cycle in $div, the window $window:"
  EFPGA_TIMING+=" setup $(sed -E 's/.* setup_ns=([^ ]+) .*/\1/' <<< "$line") ns,"
  EFPGA_TIMING+=" hold $(sed -E 's/.* hold_ns=([^ ]+) .*/\1/' <<< "$line") ns"
}

# The Mako templates mcu_gen renders, one path per line. The runners share this
# one copy; MCU_GEN_TEMPLATES in the Makefile must select the same files (the
# two find expressions are kept equivalent). ./.claude holds agent
# worktrees -- whole repository copies -- whose templates would otherwise be
# rendered too, and whose count pushes the list past the kernel's 128 KiB
# per-argument limit ("Argument list too long").
mosaic_templates() {
  find . \( -path './build/*' -o -path './.claude/*' \
    -o -path './hw/vendor/*' ! -path './hw/vendor/xheep' ! -path './hw/vendor/xheep/*' \
    -o -path './util/*' \
    -o -path './test/*' \) -prune -o -name '*.tpl' -print
}
