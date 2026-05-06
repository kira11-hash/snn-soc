/*
 * fw/src/v2b_scheduler.c
 *
 * V2.B Phase C-Milestone-1: resident 14×14 2-stage inference scheduler.
 *
 * This is the firmware reference implementation. It drives the standalone
 * V2.B SoC top (rtl/top/snn_soc_v2b_top.sv) through its register-mapped
 * bus interface to run:
 *   Stage 0: INPUT_SRAM (196 binary pixels × T=64) → STREAM_A (64 spikes × T)
 *   Stage 1: STREAM_A (64 binary WL × T=64)       → STREAM_B (10 spikes × T)
 *
 * Per GPT 2026-04-20 B5-checkpoint verdict (b-lite approach), this
 * code targets the standalone V2B SoC top (verified bit-exact in
 * tb/v2b_soc_top_parity_tb.sv). Future E203+reg_bank integration
 * will swap the register base address but keep this logic intact.
 *
 * The matching Verilog co-sim TB (tb/fw_cosim_resident_14x14_tb.sv)
 * mirrors the task structure of this file 1:1 so simulation can prove
 * the firmware logic bit-exact without compiling C for E203.
 */

#include <stdint.h>
#include "v2b_soc_regs.h"
#include "v2b_trace_hash.h"
#include "v2b_m3_cycles.h"

#ifndef V2B_TRACE_HASH_HOST_NAME
#define V2B_TRACE_HASH_HOST_NAME "?"
#endif

#ifndef V2B_TRACE_HASH_CONFIG_FASHION14
#define V2B_TRACE_HASH_CONFIG_FASHION14 "v2b_fc_fashion14_2L"
#endif

#ifndef V2B_NEGCTRL_STAGE0_THRESHOLD_DELTA
#define V2B_NEGCTRL_STAGE0_THRESHOLD_DELTA 0u
#endif

#ifndef V2B_NEGCTRL_SAMPLE_ID
#define V2B_NEGCTRL_SAMPLE_ID 0xFFFFFFFFu
#endif

#ifndef V2B_NEGCTRL_STAGE0_THRESHOLD_OVERRIDE
#define V2B_NEGCTRL_STAGE0_THRESHOLD_OVERRIDE S0_THRESHOLD
#endif

/* ── Fashion 14×14 resident topology constants (matches Python P4) ── */
#define S0_IN_DIM    196u
#define S0_OUT_DIM    64u
#define S0_THRESHOLD  16u
#define S0_SUM_MAX    2940u   /* 196 × 15 (active_wl) */

#define S1_IN_DIM     64u
#define S1_OUT_DIM    10u
#define S1_THRESHOLD   8u
#define S1_SUM_MAX    960u    /* 64 × 15 */

#define T_COUNT       64u
#define WORDS_PER_ROW  8u     /* 256 bits / 32 */

#ifndef V2B_STAGE_POLL_TIMEOUT
#define V2B_STAGE_POLL_TIMEOUT 2000000u
#endif

#define V2B_STAGE_ERR_TIMEOUT 0xFEu

static uint8_t v2b_wait_stage_done_fresh(uint32_t poll_timeout) {
    uint32_t guard = 0u;
    while (guard < poll_timeout) {
        uint32_t ctrl = V2B_SOC_STAGE_CTRL;
        if ((ctrl & V2B_SOC_STAGE_CTRL_DONE) != 0u) {
            uint8_t err = (uint8_t)V2B_SOC_STAGE_ERR(V2B_SOC_STAGE_STATUS);
            V2B_SOC_STAGE_CTRL = V2B_SOC_STAGE_CTRL_DONE; /* W1C DONE sticky */
            return err;
        }
        guard++;
    }
    return V2B_STAGE_ERR_TIMEOUT;
}

/* ── even_rate Bresenham encoder — MUST match Python
 *    snn_engine_multilayer.encode_pixel_to_spike_stream ── */
