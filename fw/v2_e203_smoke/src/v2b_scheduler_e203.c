/*
 * fw/v2_e203_smoke/src/v2b_scheduler_e203.c
 *
 * Thin wrapper that retargets fw/src/v2b_scheduler.c for this branch by
 * pinning V2B_SOC_BASE to the V2E203 address map (0xA000_0000). All other
 * primitives (v2b_encode_pixel_even_rate, v2b_load_input_stream,
 * v2b_load_mac_weights, v2b_run_stage, v2b_count_stage1_spikes,
 * v2b_infer_resident_14x14) come from v2b_scheduler.c unchanged.
 */

#define V2B_SOC_BASE 0xA0000000u
#include "../../src/v2b_scheduler.c"
