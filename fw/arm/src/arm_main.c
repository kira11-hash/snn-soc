/*
 * fw/arm/src/arm_main.c — Phase B / Phase C0-C1 entrypoint.
 *
 * Flow (matches plan REV 2 §D1 / §4):
 *   1. uart_init() + self-test banner "UART_OK"
 *   2. AXI-Lite MMIO round-trip self-test (write+read CFG4 reserved register)
 *   3. C0 loop: 10 samples × bypass-encoder path
 *      - per sample: load pre-encoded stream, load stage weights, run stages,
 *        count spikes, compare to expected_counts
 *      - PASS tag `ARM_FPGA_DEMO_ACCEL_FASHION10_PASS` on full 10-sample match
 *   4. C1 loop: 10 samples × full-scheduler path (real pixel encoder on CPU)
 *      - per sample: call v2b_infer_resident_14x14 on raw pixel_196
 *      - compare counts; PASS tag `ARM_FPGA_DEMO_SCHEDULER_FASHION10_PASS`
 *
 * Weight-load policy: v2b_infer_resident_14x14 (in v2b_scheduler.c) reloads
 * weights per-sample. The C0 loop mirrors that exactly so the TB matrix
 * used in Phase A parity (fw_cosim_resident_14x14_tb,
 * axi_arm_cosim_resident_14x14_tb) and the board-side firmware follow the
 * same weight-load schedule. Future boot-once resident optimisation is
 * deferred (see plan REV 2 §7 / doc/arm-fpga-demo/00_architecture.md §7).
 *
 * No libc dependency: no printf, malloc, or string.h. `uart_ps.c` provides
 * the minimal Tx primitives used here.
 */

#include <stdint.h>
#include "platform.h"
#include "uart_ps.h"
#include "golden_fashion10.h"
#include "v2b_soc_regs.h"

/* Forward declarations from v2b_scheduler.c (via v2b_scheduler_arm.c) */
extern void v2b_load_input_stream(const uint32_t *stream_bits, uint32_t T);
extern void v2b_load_mac_weights(const uint8_t *w_pos, const uint8_t *w_neg,
                                  uint32_t in_dim, uint32_t out_dim);
extern uint8_t v2b_run_stage(uint32_t in_dim, uint32_t out_dim,
                             uint32_t threshold, uint32_t sum_max,
                             uint32_t input_src, uint32_t output_dst);
extern void v2b_count_stage1_spikes(int32_t *counts_out, uint32_t out_dim);
extern int v2b_infer_resident_14x14(const uint8_t *pixel_196,
                                    const uint8_t *s0_w_pos, const uint8_t *s0_w_neg,
                                    const uint8_t *s1_w_pos, const uint8_t *s1_w_neg,
                                    int32_t *counts_out_10);

/* Must match topology constants in v2b_scheduler.c and golden_fashion10.h */
#define S0_IN_DIM   GOLDEN_S0_IN_DIM
#define S0_OUT_DIM  GOLDEN_S0_OUT_DIM
#define S0_THRESHOLD 16u
#define S0_SUM_MAX   2940u
#define S1_IN_DIM   GOLDEN_S1_IN_DIM
#define S1_OUT_DIM  GOLDEN_S1_OUT_DIM
#define S1_THRESHOLD 8u
#define S1_SUM_MAX   960u
#define T_COUNT     GOLDEN_T

static int32_t counts_buf[S1_OUT_DIM];

static int counts_match(const int32_t *got, const int32_t *exp)
{
    for (uint32_t j = 0; j < S1_OUT_DIM; j++)
        if (got[j] != exp[j]) return 0;
    return 1;
}

static void print_counts(const int32_t *c)
{
    uart_puts("counts=[");
    for (uint32_t j = 0; j < S1_OUT_DIM; j++) {
        uart_put_dec(c[j]);
        if (j + 1 < S1_OUT_DIM) uart_putc(' ');
    }
    uart_puts("]\n");
}

/* Bypass-encoder path: stream is pre-encoded in golden header. */
static int c0_run_sample(const v2b_fashion_sample_t *s, int k)
{
    V2B_SOC_STREAM_BUF_CTRL = V2B_SOC_STREAM_BUF_CLEAR_A | V2B_SOC_STREAM_BUF_CLEAR_B;
    v2b_load_input_stream(s->encoded_stream, T_COUNT);
    v2b_load_mac_weights(golden_s0_w_pos, golden_s0_w_neg, S0_IN_DIM, S0_OUT_DIM);
    uint8_t e0 = v2b_run_stage(S0_IN_DIM, S0_OUT_DIM, S0_THRESHOLD, S0_SUM_MAX,
                                V2B_SOC_BUF_SEL_INPUT_SRAM,
                                V2B_SOC_BUF_SEL_STREAM_A);
    if (e0 != 0) {
        uart_puts("[FAIL] sample "); uart_put_dec(k);
        uart_puts(" stage0 err="); uart_put_hex32(e0); uart_putc('\n');
        return 0;
    }
    v2b_load_mac_weights(golden_s1_w_pos, golden_s1_w_neg, S1_IN_DIM, S1_OUT_DIM);
    uint8_t e1 = v2b_run_stage(S1_IN_DIM, S1_OUT_DIM, S1_THRESHOLD, S1_SUM_MAX,
                                V2B_SOC_BUF_SEL_STREAM_A,
                                V2B_SOC_BUF_SEL_STREAM_B);
    if (e1 != 0) {
        uart_puts("[FAIL] sample "); uart_put_dec(k);
        uart_puts(" stage1 err="); uart_put_hex32(e1); uart_putc('\n');
        return 0;
    }
    v2b_count_stage1_spikes(counts_buf, S1_OUT_DIM);
    if (!counts_match(counts_buf, s->expected_counts)) {
        uart_puts("[FAIL] sample "); uart_put_dec(k);
        uart_puts(" count mismatch, got "); print_counts(counts_buf);
        uart_puts("       expected      "); print_counts(s->expected_counts);
        return 0;
    }
    uart_puts("[PASS] sample "); uart_put_dec(k);
    uart_puts(" class="); uart_put_dec((int32_t)s->expected_class);
    uart_puts(" "); print_counts(counts_buf);
    return 1;
}

