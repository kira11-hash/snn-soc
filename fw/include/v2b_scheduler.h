#ifndef V2B_SCHEDULER_H
#define V2B_SCHEDULER_H

#include <stdint.h>

void v2b_encode_pixel_even_rate(const uint8_t *pixels, uint32_t in_dim,
                                uint32_t T, uint32_t *stream_out_bits);
void v2b_load_input_stream(const uint32_t *stream_bits, uint32_t T);
void v2b_load_mac_weights(const uint8_t *w_pos, const uint8_t *w_neg,
                          uint32_t in_dim, uint32_t out_dim);
uint8_t v2b_run_stage(uint32_t in_dim, uint32_t out_dim,
                      uint32_t threshold, uint32_t sum_max,
                      uint32_t input_src, uint32_t output_dst);
void v2b_count_stage1_spikes(int32_t *counts_out, uint32_t out_dim);

int v2b_infer_resident_14x14(const uint8_t *pixel_196,
                             const uint8_t *s0_w_pos, const uint8_t *s0_w_neg,
                             const uint8_t *s1_w_pos, const uint8_t *s1_w_neg,
                             int32_t *counts_out_10);

int v2b_infer_resident_14x14_trace(const uint8_t *pixel_196,
                                   const uint8_t *s0_w_pos, const uint8_t *s0_w_neg,
                                   const uint8_t *s1_w_pos, const uint8_t *s1_w_neg,
                                   int32_t *counts_out_10,
                                   uint32_t sample_id);

#endif /* V2B_SCHEDULER_H */
