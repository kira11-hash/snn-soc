# CIM Analog Interface Specification

**文档用途**：供数字芯片团队与模拟 CIM 芯片团队进行双芯片 PCB 集成接口商讨
**版本**：v3.0
**日期**：2026-03-16（2026-03-31 审核确认：自 v3.0 以来数字侧接口参数无变更，保持冻结）
**时钟频率目标**：50MHz（周期 20ns）
**参数口径**：本文涉及的默认时序参数以 `rtl/top/snn_soc_pkg.sv` 为准，若与文档不一致以 pkg 为准。
**集成架构**：数字芯片与模拟 CIM 芯片为**独立封装、分别流片**，通过 PCB 走线互联（非片上集成）。

> **2026-04-24 关键更新**
>
> - 本文**推理接口**章节自 v3.0 以来保持冻结。
> - 项目要求已冻结：**V1 外部模拟 CIM die 必须支持由数字芯片发起的 erase / write / verify 编程。**
> - **外部编程接口合同已于 2026-04-24 冻结**为方案 α'（7 new pads），详见本文 §10 **外部编程接口 (External Programming Interface)**。
> - **Q1/Q2/Q3 已于 2026-04-24 收口（本文同日修订）**：
>   - Q1：`cim_start` 在 programming 模式下是 LEVEL-hold gate（不是 strobe）；模拟侧按 `cim_start` 高电平持续时间驱动 pulse/read-voltage。
>   - Q2：`prog_op` 只保证在**同一** `cim_start=1` 窗口内稳定；跨窗口（write→verify）可能切换，数字侧保证切换发生在 `cim_start=0` 的 1-cycle gap 中。
>   - Q3：verify 的 `bl_data` 必须在 `cim_start_ext` 上升沿后 ≤ 100 ns 稳定；若目标是接近 3σ 落在数字侧 `±2 LSB` 判据内，建议模拟+ADC 合计 RMS 噪声 ≤ 0.67 LSB（RMS ≤ 1 LSB 时可工作，但通常要依赖 retry）。
> - pad 总数从 48 扩到 **55**（46 signal + 6 power + 3 ESD；usable=52），见 `doc/15_asic_pad_map.md`。
> - 模拟同学现在可以按本文 §2/§3/§4/§5（推理）**和** §10（外部编程）同时推进实现。
> - **共享载体 pad 路由已于 2026-04-24 补齐**：`wl_data / wl_group_sel / wl_latch / cim_start / bl_sel` 在 `prog_busy=1` 时都会切到 programming 路径；回归 TB 为 `prog_wl_pad_route_tb.sv`（PROG_WL_PAD_ROUTE_TB_PASS）。
>
> **2026-04-25 clock/reset 分发冻结**：`clk` / `rst_n` 不是数字芯片转发给模拟芯片的 D→A 信号。PCB 使用同一个 50 MHz 标准时钟源和同一个 supervisor/reset 源分别扇出到数字 die 与模拟 die；数字芯片没有 `clk_out` / `rst_out` pad。模拟侧如需要约 40/60 duty cycle，应在模拟 die 内部做 DCC/本地整形，并回填 PVT 保证范围。

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
- ADC（模拟到数字转换，功能合同为 1 路 8-bit ADC + 20:1 MUX；实现可等效，不强制 SAR）

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

### 1.3 V1 当前已冻结的推理口径（必须遵守）

为避免后续接口漂移，V1 统一采用“内部并行 + 外部复用”双层口径：

- 内部并行口径（当前 `snn_soc_top` / `cim_macro_blackbox`）：
  `wl_spike[63:0] + dac_valid + cim_start/done + bl_sel[4:0] + adc_start/done + bl_data[7:0]`
- 外部复用口径（对应 `doc/15_asic_pad_map.md` 的推理载体 pads 19..45，供 chip_top/pad 使用）：
  `wl_data[7:0] + wl_group_sel[2:0] + wl_latch + cim_start/done + bl_sel[4:0] + bl_data[7:0] + clk + rst_n`
  > `clk` / `rst_n` 是 PCB shared input：同一颗板级时钟源 / reset supervisor 并行送到两颗 die，不由数字芯片转发。

当前 RTL 已加入协议原型：`rtl/snn/wl_mux_wrapper.sv`。

