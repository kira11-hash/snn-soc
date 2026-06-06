# V2C Phase A/B/C + RTL 接力文档（HANDOFF，2026-06-06）—— 给新 Claude 对话冷启动用

> **喂给新对话第一步**：`Read ~/dev/snn-soc/V2C_接力文档_PhaseABC-RTL.md`（本文件），再按 §1 跑测试确认环境，再读 `python_multilayer/v2c/PROGRESS.md`（最细执行进度）+ `V2C_RTL进展.md`（RTL+自审）+ `V2C_极致PPA创新点.md`（PPA 创新+大调研）。
> **本文件是 2026-06-06 这一整段（Phase 1 ANN 天花板 → Phase 2 SNN gate-init 翻案 → Phase A 多数据集 → Phase B 鲁棒性 → Phase C RTL 起步 → PPA 创新大调研）的权威接力**，覆盖全部来龙去脉、结论、代码、Codex 审、下一步。
> 更早入口：`V2C_6b6c_接力文档.md`（6b/6c 阶段，已被本段超越但叙事仍有用）、`plan-v1.md`（RTL/SoC/架构权威规格）、`V2C_设计决策与权衡记录.md`。
> **自动记忆**（从 ~/Desktop/soc 启动会加载）：`snn_soc_project`、`v2c_ttfs_training_pivot`（部署 recipe）、`ppa_innovation_logging`（PPA 创新留痕指令）、`env_local_machine`、`feedback_git_commit_milestones`。

---

## 0. 一句话项目 + 标准指令 + 协作风格（必记）
- **项目**：用户的 SNN/CIM 芯片项目（repo `~/dev/snn-soc`，分支 `asic-v2b-noe203-base`）。做 **V2C 论文线**：**数字二值 0T1R RRAM-CIM + TTFS** 加速器，目标 Q4 SCI。与已验证的 V2.B（ARM-FPGA evidence）**并行、绝不破坏**——V2C 全 fork。主网 **784→246→10**（W=4 主线，sweep {1,2,4,8}）。
- **★ 最高指令**：一切决策朝 **"极致压榨 PPA"**（面积/功耗/延迟）。**任何为极致 PPA 的、值得写论文的手段/架构/数据流/调度创新，必须记进 `V2C_极致PPA创新点.md`**（用户 2026-06-06 强指令，见记忆 [[ppa-innovation-logging]]）。
- **★ 战略定位（本段联网调研 + 实测坐实，很重要）**：**accuracy 不是 V2C 胜负手**（单宏 + W4 打不过更大全精度网；raw acc 非 SOTA）。**今天唯一可信的 SOTA-able 轴 = 非理想鲁棒性**（数字二值 cell + 1-bit 数字 sense + 无 ADC → 结构上零暴露于电导 variation/drift/ADC 量化）。**延迟/功耗 headline 需 RTL 综合 + 能耗才能喊**（现在只有算法 timestep、零 µJ/TOPS-W → 不能当实测卖点）。
- **协作风格**：用户用**中文、要简洁**；技术深、是认真的硬件/RTL/ASIC 工程师，可直说、可有理有据 push back。**Codex 审核质量高但仍要独立判断、不盲从**（本段就实证驳回过 Codex 的 log_scale no-decay 误报）。
- **★ git**：每取得阶段性成果/突破就 **commit**（只加相关文件，别 `git add -A`）。**push 在 agent 环境跑不通**（HTTPS remote `github.com/kira11-hash/snn-soc`，非交互 shell 读不到凭证）→ **commit 本地即可，push 让用户自己来**。`doc/arm-fpga-demo/uart_capture_*.txt` 是 V2.B 外部改动、**不是我们的、别碰**。
- **文档常被用户/Codex 外部并行编辑** → 每次 Edit 前先 `Read` 拿最新文本。

---

