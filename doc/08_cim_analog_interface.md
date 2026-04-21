# CIM 模拟接口规范（CIM Analog Interface Specification）

**文档用途**：供数字芯片团队与模拟 CIM 芯片团队进行双芯片 PCB 集成接口商讨
**版本**：v3.2（V2 编程接口 §10 + V2 ADC 扫描参数化 §11）
**日期**：2026-04-18（V2 编程脉冲/擦除接口补充 + bl_sel 从 5-bit 扩到 7-bit 支持多层可配扫描）
**时钟频率目标**：50MHz（周期 20ns）
**参数口径**：本文涉及的默认时序参数以 `rtl/top/snn_soc_pkg.sv` 为准，若与文档不一致以 pkg 为准。
**集成架构**：数字芯片与模拟 CIM 芯片为**独立封装、分别流片**，通过 PCB 走线互联（非片上集成）。

---

## 1. 概述

### 1.1 集成背景

本项目为**双芯片 PCB 集成**架构的 SNN 系统：数字芯片与模拟 CIM 芯片分别流片、独立封装，通过 PCB 走线互联。

**数字芯片**（独立 die）负责：
- SoC 控制逻辑（E203 CPU、总线、DMA、寄存器）
- SNN 控制器（时序协调、WL 复用发送）
- LIF 神经元（数字累加和阈值比较）
- 外设（UART、SPI、JTAG）

**模拟 CIM 芯片**（独立 die）负责：
- CIM Macro（128×256 RRAM 阵列，模拟计算核心）
- DAC（数字到模拟转换，WL de-mux + 电压驱动）
- ADC（模拟到数字转换，1 路 8-bit SAR ADC + 20:1 MUX）

**PCB 互联**：两颗芯片通过 PCB 走线连接，接口信号见 §1.3 外部复用口径；ASIC pad/pin 正式真源见 [`doc/15_asic_pad_map.md`](15_asic_pad_map.md)。PCB 走线需关注信号完整性（串扰、延迟匹配），详见 §5。

### 1.2 接口边界

```
┌─────────────────────────────────────────────────────────────┐
│              数字芯片（独立 die，独立封装）                     │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│  │ DAC Ctrl │    │ CIM Ctrl │    │ ADC Ctrl │              │
│  │(wl_mux)  │    │  (FSM)   │    │(差分减法) │              │
│  └────┬─────┘    └────┬─────┘    └────┬─────┘              │
│       │               │               │                     │
│  ═════╪═══════════════╪═══════════════╪═════ 数字芯片 pad   │
└───────┼───────────────┼───────────────┼─────────────────────┘
        │               │               │
  ~~~~~~│~~~~~~~~~~~~~~~│~~~~~~~~~~~~~~~│~~~~~~  ← PCB 走线互联
        │               │               │
┌───────┼───────────────┼───────────────┼─────────────────────┐
│  ═════╪═══════════════╪═══════════════╪═════ 模拟芯片 pad   │
│       ▼               ▼               ▼                     │
│  ┌─────────────────────────────────────────┐               │
│  │           CIM Macro (Analog)            │               │
│  │  ┌─────┐   ┌─────────┐   ┌─────┐       │               │
│  │  │ DAC │ → │ CIM阵列 │ → │ ADC │       │               │
│  │  └─────┘   └─────────┘   └─────┘       │               │
│  └─────────────────────────────────────────┘               │
│              模拟 CIM 芯片（独立 die，独立封装）               │
└─────────────────────────────────────────────────────────────┘
```

---

### 1.3 V1 冻结口径（必须遵守）

为避免后续接口漂移，V1 统一采用“内部并行 + 外部复用”双层口径：

- 内部并行口径（当前 `snn_soc_top` / `cim_macro_blackbox`）：
  `wl_spike[63:0] + dac_valid + cim_start/done + bl_sel[6:0] + adc_start/done + bl_data[7:0]`
  > **V2 更新**：`bl_sel` 从 5-bit 扩到 **7-bit**（`$clog2(MAX_BL_SCAN=128)`），V1 推理只用低 5 位（值 0-19），
  > V2 多层支持最多 128 路扫描（见 §11）。流片时 V1 baseline 仅需模拟侧接 bl_sel[4:0]；
  > 若未来 V2 多层要和模拟 macro 联调，需要模拟侧 BL MUX 支持 7-bit 寻址。
- 外部复用口径（对应数字芯片 72-pad 预算中的 V1 baseline 功能信号子集，供 chip_top/pad 使用）：
  `wl_data[7:0] + wl_group_sel[2:0] + wl_latch + cim_start/done + bl_sel[6:0] + bl_data[7:0] + clk + rst_n`
  > **V2 新增 pad**：`prog_en + erase_en + verify_en`（3 pin，告知模拟侧当前操作模式，见 §10）
  > 加上 bl_sel 扩宽 2 pin，V2 对数字芯片 pad 预算的净增 = 5 pin，数字 72 pad 总预算仍有 19 pin 富余。
  > 模拟芯片 48 pad 的接收侧如果也需要扩 bl_sel，请评估其 pad 预算。

当前 RTL 已加入协议原型：`rtl/snn/wl_mux_wrapper.sv`。

#### 1.3.1 WL 复用协议字段与拍数（冻结版）

| 字段 | 方向 | 位宽 | 说明 |
|:---|:---:|---:|:---|
| `wl_data` | D→A | 8 | 当前组（8 条 WL）的数据 |
| `wl_group_sel` | D→A | 3 | 组号，范围 0~7 |
| `wl_latch` | D→A | 1 | 组合输出，ST_SEND 全程（8 拍）保持高电平，与 `wl_data`/`wl_group_sel` 同拍有效，模拟侧在 `wl_latch=1` 期间每拍采样对应组数据 |
| `wl_ready` | A→D | 0 | **V1 不使用该信号**（无 ready，固定时序） |

