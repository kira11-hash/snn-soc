/*
 * fw/include/v2b_conv_scheduler.h
 *
 * V2.B CONV 扩展的 firmware 端调度器接口（ARM aarch64 与 E203 rv32 共用）。
 *
 * 概要：
 *   - 此头文件由 fw/src/v2b_conv_scheduler.c 实现，再被两条 host 路径 include：
 *       fw/arm/...                     ← ARM A53 路径（v2-arm-fpga-demo-conv）
 *       fw/v2_e203_smoke/...           ← E203 RV32 路径（v2-fpga-e203-conv）
 *   - 高层 API：v2b_run_lenet5_demo 一把跑完 5 层 LeNet-5；
 *               v2b_run_conv_layer / v2b_run_fc_stage 提供更细粒度的调度入口。
 *   - 权重以 sparse 三元组 (lane, out_c, packed4+4) 表示，由
 *     host-specific gen_lenet5_header.py 从 Python golden manifest
 *     直接生成，保证 firmware↔RTL↔Python golden 三方对齐。
 *
 * 重要约束：
 *   - 本头文件**不**包含 V1 main 的 register map；V1 路径有自己独立的
 *     fw/include/soc_regs.h。两侧不允许互相 include。
 *   - host 必须自带 uart_puts / uart_put_dec / uart_put_hex32 三个 helper，
 *     v2b_conv_scheduler.c 把它们当 extern 用。
 */
#ifndef V2B_CONV_SCHEDULER_H
#define V2B_CONV_SCHEDULER_H

#include <stdint.h>

/*
 * 单个 conv / flatten / FC 层的配置。所有字段都是 firmware 主动写入 V2B
 * MMIO 寄存器的源数据；scheduler 在调度时按硬件期望顺序拆这些字段写
 * STAGE_CFG{0..5} / CONV_CFG_*。
 */
typedef struct {
    uint16_t H;          /* 输入 fmap 行数 */
    uint16_t W;          /* 输入 fmap 列数 */
    uint16_t C_in;       /* 输入通道数 */
    uint16_t C_out;      /* 输出通道数 */
    uint16_t out_H;      /* 输出 fmap 行数（conv stride / pad 后）*/
    uint16_t out_W;      /* 输出 fmap 列数 */
    uint16_t t_count;    /* SNN 时间步数（LeNet-5 默认 10）*/
    uint16_t tile_count; /* 当前层 weight tile 数（fc1 = 9）*/
    uint16_t last_tile_valid_count; /* 最后一个 tile 内有效 lane 数 */
    uint32_t threshold;  /* LIF 阈值 */
    uint32_t sum_max;    /* ADC 满量程 sum，用于 RTL 内部归一化 */
    uint32_t fmap_base_word; /* 输入 fmap 在 fmap_sram 里的起始 word 偏移 */
    uint32_t out_base_word;  /* 输出 fmap 在 fmap_sram 里的起始 word 偏移 */
    uint8_t k;            /* conv kernel size（fc/flatten 设 0）*/
    uint8_t stride;       /* conv stride（fc/flatten 设 1）*/
    uint8_t pad;          /* conv padding（fc/flatten 设 0）*/
    uint8_t pp_sel;       /* fmap_sram ping-pong bank 选择（0/1）*/
    uint8_t flatten_mode; /* 1 = flatten FC 模式（仅 fc1 用）*/
} v2b_conv_layer_cfg_t;

/*
 * 一层 sparse 权重表。entries 内每 3 字节一组：(lane, out_c, packed)，其中
 * packed = (neg[3:0] << 4) | pos[3:0]，即 4-bit 正/4-bit 负电导编码。
 * offsets[i] / offsets[i+1] 圈出第 i 个 tile 在 entries 里的 [start, end)。
 */
typedef struct {
    const uint16_t *offsets;
    const uint8_t *entries; /* 三元组: lane, out_c, {neg[7:4],pos[3:0]} */
    uint16_t tile_count;
    uint16_t c_out;
    uint16_t last_tile_valid_count;
    uint16_t layer_id;      /* 上层 cache 键，用来在 (layer, tile) 命中时跳过重复装载 */
} v2b_sparse_layer_t;

/* 清空 stream_buffer A/B（每次推理新样本前调用，避免上一样本残留累加）*/
void v2b_clear_stream_buffers(void);

/* 把 32-bit packed input fmap word 数组逐个写入 fmap_sram 指定 bank。
 * 由于 fmap word 大量为 0，函数内部跳过 0 word 提速；并通过 V2B CONV_FMAP_WR_*
 * 寄存器组以 AUTO_INC 模式串行 commit。 */
void v2b_load_input_fmap_words(const uint32_t *words, uint32_t word_count, uint32_t target_bank);

/* 把上一次 v2b_switch_sparse_tile 装载到 MAC array 的 cell 全部清零 */
void v2b_clear_sparse_loaded_tile(void);

/* 把指定 layer / tile 的 sparse 权重装到 MAC array；命中缓存时直接 return */
void v2b_switch_sparse_tile(const v2b_sparse_layer_t *layer, uint16_t tile_idx);

/* 跑一层 conv（或 flatten 模式 FC）：写入 cfg → START → 循环
 * weight_req/weight_ready 握手 → 等 DONE。返回值：0 = OK，<0 = 错误码。 */
int v2b_run_conv_layer(const v2b_conv_layer_cfg_t *cfg,
                       const v2b_sparse_layer_t *layer,
                       uint32_t requests_expected);

/* 跑一层标准 FC stage（fc2/fc3 用）。返回 RTL 报上来的 err_code：0 = OK */
uint8_t v2b_run_fc_stage(uint32_t in_dim, uint32_t out_dim,
                         uint32_t threshold, uint32_t sum_max,
                         uint32_t input_src, uint32_t output_dst);

/* 从 stream_buf A 或 B 累加 spike count 到 counts_out[0..out_dim-1] */
void v2b_count_stream_spikes(int32_t *counts_out, uint32_t out_dim, uint32_t read_stream_b);

/* 一把跑完 LeNet-5 全 5 层（conv1 → conv2 → fc1 flatten → fc2 → fc3），
 * counts_out_10 输出最终 10 类 spike count；返回值：0 = OK，<0 = 错误码。 */
int v2b_run_lenet5_demo(const uint32_t *input_words,
                        int32_t *counts_out_10);

int v2b_run_lenet5_demo_trace(const uint32_t *input_words,
                              int32_t *counts_out_10,
                              uint32_t sample_id);

#endif /* V2B_CONV_SCHEDULER_H */
