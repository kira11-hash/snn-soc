/*
 * fw/v2_e203_smoke/src/v2_e203_lenet5_main.c
 *
 * Board-ready LeNet-5 driver for the ZCU102 + E203 + V2.B CONV evidence path.
 * Sample inputs are stored sparsely in IMEM-friendly tables, reconstructed into
 * a 784-word scratch buffer, then executed via the shared V2.B CONV scheduler.
 */

#include <stdint.h>
#include "soc_regs_v2_e203.h"
#include "v2b_soc_regs.h"
#include "golden_lenet5.h"
#include "v2b_conv_scheduler.h"

void uart_init(void);
void uart_putc(char c);
void uart_puts(const char *s);
void uart_put_dec(uint32_t v);
void uart_put_hex32(uint32_t v);

extern int v2b_run_lenet5_demo(const uint32_t *input_words, int32_t *counts_out_10);

volatile uint32_t g_arm_progress_code = 0u;
volatile uint32_t g_arm_progress_aux0 = 0u;
volatile uint32_t g_arm_progress_aux1 = 0u;
volatile uint32_t g_arm_progress_aux2 = 0u;

static uint32_t g_input_words[LENET5_INPUT_WORDS];
static int32_t g_counts_buf[10];

static void uart_put_sample_idx(uint32_t idx)
{
    if (idx < 10u) uart_putc('0');
    uart_put_dec(idx);
}

static void print_counts_i32(const int32_t *counts)
{
    uart_puts("counts=[");
    for (uint32_t j = 0; j < 10u; j++) {
        uart_put_dec((uint32_t)counts[j]);
        if (j + 1u < 10u) uart_putc(' ');
    }
    uart_puts("]\n");
}

static void print_counts_u8(const uint8_t *counts)
{
    uart_puts("counts=[");
    for (uint32_t j = 0; j < 10u; j++) {
        uart_put_dec((uint32_t)counts[j]);
        if (j + 1u < 10u) uart_putc(' ');
    }
    uart_puts("]\n");
}

static void materialize_input_words(const v2b_lenet5_sample_t *sample)
{
    for (uint32_t i = 0; i < LENET5_INPUT_WORDS; i++) {
        g_input_words[i] = 0u;
    }
    for (uint32_t k = 0; k < sample->input_nz_count; k++) {
        uint32_t idx = (uint32_t)sample->input_nz_offset + k;
        uint32_t word_idx = lenet5_input_nz_indices[idx];
        g_input_words[word_idx] = lenet5_input_nz_words[idx];
    }
}

static int counts_match(const int32_t *got, const uint8_t *exp)
{
    for (uint32_t j = 0; j < 10u; j++) {
        if (got[j] != (int32_t)exp[j]) return 0;
    }
    return 1;
}

static int argmax_counts(const int32_t *counts)
{
    int best_idx = 0;
    int32_t best_val = counts[0];
    for (int j = 1; j < 10; j++) {
        if (counts[j] > best_val) {
            best_val = counts[j];
            best_idx = j;
        }
    }
    return best_idx;
}

static int mmio_self_test(void)
{
    V2B_SOC_STAGE_CFG1 = 0xDEADBEEFu;
    if (V2B_SOC_STAGE_CFG1 != 0xDEADBEEFu) return 0;
    V2B_SOC_STAGE_CFG1 = 0x12345678u;
    if (V2B_SOC_STAGE_CFG1 != 0x12345678u) return 0;
    V2B_SOC_STAGE_CFG1 = 0u;
    return 1;
}

static int run_sample(const v2b_lenet5_sample_t *sample, uint32_t idx)
{
    int pred;
    int rc;

    uart_puts("[TB] sample ");
    uart_put_sample_idx(idx);
    uart_puts(" start nz=");
    uart_put_dec(sample->input_nz_count);
    uart_puts("\n");

    materialize_input_words(sample);
    rc = v2b_run_lenet5_demo(g_input_words, g_counts_buf);
    if (rc != 0) {
        uart_puts("[FAIL] sample ");
        uart_put_sample_idx(idx);
        uart_puts(" run rc=");
        uart_put_dec((uint32_t)(-rc));
        uart_putc('\n');
        return 0;
    }
    if (!counts_match(g_counts_buf, sample->expected_counts)) {
        uart_puts("[FAIL] sample ");
        uart_put_sample_idx(idx);
        uart_puts(" count mismatch got ");
        print_counts_i32(g_counts_buf);
        uart_puts("       expected      ");
        print_counts_u8(sample->expected_counts);
        return 0;
    }

    pred = argmax_counts(g_counts_buf);
    uart_puts("[PASS] sample ");
    uart_put_sample_idx(idx);
    uart_puts(" label=");
    uart_put_dec(sample->label);
    uart_puts(" pred=");
    uart_put_dec((uint32_t)pred);
    uart_puts(" ");
    print_counts_i32(g_counts_buf);
    return pred == (int)sample->expected_class;
}

int main(void)
{
    int pass = 0;

    uart_init();

    MARKER_W(BUFFER_PTR_0_ADDR) = 0u;
    MARKER_W(BUFFER_PTR_1_ADDR) = 0u;
    MARKER_W(BUFFER_PTR_2_ADDR) = 0u;
    MARKER_W(V2E203_BOOT_MARK_ADDR) = V2E203_BOOT_MARK;

    uart_puts("FPGA_V2_E203_BOOT_UART_PASS\n");
    uart_puts("[TB] v2_e203_lenet5 start - 10 LeNet-5 samples via E203 + CONV\n");
    uart_puts("[TB] V2B_SOC_BASE=");
    uart_put_hex32(V2B_SOC_BASE);
    uart_putc('\n');

    if (!mmio_self_test()) {
        uart_puts("[FATAL] MMIO round-trip CFG1 failed\n");
        uart_puts("FPGA_V2_E203_LENET5_FAIL\n");
        return -1;
    }
    uart_puts("[OK] MMIO round-trip CFG1\n");

    for (uint32_t i = 0; i < LENET5_NUM_SAMPLES; i++) {
        pass += run_sample(&golden_lenet5[i], i) ? 1 : 0;
    }

    if (pass == (int)LENET5_NUM_SAMPLES) {
        MARKER_W(V2E203_INFER_DONE_MARK_ADDR) = V2E203_INFER_DONE_MARK;
        uart_puts("FPGA_V2_E203_LENET5_PASS\n");
    } else {
        uart_puts("FPGA_V2_E203_LENET5_FAIL passes=");
        uart_put_dec((uint32_t)pass);
        uart_puts("/10\n");
    }

    for (;;) __asm__ volatile ("nop");
    return 0;
}