固定时序（每个 bit-plane）：

1. 进入复用发送后，总计 10 拍：`1(锁存/进入发送) + 8(组 0→7) + 1(完成)`。  
2. 发送阶段每拍 `wl_latch=1`，`wl_data` 与 `wl_group_sel` 同拍有效。  
3. 复用发送完成后，进入内部固定时序 DAC 阶段（`dac_valid` 单拍仅用于行为模型锁存触发）与后续 `cim_start` 流程。  

#### 1.3.2 责任归属（明确条款）

- 数字侧负责：
  `wl_mux_wrapper` 发送顺序、组号编码、锁存脉冲时序；`bl_sel` 扫描与 Scheme B 数字差分减法。
- 模拟芯片侧负责：
  接收 `wl_data[7:0]/wl_group_sel[2:0]/wl_latch` 并在**模拟芯片内部**完成 WL de-mux（8 组 × 8bit 锁存器，共 64 根字线驱动）；CIM MAC + ADC 转换的模拟实现，以及 `cim_done/bl_data` 返回时序。
  **简化协议**：外部接口不使用 `adc_start/adc_done` 信号（省 2 pin）。模拟芯片在收到 `cim_start` 后内部自行完成 CIM MAC 计算 + 全部 20 通道 ADC 转换，完成后拉高 `cim_done`；数字侧在 `cim_done` 后扫描 `bl_sel` 读取 `bl_data`（固定建立时间，无逐通道握手）。
  具体 de-mux 架构：模拟芯片内部有 8 个 8-bit 锁存器组，`wl_latch=1` 期间按 `wl_group_sel` 将 `wl_data` 写入对应锁存器；8 组全部写入后还原完整 64-bit WL 驱动向量。
- 后端/PCB 集成负责：
  **数字芯片侧**：在 `chip_top/pad wrapper` 完成数字芯片的 pad 复用映射与约束收敛。
  **模拟芯片侧**：完成模拟芯片的 pad 布局与信号引出。
  **PCB 设计**：完成两颗芯片之间的 PCB 走线互联，保证信号完整性（特别是 `bl_data[7:0]` 等高速信号的延迟匹配与串扰控制）。

---

## 2. 接口信号定义

### 2.1 信号总表

> 说明：本节表格为**内部并行接口口径**（`snn_soc_top` 与 `cim_macro_blackbox` 之间，仅用于仿真）。
> 实际双芯片 PCB 互联使用**数字芯片 72-pad 预算中的外部复用口径**，以 §1.3 和 `doc/15_asic_pad_map.md` 为准。

| 信号名 | 方向 | 位宽 | 类型 | 说明 |
|:---|:---:|---:|:---:|:---|
| **时钟和复位** |||||
| `clk` | D→A | 1 | 时钟 | 系统时钟，50MHz |
| `rst_n` | D→A | 1 | 复位 | 异步复位，低有效 |
| **DAC 接口** |||||
| `wl_spike` | D→A | 64 | 数据 | 字线输入，64路并行 bit-plane |
| `dac_valid` | D→A | 1 | 脉冲 | DAC 数据有效，单拍脉冲（行为模型锁存触发）；真实芯片侧由 `wl_latch` 时序控制 |
| ~~`dac_ready`~~ | ~~A→D~~ | ~~1~~ | ~~握手~~ | **已移除（2026-02-27）**：模拟侧采用固定时序 de-mux，无需握手回路 |
| **CIM 计算接口** |||||
| `cim_start` | D→A | 1 | 脉冲 | CIM 计算启动，单拍脉冲 |
| `cim_done` | A→D | 1 | 脉冲 | CIM 计算完成，单拍脉冲 |
| **ADC 接口** |||||
| `bl_sel` | D→A | 7 | 控制 | 位线选择。V1 推理固定 0-19 有效（Scheme B：10 正 + 10 负，低 5 位即可覆盖）；V2 多层最多 0-127，见 §11。**流片时模拟侧至少接 5 位**，如果后续要支持多层扩展再决定是否接满 7 位 |
| `adc_start` | D→A | 1 | 脉冲 | ADC 采样启动，单拍脉冲（**仅内部仿真，不在外部 pad 接口中**） |
| `adc_done` | A→D | 1 | 脉冲 | ADC 采样完成，单拍脉冲（**仅内部仿真，不在外部 pad 接口中**） |
| `bl_data` | A→D | 8 | 数据 | 当前通道 ADC 输出，8-bit |

**注**：D→A = 数字芯片到模拟芯片（经 PCB 走线），A→D = 模拟芯片到数字芯片（经 PCB 走线）

## ADC 和 DAC 的位宽

|模块|位宽|数量|说明|
|---|---|---|---|
|**DAC**|**1-bit**|**64 路**|每个字线是单bit数字信号 (0/1)|
|**ADC**|**8-bit**|**1 路**|时分复用20个通道（Scheme B），每次输出8-bit|

### 详细说明

#### 1. DAC 部分（数字 → 模拟）

```systemverilog
input logic [63:0] wl_spike;  // 64个1-bit数字信号
```

- **每个 wl_spike[i] 是 1-bit 数字信号**（0 或 1）
- 模拟宏内部的 DAC 将这 64 个 1-bit 数字信号转换成模拟电压/电流
- 用于驱动 64 根字线（Word Line）

**架构图**（内部并行口径，仿真用；实际 PCB 使用 WL 复用口径 §1.3）：