## 1. 环境（一定用对）
- **本机 brew/系统 python 的 pip 坏**（libexpat）。**只用 `~/dev/snn-soc/.venv-v2c`**（py3.12 + numpy + pytest + torch 2.12 + torchvision 0.27，MPS 可用）。
- **跑全部 Python 测试（当前 167 passed）**：`cd ~/dev/snn-soc && ./.venv-v2c/bin/python -m pytest -q -p no:cacheprovider python_multilayer/v2c/`
- **RTL parity（iverilog 13 + verilator 本地已装）**：`bash sim/v2c/run_cim_mac.sh` / `run_ttfs_layer.sh` / `run_ramp_layer.sh`（各自 bit-exact 对齐 Python golden）。
- **DC（SMIC55nm 库）/ FPGA（ZCU102/Vivado）= 用户在其服务器/硬件跑**；我（Claude）只出 RTL + parity + 脚本。
- 训练在 MPS，单配置约 3.5–10 分钟；鲁棒性/多数据集 sweep 是后台长 job（几十分钟～小时）。

---

## 2. 当前状态总览（headline）
- **Python golden 全完成**（Parts 1–6 + 实验 E0–E11），**167 pytest 绿**。
- **★ 部署 recipe 已翻案定型**（见 §4）：**不是 surrogate spiking 训练**，而是 **解析 gate-init + per-class 输出阈值标定，零 spiking 训练**。
- **Phase A（多数据集精度/延迟，零训练，3 seeds/full 10k）**：MNIST 98.4%@t9.9 / Fashion 87.0%@t12.3 / KMNIST 89.9%@t13.1（准确率模式）+ 早停点 ~5-7 拍更早。**泛化成立。**
- **Phase B（鲁棒性 = SOTA 轴）**：数字故障实测优雅降级（deployed 早停 @2% 故障掉 ~2-3pp、延迟保持低）；analog 基线仅 illustrative、"模拟崩"锚定文献。**3 轮 Codex 审全过。**
- **★ Phase C RTL 起步（进行中）**：3 核心 compute 模块 **bit-exact 对齐 Python golden**（iverilog）。**当前是正确基线、非 PPA-最优**；PPA-最优数据通路（含核心创新）是**下一步**。
- **Codex#4 已发出审核**（`V2C_Codex审查_Phase-C-RTL.md`）——回贴后**逐条独立判定**，再据此落地 PPA-最优 RTL。
- 本地 commit ~30 个（未 push）。

---

## 3. 完整叙事（本段来龙去脉，理解全靠这段）

### 3.1 Phase 1 — 拔高 matched ANN（E0–E6，结论：已到天花板 ~87.4%）
用户选择按 Codex 计划先拔 ANN。结果（Fashion，main/W4/in4/act1/act_hi=2.0，5 seeds，EMA）：**E0 cold 基线 87.21%±0.14**（bias=False）；E3 PACT 持平；E4 staged QAT −0.43；E5 KD −0.18；**E6 bias row(bias=True) 87.37%（+0.16，唯一边际正）**。**E1 log_scale no-decay = Codex 误报，实证驳回**（`"log_scale".endswith("scale")`=True，本就在 no_decay）。→ **ANN 已到天花板 ~87.4%，Codex "QAT 技巧能拔到 88%" 证伪。**

### 3.2 Phase 2 — SNN gate-init 翻案（E7–E10，关键突破）
- **E7（旧路径：fire_fraction 阈值 + surrogate 训练）**：strict 80.45%，full-frame≈strict → gap **不是时序问题**。
- **★★ E8（阈值复现，零训练）**：把 SNN 隐层整数阈值直接设成 **ANN 1-bit gate 等价值** `θ_int=round(T·(act_hi/2)·levels_in/scale)`（推导：`z1_ann=(scale/levels_in)·z1_int`、ANN 隐层发放⟺`z1_ann≥act_hi/2`、ramp SNN 帧内发放⟺`z1_int≥θ_int/T`，联立）。结果：**hidden-gate 100% 吻合、full-frame=87.85%≈ANN**（单 seed）。→ **SNN 架构能完整表达 ANN，~7pp gap 非结构性。** out-scale CV=0.158 但 int-vs-scaled argmax 吻合 98.4%（丢 per-class 输出 scale 只翻 1.6% 决策）。
- **E9（因果消融，gate-init+训练）**：full-frame 掉到 83.30% → **训练损害 full-frame、但拉早发放（延迟优化器）**。→ **标定 > 训练。**
- **★ E10（per-class 输出阈值坐标搜索，零训练）**：`θ_out[k]=round(c_k/scale_out[k])`，坐标下降 max `acc−λ·lat/T`。**single-seed preliminary 87.75%@t11.4 / 84.55%@t7.0；F7 定稿（3 seeds/full 10k）87.03%@t12.3 / 82.21%@t6.4**（preliminary 偏乐观、并列保留在 PROGRESS）。**标定全面压过训练。**

