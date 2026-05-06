/*
 * fw/src/v2b_conv_scheduler.c — V2.B CONV 层调度器（v2-conv 分支主力）。
 *
 * 这个文件实现了 ARM 端按层串流跑 LeNet-5 的 5 步握手协议：
 *   1) 写完 STAGE_CFG1/2 + CONV_CFG_HW/C/K_S_P/OUT_HW/T/TILE/FMAP_BASE/OUT_BASE
 *      + MODE_CFG（启用 EN，必要时打开 FLATTEN_MODE / PP_SEL）
 *   2) 清 DONE：CONV_STATUS = DONE_MASK
 *   3) 启动：CONV_CTRL = START
 *   4) tile-by-tile 等硬件 WAIT_WEIGHT_REQ → 写权重 → 发 WEIGHT_READY，
 *      重复 requests_expected 次（每像素位置触发 1 次）
 *   5) 等 DONE 并查 ERR
 *
 * 关键依赖（运行时由 fw/arm/src/v2b_conv_scheduler_arm.c 通过 include
 * "golden_lenet5.h" 后再 include 本文件来满足）：
 *   - LENET5_T_COUNT / LENET5_TH_* / LENET5_SUMMAX_* / LENET5_*_C_OUT 等宏
 *   - lenet5_*_offsets / lenet5_*_entries 数组（每层 sparse 权重三元组）
 *
 * 外部 hook（由 ARM 主程序提供）：
 *   - uart_puts / uart_put_dec / uart_put_hex32：板上调试输出
 *   - g_arm_progress_code / aux0..aux2：JTAG 在卡死时通过 mrd 读出 firmware
 *     最近一次抵达的进度码，便于异常诊断；本文件大量埋点（0x100/0x200/0x3xx 等）
 */
#include <stdint.h>
#include "v2b_conv_scheduler.h"
#include "v2b_soc_regs.h"
#include "v2b_trace_hash.h"

#ifndef V2B_TRACE_HASH_HOST_NAME
#define V2B_TRACE_HASH_HOST_NAME "?"
#endif

#ifndef V2B_TRACE_HASH_CONFIG_LENET5
#define V2B_TRACE_HASH_CONFIG_LENET5 "v2b_lenet5_mnist_28x28"
#endif

#ifndef V2B_CONV_POLL_TIMEOUT
#define V2B_CONV_POLL_TIMEOUT 4000000u   /* 单次轮询的硬上限 ≈ 4M 次循环 */
#endif

#ifndef V2B_STREAM_BUF_CLEAR_GUARD_ITERS
#define V2B_STREAM_BUF_CLEAR_GUARD_ITERS 8192u   /* CLEAR 命令后的延迟保护 */
#endif

extern void uart_puts(const char *s);
/* G2 fix（2026-05-02）：统一为 uint32_t（arm uart_ps.c 与 e203 uart_printf_v2e203.c
 * 双侧实现都已对齐）。所有调用方都传递 size/count/tile_idx 等无符号值。 */
extern void uart_put_dec(uint32_t v);
extern void uart_put_hex32(uint32_t v);
/* JTAG 调试用：firmware 卡死时可以通过 mrd 直接读这些全局变量看走到哪一拍 */
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
static uint8_t g_trace_hash_sample_active = 0u;

