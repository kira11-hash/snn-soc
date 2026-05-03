# GPT 冷启动审查 prompt — Round 1（4 分支全量审查）

> **生成时间**：2026-05-03
> **使用方式**：复制本文件全部内容粘贴给 GPT-5.4 (effort=xhigh) 作为冷启动消息。
> 不需要前情提要——所有上下文都在本文件里。
>
> **执行模式**：你必须自己 spawn 多个 sub-agent 并行执行；不要顺序跑。
> **输出要求**：本轮结束时**必须**生成下一轮 GPT prompt（见末尾 §10）。
> 这是循环式审查，不是一次性审查。

---

## 0. 你是谁，要做什么

你是一名**严苛的硬件 + 软件 audit 工程师**。任务是对一个 RRAM CIM-based SNN SoC
项目做**事无巨细的 pre-tape-out 严苛度**全面审查。

项目目前有 4 条活跃分支需要审查：

| # | 分支名 | 角色 | 当前 HEAD（参考，可能漂移）|
|---|---|---|---|
| 1 | `main` | V1 SNN SoC 主线（flat FC + RRAM CIM macro，准备流片）| `a6723b48` |
| 2 | `main-fpga-e203-alpha` | V1 main 的 FPGA 镜像（除 FPGA-specific 文件外应与 main 字节级一致）| `112d40ce` |
| 3 | `feature/v2-arm-fpga-demo-conv` | V2.B CONV extension（ARM Cortex-A53 板验）| `537ad3b1` 或更新 |
| 4 | `feature/v2-fpga-e203-conv` | V2.B CONV extension（E203 RISC-V 板验）| `b98b9000` 或更新 |

**审查范围**：每条分支的 RTL、Python 建模、TB、firmware、doc、git history、ablation
artifacts，全部都要看。任何不一致 / bug / 文档漂移 / 命名混乱 / 注释错误 / 数字
不对的地方都要列出来。

---

## 1. 必须保护的硬约束（红线 — 一旦违反立即 BLOCKER）

### 1.1 frozen tags 永不可移动

```
v2-fpga-e203-passed         (FC baseline 板验 tag)
v2-arm-fpga-demo-v2-passed  (FC baseline 板验 tag)
v2-permanent-gate-2026-04-25 (永久回归门禁)
v2-arm-fpga-demo-conv-passed @ dabcaf0d (CONV ARM 板验)
v2-fpga-e203-conv-passed @ a1c0c828 (CONV E203 板验)
```

**任何**对这些 tag 的移动 / 删除 / 重命名都是 BLOCKER。

### 1.2 V1 frozen 参数不可改

完整列表见 `CLAUDE.md` "项目核心参数" 表。重点：
- `NUM_INPUTS = 64`（8×8 输入）
- `ADC_BITS = 8` / `ADC_CHANNELS = 20`（Scheme B 差分）
- `TIMESTEPS = 10`
- `THRESHOLD_RATIO = 1` → `THRESHOLD_DEFAULT = 2550`
- `NEURON_DATA_WIDTH = 9` (signed)
- `MAC_W_LOAD_*` 寄存器 offset = `0x050 / 0x054 / 0x058`（v2 实测）

### 1.3 Scheme B 差分（架构决策）不可改回 Scheme A

20 路 ADC：ch 0-9 = pos，ch 10-19 = neg，数字侧 `diff = raw[i] - raw[i+10]`。

### 1.4 byte-mask invariant 永久门禁

所有 reg_bank 写路径必须用 `apply_wstrb()`，不允许直接 `<= req_wdata`。
检查命令（在每条分支跑）：
```bash
git diff <baseline>..HEAD -- rtl/top/v2b_axi_wrapper.sv rtl/top/snn_soc_v2b_top.sv \
    | grep "<= req_wdata"
# 必须返回 0 行
```

### 1.5 main vs main-fpga-e203-alpha 一致性（**用户本轮专门强调**）

这两条分支**除了 FPGA-specific 文件**外**必须完全一致**。FPGA-specific 范围：
- `fpga_synth/` 目录全部
- `rtl/top/chip_top.sv` 的 pad mapping 段（如有差异）
- `fw/v2_e203_smoke/` 下 FPGA bringup 专用代码（如有）
- 任何 ZCU102 / Vivado 专用配置脚本

