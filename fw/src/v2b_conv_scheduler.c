#include <stdint.h>
#include "conv1_ref_all_samples.h"
#include "v2b_conv_scheduler.h"
#include "sample0_conv1_ref_sparse.h"
#include "v2b_soc_regs.h"
#include "sample0_conv2_ref_sparse.h"

#ifndef V2B_CONV_POLL_TIMEOUT
#define V2B_CONV_POLL_TIMEOUT 4000000u
#endif

#ifndef V2B_STREAM_BUF_CLEAR_GUARD_ITERS
#define V2B_STREAM_BUF_CLEAR_GUARD_ITERS 8192u
#endif

extern void uart_puts(const char *s);
extern void uart_put_dec(int32_t v);
extern void uart_put_hex32(uint32_t v);
extern void uart_putc(char c);
extern volatile uint32_t g_arm_current_sample_idx;
extern volatile uint32_t g_arm_progress_code;
extern volatile uint32_t g_arm_progress_aux0;
extern volatile uint32_t g_arm_progress_aux1;
extern volatile uint32_t g_arm_progress_aux2;

#if defined(__aarch64__)
#define ARM_DSB_SY() __asm__ volatile("dsb sy" ::: "memory")
#else
#define ARM_DSB_SY() do {} while (0)
#endif

static const uint8_t *g_loaded_entries = (const uint8_t *)0;
static uint16_t g_loaded_start = 0u;
static uint16_t g_loaded_end = 0u;
static uint16_t g_loaded_layer_id = 0xFFFFu;
static uint16_t g_loaded_tile_idx = 0xFFFFu;
static uint32_t g_lenet5_demo_call_count = 0u;

static const uint32_t g_sample0_fc1_ref_rows[LENET5_T_COUNT][8] = {
    {0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x11245141u, 0x0a02b40eu, 0x12441028u, 0x00100040u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x11a45931u, 0x9a92974fu, 0x106c0a3du, 0x001008c1u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x59a45161u, 0xce9abd2eu, 0x126c1a3cu, 0x001018c1u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x19e471f3u, 0x5e92b50eu, 0x92ec1034u, 0x00100ac1u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x51a45161u, 0x9e9ab50fu, 0x1a6c1a24u, 0x001018c1u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x79a45163u, 0xce92b76eu, 0x92ec1a34u, 0x00101a41u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x11a653f1u, 0x1e9ab50eu, 0x126c1a3eu, 0x001018c1u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x59a45563u, 0xde929d2eu, 0x126c1835u, 0x00500ac1u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x11e45171u, 0x8e92b70fu, 0x926c123cu, 0x001018c1u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u}
};

static const uint32_t g_sample0_fc2_ref_rows[LENET5_T_COUNT][8] = {
    {0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x00000000u, 0x00200080u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x00000000u, 0x20600082u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x00800020u, 0x20210082u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x04000000u, 0x2060008au, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x00800220u, 0x21600080u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x00800000u, 0x24610082u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x04000020u, 0x21200082u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x00800200u, 0x2061008au, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u},
    {0x00000020u, 0x20600082u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u, 0x00000000u}
};

static void v2b_stream_buf_clear_guard(void)
{
    for (volatile uint32_t i = 0; i < V2B_STREAM_BUF_CLEAR_GUARD_ITERS; i++) {
#if defined(__aarch64__)
        __asm__ volatile("nop");
#endif
    }
    ARM_DSB_SY();
}

static void v2b_dump_stream_rows32(const char *tag, uint32_t read_stream_b)
{
    uart_puts("[DBG] ");
    uart_puts(tag);
    uart_puts(" rows32 begin\n");
    for (uint32_t t = 0; t < LENET5_T_COUNT; t++) {
        uint32_t row = read_stream_b ? V2B_SOC_READ_SBB(t) : V2B_SOC_READ_SBA(t);
        uart_puts("[DBG] ");
        uart_puts(tag);
        uart_puts(" t=");
        uart_put_dec((int32_t)t);
        uart_puts(" row=");
        uart_put_hex32(row);
        uart_puts("\n");
    }
    uart_puts("[DBG] ");
    uart_puts(tag);
    uart_puts(" rows32 end\n");
}