```
数字芯片（wl_mux 复用后）       PCB        模拟芯片（内部 de-mux 后）
wl_data[7:0] + group_sel ──►  走线  ──► WL de-mux ──► 64 根 WL 电压驱动
```

#### 2. ADC 部分（模拟 → 数字）

```systemverilog
input  logic [4:0] bl_sel;    // 选择通道 0-19（Scheme B）
output logic [7:0] bl_data;   // 8-bit 输出
```

- **1 个 8-bit ADC**，时分复用采样 20 个位线通道（Scheme B）
- 通过 `bl_sel` 选择当前采样哪个通道（0-19，Scheme B）
- 输出 `bl_data[7:0]` 是 8-bit 数字值

**时分复用流程**：

```
模拟芯片内部                           PCB         数字芯片
BL0  电流 ─┐                          走线
BL1  电流 ─┤                           │
...       ├─► 20:1 MUX ──► 8-bit ADC ──► bl_data[7:0] ──► ADC ctrl（差分减法）
BL19 电流 ─┘      ▲                           ▲
                 │                           │
            bl_sel[4:0] ◄──── PCB 走线 ◄──── 数字芯片发出
```

---

## 总结

|参数|值|
|---|---|
|DAC 精度|1-bit（数字驱动）|
|DAC 通道数|64 路（并行）|
|ADC 精度|8-bit|
|ADC 通道数|20 路（时分复用，Scheme B：10 正 + 10 负）|

**为什么这样设计？**

- DAC 只需要 1-bit：因为是 SNN（脉冲神经网络），输入就是 0/1 的 spike
- ADC 使用 8-bit：当前冻结建模结果确认 8-bit 精度已足够（`avgpool8x8 + ADC=8 + W=4 + T=10 + ratio_code=1`，其中 `W=4` 属于历史训练/量化实验参数，不是当前 RTL package 参数；hardware-aligned spike-only 测试精度 87.76%，zero-spike=0%）
- 双芯片架构：数字芯片和模拟芯片分别流片，通过 PCB 互联，降低混合工艺集成风险
### 2.2 信号详细说明

#### 2.2.1 wl_spike[63:0]

**功能**：输入字线驱动信号

**数据格式**：
- 表示同一子时间步的 64 维特征的某一 bit
- `wl_spike[i] = 1` 表示第 i 维特征在当前 bit-plane 为 1
- 共 8 个 bit-plane（对应 8-bit 特征值）
- 处理顺序：MSB-first（bit7 → bit0）

**时序要求**：
- 在 `dac_valid` 单拍到来时，`wl_spike` 必须稳定
- 行为模型在 `dac_valid` 单拍锁存 `wl_spike`；真实芯片侧由 `wl_latch` 时序控制

```
           ┌───────────────────┐
wl_spike   │    稳定数据        │
           └───────────────────┘
                   ↑
dac_valid  ────────┼────────────  (单拍脉冲)
                   │
                锁存点（行为模型）
```

#### 2.2.2 dac_valid（单拍触发）

**功能**：触发行为模型锁存 `wl_spike`；不是 backpressure 握手

**时序**：
```
clk        ─┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──
            └──┘  └──┘  └──┘  └──┘  └──┘  └──┘

wl_spike   ══════╱ 有效数据  ╲══════════════════
                 │          │
dac_valid  ──────┼──▓───────┼─────────────────
                 │          │
                 └── 行为模型锁存触发点
```

**约束**：
- `dac_valid` 必须是 1 个 cycle 脉冲
- `dac_valid` 脉冲到来时 `wl_spike` 需已稳定
- 数字控制链路按固定 `DAC_LATENCY_CYCLES` 等待后再发 `cim_start`

#### 2.2.3 cim_start / cim_done

**功能**：CIM 计算控制

**时序**：
```
clk        ─┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──
            └──┘  └──┘  └──┘  └──┘  └──┘  └──┘  └──┘  └──┘

cim_start  ──────┐  ┌─────────────────────────────────────
                 └──┘  (单拍脉冲)

           ←─────── CIM 计算时间 (CIM_LATENCY) ────────→

cim_done   ──────────────────────────────────────┐  ┌─────
                                                  └──┘
```

**参数**：
- `CIM_LATENCY_CYCLES`：CIM 计算延迟周期数
- 当前仿真默认值：10 cycles
- **模拟部分需要提供实际延迟范围**

#### 2.2.4 bl_sel[4:0]

**功能**：ADC 通道选择（时分复用 MUX 控制）

**有效范围**：0-19（Scheme B：0-9 正列，10-19 负列，共 20 通道）

**时序要求**：
- 切换后需等待 MUX 建立时间（`ADC_MUX_SETTLE_CYCLES`）
- 当前仿真默认值：2 cycles
- **模拟部分需要提供实际 MUX 建立时间**

#### 2.2.5 adc_start / adc_done / bl_data

**功能**：ADC 采样控制和数据输出

**时序**：
```
clk        ─┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──┐  ┌──
            └──┘  └──┘  └──┘  └──┘  └──┘  └──┘

bl_sel     ══════╱  N  ╲════════════════════════
                 │     │
settle     ──────┼─────┼─── MUX 建立时间 ────────
                 │     │
adc_start  ──────┼─────┼───┐  ┌─────────────────
                 │     │   └──┘
                 │     │
           ←─────┼─────┼── ADC 采样时间 ────────→
                 │     │
adc_done   ──────┼─────┼──────────────────┐  ┌──
                 │     │                   └──┘
                 │     │                     │
bl_data    ══════╱═════╲═════════════════════╲ 有效数据
                                               │
                                           数据有效点
```

