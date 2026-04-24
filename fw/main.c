#include "include/soc_regs.h"
#include "include/uart_printf.h"

#include <stdint.h>

// ---------------------------------------------------------------------------
// PROG_* register aliases (not in soc_regs.h; mirror silicon_bringup.c)
// ---------------------------------------------------------------------------
#define PROG_CTRL   (*(volatile uint32_t *)(REG_BANK_BASE + 0x38u))
#define PROG_ROW    (*(volatile uint32_t *)(REG_BANK_BASE + 0x3Cu))
#define PROG_COL    (*(volatile uint32_t *)(REG_BANK_BASE + 0x40u))
#define PROG_STATUS (*(volatile uint32_t *)(REG_BANK_BASE + 0x44u))

#define PROG_CTRL_START_MASK      (1u << 0)
#define PROG_CTRL_ERASE_MASK      (1u << 1)
#define PROG_CTRL_FULL_ARRAY_MASK (1u << 2)

#define PROG_STATUS_BUSY_MASK (1u << 0)
#define PROG_STATUS_PASS_MASK (1u << 1)
#define PROG_STATUS_FAIL_MASK (1u << 2)
#define PROG_STATUS_DONE_MASK (1u << 7)

// Long enough to cover one 1 ms erase pulse @ 50 MHz plus generous slack.
#define BOOT_ERASE_POLL_TIMEOUT 0x02000000u
// Short window to check whether the programming FSM is instantiated at all.
// ENABLE_PROGRAM_MODE=0 builds tie PROG_STATUS to zero, so BUSY never rises.
#define BOOT_ERASE_PROBE_CYCLES 256u

static uint32_t input_words[DMA_LEN_VALUE];

// ---------------------------------------------------------------------------
// Boot-time full-array RRAM erase.
// Device team confirmation (2026-04-24): RRAM cells after tape-out are not
// guaranteed to start in HRS, so the production boot flow must run a
// full-array erase before any inference or weight programming that depends on
// the analog array.  Path in cim_program_ctrl: SETUP → PULSE → PULSE_HOLD
// (1 ms @ 50 MHz erase pulse) → PASS → DONE (full-array erase skips verify).
// BYPASS_HANDSHAKE=0 so the real analog die receives the erase pulse.
//
// Return codes:
//   1u → FSM reported PASS
//   2u → programming FSM not instantiated (ENABLE_PROGRAM_MODE=0); skipped
//   0u → FAIL or timeout
// ---------------------------------------------------------------------------
static uint32_t boot_full_array_erase(void) {
    PROG_ROW  = 0u;
    PROG_COL  = 0u;
    PROG_CTRL = PROG_CTRL_ERASE_MASK
              | PROG_CTRL_FULL_ARRAY_MASK
              | PROG_CTRL_START_MASK;

    uint32_t fsm_present = 0u;
    for (uint32_t i = 0u; i < BOOT_ERASE_PROBE_CYCLES; ++i) {
        if (PROG_STATUS & PROG_STATUS_BUSY_MASK) {
            fsm_present = 1u;
            break;
        }
    }
    if (!fsm_present) {
        return 2u;
    }

    for (uint32_t cnt = 0u; cnt < BOOT_ERASE_POLL_TIMEOUT; ++cnt) {
        uint32_t s = PROG_STATUS;
        if (s & PROG_STATUS_DONE_MASK) {
            PROG_STATUS = PROG_STATUS_DONE_MASK;   // W1C
            if ((s & PROG_STATUS_FAIL_MASK) || !(s & PROG_STATUS_PASS_MASK)) {
                return 0u;
            }
            return 1u;
        }
    }
    return 0u;
}

int main(void) {
    APP_SIGN_ADDR = APP_SIGN_VALUE;

    uart_init(UART_BAUD_DIV);
    uart_printf("APP start\n");

    uart_printf("APP erase begin\n");
    uint32_t erase_r = boot_full_array_erase();
    if (erase_r == 1u) {
        uart_printf("APP erase DONE\n");
    } else if (erase_r == 2u) {
        uart_printf("APP erase SKIPPED (program FSM disabled)\n");
    } else {
        uart_printf("APP erase FAIL\n");
        while (1) { }
    }

    REG_TIMESTEPS = TIMESTEPS_VALUE;
    REG_THRESHOLD = THRESHOLD_VALUE;

    for (uint32_t f = 0; f < TIMESTEPS_VALUE; ++f) {
        for (uint32_t i = 0; i < PIXEL_BITS_VALUE; ++i) {
            uint32_t idx = (f * PIXEL_BITS_VALUE * 2u) + (i * 2u);
            input_words[idx + 0u] = 0x000000FFu >> i;
            input_words[idx + 1u] = 0x00000000u;
        }
    }

    DMA_SRC_ADDR  = (uint32_t)(uintptr_t)&input_words[0];
    DMA_LEN_WORDS = DMA_LEN_VALUE;
    DMA_DST_SEL   = DMA_DST_INPUT_FIFO;
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
