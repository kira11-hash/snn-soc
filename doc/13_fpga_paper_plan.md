# 13. FPGA 验证与论文兜底计划

## 0. 核心结论

本项目**完全可以**在 FPGA 上实现完整的 SNN SoC 加速器原型。
核心计算链路模块无需修改功能逻辑，仅需替换 CIM 宏并新增板级适配层。
这条路线与 ASIC 流片完全并行、互不干扰，是最稳的"论文兜底路线"：

- **流片成功**：FPGA 结果作为"架构预验证"写进论文，增加可信度
- **流片失败**（数字或模拟任一侧）：FPGA 结果 + 前/后仿真照样支撑 EI 或 SCI 四区

---

## 1. 为什么 FPGA 能发论文

### 1.1 论文定位（最关键）

不要把论文 claim 绑定在"硅上验证"，而是定义为：

> **"面向 RRAM CIM 的器件感知 SNN SoC 数字架构设计与 FPGA 原型验证"**

核心贡献：
1. 完整 SoC 架构设计（E203 + SPI + DMA + SNN 加速器 + Scheme B 差分）
2. 器件感知的数字 CIM 等效模型（可注入 RRAM 非理想效应）
3. FPGA 上端到端 MNIST 推理实测

明确声明：这是"器件感知的 FPGA 原型验证"，硅结果是后续增强版本，不是本文前提。

### 1.2 不同验证级别对应的论文水平

| 验证级别 | 论文水平 | 数据要求 |
|---------|---------|---------|
| 纯 RTL 仿真（当前已有） | EI 会议 | 波形 + 功能正确性 |
| **FPGA 验证 + 实际推理** | **SCI 四区 / EI 期刊** | 精度、延迟、资源、功耗 |
| FPGA + 器件非理想注入 | **SCI 三四区** | 消融实验、鲁棒性分析 |
| ASIC 流片 + 测试 | SCI 二三区 | 面积、功耗、实测精度 |

---

## 2. 技术方案：CIM Macro 的 FPGA 替代

### 2.1 当前行为模型（cim_macro_blackbox.sv）

当前行为模型不含真实权重，用 popcount 简化公式：

```
pop_count = popcount(wl_spike[63:0]);    // 有多少根 WL 被激活
bl_data_pos[j] = pop_count * 2 + j;     // j = 0~9，正列
bl_data_neg[j] = pop_count / 2 + j;     // j = 0~9，负列
```

这对功能验证足够，但无法做精度对比和论文实验。

### 2.2 FPGA 替代方案对比

| 方案 | 描述 | 论文价值 | 复杂度 | 推荐 |
|------|------|---------|--------|------|
| A. 纯数字 MAC | BRAM 存权重 + 1-bit×4-bit 乘累加 | 中 | 低 | 保底 |
| **B. 数字 MAC + 非理想注入** | A + D2D/C2C 变异 + 噪声 + ADC 量化 | **高** | **中** | **强烈推荐** |
| C. 混合仿真联合 | Verilog-AMS / SPICE 联合 | 最高 | 极高 | 不推荐 |

### 2.3 推荐方案 B 的具体实现

#### 核心计算逻辑

```
对每个输出列 j (0~9):
  pos_acc = Σ_{i=0}^{63} wl_spike[i] × W_pos[i][j]    // 正权重列
  neg_acc = Σ_{i=0}^{63} wl_spike[i] × W_neg[i][j]    // 负权重列

  // ADC 量化（8-bit）
  bl_data_pos[j] = clamp(pos_acc, 0, 255)
  bl_data_neg[j] = clamp(neg_acc, 0, 255)

  // Scheme B 差分（由 adc_ctrl.sv 完成，不在 CIM 内部）
  diff[j] = signed(bl_data_pos[j]) - signed(bl_data_neg[j])
```

关键优势：`wl_spike[i]` 是 1-bit，"乘法"退化为 AND 门 + 条件加法，不消耗 DSP。

