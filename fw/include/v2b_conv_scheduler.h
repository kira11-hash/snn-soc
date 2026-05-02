#ifndef V2B_CONV_SCHEDULER_H
#define V2B_CONV_SCHEDULER_H

/*
 * V2.B CONV 层调度器对外 API（v2-conv 分支）。
 *
 * 客户端：fw/arm/src/arm_main.c → v2b_run_lenet5_demo → 内部串起 5 层。
 * 实现：fw/src/v2b_conv_scheduler.c。
 */

#include <stdint.h>

/* 单层 conv / flatten 配置：H/W 是输入空间维度，out_H/out_W 是输出维度，
 * C_in/C_out 是通道数；threshold + sum_max 用于 LIF + ADC 量化；
 * t_count 是子时间步（LeNet-5 默认 10）。 */
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
    uint8_t pp_sel;       /* ping-pong bank 选择，stride>1 等场景需要切 bank */
    uint8_t flatten_mode; /* 1 = flatten 层（fc1），0 = conv 层 */
} v2b_conv_layer_cfg_t;

/* 稀疏权重表：每 tile 一段连续 entries，offsets[i]..offsets[i+1] 是 tile i 的范围。
 * entries 是打包的三元组 (lane, out_c, {neg[7:4], pos[3:0]})——每个非零权重一条。
 * 这种打包方式让 fc1 (9 tiles × 256 × 120) 这种大层能塞进 OCM。 */
typedef struct {
    const uint16_t *offsets;
    const uint8_t *entries; /* 打包三元组：lane / out_c / {neg[7:4], pos[3:0]} */
    uint16_t tile_count;
    uint16_t c_out;
    uint16_t last_tile_valid_count;
    uint16_t layer_id;
} v2b_sparse_layer_t;

/* 清 stream buffer A/B（layer 之间切换前调用，避免上一层残留） */
void v2b_clear_stream_buffers(void);

/* 把输入 fmap word 数组通过 CONV_FMAP_WR_* 寄存器组写进 fmap SRAM。
 * 仅写入非零 word 以节省 AXI 事务数；首次写入会先把整段 word 段清零防残留。 */
void v2b_load_input_fmap_words(const uint32_t *words, uint32_t word_count, uint32_t target_bank);

/* 清掉之前 v2b_switch_sparse_tile 装进 MAC 的 weight（写 0 覆盖） */
void v2b_clear_sparse_loaded_tile(void);

/* 把 layer 的 tile_idx 段权重写进 MAC 权重存储区；同 layer 同 tile 已加载会快速 return */
void v2b_switch_sparse_tile(const v2b_sparse_layer_t *layer, uint16_t tile_idx);

/* 跑一层 conv 或 flatten：详见 .c 文件函数注释 */
int v2b_run_conv_layer(const v2b_conv_layer_cfg_t *cfg,
                       const v2b_sparse_layer_t *layer,
                       uint32_t requests_expected);

/* 跑一层标准 stage（fc 用，单 tile，不走 conv 调度）。返回硬件 ERR 字段 */
uint8_t v2b_run_fc_stage(uint32_t in_dim, uint32_t out_dim,
                         uint32_t threshold, uint32_t sum_max,
                         uint32_t input_src, uint32_t output_dst);

/* 把 stream_buf_A 或 stream_buf_B 的 spike 按时间步累加成 counts 向量 */
void v2b_count_stream_spikes(int32_t *counts_out, uint32_t out_dim, uint32_t read_stream_b);

/* 顶层入口：按 LeNet-5 拓扑跑完整推理。返回 0=PASS，负数=失败层号 */
int v2b_run_lenet5_demo(const uint32_t *input_words,
                        int32_t *counts_out_10);

#endif /* V2B_CONV_SCHEDULER_H */
