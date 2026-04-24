/*
 * fw/v2_e203_smoke/src/v2_e203_smoke_main.c  (Phase A-6 minimal skeleton)
 *
 * Minimal skeleton: clear linker-symbol buffers, publish BUFFER_PTRs,
 * print UART boot/pass tags, write markers, then infinite spin.
 * Real 10-sample inference is still Phase A-8.
 */

#include <stdint.h>
#include "soc_regs_v2_e203.h"

void uart_init(void);
void uart_puts(const char *s);

int main(void)
{
    uart_init();

    /* NOLOAD buffers have SRAM power-up garbage: clear before BOOT_MARK. */
    for (uint32_t i = 0; i < 10u; i++) {
        __sample_done_flags[i] = 0u;
    }
    for (uint32_t i = 0; i < 100u; i++) {
        __smoke_counts_base[i] = 0u;
    }

    /* Publish runtime BUFFER_PTRs. TB must read these after BOOT_MARK. */
    MARKER_W(BUFFER_PTR_0_ADDR) = SMOKE_COUNTS_BUF_ADDR;
    MARKER_W(BUFFER_PTR_1_ADDR) = SAMPLE_DONE_FLAGS_ADDR;
    MARKER_W(BUFFER_PTR_2_ADDR) = 0u;

    /* BOOT marker */
    MARKER_W(V2E203_BOOT_MARK_ADDR) = V2E203_BOOT_MARK;
    uart_puts("FPGA_V2_E203_BOOT_UART_PASS\n");

    /* Skeleton skips actual inference (Phase A-8 task) */

    /* INFER_DONE marker */
    MARKER_W(V2E203_INFER_DONE_MARK_ADDR) = V2E203_INFER_DONE_MARK;
    uart_puts("FPGA_V2_E203_MULTILAYER_INFER_PASS\n");

    /* Spin */
    for (;;) {
        __asm__ volatile ("nop");
    }
    return 0;
}