#### 权重存储

```
// 64 inputs × 20 columns × 4-bit = 5120 bit = 640 Bytes
// 一个 18Kb BRAM 绑绑有余
logic [3:0] weight_pos [0:63][0:9];   // 正列权重
logic [3:0] weight_neg [0:63][0:9];   // 负列权重

initial begin
  $readmemh("weight_pos.hex", weight_pos);
  $readmemh("weight_neg.hex", weight_neg);
end
```

权重从 Python 训练管线导出（已有 4-bit 量化流程）。

#### 器件非理想效应注入（论文加分关键）

```
// 可开关参数，受寄存器或编译宏控制
parameter bit ENABLE_D2D_VARIATION = 1;   // 器件间变异
parameter bit ENABLE_NOISE         = 1;   // 读噪声
parameter int D2D_SIGMA_PERCENT    = 5;   // σ = 5%（来自实测数据）
parameter int NOISE_LSB            = 2;   // ±2 LSB 随机噪声
```

注入方式：
- **D2D 变异**：初始化时对每个权重加高斯偏移（LFSR 伪随机）
- **C2C 变异**：每次 cim_start 时对 acc 结果加噪声
- **ADC 量化误差**：截断低位模拟 INL/DNL

这些参数来自器件组的实测数据（见本文第 7 节参数来源表及引用标签说明）。

#### 工程实现补充（答疑新增）

在实现层面可按三层叠加噪声：

1. **D2D（静态）**：每个权重单元一个固定偏移，初始化后全程不变。  
2. **C2C/读噪声（动态）**：每次 `cim_start` 或每次列读时，用 `LFSR` 生成扰动加到累加结果。  
3. **ADC 量化误差**：量化前后做截断/抖动。

常用表达：

```
acc_noisy = acc_ideal + noise_dyn
w_eff     = w_base + d2d_offset[idx]
```

并在输出前 `clamp` 到 `0..255`，避免越界。

建议增加可配置控制位（便于消融实验）：

```
noise_en
noise_level
```

权重写入 ROM 的工程建议：

1. Python 导出 `weight_pos.mem`、`weight_neg.mem`（按 RTL 列映射导出，确保 pos/neg 列顺序一致）。  
2. RTL 采用 ROM/BRAM 数组 + `$readmemh` 初始化。  
3. 展平寻址最稳妥：`idx = row*10 + cls`。

可用示例（展平）：

```systemverilog
(* rom_style="block" *) reg [3:0] w_pos_rom [0:639]; // 64*10
(* rom_style="block" *) reg [3:0] w_neg_rom [0:639]; // 64*10
initial begin
  $readmemh("weight_pos.mem", w_pos_rom);
  $readmemh("weight_neg.mem", w_neg_rom);
end
```

说明：

- 上述方式是“随 bitstream 固化”，运行时不可修改。  
- 若需要在线更新权重，将 ROM 改为可写 BRAM，并增加总线写口。

### 2.4 模块接口（与 blackbox 100% 兼容）

```systemverilog
module cim_macro_fpga #(
  parameter int P_NUM_INPUTS   = 64,
  parameter int P_ADC_CHANNELS = 20
) (
  input  logic clk,
  input  logic rst_n,
  input  logic [P_NUM_INPUTS-1:0] wl_spike,
  input  logic dac_valid,
  input  logic cim_start,
  output logic cim_done,
  input  logic adc_start,
  output logic adc_done,
  input  logic [$clog2(P_ADC_CHANNELS)-1:0] bl_sel,
  output logic [7:0] bl_data
);
  // ... 内部用 BRAM 权重 + MAC + 可选噪声注入
endmodule
```

**核心计算链路模块（cim_array_ctrl、adc_ctrl、lif_neurons、DMA、总线、UART、SPI）的功能逻辑无需修改。**
FPGA 分支需额外新增：板级顶层 `top_fpga.sv`、时钟 PLL wrapper、复位同步、引脚约束 XDC、Vivado filelist。这些属于板级适配层，不属于 SoC 功能 RTL。

