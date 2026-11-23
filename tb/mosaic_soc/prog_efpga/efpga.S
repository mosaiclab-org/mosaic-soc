// Copyright 2026 MOSAIC-SoC Contributors
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

/* eFPGA peripheral firmware, for hart 0 (tb/mosaic_soc/run_efpga.sh).
 *
 * It writes a stream to the BITSTREAM register of hw/efpga/mosaic_efpga.sv,
 * connects the fabric and uses the user design through its user window. EFPGA_STREAM names the stream, a file of .word lines,
 * EFPGA_UNLOAD the stream that removes its design, and EFPGA_TAG the tag the
 * generator gave that design. With EFPGA_SILENT=0 the
 * design is tb/efpga/bus_regs.v: its two registers must read back, and after
 * it has run it is unloaded and loaded again, from its reset. With
 * EFPGA_SILENT=1 it is a design that never acknowledges, and the wrapper must
 * answer for it. The runner also builds it with streams that must make it
 * fail, at a check it names.
 *
 * The exit value is 0, or the number of the check that failed. Only
 * RV32I instructions and x0-x15 are used.
 */

#include <mosaic_memory_map.inc>

/* Where the generator put the wrapper (soc.efpga). */
#ifndef MOSAIC_ASM_EFPGA_BASE
#error "the design has no eFPGA: soc.efpga"
#endif
#define EFPGA_REG  MOSAIC_ASM_EFPGA_BASE
#define EFPGA_WIN  MOSAIC_ASM_EFPGA_WINDOW_BASE
#define BITSTREAM  0
#define STATUS     4  /* [0] busy [1] configured [2] error [3] timeout [4] blocked */
#define CONTROL    8  /* [0] isolate [1] user reset */
#define TAG        12 /* [15:0] the design in the latches, 0: none */
#define NO_ANSWER  0xFAB00BAD
#define R0_RESET   0x600DF00D

#ifndef EFPGA_SILENT
#define EFPGA_SILENT 0
#endif
#ifndef EFPGA_TAG
#define EFPGA_TAG 0
#endif

    .section .text.init,"ax"
    .global _start
_start:
    li   s0, EFPGA_REG
    li   s1, EFPGA_WIN

    /* 1. Out of reset: nothing configured, no error, no flag. */
    li   a0, 1
    lw   t0, STATUS(s0)
    bnez t0, .Lexit

    /* 2. Before the fabric is configured a read and a write of the window are
     * answered by the wrapper: NO_ANSWER, and `blocked` in STATUS. */
    li   a0, 2
    lw   t0, 0(s1)
    li   t1, NO_ANSWER
    bne  t0, t1, .Lexit
    lw   t0, STATUS(s0)
    li   t1, 0x10
    bne  t0, t1, .Lexit
    sw   t1, STATUS(s0)         /* write 1 to clear */
    lw   t0, STATUS(s0)
    bnez t0, .Lexit
    li   a0, 3
    sw   t1, 0(s1)
    lw   t0, STATUS(s0)
    bne  t0, t1, .Lexit
    sw   t1, STATUS(s0)

    /* 3. and 4. The stream. Then: configured, nothing else. */
    li   a0, 4
    la   a2, stream
    la   a3, stream_end
    jal  ra, write_stream
    li   t1, 0x2
    bne  t0, t1, .Lexit

    /* Connect the fabric with the user reset held, then release it. */
    li   t1, 0x2
    sw   t1, CONTROL(s0)
    sw   zero, CONTROL(s0)

#if EFPGA_SILENT
    /* 5. Nobody acknowledges: the wrapper answers after its timeout. */
    li   a0, 5
    lw   t0, 0(s1)
    li   t1, NO_ANSWER
    bne  t0, t1, .Lexit
    lw   t0, STATUS(s0)
    li   t1, 0xA                /* configured, timeout */
    bne  t0, t1, .Lexit
    li   t2, 0x8
    sw   t2, STATUS(s0)         /* write 1 to clear */
    lw   t0, STATUS(s0)
    li   a1, 0x2
    bne  t0, a1, .Lexit
    li   a0, 6
    sw   t2, 0(s1)
    lw   t0, STATUS(s0)
    bne  t0, t1, .Lexit
