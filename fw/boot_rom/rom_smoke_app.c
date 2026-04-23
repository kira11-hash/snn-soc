#include "../include/soc_regs.h"
#include "../include/uart_printf.h"

#include <stdint.h>

#ifndef ROM_SMOKE_ADDR
#define ROM_SMOKE_ADDR 0x00001000u
#endif

int main(void) {
    uart_init(UART_BAUD_DIV);
    APP_SIGN_ADDR = APP_SIGN_VALUE;
    uart_puts("ROMAPP start\n");
    APP_RESULT_ADDR = ROM_SMOKE_ADDR;
    APP_DONE_ADDR = APP_DONE_VALUE;
    uart_puts("ROMAPP_PASS\n");
    uart_wait_idle();
    for (;;) {
        __asm__ volatile ("wfi");
    }
    return 0;
}