---

## 3. 与 ASIC 主线的关系

### 3.1 共用部分

FPGA 分支复用 ASIC 主线的所有核心计算链路模块（源码相同，无需修改功能逻辑）。
但 FPGA 分支需要额外的适配层：板级顶层（top_fpga.sv）、时钟 PLL、复位同步、引脚约束（XDC）、文件列表切换。

```
                 ASIC 主线                    FPGA 分支
                 ────────                    ──────────
总线:            bus_simple + AXI-Lite        核心逻辑相同
UART TX:         uart_ctrl.sv                 核心逻辑相同
SPI:             spi_ctrl.sv                  核心逻辑相同
DMA:             dma_engine.sv                核心逻辑相同
加速器控制:       cim_array_ctrl.sv            核心逻辑相同
ADC 控制:        adc_ctrl.sv                  核心逻辑相同
LIF 神经元:      lif_neurons.sv               核心逻辑相同
寄存器:          reg_bank.sv                  核心逻辑相同
板级适配:        chip_top.sv（pad ring）       top_fpga.sv + XDC + PLL（FPGA 专用）
CIM 宏:          cim_macro_blackbox.sv         cim_macro_fpga.sv（数字 MAC 替代）
```

### 3.2 CIM 宏差异（唯一的功能逻辑差异）

```
ASIC:  cim_macro_blackbox.sv   →  实际连接 RRAM analog macro
FPGA:  cim_macro_fpga.sv       →  BRAM 权重 + 数字 MAC + 可选噪声
```

通过 `ifdef FPGA` 或 Vivado filelist 切换，不影响 ASIC 主线 RTL。

### 3.3 迭代路径（两条线并行）与当前进度

> **重要说明**：下表的"当前状态"是准确的分支级状态。
> main 分支仍使用 uart_stub / spi_stub 占位，
> 各 IP 在 feature 分支上独立 TB 通过后，需合并到 main 并在 snn_soc_top.sv 中
> 替换 stub 实例才算真正"集成完成"。

```
ASIC 主线                               FPGA 论文兜底线
──────────                              ─────────────
① AXI-Lite 桥接 + TB                    共用
   状态：feature/axi-lite 分支
   完成：axi_lite_if + axi2simple_bridge + TB (T1-T9, 9/9 PASS, 含背压测试)
   待做：axi_lite_interconnect (⑤) + snn_soc_top 集成 (⑥)

② UART TX                               共用
   状态：feature/uart-tx 分支
   完成：uart_ctrl.sv + TB (T1-T7+T1b, 9/9 PASS, 寄存器映射已对齐 stub)
   待做：snn_soc_top 中 uart_stub → uart_ctrl 替换

③ SPI Master                             共用
   状态：feature/spi 分支
   完成：spi_ctrl.sv + Flash model + TB (T1-T4+T1b, 9/9 PASS, 含 clk-div clamp)
   待做：snn_soc_top 中 spi_stub → spi_ctrl 替换

④ DMA 扩展                               共用
   状态：未开始

⑤ E203 接入                              共用
   状态：未开始（依赖 ①②③④ 全部合并到 main）
                                          │
                                          ▼
                                    ⑥ cim_macro_fpga.sv（替换 blackbox）
                                    ⑦ 权重导出 + $readmemh 加载
                                    ⑧ fpga/ 目录结构 + Vivado 工程
                                    ⑨ 上板验证 + 数据收集
                                    ⑩ 论文撰写
```

---

## 4. FPGA 资源评估

### 4.1 资源占用估算

| 资源 | 用量估计 | 说明 |
|------|---------|------|
| LUT | 3000~5000 | SoC 控制逻辑 + MAC 加法树 |
| FF | 1500~3000 | 寄存器 + 状态机 + 计数器 |
| BRAM (18Kb) | ~27 | 3×SRAM(16KB) + FIFO + 权重存储 |
| DSP | 0 | 1-bit×4-bit 乘法不需要 DSP，纯 LUT 实现 |

