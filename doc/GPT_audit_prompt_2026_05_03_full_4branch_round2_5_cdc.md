# GPT 冷启动 prompt — Round 2.5（CDC / reset_sync 专项审查 + 自主上板）

> **生成时间**：2026-05-03 reset_sync + sync_2ff 落地完成后
> **使用方式**：复制本文件全部内容粘贴给 GPT-5.4 (effort=xhigh) 作为冷启动消息。
> 不需要前情提要——所有上下文都在本文件里。
>
> **执行模式**：你必须自己 spawn 多个 sub-agent 并行执行。
> **本轮特殊授权**：fix-on-sight + autonomous board reverify。详见 §0。

---

## 0. 你是谁，要做什么

你是一名**严苛的硬件 CDC / reset / async 审查工程师**。本轮**专项**审查
昨天刚落地的 4 条支线 reset_sync + cim_done sync 改动，要求**一次性**完成：

1. **审查**所有相关改动（CDC / reset domain / 时序 / RTL bug / TB 覆盖度 / 文档）
2. **fix-on-sight**：发现问题自己立刻修，不要让用户来回拉锯
3. **autonomous board reverify**：所有需要 FPGA 重烧的支线**自己**完成
   - cd 到对应分支 worktree
   - 运行 vivado bitgen（要花 1-2 小时/分支，并行）
   - JTAG / xsct 烧到 ZCU102
   - 抓 UART log
   - 验证 PASS marker
   - 把 fresh UART capture commit 到对应分支
4. **一个对话内**关闭所有问题——不要写"留给下一轮"，本轮就要打掉

**特殊授权**（仅本轮）：
- ✅ 可以修 RTL / TB / sim filelist / doc
- ✅ 可以执行 bitgen / xsct / 板验
- ✅ 可以 commit + push（带 `git commit -s`）
- ❌ 仍不可移动 frozen tag / 不可 force-push / 不可 rebase 已 push 的 commit

---

## 1. 本轮要审查的改动（4 条支线 closure HEAD）

| 分支 | reset_sync 落地 commit | 状态 |
|---|---|---|
| `main` | `49e78af4` fix(sys): add async-assert/sync-release reset + cim_done CDC sync | 已 push origin |
| `main-fpga-e203-alpha` | `90fa3480`（cherry-pick of `49e78af4`）| 已 push origin |
| `feature/v2-arm-fpga-demo-conv` | `bf56e942`（cherry-pick of `49e78af4` + 加 `v2b_arm_demo_top.sv` reset_sync）| 已 push origin |
| `feature/v2-fpga-e203-conv` | `08e5b8f6`（cherry-pick of `49e78af4` + 加 `snn_soc_v2b_e203_top.sv` reset_sync）| 已 push origin |

## 2. 改动内容详情

### 2.1 新增 RTL 模块（4 条支线都加了）

| 文件 | 用途 |
|---|---|
| `rtl/sys/reset_sync.sv` | 异步 assert / 同步 release 的 reset 同步器（STAGES 默认 2） |
| `rtl/sys/sync_2ff.sv` | 通用 2-FF metastability 同步器（WIDTH 参数化，default 1） |
| `tb/reset_sync_tb.sv` | reset_sync 单元 TB（T1-T4 覆盖：async-assert / sync-release latency / sub-cycle glitch / repeated cycles）|
| `tb/sync_2ff_tb.sv` | sync_2ff 单元 TB（T1-T5 覆盖：reset / propagation / falling edge / per-bit independence WIDTH=4 / async edge mid-cycle）|
| `sim/sim_reset_sync.f` + `sim/run_reset_sync.sh` | reset_sync TB 入口 |
| `sim/sim_sync_2ff.f` + `sim/run_sync_2ff.sh` | sync_2ff TB 入口 |

PASS marker：`RESET_SYNC_TB_PASS` / `SYNC_2FF_TB_PASS`

### 2.2 修改的 RTL（每条支线略不同）

