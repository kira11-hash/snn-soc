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
- **下一步**:① 闭合剩余 ~5.6pp 需 Codex 深层 recipe（**temporal rank loss + wrong-early penalty + hidden-occurrence distillation + guard-window eval**）= 训练范式改动、工作量大；② **或转非理想鲁棒性 demo（真正 win，建议）**;③ 三数据集/T sweep;④ ramp golden 的 PPA cycle 计数(`input_bits 相位 + T compare`,非 `T×input_bits`)。
