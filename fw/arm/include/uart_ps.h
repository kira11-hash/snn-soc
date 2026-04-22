/* fw/arm/include/uart_ps.h — declarations for polling PS-UART Tx driver. */
#ifndef V2B_ARM_UART_PS_H
#define V2B_ARM_UART_PS_H

#include <stdint.h>

void uart_init(void);
void uart_putc(char c);
void uart_puts(const char *s);
void uart_put_hex32(uint32_t v);
void uart_put_dec(int32_t v);

#endif /* V2B_ARM_UART_PS_H */
