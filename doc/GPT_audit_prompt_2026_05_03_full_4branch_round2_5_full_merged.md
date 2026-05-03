# GPT 冷启动 prompt — Round 2.5 MERGED（全维度 4 分支审查 + CDC 重点 + 自主修 + 自主板验）

> **生成时间**：2026-05-03 reset_sync 落地 + 用户要求合并 round 2 全维度审查 + round 2.5 CDC 专项审查
> **使用方式**：复制本文件全部内容粘贴给 **GPT-5.4 (effort=xhigh)** 作为冷启动消息。
> 不需要前情提要——所有上下文都在本文件里（770 KB context budget 不是问题，请按本文件
> 的全部要求执行，不要因 scope 大而 cherry-pick 跳过任何一项）。
>
> **本轮 supersedes**：
> - `doc/GPT_audit_prompt_2026_05_03_full_4branch_round2.md`（原全维度，无自主修 / 板验授权）
> - `doc/GPT_audit_prompt_2026_05_03_full_4branch_round2_5_cdc.md`（仅 CDC 专项 + 自主板验）
>
> 本 merged 版 = 上述两份**取并集** + 自主修 + 自主板验授权 + CDC 重点。
>
> **执行模式**：必须 spawn **至少 7 个并行 sub-agent**。
> **特殊授权**：fix-on-sight + autonomous bitgen / xsct / UART capture + commit/push（带 `-s`）。
>
> **本轮目标**：**一个 GPT 对话内**完成全部审查 + 全部修复 + 全部上板验证；不留尾巴
> 给下一轮（除非真做不到，例如 vivado / ZCU102 host 不在你机器上，那一项明确列出
> fallback 命令给用户）。

---

## 0. 你是谁，要做什么

你是一名**严苛的硬件 + 软件 + 板验全栈 audit 工程师**。本轮**一次性完成**：

1. **全维度审查** 4 条活跃分支（RTL / Python / TB / sim / fw / doc / git）
2. **CDC / reset domain 重点深度审查**——刚加的 `reset_sync.sv` + `sync_2ff.sv` 是
   pre-tape-out 严苛度新增内容，必须重点过；同时全 RTL 重新 sweep 是否还有漏审的
   async input
3. **fix-on-sight**：发现的 BLOCKER / HIGH / MEDIUM 自己改，commit 带 `-s`，push origin
4. **autonomous board reverify**（仅 FPGA 分支）：自己 vivado bitgen + xsct/JTAG 烧
   ZCU102 + 抓 UART + 验 PASS marker + commit fresh evidence
5. **生成 final closure 报告**：4 条分支关闭 verdict 表 + 逐项 finding 列表 +
   FPGA 重烧决策表 + paper handoff guidance

特殊授权（仅本轮）：
- ✅ 可以修 RTL / TB / sim filelist / fw / doc 任何文件
- ✅ 可以执行 vivado / xsct / 板验 / 抓 UART
- ✅ 可以 `git commit -s` + `git push origin <branch>`
- ❌ 仍不可移动 frozen tag
- ❌ 仍不可 force-push
- ❌ 仍不可 rebase 已 push 的 commit

---

## 1. 项目当前状态（你必须先读完才能开始）

### 1.1 4 条分支当前 origin HEAD

| # | 分支 | HEAD | 含义 |
|---|---|---|---|
| 1 | `main` | `19e2be93` | V1 SNN SoC 主线（pre-tape-out）+ 刚加的 reset_sync + cim_done sync + round 2.5 prompt（即将 supersede 本文件）|
| 2 | `main-fpga-e203-alpha` | `ae931174` | V1 main 的 FPGA 镜像（除 FPGA-specific 外应与 main 字节级一致）|
| 3 | `feature/v2-arm-fpga-demo-conv` | `bf56e942` | V2.B CONV extension（ARM Cortex-A53 板验路径）+ reset_sync 在 chip_top + v2b_arm_demo_top 都加了 |
| 4 | `feature/v2-fpga-e203-conv` | `08e5b8f6` | V2.B CONV extension（E203 RISC-V 板验路径）+ reset_sync 在 chip_top + snn_soc_v2b_e203_top 都加了 |

### 1.2 Frozen tags（不可移动 — 严格 deref 验证，FP-006 防呆）

| Tag 名 | Annotated tag wrapper SHA | Peeled commit SHA |
|---|---|---|
| `v2-arm-fpga-demo-v2-passed` | `75c200bf` | （deref 自查）|
| `v2-fpga-e203-passed` | `a6b441e6` | （deref 自查）|
| `v2-permanent-gate-2026-04-25` | `9dbcc797` | （deref 自查）|
| `v2-arm-fpga-demo-conv-passed` | `49c26a60`（**annotated**） | `dabcaf0d`（**doc 引用此**） |
| `v2-fpga-e203-conv-passed` | `d9b14a8d`（**annotated**） | `a1c0c828`（**doc 引用此**） |

**⚠ 严重警告 — FP-006**：`git rev-parse <tag>` 返回 wrapper SHA；`git rev-parse <tag>^{}`
返回 peeled commit SHA。doc 引用的是 commit SHA。比对 tag 是否被移动**必须**用
`^{}` deref 双方再比较，**不能**直接拿 `git rev-parse <tag>` 的结果对比 doc 引用值
（前者是 49c26a60 / d9b14a8d，后者是 dabcaf0d / a1c0c828，两者本来就应该不同）。