### 3.3 Phase A — 多数据集 × 多 seed（验承重假设）
同一套 gate-init+标定在 MNIST/Fashion/KMNIST 都泛化（§2 数）。验证了"gate-init 复现 ANN / output-scale 近均匀"非 Fashion 特异。

### 3.4 Phase B — 鲁棒性（SOTA 轴，Codex#3 重做）
`robustness.py`：注数字 cell 故障（stuck0/1/invert 静态 + read_ber 非对称，`read_ber_from_device` 从 HRS/LRS 电流+sense 阈值映射）。**两视图**：full-frame + **deployed 早停（冻结 clean 标定 θ_out，故障下 strict 解码，acc+latency 同退化）**。多 seed。**三数据集 @2% 故障 deployed 只掉 ~2-3pp、延迟 t6-9 保持低**（实测优雅降级）。**analog 基线**：修了 ADC oracle full-scale 假象（改 per-output 固定标定+column 项），但 per-weight σ 被 fan-in 平均→太轻→**仅 illustrative/optimistic，"模拟崩"锚定文献**（σ>10%退化、drift 1月 68%→19%、SAF）。

### 3.5 Phase C — RTL 起步（3 模块 bit-exact，见 §6）

### 3.6 PPA 创新大调研（§7）

---

## 4. ★ 部署 recipe（必记，已写入记忆 [[v2c-ttfs-training-pivot]]）
**V2C SNN 部署 = ① 解析 gate-init（隐层整数阈值 = ANN 1-bit gate 等价式 `θ_int=round(T·(act_hi/2)·levels_in/scale)`，100% 复现 ANN 隐层）+ ② per-class 输出阈值标定（坐标搜索 `θ_out[k]=round(c_k/scale_out[k])`，一条 λ 旋钮给整条 latency-accuracy 前沿）+ ③ 零 spiking 训练。**
- surrogate 直训**有害**（训坏 full-frame）→ 别再投。接力文档/旧记忆里"surrogate 直训是部署路径"**已过时**。
- 复现：`experiments.py E8`（诊断）/`E10`（标定 Pareto）/`E11`（鲁棒性）。`train_spiking.gate_threshold_init` = E9 消融用。

---

## 5. 关键结果数（论文用，全标 single-seed/preliminary vs 定稿）
- **ANN 天花板**：~87.4%（Fashion，E6 bias row）。MNIST/KMNIST 见 Phase A。
- **部署 Pareto（3 seeds/full 10k，零训练）**：MNIST 98.36%@t9.9 / Fashion 87.03%@t12.3 / KMNIST 89.85%@t13.1（准确率模式 λ0）；早停 λ0.5：Fashion 82.21%@t6.4 等。
- **鲁棒性 deployed @2% 故障**：Fashion ~82%@t7-8 / MNIST ~94%@t6-7 / KMNIST ~83-86%@t9（4 故障模式，3 seeds）。
- ⚠ **latency 是算法 timestep，非 RTL cycle**；能效零数 → "超低延迟/功耗"现在不能当实测卖点（需 RTL+能耗）。对标 22nm TTFS ASIC（F-MNIST 95.67µJ/30FPS）、E-ReCON（419 TOPS/W）。

---

## 6. RTL 状态（详见 `V2C_RTL进展.md`）
全 fork 在 `rtl/v2c/`，TB `tb/v2c/`，sim 脚本/产物 `sim/v2c/`（build/ 已 gitignore）。**3 模块 bit-exact 对齐 Python golden（理想模式）**：
| 模块 | 文件 | golden | parity |
|---|---|---|---|
| 数字 CIM MAC | `v2c_cim_mac.sv` | `encoding.mac` | W=1/2/4/8+784/W4+边界 |
| TTFS-IF 层 | `v2c_ttfs_layer.sv` | `forward.ttfs_layer_forward` | 18 帧 spike+膜+nsteps |
| ramp 输入层 | `v2c_ramp_layer.sv` | `convert._ramp_hidden_times` | 14 帧 z1+spike（full-frame）|
- **方法**：每模块 Python-golden 向量 parity（`run_*.sh`：gen 向量←golden → iverilog → 比对）+ **严苛自审** + commit。自审抓修了 ramp 层误加 early-exit 的 bug（隐层必须 full-frame）。
- **⚠ 当前是正确基线、非 PPA-最优**：1 输出/cycle 时分复用单 MAC，每 cycle 一个 784 位全 popcount（**关键路径长 fmax 受限、延迟=OUT×T**）。
- `cost.py` 冻结了 SOP + projected_cycle 公式（RTL 对齐用）。
- **剩余 RTL**：多层 top（ramp→ttfs 链，parity vs eval_ttfs_ramp 全程）、非理想注入（LFSR/ROM，理想模式 bit-exact + 故障模式 vs robustness.py）、P&V FSM（fork V2C 版）、`snn_soc_v2c_top`。

