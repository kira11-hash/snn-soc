/*
 * fw/v2_e203_smoke/src/v2_e203_encoder_main.c  (Phase A-6 minimal skeleton)
 *
 * Minimal RPC handshake skeleton (no UART). Real encoder port lives in
 * Phase A-8.
 */

#include <stdint.h>
#include "soc_regs_v2_e203.h"

int main(void)
{
    /* Init RPC slots */
    MARKER_W(ENCODER_SAMPLE_REQ_ADDR)  = 0xFFFFFFFFu;
    MARKER_W(ENCODER_SAMPLE_DONE_ADDR) = 0xFFFFFFFFu;

    /* Publish BUFFER_PTRs */
    MARKER_W(BUFFER_PTR_0_ADDR) = ENCODER_STREAM_BASE;
    MARKER_W(BUFFER_PTR_1_ADDR) = ENCODER_SAMPLE_REQ_ADDR;
    MARKER_W(BUFFER_PTR_2_ADDR) = ENCODER_SAMPLE_DONE_ADDR;

    /* BOOT marker (after PTRs so TB can find them) */
    MARKER_W(V2E203_BOOT_MARK_ADDR) = V2E203_BOOT_MARK;

    /* RPC loop */
    for (;;) {
        volatile uint32_t req = MARKER_W(ENCODER_SAMPLE_REQ_ADDR);
        if (req == 0xFFFFFFFFu) continue;
        if (req == 0xFFu) break;
        /* Echo (TODO Phase A-8: replace with real encoder + stream write) */
        MARKER_W(ENCODER_SAMPLE_DONE_ADDR) = req;
        MARKER_W(ENCODER_SAMPLE_REQ_ADDR)  = 0xFFFFFFFFu;
    }

    MARKER_W(V2E203_ENCODER_DONE_MARK_ADDR) = V2E203_ENCODER_DONE_MARK;

    for (;;) __asm__ volatile ("nop");
    return 0;
}
