/*
 * fw/arm/src/uart_ps.c — ZCU102 PS UART 的极简 Tx 轮询驱动。
 *
 * Zynq UltraScale+ PS UART（Cadence IP）寄存器布局（节选，详见 UG1085 第 21 章）：
 *   0x00 控制寄存器 (CR)   — bit 2 RX 使能，bit 4 TX 使能
 *   0x04 模式寄存器 (MR)   — 8-bit / 1 stop / no parity 编码为 0x00000020
 *   0x18 波特率发生器 (BRGR) — 分频值
 *   0x2C 通道状态 (CSR)    — bit 3 TX FIFO 空，bit 4 TX FIFO 满
 *   0x30 收发数据寄存器     — 写 = 发送数据
 *   0x34 波特率分频器 (BDIV) — CD + BDIV 配合 BRGR 决定最终波特率
 *
 * 设计取舍：每次启动都重新 init UART（platform.h 给定 UART_REF_CLK_HZ + UART_BAUD），
 *           不依赖 bootloader / FSBL 是否已经把 UART 配好。
 *
 * 简化项：本 Phase B 驱动仅做 Tx 轮询（无 RX / 中断 / FIFO 阈值管理）。生产路径
 *         应当切到 Vitis BSP 的 Xuartps 驱动；当前这版只是为了 first-smoke 上板抓
 *         PASS marker，能用就够。
 */
#include <stdint.h>
#include "platform.h"

#ifndef UART_MIRROR_BASE
#define UART_MIRROR_BASE UART_BASE
#endif

#define UART_REG(base, off) (*(volatile uint32_t *)((uintptr_t)(base) + (uintptr_t)(off)))
#define UART_CR(base)       UART_REG((base), 0x00u)
#define UART_MR(base)       UART_REG((base), 0x04u)
#define UART_BRGR(base)     UART_REG((base), 0x18u)
#define UART_CSR(base)      UART_REG((base), 0x2Cu)
#define UART_FIFO(base)     UART_REG((base), 0x30u)
#define UART_BDIV(base)     UART_REG((base), 0x34u)

#define CR_STOPBRK (1u << 8)
#define CR_STARTBRK (1u << 7)
#define CR_TXDIS   (1u << 5)
#define CR_TXEN    (1u << 4)
#define CR_RXDIS   (1u << 3)
#define CR_RXEN    (1u << 2)
#define CR_TXRST   (1u << 1)
#define CR_RXRST   (1u << 0)

#define CSR_TEMPTY (1u << 3)  /* 1 = TxFIFO empty */
#define CSR_TFULL  (1u << 4)  /* 1 = TxFIFO full */

#define UART_TX_TIMEOUT 1000000u

static void uart_init_one(uintptr_t base)
{
    /* 1) 禁用 + 复位 Tx/Rx，把 UART 拉回干净状态 */
    UART_CR(base) = CR_TXDIS | CR_RXDIS | CR_TXRST | CR_RXRST;

    /* 2) 模式寄存器：8-bit 数据 / 1 stop / 无校验 / clock_sel=0 (用 uart_ref_clk/1)
     *    MR 布局：[8] stop-bits=0（1 stop），[5:3] parity=100（无校验），
     *           [2:1] chrl=00（8-bit），[0] clk_sel=0（不走 /8 prescale） */
    UART_MR(base) = 0x00000020u;  /* 无校验 + 8-bit + 1 stop */

    /* 3) 波特率：baud = ref_clk / (BRGR * (BAUDDIV + 1))
     *    ZCU102 的 PS UART ref clk 默认 100 MHz；目标 115200。
     *    取 BAUDDIV=6, BRGR=124 → 100e6 / (124 * 7) ≈ 115207，误差 0.006% */
    UART_BRGR(base) = 124u;
    UART_BDIV(base) = 6u;

    /* 4) 重新使能 Tx/Rx */
    UART_CR(base) = CR_TXEN | CR_RXEN;
}

void uart_init(void)
{
    uart_init_one(UART_BASE);
#if UART_MIRROR_BASE != UART_BASE
    uart_init_one(UART_MIRROR_BASE);
#endif
}

static void uart_putc_one(uintptr_t base, char c)
{
    /* 自旋等到 Tx FIFO 有空位；guard 限制最多自旋 1M 次防止 UART 异常时永久挂死 */
    uint32_t guard = 0u;
    while ((UART_CSR(base) & CSR_TFULL) && (guard < UART_TX_TIMEOUT)) {
        guard++;
    }
    if (guard < UART_TX_TIMEOUT) {
        UART_FIFO(base) = (uint32_t)(uint8_t)c;
    }
    /* guard == UART_TX_TIMEOUT 时静默丢弃此字符——UART 可能没初始化，硬卡死还不
     * 如丢字符让上层 firmware 继续跑。 */
}

void uart_putc(char c)
{
    uart_putc_one(UART_BASE, c);
#if UART_MIRROR_BASE != UART_BASE
    uart_putc_one(UART_MIRROR_BASE, c);
#endif
}

void uart_puts(const char *s)
{
    while (*s) {
        if (*s == '\n') uart_putc('\r');
        uart_putc(*s++);
    }
}

/* 极简 hex-print 工具（不依赖 printf，方便 standalone build） */
void uart_put_hex32(uint32_t v)
{
    static const char hex[] = "0123456789abcdef";
    uart_putc('0'); uart_putc('x');
    for (int i = 7; i >= 0; i--) {
        uart_putc(hex[(v >> (i * 4)) & 0xFu]);
    }
}

/* G2 fix（2026-05-02）：参数从 int32_t 改成 uint32_t，与 e203 分支对齐。
 * 旧实现里的负数分支保留意义不大（所有调用方传的都是 size/index/count），
 * 改为 uint32_t 后语义干净；32-bit ABI 下 W0 寄存器传参方式不变，板上行为不变。 */
void uart_put_dec(uint32_t v)
{
    char buf[12];
    int i = 0;
    uint32_t uv = v;
    if (uv == 0) { uart_putc('0'); return; }
    while (uv && i < (int)sizeof(buf)) { buf[i++] = (char)('0' + (uv % 10u)); uv /= 10u; }
    while (i-- > 0) uart_putc(buf[i]);
}