---

## 7. ★ PPA 创新（核心，见 `V2C_极致PPA创新点.md` §E；Codex#4 审核中）
**我分 4 路独立并行 subagent 大调研，四路收敛到核心创新**：
- **★ 核心：「双单调 MSB-first 推测首-spike 提交」**——V2C 两重单调性（ramp `membrane(t)=(t+1)·z` 对 t 单调 + bit-serial 部分 popcount 对 slice 单调）→ 每输出一对廉价 `z_lo/z_hi` 上下界，在完整 ramp / 完整 bit-serial MAC 跑完前 **provably 提交赢家（`(t+1)·z_lo≥θ`）或淘汰输者（`(t+1)·z_hi<θ`）**，停剩余计算+门控阵列。**lossless，严格更早出首 spike → 直砍延迟。**
- **支撑**：TTFS fire-once 单调行压缩（神经元发放即死→只算沉默行）、**row-serial column-parallel bit-serial 累加**（解 784-popcount 关键路径，Colonnade 范式，fmax 与 IN_DIM 解耦）、阈值/早停融进累积尾（ITA 式 fusion）、TTFS-spike-order 误差界定的近似 compressor 树、bit-plane 跳零、流水重叠+ping-pong。
- **novelty 诚实判定**：单点全已发表（BitSET/SnaPEA/ComPEND、TFSRAM/TQ-TTFS、ITA、Colonnade、DIMC）——别单 claim；**可发表 delta = 组合 co-design on 数字二值 0T1R RRAM-CIM + TTFS**。最该对标 prior art：**E-ReCON**（3T1R ReRAM spiking 数字 CIM, 419 TOPS/W@65nm，arxiv ID 待核）。
- **必报 worst-case cycle**（数据相关延迟→workload 不均）。
- **Codex#4 prompt（`V2C_Codex审查_Phase-C-RTL.md`）已要求 Codex 也自己分多 subagent 独立调研 + 独立验证/驳斥我的核心创新 + 补更强 idea + 给 RTL 落地路线。**

---

## 8. 代码地图
**Python（`python_multilayer/v2c/`，167 测试）**：
- `encoding.py`（3 codebook + 数字-CIM popcount mac）/`ttfs.py`/`forward.py`（TTFS-IF golden）/`data.py`（3 数据集）/`qat.py`/`model.py`（QuantLinear+V2CMLP 参考 ANN + PACT `_pact_quant`）/`train.py`（参考 ANN 训练，`warm_start_state`、`_param_groups` 排除 alpha）/`spiking.py`（V2CSpikingMLP 部署模型）/`train_spiking.py`（含 `gate_threshold_init`）/`convert.py`（**eval_ttfs_ramp / eval_ttfs_ramp_modes（strict/guard/full-frame）/ ramp_output_trajectories / strict_decode_from_traj / _ramp_hidden_times**）。
- **`experiments.py`**（实验驱动，E0–E11；`_gate_init_snn`、`_calibrate_cvec`、`_theta_of`）：E0–E6 ANN 天花板、E8 gate-init 诊断、E9 因果消融、E10 标定 Pareto（多 seed/`--dataset`）、E11 鲁棒性（多 seed deployed+full-frame+analog，`--dataset/--trials/--analog-only`）。
- **`robustness.py`**（inject_cell_faults / read_ber_from_device / robustness_sweep / deployed_robustness_sweep / analog_reference_sweep）。**`cost.py`**（SOP + projected_cycles）。
- 测试：`test_{encoding,ttfs,forward,data,qat,model,convert,spiking,robustness,cost}.py`。

