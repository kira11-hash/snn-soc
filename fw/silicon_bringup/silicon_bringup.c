// fw/silicon_bringup/silicon_bringup.c
// Post-silicon digital-die self-test firmware.
//
// Purpose: After the digital die comes back from tape-out (optionally WITHOUT
//          a working analog die attached), this firmware exercises every
//          digital RTL path that can be covered in isolation:
//            * E203 boot + bus/MMIO
//            * UART TX
//            * reg_bank register decode
//            * DMA → input FIFO
//            * cim_array_ctrl / adc_ctrl FSM sequencing (with test_mode MUX)
//            * LIF accumulator + output FIFO
//            * cim_program_ctrl FSM (with BYPASS_HANDSHAKE)
//
// Success criterion: "SILICON_BRINGUP_DIGITAL_PASS" on UART.
// Failure paths: specific "SILICON_BRINGUP_DIGITAL_FAIL_<stage>" tags for
// triage without a debugger.

#include "../include/soc_regs.h"
#include "../include/uart_printf.h"
#include <stdint.h>

// PROG_* register aliases moved to soc_regs.h (audit-pass4 M-2).

// audit-pass4 M-1: build id is injected by build_silicon_bringup.sh so the
// emitted .hex stays byte-reproducible by default. Set SOURCE_DATE_EPOCH in
// the env (e.g. to the git commit ctime) to embed a real date instead.
#ifndef SILICON_BRINGUP_BUILD_ID
#define SILICON_BRINGUP_BUILD_ID "frozen"
#endif

// ---------------------------------------------------------------------------
// Self-test parameters
// ---------------------------------------------------------------------------
#define BRINGUP_TEST_POS   100u   // ADC channel 0..9 fake value
#define BRINGUP_TEST_NEG     0u   // ADC channel 10..19 fake value
// diff[k] = pos - neg = 100 (signed 9-bit)
#define BRINGUP_DIFF_VAL   100

// Same LIF parameters as production inference
// (THRESHOLD_VALUE=2550, TIMESTEPS_VALUE=10 come from soc_regs.h)

// Poll bound for FPGA and slow-corner silicon bring-up.  Successful paths
// return quickly; the larger bound avoids false timeout when the clock is
// intentionally slowed for first power-on.
#define POLL_TIMEOUT       0x02000000u

// Input buffer (all-ones pattern; content irrelevant under test_mode because
// bl_data is replaced by cim_test_data_pos/neg, but FSM still needs WL input
// to advance past each bit-plane).
static uint32_t input_buf[DMA_LEN_VALUE];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static uint32_t poll_bit(volatile uint32_t *reg, uint32_t mask, uint32_t want_set) {
    uint32_t cnt = 0u;
    while (cnt < POLL_TIMEOUT) {
        uint32_t v = *reg;
        if (want_set ? ((v & mask) != 0u) : ((v & mask) == 0u)) {
            return 1u;
        }
        ++cnt;
    }
    return 0u; // timeout
}

static uint32_t wait_cim_done_bound(void) {
    return poll_bit(&CIM_CTRL, CIM_CTRL_DONE_MASK, 1u);
}

static uint32_t wait_prog_done_bound(void) {
    return poll_bit(&PROG_STATUS, PROG_STATUS_DONE_MASK, 1u);
}

/*
 * CONCERN FW-C4 fix（2026-05-02 audit）：进 wfi 之前必须 uart_wait_idle，
 * 否则 SILICON_BRINGUP_DIGITAL_PASS 末尾的 '\n' 在 TX shift register 还在
 * 移最后一位 bit 时 CPU 进入 wfi，可能让外部抓 UART 的脚本（pyserial 等）
 * 在收到换行立即关 port，丢掉最后 1 个字节。boot_rom 已用同样套路防御
 * （fw/boot_rom/boot_rom_main.c:62-66、120）。
 */