### 1.3 关键 ablation 状态（截至 2026-05-03）

`doc/19_training_accuracy_summary.md`（v2 / arm-conv / e203-conv 上都有；main 不该有）：

| # | 网络 / dataset | quant SNN test | 路径状态 |
|---|---|---|---|
| 1 | Fashion 14×14 FC 196→64→10 | 82.38% | 板验 byte-exact |
| 2 | MNIST 14×14 同上 | 96.48% | 同路径不上板 |
| 3 | LeNet-5 MNIST 28×28 | 93.03% | CONV path 板验 byte-exact |
| 4 | Fashion 28×28 FC 784→64→10 | 84.05% | Python ideal matmul，未板验 |
| 5 | LeNet-5 Fashion 28×28 | 81.99% | sim cosim bit-exact PASS |
| **T-sweep** MNIST T=30/50 | LeNet-5 | 93.55% / 92.81% | sim cosim bit-exact PASS |
| **T-sweep** Fashion T=30/50 | LeNet-5 | 82.88% / 81.94% | sim cosim bit-exact PASS |
| **CIFAR-10** Tiny VGG / Plain-CNN-4 | ~13% plateau | M5 主动收兵，不上板 |

### 1.4 本轮直接相关的最新改动（reset_sync + sync_2ff）

| 文件 | 4 条支线哪些有 | 含义 |
|---|---|---|
| `rtl/sys/reset_sync.sv` | 全 4 条 | async-assert / sync-release reset 同步器 |
| `rtl/sys/sync_2ff.sv` | 全 4 条 | 通用 2-FF metastability sync（WIDTH 参数化）|
| `tb/reset_sync_tb.sv` | 全 4 条 | T1-T4 测试，PASS marker `RESET_SYNC_TB_PASS` |
| `tb/sync_2ff_tb.sv` | 全 4 条 | T1-T5 测试（含 WIDTH=4），PASS marker `SYNC_2FF_TB_PASS` |
| `sim/sim_reset_sync.f` + `sim/run_reset_sync.sh` | 全 4 条 | reset_sync 单元入口 |
| `sim/sim_sync_2ff.f` + `sim/run_sync_2ff.sh` | 全 4 条 | sync_2ff 单元入口 |
| `rtl/top/chip_top.sv` | 全 4 条 | 加 `rst_n_sync` + `cim_done_sync` 实例化两个新模块；`snn_soc_top.rst_n` 改 `rst_n_sync`，`cim_done_ext` 改 `cim_done_sync` |
| `rtl/top/v2b_arm_demo_top.sv` | 仅 arm-conv | 加 `reset_sync`，`v2b_axi_wrapper.rst_n` 改 `rst_n_sync` |
| `rtl/top/snn_soc_v2b_e203_top.sv` | 仅 e203-conv | 加 `reset_sync`，下游 8 个子模块的 `.rst_n()` 全改 `rst_n_sync` |
| 各分支相应 sim filelist | 见 round 2.5 prompt §2.3 | 加 `../rtl/sys/sync_2ff.sv` + `../rtl/sys/reset_sync.sv` |

### 1.5 Round 1 GPT 自主完成的 closure（HEAD 之前的层）

| 分支 | Round 1 commit | 含义 |
|---|---|---|
| main | `850c3cae` | DCO governance + frozen-tag guidance |
| main-fpga-e203-alpha | `233db876` | **真 firmware 改动**：fw/e203_smoke/e203_fpga_smoke.c 加 `prog_ctrl_start_preserve_retry()` helper（避免直写 0x07 时 clobber RETRY_LIMIT[10:8]）+ 重 build elf/bin/hex/dump/map/o + UART reverify capture |
| arm-conv | `d50b7d37` | doc/manifest realign + UART reverify capture |
| e203-conv | `5cd74ea8` | doc/manifest realign + UART reverify capture + 同步 196_64_10__mnist14/model.pt |

### 1.6 必读文件清单

每条分支必读：
- `CLAUDE.md`（项目核心约束 + FP-001..FP-005 + RTL 漏洞报告规范）
- `doc/00_architecture.md`（V1 架构）
- `doc/02_reg_map.md`（V1 寄存器表）
- `doc/06_learning_path.md`
- `doc/19_training_accuracy_summary.md`（仅 v2 / arm-conv / e203-conv）
- `doc/v2-architecture/conv_extension_log.md`（仅 conv 两条支线）
- `doc/v2-architecture/non_linearity_proof.md`（仅 conv 两条支线）

仅 main / main-fpga-e203-alpha 必读：
- `doc/15_asic_pad_map.md`（55 pad 预算）
- `doc/08_cim_analog_interface.md`（外部编程 α' 协议）
- `doc/11_analog_handoff_execution_plan.md`
- `doc/main-fpga-e203/00_architecture.md`
- `doc/main-fpga-e203/uart_capture_20260503_alpha_reverify.txt`（round 1 reverify evidence）

