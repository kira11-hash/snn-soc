# 02_reg_map

**版本**：v3.1（V2 编程脉冲宽度寄存器 + 全阵列擦除 bit）
**日期**：2026-04-18
**参数口径**：寄存器默认值、位宽与地址映射以 `rtl/top/snn_soc_pkg.sv` 为准，若与文档不一致以 pkg 为准。
**架构说明**：本文描述的寄存器全部位于**数字芯片**内部。数字芯片与模拟 CIM 芯片为独立封装，通过 PCB 互联（详见 `doc/08_cim_analog_interface.md`）。

## reg_bank（base = 0x4000_0000）
| OFFSET | 名称               | 字段             | 位段      | 访问  | 默认                | 说明                                                                       |
| -----: | ---------------- | -------------- | ------- | --- | ----------------- | ------------------------------------------------------------------------ |
|   0x00 | NEURON_THRESHOLD | threshold      | [31:0]  | RW  | THRESHOLD_DEFAULT | LIF 阈值                                                                   |
|   0x04 | TIMESTEPS        | timesteps      | [7:0]   | RW  | 8'd10             | 推理帧数（每帧含 PIXEL_BITS 子时间步，当前工程默认 T=10）                                    |
|   0x08 | NUM_INPUTS       | num_inputs     | [15:0]  | RO  | 16'd64            | 输入维度（默认 `avgpool8x8` 的 8x8 离线特征）                                         |
|   0x0C | NUM_OUTPUTS      | num_outputs    | [7:0]   | RO  | 8'd10             | 输出类别                                                                     |
|   0x10 | RESET_MODE       | reset_mode     | [0]     | RW  | 1'b0              | 0=soft reset, 1=hard reset                                               |
|   0x14 | CIM_CTRL         | START          | [0]     | W1P | 0                 | 写 1 启动一次推理                                                               |
|   0x14 | CIM_CTRL         | SOFT_RESET     | [1]     | W1P | 0                 | 写 1 触发软复位脉冲                                                              |
|   0x14 | CIM_CTRL         | DONE           | [7]     | W1C | 0                 | 推理完成 sticky 标志，写 1 清零                                                    |
|   0x18 | STATUS           | BUSY           | [0]     | RO  | 0                 | 控制器忙标志                                                                   |
|   0x18 | STATUS           | IN_FIFO_EMPTY  | [1]     | RO  | 0                 | 输入 FIFO 空                                                                |
|   0x18 | STATUS           | IN_FIFO_FULL   | [2]     | RO  | 0                 | 输入 FIFO 满                                                                |
|   0x18 | STATUS           | OUT_FIFO_EMPTY | [3]     | RO  | 0                 | 输出 FIFO 空                                                                |
|   0x18 | STATUS           | OUT_FIFO_FULL  | [4]     | RO  | 0                 | 输出 FIFO 满                                                                |
|   0x18 | STATUS           | SPIKE_Q_OVERFLOW | [6]   | RO  | 0                 | spike 队列溢出 sticky 标志（soft_reset 清零）                                      |
|   0x18 | STATUS           | TIMESTEP_CNT   | [15:8]  | RO  | 0                 | 已完成帧计数                                                                   |
|   0x1C | OUT_FIFO_DATA    | spike_id       | [6:0]   | RO  | 0                 | 读一次弹出一个 spike_id（$clog2(MAX_NEURONS)=7 位），空则返回 0（边沿检测 pop：一次总线读请求只触发一次 FIFO 弹出，即使 req_valid 保持多拍）。V1 单层时 id 范围 0~9；V2 多层时可达 0~127 |
|   0x20 | OUT_FIFO_COUNT   | count          | [12:0]  | RO  | 0                 | 输出 FIFO 当前计数（有效位 [12:0]，其余为 0；默认深度 4096）                                 |
|   0x24 | THRESHOLD_RATIO  | ratio          | [7:0]   | RW  | 8'd1              | 阈值比例（1/255≈0.00392，定版 ratio_code），供固件计算绝对阈值                              |
|   0x28 | ADC_SAT_COUNT    | sat_high       | [15:0]  | RO  | 0                 | ADC 采样 == MAX (0xFF) 累计次数，CIM_CTRL.START 脉冲自动清零（见下方说明）                   |
|   0x28 | ADC_SAT_COUNT    | sat_low        | [31:16] | RO  | 0                 | ADC 采样 == 0 累计次数，CIM_CTRL.START 脉冲自动清零（见下方说明）                            |
|   0x2C | CIM_TEST         | test_mode      | [0]     | RW  | 0                 | CIM 测试模式使能（1=旁路模拟宏，用数字假响应）                                               |
|   0x2C | CIM_TEST         | test_data_pos  | [15:8]  | RW  | 0                 | 测试模式下正通道（ch 0~9）bl_data 返回值（8-bit）                                       |
|   0x2C | CIM_TEST         | test_data_neg  | [23:16] | RW  | 0                 | 测试模式下负通道（ch 10~19）bl_data 返回值（8-bit）；令 pos≠neg 使差分非零，可验证 LIF 全链路         |
|   0x30 | DBG_CNT_0        | dma_frame_cnt  | [15:0]  | RO  | 0                 | DMA 已完成 FIFO push 次数（16-bit 饱和）                                          |
|   0x30 | DBG_CNT_0        | cim_cycle_cnt  | [31:16] | RO  | 0                 | CIM busy 累计周期数（16-bit 饱和）                                                |
|   0x34 | DBG_CNT_1        | spike_cnt      | [15:0]  | RO  | 0                 | LIF spike 总数（16-bit 饱和）                                                  |
|   0x34 | DBG_CNT_1        | wl_stall_cnt   | [31:16] | RO  | 0                 | WL mux 重入告警次数（16-bit 饱和）                                                 |