> **重要边界**：
> 本节只描述**推理接口**。  
> 外部编程合同已经在本文 §10 + `doc/03` + `doc/15` 中冻结。  
> 共享载体 pad 路由（`wl_data / wl_group_sel / wl_latch / cim_start / bl_sel`
> 在 `prog_busy=1` 时切到 programming 路径）已于 2026-04-24 在
> `rtl/top/snn_soc_top.sv` 里补齐，并由 `tb/prog_wl_pad_route_tb.sv`
> （PROG_WL_PAD_ROUTE_TB_PASS）回归覆盖。

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
  **注意**：本条只覆盖推理链路。外部 erase/write/verify 的编程命令表达方式已经在本文 §10 冻结，不再是开放项。
- 后端/PCB 集成负责：
  **数字芯片侧**：在 `chip_top/pad wrapper` 完成数字芯片的 pad 复用映射与约束收敛。
  **模拟芯片侧**：完成模拟芯片的 pad 布局与信号引出。
  **PCB 设计**：完成两颗芯片之间的 PCB 走线互联，保证信号完整性（特别是 `bl_data[7:0]` 等高速信号的延迟匹配与串扰控制）。
- PCB 时钟/复位分发负责：
  板级 50 MHz 标准晶振或低抖动 clock source 以星形/并行方式分别驱动数字 die `clk` 与模拟 die `clk_in`；板级 supervisor IC + reset 按钮分别驱动数字 die `rst_n` 与模拟 die `rst_n`。数字 die 不做 clock/reset 转发、buffer 或 duty reshape。PCB 走线目标为 chip-to-chip clock skew ≤ 0.5 ns（50 MHz 周期 20 ns 的 2.5%，作为 layout target；最终 STA/接口预算以板级提取和 IO timing model 为准）。模拟 die 若偏好约 40% high / 60% low duty cycle，应在模拟 die 内部 DCC/本地时钟整形中实现，并给出 PVT 下保证范围；数字侧只假设板级输入为常规 50 MHz 时钟。

---

## 2. 接口信号定义

### 2.1 信号总表

> 说明：本节表格为**内部并行接口口径**（`snn_soc_top` 与 `cim_macro_blackbox` 之间，仅用于仿真）。
> 实际双芯片 PCB 互联使用 §1.3 定义的**外部推理载体口径**（pads 19..45）；完整 55-pad package 视图以 `doc/15_asic_pad_map.md` 为准。

| 信号名 | 方向 | 位宽 | 类型 | 说明 |
|:---|:---:|---:|:---:|:---|
| **时钟和复位** |||||
| `clk` | PCB shared | 1 | 时钟 | 系统时钟，50MHz；PCB clock source 并行送数字 die 与模拟 die，不由数字 die 输出 |
| `rst_n` | PCB shared | 1 | 复位 | 异步复位，低有效；PCB supervisor / reset button 并行送两颗 die |
| **DAC 接口** |||||
| `wl_spike` | D→A | 64 | 数据 | 字线输入，64路并行 bit-plane |
| `dac_valid` | D→A | 1 | 脉冲 | DAC 数据有效，单拍脉冲（行为模型锁存触发）；真实芯片侧由 `wl_latch` 时序控制 |
| ~~`dac_ready`~~ | ~~A→D~~ | ~~1~~ | ~~握手~~ | **已移除（2026-02-27）**：模拟侧采用固定时序 de-mux，无需握手回路 |
| **CIM 计算接口** |||||
| `cim_start` | D→A | 1 | 脉冲 | CIM 计算启动，单拍脉冲 |
| `cim_done` | A→D | 1 | 脉冲 | CIM 计算完成，单拍脉冲 |
| **ADC 接口** |||||
| `bl_sel` | D→A | 5 | 控制 | 位线选择，0-19 有效（Scheme B：10 正 + 10 负） |
| `adc_start` | D→A | 1 | 脉冲 | ADC 采样启动，单拍脉冲（**仅内部仿真，不在外部 ASIC pad 接口中**） |
| `adc_done` | A→D | 1 | 脉冲 | ADC 采样完成，单拍脉冲（**仅内部仿真，不在外部 ASIC pad 接口中**） |
| `bl_data` | A→D | 8 | 数据 | 当前通道 ADC 输出，8-bit |