仅 conv 分支必读：
- `doc/v2-fpga-e203/00_architecture.md` / `doc/arm-fpga-demo/00_architecture.md`
- 对应 `doc/<branch>/uart_capture_20260503_lenet5_reverify.txt`
- `python_multilayer/results_conv/lenet5*/lenet5_golden_manifest.json`

---

## 2. 必须保护的硬约束（红线 — 一旦违反立即 BLOCKER）

### 2.1 frozen tags 永不可移动

```
v2-fpga-e203-passed
v2-arm-fpga-demo-v2-passed
v2-permanent-gate-2026-04-25
v2-arm-fpga-demo-conv-passed @ dabcaf0d (peeled commit)
v2-fpga-e203-conv-passed @ a1c0c828 (peeled commit)
```

任何对这些 tag 的移动 / 删除 / 重命名都是 BLOCKER。
对比时**必须**用 `git rev-parse <tag>^{}`（FP-006 防呆）。

### 2.2 V1 frozen 参数不可改

完整列表见 `CLAUDE.md` "项目核心参数" 表。重点：
- `NUM_INPUTS = 64`、`ADC_BITS = 8`、`ADC_CHANNELS = 20`、`TIMESTEPS = 10`
- `THRESHOLD_RATIO = 1` → `THRESHOLD_DEFAULT = 2550`
- `NEURON_DATA_WIDTH = 9` (signed)
- `MAC_W_LOAD_*` 寄存器 offset = `0x050 / 0x054 / 0x058`

### 2.3 Scheme B 差分（架构决策）不可改回 Scheme A

20 路 ADC：ch 0-9 = pos，ch 10-19 = neg，数字侧 `diff = raw[i] - raw[i+10]`。

### 2.4 byte-mask invariant 永久门禁

所有 reg_bank 写路径必须用 `apply_wstrb()`，不允许直接 `<= req_wdata`：

```bash
git diff <baseline>..HEAD -- rtl/top/v2b_axi_wrapper.sv rtl/top/snn_soc_v2b_top.sv \
    | grep "<= req_wdata"
# 必须返回 0 行
```

### 2.5 main vs main-fpga-e203-alpha 一致性（**round 1 起的硬规则**）

这两条分支**除 FPGA-specific 文件外必须完全一致**。FPGA-specific 范围：
- `fpga_synth/` 全部
- `rtl/top/chip_top.sv` 的 pad mapping 段（如有差异）
- `fw/v2_e203_smoke/` 下 FPGA bringup 专用代码
- 任何 ZCU102 / Vivado 专用配置脚本

任何在 FPGA-specific 范围外的差异都是 BLOCKER。
**注意**：本次新加的 `rtl/sys/reset_sync.sv` / `rtl/sys/sync_2ff.sv` /
对应 TB / sim runner / `chip_top.sv` 改动**必须**两条分支字节级一致。

### 2.6 `--no-verify` / `--no-gpg-sign` 禁用

git log 凡是带 `[no-verify]` 标记或缺 `Signed-off-by` 的 round 1 之后 commit
都要列出。round 1 起 governance 要求所有新 commit `git commit -s`。

### 2.7 reset_sync / sync_2ff 实例化红线（本轮新增）

- `chip_top.sv`：全 4 条支线必须有 `reset_sync` + `sync_2ff` 实例化，下游
  `snn_soc_top.rst_n` 必须接 `rst_n_sync`，`cim_done_ext` 必须接 `cim_done_sync`
- `v2b_arm_demo_top.sv`（arm-conv）：必须有 `reset_sync`，`v2b_axi_wrapper.rst_n`
  必须接 `rst_n_sync`
- `snn_soc_v2b_e203_top.sv`（e203-conv）：必须有 `reset_sync`，下游所有子模块
  （e203_min_wrap / icb2simple_bridge / bus_interconnect / sram_simple × N /
  uart_ctrl / simple2v2btop_adapter / snn_soc_v2b_top）的 `.rst_n()` 必须接
  `rst_n_sync`，**不能**还有任何 `.rst_n(rst_n)` 漏改的实例

---

## 3. 子代理分工（**必须 spawn ≥ 7 个并行 sub-agent**）

按下列分工严格执行；任何 sub-agent 不可跳过。

### Agent A：CDC / reset domain 深度审查（**重点新代码 + 全 RTL CDC sweep**）

任务：
- **重点 1：审查 4 条支线刚加的新 RTL 模块代码本身**：
  - `rtl/sys/reset_sync.sv`：textbook 正确性（async assert / sync release 实现是否
    符合 §3.7 红线）；`async_reg = "TRUE"` 属性放置位置正确性；STAGES 参数边界
    检查（STAGES=1 是否安全？STAGES=3 是否多余？）
  - `rtl/sys/sync_2ff.sv`：参数 WIDTH 正确性；多 bit 时是否有 per-bit cycle skew
    潜在风险（应该有头注释禁止用 sync_2ff 处理多 bit 数据 — 验证注释是否到位）
