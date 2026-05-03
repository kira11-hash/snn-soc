# GPT 冷启动审查 prompt — Round 2（4 分支闭环验证 + 新角度审查）

> **生成时间**：2026-05-03 round 1 closure 之后
> **使用方式**：复制本文件全部内容粘贴给 GPT-5.4 (effort=xhigh) 作为冷启动消息。
> 不需要 round 1 prompt 作为前情——本文件内嵌所有上下文。
>
> **执行模式**：必须 spawn 多个 sub-agent 并行；不要顺序跑。
> **输出要求**：本轮结束时**必须**生成 round 3 prompt（hard gate，详见 §11）。
>
> **本轮与 round 1 的核心差异**：
> - Round 1 是"全量初次审查 + closure"
> - Round 2 是"closure regression verify + 新角度增量审查"
> - 即：先验证 round 1 的 closure 没坏掉，再换 5 个新角度找漏网

---

## 0. 你是谁，要做什么

你是一名**严苛的硬件 + 软件 audit 工程师**。这是 round 2 — round 1 已经把 4 条
分支带到 closure 状态（0 BLOCKER / 0 HIGH / 0 MEDIUM）。本轮目标：

1. **闭环验证** round 1 的 4 个 closure commit 没引入 regression
2. **新角度增量审查**（round 1 已覆盖范围内不重复）
3. **修补 round 1 的已知盲点**（详见 §1.6）
4. 决定项目是否进入 final round（"清扫 LOW + 写 paper handoff 报告"）

---

## 1. 当前 4 条分支状态（Round 1 closure 后）

### 1.1 分支 HEAD（origin / 已 push）

| 分支 | Round 1 closure HEAD | Round 1 commit 主题 |
|---|---|---|
| `main` | `850c3cae` | docs(governance): align DCO and frozen-tag guidance |
| `main-fpga-e203-alpha` | `233db876` | fix(alpha-fpga): preserve PROG_CTRL retry bits and reverify board smoke |
| `feature/v2-arm-fpga-demo-conv` | `d50b7d37` | docs(arm-conv): realign evidence chain and reverify LeNet-5 board path |
| `feature/v2-fpga-e203-conv` | `5cd74ea8` | docs(e203-conv): align evidence chain and reverify LeNet-5 board path |

### 1.2 Frozen tags（**不可移动** — 严格 deref 验证）

| Tag 名 | Annotated tag SHA | Peeled commit SHA | 含义 |
|---|---|---|---|
| `v2-arm-fpga-demo-v2-passed` | `75c200bf` | （deref 自查）| FC baseline ARM 板验 |
| `v2-fpga-e203-passed` | `a6b441e6` | （deref 自查）| FC baseline E203 板验 |
| `v2-permanent-gate-2026-04-25` | `9dbcc797` | （deref 自查）| 永久回归门禁 |
| `v2-arm-fpga-demo-conv-passed` | `49c26a60`（**annotated tag wrapper**） | `dabcaf0d`（**实际 commit，doc 引用此**） | CONV ARM 板验 |
| `v2-fpga-e203-conv-passed` | `d9b14a8d`（**annotated tag wrapper**） | `a1c0c828`（**实际 commit，doc 引用此**） | CONV E203 板验 |

**⚠ 注意**：上面 conv-passed 的两个 tag 是 **annotated tag**。
- `git rev-parse <tag>` 返回 annotated tag object SHA（49c26a60 / d9b14a8d）
- `git rev-parse <tag>^{}` 才返回 peeled commit SHA（dabcaf0d / a1c0c828）
- doc/19 + conv_extension_log + non_linearity_proof 引用的是 peeled commit SHA
- **Round 1 时有 audit 误把 annotated tag SHA 当成 commit SHA，报告"tag drift"**——这是误报
- **Round 2 任何 finding 涉及 tag 对比之前必须先用 `^{}` deref 双方再比较**（详见 §6 FP-006）

### 1.3 Round 1 验收过的 regression（已 PASS，本轮 spot-check 抽样重跑）

```
main:                 sim/run_boot_erase_e2e.sh + sim/run_e203_icarus.sh
main-fpga-e203-alpha: sim/run_fpga_programmable_cim_model.sh
arm-conv:             sim/run_v2b_partial_write_invariant.sh + sim/run_conv_ctrl_v2_unit.sh
                      + sim/run_fw_cosim_resident_14x14.sh + fw/arm/build_arm_firmware.sh
e203-conv:            sim/run_icb2simple_bridge_v2b.sh + sim/run_simple2v2btop_adapter.sh
                      + sim/run_v2_e203_cosim.sh
```