说明：
- THRESHOLD 和 THRESHOLD_RATIO 为双寄存器模式：固件可读取 ratio 计算绝对阈值后写入 THRESHOLD，或直接写入绝对阈值。
- THRESHOLD_DEFAULT = THRESHOLD_RATIO_DEFAULT × (2^PIXEL_BITS - 1) × TIMESTEPS_DEFAULT = 1 × 255 × 10 = 2550（当前工程默认）。
- CIM_TEST：硅上测试模式。写 test_mode=1 后，数字侧生成 fake CIM/ADC 响应（cim_done 延迟 2 拍, adc_done 延迟 1 拍）；bl_data 按 bl_sel 分路返回：ch 0~9 返回 test_data_pos，ch 10~19 返回 test_data_neg；DAC 阶段仍按固定 `DAC_LATENCY_CYCLES` 时序运行（无 `dac_ready` 握手）。用于不依赖真实 RRAM 宏验证数字逻辑完整性。
- 推荐写法（全链路自检）：写 `test_mode=1, test_data_pos=100, test_data_neg=0`，Scheme B 差分 = 100；按当前默认 `T=10` 推理后 `OUT_FIFO_COUNT` 应明显非零（验证 DMA→FIFO→FSM→ADC→LIF→输出FIFO 全通路）。若只想做更快冒烟，也可先将 `TIMESTEPS` 软件写成更小值。单写 `REG_CIM_TEST = 32'h0000_6401`（wstrb=4'b0111）即可同时配置三字段。
- 用途边界：CIM_TEST 仅用于时序/通路自检，不用于分类数值链路正确性验证（差分结果非真实权重，推理结果无意义）。**双芯片 bring-up 场景下，CIM_TEST 是验证数字芯片独立工作的首选手段**——不需要模拟芯片即可确认数字链路完整性。
- ADC_SAT_COUNT 清零时机：每次写 `CIM_CTRL.START=1` 启动新一轮推理时，硬件自动将 `sat_high` 和 `sat_low` 归零（`cim_array_ctrl` 在 `start_pulse` 时执行清零）。因此每次推理结束后读到的值仅反映**本轮推理**期间的饱和采样数。计数器为 16-bit，最大值 65535（饱和，不回绕）。`rst_n` 也会清零。
- DBG_CNT_0/1：16-bit 饱和计数器，仅 rst_n 清零。用于运行时诊断 DMA 搬运量、推理耗时、spike 输出量、WL mux 协议违规。
- OUT_FIFO_DATA 的 pop 机制（2026-03-15 修复）：采用**边沿检测**——`reg_bank.sv` 内部用 `out_data_read_seen` 标志确保一次总线读请求只触发一次 FIFO 弹出。此修复解决了原电平检测方案下 `bus_read()` task 的 `m_valid` 保持 2 拍导致多次 pop 的问题（Step 3.4 根因）。

### V2 CIM 编程寄存器（0x38~0x44）

