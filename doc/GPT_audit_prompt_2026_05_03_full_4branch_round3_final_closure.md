# GPT 冷启动 prompt — Round 3 FINAL CLOSURE（接住 round 2 worktree 修改 → verify → commit → 板验 → paper handoff）

> **生成时间**：2026-05-03 round 2 GPT 已完成审查 + 在 worktree 做了 fix-on-sight 但未 commit
> **使用方式**：复制本文件全部内容粘贴给 **GPT-5.4 (effort=xhigh)** 作为冷启动消息。
> 770 KB context budget 不是问题——按本文件**所有**要求执行，不要 cherry-pick 跳过任何一项。
>
> **本轮 supersedes**（前面 3 份 round 2.x prompt 的内容已在本文件吸收）：
> - `doc/GPT_audit_prompt_2026_05_03_full_4branch_round2.md`
> - `doc/GPT_audit_prompt_2026_05_03_full_4branch_round2_5_cdc.md`
> - `doc/GPT_audit_prompt_2026_05_03_full_4branch_round2_5_full_merged.md`
>
> **执行模式**：必须 spawn **至少 7 个并行 sub-agent**。
> **特殊授权**：fix-on-sight + autonomous bitgen / xsct / UART capture + commit/push（带 `-s`）。
>
> **本轮目标**：**一个 GPT 对话内**收口闭环——验证上一轮已做的修改 → commit → push →
> 板验 → final closure verdict。**不留尾巴**给下一轮（除非 vivado / ZCU102 host 真不在
> 你机器上，那一项明确列 fallback 命令给用户）。

---

## 0. 关键背景：本轮是终极收口轮 — 不留任何尾巴

上一个 GPT round 2 已经完成"已知问题"维度审查 + 已经在 4 条 worktree 做了
fix-on-sight，但：
- **所有修改还在 worktree dirty 状态**，没 commit / 没 push
- round 2 finding 表 §1 全是 firmware / doc 类，**没一条 CDC / RTL / Python ↔ RTL
  parity 类**——这强烈暗示 round 2 浅过了 4 个维度

本轮你的核心任务（全部硬要求，**不接受任何"留给下一轮"或"留给用户"的借口**，
除非本机真做不到 vivado/ZCU102 在线那一项明确列 fallback 命令）：

1. **独立验证** round 2 GPT 在 worktree 里做的修改是否真的正确（Agent A/B/C，
   不要盲信 round 2 自报）
2. **补 round 2 漏审的 4 个维度**（Agent I Python parity / Agent J RTL bug
   非 CDC / Agent K Firmware 深度 / Agent L Doc 全套 sweep）
3. **CDC 深度审查**新加的 reset_sync + sync_2ff（Agent H 4 个子任务）
4. **fix-on-sight HARD RULE**：任何 sub-agent 发现真问题（finding 不是 FP）必须
   **立刻**自己修 + commit -s + push origin。**不允许**只报告不修，**不允许**
   "留给下一轮"
5. **commit + push** 全部修改（Agent F）
6. **autonomous board reverify HARD RULE**：alpha + e203-conv 必须重烧 ZCU102；
   任何 Agent J/K trigger 的 RTL/fw 改动落到 FPGA 分支必须**自动追加**到 reverify
   队列；fresh UART capture 必须 commit
7. **闭环 verdict**：要么进 paper handoff（§5.7），要么列出无法本机闭环的 fallback
8. **必须输出下一轮 round 4 prompt**（§11.bis hard gate，无论 verdict 如何）

**13 个 sub-agent 必须全部 spawn，全部完成**（Agent A-H + Agent I-M）。任何
sub-agent 跳过 = 本轮未完成。

---

## 1. Round 2 已知 findings 状态表（**必须逐项验证**）

这是上一个 GPT round 2 自己声称已修但未 commit 的清单。你的 sub-agent 必须**独立读
worktree 的 modified file 内容**确认每一项真的修了。**不要只信 GPT round 2 的报告
原文**——它可能漏改 / 改错 / 改了无关的东西。

| ID | Severity | 分支 | 文件 | 声称修复 | 你必须 verify 的点 |
|---|---|---|---|---|---|
| F001 | HIGH | alpha | `fw/e203_smoke/e203_fpga_smoke.c` | erase/write 失败时不再误报 `FPGA_E203_PROGRAM_ERASE_WRITE_PASS`；按 `PROG_STATUS_FAIL_MASK` gate | 验证 PASS marker 在 erase/write 错误路径上**真的不打印**（grep + 静态分析）。**重 build firmware → 重烧 → 抓新 UART 验证**（必须真上板，因为 PASS marker 语义变了） |
| F002 | MEDIUM | 4 条 | `fw/boot_main.c` + `fw/boot_rom/boot_rom_main.c` | spi_wait_idle / spi_xfer 加 bounded poll timeout + rescue/error banner | 验证 timeout 常量合理（不能太短致误判，不能太长致 hang）；验证 timeout 触发后 banner 的格式不破坏现有 UART log parser |
| F003 | MEDIUM | main + alpha | `fw/silicon_bringup/silicon_bringup.c` line 193/210/233/257 | PROG_CTRL 改成 read-modify-write 保留 RETRY_LIMIT[10:8] | grep `PROG_CTRL = 0x` 应返回 0 行（除了 helper 内部）；4 处全部用 helper 改写 |
| F004 | MEDIUM | e203-conv | `fw/v2_e203_smoke/src/v2_e203_smoke_main.c` line 85 + `fw/src/v2b_scheduler.c` line 153 | 不再 (void) 掉 `v2b_infer_resident_14x14()` 返回值；stage error 时不消费未初始化 counts[10] | 读 main.c：返回码必须真的被检查；error path 必须不打误导性 PASS。**重 build → 重烧 → 抓新 UART** |
| F005 | MEDIUM | conv 两条 | `doc/v2-architecture/conv_extension_log.md` line 106 | CIFAR-10 ~13% plateau 降级为"未保留证据 exploratory note"，或补 ckpt/manifest/log | 读 doc 改后版本：claim 必须不再说"已验证 13% plateau"；如果只是降级措辞 OK，如果声称补了证据则验证 ckpt/manifest 真的存在 |
| F006 | LOW | e203-conv | `fw/src/v2b_scheduler.c` line 113 | 把 ARM 的 `V2B_STAGE_POLL_TIMEOUT` guard 同步过来 | diff e203 vs arm 的 v2b_scheduler.c：这一段必须字节级一致 |
| F007 | LOW | 多分支 | `fw/uart_printf.c` + `fw/v2_e203_smoke/src/uart_printf_v2e203.c` | UART helper 加 bounded wait | 看 timeout 常数 + fault-path 行为 |
| F008 | LOW | conv 两条 | `doc/19_training_accuracy_summary.md` line 19 + `doc/v2-architecture/conv_extension_log.md` line 213 | 补 `v2-fpga-e203-passed` 的 peeled commit `e696dc39...` | 读 doc 改后版本：必须明写 peeled commit hash |
| F009 | LOW | conv 两条 | `doc/v2-architecture/non_linearity_proof.md` line 33 + `conv_extension_log.md` line 214 | 补 `v2-permanent-gate-2026-04-25` 的 peeled commit `3e8905c0...` | 同 F008 |
| F010 | LOW | conv 两条 | 17 个 shared-infra drift（`fw/src/v2b_scheduler.c`, `rtl/top/e203_min_wrap.sv`, `sim/common_iverilog_env.sh`, `rtl/mem/sram_simple.sv` 等）| forward-only cherry-pick / single-file sync | diff arm-conv vs e203-conv 在这 17 个文件上：必须字节级一致；任何残留漂移列为新 finding |
| F011 | LOW | governance | `doc/GPT_closure_report_paper_handoff_2026_05_03.md` line 49/75/81 | 改正对 233db876 的误分类（实际包含 firmware fix + rebuild + UART reverify）| 读 doc 改后版本：narrative 必须诚实承认 firmware 改动 |
| F012 | LOW | alpha | `fw/e203_smoke/build_e203_smoke.sh` | 加 WSL fallback when riscv64-unknown-elf-gcc 缺失 | 验证 fallback 逻辑正确 + 跑 build script 重出 e203_smoke.bin（GPT 声称 SHA-256 前后相同）|

### 1.1 Round 2 GPT 已自跑通的 sim regression（你需要再独立跑一次 sanity）

```
sim/run_boot_erase_e2e.sh             (main)
sim/run_e203_icarus.sh                (main)
sim/run_fpga_programmable_cim_model.sh (alpha)
sim/run_v2b_partial_write_invariant.sh (arm-conv)
sim/run_conv_ctrl_v2_unit.sh           (arm-conv)
sim/run_fw_cosim_resident_14x14.sh     (arm-conv)
fw/arm/build_arm_firmware.sh           (arm-conv)
sim/run_v2_e203_cosim.sh               (e203-conv)
```

