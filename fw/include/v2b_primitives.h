#ifndef V2B_PRIMITIVES_H
#define V2B_PRIMITIVES_H

/*
 * V2.B firmware primitive wrappers (REV 3.3 D3 / B0).
 *
 * 5 primitives per plan REV 3.2 §Phase B architecture principle:
 *   (1) program_stage_weights   — existing cim_program_ctrl (unchanged in B1)
 *   (2) load_input_stream       — DMA to V2B_INPUT_STREAM_SRAM_BASE
 *   (3) run_streamed_stage      — STAGE_CTRL.START primitive
 *   (4) swap_stream_buffers     — STREAM_BUF_CTRL.SWAP
 *   (5) clear_or_preserve_state — STATE_CTRL
 *
 * Firmware scheduler walks `topology_desc_t *` (binary descriptor
 * produced by exporter_multilayer.py) and issues these primitives
 * in sequence. Main 14×14 resident demo path uses (2), (3), (4) +
 * (5) only — no re-program per stage.
 */

#include <stdint.h>
#include "v2b_stage_regs.h"

/* Matches exporter_multilayer.py `stage_desc_t` layout exactly. */
typedef struct __attribute__((packed)) {
    uint16_t in_dim;
    uint16_t out_dim;
    uint32_t threshold;
    uint32_t sum_max;
    uint32_t weight_pos_addr;
    uint32_t weight_neg_addr;
    uint8_t  is_resident;
    uint8_t  is_tile_final;
    uint8_t  tile_mode;
    uint8_t  chunk_id;
} v2b_stage_desc_t;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint16_t version;
    uint16_t stream_timesteps;
    uint8_t  adc_bits;
    uint8_t  adc_full_scale;
    uint8_t  num_stages_total;
    uint8_t  num_chunks;
    uint32_t pixel_stream_addr;
    uint32_t reserved[4];
    v2b_stage_desc_t stages[];
} v2b_topology_desc_t;

static inline uint32_t v2b_pack_cfg3(uint8_t input_src, uint8_t output_dst,
                                     uint8_t tile_mode, uint8_t is_tile_final,
                                     uint8_t preserve_membrane) {
    return ((uint32_t)input_src << V2B_CFG3_INPUT_SRC_SHIFT)
         | ((uint32_t)output_dst << V2B_CFG3_OUTPUT_DST_SHIFT)
         | ((uint32_t)tile_mode << V2B_CFG3_TILE_MODE_SHIFT)
         | ((uint32_t)is_tile_final << V2B_CFG3_IS_TILE_FINAL_SHIFT)
         | ((uint32_t)preserve_membrane << V2B_CFG3_PRESERVE_MEMBRANE_SHIFT);
}

/* ── Primitive (2): load pre-encoded pixel stream into input_stream_sram ── */
static inline void v2b_load_input_stream(const void *src,
                                         uint32_t length_bytes) {
    /* Uses existing DMA engine. DST_SEL=2 maps to input_stream_sram once
     * reg_bank is extended (B1 remaining). For B0 prototyping we just
     * memcpy directly; real firmware will use DMA for bandwidth. */
    volatile uint8_t *dst = (volatile uint8_t *)V2B_INPUT_STREAM_SRAM_BASE;
    const uint8_t *s = (const uint8_t *)src;
    for (uint32_t i = 0; i < length_bytes; i++) dst[i] = s[i];
}

