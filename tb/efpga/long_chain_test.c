// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// The check of tb/efpga/long_chain.v that the production firmware runs once it
// has loaded the design (EFPGA_TEST of sw/firmware/Makefile; sweep step
// efpga_timed). Returns 0, or the number of the check that failed.

#include <stdint.h>

#include "efpga.h"

static uint32_t parity(uint32_t value) {
    uint32_t bit = 0u;
    for (; value != 0u; value >>= 1) bit ^= value & 1u;
    return bit;
}

uint32_t efpga_test(void) {
    volatile uint32_t *const reg = (volatile uint32_t *)(uintptr_t)MOSAIC_EFPGA_WINDOW_BASE;
    static const uint32_t values[] = {
        0x80000000u, 0x00800000u, 0x7F000000u, 0xFFFFFFFFu, 0x12345678u, 0x0F0F0F0Fu, 0x40000001u,
    };

#ifdef MOSAIC_EFPGA_DIV
    // The fabric's clock is the one the design was timed at.
    if (*mosaic_efpga_reg(MOSAIC_EFPGA_CLKDIV) + 1u != MOSAIC_EFPGA_DIV) return 1;
#endif
    if (*reg != 0u) return 2;  // the user reset of the connection cleared it
    for (uint32_t k = 0u; k < sizeof(values) / sizeof(values[0]); ++k) {
        *reg = values[k];
        if (*reg != parity(values[k] & 0x80FFFFFFu)) return 3u + k;
    }
    // Every request answered by the design: no timeout, nothing blocked.
    if (*mosaic_efpga_reg(MOSAIC_EFPGA_STATUS) != MOSAIC_EFPGA_CONFIGURED) return 20;
    return 0;
}
