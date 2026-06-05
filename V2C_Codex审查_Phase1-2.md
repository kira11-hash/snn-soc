# V2C Phase 1–2 结果审查请求（喂给 Codex；只读仓库、勿改代码）

> 复制以下全文给 Codex。它会读仓库 `~/dev/snn-soc/python_multilayer/v2c/`。

---

## 0. 你的角色与约束
你是资深的 SNN / 量化 / 存内计算（CIM）+ 硬件审稿人。本次任务是**审查**我刚完成的一批实验的**正确性、方法学严谨性、结论是否站得住**，并指出**还能怎么提升**。

硬性约束：
- **只读，不要改任何代码或文件**；要改的话给出 diff 建议即可。
- **独立判断、可有理有据地 push back**；不要客气地附和。本项目历史上驳回过你的误报（见下 E1），所以请对自己的论断也保持怀疑。
- 结论按 **P0（必须修/严重）/ P1（应修）/ P2（可选）** 分级；引用 `文件:行号`；缺数据就写 TBD，不要臆测实测值。

## 1. 项目背景（一句话 + 战略）
- 用户的 SNN/CIM 芯片项目，做 **V2C 论文线**：**数字二值 0T1R RRAM-CIM + TTFS** 加速器（cell 二值、权重跨 W 个 cell 编码 W-bit 两补、MAC 走 popcount/shift-add、神经元 TTFS-IF 积分-首脉冲发放、per-output 整数阈值、无 ADC/无推理期乘法）。目标灌一篇 Q4 SCI。
- **★ 战略定位（重要）**：**accuracy 不是 V2C 的胜负手**（单宏 256 列 + W=4，打不过更大的全精度网）。赢面轴 = **① 非理想鲁棒性**（数字二值 + 1-bit sense + 无 ADC，抗 device variation）**② 延迟**（TTFS 单脉冲早停）**③ 无-ADC 能效**。accuracy "可信/够用"即可。
- 网络：main = `784→246→10`（单隐层）；W=4；输入 4-bit ramp（bit-serial 多比特，cell 仍二值）；隐层 1-bit；act_hi=2.0。
- **部署路径是 `spiking.py`（V2CSpikingMLP，surrogate-grad TTFS 直训）**，不是 `model.V2CMLP`（后者是量化 ANN 参考/teacher）。

## 2. 环境与复现
- venv：`~/dev/snn-soc/.venv-v2c`（torch 2.12 + MPS）。
- 全测试（当前 **158 passed**）：`cd ~/dev/snn-soc && ./.venv-v2c/bin/python -m pytest -q -p no:cacheprovider python_multilayer/v2c/`
- 实验驱动：`./.venv-v2c/bin/python python_multilayer/v2c/experiments.py {E0|E2|E3|E4|E5|E6|E7|E8} --seeds N --epochs 50 --T 16 --n-eval 2000`
- 详细进度与结论见 `python_multilayer/v2c/PROGRESS.md`（末两段 Phase 1 / Phase 2）。

## 3. 代码地图（本次新增/改动，请重点看）
- `experiments.py`（新）：E0–E6 = ANN 多 seed 实验；E7 = SNN 桥接 + golden Pareto；E8 = 阈值复现诊断。注意 driver 评估的是 **EMA（部署）权重**（修了 `train.py` 的坑：`history[-1]['test_acc']` 是 raw 权重精度、非 EMA）。
- `model.py`：`_pact_quant`（PACT 可学习激活 clip，softplus 保正、`alpha - relu(alpha-relu(x))` 形式给精确 PACT 梯度 only-saturated→α）；`V2CMLP(pact=)`、`_hidden_act`。
- `train.py`：`_param_groups`（WD 排除 `*scale`/`*bias`/`*alpha*`）；`train_model(warm_start_state=)`（staged QAT 跨阶段 load_state_dict）。
- `convert.py`：`eval_ttfs_ramp_modes`（**strict / guard-window Δ / full-frame** 三决策策略 Pareto）、`_layer_membrane_trajectory`、`_decide_guard`（Δ=0 ≡ strict 早停）、重构提取 `_ramp_hidden_times`。
- `spiking.py`（既有）：`V2CSpikingMLP`、`_layer_spikes`（整数膜 bit-exact + 单脉冲 + 守卫）、`init_thresholds_from_data`（fire_fraction 分位数阈值）、`export_int_thresholds`、`ttfs_loss`。
- `train_spiking.py`（既有）：`train_spiking(init_from_ann=...)`（内部训 matched ANN→拷 weight/log_scale→KD）。

