# Paper Handoff Summary — V2.B SNN SoC（2026-05-04 收口）

> **用途**：paper / 简历 / 答辩 / handoff 同事的**单点真相**。所有可引用的
> evidence-backed claim 都列在本文件 §1-§3；任何不在本文件里的数字都**不允许**
> 引用到对外材料（包括 paper、简历、答辩 PPT、handoff doc）。
>
> **状态**：4 条分支 round 3/4 全部闭合（含 alpha round 4 no-reburn rationale）
>
> **冻结时点**：本文件以 2026-05-04 各分支 HEAD 为 source-of-truth；后续如有改动
> 必须 forward-only 更新本文件，**不重写历史**。

---

## 1. Evidence-backed claims（可对外引用）

按可信度从高到低排序。每条 claim 都附 source-of-truth 文件路径 + commit hash，
任何引用必须能追溯到这些文件。

### 1.1 **板验 byte-exact**（最高可信度）

| Claim | 数值 | Source-of-truth |
|---|---|---|
| Fashion-MNIST 14×14 FC SNN（V2.B baseline）at ZCU102 ARM Cortex-A53 path | 10/10 sample byte-exact match Python integer reference | `feature/v2-arm-fpga-demo-conv` `doc/arm-fpga-demo/uart_capture_20260503_round4_r404_reverify.txt`（含 `ARM_FPGA_DEMO_LENET5_PASS`）|
| Fashion-MNIST 14×14 FC SNN at ZCU102 E203 RISC-V path | 10/10 sample byte-exact match | tag `v2-fpga-e203-passed @ e696dc39`（peeled commit）|
| LeNet-5 MNIST 28×28 CONV SNN at ZCU102 ARM path | 10/10 sample byte-exact match | `feature/v2-arm-fpga-demo-conv` `doc/arm-fpga-demo/uart_capture_20260503_round4_r404_reverify.txt` 后 1325 行原始 UART trace + `ARM_FPGA_DEMO_LENET5_PASS` |
| LeNet-5 MNIST 28×28 CONV SNN at ZCU102 E203 RISC-V path | 10/10 sample byte-exact match | `feature/v2-fpga-e203-conv` `doc/v2-fpga-e203/uart_capture_20260503_round4_r404_reverify.txt` + `FPGA_V2_E203_LENET5_PASS` |

### 1.2 **训练精度（10000 张 test set）**

| # | 网络 / 数据集 | 拓扑 | 关键配置 | 训练精度 | 路径状态 |
|---|---|---|---|---|---|
| 1 | Fashion-MNIST 14×14 FC baseline | 196 → 64 → 10 | T=64, ADC=10b, 4-bit signed [-7,+7] | **82.38%** | ✅ 板验 byte-exact（双 CPU 路径）|
| 2 | MNIST 14×14（同 #1 拓扑跨 dataset） | 同上 | 同上 | **96.48%** | 同 RTL 路径不重烧（bit-exact 已被 #1 板验证明）|
| 3 | LeNet-5 MNIST 28×28（CONV path） | 5 层 LeNet-5 | T=10, ADC=8b, 4-bit signed | **93.03%** | ✅ 板验 byte-exact（双 CPU 路径）|
| 4 | Fashion-MNIST 28×28 FC | 784 → 64 → 10 | T=64, ADC=10b, 4-bit signed | **84.05%** | Python ideal matmul，未板验（V2.B FC tile_mode=1 multi-tile 路径未整合）|
| 5 | LeNet-5 Fashion-MNIST 28×28 | 同 #3 | 同 #3 | **81.99%** | sim cosim bit-exact PASS（同 #3 RTL 路径，仅换 weight + input fmap），不重烧 FPGA |

Source: `doc/19_training_accuracy_summary.md`（4 条支线均有，content byte-exact 一致）+
`python_multilayer/results_*/*/summary.txt`（per-row provenance）

### 1.3 **T-extension trade-off（2×3 矩阵）**

| Network | Dataset | T=10 (baseline) | T=30 (sweet spot) | T=50 (plateau) | Cosim SHA |
|---|---|---|---|---|---|
| LeNet-5 | MNIST 28×28 | 93.03% | **93.55%** (+0.52 pp) | 92.81% (−0.22 pp) | T=10 board-verified；T=30 `45273d4b...`；T=50 `aa1c3328...` |
| LeNet-5 | Fashion-MNIST 28×28 | 81.99% | **82.88%** (+0.89 pp) | 81.94% (−0.05 pp) | T=10 `d952f218...`；T=30 `f5ed9923...`；T=50 `5ea55159...` |

**关键发现（论文叙事用）**：T=30 是**普适 sweet spot**（+0.5~0.9 pp），T=50 在两个
dataset 都掉头。T-extension 不是 Fashion 的解药；4-bit 量化栈才是。