**BRAM 详细估算（基于 RTL 实际参数）：**

| 存储器 | 规格 | 配置 | RAMB18 数量 |
|--------|------|------|------------|
| INSTR_SRAM | 16KB，32-bit宽，4K深 | 512×36 × 8 | 8 |
| DATA_SRAM | 16KB，32-bit宽，4K深 | 512×36 × 8 | 8 |
| WEIGHT_SRAM | 16KB，32-bit宽，4K深 | 512×36 × 8 | 8 |
| INPUT_FIFO | 64-bit宽，256深 | 256×36 × 2（宽度级联） | 2 |
| OUTPUT_FIFO | 4-bit宽，256深 | 最小分配 | 1 |
| 合计 | - | - | ~27 |

> 注：3 个 16KB SRAM 就需要约 24 个 RAMB18；加上 FIFO/权重存储后总量约 27。

### 4.2 推荐开发板

| 开发板 | FPGA | LUT | BRAM(18Kb) | BRAM 利用率(按27估算) | 推荐度 |
|--------|------|-----|-----------|-----------------------|--------|
| Basys3 | Artix-7 35T | 20,800 | 50 | ~54%（偏紧） | 可用但不建议首选 |
| PYNQ-Z1 | Zynq-7020 | 53,200 | 140 | ~19%（充裕） | 推荐（有 ARM 可辅助调试）|
| Nexys A7 | Artix-7 100T | 63,400 | 270 | ~10%（宽裕） | 充裕 |
| **ZCU102** | **Zynq US+ ZU9EG** | **274,080** | **912×36Kb≈1824×18Kb** | **<5%（按27估算）** | **最佳（已有优先，详见 4.3 节）** |

> Basys3 在 BRAM 上偏紧；PYNQ-Z1 / Nexys A7 / ZCU102 更稳妥。

### 4.3 ZCU102 实机评估（已有板卡）

项目组手头有 Xilinx ZCU102 评估板（XCZU9EG-2FFVB1156E，Zynq UltraScale+ MPSoC），
以下为该板卡与本项目需求的详细匹配分析。

#### 4.3.1 资源对比

| 资源 | ZCU102 (XCZU9EG PL 侧) | SNN SoC 估算需求 | 裕量 |
|------|-------------------------|------------------|------|
| CLB LUT | 274,080 | 3,000~15,000 | >18× |
| CLB FF | 548,160 | 1,500~20,000 | >27× |
| BRAM 36Kb | 912 块 (32.1 Mb) | 约14 块（≈27 块 18Kb 当量） | >65× |
| UltraRAM 288Kb | 80 块 | 0 | 全部空闲 |
| DSP48E2 | 2,520 | 0（1-bit MAC 不需要 DSP） | 全部空闲 |
| DDR4 | PS: 4 GB + PL: 512 MB | 几十 KB（MNIST 数据） | 极富余 |

**结论：资源远超需求，utilization 预计 <5%。**

#### 4.3.2 板载外设与 SoC 需求匹配

| SoC 需求 | ZCU102 板载资源 | 可用性 |
|----------|----------------|--------|
| UART TX 调试输出 | CP2108 USB-UART 桥（4 通道，micro-USB） | **可用**（通过 PMOD/FMC 或可达的 PL 引脚通道接出） |
| JTAG 调试 | 板载 Digilent USB-JTAG + 14-pin 标准 header | **直接可用** |
| SPI Flash | 2× 512Mb Micron QSPI Flash | **不能直接给 PL 侧 spi_ctrl 用**（见下方说明） |
| 外扩 IO | 2× FMC HPC (~200+ IO) + 2× PMOD (16 IO) | **充裕** |

