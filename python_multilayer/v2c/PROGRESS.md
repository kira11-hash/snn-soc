# V2C Python 层执行进度（Codex-review-per-part 协议）

每个 part：代码 → 本地验证 → 出 Codex 审核 prompt → 你确认 → 标 ✅ done（并回填 `plan-v1.md`）。

| Part | 内容 | 文件 | 本地验证 | Codex 审 | done |
|---|---|---|---|---|---|
| 1 | 权重三套编码/codebook + 数字 CIM accumulator | `encoding.py` `test_encoding.py` | ✅ stdlib + 真 numpy + **独立显式索引 ref**（160+组 + shape/float/empty/越界 guard）| ✅ 已审：P1(shape 广播) + 2×P2(float/测试同源) **全采纳、已修+复验** | ✅ |
| 2 | TTFS 输入编码（pixel→首脉冲时间、times↔stream）| `ttfs.py` `test_ttfs.py` | ✅ **pytest green**（含负向 guard）| ✅ 已审：3×P2(负时间/max_val/异常用例) 全采纳已修 | ✅ |
| 3 | 单层 TTFS-IF forward + 分类（`mac`+膜电位+首spike早停+tie-break+fallback）| `forward.py` `test_forward.py` | ✅ **pytest 65 passed**（forward-vs-ref 独立 + 早停 + 分类 + 重复spike/shape/sentinel guard）| ✅ 已审：3×P2(重复spike/classify校验/异常用例) 全采纳已修 | ✅ |
| 4 | 多层 TTFS forward（链接单层：hidden `spike_times`→`ttfs_times_to_stream`→下一层；输出层早停+分类）| `forward.py` `test_forward.py` | ✅ **pytest 71 passed** | ✅ **复审 PASS**（第1轮 1×P1+2×P2 修后复核全过）| ✅ |
| 5 | 数据集 loader（MNIST/Fashion/KMNIST → 784 uint8 + labels，torchvision；三者同形状）| `data.py` `test_data.py` | ✅ **pytest 76 passed**（+train split/flatten 约定 + gitignore _data）| ✅ 已审：2×P2(gitignore/train测试) 全采纳已修 | ✅ |
| 6a | QAT 权重量化器（BNN/ternary/two's-comp STE + scale → `encoding` 整数）| `qat.py` `test_qat.py` | ✅ **pytest 98 passed**（量化范围/pack/STE 梯度/对称码/确定性梯度语义/全零）| ✅ 已审：2×P2(对称码文档+测试/梯度口径测试) 全采纳已修 | ✅ |
| 6b/6c | per-output LSQ-QAT + **surrogate-gradient TTFS-IF 直训** + **多比特输入** + golden bit-exact | `qat.py` `model.py` `train.py` **`spiking.py` `train_spiking.py`** `convert.py` + `test_model/qat/convert/spiking.py` | ✅ **pytest 153 passed**（LSQ、QuantLinear、SpikeFn、encode_stream/encode_ramp、spiking forward/导出/阈值、**hidden fire-decision 与 golden bit-exact + 早停 pred≥95%**、过拟合降loss、桥端到端）+ Fashion W=4 ~80% | ✅ 两轮已审(P0/P1/P2 修中) | 🔶 代码+实验完成 |
| 6c+ | spiking sweep(T/W/三数据集) + latency-accuracy Pareto + 鲁棒性 demo + 二值位平面导出 + 能效-延迟-SOP | — | — | — | ⬜ |

**Part 1 Codex 修订（已落地+复验，2026-06-05）**：`mac`/`unpack` 加 shape 校验（防 `spikes` reshape 后静默广播出错的 MAC、out_dim 不匹配）；`pack` 拒非整数权重（防 float 截断）；测试加**独立显式索引** reference（不复用 `k::W` 切片）+ shape/float/empty/越界用例。

**环境备注（2026-06-05 已修）**：系统/brew python 的 pip 坏（libexpat/pyexpat），但 **`.venv-v2c` 可用**（py3.12.13 + numpy 2.4.6 + pytest 9 + **torch 2.12.0 + torchvision 0.27.0（MPS 可用）** + pyexpat ok；pip 正常）。**跑全部 v2c 测试**：
`./.venv-v2c/bin/python -m pytest -q -p no:cacheprovider python_multilayer/v2c/`（当前 **153 passed**）。/tmp wheel-extract 已弃用。

