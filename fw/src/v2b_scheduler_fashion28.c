/*
 * fw/src/v2b_scheduler_fashion28.c
 *
 * Config #5 shared scheduler:
 *   Fashion-MNIST 28x28, streamed-rate FC 784 -> 64 -> 10.
 *
 * Live repo contract (Phase 0, 2026-05-10):
 *   - stage 0 is not "13 tiles"; it is 4 tiles under the V2.B 256-WL cap:
 *       256 + 256 + 256 + 16
 *   - cross-tile accumulation is handled by stage_engine_v2 tile_mode +
 *     tile_partial_buf; only the final tile emits the stage-0 spike stream
 *   - each stage-0 tile uses the fixed full-stage sum_max (784 * 15), not
 *     tile_in_dim * 15. That keeps the tiled deployment path much closer to
 *     the historical untiled Config #5 reference without an RTL redesign to
 *     defer ADC until after cross-tile accumulation.
 *   - stage 1 remains a single-tile 64 -> 10 streamed stage
 *
 * This file is host-agnostic and is intended to be compiled through thin
 * ARM / E203 wrappers that set V2B_SOC_BASE and V2B_TRACE_HASH_HOST_NAME.
 */

#include <stdint.h>
#include "v2b_soc_regs.h"
#include "v2b_trace_hash.h"
#include "uart_printf.h"

#ifndef V2B_TRACE_HASH_HOST_NAME
#define V2B_TRACE_HASH_HOST_NAME "?"
#endif

#ifndef V2B_TRACE_HASH_CONFIG_FASHION28
#define V2B_TRACE_HASH_CONFIG_FASHION28 "v2b_fc_fashion28_2L"
#endif

#define F28_S0_IN_DIM       784u
#define F28_S0_OUT_DIM       64u
#define F28_S0_THRESHOLD     16u
#define F28_S0_FIXED_SUM_MAX (F28_S0_IN_DIM * 15u)
#define F28_S1_IN_DIM        64u
#define F28_S1_OUT_DIM       10u
#define F28_S1_THRESHOLD      8u
#define F28_S1_SUM_MAX      960u
#define F28_T_COUNT          64u
#define F28_WORDS_PER_ROW     8u   /* 256 bits / 32 */
#define F28_TILE_MAX_IN_DIM (F28_WORDS_PER_ROW * 32u)
#define F28_STAGE_ERR_TIMEOUT 0xFEu
#define F28_STAGE_POLL_TIMEOUT 2000000u

static void f28_mmio_barrier(void)
{
#if defined(__aarch64__)
    __asm__ volatile("dsb sy" ::: "memory");
    __asm__ volatile("isb" ::: "memory");
#elif defined(__riscv)
    __asm__ volatile("fence iorw, iorw" ::: "memory");
#endif
}

static void f28_stream_clear_guard(void)
{
    for (volatile uint32_t i = 0; i < 8192u; i++) {
#if defined(__aarch64__)
        __asm__ volatile("nop");
#endif
    }
    f28_mmio_barrier();
}

static uint8_t f28_wait_stage_done_fresh(uint32_t poll_timeout)
{
    uint32_t guard = 0u;
    while (guard < poll_timeout) {
        uint32_t ctrl = V2B_SOC_STAGE_CTRL;
        if ((ctrl & V2B_SOC_STAGE_CTRL_DONE) != 0u) {
            uint8_t err = (uint8_t)V2B_SOC_STAGE_ERR(V2B_SOC_STAGE_STATUS);
            V2B_SOC_STAGE_CTRL = V2B_SOC_STAGE_CTRL_DONE;
            return err;
        }
        guard++;
    }
    return F28_STAGE_ERR_TIMEOUT;
}

static uint32_t f28_stage0_tile_count(void)
{
    return (F28_S0_IN_DIM + F28_TILE_MAX_IN_DIM - 1u) / F28_TILE_MAX_IN_DIM;
}

static uint32_t f28_stage0_tile_offset(uint32_t tile_idx)
{
    return tile_idx * F28_TILE_MAX_IN_DIM;
}

static uint32_t f28_stage0_tile_in_dim(uint32_t tile_idx)
{
    uint32_t start = f28_stage0_tile_offset(tile_idx);
    uint32_t remain = F28_S0_IN_DIM - start;
    return remain > F28_TILE_MAX_IN_DIM ? F28_TILE_MAX_IN_DIM : remain;
}

static uint32_t f28_stage0_tile_sum_max(uint32_t tile_in_dim)
{
    (void)tile_in_dim;
    return F28_S0_FIXED_SUM_MAX;
}

