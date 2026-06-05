# V2C Phase 2 审查 + 调研请求（喂给 Codex；只读仓库、勿改代码）

> 复制全文给 Codex。它读 `~/dev/snn-soc/python_multilayer/v2c/`，**最新进度全在 `PROGRESS.md` 末尾三段（Phase 2 / 2.5 / E10）**。

---

## 0. 你的角色与约束
资深 SNN / 量化 / 存内计算(CIM) + 硬件审稿人。三件事：**(A) 严格审查 Phase-2 结果与结论有无问题；(B) 通读项目最新进度做整体评估；(C) 调研、思考有没有更好更优的改善/优化方法。**

约束：**只读不改**（要改给 diff 建议）；**独立判断、可 push back**（本项目已两次驳回你的 `log_scale` no-decay 误报，请对自己结论也存疑）；分 **P0/P1/P2**，引用 `文件:行号`，缺数据写 TBD 不臆测。

## 1. 项目背景 + 战略（一句话）
V2C：**数字二值 0T1R RRAM-CIM + TTFS** 加速器（cell 二值、W=4 跨 cell 编码、popcount/shift-add MAC、TTFS-IF 积分-首脉冲发放、per-output 整数阈值、无 ADC/无推理乘法）。网络 main `784→246→10`、4-bit ramp 输入、1-bit 隐层、act_hi=2.0。**★ 战略：accuracy 不是胜负手**（赢面 = 鲁棒性 / 延迟 / 无-ADC 能效），accuracy"可信/够用"即可——**所以审查时请把"是否值得继续抠 accuracy/latency"也纳入判断**。部署路径 = `spiking.py`(V2CSpikingMLP)，`model.V2CMLP` 只是 ANN 参考。

## 2. 环境 + 读哪里
- venv：`~/dev/snn-soc/.venv-v2c`；全测试 **159 passed**：`./.venv-v2c/bin/python -m pytest -q -p no:cacheprovider python_multilayer/v2c/`
- 实验：`./.venv-v2c/bin/python python_multilayer/v2c/experiments.py {E7|E8|E9|E10} --epochs 50 --T 16 --n-eval 2000`
- **进度权威**：`python_multilayer/v2c/PROGRESS.md` 末尾 **Phase 2 / Phase 2.5 / E10** 三段（含全部数与推导）。
- 关键代码：`convert.py`(`eval_ttfs_ramp_modes`/`ramp_output_trajectories`/`strict_decode_from_traj`/`_layer_membrane_trajectory`/`_decide_guard`)、`experiments.py`(E7–E10 + `_gate_init_snn`)、`train_spiking.py`(`gate_threshold_init`)、`spiking.py`。

## 3. Phase-2 来龙去脉（要点 + 数）
单宏 main、Fashion-MNIST、W4/in4/act1/act_hi=2.0、seed0、n_eval=2000、EMA。ANN 参考 = **87.46%(10k)/87.75%(sub)**。
- **E7**（旧路径：`fire_fraction` 阈值 init + surrogate 训练）：strict 80.45%@t9.6、full-frame 80.55%。
- **E8**（★ 阈值复现，**零训练**）：把隐层整数阈值设成 ANN 1-bit gate 等价 `θ_int=round(T·(act_hi/2)·levels_in/scale)`（推导见 PROGRESS）。结果：**hidden-gate 逐元素吻合=100%**；**full-frame=87.85%≈ANN**；SNN-vs-ANN 预测吻合 98.4%；out-scale CV=0.158 但 **int-argmax vs scaled-argmax 吻合 98.4%**（丢 per-class 输出 scale 只翻 1.6% 决策）。输出阈值全局 sweep：c2→85.55%@t11（注：c 标签是 softplus(c) 偏移）。
- **E9**（因果消融：`gate_threshold_init=True`，固定 gate hidden 阈值、**只变是否训练**）：gate-init+训练 → strict 84.50%@t6.7、**full-frame 83.30%**（vs E8 不训练 87.85）。→ **训练把 full-frame 拉低 −4.55pp（混因已隔离），但把发放拉早（"延迟优化器"）**。
- **E10**（★ per-class 输出阈值坐标搜索，**零训练**，train 标定/test 报数）：`θ_out[k]=round(c_k/scale_out[k])`，坐标下降 max `acc−λ·lat/T`；预计算阈值无关的输出膜轨迹 `ramp_output_trajectories` + 向量化离线解码 `strict_decode_from_traj`（测试锁定 ==golden strict）。test Pareto：**λ0→87.75%@t11.4 / λ0.5→84.55%@t7.0 / λ1→66.25%@t3.5**；global 精确 c：c2=81.10%@t9.1 / c3=87.85%@t16。calib→test gap ~1pp。