**Part 6b 设计要点（代码完成、本地 147 绿、待 Codex 审，2026-06-05）**：
- ⚠ **接力文档原计划被证伪**：「graded ReLU ANN proxy → 阈值校准 → TTFS」**行不通**。诊断（Fashion W=4）：量化 ANN proxy 86.7%，但导出跑真实 `forward.py` ≈ **随机 10%**，扫任何全局阈值乘子都救不回。根因 = TTFS-IF 动力学：**膜电位均值为负 → per-neuron 阈值多为负 → membrane 从 0 起步即过阈、t=0 秒发**；**带符号权重 → 膜电位非单调 → "首脉冲是否发放"≠"最终膜电位≥阈值"**（闭式 regime-A 61%、真实 spiking forward 仍 10%）。光靠阈值校准（原 6c 设想）救不了 → 必须在真实动力学里训练。
- **方案（用户拍板 surrogate-grad 直训）**：`spiking.py` 在真实 TTFS-IF forward 里用替代梯度直训（`SpikeFn` fast-sigmoid surrogate；单脉冲掩码；隐层 spike train 直接喂下一层 = `ttfs_times_to_stream`；膜电位发放后继续累积——全部 bit-同 `forward.py`）。权重(LSQ-QAT) + per-output 阈值(threshold-QAT) + 时序协同适配。输入用 TTFS 流 → 灰度由首脉冲时间携带。
- **per-output LSQ**（`qat.lsq_quantize_weight` + `model.QuantLinear`，spiking 复用其权重）：每输出可学习 step size，W≥4 对称两补（最负码保留不发，与 `encoding`/RTL 一致）；W=1/2 per-output 幅度版 BNN/TWN。原 `qat.quantize_weight` per-tensor baseline 保留。
- **阈值折叠精确无单位错**：`mem_train = scale ⊙ mem_inf`（per-output scale 从整数 MAC 提出），故 `fire(mem_train≥θ_train) ⟺ fire(mem_inf≥round(θ_train/scale))`；**threshold-QAT**（训练即用部署整数阈值 `θ_eff=scale·round_ste(θ/scale)`）→ 训练发放判据与 golden 整数比较 **bit 一致**。导出每输出**整数**阈值寄存器，**推理期零 BN/零乘法**（PPA-clean）。`convert.export_v2c_layers` 读学习阈值，`convert.eval_ttfs` 跑 golden 验证。
- **Fashion-MNIST W=4 T=16 主网 30ep 结果**：full-frame(无早停,精度上限) **74.0%**；**golden `forward.py` 早停/部署 66.7%**，**fallback 0%、算法首脉冲延迟 2.54/16**（早停延迟-精度代价 7.3pp）；参考量化 ANN 86.7%（灰度激活上限）。**`10% → 66.7%` 是质变**。
- **训练↔推理一致性**由 fire-decision **96% agreement** 测试保证（`test_spiking_matches_golden_forward`，threshold-QAT 拉紧）；74% vs 66.7% 是早停的**延迟-精度权衡**、非不一致。
- **headroom（6c 调优）**：T(16→32/64) + epochs + loss(earliness/membrane 配比) + 三数据集/W sweep + latency-accuracy Pareto。
- `train.py`/`model.py` 的 graded `V2CMLP` 保留为**量化 ANN 参考上界**(非 V2C 部署路径)；旧 `convert.fold_threshold`/`threshold_scale` 已删（证伪）。

