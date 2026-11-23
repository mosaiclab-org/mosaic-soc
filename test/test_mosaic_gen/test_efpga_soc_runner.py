# Copyright 2026 MOSAIC-SoC contributors
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""The two background GLS cases need positive evidence before the runner passes.

Exercise the runner's actual orchestration with a stand-in for run_case, so a
killed shell or a missing report is tested without rebuilding the chip model.
The expensive generation/build prefix is outside this test's boundary.
"""

import os
from pathlib import Path
import subprocess

import pytest


REPO = Path(__file__).resolve().parents[2]
RUNNER = REPO / "tb/efpga/run_soc_block.sh"


def _run_cases(tmp_path, behavior):
    script = RUNNER.read_text()
    # Start where the real script launches its two background workers.
    tail = script[script.index("RUN_TIMEOUT=21600\n"):]
    stand_in = r'''
run_case() {
    local simulator="$1" name="$2" expected="$3"
    if [ "$name" = task_count ]; then
        case "$BEHAVIOR" in
            killed) kill -TERM "$BASHPID" ;;
            empty) return 0 ;;
            wrong_reason) echo "ok     ${simulator}_${name}: pass"; return 0 ;;
            wrong) echo "WRONG  ${simulator}_${name}: crashed"; return 0 ;;
        esac
    fi
    echo "ok     ${simulator}_${name}: $expected"
    echo 'TB PASS cycles=123' > "$OBJ/verilator_shell_regs.log"
    if [ "$BEHAVIOR" = nonzero ] && [ "$name" = task_count ]; then
        return 17
    fi
}
'''
    return subprocess.run(
        ["bash", "-c", "set -euo pipefail\n" + stand_in + tail],
        env={**os.environ, "OBJ": str(tmp_path), "TOP": "mosaic_chip_efpga",
             "EFPGA_NETLIST": "/x/fabric_m3",
             "BEHAVIOR": behavior},
        capture_output=True, text=True, timeout=10,
    )


def test_both_expected_case_results_allow_the_runner_to_pass(tmp_path):
    result = _run_cases(tmp_path, "expected")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "TB PASS block=mosaic_chip_efpga fabric=small netlist=fabric_m3 " in result.stdout


@pytest.mark.parametrize("behavior", ["killed", "empty", "nonzero", "wrong_reason", "wrong"])
def test_a_lost_or_unexpected_case_cannot_pass(tmp_path, behavior):
    result = _run_cases(tmp_path, behavior)
    assert result.returncode != 0, result.stdout + result.stderr
    assert "TB PASS block=" not in result.stdout