## 4. 实验结果（Fashion-MNIST，main 784-246-10，W4/in4/act1/act_hi=2.0，EMA 部署权重）

### Phase 1：拔高 matched ANN（E0–E6，每个 5 seeds）
| 实验 | 内容 | acc | vs E0 |
|---|---|---|---|
| **E0** | cold 基线 bias=False | **87.21% ± 0.14%** | 基准 |
| E1 | log_scale no-decay | **误报，已实证驳回** | — |
| E3 | PACT 可学习激活 clip | 87.12% ± 0.19% | 持平 |
| E4 | staged QAT(A20/B10/C15/D10+低lr finetune) | 86.78% ± 0.18% | −0.43 |
| E5 | teacher-assistant KD(α=0.5，assistant=同架 W4 float-act ~88%) | 87.03% ± 0.17% | −0.18 |
| **E6** | constant bias row(bias=True) | **87.37% ± 0.18%** | **+0.16**（唯一正） |

- **E1 实证**：`layers.*.log_scale` 实测落 NO_DECAY 组（wd=0）；`"log_scale".endswith("scale")`=True，本就正确。（这是你上一轮的误报，本轮再次确认。）
- **结论 A**：ANN 已到天花板 ~87.4%；cold recipe（AdamW+cosine+label-smooth+平移+EMA+LSQ）已近最优，PACT/staged/KD 全无增益；唯一边际正贡献是 bias row（+0.16pp）。

### Phase 2：SNN（E7 训练后 / E8 阈值复现诊断，单 seed）
- **E7**（ramp/T16/in4/fire-frac0.5/init-from-ann/KDα0.2，n_eval2000）：strict=**80.45%**@t≈9.6 / guardΔ1=80.30 / guardΔ2=80.60 / guardΔ4=80.80@12.8 / **full-frame=80.55%**@16。→ **full-frame ≈ strict（早停代价 ~0.1pp），gap 不是时序问题，guard-window 回收 ~0**。
- **★★ E8 阈值复现（无 spiking 训练）**：把 SNN 隐层整数阈值设成 **ANN 1-bit gate 等价值** `θ_int = round(T·(act_hi/2)·levels_in / scale)`（推导见下），结果：
  - **hidden-gate agreement = 1.0000**（SNN 隐层发放 vs ANN 1-bit 激活逐元素 100% 一致）
  - **full-frame = 87.85% ≈ ANN(EMA) 87.46%**
  - strict = 59.35%（输出阈值我随意设的 `log_thr[1]=1.0`，未标定）

**E8 推导**（请重点核查）：
- ANN 隐层 pre-activation `z1_ann = x01_q @ w_q`，其中输入 in4 反量化 `x01_q = xq/levels_in`（levels_in=15）、`w_q = w_int·scale`（per-output LSQ）⟹ `z1_ann = (scale/levels_in)·z1_int`，`z1_int = xq @ w_int`。
- ANN 1-bit 隐层发放 ⟺ `relu(z1_ann)` 经 `_quant_unsigned(bits=1,hi=act_hi)` 非零 ⟺ `z1_ann ≥ act_hi/2`。
- ramp SNN 隐层膜 `(t+1)·z1_int`，帧内发放 ⟺ `T·z1_int ≥ θ_int` ⟺ `z1_int ≥ θ_int/T`。
- 联立 `z1_int ≥ (act_hi/2)·levels_in/scale` 与 `z1_int ≥ θ_int/T` ⟹ `θ_int = T·(act_hi/2)·levels_in/scale`。实现：`softplus(log_thr_hidden)=T·(act_hi/2)·levels_in`（常数），export 时 `round(/scale)` 得 per-output θ_int。

