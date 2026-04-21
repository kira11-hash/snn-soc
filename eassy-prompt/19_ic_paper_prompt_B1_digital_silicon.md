# 19. IC 论文模式模块 B.1：数字流片成功版

## 用法

本文件是 `evidence_mode = B.1` 的模式模块。使用时请先拼接共享模块 [`eassy-prompt/17_ic_paper_prompt_shared.md`](17_ic_paper_prompt_shared.md)，再追加本文件中的“模式 Prompt 正文”。

适用场景：

- 数字 SoC 已 tapeout 并完成基本 bring-up
- 可以提供数字芯片真实实物、板级测试、接口验证与功耗/频率证据
- 模拟 CIM 芯片尚未形成论文主证据，或尚未完成双芯片系统闭环
- 需要写成“silicon-proven digital platform”而不是“dual-chip system paper”

---

## 模式 Prompt 正文

以下模式模块覆盖共享模块中的通用约束，并将 `<evidence_mode>` 固定为 `B.1`。

### 1. 模式定义

- 证据模式：`B.1`
- 论文定位：**数字芯片流片成功 + 单芯片 bring-up 与实测主导**
- 推荐投稿方向：
  - DAC / DATE / ICCAD / TCAD / TVLSI
  - 或系统实现与 silicon-proven platform 导向的期刊/会议

### 2. 本模式允许的证据

允许把以下内容作为论文主证据：

- 数字芯片 die photo、封装、pad map、测试板与 bring-up 记录
- 单芯片功能通路验证
- 时钟、复位、JTAG、UART、SPI、DMA、寄存器链路或其他对外接口验证
- 单芯片功耗、频率、稳定性、吞吐、延迟
- 与 FPGA / RTL / gate-level / post-layout 结果的一致性对账
- 为未来数模协同设计准备的接口合同、预硅模型与协同设计依据

### 3. 本模式禁止的 claim

以下表述一律禁止：

- 声称模拟芯片 silicon 已成功，除非确有真实测量证据
- 声称双芯片 PCB 系统已完成闭环验证
- 把接口级验证或数字侧 `test mode` 验证写成完整数模系统结果
- 把行为模型、代理模型、板上仿真写成模拟芯片 silicon result
- 把“为双芯片集成做准备”写成“已经完成双芯片集成”

### 4. 研究主线

本模式的叙事必须围绕以下主线：

1. 数字 SoC 的架构与实现是论文主贡献之一
2. 数字芯片已经完成 silicon bring-up，关键功能路径被真实验证
3. 芯片提供了后续数模双芯片系统所需的稳定控制、接口与验证底座
4. 论文结论仅限于数字芯片已证明的能力，以及真实证据支持的集成前景

对于当前项目，优先采用如下定位：

- `digital SoC for CIM-ready SNN system`
- `silicon-proven digital control substrate`
- `tapeout-proven digital platform for future dual-chip CIM integration`

### 5. 关键实验矩阵

`EXPERIMENT_DESIGN` 阶段至少覆盖以下实验块：

1. **Silicon bring-up**
   - 上电、复位、时钟
   - JTAG / UART / SPI / DMA / 寄存器访问
   - 关键状态机与输出路径验证
2. **单芯片性能与稳定性**
   - 最高稳定频率
   - 工作电压
   - 功耗
   - 长时间运行稳定性
3. **功能对账**
   - silicon vs FPGA
   - silicon vs RTL
   - silicon vs post-layout 或 gate-level（若有）
4. **集成前准备**
   - pad-facing 信号
   - 接口时序
   - 数模 handoff 条件
   - 预硅代理验证
5. **任务级验证**
   - 若可通过数字侧 `test mode` 或代理链路完成任务级验证，可以给出
   - 但必须明确标注这是数字链路诊断或代理验证，不是双芯片闭环实测

### 6. 论文结构模板

本模式默认正文结构建议为：

1. `Introduction`
2. `Related Work`
3. `System Architecture`
4. `Digital Chip Implementation`
5. `Silicon Bring-Up and Measurement Setup`
6. `Results`
7. `Discussion and Integration Outlook`
8. `Conclusion`

若需要突出验证链，也可使用：

1. `Introduction`
2. `Related Work`
3. `Digital SoC Architecture`
4. `Silicon Implementation`
5. `Bring-Up Methodology`
6. `Results`
7. `Discussion`
8. `Conclusion`

### 7. Figure 规划

本模式至少规划以下图表：

- `Figure 1`
  - 整体系统图
  - 数字芯片在完整系统中的位置
  - 数字侧与未来模拟侧的接口边界
- 芯片与测试平台
  - die photo
  - 封装或 pad map
  - bring-up 板卡与测试连接图
- 接口与时序
  - 关键接口时序
  - 关键状态机或数据路径
- 主结果表
  - 单芯片功能、频率、功耗、稳定性
- 对账图
  - silicon 与 FPGA / RTL / post-layout 的对比

### 8. 审稿防御重点

在 `PEER_REVIEW`、`3RD_PARTY_REVIEW`、`REBUTTAL` 阶段，必须主动回答下列问题：

- 这篇论文的“silicon contribution”到底是什么？
- 数字芯片是否真的做到了论文声称的能力？
- 既然模拟芯片未闭环，为什么这仍不是半成品论文？
- 数字芯片为未来数模协同提供了什么不可替代的价值？
- 是否清楚地区分了单芯片验证、接口准备、代理验证与未来系统闭环？
- 是否诚实地说明了还未完成的部分？

### 9. 质量门

只有同时满足下列条件，`QUALITY_GATE` 才能通过：

- 有真实 die / board / bring-up 证据
- 有至少一组稳定工作的单芯片测量数据
- 有清晰的测试条件：电压、时钟、温度、仪器、脚本
- 有单芯片结果与 pre-silicon 结果的对账或偏差解释
- 论文全程明确限制 claim 到数字芯片已验证范围
- 任何涉及模拟芯片的内容都只能写成接口合同、预硅模型、协同设计背景或 future integration plan

### 10. 模式专属红线

- 不得使用“system-level measurement”“end-to-end dual-chip inference”“analog macro silicon-validated”等措辞，除非对应证据真实存在。
- 不得把数字侧 `CIM test mode` 或 bypass path 的结果误写成真实数模协同结果。
- 不得把单芯片功耗或面积直接当作双芯片系统指标。
- 不得省略 bring-up 条件和失败 case 的边界说明。