**参数**：
- `ADC_SAMPLE_CYCLES`：ADC 采样延迟周期数
- 当前仿真默认值：3 cycles
- **模拟部分需要提供实际采样时间**

**数据有效性**：
- `bl_data` 在 `adc_done` 拉高时有效
- 数据在下一个 `adc_start` 之前保持稳定

---

## 3. 时序参数汇总

### 3.1 数字侧提供的时序

| 参数 | 当前仿真值 | 单位 | 说明 |
|:---|---:|:---:|:---|
| 时钟周期 | 20 | ns | 50MHz |
| `dac_valid` 脉冲宽度 | 1 | cycle | 单拍脉冲（行为模型锁存触发，真实芯片侧使用 `wl_latch`） |
| `cim_start` 脉宽 | 1 | cycle | 单拍 |
| `adc_start` 脉宽 | 1 | cycle | 单拍 |
| `bl_sel` 提前量 | 1 | cycle | 在 adc_start 之前稳定 |

### 3.2 需要模拟侧确认的时序

| 参数 | 仿真默认值 | 需要确认 | 说明 |
|:---|---:|:---:|:---|
| WL 复用发送时间 | 10 cycles | 固定 | 1(锁存) + 8(发送组 0~7) + 1(完成) = 10 cycles |
| DAC 建立时间 | 5 cycles | ✓ | `dac_valid` 脉冲后 WL 电压建立时间（`dac_ready` 握手已移除，改为固定延迟） |
| CIM 计算时间 | 10 cycles | ✓ | `cim_done` 延迟 |
| MUX 建立时间 | 2 cycles | ✓ | `bl_sel` 切换后稳定时间 |
| ADC 采样时间 | 3 cycles | ✓ | `adc_done` 延迟 |
| ADC 数据保持时间 | ≥1 cycle | ✓ | `bl_data` 有效持续时间 |

---

## 4. 完整时序流程

### 4.1 单次推理子时间步流程

```
┌────────────────────────────────────────────────────────────────────┐
│                         一个子时间步                                │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌───────────────────┐  │
│  │ WL复用  │ → │  DAC    │ → │  CIM    │ → │      ADC (×20)      │  │
│  │ 8拍发送 │   │  阶段   │   │  阶段   │   │ bl_sel=0..19 轮询  │  │
│  └─────────┘   └─────────┘   └─────────┘   └───────────────────┘  │
│                                                                    │
│   ~10 cycles     ~5 cycles      ~10 cycles    ~(2+3)×20 = ~100    │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
                         总计约 125 cycles/子时间步
```

### 4.2 波形示例

```
clk        ─┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐
            └┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘└┘

           ╔═══════════════════════════════════════════════════╗
           ║              一个完整子时间步流程                  ║
           ╚═══════════════════════════════════════════════════╝

           │◀── DAC ──▶│◀──── CIM ────▶│◀────── ADC ×20 ──────▶│

wl_spike   ════════╱ DATA ╲════════════════════════════════════════

dac_valid  ──────────────▓───────────────────────────────────────── (单拍脉冲)

// dac_ready: 已移除，固定时序，无需握手

cim_start  ────────────────▓───────────────────────────────────────

cim_done   ─────────────────────────────▓──────────────────────────

bl_sel     ══════════════════════════╱ 0 ╲╱ 1 ╲╱ 2 ╲... ╱19╲═══

adc_start  ─────────────────────────────▓───▓───▓─────────▓────────  ← 仅内部仿真

adc_done   ────────────────────────────────▓───▓───▓─────────▓─────  ← 仅内部仿真

bl_data    ═══════════════════════════════╱D0╲╱D1╲╱D2╲..╱D19╲═══
```

> **简化协议说明**：上图中 `adc_start/adc_done` 仅存在于**数字芯片内部仿真**（`snn_soc_top` ↔ `cim_macro_blackbox` 之间）。实际双芯片 PCB 外部接口**不包含**这两个信号。模拟芯片在收到 `cim_start` 后内部自行完成 CIM MAC + 全部 20 通道 ADC 转换，以 `cim_done` 统一返回；数字侧在 `cim_done` 后按 `bl_sel` 逐通道读取 `bl_data`（固定建立时间，无逐通道握手）。详见 SNNSoC工程主文档 §简化握手协议。

---

## 5. 电气特性

> **双芯片 PCB 互联注意**：以下信号在两颗独立封装芯片之间通过 PCB 走线传输，需额外关注：
> - PCB 走线延迟（FR-4 上约 150-170 ps/mm，即每 cm 约 1.5-1.7 ns，需纳入时序预算）
> - 信号串扰（特别是 `bl_data[7:0]` 8 根数据线的间距）
> - 阻抗匹配（若时钟频率 50MHz，走线长度 < 3cm 时通常可忽略传输线效应）
> - 两颗芯片可能使用不同工艺，需确认 IO 电平兼容性

### 5.1 数字芯片侧驱动能力

| 信号 | 驱动强度 | 负载要求 |
|:---|:---|:---|
| `wl_data[7:0]`（外部复用口径） | 标准 CMOS | 待确认 |
| `wl_group_sel[2:0]` | 标准 CMOS | 待确认 |
| `wl_latch` | 标准 CMOS | 待确认 |
| `cim_start` | 标准 CMOS | 待确认 |
| `bl_sel[4:0]` | 标准 CMOS | 待确认 |

### 5.2 模拟芯片侧输出要求

| 信号 | 电平标准 | 驱动能力 |
|:---|:---|:---|
| ~~`dac_ready`~~ | **已移除** | **已移除** |
| `cim_done` | 待确认 | 待确认 |
| `bl_data[7:0]` | 待确认 | 待确认 |

