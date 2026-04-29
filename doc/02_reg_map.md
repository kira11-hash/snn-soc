# 02_reg_map

**版本**：v2.1
**日期**：2026-03-16
**参数口径**：寄存器默认值、位宽与地址映射以 `rtl/top/snn_soc_pkg.sv` 为准，若与文档不一致以 pkg 为准。
**架构说明**：本文描述的寄存器全部位于**数字芯片**内部。数字芯片与模拟 CIM 芯片为独立封装，通过 PCB 互联（详见 `doc/08_cim_analog_interface.md`）。

## Memory Map Overview

`main` 当前同时保留两种指令地址图口径：

- `snn_soc_top.ENABLE_BOOT_ROM=0`（默认，Gate A / 旧回归）
  `INSTR_SRAM @ 0x0000_0000..0x0000_3FFF`
- `chip_top.ENABLE_BOOT_ROM=1`（tape-out 目标）
  `BOOT_ROM   @ 0x0000_0000..0x0000_0FFF`
  `INSTR_SRAM @ 0x0000_1000..0x0000_4FFF`

其他区段不变：

- `DATA_SRAM   @ 0x0001_0000..0x0001_3FFF`
- `WEIGHT_SRAM @ 0x0003_0000..0x0003_3FFF`
- `reg_bank    @ 0x4000_0000`
- `dma_regs    @ 0x4000_0100`
- `uart_ctrl   @ 0x4000_0200`
- `spi_ctrl    @ 0x4000_0300`
- `fifo_regs   @ 0x4000_0400`

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
|   0x18 | STATUS           | TIMESTEP_CNT   | [15:8]  | RO  | 0                 | 已完成帧计数                                                                   |
|   0x1C | OUT_FIFO_DATA    | spike_id       | [3:0]   | RO  | 0                 | 读一次弹出一个 spike_id，空则返回 0（边沿检测 pop：一次总线读请求只触发一次 FIFO 弹出，即使 req_valid 保持多拍） |
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

### CIM 编程寄存器（2026-04-22 从 v2 分支移植）

仅在 `snn_soc_top.ENABLE_PROGRAM_MODE=1` 时由 `cim_program_ctrl` + `cim_macro_arbiter` 真正消费；默认参数下寄存器依然存在但不会触发任何硬件副作用（arbiter 和编程控制器都被 gen 块跳过）。

**外部编程 pad 映射（2026-04-24，方案 α'）**：tape-out 路径
（`chip_top.ENABLE_EXT_CIM_IF=1`）下这些寄存器的硬件副作用会经过 7 个新增
pad（`prog_op[2:0]` + `prog_level[3:0]`，pads 46..52）传递给模拟 die：
- `PROG_CTRL.ERASE / FULL_ARRAY` + `cim_program_ctrl` 的 `prog_en / erase_en /
  verify_en` 共同编码为 `prog_op_raw[2:0]`，经 10-stage pipeline 延迟后由
  `prog_op_ext[2:0]` 输出（见 `rtl/top/snn_soc_top.sv` 编码器逻辑）。
- `PROG_CTRL.LEVEL[7:4]` 经同一 10-stage pipeline 到 `prog_level_ext[3:0]`，
  与 `prog_op_ext` 相位对齐。
- `cim_start_ext` 在 `prog_busy=1` 时为 LEVEL-hold gate（由
  `prog_dac_valid | verify_en_dly1` 延迟 10 拍驱动），覆盖整个 pulse/verify
  窗口；模拟侧按电平而非边沿驱动 pulse driver（Q1 锁定）。
- 详细跨芯片协议 + Q1/Q2/Q3 不变量见 `doc/08_cim_analog_interface.md` §10 +
  `doc/03_cim_if_protocol.md` "编程协议" 节 + `doc/15_asic_pad_map.md` pads 46..52。

