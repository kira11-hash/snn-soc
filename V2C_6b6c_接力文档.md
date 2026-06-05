# V2C Part 6b/6c 接力文档（HANDOFF，2026-06-05）—— 给新对话冷启动用

> 喂给新对话：让它直接 `Read ~/dev/snn-soc/V2C_6b6c_接力文档.md`（本文件），再按 §1 跑一遍测试确认环境。
> 本文件是 **6b/6c（Python 建模 + 精度攻坚）阶段的权威接力**，覆盖本阶段所有来龙去脉、代码、数据、Codex 审、战略判断、下一步。
> 更早的入口/计划在 `V2C_接力文档.md`（§7/§9 已部分更新但已被本阶段超越）、`plan-v1.md`、`V2C_设计决策与权衡记录.md`、`python_multilayer/v2c/PROGRESS.md`（执行进度表，最细）。
> 自动记忆（从 ~/Desktop/soc 启动会加载）：`snn_soc_project.md`、`v2c_ttfs_training_pivot.md`、`env_local_machine.md`、`feedback_git_commit_milestones.md`。

---

## 0. 一句话项目 + 标准指令 + 协作风格（必记）

- **项目**：用户的 SNN/CIM 芯片项目（repo `~/dev/snn-soc`，分支 `asic-v2b-noe203-base`）。当前做 **V2C 论文线**：**数字二值 0T1R RRAM-CIM + TTFS** 加速器，目标灌一篇 **Q4 SCI**。与已验证的 V2.B（ARM-FPGA evidence）**并行、不得破坏**——V2C 全 fork 新建。
- **★ 最高指令**：一切决策朝 **"极致压榨 PPA"**（面积/功耗/延迟）。accuracy 够用即可。
- **★ 战略定位（本阶段联网调研 + 实测得出，很重要）**：**accuracy 不是 V2C 的胜负手**（受单宏 256 列 + W=4 约束，打不过更大的全精度网；90%+ 的 TTFS 论文是**纯仿真无硬件**）。V2C 该主打的赢面轴 = **① 非理想鲁棒性**（数字二值 cell + 1-bit sense + 无 ADC → 抗器件 variation；模拟多比特 CIM 在这点崩）**② 延迟**（TTFS 单脉冲早停，RTL/FPGA 可测）**③ 无-ADC 能效**（定位故事，projected）。**单脉冲稀疏 = 能效+延迟+神经形态身份的共同源头。**
- **协作风格**：用户用中文、要简洁；技术深、是认真的硬件/RTL/ASIC 工程师，可直说、可有理有据 push back。Codex 审核质量高但**仍要独立判断、不盲从**（本阶段就驳回过 Codex 的一个误报，见 §6）。
- **★ git**：每取得阶段性成果/突破就 **commit**（只加相关文件，别 `git add -A`）。**push 在 agent 环境跑不通**（HTTPS remote `github.com/kira11-hash/snn-soc`，非交互 shell 读不到凭证 → `could not read Username ... Device not configured`）→ **commit 本地即可，push 让用户自己来**。
- **文档常被用户/Codex 外部并行编辑** → 每次 Edit 前先 `Read` 拿最新文本。

---

## 1. 环境（一定用对，否则白费）

- **本机系统/brew python 的 pip 坏**（libexpat/pyexpat 缺符号）。**只用 `~/dev/snn-soc/.venv-v2c`**：py 3.12.13 + numpy 2.4.6 + pytest 9 + **torch 2.12.0 + torchvision 0.27.0（MPS 可用）** + pip 正常。
- **跑全部 v2c 测试**（当前 **155 passed**）：
  ```
  cd ~/dev/snn-soc && ./.venv-v2c/bin/python -m pytest -q -p no:cacheprovider python_multilayer/v2c/
  ```
- **装包**：`./.venv-v2c/bin/python -m pip install <pkg>`。别用系统/brew python（pip 挂）。
- 数据集 `python_multilayer/v2c/_data/`（torchvision 首次下载缓存）+ `__pycache__` + `.venv-v2c/` 都已 gitignore。
- 训练在 MPS 上跑，一个配置（含 matched ANN）约 5–10 分钟。

