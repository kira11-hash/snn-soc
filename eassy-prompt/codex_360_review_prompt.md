# Codex 360° 审查 Prompt — V2 可配脉冲 + 全阵列擦除 + 时间多层

## 背景

这是一个 SNN SoC 项目（v2 分支），数字芯片 + 模拟 CIM 芯片分别流片、PCB 互联。最近完成了一轮大更新（Iteration 16）：

1. **可配置编程脉冲宽度**：新增 `REG_PROG_PULSE_WIDTH`(0x90) 和 `REG_PROG_ERASE_WIDTH`(0x94)，CPU 可配 100ns~1ms
2. **全阵列擦除模式**：`PROG_CTRL.FULL_ARRAY` bit[2]，64 WL 同时拉高，1ms 单脉冲，跳过 verify
3. **自计时脉冲**：`cim_program_ctrl` FSM 新增 `ST_PULSE_HOLD` 状态，数字侧倒计时控制脉宽，不等模拟侧 `cim_done`
4. **时间多层推理**：固件驱动（推理→擦→重编程→下一层推理），RTL 只提供原子操作

已经过 3 轮 Ultra Review（RTL 代码 + 文档一致性 + 交叉验证），修复了 10 个问题。CIM_PROGRAM_CTRL TB 7/7 PASS，LIGHT_SMOKETEST_PASS。

---

## 审查范围

请从以下 6 个维度进行 360° 审查：

### 维度 1：RTL 功能正确性

**核心文件**：
- `rtl/snn/cim_program_ctrl.sv` — 11 状态 FSM，关注：
  - `ST_PULSE_HOLD` 自计时逻辑：`pulse_width_cnt` 倒计时是否有 off-by-one？
  - 全阵列擦除路径：`prog_wl_spike <= {NUM_INPUTS{1'b1}}`，跳过 verify 直接 → ST_PASS 的条件是否完备？
  - 逐 cell 模式的 double-NBA 模式（`prog_wl_spike <= '0; prog_wl_spike[prog_row] <= 1'b1;`）——IEEE 1800 合规但是否所有综合工具（DC/Genus）都支持？
  - `prog_dac_valid` 的生命周期：ST_SETUP 拉高 → ST_PULSE 隐式保持（FF hold）→ ST_READBACK 拉低——隐式保持是否有风险？
  - verify 窗口：写入 ±2 LSB、擦除 ≤1 LSB 是 magic number（未参数化），是否应该做成寄存器可配？

- `rtl/snn/cim_macro_arbiter.sv` — 推理/编程互斥仲裁
- `rtl/snn/layer_sequencer.sv` — 多层调度 FSM
- `rtl/snn/spike_feedback.sv` — 层间 spike mask 回注
- `rtl/snn/lif_neuron_alu.sv` — 128 神经元时分复用 ALU

- `rtl/reg/reg_bank.sv` — 寄存器读写逻辑，关注：
  - PROG_PULSE_WIDTH/ERASE_WIDTH 的 read-back 路径是否用命名常量
  - W1P/W1C 行为是否正确
  - `prog_retry_limit` 是否引用 `PROG_VERIFY_RETRY_MAX`

- `rtl/top/snn_soc_top.sv` — 顶层布线
- `rtl/top/snn_soc_pkg.sv` — 参数包

### 维度 2：RTL 综合安全性

- 所有 `always_ff` 块中是否存在 latch 推断风险？
- 有没有组合环（combinational loop）？
- 有没有不完整的 case 语句（缺 default）？
- 有没有跨时钟域信号未做同步（CDC）？（注：整个数字部分是单时钟 `clk`，JTAG 有独立 `jtag_tck` 已有 2-FF sync）
- 参数化信号位宽是否在所有实例化中保持一致？
- `snn_soc_pkg` 中的参数是否被所有消费者正确引用（没有硬编码魔数）？

### 维度 3：Testbench 覆盖度