Source: `doc/19_training_accuracy_summary.md` §5；`doc/v2-architecture/conv_extension_log.md` §2.1ter

### 1.4 **量化栈天花板特征化（quantization-stack ceiling）**

V2.B 4-bit weight + T=10/64 + 8/10b ADC 在 3 个 dataset 上的天然天花板：
- MNIST：~93-96%（V2.B 栈仍有头部空间）
- Fashion-MNIST：~82-84%（撞天花板，不论 FC 还是 LeNet-5）
- CIFAR-10：~13%（M5 主动收兵）

CIFAR-10 plateau 不是 contribution，是 limit reporting。

Source: `doc/v2-architecture/conv_extension_log.md` §2.2；`doc/19_training_accuracy_summary.md` §2.3

### 1.5 **Pre-tape-out CDC hardening**（V1 main）

| Claim | Source |
|---|---|
| async-assert / sync-release reset 同步器（reset_sync.sv，STAGES=2）+ 通用 2-FF metastability 同步器（sync_2ff.sv，参数化 WIDTH） | `rtl/sys/reset_sync.sv` + `rtl/sys/sync_2ff.sv` |
| 单元 TB 覆盖：T1 async-assert / T2 sync-release latency / T3 sub-cycle glitch / T4 repeated cycles + STAGES=3 / WIDTH=1/4/16 | `tb/reset_sync_tb.sv` `RESET_SYNC_TB_PASS` + `tb/sync_2ff_tb.sv` `SYNC_2FF_TB_PASS` |
| chip_top + V2 wrappers 全 SoC 都用 sync'd reset；下游所有 always_ff 0 残留 raw rst_n | `rtl/top/chip_top.sv` + `rtl/top/v2b_arm_demo_top.sv` + `rtl/top/snn_soc_v2b_e203_top.sv` |
| 全 RTL async input sweep 无漏审入口 | round 3 Agent H 报告 |

---

## 2. Source-of-truth evidence 优先级

### 2.1 各分支 HEAD（2026-05-04 冻结点）

| 分支 | HEAD | 角色 |
|---|---|---|
| `main` | `8e6a6135` | V1 SNN SoC 主线，pre-tape-out |
| `main-fpga-e203-alpha` | `3dd977d0` | V1 main 的 FPGA 镜像（除 FPGA-specific 外与 main 字节级一致）|
| `feature/v2-arm-fpga-demo-conv` | `ca30bd8a` | V2.B CONV extension + ARM 板验 |
| `feature/v2-fpga-e203-conv` | `b0138fbb` | V2.B CONV extension + E203 板验 |

### 2.2 Frozen tags（peeled commit，**永不可移**）

| Tag | Peeled commit | 含义 |
|---|---|---|
| `v2-fpga-e203-passed` | `e696dc39` | FC baseline E203 路径板验 |
| `v2-arm-fpga-demo-v2-passed` | `03a39a61` | FC baseline ARM 路径板验 |
| `v2-permanent-gate-2026-04-25` | `3e8905c0` | 永久 byte-mask invariant 回归门禁 |
| `v2-arm-fpga-demo-conv-passed` | `dabcaf0d` | CONV extension ARM 板验（M7 closure）|
| `v2-fpga-e203-conv-passed` | `a1c0c828` | CONV extension E203 板验（M7 closure）|

⚠ 引用 tag 时**必须**用 `git rev-parse <tag>^{}` deref 后的 peeled commit SHA，**不许**
用 `git rev-parse <tag>` 直返的 annotated tag wrapper SHA（FP-006 防呆）。

### 2.3 Per-claim source-of-truth 文件清单

| Claim 类型 | Source 文件 |
|---|---|
| 板验 evidence | `doc/main-fpga-e203/uart_capture_20260503_round3_postfix_reverify.txt`（alpha；含 round4_no_reburn_rationale.md 解释覆盖关系）<br>`doc/arm-fpga-demo/uart_capture_20260503_round4_r404_reverify.txt`（arm-conv）<br>`doc/v2-fpga-e203/uart_capture_20260503_round4_r404_reverify.txt`（e203-conv）|
| 训练精度 | `python_multilayer/results_multilayer/*/summary.txt`（FC ablations）<br>`python_multilayer/results_conv/lenet5*/lenet5_golden_manifest.json`（CONV bundles）|
| Cosim bit-exact PASS | `python_multilayer/results_conv/lenet5*/cosim_*_log.txt`（含 `LENET5_COSIM_TB_PASS` marker + `golden_counts SHA = rtl_counts SHA`）|
| Build manifests | `doc/arm-fpga-demo/build_manifest_v2.txt`（ARM）<br>`doc/v2-fpga-e203/build_manifest_lenet5.txt`（E203）|
| 量化栈天花板叙事 | `doc/v2-architecture/conv_extension_log.md` §2.2 + §2.1ter<br>`doc/19_training_accuracy_summary.md` §2.3 + §5 |
| CDC hardening | `rtl/sys/reset_sync.sv` + `rtl/sys/sync_2ff.sv` + `tb/*_tb.sv` |
| Round 3/4 audit chain | `doc/GPT_audit_prompt_2026_05_03_full_4branch_round3_final_closure.md` + `doc/GPT_audit_prompt_2026_05_04_alpha_round4_reverify.md` + `doc/main-fpga-e203/round4_no_reburn_rationale.md` |

