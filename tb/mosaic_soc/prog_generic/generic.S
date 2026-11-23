/* Topology-generic MOSAIC liveness firmware.
 *
 * Every boot image is linked separately from this source. Free-running shared
 * images identify harts with mhartid; singleton images use their generated
 * fixed hart ID. All harts write a unique non-zero sentinel. Hart 0 optionally
 * wakes every non-TITAN hart through the TDU, waits for all configured harts,
 * and exits.
 * Only RV32I+Zicsr instructions and x0-x15 are used, so the image is valid for
 * RV32E controllers and as an instruction stream on the RV64 simulation tiles.
 *
 * MOSAIC_GENERIC_EFPGA=1 (run_generic.sh EFPGA_DESIGN=<design>.v): before it wakes
 * anyone, hart 0 sets the fabric's clock to MOSAIC_GENERIC_EFPGA_CLKDIV if it is
 * defined (the N the design was timed at, less one; a read-back that differs is
 * failure 5), loads the stream of efpga_stream.inc into the eFPGA, connects it
 * and checks the design's window word 0, a register the user reset clears, on
 * every data line each way (tb/efpga/shell_regs.v), and leaves 0xA5 in it. A
 * failed check exits with 0x40000000 | its number.
 */

#include <mosaic_memory_map.inc>

#ifndef MOSAIC_GENERIC_PRIMARY
#define MOSAIC_GENERIC_PRIMARY 0
#endif
#ifndef MOSAIC_GENERIC_NUM_HARTS
#define MOSAIC_GENERIC_NUM_HARTS 1
#endif
#ifndef MOSAIC_GENERIC_WAKE_MASK
#define MOSAIC_GENERIC_WAKE_MASK 0
#endif
#ifndef MOSAIC_GENERIC_DISPATCH_MASK
#define MOSAIC_GENERIC_DISPATCH_MASK MOSAIC_GENERIC_WAKE_MASK
#endif
#ifndef MOSAIC_GENERIC_TDU
#define MOSAIC_GENERIC_TDU 0
#endif
#ifndef MOSAIC_GENERIC_TL_WINDOW
#define MOSAIC_GENERIC_TL_WINDOW 0
#endif
#ifndef MOSAIC_GENERIC_PRIMARY_SHARED
#define MOSAIC_GENERIC_PRIMARY_SHARED 0
#endif
#ifndef MOSAIC_GENERIC_FIXED_HART
#define MOSAIC_GENERIC_FIXED_HART 0
#endif
#ifndef MOSAIC_GENERIC_TESTBENCH_BOOTSTRAP
#define MOSAIC_GENERIC_TESTBENCH_BOOTSTRAP 0
#endif
#ifndef MOSAIC_GENERIC_EFPGA
#define MOSAIC_GENERIC_EFPGA 0
#endif

#if MOSAIC_GENERIC_TL_WINDOW
#define GENERIC_SENT_BASE MOSAIC_ASM_TL_SENTINEL_BASE
#define GENERIC_SOC_CTRL_BASE MOSAIC_ASM_TL_SOC_CTRL_BASE
#define GENERIC_TDU_BASE MOSAIC_ASM_TL_TDU_BASE
#else
#define GENERIC_SENT_BASE MOSAIC_ASM_SENTINEL_BASE
#define GENERIC_SOC_CTRL_BASE MOSAIC_ASM_SOC_CTRL_BASE
#define GENERIC_TDU_BASE MOSAIC_ASM_TDU_BASE
#endif

    .section .text.init,"ax"
    .global _start
_start:
#if MOSAIC_GENERIC_PRIMARY
#if MOSAIC_GENERIC_TESTBENCH_BOOTSTRAP
    /* This image may be shared by free-running testbench hart 0 and workers
     * without mhartid.  The reset-empty queue identifies hart 0; workers are
     * released only by targeted descriptors and arrive with a nonzero task. */
    li   t0, (GENERIC_TDU_BASE + 0x14)
    lw   t1, 0(t0)
    bnez t1, .Lworker_have_task
#endif
#if MOSAIC_GENERIC_PRIMARY_SHARED
    csrr t0, mhartid
#else
    li   t0, MOSAIC_GENERIC_FIXED_HART
#endif

    /* sentinel[mhartid] = hartid + 1 */
    slli t1, t0, 2
    li   t2, GENERIC_SENT_BASE
    add  t2, t2, t1
    addi t1, t0, 1
    sw   t1, 0(t2)

    bnez t0, .Lpark

#if MOSAIC_GENERIC_EFPGA
    /* The registers of sw/firmware/common/efpga.h: BITSTREAM 0x0, STATUS 0x4
     * (CONFIGURED 0x2, BUSY 0x1), CONTROL 0x8 (USER_RESET 0x2). */
    li   t0, MOSAIC_ASM_EFPGA_BASE
#ifdef MOSAIC_GENERIC_EFPGA_CLKDIV
    /* CLKDIV 0x18, before the stream: a write while connected is dropped. */
    li   a1, 5
    li   a2, MOSAIC_GENERIC_EFPGA_CLKDIV
    sw   a2, 0x18(t0)
    lw   a0, 0x18(t0)
    bne  a0, a2, .Lefpga_fail
#endif
    la   t1, efpga_stream
    la   t2, efpga_stream_end
