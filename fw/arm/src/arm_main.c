/*
 * fw/arm/src/arm_main.c
 *
 * ZCU102 ARM-hosted LeNet-5 CONV evidence entrypoint.
 */

#include <stdint.h>
#include "platform.h"
#include "uart_ps.h"
#include "v2b_soc_regs.h"
#include "golden_lenet5.h"
#include "v2b_conv_scheduler.h"

static int32_t counts_buf[10];
volatile uint32_t g_arm_current_sample_idx = 0u;
volatile uint32_t g_arm_progress_code = 0u;
volatile uint32_t g_arm_progress_aux0 = 0u;
volatile uint32_t g_arm_progress_aux1 = 0u;
volatile uint32_t g_arm_progress_aux2 = 0u;

static int counts_match(const int32_t *got, const int32_t *exp)
{
    for (uint32_t j = 0; j < 10u; j++) {
        if (got[j] != exp[j]) return 0;
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

static void print_counts(const int32_t *counts)
{
    uart_puts("counts=[");
    for (uint32_t j = 0; j < 10u; j++) {
        uart_put_dec((uint32_t)counts[j]);
        if (j + 1u < 10u) uart_putc(' ');
    }
    uart_puts("]\n");
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
    uart_puts("[TB] sample "); uart_put_dec(idx); uart_puts(" start\n");
    g_arm_current_sample_idx = idx;
    int rc = v2b_run_lenet5_demo(
        sample->input_words,
        counts_buf
    );
    if (rc != 0) {
        uart_puts("[FAIL] sample "); uart_put_dec(idx);
        uart_puts(" run rc="); uart_put_dec((uint32_t)(-rc)); uart_putc('\n');
        return 0;
    }
    if (!counts_match(counts_buf, sample->expected_counts)) {
        uart_puts("[FAIL] sample "); uart_put_dec(idx);
        uart_puts(" count mismatch got "); print_counts(counts_buf);
        uart_puts("       expected      "); print_counts(sample->expected_counts);
        return 0;
    }
    {
        int pred = argmax_counts(counts_buf);
        uart_puts("[PASS] sample "); uart_put_dec(idx);
        uart_puts(" label="); uart_put_dec(sample->label);
        uart_puts(" pred="); uart_put_dec((uint32_t)pred);
        uart_puts(" "); print_counts(counts_buf);
        return pred == (int)sample->expected_class;
    }
}

int arm_main(void)
{
    int pass = 0;

    uart_init();
    uart_puts("\nUART_OK\n");
    uart_puts("[TB] v2b_arm_lenet5 start - 10 LeNet-5 samples via AXI-Lite\n");
    uart_puts("[TB] V2B_SOC_BASE="); uart_put_hex32(V2B_SOC_BASE); uart_putc('\n');

    if (!mmio_self_test()) {
        uart_puts("[FATAL] MMIO round-trip CFG1 failed\n");
        uart_puts("ARM_FPGA_DEMO_LENET5_FAIL\n");
        return -1;
    }
    uart_puts("[OK] MMIO round-trip CFG1\n");

    for (uint32_t i = 0; i < LENET5_NUM_SAMPLES; i++) {
        pass += run_sample(&golden_lenet5[i], i) ? 1 : 0;
    }

    if (pass == (int)LENET5_NUM_SAMPLES) {
        uart_puts("ARM_FPGA_DEMO_LENET5_PASS\n");
    } else {
        uart_puts("ARM_FPGA_DEMO_LENET5_FAIL passes=");
        uart_put_dec((uint32_t)pass);
        uart_puts("/10\n");
    }

    for (;;) { __asm__ volatile("wfi"); }
    return 0;
}
