# SNN SoC 完整学习指南

**适用对象**: 研一新生，首次接触系统级数字 IC 设计
**前置知识**: Verilog/SystemVerilog 基础语法，数字电路基础
**学习目标**: 完全理解 MVP 主链路、V1 主线扩展、V1.1 tape-out 加固层（boot_rom + CIM 编程 + 方案 α' 外部编程），能独立修改、排查并为 tapeout 前收口做准备

**参数口径**：本文涉及的默认参数与时序数值以 `rtl/top/snn_soc_pkg.sv` 为准，若与文档不一致以 pkg 为准。

## 当前分支特别说明（feature/v2-arm-fpga-demo）

**本文件是 main 分支 doc/06 的克隆版**，在保留 Part A/B/C 全部内容的基础上，在末尾追加了 **Part D：V2 ARM PS-PL FPGA Demo 集成**，用于本分支特有的 ARM Cortex-A53（ZCU102 PS）+ V2.B 加速器（PL fabric）演示路径。

| 元数据 | 值 |
|------|------|
| 当前分支 | `feature/v2-arm-fpga-demo` |
| 板级冻结 tag (v1) | `v2-arm-fpga-demo-passed @ 8e51ae27`（2026-04-22） |
| 板级冻结 commit (v2 reburn) | `ea31be22`（WSTRB byte-mask 修复后重烧 PASS） |
| Claude 复核基线 HEAD | `eed19406`（在 `03a39a61` v2 tag 之后仅 doc/注释收口） |
| 是否需要 reburn | **否** — HEAD vs reburn commit 的差异均为纯文档/注释 |
| 板级 PASS 标记 | `ARM_FPGA_DEMO_ACCEL_FASHION10_PASS` + `ARM_FPGA_DEMO_SCHEDULER_FASHION10_PASS` |

**学习时请按照"先 Part A → Part B → Part C（如需了解 ASIC 主线）→ Part D（本分支特有）"的顺序**。Part D 假设你已经熟悉 V1 主线 + V1.1 加固层；如果你只想学 ARM PS-PL 集成，可以从 Part D 开始。

---

## 当前版本对应的 main 分支基线（2026-04-29 复核）

| 维度 | 状态 |
|------|------|
| RTL 总行数 | ~8,700 行（rtl/ 全树） |
| ASIC pad 冻结 | 55-pad（48 推理 + 7 外部编程；详见 `doc/15_asic_pad_map.md`） |
| TO-intent 顶层 | `rtl/top/chip_top.sv`（ENABLE_E203=1 + ENABLE_BOOT_ROM=1 + ENABLE_PROGRAM_MODE=1 + ENABLE_EXT_CIM_IF=1） |
| Boot 路径 | mask ROM @ 0x0 → bootloader → SPI 加载 app → INSTR_SRAM @ 0x1000 |
| CIM 编程能力 | `cim_program_ctrl` + `cim_macro_arbiter`（写 / 擦除 / 全阵列擦 / verify retry） |
| 外部编程接口 | 方案 α'（pads 46..52：`prog_op[2:0]` + `prog_level[3:0]`），10-stage shift register 与 cim_start 相位对齐 |
| FPGA 验证状态 | `main-fpga-e203-alpha-passed` tag 已板级冻结（2026-04-24，UART 三段 PASS） |
| 主回归全绿 | LIGHT / WEIGHTED / SAMPLE_ALIGN(100/100) / E203_SMOKE / JTAG / UART / SPI / DMA / AXI bridge / CIM_PROGRAM_CTRL / PROG_PULSE_CFG / PROG_INFLIGHT_LOCK / BOOT_ERASE_E2E / CHIP_TOP_ROM_SMOKE / SILICON_BRINGUP |

> **本文阅读顺序建议**：先按 Part A 把 MVP 主链路读懂；再按 Part B 把 UART/SPI/AXI/E203/JTAG 读懂；最后按 **Part C（V1.1 tape-out 加固层）** 学 boot_rom / CIM 编程 / 方案 α' / chip_top / silicon bringup。Part C 是 2026-04 后追加，是 main 流片前最后一段需要吃透的内容。

## 2026-03-31 审核后的建议入口

如果你是想“反向吃透当前项目现状”，不要机械地把 06 当成唯一入口从头顺排到尾。更高效的顺序是：

1. 先看 `doc/09_smoke_test_checklist.md`，建立**当前主线哪些门禁真的通过、怎么重跑、PASS 判据是什么**的整体认知。
2. 再看 `doc/15_asic_pad_map.md`、`doc/08_cim_analog_interface.md`、`doc/11_analog_handoff_execution_plan.md`，先把 **pad/pin、数模接口、对外 handoff 口径** 看成“项目当前真相”。
3. 然后看 `doc/07_tapeout_schedule.md` 文末**最新** `Status Sync`，确认现在剩下的 TO 收口项到底是什么。
4. 最后再回到本文 Part A/Part B，把它当成“系统学习顺序”和“代码解剖路线图”。

一句话版：**想反向吃透现状，先 09/15/08/11/07 收口，再用 06 拆代码。**

---

## 当前阅读口径（重要）

如果你当前的目标是“先把项目现状彻底看懂，再决定后续加什么 feature”，建议按下面的口径使用本学习路径：

- **把本文当主线，但不要当唯一真源**。它负责给你学习顺序，不负责覆盖所有最新收口信息。
- **当前阶段只先完成 Part A（阶段 A-E）**。先把现有 MVP 主链路、寄存器、TB、回归方式吃透，再进入 Part B 的 UART / SPI / AXI / E203 扩展内容。
- **Part B 不是“未来规划目录”**。UART / SPI / AXI-Lite bridge / E203 / JTAG rescue 等内容在当前 `main` 已有实际实现；阅读时要把它当作“现成代码解剖”，而不是空想设计。
- **项目现状与阶段性收口信息**，优先参考 `doc/11_analog_handoff_execution_plan.md`。
- **当前主线的已通过回归基线与执行命令**，优先参考 `doc/09_smoke_test_checklist.md`，不要只凭 Part B 的“应学内容”判断主线是否已经收口。
- **ASIC pad / pin 真源**，以 `doc/15_asic_pad_map.md` 为准，不再以旧文档里的零散 pin 算术为准。
- **数模接口与板级约束口径**，以 `doc/08_cim_analog_interface.md` 为准。
- **对齐验证链路**，重点看 `tb/top_tb_sample_align.sv`、`sim/run_sample_align.sh`、`项目相关文件/器件对齐/Python建模/export_expected_spike_ids.py` 这三处。
- **如果你在复核 output_fifo / 对齐读数语义**，注意 `reg_bank.sv` 的 `REG_OUT_DATA` 已按边沿触发 pop 收口；单次 `bus_read()` 不应因为 `m_valid` 保持两拍而多 pop。这是 2026-03-16 对齐收口里修过的真实问题。

一句话总结：**用 06 建立学习顺序，用 `pkg` / `11` / `08` / `15` 校准当前项目真相。**

---

## 如果你当前任务是 TO 前排查（非新手学习）

如果你现在的目标不是“从零入门”，而是“把当前主线彻底复核一遍，确保 tapeout 前没有认知盲区”，建议按下面顺序读：

1. 先看 `doc/09_smoke_test_checklist.md`，确认**哪些门禁真的跑过、怎么重跑、PASS 判据是什么**。
2. 再看 `doc/15_asic_pad_map.md`、`doc/08_cim_analog_interface.md`、`doc/11_analog_handoff_execution_plan.md`，确认**pad/pin、数模接口、对外 handoff 口径**；其中优先看 `11` 中“已确认事项”和文末最新状态同步。
3. 然后看 `doc/07_tapeout_schedule.md` 文末最新 `Status Sync`，确认**哪些事情已经完成、哪些仍属于 tapeout 前未闭环项**。
4. 接着回到 Part A，只做“查漏补缺式”阅读：`00/01/02` → `snn_soc_pkg.sv` → `snn_soc_top.sv` → 关键 TB / 脚本。
5. 最后再进 Part B，把 UART / SPI / AXI / E203 / JTAG rescue 当作**已落地主线**逐块核对，而不是把它们当“以后再看”的增量功能。

一句话理解：**新手按 Part A 学，TO 排查按 09/15/08/11/07 先收口，再回来看 06 补知识。**

---

## 第一部分：项目评估

### 这份 SoC 作为入门材料怎么样？

**评价：非常适合，属于"麻雀虽小五脏俱全"的教学级项目**

| 评估维度 | 评分 | 说明 |
|----------|------|------|
| 完整性 | ⭐⭐⭐⭐⭐ | 包含总线、存储、DMA、控制器、数据通路完整链路 |
| 复杂度 | ⭐⭐⭐⭐ | 当前主线约 7100 行 RTL + 4800 行 TB，已不是“几千行 toy 项目”，但模块边界仍然清楚，适合系统学习 |
| 规范性 | ⭐⭐⭐⭐ | 模块划分清晰，命名规范，有完整文档 |
| 可扩展性 | ⭐⭐⭐⭐⭐ | UART / SPI / AXI-Lite bridge / E203 / JTAG rescue / `chip_top` pad-facing wrapper 都已落地，既能学基础，也能学集成与 bring-up |
| 实用性 | ⭐⭐⭐⭐⭐ | 直接对应真实流片需求（6.30 数字单独流片 + 片外混合集成验证） |

**与其他入门项目对比**:
```
简单计数器/FIFO       ← 太简单，缺乏系统视角
当前 SNN SoC 主线     ← ✓ 正好，介于“教学项目”和“可流片主线”之间
完整 Linux SoC / 大核SoC ← 太复杂，容易迷失
```

### 学习建议

- "看懂 → 能改 → 能从头写"是正确的学习路径
- 每读完一个模块就手画框图或时序图
- 先区分“当前已实现并回归通过的主线”与“文档里保留的历史计划/增强项”
- 不要急于求成，每个阶段都要验证理解

---

# Part A: MVP 基础学习

**总时长**: 约 2 周（每天 3-4 小时）

---

## 阶段 A：鸟瞰全局（Day 1-2）

**目标**: 建立整体印象，知道"有什么"

### 阅读顺序

```
1. doc/00_overview.md          ← 整体架构说明
2. doc/01_memory_map.md        ← 地址空间划分
3. doc/02_reg_map.md           ← 寄存器定义（重要！）
4. rtl/top/snn_soc_pkg.sv      ← 全局参数和地址常量
5. rtl/top/snn_soc_top.sv      ← 顶层连接（先看模块列表，不看细节）
```

### 学习方法

- **拿纸画出模块框图**（必须手画！工具画的记不住）
- 标注每个模块的输入输出
- 理解地址空间划分的意义

### 重点理解

```
Q: 数据从哪里来，到哪里去？
A: data_sram → DMA → input_fifo → DAC → CIM → ADC → LIF → output_fifo

Q: 为什么分成多个地址段？
A: 便于地址译码，不同设备类型用不同地址前缀

Q: 一帧图像包含多少个子时间步？
A: 8 个（PIXEL_BITS = 8，每个 bit 是一个子时间步）

Q: 数据流和控制流如何分离？
A: 数据流走固定通路（data_sram → DMA → input_fifo → CIM → output_fifo），
   控制流由 CPU 负责寄存器配置/启动/读结果，二者分离便于验证与扩展。
```

### 关键参数（务必记住！）

| 参数 | 值 | 含义 |
|------|------|------|
| NUM_INPUTS | 64 | 输入维度（默认 `avgpool8x8` 的 8×8 离线特征） |
| NUM_OUTPUTS | 10 | 输出类别数（0-9 数字分类） |
| PIXEL_BITS | 8 | 每像素位宽，决定子时间步数 |
| ADC_BITS | 8 | ADC 输出位宽 |
| ADC_CHANNELS | 20 | ADC 通道数（Scheme B: 10 正 + 10 负） |
| NEURON_DATA_WIDTH | 9 | 有符号差分输出位宽（ADC_BITS+1） |
| LIF_MEM_WIDTH | 32 | LIF 膜电位位宽（32-bit signed，需覆盖多帧累加最大值，保守上界 255×255×10 < 2^20） |
| ADDR_DATA_BASE | 0x0001_0000 | 数据存储起始地址 |
| ADDR_REG_BASE | 0x4000_0000 | 寄存器起始地址 |

### 检验标准

- [ ] 能画出包含所有模块的框图（不看代码）
- [ ] 能说出数据从输入到输出经过哪些模块
- [ ] 能说出每个地址段对应什么外设
- [ ] 能解释为什么 LIF 膜电位需要 32 位

---

## 阶段 B：理解总线和数据搬运（Day 3-4）

**目标**: 理解 CPU/TB 如何与外设通信