**请模拟芯片团队提供**：
- 模拟芯片 IO 电平标准（VIH/VIL/VOH/VOL）
- 输出信号的驱动能力（是否能驱动 PCB 走线负载）
- 两颗芯片 IO 电平是否兼容（如数字芯片用 1.8V IO，模拟芯片用 3.3V IO，是否需要电平转换）
- PCB 走线长度预估（影响延迟预算）

---

## 6. 设计约束

### 6.1 时钟约束

```tcl
# 目标时钟频率
create_clock -name clk -period 20.0 [get_ports clk]

# 时钟不确定度（留给模拟部分）
set_clock_uncertainty 1.0 [get_clocks clk]
```

### 6.2 接口时序约束

```tcl
# 数字芯片输出到模拟芯片（D→A，经 PCB 走线）
# 简化协议：adc_start 不作为外部信号，已移除
set_output_delay 3.0 -clock clk [get_ports {wl_data* wl_group_sel* wl_latch cim_start bl_sel*}]

# 数字芯片输入来自模拟芯片（A→D，经 PCB 走线）
# 简化协议：dac_ready / adc_done 不作为外部信号，已移除
set_input_delay 3.0 -clock clk [get_ports {cim_done bl_data*}]
```

**注**：以上约束为初始估计值。实际值需纳入 PCB 走线延迟（每 cm 约 1.5-1.7 ns）和模拟芯片 IO 时序。两颗芯片分别综合时，各自使用对应的 output_delay/input_delay 约束。

---

## 7. 验证要求

### 7.1 功能验证

| 测试项      | 描述                                             | 负责方   |
| :------- | :--------------------------------------------- | :---- |
| DAC 触发时序 | `dac_valid` 单拍 + 固定 `DAC_LATENCY_CYCLES` 延迟正确性 | 数字+模拟 |
| CIM 计算   | start→done 延迟符合预期                              | 模拟    |
| ADC 时分复用 | 20 通道轮询正确性（Scheme B）                           | 数字+模拟 |
| 数据完整性    | bl_data 数值正确                                   | 模拟    |
| 端到端      | 完整推理流程                                         | 数字+模拟 |
|          |                                                |       |

### 7.2 时序验证

| 测试项 | 描述 | 验收标准 |
|:---|:---|:---|
| Setup/Hold | 接口信号时序 | 无违例 |
| 时钟频率 | 50MHz 运行 | 无违例 |
| 复位 | 异步复位正确性 | 功能正确 |

---

## 8. 行为模型说明

### 8.1 当前行为模型位置

```
rtl/snn/cim_macro_blackbox.sv
rtl/snn/wl_mux_wrapper.sv   // WL 复用协议原型（冻结字段/时序）
```

### 8.2 行为模型输出规则

当前仿真用的简化输出规则：

```systemverilog
// 在 adc_done 时更新（Scheme B：20 通道，前 10 正列 + 后 10 负列）
pop = popcount(wl_latched);  // 0-64
for (int j = 0; j < ADC_CHANNELS; j++) begin  // ADC_CHANNELS=20
    if (j < NUM_OUTPUTS) begin
        bl_data_internal[j] <= (pop * 2 + j) & 8'hFF;           // 正列
    end else begin
        bl_data_internal[j] <= ((pop >> 1) + (j - NUM_OUTPUTS)) & 8'hFF;  // 负列
    end
end

// bl_data 由 MUX 选择
bl_data = bl_data_internal[bl_sel];
```

**说明**：
- `popcount` 统计锁存后的 `wl_latched` 中 1 的个数（0-64）
- Scheme B 差分结构：正列产生较高值，负列产生较低值
- 数字侧在 ADC 控制器中执行差分减法：`diff[i] = raw[i] - raw[i+10]`（i=0..9）
- 真实 CIM 会输出实际的 MAC 结果

### 8.3 集成时的替换方式

`snn_soc_top.sv` 提供参数 **`ENABLE_EXT_CIM_IF`**（默认 `1'b0`），通过 generate 块在编译期选择 CIM 信号来源：

```systemverilog
generate
  if (!ENABLE_EXT_CIM_IF) begin : gen_internal_cim_macro
    // 仿真路径：实例化行为模型，所有 CIM 信号来自黑盒
    cim_macro_blackbox u_macro (...);
  end else begin : gen_external_cim_if
    // 流片路径：CIM 信号来自外部 pad（chip_top 连线）
    assign cim_done_hw = cim_done_ext;   // 模拟芯片返回
    assign bl_data_hw  = bl_data_ext;    // 模拟芯片返回
    assign adc_done_hw = ext_adc_done;   // 数字侧本地固定延迟生成（见下文 §8.4）
  end
endgenerate
```