**TB 文件**：
- `tb/cim_program_ctrl_tb.sv` — 7 个测试用例，检查是否覆盖了：
  - 逐 cell 写入各种 level（特别是 level=15 最大值）
  - 逐 cell 擦除后重新写入（erase→write 循环）
  - verify 失败后重试直到 retry 耗尽（FAIL 路径）
  - 并发 start 请求（busy 期间再次 fire start）
  - 寄存器热更新（编程进行中修改 prog_pulse_width 是否安全？）

- `tb/multilayer_tb.sv` — 多层 smoke test
- `tb/top_tb.sv` — 主线 TB

### 维度 4：文档一致性

核查以下文档是否与 RTL 完全一致：
- `doc/02_reg_map.md` — 权威寄存器映射
- `doc/08_cim_analog_interface.md` — 数模接口规格（§10 V2 编程接口）
- `doc/06_learning_path.md` — 学习路径（Stage 15）
- `doc/00_overview.md` — 项目概览
- `doc/16_iteration_log.md` — 迭代日志（Iter 16）
- `doc/11_analog_handoff_execution_plan.md` — 模拟对接计划
- `CLAUDE.md` — 项目约束

重点关注：
- FSM 状态数（应为 11，不是 12）
- 寄存器地址、位域、默认值
- 信号名称一致性

### 维度 5：架构完整性

- **时间多层 gap**：layer_sequencer 是为"CIM 同时持有多层权重"设计的硬件多层调度器。但 V2 的时间多层是固件驱动的（每次只推理 1 层）。这两种模式是否冲突？firmware 跑时间多层时应该用 layer_sequencer（单层模式）还是直接绕过它？
- **权重编程路径**：firmware 从哪里获取权重数据？SPI Flash → data_sram → CPU 读 → 逐 cell 写 PROG 寄存器？这条路径是否有瓶颈？
- **spike 跨层传递**：时间多层中，层 N 的 spike 输出如何传给层 N+1 的输入？是通过 output FIFO → CPU 读 → DMA 写回 input FIFO？还是 spike_feedback 可以直接用？
- **ENABLE_PROGRAM_MODE**：这个参数是否存在？如果不存在，cim_program_ctrl 是否在所有配置下都被实例化？
- **输入 tiling**：图像大于 128 时"分 tile 送入"的机制是否在硬件上有支持（膜电位跨 tile 累加不清零）？还是纯靠固件？

### 维度 6：已知限制 & 风险

- 列出所有 magic number（未参数化的常量）
- 列出所有仿真行为模型（`cim_macro_blackbox`）与真实硬件可能不一致的地方
- 列出所有"文档说要做但 RTL/TB 还没实现"的 gap
- 评估：如果器件老师改了编程脉宽默认值或 verify 阈值，需要改哪些文件？改动是否集中（单源）还是分散？

---

## 输出格式

请按以下格式输出，每个发现独立编号：

```
【编号】D1-001
【维度】RTL 功能正确性
【严重性】HIGH / MEDIUM / LOW
【文件】rtl/snn/cim_program_ctrl.sv:行号
【描述】具体问题
【建议修复】如何修
```

最后给出一个总结表：

```
| 维度 | CRITICAL | HIGH | MEDIUM | LOW |
|------|----------|------|--------|-----|
| ... | ... | ... | ... | ... |
```

---

## 重要提醒

1. 请认真阅读 `CLAUDE.md` 中的"误报经验知识库"部分，避免重复已确认的误报模式（FP-001 ~ FP-008）
2. 本项目是 SystemVerilog RTL（不是软件项目），请用硬件设计思维审查
3. `cim_macro_blackbox.sv` 是**行为模型**（仿真用），不会综合，不需要检查综合安全性
4. 如果报告一个 RTL bug，必须同时给出能触发该 bug 的仿真激励（参见 CLAUDE.md "RTL 漏洞报告规范"）
5. 数字系统为单时钟域（`clk`），不要报 CDC 误报（参考 FP-005）