void v2b_encode_pixel_even_rate(const uint8_t *pixels, uint32_t in_dim,
                                uint32_t T, uint32_t *stream_out_bits)
{
    /* Static scratch accumulator sized for main 14×14 (in_dim ≤ 256) */
    static int32_t acc[512];
    for (uint32_t i = 0; i < in_dim; i++) acc[i] = 0;

    for (uint32_t t = 0; t < T; t++) {
        uint32_t *row = &stream_out_bits[t * WORDS_PER_ROW];
        for (uint32_t w = 0; w < WORDS_PER_ROW; w++) row[w] = 0u;
        for (uint32_t i = 0; i < in_dim; i++) {
            acc[i] += (int32_t)pixels[i];
            if (acc[i] >= 256) {
                row[i >> 5] |= (1u << (i & 31u));
                acc[i] -= 256;
            }
        }
    }
}

/* ── Primitive (2): push T rows of pre-encoded input stream to input_stream_sram ── */
void v2b_load_input_stream(const uint32_t *stream_bits /* [T][WORDS_PER_ROW] */,
                           uint32_t T)
{
    for (uint32_t t = 0; t < T; t++) {
        const uint32_t *row = &stream_bits[t * WORDS_PER_ROW];
        V2B_SOC_INPUT_SRAM_ADDR = t;
        V2B_SOC_INPUT_SRAM_W0   = row[0];
        V2B_SOC_INPUT_SRAM_W1   = row[1];
        V2B_SOC_INPUT_SRAM_W2   = row[2];
        V2B_SOC_INPUT_SRAM_W3   = row[3];
        V2B_SOC_INPUT_SRAM_W4   = row[4];
        V2B_SOC_INPUT_SRAM_W5   = row[5];
        V2B_SOC_INPUT_SRAM_W6   = row[6];
        V2B_SOC_INPUT_SRAM_W7   = row[7];
        V2B_SOC_INPUT_SRAM_CTRL = 1u;
    }
}

/* ── Primitive (1'-lite): resident weight install (no cim_program_ctrl;
 *     uses behavioral MAC weight memory). In real CIM integration the
 *     behavioral load port is replaced by cim_program_ctrl pulsing. ── */
void v2b_load_mac_weights(const uint8_t *w_pos /* [in_dim][out_dim] 4-bit */,
                          const uint8_t *w_neg /* same shape */,
                          uint32_t in_dim, uint32_t out_dim)
{
    for (uint32_t i = 0; i < in_dim; i++) {
        for (uint32_t j = 0; j < out_dim; j++) {
            uint32_t k = i * out_dim + j;
            V2B_SOC_MAC_W_LOAD_ADDR = V2B_SOC_MAC_W_LOAD_PACK(i, j);
            V2B_SOC_MAC_W_LOAD_DATA = V2B_SOC_MAC_W_DATA_PACK(w_pos[k], w_neg[k]);
            V2B_SOC_MAC_W_LOAD_CTRL = 1u;
        }
    }
}

/* ── Primitive (3): run_streamed_stage via bus ── */
uint8_t v2b_run_stage(uint32_t in_dim, uint32_t out_dim,
                      uint32_t threshold, uint32_t sum_max,
                      uint32_t input_src, uint32_t output_dst)
{
    V2B_SOC_STAGE_CFG0 = (in_dim & 0xFFFFu) | ((out_dim & 0xFFFFu) << 16);
    V2B_SOC_STAGE_CFG1 = threshold;
    V2B_SOC_STAGE_CFG2 = sum_max;
    uint32_t cfg3 = (input_src  << V2B_SOC_CFG3_INPUT_SRC_SHIFT)
                  | (output_dst << V2B_SOC_CFG3_OUTPUT_DST_SHIFT)
                  | (1u         << V2B_SOC_CFG3_IS_TILE_FINAL_SHIFT);
    V2B_SOC_STAGE_CFG3 = cfg3;
    V2B_SOC_STAGE_CFG5 = T_COUNT;

    /* Clear stale DONE before launching a new stage. START does not auto-clear it. */
    V2B_SOC_STAGE_CTRL = V2B_SOC_STAGE_CTRL_DONE;
    V2B_SOC_STAGE_CTRL = V2B_SOC_STAGE_CTRL_START;

    /* Wait for a fresh DONE. This catches both normal long-running stages and
     * short/stale-launch corner cases where BUSY may never be observed high. */
    return v2b_wait_stage_done_fresh(V2B_STAGE_POLL_TIMEOUT);
}

