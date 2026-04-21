# 20. IC 论文模式模块 B.2：双芯片集成成功版

## 用法

本文件是 `evidence_mode = B.2` 的模式模块。使用时请先拼接共享模块 [`eassy-prompt/17_ic_paper_prompt_shared.md`](17_ic_paper_prompt_shared.md)，再追加本文件中的“模式 Prompt 正文”。

适用场景：

- 数字芯片与模拟 CIM 芯片都已流片成功
- 两颗芯片已经通过 PCB 或等效板级方式完成互联
- 可以提供真实端到端系统验证与测量
- 能够区分单芯片指标与系统级指标，并解释 pre-silicon 与 post-silicon 偏差

---

## 模式 Prompt 正文

以下模式模块覆盖共享模块中的通用约束，并将 `<evidence_mode>` 固定为 `B.2`。

### 1. 模式定义

- 证据模式：`B.2`
- 论文定位：**数字+模拟双芯片流片成功 + PCB 级系统集成 + post-silicon 端到端验证**
- 推荐投稿方向：
  - DAC / DATE / ISSCC / VLSI / JSSC / TCAS-I
  - 具体风格取决于论文重点更偏系统还是更偏测量

### 2. 本模式允许的证据

允许把以下内容作为论文主证据：

- 数字芯片 silicon
- 模拟 CIM 芯片 silicon
- 双芯片 PCB 互联
- 真实端到端任务运行
- 数模接口时序、校准、噪声、功耗、精度、吞吐、能效、鲁棒性测量
- 单芯片与系统级功耗/面积/频率/稳定性分解
- pre-silicon 与 post-silicon 的偏差对比与解释

### 3. 本模式禁止的 claim

以下表述一律禁止：

- 混淆单芯片指标与双芯片系统指标
- 把预硅行为模型结果写成最终 silicon 结果
- 把单一工作点结果写成全工作范围结论
- 省略 PCB、仪器、温度、电源、时钟、校准条件
- 省略数字部分与模拟部分各自的责任边界

### 4. 研究主线

本模式的叙事必须围绕以下主线：

1. 数字与模拟两颗芯片通过明确的接口协同工作
2. 双芯片系统在真实板级环境中完成端到端验证
3. 论文展示的不只是“能连起来”，而是量化了协同收益、代价与局限
4. 所有结论必须清晰区分：数字部分、模拟部分、系统整体

优先采用如下定位：

- `dual-chip heterogeneous SNN/CIM system`
- `silicon-validated digital-analog co-designed system`
- `PCB-integrated post-silicon end-to-end verification`

### 5. 关键实验矩阵

`EXPERIMENT_DESIGN` 阶段至少覆盖以下实验块：

1. **双芯片 bring-up**
   - 供电、时钟、复位、互联通断
   - 接口时序收敛
   - guard time / setup / hold / 校准流程
2. **系统级端到端任务**
   - 真实输入
   - 真实输出
   - 真实分类或推理结果
   - 任务级延迟、吞吐、能效
3. **单芯片与系统分解**
   - 数字芯片指标
   - 模拟芯片指标
   - 双芯片整体指标
4. **鲁棒性与边界**
   - 电压、频率、温度
   - 噪声与校准
   - 多次重复测量或多板/多芯片数据（若可得）
5. **偏差解释**
   - pre-silicon vs post-silicon
   - FPGA/behavioral model vs silicon
   - 误差来源、非理想来源、接口瓶颈来源

### 6. 论文结构模板

本模式默认正文结构建议为：

1. `Introduction`
2. `Related Work`
3. `Dual-Chip System Architecture`
4. `Digital-Analog Interface and Co-Design`
5. `Chip Implementation and PCB Integration`
6. `Measurement Setup`
7. `Results`
8. `Discussion`
9. `Conclusion`

若论文更偏电路与测量，也可以改成：

1. `Introduction`
2. `Related Work`
3. `System and Circuit Overview`
4. `Chip Implementation`
5. `PCB-Level Integration and Measurement Setup`
6. `Results`
7. `Discussion and Limitations`
8. `Conclusion`

### 7. Figure 规划

本模式至少规划以下图表：

- `Figure 1`
  - 双芯片整体系统图
  - 数字 die、模拟 die、PCB、外部测试仪器的关系
- 芯片与板级证据
  - 数字 die photo
  - 模拟 die photo
  - PCB 或测试板照片
  - 关键互联示意
- 接口与测量图
  - 关键接口时序
  - 校准流程
  - 波形或示波器截图对应的可量化结论
- 主结果表
  - 系统级精度、吞吐、功耗、能效、延迟
- 分解与偏差图
  - 单芯片与系统分解
  - pre-silicon vs post-silicon 偏差
  - 鲁棒性与边界条件

### 8. 审稿防御重点

在 `PEER_REVIEW`、`3RD_PARTY_REVIEW`、`REBUTTAL` 阶段，必须主动回答下列问题：

- 双芯片系统真正的新颖性在哪里？
- 为什么必须是数模协同，而不是分别独立存在？
- 接口与 PCB 集成的代价是否被诚实量化？
- 系统级指标是否足以支撑声称的优势？
- 单芯片指标与系统级指标是否被清晰分开？
- pre-silicon 与 post-silicon 差异是否解释充分？
- 局限性是否诚实，包括校准、噪声、温漂、封装、板级互联、可扩展性等？

### 9. 质量门

只有同时满足下列条件，`QUALITY_GATE` 才能通过：

- 数字芯片与模拟芯片都具备真实存在的 silicon 证据
- 有双芯片互联和端到端任务的真实实测结果
- 有明确的 measurement setup：仪器、电压、频率、温度、校准方法、输入输出路径
- 主结果表中清楚区分数字、模拟和系统整体指标
- 有至少一组偏差解释：pre-silicon vs post-silicon
- 全文没有任何混淆证据等级或混淆指标归属的表述

### 10. 模式专属红线

- 不得把模拟芯片的局部单元测试写成完整系统结果。
- 不得把一个工作电压、一个频率、一个温度点的数据写成“系统全面稳定”。
- 不得只报总系统功耗，而不区分数字与模拟部分。
- 不得只给概念性接口图，不给真实板级或测试条件。