- **重点 2：审查 4 条支线的 chip_top.sv / v2b_arm_demo_top.sv / snn_soc_v2b_e203_top.sv
  里 reset_sync + sync_2ff 实例化的接线**：
  - `clk` / `rst_n_async` / `rst_n_sync` 接线是否正确（不接错信号）
  - 下游所有 always_ff 是否 100% 接到 `rst_n_sync` 而非 raw `rst_n_pad` 或 `rst_n`
    （可能漏改某个）
  - e203-conv 的 `snn_soc_v2b_e203_top.sv` 子模块特别多，重点 grep
    `\.rst_n\(rst_n\)`（任何残留就是漏改）
- **重点 3：全 RTL async input sweep**（确认还有没有漏审的 async 入口）：
  ```bash
  cd "<branch worktree>"
  grep -rEn "input.*\b(uart_rx|spi_miso|gpio_in|prog_op|prog_level|adc_data|cim_done|bl_data|bl_sel|jtag_tck|jtag_tms|jtag_tdi|gpio_int|interrupt_in)\b" rtl/
  grep -rEn "negedge rst_n|posedge rst_n" rtl/ | grep -v "rst_n_async"
  ```
- 对每个发现的 async input 给出 verdict：✅ 已 sync / ❌ 漏了（自己补）/ ⚠ 不需要
  sync（说明原因，例如 jtag_tck 已自己 sync）
- 验证 Icarus iverilog elaboration 不被 `(* async_reg = "TRUE" *)` 属性 break
  （Icarus 应该忽略或接受为注释）

**输出**：`agent_a_cdc_findings.md` + 修复 commit hash 列表（如有）。

### Agent B：RTL bug hunt（非 CDC 维度，per-branch 全栈）

任务：
- 对每条分支的 `rtl/` 目录做**非 CDC 维度**的 RTL 审查（CDC 由 Agent A 负责）
- 重点：
  - 时序：`=` vs `<=` 用法（参考 CLAUDE.md FP-003）
  - 位宽截断 / 符号扩展（FP-001 类）
  - signed/unsigned 链完整性（参考 CLAUDE.md FP-001 + lif_neurons 案例）
  - reset 逻辑一致性（async vs sync 别混用）— 与 Agent A 的 CDC 互补
  - FSM：state encoding / illegal state handling
  - SVA：必须在 `ifdef VCS / ifndef SYNTHESIS` 保护下
- **每个 bug 必须按 CLAUDE.md "RTL 漏洞报告规范" 格式**：
  ```
  【缺陷描述】
  【触发条件】
  【仿真激励】
  【预期异常现象】
  ```
- **写不出可触发激励的 bug 必须标"疑似误报"，不计入修复列表**
- 发现真 bug → 自己修 → commit -s → push

**输出**：`agent_b_rtl_findings.md` + 修复 commit hash 列表（如有）。

### Agent C：Python ↔ RTL parity + Manifest verification

任务：
- 验证 `python_multilayer/results_*/lenet5*/lenet5_golden_manifest.json` 里所有
  `quant_snn_test_accuracy` / `selected_accuracy` / `t_count` 等数字与
  `doc/19` + `conv_extension_log` 表里数字字节级一致
- **必须重新计算 SHA256** 验证至少 2-3 个 bundle 的 golden_counts SHA 与 doc
  写的一致（不只信 manifest 自报数）：
  ```bash
  for sample in 0 1 2; do
      sha256sum python_multilayer/results_conv/lenet5_fashion/sample_0${sample}_output_counts.txt
  done
  ```
- 验证 `python_multilayer/topologies.yaml` 里 `196_64_10` / `784_64_10` /
  `mnist_196_64_10` 拓扑配置（threshold / sum_max / stream_timesteps / adc_bits）
  与对应 summary.txt + doc/19 数字一致
- 验证 cosim_*_log.txt 里 `LENET5_COSIM_TB_PASS` marker 真实存在 +
  `golden_counts SHA = rtl_counts SHA` 真的相等（不只 manifest 自报）
- 任何不一致 → 自己修 doc 或 manifest（看哪个是对的） → commit -s → push

**输出**：`agent_c_parity_findings.md` + 修复 commit hash 列表（如有）。

### Agent D：Firmware 全栈 audit（**round 2 已规划，本轮必做**）

任务：
- 对每条分支的 `fw/` 目录系统性审查
- 重点：
  - **W1P / W1C 寄存器**：是否每次写都 wait DONE 才继续？（参考 round 1 GPT 抓到的
    PROG_CTRL retry bit clobber bug）
  - **read-modify-write 模式**：写入控制寄存器是否会意外 clobber 其他位？（典型
    case 是直接 `REG = 0xXX` 而不是 `REG = (REG & ~MASK) | NEW`）
  - **busy-loop**：是否有 timeout 保护避免 board hang？
  - **UART printf**：buffer overflow / 字符串边界？
  - **boot rom / crt0**：reset vector / bss clear / stack init / cpu_local_rst_n 释放
- **特别审查 round 1 修过的 fw**：
  - `fw/e203_smoke/e203_fpga_smoke.c`（GPT round 1 commit 233db876 加了
    `prog_ctrl_start_preserve_retry()` helper）— 验证这个 fix 没有 break 其他
    PROG_CTRL 写法（例如其他文件可能还在直写 0x07 / 0x11，需要也用 helper 改写）
  - 全项目 grep `PROG_CTRL = 0x` 看是否还有"直写 magic 数"未通过 helper：
    ```bash
    grep -rn "PROG_CTRL = 0x" fw/
    ```
