/*
 * fw/arm/src/arm_main.c
 *
 * ZCU102 ARM 端 LeNet-5 CONV 板验入口（v2-arm-fpga-demo-conv 分支）。
 *
 * 流程：
 *   1) 初始化 PS UART0（115200 8N1），打 banner
 *   2) MMIO self-test：往 STAGE_CFG1 写 0xDEADBEEF / 0x12345678 再读回，
 *      验证 PS HPM0_FPD ↔ v2b_axi_wrapper 的 AXI-Lite 通路通畅
 *   3) 按 LENET5_NUM_SAMPLES（=10）逐样本调用 v2b_run_lenet5_demo()
 *      - 每个 sample：input fmap → conv1 → conv2 → fc1(flatten) → fc2 → fc3
 *      - 校验：counts byte-exact 匹配 expected_counts；argmax 匹配 expected_class
 *   4) 所有 sample PASS 后输出 ARM_FPGA_DEMO_LENET5_PASS（板验 PASS marker）
 *
 * Golden 数据：fw/arm/include/golden_lenet5.h + golden_lenet5.c（由 Python
 *              gen_convnet_golden.py + gen_lenet5_header.py 自动生成）。
 *
 * 关键 g_arm_progress_* 进度码（见 v2b_conv_scheduler.c）便于 JTAG 在卡死时
 * 通过 mrd 直接看到 firmware 走到了哪一拍。
 */

#include <stdint.h>
#include "platform.h"
#include "uart_ps.h"
#include "v2b_soc_regs.h"
#include "golden_lenet5.h"
#include "v2b_conv_scheduler.h"

static int32_t counts_buf[10];
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
    int rc = v2b_run_lenet5_demo_trace(
        sample->input_words,
        counts_buf,
        idx
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

    /* 1) UART 初始化 + banner（用 UART_OK 作为 firmware 真的跑起来的最早证据） */
    uart_init();
    uart_puts("\nUART_OK\n");
    uart_puts("[TB] v2b_arm_lenet5 start - 10 LeNet-5 samples via AXI-Lite\n");
    uart_puts("[TB] V2B_SOC_BASE="); uart_put_hex32(V2B_SOC_BASE); uart_putc('\n');

    /* 2) MMIO self-test：验证 PS HPM0_FPD 读写 PL fabric 寄存器无误。
     *    用 STAGE_CFG1（threshold，标准 32-bit R/W）做 round-trip；若这里都失败，
     *    说明 BD 地址映射/PL clock/AXI 桥/wrapper 任何一环坏了，没必要往下跑。 */
    if (!mmio_self_test()) {
        uart_puts("[FATAL] MMIO round-trip CFG1 failed\n");
        uart_puts("ARM_FPGA_DEMO_LENET5_FAIL\n");
        return -1;
    }
    uart_puts("[OK] MMIO round-trip CFG1\n");

    /* 3) 逐 sample 推理 + 字节级 counts 校验 */
    for (uint32_t i = 0; i < LENET5_NUM_SAMPLES; i++) {
        pass += run_sample(&golden_lenet5[i], i) ? 1 : 0;
    }

    /* 4) 全部 PASS 才打 PASS marker；自动化抓 UART 的脚本只看 PASS 字符串 */
    if (pass == (int)LENET5_NUM_SAMPLES) {
        uart_puts("ARM_FPGA_DEMO_LENET5_PASS\n");
    } else {
        uart_puts("ARM_FPGA_DEMO_LENET5_FAIL passes=");
        uart_put_dec((uint32_t)pass);
        uart_puts("/10\n");
    }

    /* 收尾：进 wfi 让 CPU idle，避免 firmware 跑飞重新进入 _start 浪费板上时间 */
    for (;;) { __asm__ volatile("wfi"); }
    return 0;
}