| 分支 | 修改文件 | 改动 |
|---|---|---|
| 全 4 条 | `rtl/top/chip_top.sv` | 加 `rst_n_sync` + `cim_done_sync` 内部 wire；实例化 `reset_sync` + `sync_2ff`；`snn_soc_top.rst_n` 改为 `rst_n_sync`，`cim_done_ext` 改为 `cim_done_sync` |
| arm-conv | `rtl/top/v2b_arm_demo_top.sv` | 加 `rst_n_sync` 内部 wire；实例化 `reset_sync`；`v2b_axi_wrapper.rst_n` 改为 `rst_n_sync` |
| e203-conv | `rtl/top/snn_soc_v2b_e203_top.sv` | 加 `rst_n_sync` 内部 wire；实例化 `reset_sync`；下游所有子模块（e203_min_wrap / icb2simple_bridge / bus_interconnect / sram_simple × N / uart_ctrl / simple2v2btop_adapter / snn_soc_v2b_top）的 `.rst_n()` 全部改为 `rst_n_sync` |

### 2.3 sim filelist 更新

| 分支 | 文件 | 改动 |
|---|---|---|
| main | `sim/rtl_with_chip_top_check.f`、`sim/sim_chip_top_rom_smoke.f`、`sim/sim_silicon_bringup.f` | 加 `../rtl/sys/sync_2ff.sv` + `../rtl/sys/reset_sync.sv` |
| main-fpga-e203-alpha | 同 main（cherry-pick） | 同上 |
| arm-conv | `sim/rtl_with_chip_top_check.f` | 同上 |
| e203-conv | `sim/sim_v2_e203.f`、`sim/sim_v2_e203_cosim.f`、`sim/sim_v2_e203_encoder_parity.f` | 同上 |

### 2.4 已自验的 sim regression

| 分支 | 跑过的 PASS gate |
|---|---|
| main | `RESET_SYNC_TB_PASS` / `SYNC_2FF_TB_PASS` / `CHIP_TOP_ROM_SMOKE_PASS` / `E203_SMOKETEST_PASS` / `ADC_SAT_COUNTER_PASS` |
| main-fpga-e203-alpha | `RESET_SYNC_TB_PASS` / `SYNC_2FF_TB_PASS` / `CHIP_TOP_ROM_SMOKE_PASS` |
| arm-conv | `RESET_SYNC_TB_PASS` / `SYNC_2FF_TB_PASS` / `V2B_PARTIAL_WRITE_INVARIANT_TB_PASS` |
| e203-conv | `RESET_SYNC_TB_PASS` / `SYNC_2FF_TB_PASS` / `V2_E203_COSIM_PASS` |

### 2.5 关键设计决策（你审查时需要核实）

1. **STAGES=2** for reset_sync — 教科书最小值，足够 metastability margin
2. **`async_reg = "TRUE"`** 属性放在 reset_sync 和 sync_2ff 的 chain flop 上，
   帮助 Vivado place adjacent + 防止优化（ASIC 工具忽略此 attribute，无害）
3. **bl_data_pad（多 bit ADC 数据）不做位级 2-FF sync** — 因为 per-bit cycle skew
   会损坏数据。设计依赖 cim_done sync 后下游 FSM 在已知稳定窗口内捕获 bl_data
4. **uart_rx_pad 不 sync** — V1 未实现 RX，仅占位 `_unused`，不消费
5. **spi_miso_pad 不 sync** — SPI master 内部 SCK 由 clk 分频生成（spi_ctrl.sv），
   MISO 与 clk 同源，时序确定，不属 CDC
6. **jtag_tck/tms/tdi 不 sync** — `jtag_mem_loader.sv` 内已用 toggle + 2-FF
   `(* async_reg = "TRUE" *)` sync 处理（CLAUDE.md FP-005）

---

## 3. 必须保护的硬约束（红线）

完整内容见 `doc/GPT_audit_prompt_2026_05_03_full_4branch_round1.md` §1。重点：

