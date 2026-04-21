# 04_walkthrough

**参数口径**：默认参数与时序常量以 `rtl/top/snn_soc_pkg.sv` 为准，本文中的数值与示例仅作说明。

## Bit-plane 输入与时序
- V1 输入为离线预处理后的 64 维特征向量；当前默认口径为 `avgpool8x8`，但 RTL 本身仅约束为 64 维、每维 8bit，不在硬件中绑定具体前处理算法。
- 同一子时间步并行送 64 维特征的第 x 位（NUM_INPUTS=64），顺序 MSB->LSB。
- `bitplane_shift` 表示当前位平面（MSB=7 ... LSB=0）。

## 三条常用执行路径

### 1. 纯 TB 直驱路径

- 入口：`run_icarus_light.sh`、`run_icarus_weighted.sh`、`run_sample_align.sh`
- 特点：TB 直接发总线写 MMIO / SRAM，不依赖 E203 先跑起来。
- 用途：最快验证 DMA、CIM 控制器、ADC、LIF 和输出 FIFO。

### 2. E203 启动链路径

- 入口：`run_e203_icarus.sh`
- 流程：`bootloader @ instr_sram -> SPI RDID / READ -> app load to data_sram -> jump -> UART printf -> firmware 配置 DMA + 推理`
- 用途：验证 CPU、SPI 启动、固件寄存器访问和推理链是否贯通。

### 3. JTAG rescue 路径

- 入口：`run_jtag_rescue_top_icarus.sh`
- 流程：Python/主机侧协议 -> `jtag_mem_loader` -> 写 `instr_sram / data_sram / weight_sram` -> 可选释放 CPU 局部复位 -> 观察 UART / 读回校验
- 用途：验证“无正常 SPI boot 时仍能救援”的系统级可恢复性。

## 一次完整推理流程（寄存器 / DMA / FSM 视角）

1. 复位释放。
2. 配置主寄存器：
   - 写 `THRESHOLD`
   - 写 `TIMESTEPS`
   - 必要时写 `RESET_MODE`
   - 若做纯数字链路自检，可写 `CIM_TEST`
3. 写 `data_sram`：
   - 每个 bit-plane 为 64-bit（NUM_INPUTS=64），拆成 2 个 32-bit word 写入。
   - 写入顺序：frame0 的 MSB->LSB，再 frame1 的 MSB->LSB。
   - **MVP / 直驱 TB**：由 TB 直接写入 data_sram。
   - **E203 路径**：CPU 通过 SPI 从外部 Flash 读数据，再写入 data_sram（当前为 PIO，后续可升级为 SPI→DMA→SRAM）。
4. 启动 DMA：
   - `DMA_SRC_ADDR` 指向 data_sram 基址
   - `DMA_LEN_WORDS = frames * PIXEL_BITS * 2`
   - `DMA_DST_SEL = INPUT_FIFO`
   - 写 `DMA_CTRL.START`
5. 轮询 DMA 完成：
   - 观察 `DMA_CTRL.DONE / ERR / BUSY`
   - 必要时读 `IN_FIFO_COUNT`，确认 bit-plane 已经入队
6. 写 `CIM_CTRL.START` 启动推理。
7. `cim_array_ctrl` 状态机循环：
   - `ST_FETCH`：从 input_fifo 取 1 个 bit-plane
   - `ST_DAC`：锁存 `wl_spike`，等待固定 `DAC_LATENCY_CYCLES`（无 `dac_ready` 握手）
   - `ST_CIM`：等待 `cim_done`
   - `ST_ADC`：按 20 通道触发 ADC，等待每次 `adc_done`；ADC 控制器完成数字差分减法后产生 `neuron_in_valid`
   - `ST_INC`：`bitplane_shift--`；若到 LSB 则帧计数++
8. 推理结束后观察：
   - `CIM_CTRL.DONE` sticky
   - `STATUS.BUSY=0`
   - `OUT_FIFO_COUNT`
   - `ADC_SAT_COUNT`
   - `DBG_CNT_0 / DBG_CNT_1`
9. 软件或 TB 读取 `OUT_FIFO_DATA` 取走 spike 序列。

**补充**：当 `TIMESTEPS=0` 时，控制器立即 done，不进入推理流程。

## DMA 2 word 拼接 64-bit
- word0 = wl[31:0]
- word1 = wl[63:32]

## LIF 累加（Scheme B 有符号）
- `neuron_in_valid` 到来时：
  - `signed_in = $signed(neuron_in_data[i])` （9-bit 有符号差分值）
  - `addend = sign_extend(signed_in, 32) <<< bitplane_shift`（算术左移）
  - 累加到有符号膜电位，超过正阈值产生 spike