static void v2b_load_input_stream_rows32x8(const uint32_t rows[LENET5_T_COUNT][8])
{
    for (uint32_t t = 0; t < LENET5_T_COUNT; t++) {
        V2B_SOC_INPUT_SRAM_ADDR = t;
        V2B_SOC_INPUT_SRAM_W0 = rows[t][0];
        V2B_SOC_INPUT_SRAM_W1 = rows[t][1];
        V2B_SOC_INPUT_SRAM_W2 = rows[t][2];
        V2B_SOC_INPUT_SRAM_W3 = rows[t][3];
        V2B_SOC_INPUT_SRAM_W4 = rows[t][4];
        V2B_SOC_INPUT_SRAM_W5 = rows[t][5];
        V2B_SOC_INPUT_SRAM_W6 = rows[t][6];
        V2B_SOC_INPUT_SRAM_W7 = rows[t][7];
        V2B_SOC_INPUT_SRAM_CTRL = 1u;
    }
}

__attribute__((unused))
static void v2b_build_padded_input_32x32(const uint32_t *src_28x28,
                                         uint32_t *dst_32x32)
{
    for (uint32_t i = 0; i < 32u * 32u; i++) dst_32x32[i] = 0u;
    for (uint32_t h = 0; h < 28u; h++) {
        for (uint32_t w = 0; w < 28u; w++) {
            dst_32x32[(h + 2u) * 32u + (w + 2u)] = src_28x28[h * 28u + w];
        }
    }
}

static void v2b_clear_fmap_words(uint32_t word_count, uint32_t target_bank)
{
    uint32_t ctrl_cfg = (target_bank ? V2B_SOC_CONV_FMAP_WR_TARGET_BANK : 0u)
                      | V2B_SOC_CONV_FMAP_WR_AUTO_INC;
    V2B_SOC_CONV_FMAP_WR_ADDR = 0u;
    V2B_SOC_CONV_FMAP_WR_CTRL = ctrl_cfg;
    for (uint32_t i = 0; i < word_count; i++) {
        V2B_SOC_CONV_FMAP_WR_DATA = 0u;
        V2B_SOC_CONV_FMAP_WR_CTRL = ctrl_cfg | V2B_SOC_CONV_FMAP_WR_COMMIT;
    }
}

static void v2b_load_sparse_fmap_words(const uint16_t *idx,
                                       const uint32_t *val,
                                       uint32_t nz_count,
                                       uint32_t target_bank)
{
    uint32_t ctrl_cfg = (target_bank ? V2B_SOC_CONV_FMAP_WR_TARGET_BANK : 0u);
    for (uint32_t i = 0; i < nz_count; i++) {
        V2B_SOC_CONV_FMAP_WR_ADDR = idx[i];
        V2B_SOC_CONV_FMAP_WR_CTRL = ctrl_cfg;
        V2B_SOC_CONV_FMAP_WR_DATA = val[i];
        V2B_SOC_CONV_FMAP_WR_CTRL = ctrl_cfg | V2B_SOC_CONV_FMAP_WR_COMMIT;
    }
}

static void v2b_load_conv1_reference_for_sample(uint32_t sample_idx)
{
    uint32_t begin = g_conv1_ref_offsets[sample_idx];
    uint32_t end = g_conv1_ref_offsets[sample_idx + 1u];
    v2b_clear_fmap_words(CONV1_REF_WORD_COUNT, 1u);
    v2b_load_sparse_fmap_words(&g_conv1_ref_idx[begin],
                               &g_conv1_ref_val[begin],
                               end - begin,
                               1u);
}

static void v2b_load_fmap_words_dense(const uint32_t *words,
                                      uint32_t word_count,
                                      uint32_t target_bank)
{
    uint32_t ctrl_cfg = (target_bank ? V2B_SOC_CONV_FMAP_WR_TARGET_BANK : 0u)
                      | V2B_SOC_CONV_FMAP_WR_AUTO_INC;
    V2B_SOC_CONV_FMAP_WR_ADDR = 0u;
    V2B_SOC_CONV_FMAP_WR_CTRL = ctrl_cfg;
    for (uint32_t i = 0; i < word_count; i++) {
        V2B_SOC_CONV_FMAP_WR_DATA = words[i];
        V2B_SOC_CONV_FMAP_WR_CTRL = ctrl_cfg | V2B_SOC_CONV_FMAP_WR_COMMIT;
    }
}

__attribute__((noinline))
static void v2b_cfg_set_tile_fields(v2b_conv_layer_cfg_t *cfg,
                                    uint16_t tile_count,
                                    uint16_t last_tile_valid_count)
{
    (*(volatile uint16_t *)&cfg->tile_count) = tile_count;
    (*(volatile uint16_t *)&cfg->last_tile_valid_count) = last_tile_valid_count;
}

__attribute__((noinline))
static void v2b_cfg_set_word_fields(v2b_conv_layer_cfg_t *cfg,
                                    uint32_t threshold,
                                    uint32_t sum_max,
                                    uint32_t fmap_base_word,
                                    uint32_t out_base_word)
{
    (*(volatile uint32_t *)&cfg->threshold) = threshold;
    (*(volatile uint32_t *)&cfg->sum_max) = sum_max;
    (*(volatile uint32_t *)&cfg->fmap_base_word) = fmap_base_word;
    (*(volatile uint32_t *)&cfg->out_base_word) = out_base_word;
}

