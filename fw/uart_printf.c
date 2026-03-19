#include "include/soc_regs.h"
#include "include/uart_printf.h"

#include <stdarg.h>
#include <stdint.h>

static void uart_put_hex_nibble(uint8_t nibble) {
    nibble &= 0xFu;
    uart_putc((nibble < 10u) ? (char)('0' + nibble) : (char)('a' + (nibble - 10u)));
}

void uart_init(uint32_t baud_div) {
    UART_CTRL = baud_div;
}

void uart_wait_idle(void) {
    while ((UART_STATUS & 0x1u) != 0u) {
    }
}

void uart_putc(char c) {
    uart_wait_idle();
    UART_TXDATA = (uint32_t)(uint8_t)c;
}

void uart_puts(const char *s) {
    while (*s != '\0') {
        uart_putc(*s++);
    }
}

void uart_put_hex8(uint8_t value) {
    uart_put_hex_nibble((uint8_t)(value >> 4));
    uart_put_hex_nibble(value);
}

void uart_put_hex32(uint32_t value) {
    for (int shift = 28; shift >= 0; shift -= 4) {
        uart_put_hex_nibble((uint8_t)(value >> shift));
    }
}

void uart_put_u32(uint32_t value) {
    char buf[10];
    int idx = 0;

    if (value == 0u) {
        uart_putc('0');
        return;
    }

    while (value != 0u) {
        buf[idx++] = (char)('0' + (value % 10u));
        value /= 10u;
    }

    while (idx > 0) {
        uart_putc(buf[--idx]);
    }
}

void uart_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);

    while (*fmt != '\0') {
        if (*fmt != '%') {
            uart_putc(*fmt++);
            continue;
        }

        fmt++;
        switch (*fmt) {
            case 'c':
                uart_putc((char)va_arg(ap, int));
                break;
            case 's':
                uart_puts(va_arg(ap, const char *));
                break;
            case 'x':
                uart_put_hex32(va_arg(ap, uint32_t));
                break;
            case 'u':
                uart_put_u32(va_arg(ap, uint32_t));
                break;
            case '%':
                uart_putc('%');
                break;
            default:
                uart_putc('?');
                break;
        }
        fmt++;
    }

    va_end(ap);
}