- 膜电位复位行为由 `RESET_MODE`（reg offset 0x10）配置：
  - `0`（soft，默认）：`V = V - Vth`，保留残余电位，当前工程冻结默认
  - `1`（hard）：`V = 0`，可选项，经建模验证与 soft 等效（见 README §建模定版补充）

## V2 多层推理数据通路

> 需要编译开关 `+define+SIM_MULTI_LAYER`，使 `ENABLE_MULTI_LAYER=1`。
> 涉及模块：`layer_sequencer.sv`、`spike_feedback.sv`、`lif_neuron_alu.sv`。

### 总体架构

多层推理由 `layer_sequencer` 统一编排，最多支持 4 层（MAX_LAYERS=4）。
每层拥有独立的描述符寄存器，描述该层的阵列范围、时间步、阈值和神经元数量。
层间数据传递通过 `spike_feedback` 完成——上一层的 spike 输出被转换为下一层的 WL 输入向量。

数据通路示意：

```
DMA数据 → input_fifo ─→ cim_array_ctrl ─→ ADC差分 ─→ lif_neuron_alu
                │                                        │
                │                                   spike_mask
                │                                        │
                └────── spike_feedback ◄─────────────────┘
                   （中间层 spike → 下一层 WL 输入）
```

### 多层配置步骤（寄存器视角）

1. 写 `REG_ML_CTRL`（0x48）：设置 `num_layers`（层数-1，0=1层，3=4层）和 `enable=1`
2. 对每一层 N（0 到 num_layers）写 4 个层描述符寄存器：

| 寄存器 | 地址 | 字段格式 | 说明 |
|--------|------|----------|------|
| `LAYER_CFG(N)` | 0x50+N×0x10 | `{bl_count[31:24], bl_offset[23:16], wl_count[15:8], wl_offset[7:0]}` | 阵列扫描范围 |
| `LAYER_TIMING(N)` | 0x54+N×0x10 | `{use_bitplane[8], timesteps[7:0]}` | 输入编码方式和时间步数 |
| `LAYER_THRESHOLD(N)` | 0x58+N×0x10 | 32-bit LIF 阈值 | 本层 spike 判决门限 |
| `LAYER_NEURON_CFG(N)` | 0x5C+N×0x10 | `{neuron_count[7:0]}` | 本层活跃神经元数量 |

3. DMA 加载第 0 层输入数据到 input_fifo（标准 bit-plane 编码）
4. 写 `CIM_CTRL.START` 启动推理

### 多层执行流程（`layer_sequencer` 状态机）

`layer_sequencer` 的 FSM 包含 8 个状态，按以下流程驱动每一层的推理：

```
IDLE ──start_pulse──→ LOAD_DESC ──→ RUN_LAYER ──→ WAIT_DONE
                         ▲                            │
                         │              ┌─ 最后一层 ──→ ALL_DONE → IDLE
                         │              │
                         │              └─ 非最后一层 → WAIT_ALU → FEEDBACK → CLEAR_MEM
                         │                                                       │
                         └───────────────────────────────────────────────────────┘
```

各状态详细说明：

1. **ST_LOAD_DESC**：按 `layer_idx` 从层描述符寄存器组中锁存当前层的 `wl_count/wl_offset/bl_count/bl_offset/timesteps/use_bitplane/threshold/neuron_count`。
2. **ST_RUN_LAYER**：将锁存的描述符配置到 `cim_array_ctrl`、`adc_ctrl`、`lif_neuron_alu`，并发出 `ctrl_start_pulse` 启动本层推理。第 0 层 `ctrl_use_feedback=0`（输入来自 DMA），后续层 `ctrl_use_feedback=1`（输入来自 spike_feedback）。
3. **ST_WAIT_DONE**：等待 `cim_array_ctrl` 发出 `ctrl_done_pulse`。如果是最后一层（`layer_idx == layer_max`），进入 ALL_DONE；否则准备下一层的 `feedback_next_wl_count`，进入 WAIT_ALU。
4. **ST_WAIT_ALU**：等待 `lif_neuron_alu` 完成所有神经元的膜电位更新和阈值判断（`alu_busy` 拉低），然后触发 `feedback_en`。
5. **ST_FEEDBACK**：等待 `spike_feedback` 完成 spike_mask 到 WL 向量的转换（`feedback_valid` 拉高），然后递增 `layer_idx` 并发出 `alu_clear_pulse`。
6. **ST_CLEAR_MEM**：等待 `lif_neuron_alu` 逐拍清零所有膜电位（`alu_clearing` 拉低后完成），为下一层推理准备干净的初始状态。
7. **ST_ALL_DONE**：拉低 `busy`，发出 `done_pulse`，通知 CPU 所有层推理完成。

关键控制信号：

