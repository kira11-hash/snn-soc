/* fw/arm/include/uart_ps.h — declarations for polling PS-UART Tx driver. */
#ifndef V2B_ARM_UART_PS_H
#define V2B_ARM_UART_PS_H

#include <stdint.h>

void uart_init(void);
void uart_putc(char c);
void uart_puts(const char *s);
void uart_put_hex32(uint32_t v);
/* G2 fix（2026-05-02）：统一 uart_put_dec 签名为 uint32_t（语义上是非负计数/索引，
 * 历史上 arm 端用 int32_t、e203 端用 uint32_t 不一致；32-bit ABI 下两种参数传递
 * 相同，所以板上行为不变，只是消除编译时的 implicit conversion warning + 让两条
 * 分支共享 fw/src/v2b_conv_scheduler.c 的 extern 声明保持一致）。 */
void uart_put_dec(uint32_t v);

#endif /* V2B_ARM_UART_PS_H */
