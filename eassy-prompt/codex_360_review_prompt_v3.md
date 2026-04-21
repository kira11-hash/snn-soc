# Codex 360° 审查 Prompt V3 — Phase A0 闭环 + 路线图 v2 审阅

## 背景

SNN SoC 项目（v2 分支）。自 V2 审查以来已完成两轮修复 + 路线图一次大修订，现在请做第 3 轮审查。

### 本轮审查对象

**一、RTL / TB / 文档改动**（Phase A0 闭环）
Codex 第 2 轮审查报告的 5 个 finding 全部修复，加上 Ultra Review 次级问题（3 个）和若干架构接口改动。

**二、路线图 v2 草稿**
根据 GPT 第 1 轮路线图审阅吸收了 6 条建议（HIGH 2 + MEDIUM 4），重新输出。草稿位置：
`eassy-prompt/v2_roadmap_draft.md`

两部分独立审查，每部分单独出总表。

---

## 🟢 审查基线（请先跑一遍确认）

```bash
cd sim && bash run_icarus_light.sh                # 期望 LIGHT_SMOKETEST_PASS
cd sim && bash run_icarus_weighted.sh             # 期望 WEIGHTED_SIM_PASS
cd sim && bash run_multilayer.sh                  # 期望 MULTILAYER_SMOKE_PASS
cd sim && bash run_multilayer_scan_ext.sh         # 期望 MULTILAYER_SCAN_EXT_PASS (新增，T1 bl_sel=63, T2 bl_sel=127)
cd sim && bash run_sample_align.sh                # 期望 SAMPLE_ALIGN_PASS (100/100)
cd sim && bash run_adc_sat_counter.sh             # 期望 ADC_SAT_COUNTER_PASS
cd sim && bash run_jtag_rescue_top_icarus.sh      # 期望 JTAG_RESCUE_TOP_PASS
cd sim && bash run_e203_icarus.sh                 # 期望 E203_SMOKETEST_PASS
cd sim && iverilog -g2012 -gno-assertions ../rtl/top/snn_soc_pkg.sv ../rtl/snn/cim_program_ctrl.sv ../tb/cim_program_ctrl_tb.sv -s cim_program_ctrl_tb -o cim_prog_tb.vvp && vvp cim_prog_tb.vvp   # 期望 CIM_PROGRAM_CTRL_PASS 7/7
```

所有 9 个 TB 在本稿发出时全部 PASS。

---

## 第 1 部分：RTL / TB / 文档 审查

### 本轮修复清单

| ID | 严重度 | 内容 | 文件 |
|---|---|---|---|
| D2-001 | HIGH | 逐 cell erase 路径 prog_col 越界 guard 扩展到 `!prog_full_array` 条件，覆盖逐 cell erase 非法列 | `rtl/snn/cim_program_ctrl.sv` |
| D2-002 | MEDIUM | `sim/models/cim_macro_blackbox_weighted_icarus.sv` bl_sel 从 5-bit 扩到 `$clog2(MAX_BL_SCAN)=7`，assert 从 $error 降为 $warning | 同上文件 |
| D2-003 | MEDIUM | 新 TB `tb/multilayer_scan_ext_tb.sv` + `sim/run_multilayer_scan_ext.sh`，覆盖 bl_cnt=64（T1）和 bl_cnt=128（T2），验证 bl_sel 达到预期最大值 | tb + sim |
| D2-004 | MEDIUM | `doc/15_asic_pad_map.md` 更新：V1 48 pad 基线 + V2 新增 5 pad（bl_sel[5:6] + prog_en/erase_en/verify_en） = 53/72 pad 已用 | doc |
| D2-005 | LOW | `doc/03_cim_if_protocol.md` 推理接口 bl_sel 位宽 + V1/V2 路径说明 | doc |
| **D2-006** | HIGH | Ultra Review 补：prog_row 越界 guard（与 prog_col 对称保护），`(prog_row >= 6'(PROG_ROWS))` 也触发 ST_FAIL | `rtl/snn/cim_program_ctrl.sv` |
| **D2-007** | MEDIUM | Ultra Review 补：`reload_layer_weights` task 内加 `@(negedge clk)`，避免阻塞赋值 vs always_ff 非阻塞赋值的 multi-driver 竞争 | `rtl/snn/cim_macro_blackbox.sv` |
| **D2-008** | LOW | Ultra Review 补：e203_tb `$finish` 前 release force 信号；multilayer_scan_ext_tb 清零 bl_sel_max_observed 用 `@(negedge clk)` 避边沿 | tb |
| A4-task | feat | `cim_macro_blackbox.sv` 暴露 `reload_layer_weights(string hex_path)` task，TB 层切换时调用，$readmemh 加载权重 + 同步清零 prog_pulse_acc | `rtl/snn/cim_macro_blackbox.sv` |
| helper | feat | `e203_tb.sv` 封装 `release_cpu_for_preloaded_boot()` task，说明仅用于 $readmemh 预加载场景，JTAG rescue TB 不得使用 | `tb/e203_tb.sv` |
| sync | fix | `tb/cim_program_ctrl_tb.sv` 信号 `prog_bl_sel` 从 5-bit 扩到 7-bit 跟 DUT 同步 | `tb/cim_program_ctrl_tb.sv` |

