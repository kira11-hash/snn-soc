# Codex 360° 审查 Prompt V4 — Codex 第 3 轮 finding 闭环 + 路线图 v3 审阅

## 背景

SNN SoC 项目（v2 分支）。**第 3 轮审查已完成并闭环所有 finding**，这是第 4 轮。

- 第 2 轮：5 个 finding → Ultra Review 补 3 个 → 合并后 8 个全修
- 第 3 轮：Codex 独立验证 D3-001 CRITICAL + 5 个新 finding（D3-002~D3-006）+ 路线图 8 条建议
- **第 3 轮全部闭环**：D3-001（已在本侧 Ultra Review 中发现并修复）、D3-002 ~ D3-006 全修、R-001~R-008 全吸收

本轮要做两件事：
1. 确认 A0 彻底闭环（CIM_PROGRAM_CTRL 真的 7/7 PASS，不是 stale vvp 假象）
2. 确认路线图 v3 吸收 GPT 第 2 轮建议完整、可落地

---

## ⚠️ 重要提示（防止再次 stale vvp 陷阱）

**Windows Icarus 编译命令的正确形式**：
```bash
iverilog -g2012 -gno-assertions -o /tmp/xxx.vvp -s top_module <files...>
vvp /tmp/xxx.vvp
```

- `-s` 和 `-o` 必须**放在源文件前**
- 每次 commit 前编译产物用 `/tmp/xxx.vvp` 显式路径，避免读到 stale `a.out` 或残留 vvp
- 上一轮 prompt 的命令 `iverilog ... -s xxx -o xxx.vvp files` 把 `-s xxx` 当成文件名报错 `-s: No such file or directory`
- 这就是 CIM_PROGRAM_CTRL 之前"7/7 PASS"的假象根源 —— iverilog 没编译，vvp 跑的是旧版本

---

## 🟢 审查基线（请先跑一遍确认）

```bash
# 标准 shell 命令（注意 -o 和 -s 放在源文件前）
cd sim && bash run_icarus_light.sh                # 期望 LIGHT_SMOKETEST_PASS
cd sim && bash run_icarus_weighted.sh             # 期望 WEIGHTED_SIM_PASS（无 bl_sel 宽度告警）
cd sim && bash run_multilayer.sh                  # 期望 MULTILAYER_SMOKE_PASS
cd sim && bash run_multilayer_scan_ext.sh         # 期望 MULTILAYER_SCAN_EXT_PASS（T1/T2 含 pattern 检查）
cd sim && bash run_sample_align.sh                # 期望 SAMPLE_ALIGN_PASS (100/100)
cd sim && bash run_adc_sat_counter.sh             # 期望 ADC_SAT_COUNTER_PASS
cd sim && bash run_jtag_rescue_top_icarus.sh      # 期望 JTAG_RESCUE_TOP_PASS
cd sim && bash run_e203_icarus.sh                 # 期望 E203_SMOKETEST_PASS

# CIM_PROGRAM_CTRL 独立编译（注意 -o 显式路径）
cd sim && iverilog -g2012 -gno-assertions -o /tmp/cim_prog.vvp \
  ../rtl/top/snn_soc_pkg.sv ../rtl/snn/cim_program_ctrl.sv ../tb/cim_program_ctrl_tb.sv
vvp /tmp/cim_prog.vvp                              # 期望 CIM_PROGRAM_CTRL_PASS (7 PASS, 0 FAIL)
```

所有 9 个 TB 在本稿发出时已经过本侧**严格验证**（每次都用 `-o /tmp/xxx.vvp` 确保不读 stale）。

---

## 第 1 部分：RTL / TB / 文档 审查（本轮闭环确认）

### 本轮修复清单