.Lefpga_word:
    lw   a0, 0(t1)
    sw   a0, 0(t0)
    addi t1, t1, 4
    bne  t1, t2, .Lefpga_word
.Lefpga_busy:
    lw   a0, 4(t0)
    andi a2, a0, 1
    bnez a2, .Lefpga_busy
    li   a1, 1
    li   a2, 2
    bne  a0, a2, .Lefpga_fail
    sw   a2, 8(t0)
    sw   zero, 8(t0)
    li   t1, MOSAIC_ASM_EFPGA_WINDOW_BASE
    li   a1, 2
    lw   a0, 0(t1)
    bnez a0, .Lefpga_fail
    li   a1, 3
    li   a2, 1
.Lefpga_line:
    sw   a2, 0(t1)
    lw   a0, 0(t1)
    bne  a0, a2, .Lefpga_fail
    xori a3, a2, -1
    sw   a3, 0(t1)
    lw   a0, 0(t1)
    bne  a0, a3, .Lefpga_fail
    slli a2, a2, 1
    bnez a2, .Lefpga_line
    /* The design drives its pads with R[7:0]: a delivery wrapper with no pad
     * ring has them at its pins (tb/efpga/tb_efpga_soc.sv reads them). */
    li   a2, 0xA5
    sw   a2, 0(t1)
    /* Every request answered: no timeout, nothing blocked. */
    li   a1, 4
    lw   a0, 4(t0)
    li   a2, 2
    beq  a0, a2, .Lefpga_done
.Lefpga_fail:
    li   t0, GENERIC_SOC_CTRL_BASE
    li   a0, 0x40000000
    or   a0, a0, a1
    sw   a0, 4(t0)
    li   t1, 1
    sw   t1, 0(t0)
    j    .Lpark
.Lefpga_done:
#endif

#if MOSAIC_GENERIC_TDU && MOSAIC_GENERIC_WAKE_MASK
    /* Normal AMP images can broadcast-wake before queueing.  A worker-only
     * testbench instead arms WAKE_MASK and lets each targeted descriptor push
     * release exactly its hinted hart, because no TITAN exists to start it. */
#if MOSAIC_GENERIC_TESTBENCH_BOOTSTRAP
    li   t1, (GENERIC_TDU_BASE + 0x08)
    li   t2, MOSAIC_GENERIC_WAKE_MASK
    sw   t2, 0(t1)
#else
    li   t1, (GENERIC_TDU_BASE + 0x0c)
    li   t2, MOSAIC_GENERIC_WAKE_MASK
    sw   t2, 0(t1)
#endif

    li   t0, 1
.Lpush_next:
    li   t1, MOSAIC_GENERIC_NUM_HARTS
    bge  t0, t1, .Lpush_done
    li   t1, 1
    sll  t1, t1, t0
    li   t2, MOSAIC_GENERIC_DISPATCH_MASK
    and  t1, t1, t2
    beqz t1, .Lpush_skip
.Lpush_wait:
    li   t1, (GENERIC_TDU_BASE + 0x18)
    lw   t2, 0(t1)
    andi t2, t2, 0x20
    bnez t2, .Lpush_wait
    slli t1, t0, 11
    li   t2, 0x00010000
    or   t1, t1, t2
    li   t2, (GENERIC_TDU_BASE + 0x10)
    sw   t1, 0(t2)
.Lpush_skip:
    addi t0, t0, 1
    j    .Lpush_next
.Lpush_done:
#endif

    /* The combined HEX initializes the generated shared-control range to zero.
     * Require each exact hart-derived value, not merely nonzero memory. */
    li   t0, GENERIC_SENT_BASE
    li   t1, (GENERIC_SENT_BASE + 4 * MOSAIC_GENERIC_NUM_HARTS)
    li   t2, 1
.Lscan:
    lw   a0, 0(t0)
    bne  a0, t2, .Lscan
    addi t0, t0, 4
    addi t2, t2, 1
    bne  t0, t1, .Lscan

    li   t0, GENERIC_SOC_CTRL_BASE
    sw   zero, 4(t0)
    li   t1, 1
    sw   t1, 0(t0)

#endif

#if !MOSAIC_GENERIC_PRIMARY || MOSAIC_GENERIC_TESTBENCH_BOOTSTRAP
.Lworker:
    /* Dormant workers need no CSR support. An atomic TASK_POP descriptor
     * supplies a unique sentinel slot even when many harts share this image. */
#if MOSAIC_GENERIC_TDU
    li   t0, (GENERIC_TDU_BASE + 0x14)
.Lpop:
    lw   t1, 0(t0)
    beqz t1, .Lpop
.Lworker_have_task:
    srli t1, t1, 11
    andi t1, t1, 0x1f
    slli t2, t1, 2
    li   t0, GENERIC_SENT_BASE
    add  t0, t0, t2
    addi t1, t1, 1
    sw   t1, 0(t0)
#else
    /* Config validation only permits dormant worker roles with a TDU. */
    j .Lpark
#endif
#endif

.Lpark:
    j .Lpark

#if MOSAIC_GENERIC_PRIMARY && MOSAIC_GENERIC_EFPGA
    .section .rodata
    .balign 4
efpga_stream:
#include "efpga_stream.inc"
efpga_stream_end:
#endif
