#include "include/soc_regs.h"
#include "include/uart_printf.h"

#include <stdint.h>

// PROG_* register aliases moved to soc_regs.h (audit-pass4 M-2).

// Long enough to cover one 1 ms erase pulse @ 50 MHz plus generous slack.
#define BOOT_ERASE_POLL_TIMEOUT 0x02000000u
#define APP_POLL_TIMEOUT        0x02000000u

static uint32_t input_words[DMA_LEN_VALUE];
static uint32_t boot_erase_last_status;

static uint32_t wait_dma_done_bound(uint32_t *ctrl_out) {
    uint32_t ctrl = 0u;
    for (uint32_t guard = 0u; guard < APP_POLL_TIMEOUT; ++guard) {
        ctrl = DMA_CTRL;
        if ((ctrl & DMA_CTRL_DONE_MASK) != 0u) {
            if (ctrl_out) {
                *ctrl_out = ctrl;
            }
            return 1u;
        }
    }
    if (ctrl_out) {
        *ctrl_out = ctrl;
    }
    return 0u;
}

static uint32_t wait_cim_done_bound(void) {
    for (uint32_t guard = 0u; guard < APP_POLL_TIMEOUT; ++guard) {
        if ((CIM_CTRL & CIM_CTRL_DONE_MASK) != 0u) {
            return 1u;
        }
    }
    return 0u;
}

// ---------------------------------------------------------------------------
// Boot-time full-array RRAM erase.
// Device team confirmation (2026-04-24): RRAM cells after tape-out are not
// guaranteed to start in HRS, so the production boot flow must issue a
// full-array erase before any inference or weight programming that depends on
// the analog array.  Path in cim_program_ctrl: SETUP → PULSE → PULSE_HOLD
// (1 ms @ 50 MHz erase pulse) → PASS → DONE.
//
// Important semantic note:
//   full-array erase is a fire-and-forget controller path in current RTL:
//   it intentionally skips per-cell readback verify.  A successful return
//   therefore means "the programming FSM accepted and completed the 1 ms erase
//   sequence", not "firmware has independently spot-verified array state".
//   BYPASS_HANDSHAKE stays 0 so the real analog die receives the actual pulse.
//
// Return codes:
//   1u → erase sequence completed (controller PASS/DONE)
//   2u → programming FSM not instantiated (ENABLE_PROGRAM_MODE=0); skipped
//   0u → controller timeout or unexpected status
// ---------------------------------------------------------------------------
static uint32_t boot_full_array_erase(void) {
    boot_erase_last_status = 0u;

    // 2026-04-25: deterministically detect whether the programming FSM is
    // present via PROG_STATUS[6] (RO, driven by ENABLE_PROGRAM_MODE).  This
    // replaces the old 256-cycle BUSY probe, which was fragile against future
    // short-pulse ops that might complete before CPU observes BUSY=1.
    uint32_t s_pre = PROG_STATUS;
    boot_erase_last_status = s_pre;
    if ((s_pre & PROG_STATUS_FSM_PRESENT_MASK) == 0u) {
        return 2u;
    }

    PROG_STATUS = PROG_STATUS_DONE_MASK;   // clear any stale DONE before START

    PROG_ROW  = 0u;
    PROG_COL  = 0u;
    // 2026-04-25 read-modify-write: byte0 controls START/ERASE/FULL_ARRAY/BYPASS/
    // LEVEL only.  RETRY_LIMIT (bits[10:8]) MUST stay at the reset default (4)
    // for any later non-bypass write/verify ops.  The previous full-word write
    // silently zeroed RETRY_LIMIT.
    uint32_t pc = PROG_CTRL;
    PROG_CTRL = (pc & ~PROG_CTRL_LOW_MASK)
              | PROG_CTRL_ERASE_MASK
              | PROG_CTRL_FULL_ARRAY_MASK
              | PROG_CTRL_START_MASK;

    for (uint32_t cnt = 0u; cnt < BOOT_ERASE_POLL_TIMEOUT; ++cnt) {
        uint32_t s = PROG_STATUS;
        boot_erase_last_status = s;
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
        uart_printf("APP erase SEQ_DONE\n");
    } else if (erase_r == 2u) {
        uart_printf("APP erase SKIPPED (program FSM disabled)\n");
    } else {
        uart_printf("APP erase FAIL status=%x\n", boot_erase_last_status);
        uart_wait_idle();
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

    uint32_t dma_status = 0u;
    if (!wait_dma_done_bound(&dma_status)) {
        uart_printf("APP dma timeout ctrl=%x\n", dma_status);
        uart_wait_idle();
        while (1) { }
    }
    DMA_CTRL = DMA_CTRL_DONE_MASK;

    CIM_CTRL = CIM_CTRL_START_MASK;
    if (!wait_cim_done_bound()) {
        uart_printf("APP cim timeout ctrl=%x\n", CIM_CTRL);
        uart_wait_idle();
        while (1) { }
    }

    uint32_t count = REG_OUT_COUNT;
    APP_RESULT_ADDR = count;

    uint32_t hist[10];
    for (uint32_t d = 0; d < 10u; ++d) hist[d] = 0u;
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