**RTL**：`rtl/v2c/{v2c_cim_mac,v2c_ttfs_layer,v2c_ramp_layer}.sv`；`tb/v2c/{gen_*_vectors.py, *_tb.sv}`；`sim/v2c/run_*.sh`。

**文档（repo 根）**：`plan-v1.md`（架构权威）、`V2C_RTL进展.md`、`V2C_极致PPA创新点.md`、`V2C_Codex审查_*.md`（4 份）、`python_multilayer/v2c/PROGRESS.md`、`V2C_6b6c_接力文档.md`、`V2C_设计决策与权衡记录.md`、`V2C_RTL_bug记录.md`。

---

## 9. Codex 审核记录（本段 4 轮，协议：出 prompt → 用户回贴 → 逐条独立判定采纳/驳回 → 修 → 复验）
- **#1**（Phase1-2，`V2C_Codex审查_Phase1-2.md`）：ANN 天花板 + gate-init。
- **#2**（Phase2，`V2C_Codex审查_Phase2.md`）：P1.3 eval_ttfs_ramp deeper-net 早停 bug、P2.1 rounding tie、P2.2 阈值断言≥1、frontier 标 observed、latency=算法步非 cycle——**全采纳已修**。驳回 log_scale 误报。
- **#3**（Phase-AB，`V2C_Codex审查_Phase-AB.md`）：**deployed 早停鲁棒性（P1.2，关键）**、多 seed（P1.1）、故障物理拆+read-BER（P1.3）、analog 公平性（P1.4）、SOP/cycle 冻结——**全采纳已做**（G1–G5）。
- **#4**（Phase-C-RTL，`V2C_Codex审查_Phase-C-RTL.md`，**审核中**）：审 RTL + **重点 PPA-最优微架构/创新**（含我 4-subagent 调研综合作参考）+ **要求 Codex 自己也分多 subagent 独立调研**。**回贴后逐条独立判定，再落地 PPA-最优 RTL。**

---

## 10. Git（本地，未 push）
近段 commit（最新在上）：PPA 调研综合 + Codex#4 多-subagent 要求 → PPA 创新文档+Codex#4 修订 → 最终 3 数据集鲁棒性 → 3 个 RTL 模块（cim_mac/ttfs_layer/ramp_layer）→ G5 cost → 鲁棒性 Codex#3 返工 → Phase A/B → E8/E9/E10 → E0–E6。push 受限（§0）。新里程碑继续 commit（只加相关文件）。

---

## 11. Gotcha / 红线（别踩、别重做）
- **不碰 V2.B**：`rtl/snn/`、`rtl/top/snn_soc_v2b_top` 等原地不动；V2C 全 fork（`rtl/v2c/` 等）。uart_capture 外部改动别碰。
- **部署路径 = gate-init + 标定零训练**（§4），别再投 surrogate 端到端训练（已证有害）。
- **别重做无效杠杆**：PACT/staged-QAT/KD（ANN 端无增益）、in8/W8、surrogate 直训抠精度。
- **accuracy 非胜负手**；别为精度加层/加宽（破 PPA/headline）。鲁棒性是 SOTA 轴。
- **latency=算法 timestep ≠ RTL cycle**；能效零数 → 别 over-claim "超低延迟/功耗"（需 RTL+能耗）。
- **RTL parity 红线**：每模块对 Python golden bit-exact（理想模式）+ 严苛自审 + commit。
- **PPA 创新留痕**：任何为极致 PPA 的可发表创新 → 写进 `V2C_极致PPA创新点.md`（[[ppa-innovation-logging]]）。
- **analog 基线仅 illustrative**，"模拟崩"锚定文献，别声称家酿模型是公平对照。
- **DC/FPGA 用户跑**；我出 RTL+parity+脚本。
- **Codex 高质量但要独立判断**（驳回过误报）。**单 seed 数保留**（E8/E9/E10 preliminary 在 PROGRESS）。

---