**Part 6c 探索记录（accuracy 攻坚 + 战略转向，2026-06-05，本地 149 绿）**：
- **Codex P0/P1/P2 已修**：① 训练 forward 改**整数精确膜**(`mem_i=x@w_int`)→ 发放判据与 golden **bit-exact**(`test_hidden_fire_decisions_bit_exact_with_golden` 锁定 hidden 100% 一致)；② `hard_classify`/membrane-CE 用整数膜(per-output scale 不再乱序 argmax)；③ `QuantLinear.scale` 改 **softplus** 参数化(防负 scale 死区)；④ `init_thresholds_from_data` 用**数值稳定 softplus 逆** `y+log(-expm1(-y))`(防 `log(expm1)` 在大 θ 溢出→NaN)。修后口径变诚实：Fashion W=4 T=16 部署 **64.5%** / full-frame 69.7%(原 74% 被 scaled-membrane 高估)。
- **★ 二值输入天花板（根因）**：单二值脉冲输入 → 灰度只在 **timing** 里、membrane 求和只看二值 → 精度封在 **~65-68%**(= 二值化图 MLP)。**所有 tweak 全失败**：ETTFS-init / WS(和 W=4 量化冲突,塌成 ±1) / 数据驱动阈值 / T=32(更差) / 更深 ablation 网(更差) / 温度-only loss —— 一律破不了 68%。
- **★ 突破：多比特(ramp / bit-serial)输入**（`spiking.encode_ramp` + `train_spiking --input-mode ramp --in-bits N`）。把像素量化成 N-bit、每 timestep 重复喂入 → 第一层膜电位 `(t+1)·(x_多比特@W)` = **完整灰度 MAC**(硬件 = bit-serial 输入 + shift-add,cell 仍二值)。隐层/输出维持单脉冲 TTFS。结果 Fashion W=4 T=16：
  - ramp in4/W4 = **78.8%**(+11pp);**+ 温和 KD α=0.2 = 79.76%(最佳)**;teacher ANN(50ep)=88.3%。
  - 没用的杠杆(训练受限、非精度问题)：in-bits=8=75.5%、W=8=74.3%、KD α=0.5=76.9%。**in4/W4 是甜点。**
  - ⚠ ramp 模式 golden `forward.py` 是 **TBD**（golden 目前只验二值 TTFS 流；ramp 报训练 `hard_classify`/full-frame）。要正式部署需给 `forward.py`/`encoding` 加 bit-serial 多比特输入路径。
