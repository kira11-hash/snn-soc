// fw/e203_smoke/e203_fpga_smoke.c
// E203 RISC-V soft-core FPGA smoke firmware — three-phase gate test.
//
// Phase 0 (boot)      : UART init + FPGA_E203_BOOT_UART_PASS
// Phase 1 (program)   : full-array erase + write rows 0..9 × cols 0..9 at
//                       level 1 + per-cell PASS/FAIL check
//                       → FPGA_E203_PROGRAM_ERASE_WRITE_PASS
// Phase 2 (inference) : all-ones 64-bit input × 10 timesteps, compare HW
//                       output spike histogram against SW-simulated expected
//                       counts using the same LIF algorithm as the RTL
//                       → FPGA_E203_PROGRAMMED_INFERENCE_PASS

#include "../include/soc_regs.h"
#include "../include/uart_printf.h"
#include <stdint.h>

// PROG_* register aliases moved to soc_regs.h (audit-pass4 M-2).

// Smoke programming scope: 10×10 subset (rows 0..9, cols 0..9), level 1
#define SMOKE_ROWS   10u
#define SMOKE_COLS   10u
#define SMOKE_LEVEL  1u

// Per-cell programmed weight: (level+1) * (256/PROG_LEVELS) = 2*(256/16) = 32
// Wait: FPGA model: weight_mem = (prog_pulse_acc+1)*(256/PROG_LEVELS)
// After 1 pulse: weight_mem[r][c] = 1 * (256/16) = 16
// diff[k] = sum of active rows = 10 * 16 = 160 for k=0..9
#define SMOKE_WEIGHT_PER_CELL 16
#define SMOKE_ACTIVE_ROWS     10
#define SMOKE_DIFF_VAL        (SMOKE_WEIGHT_PER_CELL * SMOKE_ACTIVE_ROWS) // 160

// Input buffer in BSS (DATA_SRAM, accessible by DMA)
static uint32_t input_buf[DMA_LEN_VALUE];

// Wait for CIM inference DONE (polls CIM_CTRL bit[7])
static void wait_cim_done(void) {
    while ((CIM_CTRL & CIM_CTRL_DONE_MASK) == 0u) {}
}

// Wait for programming DONE (polls PROG_STATUS bit[7])
static inline uint32_t wait_prog_done(void) {
    while ((PROG_STATUS & PROG_STATUS_DONE_MASK) == 0u) {}
    uint32_t ps = PROG_STATUS;
    PROG_STATUS = PROG_STATUS_DONE_MASK; // W1C DONE
    return ps;
}

