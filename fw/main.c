#include "include/soc_regs.h"
#include "include/uart_printf.h"

#include <stdint.h>

static uint32_t input_words[DMA_LEN_VALUE];

int main(void) {
    APP_SIGN_ADDR = APP_SIGN_VALUE;

    REG_TIMESTEPS = TIMESTEPS_VALUE;
    REG_THRESHOLD = THRESHOLD_VALUE;

    uart_init(UART_BAUD_DIV);
    uart_printf("APP start\n");

    for (uint32_t f = 0; f < TIMESTEPS_VALUE; ++f) {
        for (uint32_t i = 0; i < PIXEL_BITS_VALUE; ++i) {
            uint32_t idx = (f * PIXEL_BITS_VALUE * 2u) + (i * 2u);
            input_words[idx + 0u] = 0x000000FFu >> i;
            input_words[idx + 1u] = 0x00000000u;
        }
    }

    DMA_SRC_ADDR  = (uint32_t)(uintptr_t)&input_words[0];
    DMA_LEN_WORDS = DMA_LEN_VALUE;
    DMA_CTRL      = DMA_CTRL_START_MASK;

    while ((DMA_CTRL & DMA_CTRL_DONE_MASK) == 0u) {
    }
    DMA_CTRL = DMA_CTRL_DONE_MASK;

    CIM_CTRL = CIM_CTRL_START_MASK;
    while ((CIM_CTRL & CIM_CTRL_DONE_MASK) == 0u) {
    }

    uint32_t count = REG_OUT_COUNT;
    APP_RESULT_ADDR = count;

    uint32_t hist[10] = {0};
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t id = REG_OUT_DATA & 0xFu;
        if (id < 10u) {
            hist[id]++;
        }
    }

    uint32_t best = 0;
    for (uint32_t d = 1; d < 10u; ++d) {
        if (hist[d] > hist[best]) {
            best = d;
        }
    }

    uart_printf("APP inference done count=%u\n", count);
    uart_printf("Predicted digit: %u\n", best);
    for (uint32_t d = 0; d < 10u; ++d) {
        uart_printf("  neuron[%u]=%u\n", d, hist[d]);
    }
    uart_wait_idle();
    APP_DONE_ADDR = APP_DONE_VALUE;

    while (1) {
    }
}