---

## 2. 4 条分支 worktree 当前实测状态

### 2.1 origin HEAD（这是 round 2 改之前的状态，未变）

| # | 分支 | origin HEAD | 含义 |
|---|---|---|---|
| 1 | `main` | `da249466` | merged round 2.5 prompt（即将 supersede 本 prompt） |
| 2 | `main-fpga-e203-alpha` | `c9e01889` | 同上（cherry-pick） |
| 3 | `feature/v2-arm-fpga-demo-conv` | `bf56e942` | reset_sync + sync_2ff 落地 commit |
| 4 | `feature/v2-fpga-e203-conv` | `08e5b8f6` | reset_sync + sync_2ff 落地 commit |

### 2.2 各分支 worktree dirty 文件数（round 2 GPT 修改后的状态）

| 分支 | dirty 文件数（已 modified，未 commit）|
|---|---|
| main | 8 个：boot_main.c, boot_rom_main.c, silicon_bringup.c, uart_printf.c, fw/boot_rom/out/{bin,hex}, doc/main-fpga-e203/fw_main_c_*.md, tb/e203_tb.sv |
| alpha | 18 个：含 main 那 8 个 + fw/e203_smoke/{e203_fpga_smoke.c, build_e203_smoke.sh, out/*}, doc/main-fpga-e203/00_architecture.md |
| arm-conv | 20 个：fw/{boot_main.c, uart_printf.c, include/v2b_soc_regs.h}, rtl/{mem/sram_simple.sv, snn/layer_sequencer.sv, snn/spike_feedback.sv, top/e203_min_wrap.sv}, sim/{common_iverilog_env.sh, run_e203_icarus.sh, run_jtag_rescue_top_icarus.sh, sim_fw_cosim_resident_14x14.f, sim_v2b_partial_write_invariant.f}, doc/{06, 19, arm-fpga-demo/{00, board_bringup_log_lenet5.txt, build_manifest_v2.txt}, v2-architecture/{conv_extension_log.md, non_linearity_proof.md}} + .gitignore |
| e203-conv | 16 个：fw/{boot_main.c, uart_printf.c, src/v2b_scheduler.c, v2_e203_smoke/src/{v2_e203_smoke_main.c, uart_printf_v2e203.c}}, rtl/dma/dma_engine.sv, tb/v2_e203_cosim_tb.sv, doc/{06, 19, 19_phase_d, v2-architecture/{conv_extension_log.md, non_linearity_proof.md}, v2-fpga-e203/{00, board_bringup_log_lenet5.txt, build_manifest_lenet5.txt}} + .gitignore |

⚠ **arm-conv 有 RTL 改动**（sram_simple.sv / layer_sequencer.sv / spike_feedback.sv /
e203_min_wrap.sv）—— 按 F010 这是 shared-infra drift sync from main，但**你必须验证**
这些 RTL 改动确实是 forward-only 一致性同步、**不**引入功能行为变化。

⚠ **e203-conv 有 `rtl/dma/dma_engine.sv` 改动**——本轮 round 2 finding 没列这个，
GPT 自己加进去的，**必须独立审查**这个改动是 shared-infra sync 还是漏审 finding。

⚠ **main 有 `tb/e203_tb.sv` 改动**——按 round 1 GPT report 提到的"VCD dump opt-in"，
但 round 1 closure commit 没包含这个改动；现在 worktree 又出现了，需要确认是否
是同一个改动，还是 round 2 GPT 又改了一次。

---

## 3. 必须保护的硬约束（红线）

### 3.1 frozen tags 永不可移动

```
v2-fpga-e203-passed                        peeled @ e696dc39 (per F008 doc fix)
v2-arm-fpga-demo-v2-passed                 peeled @ ?? (deref 自查)
v2-permanent-gate-2026-04-25               peeled @ 3e8905c0 (per F009 doc fix)
v2-arm-fpga-demo-conv-passed               peeled @ dabcaf0d
v2-fpga-e203-conv-passed                   peeled @ a1c0c828
```

任何对这些 tag 的移动 / 删除 / 重命名都是 BLOCKER。**永远**用 `git rev-parse <tag>^{}`
deref 后再比对（FP-006 防呆）。

### 3.2 V1 frozen 参数不可改

- `NUM_INPUTS = 64` / `ADC_BITS = 8` / `ADC_CHANNELS = 20` / `TIMESTEPS = 10`
- `THRESHOLD_RATIO = 1` → `THRESHOLD_DEFAULT = 2550`
- `NEURON_DATA_WIDTH = 9` (signed)
- `MAC_W_LOAD_*` offsets = `0x050 / 0x054 / 0x058`

### 3.3 Scheme B 差分不可改回 Scheme A

### 3.4 byte-mask invariant 永久门禁

```bash
git diff <baseline>..HEAD -- rtl/top/v2b_axi_wrapper.sv rtl/top/snn_soc_v2b_top.sv \
    | grep "<= req_wdata"
# 必须 0 行
```

### 3.5 main vs main-fpga-e203-alpha 一致性

除 FPGA-specific 外字节级一致。本轮 round 2 GPT 把同样的 fw 修改在两边都做了，
但**你必须 diff 验证**两边修改后的 fw 内容确实字节级一致（GPT 可能漏改一边）。

### 3.6 reset_sync / sync_2ff 实例化不可丢失

- chip_top.sv（4 条）必须有 reset_sync + sync_2ff 实例化
- v2b_arm_demo_top.sv（arm-conv）必须有 reset_sync
- snn_soc_v2b_e203_top.sv（e203-conv）必须有 reset_sync + 下游 8 个子模块 `.rst_n(rst_n_sync)`

### 3.7 commit 必须 `-s`

DCO governance from main `850c3cae`. Any new commit lacking `Signed-off-by:` is BLOCKER.

### 3.8 不可 force-push / 不可 rebase 已 push commit / 不可移 frozen tag

---

## 4. 子代理分工（**必须 spawn 13 个并行 sub-agent**）

> **本轮特别提示**：round 2 GPT 报告的 12 个 finding 全是 firmware / doc /
> shared-infra issues，**没一条 CDC 或 reset_sync 类，没一条 RTL 类，没一条 Python
> ↔ RTL parity 类，没一条 TB coverage 类**。这强烈暗示 round 2 浅过了多个维度。
> 本轮 13 个 sub-agent 是为了把所有可能的死角全打掉，绝对不留尾巴：
> - Agent A-G + H：接 round 2 尾巴 + CDC 深度 + 板验
> - Agent I-M（**本轮新增**）：补 round 2 没专门做的 5 个维度
>   - Agent I：Python ↔ RTL parity + manifest SHA
>   - Agent J：RTL bug hunt 非 CDC 维度（FP-001~FP-005 类）
>   - Agent K：Firmware 深度 audit 非 round-2-finding 项
>   - Agent L：Doc cross-consistency 全套 sweep
>   - Agent M：TB coverage 全栈审查 + Reproducibility 验证
>
> **fix-on-sight + autonomous board reverify 是本轮硬要求**：任何 sub-agent 发现
> 真问题（finding 不是 FP）必须**立刻**自己修 + commit -s + push origin；任何
> firmware/RTL 改动落到 alpha / arm-conv / e203-conv 上后**必须**触发对应分支的
> board reverify（vivado bitgen + xsct + UART capture + commit fresh evidence）。
> **不接受**"留给下一轮""留给用户"——除非本机真做不到（vivado/ZCU102 不在线），
> 那一项明确列 fallback 命令。

### Agent A：Verify F001/F002/F003/F004（HIGH + 关键 MEDIUM 修复正确性）

任务：
- 对每个 finding 独立读 worktree 的 modified file 内容
- 静态分析（grep / 上下文阅读）确认修复真的实现了 finding 描述的语义
- 跑对应单元 sim（已知 PASS 列表见 §1.1）确认 functional 不破
- **特别重点 F001**：对 `e203_fpga_smoke.c` 跑 erase/write 错误路径 mock testing
  （strict 静态分析 + 如果有对应 TB 跑通过）
- **特别重点 F003**：grep `PROG_CTRL = 0x` 必须 0 残留
- **特别重点 F004**：在 v2_e203_smoke_main.c 里找 `(void)` 残留 + verify
  v2b_scheduler.c 返回码处理逻辑
- 任何 finding 修复**未真正实现** / **实现不完整** / **引入新 bug** → 自己修 +
  commit -s + push

**输出**：`agent_a_verify_high_medium.md` + 新 commit hash 列表（如果发现需要补救）。

### Agent B：Verify F005-F012（其余 LOW + doc + DCO）

任务：
- 对 F005 (CIFAR plateau)：读 doc 改后版本验证 narrative 降级到位
- 对 F006/F007：diff e203 vs arm 的 v2b_scheduler.c 和 uart_printf*.c，
  字节级一致
- 对 F008/F009：grep doc 必须有 peeled commit hash
- 对 F010：diff arm-conv vs e203-conv 的 17 个 shared-infra 文件，必须字节级一致
- 对 F011：读 closure report 改后版本，narrative 必须诚实承认 233db876 的
  firmware 改动
- 对 F012：跑 alpha 的 `fw/e203_smoke/build_e203_smoke.sh` 验证 WSL fallback 工作；
  对比新生成的 e203_smoke.bin 与 worktree 已存的 SHA-256 必须相同
- 任何漏修 / 修错 → 自己补 + commit + push

**输出**：`agent_b_verify_low_doc.md` + 新 commit hash（如有）。

### Agent C：审查 round 2 GPT 加进去但 finding 表没列的 worktree 改动

任务：
- arm-conv worktree 的 RTL 改动（`rtl/mem/sram_simple.sv`,
  `rtl/snn/layer_sequencer.sv`, `rtl/snn/spike_feedback.sv`,
  `rtl/top/e203_min_wrap.sv`）：
  - 是否真的是 main → arm-conv 的 forward-only sync？
  - diff 这些文件的 main vs arm-conv worktree 改后版本：必须字节级一致
  - 是否引入功能行为变化？（不应该有 — sync 只是把 arm-conv 拉齐到 main）
- e203-conv worktree 的 `rtl/dma/dma_engine.sv` 改动：
  - 这个不在 round 2 finding 列表里，GPT 自己改了
  - 验证是否 main → e203-conv shared-infra sync？还是漏审 finding？
  - 如果是 sync，diff 验证；如果是 GPT 自己发现的新 bug，要求 GPT 补 finding 描述
- main worktree 的 `tb/e203_tb.sv` 改动：
  - 是否就是 round 1 closure report 提的"VCD dump opt-in"？
  - diff old vs new 验证改动语义
- main worktree 的 `fw/boot_rom/out/{boot_rom.bin, boot_rom.hex}` 改动：
  - boot_rom_main.c 改了所以 binary 重 build 是预期的
  - **必须**重跑 build script 确认 SHA 可复现

**输出**：`agent_c_unlisted_changes.md` + 任何新 finding（如发现真问题）。

### Agent D：完整 sim regression 全量 sweep + cross-branch consistency

任务：
- 在 4 条支线上分别跑**所有** `sim/run_*.sh`（不只 §1.1 那 8 个）：
  ```bash
  cd "<branch worktree>/sim"
  for sh in run_*.sh; do
      echo "=== $sh ==="
      timeout 1800 bash "$sh" 2>&1 | tail -3
  done
  ```
- 列每条支线完整 PASS / FAIL marker 表
- 任何 FAIL → root cause → 自己修（fix-on-sight）→ 重跑 PASS → commit + push
- **特别注意**：
  - reset_sync 加了 2 拍 reset 释放，TB hardcoded wait cycle 数应该 +2，
    不是 revert reset_sync（FP-007）
  - sample 输出 byte-exact 一致但 cycle 数差 2 是预期，不是 bug（FP-008）
- main vs main-fpga-e203-alpha：
  - 在每个 sub-agent fix 完成 commit 之后，跑 `git diff` 对比两边 fw/ 修改后内容
  - 必须字节级一致（除 FPGA-specific 范围）
  - 任何漂移 → 自己同步 → commit -s → push

**输出**：`agent_d_sim_consistency.md` + sim 全表 + 新 commit hash（如有）。

### Agent E：Frozen tag 严格 deref 验证 + DCO compliance

任务：
- 5 个 frozen tag 用 `git rev-parse <tag>^{}` deref，对照 doc 引用的 commit hash
- 对照 round 2 finding 表 §1（peeled commit hash）：
  - `v2-fpga-e203-passed` peeled @ `e696dc39...`
  - `v2-permanent-gate-2026-04-25` peeled @ `3e8905c0...`
  - `v2-arm-fpga-demo-conv-passed` peeled @ `dabcaf0d`
  - `v2-fpga-e203-conv-passed` peeled @ `a1c0c828`
  - `v2-arm-fpga-demo-v2-passed` peeled @ ??（你 deref 得到什么就是什么）
- 任何 doc / round 2 GPT 报告里写的 hash 与实际 deref 结果不一致 → finding
- DCO compliance（仅检查本轮 + round 2 新增 commit，不审 frozen-history debt）：
  ```bash
  git log --since=2026-05-03T00:00:00 --pretty="%H %s" | while read hash subject; do
      git log -1 --pretty="%b" $hash | grep -q "Signed-off-by:" \
          || echo "$hash MISSING DCO: $subject"
  done
  ```

**输出**：`agent_e_tag_dco.md` + 任何漂移 finding。

### Agent F：所有 worktree 修改 commit + push（**autonomous**）

任务：
- 等 Agent A-E 全部完成 verify 后，开始 commit
- 对每条分支：
  - `git status` 列所有 dirty 文件
  - 按主题分组（fw fixes / doc fixes / RTL sync / TB sync）做 1-3 个清晰 commit
  - 每个 commit message 必须：
    - 引用 finding ID（F001 / F002 / ...）
    - 说明改了什么 + 为什么
    - 列出 sim regression PASS marker
    - 带 `Signed-off-by:` (`-s`)
  - `git push origin <branch>`
- 4 条支线全部 push 后 sanity check：
  ```bash
  for path in <all 4 worktrees>; do
      git -C "$path" status --short  # 必须 0 dirty
      git -C "$path" log origin/<branch>..HEAD  # 必须 0 unpushed
  done
  ```
- 如果 push 失败（network / auth / non-fast-forward），列为 finding 给用户，
  **不要假装 push 成功**

**输出**：`agent_f_commits.md` + 4 条分支的 commit hash 列表 + push log 摘要。

### Agent H：CDC / reset domain 深度审查（**新代码重点 + 全 RTL sweep**）

> ⚠ 本 sub-agent 专门补 round 2 浅过的 CDC 审查。round 2 finding 表 §1 没有 CDC
> 类项目，但**这不等于 CDC 没问题**——可能 round 2 没系统看。本轮必须独立深审。

任务分 4 块：

**任务 H.1：审查 2026-05-03 新加的 RTL 模块源码 textbook 正确性**

- 读 `rtl/sys/reset_sync.sv`（4 条支线必须字节级一致；先 diff 验证）：
  - async-assert / sync-release 实现是否符合 textbook 教科书写法（`always_ff @(posedge
    clk or negedge rst_n_async)`，async branch 清 chain，sync branch walk a 1 in）
  - `(* async_reg = "TRUE" *)` 属性放置位置是否在 chain flop 上
  - STAGES 参数边界：STAGES=1 是否安全？STAGES=3 是否多余？默认 2 是否合理？
  - `rst_n_sync = sync_chain[STAGES-1]` 索引是否正确
- 读 `rtl/sys/sync_2ff.sv`：
  - 参数 WIDTH 实现是否正确（`logic [WIDTH-1:0] sync_ff1, sync_ff2`）
  - 是否有头注释**禁止**用 sync_2ff 处理多 bit 数据总线（cycle skew 风险）
  - `rst_n_sync` 的 reset 处理是否正确
- 读 `tb/reset_sync_tb.sv` + `tb/sync_2ff_tb.sv`：
  - 是否覆盖 STAGES≠2 / WIDTH=8/16 极端值？
  - 是否覆盖 X-prop（reset 释放后下一拍 input=X）？
  - 是否覆盖 clk glitch + rst_n_async 同时 toggle 的 corner case？
  - **如果 coverage 不足，自己补 cases，重跑 PASS**

**任务 H.2：审查 chip_top / v2b_arm_demo_top / snn_soc_v2b_e203_top 接线正确性**

- 4 条支线的 `chip_top.sv` 都必须有 `reset_sync` + `sync_2ff` 实例化
- arm-conv 的 `v2b_arm_demo_top.sv` 必须有 `reset_sync`
- e203-conv 的 `snn_soc_v2b_e203_top.sv` 必须有 `reset_sync`
- 接线 verify：
  - `reset_sync` 输入 `clk` / `rst_n_async` 正确（不接错信号）
  - `reset_sync` 输出 `rst_n_sync` 真的下游全消费
  - `sync_2ff` 输入 `rst_n_sync` 是 reset_sync 的输出（不是 raw rst_n_pad）
- **特别 grep**：
  ```bash
  # 任何残留的 .rst_n(rst_n) 或 .rst_n(rst_n_pad) 都是漏改
  grep -nE "\.rst_n\((rst_n|rst_n_pad|rst_n_async)\)" rtl/top/chip_top.sv \
      rtl/top/v2b_arm_demo_top.sv rtl/top/snn_soc_v2b_e203_top.sv 2>/dev/null
  # 应该 0 行残留（所有连接都该是 .rst_n(rst_n_sync)）
  ```
- e203-conv 子模块特别多，逐个 verify：e203_min_wrap / icb2simple_bridge_v2b /
  bus_interconnect_v2_e203 / sram_simple × N / uart_ctrl / simple2v2btop_adapter /
  snn_soc_v2b_top 的 `.rst_n()` 端口必须 100% 接 `rst_n_sync`

**任务 H.2bis：4 条支线 reset_sync / sync_2ff 接线一致性 cross-branch diff**

> 这是独立 verify 项：上面 H.2 是"单分支接线对"；这里是"4 条之间一致性"。

```bash
# 共用文件（4 条字节级一致）
for f in rtl/sys/reset_sync.sv rtl/sys/sync_2ff.sv \
         tb/reset_sync_tb.sv tb/sync_2ff_tb.sv \
         sim/run_reset_sync.sh sim/run_sync_2ff.sh \
         sim/sim_reset_sync.f sim/sim_sync_2ff.f; do
    echo "=== $f ==="
    sha=$(git -C "<main worktree>" hash-object "$f")
    for b in "<alpha>" "<arm-conv>" "<e203-conv>"; do
        sha2=$(git -C "$b" hash-object "$f")
        [ "$sha" = "$sha2" ] && echo "  $b: OK" || echo "  $b: DRIFT (sha2=$sha2)"
    done
done

# chip_top.sv 的 reset_sync + sync_2ff 实例化段（4 条字节级一致）
# 提取 "── Async / CDC synchronizers" 注释开始到 "snn_soc_top #(" 之前的段
for b in main alpha arm-conv e203-conv; do
    echo "=== $b ==="
    sed -n '/── Async \/ CDC synchronizers/,/snn_soc_top #(/p' \
        "<$b worktree>/rtl/top/chip_top.sv" | sha256sum
done
# 4 条 sha256 必须完全一致

# v2b_arm_demo_top.sv（仅 arm-conv 有）— 验证 reset_sync 实例化段
sed -n '/── Async-assert/,/v2b_axi_wrapper #(/p' \
    "<arm-conv>/rtl/top/v2b_arm_demo_top.sv" | wc -l
# > 0 行说明实例化段存在

# snn_soc_v2b_e203_top.sv（仅 e203-conv 有）— 验证 reset_sync 实例化段
sed -n '/Async-assert.*sync-release reset/,/E203 core wrap/p' \
    "<e203-conv>/rtl/top/snn_soc_v2b_e203_top.sv" | wc -l
# > 0 行说明实例化段存在
```

任何 4 条支线之间的 byte-level drift（共用文件不该 drift）→ 自己同步 →
commit -s → push（如果本轮 Agent F 还没开 commit，把同步 fix 加入 Agent F 的
commit 队列）

**任务 H.3：全 RTL async input sweep（确认还有没有漏审的 async 入口）**

```bash
cd "<branch worktree>"

# 找所有外部异步输入 pad（来自模拟侧 / 板级 / 上电 reset）
grep -rEn "input.*\b(uart_rx|spi_miso|gpio_in|prog_op|prog_level|adc_data|cim_done|bl_data|bl_sel|jtag_tck|jtag_tms|jtag_tdi|gpio_int|interrupt_in|button|switch|cim_done_pad)\b" rtl/

# 找所有 async assert reset 但下游 always_ff 是否仍直接消费 raw rst_n_pad
grep -rEn "negedge rst_n|posedge rst_n" rtl/ | grep -v "rst_n_async\|rst_n_sync"

# 找多 clock 域（CLAUDE.md FP-005 已确认 V1 单时钟，但 V2 conv 可能有变化）
grep -rEn "input.*\b(clk[0-9]|sys_clk|periph_clk|mem_clk|ddr_clk|tck)\b" rtl/

# 找 clock divider / generator
grep -rEn "always.*posedge clk.*sck|sck_int|clk_div" rtl/
```

对每个发现的 async input：✅ 已 sync / ❌ 漏了（**自己补 sync_2ff**） /
⚠ 不需要 sync（说明原因，例如 jtag_tck 已自己 sync via `(* async_reg = "TRUE" *)`，
spi_miso 单 clk 域因为 SCK = clk/N 等）

**任务 H.4：reset_sync 加 2 拍释放对下游 TB / FW 的影响 sanity**

- 找所有 hardcoded "reset 释放后第 N 拍开始观察 X" 的 TB 假设：
  ```bash
  grep -rEn "after.*reset|repeat\([0-9]+\).*posedge clk.*//.*reset" tb/ sim/
  ```
- 任何 TB 在 reset 释放后**前 5 个 cycle 内**做时序敏感 check 的，验证是否需要 +2
- FW 类似：bringup / boot / smoke firmware 在 reset 后立刻读 status reg 的，
  验证是否需要等 sync release 完成
- **特别**：FP-007 / FP-008 必须主动对照 — 任何 reset_sync 引入的 regression 候选
  必须先排除这两个 FP，**不要 revert reset_sync**，应该改 TB / FW

**输出**：`agent_h_cdc_findings.md`，包含：
- 4 块任务每块的 verdict（✅ PASS / ⚠ PASS with caveat / ❌ FAIL with finding）
- 任何新发现的 CDC bug → 自己修 + commit -s + push
- 任何 TB coverage 增补 → 加新 case + 重跑 PASS + commit
- FP-007 / FP-008 排除验证日志

---

### Agent I：Python ↔ RTL parity + Manifest SHA verification（**round 2 没做**）

> ⚠ round 2 finding 表 §1 没有任何 Python ↔ RTL parity 类项目——意味着本维度
> 可能完全没审。论文 evidence chain 的核心就是"manifest 数字 = doc 数字 = 实际
> 文件 SHA = cosim PASS marker"，本 sub-agent 必须独立 verify。

任务：

**I.1 Manifest 内部数字一致性**

对每个 manifest（4 条 conv 分支共 ~10 个）：
```bash
ls python_multilayer/results_conv/lenet5*/lenet5_golden_manifest.json
```
读取每个 manifest，验证：
- `quant_snn_test_accuracy` / `selected_accuracy` / `t_count` / `samples` 字段存在
- `samples[N].output_counts` 引用的相对路径文件真实存在
- 每个 sample 的 `prediction` 与 `expected_prediction` 字段（如有）一致

**I.2 Manifest ↔ doc 数字一致性**

读 `doc/19_training_accuracy_summary.md` + `doc/v2-architecture/conv_extension_log.md`
里的精度表格。每一个引用到 manifest 的数字（quant_snn_test_acc / selected_acc /
SHA256）必须**字节级匹配** manifest。

不一致 → 自己修 doc 或 manifest（看哪个是 ground truth）→ commit -s → push

**I.3 Cosim PASS marker + SHA 自洽**

对每个有 cosim_*_log.txt 的 bundle：
```bash
grep "LENET5_COSIM_TB_PASS" python_multilayer/results_conv/lenet5*/cosim_*_log.txt
grep "lenet5_golden_counts_concat=" python_multilayer/results_conv/lenet5*/cosim_*_log.txt
grep "lenet5_rtl_counts_dump=" python_multilayer/results_conv/lenet5*/cosim_*_log.txt
```
- 每个 bundle 的 cosim PASS marker 必须存在
- `golden_counts_concat` SHA 必须 == `rtl_counts_dump` SHA（byte-exact match 证据）
- 这两个 SHA 必须与 doc 引用值一致

**I.4 Topologies.yaml ↔ summary.txt ↔ doc 一致性**

```bash
ls python_multilayer/results_multilayer/*/summary.txt
```
对每个 summary.txt（FC SNN 的 ablation 数据），验证：
- summary.txt 里的 `test_accuracy` / `final_epoch_acc` / `seed` / `epochs` 与
  doc/19 表里数字一致
- summary.txt 引用的 topology name 在 `python_multilayer/topologies.yaml` 里存在
- topology 字段（threshold / sum_max / stream_timesteps / adc_bits / dataset）
  与 summary.txt 自报字段一致

**I.5 独立 SHA256 重算（不只信 manifest 自报）**

```bash
# 抽 2-3 个 bundle 重算 sample_NN_output_counts.txt 的 SHA256
sha256sum python_multilayer/results_conv/lenet5_fashion/sample_*_output_counts.txt | sha256sum
# 对比 manifest 里 records 的总 SHA
```
- 任何独立重算结果与 manifest / doc 不一致 → 自己修 → commit → push

**输出**：`agent_i_python_rtl_parity.md` + finding + 修复 commit hash 列表。

---

### Agent J：RTL bug hunt 非 CDC 维度（**round 2 没专门做 — FP-001~FP-005 类**）

> ⚠ round 2 finding 表 §1 没有任何 RTL bug 类项目——意味着 RTL 非 CDC 维度
> 没专门审。流片在即（V1 main），任何 FP-001 ~ FP-005 类残留 bug 都是 tape-out
> 风险。本 sub-agent **必须**做完整的 RTL bug hunt。

任务：

**J.1 全 RTL signed/unsigned 链审查（FP-001 类）**

```bash
# 找所有 $signed() / <<< / >>> 出现的地方
grep -rEn "\\\$signed|<<<|>>>" rtl/
```
对每个出现：读完整赋值链 + 对照 SV LRM §6.24.1 + 验证位宽匹配。重点：
- `lif_neurons.sv`（已有 FP-001 案例，验证 fix 还在）
- `cim_macro_blackbox.sv`（Scheme B 差分计算）
- `tile_partial_buf.sv`（V2.B partial sum 累加）
- 任何 V2.B CONV path 涉及负数累加的位置

**J.2 全 RTL 位宽审查（FP-002 类）**

```bash
# 找所有 logic [N:0] 声明
grep -rnE "logic\s+\[\d+:0\]" rtl/ | head -50
# 找位宽截断 / 拼接
grep -rnE "\{.*,.*\}|\\[\\d+:\\d+\\]" rtl/ | head -50
```
对每个 reg / wire 验证：
- 位宽与 `snn_soc_pkg.sv` 里的 parameter 派生一致
- 任何 `data_width = $clog2(N)` 类用法验证 N 与 width 匹配
- output FIFO width = $clog2(NUM_OUTPUTS) — 验证 NUM_OUTPUTS=10 → width=4 OK

**J.3 全 RTL FSM 审查（阻塞 vs 非阻塞 — FP-003 类）**

```bash
# 找所有 always_ff 块里的 FSM
grep -rnE "always_ff" rtl/ | head -30
```
对每个 FSM：
- state encoding 是否 onehot / binary / gray
- illegal state handling 是否有 default + reset 到 IDLE
- 阻塞赋值 `=` 出现在 always_ff 里 → 必须解释为什么（一般是错的）
- 地址 `+/-` 类 timing 是否正确（参考 dma_engine FP-003 案例）

**J.4 边界条件审查（FP-004 类）**

对所有"零长度 / 极小输入 / 极大输入"路径：
- DMA: zero-length transfer（FP-004 案例验证 fix 还在）
- CIM: bl_sel = NUM_OUTPUTS-1 → MUX boundary
- LIF: threshold = 0 / threshold = MAX
- stage_engine: tile_count = 1 / tile_count = 9
- input fmap 全 0 / 全 1

**J.5 假 CDC 报告排除（FP-005 类）**

如果你在审查中**发现疑似 CDC 问题**（例如 fifo_sync 跨域）—— 必须先确认：
- 该模块真的有多个时钟域？还是单时钟（FP-005）
- 任何 "name 含 sync" 的模块默认是单时钟
- 跨时钟域只在 jtag_tck path 真存在（已有 sync）

**J.6 SVA 完整性 + 保护**

- 所有 SVA assertion 必须在 `ifdef VCS` / `ifndef SYNTHESIS` 保护下
- Icarus 跑 sim 时必须能 elaborate 通过（SVA 跳过）
- VCS 跑 sim 时必须 0 assertion failure

**所有 J.1-J.6 finding 必须遵循 CLAUDE.md "RTL 漏洞报告规范"**：
```
【缺陷描述】
【触发条件】
【仿真激励】
【预期异常现象】
```
**写不出可触发激励的 bug 必须标"疑似误报"，不计入修复列表**（防止 FP-001~FP-005
重复发生）。

发现真 bug → 自己修 → commit -s → push → 触发对应分支板验（如 RTL 改动落到
FPGA 分支）

**输出**：`agent_j_rtl_bugs.md` + finding + 修复 commit hash + 任何触发的板验
trigger 标记（给 Agent G）。

---

### Agent K：Firmware 深度 audit（非 round-2-finding 项）

> ⚠ round 2 finding 表 §1 集中在 fw（F001 alpha smoke / F002 boot / F003
> silicon_bringup / F004 e203 scheduler / F006 timeout drift / F007 uart）
> ——但 round 2 是按"已知问题列表"修，本 sub-agent 必须做**穷举式**深审。

任务：

**K.1 PROG_CTRL 写法穷举**

```bash
# round 2 已修部分；本轮验证 0 残留
grep -rn "PROG_CTRL = 0x" fw/
grep -rn "PROG_CTRL =" fw/ | grep -v "preserve_retry\|prog_ctrl_start_preserve_retry"
```
任何残留 → 改用 helper → commit → push → trigger 对应分支板验

**K.2 W1P / W1C 寄存器读写模式穷举**

```bash
# 找所有 W1P 寄存器写入（CTRL 类）
grep -rnE "(CTRL|CMD)\s*=\s*0" fw/
# 必须每次写都 wait DONE 才继续；找无 wait 的写
```
逐个验证 W1P 写后是否有对应 wait_done() 或 status poll。

**K.3 busy-loop timeout 穷举**

```bash
# round 2 修了 boot SPI/UART; 本轮找还有没有其他 busy-loop 没 timeout
grep -rnE "while\s*\([^)]*BUSY|while\s*\([^)]*VALID|while\s*\([^)]*RDY" fw/
```
每个 busy-loop 必须有 bounded poll + timeout banner。

**K.4 UART helper 全栈审查**

- main: `fw/uart_printf.c`
- alpha: `fw/uart_printf.c`（应与 main 字节级一致）
- arm-conv: `fw/uart_printf.c` + `fw/arm/uart_ps.c`
- e203-conv: `fw/uart_printf.c` + `fw/v2_e203_smoke/src/uart_printf_v2e203.c`

逐个验证：
- string buffer overflow 风险（snprintf vs strcat / sprintf）
- 字符串边界处理
- printf-format-string injection 风险（如果有用户输入）

**K.5 boot rom / crt0 sanity**

- `fw/boot_rom/boot_rom_main.c` + `fw/boot_rom/out/boot_rom.{bin,hex}`
- `fw/boot_main.c`
- crt0 / startup code（如果有）
- 验证：reset vector / bss clear / stack init / cpu_local_rst_n 释放顺序

**K.6 ARM firmware（fw/arm/）专项**

round 2 fw audit 集中在 E203 / smoke 路径，ARM firmware 可能漏审：
- `fw/arm/src/v2b_scheduler.c`
- `fw/arm/src/v2b_inference.c`
- `fw/arm/build_arm_firmware.sh`
- 验证 ARM 路径有相同等级的 timeout / error handling 严谨度

**所有 K.1-K.6 finding 必须遵循 CLAUDE.md "RTL 漏洞报告规范"**（fw 类同样需要
可触发激励 — 一般是 unit test / 静态分析）。

发现真 bug → 自己修 → 重 build → commit -s → push → trigger 对应分支板验

**输出**：`agent_k_fw_deep.md` + finding + 修复 + 重 build artifact SHA256 +
触发的板验 trigger 标记。

---

### Agent L：Doc cross-consistency 全套 sweep

> ⚠ round 2 finding 表 §1 doc 类只到 F005/F008/F009/F011（4 个点），但项目
> 共有 ~30+ doc 文件，本 sub-agent 必须做**全套** doc 一致性 sweep。

任务：

**L.1 跨 doc 互相引用一致性**

每个 doc 里"详见 docXX §Y" 类引用：
- 引用的 doc 必须存在
- 引用的 § 必须存在
- 引用的内容必须仍然描述对应主题（不是 stale）

```bash
grep -rnE "详见|参考|see|cf\\.|参见" doc/ | head -50
```

**L.2 commit hash 引用一致性**

每个 doc 里 quote 的 commit hash（包括 frozen tag peeled commit）：
- `git cat-file -e <hash>` 必须存在
- 如果是 tag peeled commit，必须用 `git rev-parse <tag>^{}` 一致

**L.3 文件路径引用一致性**

每个 doc 里 quote 的文件路径：
- `ls <path>` 必须存在
- 如果是 evidence 文件（UART capture / manifest / SHA），必须真实存在

**L.4 数字引用一致性**

每个 doc 里 quote 的精度数字 / cycle 数 / SHA256：
- 与 source-of-truth 文件（manifest / summary.txt / cosim_log）字节级一致
- 与其他 doc 里 cross-quote 的同一数字一致

**L.5 main vs alpha doc 一致性**

```bash
for d in doc/*.md doc/v2-architecture/*.md; do
    diff <(git -C "<main>" show HEAD:"$d" 2>/dev/null) \
         <(git -C "<alpha>" show HEAD:"$d" 2>/dev/null) > /dev/null || echo "$d DRIFT"
done
```
任何漂移（除 doc/main-fpga-e203/ 路径外）→ 自己同步 → commit → push

**L.6 arm-conv vs e203-conv doc 一致性**

```bash
for d in doc/19_training_accuracy_summary.md doc/06_learning_path.md \
         doc/v2-architecture/conv_extension_log.md doc/v2-architecture/non_linearity_proof.md; do
    diff <(git -C "<arm-conv>" show HEAD:"$d" 2>/dev/null) \
         <(git -C "<e203-conv>" show HEAD:"$d" 2>/dev/null) > /dev/null || echo "$d DRIFT"
done
```
共享 doc 必须字节级一致。

**L.7 CLAUDE.md ↔ 实际状态一致性**

CLAUDE.md 里的所有"项目核心参数"表格 / "寄存器地址表" / "误报经验知识库"
等内容必须与实际代码 / RTL / fw 一致。

发现 doc 漂移 → 自己修（决定 doc 还是源是 ground truth）→ commit -s → push

**输出**：`agent_l_doc_sweep.md` + 所有 doc 一致性 verdict + 修复 commit hash。

---

### Agent M：TB coverage 全栈审查 + Reproducibility 验证

> ⚠ round 2 sim sweep 全 PASS 不代表 TB 覆盖度足够 — 只代表"现有 TB 写的 case
> 全 PASS"。本 sub-agent 补审 TB **本身**够不够 + 项目能否在 clean checkout
> 上 reproducibility build。

任务：

**M.1 关键 TB coverage 审查**

对每条分支的关键 TB（不只 reset_sync_tb / sync_2ff_tb）逐个审查：
- 每个 TB 的 case 列表（grep `task automatic check` / `if` / `assert` 数量估算）
- 每个 TB 是否覆盖：normal path / boundary / error path / random stress
- 重点 TB（必审）：
  - main: `tb/top_tb.sv`, `tb/top_tb_adc_sat_counter.sv`,
    `tb/cim_program_ctrl_tb.sv`, `tb/dma_engine_tb.sv`, `tb/lif_neurons_tb.sv`,
    `tb/e203_tb.sv`
  - arm-conv: `tb/conv_ctrl_v2_tb.sv`, `tb/v2b_partial_write_invariant_tb.sv`,
    `tb/fw_cosim_resident_14x14_tb.sv`
  - e203-conv: `tb/v2_e203_cosim_tb.sv`, `tb/icb2simple_bridge_v2b_tb.sv`,
    `tb/simple2v2btop_adapter_tb.sv`
- 任何关键路径 TB **case 数过少 / 仅 happy path / 无 error path** → 列为
  finding "TB coverage gap @ <file>"
- **不强制要求自己补 TB**（那是大工程），但必须列出"应补但未补"的 case 清单
  给下一轮 / 用户决定

**M.2 Reproducibility — clean checkout 试 build**

```bash
# 模拟 clean checkout
cd /tmp
rm -rf snn-soc-clean
git clone <origin url> snn-soc-clean
cd snn-soc-clean

# 试 build 主要 firmware
git checkout main
bash fw/boot_rom/build_boot_rom.sh           # main boot rom
bash fw/silicon_bringup/build_silicon_bringup.sh  # main silicon bringup

git checkout main-fpga-e203-alpha
bash fw/e203_smoke/build_e203_smoke.sh       # alpha e203 smoke

git checkout feature/v2-arm-fpga-demo-conv
bash fw/arm/build_arm_firmware.sh            # arm fw

git checkout feature/v2-fpga-e203-conv
bash fw/v2_e203_smoke/build_v2_e203_smoke.sh  # e203 v2 fw

# 试 build 主要 sim
git checkout main
bash sim/run_chip_top_rom_smoke.sh
bash sim/run_e203_icarus.sh

# ... 等等
```

任何 build 失败 → root cause（缺依赖 / 缺 toolchain / 缺 path 配置） → 自己修
build script（加 fallback / 文档化依赖）→ commit -s → push

**M.3 SHA256 一致性 — 重 build 后 binary 是否 byte-exact**

对每个 fw build 后生成的 binary（.bin / .hex / .elf）：
```bash
# 重 build 后 SHA256
sha256sum fw/<feature>/out/*.bin

# 与已 commit 的 binary 比较
git diff fw/<feature>/out/*.bin
```
任何漂移说明 build 不可复现（坏！）→ 自己修 → commit → push

**M.4 sim PASS marker 一致性**

清 checkout 后，跑全部 sim/run_*.sh，验证每个 PASS marker 仍然出现：
```bash
for sh in sim/run_*.sh; do
    timeout 1800 bash "$sh" 2>&1 | grep -E "_PASS|_FAIL"
done
```
任何 PASS 不一致（之前 PASS 现在 FAIL，或 FAIL 现在 PASS）说明项目状态不
self-consistent → finding。

**输出**：`agent_m_tb_repro.md`：
- TB coverage gap 清单（按重要性排序）
- Build script 修复 commit hash（如有）
- Reproducibility verdict per branch（✅ clean build PASS / ⚠ partial / ❌ broken）
- 任何 sim PASS 不一致 finding

---

### Agent G：Autonomous board reverify（**alpha + e203-conv** + Agent J/K trigger 的额外分支）

任务：

**G.1 基线重烧矩阵（round 2 finding 直接触发）**

| 分支 | 是否需要重烧 | 理由 |
|---|---|---|
| `main` | ❌ 不需要 | V1 ASIC pre-tape-out，无 FPGA bitstream |
| `main-fpga-e203-alpha` | ✅ **必须** | F001 改了 alpha smoke firmware PASS gating；F003 改了 silicon_bringup PROG_CTRL 写法；现有 UART evidence 失真 |
| `feature/v2-arm-fpga-demo-conv` | ⚠ **依 Agent J/K 结果**：如果 RTL 或 ARM fw 有改动 → 必须重烧；否则 round 2 verdict 是 NO | 见 G.2 |
| `feature/v2-fpga-e203-conv` | ✅ **必须** | F004 改了 v2_e203_smoke_main.c 返回码处理；F006 同步了 V2B_STAGE_POLL_TIMEOUT；现有 UART evidence 失真 |

**G.2 动态触发矩阵（Agent J/K 在 verify 过程中改了 RTL/fw 的 trigger）**

Agent J（RTL bug hunt）+ Agent K（fw 深度 audit）任何 commit 落到 FPGA 分支
（alpha / arm-conv / e203-conv），必须**自动追加**到本 sub-agent 的 reverify
队列。具体规则：

| Agent J/K commit 落点 | 必须 trigger 的板验 |
|---|---|
| 改 `rtl/` 任何文件 → 落到 alpha | alpha 重烧 + UART capture |
| 改 `rtl/` 任何文件 → 落到 arm-conv | arm-conv 重烧 + UART capture |
| 改 `rtl/` 任何文件 → 落到 e203-conv | e203-conv 重烧 + UART capture |
| 改 `fw/e203_smoke/` → 落到 alpha | alpha 重烧 + UART capture |
| 改 `fw/arm/` → 落到 arm-conv | arm-conv 重烧 + UART capture |
| 改 `fw/v2_e203_smoke/` 或 `fw/src/` → 落到 e203-conv | e203-conv 重烧 + UART capture |
| 仅改 doc / sim / TB → 落到任何分支 | 不 trigger 板验 |

**对每条需要重烧的分支 autonomous 完成**：

1. cd 到分支 worktree（**确认 Agent F 的 commit 已 push 到 origin**）
2. vivado bitgen（脚本通常在 `fpga_synth/<board>/` 或 `scripts/build_<branch>_bitstream.sh`；
   如果找不到 build 脚本，列 fallback）
3. 拿到 fresh `.bit` + `.elf` / `.hex` 并记录 SHA256（重烧前 vs 后）
4. xsct / JTAG load 到 ZCU102
5. 抓 UART log，文件命名：
   - alpha：`doc/main-fpga-e203/uart_capture_20260503_round3_postfix_reverify.txt`
   - e203-conv：`doc/v2-fpga-e203/uart_capture_20260503_round3_postfix_reverify.txt`
6. 验证 PASS marker：
   - alpha：`FPGA_E203_BOOT_UART_PASS` + `FPGA_E203_PROGRAM_ERASE_WRITE_PASS`
     （**特别注意** F001 修复后 PASS 不能再误报；如果 erase/write 失败应看到
     `FPGA_E203_PROGRAM_ERASE_WRITE_FAIL` 或类似 marker）
     + `FPGA_E203_PROGRAMMED_INFERENCE_PASS`
   - e203-conv：`FPGA_V2_E203_BOOT_UART_PASS` + `FPGA_V2_E203_LENET5_PASS`
7. fresh UART capture + 更新的 `build_manifest_*.txt` 加到 git，commit -s，push origin
8. **如果某步本机做不了**（vivado / ZCU102 不在线），明确列 fallback：
   "无法 autonomous reburn，请用户在 ZCU102 host 上跑：<具体命令>"——
   **不要假装做了**

**输出**：`agent_g_board_reverify.md`，每条分支：
- bitgen 命令 + 退出码 + 时长
- bitstream / elf / hex SHA256（重烧前 vs 后）
- xsct/JTAG 烧录命令 + 退出码
- UART capture 文件路径 + 关键 PASS marker 行号 + grep "PASS" 摘要
- commit hash（fresh evidence push 后）
- 任何 fallback 命令

---

## 5. 输出格式（你的最终 deliverable）

### 5.1 执行 summary 表

| 分支 | round 2 finding 全部 verify 通过？ | 新增 finding | 全 sim PASS？ | 板验完成？ | 仍需用户介入？ |
|---|---|---|---|---|---|
| main | YES/NO | N | YES/NO | N/A | YES/NO |
| alpha | YES/NO | N | YES/NO | YES/已自动重烧/失败 | YES/NO |
| arm-conv | YES/NO | N | YES/NO | N/A | YES/NO |
| e203-conv | YES/NO | N | YES/NO | YES/已自动重烧/失败 | YES/NO |

### 5.2 完整 commit 列表

每个分支：
- commit hash
- subject line
- 包含的 finding ID
- 是否 push origin（YES/NO + 时间）

### 5.3 重烧 evidence 表

| 分支 | 重烧 commit hash | bitstream 旧 SHA → 新 SHA | UART capture 文件 | 关键 PASS marker（行号） | 是否 autonomous 完成 |
|---|---|---|---|---|---|
| alpha | … | … | … | … | YES/fallback |
| e203-conv | … | … | … | … | YES/fallback |

### 5.4 新增 finding 列表（如有）

如果你在 verify 过程中发现 round 2 GPT 漏审 / 修错 / 引入新 bug，列出来：
ID（F101 起）/ Severity / Branch / File:line / 现象 / 修复方式 / 是否已自动修。

### 5.5 误报候选清单

对照 FP-001 ~ FP-008 + 本 prompt §6 新增的，列出排除过的误报。

### 5.6 Final closure verdict（**hard gate**）

明确给出：
- ✅ **闭环成功**：4 条支线本轮全部闭合（0 BLOCKER + 0 HIGH + 0 MEDIUM + ≤ 3 LOW
  + 全 sim PASS + 全 worktree commit/push + alpha + e203-conv 板验 PASS +
  Round 1 closure 复审 ✅）
  → **进 paper handoff 模式**，输出 §5.7 paper handoff guidance，**不再生成下一轮**
- ⚠ **部分闭合**：列出哪些子项必须用户介入（给具体 fallback 命令）
- ❌ **闭合失败**：列出原因 + 自己再尝试一轮 fix-on-sight；如果重试仍失败，
  生成 round 4 prompt（文件名格式：
  `doc/GPT_audit_prompt_2026_05_03_full_4branch_round4_<theme>.md`）

### 5.7 Paper handoff guidance（**仅 verdict = ✅ 时输出**）

如果本轮闭合，提供：

**5.7.1 论文 / 简历可引用的 evidence-backed claim 列表**

按可信度从高到低：
1. 板验 byte-exact 数字（带 UART capture 文件 + PASS marker 行号引用）
2. Sim cosim bit-exact 数字（带 cosim_log + golden/RTL SHA 对比）
3. PyTorch float proxy 训练精度（带 manifest 引用）
4. 文献区间对照（可以引但不能 quote 具体 paper number）

**5.7.2 Source-of-truth evidence 优先级**

列出每个 claim 对应的 single source of truth 文件路径。

**5.7.3 论文红线**

- ❌ 不要声称 SOTA / outperforms TrueNorth / Loihi
- ❌ 不要把 selected_accuracy = 1.0 当 100% test set 精度
- ❌ 不要 quote 任何 T=50 ablation 数字（都是负 trade-off）
- ❌ 不要声称本轮之后又做了 fresh board run（只引用本轮真做的 reverify evidence）
- ✅ 可以声称：runtime-configurable FC/CONV stage scheduling + dual-CPU bit-exact
  validation + quantization-stack-ceiling characterization

**5.7.4 Frozen tag 维护规则**

- forward-only `git commit -s`
- 不可移动 frozen tag
- 任何 hash 引用必须用 peeled commit SHA（FP-006 防呆）

---

## 6. FP（误报）模式提醒

### 6.1 已入库 FP（CLAUDE.md + 历史轮次加的）

- **FP-001**：`$signed()` + `<<<` 链报告前必须读完整赋值链 + 对照 SV LRM §6.24.1
- **FP-002**：报告位宽不足前必须查 `snn_soc_pkg.sv` 实际值 + 算 `$clog2`
- **FP-003**：FSM 地址 `+/-` 报告前必须区分阻塞 / 非阻塞赋值时序
- **FP-004**：边界条件报告前必须先确认是否已在文档定义为合法
- **FP-005**：CDC 报告前必须确认模块真有多个时钟域
- **FP-006**：annotated tag SHA vs peeled commit SHA 混淆——比对 frozen tag 必须
  用 `<tag>^{}` deref
- **FP-007**：报告 reset_sync 引入功能性问题前先排除"TB hardcoded wait cycles"
- **FP-008**：reset_sync 加 2 拍只影响 startup timing，不影响 inference functional
  正确性；sample byte-exact 一致但 cycle 数差 2 是预期，不是 bug

### 6.2 FP-009 候选（本轮新增，待你审查后决定入库）

**误判描述**：报告 worktree dirty 文件是"未提交的 bug"

**实际情况**：worktree dirty 是 round 2 GPT 自己做的 fix-on-sight，未来 push 即可。
报告时应区分"修改语义错误"vs"修改正确但未 commit"。

**识别规则**：报告 dirty file 前必须先：
1. 读 `git diff` 内容理解改动语义
2. 对照 round 2 finding 表 §1 看是否是已知 finding 修复
3. 如果是 finding 修复，报告 verdict 应该是 "verify finding F00X 是否真的修对了"
   而不是 "存在未提交的 bug"

---

## 7. 必须做的命令（举证 — 不接受"凭直觉"）

```bash
# 1. Frozen tag deref（FP-006 防呆）
for tag in v2-fpga-e203-passed v2-arm-fpga-demo-v2-passed v2-permanent-gate-2026-04-25 \
           v2-arm-fpga-demo-conv-passed v2-fpga-e203-conv-passed; do
    obj=$(git rev-parse $tag)
    type=$(git cat-file -t $tag)
    if [ "$type" = "tag" ]; then
        peeled=$(git rev-parse $tag^{})
        echo "annotated $tag: wrapper=$obj peeled=$peeled"
    else
        echo "lightweight $tag: commit=$obj"
    fi
done

# 2. byte-mask invariant
git diff <baseline>..HEAD -- rtl/top/v2b_axi_wrapper.sv rtl/top/snn_soc_v2b_top.sv \
    | grep "<= req_wdata"

# 3. cosim SHA recompute
sha256sum python_multilayer/results_conv/lenet5_fashion/sample_*_output_counts.txt

# 4. PROG_CTRL magic 数残留 (Agent A 验 F003 用)
grep -rn "PROG_CTRL = 0x" fw/

# 5. cross-branch fw consistency (Agent D 用)
diff <(git -C "<main worktree>" diff fw/boot_main.c) \
     <(git -C "<alpha worktree>" diff fw/boot_main.c)

# 6. Frozen 参数 grep
grep -rn "NUM_INPUTS.*=" rtl/ | grep -v "= 64\|=64"

# 7. async input sweep
grep -rEn "input.*\b(uart_rx|spi_miso|cim_done|adc_data|gpio)" rtl/

# 8. DCO compliance（窄口径，仅本轮）
git log --since=2026-05-03T00:00:00 --pretty="%H %s" | while read hash subject; do
    git log -1 --pretty="%b" $hash | grep -q "Signed-off-by:" \
        || echo "$hash MISSING DCO: $subject"
done

# 9. sim regression sweep template
cd "<branch worktree>/sim"
for sh in run_*.sh; do
    echo "=== $sh ==="
    timeout 1800 bash "$sh" 2>&1 | tail -3
done

# 10. autonomous board reverify (Agent G)
# vivado bitgen template
cd "<branch worktree>/fpga_synth/<board>"
vivado -mode batch -source build_<feature>.tcl 2>&1 | tee bitgen.log
sha256sum out/*.bit
# xsct template
xsct -nodisp scripts/load_and_run.tcl
# UART capture template
python scripts/capture_uart.py --port /dev/ttyUSB0 --baud 115200 \
    --output doc/<branch>/uart_capture_20260503_round3_postfix_reverify.txt \
    --duration 60
```

---

## 8. 你不能做的事

- ❌ 不可移动 frozen tag
- ❌ 不可 force-push
- ❌ 不可 rebase 已 push 的 commit
- ❌ 不可在没读完 CLAUDE.md + §1 + §2 + §3 的情况下 commit
- ❌ 不可 `git commit` 不带 `-s`
- ❌ 不可假装做了 board reverify（如果实际跑不了 vivado / xsct）
- ❌ 不可信 round 2 GPT 报告的"已修"原文，必须独立 verify
- ❌ 不可输出 "全部都很好" — 4 条支线 + 大量 worktree 改动，几乎不可能 0 finding

---

## 9. 时间预算

- Sub-agent A-E + H + I + J + K + L + M 并行 verify（12 个 verify agent）：~5-7 小时
- Sub-agent F commit + push（含 J/K/M 自动修的 commit）：~1 小时
- Sub-agent G board reverify（alpha + e203-conv 并行 + 任何 J/K 触发的额外分支）：~3-5 小时
- Synthesize + 写 final report + 写 round 4 prompt：~1-2 小时
- **总 ETA：10-15 小时**

如果你机器跑不完整（例如 vivado 占内存太大 / ZCU102 不在线），按"先完成所有
verify + commit + push，最后未完成的板验项明确列 fallback 命令"的优先级处理；
**不要为了赶时间跳过任何 sub-agent**——13 个 sub-agent 是 paper handoff 的硬要求。

如果某些步骤本机做不了，**列入 finding + fallback 命令**，不要假装做了。

---

## 10. 用户元目标

用户准备：
1. 流片 V1（main）— pre-tape-out 严苛度，本轮验证 reset_sync + boot fw timeout +
   silicon_bringup PROG_CTRL fix 全闭环
2. 投 SCI Q4 论文 — paper handoff 在本轮闭环后立即开始
3. 写硕士毕业论文 — 工程素养 + 全维度 audit 是 evidence

**Round 3 是收口轮**——本轮干净就**直接进 paper handoff**，不再 audit；本轮如有
未闭合项，列具体 fallback 给用户共同收尾。

---

## 11. 终止条件

满足以下**全部**条件 → 进 paper handoff：
- 0 BLOCKER + 0 HIGH + 0 MEDIUM + ≤ 3 LOW（合计 12 个 sub-agent 输出）
- 4 条支线 worktree 全 commit + push（0 dirty）
- 4 条支线全 sim regression PASS
- alpha + e203-conv 板验 PASS（含 fresh UART evidence commit）
- 任何 Agent J / Agent K trigger 的额外板验也 PASS
- Round 2 finding 表 §1 全部 verify ✅
- **Agent H CDC 深度审查 ≤ 3 LOW**（新代码 textbook 正确 + 接线无残留 + 全 RTL
  async sweep 无漏审入口 + H.2bis cross-branch 一致性 + FP-007/FP-008 排除）
- **Agent I Python ↔ RTL parity 0 不一致**（manifest / doc / cosim PASS marker /
  独立 SHA 重算全部 byte-exact）
- **Agent J 全 RTL bug hunt ≤ 3 LOW**（FP-001 ~ FP-005 全排除 + SVA 完整）
- **Agent K Firmware 深度 audit ≤ 3 LOW**（PROG_CTRL / W1P/W1C / busy-loop /
  UART / boot rom / ARM fw 全清）
- **Agent L Doc cross-consistency ≤ 3 LOW**（互引用 / commit hash / 文件路径 /
  数字 / main vs alpha / arm vs e203 / CLAUDE.md vs 实际状态全一致）
- **Agent M TB coverage + reproducibility ≤ 3 LOW**（关键 TB 无 critical
  coverage gap + clean checkout build PASS + binary SHA byte-exact 可复现）
- Round 1 closure 复审仍 ⚠ partial 是 OK（已经 documented）

### 11.bis 下一轮 prompt 生成（**强制 hard gate，无论本轮是否闭合**）

本轮**必须**生成下一轮 GPT 冷启动 prompt，**inline 输出**到你的最终报告里
（不要写文件 — 让用户 copy-paste 到下一个 GPT 会话）。这是循环式审查，不是
一次性审查。即使本轮 verdict = ✅ 闭合，也要生成"下一轮 verify 本轮 closure
是否真实"的 prompt。

下一轮 prompt 文件名（你只需在 prompt 内容里写明，不需要真创建文件）：

| 本轮 verdict | 下一轮 prompt 文件名 | 主题 |
|---|---|---|
| ✅ 闭合 | `doc/GPT_audit_prompt_2026_05_03_full_4branch_round4_closure_verify.md` | "Verify round 3 closure 是真的：重跑 sim regression + 重新 deref tag + 抽查 board UART evidence + 复核 paper handoff guidance" |
| ⚠ 部分闭合 | `doc/GPT_audit_prompt_2026_05_03_full_4branch_round4_partial_recovery.md` | 列出本轮未闭合项 + 用户已介入完成项目 + 还需 GPT 收尾的清单 |
| ❌ 闭合失败 | `doc/GPT_audit_prompt_2026_05_03_full_4branch_round4_<theme>.md` | 本轮未闭合项的清扫 prompt |

下一轮 prompt 必须满足：

1. **接续本轮 unresolved findings**：所有 BLOCKER/HIGH/MEDIUM/LOW（含本轮自报
   ✅ 已修但**未独立第三方验证**的 finding）继续传递
2. **新增审查角度**：本轮已审查范围列出来；下一轮**至少换 2 个新角度**，例如：
   - Vivado synthesis report (LUT/FF/BRAM utilization) audit
   - Python/topologies.yaml 全字段 schema validation
   - Git history 时间线 / commit 节奏 / 是否有 force-push 痕迹
   - sim/run_*.sh 全部脚本是否能在 clean checkout 上 run（reproducibility）
   - 完整 `fpga_synth/` 目录 audit
   - V1 ASIC pad-cell 实例化 readiness（pad cell macro / ESD / drive-strength
     还没接，是真 tape-out blocker）
   - main 分支 fw/silicon_bringup 的边界条件覆盖度
3. **保留全部红线**（frozen tag / V1 frozen 参数 / Scheme B / byte-mask invariant /
   main vs alpha 一致性 / DCO / no force-push）
4. **保留全部 FP 模式**（FP-001 ~ FP-009）
5. **更新 4 条支线 origin HEAD** 到本轮结束时的实际值
6. **标明本轮 round 编号**（round 3）+ 下一轮 round 编号（round 4）
7. **声明终止条件**：连续 2 轮报告 0 BLOCKER + 0 HIGH + 0 MEDIUM + ≤ 3 LOW +
   全 sim PASS + 全 board reverify PASS → 进入"final paper handoff round"，
   下一轮改为只清扫 LOW + 写最终 closure tag 候选
8. **声明 fix-on-sight + autonomous board reverify** 授权（如果本轮 verdict
   = ✅，下一轮可以放宽到只 verify 不修；如果 ⚠ / ❌，下一轮继续 fix-on-sight）

**这个下一轮 prompt 是 hard gate**：本轮报告里**没有**这一段 = 本轮未完成。

---

## 12. 最后

跑吧。Spawn 7 个 sub-agent，don't wait。

本轮 deliverable：
1. §5.1 ~ §5.7 完整报告
2. 所有 worktree 修改 commit + push origin
3. alpha + e203-conv 板验 evidence push origin
4. **Agent H CDC 深度审查 verdict + 任何新发现的 CDC fix commit**
5. Final closure verdict（✅ paper handoff / ⚠ 部分闭合 / ❌ 失败）
6. **下一轮 round 4 prompt 内容**（无论 verdict 如何，**强制 hard gate**，
   inline 输出，详见 §11.bis；闭合时主题是"verify closure 是真的"，未闭合时
   主题是"清扫剩余项"）

不要留尾巴。本轮就是终极一次性收口。

---

**END OF ROUND 3 FINAL CLOSURE PROMPT — copy this whole file into a new GPT-5.4 (effort=xhigh) cold-start chat**