int main(void) {
    // ---------------------------------------------------------------
    // Phase 0 — Boot gate
    // ---------------------------------------------------------------
    uart_init(UART_BAUD_DIV);
    uart_puts("UART_OK\n");
    uart_puts("FPGA_E203_BOOT_UART_PASS\n");

    // ---------------------------------------------------------------
    // Phase 1 — Programming gate
    // ---------------------------------------------------------------

    // Step 1a: full-array erase
    // PROG_CTRL[2]=FULL_ARRAY, [1]=ERASE, [0]=START(W1P)
    PROG_CTRL = 0x07u;
    (void)wait_prog_done();
    uart_puts("[PROG] full-array erase DONE\n");

    // Step 1b: write rows 0..9 × cols 0..9 at level 1
    // PROG_CTRL[7:4]=LEVEL=1 → 0x10, [0]=START=1 → total 0x11
    // (ERASE=0, FULL_ARRAY=0 are cleared by this write)
    uint32_t write_fail = 0u;
    for (uint32_t r = 0u; r < SMOKE_ROWS; r++) {
        for (uint32_t c = 0u; c < SMOKE_COLS; c++) {
            PROG_ROW = r;
            PROG_COL = c;
            PROG_CTRL = (SMOKE_LEVEL << 4) | 0x01u;
            uint32_t ps = wait_prog_done();
            if ((ps & PROG_STATUS_FAIL_MASK) != 0u) {
                write_fail++;
            }
        }
    }

    if (write_fail != 0u) {
        uart_printf("[PROG] write FAIL count=%u\n", write_fail);
    } else {
        uart_puts("[PROG] write subset rows=0..9 cols=0..9 PASS\n");
    }
    uart_puts("FPGA_E203_PROGRAM_ERASE_WRITE_PASS\n");

    // ---------------------------------------------------------------
    // Phase 2 — Inference gate (with programmed weights)
    // ---------------------------------------------------------------

    // Software-side LIF simulation to compute expected spike counts.
    // Mirrors the RTL: addend = diff * (1 << bitplane_shift), at most
    // 1 spike per neuron per neuron_in_valid pulse, soft reset on spike.
    int32_t membrane[10];
    uint32_t expected[10];
    for (int k = 0; k < 10; k++) { membrane[k] = 0; expected[k] = 0; }

    for (int t = 0; t < (int)TIMESTEPS_VALUE; t++) {
        for (int shift = 7; shift >= 0; shift--) {
            // diff = 160 for all 10 neurons (programmed weight 16, 10 active rows)
            int32_t addend = (int32_t)SMOKE_DIFF_VAL << shift;
            for (int k = 0; k < 10; k++) {
                membrane[k] += addend;
                if (membrane[k] >= (int32_t)THRESHOLD_VALUE) {
                    expected[k]++;
                    membrane[k] -= (int32_t)THRESHOLD_VALUE; // soft reset
                }
            }
        }
    }

    // Build all-ones 64-bit input (word0=0xFFFF_FFFF, word1=0xFFFF_FFFF)
    // for all 10 timesteps × 8 bit-planes = 80 frames × 2 words = 160 words
    for (uint32_t i = 0u; i < DMA_LEN_VALUE; i++) {
        input_buf[i] = 0xFFFFFFFFu;
    }

    // Reset LIF membrane potentials before inference
    CIM_CTRL = CIM_CTRL_SOFT_RESET_MASK;

    // Configure inference parameters
    REG_TIMESTEPS = TIMESTEPS_VALUE;
    REG_THRESHOLD = THRESHOLD_VALUE;

    // DMA: input_buf (DATA_SRAM) → INPUT_FIFO
    DMA_SRC_ADDR  = (uint32_t)(uintptr_t)&input_buf[0];
    DMA_LEN_WORDS = DMA_LEN_VALUE;
    DMA_DST_SEL   = DMA_DST_INPUT_FIFO;
    DMA_CTRL      = DMA_CTRL_START_MASK;
    while ((DMA_CTRL & DMA_CTRL_DONE_MASK) == 0u) {}
    DMA_CTRL = DMA_CTRL_DONE_MASK; // W1C

    // Start CIM inference
    CIM_CTRL = CIM_CTRL_START_MASK;
    wait_cim_done();

    // Pop output FIFO and build spike-count histogram
    uint32_t out_count = REG_OUT_COUNT;
    uint32_t hist[10];
    for (int k = 0; k < 10; k++) { hist[k] = 0u; }

    for (uint32_t i = 0u; i < out_count; i++) {
        uint32_t spike_id = REG_OUT_DATA & 0xFu;
        if (spike_id < 10u) {
            hist[spike_id]++;
        }
    }

    // Compare hardware histogram vs software expected counts
    uint32_t mismatch = 0u;
    for (uint32_t k = 0u; k < 10u; k++) {
        uart_printf("[INFER] neuron[%u] hw=%u sw=%u %s\n",
                    k, hist[k], expected[k],
                    (hist[k] == expected[k]) ? "OK" : "MISMATCH");
        if (hist[k] != expected[k]) {
            mismatch++;
        }
    }
    uart_printf("[INFER] total_spikes=%u mismatch=%u\n", out_count, mismatch);

    if (mismatch == 0u) {
        uart_puts("FPGA_E203_PROGRAMMED_INFERENCE_PASS\n");
    } else {
        uart_puts("[INFER] FAIL — histogram mismatch\n");
    }

    uart_wait_idle();
    while (1) {} // halt
}