static void hang(void) {
    uart_wait_idle();
    for (;;) {
        __asm__ volatile ("wfi");
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(void) {
    uart_init(UART_BAUD_DIV);
    uart_printf("\nSILICON_BRINGUP_START v1 build=%s\n", SILICON_BRINGUP_BUILD_ID);

    // --------------------------------------------------------------------
    // Stage A — Digital inference datapath via REG_CIM_TEST (test_mode=1)
    // Bypasses analog CIM + ADC; exercises every digital stage downstream.
    // --------------------------------------------------------------------
    uart_printf("[STAGE_A] inference with test_mode=1, pos=%u, neg=%u\n",
                BRINGUP_TEST_POS, BRINGUP_TEST_NEG);

    // Reset membrane potentials before test
    CIM_CTRL = CIM_CTRL_SOFT_RESET_MASK;
    REG_RESET_MODE = 0u; // always force soft-reset semantics for the SW golden

    REG_TIMESTEPS = TIMESTEPS_VALUE;
    REG_THRESHOLD = THRESHOLD_VALUE;

    // Enable test_mode + set pos/neg
    //   bit[0]      = test_mode
    //   bit[15:8]   = test_data_pos
    //   bit[23:16]  = test_data_neg
    REG_CIM_TEST = 0x00000001u
                 | ((uint32_t)BRINGUP_TEST_POS << 8)
                 | ((uint32_t)BRINGUP_TEST_NEG << 16);

    // Fill input buffer (content doesn't matter for bl_data under test_mode,
    // but cim_array_ctrl still pops one frame per bit-plane)
    for (uint32_t i = 0u; i < DMA_LEN_VALUE; ++i) {
        input_buf[i] = 0xFFFFFFFFu;
    }

    // Pre-compute software expected spike counts
    int32_t  membrane[10];
    uint32_t expected[10];
    for (int k = 0; k < 10; ++k) { membrane[k] = 0; expected[k] = 0u; }
    for (uint32_t t = 0u; t < TIMESTEPS_VALUE; ++t) {
        for (int shift = 7; shift >= 0; --shift) {
            int32_t addend = (int32_t)BRINGUP_DIFF_VAL << shift;
            for (int k = 0; k < 10; ++k) {
                membrane[k] += addend;
                if (membrane[k] >= (int32_t)THRESHOLD_VALUE) {
                    expected[k]++;
                    membrane[k] -= (int32_t)THRESHOLD_VALUE;
                }
            }
        }
    }

    // DMA input_buf → INPUT_FIFO
    DMA_SRC_ADDR  = (uint32_t)(uintptr_t)&input_buf[0];
    DMA_LEN_WORDS = DMA_LEN_VALUE;
    DMA_DST_SEL   = DMA_DST_INPUT_FIFO;
    DMA_CTRL      = DMA_CTRL_START_MASK;
    if (!poll_bit(&DMA_CTRL, DMA_CTRL_DONE_MASK, 1u)) {
        uart_printf("SILICON_BRINGUP_DIGITAL_FAIL_DMA\n");
        hang();
    }
    DMA_CTRL = DMA_CTRL_DONE_MASK;

    CIM_CTRL = CIM_CTRL_START_MASK;
    if (!wait_cim_done_bound()) {
        uart_printf("SILICON_BRINGUP_DIGITAL_FAIL_CIM_TIMEOUT\n");
        hang();
    }

    uint32_t out_count = REG_OUT_COUNT;
    uint32_t hist[10];
    for (int k = 0; k < 10; ++k) { hist[k] = 0u; }
    for (uint32_t i = 0u; i < out_count; ++i) {
        uint32_t id = REG_OUT_DATA & 0xFu;
        if (id < 10u) hist[id]++;
    }

    uint32_t infer_mismatch = 0u;
    for (uint32_t k = 0u; k < 10u; ++k) {
        uart_printf("[STAGE_A] neuron[%u] hw=%u sw=%u %s\n",
                    k, hist[k], expected[k],
                    (hist[k] == expected[k]) ? "OK" : "MISMATCH");
        if (hist[k] != expected[k]) infer_mismatch++;
    }
    uart_printf("[STAGE_A] total_spikes=%u mismatch=%u\n", out_count, infer_mismatch);
    if (infer_mismatch != 0u) {
        uart_printf("SILICON_BRINGUP_DIGITAL_FAIL_INFER\n");
        hang();
    }

    // Disable test_mode for clean follow-up
    REG_CIM_TEST = 0u;

    // --------------------------------------------------------------------
    // Stage B — Programming FSM via PROG_CTRL.BYPASS_HANDSHAKE=1
    // Exercises cim_program_ctrl state transitions WITHOUT a responding macro.
    // Verify PASS path for both ERASE and WRITE ops.
    // --------------------------------------------------------------------
    uart_printf("[STAGE_B] programming FSM with bypass_handshake=1\n");

    // B0: runtime 0->1->0 bypass readback toggle.  This is intentionally
    // performed while the FSM is idle; in-flight policy remains "do not touch
    // config fields while busy".
    PROG_CTRL = PROG_CTRL_BYPASS_MASK;
    if ((PROG_CTRL & PROG_CTRL_BYPASS_MASK) == 0u) {
        uart_printf("SILICON_BRINGUP_DIGITAL_FAIL_PROG_BYPASS_SET\n");
        hang();
    }
    PROG_CTRL = 0u;
    if ((PROG_CTRL & PROG_CTRL_BYPASS_MASK) != 0u) {
        uart_printf("SILICON_BRINGUP_DIGITAL_FAIL_PROG_BYPASS_CLR\n");
        hang();
    }
    uart_printf("[STAGE_B] bypass toggle readback PASS\n");

    // B1: full-array erase path.  This intentionally covers the special
    // "skip verify" path in cim_program_ctrl; B2 below covers bypassed erase
    // readback/verify.
    PROG_ROW  = 0u;
    PROG_COL  = 0u;
    PROG_CTRL = PROG_CTRL_BYPASS_MASK
              | PROG_CTRL_ERASE_MASK
              | PROG_CTRL_FULL_ARRAY_MASK
              | PROG_CTRL_START_MASK;
    if (!wait_prog_done_bound()) {
        uart_printf("SILICON_BRINGUP_DIGITAL_FAIL_PROG_ERASE_TIMEOUT\n");
        hang();
    }
    {
        uint32_t ps = PROG_STATUS;
        PROG_STATUS = PROG_STATUS_DONE_MASK; // W1C
        uart_printf("[STAGE_B] full_array_erase PROG_STATUS=0x%x\n", ps);
        if ((ps & PROG_STATUS_FAIL_MASK) || !(ps & PROG_STATUS_PASS_MASK)) {
            uart_printf("SILICON_BRINGUP_DIGITAL_FAIL_PROG_ERASE\n");
            hang();
        }
    }

    // B2: single-cell erase @ (row=5, col=3).  Unlike full-array erase, this
    // enters READBACK/RB_WAIT/VERIFY and therefore proves BYPASS_HANDSHAKE
    // supplies a fake done/data pair for erase verify.
    PROG_ROW  = 5u;
    PROG_COL  = 3u;
    PROG_CTRL = PROG_CTRL_BYPASS_MASK
              | PROG_CTRL_ERASE_MASK
              | PROG_CTRL_START_MASK;
    // Deliberately clear the live control register while the erase is in
    // flight.  RTL must have latched BYPASS_HANDSHAKE/op/level at START, so
    // this must not hang RB_WAIT or change the fake readback value.
    PROG_CTRL = 0u;
    if (!wait_prog_done_bound()) {
        uart_printf("SILICON_BRINGUP_DIGITAL_FAIL_PROG_CELL_ERASE_TIMEOUT\n");
        hang();
    }
    {
        uint32_t ps = PROG_STATUS;
        PROG_STATUS = PROG_STATUS_DONE_MASK; // W1C
        uart_printf("[STAGE_B] erase PROG_STATUS=0x%x\n", ps);
        if ((ps & PROG_STATUS_FAIL_MASK) || !(ps & PROG_STATUS_PASS_MASK)) {
            uart_printf("SILICON_BRINGUP_DIGITAL_FAIL_PROG_CELL_ERASE\n");
            hang();
        }
    }

    // B3: single-cell write @ (row=5, col=3), level=4
    PROG_ROW  = 5u;
    PROG_COL  = 3u;
    PROG_CTRL = PROG_CTRL_BYPASS_MASK
              | (4u << PROG_CTRL_LEVEL_SHIFT)
              | PROG_CTRL_START_MASK;
    if (!wait_prog_done_bound()) {
        uart_printf("SILICON_BRINGUP_DIGITAL_FAIL_PROG_WRITE_TIMEOUT\n");
        hang();
    }
    {
        uint32_t ps = PROG_STATUS;
        PROG_STATUS = PROG_STATUS_DONE_MASK; // W1C
        uart_printf("[STAGE_B] write PROG_STATUS=0x%x\n", ps);
        if ((ps & PROG_STATUS_FAIL_MASK) || !(ps & PROG_STATUS_PASS_MASK)) {
            uart_printf("SILICON_BRINGUP_DIGITAL_FAIL_PROG_WRITE\n");
            hang();
        }
    }

    // Turn bypass off again — any subsequent production use should start clean
    PROG_CTRL = 0u;

    // --------------------------------------------------------------------
    // All digital-only stages passed
    // --------------------------------------------------------------------
    uart_printf("SILICON_BRINGUP_DIGITAL_PASS\n");
    hang();
    return 0;
}
