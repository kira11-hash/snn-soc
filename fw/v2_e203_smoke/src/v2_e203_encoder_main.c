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
    __encoder_sample_req  = 0xFFFFFFFFu;
    __encoder_sample_done = 0xFFFFFFFFu;
    __encoder_all_done    = 0u;

    /* Publish BUFFER_PTRs */
    MARKER_W(BUFFER_PTR_0_ADDR) = ENCODER_STREAM_ADDR;
    MARKER_W(BUFFER_PTR_1_ADDR) = ENCODER_SAMPLE_REQ_ADDR;
    MARKER_W(BUFFER_PTR_2_ADDR) = ENCODER_SAMPLE_DONE_ADDR;

    /* BOOT marker (after PTRs so TB can find them) */
    MARKER_W(V2E203_BOOT_MARK_ADDR) = V2E203_BOOT_MARK;

    /* RPC loop */
    for (;;) {
        volatile uint32_t req = __encoder_sample_req;
        if (req == 0xFFFFFFFFu) continue;
        if (req == 0xFFu) break;
        /* Echo (TODO Phase A-8: replace with real encoder + stream write) */
        __encoder_sample_done = req;
        __encoder_sample_req  = 0xFFFFFFFFu;
    }

    __encoder_all_done = 1u;
    MARKER_W(V2E203_ENCODER_DONE_MARK_ADDR) = V2E203_ENCODER_DONE_MARK;

    for (;;) __asm__ volatile ("nop");
    return 0;
}
