/*
 * fw/arm/src/uart_ps.c — minimal polling PS-UART Tx driver for ZCU102.
 *
 * Zynq UltraScale+ PS UART Cadence IP register map (excerpt; see UG1085 Ch 21):
 *   0x00 Control Register       — bit 2 TX enable, bit 4 RX enable
 *   0x04 Mode Register          — 8-bit, 1 stop, no parity encoded as 0x00000020
 *   0x18 Baud Rate Generator    — BRGR (divisor)
 *   0x2C Channel Status         — bit 3 TX empty, bit 4 TX full
 *   0x30 Transmit and Receive   — write = TX data
 *   0x34 Baud Rate Divider      — BAUDDIV (CD + BDIV)
 *
 * Strategy: re-init the UART with a known baud (platform.h gives
 * UART_REF_CLK_HZ and UART_BAUD) so we don't depend on bootloader state.
 *
 * Simplification: this Phase B driver only does Tx polling (no RX, no
 * interrupts, no FIFO threshold management). Real production code would
 * use Vitis BSP's Xuartps driver.
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
    /* Disable + reset Tx/Rx */
    UART_CR(base) = CR_TXDIS | CR_RXDIS | CR_TXRST | CR_RXRST;

    /* 8-bit, 1 stop, no parity, normal mode; clock_sel=0 (uart_ref_clk/1).
     * MR layout: [8] stop-bits=0 (1 stop), [5:3] parity=100 (no parity),
     * [2:1] chrl=00 (8-bit), [0] clk_sel=0 (no /8 prescale). */
    UART_MR(base) = 0x00000020u;  /* par=no, 8-bit, 1 stop */

    /* Compute BAUD: baud = ref_clk / (BRGR * (BAUDDIV + 1))
     * With ref_clk=100 MHz and baud=115200, pick BAUDDIV=6 → BRGR=124.
     * (100e6 / (124 * 7) ≈ 115207 → 0.006% error). */
    UART_BRGR(base) = 124u;
    UART_BDIV(base) = 6u;

    /* Enable Tx/Rx */
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
    /* Spin until Tx FIFO has room */
    uint32_t guard = 0u;
    while ((UART_CSR(base) & CSR_TFULL) && (guard < UART_TX_TIMEOUT)) {
        guard++;
    }
    if (guard < UART_TX_TIMEOUT) {
        UART_FIFO(base) = (uint32_t)(uint8_t)c;
    }
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

/* tiny hex-print helper for debug (no printf dependency) */
void uart_put_hex32(uint32_t v)
{
    static const char hex[] = "0123456789abcdef";
    uart_putc('0'); uart_putc('x');
    for (int i = 7; i >= 0; i--) {
        uart_putc(hex[(v >> (i * 4)) & 0xFu]);
    }
}

void uart_put_dec(int32_t v)
{
    char buf[12];
    int i = 0;
    uint32_t uv;
    if (v < 0) { uart_putc('-'); uv = (uint32_t)(-v); }
    else       { uv = (uint32_t)v; }
    if (uv == 0) { uart_putc('0'); return; }
    while (uv && i < (int)sizeof(buf)) { buf[i++] = (char)('0' + (uv % 10u)); uv /= 10u; }
    while (i-- > 0) uart_putc(buf[i]);
}