**注**：D→A = 数字芯片到模拟芯片（经 PCB 走线），A→D = 模拟芯片到数字芯片（经 PCB 走线）。`clk` / `rst_n` 是例外：它们是 PCB shared source 到两颗 die 的输入，不是 D→A 转发信号。

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
> - PCB 走线延迟（FR-4 典型约 60-70 ps/cm，具体以 PCB stackup / field solver 为准，需纳入时序预算）
> - 信号串扰（特别是 `bl_data[7:0]` 8 根数据线的间距）
> - 阻抗匹配（按 IO 边沿速度而不只按 50MHz 频率判断；必要时在源端预留串联阻尼电阻）
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

# 初始时钟不确定度：含 source jitter、PCB 分发 skew、pad/IO 模型余量。
# clk 是 PCB shared input，不是数字芯片输出给模拟芯片的 forwarded clock。
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

**注**：以上约束为初始估计值。实际值需纳入 PCB 走线延迟（FR-4 典型约 60-70 ps/cm，具体以 PCB stackup / field solver 为准）、板级 clock source 抖动、chip-to-chip clock skew、pad/IO timing model 和模拟芯片 IO 时序。两颗芯片分别综合时，各自使用对应的 output_delay/input_delay 约束；`clk` 本身按 PCB shared source 建模，不按 D→A output delay 建模。

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

1. ✅ 符合接口定义的 CIM Macro（**推理外部复用口径**与当前数字芯片 pad 方案匹配）
2. ✅ 确认表格中的时序参数（DAC/CIM/ADC 延迟）
3. ✅ 提供模拟芯片 IO 时序模型（用于数字芯片 STA 约束推导）
4. ✅ 确认 IO 电平标准（VIH/VIL/VOH/VOL）及与数字芯片的兼容性
5. ✅ 外部编程 sideband pads (`prog_op[2:0]` + `prog_level[3:0]`) 已冻结；模拟同学可按本文 §10 直接实现 decoder / pulse driver / verify readback 路径

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

## 10. 外部编程接口 (External Programming Interface)

**冻结日期**：2026-04-24（方案 α'）
**对应 pad**：`doc/15_asic_pad_map.md` 中的 pad 46..52（共 7 pads）
**RTL 入口**：`rtl/top/snn_soc_top.sv` 的 `prog_op_ext[2:0]` / `prog_level_ext[3:0]` 输出端口

### 10.1 合同总览

数字芯片在做**推理**和**编程**时共用 pad 19..45（`wl_data / wl_group_sel / wl_latch / cim_start / cim_done / bl_sel / bl_data`）。模拟芯片通过新增的 `prog_op[2:0]`（pad 46..48）判断当前 `cim_start` 对应什么操作；`prog_level[3:0]`（pad 49..52）给 write 操作提供目标电导等级。

**关键不变量（模拟同学必须遵守，2026-04-24 Q1/Q2/Q3 锁死版）**：

1. **`cim_start` 在编程模式下是 LEVEL-hold 的 pulse-gate（Q1）**：
   - `cim_start=1`：数字侧认可当前 `prog_op` 对应的 pulse/read 正在生效；
     模拟侧 pulse driver / read-voltage 驱动应全程打开。
   - `cim_start=0`：pulse 关闭；模拟侧必须立即撤去 pulse/read-voltage。
   - **本次脉冲时长以 `cim_start` 高电平持续时间为准**。模拟侧**不需要**
     也**不应该**自己查 `prog_op→脉宽` 表做内部自计时——以免和数字侧
     `REG_PROG_PULSE_WIDTH` 档位改变不同步。
   - 推理模式下（`prog_busy=0`）`cim_start` 退化为原来的 1-cycle strobe
     (`cim_start_pulse` 穿透)，保持推理链路兼容。

2. **`prog_op[2:0]` 在每个 `cim_start=1` 窗口内稳定，跨窗口可能切换（Q2）**：
   - 不变量是**"`prog_op` 在 `cim_start` 高电平期间保持不变"**，而**不是**
     "`prog_op` 在整个 `prog_busy` 期间保持不变"。
   - 单次 write 操作会依次出现两种窗口：
     1) pulse 窗口：`cim_start=1` 且 `prog_op=010` 持续整个 SET 脉冲时长；
     2) verify 窗口：`cim_start=1` 且 `prog_op=011` 持续整个读回时长。
     两个窗口之间数字侧保证**至少 1 cycle 的 `cim_start=0` gap**，`prog_op`
     的切换只会发生在 gap 里，因此模拟侧在 `cim_start` 上升沿锁存 `prog_op`
     就足以拿到正确编码。
   - retry 时同样是若干"pulse 窗口 + verify 窗口"交替，每次 `cim_start` 上升沿
     都要重新锁存 `prog_op`。