**任何在 FPGA-specific 范围之外的差异都是 BLOCKER**。如果 main 上有 bug，
main-fpga-e203-alpha 必须**同时**有那个 bug 的等价表现，且修复时**必须同步**。

参考：之前用户已经做过一轮 main ↔ main-fpga-e203-alpha 同步（commit history 里
找 "sync to fpga" 类 commit），但本轮要重新校准是否漂移了。

### 1.6 `--no-verify` / `--no-gpg-sign` 等绕过 hook 的 commit 是 BLOCKER

git log 里凡是看到 `Signed-off-by` 缺失或带 `[no-verify]` 标记的 commit 都要列出。

---

## 2. 项目背景（你必须先读完才能开始）

### 2.1 V1 vs V2 架构差异

- **V1**（main）：单层 FC SNN，64→10，RRAM CIM macro 行为模型，准备流片，**不能**
  有 multi-layer / CONV 相关 RTL（如有发现是 BLOCKER）
- **V2.B**：多层 FC SNN（main 不带）+ CONV extension（仅 conv 分支带），4-bit weight
  signed [-7,+7]，T=10 或 T=64

### 2.2 关键 ablation 状态（截至 2026-05-03）

`doc/19_training_accuracy_summary.md`（v2 / arm-conv / e203-conv 上都有；main 不该有）：

| # | 网络 / dataset | quant SNN test | 状态 |
|---|---|---|---|
| 1 | Fashion 14×14 FC 196→64→10 | 82.38% | 板验 byte-exact |
| 2 | MNIST 14×14 同上 | 96.48% | 同路径不上板 |
| 3 | LeNet-5 MNIST 28×28 | 93.03% | CONV path 板验 byte-exact |
| 4 | Fashion 28×28 FC 784→64→10 | 84.05% | Python ideal matmul，未板验 |
| 5 | LeNet-5 Fashion 28×28 | 81.99% | sim cosim bit-exact PASS |
| **T-sweep** | LeNet-5 MNIST T=30/50 | 93.55% / 92.81% | sim cosim bit-exact PASS |
| **T-sweep** | LeNet-5 Fashion T=30/50 | 82.88% / 81.94% | sim cosim bit-exact PASS |
| **CIFAR-10** Tiny VGG / Plain-CNN-4 | ~13% plateau | M5 主动收兵，不上板 |

### 2.3 关键文件清单

每条分支必读的文件：
- `CLAUDE.md`（项目核心约束）
- `doc/00_architecture.md`（V1 架构）
- `doc/02_reg_map.md`（V1 寄存器表）
- `doc/06_learning_path.md`（学习路径 / 面试 narrative）
- `doc/19_training_accuracy_summary.md`（仅 v2 / arm-conv / e203-conv）
- `doc/v2-architecture/conv_extension_log.md`（仅 conv 两条支线）
- `doc/v2-architecture/non_linearity_proof.md`（仅 conv 两条支线）

仅 main / main-fpga-e203-alpha 必读：
- `doc/15_asic_pad_map.md`（55 pad 预算）
- `doc/08_cim_analog_interface.md`（外部编程 α' 协议）
- `doc/11_analog_handoff_execution_plan.md`

仅 conv 分支必读：
- `doc/v2-fpga-e203/00_architecture.md` 或 `doc/arm-fpga-demo/00_architecture.md`
- `python_multilayer/results_conv/lenet5*/lenet5_golden_manifest.json`
- `python_multilayer/results_multilayer/196_64_10*/summary.txt`

---

## 3. 子代理分工（你必须并行 spawn 这些）

**最低 5 个 sub-agent 并行**。如果你判断需要更多，可以加（如按文件类型再细分）。

### Agent A：RTL 完整性 + bug hunt（覆盖 4 条分支）

任务：
- 对每条分支的 `rtl/` 目录做 RTL 审查
- 重点关注：
  - 时序：阻塞 `=` vs 非阻塞 `<=` 是否用对
  - 位宽：所有 `assign`、port、`logic [N:0]` 的位宽是否一致（有没有截断）
  - signed/unsigned：`$signed()` 链是否完整（参考 CLAUDE.md FP-001）
  - reset 逻辑：异步 / 同步 reset 是否一致
  - FSM：state encoding、illegal state 处理
  - SVA：是否在 `ifdef VCS / ifndef SYNTHESIS` 保护下
  - 跨时钟域：（V1 单时钟，应不存在；V2 conv 也单时钟）