| ID | 严重度 | 内容 | 文件 |
|---|---|---|---|
| **D3-FIX** | CRITICAL | `6'(PROG_ROWS)=0` 位宽截断 → 改用 `int'()` cast。D2-006 guard 实际修复 | `rtl/snn/cim_program_ctrl.sv:205-207` |
| D3-002 | MEDIUM | 新增 `ENABLE_BRAM_WEIGHT_MODEL` package 参数。`snn_soc_top` 的 `P_USE_BRAM_WEIGHTS` 改为 OR 两者 | `snn_soc_pkg.sv` + `snn_soc_top.sv` |
| D3-003 | MEDIUM | scan_ext TB 加 pattern 检查：T1/T2 验证 `raw_data[5/31/63/127]` + `neuron_in_data_wide[5]=100` | `tb/multilayer_scan_ext_tb.sv` |
| D3-004 | LOW | reload task 加 3 个 `$fatal` runtime guard（rst_n=0 / cim_busy/adc_busy / prog_en/erase_en） | `rtl/snn/cim_macro_blackbox.sv` |
| D3-005 | LOW | doc/03 row guard 描述同步（prog_col ≥ PROG_COLS **或** prog_row ≥ PROG_ROWS） | `doc/03_cim_if_protocol.md` |
| D3-006 | LOW | chip_top 注释 Pad 19-50 + 分段说明 V1/V2/ESD | `rtl/top/chip_top.sv` |
| CLAUDE.md | 规则 | 新增 2 条禁止行为：`N'(large_param)` 截断 + stale vvp 依赖 | `CLAUDE.md` |
| bug log | 记录 | D3-002~D3-006 + D3-FIX 完整记录 | `已修复的bug原因及其解决办法.md` |

### 请独立确认（以免再次被"声称 PASS 但实际没编译"误导）

1. **必须亲自跑 `iverilog -g2012 -gno-assertions -o /tmp/fresh.vvp ... && vvp /tmp/fresh.vvp`** 确认 CIM_PROGRAM_CTRL 真的 7/7 PASS
2. 故意 inject 一个非法 test case：`prog_row=64, prog_col=0, prog_erase=1, prog_full_array=0`，验证 prog_fail 是否正确置起（证明 D3-FIX 后 guard 还在工作）
3. 验证 D3-002：实例化 `snn_soc_top #(.ENABLE_PROGRAM_MODE=0, .ENABLE_MULTI_LAYER=1)` 并且 `+define+SIM_BRAM_WEIGHT_MODEL`，确认 weight_mem 确实参与推理（P_USE_BRAM_WEIGHTS 应该 = 1）
4. 验证 D3-004：TB 故意在 rst_n=0 期间调用 reload_layer_weights，期望 $fatal 立即终止

### 特别关注项

#### D3-FIX 隐患扫描
请全局 grep `N'([A-Z_]+)` 看是否还有其他位宽截断陷阱：
```bash
grep -rn "[0-9]\+'([A-Z_]\+)" rtl/
```
当前已知的安全值（未触发截断）：`8'(MAX_BL_SCAN=128)`, `8'(ADC_CHANNELS=20)`, `8'(NUM_OUTPUTS=10)`, `5'(PROG_COLS=20)` — 全部 < 2^N

#### D3-003 TB 覆盖限制
pattern 检查依赖 test_mode MUX 语义（bl_sel < NUM_OUTPUTS 返回 pos，否则 neg）。这个 MUX 在 V2 多层场景下不完美（以 NUM_OUTPUTS=10 为界，不是 eff_half_count）。
- 是否应该在 snn_soc_top 加一个 V2-aware test_mode 路径？
- 或者保持现状，把更强的差分验证留给 Phase V2.A 的 multilayer_sample_align_tb（真权重 + 真 diff 对齐）？

#### D3-002 默认行为变化
`ENABLE_BRAM_WEIGHT_MODEL` 默认 0，所以 V1 行为完全不变。但如果有 TB 之前依赖 `ENABLE_PROGRAM_MODE=1` 来启用 BRAM 权重，现在需要显式 OR 了？请确认没有 V1 TB 会被这个拆分破坏（当前 V1 TB 不传 ENABLE_PROGRAM_MODE，默认 0，所以两个都 0，popcount 行为不变）

---

## 第 2 部分：路线图 v3 草稿审查

### 文档位置
`eassy-prompt/v2_roadmap_draft.md`（已更新为第 3 稿）

### GPT 第 2 轮建议吸收情况