## 5. 我的核心论断（请逐条判定对/错/存疑）
- **断言 A**：ANN 天花板 ~87.4%，Codex 之前"QAT 技巧能拔到 88%"的假设被 E0–E6 系统证伪。
- **断言 B**：E8 推导正确，gate 可 100% 复现，SNN 架构能完整表达 ANN（full-frame 87.85% ≈ ANN）→ ~7pp gap **非结构性**。
- **断言 C**：E7 的 surrogate 端到端训练把 full-frame 从 87.85% **训坏到 80.5%**（为治早停牺牲判别力、两头不讨好）。
- **断言 D**：SNN 剩余唯一问题 = **输出层时序标定**（让正确类最早发），且这是 latency-accuracy 旋钮（输出阈值高→晚发→逼近 full-frame）。

## 6. 重点核查项（请给 P0/P1/P2）
1. **数学/推导**：E8 的 θ 公式（含单位、`levels_in`、`act_hi/2`、整数 rounding 误差）对不对？`convert._ramp_hidden_times` / `_layer_membrane_trajectory` / `_decide_guard`（声称 Δ=0 ≡ strict 早停）实现正确吗？
2. **"训练有害"结论是否稳健**：E8 用了**任意输出阈值**（`log_thr[1]=1.0`）就得到 full-frame 87.85%；E7 的 full-frame 80.5% 是训练后的。87.85 vs 80.5 的对比公平吗？会不会 E8 的 full-frame 高只是因为某种评测口径（2000 子集 vs ANN 10k；fallback 占比；输出 argmax 用整数膜 vs ANN 带 per-output scale）？**full-frame argmax 丢了输出层 per-class scale，为何还能 ≈ ANN？是否 output scale 近均匀？请验证。**
3. **方法学**：E7/E8 只跑了单 seed；n_eval=2000 子集的统计误差；E0–E6 的 EMA 评测（driver 自评 EMA 而非 history）是否引入偏差。
4. **guard-window/full-frame eval**：`eval_ttfs_ramp_modes` 对 deeper net（隐层 early_exit）与 main（2 层）的处理；`eval_ttfs_ramp` 旧实现对 layers[2:] 用 early_exit=True 的潜在 bug（仅 main 不触发）是否要修。
5. **bias 行**：数字 CIM 加"常数 bias 行"（恒开输入行 + W-bit 权重）作可训练 affine bias，硬件/训练/与阈值的关系（阈值是时间无关偏移、bias 行贡献 `(t+1)·b` 随时间累积）论述对不对？在 SNN 做值不值得？

## 7. 开放问题（请给改进建议）
1. **如何在保留早停（低延迟 headline）的同时拿到 ~87%**？候选：(a) 输出阈值按 `θ_out[k]∝1/scale_out[k]` 标定让 earliest-spike 复现 ANN argmax；(b) 冻结 gate-init 隐层、只训输出层时序；(c) 输出阈值 sweep 出 latency-accuracy Pareto（起点 87.85%）。哪条最稳？还有别的吗？
2. **是否应放弃 surrogate 端到端训练**，改"gate-init（解析阈值）+ 仅标定/轻训输出"？风险？
3. **鲁棒性 demo**（项目真正的赢面轴）：故障注入模型（stuck-at-0/1、read bit-flip 按 on/off+噪声+阈值推 read-BER、write-fail）怎么建最有说服力？与模拟 ADC-based CIM 的脆弱性对比怎么做（NeuroSim 只能当模拟基线，仿不了我们的数字 TTFS）？
4. 还有哪些 **PPA / 精度 / 方法学** 提升点是我漏掉的？

## 8. 输出格式
按 `P0 / P1 / P2` 分组逐条给：问题描述 + `文件:行号` + 你的判断（对/错/存疑）+ 建议。最后给一段"我若是你下一步会怎么做"的独立意见。
