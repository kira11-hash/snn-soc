/*
 * fw/v2_e203_smoke/src/v2_e203_smoke_main.c  (Phase A-6 minimal skeleton)
 *
 * Minimal skeleton: write BOOT_MARK + BUFFER_PTR + INFER_DONE markers
 * to DMEM, then infinite spin. No UART, no bss loop — leaves UART
 * + inference for Phase A-8.
 */

#include <stdint.h>
#include "soc_regs_v2_e203.h"

int main(void)
{
    /* Publish BUFFER_PTRs (point to "expected" regions in DMEM) */
    MARKER_W(BUFFER_PTR_0_ADDR) = SMOKE_COUNTS_BUF_BASE;
    MARKER_W(BUFFER_PTR_1_ADDR) = SAMPLE_DONE_FLAGS_BASE;
    MARKER_W(BUFFER_PTR_2_ADDR) = 0u;

    /* BOOT marker */
    MARKER_W(V2E203_BOOT_MARK_ADDR) = V2E203_BOOT_MARK;

    /* Skeleton skips actual inference (Phase A-8 task) */

    /* INFER_DONE marker */
    MARKER_W(V2E203_INFER_DONE_MARK_ADDR) = V2E203_INFER_DONE_MARK;

    /* Spin */
    for (;;) {
        __asm__ volatile ("nop");
    }
    return 0;
}