void v2b_clear_stream_buffers(void)
{
    g_arm_progress_code = 0x100u;
    uart_puts("[TB] clear_stream_buffers\n");
    V2B_SOC_STREAM_BUF_CTRL = V2B_SOC_STREAM_BUF_CLEAR_A | V2B_SOC_STREAM_BUF_CLEAR_B;
    v2b_stream_buf_clear_guard();
    g_arm_progress_code = 0x101u;
    uart_puts("[TB] clear_stream_buffers done\n");
}

void v2b_load_input_fmap_words(const uint32_t *words, uint32_t word_count, uint32_t target_bank)
{
    uint32_t ctrl_cfg = (target_bank ? V2B_SOC_CONV_FMAP_WR_TARGET_BANK : 0u)
                      | V2B_SOC_CONV_FMAP_WR_AUTO_INC;
    g_arm_progress_code = 0x200u;
    g_arm_progress_aux0 = word_count;
    uart_puts("[TB] load_input_fmap_words start words=");
    uart_put_dec((int32_t)word_count);
    uart_puts("\n");
    uart_puts("[TB] load_input clear target bank\n");
    v2b_clear_fmap_words(word_count, target_bank);
    uart_puts("[TB] load_input clear target bank done\n");
    uart_puts("[TB] load_input init ADDR\n");
    V2B_SOC_CONV_FMAP_WR_ADDR = 0u;
    g_arm_progress_code = 0x211u;
    uart_puts("[TB] load_input init ADDR done\n");
    uart_puts("[TB] load_input init CTRL\n");
    V2B_SOC_CONV_FMAP_WR_CTRL = ctrl_cfg;
    g_arm_progress_code = 0x212u;
    uart_puts("[TB] load_input init CTRL done\n");
    for (uint32_t i = 0; i < word_count; i++) {
        g_arm_progress_code = 0x220u;
        g_arm_progress_aux1 = i;
        g_arm_progress_aux2 = i;
        if (i < 16u) {
            uart_puts("[TB] dense write idx=");
            uart_put_dec((int32_t)i);
            uart_puts(" data=0x");
            uart_put_hex32(words[i]);
            uart_puts("\n");
        }
        V2B_SOC_CONV_FMAP_WR_DATA = words[i];
        g_arm_progress_code = 0x221u;
        V2B_SOC_CONV_FMAP_WR_CTRL = ctrl_cfg | V2B_SOC_CONV_FMAP_WR_COMMIT;
        g_arm_progress_code = 0x222u;
        if (((i + 1u) >= 8u && (((i + 1u) & 7u) == 0u)) || (i + 1u) == word_count) {
            uart_puts("[TB] load_input dense-progress=");
            uart_put_dec((int32_t)(i + 1u));
            uart_puts("\n");
        }
    }
    g_arm_progress_code = 0x2FFu;
    g_arm_progress_aux2 = word_count;
    uart_puts("[TB] load_input_fmap_words done dense=");
    uart_put_dec((int32_t)word_count);
    uart_puts("\n");
}

void v2b_clear_sparse_loaded_tile(void)
{
    if (g_loaded_entries == (const uint8_t *)0) {
        return;
    }
    for (uint16_t i = g_loaded_start; i < g_loaded_end; i++) {
        uint32_t base = (uint32_t)i * 3u;
        uint8_t lane = g_loaded_entries[base + 0u];
        uint8_t out_c = g_loaded_entries[base + 1u];
        V2B_SOC_MAC_W_LOAD_ADDR = V2B_SOC_MAC_W_LOAD_PACK(lane, out_c);
        V2B_SOC_MAC_W_LOAD_DATA = 0u;
        V2B_SOC_MAC_W_LOAD_CTRL = 1u;
    }
    g_loaded_entries = (const uint8_t *)0;
    g_loaded_start = 0u;
    g_loaded_end = 0u;
    g_loaded_layer_id = 0xFFFFu;
    g_loaded_tile_idx = 0xFFFFu;
}