3. **`prog_level[3:0]` 与 `prog_op` 一起相位对齐**：只在 `prog_op==3'b010`
   （write）时有效；其他 op 时数字侧仍然驱动但内容可忽略。数字侧 RTL 里
   `prog_level_ext` 与 `prog_op_ext` 同时通过 10-stage pipeline 对齐到
   `cim_start_ext`，因此两者相对相位是确定的。

4. **verify 的 PASS/FAIL 判决由数字侧完成**：数字侧对 `bl_data` 与
   `prog_level*16` 做 **±2 LSB** 窗口比较，**模拟侧不需要返回 pass 信号**。
   因此**没有** `prog_pass` pad。模拟侧只需保证 `bl_data` 在 `cim_start=1`
   窗口内有效（见 §10.5 时序预算）。

5. **`cim_done` 在编程期间是可选反馈，不强制**：数字侧 `cim_program_ctrl`
   是自计时的（用寄存器配置的 pulse 宽度倒计数），**不会**依赖 `cim_done`
   推进编程状态。模拟侧如果需要驱动 `cim_done`，其语义是"本次 pulse 已施加
   完毕"，不要赋予其他含义。

### 10.2 `prog_op[2:0]` 编码表

| `prog_op[2:0]` | 操作 | 模拟侧动作 | `prog_level` 有效？ | row / col 来源 |
|:---:|---|---|:---:|---|
| `000` | 推理 (inference) | 按标准 MAC 做 Scheme B 差分，读 10+10 列 | 否 | `wl_data + wl_group_sel + wl_latch`（64-bit 一热位图经 8×8 TDM）+ `bl_sel` |
| `001` | 擦除单 cell (erase_cell) | 对所选 cell 施加 RESET 脉冲（擦至高阻） | 否 | `wl_data + wl_group_sel + wl_latch`（单行 one-hot）+ `bl_sel`（列） |
| `010` | 写入单 cell (write) | 对所选 cell 施加 SET 脉冲（写到 `prog_level` 对应的电导） | **是** | 同 001 |
| `011` | 验证读回 (verify) | 对所选 cell 做读电压采样，结果量化 8-bit 放 `bl_data` | 否 | 同 001 |
| `100` | 全阵列擦除 (erase_full_array) | 全部 WL 同时拉高做 RESET 擦除（忽略 `wl_data`）| 否 | 全阵列 |
| `101..111` | 保留 | 视作 idle / no-op；**不要**执行任何 program/erase 动作 | — | — |

### 10.3 脉冲宽度与关断语义（合同级定义，2026-04-24 Q1 锁定）

外部编程合同按下面语义冻结：

- `prog_op[2:0]` / `prog_level[3:0]` 负责表达**操作类型**和**目标等级**；
  两者在 RTL 内部经 10-stage pipeline 与 `cim_start_ext` 相位对齐，分析 die
  在 `cim_start_ext` 上升沿锁存 `{prog_op, prog_level}` 即可获得正确编码。
- 对于 `erase_cell / write / verify / erase_full_array`，共享 pad `cim_start`
  充当 **LEVEL-hold pulse-gate**：
  - `cim_start=1`：模拟侧按当前 `prog_op` 对应的操作保持 pulse / read-voltage
    驱动打开；
  - `cim_start=0`：模拟侧必须立即关闭 pulse / read-voltage 驱动。
- **本次脉冲时长最终以 `cim_start` 高电平持续时间为准**，模拟侧**不要**
  自己做脉宽定时（否则与数字侧 `REG_PROG_PULSE_WIDTH` 档位变化不同步）。
- 数字侧保证 **同一 `cim_start` 高电平窗口内 `prog_op` 恒定**；写→读相位
  切换发生在 `cim_start=0` 的 gap cycle 中（至少 1 cycle）。
- 推理模式下（`prog_busy=0`）`cim_start` 退化为原来的 1-cycle strobe
  (`cim_start_pulse`)，不受本节 level-gate 语义约束。

