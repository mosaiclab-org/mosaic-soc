// Copyright 2026 MOSAIC-SoC contributors
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// The check of tb/efpga/task_count.v that the production firmware runs once
// it has loaded the design (EFPGA_TEST of sw/firmware/Makefile; sweep step
// efpga_task): tasks given to the fabric through the TDU, as to a worker hart.
// Returns 0, or the number of the check that failed, with the driver's
// outcome in bits [11:8] where there is one.

#include <stdint.h>

#include "efpga.h"

#define POLLS 1000u
#define SLOT (1u << MOSAIC_EFPGA_TDU_SLOT)

static uint32_t sleeping(void) {
    return (tdu_get_core_status().sleeping & SLOT) != 0u;
}

static uint32_t queued(void) {
    return tdu_get_task_status().count;
}

static void wait_asleep(void) {
    for (uint32_t left = POLLS; !sleeping() && left != 0u; --left) {}
}

uint32_t efpga_test(void) {
    uint32_t result = 0u, outcome;
    static const uint16_t ids[2] = {0x1234u, 0xBEEFu};
    const uint32_t mask = tdu_get_wake_mask();

    if (!sleeping()) return 1;  // the slot sleeps until a task wakes it
    // Two tasks the design ends: the result names the task and counts it.
    for (uint32_t k = 0; k < 2u; ++k) {
        outcome = mosaic_efpga_task(ids[k], &result, POLLS);
        if (outcome != MOSAIC_EFPGA_TASK_DONE) return 2u | outcome << 8;
        if (result != ((k + 1u) << 16 | (uint32_t)(ids[k] ^ 0xA5A5u))) return 3;
        if (*mosaic_efpga_reg(MOSAIC_EFPGA_TASK) >> 16 != ids[k]) return 4;
        if (!sleeping()) return 5;
    }
    // A wake with nothing in the queue: the slot takes 0 and sleeps again.
    tdu_wake_harts(SLOT);
    wait_asleep();
    if (!sleeping() || *mosaic_efpga_reg(MOSAIC_EFPGA_TASK) >> 16 != ids[1]) return 6;
    // A hart's descriptor at the head, pushed with no hart in WAKE_MASK: the
    // driver refuses a task behind it, and the slot, woken, leaves it there.
    const tdu_task_t hart = {0x7777u, 1u, 0u};
    tdu_set_wake_mask(0u);
    if (tdu_task_push(&hart) != 0) return 17;
    outcome = mosaic_efpga_task(0x0001u, &result, POLLS);
    if (outcome != MOSAIC_EFPGA_TASK_NOT_TAKEN || queued() != 1u) return 18u | outcome << 8;
    tdu_wake_harts(SLOT);
    wait_asleep();
    if (queued() != 1u || *mosaic_efpga_reg(MOSAIC_EFPGA_TASK) >> 16 != ids[1]) return 19;
    tdu_task_t back = {0u, 0u, 0u};
    if (tdu_task_pop(&back) != 0 || back.task_id != 0x7777u || back.core_hint != 1u) return 20;
    // The slot's own descriptor, pushed with the slot out of WAKE_MASK: it
    // waits, asleep, until a WAKE_REQ wakes the slot, which then runs it.
    const tdu_task_t own = {0x2468u, (uint8_t)MOSAIC_EFPGA_TDU_SLOT, 0u};
    if (tdu_task_push(&own) != 0) return 21;
    for (uint32_t left = 100u; left != 0u; --left) {}
    if (!sleeping() || queued() != 1u) return 22;
    tdu_wake_harts(SLOT);
    for (uint32_t left = POLLS; queued() != 0u && left != 0u; --left) {}
    wait_asleep();
    if (queued() != 0u || !sleeping()) return 23;
    if (*mosaic_efpga_reg(MOSAIC_EFPGA_RESULT) != (3u << 16 | (0x2468u ^ 0xA5A5u))) return 24;
    tdu_set_wake_mask(mask);
    // A task the design never ends: parked by the TDU, the slot asleep again.
    outcome = mosaic_efpga_task(0xFFFFu, &result, 200u);
    if (outcome != MOSAIC_EFPGA_TASK_PARKED) return 7u | outcome << 8;
    if (!sleeping()) return 8;
    if (!(*mosaic_efpga_reg(MOSAIC_EFPGA_STATUS) & MOSAIC_EFPGA_CUT)) return 9;
    if (*mosaic_efpga_reg(MOSAIC_EFPGA_RESULT) != MOSAIC_EFPGA_NO_ANSWER) return 10;
    // A task while the fabric is isolated: taken, and cut at once.
    *mosaic_efpga_reg(MOSAIC_EFPGA_CONTROL) = MOSAIC_EFPGA_ISOLATE;
    outcome = mosaic_efpga_task(0x0042u, &result, POLLS);
    if (outcome != MOSAIC_EFPGA_TASK_CUT) return 11u | outcome << 8;
    if (*mosaic_efpga_reg(MOSAIC_EFPGA_TASK) >> 16 != 0x0042u) return 12;
    // Connected again, without the user reset: the count goes on.
    *mosaic_efpga_reg(MOSAIC_EFPGA_CONTROL) = 0u;
    outcome = mosaic_efpga_task(0x0042u, &result, POLLS);
    if (outcome != MOSAIC_EFPGA_TASK_DONE) return 13u | outcome << 8;
    if (result != (4u << 16 | (0x0042u ^ 0xA5A5u))) return 14;
    // Nothing left: an empty queue, no flag but `configured`.
    if (!tdu_get_task_status().empty) return 15;
    if (*mosaic_efpga_reg(MOSAIC_EFPGA_STATUS) != MOSAIC_EFPGA_CONFIGURED) return 16;
    return 0;
}