static int c1_run_sample(const v2b_fashion_sample_t *s, int k)
{
    int pred = v2b_infer_resident_14x14(
        s->pixel_196,
        golden_s0_w_pos, golden_s0_w_neg,
        golden_s1_w_pos, golden_s1_w_neg,
        counts_buf);
    if (pred < 0) {
        uart_puts("[FAIL] sample "); uart_put_dec(k);
        uart_puts(" infer rc="); uart_put_dec(pred); uart_putc('\n');
        return 0;
    }
    if (!counts_match(counts_buf, s->expected_counts)) {
        uart_puts("[FAIL] sample "); uart_put_dec(k);
        uart_puts(" scheduler count mismatch, got "); print_counts(counts_buf);
        uart_puts("       expected      "); print_counts(s->expected_counts);
        return 0;
    }
    uart_puts("[PASS] sample "); uart_put_dec(k);
    uart_puts(" predicted="); uart_put_dec(pred);
    uart_puts(" "); print_counts(counts_buf);
    return 1;
}

static int mmio_self_test(void)
{
    /* CFG1 (threshold) is a plain 32-bit R/W register (see v2b_soc_v2b_top:341
     * and read_mux :442). v2b_top doesn't connect CFG4, so writes to CFG4
     * are silently dropped and reads return 0 — using CFG1 instead gives a
     * true round-trip. sw_run_stage will overwrite CFG1 before each stage,
     * so clobbering it here is harmless. */
    V2B_SOC_STAGE_CFG1 = 0xDEADBEEFu;
    uint32_t rb = V2B_SOC_STAGE_CFG1;
    if (rb != 0xDEADBEEFu) {
        uart_puts("[FATAL] MMIO self-test CFG1 mismatch got "); uart_put_hex32(rb);
        uart_puts(" exp 0xDEADBEEF\n");
        return 0;
    }
    V2B_SOC_STAGE_CFG1 = 0x12345678u;
    rb = V2B_SOC_STAGE_CFG1;
    if (rb != 0x12345678u) {
        uart_puts("[FATAL] MMIO self-test CFG1 2nd mismatch got "); uart_put_hex32(rb);
        uart_puts(" exp 0x12345678\n");
        return 0;
    }
    V2B_SOC_STAGE_CFG1 = 0u;   /* leave clean */
    uart_puts("[OK] MMIO round-trip CFG1\n");
    return 1;
}

int arm_main(void)
{
    uart_init();
    uart_puts("\nUART_OK\n");
    uart_puts("[TB] v2b_arm_demo start — 10 Fashion 14x14 samples via AXI-Lite\n");
    uart_puts("[TB] V2B_SOC_BASE=");  uart_put_hex32(V2B_SOC_BASE);  uart_putc('\n');

    if (!mmio_self_test()) {
        uart_puts("ARM_FPGA_DEMO_MMIO_FAIL\n");
        return -1;
    }

    /* ── C0 loop: bypass encoder, use pre-encoded streams ── */
    uart_puts("\n[TB] C0 loop (bypass encoder)\n");
    int c0_pass = 0;
    for (int k = 0; k < (int)GOLDEN_NUM_SAMPLES; k++) {
        if (c0_run_sample(&golden_fashion10[k], k)) c0_pass++;
    }
    if (c0_pass == (int)GOLDEN_NUM_SAMPLES) {
        uart_puts("ARM_FPGA_DEMO_ACCEL_FASHION10_PASS\n");
    } else {
        uart_puts("ARM_FPGA_DEMO_ACCEL_FASHION10_FAIL passes=");
        uart_put_dec(c0_pass); uart_puts("/10\n");
    }

    /* ── C1 loop: full scheduler flow (encoder runs on CPU) ── */
    uart_puts("\n[TB] C1 loop (full scheduler, real pixel encoder)\n");
    int c1_pass = 0;
    for (int k = 0; k < (int)GOLDEN_NUM_SAMPLES; k++) {
        if (c1_run_sample(&golden_fashion10[k], k)) c1_pass++;
    }
    if (c1_pass == (int)GOLDEN_NUM_SAMPLES) {
        uart_puts("ARM_FPGA_DEMO_SCHEDULER_FASHION10_PASS\n");
    } else {
        uart_puts("ARM_FPGA_DEMO_SCHEDULER_FASHION10_FAIL passes=");
        uart_put_dec(c1_pass); uart_puts("/10\n");
    }

    /* Spin forever — JTAG can re-launch if needed */
    for (;;) { __asm__ volatile("wfi"); }
    return 0;
}