---

## 2. 当前状态总览（headline）

- **代码**：V2C Python 层完成，**155 pytest 绿**。本地已 commit 4 次（见 §7），**未 push**。
- **精度（Fashion-MNIST W=4，golden 部署数）**：
  ```
  68%   二值 TTFS 输入（起点）
  78.8  多比特(ramp/bit-serial)输入 ← +11pp 唯一大突破
  79.8  + 温和 KD(α=0.2)
  81.25 + init-from-matched-ANN     ← 最佳，golden 部署、延迟≈0
  ─────
  86.84 公平上界(bias=False,1-bit 隐层 ANN)；act_hi=2.0 时 87.29
  ```
- **★ 结论**：SNN **卡在 ~81%**，且与 teacher 质量/init 细节**脱钩**（teacher 87.05→87.48，SNN 纹丝不动）。剩 ~6pp 是 **surrogate-gradient TTFS 训练的结构性硬骨头**，需训练范式重写（研究级、回报不确定）。**accuracy 攻坚已到实际极限。**
- **下一步（强烈建议）**：转**非理想鲁棒性 demo**（§8）——真正能赢的轴。用户当前正在此决策点（继续啃 6pp vs 转鲁棒性）。

**复现最佳配置**：
```
cd ~/dev/snn-soc && ./.venv-v2c/bin/python python_multilayer/v2c/train_spiking.py \
  --dataset fashion_mnist --W 4 --T 16 --epochs 50 --input-mode ramp --in-bits 4 \
  --fire-frac 0.5 --init-from-ann --kd-alpha 0.2
```

---

## 3. 技术叙事（这一阶段的完整来龙去脉，理解全靠这段）

### 3.1 原计划被证伪
接力文档原计划：训 graded ReLU 量化 ANN proxy → 阈值校准折叠 → 跑 TTFS forward。**证伪**：量化 ANN proxy 86.7%，但导出权重跑真实 `forward.py` ≈ **随机 10%**，扫任何全局阈值乘子都救不回。**根因 = TTFS-IF 动力学**：① 膜电位均值为负 → per-neuron 阈值多为负 → membrane 从 0 起即过阈、**t=0 秒发**；② 带符号权重 → 膜电位**非单调** → "首脉冲是否发放" ≠ "最终膜电位 ≥ 阈值"。**光靠阈值校准救不了。**

### 3.2 转向：surrogate-gradient 在真实 TTFS-IF 动力学里直训
`spiking.py`：用替代梯度（`SpikeFn` fast-sigmoid/SuperSpike）在**与 `forward.py` 同语义**的可微 TTFS-IF forward 里直训。
- **整数精确膜（bit-exact）**：训练发放判据用**整数膜** `mem_i = x@w_int`（fp32 精确表示整数，W≤4/in≤4 时 < 2^24），`mem_i ≥ θ_int` 与 golden 整数比较 **bit 一致**（`test_hidden_fire_decisions_bit_exact_with_golden` 锁 hidden 100%）；梯度走平滑的 `mem_q - thr_eff`（STE 组合 `s = s_hard + (sg - sg.detach())`）。
- **threshold-QAT**：`mem_train = scale ⊙ mem_inf`（per-output LSQ scale 从整数 MAC 提出），故 `fire(mem_train≥θ_train) ⟺ fire(mem_inf≥round(θ_train/scale))`；训练即用部署整数阈值 `θ_eff = scale·round_ste(θ/scale)`。导出每输出**整数**阈值寄存器，**推理零 BN/零乘法**（PPA-clean）。
- 首结果（二值 TTFS 输入）：Fashion W=4 部署 **64.5%**。

### 3.3 ★ 二值输入天花板（根因 #2）
**单二值脉冲输入把灰度只编进 timing**，CIM 的膜电位求和 = `Σ 二值spike·权重` **只看到二值**（像素是 128 还是 255 贡献一样）→ 等于喂二值化（黑白）图 → 精度封在 **~65-68%**（= 二值化图 MLP）。**所有训练 tweak 全失败**：ETTFS-init / WS（与 W=4 量化冲突，标准化后量化塌成 ±1）/ 数据驱动阈值 / T=32（更差）/ 更深 ablation 网（更差）/ 温度-only loss（更差）。