---

## 3. 红线（**不能写**）

按"绝对不能 / 谨慎引用"两档分类。

### 3.1 ❌ **绝对不能写**（写了就是 reviewer reject 风险）

| 红线 | 原因 |
|---|---|
| "demonstrates state-of-the-art accuracy" / "best-in-class" / "outperforms TrueNorth / Loihi" | 没做严格 SOTA 对比，体量也不同；Loihi/TrueNorth 是商用 chip 体量，V2.B 是 4-bit 量化 evaluation chip |
| "tested on CIFAR-10" / "supports CIFAR-10" | M5 主动收兵 13% plateau，**不是** contribution |
| `selected_accuracy = 1.0` 当 100% test set 精度 | 它是 10 个 class-first sample 的 byte-exact match 证据，**不是** test set 精度 |
| Quote 任何 T=50 ablation 数字（93.55%以外不要 quote 30，91.94%不要 quote 50） | T=50 在两个 dataset 都是 −0.05~−0.22 pp 负 trade-off |
| "本轮之后又做了 fresh board run" | alpha round 4 没新 reverify（用的是 round 3 postfix capture，详见 round4_no_reburn_rationale.md）|
| "V1 已流片" / "V1 已 tape-out" | V1 main 仍 pre-tape-out；4 条支线全部是 FPGA evidence + ASIC pad-cell 仍 P&R 启动前 |
| "本工作是首个 RRAM CIM SNN" 类创新声明 | RRAM CIM SNN 是已有方向，V2.B 卖点是 runtime-configurable FC/CONV scheduling + dual-CPU bit-exact validation |

### 3.2 ⚠ **谨慎引用**（写之前必须配对照才不误导）

| 数字 | 谨慎引用方式 |
|---|---|
| Fashion 14×14 = 82.38% | 单独 quote 危险（reviewer 会问"为什么这么低"）。**必须**配 #2 MNIST 14×14 = 96.48% + #4 Fashion 28×28 FC = 84.05% 一起出现，论证是 quantization-stack-ceiling 不是路径瓶颈 |
| Fashion 28×28 FC = 84.05% | 必须说明"Python ideal matmul，未板验"，作为 #1 的 ablation 旁证（证明不是 14×14 下采样的锅）|
| LeNet-5 Fashion = 81.99% | 必须配 #3 MNIST = 93.03% 一起出现，论证 quantization stack 在两个任务上的天然差距 |
| T=30 Fashion = 82.88% | 必须配 T=10 81.99% + T=50 81.94% 一起出现，论证 T-extension 不是 Fashion 的解药 |
| 任何"selected_accuracy" 字段 | 必须改写成"10/10 (or N/M) sample byte-exact match Python integer reference"，**不要**quote 0.9/1.0 数字 |

---

## 4. 推荐论文 contribution 主线

按 paper / 简历 / 答辩三种场景分别给样例措辞。

### 4.1 论文 contribution（4 段）

> "We present V2.B, a runtime-configurable streaming-stage SNN accelerator
> integrated with an RRAM CIM macro on a 1×1 mm digital die. V2.B's contributions
> are: (1) a single stage_engine MAC unit serving both flat fully-connected and
> 5-layer LeNet-5 CNN inference paths, switched at runtime by a 1-bit
> `cfg_conv_mode` register; (2) dual-CPU FPGA validation on ZCU102 with both an
> ARM Cortex-A53 (PS) and an E203 RISC-V (PL soft-core) achieving 10-of-10 sample
> byte-exact agreement against a Python integer-reference engine, on Fashion-MNIST
> 14×14 (82.38%, FC baseline) and MNIST 28×28 (93.03%, LeNet-5); (3) a
> characterization of the V2.B quantization-stack ceiling (4-bit weights, 1-bit
> spikes, 8/10-bit ADC, T=10/64) across MNIST (~93-96%), Fashion-MNIST (~82-84%),
> and CIFAR-10 (~13% plateau, structurally below stack capacity), with
> T-extension ablation (T=10/30/50 sweep) showing T=30 as a universal sweet spot
> with diminishing return at T=50; (4) pre-tape-out CDC hardening including
> async-assert / sync-release reset synchronizers and 2-FF metastability
> synchronizers on all asynchronous pad inputs, validated by 4 unit TBs and
> 13-sub-agent multi-round audit chain."