/* ── Read stage 1 output (stream_buf_B) and count spikes per class ── */
void v2b_count_stage1_spikes(int32_t *counts_out /* [out_dim] */,
                             uint32_t out_dim)
{
    for (uint32_t j = 0; j < out_dim; j++) counts_out[j] = 0;
    for (uint32_t t = 0; t < T_COUNT; t++) {
        uint32_t row = V2B_SOC_READ_SBB(t);
        for (uint32_t j = 0; j < out_dim; j++) {
            if (row & (1u << j)) counts_out[j] += 1;
        }
    }
}

/* ── Top-level: resident 14×14 2-stage inference for one sample ── */
int v2b_infer_resident_14x14(const uint8_t *pixel_196,
                             const uint8_t *s0_w_pos, const uint8_t *s0_w_neg,
                             const uint8_t *s1_w_pos, const uint8_t *s1_w_neg,
                             int32_t *counts_out_10)
{
    /* Scratch: T × 8 words = 64 × 8 = 512 uint32 = 2 KB */
    static uint32_t stream_bits[T_COUNT * WORDS_PER_ROW];

    /* Step 1: encode pixel → binary spike stream */
    v2b_encode_pixel_even_rate(pixel_196, S0_IN_DIM, T_COUNT, stream_bits);

    /* Step 2: clear stream buffers (per-sample membrane reset built-in to stage) */
    V2B_SOC_STREAM_BUF_CTRL = V2B_SOC_STREAM_BUF_CLEAR_A | V2B_SOC_STREAM_BUF_CLEAR_B;

    /* Step 3: load encoded stream + stage 0 weights, run stage 0 */
    v2b_load_input_stream(stream_bits, T_COUNT);
    v2b_load_mac_weights(s0_w_pos, s0_w_neg, S0_IN_DIM, S0_OUT_DIM);
    uint8_t e0 = v2b_run_stage(S0_IN_DIM, S0_OUT_DIM, S0_THRESHOLD, S0_SUM_MAX,
                                V2B_SOC_BUF_SEL_INPUT_SRAM,
                                V2B_SOC_BUF_SEL_STREAM_A);
    if (e0 != 0) return -1;

    /* Step 4: load stage 1 weights, run stage 1 */
    v2b_load_mac_weights(s1_w_pos, s1_w_neg, S1_IN_DIM, S1_OUT_DIM);
    uint8_t e1 = v2b_run_stage(S1_IN_DIM, S1_OUT_DIM, S1_THRESHOLD, S1_SUM_MAX,
                                V2B_SOC_BUF_SEL_STREAM_A,
                                V2B_SOC_BUF_SEL_STREAM_B);
    if (e1 != 0) return -2;

    /* Step 5: read per-class spike counts */
    v2b_count_stage1_spikes(counts_out_10, S1_OUT_DIM);

    /* Step 6: predict argmax — caller can also do this */
    int best_class = 0;
    int32_t best_count = counts_out_10[0];
    for (int j = 1; j < 10; j++) {
        if (counts_out_10[j] > best_count) {
            best_count = counts_out_10[j];
            best_class = j;
        }
    }
    return best_class;
}