- **`ENABLE_EXT_CIM_IF=0`**（默认，用于仿真/FPGA）：`cim_macro_blackbox` 被实例化，提供 `cim_done`/`adc_done`/`bl_data` 响应。`cim_macro_blackbox.sv` 内部另有 `` `ifdef SYNTHESIS `` 宏，综合时切换为空端口定义。
- **`ENABLE_EXT_CIM_IF=1`**（流片路径，`chip_top.sv` 默认配置）：黑盒不被实例化，`cim_done` 和 `bl_data` 来自外部 pad 输入，`adc_done` 由数字侧本地生成。

**双芯片集成方式**（实际流片架构）：
1. `chip_top.sv` 以 `ENABLE_EXT_CIM_IF=1` 实例化 `snn_soc_top`，CIM 黑盒不参与综合
2. WL 复用信号（`wl_data/wl_group_sel/wl_latch`）和控制信号（`cim_start/bl_sel`）通过 `_ext` 端口连接到 chip_top pad
3. `cim_done` 和 `bl_data` 从 chip_top pad 输入，经 `_ext` 端口回到数字控制链路
4. 模拟 CIM 芯片独立流片，通过 PCB 走线与数字芯片互联
5. 联合验证可使用混合仿真（AMS）或 FPGA + 模拟芯片实物联调

### 8.4 本地 ADC 定时生成（ext_adc_done）

简化协议下外部接口不包含 `adc_start/adc_done`，但数字芯片内部的 `adc_ctrl` 仍需要逐通道的 `adc_done` 脉冲来推进 20 通道扫描。当 `ENABLE_EXT_CIM_IF=1` 且 `cim_test_mode=0` 时，`snn_soc_top` 内部生成本地固定延迟 `ext_adc_done`：

- **触发**：`adc_ctrl` 发出 `adc_start` 脉冲（纯内部信号，不出 pad）
- **延迟**：`ADC_SAMPLE_CYCLES`（当前默认 3 cycles = 60 ns @ 50MHz），与行为模型一致
- **输出**：`ext_adc_done` 单拍脉冲，经 generate 块赋值给 `adc_done_hw`，再由 test mode MUX 选通为最终 `adc_done`

> **注**：此延迟值是仿真占位。流片后，实际 ADC 采样时间由模拟芯片内部完成（包含在 `cim_start→cim_done` 总延迟内），数字侧在 `cim_done` 后按固定建立时间扫描 `bl_data`。`ext_adc_done` 的延迟值应根据模拟侧确认的"bl_sel 切换到 bl_data 有效"时间（§3.2 A5-5）来最终调整。

---

## 9. 待确认事项清单

### 9.1 时序参数

| 序号 | 参数 | 仿真默认值 | 模拟侧确认值 | 状态 |
|:---:|:---|---:|---:|:---:|
| 1 | DAC 建立时间 | 5 cycles | | 待确认 |
| 2 | CIM 计算时间 | 10 cycles | | 待确认 |
| 3 | MUX 建立时间 | 2 cycles | | 待确认 |
| 4 | ADC 采样时间 | 3 cycles | | 待确认 |
| 5 | ADC 数据保持时间 | 1 cycle | | 待确认 |

### 9.2 电气参数

| 序号 | 参数 | 数字侧要求 | 模拟侧提供 | 状态 |
|:---:|:---|:---|:---|:---:|
| 1 | 输入高电平阈值 | | | 待确认 |
| 2 | 输入低电平阈值 | | | 待确认 |
| 3 | 输出高电平 | | | 待确认 |
| 4 | 输出低电平 | | | 待确认 |
| 5 | 是否需要电平转换 | | | 待确认 |

### 9.3 其他事项

> **双芯片架构说明**：数字芯片与模拟芯片独立流片、通过 PCB 互联。对当前学生项目主线来说，数字芯片并不依赖模拟芯片的 LEF/Liberty/GDS；数字侧真正需要的是**接口时序模型**和**PCB 互联约束**，以完成 STA 估算和板级联调准备。

| 序号 | 事项 | 适用范围 | 状态 |
|:---:|:---|:---:|:---:|
| 1 | 模拟芯片 IO 时序模型（用于数字芯片 STA） | 数字芯片后端 | 待协商 |
| 2 | PCB 互联信号完整性分析 | PCB 设计 | 待启动 |


---

## 10. V2 编程接口（CIM Program-and-Verify）

> 本节描述 V2 新增的 RRAM 编程/擦除/验证接口。V1 流片不使用此接口；V2 数字芯片通过 `cim_program_ctrl` 模块控制编程脉冲，仍然经由 PCB 走线与模拟 CIM 芯片互联。

### 10.1 编程操作模式

| 模式 | PROG_CTRL 配置 | WL 行为 | 脉冲宽度来源 | 验证 |
|------|--------------|---------|------------|------|
| 逐 cell 写入（SET） | ERASE=0, FULL_ARRAY=0 | one-hot（目标行=1） | `PROG_PULSE_WIDTH.write_pulse_sel`：1us / 10us / 100us | 写入后 ADC 读回验证 |
| 逐 cell 擦除（RESET） | ERASE=1, FULL_ARRAY=0 | one-hot（目标行=1） | 固定 `PROG_ERASE_WIDTH` = 1ms | 擦除后 ADC 读回验证（≤1 LSB） |
| 全阵列擦除 | ERASE=1, FULL_ARRAY=1 | 全部 64 WL 同时拉高 | 固定 `PROG_ERASE_WIDTH` = 1ms | 跳过 verify，直接 PASS |

### 10.2 编程时序（自计时模式）

```
                         selected write width / fixed erase width
                    ┌──────────────────────────────────────┐
dac_valid    ───────┤    持续拉高（ST_SETUP → ST_PULSE_HOLD） ├──────
                    └──────────────────────────────────────┘
                    ↑          (ST_PULSE 隐式保持)          ↑
               ST_SETUP                              ST_READBACK
              (prog_en/                              入口拉低
              erase_en)

cim_start    ──────────▓────────────────────────────────────────── (单拍)
                       ↑
                   ST_PULSE

prog_adc_start ─────────────────────────────────────────────▓──── (仅非全阵列模式)
                                                            ↑
                                                       ST_READBACK
                                                    → ST_RB_WAIT(等 adc_done)
                                                    → ST_VERIFY
