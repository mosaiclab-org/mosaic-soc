#!/bin/bash
# Full regression sweep: every test suite of the project, run in sequence.
#
# Each step has a name, a command and a success marker (a regular expression
# that must appear in the step's log). A step passes only when the command
# exits 0 AND the marker is found, because several runners exit 0 while
# printing a failure.
#
# Suites that look alike are separate steps on purpose. tb/mosaic/run.sh checks
# that the workers are alive and executed code but does not test dormancy; the
# cocotb test in tb/mosaic/cocotb does. tb/sci/hazard3 adds the Hazard3 include
# path itself; the full-SoC build has to find the same headers on its own.
#
# Usage:
#   scripts/run_sweep.sh                 # everything but the opt-in steps (~40 min)
#   scripts/run_sweep.sh --list          # print the step names and exit
#   scripts/run_sweep.sh --only wake     # steps whose name matches a regex
#   scripts/run_sweep.sh --only efpga_netlist   # an opt-in step: named in full
#   SWEEP_LOGS=/path scripts/run_sweep.sh
#
# Exits NON-ZERO if any step fails, so it can gate a merge. Steps are never
# skipped silently: the summary names what --only excluded and the opt-in
# steps it did not run.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

LOGS="${SWEEP_LOGS:-$REPO/build/sweep}"   # under build/, which is gitignored
ONLY=""
LIST_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST_ONLY=1; shift ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

EXIT_OK='EXIT SUCCESS|RESULT: EXIT SUCCESS'