> 以下寄存器由 V2 `cim_program_ctrl` 模块消费，用于 RRAM 阵列的写入/擦除/验证操作。V1 流片不使用。

| OFFSET | 名称 | 字段 | 位段 | 访问 | 默认 | 说明 |
|---:|---|---|---|---|---|---|
| 0x38 | PROG_CTRL | START | [0] | W1P | 0 | 写 1 启动一次编程/擦除/验证操作 |
| 0x38 | PROG_CTRL | ERASE | [1] | RW | 0 | 0=写入(SET)，1=擦除(RESET) |
| 0x38 | PROG_CTRL | FULL_ARRAY | [2] | RW | 0 | 全阵列擦除模式（1=所有 WL 同时拉高，单脉冲擦除，跳过 verify） |
| 0x38 | PROG_CTRL | LEVEL | [7:4] | RW | 0 | 4-bit 目标电导等级（0~15） |
| 0x38 | PROG_CTRL | RETRY_LIMIT | [10:8] | RW | 3'd4 | 最大重试次数（0~7） |
| 0x3C | PROG_ROW | row | [5:0] | RW | 0 | 目标行地址（0~63） |
| 0x40 | PROG_COL | col | [4:0] | RW | 0 | 目标列地址（0~19） |
| 0x44 | PROG_STATUS | BUSY | [0] | RO | 0 | 编程控制器忙 |
| 0x44 | PROG_STATUS | PASS | [1] | RO | 0 | 上次操作通过（验证成功） |
| 0x44 | PROG_STATUS | FAIL | [2] | RO | 0 | 上次操作失败（重试耗尽） |
| 0x44 | PROG_STATUS | RETRY_COUNT | [5:3] | RO | 0 | 上次操作实际重试次数 |
| 0x44 | PROG_STATUS | DONE | [7] | W1C | 0 | 编程完成 sticky 标志，写 1 清零 |

### V2 编程脉冲宽度寄存器（0x90~0x94）

> 以下寄存器控制 `cim_program_ctrl` 的编程/擦除脉冲持续时间（时钟周期数）。V1 流片不使用。

| OFFSET | 名称 | 字段 | 位段 | 访问 | 默认 | 说明 |
|---:|---|---|---|---|---|---|
| 0x90 | PROG_PULSE_WIDTH | pulse_width | [15:0] | RO | 16'd50 | 当前写入脉冲宽度（resolved cycles） |
| 0x90 | PROG_PULSE_WIDTH | write_pulse_sel | [17:16] | RW | 2'd0 | 写入脉冲档位：0=1us(50 cyc), 1=10us(500 cyc), 2=100us(5000 cyc), 3=保留/按100us处理 |
| 0x94 | PROG_ERASE_WIDTH | erase_width | [15:0] | RO | 16'd50000 | 擦除脉冲宽度固定 1ms @ 50MHz；写入此寄存器被忽略 |

说明：
- `PROG_PULSE_WIDTH`：写 `write_pulse_sel` 选择逐 cell 写入（SET）脉冲宽度。只允许 1us / 10us / 100us 三档，避免固件写出任意危险脉宽。读回时低 16 位为实际 cycle 数，高位 [17:16] 为选择档位。
- `PROG_ERASE_WIDTH`：逐 cell 擦除与全阵列擦除都强制使用 50000 cycles = 1ms @ 50MHz。该寄存器只读；写入会被硬件忽略。
- 脉冲由数字侧自计时（`ST_PULSE_HOLD` 倒计时），不依赖 `cim_done` 握手返回。

### V2 多层控制寄存器（0x48~0x8F）

> 以下寄存器由 V2 `layer_sequencer` 模块消费，支持最多 4 层 SNN 推理。需要 `+define+SIM_MULTI_LAYER` 编译开关。V1 单层推理不使用。

| OFFSET | 名称 | 字段 | 位段 | 访问 | 默认 | 说明 |
|---:|---|---|---|---|---|---|
| 0x48 | ML_CTRL | num_layers | [1:0] | RW | 0 | 层数 - 1（0=1层，1=2层，...，3=4层） |
| 0x48 | ML_CTRL | enable | [8] | RW | 0 | 多层使能（1=启用 layer_sequencer） |

**层描述符**：每层占 4 个 32-bit 寄存器（16 字节），Layer N 基地址 = `0x50 + N × 0x10`。

