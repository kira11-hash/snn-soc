# ~~GEMM 加速器扩展计划~~ [已取消 — 2026-04]

> **状态：CANCELLED**
>
> 本文档中描述的 GEMM/ANN 双模态扩展方案已于 2026-04 经用户与师兄讨论后决定取消（对应 V2 Iter 14 #5 CPU-ANN bridge）。
> 原因：当前项目聚焦 SNN/CIM 主线流片，GEMM 扩展超出 V2 scope。
> 保留此文档仅供历史参考，**不应作为当前或未来工作计划的依据**。

---

<details>
<summary>以下为原始文档内容（仅供历史参考）</summary>

## 1. 文档目的

本文档用于回答一个具体问题：

- 在当前 `SNN/CIM SoC` 主线之外，是否有必要增加一条 `GEMM/ANN` 计算主线，用来形成更完整的论文故事和更强的求职项目闭环。

本文档给出的结论是：

- `有必要`
- 但不建议做”大而全”的通用 AI 加速器
- 建议采用 **收缩后的 GEMM 方案**：
  - 先完成当前 `SNN/CIM` 主线
  - 再增加一个 **可落地、可验证、可发四区论文** 的 `INT8 GEMM` 版本
  - 核心卖点不是”GEMM 很先进”，而是 **ANN 高精度 / SNN 低能耗双模态可切换**

---

## 2. 项目定位

### 2.1 当前问题

当前项目的 `CIM macro` 由模拟方向同学负责，数字侧主要负责：

- E203 RISC-V CPU
- DMA
- AXI-Lite / bus
- SRAM / FIFO / reg_bank
- LIF neuron / digital control
- UART / SPI / JTAG
- FPGA 验证与系统集成

这条线本身很有工程价值，但如果只靠数字外围电路写论文，会遇到两个现实问题：

- 论文叙事里“计算核心”不够强
- 流片结果受模拟链路影响较大，存在不确定性

因此，增加一条 **独立于模拟 macro 的数字 GEMM 计算主线** 是合理的。

### 2.2 目标论文故事

推荐的论文故事不是“做一个很强的 GEMM 架构”，而是：

> 一个基于 RISC-V 的双模态 AI SoC：
> 在同一套 CPU / DMA / SRAM / 外设基础设施上，
> 支持 `ANN/GEMM` 高精度模式和 `SNN/CIM-equivalent` 低能耗模式，
> 并在 FPGA 上完成系统级验证。

这个定位更适合：

- 普通 SCI 四区 / OA
- 一年左右可落地的学生项目
- 求职时展示“从建模到 RTL 到验证到 FPGA”的完整能力

---

## 3. 总体结论

### 3.1 建议采用“收缩后的 Claude 版”

本项目不建议一上来就做：

- 通用多网络支持
- `INT4 + INT8` 双精度第一版
- `32x32` 大阵列第一版
- Transformer / Attention
- 稀疏跳过、复杂 dataflow、复杂层间调度

建议第一版 GEMM 只做：

- `INT8`
- `16x16 systolic array`
- `LeNet-like CNN on MNIST`
- 支持最必要算子：
  - `GEMM`
  - `ReLU`
  - `Pool`
- 卷积通过 `im2col + GEMM` 或等价 lowering 映射到 GEMM

### 3.2 为什么不用更大的版本

因为第一版真正要追求的是：

- 做完
- 做通
- 验证清楚
- FPGA 能跑
- 论文能讲清楚

而不是追求：

- 网络越大越好
- 结构越花越好
- 功能越全越好

对当前项目来说，**闭环能力比“看起来更先进”更重要**。

---

## 4. 与当前 SNN 主线的关系

### 4.1 优先级

GEMM 线不是当前第一优先级。

建议顺序固定为：

1. 先完成当前 `SNN/CIM` 主线
   - Python 定参数
   - RTL 参数同步
   - 黑盒 / weighted / VCS 仿真
   - Python↔RTL 数值对齐
   - 外设集成主线
2. 再启动 GEMM 主线

原因很简单：

- 当前 SNN 主线已经有明确的闭环路径
- 如果在它尚未收尾时同时开 GEMM，很容易两条线都失控

### 4.2 复用关系

GEMM 线可以 **大量复用** 当前 SoC 基础设施，但不能写成“完全不需要修改”。

可复用的基础设施包括：

- E203 CPU
- AXI-Lite / simple bus
- DMA 框架
- SRAM
- UART / SPI / JTAG
- 一部分寄存器访问和中断框架

但以下部分必须按 GEMM 需求重新评估：

