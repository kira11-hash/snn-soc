/*
 * fw/arm/src/arm_main_fashion14.c
 *
 * ARM-side Fashion-14x14 2-layer FC runner for M1 Phase 1 board closure.
 * Uses the shared resident scheduler plus the trace-hash wrapper so each
 * sample emits one TRACE_HASH_BEGIN ... END block that can be diffed against
 * the E203 path.
 */

#include <stdint.h>
#include "platform.h"
#include "uart_ps.h"
#include "golden_fashion10.h"
#include "v2b_soc_regs.h"
#include "v2b_scheduler.h"

#if defined(V2B_M3_ENABLED)
#include "v2b_m3_cycles.h"
static v2b_m3_state_t g_m3_state;
#endif

#ifndef V2B_M3_CONFIG_NAME
#define V2B_M3_CONFIG_NAME "v2b_fc_fashion14_2L"
#endif
#ifndef V2B_M3_HOST_NAME
#define V2B_M3_HOST_NAME "arm"
#endif

static int32_t counts_buf[10];

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

static int run_sample(const v2b_fashion_sample_t *sample, uint32_t idx)
{
#if defined(V2B_M3_ENABLED)
    /* M3 Phase 2A build: route through the cycle-partition variant. counts
     * still match expected_counts (no datapath perturbation), but each
     * sample emits one extra M3_CYCLES line in addition to TRACE_HASH
     * lines that the _trace path would have emitted. We deliberately do
     * NOT also call _trace here — the M1 trace evidence is already
     * captured on the existing board run; this build is dedicated to
     * latency partition. */
    v2b_m3_init(&g_m3_state);
    int rc = v2b_infer_resident_14x14_m3(
        sample->pixel_196,
        golden_s0_w_pos, golden_s0_w_neg,
        golden_s1_w_pos, golden_s1_w_neg,
        counts_buf,
        &g_m3_state
    );
    /* Dump unconditionally — even on failure we want the partial cycle
     * partition for diagnosis. dump_uart returns 1 on success / 0 on NULL. */
    v2b_m3_dump_uart(&g_m3_state, V2B_M3_CONFIG_NAME, V2B_M3_HOST_NAME, idx);
#else
    int rc = v2b_infer_resident_14x14_trace(
        sample->pixel_196,
        golden_s0_w_pos, golden_s0_w_neg,
        golden_s1_w_pos, golden_s1_w_neg,
        counts_buf,
        idx
    );
#endif

    if (rc < 0) {
        uart_puts("[FAIL] sample ");
        uart_put_dec(idx);
        uart_puts(" run rc=");
        uart_put_dec((uint32_t)(-rc));
        uart_putc('\n');
        return 0;
    }
    if (!counts_match(counts_buf, sample->expected_counts)) {
        uart_puts("[FAIL] sample ");
        uart_put_dec(idx);
        uart_puts(" count mismatch got ");
        print_counts(counts_buf);
        uart_puts("       expected      ");
        print_counts(sample->expected_counts);
        return 0;
    }

    {
        int pred = argmax_counts(counts_buf);
        uart_puts("[PASS] sample ");
        uart_put_dec(idx);
        uart_puts(" label=");
        uart_put_dec(sample->expected_class);
        uart_puts(" pred=");
        uart_put_dec((uint32_t)pred);
        uart_puts(" ");
        print_counts(counts_buf);
        return pred == (int)sample->expected_class;
    }
}

int arm_main(void)
{
    int pass = 0;

    uart_init();
    uart_puts("\nUART_OK\n");
#if defined(V2B_M3_ENABLED)
    uart_puts("[TB] v2b_arm_fashion14_m3 start - 10 Fashion 14x14 samples (M3 latency partition)\n");
    /* Enable PMCCNTR_EL0 once before any inference loop. Subsequent
     * v2b_m3_cycle_now() reads return free-running cycle counts. */
    v2b_m3_cycle_init_host();
#else
    uart_puts("[TB] v2b_arm_fashion14_trace start - 10 Fashion 14x14 samples via AXI-Lite\n");
#endif
    uart_puts("[TB] V2B_SOC_BASE=");
    uart_put_hex32(V2B_SOC_BASE);
    uart_putc('\n');

    if (!mmio_self_test()) {
        uart_puts("[FATAL] MMIO round-trip CFG1 failed\n");
        uart_puts("ARM_FPGA_DEMO_SCHEDULER_FASHION10_FAIL\n");
        return -1;
    }
    uart_puts("[OK] MMIO round-trip CFG1\n");

    for (uint32_t i = 0; i < GOLDEN_NUM_SAMPLES; i++) {
        pass += run_sample(&golden_fashion10[i], i) ? 1 : 0;
    }

    if (pass == (int)GOLDEN_NUM_SAMPLES) {
        uart_puts("ARM_FPGA_DEMO_SCHEDULER_FASHION10_PASS\n");
#if defined(V2B_M3_ENABLED)
        /* Sentinel for capture_uart.py / m3_latency_plot.py to detect end
         * of board run cleanly (10 M3_CYCLES lines + this trailer). */
        uart_puts("M3_BOARD_RUN_END config=" V2B_M3_CONFIG_NAME " host=" V2B_M3_HOST_NAME "\n");
#endif
    } else {
        uart_puts("ARM_FPGA_DEMO_SCHEDULER_FASHION10_FAIL passes=");
        uart_put_dec((uint32_t)pass);
        uart_puts("/10\n");
    }

    for (;;) { __asm__ volatile("wfi"); }
    return 0;
}