| 层内偏移 | 名称 | 字段 | 位段 | 访问 | 说明 |
|---:|---|---|---|---|---|
| +0x00 | LAYER_CFG | wl_offset | [7:0] | RW | WL 起始偏移（**D1-007**：当前 RTL 未使用，为未来硬件 sub-array 多层保留字段。V2 时间多层由固件全阵列操作，不需要 offset） |
| +0x00 | LAYER_CFG | wl_count | [15:8] | RW | WL 数量（本层输入维度，如 64）|
| +0x00 | LAYER_CFG | bl_offset | [23:16] | RW | BL 起始偏移（**D1-007**：同 wl_offset，当前保留） |
| +0x00 | LAYER_CFG | bl_count | [31:24] | RW | 本层扫描的 BL 通道数（Scheme B 含正负列）。有效范围为偶数 2~`MAX_BL_SCAN`=128；差分后输出维度 = bl_count/2。超出 2~128 时 adc_ctrl 会安全钳位回 V1 默认 20；固件应避免配置奇数 bl_count |
| +0x04 | LAYER_TIMING | timesteps | [7:0] | RW | 本层时间步数 |
| +0x04 | LAYER_TIMING | use_bitplane | [8] | RW | 1=bit-plane 编码输入，0=binary spike 输入 |
| +0x08 | LAYER_THRESHOLD | threshold | [31:0] | RW | 本层 LIF 阈值 |
| +0x0C | LAYER_NEURON_CFG | neuron_count | [7:0] | RW | 本层活跃神经元数量 |

**层描述符绝对地址映射**：

| Layer | CFG | TIMING | THRESHOLD | NEURON_CFG |
|---|---|---|---|---|
| 0 | 0x50 | 0x54 | 0x58 | 0x5C |
| 1 | 0x60 | 0x64 | 0x68 | 0x6C |
| 2 | 0x70 | 0x74 | 0x78 | 0x7C |
| 3 | 0x80 | 0x84 | 0x88 | 0x8C |

## dma_regs（base = 0x4000_0100）
| OFFSET | 名称 | 字段 | 位段 | 访问 | 默认 | 说明 |
|---:|---|---|---|---|---|---|
| 0x00 | DMA_SRC_ADDR | addr | [31:0] | RW | 0 | DMA 源地址（byte 地址，SoC 物理地址，需 4B 对齐） |
| 0x04 | DMA_LEN_WORDS | len | [31:0] | RW | 0 | 32-bit word 计数（DST_INPUT_FIFO 要求偶数；WEIGHT/INSTR 允许奇数），不越界 |
| 0x08 | DMA_CTRL | START | [0] | W1P | 0 | 写 1 启动 DMA |
| 0x08 | DMA_CTRL | DONE | [1] | W1C | 0 | DMA 完成 sticky 标志 |
| 0x08 | DMA_CTRL | ERR | [2] | W1C | 0 | DMA 错误 sticky 标志 |
| 0x08 | DMA_CTRL | BUSY | [3] | RO | 0 | DMA 忙标志（state != IDLE） |
| 0x0C | DMA_DST_SEL | dst_sel | [1:0] | RW | 0 | DMA 目标选择：0=INPUT_FIFO（默认，64-bit 拼接 push），1=WEIGHT_SRAM，2=INSTR_SRAM；3=非法（START 时直接报 ERR）；仅 IDLE 时可写 |

## fifo_regs（base = 0x4000_0400）
| OFFSET | 名称 | 字段 | 位段 | 访问 | 默认 | 说明 |
|---:|---|---|---|---|---|---|
| 0x00 | IN_FIFO_COUNT | count | [8:0] | RO | 0 | 输入 FIFO 计数（有效位 [8:0]，其余为 0） |
| 0x04 | OUT_FIFO_COUNT | count | [12:0] | RO | 0 | 输出 FIFO 计数（有效位 [12:0]，其余为 0；默认深度 4096） |
| 0x08 | FIFO_STATUS | in_empty | [0] | RO | 0 | 输入 FIFO 空 |
| 0x08 | FIFO_STATUS | in_full | [1] | RO | 0 | 输入 FIFO 满 |
| 0x08 | FIFO_STATUS | out_empty | [2] | RO | 0 | 输出 FIFO 空 |
| 0x08 | FIFO_STATUS | out_full | [3] | RO | 0 | 输出 FIFO 满 |