### 3.4 ★★ 突破：多比特（ramp / bit-serial）输入
`spiking.encode_ramp`：把像素量化成 N-bit、**每 timestep 重复喂入** → 第一层膜电位 `membrane(t) = (t+1)·(xq @ W)` = **完整灰度 MAC**。
- **硬件等价**（数字 CIM 标准做法，cell 仍二值）：bit-serial 输入 = N 个 bit-plane 相位 + `2^k` shift-add（`Σ_k 2^k·encoding.mac(bitplane_k)` == `xq @ w_int`，`test_ramp_bitserial_equivalence_and_golden` 锁定）。隐层/输出维持**单脉冲 TTFS**（保稀疏/延迟/身份）。
- **PPA cycle 口径**（重要，写论文用）：优化实现 = 先算一次 `z=xq@W`（`input_bits` 相位）+ 本地 ramp `T` 次寄存器加/比较，**不是** `T×input_bits×stripes`。
- 结果：Fashion W=4 **78.8%**（+11pp）。`in-bits=8`/`W=8` 反而更差（训练受限，**in4/W4 是甜点**）。
- BNN 依据：1-bit 隐层 + 高精度第一层能到 ~87%（第一/末层对量化最敏感，BNN 都保留高精度）。

### 3.5 精度-隐层精度 Pareto + 7pp gap
`model.V2CMLP` 加 `input_bits`/`act_bits` 激活量化，量 ANN 上界（Fashion W=4 40ep）：
```
float-in/float-act 88.25；4-bit 输入几乎零损失 88.20；
4-bit-in × act {4-bit 88.14 / 2-bit 87.90 / 1-bit 87.15(bias=True), 86.84(bias=False)}
```
→ **隐层精度几乎不影响精度（hybrid 多比特隐层只 +1pp，不值得——会砍掉稀疏/headline）**。
→ **★ 关键 open problem：1-bit 隐层 ANN ≈ 87%，但 spiking 方案 A 只 80%，差 ~7pp 全是 surrogate-TTFS 训练开销，不是架构**（ramp 下 spiking 隐层 `(t+1)z1≥θ` 数学上 ≡ 二值阈值 `z1≥θ/T`，应能到 87%）。

### 3.6 闭合 7pp 的尝试（全记录，别重做）
| 杠杆 | 结果 |
|---|---|
| **multi-bit 输入** | 68→78.8 ✓✓ 唯一大赢 |
| 温和 KD α=0.2 | +1pp → 79.8 ✓ |
| **init-from-matched-ANN** | → **81.25 ✓**（训匹配 1-bit ANN→拷 weight/log_scale 初始化+蒸馏，`--init-from-ann`，Codex/NatComm-2024 路线）|
| KD α=0.5 | -2pp ✗（静态 teacher 过强压坏时序）|
| in-bits=8 / W=8 | 75.5 / 74.3 ✗（训练受限）|
| membrane-focus（beta_mem↑） | 78/75 ✗ |
| ETTFS-init / WS（单独） | 更差 ✗ |
| T=32 / 更深 ablation 网 | 更差 ✗ |
| hidden-occurrence 蒸馏 `--hidden-kd` | 79.1 ✗（init 已对齐权重，蒸馏只扰动时序；**注：修过一个梯度=0 的 bug**，见 §6）|
| act_hi grid（ANN 端） | ANN 86.84→**87.29**（act_hi=2.0 最优，白拿+0.45pp）✓，但 SNN 不跟 ✗ |
| 更强 teacher(87.48) 重 init | SNN 仍 80.5 ✗（**teacher-decoupled 实锤**）|

**剩余路线（研究级、未做）**：temporal rank loss + wrong-early penalty + guard-window eval（Codex 建议）；PACT learnable act clip / staged QAT（只抬 ANN 参考数、SNN 不跟）；常数 bias row（PPA 友好 ablation，ANN bias 只值 0.3pp，存疑）。

---