# name | success-marker regex | command
#
# The marker matters as much as the exit status: several of these scripts exit
# 0 while printing a failure, so "did it exit 0" alone is not a pass.
STEPS=(
  "pytest|[0-9]+ passed|python3 -m pytest test/test_mosaic_gen -q"
  "tb_matrix_validate|report|./mosaic tb-matrix run --tier validate"

  "tdu_soc_cocotb|PASS|passed|tb/tdu/soc/cocotb/run.sh"
  "mosaic_sci_wakeloop|PASS|SUCCESS|tb/mosaic/run.sh"
  "mosaic_sci_cocotb|TESTS=1 PASS=1 FAIL=0|tb/mosaic/cocotb/run.sh"
  "idma_cocotb|PASS|passed|tb/idma/cocotb/run.sh"
  "log_xbar|PASS|tb/log_xbar/run.sh"
  "tl_obi|PASS|tb/tl_obi/run.sh"
  "floonoc_bridges|PASS|passed|tb/floonoc/cocotb/run.sh"
  "floonoc_stage2|PASS|passed|tb/floonoc/cocotb/run.sh stage2"

  "sci_tb_serv|TB PASS|tb/sci/serv/run.sh"
  "sci_tb_fazyrv|TB PASS|tb/sci/fazyrv/run.sh"
  "sci_tb_picorv32|TB PASS|tb/sci/picorv32/run.sh"
  "sci_tb_hazard3|TB PASS|tb/sci/hazard3/run.sh"
  "efpga_fabric|TB PASS|tb/efpga/run.sh"
  "efpga_wrapper|TB PASS|tb/efpga/run_wrapper.sh"
  "efpga_powerup|TB PASS|tb/efpga/run_powerup.sh"
  "efpga_soc|^### RESULT: EXIT SUCCESS|tb/mosaic_soc/run_efpga.sh"
  "efpga_design|^### RESULT: EXIT SUCCESS.* with shell_regs.v in its eFPGA, checked by shell_regs_test.c, warm reboots: 1 |MOSAIC_CFG=configs/mosaic_efpga_demo.yaml EFPGA_DESIGN=tb/efpga/shell_regs.v EFPGA_TEST=tb/efpga/shell_regs_test.c WARM_REBOOTS=1 tb/mosaic_soc/run_fw.sh"
  "efpga_log|^### RESULT: EXIT SUCCESS.* with shell_regs.v in its eFPGA, checked by shell_regs_test.c, warm reboots: 0 |MOSAIC_CFG=configs/mosaic_efpga_demo_log.yaml EFPGA_DESIGN=tb/efpga/shell_regs.v EFPGA_TEST=tb/efpga/shell_regs_test.c tb/mosaic_soc/run_fw.sh"
  "efpga_floonoc|^### RESULT: EXIT SUCCESS.* with shell_regs.v in its eFPGA, checked by shell_regs_test.c, warm reboots: 0 |MOSAIC_CFG=configs/mosaic_efpga_demo_floonoc.yaml EFPGA_DESIGN=tb/efpga/shell_regs.v EFPGA_TEST=tb/efpga/shell_regs_test.c tb/mosaic_soc/run_fw.sh"
  "efpga_serv|^### RESULT: EXIT SUCCESS.* with shell_regs.v in its eFPGA, checked by shell_regs_test.c, warm reboots: 0 |MOSAIC_CFG=configs/mosaic_efpga_serv.yaml EFPGA_DESIGN=tb/efpga/shell_regs.v EFPGA_TEST=tb/efpga/shell_regs_test.c tb/mosaic_soc/run_fw.sh"
  "efpga_medium|^### RESULT: EXIT SUCCESS.* with shell_regs.v in its eFPGA, checked by shell_regs_test.c, warm reboots: 0 |MOSAIC_CFG=configs/mosaic_efpga_medium.yaml EFPGA_DESIGN=tb/efpga/shell_regs.v EFPGA_TEST=tb/efpga/shell_regs_test.c tb/mosaic_soc/run_fw.sh"
  "efpga_task|^### RESULT: EXIT SUCCESS.* with task_count.v in its eFPGA, checked by task_count_test.c, warm reboots: 0 |MOSAIC_CFG=configs/mosaic_efpga_demo.yaml EFPGA_DESIGN=tb/efpga/task_count.v EFPGA_TEST=tb/efpga/task_count_test.c tb/mosaic_soc/run_fw.sh"
  "efpga_blocka|^### RESULT: EXIT SUCCESS.*, shell_regs.v loaded in the eFPGA and checked |MOSAIC_CFG=configs/mosaic_block_efpga.yaml EFPGA_DESIGN=tb/efpga/shell_regs.v tb/mosaic_soc/run_generic.sh"
  "efpga_synth|^SYNTH PASS preset=small |flow/librelane/scripts/efpga_synth.sh small"
  "efpga_netlist|^TB PASS netlist=small |tb/efpga/run_netlist.sh"
  "efpga_block|^TB PASS block=mosaic_efpga |flow/librelane/scripts/efpga_block.sh build/efpga_netlist/fabric && flow/librelane/scripts/efpga_block_sta.sh build/efpga_netlist/fabric flow/librelane/experimental/final_efpga_block counter8_en bus_regs task_count && tb/efpga/run_block.sh build/efpga_netlist/fabric flow/librelane/experimental/final_efpga_block"
  "efpga_block_soc|^TB PASS block=mosaic_block_efpga |flow/librelane/scripts/efpga_block.sh build/efpga_netlist/fabric block_efpga configs/mosaic_block_efpga.yaml && nix develop .#efpga --option warn-dirty false --command python3 util/mosaic_gen/efpga_gen.py --fabric build/efpga/small --out build/efpga_soc_designs --shell tb/efpga/shell_regs.v && flow/librelane/scripts/efpga_block_sta.sh build/efpga_netlist/fabric flow/librelane/experimental/final_block_efpga counter8_en bus_regs task_count build/efpga_soc_designs/shell_regs && tb/efpga/run_soc_block.sh build/efpga_netlist/fabric configs/mosaic_block_efpga.yaml flow/librelane/experimental/final_block_efpga"
  "efpga_timed|^### RESULT: EXIT SUCCESS.*, shell_regs.v loaded in the eFPGA and checked — timed at nine corners, 50 ns, one cycle in [0-9]*, the window measured: setup [0-9]|EFPGA_MACRO=build/efpga_netlist/fabric EFPGA_VIEWS=flow/librelane/experimental/final_block_efpga MOSAIC_CFG=configs/mosaic_block_efpga.yaml EFPGA_DESIGN=tb/efpga/shell_regs.v tb/mosaic_soc/run_generic.sh && mkdir -p build/efpga_timed && { EFPGA_MACRO=build/efpga_netlist/fabric MOSAIC_CFG=configs/mosaic_efpga_demo.yaml EFPGA_DESIGN=tb/efpga/long_chain.v EFPGA_TEST=tb/efpga/long_chain_test.c tb/mosaic_soc/run_fw.sh > build/efpga_timed/long_chain.log 2>&1; cat build/efpga_timed/long_chain.log; grep -q '^### RESULT: EXIT SUCCESS — production firmware ran .* with long_chain.v in its eFPGA, checked by long_chain_test.c, .* timed at nine corners, 50 ns, one cycle in [0-9]*, the window estimated: setup [0-9]' build/efpga_timed/long_chain.log && test \"\$(sed -n 's/^### RESULT: EXIT SUCCESS.* one cycle in \([0-9]*\),.*/\1/p' build/efpga_timed/long_chain.log)\" -gt 4; } && { EFPGA_DIV=4 EFPGA_MACRO=build/efpga_netlist/fabric MOSAIC_CFG=configs/mosaic_efpga_fast.yaml EFPGA_DESIGN=tb/efpga/task_count.v tb/mosaic_soc/run_fw.sh > build/efpga_timed/control.log 2>&1; cat build/efpga_timed/control.log; grep -q '^STA DESIGN FAIL design=task_count .* setup_ns=-' build/efpga_timed/control.log && grep -q '^### RESULT: refused — task_count fails timing at 31.25 ns, one cycle in 4 ' build/efpga_timed/control.log; }"

  "wake_obi|$EXIT_OK|tb/mosaic_soc/run.sh"
  "wake_log|$EXIT_OK|MOSAIC_CFG=configs/mosaic_wake_demo_log.yaml tb/mosaic_soc/run.sh"
  "wake_floonoc|$EXIT_OK|MOSAIC_CFG=configs/mosaic_floonoc.yaml tb/mosaic_soc/run.sh"
  "wake_picorv32|$EXIT_OK|MOSAIC_CFG=configs/mosaic_picorv32.yaml tb/mosaic_soc/run.sh"
  "wake_snitch|$EXIT_OK|MOSAIC_CFG=configs/mosaic_snitch.yaml tb/mosaic_soc/run.sh"
  "wake_cva6|$EXIT_OK|MOSAIC_CFG=configs/mosaic_cva6.yaml tb/mosaic_soc/run.sh"
  "wake_new_cores|$EXIT_OK|MOSAIC_CFG=configs/mosaic_new_cores.yaml tb/mosaic_soc/run.sh"
  "wake_hazard3|$EXIT_OK|MOSAIC_CFG=configs/mosaic_hazard3.yaml tb/mosaic_soc/run.sh"
  "wake_rocket|$EXIT_OK|MOSAIC_CFG=configs/mosaic_rocket.yaml tb/mosaic_soc/run.sh"
  "wake_boom|$EXIT_OK|MOSAIC_CFG=configs/mosaic_boom.yaml tb/mosaic_soc/run.sh"
  "wake_berkeley|$EXIT_OK|MOSAIC_CFG=configs/mosaic_berkeley.yaml tb/mosaic_soc/run.sh"

  "titan_smp_obi|$EXIT_OK|MOSAIC_CFG=configs/mosaic_titan_obi.yaml tb/mosaic_soc/run_titan.sh"
  "titan_smp_log|$EXIT_OK|MOSAIC_CFG=configs/mosaic_titan_log.yaml tb/mosaic_soc/run_titan.sh"
  "titan_smp_floonoc|$EXIT_OK|MOSAIC_CFG=configs/mosaic_titan_floonoc.yaml tb/mosaic_soc/run_titan.sh"

  "firmware_7hart|$EXIT_OK|tb/mosaic_soc/run_fw.sh"
  "generic_boot_blocka|$EXIT_OK|MOSAIC_CFG=configs/mosaic_tapeout_ultra.yaml tb/mosaic_soc/run_generic.sh"
  "uart_bringup_blocka|$EXIT_OK|MOSAIC_CFG=configs/mosaic_tapeout_ultra.yaml tb/mosaic_soc/run_uart.sh"
  "gls_blocka|$EXIT_OK|tb/gls/run_gls.sh"
  "demo03_blocka_prompt|RESULT: prompt|MOSAIC_DEMO_AGENT=off ./demo/03_blocka_from_prompt.sh"
)