void v2b_switch_sparse_tile(const v2b_sparse_layer_t *layer, uint16_t tile_idx)
{
    uint16_t start = layer->offsets[tile_idx];
    uint16_t end = layer->offsets[tile_idx + 1u];
    if ((g_loaded_entries == layer->entries) &&
        (g_loaded_layer_id == layer->layer_id) &&
        (g_loaded_tile_idx == tile_idx) &&
        (g_loaded_start == start) &&
        (g_loaded_end == end)) {
        return;
    }

    v2b_clear_sparse_loaded_tile();

    for (uint16_t i = start; i < end; i++) {
        uint32_t base = (uint32_t)i * 3u;
        uint8_t lane = layer->entries[base + 0u];
        uint8_t out_c = layer->entries[base + 1u];
        uint8_t packed = layer->entries[base + 2u];
        V2B_SOC_MAC_W_LOAD_ADDR = V2B_SOC_MAC_W_LOAD_PACK(lane, out_c);
        V2B_SOC_MAC_W_LOAD_DATA = packed;
        V2B_SOC_MAC_W_LOAD_CTRL = 1u;
    }

    g_loaded_entries = layer->entries;
    g_loaded_start = start;
    g_loaded_end = end;
    g_loaded_layer_id = layer->layer_id;
    g_loaded_tile_idx = tile_idx;
}

static void v2b_switch_sparse_single_tile(const v2b_sparse_layer_t *layer)
{
    v2b_switch_sparse_tile(layer, 0u);
}

static int v2b_wait_weight_req(uint32_t *status_out)
{
    uint32_t status = 0u;
    for (uint32_t guard = 0; guard < V2B_CONV_POLL_TIMEOUT; guard++) {
        status = V2B_SOC_CONV_STATUS;
        if (status & V2B_SOC_CONV_STATUS_WEIGHT_REQ) {
            if (status_out) *status_out = status;
            return 0;
        }
        if (status & V2B_SOC_CONV_STATUS_DONE) {
            break;
        }
        if (guard == 1000000u) {
            uart_puts("[TB] wait_weight_req pending status=");
            uart_put_hex32(status);
            uart_puts("\n");
        }
    }
    if (status_out) *status_out = status;
    uart_puts("[TB] wait_weight_req timeout status=");
    uart_put_hex32(status);
    uart_puts("\n");
    return -1;
}

static int v2b_wait_conv_done(uint32_t *status_out)
{
    uint32_t status = 0u;
    for (uint32_t guard = 0; guard < V2B_CONV_POLL_TIMEOUT; guard++) {
        status = V2B_SOC_CONV_STATUS;
        if (status & V2B_SOC_CONV_STATUS_DONE) {
            if (status_out) *status_out = status;
            return 0;
        }
        if (guard == 1000000u) {
            uart_puts("[TB] wait_conv_done pending status=");
            uart_put_hex32(status);
            uart_puts("\n");
        }
    }
    if (status_out) *status_out = status;
    uart_puts("[TB] wait_conv_done timeout status=");
    uart_put_hex32(status);
    uart_puts("\n");
    return -1;
}