### 特别关注项

#### D2-006 prog_row guard
修复位置：`cim_program_ctrl.sv:172-180`
```systemverilog
if (!prog_full_array && ((prog_col >= 5'(PROG_COLS)) ||
                         (prog_row >= 6'(PROG_ROWS)))) begin
    state <= ST_FAIL;
end
```
- 请验证：`prog_row` 是 6-bit 输入、`PROG_ROWS = NUM_INPUTS = 64`，当前隐性安全（最大值 63）
- 如果 `PROG_ROWS` 未来改小（比如 48），这里是否还工作
- 是否有场景 `prog_erase && prog_full_array` 但 `prog_row` 仍重要？（理论上全阵列不 care 行，但请确认）

#### D2-007 reload_layer_weights 竞争
修复方式：task 内首行 `@(negedge clk);`
- 请验证：TB 在任意时刻调用此 task 是否安全（可能在 posedge clk 前、后、中间）
- 边界：调用时 rst_n=0 会如何？（目前 task 里没 guard rst_n）
- weight_mem 的 $readmemh 写入 + always_ff 写入（prog_en/erase_en 路径）如果同时发生的竞争

#### D2-003 新 TB 覆盖度
- 只验证了 bl_sel 最大值到达 63/127，**没验证** eff_half_count 差分输出是否正确、neuron_in_data_wide[高索引] 是否被更新
- 请评估：这个 smoke 强度够不够？是否应该加 data pattern 验证（test mode 下返回 pos/neg 固定值，检查差分结果符合预期）

#### A4 reload task 架构
- 这个 task 是"仿真 shortcut"，真实硬件是 cim_program_ctrl FSM 跑 1280 次编程
- 请验证：TB 用 reload task 跳过 FSM 时，系统状态是否自洽（没有遗留的 prog_busy / prog_done_pulse sticky 等）
- 多层切换时 reload 时序：上一层推理完 → reload → 下一层推理开始，有没有需要的 delay

#### E203 helper
- release_cpu_for_preloaded_boot() 内部 force 没有对应 release（在仿真主 initial 结束时才 release）
- 如果 TB 中途 soft_reset CPU，helper 的 force 是否会和 reset 流程冲突

---

## 第 2 部分：路线图 v2 草稿审查

### 文档位置
`eassy-prompt/v2_roadmap_draft.md`

### GPT 第 1 轮建议吸收情况

请对照你上一轮给的 6 条建议，检查是否都被正确吸收：