| 档位 (`PROG_PULSE_WIDTH[17:16]`) | 写入脉宽 (cycles @ 50 MHz) | 实际时间 |
|:---:|:---:|:---:|
| `00` | 50 | 1 µs |
| `01` | 500 | 10 µs |
| `10` | 5000 | 100 µs |
| `11` | (保留，钳到 100 µs) | 100 µs |

擦除脉宽固定 `50000 cycles = 1 ms @ 50 MHz`，数字侧硬编码。

> **RTL 对齐 (2026-04-24)**：`rtl/top/snn_soc_top.sv` 的 `cim_start_ext` 在
> `prog_busy=1` 期间由 `(prog_dac_valid | verify_en_dly1)` 延迟 10 拍驱动，
> 完全覆盖每次 SET / RESET / verify pulse 的宽度。`wl_data / wl_group_sel /
> wl_latch` 通过 `wl_mux_wrapper` 的 prog_busy mux 路由来自 `prog_wl_spike`，
> `bl_sel_ext` 来自 `arb_bl_sel`（arbiter 在 prog_busy 时自动切换到
> `prog_bl_sel`）。共享载体 pad 的路由已全部对接编程路径，可按本文做端到端
> 实现。

### 10.4 典型编程时序（单 cell 写入 level=7，Q1/Q2 锁定后）

write op 会产生"pulse 窗口 + verify 窗口"两段 `cim_start=1` 序列，中间至少
隔 1 cycle。对于 level=7（7 个 SET 脉冲），数字侧会先发一次 cim_start=1
覆盖 7 个连续脉冲，然后 1-cycle gap，再发一次 cim_start=1 覆盖 readback。
波形示意：

```
                   ←——— pulse 窗口（~7×PULSE_WIDTH + 前后 overhead ———→ ←gap→ ←verify窗口→
cycle     0   1   …  10  11  …      end_pulse  end_pulse+1   +2 …   rb_end
──────────────────────────────────────────────────────────────────────────────
prog_op   000 000 …  010 010 …      010        000             011 …   011
prog_lvl   0   0  …   7   7  …       7          0               7  …    7      (don't care in verify)
wl_data       (8×8 TDM row-bitmap burst during cycles 1..9)
wl_latch   _____   ┴ ┴ ┴ ┴ ┴ ┴ ┴ ┴ __________________________________________
bl_sel    (idle) … C  C  C  …      C          C               C  …    C
cim_start ___________│‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾│_____│‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾│__
                     │ ← 10 clk AFTER wl_latch seq  │     │ ← verify gate
                     │   (确保 WL 已经 latch 完成)    │
cim_done      (optional, 不必需)
bl_data       (don't care during pulse window)     │     R   R  …  R   (read回 8-bit)
```

**要点**：
- `cim_start` 上升沿距离 `wl_latch` 最后一拍 ≥ 9 clk（WL TDM 完全 latch 后
  才给 cim_start）。
- `cim_start=1` 高电平时长 ≈ 本次 SET 脉冲时长（单次 write 可能含多个
  back-to-back 的内部 pulse，但外部 pad 上是一个连续的 level）。
- `cim_start` 拉低时 pulse driver 立即关断。
- 写→读之间 `cim_start=0` 至少 1 clk，这是 `prog_op` 安全切换到 `011` 的窗口。

### 10.5 典型 verify 时序与时序预算（Q3 锁定）

```
cycle       0   1   2   3   4   5   …   N
─────────────────────────────────────────────
prog_op   010 000 011 011 011 011 …   011    ← 在 cim_start=0 那一拍（cy=1）切换
prog_lvl   7   7   7   7   7   7   …    7    ← don't care in verify, but driven
bl_sel     C   C   C   C   C   C   …    C
cim_start __│___│‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾│______   ← level gate (verify window)
                │            ↑            │
                │  模拟侧最晚在此把          │
                │  bl_data 建立到 ±1 LSB    │
bl_data    x   x   x   x   R   R   …    R
cim_done                        (optional, 数字侧不依赖)
```

**时序预算（冻结）**：

- **开始计时点**：`cim_start_ext` 上升沿（即 verify 窗口开始）。
- **bl_data 必须稳定时刻**：`cim_start_ext` 上升沿后 ≤ **`T_ADC_LATENCY`**
  - 数字侧目前默认预算：`ADC_MUX_SETTLE_CYCLES=2` + `ADC_SAMPLE_CYCLES=3` =
    **5 cycles = 100 ns @ 50 MHz**
  - 即模拟侧从 cim_start 上升沿起 **≤ 100 ns** 必须把 8-bit 读回值稳定到
    `bl_data[7:0]` 上
