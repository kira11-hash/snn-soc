#ifndef V2B_CONV_SCHEDULER_H
#define V2B_CONV_SCHEDULER_H

#include <stdint.h>

typedef struct {
    uint16_t H;
    uint16_t W;
    uint16_t C_in;
    uint16_t C_out;
    uint16_t out_H;
    uint16_t out_W;
    uint16_t t_count;
    uint16_t tile_count;
    uint16_t last_tile_valid_count;
    uint32_t threshold;
    uint32_t sum_max;
    uint32_t fmap_base_word;
    uint32_t out_base_word;
    uint8_t k;
    uint8_t stride;
    uint8_t pad;
    uint8_t pp_sel;
    uint8_t flatten_mode;
} v2b_conv_layer_cfg_t;

typedef struct {
    const uint16_t *offsets;
    const uint8_t *entries; /* packed triples: lane, out_c, {neg[7:4],pos[3:0]} */
    uint16_t tile_count;
    uint16_t c_out;
    uint16_t last_tile_valid_count;
    uint16_t layer_id;
} v2b_sparse_layer_t;

void v2b_clear_stream_buffers(void);
void v2b_load_input_fmap_words(const uint32_t *words, uint32_t word_count, uint32_t target_bank);
void v2b_clear_sparse_loaded_tile(void);
void v2b_switch_sparse_tile(const v2b_sparse_layer_t *layer, uint16_t tile_idx);
int v2b_run_conv_layer(const v2b_conv_layer_cfg_t *cfg,
                       const v2b_sparse_layer_t *layer,
                       uint32_t requests_expected);
uint8_t v2b_run_fc_stage(uint32_t in_dim, uint32_t out_dim,
                         uint32_t threshold, uint32_t sum_max,
                         uint32_t input_src, uint32_t output_dst);
void v2b_count_stream_spikes(int32_t *counts_out, uint32_t out_dim, uint32_t read_stream_b);
int v2b_run_lenet5_demo(const uint32_t *input_words,
                        int32_t *counts_out_10);

#endif /* V2B_CONV_SCHEDULER_H */