| 编号 | 优先级 | 原建议 | 新稿处理 |
|---|---|---|---|
| R-001 | HIGH | Phase A0 状态要对齐真实（CIM_PROGRAM_CTRL 曾经 FAIL） | ✅ A0 清单加粗 D3-FIX + 列出 stale vvp 假象，"真 PASS"标注 |
| R-002 | HIGH | B3b cell 数 1280×4=5120 口径错 | ✅ B3b 改为 manifest 自动统计，估时 10-15s 而非 3-5s；风险矩阵加新条 |
| R-003 | HIGH | C6 FPGA 禁止 shortcut | ✅ C6 新增禁用条款，DC 开闸指标 3 改为"真实可综合路径"；新增语义鸿沟说明 |
| R-004 | MEDIUM | A3 口径 Python exported-hex = Python quantized | ✅ A3 验收改为 quantized，不是 float |
| R-005 | MEDIUM | A2 acc 硬门槛 80%，stretch 85% | ✅ A2 拆成 hard/stretch 双阈值 |
| R-006 | MEDIUM | A5 TB 需要 BRAM 权重模型启用 | ✅ A5 验收要求 `ENABLE_BRAM_WEIGHT_MODEL=1` 或 `ENABLE_PROGRAM_MODE=1`（D3-002 也新增了这个参数） |
| R-007 | LOW | A6.b 三级 accuracy 口径 | ✅ 拆分 Python full / RTL alignment / FPGA demo / RTL full（可选 overnight） |
| R-008 | LOW | C0 阈值 <30% 太硬 | ✅ 改为 目标<30% 警戒50% 阻断>70% |

### 请验证
1. 8 条建议是否吸收完整、准确
2. 时间线是否合理（A0 花了 1 天，实际 Phase A 3 周够吗）
3. DC 开闸 6 条硬指标是否覆盖充分
4. "仿真 shortcut vs FPGA 真实路径"的语义鸿沟描述是否清楚
5. 风险矩阵新增的 "B3b cell 数大幅超预期" 和 "C6 无法走真实编程路径" 是否合理

---

## 审查格式要求

```
【编号】D4-XXX 或 R4-XXX
【维度】RTL 正确性 / 综合安全 / TB 覆盖 / 文档一致 / 架构完整 / 路线图
【严重度】CRITICAL / HIGH / MEDIUM / LOW
【位置】文件:行号 或 路线图章节
【问题】
【仿真激励】（如是 RTL bug）
【修复建议】
```

两张总结表：RTL/TB/文档 + 路线图

---

## 审查约束（沿用）

1. 先读 `CLAUDE.md` 误报知识库（FP-001~FP-008）+ 新增的禁止行为（`N'()` 截断 + stale vvp）
2. SystemVerilog RTL 思维审查
3. `cim_macro_blackbox.sv` 行为模型分支不综合
4. 单时钟域，不报 CDC
5. RTL bug 必须提供仿真激励
6. E203 CPU 上电 hold 是 V2 安全功能，不是 bug
7. 路线图建议可以给方向性，不强制 RTL 改动

---

## 本轮目标

- **最重要**：用 `iverilog -o /tmp/fresh.vvp` 独立验证 CIM_PROGRAM_CTRL 真的 PASS（上一轮 stale vvp 已经坑过一次）
- 确认 D3-001~D3-006 修复到位、没有引入新问题
- 确认路线图 v3 吸收 R-001~R-008 建议完整
- 如果没有新 CRITICAL/HIGH，就把 `v2_roadmap_draft.md` 落地为 `doc/17_v2_roadmap.md`，正式进入 Phase V2.A 实质工作

---

## 附：本侧确认的回归状态（2026-04-18 22:00）

全部用 `-o /tmp/xxx.vvp` 显式编译，无 stale 假象：

| TB | 状态 | 时间戳 |
|---|---|---|
| LIGHT_SMOKETEST | ✅ PASS | 21:50 |
| WEIGHTED_SIM | ✅ PASS | 21:51 |
| MULTILAYER_SMOKE | ✅ PASS | 21:52 |
| MULTILAYER_SCAN_EXT（含 D3-003 pattern） | ✅ PASS | 21:55 |
| SAMPLE_ALIGN (100/100) | ✅ PASS | 21:40 |
| ADC_SAT_COUNTER | ✅ PASS | 21:42 |
| JTAG_RESCUE_TOP | ✅ PASS | 21:41 |
| E203_SMOKETEST | ✅ PASS | 21:57 |
| CIM_PROGRAM_CTRL | ✅ 7 PASS 0 FAIL | 21:45（用 /tmp/cim_prog_v.vvp 验证真 PASS） |

本侧 stale vvp 教训已写入 CLAUDE.md，如果你发现"意外 PASS"请先怀疑 stale binary。