- **★ 战略转向（联网调研）**：**accuracy 不是 V2C 的胜负手**（受单宏 256 列 + W=4 约束,打不过更大的全精度网;90%+ 的 SNN 用 784-400-400 + analog 输入）。V2C 该赢的轴 = **① 非理想鲁棒性**(数字二值 cell + 1-bit sense + 无 ADC → 抗器件 variation,模拟多比特 CIM 在这点崩;**可在 Python 注故障画曲线、by-design 稳赢、性价比最高**) + **② 延迟**(TTFS 单脉冲早停,RTL/FPGA 可测) + **③ 无-ADC 能效**(定位故事,projected)。~80% 精度"可信即可"。详见自动记忆 [[v2c-ttfs-training-pivot]]。
- **方案选择**：**A = 多比特输入 + TTFS 隐层**(已做,~80%,**保住单脉冲稀疏 = 能效+延迟+神经形态身份**)。**B/hybrid = 相位编码隐层多比特** → **不值得**(见下 Pareto:隐层精度只值 +1pp,却砍掉稀疏/headline)。
- **★ 精度-隐层精度 Pareto（ANN 上界,`model.V2CMLP` 加 `input_bits`/`act_bits` 量化,Fashion W=4 40ep）**:float-in/float-act 88.25;**4-bit 输入几乎零损失(88.20)**;4-bit-in × act {4-bit 88.14 / 2-bit 87.90 / **1-bit 87.15**}。→ **隐层精度几乎不影响精度(hybrid 只 +1pp)**。
- **★ 关键 open problem:7pp spiking-vs-ANN gap**。**1-bit 隐层 ANN = 87.15%,但 spiking 方案 A 只 80%** —— 差的 7pp **全是 surrogate-gradient TTFS 训练比干净 QAT 难训的开销,不是架构/精度**(ramp 下 spiking 隐层 `(t+1)z1≥θ` 数学上 ≡ 二值阈值,应能到 87%)。试过闭合都失败:membrane-focus(`beta_mem`=1→78.2 / =3→75.4,更差)、KD(α=0.2 +1pp / α=0.5 -2pp)、in8/W8、ETTFS-init/WS。**架构支持 87%,精度故事没死,但闭合这 7pp 需要更强的 spiking 训练法 → 列为 Codex 调研的核心问题。**
- **Codex 第二轮审 + 修(2026-06-05，155 绿)**:整数膜 bit-exact / softplus scale / 稳定 softplus 逆 / **阈值 ≥1 钳位**(防 t=0 退化) / **fp32 整数膜守卫**(W8/in8 越界报错) / **`convert.eval_ttfs_ramp`**(ramp 的 golden:第一层 `Σ_k 2^k·encoding.mac(bitplane_k)` bit-serial MAC + ramp TTFS,**让 ramp 精度成为 golden 部署数**) + bit-serial 等价测试(独立参考 `Σ2^k·mac==v@w_int`)。commit `1ac1970`。
- **bias 公平性（Codex 抓的方法论漏洞，已查）**:`bias=False` 1-bit 隐层 ANN = **86.84%**（vs bias=True 87.15，仅差 0.3pp）→ **7pp gap 是真的训练开销、不是 bias**(spiking 的阈值吸收了 bias 作用)。公平上界 ≈ **86.84%**。
- **★ init-from-ann gap-closer（Codex 推荐 matched-init，有效）**:先训匹配的 1-bit 隐层 ANN(87%)→ 拷 `weight/log_scale` 初始化 spiking + 温和 KD → **golden 部署 81.25%(延迟≈0、ramp 在 t=0 即给完整灰度 MAC)**。`train_spiking --init-from-ann`。**精度全景 `68(二值)→78.8(ramp)→79.8(+KD)→81.25(+init-from-ann)`**,gap 收到 ~5.6pp。
- **★ SNN 卡在 ~81%、与 teacher/init 脱钩（2026-06-05 实测结论）**:试遍便宜+中等杠杆,**SNN 一律 ~80-81%**。`act_hi` grid(`model.V2CMLP.act_hi`,1-bit 隐层二值阈=act_hi/2):**act_hi=2.0 最优,ANN 86.84→87.29%**(白拿 +0.45pp);但用 act_hi=2.0+bias=False 的更强 teacher(87.48%)重 init SNN → golden **80.45%(没涨)**。hidden-occurrence 蒸馏(`--hidden-kd`,已修梯度伸缩相消 bug→改发放余量 BCEWithLogits)→ 79.1%(更差,init 已对齐权重、蒸馏只扰动时序)。**最佳 SNN 仍是 init-from-ann 的 81.25%**。**结论:剩 ~6pp 是 surrogate-TTFS 训练硬骨头,teacher 再好也传不过去 → 闭合需训练范式重写(temporal rank loss + wrong-early penalty),研究级、回报不确定。** Codex 误报已驳:`log_scale` no-decay 其实正确(`"log_scale".endswith("scale")`=True)。
- **下一步（建议②）**:① 继续闭合 ~6pp 需研究级范式重写(回报不确定);② **★转非理想鲁棒性 demo(真正 win,accuracy 本就非胜负手,81% 够用,强烈建议)**;③ ANN 参考上界可继续抬(PACT/staged-QAT → ~88,但 SNN 不跟,只助参考数);④ 三数据集/T sweep + ramp golden PPA cycle 计数。

**Part 6c+ Phase 1：拔高 matched ANN 实验（按 Codex 计划 E0–E7，2026-06-05，本地 158 绿）**：
- **驱动**：新建 `experiments.py`（E0–E6 多 seed mean±std；E7 = SNN 桥接 + golden Pareto）。**修了 train.py 隐性坑**：`history[-1]['test_acc']` 是 raw 权重精度、非 EMA 部署精度 → driver 改评估返回的 EMA 网络。EMA 为部署权重，全部数为 EMA。
- **结果表（Fashion-MNIST，main 784-246-10，W4/in4/act1/act_hi=2.0，5 seeds，EMA 部署）**：

  | 实验 | 内容 | acc | vs E0 |
  |---|---|---|---|
  | **E0** | cold 基线 bias=False | **87.21% ± 0.14%** | 基准 |
  | E1 | log_scale no-decay | **误报，实证驳回** | — |
  | E3 | PACT 可学习激活 clip | 87.12% ± 0.19% | 持平 |
  | E4 | staged QAT(A20/B10/C15/D10+finetune) | 86.78% ± 0.18% | −0.43 |
  | E5 | teacher-assistant KD(α=0.5) | 87.03% ± 0.17% | −0.18 |
  | **E6** | constant bias row(bias=True) | **87.37% ± 0.18%** | **+0.16** ★最佳 |