### 1.4 Round 1 触动过的功能性文件（重点 regression 关注）

| 分支 | 文件 | 改动语义 |
|---|---|---|
| `main-fpga-e203-alpha` | `fw/e203_smoke/e203_fpga_smoke.c` | 加 `prog_ctrl_start_preserve_retry()` helper，避免直接写 `PROG_CTRL = 0x07u` 时把 RETRY_LIMIT[10:8] 清零 |
| `main-fpga-e203-alpha` | `fw/e203_smoke/out/*.{bin,elf,hex,dump,map,o}` | 重 build 后的 bring-up smoke firmware 全套 artifacts |
| `main` | `tb/e203_tb.sv` | VCD dump 改 `+DUMP_VCD` opt-in（避免 targeted regression 卡死） |
| `e203-conv` | `tb/v2_e203_cosim_tb.sv` | 同上 VCD opt-in |

### 1.5 Round 1 新生成的 evidence（板级证据，不可丢失）

| 分支 | UART capture 文件 | 用途 |
|---|---|---|
| `main-fpga-e203-alpha` | `doc/main-fpga-e203/uart_capture_20260503_alpha_reverify.txt` | alpha smoke firmware fix 重烧 + 上板 reverify |
| `feature/v2-arm-fpga-demo-conv` | `doc/arm-fpga-demo/uart_capture_20260503_lenet5_reverify.txt` | ARM LeNet-5 reverify（1326 行原始 UART） |
| `feature/v2-fpga-e203-conv` | `doc/v2-fpga-e203/uart_capture_20260503_lenet5_reverify.txt` | E203 LeNet-5 reverify（1325 行原始 UART） |

### 1.6 Round 1 已知盲点（**Round 2 必须补审**）

1. **Annotated tag deref 没做严格区分**——round 1 GPT 报告"frozen tags 没动"是
   对的，但是 round 1 完成后 audit 阶段有人误把 tag wrapper SHA 当 commit SHA，
   报了一个 false-positive "tag drift"。**Round 2 必须显式列 5 个 frozen tag 的
   peeled commit SHA，证明它们与 doc 引用一致**