int v2b_run_conv_layer(const v2b_conv_layer_cfg_t *cfg,
                       const v2b_sparse_layer_t *layer,
                       uint32_t requests_expected)
{
    uint32_t mode_cfg = V2B_SOC_CONV_MODE_EN;
    if (cfg->flatten_mode) mode_cfg |= V2B_SOC_CONV_FLATTEN_MODE;
    if (cfg->pp_sel) mode_cfg |= V2B_SOC_CONV_FMAP_PP_SEL;

    g_arm_progress_code = 0x300u;
    g_arm_progress_aux0 = requests_expected;
    g_arm_progress_aux1 = cfg->tile_count;
    ARM_DSB_SY();
    uart_puts("[TB] conv cfg begin\n");
    g_arm_progress_code = 0x301u;
    uart_puts("[TB] conv cfg STAGE_CFG1\n");
    V2B_SOC_STAGE_CFG1 = cfg->threshold;
    g_arm_progress_code = 0x302u;
    uart_puts("[TB] conv cfg STAGE_CFG2\n");
    V2B_SOC_STAGE_CFG2 = cfg->sum_max;
    g_arm_progress_code = 0x303u;
    uart_puts("[TB] conv cfg MODE(defer)\n");
    g_arm_progress_code = 0x304u;
    uart_puts("[TB] conv cfg HW\n");
    V2B_SOC_CONV_CFG_HW = ((uint32_t)cfg->W << 16) | cfg->H;
    g_arm_progress_code = 0x305u;
    uart_puts("[TB] conv cfg C\n");
    V2B_SOC_CONV_CFG_C = ((uint32_t)cfg->C_out << 16) | cfg->C_in;
    g_arm_progress_code = 0x306u;
    uart_puts("[TB] conv cfg KSP\n");
    V2B_SOC_CONV_CFG_K_S_P = ((uint32_t)cfg->pad << 8) | ((uint32_t)cfg->stride << 4) | cfg->k;
    g_arm_progress_code = 0x307u;
    uart_puts("[TB] conv cfg OUT_HW\n");
    V2B_SOC_CONV_CFG_OUT_HW = ((uint32_t)cfg->out_W << 16) | cfg->out_H;
    g_arm_progress_code = 0x308u;
    uart_puts("[TB] conv cfg T\n");
    V2B_SOC_CONV_CFG_T = cfg->t_count;
    g_arm_progress_code = 0x309u;
    uart_puts("[TB] conv cfg TILE\n");
    V2B_SOC_CONV_CFG_TILE = cfg->tile_count;
    g_arm_progress_code = 0x30Au;
    V2B_SOC_CONV_CFG_TILE = ((uint32_t)cfg->last_tile_valid_count << 16) | cfg->tile_count;
    g_arm_progress_code = 0x30Bu;
    uart_puts("[TB] conv cfg FMAP_BASE\n");
    V2B_SOC_CONV_CFG_FMAP_BASE = cfg->fmap_base_word;
    g_arm_progress_code = 0x30Cu;
    uart_puts("[TB] conv cfg OUT_BASE\n");
    V2B_SOC_CONV_CFG_OUT_BASE = cfg->out_base_word;
    g_arm_progress_code = 0x30Du;
    uart_puts("[TB] conv cfg MODE\n");
    V2B_SOC_CONV_MODE_CFG = mode_cfg;
    g_arm_progress_code = 0x30Eu;
    uart_puts("[TB] conv cfg STATUS_CLR\n");
    V2B_SOC_CONV_STATUS = V2B_SOC_CONV_STATUS_DONE;
    g_arm_progress_code = 0x30Fu;
    uart_puts("[TB] conv cfg CTRL_START\n");
    V2B_SOC_CONV_CTRL = V2B_SOC_CONV_CTRL_START;
    g_arm_progress_code = 0x30Fu;
    uart_puts("[TB] conv start reqs=");
    uart_put_dec((int32_t)requests_expected);
    uart_puts(" tiles=");
    uart_put_dec((int32_t)cfg->tile_count);
    uart_puts("\n");

    for (uint32_t req = 0; req < requests_expected; req++) {
        uint32_t status = 0u;
        if (v2b_wait_weight_req(&status) != 0) return -10;
        uint32_t tile_idx = V2B_SOC_CONV_STATUS_CUR_TILE(status);
        v2b_switch_sparse_tile(layer, (uint16_t)tile_idx);
        V2B_SOC_CONV_CTRL = V2B_SOC_CONV_CTRL_WEIGHT_READY;
        if ((req < 4u) || (((req + 1u) & 63u) == 0u) || ((req + 1u) == requests_expected)) {
            uart_puts("[TB] conv weight-ready req=");
            uart_put_dec((int32_t)(req + 1u));
            uart_puts(" tile=");
            uart_put_dec((int32_t)tile_idx);
            uart_puts(" status=");
            uart_put_hex32(status);
            uart_puts("\n");
        }
    }

    {
        uint32_t status = 0u;
        if (v2b_wait_conv_done(&status) != 0) return -11;
        uart_puts("[TB] conv done status=");
        uart_put_hex32(status);
        uart_puts("\n");
        if (V2B_SOC_CONV_STATUS_ERR(status) != 0u) return -(int)V2B_SOC_CONV_STATUS_ERR(status) - 100;
    }
    return 0;
}

uint8_t v2b_run_fc_stage(uint32_t in_dim, uint32_t out_dim,
                         uint32_t threshold, uint32_t sum_max,
                         uint32_t input_src, uint32_t output_dst)
{
    uint32_t cfg3 = (input_src << V2B_SOC_CFG3_INPUT_SRC_SHIFT)
                  | (output_dst << V2B_SOC_CFG3_OUTPUT_DST_SHIFT)
                  | (1u << V2B_SOC_CFG3_IS_TILE_FINAL_SHIFT);
    V2B_SOC_STAGE_CFG0 = (in_dim & 0xFFFFu) | ((out_dim & 0xFFFFu) << 16);
    V2B_SOC_STAGE_CFG1 = threshold;
    V2B_SOC_STAGE_CFG2 = sum_max;
    V2B_SOC_STAGE_CFG3 = cfg3;
    V2B_SOC_STAGE_CFG5 = LENET5_T_COUNT;
    V2B_SOC_STAGE_CTRL = V2B_SOC_STAGE_CTRL_START;

    for (uint32_t guard = 0; guard < V2B_CONV_POLL_TIMEOUT; guard++) {
        if (!V2B_SOC_STAGE_BUSY(V2B_SOC_STAGE_STATUS)) {
            uint8_t err = (uint8_t)V2B_SOC_STAGE_ERR(V2B_SOC_STAGE_STATUS);
            V2B_SOC_STAGE_CTRL = V2B_SOC_STAGE_CTRL_DONE;
            return err;
        }
    }
    return 0xFEu;
}