- **bl_data 必须保持时长**：从建立点起一直保持到 **`cim_start_ext` 下降沿**
  （或下一次 `bl_sel` 变化）。数字侧在 `adc_done` 拉高那拍采样，因此至少
  要覆盖到 adc_done 时刻。
- **cim_done（可选）**：若驱动，必须在 `bl_data` 已稳定之后拉高；数字侧
  不依赖它推进状态，只是作为 optional 调试辅助。

**噪声预算（冻结）**：

- 数字侧判据：`target = prog_level × 16`，窗口 `±2 LSB`。
- 噪声预算建议这样理解：
  - **RMS ≤ 1 LSB**（约 ±0.4% 满量程）时，在高斯且零均值近似下，单次 verify
    落在 `±2 LSB` 窗口内的概率约为 **95.4%**；数字侧可依赖
    `PROG_CTRL.RETRY_LIMIT`（**默认 4**，3-bit 字段上限 7）吸收剩余 false-fail。
  - **若目标是“约 3σ 都落在 ±2 LSB 内”**，则 RMS 噪声应压到约 **≤ 0.67 LSB**。
  - 因此，对模拟/器件侧的工程建议是：**尽量做到 RMS ≤ 0.67 LSB；若只能做到
    RMS ≤ 1 LSB，系统仍可工作，但默认应保留 retry。**
- 换算到电流：8-bit ADC 满量程对应 LRS 电流（~nA 量级），1 LSB ≈ FS/256，
  要求读回噪声 ≤ 数 pA RMS 级别。
- 如果模拟/器件实际做不到上述预算，需提前与数字侧商量放宽判据（数字侧会改
  `±2` 为 `±3` 或更大），否则 verify 阶段会出现可预期的 false-fail。

**数字侧判据复核**（不改）：`bl_data` vs `prog_level*16 ± 2`；擦除 verify
复用 `bl_data ≤ 1` 判据（high-resistance 态 ≈ code 0）。

### 10.6 全阵列擦除 (`prog_op=100`)

```
cycle    0   1   2   ...   50000
---------------------------------------
prog_op  100 100 100 ...   100
prog_lvl  x   x   x  ...    x    ← don't care
wl_data   x   x   x  ...    x    ← analog ignores wl_data in this mode,
                                   全阵列同时 RESET
bl_sel    x   x   x  ...    x
cim_start __|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|__
(analog: drive full-array RESET while cim_start=1)
```

擦除期间**不需要** verify（单独的 erase op 是 fire-and-forget）；数字侧固件如需验证全阵列状态，会在擦除后逐 cell 用 `prog_op=011` verify。

**关断语义冻结**：

- 模拟侧必须把 `cim_start` 看作全阵列擦除 pulse-gate
- 若数字侧因为复位/异常提前把 `cim_start` 拉低，模拟侧应**立即停止当前 pulse**，
  不应在内部偷偷补完整个 1 ms pulse

### 10.7 reset + idle 行为

- 芯片级 `rst_n` 有效时：数字侧所有 `prog_*` 信号都被拉 0，`cim_start` 也不会发。
- `!prog_busy && !cim_array_busy`（系统空闲）时：`prog_op=000` 作为默认值，`cim_start=0`。模拟侧此时应保持 idle，不做任何 pulse。
- 模拟侧遇到未定义编码 `101..111` 时：**视作 idle，不执行任何 program/erase/verify 动作**。这是未来扩展预留。

### 10.8 电气要求

沿用 §5（数字驱动能力 / 模拟输出要求），新增 `prog_op` / `prog_level` pad 的要求：
- 驱动方向：**D→A**（数字输出，模拟输入）
- 电平：沿用推理接口同一 IO bank 电平（见 §5.1）
- 建立时间（setup）：`prog_op` / `prog_level` 在 `cim_start` 上升沿前至少
  **10 ns** 稳定（1 个 50 MHz clk 周期的裕量）；数字侧已通过 10-stage
  pipeline 把两者与 `cim_start_ext` 相位对齐，实际 setup ≈ 数个 clk，
  10 ns 是保守最小值。
