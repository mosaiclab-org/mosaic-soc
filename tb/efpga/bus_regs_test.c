// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// A control for the user's check of the production firmware (EFPGA_TEST of
// sw/firmware/Makefile; tb/mosaic_soc/run_efpga.sh, run boot_test): with
// tb/efpga/bus_regs.v in the fabric it returns 7, which must end the run with
// 0x40000007. Any other value says that the check did not run, or did not
// read the design: R0 holds R0_RESET after the user reset.

#include <stdint.h>

#include "efpga.h"

uint32_t efpga_test(void) {
    const uint32_t r0 = *(volatile uint32_t *)(uintptr_t)MOSAIC_EFPGA_WINDOW_BASE;
    return r0 == 0x600DF00Du ? 7u : 1u;
}