## 12. 新对话接手第一步
1. `Read` 本文件 + `PROGRESS.md` + `V2C_RTL进展.md` + `V2C_极致PPA创新点.md`（PPA 创新+调研）+ `plan-v1.md`（RTL 架构）。
2. 跑 **167 Python 测试** + **3 个 RTL parity**（§1）确认环境 + 现状。
3. **Codex#4 已判定落地（见 §13 + `V2C_极致PPA创新点.md §F` + commit 6f6ca67/ea13b86）**：P1#3/#4 采纳、P1#1/#2 降 P2、P2#5 采纳；★ **可行性分析否决了"双单调推测"，改选异构 co-design+skip-zero**（别再投双单调 bit-serial 推测）。
4. **下一步 RTL（task #6）= 落地 §F 异构数据通路**：① skip-zero 量化（输入瓶颈主杠杆）② 异构数据通路（dense-input bit-parallel+skip-zero ‖ event-driven output row-serial），parity 保功能不变 ③ 模块4 多层 top（ramp→output 全链 parity vs eval_ttfs_ramp）。再做非理想注入 / P&V FSM / `snn_soc_v2c_top`。
5. DC/FPGA 脚本写好交用户跑。**取得成果就 commit；每完成任务做全面自检；不拘泥旧决定、发现更极致 PPA/更大创新就改；给 Codex 的 prompt 也带这两条**（[[feedback-work-method]]）。

---

## 13. ★ 最新进展（2026-06-06 续）— Codex#4 判定 + 可行性分析 + 异构方案 + 5 条新工作指令
**Codex#4 逐条独立判定（已落地，commit 6f6ca67/ea13b86）**：
- P1#3 cost.py 读宽 256→128（plan P_READ_BITS=128，hidden 8 stripes，原低估 input cycle 2x）= 采纳。
- P1#4 cost.py output cycle 从算法 t_exit 改为 active hidden rows（event-driven）= 采纳。
- P1#1 read_ber device 值只 print 没用 → 加 device 锚点真跑；P1#2 analog calib=eval → 加独立 calib_images = 降 P2 修诚实口径。
- P2#5 parity 加 production 维度 784→246 ramp / 246→10 ttfs（bit-exact、位宽够）= 采纳。
- ⚠ Codex 没按要求自己做独立多-subagent 调研（单源偏差），novelty 对标基本抄我 §3a；E-ReCON ID 也是抄的（我已独立核实，见下）。

**★ 可行性分析（数据驱动，gate-init SNN+真实 Fashion 权重，见 `V2C_极致PPA创新点.md §F`）**：
- **否决"双单调 bit-serial MSB-first 推测"**：输入层 dense（占 99.8% cycle），MSB-first 推测 best-case 平均 14.49/16 bit-plane 才判定、0% 在 4 项内 → 输 bit-parallel 3.6×。输出层稀疏但绝对 cycle 仅 54，推测收益可忽略。lossless 成立（三条件：MSB-first 序 / z1 符号 / tie-break）但不划算。
- **★ 选定方案 = 异构 TTFS-aware 数字二值 0T1R CIM 数据流 co-design**：输入层保持 plan bit-parallel + **skip-zero**（零行省 52.8%、零位上限 73.5%，dense 输入瓶颈唯一大杠杆）；输出层 event-driven row-serial（active rows ~54/246，fire-rate 22%）+ 首-spike 早停 + 决策融进累积尾。
- **诚实再定位**：RTL 延迟瓶颈是 dense 输入层、TTFS 早停只省输出 <1% → "超低延迟"抓手是输入 skip-zero 不是 TTFS 早停；TTFS 稀疏价值在能耗/SOP + 延迟确定性（输入 dense 主导→worst≈mean）。
- **E-ReCON 核实**：arxiv 2605.20717 真实存在（3T1R ReRAM/65nm/419 TOPS/W/AND-mul+10T28T adder tree/CNN+SNN）= related-work 主对标；V2C 差异 = 0T1R+TTFS ramp+无 ADC 鲁棒性+skip-zero。

**★ 用户 5 条新工作指令（已入记忆，硬规则）**：① 每完成任务做全面自检；② 不拘泥旧决定、发现更极致 PPA/更大创新就改；③ 给 Codex 的 prompt 也带 ①②；④ 实验数据/idea/novelty/决策原因都留痕到专门文档；⑤ 汇报用大白话让用户理解。记忆：[[feedback-work-method]] [[feedback-record-keeping]] [[feedback-communication-chinese]]。

**进行中**：基于"输入层 dense 是瓶颈"，分多 subagent 调研 ANN/DNN 加速器/LLM/DL 算法领域可借鉴的极致 PPA 方案（架构/算法/优化），找新创新点。