2. **GPT round 1 在 §6 FPGA 重烧表里把 alpha firmware 改动归到 "doc + manifest"，
   未承认改了 fw/**——实际 233db876 含 `fw/e203_smoke/e203_fpga_smoke.c` 真改动 +
   重 build artifacts。Round 2 应该对所有 closure commit 重新分类（doc-only /
   firmware / RTL / TB / sim / Python），不接受混淆
3. **arm-conv vs e203-conv 跨分支同步度** round 1 没做。Round 1 Agent D 只比了
   main vs main-fpga-e203-alpha；arm-conv 和 e203-conv 共享大量 cherry-pick 内容
   但可能也漂移了
4. **Firmware 整体 audit** round 1 只浅度看了 alpha smoke firmware（因为它被 GPT
   改了）；`fw/arm/`、`fw/v2_e203_smoke/`、`fw/silicon_bringup/`、`fw/include/`
   全部目录 round 1 没系统性审查
5. **CIFAR-10 plateau evidence 审计**——M5 主动收兵的"~13% plateau"声明 round 1
   只在 conv_extension_log §2.2 写了句子，没人核对 plateau 训练 manifest /
   actual training log / 是否真的卡 13%。如果用户写论文 review 这一段，reviewer
   可能要求实际数字
6. **Commit message DCO compliance**——round 1 加了"forward-only `git commit -s`"
   governance（main 850c3cae）；round 2 应该 audit 所有 round 1 之后的 commit 是否
   都带 Signed-off-by

---

## 2. 必须保护的硬约束（与 round 1 相同 — 简版）

完整内容见前一轮 prompt（`doc/GPT_audit_prompt_2026_05_03_full_4branch_round1.md`）。
重点不变：

- frozen tag 只能 forward-only 移动 / 不能删 / 不能改名
- V1 frozen 参数不可改（`NUM_INPUTS=64`、`ADC_BITS=8`、`THRESHOLD_DEFAULT=2550` 等）
- Scheme B 差分不能改回 Scheme A
- byte-mask invariant 永不破：所有 reg_bank 写路径走 `apply_wstrb()`
- main vs main-fpga-e203-alpha **除 FPGA-specific 外完全一致**
- 任何 `--no-verify` / `--no-gpg-sign` 是 BLOCKER
- 不可执行 `git push` / `git tag` / `git reset --hard` / `git rebase`

---

## 3. 子代理分工（**5 个并行**，与 round 1 不重复）

### Agent A：Round 1 closure regression spot-check

任务：
- 对 §1.4 列出的每个 round 1 触动文件，重新跑对应 sim gate（§1.3）
- 对比 PASS marker 是否仍然出现
- 对 main-fpga-e203-alpha 的 firmware 重 build 验证：
  ```bash
  cd "<main-fpga-e203-alpha worktree>"
  bash fw/e203_smoke/build_fpga_smoke.sh  # 或对应的 build 脚本
  diff <(sha256sum fw/e203_smoke/out/e203_smoke.bin) <(git show 233db876:fw/e203_smoke/out/e203_smoke.bin | sha256sum)
  # 必须 byte-exact 一致；不一致说明 firmware build 不可复现
  ```
- **输出**：每个 sim gate / build 步骤一个 PASS / FAIL 行

### Agent B：Annotated tag deref 严格验证（**修补 round 1 盲点 1**）

任务：
- 对每个 frozen tag（§1.2 列 5 个）跑：
  ```bash
  for tag in v2-arm-fpga-demo-v2-passed v2-fpga-e203-passed \
             v2-permanent-gate-2026-04-25 \
             v2-arm-fpga-demo-conv-passed v2-fpga-e203-conv-passed; do
      echo "$tag tag_obj=$(git rev-parse $tag) commit=$(git rev-parse $tag^{})"
  done
  ```
- 对 doc/19 + conv_extension_log + non_linearity_proof 里所有 commit hash 引用，
  逐个对比是否与上面 deref 出的 commit SHA 一致
- 任何不一致都列出来；如果是 doc 漂移就列 "doc 应改为 X"，如果是 tag 真移了就
  列 "tag 应 reset 回 X"
- **关键**：在 finding 里**永远显示**"tag SHA = X" 和 "peeled commit SHA = Y" 两行
  避免和 round 1 一样混淆

### Agent C：arm-conv vs e203-conv 跨分支同步审查（**修补 round 1 盲点 3**）

任务：
- 对比 `feature/v2-arm-fpga-demo-conv` vs `feature/v2-fpga-e203-conv` 所有目录
- 列出每个文件级差异，分类：
  - ✅ CPU-path-specific（合法差异：ARM-Cortex-A53 vs E203 RISC-V，例如 `fw/arm/`
    vs `fw/v2_e203_smoke/`、`doc/arm-fpga-demo/` vs `doc/v2-fpga-e203/`）
  - ⚠ 应同步但漂移了
  - ❌ BLOCKER（两边内容不一致且不属于 CPU-path-specific）
- 对比关键共享文件（应字节级一致）：
  - `doc/19_training_accuracy_summary.md`
  - `doc/v2-architecture/conv_extension_log.md`
  - `doc/v2-architecture/non_linearity_proof.md`
  - 所有 `python_multilayer/results_conv/lenet5*/` 下的 manifest + hex artifacts
- 给出每个差异的修复 git 操作建议

### Agent D：Firmware 全栈 audit（**修补 round 1 盲点 4**）

任务：
- 对每条分支的 `fw/` 目录系统性审查
- 重点关注：
  - 寄存器读写：是否有"直接写整个 reg 但实际只想改部分位"的 bug（参考 round 1
    GPT 抓到的 PROG_CTRL retry bit clobber）
  - W1P (write-1-pulse) 寄存器：是否每次写都 wait DONE 再继续
  - W1C (write-1-clear) 寄存器：是否在 poll 之前 clear 过
  - busy-loop：是否有 timeout 保护（避免 board hang）
  - UART 输出：printf-style 字符串是否有 buffer overflow 风险
  - boot rom / crt0：reset vector / bss clear / stack init 是否完整
- 对每个 fw 文件给出"有 bug / 疑似 bug / clean"的 verdict
- 同样要求"报 bug 必须有 simulate triggerable case"（CLAUDE.md "RTL 漏洞报告规范"
  对 firmware 同样适用）

### Agent E：Round 1 doc closure narrative + CIFAR plateau evidence（**修补 round 1 盲点 2 + 5 + 6**）

任务：
- 重新分类 round 1 的 4 个 closure commit：
  - `850c3cae` (main): 实际是 doc-only / governance-only — 验证
  - `233db876` (main-fpga-e203-alpha): 含 firmware + artifact rebuild — 验证 GPT §6 表是否准确
  - `d50b7d37` (arm-conv): 检查 12 文件，列每文件改动类型
  - `5cd74ea8` (e203-conv): 同上
- **如果 GPT §6 表对 233db876 分类不准确，列为 finding "GPT closure report 漏报
  firmware 改动"**
- CIFAR-10 plateau 证据审计：
  - 找 `python_multilayer/checkpoints/` 下是否有 tiny_vgg / plain_cnn4 ckpt
  - 找训练 log（可能在 `python_multilayer/results_conv/` 或本地临时位置）
  - 验证 conv_extension_log §2.2 声称的 "~13% plateau" 是否有 reproducible 证据
  - 如果找不到证据，报 "CIFAR plateau claim 缺 evidence"，建议重训 1 次记录数字
- DCO compliance 审计：
  - `git log --all --since=2026-05-02 --pretty=%H | xargs -I{} sh -c 'git log -1 --pretty="%H %s%n%b" {} | grep -q "Signed-off-by:" || echo "{} MISSING DCO"'`
  - 列出所有 round 1 之后无 Signed-off-by 的 commit
- **不要重新审 round 1 已审过的 RTL bug / Python parity / doc 一致性**——那些
  Agent C 在跨分支同步审查里会顺带覆盖

---

## 4. 输出格式（与 round 1 同 — §4.1 ~ §4.5）

加 1 项：

### 4.6 Round 1 closure 复审 verdict（必须）

明确给出：
- ✅ Round 1 closure 仍然成立（regression 全 PASS + frozen tag 仍正确 + doc 仍 self-consistent）
- ⚠ Round 1 closure 部分成立（列出哪些 closure commit 需要补救）
- ❌ Round 1 closure 失效（列出原因 + 需要 revert 的 commit）

---

## 5. 必须做的命令（与 round 1 类似，加 1 项）

```bash
# 严格 tag deref 模板（防 FP-006）
for tag in $(git tag); do
    obj_sha=$(git rev-parse $tag)
    obj_type=$(git cat-file -t $tag)
    if [ "$obj_type" = "tag" ]; then
        peeled=$(git rev-parse $tag^{})
        echo "annotated $tag: tag_obj=$obj_sha peeled_commit=$peeled"
    else
        echo "lightweight $tag: commit=$obj_sha"
    fi
