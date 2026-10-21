// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// The check of tb/efpga/shell_regs.v that the production firmware runs once it
// has loaded the design (EFPGA_TEST of sw/firmware/Makefile; sweep step
// efpga_design). Returns 0, or the number of the check that failed.

#include <stdint.h>

#include "efpga.h"

uint32_t efpga_test(void) {
    volatile uint32_t *const reg = (volatile uint32_t *)(uintptr_t)MOSAIC_EFPGA_WINDOW_BASE;
    volatile uint8_t *const bytes = (volatile uint8_t *)(uintptr_t)MOSAIC_EFPGA_WINDOW_BASE;

    if (*reg != 0u) return 1;  // the user reset of the connection cleared it
    *reg = 0x12345678u;
    if (*reg != 0x12345678u) return 2;
    bytes[2] = 0xABu;  // one byte enable
    if (*reg != 0x12AB5678u) return 3;
    for (uint32_t bit = 1u; bit != 0u; bit <<= 1) {  // every data line, each way
        *reg = bit;
        if (*reg != bit) return 4;
        *reg = ~bit;
        if (*reg != ~bit) return 5;
    }
    // Every request answered by the design: no timeout, nothing blocked.
    if (*mosaic_efpga_reg(MOSAIC_EFPGA_STATUS) != MOSAIC_EFPGA_CONFIGURED) return 6;
    return 0;
}
