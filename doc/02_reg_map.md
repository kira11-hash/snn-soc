# 02_reg_map

**参数口径**：寄存器默认值、位宽与地址映射以 `rtl/top/snn_soc_pkg.sv` 为准，若与文档不一致以 pkg 为准。

## reg_bank（base = 0x4000_0000）
| OFFSET | 名称 | 字段 | 位段 | 访问 | 默认 | 说明 |
|---:|---|---|---|---|---|---|
| 0x00 | NEURON_THRESHOLD | threshold | [31:0] | RW | THRESHOLD_DEFAULT | LIF 阈值 |
| 0x04 | TIMESTEPS | timesteps | [7:0] | RW | 8'd10 | 推理帧数（每帧含 PIXEL_BITS 子时间步，定版 T=10） |
| 0x08 | NUM_INPUTS | num_inputs | [15:0] | RO | 16'd64 | 输入维度（8x8 离线投影后特征） |
| 0x0C | NUM_OUTPUTS | num_outputs | [7:0] | RO | 8'd10 | 输出类别 |
| 0x10 | RESET_MODE | reset_mode | [0] | RW | 1'b0 | 0=soft reset, 1=hard reset |
| 0x14 | CIM_CTRL | START | [0] | W1P | 0 | 写 1 启动一次推理 |
| 0x14 | CIM_CTRL | SOFT_RESET | [1] | W1P | 0 | 写 1 触发软复位脉冲 |
| 0x14 | CIM_CTRL | DONE | [7] | W1C | 0 | 推理完成 sticky 标志，写 1 清零 |
| 0x18 | STATUS | BUSY | [0] | RO | 0 | 控制器忙标志 |
| 0x18 | STATUS | IN_FIFO_EMPTY | [1] | RO | 0 | 输入 FIFO 空 |
| 0x18 | STATUS | IN_FIFO_FULL | [2] | RO | 0 | 输入 FIFO 满 |
| 0x18 | STATUS | OUT_FIFO_EMPTY | [3] | RO | 0 | 输出 FIFO 空 |
| 0x18 | STATUS | OUT_FIFO_FULL | [4] | RO | 0 | 输出 FIFO 满 |
| 0x18 | STATUS | TIMESTEP_CNT | [15:8] | RO | 0 | 已完成帧计数 |
| 0x1C | OUT_FIFO_DATA | spike_id | [3:0] | RO | 0 | 读一次弹出一个 spike_id，空则返回 0 |
| 0x20 | OUT_FIFO_COUNT | count | [8:0] | RO | 0 | 输出 FIFO 当前计数（有效位 [8:0]，其余为 0） |
| 0x24 | THRESHOLD_RATIO | ratio | [7:0] | RW | 8'd4 | 阈值比例（4/255≈0.0157，定版 ratio_code），供固件计算绝对阈值 |
| 0x28 | ADC_SAT_COUNT | sat_high | [15:0] | RO | 0 | ADC 采样 == MAX (0xFF) 累计次数，每次推理自动清零 |
| 0x28 | ADC_SAT_COUNT | sat_low | [31:16] | RO | 0 | ADC 采样 == 0 累计次数，每次推理自动清零 |
| 0x2C | CIM_TEST | test_mode | [0] | RW | 0 | CIM 测试模式使能（1=旁路模拟宏，用数字假响应） |
| 0x2C | CIM_TEST | test_data_pos | [15:8] | RW | 0 | 测试模式下正通道（ch 0~9）bl_data 返回值（8-bit） |
| 0x2C | CIM_TEST | test_data_neg | [23:16] | RW | 0 | 测试模式下负通道（ch 10~19）bl_data 返回值（8-bit）；令 pos≠neg 使差分非零，可验证 LIF 全链路 |
| 0x30 | DBG_CNT_0 | dma_frame_cnt | [15:0] | RO | 0 | DMA 已完成 FIFO push 次数（16-bit 饱和） |
| 0x30 | DBG_CNT_0 | cim_cycle_cnt | [31:16] | RO | 0 | CIM busy 累计周期数（16-bit 饱和） |
| 0x34 | DBG_CNT_1 | spike_cnt | [15:0] | RO | 0 | LIF spike 总数（16-bit 饱和） |
| 0x34 | DBG_CNT_1 | wl_stall_cnt | [31:16] | RO | 0 | WL mux 重入告警次数（16-bit 饱和） |

