# 18. IC 论文模式模块 A：系统架构 / FPGA 原型验证版

## 用法

本文件是 `evidence_mode = A` 的模式模块。使用时请先拼接共享模块 [`eassy-prompt/17_ic_paper_prompt_shared.md`](17_ic_paper_prompt_shared.md)，再追加本文件中的“模式 Prompt 正文”。

适用场景：

- RTL / TB / regression 已完整
- Python↔RTL 或软件↔硬件对齐已建立
- FPGA 原型可跑端到端任务
- 可以做器件感知数字等效建模或非理想注入
- ASIC 还处于综合、P&R、接口冻结、流片前准备阶段，或者流片结果尚未形成论文主证据

---

## 模式 Prompt 正文

以下模式模块覆盖共享模块中的通用约束，并将 `<evidence_mode>` 固定为 `A`。

### 1. 模式定义

- 证据模式：`A`
- 论文定位：**系统架构 / FPGA 原型验证 / pre-silicon 证据主导**
- 推荐投稿方向：
  - DAC / DATE / FPGA / FPL / FCCM / ICCAD
  - 或系统实现导向的 EI / SCI 期刊

### 2. 本模式允许的证据

允许把以下内容作为主证据：

- RTL 功能验证
- testbench 与 regression logs
- Python↔RTL 或 golden model↔RTL 数值对齐
- FPGA 原型端到端任务验证
- 真实的综合、STA、P&R 报告（若确实存在）
- 器件感知数字等效模型
- 非理想因素注入实验
- 板级资源、频率、吞吐、功耗、延迟、任务精度

### 3. 本模式禁止的 claim

以下表述一律禁止：

- 把该论文写成 silicon paper
- 把行为模型或 FPGA 数据写成“流片实测结果”
- 把接口冻结、时序合同或 pad 规划写成“芯片成功”
- 把未来的数模双芯片集成写成“已经完成系统级闭环”
- 把器件感知数字模型写成真实模拟 CIM 宏的 silicon measurement

### 4. 研究主线

本模式的核心叙事必须稳定围绕以下主线展开：

1. 一个清晰、可实现、可验证的 IC 系统或 SoC 架构
2. 一个能在 FPGA 或等效平台上完成端到端验证的实现
3. 一个与目标模拟/器件侧一致的接口与等效模型
4. 一组足以支撑贡献的系统级指标与公平对比

对于当前项目，优先采用如下叙事方式：

- 主线是“器件感知的 SNN SoC 数字架构设计与 FPGA 原型验证”
- SNN 只是工作负载与应用场景，不应把论文写成训练算法论文
- Python 训练、量化、样本导出仅作为离线权重生成和软硬件一致性工具，不是主贡献

### 5. 关键实验矩阵

`EXPERIMENT_DESIGN` 阶段至少覆盖以下实验块：

1. **功能正确性**
   - 关键模块单测
   - 端到端 smoke/regression
   - software↔RTL 或 Python↔RTL 对齐
2. **系统级任务验证**
   - FPGA 上真实 workload、真实输入集、真实输出判定
   - 任务精度、延迟、吞吐、资源、频率、功耗
3. **器件感知评估**
   - 非理想注入
   - 精度/鲁棒性变化
   - 参数敏感性
4. **对照与消融**
   - 去掉关键机制后的对比
   - 黑盒基线或简化基线
   - 若声称接口/缓冲/调度优化有效，必须给有无该机制的对照
5. **实现代价**
   - FPGA 资源利用率
   - 若存在真实综合/STA/P&R，则补充面积、频率、功耗估计

### 6. 论文结构模板

本模式默认正文结构建议为：

1. `Introduction`
2. `Related Work`
3. `System Architecture`
4. `Device-Aware Modeling and Implementation`
5. `Experimental Setup`
6. `Results`
7. `Discussion and Limitations`
8. `Conclusion`

如果论文更偏 SoC 实现，也可以改成：

1. `Introduction`
2. `Related Work`
3. `Architecture`
4. `RTL/FPGA Implementation`
5. `Experimental Setup`
6. `Results`
7. `Discussion`
8. `Conclusion`

### 7. Figure 规划

本模式至少规划以下图表：

- `Figure 1`
  - 系统架构总览
  - 关键数据通路
  - 数字控制链、CIM 接口、FPGA/验证位置
- 接口或时序图
  - 关键控制协议
  - bit-plane / WL / ADC 扫描 / 输出路径
- 端到端验证图
  - FPGA 板卡或验证平台
  - 工作流图
- 主结果表
  - 任务精度、延迟、吞吐、资源、功耗
- 消融/鲁棒性图
  - 非理想注入
  - 参数 sweep

### 8. 审稿防御重点

在 `PEER_REVIEW`、`3RD_PARTY_REVIEW`、`REBUTTAL` 阶段，必须主动回答下列问题：

- 这项工作是系统/架构贡献，还是只是把现有模块拼起来？
- FPGA 原型是否真的支撑了论文 claim？
- 器件感知模型是否有来源、有参数依据、有局限性说明？
- baseline 是否公平？
- 论文是否诚实地区分了 FPGA / RTL / 综合结果与未来 silicon 结果？
- 如果没有 silicon，为何仍值得发表？

### 9. 质量门

只有同时满足下列条件，`QUALITY_GATE` 才能通过：

- 有完整的 regression 和端到端验证证据
- 关键 claim 至少有一组真实可复现结果支撑
- 若声称 FPGA 验证，则必须有板级结果，而不是仅有综合
- 若声称面积/时序/功耗，则必须引用真实工具报告，而非人工估算
- 若声称器件感知或鲁棒性，则必须给参数来源与实验曲线
- 全文不得出现任何 silicon 成功的暗示性表述

### 10. 模式专属红线

- 不得将 `test mode`、旁路模式、黑盒模型、离线代理测试写成系统级任务实测的唯一证据。
- 不得因为“FPGA 跑通”就暗示“ASIC 也必然成功”。
- 不得把 `post-synthesis` 或 `P&R estimate` 写成 tapeout 后结果。
- 不得把模拟团队待提供的信息写成已经掌握的已知常数。
