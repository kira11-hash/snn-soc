/*
 * fw/v2_e203_smoke/src/v2_e203_smoke_main.c (Phase A-8)
 *
 * Full 10-sample Fashion-14x14 inference driver. Uses
 * v2b_infer_resident_14x14 from v2b_scheduler.c (retargeted via
 * v2b_scheduler_e203.c to V2B_SOC_BASE=0xA000_0000). Golden pixels /
 * weights / expected counts come from golden_fashion10.{h,c}.
 *
 * Boot order:
 *   1. uart_init
 *   2. clear counts / sample_done_flags (NOLOAD has SRAM power-up garbage)
 *   3. publish BUFFER_PTR_0/1 -> {&counts_buf, &sample_done_flags}
 *   4. BOOT_MARK + UART "FPGA_V2_E203_BOOT_UART_PASS"
 *   5. 10-sample loop (real inference)
 *   6. INFER_DONE_MARK + UART "FPGA_V2_E203_MULTILAYER_INFER_PASS"
 *   7. spin
 */

#include <stdint.h>
#include "soc_regs_v2_e203.h"
#include "golden_fashion10.h"

void uart_init(void);
void uart_puts(const char *s);
void uart_put_dec(uint32_t v);

extern int v2b_infer_resident_14x14(const uint8_t *pixel_196,
                                    const uint8_t *s0_w_pos, const uint8_t *s0_w_neg,
                                    const uint8_t *s1_w_pos, const uint8_t *s1_w_neg,
                                    int32_t *counts_out_10);

static void uart_put_sample_idx(uint32_t k)
{
    if (k < 10u) uart_puts("0");
    uart_put_dec(k);
}

static void uart_put_count_value(int32_t v)
{
    if (v < 0) {
        uart_puts("-");
        uart_put_dec((uint32_t)(-v));
    } else {
        uart_put_dec((uint32_t)v);
    }
}

static void uart_put_counts_line(uint32_t k, const int32_t *counts)
{
    uart_puts("sample ");
    uart_put_sample_idx(k);
    uart_puts(" counts=[");
    for (uint32_t j = 0; j < 10u; j++) {
        if (j != 0u) uart_puts(" ");
        uart_put_count_value(counts[j]);
    }
    uart_puts("]\n");
}

int main(void)
{
    uart_init();

    /* Clear NOLOAD buffers. */
    for (uint32_t i = 0; i < 10u; i++) __sample_done_flags[i] = 0u;
    for (uint32_t i = 0; i < 100u; i++) __smoke_counts_base[i] = 0u;

    /* Publish runtime BUFFER_PTRs. */
    MARKER_W(BUFFER_PTR_0_ADDR) = SMOKE_COUNTS_BUF_ADDR;
    MARKER_W(BUFFER_PTR_1_ADDR) = SAMPLE_DONE_FLAGS_ADDR;
    MARKER_W(BUFFER_PTR_2_ADDR) = 0u;

    /* BOOT marker and UART tag. */
    MARKER_W(V2E203_BOOT_MARK_ADDR) = V2E203_BOOT_MARK;
    uart_puts("FPGA_V2_E203_BOOT_UART_PASS\n");

    /* N-sample inference loop. FPGA G3 will run full 10; Icarus cosim
     * covers first NUM_COSIM_SAMPLES to keep wall-clock feasible.
     * Same build serves both (#if controlled in firmware only, not RTL). */
#ifndef NUM_COSIM_SAMPLES
#define NUM_COSIM_SAMPLES GOLDEN_NUM_SAMPLES
#endif
    uint32_t mismatch = 0u;
    for (uint32_t k = 0; k < NUM_COSIM_SAMPLES; k++) {
        int32_t counts[10];
        (void)v2b_infer_resident_14x14(
            golden_fashion10[k].pixel_196,
            golden_s0_w_pos, golden_s0_w_neg,
            golden_s1_w_pos, golden_s1_w_neg,
            counts);

        /* Write per-sample counts into the shared counts buffer, then
         * raise the sample-done flag so TB can poll in order. */
        for (uint32_t j = 0; j < 10u; j++) {
            __smoke_counts_base[k * 10u + j] = (uint32_t)counts[j];
            if (counts[j] != golden_fashion10[k].expected_counts[j]) {
                mismatch = 1u;
                uart_puts("FPGA_V2_E203_COUNT_MISMATCH sample=");
                uart_put_sample_idx(k);
                uart_puts(" class=");
                uart_put_dec(j);
                uart_puts(" got=");
                uart_put_count_value(counts[j]);
                uart_puts(" exp=");
                uart_put_count_value(golden_fashion10[k].expected_counts[j]);
                uart_puts("\n");
            }
        }
        __sample_done_flags[k] = 1u;
        uart_put_counts_line(k, counts);
    }

    if (mismatch) {
        uart_puts("FPGA_V2_E203_MULTILAYER_INFER_FAIL\n");
        for (;;) __asm__ volatile ("nop");
    }

    /* INFER_DONE marker + UART tag. */
    MARKER_W(V2E203_INFER_DONE_MARK_ADDR) = V2E203_INFER_DONE_MARK;
    uart_puts("FPGA_V2_E203_MULTILAYER_INFER_PASS\n");

    for (;;) __asm__ volatile ("nop");
    return 0;
}