- **★ 结论：ANN 已到天花板 ~87.4%，Codex「QAT 技巧能拔到 88%」假设被系统实验证伪**。cold recipe(AdamW+cosine+LS+平移+EMA+LSQ)已近最优，PACT/staged/KD **全无增益**；唯一边际正贡献是 **bias row(+0.16pp，PPA 便宜：一条常开二值 cell 行)**。这反向坐实战略判断：**单宏 784-246-10 下 accuracy 非胜负手**。
- **E1 实证**：`layers.*.log_scale` 落 NO_DECAY 组(wd=0)；Codex 又看错 `"log_scale".endswith("scale")`=True。`_param_groups` 另把 `*alpha*`(PACT clip)也排除 WD。
- **E2**：act_hi=2.0 经 prior-grid + E0/E6 三次确认最优；7 点全网格未重跑(低 EV)。model.py 默认 act_hi=4.0 未改(所有 matched/部署/init-from-ann 调用都显式传 2.0，默认值在真实路径不触发)。
- **新增可复用基建**：`model._pact_quant`+`V2CMLP(pact=)`(softplus 保正、精确 PACT 梯度 only-saturated→α)；`train.train_model(warm_start_state=)`(staged QAT)；**`convert.eval_ttfs_ramp_modes`(strict / guard-window Δ / full-frame 三点 Pareto，E7 + 鲁棒性曲线共用)** + 重构提取 `_ramp_hidden_times`。测试 +3(2 PACT + 1 modes)。
- **下一步（Phase 2 改善 SNN，用户已拍板收口 ANN 进 SNN）**：E7 = 用最佳 ANN(= cold matched，`--init-from-ann` 内部即训此)init SNN(ramp/T16/in4/fire-frac0.5/init-from-ann/KDα0.2)，跑 `eval_ttfs_ramp_modes` 出 strict(当前 81.25%)/guardΔ/full-frame Pareto——**guard-window 可不重训回收 early-exit 损失**(错误类早发一拍)。再评估是否需训练范式重写(temporal rank loss + wrong-early penalty)。

**Part 6c+ Phase 2：SNN 桥接 + 阈值复现诊断（E7/E8，2026-06-05，本地 158 绿）**：
- **E7（训练后 SNN，`experiments.py E7`，ramp/T16/in4/fire-frac0.5/init-from-ann/KDα0.2，seed0，n_eval2000）**：strict=**80.45%**@t≈9.6 / guardΔ1=80.30 / guardΔ2=80.60 / guardΔ4=80.80@12.8 / **full-frame=80.55%**@16。**full-frame ≈ strict（早停代价 ~0.1pp）→ gap 不是时序/早停问题，guard-window 几乎回收不了**。接力文档建议的 temporal-rank/wrong-early loss 是治时序的，**打偏**。
- **★★ E8 阈值复现诊断（`experiments.py E8`，关键翻案结果）**：把 SNN 隐层整数阈值**直接设成 ANN 1-bit gate 等价值** `θ_int = round(T·(act_hi/2)·levels_in/scale)`（推导：`z1_ann=(scale/levels_in)·z1_int`、ANN 隐层发放 ⟺ `z1_ann≥act_hi/2`；ramp SNN 帧内发放 ⟺ `z1_int≥θ_int/T`；等号联立。实现：`softplus(log_thr_hidden)=T·(act_hi/2)·levels_in`，export 再 /scale）。**无 spiking 训练**，结果：
  - **hidden-gate agreement = 1.0000**（SNN 隐层发放与 ANN 1-bit 激活逐元素 100% 一致 → 推导正确、gate 完美复现）
  - **full-frame = 87.85% ≈ ANN(EMA) 87.46%** → **SNN 架构能完整表达 ANN，~7pp gap 非结构性**
  - strict = 59.35%（输出阈值未标定，最早发放非正确类）