- 报 fw bug 也要遵循"必须可触发激励"规则
- 发现真 bug → 自己修 → 必要时重 build artifacts → commit -s → push

**输出**：`agent_d_fw_findings.md` + 修复 commit hash 列表 + （如重 build firmware）
fresh artifacts SHA。

### Agent E：4 分支一致性 + 跨分支同步审查（**round 2 已规划，本轮必做 + 加新代码 cross-check**）

任务：
- **main vs main-fpga-e203-alpha**（CLAUDE.md 硬规则）：
  - 对比所有目录（除 `fpga_synth/`、`rtl/top/chip_top.sv` 的 pad 段、
    `fw/v2_e203_smoke/`）
  - 列每个文件级差异，分类：✅ FPGA-specific / ⚠ 应同步漏了 / ❌ BLOCKER
  - 对 ❌ 自己修（cherry-pick 或反向 sync） → commit -s → push
- **arm-conv vs e203-conv**：
  - 对比 `doc/19_training_accuracy_summary.md` / `doc/v2-architecture/conv_extension_log.md` /
    `doc/v2-architecture/non_linearity_proof.md` / `python_multilayer/results_conv/lenet5*/`
    （这些应字节级一致）
  - 列差异，分类：✅ CPU-path-specific / ⚠ 应一致漏了 / ❌ BLOCKER
- **新代码 cross-branch 一致性**（本轮新增重点）：
  - `rtl/sys/reset_sync.sv` 在 4 条支线必须字节级一致
  - `rtl/sys/sync_2ff.sv` 在 4 条支线必须字节级一致
  - `tb/reset_sync_tb.sv` / `tb/sync_2ff_tb.sv` 在 4 条支线必须字节级一致
  - `sim/run_reset_sync.sh` / `sim/run_sync_2ff.sh` 在 4 条支线必须字节级一致
  - `chip_top.sv` 的 reset_sync + sync_2ff 实例化段在 4 条字节级一致
- **frozen tag 严格 deref 验证**（FP-006 防呆）：
  ```bash
  for tag in v2-arm-fpga-demo-v2-passed v2-fpga-e203-passed v2-permanent-gate-2026-04-25 \
             v2-arm-fpga-demo-conv-passed v2-fpga-e203-conv-passed; do
      tag_obj=$(git rev-parse $tag)
      tag_type=$(git cat-file -t $tag)
      if [ "$tag_type" = "tag" ]; then
          peeled=$(git rev-parse $tag^{})
          echo "annotated $tag: tag_obj=$tag_obj peeled=$peeled"
      else
          echo "lightweight $tag: commit=$tag_obj"
      fi
  done
  ```
  对比 doc 引用的 commit hash 与上面 deref 出的 peeled commit SHA
- **DCO compliance**：
  ```bash
  git log --since=2026-05-02 --pretty="%H %s" | while read hash subject; do
      git log -1 --pretty="%b" $hash | grep -q "Signed-off-by:" || echo "$hash MISSING DCO: $subject"
  done
  ```
  列出所有缺 Signed-off-by 的 commit；任何 round 1 之后的 commit 缺签都是 finding

**输出**：`agent_e_consistency_findings.md` + 修复 commit hash 列表（如有）。

### Agent F：Sim regression 全量 sweep + TB 覆盖度增补

任务：
- **全量 sweep**：在 4 条支线上分别跑**所有** `sim/run_*.sh`（不是抽样）：
  ```bash
  cd "<branch worktree>/sim"
  for sh in run_*.sh; do
      echo "=== $sh ==="
      timeout 1800 bash "$sh" 2>&1 | tail -3
  done
  ```
- 列出每条支线完整 PASS / FAIL marker 表
- 任何 FAIL **必须** root cause（不接受"reset_sync 加了 2 拍延迟所以 timing 紧"
  作为借口 — reset_sync 是 forward-correct fix，TB / FW 应该能 handle reset 释放
  晚 2 拍；TB hardcoded wait cycle 数应该 +2 而不是 revert reset_sync）
- 发现真 FAIL → 自己修（**fix-on-sight**）→ 重跑 PASS → commit -s → push
- **TB 覆盖度增补**（重点新 TB）：
  - `tb/reset_sync_tb.sv`：是否覆盖 STAGES≠2 的实例化（应该加参数化测试）？
    是否覆盖 X-prop（reset 释放后下一拍 input=X）？
  - `tb/sync_2ff_tb.sv`：WIDTH=1/4 已有；建议加 WIDTH=8/16 极端值测试 +
    clk glitch + rst_n_async 同时 toggle 的 corner case
  - 如果 coverage 不足，**自己**补 cases，重跑 PASS

**输出**：`agent_f_sim_findings.md` + 修复 commit hash 列表 + 新 TB cases（如有）。

### Agent G：Doc 更新 + CIFAR plateau evidence + Closure narrative reclassification