#else
    /* 5. Word 0 is R0, which the user reset put at R0_RESET. */
    li   a0, 5
    lw   t0, 0(s1)
    li   t1, R0_RESET
    bne  t0, t1, .Lexit

    /* 6. Every data line, each way: a walking one, then a walking zero. */
    li   a0, 6
    li   t1, 1
.Lwalk:
    sw   t1, 0(s1)
    lw   t0, 0(s1)
    bne  t0, t1, .Lexit
    not  t2, t1
    sw   t2, 0(s1)
    lw   t0, 0(s1)
    bne  t0, t2, .Lexit
    slli t1, t1, 1
    bnez t1, .Lwalk

    /* 7. Word 1 is R1, four bits wide; its upper bits read as R0's, and R0,
     * left at 0x7FFFFFFF by the walk, must not have moved. */
    li   a0, 7
    li   t1, 0xFFFFFFF6
    sw   t1, 4(s1)
    lw   t0, 4(s1)
    li   t1, 0x7FFFFFF6
    bne  t0, t1, .Lexit
    lw   t0, 0(s1)
    li   t1, 0x7FFFFFFF
    bne  t0, t1, .Lexit

    /* 8. A byte written to a register is dropped: taken as a word, this one
     * would clear the fabric. Nothing was blocked and nothing timed out. */
    li   a0, 8
    li   t1, 4
    sb   t1, CONTROL(s0)
    lw   t0, STATUS(s0)
    li   t1, 0x2
    bne  t0, t1, .Lexit

    /* 9. TAG names bus_regs. The unload removes the design that has run:
     * then STATUS 0, TAG 0, CONTROL as after a reset. */
    li   a0, 9
    li   t1, EFPGA_TAG
    lw   t0, TAG(s0)
    bne  t0, t1, .Lexit
    la   a2, unload
    la   a3, unload_end
    jal  ra, write_stream
    bnez t0, .Lexit
    lw   t0, TAG(s0)
    bnez t0, .Lexit
    lw   t0, CONTROL(s0)
    li   t1, 0x3
    bne  t0, t1, .Lexit

    /* 10. bus_regs again. Connected without its user reset, R0 reads 0: the
     * unload put every flip-flop at 0. After the user reset it reads R0_RESET,
     * and it takes a new value. */
    li   a0, 10
    la   a2, stream
    la   a3, stream_end
    jal  ra, write_stream
    li   t1, 0x2
    bne  t0, t1, .Lexit
    sw   zero, CONTROL(s0)
    lw   t0, 0(s1)
    bnez t0, .Lexit
    sw   t1, CONTROL(s0)
    sw   zero, CONTROL(s0)
    lw   t0, 0(s1)
    li   t1, R0_RESET
    bne  t0, t1, .Lexit
    li   t1, 0x12345678
    sw   t1, 0(s1)
    lw   t0, 0(s1)
    bne  t0, t1, .Lexit
#endif

    li   a0, 0
.Lexit:
    li   t0, MOSAIC_ASM_SOC_CTRL_BASE
    sw   a0, 4(t0)
    li   t1, 1
    sw   t1, 0(t0)
.Lpark:
    j    .Lpark

/* Write the words from a2 up to a3 to BITSTREAM, and wait until the loader is
 * no longer busy, which it may be while it strobes the last frame or clears.
 * Returns STATUS in t0; exits with a0 if the loader stays busy. */
write_stream:
    lw   t2, 0(a2)
    sw   t2, BITSTREAM(s0)
    addi a2, a2, 4
    bne  a2, a3, write_stream
    li   t2, 64
.Lbusy:
    lw   t0, STATUS(s0)
    andi t1, t0, 1
    beqz t1, .Lidle
    addi t2, t2, -1
    bnez t2, .Lbusy
    j    .Lexit
.Lidle:
    ret

    .section .data
    .balign 4
stream:
#include EFPGA_STREAM
stream_end:
unload:
#include EFPGA_UNLOAD
unload_end:
