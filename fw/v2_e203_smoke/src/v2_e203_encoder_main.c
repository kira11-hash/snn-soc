/*
 * fw/v2_e203_smoke/src/v2_e203_encoder_main.c (Phase A-8 deferred-encode)
 *
 * NOTE: the real v2b_encode_pixel_even_rate call is compiled out under
 * the -DICARUS_SKIP_ENCODE flag used by build_v2_e203_smoke.sh to keep
 * Icarus wall-clock feasible. When that flag is NOT defined, the full
 * 64×WORDS_PER_ROW stream is written into __encoder_stream_base so an
 * FPGA Gate G3 TB (or a Verilator/VCS run) can do bit-exact parity
 * against Python sample_XX_wl_stream.hex.
 *
 * Either way the RPC handshake (REQ/DONE/ALL_DONE) is exercised in full
 * so the integration path is verified.
 */

#include <stdint.h>
#include "soc_regs_v2_e203.h"
#include "golden_fashion10.h"

void uart_init(void);
void uart_puts(const char *s);

extern void v2b_encode_pixel_even_rate(const uint8_t *pixels, uint32_t in_dim,
                                       uint32_t T, uint32_t *stream_out_bits);

int main(void)
{
    uart_init();

    /* Init RPC slots (NOLOAD garbage defense) */
    __encoder_sample_req  = 0xFFFFFFFFu;
    __encoder_sample_done = 0xFFFFFFFFu;
    __encoder_all_done    = 0u;

    /* Publish runtime BUFFER_PTRs. */
    MARKER_W(BUFFER_PTR_0_ADDR) = ENCODER_STREAM_ADDR;
    MARKER_W(BUFFER_PTR_1_ADDR) = ENCODER_SAMPLE_REQ_ADDR;
    MARKER_W(BUFFER_PTR_2_ADDR) = ENCODER_SAMPLE_DONE_ADDR;

    MARKER_W(V2E203_BOOT_MARK_ADDR) = V2E203_BOOT_MARK;
    uart_puts("FPGA_V2_E203_ENCODER_BOOT_PASS\n");

    for (;;) {
        volatile uint32_t req = __encoder_sample_req;
        if (req == 0xFFFFFFFFu) continue;
        if (req == 0xFFu) break;

#ifndef ICARUS_SKIP_ENCODE
        if (req < GOLDEN_NUM_SAMPLES) {
            v2b_encode_pixel_even_rate(golden_fashion10[req].pixel_196,
                                       GOLDEN_S0_IN_DIM,
                                       T_COUNT,
                                       (uint32_t *)__encoder_stream_base);
        }
#else
        /* Icarus skip path: write a trivial marker into stream slot 0
         * so TB can distinguish a responded round from idle, without the
         * full 1M+ cycle encoder loop. Stream bit-exact deferred to FPGA G3. */
        if (req < GOLDEN_NUM_SAMPLES) {
            __encoder_stream_base[0] = 0xE10DE10Du;
            __encoder_stream_base[1] = req;
        }
#endif

        __encoder_sample_done = req;
        __encoder_sample_req  = 0xFFFFFFFFu;
    }

    __encoder_all_done = 1u;
    MARKER_W(V2E203_ENCODER_DONE_MARK_ADDR) = V2E203_ENCODER_DONE_MARK;
    uart_puts("FPGA_V2_E203_ENCODER_ALL_DONE_PASS\n");

    for (;;) __asm__ volatile ("nop");
    return 0;
}