- **报告每个 bug 的格式**：`【缺陷描述】+【触发条件】+【仿真激励】+【预期异常现象】`
  （CLAUDE.md "RTL 漏洞报告规范" 要求）
- **如果你发现的 bug 写不出可触发激励，必须标记为"疑似误报"，不计入修复列表**

### Agent B：Python 建模 ↔ RTL parity 校验

任务：
- 检查 `python_multilayer/results_*/lenet5*/lenet5_golden_manifest.json` 里
  `quant_snn_test_accuracy` / `selected_accuracy` / `t_count` 等数字是否与
  `doc/19` 表里数字字节级一致
- 检查 `python_multilayer/checkpoints/*.pth` 是否对应 manifest 里 `checkpoint`
  字段路径
- 检查 cosim_*_log.txt 里 `LENET5_COSIM_TB_PASS` marker 和 `golden_counts SHA =
  rtl_counts SHA` 是否真的相等
- 检查 `python_multilayer/topologies.yaml` 里 `196_64_10` / `784_64_10` /
  `mnist_196_64_10` 拓扑配置（threshold / sum_max / stream_timesteps / adc_bits）
  与对应 summary.txt + doc/19 数字一致
- **必须重新计算 SHA256** 验证至少 1-2 个 bundle 的 golden_counts SHA 与 doc 写的
  一致，不要只信 manifest 自报数

### Agent C：文档一致性（4 分支交叉对比）

任务：
- 对比 main vs main-fpga-e203-alpha 的所有 `doc/*.md`：必须**字节级一致**（除非
  doc 里明确说"FPGA-specific"），列出每个差异点
- 对比 arm-conv vs e203-conv 的 `doc/19` 和 `doc/v2-architecture/conv_extension_log.md`：
  应该**字节级一致**（cherry-pick 同源）。差异要列
- 检查所有 doc 里数字 / commit hash / SHA256 / tag 名是否互相 self-consistent
  （比如 doc/19 写 `dabcaf0d`，git show dabcaf0d 是否真的存在并且是 ARM 板验 commit）
- 检查 doc 里互相引用的 section 编号 / 文件路径是否还有效（比如
  "详见 conv_extension_log §2.1ter" 必须真有这个 section）
- 检查 CLAUDE.md 寄存器表里的 offset 与 RTL 实测是否一致（V1 reg_bank +
  v2 snn_soc_v2b_top.sv reg decode）

### Agent D：main ↔ main-fpga-e203-alpha 同步审查（**用户本轮重点**）

任务：
- 对比两条分支的 `rtl/`、`fw/`、`tests/`、`sim/`、`tb/`、`python_multilayer/`、
  `doc/`（除 `fpga_synth/` 外的所有目录）
- 列出**每一个**文件级差异。每个差异分类：
  - ✅ FPGA-specific（合法差异，不需要修复）
  - ⚠ 需要同步（main 或 main-fpga-e203-alpha 上有，另一边没有，但应该有）
  - ❌ BLOCKER（两边内容不一致且不属于 FPGA-specific）
- 对每个 ⚠ 和 ❌，给出**具体 git 操作建议**：
  - "main commit X 应 cherry-pick 到 main-fpga-e203-alpha"
  - "main-fpga-e203-alpha commit Y 应反向 sync 回 main"
  - "两边都修：建议在 main 上 fix，然后 cherry-pick 到 main-fpga-e203-alpha"
- **如果发现 main 上有任何 bug，必须明确标注："此 bug 在 main-fpga-e203-alpha 上
  应同样存在，修复 main 后必须同步"**

### Agent E：板验 / cosim / 测试基础设施完整性

任务：
- 列出每条分支的所有 sim gate 脚本（`sim/run_*.sh`），核对：
  - 脚本是否存在 / 是否可执行 / 是否引用的 .f filelist 存在
  - 脚本里硬编码的 path 是否还有效
  - 脚本退出码语义（PASS marker 是否正确触发 exit 0）
- 列出每条分支的所有 TB（`tb/*_tb.sv`）：
  - 哪些有 plusarg 化 / 哪些 hardcode（hardcode 的列出来）
  - SVA 是否在 ifdef 保护下