- `ctrl_is_last_layer`：`layer_idx == layer_max` 时为 1，控制 `lif_neuron_alu` 的 `output_fifo_en`——只有最后一层才把 spike 写入 output_fifo。
- `ctrl_binary_mode`：`= !use_bitplane`，中间层为 1（binary spike 不走 bit-plane 编码）。
- `alu_clear_pulse`：在 ST_FEEDBACK→ST_CLEAR_MEM 转换时发出，触发 `lif_neuron_alu` 清零膜电位数组。

### spike_feedback 工作原理

`spike_feedback` 负责将上一层推理产生的 spike 结果转换为下一层的 WL 驱动向量：

1. **锁存**：`lif_neuron_alu` 遍历完所有活跃神经元后，拉高 `spike_mask_valid` 一拍。`spike_feedback` 捕获并锁存 `spike_mask`（MAX_NEURONS=128 位，每 bit 对应一个神经元是否 spike）。
2. **截取**：`layer_sequencer` 发出 `feedback_en` 时，`spike_feedback` 根据 `next_wl_count`（下一层的有效字线数）截取 `spike_mask` 的低位，超出部分填 0。例如下一层 `wl_count=10`，则只保留 `spike_mask[9:0]`。
3. **输出**：截取后的向量通过 `feedback_wl_data` 送给 `cim_array_ctrl`，同时拉高 `feedback_valid` 通知 `layer_sequencer` 回注完成。

设计要点：
- 中间层 spike 是 binary（0/1），不走 bit-plane 编码，`use_bitplane=0`，`cim_array_ctrl` 只发 1 个"帧"的 WL 激励。
- 第 0 层通常 `use_bitplane=1`，来自 DMA 的标准 bit-plane 编码输入（MSB→LSB 多帧）。
- `latched_flag` 防止同一份 spike_mask 被重复回注。

### lif_neuron_alu 层间行为

`lif_neuron_alu` 是 V2 专用的时分复用 LIF ALU，与 V1 的 `lif_neurons`（10 路并行）不同，采用 2 级流水线串行处理最多 128 个神经元：

| Stage | 操作 | 说明 |
|-------|------|------|
| Stage 0 | 读膜电位 + 锁存输入 | `mem_array[neuron_idx]` → `s1_mem_rd`；`neuron_in_data[idx]` → `s1_input` |
| Stage 1 | 累加 + 判阈值 + spike | `addend = input <<< bitplane_shift`；`new_mem = old + addend`；`new_mem >= threshold` → spike |

层间切换时的关键行为：

- **清零触发**：`layer_sequencer` 在 ST_FEEDBACK 发出 `alu_clear_pulse`，ALU 进入 clearing 模式，逐拍将 `mem_array[0..MAX_NEURONS-1]` 全部清零。清零期间不接受新的 `neuron_in_valid`。
- **spike 队列**：内部有深度 32 的 spike 队列缓冲。`output_fifo_en=1`（最后一层）时，spike 写入队列后逐拍弹出到 output_fifo；`output_fifo_en=0`（中间层）时，只更新 `spike_mask`，不写 output_fifo。
- **spike_mask 输出**：所有活跃神经元处理完毕后，拉高 `spike_mask_valid` 一拍，通知 `spike_feedback` 锁存。

### 3 层网络推理示例

以下以 MNIST 分类的 3 层 SNN 网络为例，说明多层推理的完整流程。

**层配置寄存器写入：**

```c
// ML_CTRL: num_layers=2 (3层-1), enable=1
bus_write(0x4000_0048, 32'h0000_0105);  // {enable[8]=1, num_layers[1:0]=2}

// ── Layer 0: 输入层 64→20→10 ──
// LAYER_CFG(0): bl_count=20, bl_offset=0, wl_count=64, wl_offset=0
bus_write(0x4000_0050, 32'h1400_4000);
// LAYER_TIMING(0): use_bitplane=1, timesteps=10
bus_write(0x4000_0054, 32'h0000_010A);  // {use_bitplane[8]=1, timesteps[7:0]=10}
// LAYER_THRESHOLD(0): 2550
bus_write(0x4000_0058, 32'h0000_09F6);
// LAYER_NEURON_CFG(0): 10 个活跃神经元
bus_write(0x4000_005C, 32'h0000_000A);

// ── Layer 1: 隐藏层 10→20→10 ──
// LAYER_CFG(1): bl_count=20, bl_offset=0, wl_count=10, wl_offset=0
bus_write(0x4000_0060, 32'h1400_0A00);
// LAYER_TIMING(1): use_bitplane=0, timesteps=5
bus_write(0x4000_0064, 32'h0000_0005);  // {use_bitplane=0, timesteps=5}
// LAYER_THRESHOLD(1): 500
bus_write(0x4000_0068, 32'h0000_01F4);
// LAYER_NEURON_CFG(1): 10 个活跃神经元
bus_write(0x4000_006C, 32'h0000_000A);

// ── Layer 2: 输出层 10→20→10 ──
// LAYER_CFG(2): bl_count=20, bl_offset=0, wl_count=10, wl_offset=0
// Scheme B 使用 pos/neg 差分列，10 个输出神经元需要扫描 20 条 BL。
bus_write(0x4000_0070, 32'h1400_0A00);
// LAYER_TIMING(2): use_bitplane=0, timesteps=3
bus_write(0x4000_0074, 32'h0000_0003);
// LAYER_THRESHOLD(2): 300
bus_write(0x4000_0078, 32'h0000_012C);
// LAYER_NEURON_CFG(2): 10 个活跃神经元
bus_write(0x4000_007C, 32'h0000_000A);
```