## 4. 代码地图（`python_multilayer/v2c/`，纯 fork、不碰 V2.B）

**底层 golden（Part 1–5，已审）**：
- `encoding.py` — 三套权重编码（W=1 BNN / W=2 ternary / W≥4 对称两补，最负码保留不发）+ 数字-CIM `mac`(popcount/shift-add)。纯 numpy、bit-exact golden。
- `ttfs.py` — TTFS 输入编码（像素→首脉冲时间，`encode_pixel_to_ttfs`/`ttfs_times_to_stream`/`ttfs_stream_to_times`，`NO_SPIKE=-1`）。
- `forward.py` — 单/多层 TTFS-IF golden（`ttfs_layer_forward` 早停、`ttfs_classify` 最早+tie-break(早停步膜)+fallback(argmax 最终膜)、`multilayer_ttfs_forward`）。**注意：`mac` 要求二值输入**（ramp 多比特走 `convert.eval_ttfs_ramp`，见下）。
- `data.py` — MNIST/Fashion/KMNIST loader（784 uint8 + labels）。

**量化 + 模型**：
- `qat.py` — `quantize_weight`(per-tensor baseline，保留不动) + **`lsq_quantize_weight`(per-output LSQ，对称两补、梯度缩放 1/√(in·qmax)、STE)** + `suggested_lsq_scale` + `_round_ste`/`_grad_scale`。
- `model.py` — **`QuantLinear`**（权重 + per-output **softplus** scale `log_scale`（防负 scale 死区）+ 可选 bias + `weight_standardize` option + `effective_weight()`；spiking 复用其权重）；**`V2CMLP`**（量化 ANN 参考/teacher，**非部署路径**；`input_bits`/`act_bits`/`act_hi` 激活量化 + `hidden_acts()` 取二值隐层激活作蒸馏目标）；`make_mlp`。`_quant_unsigned` STE。

**★ 部署路径（spiking）**：
- `spiking.py` — **`V2CSpikingMLP`**（部署模型）：`SpikeFn`(替代梯度) / `encode_stream`(单脉冲 TTFS) / **`encode_ramp`(多比特 ramp 输入)** / `_layer_spikes`(整数精确膜 + 单脉冲掩码 + force-fire + **fp32 bound 守卫**) / `_effective_thresholds`+`export_int_thresholds`(threshold-QAT，**θ_int≥1 钳位**) / `init_thresholds_from_data`(数据驱动阈值,数值稳定 softplus 逆 `y+log(-expm1(-y))`) / `_ettfs_init`(opt) / `forward(return_hidden=)`(返回 earliness/整数膜/可微 mem_loss/首脉冲;return_hidden 时additionally 返回隐层发放余量供蒸馏) / `ttfs_loss`(earliness CE + membrane CE,membrane per-sample 标准化防溢出) / `hard_classify`(监控,匹配 ttfs_classify) / `per_layer_first_times`(测试用)。
- `train.py` — **参考 ANN 训练器**（`train_model`：AdamW(scale/bias 不 WD,`log_scale` 已正确在 no_decay) + cosine + label smoothing + 平移增广 + EMA + 可选 KD；`input_bits`/`act_bits`/`act_hi`/`bias` 参数）。**非部署路径。**
- `train_spiking.py` — **spiking 训练 + golden 验证**。CLI flags：`--input-mode {ttfs,ramp}` `--in-bits N` `--fire-frac F`(数据驱动阈值) `--beta-mem` `--force-fire` `--ws` `--ettfs-init` `--decode-gamma` `--kd`/`--kd-alpha` `--init-from-ann`(训匹配 1-bit ANN→拷权重+蒸馏,默认 ann_act_hi=2.0/bias=False) `--hidden-kd`(隐层发放蒸馏)。训练循环含梯度裁剪(max_norm=5,SNN BPTT 稳)。ramp 模式自动跑 `eval_ttfs_ramp` golden。
- `convert.py` — 导出 + golden 桥：`export_v2c_layers`(读学习整数阈值→`(cells,W,out,θ)`) / `images_to_streams` / **`eval_ttfs`**(二值 TTFS golden) / **`eval_ttfs_ramp`**(多比特 ramp golden：第一层 `Σ_k 2^k·mac(bitplane_k)` bit-serial + ramp TTFS 隐层 + golden 输出)。