- 保持时间（hold）：`prog_op` / `prog_level` 在 `cim_start` 下降沿后至少
  **5 ns** 保持；数字侧 pipeline 会同步切换（下降沿那一拍起 `prog_op` 切
  到 000 或下一阶段值），因此 hold 天然 ≥ 0，5 ns 是合同保守值。
- `bl_data` (A→D, verify readback) 时序：**从 `cim_start_ext` 上升沿起
  ≤ 100 ns 稳定到 ±1 LSB，保持到 `cim_start_ext` 下降沿**（见 §10.5）。
- 功耗：静态（idle 态 `prog_op=000`）下可按常态 LVCMOS/LVCMOS18 静态功耗估算；编程脉冲期间主要功耗来自模拟侧的 pulse driver

### 10.9 验证与回归

- 仿真（编程 FSM）：`tb/prog_bypass_latch_tb.sv`（bypass 锁存语义）+
  `tb/cim_program_ctrl_tb.sv`（FSM 8 个子测试）覆盖编程 FSM 自身。
- 仿真（外部 pad 编码器）：`tb/prog_pad_encoder_tb.sv` 直接观察
  `snn_soc_top.prog_op_ext / prog_level_ext`，断言 write / erase_cell /
  verify / erase_full_array 四种编码与内部信号相位一致（带 10-stage 延迟对齐）。
- 仿真（共享载体 pad 路由 + gate 语义）：`tb/prog_wl_pad_route_tb.sv` 断言
  (a) WL 8×8 TDM 重组出的 64-bit 位图 = 编程目标行 one-hot；
  (b) `cim_start_ext` 上升沿距离 `wl_latch` 最后一拍 ≥ 9 cycles；
  (c) `cim_start_ext` 是 LEVEL gate 而不是 strobe（首窗口宽度 ≥ 40 cycles）；
  (d) `prog_op_ext` 在单个 `cim_start=1` 窗口内稳定。
- 脉宽寄存器：`tb/prog_pulse_cfg_tb.sv`（4 档 preset + erase fixed），通过
  tag `PROG_PULSE_CFG_TB_PASS`。
- 启动互锁：`tb/prog_start_interlock_tb.sv`，通过 tag
  `PROG_START_INTERLOCK_TB_PASS`。
- FPGA：`main-fpga-e203-alpha-passed @ 2adc327b` 已记录
  `FPGA_E203_BOOT_UART_PASS` / `FPGA_E203_PROGRAM_ERASE_WRITE_PASS` /
  `FPGA_E203_PROGRAMMED_INFERENCE_PASS`。数字侧编程 FSM、arbiter 与
  α' pad 编码 / gate 语义的 RTL 回归分别由
  `PROG_PAD_ENCODER_TB_PASS`、`PROG_WL_PAD_ROUTE_TB_PASS`、
  `PROG_BYPASS_LATCH_TB_PASS` 覆盖；板级 UART 原始证据见
  `doc/main-fpga-e203/board_bringup_log_c0c1c2.txt`。

### 10.10 已知 follow-up

- **共享载体 pad 路由状态（2026-04-24 已完成）**：
  - `wl_data / wl_group_sel / wl_latch`：`prog_busy=1` 时由 `wl_mux_wrapper`
    以 `prog_wl_spike` 为输入产生 TDM 脉冲（已在 `snn_soc_top` 里通过
    `prog_busy` mux 切换，PROG_WL_PAD_ROUTE_TB_PASS 覆盖）。
  - `cim_start_ext`：`prog_busy=1` 时由 `(prog_dac_valid | verify_en_dly1)`
    经 10-stage shift register 延迟驱动（LEVEL gate，Q1 锁定）。
  - `bl_sel_ext`：始终 = `arb_bl_sel`（arbiter 根据 `prog_busy` 自动在
    inference bl_sel 与 `prog_bl_sel` 之间切换）。
  - `prog_op_ext / prog_level_ext`：经 10-stage pipeline 与 `cim_start_ext`
    对齐（Q2 锁定）。
- **剩余 TODO**：
  - 模拟侧回填 §5 的电气参数 + 芯片 pinout 后，应与本节 §10.8 合并成最终
    电气合同。
  - 若后续修改 `fw/e203_smoke/e203_fpga_smoke.c`、ZCU102 wrapper/TCL、
    约束或任何影响综合的 α' pad 路由 RTL，必须重新跑
    `main-fpga-e203-alpha` 板级验证；当前已冻结证据不应被 silently 复用。