**执行流程时序：**

| 阶段 | 状态机状态 | 动作 |
|------|-----------|------|
| 1 | LOAD_DESC(L0) | 锁存 Layer 0 描述符：wl=64, bl=20, T=10, bitplane, thresh=2550 |
| 2 | RUN_LAYER(L0) | `ctrl_use_feedback=0`（DMA 输入），启动 cim_array_ctrl |
| 3 | WAIT_DONE(L0) | cim_array_ctrl 完成 10 帧 × 8 bit-plane 的推理循环 |
| 4 | WAIT_ALU(L0) | lif_neuron_alu 串行处理 10 个神经元（每个 ADC 有效时触发一轮） |
| 5 | FEEDBACK(L0→L1) | spike_feedback 截取 spike_mask[9:0]，输出为 Layer 1 的 WL 向量 |
| 6 | CLEAR_MEM | 清零 lif_neuron_alu 的 128 个膜电位（128 clk） |
| 7 | LOAD_DESC(L1) | 锁存 Layer 1 描述符：wl=10, bl=20, T=5, binary, thresh=500 |
| 8 | RUN_LAYER(L1) | `ctrl_use_feedback=1`（spike 输入），`ctrl_binary_mode=1`，启动推理 |
| 9 | WAIT_DONE(L1) | cim_array_ctrl 完成 5 帧 binary spike 的推理循环 |
| 10 | FEEDBACK(L1→L2) | 同上，spike_mask 回注为 Layer 2 的 WL 向量 |
| 11 | CLEAR_MEM | 再次清零膜电位 |
| 12 | LOAD_DESC(L2) | 锁存 Layer 2 描述符：wl=10, bl=10, T=3, binary, thresh=300 |
| 13 | RUN_LAYER(L2) | `ctrl_is_last_layer=1`，`output_fifo_en=1`，启动推理 |
| 14 | WAIT_DONE(L2) | 推理完成，spike 已写入 output_fifo |
| 15 | ALL_DONE | `done_pulse=1`，`busy=0`，CPU 可读取 output_fifo |

**观察要点：**
- Layer 0 → Layer 1 的 spike_feedback：如果 Layer 0 的 10 个输出神经元中只有 neuron 2、5、7 spike，则 `feedback_wl_data = 128'b...10100100`（bit 2/5/7 为 1），Layer 1 的 CIM 阵列只有第 2/5/7 行 WL 被激活。
- 中间层（Layer 1）不写 output_fifo，`output_fifo_en=0`，spike 只在 `spike_mask` 中记录。
- Layer 2 作为最后一层，`output_fifo_en=1`，spike 的神经元编号通过 spike 队列写入 output_fifo，软件通过 `OUT_FIFO_DATA` 读取。

## bring-up 时最值得看的观察点

- DMA 不结束：先查 `DMA_SRC_ADDR` 是否 4B 对齐，再查 `DMA_LEN_WORDS` 是否满足 `INPUT_FIFO` 的偶数字要求。
- DMA 结束但 `OUT_FIFO_COUNT=0`：优先切到 `CIM_TEST` 模式，用已知 `test_data_pos != test_data_neg` 的假响应排除模拟宏与权重因素。
- `ADC_SAT_COUNT` 明显增大：说明当前模拟/数字接口接近满量程，阈值与 ADC 动态范围需要重新核。
- `DBG_CNT_0.cim_cycle_cnt` 异常偏大：优先检查 `cim_done`、`adc_done` 和 `input_fifo` 是否出现等待。
- 读 `OUT_FIFO_DATA` 时要记住“单次总线读请求 = 消费一个条目”；它不是静态观察寄存器。

## 对应验证入口

- 看纯数字主链：`run_icarus_light.sh`
- 看真实权重与样本对齐：`run_icarus_weighted.sh`、`run_sample_align.sh`
- 看 CPU + 启动链：`run_e203_icarus.sh`
- 看救援路径：`run_jtag_rescue_top_icarus.sh`