- `reg_bank`
  - 需要新增 GEMM 模式寄存器
- `DMA`
  - 地址、长度、源/目的语义可能扩展
- `SRAM`
  - 需要考虑输入 / 权重 / 中间特征图 / 输出的分区或时分复用
- `top-level control`
  - 需要新的模式选择和状态流
- `software flow`
  - 需要新的权重装载、层配置和结果读取流程

所以正确说法是：

- **复用 SoC 基础设施**
- **但 GEMM 集成仍然需要系统级修改**

---

## 5. 当前建议的 GEMM MVP

### 5.1 目标网络

第一版建议选择：

- `LeNet-like CNN on MNIST`

注意这里用 **LeNet-like**，不是严格宣称“标准 LeNet-5”。

推荐的最小工作负载可以定义为：

1. Conv
2. Pool
3. Conv
4. Pool
5. FC

其中：

- `Conv / FC` 最终都映射到 GEMM
- `Pool` 由单独的小模块处理
- `ReLU` 由单独的小模块处理

### 5.2 为什么不用 Transformer

第一版明确不做 Transformer。

原因不是“GEMM 不会做”，而是 Transformer 的复杂度完全不是一个量级：

- GEMM 之外还要有：
  - Softmax
  - LayerNorm
  - Multi-head Attention
  - 大规模片上 buffer / 带宽调度
- 验证和数据流组织复杂度会暴涨

对当前项目目标：

- 论文够用
- FPGA 可跑
- 一年左右吃透

Transformer 完全不划算。

---

## 6. GEMM 体系结构建议

### 6.1 阵列规模

第一版建议：

- `16x16 systolic array`

原因：

- 足够支撑 `LeNet-like + MNIST`
- 资源压力可控
- 验证量可控
- 更容易在 FPGA 上拿到完整结果

以下内容不建议第一版做：

- `32x32` 第一版
- 更大阵列
- 面向大模型的存储层次设计

### 6.2 数值格式

第一版建议：

- 仅做 `INT8`

理由：

- Python 参考建模简单
- RTL 验证简单
- 结果解释简单
- 论文叙事足够

可作为第二阶段可选扩展的内容：

- `INT4` 对照
- 可配置精度

但不建议放进第一版。

### 6.3 模块划分

第一版可按下列模块实现：

| 模块 | 作用 | 备注 |
|------|------|------|
| `gemm_unit.sv` | `16x16` systolic MAC 阵列 | 核心计算单元 |
| `gemm_ctrl.sv` | tile 调度、层执行控制 | 第一版做最小 FSM |
| `activation_unit.sv` | ReLU / bypass | 不要把 LIF 混进 GEMM 数据流 |
| `pool_unit.sv` | max/avg pool | 先做最小必需版本 |
| `weight_loader.sv` | 将权重送入 GEMM 阵列 | 可对接 SRAM/SPI 装载流程 |
| `mode_switch_mux.sv` | SNN/GEMM 双模态切换 | 顶层模式控制 |

说明：

- 这里的 `mode_switch_mux` 不是“所有问题都靠一个 mux 解决”
- 实际上顶层还需要模式相关的控制、状态和数据路径组织

---

## 7. 建模策略

### 7.1 GEMM 是否需要单独建模

需要，但 **不是** 当前 `SNN` 这套大规模 sweep 风格。

GEMM 线真正需要的是：

- 一个 **最小 Python 参考模型**
- 用来提供：
  - 量化权重
  - 量化输入
  - 中间层 golden reference
  - 最终分类结果

### 7.2 GEMM 不需要做的事

第一版 GEMM 不需要：

- 像当前 SNN 一样暴力全量扫参
- 大规模 hyper parameter 搜索
- 器件模型建模
- ratio / threshold / timesteps 这类 SNN 参数调优

### 7.3 GEMM 需要做的建模内容

建议只做这些：

1. 选定固定网络
   - `LeNet-like CNN on MNIST`
2. 选定固定数值格式
   - `INT8`
3. 在 Python 中完成：
   - quantized inference
   - 每层输出 reference
   - 权重导出
   - 输入导出
4. 作为 RTL 对齐标准

一句话：

- `SNN` 需要“扫参建模”
- `GEMM` 需要“参考模型建模”

---

## 8. 双模态系统定位

### 8.1 模式定义

建议论文和工程统一口径：

- `ANN/GEMM mode`
  - 高精度优先
  - 运行 `INT8 GEMM + ReLU + Pool`
- `SNN/CIM-equivalent mode`
  - 低能耗优先
  - 运行当前 `1-bit spike + 4-bit weight + LIF` 路线