## 4. 我得出的关键结论（请逐条判定 对/错/存疑）
- **结论 B**：gate-init 让 SNN **零训练复现 ANN**（full-frame 87.85%、gate 100%、预测吻合 98.4%）→ ~7pp gap 非结构性。
- **结论 C（精炼）**：surrogate 训练**损害 full-frame**（87.85→83.30，已隔离阈值 init 混因），但**是延迟优化器**（拉早发放）。
- **结论 D（新，最重要）**：**per-class 输出阈值标定全面压过训练**——零训练拿 84.55%@t7.0（≈训练 84.50%@t6.7）**且**保住 87.75%@t11.4 上限（训练 full-frame 只 83.30）。
- **最终 recipe**：**解析 gate-init + per-class 输出阈值标定，零 spiking 训练**；一条旋钮 λ 给整条 latency-accuracy 前沿。

## 5. (A) 严格审查（P0/P1/P2）
1. **离线解码正确性**：`strict_decode_from_traj` / `ramp_output_trajectories` 与 golden `eval_ttfs_ramp_modes` strict 是否真的逐样本一致（测试只验了一个阈值点）？tie-break / fallback / latency 口径有没有漏？
2. **per-class θ_out=round(c_k/scale_out[k]) 的依据**：这个参数化合理吗？坐标下降（贪心、init c=2、3 轮、网格离散）有无明显局部最优/过拟合 calib 的风险？λ 扫法能否真代表 Pareto 前沿？
3. **"标定压过训练"是否稳健**：会不会是单 seed / calib-test 口径 / softplus(c) 标签修正造成的错觉？E9 训练只跑了 1 seed、1 种超参（KDα0.2/fire_frac0.5），能否就断言"训练有害/不必要"？是否该试"gate-init + 只训输出阈值（冻结权重）"或"训练时正则化 hidden 阈值贴住 gate"再下结论？
4. **方法学**：全程单 seed；n_eval=2000（95%CI ~±1.7pp）；calib 用 train 子集报 test（gap ~1pp，够干净吗？要不要独立 val 集）；E8 sweep 的 softplus(c) 标签偏移是否还有别处类似口径问题。
5. **golden 一致性**：`_layer_membrane_trajectory` 全帧膜 vs `_layer_spikes` 训练期整数膜在输出层是否仍 bit 一致；deeper-net（ablation）路径修复后是否真的对（仅 main 被测）。

## 6. (B) 查看最新进度
通读 `PROGRESS.md` 末三段 + 上述代码，给一句话整体评估：**Phase 1（ANN 天花板 ~87.4%）+ Phase 2（SNN= gate-init+标定，87.75%@t11.4 / 84.55%@t7.0）的结果链条是否自洽、可信、可写进论文**？有没有逻辑断裂或被高估的地方？

## 7. (C) 调研 / 更优方法（重点——请放开想）
1. **能否突破当前 Pareto**（比 87.75%@t11.4 / 84.55%@t7.0 更优）？尤其：**有没有办法在不牺牲 full-frame 87.85% 的前提下把延迟压到 t<7**？候选：只训输出时序、hidden 阈值正则贴 gate、guard-window+per-class 联合、temporal contrastive……哪条最有指望？
2. **延迟地板的根因**：为什么 t<7 精度崩？是不是隐层 TTFS 脉冲到达分布太晚（早期证据不足）？能否让**信息量大的隐层神经元更早发**（不破坏 gate）——比如输入 ramp 的 bit 顺序、隐层 per-class/per-neuron 阈值、或 MSB-first bit-serial？
3. **更原理化的输出阈值**（替代坐标搜索）：能否从 ANN 输出 logit 统计/margin 解析地推 per-class θ_out？
4. **bias 行**（数字 CIM 常数恒开行 + W-bit 权重）值不值得在 SNN 做？预期收益？
5. **鲁棒性 demo（下一阶段、项目真正赢面）**：数字故障注入（cell stuck-at / read bit-flip(按 on/off+噪声+阈值推 read-BER) / write-fail）怎么建最有说服力？与模拟 ADC-based CIM（conductance variation + ADC quant/noise）对比怎么设计？这些能直接架在 `eval_ttfs_ramp_modes`/`ramp_output_trajectories` + cell mask 上吗？
6. 站在"accuracy 非胜负手"的战略上：**你认为现在最该投入的是哪一项**（继续压延迟 / 鲁棒性 / 能效-SOP-J 量化 / RTL）？还是说 SNN 这块已"够用"该收手？
7. 有没有我们**根本性漏掉**的更优思路（架构/编码/训练/解码层面）？

## 8. 输出格式
P0/P1/P2 分组逐条（问题 + `文件:行号` + 对/错/存疑 + 建议）；第 6 节一句话整体评估；第 7 节按"高/中/低 指望 × 成本"排序给候选方法，并明确"你若是我下一步会做什么"。