```

**关键设计决策**：编程脉冲由数字侧自计时（`ST_PULSE_HOLD` 状态倒计时 `pulse_width_cnt`），不等待模拟侧 `cim_done` 返回。写入只开放 1us / 10us / 100us 三档，用于摸索器件 SET 所需脉宽；擦除统一使用 1ms，保证 RESET 能量足够。

### 10.3 可配置脉冲宽度

| 寄存器 | 默认值 | 范围 | 物理含义（@50MHz） |
|--------|--------|------|-------------------|
| 寄存器 / 字段 | 默认值 | 可选项 | 物理含义（@50MHz） |
|--------|--------|------|-------------------|
| `PROG_PULSE_WIDTH.write_pulse_sel`（0x90[17:16]） | 0 | 0 / 1 / 2 | 写入脉冲：1us(50 cycles) / 10us(500 cycles) / 100us(5000 cycles) |
| `PROG_ERASE_WIDTH`（0x94[15:0]） | 50000 | 固定 | 擦除脉冲：1ms(50000 cycles)，写寄存器无效 |

器件写入所需脉宽未知，因此 SET 写入保留 1us / 10us / 100us 三档；RESET 擦除统一使用 1ms。`PROG_PULSE_WIDTH` 读回低 16 位为 resolved cycle 数，高位 [17:16] 为选择档位。

### 10.4 全阵列擦除特殊行为

全阵列擦除（`PROG_CTRL.FULL_ARRAY=1 && PROG_CTRL.ERASE=1`）与逐 cell 操作的关键差异：

1. **WL 驱动**：所有 64 根 WL 同时拉高（`wl_spike = {NUM_INPUTS{1'b1}}`），而非 one-hot
2. **脉冲宽度**：使用固定 1ms `PROG_ERASE_WIDTH`，而非写入档位
3. **跳过验证**：脉冲完成后直接 → ST_PASS → ST_DONE，不做 ADC 读回验证
4. **用途**：层间全阵列擦除（时间多层推理的层切换时使用）

### 10.5 对模拟侧的影响

V2 编程操作对模拟 CIM 芯片的额外要求：

| 编号 | 问题 | 说明 |
|------|------|------|
| V2-1 | 编程模式下 WL 持续驱动（非推理时的单拍脉冲），模拟侧 WL 驱动器能否承受长时间高电平？ | 最长 ~1ms |
| V2-2 | 全阵列擦除时所有 64 WL 同时为高，阵列功耗和 sneak path 电流情况？ | 最坏情况功耗评估 |
| V2-3 | 编程/擦除电压（V_SET / V_RESET）与读电压（V_read=1.5V）如何切换？是否需要额外的控制信号？ | 数字侧目前通过 `prog_en` / `erase_en` / `verify_en` 三个使能信号区分模式 |
| V2-4 | 逐 cell 编程后 ADC 读回验证精度要求？数字侧当前使用 ±2 LSB 窗口 | `ST_VERIFY` 中判定：`readback ∈ [target-2, target+2]` 即 PASS |
| V2-5 | 擦除后 ADC 读回值 ≤1 LSB 的判据是否合理？ | `ST_VERIFY` 擦除模式：`readback ≤ 1` 即 PASS |
| V2-6 | 写入脉冲宽度推荐档位？当前默认 1us，另有 10us / 100us；擦除固定 1ms @50MHz | 器件老师建议最终 SET 档位？ |

> 这些问题需在下次器件老师会议中确认。数字侧已预留 `prog_en`、`erase_en`、`verify_en` 三个使能信号，可通过 PCB 走线连接到模拟芯片的编程/擦除/验证模式切换逻辑。

---

## 附录 A：Verilog 端口定义

```systemverilog
module cim_macro_blackbox #(
    parameter int P_NUM_INPUTS   = snn_soc_pkg::NUM_INPUTS,    // 64
    parameter int P_ADC_CHANNELS = snn_soc_pkg::ADC_CHANNELS   // 20
) (
    // 时钟和复位
    input  logic        clk,
    input  logic        rst_n,

    // DAC 接口
    input  logic [P_NUM_INPUTS-1:0] wl_spike,  // 64-bit 字线输入
    // dac_valid: 单拍脉冲，通知行为模型锁存 wl_spike（真实芯片侧由 wl_latch 控制）
    // dac_ready 已移除（2026-02-27）：固定时序，无需握手
    input  logic        dac_valid,

    // CIM 计算接口
    input  logic        cim_start,              // 计算启动脉冲
    output logic        cim_done,               // 计算完成脉冲

    // ADC 接口
    input  logic [$clog2(P_ADC_CHANNELS)-1:0] bl_sel,  // 通道选择 0-19（Scheme B）
    input  logic        adc_start,              // ADC 采样启动
    output logic        adc_done,               // ADC 采样完成
    output logic [snn_soc_pkg::ADC_BITS-1:0] bl_data  // 8-bit ADC 输出
);
```

---

## 注：接口部分

**模拟芯片团队需要提供：**

1. ✅ 符合接口定义的 CIM Macro（外部复用口径与数字芯片 72-pad 预算中的 V1 baseline pad 方案匹配）
2. ✅ 确认表格中的时序参数（DAC/CIM/ADC 延迟）
3. ✅ 提供模拟芯片 IO 时序模型（用于数字芯片 STA 约束推导）
4. ✅ 确认 IO 电平标准（VIH/VIL/VOH/VOL）及与数字芯片的兼容性

---

## 物理阵列大小

根据当前设计参数：

|维度|值|说明|
|---|---|---|
|**输入（字线 WL）**|**64**|默认 `avgpool8x8` 的 8×8 离线特征，对应 `wl_spike[63:0]`|
|**输出（位线 BL）**|**20**|Scheme B 差分：10 正列 + 10 负列，`bl_sel` 0-19|

所以有效使用的阵列是：

```
        ←──────── 20 个位线（输出，Scheme B 差分）───────→
        BL0+ BL1+ ... BL9+  BL0- BL1- ... BL9-
    ↑   ┌────┬────┬────┬────┬────┬────┬────┬────┐
    │   │W[0]│    │    │    │    │    │    │    │
    │   ├────┼────┼────┼────┼────┼────┼────┼────┤
   64   │W[1]│    │    │    │    │    │    │    │
   个   ├────┼────┼────┼────┼────┼────┼────┼────┤
   字   │... │    │    │    │    │    │    │    │
   线   ├────┼────┼────┼────┼────┼────┼────┼────┤
  (输入)│W[63]│   │    │    │    │    │    │    │
    ↓   └────┴────┴────┴────┴────┴────┴────┴────┘
         WL0  WL1  WL2  ...                     WL63
```

**物理规模：128 × 256 RRAM 阵列（差分结构，有效 64 × 20 = 1280 个存储单元）**

---

## 需要确认的事项

重点确认：

```markdown
1. 阵列规模确认
   - 字线数量：64 根（输入维度，默认 `avgpool8x8` 的 8×8 离线特征）
   - 位线数量：20 根（Scheme B：10 正 + 10 负）
   - 物理阵列：128×256 RRAM（差分结构）

2. 时序参数（08文档第9节的表格）
   - DAC 建立时间：实际是多少？（仿真默认 5 cycles）
   - CIM 计算时间：实际是多少？（仿真默认 10 cycles）
   - ADC 采样时间：实际是多少？（仿真默认 3 cycles）
   - MUX 建立时间：实际是多少？（仿真默认 2 cycles）

3. 电气参数
   - 输入电平要求？
   - 输出驱动能力？
```

---

## 关于物理阵列与逻辑映射的澄清

物理阵列为 128×256 RRAM，采用差分结构（Scheme B）：

|层面|规模|说明|
|---|---|---|
|物理 RRAM|128 × 256|0T1R 阵列，差分结构|
|有效使用|64 × 20|64 WL（10 正列 + 10 负列）|
|逻辑输出|10 类别|数字侧差分后得到 10 个有符号结果|

**V1 输入说明**：数字芯片输入的是离线预处理后的 64 维特征向量；当前默认口径为 `avgpool8x8`，但 RTL 本身仅约束为 64 维输入接口，不在硬件里绑定具体前处理算法，所以它不是原始 28×28 像素。

**验证状态（2026-03-16）**：
- Step 3.4/3.5 Python↔RTL 数值对齐已通过（SAMPLE_ALIGN_PASS，100/100 样本完全一致）
- 对齐语义说明：`expected_classes.hex` 存的是 Python `predicted_class`，用于 RTL 等价性比对；真实标签保存在 `alignment_manifest.json`
- 数字芯片推理链路已验证完整：DMA→input FIFO→CIM FSM→ADC MUX→LIF 神经元→output FIFO
- 当前进入 Phase 4 外设集成阶段（AXI-Lite → UART → SPI → DMA扩展 → E203接入）

---

## 11. V2 ADC 扫描参数化（bl_sel 扩宽）

> 本节描述 V2 新增的"可配扫描通道数"对模拟接口的影响。V1 流片如果不支持多层，模拟侧不需要做任何改动；只在未来 V2 多层扩展到模拟 macro 时才要考虑。

### 11.1 背景

V2 时间多层架构支持 64→32→16→10 这类"每层 BL 数量不同"的网络。为此数字侧 ADC 控制器做了三个改动：
- `bl_sel` 从 5-bit 扩到 7-bit（最大支持 128 路扫描）
- 增加 `bl_scan_count` 软件寄存器（偶数 2~128，运行时可配；Scheme B 正负列成对）
- 差分切分点从固定 10 改为 `bl_scan_count / 2`（前半正、后半负）

### 11.2 对模拟 CIM macro 的潜在要求

以下仅在"未来要支持多层扩展到模拟 macro"时才生效：

| 需求 | 说明 | V1 流片是否必需 |
|---|---|---|
| BL MUX 支持 7-bit 寻址 | 扫描更多 BL 列时选择器需要扩宽 | ❌ 不需要（V1 只用 5-bit） |
| ADC 采样速率足够 | 一次推理要扫 128 路而不是 20 路，总时间 ×6 | ❌ 不需要 |
| WL 规模对齐 | 64→32→16→10 的后三层 WL 数量 < 64，复用阵列前 N 行 | ❌ 不需要 |
| bl_sel 高 2 位的物理连接 | pad 层面是否暴露 bl_sel[6:5] | ⚠️ 建议保留（未来扩展用） |

### 11.3 当前 chip_top pad 状态

`rtl/top/chip_top.sv` 的 `bl_sel_pad` 已经是 7-bit。流片时模拟芯片可以：
- (a) 只接收 bl_sel[4:0]，忽略高 2 位（V1 baseline 兼容）
- (b) 接满 bl_sel[6:0]（未来多层扩展准备）

建议 (b)，因为 pad 预算允许（数字 72/模拟 48），且未来不用改 pad map。

### 11.4 数字侧运行时控制

- `use_scan_cfg=0`（默认）：固定 V1 20 路扫描，bl_sel 最大 19
- `use_scan_cfg=1` + `bl_scan_count=N`（N ∈ [2, 128]）：扫描 N 路，bl_sel 最大 N-1

V2 多层 TB（`multilayer_scan_ext_tb.sv`）已验证 bl_sel 达到 63（bl_scan_count=64）和 127（bl_scan_count=128），对应的 MULTILAYER_SCAN_EXT_PASS 在 2026-04-18 通过。