done
```

---

## 6. FP（误报）模式 — 加 FP-006

CLAUDE.md 已有 FP-001 ~ FP-005。Round 1 完成后追加：

### FP-006：Annotated tag SHA vs commit SHA 混淆（2026-05-03 round 1 后确认）

- **误判描述**：报告 "frozen tag 已经从 doc 写的 X commit 移到 Y commit"
- **实际情况**：被报"移动"的 Y 其实是 annotated tag object 的 SHA，而 doc 引用
  的 X 是 peeled commit SHA。两者本来就应该不同，因为 annotated tag 是个独立
  object 包装着 commit pointer
- **根本原因**：审计人员用 `git rev-parse <tag>` 而没用 `git rev-parse <tag>^{}`，
  把 wrapper SHA 当 commit SHA 比对
- **识别规则**：报告 frozen tag 移动前**必须**：
  1. `git cat-file -t <tag>` 确认 type 是 `tag` (annotated) 还是 `commit` (lightweight)
  2. 如果是 annotated，必须用 `<tag>^{}` deref
  3. 与 doc 引用的 commit SHA 比较时**永远**比较 peeled commit SHA，不比较 wrapper SHA
- **本误报实例**：round 1 完成后误报 `v2-arm-fpga-demo-conv-passed` 从 `dabcaf0d` 移
  到 `49c26a60`，实际 49c26a60 是 annotated tag wrapper，peeled 仍是 dabcaf0d，doc
  没有漂移

---

## 7. 你不能做的事（与 round 1 同）

- ❌ 不可执行 git push / tag / reset --hard / rebase 任何写操作
- ❌ 不可修改 RTL / Python / doc 任何文件——你只是 audit
  - **例外**：本轮 GPT 在 round 1 时已经做了 fix-on-sight closure；如果用户授权进
    "fix-on-sight" 模式，可以做与 round 1 相同等级的非破坏性修复（doc / manifest /
    TB hygiene / firmware bug fix + 必须重新 build + 板验 + 抓 UART evidence）
- ❌ 不可移动 frozen tag
- ❌ 不可在没读完 CLAUDE.md + round 1 prompt 的情况下报 bug
- ❌ 不可输出 "全部都很好"——4 条分支这么大，绝对会有 LOW finding 或 doc 漂移。
  即使 BLOCKER/HIGH/MEDIUM = 0，LOW 必须 ≥ 5

---

## 8. 时间预算

- Sub-agent 并行运行：~2-4 小时
- Synthesize：30-60 分钟
- 总 ETA：3-5 小时

---

## 9. 给用户的最终交付（与 round 1 同 + 加 §4.6 verdict）

1. 执行 summary 表
2. 完整 findings 列表（按 severity 倒序）
3. 同步 action 清单
4. FPGA 重烧决策表
5. 误报候选清单（特别注意 FP-006）
6. **Round 1 closure 复审 verdict**（§4.6，本轮新增）
7. **Round 3 prompt**（§11，必须生成）

---

## 10. Round 1 → Round 2 → Round 3 终止条件

继续轮转，直到某一轮报告**同时满足**：

- 0 BLOCKER
- 0 HIGH
- 0 MEDIUM
- ≤ 3 LOW
- Round N 闭环 verdict = ✅
- 5 个 sub-agent 全部明确报"无新发现"

满足条件时，下一轮 prompt 应改为 **"final round: 清扫 LOW + 写 paper handoff
报告 + 列 final closure tag 候选"** 模式。

---

## 11. 下一轮 prompt 生成（**强制，不可省略**）

本轮结束前必须生成：
- 文件名格式：`doc/GPT_audit_prompt_2026_05_03_full_4branch_round3.md`
- 内容**完整 inline 输出**到你的最终报告里（让用户 copy-paste 到下一个 GPT 会话），
  不要直接写文件
- 必须更新：
  - 4 条分支当前 origin HEAD（本轮结束时的实际值，可能是 round 1 closure HEAD
    或 round 2 后又新增的 closure commit）
  - 所有 frozen tag 的 peeled commit SHA（用 §5 命令模板算的）
  - Round 2 已覆盖的 5 个新角度列出来
  - Round 3 必须再换至少 2 个新角度，例如：
    - vivado synthesis report (LUT/FF/BRAM utilization) audit
    - python_multilayer/topologies.yaml 全字段 schema validation
    - git history 时间线 / commit 节奏 / 是否有 force-push 痕迹
    - sim/run_*.sh 全部脚本是否能在 clean checkout 上 run（reproducibility）
    - 完整 fpga_synth/ 目录 audit（vivado IP / TCL / constraints）
- Round 3 必须保留所有红线 + FP-001 ~ FP-006 模式
- 标明本轮 round 编号（round 2）+ 下一轮 round 编号（round 3）

---

## 12. 用户元目标（理解 audit 严苛度的来源）

用户准备：
1. 流片 V1（main）— pre-tape-out 不容许 RTL bug
2. 投 SCI Q4 论文 — 数据 / doc / git history 必须 self-consistent
3. 写硕士毕业论文 — 工程素养体现在 doc + commit message 质量
4. 让 V2.B CONV extension 的 ablation 经得起 reviewer 推敲

**Round 2 特定关注**：用户在 round 1 之后明确要求"循环式审查直到无死角"。
本轮要为 paper handoff 做最后一轮严苛拉网。

---

## 13. 最后

跑吧。Spawn agents，don't wait。生成 round 3 prompt 是 hard gate，没生成
等于没完成。

如果你判断 round 2 已满足 §10 终止条件，你的 round 3 prompt **必须**改为
final-round 模式（"清扫 LOW + paper handoff report + 列 final closure tag 候选"）。

---

**END OF ROUND 2 PROMPT — copy this whole file into a new GPT-5.4 (effort=xhigh) cold-start chat**