### 阅读顺序

```
1. rtl/bus/bus_simple_if.sv         ← 接口定义（5分钟）
2. rtl/bus/bus_interconnect.sv      ← 地址译码（重点）
3. tb/tb_lib/bus_master_tasks.sv    ← 读写时序（重点）
4. rtl/mem/sram_simple.sv           ← 最简单的 slave
5. rtl/mem/sram_simple_dp.sv        ← 带 DMA 端口的 SRAM
6. rtl/dma/dma_engine.sv            ← DMA 状态机（重点）
7. rtl/mem/fifo_sync.sv             ← 同步 FIFO
```

### 学习方法

- 对照 bus_simple_if 的信号，在纸上画时序图
- 理解 "1-cycle 响应" 的含义
- 跟踪 DMA 状态机的每个状态转换

### 总线时序图（手画这个！）

**写操作时序**:
```
clk     : _/‾\_/‾\_/‾\_/‾\
m_valid : ___/‾‾‾\________
m_write : ___/‾‾‾\________
m_addr  : ---<ADDR>-------
m_wdata : ---<DATA>-------
m_ready : ______/‾‾‾\_____   ← T+1 响应
```

**读操作时序**:
```
clk      : _/‾\_/‾\_/‾\_/‾\
m_valid  : ___/‾‾‾\________
m_write  : ___________      ← 保持低
m_addr   : ---<ADDR>-------
m_rvalid : ______/‾‾‾\_____  ← T+1 响应
m_rdata  : ------<DATA>----
```

### 重点理解

```
Q: 为什么 DMA 需要 ST_SETUP 状态？
A: 因为 addr_ptr <= src_addr_reg 是非阻塞赋值，
   需要等一拍才能让组合逻辑 dma_rd_addr = addr_ptr 读到正确地址

Q: bus_interconnect 为什么要打一拍？
A: 为了保证固定 1-cycle 响应，让时序可预测

Q: 64-bit 数据怎么存储在 32-bit SRAM 中？
A: 用 2 个 word：word0[31:0] + word1[31:0] = 64 bit（整打包，无废 bit）
```

### DMA 状态机详解

DMA 支持三种目标（`DST_SEL`），不同目标走不同的 FSM 路径：

```
[DST_INPUT_FIFO (默认)]：
ST_IDLE ──start_pulse──> ST_SETUP
   ↑                        │
   │                        ▼
   │                     ST_RD0 ──────> 读 word0 (低 32 位)
   │                        │
   │                        ▼
   │                     ST_RD1 ──────> 读 word1 (高 32 位)
   │                        │
   │                        ▼
   │      还有数据?      ST_PUSH ──────> 拼接成 64-bit 写入 FIFO
   │        ├─Yes──────────┘
   │        │
   └─No─────┘

[DST_WEIGHT_BUF / DST_INSTR_SRAM]：
ST_IDLE ──start_pulse──> ST_SETUP
   ↑                        │
   │                        ▼
   │                     ST_RD0 ──────> 读 1 个 word
   │                        │
   │                        ▼
   │      还有数据?      ST_WR  ──────> 逐 word 写入目标 SRAM
   │        ├─Yes──────────┘
   │        │
   └─No─────┘
```

注意：`DST_INPUT_FIFO` 需要每两个 word 拼成 64-bit 再 push，因此 `DMA_LEN_WORDS` 必须为偶数。`DST_WEIGHT_BUF` / `DST_INSTR_SRAM` 逐 word 写入，允许奇数长度。

### 检验标准

- [ ] 能手画 bus_write32 和 bus_read32 的时序图
- [ ] 能解释 DMA 的 5 个状态各自做什么
- [ ] 能说出为什么 push 和 pop 是单拍信号
- [ ] 能解释 DMA 多目标扩展后 `ST_WR` 状态的作用（`DST_WEIGHT_BUF` / `DST_INSTR_SRAM` 走 `ST_RD0→ST_WR` 而非 `ST_PUSH`）
- [ ] 能解释 DMA_LEN_WORDS 为什么 `DST_INPUT_FIFO` 目标要求偶数（`DST_WEIGHT_BUF` / `DST_INSTR_SRAM` 允许奇数）

---

## 阶段 C：理解 SNN 核心流水线（Day 5-7）

**目标**: 理解推理的完整数据流，这是项目最核心的部分！

### 阅读顺序（按数据流方向）

```
1. rtl/snn/cim_array_ctrl.sv     ← 主 FSM（最重要！）
2. rtl/snn/wl_mux_wrapper.sv     ← WL 时分复用（64-bit→8×8 分组发送）
3. rtl/snn/dac_ctrl.sv           ← DAC 固定时序控制（无 dac_ready 握手）
4. doc/03_cim_if_protocol.md     ← CIM 接口协议
5. rtl/snn/cim_macro_blackbox.sv ← 行为模型
6. rtl/snn/adc_ctrl.sv           ← ADC 时分复用（重点）
7. rtl/snn/lif_neurons.sv        ← LIF 神经元（重中之重！）
```

### 学习方法

- 画出 cim_array_ctrl 的状态转移图
- 标注每个状态的进入条件和退出条件
- 理解 pulse vs level 的区别

### 主控状态机流转图（必须手画！）

```
            start_pulse
                │
                ▼
    ┌─────► ST_IDLE ◄─────────────────┐
    │                                  │
    │       ST_FETCH ─────────────────►│  ← 从 FIFO 取数据
    │           │                      │
    │           ▼                      │
    │       ST_DAC ──► dac_done_pulse  │  ← wl_mux(10拍) + DAC 转换
    │           │                      │
    │           ▼                      │
    │       ST_CIM ──► cim_done_pulse  │  ← CIM 计算
    │           │                      │
    │           ▼                      │
    │       ST_ADC ──► neuron_in_valid │  ← ADC 采样 20 通道后做差分
    │           │                      │
    │           ▼                      │
    │       ST_INC ────────────────────┤  ← 更新计数器
    │           │                      │
    │     ts < max?                    │
    │      │    │                      │
    │     Yes   No                     │
    │      │    └──► ST_DONE ──────────┘
    │      │
    └──────┘
```

### bitplane_shift 变化规律

```
帧0: bitplane_shift = 7,6,5,4,3,2,1,0 (8个子时间步)
帧1: bitplane_shift = 7,6,5,4,3,2,1,0
...
帧N-1: bitplane_shift = 7,6,5,4,3,2,1,0

总子时间步数 = TIMESTEPS × PIXEL_BITS = 10 × 8 = 80（当前工程默认 T=10）
```

### ADC 时分复用详解

> **注**：以下描述 `adc_ctrl.sv` 内部仿真行为（`snn_soc_top` ↔ `cim_macro_blackbox` 并行接口）。外部简化协议使用 `cim_start`/`cim_done`，详见 `doc/08` §1.3。

```
20 个通道输出（Scheme B: 10 正 + 10 负），只用 1 个 8-bit ADC：

bl_sel: 0 → 1 → 2 → ... → 19（前 10 正列，后 10 负列）

每个通道的采样流程:
1. 设置 bl_sel (5-bit)
2. 等待 settle（稳定）
3. adc_start 脉冲
4. 等待 adc_done 脉冲
5. 锁存 bl_data[7:0] 到 raw_data[bl_sel]
6. bl_sel++

20 个通道全部采完后，数字差分减法：
- diff[i] = raw_data[i] - raw_data[i+10]（i=0..9）
- neuron_in_valid 拉高一拍
- neuron_in_data = 10 路 signed 9-bit 差分结果
```

### LIF 神经元算法（核心！）

```systemverilog
// 移位累加（bit-serial 核心，Scheme B 有符号）
signed_in = $signed(neuron_in_data[i]);           // 9-bit signed
addend = sign_extend(signed_in, 32) <<< bitplane_shift;  // 算术左移
new_mem = membrane[i] + addend;                   // signed 32-bit 累加

// 有符号阈值比较 + spike 产生
if (new_mem >= $signed(threshold)) begin
    spike = 1'b1;
    membrane[i] = (reset_mode) ? 0 : (new_mem - threshold);
end else begin
    membrane[i] = new_mem;
end
```

**位权计算示例**：
| bitplane_shift | 权重 | 说明 |
|----------------|------|------|
| 7 | 128 | MSB，最高权重 |
| 6 | 64 | |
| ... | ... | |
| 1 | 2 | |
| 0 | 1 | LSB，最低权重 |

### 重点理解

```
Q: cim_array_ctrl 在 FIFO 为空时会怎样？
A: 使用全 0 的 wl_bitmap，不会卡死

Q: 为什么 adc_ctrl 需要 20 次循环？
A: Scheme B 时分复用架构，1 个 ADC 依次采样 20 个通道（10 正列 + 10 负列）

Q: neuron_in_valid 是在哪个模块产生的？
A: adc_ctrl，在 20 路数据采样完成并执行数字差分减法后产生单拍脉冲

Q: 为什么用 MSB-first（bitplane_shift 从 7 开始）？
A: 高位权重大，先处理高位可以更早判断是否超过阈值

Q: 膜电位为什么不会溢出？
A: 按当前工程默认（T=10）做保守估算：
   最大单帧累积 = `(2^ADC_BITS-1) × ((1<<PIXEL_BITS)-1) = 255 × 255 = 65025`
   10 帧总和 ≈ `650250 < 2^20`，考虑符号位后 32 位有符号仍有充足余量。
```

### 检验标准

- [ ] 能画出 cim_array_ctrl 完整状态图
- [ ] 能解释 wl_mux_wrapper 如何将 64-bit 并行信号拆成 8 组 × 8-bit 串行发送（10 cycles）
- [ ] 能解释每个 pulse 信号的产生者和消费者
- [ ] 能说出一个子时间步需要多少时钟周期（~125 cycles: WL复用10 + DAC5 + CIM10 + ADC100）
- [ ] 能解释 LIF 的移位累加原理
- [ ] 能说出 soft reset 和 hard reset 的区别

---

## 阶段 D：理解寄存器和控制（Day 8）

**目标**: 理解软件如何配置硬件

### 阅读顺序

```
1. doc/02_reg_map.md            ← 对照文档
2. rtl/reg/reg_bank.sv          ← 实现
3. rtl/reg/fifo_regs.sv         ← FIFO 状态
```

### 寄存器类型详解

| 类型 | 含义 | 示例 |
|------|------|------|
| RW | 可读可写 | THRESHOLD、TIMESTEPS |
| RO | 只读 | NUM_INPUTS、NUM_OUTPUTS |
| W1P | 写1产生脉冲，自动清0 | CIM_CTRL.START |
| W1C | 写1清除sticky位 | CIM_CTRL.DONE |

### 重点寄存器

| 地址 | 名称 | 关键位段 |
|------|------|----------|
| 0x4000_0000 | THRESHOLD | [31:0] 阈值，默认 THRESHOLD_DEFAULT = 2550（1×255×10，当前工程默认） |
| 0x4000_0004 | TIMESTEPS | [7:0] 帧数，默认 10（当前工程默认） |
| 0x4000_0014 | CIM_CTRL | bit0=START(W1P), bit1=SOFT_RESET(W1P), bit7=DONE(W1C) |
| 0x4000_0018 | STATUS | bit0=BUSY(RO), bit[15:8]=TIMESTEP_CNT(RO) |
| 0x4000_0024 | THRESHOLD_RATIO | [7:0] 阈值比例，默认 1 (ratio_code=1, 1/255≈0.00392, 定版) |
| 0x4000_0028 | ADC_SAT_COUNT | [15:0]=sat_high, [31:16]=sat_low (RO) |

### 重点理解

```
Q: W1P 和 W1C 有什么区别？
A: W1P (Write-1 Pulse): 写1产生单拍脉冲，自动清0
   W1C (Write-1 Clear): 写1清除sticky位，读不清

Q: OUT_FIFO_DATA 读取时为什么要延迟一拍 pop？
A: 避免读数据和弹出在同一拍，防止时序竞争

Q: 如何启动一次推理？
A: 1. 写 THRESHOLD
   2. 写 TIMESTEPS
   3. DMA 传输数据
   4. 写 CIM_CTRL.START = 1
```

### 检验标准

- [ ] 能从文档找到任意寄存器的地址和位定义
- [ ] 能解释 start_pulse 是如何产生的
- [ ] 能说出 done_sticky 的置位和清除条件
- [ ] 能写出完整的软件操作流程

---

## 阶段 E：理解 Testbench（Day 9）

**目标**: 理解验证流程，能修改测试

### 阅读文件

```
1. tb/tb_lib/bus_master_tasks.sv ← 总线读写任务
2. tb/top_tb.sv                  ← 测试流程
```

### 测试流程分解