- frozen tag 不可移动（用 `git rev-parse <tag>^{}` deref 验证，避免 FP-006）
- V1 frozen 参数不可改
- Scheme B 差分不可改回 Scheme A
- byte-mask invariant 不可破
- main vs main-fpga-e203-alpha 必须除 FPGA-specific 外完全一致
- 不可 `--no-verify` / `--no-gpg-sign`
- 所有新 commit 必须 `git commit -s`

---

## 4. 子代理分工（**5 个并行**）

### Agent A：CDC / reset domain 深度审查

任务：
- 逐文件读 reset_sync.sv + sync_2ff.sv，验证 logic 是否 textbook 正确
- 逐文件读 chip_top.sv（4 条支线版本）、v2b_arm_demo_top.sv（arm-conv）、
  snn_soc_v2b_e203_top.sv（e203-conv），验证：
  - reset_sync 实例化的 `clk` 和 `rst_n_async` 输入是否正确（不是接错信号）
  - 下游所有 always_ff 的 `rst_n` 端口是否真的接到 `rst_n_sync`（不是漏改某个）
  - 是否所有"接收外部异步信号"的位置都加了 sync
- 重新对全 RTL 跑一次 async input grep，确认没有漏审的 async 入口：
  ```bash
  cd "<branch worktree>"
  # external pad inputs
  grep -rEn "input.*\b(uart_rx|spi_miso|gpio_in|prog_op|prog_level|adc_data|cim_done|bl_data|bl_sel|jtag_tck|jtag_tms|jtag_tdi)\b" rtl/
  # all rst_n usage
  grep -rEn "negedge rst_n|posedge rst_n" rtl/ | grep -v "rst_n_async"
  ```
- 对每个发现的 async input 给出 verdict：✅ 已 sync / ❌ 漏了需要补 / ⚠ 不需要
  sync（说明原因，例如 jtag_tck 已自己 sync）
- 验证 `async_reg = "TRUE"` 属性语法对 Icarus 不导致 elaboration error

### Agent B：Sim regression 全量 sweep

任务：
- 在 4 条支线上分别跑**全量** sim regression（不只是抽样）：
  ```bash
  cd "<branch worktree>/sim"
  for sh in run_*.sh; do
    echo "=== $sh ==="
    timeout 1800 bash "$sh" 2>&1 | tail -3
  done
  ```
- 列出每条支线的 PASS / FAIL marker 完整表
- 任何 FAIL 都要 root cause（不接受"reset_sync 加了 2 拍延迟所以 timing 紧"作为
  借口——reset_sync 是 forward-correct fix，下游 FW / TB 应该能 handle
  reset 释放晚 2 拍）
- 如果 FAIL 是真的因为 reset_sync 引起，**自己**修（不许说"留给用户"）

### Agent C：TB 覆盖度审查 + 增补

任务：
- 检查 reset_sync_tb.sv / sync_2ff_tb.sv 的 coverage 是否 textbook 完整：
  - reset_sync：是否覆盖 STAGES≠2 的实例化（参数化测试）？
  - sync_2ff：WIDTH=1 + WIDTH=4 已覆盖；是否需要 WIDTH=8/16 极端值测试？
  - 是否覆盖 `clk` glitch + `rst_n_async` 同时 toggle 的 corner case？
  - 是否有 X-prop 测试（reset 释放后下一拍 input=X，输出应该是 X 而不是无意义 0/1）？
- 如果 coverage 不足，**自己**补 TB cases，重跑 PASS
- 检查 `chip_top_rom_smoke_tb.sv` 等顶层 TB 是否需要更新 reset 释放等待
  cycle 数（从原来的 N 加 2）

### Agent D：4 条支线一致性 cross-check

任务：
- 对比 main vs main-fpga-e203-alpha 的 `rtl/sys/`、`rtl/top/chip_top.sv`、
  4 个新 TB/sim 文件，**必须字节级一致**（除 FPGA-specific 文件外）
- 对比 arm-conv vs e203-conv 的 `rtl/sys/`、`tb/reset_sync_tb.sv`、
  `tb/sync_2ff_tb.sv`、`sim/run_reset_sync.sh`、`sim/run_sync_2ff.sh`，应字节级一致