| OFFSET | 名称 | 字段 | 位段 | 访问 | 默认 | 说明 |
|---:|---|---|---|---|---|---|
| 0x38 | PROG_CTRL | START | [0] | W1P | 0 | 启动一次编程/擦除序列；仅 `ENABLE_PROGRAM_MODE=1` 时生效，推理 busy/pending 或编程自 busy 期间被硬件 interlock 屏蔽 |
| 0x38 | PROG_CTRL | ERASE | [1] | RW¹ | 0 | 0=写入(SET)，1=擦除(RESET) |
| 0x38 | PROG_CTRL | FULL_ARRAY | [2] | RW¹ | 0 | 仅 ERASE=1 生效：1=所有 WL 同时拉高并跳过 verify |
| 0x38 | PROG_CTRL | BYPASS_HANDSHAKE | [3] | RW¹ | 0 | **Silicon bring-up 专用**：1=绕过 `prog_adc_done` 等待，verify 始终 PASS（用 ideal readback）；用于模拟 die 缺失时的数字自检，生产固件必须保持 0 |
| 0x38 | PROG_CTRL | LEVEL | [7:4] | RW¹ | 0 | 目标电导等级（0~15，对应 4-bit 权重量化） |
| 0x38 | PROG_CTRL | RETRY_LIMIT | [10:8] | RW¹ | 4 | verify 失败最大重试次数（0~7）。⚠️ 整字写 PROG_CTRL 时 byte1=0 会清零此字段；fw 应使用 read-modify-write 或显式置 4u<<8 以保留默认值。 |
| 0x3C | PROG_ROW | row | [5:0] | RW¹ | 0 | 目标行（0~63，= WL/NUM_INPUTS 索引） |
| 0x40 | PROG_COL | col | [4:0] | RW¹ | 0 | 目标列（0~19，= ADC 通道索引） |
| 0x44 | PROG_STATUS | BUSY | [0] | RO | 0 | 编程控制器忙（FSM 非 IDLE） |
| 0x44 | PROG_STATUS | PASS | [1] | RO | 0 | 上次序列验证通过 |
| 0x44 | PROG_STATUS | FAIL | [2] | RO | 0 | 上次序列重试耗尽失败 |
| 0x44 | PROG_STATUS | RETRY_COUNT | [5:3] | RO | 0 | 上次序列实际重试次数 |
| 0x44 | PROG_STATUS | PROG_FSM_PRESENT | [6] | RO | ENABLE_PROGRAM_MODE | 1 = `cim_program_ctrl` 已实例化（编译期常量）；0 = 编程 FSM 未实现，PROG_CTRL.START 是 no-op。fw 用此位代替 cycle-bound BUSY 探测以避免 fast-pulse race。 |
| 0x44 | PROG_STATUS | DONE | [7] | W1C | 0 | 编程完成 sticky（软件写 1 清零） |
| 0x90 | PROG_PULSE_WIDTH | pulse_width | [15:0] | RO | 50 | 当前写入脉冲 resolved cycles（档位解码后的值） |
| 0x90 | PROG_PULSE_WIDTH | write_pulse_sel | [17:16] | RW¹ | 0 | 写入脉冲档位：0=1us(50), 1=10us(500), 2=100us(5000), 3=保留（按 100us 处理，防止误写 1ms SET 脉冲） |
| 0x94 | PROG_ERASE_WIDTH | erase_width | [15:0] | RO | 50000 | 擦除脉冲宽度固定 1ms @ 50MHz（逐 cell 与全阵列擦除共用，写入此寄存器被忽略） |

> ¹ **In-flight 写锁（2026-04-25 CRITICAL fix）**：标记为 `RW¹` 的所有 config 字段
> 在 `prog_busy=1 || prog_start_pending=1 || prog_start_pulse=1` 时**写入会被
> reg_bank 静默忽略**。原因：snn_soc_top 的外部 pad 编码器（`prog_op_ext` /
> `prog_level_ext`）使用这些寄存器的 LIVE 值 + 10-stage pipeline；若允许 in-flight
> 改写，10 拍后 pad 上的 op/level 会与 cim_program_ctrl 内部锁存值不一致，
> 数字侧与模拟 die 接口将出现窗口期 inconsistency。锁仅在 `ENABLE_PROGRAM_MODE=1`
> 时生效；FSM 不实例化时所有字段均可任意 RW。`PROG_STATUS.DONE`（W1C）和
> `PROG_CTRL.START`（W1P，已有三重守卫）不受此锁影响。覆盖：`tb/prog_inflight_lock_tb.sv`。

**为什么写入是档位而不是自由脉宽？** RRAM 器件编程窗口未标定，留三档供实验标定；擦除固定 1ms 防止误写短脉冲烧伤器件。

**两条路径互锁（reg_bank 三重守卫实现，2026-04-22 Q2 修复）**：

每条 START 写入都检查 3 个条件：

- `!{peer}_busy`：对侧 FSM 不处于 busy（稳态互锁）
- `!{peer}_start_pending`：近期发过对侧 start_pulse 但对侧 busy 还没升起（多拍 downstream 延迟容忍）
- `!{peer}_start_pulse`：本拍 reg_bank 同时在接受对侧的 START W1P（最激进的 back-to-back 情形）

即：
- 写 `CIM_CTRL.START=1` 在 `ENABLE_PROGRAM_MODE=1` 时要求
  `!prog_busy && !prog_start_pending && !prog_start_pulse`；在
  `ENABLE_PROGRAM_MODE=0` 时编程侧不存在，`prog_*` 守卫等价旁路。
- 写 `PROG_CTRL.START=1` 要求
  `ENABLE_PROGRAM_MODE && !snn_busy && !snn_start_pending && !start_pulse
  && !prog_busy && !prog_start_pulse`。其中 `ENABLE_PROGRAM_MODE=0` 时
  START 是 no-op，不会留下 `prog_start_pending`。

仅用 `!busy` 单重守卫**无法封堵 back-to-back race**（start_pulse W1P 发出后下游 FSM 要
下一拍才把 busy 拉高，这一拍的空窗足以让对侧 START 绕过互锁）。三重守卫 + `cim_macro_arbiter`
共同确保 CIM 宏任一时刻仅由一条路径驱动。

race 覆盖由 `tb/prog_start_interlock_tb.sv` 的 T3/T4 两个 case 验证（TB 人为按住 busy=0
模拟下游 FSM 滞后，写 back-to-back CIM.START→PROG.START 或反向，检查只有第一条 START 生效）。

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