int v2b_infer_resident_14x14_trace(const uint8_t *pixel_196,
                                   const uint8_t *s0_w_pos, const uint8_t *s0_w_neg,
                                   const uint8_t *s1_w_pos, const uint8_t *s1_w_neg,
                                   int32_t *counts_out_10,
                                   uint32_t sample_id)
{
    static uint32_t stream_bits[T_COUNT * WORDS_PER_ROW];
    uint32_t s0_threshold = S0_THRESHOLD;
    uint8_t e0;
    uint8_t e1;

    if (sample_id == V2B_NEGCTRL_SAMPLE_ID) {
        if (V2B_NEGCTRL_STAGE0_THRESHOLD_OVERRIDE != S0_THRESHOLD) {
            s0_threshold = V2B_NEGCTRL_STAGE0_THRESHOLD_OVERRIDE;
        } else if (V2B_NEGCTRL_STAGE0_THRESHOLD_DELTA != 0u) {
            s0_threshold += V2B_NEGCTRL_STAGE0_THRESHOLD_DELTA;
        }
    }

    v2b_encode_pixel_even_rate(pixel_196, S0_IN_DIM, T_COUNT, stream_bits);
    V2B_SOC_STREAM_BUF_CTRL = V2B_SOC_STREAM_BUF_CLEAR_A | V2B_SOC_STREAM_BUF_CLEAR_B;
    v2b_trace_hash_clear();

    v2b_load_input_stream(stream_bits, T_COUNT);
    v2b_load_mac_weights(s0_w_pos, s0_w_neg, S0_IN_DIM, S0_OUT_DIM);
    v2b_trace_hash_enable(0u);
    e0 = v2b_run_stage(S0_IN_DIM, S0_OUT_DIM, s0_threshold, S0_SUM_MAX,
                       V2B_SOC_BUF_SEL_INPUT_SRAM,
                       V2B_SOC_BUF_SEL_STREAM_A);
    v2b_trace_hash_disable();
    if (e0 != 0u) {
        v2b_trace_hash_dump_uart(V2B_TRACE_HASH_CONFIG_FASHION14,
                                 V2B_TRACE_HASH_HOST_NAME,
                                 sample_id);
        return -1;
    }

    v2b_load_mac_weights(s1_w_pos, s1_w_neg, S1_IN_DIM, S1_OUT_DIM);
    v2b_trace_hash_enable(1u);
    e1 = v2b_run_stage(S1_IN_DIM, S1_OUT_DIM, S1_THRESHOLD, S1_SUM_MAX,
                       V2B_SOC_BUF_SEL_STREAM_A,
                       V2B_SOC_BUF_SEL_STREAM_B);
    v2b_trace_hash_disable();
    if (e1 != 0u) {
        v2b_trace_hash_dump_uart(V2B_TRACE_HASH_CONFIG_FASHION14,
                                 V2B_TRACE_HASH_HOST_NAME,
                                 sample_id);
        return -2;
    }

    v2b_count_stage1_spikes(counts_out_10, S1_OUT_DIM);

    {
        int best_class = 0;
        int32_t best_count = counts_out_10[0];
        for (int j = 1; j < 10; j++) {
            if (counts_out_10[j] > best_count) {
                best_count = counts_out_10[j];
                best_class = j;
            }
        }
        v2b_trace_hash_dump_uart(V2B_TRACE_HASH_CONFIG_FASHION14,
                                 V2B_TRACE_HASH_HOST_NAME,
                                 sample_id);
        return best_class;
    }
}

/* ── M3 Phase 2A: latency / cycle partition variant ───────────────────
 *
 * Mirrors v2b_run_stage / v2b_infer_resident_14x14 but switches the
 * 5-segment recorder (v2b_m3_state_t) at:
 *   - HOST_SETUP for pixel encode + buffer clear + per-stage CFG writes
 *   - TRANSFER  for input fmap + weight load
 *   - ACCEL_ACTIVE for STAGE_CTRL.START → BUSY=0 busy-poll
 *   - READBACK for stream_buffer drain
 *   - DECODE   for argmax
 *
 * Codex 2026-05-06 review constraint: do NOT scatter calls into the
 * existing _trace / base path. These variants are entirely isolated. */

static uint8_t v2b_run_stage_m3(v2b_m3_state_t *m3,
                                uint32_t in_dim, uint32_t out_dim,
                                uint32_t threshold, uint32_t sum_max,
                                uint32_t input_src, uint32_t output_dst)
{
    /* Caller is in TRANSFER (input/weight load just finished). The CFG
     * writes that follow are host-side bookkeeping → HOST_SETUP. */
    v2b_m3_seg_switch(m3, V2B_M3_SEG_HOST_SETUP);

    V2B_SOC_STAGE_CFG0 = (in_dim & 0xFFFFu) | ((out_dim & 0xFFFFu) << 16);
    V2B_SOC_STAGE_CFG1 = threshold;
    V2B_SOC_STAGE_CFG2 = sum_max;
    uint32_t cfg3 = (input_src  << V2B_SOC_CFG3_INPUT_SRC_SHIFT)
                  | (output_dst << V2B_SOC_CFG3_OUTPUT_DST_SHIFT)
                  | (1u         << V2B_SOC_CFG3_IS_TILE_FINAL_SHIFT);
    V2B_SOC_STAGE_CFG3 = cfg3;
    V2B_SOC_STAGE_CFG5 = T_COUNT;

    /* Clear stale DONE before launching (kept inside HOST_SETUP because
     * it's a host-side W1C write, not yet handing over to the engine). */
    V2B_SOC_STAGE_CTRL = V2B_SOC_STAGE_CTRL_DONE;

    /* Crossover point: from this single switch onward we are in
     * ACCEL_ACTIVE. The START write itself crosses the boundary; we
     * switch state machine BEFORE the write so the cycle-now() snapshot
     * captures "just before START" in cumulative[HOST_SETUP] and
     * "from-START-onward" in cumulative[ACCEL_ACTIVE]. */
    v2b_m3_seg_switch(m3, V2B_M3_SEG_ACCEL_ACTIVE);
    V2B_SOC_STAGE_CTRL = V2B_SOC_STAGE_CTRL_START;

    /* Busy-poll DONE; entire poll-loop is ACCEL_ACTIVE per design §2. */
    return v2b_wait_stage_done_fresh(V2B_STAGE_POLL_TIMEOUT);
    /* Returns with m3 still in ACCEL_ACTIVE; caller switches out. */
}