**SPI Flash 重要说明**：
ZCU102 板载 QSPI Flash 连接在 PS 侧 MIO 引脚上，用于 ARM 引导启动，
PL 侧自研 `spi_ctrl.sv` 无法直接驱动这些 Flash。解决方案（三选一）：

1. **外接 SPI Flash 模块**（推荐）：通过 PMOD 或 FMC 接一个小 Flash 板，PL 侧 spi_ctrl 直接驱动
2. **BRAM 模拟 Flash**：用 BRAM + `$readmemh` 预加载 MNIST 数据，spi_ctrl 仅做功能验证
3. **PS 中转**：ARM 通过 MIO 读 Flash，再通过 AXI 传给 PL 侧 SRAM

方案 1 最接近真实场景；方案 2 最简单，足够发论文。

#### 4.3.3 ARM (PS) vs E203 (PL)：双路线策略

ZCU102 的 PS 侧有硬核 ARM Cortex-A53（四核，1.5GHz，可跑 Linux），
这使得除了"纯 PL 复刻 ASIC"之外，还有一条"ARM + 加速器"路线可选。

| | 方案 A：纯 PL（E203 + SNN） | 方案 B：PS ARM + PL 加速器 |
|---|---|---|
| **CPU** | E203 RISC-V（PL 内软核） | ARM Cortex-A53（PS 硬核） |
| **OS** | 裸机固件（无 OS） | PetaLinux / Bare-metal |
| **数据加载** | SPI Flash → CPU → SRAM → DMA | ARM 读 DDR/SD 卡 → AXI → PL SRAM → DMA |
| **开发方式** | 交叉编译 RISC-V 固件，JTAG 烧写 | GCC/Python 直接在板上运行 |
| **论文价值** | 完整复刻 ASIC 设计，映射最强 | 大规模实验最方便，可做 demo |
| **适合阶段** | 验证 SoC 架构正确性 | 批量跑实验、出数据表 |

**ARM 路线的独特优势**：

1. **批量实验**：Python 脚本循环 10,000 张 MNIST 测试图，自动统计 accuracy
2. **参数扫描**：脚本自动修改 threshold / timesteps / noise_level，跑多组实验出图表
3. **实时 demo**：摄像头输入 → 预处理 → SNN 推理 → 屏幕显示分类结果
4. **功耗对比**：ARM 纯软件推理 vs SNN 硬件加速，直接出 speedup 和能效比数据
5. **AXI 天然对接**：PS 通过 AXI HP/HPC 端口驱动 PL，而我们的 `axi2simple_bridge` 恰好做这个转换

**推荐策略**：先做方案 A（纯 PL + E203）拿到基线数据和 ASIC 等效验证；
再做方案 B（ARM + 加速器）做批量实验和 demo。论文里两条路线都能写，
方案 A 证明"架构设计正确"，方案 B 提供"大规模实验数据"。

#### 4.3.4 FPGA 适配层清单（不可省略）

纯 PL 方案需要以下 FPGA 专用适配（非 SoC 功能逻辑）：

| 适配项 | 说明 |
|--------|------|
| `top_fpga.sv` | 板级顶层，连接 PL 引脚到 SoC 顶层端口 |
| 时钟 PLL/MMCM | 50 MHz 系统时钟生成（板载 300MHz 差分时钟 → PLL ÷6） |
| 复位同步 | 板载按钮去抖 + 异步复位同步器 |
| `.xdc` 约束文件 | 引脚分配（UART TX → PMOD/USB-UART、LED、按键、SPI） |
| Vivado 工程/TCL | 综合 + 实现 + 生成 bitstream 脚本 |

这些与 SoC 功能 RTL 无关，属于板级集成工程。

---

## 5. FPGA 工程目录结构

已在 `doc/12_fpga_validation_guide.md` 中定义，保持一致：

