# V2C Phase A+B 审查 + 调研请求（喂给 Codex；只读仓库、勿改代码）

> 复制全文给 Codex。它读 `~/dev/snn-soc/python_multilayer/v2c/`，**最新进度在 `PROGRESS.md` 末尾的 Phase A / Phase B 段**。前两轮审查见 `V2C_Codex审查_Phase2.md`（已全采纳修复）。

---

## 0. 你的角色与约束
资深 SNN / 量化 / 存内计算(CIM) + 器件可靠性审稿人。三件事：**(A) 严格审查 Phase A+B 结果与方法学有无问题；(B) 重点拷问 analog 鲁棒性基线的公平性/可信度；(C) 调研、给出更优做法**——这是进 RTL 阶段前的最后把关。

约束：**只读不改**（要改给 diff 建议）；**独立判断、可 push back**（本项目已多次驳回你的误报，对自己结论也存疑）；分 **P0/P1/P2**，引用 `文件:行号`，缺数据写 TBD。

## 1. 背景（一句话）
V2C = **数字二值 0T1R RRAM-CIM + TTFS** 加速器（cell 二值、W=4 跨 cell、popcount/shift-add MAC、TTFS-IF 早停、per-output 整数阈值、无 ADC/无推理乘法）。**部署路径 = 解析 gate-init（隐层阈值=ANN 1-bit gate 等价式）+ per-class 输出阈值标定，零 spiking 训练**（Phase-2 结论，已两轮 Codex 审）。战略：**accuracy 非胜负手，鲁棒性是唯一今天可信的 SOTA-able 轴**；延迟/功耗要 RTL+能耗才能喊。

## 2. 本轮新增（Phase A + B，Python sim，159→163 tests 绿）
- **Phase A**（`experiments.py E10 --dataset {mnist,fashion_mnist,kmnist} --seeds 3 --n-eval 10000`）：同一套零训练 gate-init+标定，三数据集 latency-accuracy Pareto（λ0 准确率 / λ0.5 早停）：

  | 数据集 | λ0 | λ0.5 |
  |---|---|---|
  | MNIST | 98.36%±0.04 @t≈9.9 | 95.98% @t≈5.3 |
  | Fashion | 87.03%±0.11 @t≈12.3 | 82.21% @t≈6.4 |
  | KMNIST | 89.85%±0.15 @t≈13.1 | 86.96% @t≈7.8 |

- **Phase B 数字鲁棒性**（`E11`，`robustness.py`）：gate-init full-frame，向 packed 二值 cell **i.i.d. 注故障**（stuck-at-0/1、read bit-flip），3 模式×5 trial，acc-vs-故障率。三数据集均优雅降级，现实区(~1-2%)几乎不掉；flip 最伤。Fashion clean 87.85：flip 5%→74.2/10%→55.1；MNIST 最稳(5%→96)。
- **Phase B analog 基线**（`robustness.analog_reference_sweep`）：同 matched-ANN W4 整数权重，但 MAC 加 **per-weight 电导 variation N(0,σ)（乘性）+ per-output full-scale ADC**。σ-sweep。**已修一个 ADC 假象**（旧全局 full-scale=max 被离群值主导 → Fashion σ=0 崩 69.65%；改 per-output → σ=0≈clean：Fashion 87.35/MNIST 97.35/KMNIST 89.30）。**但 σ 效应很轻**（σ0→0.3：Fashion −1.5pp、MNIST −0.65、KMNIST −2.5）。

## 3. 我的关键判断（请逐条判定 对/错/存疑）
- **A**：gate-init+标定**跨三数据集泛化**（MNIST≈ANN 98.4%、KMNIST 89.9%），承重假设(output-scale 近均匀 / gate-init 复现 ANN)成立、非 Fashion 特异。
- **B**：数字鲁棒性优雅降级是 V2C 真测结果、可信。
- **C（最不确定，重点审）**：**家酿 analog 模型不构成"模拟崩"**——per-weight σ 在大 fan-in MAC 里被平均掉（SNR~√N/σ），太轻；真实模拟脆弱主要来自**不被平均的项**（drift、ADC 动态范围、IR-drop、非线性、read noise）。**故我决定：analog 对照锚定已发表数据（σ>10% 退化、drift 1月 68%→19%、SAF），家酿 σ-模型仅作 illustrative/optimistic 补充。** V2C 论点改写为"数字二值+1-bit sense+无 ADC → 结构上零暴露于这些退化源"。

## 4. (A) 严格审查（P0/P1/P2）
1. **Phase A 方法学**：calib-on-train→report-on-test 的乐观（KMNIST calib 0.97 vs test 0.90 的 gap 是 KMNIST 难/分布偏移还是过拟合标定？）；坐标搜索的局部最优；3 seeds 够不够定稿。
2. **数字故障模型**：i.i.d. per-cell stuck/flip on packed binary cells（`robustness.inject_cell_faults`）是不是对的抽象？full-frame 是不是对的鲁棒性度量（vs 早停点）？**故障率该不该从器件参数（on/off ratio、sense margin、SAF 率 1.75%LRS/9%HRS）映射成物理 read-BER，而不是抽象扫 0-20%？**
3. **golden 一致性**：`ramp_output_trajectories(layers=faulted)` 注故障后走的还是同一 golden 路径吗？`faulted_full_frame_acc` 的 argmax(final membrane) 口径对吗？

## 5. (B) ★ analog 基线公平性（最重点——请给明确意见）
1. 我的判断"per-weight σ 因 fan-in averaging 太轻、不可信"对吗？真实模拟 CIM 在 σ=10-30% 的实际掉点是多少（给文献数）？
2. **要不要在模型里加不被平均的项**（drift / ADC 动态范围不足 / IR-drop / 列向 read noise ∝ 信号）？若加，加哪个最关键、怎么参数化才不算 over-modeling？
3. 还是说 **"数字实测 + analog 文献锚定 + 家酿仅 illustrative"** 就是最稳、审稿人最认的做法？一个器件可靠性审稿人会接受哪种？
4. 公平性红线：同一网络/同一精度比，digital 的"故障率 r"和 analog 的"σ"怎么对齐才公平（二者是不同物理量）？

## 6. (C) 调研 / 更优做法
1. **最强、最诚实的鲁棒性 claim 应该怎么写**？"immune-by-construction + 实测数字降级 + 文献模拟脆弱" vs 一张 head-to-head 曲线——哪个更稳、更有冲击力？
2. 有没有**别人已发表的"数字二值/SRAM CIM vs 模拟 CIM" variation 对照**可直接对标/引用？
3. 进 RTL 前，**Python 侧还有什么必须先钉死的**（多 seed 定稿？三数据集都补鲁棒性多 seed？SOP-J 的算法侧计数？）？
4. 站在"鲁棒性是 SOTA 轴 + 延迟/功耗需 RTL"的战略上，RTL 阶段最该先量化哪几个数（cycles/µJ-inf/TOPS-W/SOP-J）来支撑 headline，对标谁（22nm TTFS ASIC 95.67µJ/30FPS F-MNIST）？

## 7. 输出格式
P0/P1/P2 分组逐条（问题 + `文件:行号` + 对/错/存疑 + 建议）；第 5 节给"我若是你会怎么做 analog 基线"的明确取舍；第 6 节按"进 RTL 前必做 / 可选"排序。