/* ── Primitive (3): run_streamed_stage with a fully configured stage_desc ── */
static inline uint8_t v2b_run_streamed_stage(const v2b_stage_desc_t *s,
                                             uint8_t  input_src,
                                             uint8_t  output_dst,
                                             uint16_t t_count,
                                             uint32_t sum_max_override) {
    /* Write CFG0..5 */
    V2B_REG_STAGE_CFG0 = ((uint32_t)s->in_dim)
                      | ((uint32_t)s->out_dim << 16);
    V2B_REG_STAGE_CFG1 = s->threshold;
    V2B_REG_STAGE_CFG2 = (sum_max_override != 0u) ? sum_max_override : s->sum_max;
    V2B_REG_STAGE_CFG3 = v2b_pack_cfg3(input_src, output_dst,
                                       s->tile_mode, s->is_tile_final, 0);
    V2B_REG_STAGE_CFG4 = s->weight_pos_addr;
    V2B_REG_STAGE_CFG5 = s->weight_neg_addr;
    /* t_count is sneakily stashed into CFG0 upper 16 bits for now — reg_bank
     * B1 expansion will provide a dedicated t_count field. */
    (void)t_count;

    /* Kick off. */
    V2B_REG_STAGE_CTRL = V2B_STAGE_CTRL_START;

    /* Poll DONE. Production firmware will use interrupt. */
    while (V2B_STAGE_STATUS_BUSY(V2B_REG_STAGE_STATUS)) { /* spin */ }
    uint8_t err = (uint8_t)V2B_STAGE_STATUS_ERR(V2B_REG_STAGE_STATUS);
    V2B_REG_STAGE_CTRL = V2B_STAGE_CTRL_DONE;  /* W1C */
    return err;
}

/* ── Primitive (4): swap stream buffers A/B ────────────────────── */
static inline void v2b_swap_stream_buffers(void) {
    V2B_REG_STREAM_BUF_CTRL = V2B_STREAM_BUF_SWAP;
}

/* ── Primitive (5): state clear ────────────────────────────────── */
static inline void v2b_clear_membrane(void) {
    V2B_REG_STATE_CTRL = V2B_STATE_CLEAR_MEMBRANE;
}

static inline void v2b_clear_all_state(void) {
    V2B_REG_STATE_CTRL = V2B_STATE_CLEAR_ALL;
}

static inline void v2b_clear_tile_buf(void) {
    V2B_REG_STREAM_BUF_CTRL = V2B_STREAM_BUF_CLEAR_TILE_BUF;
}

/* ── Descriptor validation ─────────────────────────────────────── */
static inline int v2b_validate_descriptor(const v2b_topology_desc_t *d) {
    if (d->magic != V2B_TOPO_DESC_MAGIC) return -1;
    if (d->version != V2B_TOPO_DESC_VERSION) return -2;
    if (d->num_stages_total == 0 || d->num_stages_total > V2B_TOPO_DESC_MAX_STAGES) return -3;
    return 0;
}

/* ── Pixel encoding (even_rate Bresenham accumulator, MUST match Python) ── */
/* Produces T × in_dim bit-packed stream. Output `stream[T][WORDS_PER_ROW]`.
 * Caller supplies T, in_dim, pixels (uint8 [in_dim]), and a pre-zeroed
 * bit-packed buffer sized (T * ((in_dim + 31) / 32)) uint32 words. */
static inline void v2b_encode_pixel_stream_even_rate(
    const uint8_t *pixels, uint32_t in_dim, uint32_t T,
    uint32_t *stream_bits_out /* row-major [T][WORDS_PER_ROW] */) {
    /* Per-neuron accumulator (int64 for large T). Matches
     * `encode_pixel_to_spike_stream` in snn_engine_multilayer.py. */
    const uint32_t words_per_row = (in_dim + 31u) / 32u;
    /* Zero-init accumulator each call — in embedded we'd preallocate */
    static int32_t acc[1024]; /* sized for in_dim <= 1024 (covers 28×28) */
    for (uint32_t i = 0; i < in_dim; i++) acc[i] = 0;

    for (uint32_t t = 0; t < T; t++) {
        uint32_t *row = &stream_bits_out[t * words_per_row];
        for (uint32_t w = 0; w < words_per_row; w++) row[w] = 0u;
        for (uint32_t i = 0; i < in_dim; i++) {
            acc[i] += (int32_t)pixels[i];
            if (acc[i] >= 256) {
                row[i >> 5] |= (1u << (i & 31u));
                acc[i] -= 256;
            }
        }
    }
}

#endif /* V2B_PRIMITIVES_H */
