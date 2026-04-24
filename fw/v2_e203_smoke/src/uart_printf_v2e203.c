/*
 * fw/v2_e203_smoke/src/uart_printf_v2e203.c
 *
 * Tiny UART TX helpers for V2E203 smoke / encoder firmware.
 * Only depends on `soc_regs_v2_e203.h` — does NOT include V1 `fw/include/soc_regs.h`.
 */

#include <stdint.h>
#include "soc_regs_v2_e203.h"

void uart_init(void)
{
    UART_CTRL = UART_BAUD_DIV;
}

static void uart_tx_byte(uint8_t b)
{
    while (UART_STATUS & UART_STATUS_TX_BUSY) { /* spin */ }
    UART_TXDATA = (uint32_t)b;
}

void uart_putc(char c)
{
    uart_tx_byte((uint8_t)c);
}

void uart_puts(const char *s)
{
    while (*s) {
        if (*s == '\n') uart_tx_byte('\r');
        uart_tx_byte((uint8_t)*s);
        s++;
    }
}

static const char HEX[] = "0123456789ABCDEF";

void uart_put_hex8(uint8_t v)
{
    uart_tx_byte((uint8_t)HEX[(v >> 4) & 0xF]);
    uart_tx_byte((uint8_t)HEX[v & 0xF]);
}

void uart_put_hex32(uint32_t v)
{
    uart_puts("0x");
    for (int i = 7; i >= 0; i--) {
        uart_tx_byte((uint8_t)HEX[(v >> (i * 4)) & 0xF]);
    }
}

void uart_put_dec(uint32_t v)
{
    char buf[12];
    int n = 0;
    if (v == 0) {
        uart_tx_byte('0');
        return;
    }
    while (v && n < 11) {
        buf[n++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (n--) uart_tx_byte((uint8_t)buf[n]);
}