# Steps too long for every sweep (a regex of whole names): they run only when
# --only matches the whole name, not a part of it. efpga_netlist hardens the
# fabric of small for GF180MCU and simulates its netlist, about 3.5 hours.
# efpga_block, after it, hardens the wrapper with that macro as one block, times
# each design on it and simulates its netlist, about 1 hour. efpga_block_soc does
# the same with Block A's SoC around the macro (configs/mosaic_block_efpga.yaml).
# efpga_timed, after those two, times a user's design on that layout in the
# one-command flow and runs it at the fabric's clock it meets; then a design of
# 40 LUTs in a row, which needs more than four cycles, at its own; and its
# control, task_count at 32 MHz (configs/mosaic_efpga_fast.yaml) asked to run at
# four, must be refused on setup. About an hour.
OPT_IN="efpga_netlist|efpga_block|efpga_block_soc|efpga_timed"
opt_in() { printf '%s' "$1" | grep -qxE "$OPT_IN" && ! printf '%s' "$1" | grep -qxE "${ONLY:-^$}"; }

if [ "$LIST_ONLY" = 1 ]; then
  for entry in "${STEPS[@]}"; do
    name="${entry%%|*}"
    if printf '%s' "$name" | grep -qxE "$OPT_IN"; then echo "$name (opt-in)"; else echo "$name"; fi
  done
  exit 0