- arm-conv `v2b_arm_demo_top.sv` 和 e203-conv `snn_soc_v2b_e203_top.sv`
  的 reset_sync 实例化模式是否风格一致（参数 / 注释 / 命名）
- 列出每个差异点，分类：✅ 合法（CPU-path-specific）/ ❌ BLOCKER（应一致但漂移）
- 对每个 ❌ 自己修（cherry-pick 或同步 commit）

### Agent E：Doc 更新 + Autonomous board reverify

任务（doc 部分）：
- 更新 `doc/19_training_accuracy_summary.md`（如果在 conv 分支）+
  `doc/v2-architecture/conv_extension_log.md`（如果在 conv 分支）+
  `doc/00_architecture.md`（main + alpha）+ `doc/06_learning_path.md`，
  把 reset_sync + cim_done sync 的存在 + 含义写入文档
- 在 main + alpha 的 `doc/main-fpga-e203/00_architecture.md` 加 reset domain 章节
- 在 conv 分支的 `doc/arm-fpga-demo/00_architecture.md` 或
  `doc/v2-fpga-e203/00_architecture.md` 加 reset domain 章节

任务（board reverify 部分，**仅适用 FPGA 支线**）：

| 分支 | 是否需要重烧 | 理由 |
|---|---|---|
| `main` | ❌ 不需要 | V1 ASIC pre-tape-out，无 FPGA bitstream |
| `main-fpga-e203-alpha` | ✅ **需要** | 加了 reset_sync 改了 chip_top.sv，影响 alpha smoke firmware reset 释放时序 |
| `feature/v2-arm-fpga-demo-conv` | ✅ **需要** | 加了 reset_sync 改了 v2b_arm_demo_top.sv，影响 ARM AXI-Lite reset 释放时序 |
| `feature/v2-fpga-e203-conv` | ✅ **需要** | 加了 reset_sync 改了 snn_soc_v2b_e203_top.sv 顶层，所有下游模块 reset 释放晚 2 拍 |

对每条需要重烧的分支，**autonomous** 完成：
1. cd 到分支 worktree
2. 触发 vivado bitgen（如果分支有 vivado 工程；通常脚本在 `fpga_synth/<board>/`
   或 `scripts/build_<branch>_bitstream.sh`）
3. 拿到 fresh `.bit` + `.elf` / `.hex`
4. xsct / JTAG load 到 ZCU102
5. 抓 UART log（参考已有的 `doc/<branch>/uart_capture_*.txt` 命名模式）
6. 验证 PASS marker（`ARM_FPGA_DEMO_LENET5_PASS` / `FPGA_V2_E203_LENET5_PASS` /
   `FPGA_E203_BOOT_UART_PASS` 等）
7. 把 fresh UART capture + 更新的 `build_manifest_*.txt` 加到 git，
   `git commit -s`，push origin
8. 如果某步失败（比如 vivado 不在你的机器上），**列为 finding**：
   "无法 autonomous reburn，需要用户在 ZCU102 host 机器上跑：<具体命令>"

**重烧后 evidence 文件命名建议**：
```
doc/<branch>/uart_capture_20260503_reset_sync_reverify.txt
doc/<branch>/build_manifest_<feature>.txt（更新 sha256）
```

---

## 5. 输出格式

### 5.1 执行 summary

| 分支 | 改前状态 | 改后状态 | 重烧结论 | 仍需用户介入？ |
|---|---|---|---|---|
| main | reset_sync 已落 | doc 已补 / 全 sim PASS | NO | NO |
| main-fpga-e203-alpha | … | … | YES / 已自动重烧 / fresh UART 已 commit | NO / YES（写明原因） |
| arm-conv | … | … | … | … |
| e203-conv | … | … | … | … |

### 5.2 完整 finding 表

每条：ID / Severity / Branch / File:line / 现象 / 根因 / 修复方式 / 是否已自动修
（YES → 给出 commit hash；NO → 给出阻碍原因）。

### 5.3 Board reverify 详细 log