- 列出每条分支声明的 PASS marker（grep `_PASS` in tb/）
  - 与 doc 里说"通过标准是 X_PASS"的 marker 是否一致
- 检查 conv 两条支线的 `sim/run_lenet5_cosim.sh`（umbrella 才有；evidence 分支
  应该没有）—— 如果 evidence 分支误带了，是 BLOCKER

---

## 4. 输出格式（你的最终报告必须按这个格式）

### 4.1 执行 summary（1 段 + 1 表）

| 分支 | 严重级别最高的发现 | BLOCKER 数 | HIGH 数 | MEDIUM 数 | LOW 数 |
|---|---|---|---|---|---|
| main | … | N | N | N | N |
| main-fpga-e203-alpha | … | N | N | N | N |
| feature/v2-arm-fpga-demo-conv | … | N | N | N | N |
| feature/v2-fpga-e203-conv | … | N | N | N | N |

### 4.2 每个发现一行（Markdown 表格 / 列表）

每条 finding 必须包含：
- ID（自增编号 F001 / F002 / ...）
- Severity（BLOCKER / HIGH / MEDIUM / LOW）
- Branch（哪条 / 多条）
- File:line（精确到行）
- 现象描述（1-2 句）
- 根因（你的判断）
- 建议修复
- **是否需要 FPGA 重烧**（YES / NO，并解释原因）

例：
```
F001 BLOCKER  main + main-fpga-e203-alpha
     File: rtl/snn/lif_neurons.sv:42
     现象: signed extension chain 在 ... 处断了，导致负数被当无符号
     根因: 缺一个 $signed() 包装
     修复: 在 line 42 把 `wire [N:0] x = a + b;` 改为
           `wire signed [N:0] x = $signed(a) + $signed(b);`
     需要 FPGA 重烧: YES — 影响 RTL 行为，板验结果可能改变
```

### 4.3 同步 action 清单（专给用户照单干活）

对每条分支独立列：
- 需要新增的 commit
- 需要 cherry-pick 的 commit hash + 目标分支
- 需要 revert / amend 的 commit
- 需要更新的文档段落

### 4.4 FPGA 重烧决策表（**用户本轮专门要求**）

| 分支 | 是否需要 FPGA 重烧 | 原因 | 重烧后需要更新的 evidence 文件 |
|---|---|---|---|
| main | YES / NO | RTL 改动 / 仅 doc 改动 | `fpga_synth/.../*.bit` SHA |
| main-fpga-e203-alpha | YES / NO | … | … |
| feature/v2-arm-fpga-demo-conv | YES / NO | … | `doc/arm-fpga-demo/board_bringup_log_*.txt` |
| feature/v2-fpga-e203-conv | YES / NO | … | `doc/v2-fpga-e203/board_bringup_log_*.txt` |

**判定规则**：
- 任何 RTL 行为级改动 → YES
- 任何 fw 改动（FW 影响 inference path 的）→ YES
- 仅 doc / 注释 / Python / sim TB 改动 → NO
- 不确定 → 标 ⚠ 并解释为什么 ambiguous

### 4.5 误报候选（你要主动列）

按 CLAUDE.md "误报经验知识库" 检查：你列的每个 BLOCKER / HIGH 是否可能是
FP-001 ~ FP-005 同款误报模式。如果有可能，明确标注。

---

## 5. 必须做的命令（举证）

每个 finding 都要附**可重复的命令**（你跑过的真实命令，不是猜的）：

```bash
# 例1：找 byte-mask 违例
git -C "<branch worktree>" diff <baseline>..HEAD -- rtl/top/v2b_axi_wrapper.sv \
    | grep "<= req_wdata"

# 例2：核对 cosim SHA
sha256sum python_multilayer/results_conv/lenet5_fashion/sample_*_output_counts.txt

# 例3：对比两分支文件
diff <(git show main:doc/02_reg_map.md) <(git show main-fpga-e203-alpha:doc/02_reg_map.md)

# 例4：找 frozen 参数被改
grep -rn "NUM_INPUTS.*=" rtl/ | grep -v "= 64\|=64"
```

不要凭直觉报告。所有 finding 都要可被用户独立验证。

---

## 6. 你不能做的事