任务：
- **Doc 更新（reset_sync + sync_2ff narrative）**：
  - main + alpha：在 `doc/main-fpga-e203/00_architecture.md` 加 reset domain 章节
  - arm-conv：在 `doc/arm-fpga-demo/00_architecture.md` 加 reset domain 章节
  - e203-conv：在 `doc/v2-fpga-e203/00_architecture.md` 加 reset domain 章节
  - conv 分支：在 `doc/v2-architecture/conv_extension_log.md` 末尾加 §
    "2026-05-03 pre-tape-out CDC fix" 简述 reset_sync + sync_2ff 改动
  - 主 doc：在 `doc/06_learning_path.md` 适当位置加 metastability / async-assert /
    sync-release 学习路径段（面试视角写法，参考已有 §15-§18 风格）
- **CIFAR-10 plateau evidence audit**（round 2 已规划，本轮必做）：
  - 找 `python_multilayer/checkpoints/` 下是否有 tiny_vgg / plain_cnn4 ckpt
  - 找训练 log（可能在 `python_multilayer/results_conv/` 或本地临时位置）
  - 验证 `conv_extension_log §2.2` 声称的 "~13% plateau" 是否有 reproducible 证据
  - 如果证据**缺失**，列为 finding "CIFAR plateau claim 缺 evidence"，并：
    - 选项 1：建议用户在 GPU 机器上重训记录数字（你这边可能跑不了 GPU）
    - 选项 2：如果你能在 CPU 上跑 1-2 epoch 看 loss 趋势 ≈ 13% chance，那也算
      partial evidence，记下来
  - 如果证据**存在**，验证数字与 doc 一致
- **Round 1 closure 复审（重新分类 closure commit）**：
  - `850c3cae` (main): 实际是 doc-only / governance-only — 验证
  - `233db876` (alpha): 含 firmware + artifact rebuild — 验证 round 1 GPT 报告
    §6 表是否准确分类（GPT 当时报为 "doc + manifest + TB hygiene" 略微淡化了
    firmware 改动）
  - `d50b7d37` (arm-conv): 12 文件，列每文件改动类型
  - `5cd74ea8` (e203-conv): 同上
  - 如果 GPT round 1 报告对 233db876 分类不准确，列为 finding
    "round 1 closure report 漏报 firmware 改动" 并在本轮 doc 里补正

**输出**：`agent_g_doc_findings.md` + 修复 commit hash 列表（如有）+ CIFAR plateau
evidence verdict。

### Agent H：Autonomous board reverify（**仅 FPGA 分支**）

任务：

| 分支 | 是否需要重烧 | 理由 |
|---|---|---|
| `main` | ❌ 不需要 | V1 ASIC pre-tape-out，无 FPGA bitstream |
| `main-fpga-e203-alpha` | ✅ **需要** | 加了 reset_sync 改了 chip_top.sv，影响 alpha smoke firmware reset 释放时序 |
| `feature/v2-arm-fpga-demo-conv` | ✅ **需要** | 加了 reset_sync 改了 v2b_arm_demo_top.sv，影响 ARM AXI-Lite reset 释放时序 |
| `feature/v2-fpga-e203-conv` | ✅ **需要** | 加了 reset_sync 改了 snn_soc_v2b_e203_top.sv 顶层，所有下游模块 reset 释放晚 2 拍 |

**对每条需要重烧的分支 autonomous 完成**：

1. cd 到分支 worktree
2. 触发 vivado bitgen（脚本通常在 `fpga_synth/<board>/` 或 `scripts/build_<branch>_bitstream.sh`）
3. 拿到 fresh `.bit` + `.elf` / `.hex` (SHA256 记录)
4. xsct / JTAG load 到 ZCU102
5. 抓 UART log
6. 验证 PASS marker：
   - alpha：`FPGA_E203_BOOT_UART_PASS` + `FPGA_E203_PROGRAM_ERASE_WRITE_PASS` +
     `FPGA_E203_PROGRAMMED_INFERENCE_PASS`
   - arm-conv：`ARM_FPGA_DEMO_LENET5_PASS`
   - e203-conv：`FPGA_V2_E203_BOOT_UART_PASS` + `FPGA_V2_E203_LENET5_PASS`
7. 把 fresh UART capture（命名：`doc/<branch>/uart_capture_20260503_reset_sync_reverify.txt`）
   + 更新的 `build_manifest_*.txt` 加到 git，`git commit -s`，push origin
8. **如果某步失败**（例如 vivado 不在你的机器上 / ZCU102 不在线），列为 finding：
   "无法 autonomous reburn，需要用户在 ZCU102 host 上跑：<具体命令>"——**不要假装做了**

**输出**：`agent_h_board_reverify.md`，包含：
- 每条分支 bitgen 命令 + 退出码 + 时长
- bitstream / elf / hex SHA256（重烧前 vs 后）
- xsct/JTAG 烧录命令 + 退出码
- UART capture 文件路径 + 关键 PASS marker 行号
- commit hash（fresh evidence push 后）
- 任何 fallback 命令（给用户在正确环境跑）

---

## 4. 输出格式（你的最终 deliverable）

### 4.1 执行 summary 表