| 原建议 | 新稿处理 |
|---|---|
| A4 不应常驻 4 层权重 | ✅ A4 拆成 A4a/A4b/A4c；A4b 明确"单 macro + reload 接口" |
| D1 需补充"第 2 轮待闭环" | ✅ Phase A0 整块新增，所有 D2 finding 列出 |
| E203 表述避免"bug" | ✅ 改为"已适配 V2 cpu_reset_hold 安全引导语义" + 决策表强调"不是 bug 是功能" |
| A6 口径拆分 | ✅ A6.a（RTL 等价性 100/100）+ A6.b（Fashion-MNIST accuracy 分开报告） |
| 黑盒合并不作硬门槛 | ✅ A4c 改为"可选"，A4a/A4b 已在 A0 完成 |
| Pad map 前置到 Phase D0/A0 | ✅ 移到 A0，D3 删除 |

**新增条目**：
- Phase C0（新增）：Vivado synthesis-only 资源预估门槛
- DC 开闸指标 6：scan128/scan64 回归 PASS
- 新增决策：E203 reset hold 语义明确

**请特别审查**：
1. 上述吸收是否完整、准确
2. 时间估算是否合理（A0 完成后，Phase A 实质阶段 3 周是否够）
3. 风险矩阵是否有漏掉的项
4. DC 开闸硬指标 6 条是否覆盖充分
5. A6.a 的"RTL 等价性 100/100 不是调参问题"这个框架是否逻辑闭环

### 路线图的开放问题（可能需要 Codex 帮判断）

1. Fashion-MNIST 4 层 64→32→16→10 拓扑，Python float accuracy 预期能到多少？（凭经验估 80-85%）这个目标合理吗
2. B3b 完整编程闭环 1280×4 cells，脉宽缩短到 5 cycles 后，Icarus 跑完时间估算 ~3-5s 是否准确
3. ZCU102 用 Vivado 2023.x 综合 snn_soc_top（约 50k LUT 估算）需要的时间预估合理吗
4. A4b 的"reload 接口"是仿真 shortcut，C6 FPGA 上板时**不能用此接口**（FPGA 没有 $readmemh 机制）—— 路线图是否清楚地表达了这个语义鸿沟

---

## 审查格式要求

### 第 1 部分（RTL/TB/文档）

```
【编号】D3-XXX
【维度】RTL 正确性 / 综合安全 / TB 覆盖 / 文档一致 / 架构完整 / 其他
【严重度】CRITICAL / HIGH / MEDIUM / LOW
【文件】path:line
【问题】具体描述
【仿真激励】（如是 RTL bug，按 CLAUDE.md RTL 漏洞报告规范）
【修复建议】最小改动
```

### 第 2 部分（路线图）

```
【建议编号】R-XXX
【优先级】HIGH / MEDIUM / LOW
【章节】Phase X / 决策 N / 风险矩阵 / ...
【问题】
【建议修改】
```

### 最后两张总结表

**RTL/TB/文档**：
```
| 维度 | CRITICAL | HIGH | MEDIUM | LOW |
```

**路线图**：
```
| 章节 | HIGH | MEDIUM | LOW |
```

---

## 审查约束（沿用）

1. 先读 `CLAUDE.md` 误报知识库，避免 FP-001~FP-008 重复
2. 本项目 SystemVerilog RTL，用硬件思维审查
3. `cim_macro_blackbox.sv` 行为模型（`\`ifdef SYNTHESIS` else 分支），不综合
4. 单时钟域（除 JTAG tck），不报 CDC 误报
5. RTL bug 必须提供仿真激励
6. **E203 CPU 上电 hold 是 V2 安全引导功能**，不是 bug；e203_tb 的 force 是 TB 旁路，不要报成"force 误用"
7. 路线图部分可以给"方向性"建议，不一定非要有具体 RTL 改动

---

## 本轮目标

- 确认 A0 修复没有引入新 bug
- 确认路线图 v2 吸收建议完整、可落地
- 如果没有 CRITICAL/HIGH，我就把路线图落地到 `doc/17_v2_roadmap.md`，开始 Phase A 实质工作