每条 FPGA 分支：
- bitgen 命令 + 退出码 + 时长
- bitstream SHA256（重烧前 vs 重烧后）
- xsct/JTAG 烧录命令 + 退出码
- UART capture 文件路径 + 关键 PASS marker 行
- commit hash（fresh UART evidence 提交后的）

### 5.4 final closure verdict

明确给出：
- ✅ 4 条支线 reset_sync + CDC sync 完全闭合（0 BLOCKER / 0 HIGH / 0 MEDIUM /
  ≤ 3 LOW，所有 FPGA 支线已 reverify PASS）
- ⚠ 部分闭合（列出哪些子项需要继续）
- ❌ 闭合失败（列出原因）

---

## 6. FP（误报）模式

CLAUDE.md FP-001 ~ FP-005 + round 2 prompt 加的 FP-006（annotated tag wrapper
vs peeled commit SHA 混淆）。新增 round 2.5 候选 FP：

### FP-007（候选，待你审查后决定是否入库）

**误判描述**：报告 reset_sync 引入了某个时序问题，但实际是 TB 没适配
reset 释放晚 2 拍

**识别规则**：报告 reset_sync 引入功能性问题前，先确认：
1. 该问题是否在 reset 释放后立即出现（还是后续 inference 阶段）
2. TB 是否有写死"reset 释放后第 N 拍开始观察 X"的硬假设
3. 如果 TB 假设过紧，应该改 TB 的 wait cycle 数（+2），不是 revert reset_sync

---

## 7. 你不能做的事

- ❌ 不可移动 frozen tag
- ❌ 不可 force-push 已 push 的 commit
- ❌ 不可 rebase 共享分支
- ❌ 不可在没读完 CLAUDE.md + §1.6 + §2.5 的情况下报 bug
- ❌ 不可输出 "全部都很好"——4 条支线刚加新 RTL，几乎不可能 0 finding
- ❌ 不可 `git commit` 不带 `-s`（DCO governance @ main 850c3cae）

---

## 8. 时间预算

- Sub-agent 并行运行：~2-4 小时
- bitgen × 3 分支（如果都需要重烧）：每条 ~1-2 小时，可并行
- xsct + UART capture：每条 ~10-15 分钟
- Synthesize + 写 final report：1 小时
- **总 ETA：4-7 小时**

如果某些步骤 GPT 这台机器做不到（例如 vivado 不在机器上 / ZCU102 不在线），
**列入 finding 给出具体 fallback 命令** 让用户在正确环境跑，不要假装做了。

---

## 9. 用户元目标（理解 audit 严苛度的来源）

用户在准备：
1. 流片 V1（main）— 这是 reset_sync 的核心受益者
2. 投 SCI Q4 论文 — reset_sync 是"我的设计经过 pre-tape-out 严苛 review" 的
   工程严谨度证据
3. 写硕士毕业论文 — reset_sync 是面试官 / 答辩老师爱问的"你考虑过 metastability
   吗" 这一段的硬证据

**Round 2.5 是为 paper handoff 做最后一道质保**——你这一轮如果干净，下一轮
就可以进 final round（清扫 LOW + paper handoff）。

---

## 10. 下一轮 prompt 生成

如果本轮 §5.4 verdict = ✅ 全闭合，下一轮 prompt 应改为 **final round
"paper handoff + LOW sweep + 最终 closure tag 候选"**。

如果 verdict ≠ ✅，本轮**不**生成下一轮 prompt——你应该自己 fix 完，不留尾巴。
唯一例外：board reverify 必须用户在 ZCU102 host 上跑（本机做不到）这一项可以
留给用户，但其他全部应该闭合。

下一轮 prompt 文件名：`doc/GPT_audit_prompt_2026_05_03_full_4branch_round3_final.md`
（如果生成）。

---

## 11. 最后

跑吧。Spawn agents，don't wait。本轮 deliverable 是 **完全闭环的 reset_sync +
CDC fix**，包括 board reverify。不要留尾巴。

---

**END OF ROUND 2.5 PROMPT — copy this whole file into a new GPT-5.4 (effort=xhigh) cold-start chat**