**测试**：`test_{encoding,ttfs,forward,data,qat,model,convert,spiking}.py`，155 passed。关键：`test_hidden_fire_decisions_bit_exact_with_golden`(hidden 100% bit-exact)、`test_spiking_matches_golden_forward`(pred≥0.95)、`test_ramp_bitserial_equivalence_and_golden`(独立 shift-add 参考)、`test_fp32_membrane_guard_raises_unsafe_config`。

---

## 5. 关键概念速查（新对话理解用）

- **为什么 naive ANN→TTFS 失败**：TTFS-IF 动力学（膜均值为负→θ≤0 秒发；非单调→首脉冲≠最终膜）。→ 必须 surrogate 直训。
- **二值输入天花板**：单二值脉冲 → 灰度只在 timing、membrane 求和二值 → ~65-68%。→ 多比特 ramp 输入捅破。
- **ramp 输入 = bit-serial 多比特**：`xq` 每步重复 → `(t+1)·z1` = 完整灰度 MAC；硬件 = bit-plane 相位 + shift-add，cell 仍二值。第一层是 full MAC，隐层/输出维持单脉冲 TTFS。
- **整数精确膜 + threshold-QAT** → 训练发放判据与 golden **bit 一致**（仅 W≤4/in≤4 安全，fp32<2^24，守卫会对 W8/in8 报错）。
- **init-from-ann**：matched 1-bit 隐层 ANN(W4/in4/act1/bias=False/act_hi=2.0) → 拷 weight/log_scale 初始化 spiking + KD → 81.25%（当前最佳）。
- **延迟≈0 的由来**：ramp 在 t=0 第一拍 `membrane(0)=z1` 就是完整灰度 MAC，好的 init 让它秒判且准（硬件实际延迟 = input_bits 相位 + 少数 cycle）。

---

## 6. Codex 审核记录（两轮 + 调研，本阶段）

**协议**：每个 part 出 Codex prompt（背景+规格+重点核查+P0/P1/P2+只读不改）→ 用户回贴 → **逐条独立判定采纳/驳回**（高质量但不盲从）→ 修 → 复验。

**第二轮 Codex 审（已全修，commit `1ac1970`）**：
- P0 ramp golden TBD → **已实现** `eval_ttfs_ramp` + bit-serial 等价测试。
- P0 fp32 整数膜对 W8/in8 越界 → 加 **bound 守卫**（越界 `ValueError`，非静默丢位）。
- P1 softplus 阈值可导出 0 整数阈值 → **θ_int≥1 钳位**（export + effective）。
- P1 ramp 80% 只是训练 hard_classify、非 golden → 实现 golden 后已是部署数。
- P2 测试只验形状、文档旧数 → 加 bit-serial 等价/fp32 守卫测试 + 文档同步 153→155。

**第三轮 Codex 调研报告（精度方向，部分采纳）**：
- ✓ **act_hi grid**（白拿 +0.45pp，已做，act_hi=2.0 最优）。
- ✓ bias 公平性（已查：bias=False ANN 86.84，gap 是真训练开销、非 bias）。
- ✗→已驳 **`log_scale` no-decay "bug" 是误报**：`"log_scale".endswith("scale")` = True，本就正确在 no_decay。
- 推荐但未做（研究级/SNN 不跟）：PACT / staged QAT / teacher-assistant KD / constant bias row / temporal rank loss + guard-window。
- ✗ hidden-occurrence 蒸馏：Codex 强推，但实测无效（init 已对齐；**期间修了一个真 bug**：`spikes.sum` 梯度因单脉冲掩码伸缩相消为 0 → 改用**发放余量 `mem_q-thr_eff` + BCEWithLogits**，梯度才流，但仍不涨）。
- 战略：Codex 同意"别正面拼 90%+ 纯仿真精度，主打鲁棒性/无ADC/延迟"。

---

## 7. Git 历史（本地，未 push）