| 分支 | BLOCKER | HIGH | MEDIUM | LOW | 重烧结论 | 仍需用户介入？ |
|---|---|---|---|---|---|---|
| main | N | N | N | N | N/A | YES/NO |
| main-fpga-e203-alpha | N | N | N | N | YES/已自动重烧/失败 | YES/NO |
| arm-conv | N | N | N | N | YES/已自动重烧/失败 | YES/NO |
| e203-conv | N | N | N | N | YES/已自动重烧/失败 | YES/NO |

### 4.2 完整 finding 表（按 severity 倒序）

每条 finding：
- ID（F001 / F002 / ...）
- Severity（BLOCKER / HIGH / MEDIUM / LOW）
- Branch
- File:line
- 现象（1-2 句）
- 根因
- 修复方式
- **是否已自动修**（YES → commit hash；NO → 阻碍原因）
- 对 RTL bug：必须有"仿真激励"段（无激励 = 标"疑似误报"不修复）

### 4.3 修复 commit 全表

每条修复的 commit：分支 / hash / 文件清单 / 一句话改了什么。

### 4.4 FPGA 重烧决策表 + 实际执行结果

| 分支 | 重烧决策 | 实际执行 | bitstream 旧 SHA → 新 SHA | UART capture 文件 | 关键 PASS marker | 重烧 commit hash |
|---|---|---|---|---|---|---|
| main | NO | N/A | N/A | N/A | N/A | N/A |
| alpha | YES | done / failed-need-user | …→… | doc/main-fpga-e203/uart_capture_20260503_reset_sync_reverify.txt | FPGA_E203_BOOT_UART_PASS @ line N | <hash> |
| arm-conv | YES | … | … | … | ARM_FPGA_DEMO_LENET5_PASS @ line N | <hash> |
| e203-conv | YES | … | … | … | FPGA_V2_E203_LENET5_PASS @ line N | <hash> |

### 4.5 误报候选清单

对照 CLAUDE.md FP-001 ~ FP-005 + FP-006 + 本 prompt §5.1 的 FP-007，列出所有疑似
但已排除的误报候选。

### 4.6 Round 1 closure 复审 verdict

- ✅ Round 1 closure 仍然成立（regression 全 PASS + frozen tag 仍正确 + doc 仍 self-consistent）
- ⚠ Round 1 closure 部分成立（哪些 closure commit 需要本轮补救）
- ❌ Round 1 closure 失效（哪些需要 revert）

### 4.7 Final closure verdict

明确给出（**hard gate**）：
- ✅ 4 条支线本轮完全闭合（0 BLOCKER / 0 HIGH / 0 MEDIUM / ≤ 3 LOW + 全 sim PASS +
  全 FPGA reverify PASS + closure 复审 ✅）
  → **进 paper handoff 模式**，不再生成下一轮 prompt
- ⚠ 部分闭合（列出哪些子项必须用户介入）→ 给用户具体 fallback 命令
- ❌ 闭合失败（列出原因 + 自己再尝试一轮 fix-on-sight）

### 4.8 Paper handoff guidance（**仅 verdict = ✅ 时输出**）

如果本轮闭合，提供：
1. 论文 claim 红线（哪些数字 / marker 是 evidence-backed 可写的）
2. source-of-truth evidence 优先级（指向具体 evidence 文件）
3. 论文不要声称：本轮之后又做了 fresh board run（如果 reverify 没真做的话）
4. frozen tag 维护规则（forward-only `git commit -s`）

---

## 5. FP（误报）模式提醒

### 已入库 FP（CLAUDE.md + round 1/2 加的）

- **FP-001**：`$signed()` + `<<<` 链报告前必须读完整赋值链 + 对照 SV LRM §6.24.1
- **FP-002**：报告位宽不足前必须查 `snn_soc_pkg.sv` 实际值 + 算 `$clog2`
- **FP-003**：FSM 地址 `+/-` 报告前必须区分阻塞 / 非阻塞赋值时序
- **FP-004**：边界条件报告前必须先确认是否已在文档定义为合法
- **FP-005**：CDC 报告前必须确认模块真有多个时钟域
- **FP-006**：annotated tag SHA vs peeled commit SHA 混淆——比对 frozen tag 必须
  用 `<tag>^{}` deref

### 5.1 FP-007 候选（本轮新增，待你审查后入库）

**误判描述**：报告 reset_sync 引入了某个时序问题，但实际是 TB 没适配 reset 释放
晚 2 拍

**识别规则**：报告 reset_sync 引入功能性问题前，先确认：
1. 该问题是否在 reset 释放后立即出现（还是后续 inference 阶段）
2. TB 是否有写死"reset 释放后第 N 拍开始观察 X"的硬假设
3. 如果 TB 假设过紧，应该改 TB 的 wait cycle 数（+2），不是 revert reset_sync

任何报告 reset_sync 相关 regression 前必须排除 FP-007。

### 5.2 FP-008 候选（本轮新增，待你审查后入库）

**误判描述**：报告"reset_sync 让某个长 inference run 的 cycle 数变了 2，板验
sample N 输出和 round 1 evidence 不一致"

**识别规则**：reset 释放晚 2 拍只影响**启动时序**，不影响**已稳定 inference 的功能
正确性**。如果 sample 输出 byte-exact 不一致，**不是** reset_sync 的问题，是
真功能 bug。如果 sample 输出 byte-exact 一致但 cycle 数差 2，那是预期 — 在
重烧 evidence 里更新 cycle 数即可，不要 revert。