```
Step 1: 配置寄存器
        ├─ 写 THRESHOLD = THRESHOLD_DEFAULT（当前默认 2550）
        └─ 写 TIMESTEPS = TIMESTEPS_DEFAULT（当前默认 10）

Step 2: 准备数据
        └─ 写入 data_sram（TIMESTEPS × PIXEL_BITS × 2 word）

Step 3: 启动 DMA
        ├─ 写 DMA_SRC_ADDR = 0x0001_0000
        ├─ 写 DMA_LEN_WORDS = TIMESTEPS × PIXEL_BITS × 2
        ├─ 写 DMA_CTRL.START = 1
        └─ 轮询 DMA_CTRL.DONE

Step 4: 启动推理
        ├─ 写 CIM_CTRL.START = 1
        └─ 轮询 CIM_CTRL.DONE（超时保护）

Step 5: 读取结果
        ├─ 读 OUT_FIFO_COUNT
        └─ 循环读 OUT_FIFO_DATA（每读一次自动 pop）
```

### 波形 Dump

```systemverilog
$fsdbDumpfile("waves/snn_soc.fsdb");
$fsdbDumpvars(0, top_tb);
```

### 检验标准

- [ ] 能说出 TB 的 5 个步骤
- [ ] 能修改 wl_vec 数据观察不同输出
- [ ] 理解 do-while 轮询的作用
- [ ] 能解释为什么 `DMA_LEN_WORDS = TIMESTEPS × PIXEL_BITS × 2`

---

## 第三部分：仿真实战

### 实验 1：基础仿真（必做）

**目标**: 跑通仿真，生成波形

**步骤**:
```bash
cd sim
./run_vcs.sh          # 编译并运行
./run_verdi.sh        # 打开波形查看器
```

**预期结果**:
```
- vcs.log 无 Error
- sim.log 出现 "[TB] Simulation finished."
- sim.log 出现 "[TB] OUT_FIFO_COUNT = N"（N 随输入激励变化；默认黑盒全量回归样例可到数百，若长期为 0 参考 `doc/09` 问题 3）
- waves/snn_soc.fsdb 文件生成
```

**Verdi 查看重点**:
1. 添加 `u_cim_ctrl.state` 信号，观察状态流转
2. 添加 `u_adc.bl_sel` 信号，观察 0-19 循环（Scheme B：前10正列，后10负列）
3. 添加 `u_lif.membrane[0]` 信号，观察膜电位累加
4. 添加 `u_cim_ctrl.bitplane_shift` 信号，观察 7→0 变化

---

### 实验 2：参数修改实验（必做）

**目标**: 理解参数对行为的影响

**实验 2.1**: 修改时间步数
```systemverilog
// tb/top_tb.sv
bus_write32(bus_vif, 32'h4000_0004, 32'd10, 4'hF);  // TIMESTEPS = 10
```
预期：推理更快完成，输出 spike 更少

**实验 2.2**: 修改阈值
```systemverilog
// tb/top_tb.sv
bus_write32(bus_vif, 32'h4000_0000, 32'd50, 4'hF);  // THRESHOLD = 50
```
预期：更容易触发 spike，输出更多

**实验 2.3**: 修改 ADC 延迟
```systemverilog
// rtl/top/snn_soc_pkg.sv
parameter int ADC_SAMPLE_CYCLES = 10;  // 改成 10
```
预期：每个 timestep 时间变长

---

### 实验 3：调试实验（推荐）

**目标**: 学会定位问题

**故意引入 bug**:
```systemverilog
// rtl/snn/cim_array_ctrl.sv ST_ADC 状态
// 把 neuron_in_valid 改成 cim_done（错误的信号）
if (cim_done) begin  // 原本是 neuron_in_valid
  state <= ST_INC;
end
```

**观察现象**: 仿真卡死在某个状态

**调试方法**:
1. 在 Verdi 中添加 `state` 信号
2. 观察卡在哪个状态（应该是 ST_ADC）
3. 检查该状态的退出条件
4. 发现 cim_done 已经过去，等不到了
5. 定位到错误信号

---

### 实验 4：添加调试输出（推荐）

**目标**: 学会使用 $display 调试

```systemverilog
// 在 cim_array_ctrl.sv 添加
always_ff @(posedge clk) begin
  if (rst_n && state != $past(state))
    $display("[%0t] CIM FSM: %s -> %s, ts=%0d, bp=%0d",
             $time, $past(state).name(), state.name(),
             timestep_counter, bitplane_shift);
end
```

---

### 模块级仿真实战（推荐）

**目标**: 深入理解每个模块的行为，建立系统性的验证思维

**为什么要做模块级仿真**:
1. **理解更深刻** - 专注单个模块，观察每个信号变化
2. **调试更容易** - 问题定位更精准
3. **测试更全面** - 可以覆盖各种边界情况
4. **信心更足** - 每个模块都验证通过，集成时更放心

#### 建议的仿真顺序（从简单到复杂）

**阶段 1：基础模块（1-2天）**

1. **FIFO** ([rtl/mem/fifo_sync.sv](../rtl/mem/fifo_sync.sv))
   - 测试场景：满、空、同时读写、计数器
   - 最简单，先练手

2. **SRAM** ([rtl/mem/sram_simple.sv](../rtl/mem/sram_simple.sv))
   - 测试场景：读写、地址边界

**阶段 2：控制逻辑（2-3天）**

3. **DMA 引擎** ([rtl/dma/dma_engine.sv](../rtl/dma/dma_engine.sv))
   - 测试场景：正常搬运、越界、奇数长度
   - 重点观察状态机流转

4. **寄存器组** ([rtl/reg/reg_bank.sv](../rtl/reg/reg_bank.sv))
   - 测试场景：读写、W1C、只读寄存器

**阶段 3：SNN 核心（3-4天）**

5. **LIF 神经元** ([rtl/snn/lif_neurons.sv](../rtl/snn/lif_neurons.sv))
   - 测试场景：membrane 累加、超过阈值发放 spike
   - 测试不同输入值、不同阈值

6. **ADC 控制** ([rtl/snn/adc_ctrl.sv](../rtl/snn/adc_ctrl.sv))
   - 测试场景：时分复用、bl_sel 切换

7. **CIM 阵列控制** ([rtl/snn/cim_array_ctrl.sv](../rtl/snn/cim_array_ctrl.sv))
   - 测试场景：完整推理流程、bitplane 顺序、timestep 计数
   - 最复杂，留到最后

**阶段 4：集成测试**

8. **顶层 smoke test**（已有）
   - 验证所有模块协同工作

#### 模块测试框架示例

```systemverilog
// 示例：FIFO 模块测试
module fifo_tb;
  // 1. 信号声明
  logic clk, rst_n;
  logic push, pop;
  logic [31:0] push_data, rd_data;
  logic empty, full;
  logic [4:0] count;

  // 2. 实例化 DUT
  fifo_sync #(.WIDTH(32), .DEPTH(16)) dut (
    .clk(clk),
    .rst_n(rst_n),
    .push(push),
    .push_data(push_data),
    .pop(pop),
    .rd_data(rd_data),
    .empty(empty),
    .full(full),
    .count(count)
  );

  // 3. 时钟生成
  initial begin
    clk = 0;
    forever #10 clk = ~clk;  // 50MHz
  end

  // 4. 测试场景
  initial begin
    // 复位
    rst_n = 0; push = 0; pop = 0;
    #100 rst_n = 1;

    // 测试1：写满 FIFO
    $display("[Test 1] Fill FIFO");
    repeat(16) begin
      @(posedge clk);
      push = 1;
      push_data = $random;
    end
    @(posedge clk);
    push = 0;

    // 检查 full 信号
    if (!full) $error("FIFO should be full!");

    // 测试2：读空 FIFO
    $display("[Test 2] Drain FIFO");
    repeat(16) begin
      @(posedge clk);
      pop = 1;
    end
    @(posedge clk);
    pop = 0;

    // 检查 empty 信号
    if (!empty) $error("FIFO should be empty!");

    // 测试3：同时读写
    $display("[Test 3] Simultaneous push/pop");
    // ...

    $display("[Test] All tests passed!");
    $finish;
  end

  // 5. 波形记录
  initial begin
    $fsdbDumpfile("waves/fifo_test.fsdb");
    $fsdbDumpvars(0, fifo_tb);
  end
endmodule
```

#### 测试要点

**每个模块测试应该包含**:
1. **正常功能** - 验证基本读写、状态转换
2. **边界条件** - 满、空、最大值、最小值
3. **异常情况** - 错误输入、超时、X/Z 值
4. **时序检查** - 总线 valid/ready 握手、SNN 脉冲宽度

**波形观察重点**:
- 状态机：每个状态停留时间、转换条件
- 握手信号：总线 valid/ready 关系 + SNN done_pulse 时序关系
- 计数器：是否正确递增/递减
- 数据通路：数据是否正确传递

#### 学习建议

**边学边测的流程**:
```
读代码 → 理解功能 → 写测试 → 跑仿真 → 看波形 → 理解透彻
  ↑                                                      ↓
  └───────────────── 发现问题，回到代码 ─────────────────┘
```

**重要提醒**:
1. **保留 smoke test** - 模块测试通过后，还是要跑整体测试
2. **写测试文档** - 每个模块测试什么、结果如何，记录下来
3. **边界条件优先** - 不只测正常情况，要测边界（0、最大值、X/Z等）
4. **波形对比** - 和预期行为对比，理解每个信号的含义

通过这样系统化的模块级测试，你对整个系统的理解会比只跑 smoke test 深刻 10 倍！

---

## 第四部分：知识检验清单

### 基础层（必须全部掌握）

- [ ] 能画出 SoC 整体框图（不看代码）
- [ ] 能说出地址 0x4000_001C 对应什么寄存器
- [ ] 能解释总线 valid/ready 握手协议与 SNN 单拍脉冲协议
- [ ] 能说出 DMA 状态机的 5 个状态
- [ ] 能画出 cim_array_ctrl 状态转移图
- [ ] 能解释 pulse 和 level 的区别
- [ ] 能独立运行仿真并查看波形

### 进阶层（应该掌握）

- [ ] 能解释 bus_interconnect 为什么打一拍
- [ ] 能解释 OUT_FIFO pop 为什么延迟一拍
- [ ] 能计算一次完整推理需要多少时钟周期
- [ ] 能修改 TB 参数观察不同结果
- [ ] 能定位简单的时序 bug
- [ ] 能解释 LIF 膜电位的位宽为什么是 32 位

### 高级层（加分项）

- [ ] 能独立添加新的寄存器
- [ ] 能修改 FSM 添加新状态
- [ ] 能写简单的 assertion 检查
- [ ] 理解为什么用非阻塞赋值
- [ ] 能解释片外/片上数模混合集成的注意事项

---

## 第五部分：常见问题 FAQ

### Q1: 看不懂 SystemVerilog 语法怎么办？
```
推荐资源:
- 《SystemVerilog for Verification》第1-3章
- CSDN/知乎搜索 "SystemVerilog always_ff always_comb"
- 夏宇闻《Verilog 数字系统设计教程》
```