- **★ 重构认知**：① gate 复现已解决(87.85% full-frame、零训练)；② E7 训练后 full-frame 只 80.5%（⚠ 当时归因为"训练训坏"过头了——E7 同时用了 `fire_fraction` 阈值初始化，混了因，**已由 E9 消融精炼**，见下）；③ 输出层时序标定是 latency-accuracy 旋钮。**接力文档"研究级 ~6pp 硬骨头"基本翻案**。
- **bias 问题（用户提问）**：数字 CIM 可加训练 bias = **常数 bias 行**(恒开输入行 + W-bit 权重行，同二值 cell，+1 行 PPA 可忽略、无 ADC/乘法)。TTFS nuance：阈值吸收部分 bias(故 ANN 端 E6 只 +0.16pp)，但 ramp 下 bias 行贡献 `(t+1)·b`(随时间累积)、阈值是时间无关偏移 → 不同自由度，**bias 行在 SNN 可能比 ANN 更有用**(候选 Phase-2 杠杆)。注：E6 `bias=True` 是 float-bias 代理，硬件版是常数 cell 行。
- **下一步候选**：① 输出层时序标定(`θ_out[k]∝1/scale_out[k]` 让 earliest-spike 复现 ANN argmax / 或冻结 gate-init 只训输出时序 / 或输出阈值 sweep 出 latency-accuracy Pareto，起点 87.85%)；② 常数 bias 行(SNN)；③ 是否接受 full-frame 部署(87.85%@T cycle)换取无训练。**待 Codex 审 + 用户定向**。

**Part 6c+ Phase 2.5：Codex 审 + E8 全量 + E9 因果消融（2026-06-05，本地 158 绿）**：
- **Codex 审（第四轮，全 P1/P2 已采纳修复，无 P0）**：P1.3 `eval_ttfs_ramp` deeper-net 早停 bug（中间隐层误用 early_exit）→ 已改中间层 full、仅输出早停（main 不触发）；P2.1 `_quant_unsigned` 注 1-bit 边界 half-to-even tie；P2.2 `test_spiking` 阈值断言 →≥1。Codex 收窄断言 A/B/D（别说"所有 QAT 证伪"/"唯一问题"），**已采纳**。
- **E8 全量诊断（50ep, n_eval2000，验断言 B 非假象，P1.2）**：ANN 10k=87.46/sub=87.75；**SNN full-frame=87.85≈ANN**；SNN-vs-ANN 预测吻合 **98.4%**；hidden-gate **100%**；**out-scale CV=0.158 但 int-argmax vs scaled-argmax 吻合 98.4%**（丢 per-class 输出 scale 只翻 1.6% 决策 → 这就是无-scale 整数膜 argmax 能复现 ANN 的原因）。**断言 B 实锤**。
- **★ E8 输出阈值 Pareto（gate-init，零训练，`θ_out[k]=round(c/scale_out[k])` sweep c）**：c=1.0→strict 59.4%@t2.9；c=1.5→69.5%@t5.3；**c=2.0→85.55%@t11**；c≥3→87.85%@t16(全 fallback)。低延迟段 guard-window 有用(c=1.0: strict59%→guardΔ2 66%@t4.8)。
- **★★ E9 因果消融（gate-init 阈值固定、只变是否训练，隔离 P1.1 的混因，`train_spiking gate_threshold_init=True`）**：gate-init+**训练**(seed0) → strict=**84.50%@t6.7** / full-frame=**83.30%**。**对比 E8 gate-init 不训练 full=87.85**：
  - **断言 C 成立但精炼**：训练确实把 **full-frame 从 87.85 拉到 83.30（−4.55pp）**——隔离了阈值初始化混因后，"surrogate 训练损害 full-frame 判别力"为真。
  - **但训练是"延迟优化器"**：把发放拉早（strict 84.50%@**t6.7** vs 不训练需 t≈11 才 85.55%；t≈6.7 处不训练只 ~75%）。即**训练牺牲峰值精度换早停延迟**。
  - E9 full 83.30 > E7(fire_fraction+train) full 80.55 → **gate-init 对训练版也有帮助**。
- **★ Phase-2 最终结论 + 部署 recipe（latency-accuracy Pareto 前沿，单 seed，待多 seed 复核）**：
  - **准确率模式**：gate-init **不训练** → **87.85%@t16**（=ANN）或 85.55%@t11。
  - **低延迟模式**：gate-init **+训练** → **84.50%@t6.7**。
  - 二者并集即 Pareto 前沿。**SNN accuracy 基本解决**（解析 gate-init + 输出标定，无需/可选训练），不再是研究级硬骨头。
- **下一步（用户定向）**：accuracy 既已解决/够用，倾向**转 Phase 3 非理想鲁棒性**（真正赢面轴）。可选精修：per-class θ_out 坐标搜索把拐点左移、常数 bias 行、多 seed 复核 E8/E9。
