#include "include/soc_regs.h"
#include "include/uart_printf.h"

#include <stdint.h>

#define JTAG_RESCUE_DATA_ADDR  ((volatile uint32_t *)DATA_SRAM_BASE)
#define JTAG_RESCUE_DATA_MAGIC 0x4A544147u /* 'JTAG' */

int main(void) {
    uint32_t value = *JTAG_RESCUE_DATA_ADDR;

    uart_init(UART_BAUD_DIV);
    if (value == JTAG_RESCUE_DATA_MAGIC) {
        uart_puts("JTAG RESCUE OK\n");
    } else {
        uart_puts("JTAG RESCUE BAD\n");
        uart_put_hex32(value);
        uart_putc('\n');
    }
    uart_wait_idle();

    while (1) {
    }
}