```
fpga/
  boards/
    <board_name>/
      constraints.xdc         # 引脚约束（UART TX、SPI、LED、按键）
      top_fpga.sv             # 板级顶层（时钟 PLL、复位同步、pad 连接）
      build.tcl               # Vivado 批处理综合脚本
  ip/
    clk_wiz_wrapper.sv        # 时钟 PLL 封装
  cim_model/
    cim_macro_fpga.sv         # 数字 CIM 等效模型（BRAM 权重 + MAC）
    weight_pos.hex            # 正列权重（Python 导出）
    weight_neg.hex            # 负列权重（Python 导出）
  scripts/
    export_weights.py         # Python → .hex 权重导出脚本
    run_fpga_smoke.py         # UART 接收 + 验证脚本
```

---

## 6. 论文可发表最小包（MVP）

### 6.1 必须有的数据

1. **端到端推理演示**：E203 固件驱动 SPI 读 Flash → CPU 写 data_sram → DMA 搬运至 input_fifo → SNN 推理 → UART 打印分类结果
2. **精度对比**：FPGA 推理精度 vs Python golden model（应一致或差距 <0.5%）
3. **FPGA 资源报告**：Vivado 综合后 LUT/FF/BRAM/DSP utilization
4. **推理延迟**：每帧推理 cycle 数（可从 debug 计数器读取）
5. **功耗估算**：Vivado Power Report（粗略即可）

### 6.2 加分项（区分度，冲 SCI）

6. **消融实验**：
   - 有/无 D2D 变异对精度的影响
   - 有/无 C2C 噪声对精度的影响
   - 不同 ADC 位宽（6/7/8 bit）对精度的影响
   - 不同 Timestep（5/8/10/15）对精度的影响
7. **鲁棒性分析**：变异幅度 sweep（σ = 1%~10%）下的精度曲线
8. **与其他 SNN FPGA 实现的对比表**（文献中有不少可引用）

### 6.3 建议论文结构

```
1. Introduction
   - SNN + CIM 趋势
   - RRAM 非理想效应对推理精度的挑战
   - 本文贡献：器件感知 FPGA 原型 + 系统级验证

2. System Architecture
   - SoC 整体框图（E203 + bus + DMA + SNN accelerator）
   - Scheme B 差分架构
   - 数据流：Flash → SPI → CPU 中转写 SRAM → DMA → FIFO → CIM → LIF → output
   - 注：V1 为 CPU 中转路径（firmware loop），非 SPI→DMA 直连

3. Device-Aware Digital CIM Model
   - 数字 MAC 等效 RRAM CIM（1-bit × 4-bit）
   - 器件非理想效应建模（D2D/C2C/noise 参数来源）
   - 与 Python 行为模型的一致性验证

4. FPGA Implementation
   - 平台选择与资源利用率
   - 时钟/复位/IO 适配
   - 权重加载方案

5. Experimental Results
   - MNIST 分类精度（FPGA vs Python golden）
   - 推理延迟与吞吐量
   - 功耗报告
   - 消融实验（非理想效应、ADC 位宽、Timestep）

6. Comparison with Prior Work
   - 与其他 SNN FPGA 实现的对比表
   - 关键差异：器件感知建模、CIM 架构等效

7. Conclusion
   - FPGA 验证通过，证明架构可行性
   - 为后续 ASIC 流片提供信心
   - 未来工作：硅验证、V2 增强（RX、write/erase、自适应阈值）
```

---

## 7. 关键参数来源（论文引用依据）

以下数据已在项目中确认。表中"来源标签"为项目内部追溯码，
对应的原始出处在下方"引用标签清单"中列出。论文撰写时需替换为正式文献引用。