fi

mkdir -p "$LOGS"
RESULTS="$LOGS/results.tsv"
: > "$RESULTS"
EXCLUDED=0
OPTED=""

for entry in "${STEPS[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  marker="${rest%|*}"
  cmd="${rest##*|}"

  if [ -n "$ONLY" ] && ! printf '%s' "$name" | grep -qE "$ONLY"; then
    EXCLUDED=$((EXCLUDED + 1))
    continue
  fi
  if opt_in "$name"; then
    OPTED="$OPTED $name"
    continue
  fi

  log="$LOGS/${name}.log"
  start=$SECONDS
  printf '=== [%s] %s\n' "$(date +%H:%M:%S)" "$name" >&2
  ( eval "$cmd" ) >"$log" 2>&1
  rc=$?
  dur=$((SECONDS - start))

  if [ "$rc" -ne 0 ]; then
    verdict="FAIL(exit=$rc)"
  elif ! grep -qE "$marker" "$log"; then
    verdict="FAIL(no-marker)"
  else
    verdict="PASS"
  fi
  printf '%s\t%s\t%ss\t%s\n' "$name" "$verdict" "$dur" "$log" >> "$RESULTS"
  printf '    -> %s (%ss)\n' "$verdict" "$dur" >&2
done

echo
echo "===================== SWEEP SUMMARY ====================="
awk -F'\t' '{printf "%-26s %-14s %6s\n", $1, $2, $3}' "$RESULTS"
echo "---------------------------------------------------------"
awk -F'\t' -v excluded="$EXCLUDED" '
  {total++; if ($2 ~ /^PASS/) pass++; else {fail++; failed = failed "\n  " $1 "  " $4}}
  END {
    printf "PASS %d   FAIL %d   (ran %d)\n", pass, fail, total
    if (excluded > 0) printf "NOT RUN: %d step(s) excluded by --only\n", excluded
    if (fail > 0) printf "failing steps:%s\n", failed
  }' "$RESULTS"
[ -z "$OPTED" ] || echo "NOT RUN (opt-in, --only <name> runs it):$OPTED"
echo "logs: $LOGS"

# Non-zero if anything failed — without this the script is unusable as a gate,
# and "the sweep passed" would mean only "the sweep finished".
! grep -q $'\tFAIL' "$RESULTS"