说明：
- THRESHOLD 和 THRESHOLD_RATIO 为双寄存器模式：固件可读取 ratio 计算绝对阈值后写入 THRESHOLD，或直接写入绝对阈值。
- THRESHOLD_DEFAULT = THRESHOLD_RATIO_DEFAULT × (2^PIXEL_BITS - 1) × TIMESTEPS_DEFAULT = 4 × 255 × 10 = 10200（定版）。
- CIM_TEST：硅上测试模式。写 test_mode=1 后，数字侧生成 fake CIM/ADC 响应（cim_done 延迟 2 拍, adc_done 延迟 1 拍）；bl_data 按 bl_sel 分路返回：ch 0~9 返回 test_data_pos，ch 10~19 返回 test_data_neg；DAC 阶段仍按固定 `DAC_LATENCY_CYCLES` 时序运行（无 `dac_ready` 握手）。用于不依赖真实 RRAM 宏验证数字逻辑完整性。
- 推荐写法（全链路自检）：写 `test_mode=1, test_data_pos=100, test_data_neg=0`，Scheme B 差分 = 100，T=10 推理后 OUT_FIFO_COUNT 应明显非零（验证 DMA→FIFO→FSM→ADC→LIF→输出FIFO 全通路）。单写 `REG_CIM_TEST = 32'h0000_6401`（wstrb=4'b0111）即可同时配置三字段。
- 用途边界：CIM_TEST 仅用于时序/通路自检，不用于分类数值链路正确性验证（差分结果非真实权重，推理结果无意义）。
- DBG_CNT_0/1：16-bit 饱和计数器，仅 rst_n 清零。用于运行时诊断 DMA 搬运量、推理耗时、spike 输出量、WL mux 协议违规。

## dma_regs（base = 0x4000_0100）
| OFFSET | 名称 | 字段 | 位段 | 访问 | 默认 | 说明 |
|---:|---|---|---|---|---|---|
| 0x00 | DMA_SRC_ADDR | addr | [31:0] | RW | 0 | DMA 源地址（byte 地址，SoC 物理地址，需 4B 对齐） |
| 0x04 | DMA_LEN_WORDS | len | [31:0] | RW | 0 | 32-bit word 计数，必须为偶数且不越界 |
| 0x08 | DMA_CTRL | START | [0] | W1P | 0 | 写 1 启动 DMA |
| 0x08 | DMA_CTRL | DONE | [1] | W1C | 0 | DMA 完成 sticky 标志 |
| 0x08 | DMA_CTRL | ERR | [2] | W1C | 0 | DMA 错误 sticky 标志 |
| 0x08 | DMA_CTRL | BUSY | [3] | RO | 0 | DMA 忙标志（state != IDLE） |

## fifo_regs（base = 0x4000_0400）
| OFFSET | 名称 | 字段 | 位段 | 访问 | 默认 | 说明 |
|---:|---|---|---|---|---|---|
| 0x00 | IN_FIFO_COUNT | count | [8:0] | RO | 0 | 输入 FIFO 计数（有效位 [8:0]，其余为 0） |
| 0x04 | OUT_FIFO_COUNT | count | [8:0] | RO | 0 | 输出 FIFO 计数（有效位 [8:0]，其余为 0） |
| 0x08 | FIFO_STATUS | in_empty | [0] | RO | 0 | 输入 FIFO 空 |
| 0x08 | FIFO_STATUS | in_full | [1] | RO | 0 | 输入 FIFO 满 |
| 0x08 | FIFO_STATUS | out_empty | [2] | RO | 0 | 输出 FIFO 空 |
| 0x08 | FIFO_STATUS | out_full | [3] | RO | 0 | 输出 FIFO 满 |
