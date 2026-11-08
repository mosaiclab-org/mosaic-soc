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
#define MOSAIC_EFPGA_STATUS 0x4u     // R  the bits below; timeout, blocked and cut W1C
#define MOSAIC_EFPGA_CONTROL 0x8u    // RW isolate, user reset; W clear
#define MOSAIC_EFPGA_TAG 0xCu        // R  the tag of the design in the fabric, 0: none
#define MOSAIC_EFPGA_TASK 0x10u      // R  the descriptor of the last task the fabric took
#define MOSAIC_EFPGA_RESULT 0x14u    // R  its task_result; MOSAIC_EFPGA_NO_ANSWER if cut
#define MOSAIC_EFPGA_CLKDIV 0x18u    // RW the fabric's clock pulses every CLKDIV+1 cycles

#define MOSAIC_EFPGA_BUSY 0x01u
#define MOSAIC_EFPGA_CONFIGURED 0x02u
#define MOSAIC_EFPGA_ERROR 0x04u      // the cause is in bits [10:8]
#define MOSAIC_EFPGA_TIMEOUT 0x08u    // the design did not answer a request
#define MOSAIC_EFPGA_BLOCKED 0x10u    // a request while the fabric was cut off
#define MOSAIC_EFPGA_CUT 0x20u        // a task ended without task_done since cleared (W1C)

#define MOSAIC_EFPGA_NO_ANSWER 0xFAB00BADu  // a request or a task the design did not answer
// Not a STATUS: a failure at boot whose low bits are the CLKDIV the wrapper
// kept instead of the one the deployment table asked for (cold_boot.c).
#define MOSAIC_EFPGA_CLKDIV_REFUSED 0x00100000u

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

#ifdef MOSAIC_EFPGA_PADS
// Gives the pads of `mask` (bit k: pad k of the fabric, an option of the pad
// of gpio_k) to the fabric, and every other one back to its GPIO. Out of reset
// each is the GPIO's (configs/pad_cfg.py, pad_control).
static inline void mosaic_efpga_pads(uint32_t mask) {
    static const uint32_t addresses[] = MOSAIC_EFPGA_PAD_MUX_ADDRS;
    static const uint32_t fabric[] = MOSAIC_EFPGA_PAD_MUX_FABRIC;
    for (uint32_t pad = 0; pad < MOSAIC_EFPGA_PADS; ++pad) {
        *(volatile uint32_t *)(uintptr_t)addresses[pad] = ((mask >> pad) & 1u) ? fabric[pad] : 0u;
    }
}
#endif

// Connects a configured fabric to the bus and its edges, with the user reset
// held for one write and then released.
static inline void mosaic_efpga_connect(void) {
    *mosaic_efpga_reg(MOSAIC_EFPGA_CONTROL) = MOSAIC_EFPGA_USER_RESET;
    *mosaic_efpga_reg(MOSAIC_EFPGA_CONTROL) = 0u;
}

#ifdef MOSAIC_EFPGA_TDU_SLOT
#include "tdu.h"

#define MOSAIC_EFPGA_TASK_DONE 0u       // the design ended the task: *result is its task_result
#define MOSAIC_EFPGA_TASK_NOT_TAKEN 1u  // the queue was not empty, or the slot did not take it
#define MOSAIC_EFPGA_TASK_CUT 2u        // taken while the fabric was cut off, or cut off after
#define MOSAIC_EFPGA_TASK_PARKED 3u     // the design did not end it: the TDU parked the slot

// Gives task_id to the fabric through the TDU, as a worker hart gets a task:
// the descriptor is pushed with the fabric's slot as its core_hint, which
// wakes the slot, and the slot takes it from the queue (docs/efpga.md). Then
// reads CORE_STATUS, at most `polls` times, until the slot sleeps again. The
// queue must be empty: the slot takes only a head meant for it. A task the
// slot did not take is taken back from the queue; one the design did not end
// is parked. A design must drop a task that was parked or cut
// (docs/efpga.md); one that cannot needs its user reset before the next.
static inline uint32_t mosaic_efpga_task(uint16_t task_id, uint32_t *result, uint32_t polls) {
    const uint32_t slot = 1u << MOSAIC_EFPGA_TDU_SLOT;
    const tdu_task_t task = {task_id, (uint8_t)MOSAIC_EFPGA_TDU_SLOT, 0u};
    if (!tdu_get_task_status().empty) return MOSAIC_EFPGA_TASK_NOT_TAKEN;
    *mosaic_efpga_reg(MOSAIC_EFPGA_STATUS) = MOSAIC_EFPGA_CUT;
    const uint32_t mask = tdu_get_wake_mask();
    tdu_set_wake_mask(slot);  // the push wakes the slot and no hart
    uint32_t outcome = MOSAIC_EFPGA_TASK_NOT_TAKEN;
    if (tdu_task_push(&task) == 0) {
        uint32_t left = polls, empty;
        while (!(empty = tdu_get_task_status().empty) && left != 0u) --left;
        tdu_task_t back;
        if (!empty && tdu_task_pop(&back) == 0) {
            outcome = MOSAIC_EFPGA_TASK_NOT_TAKEN;  // never taken: out of the queue again
        } else {
            // Decided on the last read. A park that meets the design's
            // task_done changes nothing, and `cut` tells the two apart; the
            // slot sleeps two cycles after a park.
            uint32_t asleep, parked = 0u;
            left = polls;
            while (!(asleep = tdu_get_core_status().sleeping & slot) && left != 0u) --left;
            if (!asleep) {
                tdu_park_harts(slot);
                parked = 1u;
                for (left = 16u; !(asleep = tdu_get_core_status().sleeping & slot) && left != 0u;)
                    --left;
            }
            if (!asleep || (*mosaic_efpga_reg(MOSAIC_EFPGA_STATUS) & MOSAIC_EFPGA_CUT)) {
                outcome = parked ? MOSAIC_EFPGA_TASK_PARKED : MOSAIC_EFPGA_TASK_CUT;
            } else {
                *result = *mosaic_efpga_reg(MOSAIC_EFPGA_RESULT);
                outcome = MOSAIC_EFPGA_TASK_DONE;
            }
        }
    }
    tdu_set_wake_mask(mask);
    return outcome;
}
#endif

#endif  // MOSAIC_EFPGA_H_
