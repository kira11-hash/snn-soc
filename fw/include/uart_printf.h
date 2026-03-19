#ifndef UART_PRINTF_H
#define UART_PRINTF_H

#include <stdint.h>

void uart_init(uint32_t baud_div);
void uart_wait_idle(void);
void uart_putc(char c);
void uart_puts(const char *s);
void uart_put_hex8(uint8_t value);
void uart_put_hex32(uint32_t value);
void uart_put_u32(uint32_t value);
void uart_printf(const char *fmt, ...);

#endif