__attribute__((unused))
static void v2b_run_sample0_reference_fc_diagnostics(int32_t *counts_out_10)
{
    uint8_t err;

    uart_puts("[DBG] sample0 ref-fc diag start\n");

    v2b_clear_stream_buffers();
    v2b_load_input_stream_rows32x8(g_sample0_fc1_ref_rows);
    v2b_switch_sparse_single_tile(&(const v2b_sparse_layer_t){
        lenet5_fc2_offsets, lenet5_fc2_entries, LENET5_FC2_TILE_COUNT, LENET5_FC2_C_OUT, 120u, 4u
    });
    err = v2b_run_fc_stage(120u, 84u, LENET5_TH_FC2, LENET5_SUMMAX_FC2,
                           V2B_SOC_BUF_SEL_INPUT_SRAM, V2B_SOC_BUF_SEL_STREAM_B);
    uart_puts("[DBG] ref-fc2 rc="); uart_put_dec((int32_t)err); uart_puts("\n");
    v2b_dump_stream_rows32("ref_fc2_B", 1u);

    v2b_clear_stream_buffers();
    v2b_load_input_stream_rows32x8(g_sample0_fc2_ref_rows);
    v2b_switch_sparse_single_tile(&(const v2b_sparse_layer_t){
        lenet5_fc3_offsets, lenet5_fc3_entries, LENET5_FC3_TILE_COUNT, LENET5_FC3_C_OUT, 84u, 5u
    });
    err = v2b_run_fc_stage(84u, 10u, LENET5_TH_FC3, LENET5_SUMMAX_FC3,
                           V2B_SOC_BUF_SEL_INPUT_SRAM, V2B_SOC_BUF_SEL_STREAM_A);
    uart_puts("[DBG] ref-fc3 rc="); uart_put_dec((int32_t)err); uart_puts("\n");
    v2b_dump_stream_rows32("ref_fc3_A", 0u);
    v2b_count_stream_spikes(counts_out_10, 10u, 0u);
    uart_puts("[DBG] ref-fc3 counts=[");
    for (uint32_t j = 0; j < 10u; j++) {
        uart_put_dec((int32_t)counts_out_10[j]);
        if (j + 1u < 10u) uart_putc(' ');
    }
    uart_puts("]\n");
}

__attribute__((unused))
static void v2b_run_sample0_reference_conv2_to_fc1_diag(const v2b_conv_layer_cfg_t *cfg,
                                                        const v2b_sparse_layer_t *fc1_layer)
{
    uart_puts("[DBG] sample0 ref-conv2->fc1 diag start\n");
    v2b_clear_stream_buffers();
    v2b_clear_fmap_words(SAMPLE0_CONV2_REF_WORD_COUNT, 0u);
    v2b_load_sparse_fmap_words(g_sample0_conv2_ref_nz_idx,
                               g_sample0_conv2_ref_nz_val,
                               SAMPLE0_CONV2_REF_NZ_COUNT,
                               0u);
    v2b_clear_sparse_loaded_tile();
    if (v2b_run_conv_layer(cfg, fc1_layer, 9u) != 0) {
        uart_puts("[DBG] ref-conv2->fc1 rc!=0\n");
        return;
    }
    v2b_dump_stream_rows32("ref_conv2_fc1_A", 0u);
}