### 4.2 简历表述（2 句）

> "Designed and FPGA-prototyped a runtime-configurable SNN accelerator (V2.B);
> demonstrated bit-exact end-to-end inference on Fashion-MNIST 14×14 (82.38%, FC)
> and 5-layer LeNet-5 CNN on MNIST 28×28 (93.03%) under 4-bit weight, 8/10-bit
> ADC, T=10/64 hardware-friendly constraints; verified on ZCU102 with ARM
> Cortex-A53 + E203 RISC-V dual CPU paths."

### 4.3 答辩高频追问 + 安全答案

| 答辩老师可能问 | 准备答案 |
|---|---|
| "你这个流过片吗？" | "V1 已 frozen feature-complete，pre-tape-out 严苛度审核完成（含 round 1/2/3/4 audit chain + reset_sync CDC fix），准备 Q4 流片；V2 是 FPGA prototype evidence。" |
| "为什么 Fashion 才 82%？" | "V2.B 4-bit weight + T=64 + 1-bit spike + 8/10b ADC 量化栈在 Fashion 这种 texture-heavy 任务上的天然天花板，配合 #2 MNIST 同拓扑 96.48% + #4 Fashion 28×28 84.05% + #5 LeNet-5 Fashion 81.99% + T-sweep 形成 quantization-stack-ceiling 三角证据，证明不是路径或架构问题。" |
| "为什么 CIFAR-10 不行？" | "M5 主动收兵 ~13% plateau。诚实记录在 conv_extension_log §2.2，不当 contribution 写。这是 V2.B 量化栈在 CIFAR 级 dataset 上的天然边界，需要 v3 stack（wider weights + longer T + higher ADC）才能突破。" |
| "你这个怎么证明 reviewer 信你的数字？" | "5 条 evidence chain：(1) UART capture 抓的真实板上 trace；(2) Python integer reference 公开（python_multilayer/snn_engine_conv.py）；(3) Cosim PASS marker + golden/RTL SHA 字节相等；(4) 4 条支线 git history + DCO Signed-off-by；(5) 13-sub-agent multi-round audit chain（round 1→2→3/4→alpha补单）封存在 doc/GPT_audit_prompt_*。" |

---

## 5. 引用规则（每次对外引用必须遵守）

1. **任何数字必须可追溯**到 §2.3 source-of-truth 文件清单的具体路径
2. **任何 commit hash 必须 peeled commit**（不许 quote annotated tag wrapper SHA）
3. **任何 board-verified claim 必须**指向具体 UART capture 文件 + 行号 + PASS marker
4. **任何 cosim bit-exact claim 必须**带 `golden_counts SHA = rtl_counts SHA` 对子
5. **本文件 §3 红线写过的措辞绝对不许出现**在 paper / 简历 / 答辩 PPT / handoff doc

---

## 6. 后续维护

- 本文件冻结时点：2026-05-04，4 条支线 HEAD = §2.1 表
- 后续 ablation 增补：在 §1 + §2 表末尾追加，**不重写历史行**
- 任何 v3 工作（graded spike / multi-bit weight / longer T 等）：另起新 paper /
  新 doc，**不在本文件内 mutate** 已封存的 V2.B 数字
- 下一轮 audit（如有）：基于本文件 §2.1 HEAD 做 forward-only

---

## 7. 收口声明

V2.B SNN SoC 项目从 2026-04-30 round 1 audit 启动到 2026-05-04 alpha round 4
no-reburn rationale 收口，共完成：

- ✅ Round 1 全 4 分支 audit（含 closure commit）
- ✅ Round 2 全维度审查 + 12 finding fix-on-sight
- ✅ Round 3 13-sub-agent 全维度收口（含 CDC + Python parity + RTL bug + fw 深度
  + doc 全套 + TB coverage + reproducibility）
- ✅ Round 4 续审 + 4 条支线 fix commit
- ✅ alpha round 4 no-reburn rationale（独立验证 4 个 claim 全通过）
- ✅ 4 条分支板验 evidence 完整链
- ✅ 5 个 frozen tag 全 peeled 正确
- ✅ DCO Signed-off-by 全签

**Paper handoff 启动条件已全部满足**。下一步是写 paper draft + 简历 update +
答辩 PPT；本文件 §1-§5 是这些对外材料的唯一引用 source。
