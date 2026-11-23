// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// The check of tb/efpga/shell_regs.v that the production firmware runs once it
// has loaded the design (EFPGA_TEST of sw/firmware/Makefile; sweep steps
// efpga_design, efpga_log, efpga_floonoc, efpga_serv). Returns 0, or the
// number of the check that failed.

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
    // The pads. Out of reset each is its GPIO's, and the fabric reads 0 from
    // it; given to the fabric, a pad carries what the design drives, R[7:0],
    // and the design reads it back on word 1.
    *reg = 0xA5u;
    if ((reg[1] & 0xFFu) != 0u) return 7;
    mosaic_efpga_pads(0xFFu);
    if ((reg[1] & 0xFFu) != 0xA5u) return 8;
    *reg = 0x5Au;
    if ((reg[1] & 0xFFu) != 0x5Au) return 9;
    mosaic_efpga_pads(0x0Fu);  // pads 4 to 7 back to their GPIO
    if ((reg[1] & 0xFFu) != 0x0Au) return 10;
    mosaic_efpga_pads(0u);
    if ((reg[1] & 0xFFu) != 0u) return 11;
    // Every request answered by the design: no timeout, nothing blocked.
    if (*mosaic_efpga_reg(MOSAIC_EFPGA_STATUS) != MOSAIC_EFPGA_CONFIGURED) return 6;
    return 0;
}
