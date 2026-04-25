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
    static const uint32_t pow10[] = {
        1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
        10000u, 1000u, 100u, 10u, 1u
    };
    uint32_t started = 0u;

    if (v == 0) {
        uart_tx_byte('0');
        return;
    }

    for (uint32_t i = 0; i < (sizeof(pow10) / sizeof(pow10[0])); i++) {
        uint8_t digit = 0u;
        while (v >= pow10[i]) {
            v -= pow10[i];
            digit++;
        }
        if (digit != 0u || started) {
            uart_tx_byte((uint8_t)('0' + digit));
            started = 1u;
        }
    }
}
