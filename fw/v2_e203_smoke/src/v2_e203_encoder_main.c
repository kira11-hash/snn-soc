/*
 * fw/v2_e203_smoke/src/v2_e203_encoder_main.c (Phase A-8)
 *
 * Real encoder-parity firmware: TB drives sample index via
 * ENCODER_SAMPLE_REQ (runtime address published via BUFFER_PTR_1).
 * CPU runs v2b_encode_pixel_even_rate on golden_fashion10[k].pixel_196
 * and writes the resulting 64×8 uint32 stream to
 * ENCODER_STREAM_BASE (published via BUFFER_PTR_0), then sets
 * SAMPLE_DONE = k. TB compares the stream to
 * python_multilayer/.../fashion_multilayer_golden/sample_kk_wl_stream.hex.
 *
 * RPC state machine:
 *   REQ == 0xFFFFFFFF : idle, no work
 *   REQ == 0..9       : encode sample k, fill stream, set DONE=k, set REQ=IDLE
 *   REQ == 0xFF       : terminate, write ENCODER_DONE_MARK
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

        /* Real encode: write stream_out_bits to __encoder_stream_base. */
        if (req < GOLDEN_NUM_SAMPLES) {
            v2b_encode_pixel_even_rate(golden_fashion10[req].pixel_196,
                                       GOLDEN_S0_IN_DIM,
                                       T_COUNT,
                                       (uint32_t *)__encoder_stream_base);
        }

        __encoder_sample_done = req;
        __encoder_sample_req  = 0xFFFFFFFFu;
    }

    __encoder_all_done = 1u;
    MARKER_W(V2E203_ENCODER_DONE_MARK_ADDR) = V2E203_ENCODER_DONE_MARK;
    uart_puts("FPGA_V2_E203_ENCODER_ALL_DONE_PASS\n");

    for (;;) __asm__ volatile ("nop");
    return 0;
}