---

## 6. 必须做的命令（举证 — 不接受"凭直觉"）

每个 finding 都要附**可重复的命令**。模板：

```bash
# 1. Frozen tag deref（FP-006 防呆）
for tag in $(git tag); do
    obj_sha=$(git rev-parse $tag)
    obj_type=$(git cat-file -t $tag)
    if [ "$obj_type" = "tag" ]; then
        peeled=$(git rev-parse $tag^{})
        echo "annotated $tag: wrapper=$obj_sha peeled=$peeled"
    else
        echo "lightweight $tag: commit=$obj_sha"
    fi
done

# 2. byte-mask invariant
git diff <baseline>..HEAD -- rtl/top/v2b_axi_wrapper.sv rtl/top/snn_soc_v2b_top.sv \
    | grep "<= req_wdata"

# 3. cosim SHA recompute
sha256sum python_multilayer/results_conv/lenet5_fashion/sample_*_output_counts.txt

# 4. cross-branch consistency
diff <(git show main:doc/02_reg_map.md) <(git show main-fpga-e203-alpha:doc/02_reg_map.md)

# 5. Frozen 参数 grep
grep -rn "NUM_INPUTS.*=" rtl/ | grep -v "= 64\|=64"

# 6. async input sweep (Agent A 用)
grep -rEn "input.*\b(uart_rx|spi_miso|cim_done|adc_data|gpio)" rtl/

# 7. PROG_CTRL magic 数 grep (Agent D 用)
grep -rn "PROG_CTRL = 0x" fw/

# 8. DCO compliance
git log --since=2026-05-02 --pretty="%H %s" | while read hash subject; do
    git log -1 --pretty="%b" $hash | grep -q "Signed-off-by:" \
        || echo "$hash MISSING DCO: $subject"
done
```

---

## 7. 你不能做的事

- ❌ 不可移动 frozen tag
- ❌ 不可 force-push
- ❌ 不可 rebase 已 push 的 commit
- ❌ 不可在没读完 CLAUDE.md + §1.6 + §2 的情况下报 bug
- ❌ 不可输出 "全部都很好" — 4 条分支 + 新加 ~600 行 RTL + 新加 5 个文件，
  几乎不可能 0 finding。如果真的 0 finding，再审一次（往 LOW 找）
- ❌ 不可 `git commit` 不带 `-s`
- ❌ 不可假装做了 board reverify（如果实际跑不了 vivado / xsct）

---

## 8. 时间预算

- Sub-agent 并行运行：~3-5 小时
- bitgen × 3 分支（如都需重烧，可并行）：每条 ~1-2 小时
- xsct + UART capture：每条 ~10-20 分钟
- Synthesize + 写 final report：~1 小时
- **总 ETA：5-8 小时**

如果你这台机器跑不了某些步骤（vivado / ZCU102 不在线），**列入 finding 给出
具体 fallback 命令** 让用户在正确环境跑，**不要假装做了**。

---

## 9. 用户元目标（理解 audit 严苛度的来源）

用户准备：
1. 流片 V1（main）— pre-tape-out 不容许 RTL bug；reset_sync 是核心受益者
2. 投 SCI Q4 论文 — 数据 / doc / git history 必须 self-consistent
3. 写硕士毕业论文 — 工程素养 + reset_sync 是面试 / 答辩"你考虑过 metastability 吗"
   的硬证据
4. 让 V2.B CONV extension 的 ablation 经得起 reviewer 推敲

**Round 2.5 MERGED 是为 paper handoff 做最后一道全维度质保**。本轮如果干净，
直接进 paper handoff，不再有下一轮 audit；本轮如果有未闭合项，列出来由你 / 用户
共同收尾。

---

## 10. 终止条件 / 下一轮 prompt 决策

满足以下**全部**条件 → 进 paper handoff，不生成下一轮：
- 0 BLOCKER + 0 HIGH + 0 MEDIUM + ≤ 3 LOW
- 4 条支线全 sim regression PASS（Agent F sweep 全绿）
- 3 条 FPGA 支线 board reverify PASS（Agent H 完成 + UART capture commit）
- Round 1 closure 复审 = ✅
- 7 个 sub-agent 全部明确报"无新 BLOCKER/HIGH/MEDIUM 发现"

不满足 → 生成 `doc/GPT_audit_prompt_2026_05_03_full_4branch_round3_final_sweep.md`，
内容 = 本轮未闭合项的清扫 prompt。

---

## 11. 最后

跑吧。Spawn 7 个 sub-agent，don't wait。

本轮 deliverable：
1. §4.1 ~ §4.8 完整报告
2. 所有修复 commit 已 push origin
3. 所有 reverify evidence 已 push origin
4. final closure verdict（✅ paper handoff / ⚠ 部分闭合 / ❌ 失败）
5. 如未闭合，下一轮 prompt 内容（inline 输出，让用户 copy）

不要留尾巴。本轮就是终极一次性收口审查。

---

**END OF ROUND 2.5 MERGED PROMPT — copy this whole file into a new GPT-5.4 (effort=xhigh) cold-start chat**
