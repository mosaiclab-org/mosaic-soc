// Copyright 2026 MOSAIC-SoC Contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Driver of the eFPGA, hw/efpga/mosaic_efpga.sv, on a design with soc.efpga.
// docs/efpga.md describes the registers and the streams.

#ifndef MOSAIC_EFPGA_H_
#define MOSAIC_EFPGA_H_

#include <stdint.h>

#include <mosaic_memory_map.h>

#ifndef MOSAIC_EFPGA_BASE
#error "the design has no eFPGA: soc.efpga"
#endif

#define MOSAIC_EFPGA_BITSTREAM 0x0u  // W  the next word of a stream
#define MOSAIC_EFPGA_STATUS 0x4u     // R  the bits below; timeout and blocked W1C
#define MOSAIC_EFPGA_CONTROL 0x8u    // RW isolate, user reset; W clear
#define MOSAIC_EFPGA_TAG 0xCu        // R  the tag of the design in the fabric, 0: none

#define MOSAIC_EFPGA_BUSY 0x01u
#define MOSAIC_EFPGA_CONFIGURED 0x02u
#define MOSAIC_EFPGA_ERROR 0x04u      // the cause is in bits [10:8]
#define MOSAIC_EFPGA_TIMEOUT 0x08u    // the design did not answer a request
#define MOSAIC_EFPGA_BLOCKED 0x10u    // a request while the fabric was cut off

// A load left a design configured; an unload, or a clear, left none.
#define MOSAIC_EFPGA_LOADED(status) \
    (((status) & (MOSAIC_EFPGA_BUSY | MOSAIC_EFPGA_CONFIGURED | MOSAIC_EFPGA_ERROR)) == \
     MOSAIC_EFPGA_CONFIGURED)
#define MOSAIC_EFPGA_EMPTY(status) \
    (((status) & (MOSAIC_EFPGA_BUSY | MOSAIC_EFPGA_CONFIGURED | MOSAIC_EFPGA_ERROR)) == 0u)

#define MOSAIC_EFPGA_ISOLATE 0x1u
#define MOSAIC_EFPGA_USER_RESET 0x2u
#define MOSAIC_EFPGA_CLEAR 0x4u

static inline volatile uint32_t *mosaic_efpga_reg(uint32_t offset) {
    return (volatile uint32_t *)(uintptr_t)(MOSAIC_EFPGA_BASE + offset);
}

// Writes `count` words of a stream to BITSTREAM: <design>.hex, which loads a
// design, or <design>.unload.hex, which removes the one in the fabric (both
// from util/mosaic_gen/efpga_gen.py). Then reads STATUS until the loader is
// no longer busy, at most 64 times. Returns STATUS: MOSAIC_EFPGA_LOADED after
// a design was loaded, MOSAIC_EFPGA_EMPTY after one was removed,
// MOSAIC_EFPGA_ERROR and its cause if the stream was refused,
// MOSAIC_EFPGA_BUSY if it never ended. A load leaves the timeout and blocked
// flags as they were. After a reset that kept power, the fabric still holds
// the design that ran (TAG is not 0), and the loader takes only its unload.
static inline uint32_t mosaic_efpga_load(const volatile uint32_t *words, uint32_t count) {
    for (uint32_t index = 0; index < count; ++index) {
        *mosaic_efpga_reg(MOSAIC_EFPGA_BITSTREAM) = words[index];
    }
    uint32_t status = *mosaic_efpga_reg(MOSAIC_EFPGA_STATUS);
    for (uint32_t reads = 64u; (status & MOSAIC_EFPGA_BUSY) != 0u && reads != 0u; --reads) {
        status = *mosaic_efpga_reg(MOSAIC_EFPGA_STATUS);
    }
    return status;
}

// Connects a configured fabric to the bus and its edges, with the user reset
// held for one write and then released.
static inline void mosaic_efpga_connect(void) {
    *mosaic_efpga_reg(MOSAIC_EFPGA_CONTROL) = MOSAIC_EFPGA_USER_RESET;
    *mosaic_efpga_reg(MOSAIC_EFPGA_CONTROL) = 0u;
}

#endif  // MOSAIC_EFPGA_H_