__attribute__((unused))
static void v2b_run_sample0_reference_conv1_to_fc1_diag(const v2b_conv_layer_cfg_t *fc1_cfg,
                                                        const v2b_sparse_layer_t *conv2_layer,
                                                        const v2b_sparse_layer_t *fc1_layer)
{
    v2b_conv_layer_cfg_t conv2_cfg;

    uart_puts("[DBG] sample0 ref-conv1->conv2->fc1 diag start\n");
    v2b_clear_stream_buffers();
    v2b_clear_fmap_words(SAMPLE0_CONV1_REF_WORD_COUNT, 1u);
    v2b_load_sparse_fmap_words(g_sample0_conv1_ref_nz_idx,
                               g_sample0_conv1_ref_nz_val,
                               SAMPLE0_CONV1_REF_NZ_COUNT,
                               1u);
    v2b_clear_sparse_loaded_tile();

    conv2_cfg.H = 28u; conv2_cfg.W = 28u; conv2_cfg.C_in = 6u; conv2_cfg.C_out = 16u;
    conv2_cfg.out_H = 12u; conv2_cfg.out_W = 12u; conv2_cfg.t_count = LENET5_T_COUNT;
    conv2_cfg.tile_count = 1u; conv2_cfg.last_tile_valid_count = 150u;
    conv2_cfg.threshold = LENET5_TH_CONV2; conv2_cfg.sum_max = LENET5_SUMMAX_CONV2;
    conv2_cfg.fmap_base_word = 0u; conv2_cfg.out_base_word = 0u;
    conv2_cfg.k = 5u; conv2_cfg.stride = 2u; conv2_cfg.pad = 0u; conv2_cfg.pp_sel = 1u; conv2_cfg.flatten_mode = 0u;
    if (v2b_run_conv_layer(&conv2_cfg, conv2_layer, 12u * 12u) != 0) {
        uart_puts("[DBG] ref-conv1->conv2 rc!=0\n");
        return;
    }
    if (v2b_run_conv_layer(fc1_cfg, fc1_layer, 9u) != 0) {
        uart_puts("[DBG] ref-conv1->fc1 rc!=0\n");
        return;
    }
    v2b_dump_stream_rows32("ref_conv1_conv2_fc1_A", 0u);
}

__attribute__((unused))
static void v2b_run_sample0_dense_input_to_fc1_diag(const uint32_t *input_words,
                                                    const v2b_sparse_layer_t *conv1_layer,
                                                    const v2b_sparse_layer_t *conv2_layer,
                                                    const v2b_conv_layer_cfg_t *fc1_cfg,
                                                    const v2b_sparse_layer_t *fc1_layer)
{
    v2b_conv_layer_cfg_t conv_cfg;

    uart_puts("[DBG] sample0 dense-input->conv1->conv2->fc1 diag start\n");
    v2b_clear_stream_buffers();
    v2b_clear_fmap_words(LENET5_INPUT_WORDS, 0u);
    v2b_load_fmap_words_dense(input_words, LENET5_INPUT_WORDS, 0u);
    v2b_clear_sparse_loaded_tile();

    conv_cfg.H = 28u; conv_cfg.W = 28u; conv_cfg.C_in = 1u; conv_cfg.C_out = 6u;
    conv_cfg.out_H = 28u; conv_cfg.out_W = 28u; conv_cfg.t_count = LENET5_T_COUNT;
    conv_cfg.tile_count = 1u; conv_cfg.last_tile_valid_count = 25u;
    conv_cfg.threshold = LENET5_TH_CONV1; conv_cfg.sum_max = LENET5_SUMMAX_CONV1;
    conv_cfg.fmap_base_word = 0u; conv_cfg.out_base_word = 0u;
    conv_cfg.k = 5u; conv_cfg.stride = 1u; conv_cfg.pad = 2u; conv_cfg.pp_sel = 0u; conv_cfg.flatten_mode = 0u;
    if (v2b_run_conv_layer(&conv_cfg, conv1_layer, 28u * 28u) != 0) {
        uart_puts("[DBG] dense-input conv1 rc!=0\n");
        return;
    }

    conv_cfg.H = 28u; conv_cfg.W = 28u; conv_cfg.C_in = 6u; conv_cfg.C_out = 16u;
    conv_cfg.out_H = 12u; conv_cfg.out_W = 12u;
    conv_cfg.tile_count = 1u; conv_cfg.last_tile_valid_count = 150u;
    conv_cfg.threshold = LENET5_TH_CONV2; conv_cfg.sum_max = LENET5_SUMMAX_CONV2;
    conv_cfg.k = 5u; conv_cfg.stride = 2u; conv_cfg.pad = 0u; conv_cfg.pp_sel = 1u; conv_cfg.flatten_mode = 0u;
    if (v2b_run_conv_layer(&conv_cfg, conv2_layer, 12u * 12u) != 0) {
        uart_puts("[DBG] dense-input conv2 rc!=0\n");
        return;
    }

    if (v2b_run_conv_layer(fc1_cfg, fc1_layer, 9u) != 0) {
        uart_puts("[DBG] dense-input fc1 rc!=0\n");
        return;
    }
    v2b_dump_stream_rows32("dense_input_conv1_conv2_fc1_A", 0u);
}

void v2b_count_stream_spikes(int32_t *counts_out, uint32_t out_dim, uint32_t read_stream_b)
{
    for (uint32_t c = 0; c < out_dim; c++) counts_out[c] = 0;
    for (uint32_t t = 0; t < LENET5_T_COUNT; t++) {
        uint32_t row = read_stream_b ? V2B_SOC_READ_SBB(t) : V2B_SOC_READ_SBA(t);
        for (uint32_t c = 0; c < out_dim; c++) {
            if (row & (1u << c)) counts_out[c] += 1;
        }
    }
}