| 参数 | 值 | 来源标签 | 说明 |
|------|-----|---------|------|
| 4-bit 权重精度 | 16 levels, log-spaced | D1 | 器件组 RRAM 阵列电学测试 |
| D2D 变异 | σ = 5%±1% | D3 | 器件组 wafer 级统计（多 die 采样）|
| C2C 变异 | σ = 3%±1% | D3 | 器件组同一 die 重复读取统计 |
| On/Off ratio | 5000:1 | D2 | 器件组 HRS/LRS 电阻比测试 |
| Python baseline 精度 | 90.42% (spike-only) | J2/J3 | Python 管线 `proj_sup_64` 最终锁定配置 |
| Zero-spike rate | 0.00% | J3 | Python 校准后验证（calibrate_threshold.py）|
| ADC 位宽 | 8-bit | A3 | Python 建模 sweep：6/8/12-bit 对比 |
| 阈值 | 3060 (= 4×255×3) | J2 | 工程默认值（论文高精度对照可用 T=10，对应 10200） |

### 引用标签清单

项目内部使用以下标签追溯决策来源。论文撰写时需将器件数据替换为正式参考文献
（器件组论文/报告），Python 建模数据需附实验复现脚本。

| 标签 | 原始出处 | 存放位置 |
|------|---------|---------|
| D1 | 器件组 RRAM 阵列电学特性报告（4-bit 量化方案） | 待向器件组索取正式文档或预印本 |
| D2 | 器件组 On/Off ratio 测试数据 | 同上 |
| D3 | 器件组 D2D/C2C 变异统计数据 | 同上 |
| D4 | 器件组读电压 / 电阻范围测试 | 同上 |
| D5 | 器件组 IR drop 阵列级仿真 | 同上 |
| A3 | Python 建模 ADC 位宽 sweep 实验 | `python/` 目录下建模脚本 |
| J1 | Python 建模自适应阈值实验（结论：不采用）| 同上 |
| J2 | Python 建模 ratio_code / threshold 锁定 | `snn_soc_pkg.sv` THRESHOLD_DEFAULT |
| J3 | Python 建模 zero-spike 校准结果 | `python/calibrate_threshold.py` |

---

## 8. 时间线建议

| 阶段 | 内容 | 预计周期 |
|------|------|---------|
| 当前 | ASIC 主线迭代（DMA → E203） | 进行中 |
| E203 接入后 | 开 feature/fpga 分支，写 cim_macro_fpga.sv | 1~2 天 |
| 权重导出 | Python 脚本导出 .hex，$readmemh 验证 | 半天 |
| Vivado 综合 | fpga/ 目录、XDC、PLL、综合 + 实现 | 1~2 天 |
| 上板调试 | UART printf 验证 → SPI Flash 加载 → 端到端 | 1~3 天 |
| 数据收集 | 跑 MNIST 测试集 + 消融实验 | 1~2 天 |
| 论文撰写 | 初稿 | 1~2 周 |

**总计约 2~3 周**（与 ASIC 后端并行，不占额外时间）。

---

## 9. 风险与规避

| 风险 | 后果 | 规避措施 |
|------|------|---------|
| 数字流片失败 | 无硅测试数据 | FPGA 结果兜底，论文不依赖硅 |
| 模拟流片失败 | CIM macro 不工作 | CIM test mode 已预留（REG_CIM_TEST），可绕过模拟；FPGA 独立验证 |
| FPGA 精度与 Python 不一致 | 论文数据不可信 | 用相同权重 + 相同量化流程，差异应 <0.5%；如有差异可分析原因 |
| 开发板不够用 | BRAM 紧张或 IO 不足 | 优先选 PYNQ-Z1/Nexys A7/ZCU102；Basys3 仅作最小演示 |
| 论文审稿质疑"为何不流片" | 被拒 | 明确声明 FPGA 是"架构预验证"，流片是后续工作；加入非理想注入提升含金量 |

---

## 10. 与 doc/12_fpga_validation_guide.md 的分工

| 文档 | 定位 | 内容 |
|------|------|------|
| `12_fpga_validation_guide.md` | 工程执行手册 | FPGA 上板流程、Go/No-Go 门禁、交付物清单 |
| **`13_fpga_paper_plan.md`（本文）** | **论文策略与技术方案** | CIM 替代方案、论文结构、数据需求、时间线 |

两者互补，不重复。