static void v2b_stream_buf_clear_guard(void)
{
    for (volatile uint32_t i = 0; i < V2B_STREAM_BUF_CLEAR_GUARD_ITERS; i++) {
#if defined(__aarch64__)
        __asm__ volatile("nop");
#endif
    }
    ARM_DSB_SY();
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
    uint32_t written = 0u;
    g_arm_progress_code = 0x200u;
    g_arm_progress_aux0 = word_count;
    uart_puts("[TB] load_input_fmap_words start words=");
    uart_put_dec((uint32_t)word_count);
    uart_puts("\n");
    v2b_clear_fmap_words(word_count, target_bank);
    for (uint32_t i = 0; i < word_count; ) {
        while (i < word_count && words[i] == 0u) {
            g_arm_progress_aux1 = i;
            i++;
        }
        if (i >= word_count) {
            break;
        }
        g_arm_progress_code = 0x210u;
        g_arm_progress_aux1 = i;
        if (written == 0u) {
            uart_puts("[TB] load_input init ADDR\n");
        }
        V2B_SOC_CONV_FMAP_WR_ADDR = i;
        g_arm_progress_code = 0x211u;
        if (written == 0u) {
            uart_puts("[TB] load_input init ADDR done\n");
            uart_puts("[TB] load_input init CTRL\n");
        }
        V2B_SOC_CONV_FMAP_WR_CTRL = ctrl_cfg;
        g_arm_progress_code = 0x212u;
        if (written == 0u) {
            uart_puts("[TB] load_input init CTRL done\n");
        }
        while (i < word_count && words[i] != 0u) {
            g_arm_progress_code = 0x220u;
            g_arm_progress_aux1 = i;
            g_arm_progress_aux2 = written;
            if (written < 16u) {
                uart_puts("[TB] nz write src_idx=");
                uart_put_dec((uint32_t)i);
                uart_puts(" nz_idx=");
                uart_put_dec((uint32_t)written);
                uart_puts(" data=");
                uart_put_hex32(words[i]);
                uart_puts("\n");
            }
            V2B_SOC_CONV_FMAP_WR_DATA = words[i];
            g_arm_progress_code = 0x221u;
            V2B_SOC_CONV_FMAP_WR_CTRL = ctrl_cfg | V2B_SOC_CONV_FMAP_WR_COMMIT;
            g_arm_progress_code = 0x222u;
            if (written < 16u) {
                uart_puts("[TB] nz write done idx=");
                uart_put_dec((uint32_t)written);
                uart_puts("\n");
            }
            i++;
            written++;
        }
        if ((written >= 8u && (written & 7u) == 0u) || i >= word_count) {
            uart_puts("[TB] load_input_fmap_words nz-progress=");
            uart_put_dec((uint32_t)written);
            uart_puts("\n");
        }
    }
    g_arm_progress_code = 0x2FFu;
    g_arm_progress_aux2 = written;
    uart_puts("[TB] load_input_fmap_words done nz=");
    uart_put_dec((uint32_t)written);
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

static uint8_t v2b_wait_fc_stage_done_fresh(void)
{
    uint32_t guard = 0u;
    while (guard < V2B_CONV_POLL_TIMEOUT) {
        uint32_t ctrl = V2B_SOC_STAGE_CTRL;
        if ((ctrl & V2B_SOC_STAGE_CTRL_DONE) != 0u) {
            uint8_t err = (uint8_t)V2B_SOC_STAGE_ERR(V2B_SOC_STAGE_STATUS);
            V2B_SOC_STAGE_CTRL = V2B_SOC_STAGE_CTRL_DONE;
            return err;
        }
        guard++;
    }
    return 0xFEu;
}

/*
 * 跑一层 conv（也支持 flatten 层）：
 *   - cfg 携带 H/W/C_in/C_out/k/stride/pad/out_H/out_W/t_count/tile_count/threshold/sum_max/...
 *   - layer 携带 sparse 权重三元组（每个 tile 一段）
 *   - requests_expected：硬件总共会发出多少次 WAIT_WEIGHT_REQ
 *     · conv 层：(out_H × out_W) 次（每像素位置请求一次）
 *     · flatten 层：tile_count 次（每个 tile 请求一次）
 *
 * 返回值：0 = 成功；负数 = 错误码（-10=weight req 超时，-11=DONE 超时，
 *         -100-err = CONV_STATUS 报告的硬件错误码 err）
 */
int v2b_run_conv_layer(const v2b_conv_layer_cfg_t *cfg,
                       const v2b_sparse_layer_t *layer,
                       uint32_t requests_expected)
{
    uint8_t trace_open = 0u;
    /* 拼 MODE_CFG：始终打开 EN；
     *   FLATTEN_MODE：fc1 用，把 conv 输出按 row-major (h*W+w)*C+c 平铺给 stage_engine
     *   FMAP_PP_SEL：选 ping/pong bank（stride>1 等需要写到另一个 bank 的层用） */
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
    if (g_trace_hash_sample_active) {
        v2b_trace_hash_enable((uint8_t)(layer->layer_id - 1u));
        trace_open = 1u;
    }
    V2B_SOC_CONV_CTRL = V2B_SOC_CONV_CTRL_START;
    g_arm_progress_code = 0x30Fu;
    uart_puts("[TB] conv start reqs=");
    uart_put_dec((uint32_t)requests_expected);
    uart_puts(" tiles=");
    uart_put_dec((uint32_t)cfg->tile_count);
    uart_puts("\n");

    for (uint32_t req = 0; req < requests_expected; req++) {
        uint32_t status = 0u;
        if (v2b_wait_weight_req(&status) != 0) {
            if (trace_open) v2b_trace_hash_disable();
            return -10;
        }
        uint32_t tile_idx = V2B_SOC_CONV_STATUS_CUR_TILE(status);
        v2b_switch_sparse_tile(layer, (uint16_t)tile_idx);
        V2B_SOC_CONV_CTRL = V2B_SOC_CONV_CTRL_WEIGHT_READY;
        if ((req < 4u) || (((req + 1u) & 63u) == 0u) || ((req + 1u) == requests_expected)) {
            uart_puts("[TB] conv weight-ready req=");
            uart_put_dec((uint32_t)(req + 1u));
            uart_puts(" tile=");
            uart_put_dec((uint32_t)tile_idx);
            uart_puts(" status=");
            uart_put_hex32(status);
            uart_puts("\n");
        }
    }

    {
        uint32_t status = 0u;
        if (v2b_wait_conv_done(&status) != 0) {
            if (trace_open) v2b_trace_hash_disable();
            return -11;
        }
        uart_puts("[TB] conv done status=");
        uart_put_hex32(status);
        uart_puts("\n");
        if (trace_open) v2b_trace_hash_disable();
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
    V2B_SOC_STAGE_CTRL = V2B_SOC_STAGE_CTRL_DONE;
    V2B_SOC_STAGE_CTRL = V2B_SOC_STAGE_CTRL_START;
    return v2b_wait_fc_stage_done_fresh();
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

/*
 * 跑完整 LeNet-5 推理（conv1 → conv2 → fc1(flatten) → fc2 → fc3）。
 *
 * 参数：
 *   input_words：长度 LENET5_INPUT_WORDS 的 32-bit word 数组，packed 8-bit
 *                bitplane 后的 28×28×T 输入 fmap。由 Python encode_image_to_spike_fmap +
 *                pack_spike_fmap 生成，固化在 golden_lenet5.[hc] 里。
 *   counts_out_10：输出每类 spike count（10 维），调用方比对 expected_counts 即可。
 *
 * 返回值：0 = 全部 PASS；-1..-5 = 第 N 层失败（-1 conv1，-2 conv2，-3 fc1，-4 fc2，-5 fc3）
 *
 * 注意：fc2/fc3 走 v2b_run_fc_stage（标准 stage 路径，单 tile），其余走 conv 调度。
 *       fc1 是 flatten 层（tile_count=9，input_dim=2304），仍走 conv 调度但带 flatten_mode=1。
 */
int v2b_run_lenet5_demo(const uint32_t *input_words,
                        int32_t *counts_out_10)
{
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

    uart_puts("[TB] LeNet conv1 start\n");
    v2b_clear_stream_buffers();
    v2b_load_input_fmap_words(input_words, LENET5_INPUT_WORDS, 0u);

    cfg.H = 28u; cfg.W = 28u; cfg.C_in = 1u; cfg.C_out = 6u;
    cfg.out_H = 28u; cfg.out_W = 28u; cfg.t_count = LENET5_T_COUNT;
    v2b_cfg_set_tile_fields(&cfg, 1u, 25u);
    v2b_cfg_set_word_fields(&cfg, LENET5_TH_CONV1, LENET5_SUMMAX_CONV1, 0u, 0u);
    cfg.k = 5u; cfg.stride = 1u; cfg.pad = 2u; cfg.pp_sel = 0u; cfg.flatten_mode = 0u;
    if (v2b_run_conv_layer(&cfg, &conv1_layer, 28u * 28u) != 0) return -1;

    g_arm_progress_code = 0x400u;
    g_arm_progress_aux0 = 144u;
    g_arm_progress_aux1 = 1u;
    g_arm_progress_aux2 = 2u;
    uart_puts("[TB] LeNet conv2 start\n");
    g_arm_progress_code = 0x401u;
    cfg.H = 28u; cfg.W = 28u; cfg.C_in = 6u; cfg.C_out = 16u;
    cfg.out_H = 12u; cfg.out_W = 12u;
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
    if (g_trace_hash_sample_active) v2b_trace_hash_enable((uint8_t)(fc2_layer.layer_id - 1u));
    err = v2b_run_fc_stage(120u, 84u, LENET5_TH_FC2, LENET5_SUMMAX_FC2,
                           V2B_SOC_BUF_SEL_STREAM_A, V2B_SOC_BUF_SEL_STREAM_B);
    if (g_trace_hash_sample_active) v2b_trace_hash_disable();
    if (err != 0u) return -4;

    uart_puts("[TB] LeNet fc3 start\n");
    v2b_switch_sparse_single_tile(&fc3_layer);
    if (g_trace_hash_sample_active) v2b_trace_hash_enable((uint8_t)(fc3_layer.layer_id - 1u));
    err = v2b_run_fc_stage(84u, 10u, LENET5_TH_FC3, LENET5_SUMMAX_FC3,
                           V2B_SOC_BUF_SEL_STREAM_B, V2B_SOC_BUF_SEL_STREAM_A);
    if (g_trace_hash_sample_active) v2b_trace_hash_disable();
    if (err != 0u) return -5;

    v2b_clear_sparse_loaded_tile();
    v2b_count_stream_spikes(counts_out_10, 10u, 0u);
    return 0;
}

int v2b_run_lenet5_demo_trace(const uint32_t *input_words,
                              int32_t *counts_out_10,
                              uint32_t sample_id)
{
    int rc;

    g_trace_hash_sample_active = 1u;
    v2b_trace_hash_clear();
    rc = v2b_run_lenet5_demo(input_words, counts_out_10);
    v2b_trace_hash_disable();
    v2b_trace_hash_dump_uart(V2B_TRACE_HASH_CONFIG_LENET5,
                             V2B_TRACE_HASH_HOST_NAME,
                             sample_id);
    g_trace_hash_sample_active = 0u;
    return rc;
}