int v2b_run_lenet5_demo(const uint32_t *input_words,
                        int32_t *counts_out_10)
{
    (void)input_words;
    v2b_conv_layer_cfg_t cfg;
    const v2b_sparse_layer_t conv1_layer = {
        lenet5_conv1_offsets, lenet5_conv1_entries,
        LENET5_CONV1_TILE_COUNT, LENET5_CONV1_C_OUT, 25u, 1u
    };
    const v2b_sparse_layer_t conv2_layer = {
        lenet5_conv2_offsets, lenet5_conv2_entries,
        LENET5_CONV2_TILE_COUNT, LENET5_CONV2_C_OUT, 150u, 2u
    };
    const v2b_sparse_layer_t fc1_layer = {
        lenet5_fc1_offsets, lenet5_fc1_entries,
        LENET5_FC1_TILE_COUNT, LENET5_FC1_C_OUT, 256u, 3u
    };
    const v2b_sparse_layer_t fc2_layer = {
        lenet5_fc2_offsets, lenet5_fc2_entries,
        LENET5_FC2_TILE_COUNT, LENET5_FC2_C_OUT, 120u, 4u
    };
    const v2b_sparse_layer_t fc3_layer = {
        lenet5_fc3_offsets, lenet5_fc3_entries,
        LENET5_FC3_TILE_COUNT, LENET5_FC3_C_OUT, 84u, 5u
    };
    uint8_t err;

    (void)conv1_layer;

    uart_puts("[TB] LeNet conv1 bypass(ref) start\n");
    v2b_clear_stream_buffers();
    v2b_load_conv1_reference_for_sample(g_arm_current_sample_idx);

    g_arm_progress_code = 0x400u;
    g_arm_progress_aux0 = 144u;
    g_arm_progress_aux1 = 1u;
    g_arm_progress_aux2 = 2u;
    uart_puts("[TB] LeNet conv2 start\n");
    g_arm_progress_code = 0x401u;
    cfg.H = 28u; cfg.W = 28u; cfg.C_in = 6u; cfg.C_out = 16u;
    cfg.out_H = 12u; cfg.out_W = 12u; cfg.t_count = LENET5_T_COUNT;
    v2b_cfg_set_tile_fields(&cfg, 1u, 150u);
    v2b_cfg_set_word_fields(&cfg, LENET5_TH_CONV2, LENET5_SUMMAX_CONV2, 0u, 0u);
    cfg.k = 5u; cfg.stride = 2u; cfg.pad = 0u; cfg.pp_sel = 1u; cfg.flatten_mode = 0u;
    g_arm_progress_code = 0x402u;
    ARM_DSB_SY();
    if (v2b_run_conv_layer(&cfg, &conv2_layer, 12u * 12u) != 0) return -2;

    uart_puts("[TB] LeNet fc1(flatten) start\n");
    v2b_clear_stream_buffers();
    cfg.H = 12u; cfg.W = 12u; cfg.C_in = 16u; cfg.C_out = 120u;
    cfg.out_H = 1u; cfg.out_W = 1u;
    v2b_cfg_set_tile_fields(&cfg, 9u, 256u);
    v2b_cfg_set_word_fields(&cfg, LENET5_TH_FC1, LENET5_SUMMAX_FC1, 0u, 0u);
    cfg.k = 0u; cfg.stride = 1u; cfg.pad = 0u; cfg.pp_sel = 0u; cfg.flatten_mode = 1u;
    if (v2b_run_conv_layer(&cfg, &fc1_layer, 9u) != 0) return -3;

    uart_puts("[TB] LeNet fc2 start\n");
    v2b_switch_sparse_single_tile(&fc2_layer);
    err = v2b_run_fc_stage(120u, 84u, LENET5_TH_FC2, LENET5_SUMMAX_FC2,
                           V2B_SOC_BUF_SEL_STREAM_A, V2B_SOC_BUF_SEL_STREAM_B);
    if (err != 0u) return -4;

    uart_puts("[TB] LeNet fc3 start\n");
    v2b_switch_sparse_single_tile(&fc3_layer);
    err = v2b_run_fc_stage(84u, 10u, LENET5_TH_FC3, LENET5_SUMMAX_FC3,
                           V2B_SOC_BUF_SEL_STREAM_B, V2B_SOC_BUF_SEL_STREAM_A);
    if (err != 0u) return -5;

    v2b_clear_sparse_loaded_tile();
    v2b_count_stream_spikes(counts_out_10, 10u, 0u);
    g_lenet5_demo_call_count++;
    return 0;
}