int v2b_infer_resident_14x14_m3(const uint8_t *pixel_196,
                                const uint8_t *s0_w_pos, const uint8_t *s0_w_neg,
                                const uint8_t *s1_w_pos, const uint8_t *s1_w_neg,
                                int32_t *counts_out_10,
                                v2b_m3_state_t *m3)
{
    static uint32_t stream_bits[T_COUNT * WORDS_PER_ROW];
    uint8_t e0;
    uint8_t e1;

    if (m3 == 0) return -100; /* defensive: M3 variant requires state */

    /* Caller already invoked v2b_m3_init(m3); we open the first segment. */
    v2b_m3_seg_begin(m3, V2B_M3_SEG_HOST_SETUP);

    v2b_encode_pixel_even_rate(pixel_196, S0_IN_DIM, T_COUNT, stream_bits);
    V2B_SOC_STREAM_BUF_CTRL = V2B_SOC_STREAM_BUF_CLEAR_A | V2B_SOC_STREAM_BUF_CLEAR_B;

    /* HOST_SETUP -> TRANSFER (input + stage-0 weight load) */
    v2b_m3_seg_switch(m3, V2B_M3_SEG_TRANSFER);
    v2b_load_input_stream(stream_bits, T_COUNT);
    v2b_load_mac_weights(s0_w_pos, s0_w_neg, S0_IN_DIM, S0_OUT_DIM);

    /* run_stage_m3 takes HOST_SETUP -> ACCEL_ACTIVE internally */
    e0 = v2b_run_stage_m3(m3, S0_IN_DIM, S0_OUT_DIM, S0_THRESHOLD, S0_SUM_MAX,
                          V2B_SOC_BUF_SEL_INPUT_SRAM,
                          V2B_SOC_BUF_SEL_STREAM_A);
    if (e0 != 0u) {
        v2b_m3_finalize(m3);
        return -1;
    }

    /* ACCEL_ACTIVE -> TRANSFER (stage-1 weight load only; input still
     * resident in stream_a from stage 0). */
    v2b_m3_seg_switch(m3, V2B_M3_SEG_TRANSFER);
    v2b_load_mac_weights(s1_w_pos, s1_w_neg, S1_IN_DIM, S1_OUT_DIM);

    e1 = v2b_run_stage_m3(m3, S1_IN_DIM, S1_OUT_DIM, S1_THRESHOLD, S1_SUM_MAX,
                          V2B_SOC_BUF_SEL_STREAM_A,
                          V2B_SOC_BUF_SEL_STREAM_B);
    if (e1 != 0u) {
        v2b_m3_finalize(m3);
        return -2;
    }

    /* ACCEL_ACTIVE -> READBACK */
    v2b_m3_seg_switch(m3, V2B_M3_SEG_READBACK);
    v2b_count_stage1_spikes(counts_out_10, S1_OUT_DIM);

    /* READBACK -> DECODE */
    v2b_m3_seg_switch(m3, V2B_M3_SEG_DECODE);
    {
        int best_class = 0;
        int32_t best_count = counts_out_10[0];
        for (int j = 1; j < 10; j++) {
            if (counts_out_10[j] > best_count) {
                best_count = counts_out_10[j];
                best_class = j;
            }
        }
        /* Close active segment (DECODE) before finalize records the
         * end-to-end wall-clock anchor. */
        v2b_m3_seg_end(m3);
        v2b_m3_finalize(m3);
        return best_class;
    }
}
