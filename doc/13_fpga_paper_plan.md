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
   完成：axi_lite_if + axi2simple_bridge + TB (T1-T7 PASS)
   待做：axi_lite_interconnect (⑤) + snn_soc_top 集成 (⑥)

② UART TX                               共用
   状态：feature/uart-tx 分支
   完成：uart_ctrl.sv + TB (T1-T7, 8/8 PASS)
   待做：snn_soc_top 中 uart_stub → uart_ctrl 替换

③ SPI Master                             共用
   状态：feature/spi 分支
   完成：spi_ctrl.sv + Flash model + TB (T1-T4, 8/8 PASS)
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
| BRAM (18Kb) | 4~6 | 3×SRAM(16KB) + 1×权重(640B) + FIFO |
| DSP | 0 | 1-bit×4-bit 乘法不需要 DSP，纯 LUT 实现 |

### 4.2 推荐开发板

| 开发板 | FPGA | LUT | BRAM | 价格 | 推荐度 |
|--------|------|-----|------|------|--------|
| Basys3 | Artix-7 35T | 20,800 | 50×18Kb | ~500 RMB | 够用 |
| PYNQ-Z1 | Zynq-7020 | 53,200 | 140×18Kb | ~800 RMB | 推荐（有 ARM 可辅助调试）|
| Nexys A7 | Artix-7 100T | 63,400 | 135×18Kb | ~1500 RMB | 充裕 |
| 自有板卡 | 看具体型号 | — | — | — | 有就用 |

Artix-7 35T 就足够（资源使用率约 15~25%）。

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
| 阈值 | 10200 (= 4×255×10) | J2 | ratio_code=4, T=10 下计算值 |

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
| 开发板不够用 | 资源不够 | Artix-7 35T 已足够（utilization ~20%），实在不够换 100T |
| 论文审稿质疑"为何不流片" | 被拒 | 明确声明 FPGA 是"架构预验证"，流片是后续工作；加入非理想注入提升含金量 |

---

## 10. 与 doc/12_fpga_validation_guide.md 的分工

| 文档 | 定位 | 内容 |
|------|------|------|
| `12_fpga_validation_guide.md` | 工程执行手册 | FPGA 上板流程、Go/No-Go 门禁、交付物清单 |
| **`13_fpga_paper_plan.md`（本文）** | **论文策略与技术方案** | CIM 替代方案、论文结构、数据需求、时间线 |

两者互补，不重复。