static void f28_encode_pixel_even_rate_slice(const uint8_t *pixels,
                                             uint32_t row_offset,
                                             uint32_t in_dim,
                                             uint32_t T,
                                             uint32_t *stream_out_bits)
{
    static int32_t acc[F28_TILE_MAX_IN_DIM];

    for (uint32_t i = 0; i < in_dim; i++) acc[i] = 0;
    for (uint32_t k = 0; k < T * F28_WORDS_PER_ROW; k++) stream_out_bits[k] = 0u;

    for (uint32_t t = 0; t < T; t++) {
        uint32_t *row = &stream_out_bits[t * F28_WORDS_PER_ROW];
        for (uint32_t w = 0; w < F28_WORDS_PER_ROW; w++) row[w] = 0u;
        for (uint32_t i = 0; i < in_dim; i++) {
            acc[i] += (int32_t)pixels[row_offset + i];
            if (acc[i] >= 256) {
                row[i >> 5] |= (1u << (i & 31u));
                acc[i] -= 256;
            }
        }
    }
}

void v2b_load_input_stream(const uint32_t *stream_bits, uint32_t T)
{
    for (uint32_t t = 0; t < T; t++) {
        const uint32_t *row = &stream_bits[t * F28_WORDS_PER_ROW];
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

void v2b_load_mac_weights_packed(const uint8_t *packed_weights,
                                 uint32_t row_offset,
                                 uint32_t in_dim,
                                 uint32_t out_dim,
                                 uint32_t full_out_dim)
{
    for (uint32_t i = 0; i < in_dim; i++) {
        for (uint32_t j = 0; j < out_dim; j++) {
            uint32_t src_idx = (row_offset + i) * full_out_dim + j;
            uint8_t packed = packed_weights[src_idx];
            uint8_t pos = packed & 0x0Fu;
            uint8_t neg = (packed >> 4) & 0x0Fu;
            V2B_SOC_MAC_W_LOAD_ADDR = V2B_SOC_MAC_W_LOAD_PACK(i, j);
            V2B_SOC_MAC_W_LOAD_DATA = V2B_SOC_MAC_W_DATA_PACK(pos, neg);
            V2B_SOC_MAC_W_LOAD_CTRL = 1u;
        }
    }
}

static uint8_t f28_run_stage_cfg(uint32_t in_dim,
                                 uint32_t out_dim,
                                 uint32_t threshold,
                                 uint32_t sum_max,
                                 uint32_t input_src,
                                 uint32_t output_dst,
                                 uint8_t tile_mode,
                                 uint8_t is_tile_final)
{
    uint32_t cfg3 = (input_src  << V2B_SOC_CFG3_INPUT_SRC_SHIFT)
                  | (output_dst << V2B_SOC_CFG3_OUTPUT_DST_SHIFT);
    if (tile_mode) cfg3 |= (1u << V2B_SOC_CFG3_TILE_MODE_SHIFT);
    if (is_tile_final) cfg3 |= (1u << V2B_SOC_CFG3_IS_TILE_FINAL_SHIFT);

    V2B_SOC_STAGE_CFG0 = (in_dim & 0xFFFFu) | ((out_dim & 0xFFFFu) << 16);
    V2B_SOC_STAGE_CFG1 = threshold;
    V2B_SOC_STAGE_CFG2 = sum_max;
    V2B_SOC_STAGE_CFG3 = cfg3;
    V2B_SOC_STAGE_CFG5 = F28_T_COUNT;
    V2B_SOC_STAGE_CTRL = V2B_SOC_STAGE_CTRL_DONE;
    V2B_SOC_STAGE_CTRL = V2B_SOC_STAGE_CTRL_START;
    return f28_wait_stage_done_fresh(F28_STAGE_POLL_TIMEOUT);
}

static void f28_count_stage1_spikes(int32_t *counts_out)
{
    for (uint32_t j = 0; j < F28_S1_OUT_DIM; j++) counts_out[j] = 0;
    for (uint32_t t = 0; t < F28_T_COUNT; t++) {
        uint32_t row = V2B_SOC_READ_SBB(t);
        for (uint32_t j = 0; j < F28_S1_OUT_DIM; j++) {
            if (row & (1u << j)) counts_out[j] += 1;
        }
    }
}

static void f28_clear_stage_state(void)
{
    V2B_SOC_STREAM_BUF_CTRL = V2B_SOC_STREAM_BUF_CLEAR_A
                            | V2B_SOC_STREAM_BUF_CLEAR_B
                            | V2B_SOC_STREAM_BUF_CLEAR_TILE_BUF;
    f28_stream_clear_guard();
}

static int f28_run_stage0_internal(const uint8_t *pixel_784,
                                   const uint8_t *s0_w_packed,
                                   uint8_t trace_stage0)
{
    static uint32_t stream_bits[F28_T_COUNT * F28_WORDS_PER_ROW];

    uint32_t tile_count = f28_stage0_tile_count();
    for (uint32_t tile_idx = 0; tile_idx < tile_count; tile_idx++) {
        uint32_t tile_offset = f28_stage0_tile_offset(tile_idx);
        uint32_t tile_in_dim = f28_stage0_tile_in_dim(tile_idx);
        uint8_t is_last = (tile_idx + 1u == tile_count) ? 1u : 0u;
        uint8_t trace_open = 0u;
        uint8_t err;

        f28_encode_pixel_even_rate_slice(pixel_784, tile_offset, tile_in_dim,
                                         F28_T_COUNT, stream_bits);
        v2b_load_input_stream(stream_bits, F28_T_COUNT);
        v2b_load_mac_weights_packed(s0_w_packed, tile_offset, tile_in_dim,
                                    F28_S0_OUT_DIM, F28_S0_OUT_DIM);

        if (trace_stage0 && is_last) {
            v2b_trace_hash_enable(0u);
            trace_open = 1u;
        }

        err = f28_run_stage_cfg(tile_in_dim, F28_S0_OUT_DIM,
                                F28_S0_THRESHOLD,
                                f28_stage0_tile_sum_max(tile_in_dim),
                                V2B_SOC_BUF_SEL_INPUT_SRAM,
                                V2B_SOC_BUF_SEL_STREAM_A,
                                /*tile_mode=*/1u,
                                is_last);
        if (trace_open) v2b_trace_hash_disable();
        if (err != 0u) return -1;
    }
    return 0;
}

int v2b_infer_resident_28x28(const uint8_t *pixel_784,
                             const uint8_t *s0_w_packed,
                             const uint8_t *s1_w_packed,
                             int32_t *counts_out_10)
{
    int stage0_rc;
    int best_class = 0;
    int32_t best_count;
    uint8_t err;

    f28_clear_stage_state();

    stage0_rc = f28_run_stage0_internal(pixel_784, s0_w_packed, /*trace_stage0=*/0u);
    if (stage0_rc != 0) return stage0_rc;

    v2b_load_mac_weights_packed(s1_w_packed, 0u, F28_S1_IN_DIM, F28_S1_OUT_DIM, F28_S1_OUT_DIM);
    err = f28_run_stage_cfg(F28_S1_IN_DIM, F28_S1_OUT_DIM,
                            F28_S1_THRESHOLD, F28_S1_SUM_MAX,
                            V2B_SOC_BUF_SEL_STREAM_A,
                            V2B_SOC_BUF_SEL_STREAM_B,
                            /*tile_mode=*/0u,
                            /*is_tile_final=*/1u);
    if (err != 0u) return -2;

    f28_count_stage1_spikes(counts_out_10);
    best_count = counts_out_10[0];
    for (int j = 1; j < 10; j++) {
        if (counts_out_10[j] > best_count) {
            best_count = counts_out_10[j];
            best_class = j;
        }
    }
    return best_class;
}

int v2b_infer_resident_28x28_trace(const uint8_t *pixel_784,
                                   const uint8_t *s0_w_packed,
                                   const uint8_t *s1_w_packed,
                                   int32_t *counts_out_10,
                                   uint32_t sample_id)
{
    int rc;
    uint8_t err;

    f28_clear_stage_state();
    v2b_trace_hash_clear();

    rc = f28_run_stage0_internal(pixel_784, s0_w_packed, /*trace_stage0=*/1u);
    if (rc != 0) {
        v2b_trace_hash_dump_uart(V2B_TRACE_HASH_CONFIG_FASHION28,
                                 V2B_TRACE_HASH_HOST_NAME,
                                 sample_id);
        return rc;
    }

    v2b_load_mac_weights_packed(s1_w_packed, 0u, F28_S1_IN_DIM, F28_S1_OUT_DIM, F28_S1_OUT_DIM);
    v2b_trace_hash_enable(1u);
    err = f28_run_stage_cfg(F28_S1_IN_DIM, F28_S1_OUT_DIM,
                            F28_S1_THRESHOLD, F28_S1_SUM_MAX,
                            V2B_SOC_BUF_SEL_STREAM_A,
                            V2B_SOC_BUF_SEL_STREAM_B,
                            /*tile_mode=*/0u,
                            /*is_tile_final=*/1u);
    v2b_trace_hash_disable();
    if (err != 0u) {
        v2b_trace_hash_dump_uart(V2B_TRACE_HASH_CONFIG_FASHION28,
                                 V2B_TRACE_HASH_HOST_NAME,
                                 sample_id);
        return -2;
    }

    f28_count_stage1_spikes(counts_out_10);

    rc = 0;
    {
        int best_class = 0;
        int32_t best_count = counts_out_10[0];
        for (int j = 1; j < 10; j++) {
            if (counts_out_10[j] > best_count) {
                best_count = counts_out_10[j];
                best_class = j;
            }
        }
        rc = best_class;
    }
    v2b_trace_hash_dump_uart(V2B_TRACE_HASH_CONFIG_FASHION28,
                             V2B_TRACE_HASH_HOST_NAME,
                             sample_id);
    return rc;
}