### 8.2 卖点

第一版论文卖点建议明确写成：

- 在同一 SoC 中支持双模态 AI 推理
- `ANN` 模式提供更高精度
- `SNN` 模式提供更低能耗
- 共享 CPU / DMA / SRAM / 外设基础设施
- 模式切换成本低于两套完全独立系统

这个卖点对于四区是够用的，前提是：

- 验证完整
- FPGA 数据完整
- 结果可复现

---

## 9. 验证路线

### 9.1 GEMM 线验证顺序

建议固定按下列顺序推进：

1. Python 参考模型
2. GEMM 核 RTL 单元验证
3. ReLU / Pool / Loader 单元验证
4. GEMM SoC 集成验证
5. ANN/SNN 双模态切换验证
6. FPGA 验证

### 9.2 不建议的做法

不建议一开始就：

- 上 FPGA 再说
- 先写一大堆模块再验证
- 先同时做 `INT4 + INT8 + 32x32 + 多网络`

这样非常容易失控。

---

## 10. 论文定位建议

### 10.1 建议论文主线

推荐论文标题方向：

> A RISC-V-Based Dual-Mode AI Accelerator SoC Supporting
> High-Accuracy ANN Inference and Low-Energy SNN Inference

### 10.2 论文创新点建议

建议把创新点控制在以下组合内：

1. **双模态系统集成**
   - 同一 SoC 支持 `ANN + SNN`
2. **模式切换机制**
   - 共享控制平面和存储资源
3. **系统级 FPGA 验证**
   - 给出资源、频率、吞吐、能效、精度对比

如果第一版还能再加一个小点，可以选：

- 可配置精度

但不建议第一版把创新点铺得太多。

### 10.3 不建议的论文写法

不建议把论文重点写成：

- “新型超强 GEMM 架构”
- “类 TPU 大规模通用加速器”
- “Transformer 加速器”

这些都会把评审预期抬高，而与你当前资源和时间不匹配。

---

## 11. 时间预估

### 11.1 现实预估

在当前主线先收尾的前提下，GEMM 第一版更现实的估计是：

- `3-4 个月`：非常顺利、范围严格控制、AI 高强度辅助、验证没有大返工
- `4-6 个月`：更现实的估计

需要明确：

- AI 可以明显提升编码、脚本、文档和资料整理效率
- 但 **不能消除系统验证和集成调试成本**

### 11.2 为什么不该估计得过低

因为实际耗时不只在 RTL：

- Python 参考模型
- 权重/输入导出
- 单元测试
- SoC 集成
- FPGA 资源与时序
- 实验数据收集
- 论文图表整理

---

## 12. 对求职和项目价值的判断

如果当前 `SNN/CIM` 主线和后续 `GEMM` 收缩版都做通，这个项目的价值已经很高。

原因在于它覆盖了：

- Python 建模
- 数字 RTL
- 验证
- FPGA
- SoC 集成
- 双模态 AI 推理

对数字 IC / SoC / AI accelerator / FPGA / 验证类岗位来说，
**一个能被你彻底讲清楚的收缩版双模态项目，比一个做得很大但没收住的项目更有竞争力。**

---

## 13. 与当前项目的关系

### 13.1 这条线不应干扰当前定版主线

当前已经明确的主线是：

1. Python 定参数
2. RTL 参数同步
3. 黑盒 / weighted / VCS 仿真
4. Python↔RTL 数值对齐
5. 外设集成

在这条线没有收住之前，不建议正式切换到 GEMM 实施阶段。

### 13.2 当前文档结论

因此，本计划的最终建议是：

- **保留 GEMM 扩展方向**
- **采用收缩后的 GEMM MVP**
- **先完成当前 SNN/CIM 主线，再启动 GEMM**

---

## 14. 最终建议

如果目标是：

- 一年左右吃透项目
- 兼顾流片 / FPGA / 论文 / 秋招
- 发一篇普通 SCI 四区 / OA

那么最佳选择不是“大而全”的 GEMM 方案，而是：

### 推荐方案

- 先完成当前 `SNN/CIM SoC` 主线闭环
- 再实现一个 **收缩版 GEMM/ANN 模式**
  - `INT8`
  - `16x16`
  - `LeNet-like CNN on MNIST`
  - `GEMM + ReLU + Pool`
- 最终形成一个 **ANN 高精度 / SNN 低能耗双模态 AI SoC**

这是当前最稳、最容易落地、最适合写论文也最适合找工作的路线。

</details>