### Q2: 仿真跑不起来怎么办？
```
检查清单:
1. 先区分你跑的是 Icarus 还是 VCS/Verdi 流程，不要混着排查
2. Icarus（Windows）优先用 Git for Windows 自带的 `bash.exe` 跑 `sim/*.sh`，不要直接用 `C:\Windows\System32\bash.exe`
3. `run_e203_icarus.sh` / `run_jtag_rescue_top_icarus.sh` 额外依赖 WSL 里的 `riscv64-unknown-elf-gcc / objcopy`
4. 若是直接 `iverilog -f *.f`，确认当前目录在 `sim/`，否则相对路径会错
5. 若是 VCS/Verdi，检查 `VERDI_HOME`、`vcs.log` 的第一个 Error、以及服务器 Linux 环境是否初始化完成
```

### Q3: 波形太多信号，不知道看哪个？
```
优先看:
1. clk, rst_n（确认时钟和复位正常）
2. 各模块的 state 信号
3. 关键握手信号（总线 valid/ready + SNN done_pulse）
4. 数据通路信号（fifo count, membrane 等）
5. bitplane_shift（观察 7→0 变化）
```

### Q4: 理解了代码但记不住怎么办？
```
方法:
1. 手画框图和时序图（别用工具，手画记忆深刻）
2. 尝试给别人讲解（费曼学习法）
3. 动手改代码观察效果
4. 写学习笔记，整理关键点
```

### Q5: 为什么用 bit-serial 架构？
```
减少 CIM Macro 的面积和连线：
- 并行送 8bit 需要 64×8=512 根线
- bit-serial 只需 64 根线，每 bit 逐位送入
- 代价是速度变慢 8 倍，但面积大幅减小
```

### Q6: bitplane_shift 为什么从 7 开始？
```
MSB-first 设计：
- bit7 是最高位，权重最大 (128)
- 先处理高位可以更早判断是否超过阈值
- 也便于实现早停优化（future work）
```

### Q7: CIM Macro 行为模型的输出有什么含义？
```
Scheme B 行为模型（20 通道：前 10 正列 + 后 10 负列）：
pop = popcount(wl_latched)  // 0-64（在 dac_valid 单拍触发后锁存）
正列 (j<10): bl_data[j] = (pop * 2 + j) & 0xFF
负列 (j>=10): bl_data[j] = (pop/2 + (j-10)) & 0xFF

- popcount: 统计锁存向量 wl_latched 中 1 的个数
- 数字侧差分: diff[i] = raw[i] - raw[i+10] (i=0..9)
- 真实 CIM 会输出实际的 MAC 结果
```

### Q8: soft reset 和 hard reset 怎么选？
```
- soft reset: 膜电位减去阈值，保留超出部分
  → 更接近当前工程口径，也是当前 RTL 默认值 (`reset_mode=0`)
- hard reset: 膜电位直接清零
  → 更简单，适合做对照实验或特定算法探索 (`reset_mode=1`)
```

### Q9: 片外/片上数模混合集成需要注意什么？
```
1. 保持 cim_macro_blackbox.sv 的端口定义不变
2. 与模拟团队确认时序约束（见 doc/08_cim_analog_interface.md）
3. 时钟频率目标 50MHz（保守裕量）
4. 关注建立/保持时间要求
```

---

## 第六部分：时间规划

### Part A 推荐学习时间表

| 天数 | 内容 | 时长 | 关键交付物 |
|------|------|------|------------|
| Day 1-2 | 阶段 A：鸟瞰全局 | 4-6h | 手画系统框图 |
| Day 3-4 | 阶段 B：总线和数据搬运 | 6-8h | 手画总线时序图、DMA 状态机图 |
| Day 5-7 | 阶段 C：SNN 核心流水线 | 8-10h | 手画 cim_array_ctrl 状态图、LIF 算法理解 |
| Day 8 | 阶段 D：寄存器和控制 | 3-4h | 整理寄存器操作序列 |
| Day 9 | 阶段 E：Testbench | 2-3h | 理解 TB 流程 |
| Day 10-12 | 仿真实验 1-4 | 6-8h | 波形截图、参数修改实验记录 |
| Day 13-18 | 模块级仿真（推荐）| 12-16h | 各模块测试用例、波形分析 |
| Day 19-20 | 复习 + 知识检验 | 4h | 完成检验清单 |

**Part A 总计约 3 周**，每天投入 3-4 小时（包含模块级仿真）。
**如果跳过模块级仿真，约 2 周**。

---

# Part B: V1 进阶学习

完成 Part A 后，你已经掌握了 MVP。接下来学习 V1 版本需要的新知识。

**前置条件**: Part A 检验清单全部通过

> **注意**：Part B 的阶段 9–14 既介绍协议原理，也会指引你去读当前 `main` 分支上已完成的 V1 实现。每个阶段的"实际实现参考"小节列出了对应的 RTL/TB/脚本文件，建议结合代码阅读。
> 迭代变更详情见 `doc/16_iteration_log.md`（Iteration 1–7 = V1 主线；Iteration 10–11 = V1.1 boot_rom + 方案 α'，对应本文 Part C）。

---

## 阶段 9：UART 外设设计（Day 15-17）

**目标**: 理解 UART 协议原理，能设计实现完整的 UART 控制器

### 9.1 UART 协议基础

**数据帧格式（8N1）**:
```
空闲─┬─起始位─┬─D0─D1─D2─D3─D4─D5─D6─D7─┬─停止位─┬─空闲
     │   0   │        数据位          │   1   │
```

**关键公式**:
```
分频系数 = 时钟频率 / 波特率
例如：50MHz / 115200 = 434
```

### 9.2 UART TX 设计

**状态机**:
```
ST_IDLE ──tx_valid──> ST_START ──> ST_DATA(×8) ──> ST_STOP ──> ST_IDLE
```

**关键信号**:
- `tx_data[7:0]`: 待发送数据
- `tx_valid`: 发送请求
- `tx_ready`: 发送器空闲
- `uart_tx`: 串行输出

### 9.3 UART RX 设计

**关键设计点**:
- 起始位检测（下降沿）
- 采样点在位中心（半位时间延迟）
- RX FIFO 缓冲

### 实际实现参考

当前 `main` 分支上的 UART 实现：

| 文件 | 说明 |
|------|------|
| [rtl/periph/uart_ctrl.sv](../rtl/periph/uart_ctrl.sv) | TX 4态FSM（IDLE/START/DATA/STOP），baud_div 可配，RX V1 占位 |
| [tb/uart_tb.sv](../tb/uart_tb.sv) | T1~T8 独立烟雾测试 |
| `sim/run_uart_icarus.sh` | 运行脚本，PASS 标准 `UART_SMOKETEST_PASS` |

> **当前口径提醒**：
> `uart_ctrl` 上电默认 `baud_div=434`，这是 50MHz / 115200 的硬件口径。
> 但 `run_e203_icarus.sh` 和 `run_jtag_rescue_top_icarus.sh` 为了缩短 Icarus 仿真时间，会在构建固件时临时覆盖 `UART_BAUD_DIV=2`。
> 这只影响仿真 smoke 固件，不代表板级 bring-up 或真实芯片的推荐串口配置。

### 检验标准

- [ ] 115200 波特率在 50MHz 时钟下的分频系数是多少？
- [ ] 为什么 RX 要在位中心采样？
- [ ] UART TX 发送一个字节需要多少个波特周期？
- [ ] 阅读 `uart_ctrl.sv` 并与上面的协议框架对比，理解 `baud_div=0` 钳位防御

---

## 阶段 10：SPI 外设设计（Day 18-20）

**目标**: 理解 SPI 协议原理，能设计实现 SPI Master 控制器

### 10.1 SPI 四线接口

| 信号 | 方向 | 含义 |
|------|------|------|
| SCLK | Master→Slave | 时钟 |
| MOSI | Master→Slave | 主发从收 |
| MISO | Slave→Master | 从发主收 |
| CS | Master→Slave | 片选（低有效） |

### 10.2 SPI 模式

| 模式 | CPOL | CPHA | 常用场景 |
|:---:|:---:|:---:|:---|
| 0 | 0 | 0 | **Flash 常用** |
| 3 | 1 | 1 | **Flash 常用** |

**建议**: 先实现 Mode 0

> **当前主线口径**：`main` 里已冻结并回归通过的是 `spi_ctrl` 的 **Mode 0** 主路径；Mode 3 在这里保留为协议学习对照和后续扩展练习，不是当前 V1 主线的必选实现项。

### 10.3 SPI Master 状态机

```
ST_IDLE ──> ST_CS_LOW ──> ST_TRANSFER(×8) ──> ST_CS_HIGH ──> ST_IDLE
```

### 实际实现参考

当前 `main` 分支上的 SPI 实现：

| 文件 | 说明 |
|------|------|
| [rtl/periph/spi_ctrl.sv](../rtl/periph/spi_ctrl.sv) | SPI Master（Mode 0，3态FSM，8-bit 全双工，软件控 CS，baud_div 7级） |
| [tb/spi_flash_model.sv](../tb/spi_flash_model.sv) | SPI Flash 行为模型（RDID/READ，64KB 窗口） |
| [tb/spi_tb.sv](../tb/spi_tb.sv) | T1~T3+T1b 独立烟雾测试 |
| `sim/run_spi_icarus.sh` | 运行脚本，PASS 标准 `SPI_SMOKETEST_PASS` |

### 检验标准

- [ ] SPI Mode 0 和 Mode 3 的区别是什么？
- [ ] 为什么 SPI 比 UART 快？
- [ ] 如何读取 Flash 的 JEDEC ID？
- [ ] 阅读 `spi_ctrl.sv`，理解 `clk_div=0+spi_en=1` 安全钳位机制

---

## 阶段 11：AXI-Lite 总线（Day 21-24）

**目标**: 理解 AXI-Lite 协议，能设计 AXI-Lite Master 和 Slave

### 11.1 五个通道

| 通道 | 方向 | 用途 |
|:---|:---|:---|
| AW | Master→Slave | Write Address |
| W | Master→Slave | Write Data |
| B | Slave→Master | Write Response |
| AR | Master→Slave | Read Address |
| R | Slave→Master | Read Data |

### 11.2 握手协议

```
valid 和 ready 同时为 1 时传输完成
valid 一旦拉高，在 ready 之前不能撤销
```

### 11.3 AXI to Simple Bridge

**为什么需要桥接**:
- 外部调试/测试主机可能使用 AXI-Lite 接口
- 现有 slave 使用 simple 接口
- 桥接器转换协议，保持 slave 不变

> **V1 实际架构**：E203 使用的是 ICB（Internal Coherent Bus）而非 AXI。当前 `main` 分支采用 **ICB→simple 直桥**（`icb2simple_bridge.sv`）而非 ICB→AXI→simple 双桥路径，减少一层协议转换面积和时序负担。AXI-Lite bridge（`axi2simple_bridge.sv`）作为独立模块已验证通过，可供后续需要 AXI 接入时复用。

### 实际实现参考

| 文件 | 说明 |
|------|------|
| [rtl/bus/axi_lite_if.sv](../rtl/bus/axi_lite_if.sv) | AXI4-Lite SystemVerilog interface 定义 |
| [rtl/bus/axi2simple_bridge.sv](../rtl/bus/axi2simple_bridge.sv) | AXI-Lite → bus_simple 协议转换桥（5态FSM） |
| [rtl/bus/icb2simple_bridge.sv](../rtl/bus/icb2simple_bridge.sv) | ICB → bus_simple 直桥（V1 E203 主路径） |
| [tb/axi_bridge_tb.sv](../tb/axi_bridge_tb.sv) | T1~T13 端到端测试 |
| `sim/run_axi_bridge_icarus.sh` | 运行脚本，PASS 标准 `AXI_BRIDGE_SMOKETEST_PASS` |

### 检验标准

- [ ] AXI-Lite 有几个通道？各有什么作用？
- [ ] valid/ready 握手的规则是什么？
- [ ] 为什么选择 AXI-Lite 而不是完整 AXI4？
- [ ] V1 为什么最终用 ICB→simple 直桥而非 AXI 双桥？

---

## 阶段 12：E203 RISC-V Core（Day 25-27）

**目标**: 了解 E203 的架构和接口，理解如何将 E203 集成到 SoC

### 12.1 E203 概述

| 特性 | 说明 |
|------|------|
| 架构 | 32 位 RISC-V |
| 指令集 | 上游 E203 为 RV32IMAC；本项目当前接入口径裁剪后实际只保留 RV32I 主路径 |
| 流水线 | 2 级 |
| 开源协议 | Apache 2.0 |

### 12.2 E203 集成架构（V1 实际实现）

```
E203 Core (e203_min_wrap.sv)
    ↓ mem_icb
ICB-to-Simple Bridge (icb2simple_bridge.sv)
    ↓ bus_simple
bus_interconnect (地址译码)
    ↓
各个 Slave（instr_sram / data_sram / weight_sram / reg_bank / dma / uart / spi / fifo_regs）
```

> V1 采用 ICB→simple **直桥**，不经过 AXI。`e203_min_wrap.sv` 关闭 JTAG/ITCM/DTCM/NICE/ECC/AMO/share-muldiv，仅保留 RV32I 主路径与 `mem_icb`。PPI/CLINT/PLIC/FIO 全部接到 `icb_err_slave`。

### 12.3 启动流程（V1 实际实现）

```
1. 上电复位
2. E203 从 0x0000_0000 取第一条指令 → bootloader（预加载在 instr_sram）
3. bootloader: UART 输出 "BL start" → SPI RDID → SPI READ header + app payload
4. bootloader: 将 app 装载到 data_sram @ 0x0001_0000 → fence.i → 跳转
5. app: UART 输出 "APP start" → DMA + SNN 推理 → UART 输出结果
```

### 实际实现参考

| 文件 | 说明 |
|------|------|
| [rtl/top/e203_min_wrap.sv](../rtl/top/e203_min_wrap.sv) | E203 最小包装层 |
| [rtl/bus/icb2simple_bridge.sv](../rtl/bus/icb2simple_bridge.sv) | ICB→simple 直桥 |
| [rtl/bus/icb_err_slave.sv](../rtl/bus/icb_err_slave.sv) | ICB 错误应答从设备 |
| [fw/boot_main.c](../fw/boot_main.c) | bootloader 源码 |
| [fw/main.c](../fw/main.c) | app 固件源码 |
| [fw/include/soc_regs.h](../fw/include/soc_regs.h) | 寄存器地址头文件 |
| [tb/e203_tb.sv](../tb/e203_tb.sv) | E203 专用 TB |
| `sim/run_e203_icarus.sh` | 运行脚本，PASS 标准 `E203_SMOKETEST_PASS` |

> **读固件时要注意两层口径**：
> 启动链本身（bootloader → SPI 读镜像 → 跳转 app → DMA + SNN）是真实要检查的主线；
> 其中 UART 分频值在 Icarus 脚本里会临时覆盖成 `2` 做仿真加速，而不是把真实 50MHz / 115200 目标改掉。

### 推荐资源

- E203 官方文档：https://github.com/SI-RISCV/e200_opensource
- 《手把手教你设计 CPU——RISC-V 处理器篇》

### 检验标准

- [ ] E203 支持哪些 RISC-V 指令集扩展？（V1 裁剪后只用 RV32I）
- [ ] ICB 总线和 AXI 总线的区别是什么？
- [ ] E203 复位后从哪个地址开始执行？
- [ ] 为什么 V1 用 ICB→simple 直桥而不是 ICB→AXI→simple 双桥？

---

## 阶段 13：嵌入式固件开发（Day 28-29）

**目标**: 了解 RISC-V 嵌入式开发流程，能编写简单的驱动和应用程序

### 13.1 开发环境

```bash
# 安装 RISC-V 工具链
sudo apt install gcc-riscv64-unknown-elf
```

> **环境提醒**：当前仓库的 `run_e203_icarus.sh` / `run_jtag_rescue_top_icarus.sh` 默认是“Windows 下用 Git Bash 跑 Icarus + WSL 里调用 `riscv64-unknown-elf-gcc/objcopy` 构建固件”的混合流程；不是要求你把全部仿真都切到 WSL 内完成。

### 13.2 寄存器访问

```c
#define REG32(addr) (*(volatile uint32_t *)(addr))

#define REG_BASE        0x40000000
#define REG_THRESHOLD   (REG_BASE + 0x00)
#define REG_TIMESTEPS   (REG_BASE + 0x04)
#define REG_CIM_CTRL    (REG_BASE + 0x14)
#define REG_STATUS      (REG_BASE + 0x18)
```

### 13.3 SNN 驱动示例

```c
void snn_init(uint32_t threshold, uint32_t timesteps) {
    REG32(REG_THRESHOLD) = threshold;
    REG32(REG_TIMESTEPS) = timesteps;
}

void snn_start(void) {
    REG32(REG_CIM_CTRL) = 1;  // START bit
}

int snn_wait_done(void) {
    while (!(REG32(REG_CIM_CTRL) & 0x80)) {
        // 等待 DONE bit (bit7)
    }
    return 0;
}
```

### 检验标准

- [ ] startup.S 的作用是什么？
- [ ] 如何通过 C 代码访问硬件寄存器？
- [ ] 为什么要用 volatile 关键字？

---

## 阶段 14：DMA 多目标与 JTAG 救援通路（Day 30-32）

**目标**: 理解 DMA 扩展后的多目标路由机制，以及 JTAG 救援通路的设计与使用

### 14.1 DMA 多目标扩展

V1 的 DMA 新增了 `DMA_DST_SEL` 寄存器，支持三种目标：

| `DST_SEL[1:0]` | 目标 | 行为 |
|---|---|---|
| `2'b00` | `input_fifo` | 每两个 word 拼成 64-bit push（原有行为） |
| `2'b01` | `weight_sram` | 逐 word 写入，允许奇数长度 |
| `2'b10` | `instr_sram` | 逐 word 写入，允许奇数长度 |

FSM 扩展：`DST_INPUT_FIFO` 走 `RD0→RD1→PUSH`，`DST_WEIGHT/INSTR` 走 `RD0→WR`。

### 14.2 JTAG 救援通路

当 CPU/bootloader/SPI 启动失败时，JTAG rescue loader 提供独立的直写 SRAM + CPU 重启能力。

**TAP 指令**:

| IR (4-bit) | 名称 | 说明 |
|---|---|---|
| `4'h1` | IDCODE | 返回 `32'hE203_0001` |
| `4'h2` | MEMACC | 读写 `instr/data/weight_sram`，MMIO 一律返回 `err=1` |
| `4'h3` | CPUCTL | `cpu_reset_hold`：只复位 CPU+bridge，不影响 SRAM/SNN/外设 |
| `4'hF` | BYPASS | 标准 bypass |

**仲裁策略**: JTAG 等待 `cpu_bridge_busy=0` 后接管；256 周期超时自动触发 `jtag_timeout_force`。

### 实际实现参考

| 文件 | 说明 |
|------|------|
| [rtl/dma/dma_engine.sv](../rtl/dma/dma_engine.sv) | DMA 多目标扩展（`DST_SEL`、`ST_WR` 状态） |
| [rtl/periph/jtag_mem_loader.sv](../rtl/periph/jtag_mem_loader.sv) | 自定义 4-wire JTAG TAP |
| [tb/dma_tb.sv](../tb/dma_tb.sv) | DMA 独立 TB（T1~T10） |
| [tb/jtag_mem_loader_tb.sv](../tb/jtag_mem_loader_tb.sv) | JTAG 单元测试 |
| [tb/jtag_rescue_top_tb.sv](../tb/jtag_rescue_top_tb.sv) | JTAG 系统级测试 |
| [scripts/jtag_rescue.py](../scripts/jtag_rescue.py) | Python 主机侧工具 |
| [doc/05_debug_guide.md](05_debug_guide.md) | JTAG 调试/救援指南 |

### 检验标准

- [ ] DMA 的 `DST_INPUT_FIFO` 和 `DST_WEIGHT_BUF` 路径有什么区别？为什么 `DST_INPUT_FIFO` 要求偶数长度？
- [ ] JTAG rescue 可以访问哪些地址范围？MMIO 访问会发生什么？
- [ ] `cpu_reset_hold` 复位 CPU 后，SRAM/SNN/外设状态会被影响吗？
- [ ] 256 周期超时机制解决什么问题？

---

## Part B 时间规划

| 天数 | 内容 | 时长 |
|------|------|------|
| Day 15-17 | UART 设计 | 6-8h |
| Day 18-20 | SPI 设计 | 6-8h |
| Day 21-24 | AXI-Lite 总线 | 8-10h |
| Day 25-27 | E203 集成 | 6-8h |
| Day 28-29 | 固件开发 | 4-6h |
| Day 30-32 | DMA 多目标 + JTAG 救援 | 6-8h |

**Part B 总计约 2.5 周**，每天投入 3-4 小时。

---

# Part C: V1.1 Tape-out 加固层

完成 Part B 后，你已经掌握了 V1 的全部数字主链路。Part C 是 **2026-04 月之后追加** 的内容，覆盖了流片前最后一段必须吃透的特性：mask boot ROM、片上 CIM 编程通路、方案 α' 外部编程接口、`chip_top` pad-facing 包装、silicon bring-up 固件与板级 FPGA 验证证据链。

**前置条件**：Part B 全部检验清单通过；能完整描述 E203 启动链。

> **为什么独立成 Part C？** 这部分内容是 Iteration 10、11 之后才并入 main，目的是为 6 月底 V1 流片做最后一公里收口。不学这一段，直接读 `chip_top.sv` 会看不懂 `ENABLE_BOOT_ROM` / `ENABLE_PROGRAM_MODE` / 方案 α' 那些 generate 块在做什么。

---

## 阶段 15：Boot ROM 与 chip_top tape-out 包装（Day 33-34）

**目标**：理解 V1.1 引入的 mask boot ROM 与 `chip_top` 顶层 wrapper，能解释三套地址映射在 `ENABLE_BOOT_ROM` 不同取值下的差异。

### 15.1 为什么需要 boot ROM

| 问题 | 原因 |
|------|------|
| ASIC 上电时 INSTR_SRAM 是 X | SRAM 没有上电态，CPU 取指会得到不可预期的指令 |
| 不能依赖 JTAG 装载 | 流片后量产板上不一定有 JTAG 调试器 |
| 不能依赖 SPI 直 boot | E203 本身是 RV32I 通用核，无 boot-from-SPI 硬件，需要 bootloader |

**解决方案**：实例化一个工艺 mask ROM（4KB @ 0x0），上电立刻跑 bootloader（`fw/boot_main.c`）→ 配置 SPI → 把 app（`fw/main.c`）从 SPI flash 搬到 INSTR_SRAM @ 0x1000 → fence.i → 跳转。

### 15.2 三套地址映射

| 配置 | 0x0 处映射 | INSTR_SRAM 起点 | 适用场景 |
|------|-----------|----------------|---------|
| `ENABLE_BOOT_ROM=0`（默认） | INSTR_SRAM 直接 | `0x0000_0000` | Gate A 旧回归、`top_tb` 直灌 hex |
| `chip_top.ENABLE_BOOT_ROM=1` | boot_rom 4KB | `0x0000_1000`（平移后）| ASIC tape-out 路径、`chip_top_rom_smoke_tb` |
| `snn_soc_fpga_top`（FPGA）| INSTR_SRAM + INSTR_INIT_FILE | `0x0000_0000` | FPGA 板级 demo（BRAM 预装 firmware） |

地址常量真源：[rtl/top/snn_soc_pkg.sv](../rtl/top/snn_soc_pkg.sv) 中
`ADDR_BOOT_ROM_BASE / ADDR_BOOT_ROM_END / ADDR_INSTR_BASE_WITH_ROM / ADDR_INSTR_END_WITH_ROM`。

### 15.3 关键 RTL 文件

| 文件 | 说明 |
|------|------|
| [rtl/mem/boot_rom.sv](../rtl/mem/boot_rom.sv) | 同步 ROM 行为模型（仿真+FPGA），ASIC 由 ROM compiler 取代；OOB 返回 0（防御性，2026-04-25 收紧） |
| [rtl/bus/bus_interconnect.sv](../rtl/bus/bus_interconnect.sv) | `ENABLE_BOOT_ROM=1` 时低 4KB 路由到 boot_rom，INSTR_SRAM 平移；`=0` 时 boot_rom 路径整个 generate-out |
| [rtl/bus/icb2simple_bridge.sv](../rtl/bus/icb2simple_bridge.sv) | 同样新增 `ENABLE_BOOT_ROM` 参数选择 INSTR 窗口 |
| [rtl/periph/jtag_mem_loader.sv](../rtl/periph/jtag_mem_loader.sv) | 同上 |
| [rtl/top/snn_soc_top.sv](../rtl/top/snn_soc_top.sv) | 透传 `ENABLE_BOOT_ROM` + `BOOT_ROM_INIT_FILE` + `INSTR_INIT_FILE` 参数 |
| [rtl/top/chip_top.sv](../rtl/top/chip_top.sv) | tape-out 顶层：默认打开 `ENABLE_BOOT_ROM=1` + ENABLE_E203=1 + ENABLE_PROGRAM_MODE=1 + ENABLE_EXT_CIM_IF=1 |

### 15.4 启动链全貌（chip_top tape-out 路径）

```
1. 上电复位（rst_n_pad 释放）
2. CPU 从 0x0 取指 → boot_rom（mask ROM，4KB）
3. boot_main.c：
   - 配置 UART (115200) 输出 "BL start"
   - 配置 SPI (Mode 0)、读 SPI flash header
   - 把 app payload 搬到 INSTR_SRAM @ 0x1000
   - fence.i → jal x0, 0x1000
4. main.c (app)：
   - UART 输出 "APP start"
   - **新：开机全阵列擦除 RRAM**（详见阶段 16）
   - 主循环：DMA + SNN 推理 → UART 输出 spike id
```

### 15.5 关键回归

| 命令 | PASS 标记 |
|------|----------|
| `bash sim/run_chip_top_rom_smoke.sh` | `CHIP_TOP_ROM_SMOKE_PASS` — 用 chip_top 顶层 + 真 boot_rom hex 跑端到端 |
| `bash sim/run_chip_top_rom_hi_smoke.sh` | 验证 0x1000 平移后 INSTR_SRAM 仍然可读写 |
| `bash sim/run_axi_instr_hi_window.sh` | AXI bridge 在 INSTR 平移窗口下的访问语义 |
| `bash sim/run_jtag_instr_hi_window.sh` | JTAG rescue 在 INSTR 平移窗口下的语义 |
| `bash sim/run_boot_rom.sh` | `BOOT_ROM_TB_PASS`（含 OOB 返回 0 检验） |

### 检验标准

- [ ] 能解释为什么 boot_rom 的 OOB 必须返回 0 而不能 wrap
- [ ] 能解释 `ENABLE_BOOT_ROM=0` 与 `=1` 时 `bus_interconnect` 译码差异
- [ ] 能解释为什么 `BOOT_ROM_INIT_FILE` 留空时 `chip_top` 仿真会打 WARN（CPU trap）
- [ ] 能解释 INSTR_INIT_FILE（FPGA 用）和 BOOT_ROM_INIT_FILE（ASIC 用）的不同适用场景

---

## 阶段 16：CIM 编程模式与 boot-time 全阵列擦除（Day 35-37）

**目标**：理解 V1 单层 CIM 写 / 擦 / verify 的硬件控制器与寄存器接口；理解 fw/main.c 开机为什么必须做一次全阵列擦除。

### 16.1 为什么 V1 也要支持编程

V1 原本只做"推理"，把权重通过 `weight_pos.hex` / `weight_neg.hex` 离线注入 macro。但器件老师在 2026-04-22 / 2026-04-24 反复确认两件事：

1. **流片后 RRAM 单元初始状态不保证是 HRS**（高阻），可能是 LRS 或随机态。
2. **开机必须先做一次全阵列擦除**，否则推理结果不可预期。

因此 V1 从 V2 移植了 `cim_program_ctrl` + `cim_macro_arbiter` 这一套编程通路，封装在 `ENABLE_PROGRAM_MODE=1` generate 块下，默认行为对旧回归零影响。

### 16.2 编程寄存器（PROG_*，0x4000_0038~0x4000_0094）

| 偏移 | 名称 | 关键位 | 说明 |
|------|------|--------|------|
| 0x38 | PROG_CTRL | [0]=START W1P, [1]=ERASE RW^1, [2]=FULL_ARRAY RW^1, [3]=BYPASS_HANDSHAKE RW^1, [7:4]=LEVEL RW^1, [10:8]=RETRY_LIMIT RW^1 | 启动一次编程操作；BYPASS=1 跳过 handshake（仿真用），生产固件保持 0 |
| 0x3C | PROG_ROW | [5:0]=row | 目标行（0~63） |
| 0x40 | PROG_COL | [4:0]=col | 目标列（0~19） |
| 0x44 | PROG_STATUS | [0]=BUSY RO, [1]=PASS RO, [2]=FAIL RO, [5:3]=RETRY_COUNT RO, [6]=PROG_FSM_PRESENT RO, [7]=DONE W1C | 状态/完成位；bit[6] 表示 ENABLE_PROGRAM_MODE 是否在硬件上启用，固件用此位代替 BUSY 探测 |
| 0x90 | PROG_PULSE_WIDTH | [17:16]=sel RW（0=1us/1=10us/2=100us/3→100us）, [15:0]=cycles RO | 写入脉冲宽度档位 |
| 0x94 | PROG_ERASE_WIDTH | [15:0]=50000 RO（1ms@50MHz）| 擦除脉冲宽度，固定，写入忽略 |

**RW^1 的含义**：寄存器在 `prog_busy=1 / prog_start_pending=1 / prog_start_pulse=1` 任一为 1 时被锁，不接受新写入。这是 2026-04-25 加的 in-flight lock，目的是防止 10-stage pad 编码器 pipeline 与 `cim_program_ctrl` 内部锁存值漂移。
覆盖：[`tb/prog_inflight_lock_tb.sv`](../tb/prog_inflight_lock_tb.sv)。

### 16.3 PROG_FSM_PRESENT 与 race-free 探测

旧固件用 "256-cycle BUSY 探测" 判断编程 FSM 是否真的存在；这种方式在快速脉冲（例如 BYPASS=1 + 短脉冲）下会被 BUSY 升起→落下越过，假阳性。新方式：

```c
uint32_t s_pre = PROG_STATUS;
if ((s_pre & PROG_STATUS_FSM_PRESENT_MASK) == 0u) {
    return 2u;   // ENABLE_PROGRAM_MODE=0 build, no-op
}
// 编程 FSM 存在 → 安全发起 START
```

PROG_STATUS[6] 是组合逻辑直接驱动 `ENABLE_PROGRAM_MODE`，编译期常量级别的可信度。

### 16.4 boot-time 全阵列擦除（fw/main.c, 2026-04-24）

```c
// 1. 探测 FSM 是否存在
if ((PROG_STATUS & FSM_PRESENT_MASK) == 0) goto skip;

// 2. 清掉旧 DONE
PROG_STATUS = DONE_MASK;

// 3. read-modify-write，保留 RETRY_LIMIT 默认值 4
PROG_ROW = 0;
PROG_COL = 0;
PROG_CTRL = (PROG_CTRL & ~LOW_MASK) | ERASE_MASK | FULL_ARRAY_MASK | START_MASK;

// 4. 轮询 DONE，超时回 0
while (poll < BOOT_ERASE_POLL_TIMEOUT) {
    s = PROG_STATUS;
    if (s & DONE_MASK) break;
}

// 5. UART 输出 "APP erase SEQ_DONE"
```

**注意语义**：返回 1 表示"controller 完成 1 ms 擦除时序"，**不**表示固件已经逐 cell verify。逐 cell verify 由 `cim_program_ctrl` 在 `prog_op=write` 时做，开机擦除是 fire-and-forget。

### 16.5 cim_program_ctrl 状态机（高层）

```
ST_IDLE
  └─ start → ST_SETUP (锁存 op/row/col/level)
       └─ ST_PULSE (脉冲发出，宽度由 PROG_PULSE_WIDTH 或 PROG_ERASE_WIDTH 决定)
            └─ ST_PULSE_HOLD
                 ├─ FULL_ARRAY=1 或 op=erase 单 cell → ST_PASS（不做 verify）
                 └─ op=write → ST_VERIFY → ST_RB_WAIT → 比对 bl_data
                      ├─ 匹配 → ST_PASS
                      └─ 不匹配 → 重试，直到 RETRY_COUNT == RETRY_LIMIT → ST_FAIL
                           ↓
                          ST_DONE (DONE sticky=1，PASS/FAIL 二选一)
```

详细状态：[rtl/snn/cim_program_ctrl.sv](../rtl/snn/cim_program_ctrl.sv)（335 行，注释详细）。

### 16.6 cim_macro_arbiter（推理 vs 编程仲裁）

| 状态 | 行为 |
|------|------|
| `prog_busy=0`（默认）| arbiter 透传推理侧信号；prog_* 全部 tie 0 |
| `prog_busy=1` | arbiter 屏蔽推理侧 done/data，把 cim_program_ctrl 的 wl/dac/cim 信号送到 cim_macro_blackbox |

互斥保证：在 `reg_bank` 的写入门控里，SNN START 与 PROG START 互锁，不会同时发起。

### 16.7 关键回归

| 命令 | PASS 标记 |
|------|----------|
| `bash sim/run_cim_program_ctrl.sh` | `CIM_PROGRAM_CTRL_PASS`（8 个子测试：写、擦、verify、retry、DONE、互锁等） |
| `bash sim/run_prog_pulse_cfg.sh` | `PROG_PULSE_CFG_TB_PASS`（4 档预设 + erase 固定） |
| `bash sim/run_prog_inflight_lock.sh` | `PROG_INFLIGHT_LOCK_TB_PASS`（18 个子测试） |
| `bash sim/run_prog_disabled_no_pending.sh` | `PROG_DISABLED_NO_PENDING_TB_PASS`：ENABLE_PROGRAM_MODE=0 时 PROG_CTRL.START 不留 pending |
| `bash sim/run_boot_erase_e2e.sh` | `BOOT_ERASE_E2E_TB_PASS`：完整 fw 开机擦除 → 控制器 SEQ_DONE → 1280 cells 全 0 readback |
| `bash sim/run_prog_start_interlock.sh` | `PROG_START_INTERLOCK_TB_PASS`：SNN/PROG 互锁正向 |
| `bash sim/run_prog_pad_encoder.sh` | `PROG_PAD_ENCODER_TB_PASS`：prog_op_ext / prog_level_ext pad 编码（详见阶段 17） |
| `bash sim/run_prog_wl_pad_route.sh` | `PROG_WL_PAD_ROUTE_TB_PASS`：编程模式下 WL pad 路由 |
| `bash sim/run_prog_bypass_latch.sh` | `PROG_BYPASS_LATCH_TB_PASS`：BYPASS_HANDSHAKE 在 START 拍锁存 |

### 检验标准

- [ ] 能说出 PROG_CTRL 七个字段以及每个字段的 RW 类型
- [ ] 能解释 in-flight lock 的目的（防 pad encoder pipeline 与 FSM 锁存值漂移）
- [ ] 能解释 PROG_STATUS[6] 替换 256-cycle BUSY 探测的动机
- [ ] 能写出 fw 开机全阵列擦除的 5 步序列
- [ ] 能区分 "controller SEQ_DONE" 与 "fw 逐 cell verify" 两种语义

---

## 阶段 17：方案 α' 外部编程接口（Day 38）

**目标**：理解 2026-04-24 冻结的方案 α'（α-prime）外部编程合同：为什么把 pad 数从 48 扩到 55，以及 7 个新增 pad 各自的语义。

### 17.1 背景

V1 数字芯片与模拟芯片是两个独立 die 通过 PCB 互联。模拟侧 RRAM 阵列需要外部 stimulate "写入电压 / 擦除电压 / verify 时序"。早期方案 α 是把 prog_op 直接驱动模拟管脚，但缺少"目标电导级数 / verify 通路"，方案 α' 在此基础上增补：

| 新增 pad | 数量 | 含义 |
|---------|------|------|
| `prog_op[2:0]` | 3 | op 编码：000=inference / 100=full_array_erase / 101=erase_single / 110=write / 111=verify |
| `prog_level[3:0]` | 4 | 目标电导等级（write 时有效，0~15） |
| 总计 | 7 | 对应 doc/15 pads 46..52 |

**移除的旧 pad**：原计划的 `prog_pass` 被去掉——verify PASS/FAIL 由数字侧根据 `bl_data` 自己算，不需要从模拟侧 strobe 出来。

### 17.2 pad 编码器 + 10-stage 相位对齐

`snn_soc_top.sv` 的 `prog_op_ext` / `prog_level_ext` 编码器把 `cim_program_ctrl` 当前操作翻译成 prog_op[2:0] + prog_level[3:0]，再过一个 10 拍 shift register 与 `cim_start_ext` 相位对齐：

```
cim_start_ext       :     ___/‾‾‾\__________________
prog_op_ext  (10st) :  ----<op>--<op>--<op>--<op>...
prog_level_ext (10st):  ----<lvl>--<lvl>--<lvl>...
                                    ↑
                       与 cim_start 同时到达模拟侧 pad
```

10 拍延迟来自 wl_mux_wrapper 的 8 cycle SEND + 1 cycle 锁存 + 1 cycle DONE，目的是让模拟侧"看到 cim_start 的同时已经看到稳定的 op/level"，避免相位失配。

### 17.3 in-flight lock 与编码器的关系

阶段 16.2 提到的 in-flight lock 直接服务于这个编码器：如果在 `prog_busy=1` 期间 CPU 改了 PROG_CTRL.LEVEL，10 拍后 prog_level_ext pad 就会从 op=A 漂到 op=B，但 `cim_program_ctrl` 还在按 op=A 的 ROW/COL 跑——数字侧与模拟 die 接口不一致直接会让一次写入定位错。

锁住的字段：ERASE / FULL_ARRAY / BYPASS / LEVEL / RETRY_LIMIT / ROW / COL / PULSE_WIDTH。

### 17.4 关键文件

| 文件 | 说明 |
|------|------|
| [rtl/top/snn_soc_top.sv](../rtl/top/snn_soc_top.sv) | `prog_op_ext` / `prog_level_ext` 编码器 + 10-stage shift register |
| [rtl/top/chip_top.sv](../rtl/top/chip_top.sv) | pad 路由：`prog_op_pad[2:0]` / `prog_level_pad[3:0]` 直连 ext 端口 |
| [doc/08_cim_analog_interface.md](08_cim_analog_interface.md) §10 | 外部编程协议正文 |
| [doc/03_cim_if_protocol.md](03_cim_if_protocol.md) 末节 | 时序细节 |
| [doc/15_asic_pad_map.md](15_asic_pad_map.md) | 55-pad 全表（pads 46..52 标注 α' 新增） |

### 17.5 关键回归

| 命令 | PASS 标记 |
|------|----------|
| `bash sim/run_prog_pad_encoder.sh` | 验证编码器对每个 op/level 的 pad 输出 |
| `bash sim/run_prog_wl_pad_route.sh` | 编程模式下 WL pad 仍能正确路由（推理通路不被破坏） |

### 检验标准

- [ ] 能说出方案 α' 7 个新 pad 的位宽与含义
- [ ] 能解释为什么 verify PASS/FAIL 不需要单独的 pad
- [ ] 能解释 10-stage shift register 与 `cim_start_ext` 相位对齐的目的
- [ ] 能解释 in-flight lock 失效会怎样让 prog_op/prog_level pad 漂移

---

## 阶段 18：Silicon bring-up 固件与 FPGA 板级证据链（Day 39-40）

**目标**：理解流片回片后的 day-1 / day-2 / day-3 上板流程，以及 ZCU102 FPGA 板级验证作为 tape-out 前的最后一道护栏。

### 18.1 silicon bring-up 固件

[fw/silicon_bringup/silicon_bringup.c](../fw/silicon_bringup/silicon_bringup.c) 是流片后第一段在真芯片上跑的代码，分四个阶段：

| 阶段 | 目的 | UART 输出 |
|------|------|---------|
| Phase 0 | 上电 self-print，确认 UART/CPU 活着 | `BRINGUP_PHASE_0_UART_OK` |
| Phase 1 | BYPASS_HANDSHAKE=1 → 全阵列擦除（不依赖模拟 die） | `BRINGUP_PHASE_1_BYPASS_ERASE_OK` |
| Phase 2 | BYPASS=0 → 真模拟擦除（依赖模拟 die 已上电） | `BRINGUP_PHASE_2_REAL_ERASE_OK` |
| Phase 3 | 真模拟写一个目标 cell + verify | `BRINGUP_PHASE_3_REAL_WRITE_VERIFY_OK` |

设计意图：在不确定模拟 die 是否真的工作时，先用 BYPASS 模式确认数字 die 自己是好的；再逐步把模拟 die 拉进来。详见 [doc/silicon_bringup_guide.md](silicon_bringup_guide.md) Day 1/2/3 SOP。

### 18.2 ZCU102 FPGA 板级证据链（main-fpga-e203 alpha）

**位置**：`feature/main-fpga-e203` 系列分支（最新冻结点：`main-fpga-e203-alpha-passed` tag）。

**FPGA wrapper**：`fpga/boards/zcu102/snn_soc_fpga_top.sv`
- 时钟：USER_SI570 300MHz 差分 → MMCM → 50MHz
- 复位：btn_rst (AM13) | !mmcm_locked → 2-FF 同步释放
- UART：on-board CP2108 J83 (F13/E13) 115200 8N1
- BRAM 预装固件：`fw/e203_smoke/e203_fpga_smoke.c` → `e203_smoke.hex` (2268 bytes)

**板级 PASS marker**（UART log 有真实抓取）：
```
FPGA_E203_BOOT_UART_PASS
[PROG] full-array erase DONE
[PROG] write subset rows=0..9 cols=0..9 PASS
FPGA_E203_PROGRAM_ERASE_WRITE_PASS
FPGA_E203_PROGRAMMED_INFERENCE_PASS
```

**为什么 FPGA 可以代替 silicon**：FPGA 上 `cim_macro_blackbox` 是行为模型 + behavioral popcount 公式（Scheme B 差分），数字逻辑路径与流片 RTL 完全一致；时钟约束 50MHz 与 ASIC 目标一致；E203 + UART + bus interconnect + reg_bank + dma + cim_program_ctrl 全部综合到 PL fabric。所以"数字侧端到端启动 → 编程 → 推理"在 FPGA 板上跑过即等价于数字 die 的端到端验证。

### 18.3 不需要重烧 FPGA 的判定标准

由 [doc/main-fpga-e203/fw_main_c_boot_erase_board_validation_analysis.md](main-fpga-e203/fw_main_c_boot_erase_board_validation_analysis.md) 给出的四条触发条件：

1. 改动 `fw/e203_smoke/e203_fpga_smoke.c`（FPGA BRAM init 固件）
2. 改动 `snn_soc_top` / `cim_program_ctrl` / `cim_macro_arbiter` / `wl_mux_wrapper` / `cim_macro_blackbox` 的**功能性**逻辑
3. 改动 ZCU102 wrapper 或 XDC
4. `fw/main.c` 引入到 FPGA pre-init（目前没有这个计划）

判定逻辑：
- **纯文档 / 纯注释 / TB-only / 防御性 OOB / 默认参数追加** → 不需要重烧
- **行为可见的 RTL 修改 / FPGA wrapper 改动 / FPGA 固件改动** → 必须重烧

main HEAD 相对于 alpha 冻结点的所有改动，按此判定都属于"防御性 + 默认参数 + TB-only"，**不触发重烧**。

### 18.4 关键回归与脚本

| 命令 | 用途 |
|------|------|
| `bash sim/run_silicon_bringup.sh` | 跑 silicon_bringup 固件的 Icarus 仿真，验证 4 个 phase 的 UART 输出 |
| `bash scripts/fpga_bringup_capture.sh`（在 alpha 分支）| 板上 UART capture 自动化 |
| `python scripts/program_zcu102_e203.tcl`（Vivado）| 烧 bitstream + BRAM init |

### 检验标准

- [ ] 能说出 silicon_bringup 固件的 4 个 Phase 与每个 Phase 的 UART 标记
- [ ] 能解释为什么 Phase 1 用 BYPASS_HANDSHAKE=1 而 Phase 2/3 不用
- [ ] 能复述"是否触发 FPGA reburn"的 4 条判定标准
- [ ] 能解释 FPGA 板上验证为什么可以代替 silicon 的端到端启动→编程→推理验证

---

## Part C 时间规划

| 天数 | 内容 | 时长 |
|------|------|------|
| Day 33-34 | 阶段 15：boot ROM + chip_top | 5-6h |
| Day 35-37 | 阶段 16：CIM 编程模式 + boot-time erase | 8-10h |
| Day 38 | 阶段 17：方案 α' 外部编程接口 | 3-4h |
| Day 39-40 | 阶段 18：silicon bring-up + FPGA 证据链 | 4-6h |

**Part C 总计约 1 周**，每天投入 3-4 小时。

---

## 学习资源汇总

### MVP 基础
- 项目文档：`doc/00_overview.md` ~ `doc/05_debug_guide.md`
- 接口文档：`doc/08_cim_analog_interface.md`（片外/片上数模混合集成用）
- 参考书：《Verilog HDL 高级数字设计》

### V1 进阶
- UART/SPI：搜索 "FPGA UART/SPI 设计"
- AXI：ARM AMBA AXI4-Lite 官方规范
- E203：https://github.com/SI-RISCV/e200_opensource
- RISC-V：《手把手教你设计 CPU——RISC-V 处理器篇》

### V1.1 Tape-out 加固（Part C）
- mask ROM 设计：foundry ROM compiler 用户手册（每家工艺都不同）
- RRAM 编程电压 / 时序：项目 `doc/08_cim_analog_interface.md` §10
- 方案 α' 外部编程合同：项目 `doc/03_cim_if_protocol.md` 末节 + `doc/15_asic_pad_map.md`
- silicon bring-up SOP：项目 `doc/silicon_bringup_guide.md`（Day 1/2/3）
- FPGA 板级证据链：`doc/main-fpga-e203/fw_main_c_boot_erase_board_validation_analysis.md`

### 工具
- VCS/Verdi：Synopsys 官方文档
- Design Compiler：综合工具
- OpenOCD/GDB：调试工具
- Vivado 2022.2（FPGA 综合 + 板上烧写）

---

*最后更新：2026-04-29（main 分支 V1 + V1.1 全量复核 + Part C 增补）*

**学习建议**：Part A 必须完全掌握后再开始 Part B；Part B 通了再读 Part C，不要跳读。每个阶段学完后，尝试写一段代码或画一个图来验证理解。遇到问题及时记录，积极讨论。

---

# Part D: V2 ARM PS-PL FPGA Demo 集成（本分支特有）

**目标**：理解 ZCU102 ARM Cortex-A53 (PS) + V2.B 加速器 (PL fabric) 演示链路，能解释 AXI4-Lite HPM0 接入、ARM 裸机 C 固件、Vivado Block Design 流程和 v1/v2 双 tag 证据策略。

**前置条件**：
- Part A/B/C 全部检验清单通过
- 至少看过 [doc/arm-fpga-demo/00_architecture.md](arm-fpga-demo/00_architecture.md)（本分支根目录的架构正文）

> **本分支独立性**：feature/v2-arm-fpga-demo 是 evidence branch，永久保留不合并。它的目的是用 ZCU102 上的 ARM 裸机 + PL 加速器演示 V2.B（streamed-stage MAC + multilayer）的端到端推理。学习它有助于理解"如果不要 RISC-V 软核，而用现成 ARM PS 来驱动 SNN 加速器"的架构选项。

---

## 阶段 19：ZCU102 ARM PS-PL 集成基础（Day 41-43）

### 19.1 ZCU102 架构鸟瞰

```
┌──────────────────── PS (Processing System) ─────────────────────┐
│  ARM Cortex-A53 ×4  (运行裸机 C，aarch64-none-elf-gcc 编译)     │
│       │                                                          │
│       ├─ DDR4 RAM (PS 侧)                                        │
│       ├─ UART0 (硬核外设，板上 USB-UART)                         │
│       └─ HPM0_FPD (M_AXI HPM0 → PL，用于 MMIO 访问 PL fabric)    │
│                                                                  │
└──────────┬─────────────────────────────────────────────────────┘
           │ AXI4-Lite (PL fabric clk = 50 MHz)
           ▼
┌──────────────────── PL (Programmable Logic) ────────────────────┐
│  v2b_arm_demo_top                                                │
│   ├─ v2b_axi_wrapper      (AXI4-Lite Slave + WSTRB byte-mask)    │
│   ├─ simple2v2btop_adapter (simple_bus → v2b_bus 4-state FSM)    │
│   └─ snn_soc_v2b_top      (V2.B 加速器内核)                      │
│        ├─ stage_engine_v2  (tile-mode 调度)                      │
│        ├─ cim_mac_behavioral_v2 (WL-serial + j-parallel MAC)     │
│        ├─ stream_buffer_v2 (A/B 缓冲)                             │
│        ├─ tile_partial_buf (flat 1D BRAM)                        │
│        ├─ layer_sequencer  (多层串流)                             │
│        ├─ spike_feedback   (跨层反馈)                             │
│        └─ lif_neuron_alu   (LIF 计算)                            │
└──────────────────────────────────────────────────────────────────┘
```

### 19.2 与 V1 main 主线的关键区别

| 维度 | V1 main（ASIC tape-out） | 本分支（ARM FPGA demo） |
|------|-----------------------|----------------------|
| CPU | E203 RV32I 软核 (PL fabric) | ARM Cortex-A53 (PS 硬核) |
| 启动 | mask ROM @ 0x0 → SPI → INSTR_SRAM | PS DDR 直接跑裸机 ELF |
| 总线 | ICB → simple_bus | AXI4-Lite HPM0 → simple_bus |
| 加速器 | V1 单层 64×20 (cim_macro_blackbox) | V2.B streamed-stage multilayer |
| 调度 | 一次 80 子时间步推理 | tile-mode + 多层串流 |
| FW 工具链 | riscv64-unknown-elf-gcc | aarch64-none-elf-gcc |
| 烧写 | bitstream + BRAM init | bitstream + ELF (xsct program) |
| 数据集 | MNIST 8×8 (avgpool) | Fashion-MNIST 14×14 |

### 19.3 关键阅读文件

| 文件 | 说明 |
|------|------|
| [rtl/top/v2b_arm_demo_top.sv](../rtl/top/v2b_arm_demo_top.sv) | OOC 综合顶层（端口 re-expose 给 BD） |
| [rtl/top/v2b_axi_wrapper.sv](../rtl/top/v2b_axi_wrapper.sv) | AXI4-Lite slave 包装器（WSTRB byte-mask 已修复） |
| [rtl/bus/simple2v2btop_adapter.sv](../rtl/bus/simple2v2btop_adapter.sv) | simple_bus → V2.B 命令适配 4 态 FSM |
| [doc/arm-fpga-demo/00_architecture.md](arm-fpga-demo/00_architecture.md) | 顶层架构 + Phase 定义 + tag policy |
| `fpga_synth/zcu102_arm_demo/` | Vivado 工程目录（build TCL + BD） |

### 检验标准

- [ ] 能画出 PS HPM0 → PL AXI Slave → simple → V2.B 的总线层级
- [ ] 能解释为什么用 AXI4-Lite 而不是 AXI4-Full（带宽 vs 复杂度）
- [ ] 能说出本分支固件的工具链与 V1 main 的差异
- [ ] 能解释 v2b_arm_demo_top 与 snn_soc_v2b_top 的区别

---

## 阶段 20：AXI4-Lite slave + WSTRB byte-mask（Day 44-45）

**目标**：理解 v2b_axi_wrapper 如何处理部分字节写（partial WSTRB），以及 F1 修复案例的来龙去脉。

### 20.1 partial WSTRB bug（v1 frozen 的隐性缺陷）

**v1 frozen tag** (`8e51ae27`) 的 `v2b_axi_wrapper` 在 WSTRB ≠ `4'hF`（不是全字写）时，把 `wdata` 整体写入寄存器，没有按字节屏蔽。这在 ARM PS 端的实际固件路径下不会触发——因为裸机 C 都用 `volatile uint32_t *` 全字写——但**理论上是协议违例**。

**触发条件**（仅理论 / TB 抓取）：
- `wstrb=4'b0011`（只写低 16 位）+ wdata=0xFFFF_FFFF → 期望寄存器只更新低 16 位，但实际 32 位都被覆盖。
- 对 W1P / W1C 寄存器尤其危险：高位的 sticky 状态会被错误清掉。

### 20.2 F1 修复方案

commit `bd860dcc` (`fix(v2-arm-fpga-demo/F1): honor WSTRB in V2.B AXI endpoint`)：

```systemverilog
function automatic logic [31:0] apply_wstrb(
    input logic [31:0] old_val,
    input logic [31:0] new_val,
    input logic [3:0]  wstrb
);
  apply_wstrb = '0;
  apply_wstrb[7:0]   = wstrb[0] ? new_val[7:0]   : old_val[7:0];
  apply_wstrb[15:8]  = wstrb[1] ? new_val[15:8]  : old_val[15:8];
  apply_wstrb[23:16] = wstrb[2] ? new_val[23:16] : old_val[23:16];
  apply_wstrb[31:24] = wstrb[3] ? new_val[31:24] : old_val[31:24];
endfunction
```

15 处寄存器写改用 `apply_wstrb(old, new, wstrb)`。AXI 栈级 TB [tb/v2b_axi_partial_write_tb.sv](../tb/v2b_axi_partial_write_tb.sv) 通过 `sim/run_v2b_axi_partial_write.sh` 验证，8 个 case 全 PASS；本分支另补一个 direct-top permanent gate [tb/v2b_partial_write_invariant_tb.sv](../tb/v2b_partial_write_invariant_tb.sv)，专门守住 `snn_soc_v2b_top.cmd_wstrb` 的 W1P/W1C invariant。

### 20.3 重烧 (reburn) 决策与证据

| 项 | 内容 |
|------|------|
| 修复 commit | `bd860dcc`（F1） |
| 重烧 commit | `ea31be22`（v2 board PASS log） |
| 新 bitstream SHA256 | `78A5F36CFB241FBC...` |
| 新 ELF SHA256 | `AEEB02A06A74E0BF...` |
| 新 XSA SHA256 | `9EAFBD3CC9867150...` |
| Manifest | [doc/arm-fpga-demo/build_manifest_v2.txt](arm-fpga-demo/build_manifest_v2.txt) |
| HEAD vs reburn 改动 | 仅 doc + RTL 注释（F8 / F9） → **不再触发 reburn** |

**判定原则**（适用于本分支后续所有改动）：
- WSTRB byte-mask 行为变化 → reburn
- AXI 寄存器位段语义变化 → reburn
- v2b 加速器内部 RTL（cim_mac / stage_engine / stream_buffer / tile_partial_buf）变化 → reburn
- 纯文档 / 纯注释 / TB-only / 不进 BD 综合 → 不 reburn

### 检验标准

- [ ] 能写出 `apply_wstrb` 的 4 字节 mask 逻辑
- [ ] 能解释为什么裸机 C 固件不会触发 partial WSTRB
- [ ] 能说出 F1 修复后必须重烧的理由
- [ ] 能列举本分支 HEAD 后的"不需要 reburn"改动有哪些

---

## 阶段 21：V2.B streamed-stage MAC pipeline（Day 46-49）

**目标**：理解 V2.B 在 V1 cim_macro_blackbox 之上做的**两个最大变化**：(a) WL-serial j-parallel 计算结构；(b) tile-mode 调度。

### 21.1 V1 vs V2.B MAC 结构

V1 main 的 `cim_macro_blackbox`：popcount 公式（行为模型），一次拿到整列差分结果，**不真做 MAC**。V2.B 的 `cim_mac_behavioral_v2`：
- WL 维度串行（每拍 1 根 WL）
- j（输出列）维度并行（同时算 NUM_OUTPUTS 列）
- 内部用 adder tree 累加
- 接受时序约束：50 MHz @ ZCU102，WNS > 0

```
[V1] popcount(wl_latched)  → bl_data[j] = popcount * 2 + j (假数据)
[V2.B] for k in 0..63:                                  ← 64 个 cycle，WL 串行
         for j in 0..NUM_OUTPUTS-1: parallel             ← j 维并行
           psum[j] += weight[k][j] * (wl[k] ? 1 : 0)
```

### 21.2 stage_engine_v2 与 tile-mode

V2.B 把整个推理拆成多个 **tile**（小子矩阵），每个 tile：
1. `stream_buffer_v2` 从 input_stream_sram 取一段输入到 A/B 双缓冲
2. `cim_mac_behavioral_v2` 跑 WL-serial j-parallel MAC，结果累加到 `tile_partial_buf`
3. 所有 tile 跑完后 → `lif_neuron_alu` 算 spike → `spike_feedback` 发给下一层
4. `layer_sequencer` 控制层间切换

详见 [tb/v2b_axi_partial_write_tb.sv](../tb/v2b_axi_partial_write_tb.sv) / [tb/v2b_partial_write_invariant_tb.sv](../tb/v2b_partial_write_invariant_tb.sv) 的子 invariants 与 [doc/arm-fpga-demo/00_architecture.md](arm-fpga-demo/00_architecture.md) §3 数据流。

### 21.3 关键 RTL 文件

| 文件 | 行数 | 说明 |
|------|------|------|
| [rtl/snn/cim_mac_behavioral_v2.sv](../rtl/snn/cim_mac_behavioral_v2.sv) | ~150 | WL-serial j-parallel MAC（FPGA-friendly refactor） |
| [rtl/snn/stage_engine_v2.sv](../rtl/snn/stage_engine_v2.sv) | ~250 | tile-mode FSM |
| [rtl/snn/stream_buffer_v2.sv](../rtl/snn/stream_buffer_v2.sv) | ~100 | A/B 缓冲 |
| [rtl/snn/tile_partial_buf.sv](../rtl/snn/tile_partial_buf.sv) | ~80 | flat 1D BRAM, ram_style distributed |
| [rtl/snn/layer_sequencer.sv](../rtl/snn/layer_sequencer.sv) | ~120 | 多层串流控制 |
| [rtl/snn/lif_neuron_alu.sv](../rtl/snn/lif_neuron_alu.sv) | ~80 | LIF spike 算子 |
| [rtl/snn/spike_feedback.sv](../rtl/snn/spike_feedback.sv) | ~80 | 跨层反馈 |

### 21.4 历史 synth 反模式（已闭环）

[doc/19_phase_d_synthesis_readiness.md](19_phase_d_synthesis_readiness.md) 记录了 V2.B 在 phase-D 综合阶段踩过的几个坑：
- broadcast-reset / 2D unpacked array
- ram_style 默认推 dual-port BRAM 浪费面积
- cim_mac 全并行 MAC 综合 hang

修复 commits：`5e0cb552` / `00717074` / `41790ff1`。最终 phase-B bitgen WNS 4.837 ns @ 50 MHz，0 routing errors。

### 检验标准

- [ ] 能画出 cim_mac_behavioral_v2 的 WL-serial j-parallel 数据流
- [ ] 能解释 tile-mode 相对于"全矩阵一次算"的收益（BRAM 面积 vs latency）
- [ ] 能解释 stream_buffer_v2 的 A/B 双缓冲为什么能 overlap 取数与计算
- [ ] 能说出 phase-D 综合反模式的 3 条主要坑

---

## 阶段 22：ARM 裸机固件与板上烧写流程（Day 50-51）

### 22.1 工具链与构建

```bash
# 编译器
aarch64-none-elf-gcc -O2 -ffreestanding -nostdlib \
    -Wl,-T,linker.ld \
    main.c startup.S -o demo.elf

# Vivado 工程构建
cd fpga_synth/zcu102_arm_demo
vivado -mode batch -source build_arm_demo.tcl
# 输出：design_1_wrapper.bit + .xsa

# 板上烧写（Xilinx XSCT）
xsct program_zcu102_arm_demo.tcl
# 内部步骤：
#   - connect to JTAG cable
#   - source psu_init.tcl
#   - fpga -file design_1_wrapper.bit
#   - dow demo.elf
#   - con
#   - 抓取 UART0 的 PASS marker
```

### 22.2 v1 / v2 双 tag 策略

| Tag | 指向 | 状态 |
|-----|------|------|
| `v2-arm-fpga-demo-passed` | `8e51ae27` (v1 frozen) | 永久保留，论文/简历可引用 |
| `v2-arm-fpga-demo-v2-passed` | `03a39a61`（annotated tag；artifact-bearing reburn log 从 `ea31be22` 开始） | F1 修复后重烧 PASS 基线 |

**复现优先用 v2 tag**：因为 v1 有 partial WSTRB 协议问题（虽然不触发，但讲解时容易让评审困惑）。**对比研究可用 v1 tag**：保留早期版本不可变性。

### 22.3 关键回归与板上证据

| 命令 | 标记 |
|------|------|
| `cd sim && bash run_v2b_axi_partial_write.sh` | `V2B_AXI_PARTIAL_WRITE_TB_PASS`（AXI 栈级 partial-write 回归） |
| `cd sim && bash run_v2b_partial_write_invariant.sh` | `V2B_PARTIAL_WRITE_INVARIANT_TB_PASS`（direct-top permanent invariant gate） |
| `cd sim && bash run_axi_arm_cosim_resident_14x14.sh` | `AXI_ARM_COSIM_RESIDENT_14X14_TB_PASS` |
| 板上 UART log | `ARM_FPGA_DEMO_ACCEL_FASHION10_PASS` + `ARM_FPGA_DEMO_SCHEDULER_FASHION10_PASS` |

### 22.4 致命风险与已闭环项

| 项 | 状态 | 证据 |
|------|------|------|
| WSTRB byte-mask | ✅ FIXED + reburned | F1 / `bd860dcc` / new bitstream SHA |
| 综合 hang / 不收敛 | ✅ RESOLVED | `5e0cb552` / `00717074` / `41790ff1` |
| 综合反模式记录 | ✅ DOCUMENTED | doc/19 |
| pad-cell P&R blocker（chip_top） | ⚠ 标记 | F8 注释升级，不阻塞 FPGA branch |
| DMA dst SRAM byte-offset | ✅ DOCUMENTED | F9 注释升级，alpha-passed 行为已确认 |
| tag 与 SHA 对应关系 | ✅ LOCKED | manifest_v2.txt 完整记录 |

### 检验标准

- [ ] 能说出从 ELF + bitstream 到 PASS 标记的完整烧写步骤
- [ ] 能解释 v1 / v2 双 tag 策略的设计意图
- [ ] 能复述 F1 修复后的回归证据链
- [ ] 能说出本分支当前没有任何阻塞 reburn 的 RTL 改动

---

## Part D 时间规划

| 天数 | 内容 | 时长 |
|------|------|------|
| Day 41-43 | 阶段 19：ZCU102 ARM PS-PL 集成基础 | 6-8h |
| Day 44-45 | 阶段 20：AXI4-Lite slave + WSTRB | 5-6h |
| Day 46-49 | 阶段 21：V2.B streamed-stage MAC | 10-12h |
| Day 50-51 | 阶段 22：ARM 裸机固件 + 板上烧写 | 5-6h |

**Part D 总计约 1.5 周**，每天投入 3-4 小时。

---

*Part D 最后更新：2026-04-29（基于 v2-arm-fpga-demo Claude 复核基线 HEAD = eed19406；本次 GPT 仅补 doc/TB gate，不影响 FPGA bitstream）*

**学习建议**：本分支是"evidence branch"，优先看 `doc/arm-fpga-demo/00_architecture.md` 与板级证据日志，再回到 RTL 看实现。建议在阅读 cim_mac_behavioral_v2 / stage_engine_v2 之前先把 V1 的 cim_macro_blackbox / cim_array_ctrl 看懂，这样能看出 V2.B 重构的关键演进点。