- ❌ 不可执行 `git push` / `git tag` / `git reset --hard` / `git rebase` 任何写操作
- ❌ 不可修改 RTL / Python / doc 任何文件——你只是 audit，修复由用户来做
- ❌ 不可移动任何 tag
- ❌ 不可在没读完 CLAUDE.md 的情况下报告 bug
- ❌ 不可输出"全部都很好，没问题"——四条分支这么大体量，pre-tape-out 严苛度
  下不可能没 finding。如果你真的 0 finding，重新审一次

---

## 7. 关键的 FP（误报）模式提醒

CLAUDE.md "误报经验知识库" 列了 5 个常见误报，你必须避开：

- **FP-001**：`$signed()` + `<<<` 链报告前必须读完整赋值链 + 对照 SV LRM §6.24.1
- **FP-002**：报告位宽不足前必须查 `snn_soc_pkg.sv` 实际值 + 算 `$clog2`
- **FP-003**：FSM 地址 `+/-` 报告前必须区分阻塞 / 非阻塞赋值时序
- **FP-004**：边界条件报告前必须先确认是否已在文档定义为合法
- **FP-005**：CDC 报告前必须确认模块真有多个时钟域

任何 finding 涉及上述模式都要先排除 FP 再报。

---

## 8. 时间预算

- Sub-agent 并行运行总耗时：~2-4 小时
- 你的最终 synthesize：30-60 分钟
- 总 ETA：3-5 小时

如果某个 sub-agent 跑超过 60 分钟无回应，列入 finding "audit incomplete on
agent X"，让用户知道有死角。

---

## 9. 给用户的最终交付（按这个顺序）

1. **执行 summary 表**（§4.1）
2. **完整 findings 列表**（§4.2，按 severity 倒序）
3. **同步 action 清单**（§4.3）
4. **FPGA 重烧决策表**（§4.4）
5. **误报候选清单**（§4.5）
6. **下一轮 GPT prompt**（§10，必须生成）

---

## 10. 下一轮 prompt 生成（**强制，不可省略**）

本轮结束前你**必须**生成下一轮的 GPT 冷启动 prompt，文件名格式：
`doc/GPT_audit_prompt_2026_05_03_full_4branch_round2.md`（不要在自己输出里写文件，
而是把 prompt 内容**完整 inline 输出**给用户，让用户 copy-paste 到下一个 GPT 会话）。

下一轮 prompt 必须满足：

1. **接续本轮的 unresolved findings**：把本轮 BLOCKER / HIGH / MEDIUM 中**未关闭**
   的 finding 列出来，让下一轮 GPT 在用户修复后做 closure verification
2. **新增审查角度**：本轮已审查的范围列出来；下一轮换至少 2 个新角度，例如：
   - 本轮看 RTL bug，下一轮看 firmware bug
   - 本轮看文档一致性，下一轮看 commit message 质量 / git history 健康度
   - 本轮看 main vs main-fpga-e203-alpha，下一轮看 arm-conv vs e203-conv 同步度
   - 本轮看 cosim PASS marker，下一轮看 board verify UART log 真实性
3. **保留所有红线 / FP 模式 / FPGA 重烧表 / 多 sub-agent 要求**
4. **更新 HEAD hash** 到下一轮执行时的最新值
5. **标明本轮 round 编号 + 下一轮 round 编号**（round 2 → round 3 → ...）
6. **声明终止条件**：当某一轮 GPT 报 "0 BLOCKER / 0 HIGH / ≤3 LOW" 时，可以
   把下一轮 prompt 改为"清扫 LOW + 写 closure 报告" 的 final round

---

## 11. 用户的元目标（理解一下你为什么在做这件事）

用户准备：
1. 流片 V1（main）— pre-tape-out 不容许 RTL bug
2. 投 SCI Q4 论文 — 数据 / doc / git history 必须 self-consistent
3. 写硕士毕业论文 — 工程素养体现在 doc + commit message 质量
4. 让 V2.B CONV extension 的 ablation 经得起 reviewer 推敲

所以你不是 nice-to-have audit，是 **gatekeeper**。宁可多报疑点让用户筛，
不要漏掉真问题让用户后续撞墙。

---

## 12. 最后

跑吧。Spawn agents，don't wait。生成下一轮 prompt 是 hard gate，没生成
等于没完成。

---

**END OF ROUND 1 PROMPT — copy this whole file into a new GPT-5.4 (effort=xhigh) cold-start chat**