```
55020ea v2c: hidden-distill + act_hi grid; SNN plateaus ~81% (gap is training, not teacher)
659a22c v2c: init-from-matched-ANN gap-closer -> Fashion W4 golden 81.25%
1ac1970 v2c: address Codex review (ramp golden, fp32 guard, θ>=1, bit-serial tests)
11ff636 v2c: Python golden + surrogate-grad TTFS spiking + multi-bit input
344d0cf config5: ...（V2.B 旧 commit，分界）
```
push 受限（见 §0）。新里程碑继续 commit（只加 `python_multilayer/v2c/` 相关 + `.gitignore` + V2C 文档）。

---

## 8. ★ 下一步：非理想鲁棒性 demo（强烈建议的主线）

**为什么**：accuracy 不是胜负手（§0 战略）；鲁棒性是数字二值 CIM **by-design 稳赢**、审稿人最买账、可现在就在 Python 做的轴。
**怎么做**：
1. 给 golden（`forward.py`/`encoding`/`convert`）加**器件非理想注入**：stuck-at-0/1、read bit-flip（按 on/off+噪声+阈值推导的 read-BER）、write-fail。plan 里本有注入逻辑设想（LFSR/ROM mask）。
2. 拿训好的 SNN（init-from-ann 81.25% 那个），跑 `eval_ttfs_ramp` 在不同故障率下 → 画 **accuracy-vs-故障率曲线**。
3. **对比模拟 CIM 的脆弱**：用 NeuroSim（=传统模拟 ADC-based CIM 的 benchmark 工具，**仿不了我们的 TTFS 数字加速器，只能当模拟基线**）或文献数，证明"数字二值 + 1-bit sense + 无 ADC → variation 来了几乎不掉，模拟多比特 CIM 会崩"。
4. 一张图 = 一个 by-design 的 win。
**其他可选**：三数据集(MNIST/Fashion/KMNIST) sweep；T sweep；ramp golden 的 PPA cycle/energy 计数；ANN 参考数抬到 ~88(PACT/staged QAT，只助参考)。

---

## 9. Gotcha / 红线（别踩、别重做）

- **不碰 V2.B**：`topologies.py`、`cim_program_ctrl.sv`、`trainer_multilayer.py`、`forward.py` 之外的 V2.B 文件。V2C 全 fork。
- **部署路径是 `spiking.py`（V2CSpikingMLP），不是 `model.V2CMLP`**（后者是量化 ANN 参考/teacher）。
- **别重做这些无效杠杆**（§3.6 表）：in8/W8、membrane-focus、hidden 蒸馏、hybrid 多比特隐层、ETTFS-init/WS 单独、T=32、更深网。
- **fp32 整数膜只对 W≤4 + in_bits≤4 安全**（守卫会对越界报错）；要 W8/in8 得改 int64 golden。
- **ramp 多比特输入的 golden 是 `convert.eval_ttfs_ramp`**（`forward.py` 拒非二值输入）。
- **编辑文档/代码前先 Read**（外部并行编辑频繁）。
- **真实性红线**：标 `Python Sim./RTL/FPGA/DC/Estimate/Device-Cite`，不混仿真与实测；缺数据写 TBD。full-frame vs 早停部署、训练 hard_classify vs golden 要标清。
- **Codex 高质量但要独立判断**（本阶段驳回过 log_scale 误报）。
- **90%+ 在单宏纯 FC 784-246-10 下不现实**（ETTFS 89.3% 用 784-400-400-10）；别为精度去加层/加宽（破 PPA/headline）。

---

## 10. 新对话接手第一步

1. `Read` 本文件 + `python_multilayer/v2c/PROGRESS.md`（最细执行进度）。
2. 跑测试确认 **155 passed** + 环境 OK（§1 命令）。
3. 看 `spiking.py`/`train_spiking.py`/`convert.py`/`model.py` 了解部署路径 + flags。
4. **跟用户确认方向**：当前在决策点——（a）转**非理想鲁棒性 demo**（§8，强烈建议）还是（b）继续啃 ~6pp accuracy（研究级 temporal recipe，回报不确定）。用户倾向需确认。
5. 取得成果就 commit（§0 git 规则）。
