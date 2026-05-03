# 19. SNN SoC 训练精度汇总与文献对比（2026-05-03）

> **用途**：把目前所有"在硬件上能跑通的 SNN 训练精度"放一个表里方便论文/简历/
> handoff 引用。包含原始的 V2.B FC baseline (Fashion-MNIST 14×14)、本次 ablation
> 跑出来的 MNIST 14×14、V2.B CONV extension 的 LeNet-5 28×28、Fashion-MNIST 28×28
> raw-input 路径、LeNet-5 on Fashion-MNIST 28×28（4-bit 量化栈天花板对照），以及
> 最新的 T-extension trade-off 三组（T=10/30/50 sweep on LeNet-5 Fashion + MNIST），
> 并给出文献对照让读者知道这些数字"拿不拿得出手"。
>
> **状态**：2026-05-03 update（新增 §5 T-extension trade-off 表 — 3 组新 ablation
> 全部 cosim bit-exact PASS）。新增训练结果时在末尾追加，**不重写历史行**。

---

## 1. 三个 benchmark 一览

| # | 网络 / 数据集 | 拓扑 | 关键配置 | 训练精度 | 板验状态 |
|---|---|---|---|---|---|
| **1** | **Fashion-MNIST 14×14**（V2.B FC baseline，frozen） | 2 层 FC SNN：196 → 64 → 10 | T=64, ADC=10, weight=4-bit signed [-7,+7] | **82.38%** | ✅ ZCU102 板验通过（tag `v2-arm-fpga-demo-v2-passed @ 03a39a61` + `v2-fpga-e203-passed`），10/10 sample 与 Python golden byte-exact |
| **2** | **MNIST 14×14**（同 196→64→10 拓扑，本次 ablation） | 2 层 FC SNN：196 → 64 → 10 | T=64, ADC=10, weight=4-bit signed [-7,+7] | **96.48%** | ❌ 不上板（路径与 #1 完全一致，bit-exact 已被 #1 板验证明；MNIST 重烧无新工程价值） |
| **3** | **LeNet-5 (MNIST 28×28)**（V2.B CONV extension） | 5 层 LeNet-5：Conv1+Conv2+FC1+FC2+FC3 | T=10, ADC=8, weight=4-bit signed [-7,+7] | **93.03%** | ✅ ZCU102 板验通过（tag `v2-arm-fpga-demo-conv-passed @ dabcaf0d` + `v2-fpga-e203-conv-passed @ a1c0c828`），10/10 sample byte-exact |
| **4** | **Fashion-MNIST 28×28**（同 196→64→10 拓扑放大到 784→64→10，本次 ablation） | 2 层 FC SNN：784 → 64 → 10 | T=64, ADC=10, weight=4-bit signed [-7,+7] | **84.05%** | ❌ 不上板（Python ideal matmul 训练，未做 multi-tile bit-exact；784 输入需要 V2.B tile_mode=1 FC 路径整合后才能 byte-exact 板验，超本计划 scope） |
| **5** | **LeNet-5 (Fashion-MNIST 28×28)**（用 #3 同拓扑跑 Fashion，本次 ablation） | 5 层 LeNet-5：Conv1+Conv2+FC1+FC2+FC3 | T=10, ADC=8, weight=4-bit signed [-7,+7] | **81.99%** （float proxy 90.94%）| ✅ Sim cosim bit-exact 通过（10/10 sample byte-exact，golden_counts SHA `d952f218...` = rtl_counts SHA），不重烧 ZCU102（路径与 #3 完全一致，仅换 weight + input fmap hex；bit-exactness 已被 #3 板验证明） |

### 1.1 配置差异说明

| 维度 | #1 Fashion 14×14 | #2 MNIST 14×14 | #3 LeNet-5 MNIST | #4 Fashion 28×28 FC | #5 LeNet-5 Fashion |
|---|---|---|---|---|---|
| Input | Fashion-MNIST 28×28 → 下采样到 14×14 → 196 像素 | MNIST 28×28 → 下采样到 14×14 → 196 像素 | MNIST 28×28（原图，不下采样） | Fashion-MNIST 28×28（原图，不下采样）→ 784 像素 | Fashion-MNIST 28×28（原图，不下采样） |
| Layer kind | 全 FC | 全 FC | 2 conv + 3 FC（混合） | 全 FC | 2 conv + 3 FC（混合） |
| 时间步 T | 64 | 64 | 10 | 64 | 10 |
| ADC bits | 10（V2.B 加速器配置） | 10 | 8（用 V1 默认） | 10 | 8 |
| Weight quant | 4-bit signed [-7, +7] QAT | 同上 | 同上 | 同上 | 同上 |
| Encoding | streamed_rate (Bresenham accumulator) | 同上 | rate / Bresenham（首层）+ tile-mode partial sum | 同上（首 FC 需 tile_mode=1, 4 tiles，但 Python 用 ideal matmul） | rate / Bresenham（首层）+ tile-mode partial sum（与 #3 完全一致） |
| 网络 #params | 196×64 + 64×10 = 13,184 | 同 #1 | conv1 6×1×5×5 + conv2 16×6×5×5 + fc1 2304×120 + fc2 120×84 + fc3 84×10 ≈ 296K | 784×64 + 64×10 = 50,816 | 同 #3 ≈ 296K |
| Float proxy 精度 | — | — | ~99% | — | **90.94%**（PyTorch fp32 LeNet on Fashion） |
| Quant SNN 精度 | 82.38% | 96.48% | 93.03% | 84.05% | **81.99%**（vs proxy -8.95 pp） |

### 1.2 板验 selected accuracy 红线

#1 / #3 上板时拿到的 `selected_accuracy = 1.0`（10/10 sample byte-exact）**不是** test-set
精度——它只证明：
- 选定的 10 个 class-first 样本（每类各一）在硬件上跑出的 spike count
- **字节级匹配** Python integer reference 算出的 spike count
- argmax(counts) == Python golden 的 expected_class

这是 **firmware ↔ golden 一致性证据**（"硬件没算错"），不是 **任务精度证据**
（"网络认对了多少张图"）。**论文真精度只能引用上面表 §1 的训练精度
（10000 张 test set 上的）**，不能引用 selected_accuracy=1.0。

---

## 2. 文献对比：MNIST 上的 SNN 精度（"拿不拿得出手"）

> 这里只做 **consistency check**，不做严格 SOTA review。目的是让读者知道
> 96.48% / 93.03% 在文献里大概什么档位，以便论文叙事时不浮夸也不自卑。

### 2.1 MNIST 上的 SNN 精度大致区间

| 档位 | 大致精度区间 | 代表性配置 | 备注 |
|---|---|---|---|
| **Floor**（早期 LIF + STDP） | 85–92% | Diehl & Cook 2015 等，无量化、纯无监督 | 学术上"能跑"但不算 hardware-friendly |
| **中段**（量化 + 浅网络 + 短 T） | 93–97% | 4-bit / 8-bit quantized FC SNN，T=10–64，2 层 | 我们 #2/#3 的档位 |
| **高段**（深网络 / ANN→SNN 转换 / 长 T） | 97–99% | Sengupta 2019 / Cao 2015 / TrueNorth IBM 等，full precision 或 8-bit ADC，5+ 层，T=100–500 | 工程代价大，硬件友好度差 |
| **Ceiling**（28×28 极限）| 99%+ | full-precision deep CNN | 不在 SNN paper 主流叙事范围 |

### 2.2 同 hardware-friendly 约束下的横向对比（4-bit weights、短 T、tiny FC / small CNN）

| 工作 | 数据集 | 网络 | weight bits | T | 精度 | 备注 |
|---|---|---|---|---|---|---|
| **本工作 #2** | **MNIST 14×14** | **196→64→10 FC** | **4** | **64** | **96.48%** | **本次 ablation** |
| **本工作 #3** | **MNIST 28×28** | **LeNet-5** | **4** | **10** | **93.03%** | **本次 V2.B CONV path** |
| **本工作 #4** | **Fashion-MNIST 28×28** | **784→64→10 FC** | **4** | **64** | **84.05%** | **本次 ablation（Python ideal matmul，未板验）** |
| **本工作 #5** | **Fashion-MNIST 28×28** | **LeNet-5** | **4** | **10** | **81.99%** | **本次 ablation（与 #3 同 RTL 路径，cosim bit-exact PASS，未重烧 FPGA）** |
| **本工作 #1** | **Fashion-MNIST 14×14** | **196→64→10 FC** | **4** | **64** | **82.38%** | **本次 V2.B FC baseline** |
| Loihi (Intel) | MNIST 28×28 | 多种小 SNN | 8 | 100+ | 96–97% | 8-bit weights, longer T |
| TrueNorth (IBM) | MNIST 28×28 | 较大深网 | "synaptic crossbar" ~16 levels | rate-coded | ~99% | 体量大很多 |
| TENNLab/Caspian | MNIST 28×28 | 浅 SNN | 8 | 10–50 | 96–97% | 与我们同量级 |
| 各 4-bit / 2-bit quant SNN paper（学界中段，2022–2024）| MNIST 28×28 | 2–4 层 | 2–4 | 8–32 | 95–97% | 我们 #2 / #3 的同档 |

> ⚠ **不引用具体 paper 数字到论文里**——以上区间是个人记忆，论文 review 时
> 必须自己查 reference 核实。这里只用作"我大概在哪个档位"的内部 sanity check。

### 2.3 你的数字"拿不拿得出手"

| 我的结果 | 评级 | 解读 |
|---|---|---|
| #2 **MNIST 14×14, 96.48%** | ✅ **拿得出手**（中段偏上） | 在 4-bit weights + T=64 + 14×14 input + 13K params 这种 hardware-friendly tiny-FC 约束下，96.48% 与文献中段量化 SNN 一致；考虑 14×14 比 28×28 信息少 1-2 pp 的预期，相当于 "compensated 28×28-equivalent" ~98%，是上佳的 baseline number |
| #3 **MNIST 28×28 LeNet-5, 93.03%** | ✅ **拿得出手**（中段，注意低于 #2） | 看似比 #2 低 ~3 pp 反直觉，但因为 (a) T 从 64 缩到 10（4 倍少时间步） (b) ADC 从 10-bit 缩到 8-bit (c) 网络深 5 层有 cascaded 量化误差累积。在 4-bit / T=10 / ADC=8 约束下 LeNet-5 跑到 93% 可接受；如果想冲 96%+ 需要 T 加到 30-50 + ADC=10。这是 **trade-off 透明叙事**而不是缺点 |
| #1 **Fashion-MNIST 14×14, 82.38%** | ⚠ **拿得出手但要小心叙事** | Fashion-MNIST 14×14 + 浅 FC 在文献里通常是 87-92%，82% 偏低。原因主要是 14×14 下采样让 Fashion 类间纹理特征丢失（Fashion 比 MNIST 更依赖纹理）。**不要单独 quote 82%**——配合 #2（同拓扑 MNIST 96.48%）和 #4（同拓扑 Fashion 28×28 84.05%）一起出现，能说明"82% 不是路径瓶颈，是 Fashion + 14×14 + 4-bit 三者交集的任务难度上限"。论文里写"Fashion 14×14 demonstrates the streaming FC pipeline functions correctly; absolute accuracy is task/quantization-bound, not infrastructure-bound." |
| #4 **Fashion-MNIST 28×28, 84.05%** | ⚠ **拿得出手但要小心叙事，同时是关键 ablation 证据** | 把 #1 的 14×14 input 升到原始 28×28 raw（拓扑保持 2-FC，仅首层 in_dim 从 196 升到 784）只买到 +1.67 pp（82.38% → 84.05%）。这是"Fashion 14×14 不是分辨率瓶颈"的直接证据：4× 像素只换 1.67 pp 说明瓶颈在 4-bit weight + 浅 FC + Fashion 任务难度，不在 avgpool 下采样。**论文里**：用 #4 反驳"82% 是不是因为下采样太狠"的潜在 reviewer 质疑——同拓扑放大 input 也只到 84%，下采样不背锅。**简历里**：通常不单独 quote 84.05%，可作为 #1 的旁证；如果需要单独提，说明清楚"Python ideal matmul 训练精度，未板验"。 |
| #5 **LeNet-5 (Fashion-MNIST 28×28), 81.99%** | ⚠ **拿得出手但同时是 quantization-stack ceiling 证据** | PyTorch float LeNet-5 baseline 90.94% → quant SNN 81.99%（4-bit weight + T=10 + 8-bit ADC 量化栈丢 -8.95 pp）。这与 #1 / #4 在同一个量化天花板（~82-84%）撞上：**不论换 FC 还是 LeNet-5 conv，Fashion-MNIST 在 V2.B 4-bit / T=10 / ADC=8/10 stack 下都收敛到 ~82%**。论文里：(a) **不**说"加 conv 就能解决 Fashion 82%"——本 ablation 直接反证；(b) **要**说"V2.B 量化栈在 MNIST 上还有头部空间（93-96%），在 Fashion 上撞了量化天花板，与 CIFAR-10 上的 13% plateau 是同一现象的不同程度（详见 conv_extension_log.md §2.2）"；(c) 为什么这个数仍 valuable：是 V2.B CONV 路径**已 board-verified bit-exact**（#3）的同路径运行，10/10 sample byte-exact 自洽（cosim PASS golden_counts SHA = rtl_counts SHA = `d952f218...`），把"路径正确性"和"任务精度"分开 — 体现工程严谨性。**简历里**：通常不单独 quote 81.99%；和 #3 一起出现说"同路径 dataset swap，MNIST 93% / Fashion 82%，是 quant stack 在两个任务上的天然差距，不是路径问题"。 |

---

## 3. 推荐论文 / 简历叙事

### 3.1 论文 contribution 主线

> "V2.B FPGA evidence demonstrates that a runtime-configurable streaming-stage
> spiking neural network accelerator can host both flat fully-connected topologies
> (196→64→10 on Fashion-MNIST 14×14, T=64, 4-bit weights, 10-bit ADC,
> board-verified bit-exact) and a 5-layer LeNet-5 CNN (MNIST 28×28, T=10, 4-bit
> weights, 8-bit ADC, board-verified bit-exact on two CPU paths). Reported
> training accuracy: Fashion-MNIST 14×14 = 82.38%, MNIST 14×14 (cross-dataset
> ablation, same topology) = 96.48%, MNIST 28×28 LeNet-5 = 93.03%,
> Fashion-MNIST 28×28 (raw-input ablation, 784→64→10) = 84.05%, and
> Fashion-MNIST 28×28 (LeNet-5 path, ablation) = 81.99% (sim cosim
> bit-exact, PyTorch float proxy 90.94%) — all within the literature range
> for comparable bit-width / time-step quantized SNN deployments. The
> 14×14 vs 28×28 Fashion ablation (+1.67 pp for 4× pixels) and the
> LeNet-5-vs-FC ablation on Fashion (no architectural lift over FC at this
> quantization stack) jointly indicate that Fashion accuracy is bounded by
> the 4-bit weight / short-T / 8-10-bit ADC quantization stack, not by
> input resolution or by FC-vs-conv architecture choice."

### 3.2 简历表述

> "Designed and FPGA-prototyped a runtime-configurable SNN accelerator (V2.B);
> demonstrated bit-exact end-to-end inference for FC SNN on Fashion-MNIST 14×14
> (82.38%) and a 5-layer LeNet-5 CNN on MNIST 28×28 (93.03%) under 4-bit weight,
> 8/10-bit ADC, T=10/64 hardware-friendly constraints; verified on ZCU102 with
> ARM Cortex-A53 + E203 RISC-V dual CPU paths."

### 3.3 红线（不能写的）

- ❌ "demonstrates state-of-the-art accuracy" / "best-in-class" — 不是
- ❌ "outperforms TrueNorth / Loihi" — 没做严格对比，体量也不同
- ❌ "tested on CIFAR-10" — Tiny VGG/Plain-CNN-4 主动收兵了（plateau ~13%），
  论文不当 contribution（详见 `doc/v2-architecture/conv_extension_log.md` §2.2）
- ❌ "selected_accuracy = 1.0 means 100% MNIST accuracy" — 不是；那是
  byte-exact match Python golden 的 10 个样本，不是 test set 精度

---

## 4. Reproduction 命令

```bash
cd python_multilayer

# (1) Fashion-MNIST 14×14 baseline (82.38%) ── 已存在 frozen artifact
python run_streamed_rate_train.py --topology 196_64_10 --epochs 30 --seed 42

# (2) MNIST 14×14 cross-dataset ablation (96.48%) ── 本次新增
python run_streamed_rate_train.py --topology 196_64_10 \
    --dataset-override mnist --tag _mnist14 --epochs 30 --seed 42
# 输出：python_multilayer/results_multilayer/196_64_10__mnist14/
#       summary.txt + model.pt （在 arm-conv 分支 commit f9ca16a9）

# (3) LeNet-5 MNIST 28×28 (93.03%) ── V2.B CONV path
python gen_convnet_golden.py --network lenet5
# 输出：python_multilayer/results_conv/lenet5/lenet5_golden_manifest.json
#       quant_snn_test_accuracy = 0.9303

# (4) Fashion-MNIST 28×28 raw-input ablation (84.05%) ── 本次新增
python run_streamed_rate_train.py --topology 784_64_10 --epochs 30 --seed 42
# 输出：python_multilayer/results_multilayer/784_64_10/
#       summary.txt + model.pt （在 v2 分支 commit 提交）
# 注意：784 输入需要 V2.B tile_mode=1（4 个 256-tile partial-sum 累加）才能
# byte-exact 板验；当前 Python forward 用 ideal matmul，未做 multi-tile
# RTL bit-exact mapping，因此本数字仅作为训练精度参考，不可上板。

# (5) LeNet-5 on Fashion-MNIST 28×28 ablation (81.99%) ── 本次新增
python gen_convnet_golden.py --network lenet5 \
    --dataset-override fashion_mnist --tag _fashion --samples 10
# 输出：python_multilayer/checkpoints/lenet5_snn_fashion.pth
#       python_multilayer/results_conv/lenet5_fashion/
#         + lenet5_golden_manifest.json (quant_snn_test_acc=0.8199, selected=0.9)
#         + sample_NN_*.hex / weights/ (10 个 class-first sample 的整数 golden)
#         + cosim_full_log.txt (LENET5_COSIM_TB_PASS marker)
# RTL bit-exact 验证（与 #3 共用同一 cosim TB，仅换 bundle）：
# 该 evidence branch 不携带历史 wrapper `sim/run_lenet5_cosim.sh`；
# 归档的 full cosim 输出见：
#   python_multilayer/results_conv/lenet5_fashion/cosim_full_log.txt
# 通过标准：LENET5_COSIM_TB_PASS mode=--full bundle=lenet5_fashion samples=10
# 关键 SHA（golden ↔ rtl 必须相等）：
#   golden_counts_concat = rtl_counts_dump =
#     d952f218c3874aa88041db669fb7d898a25bc79590260423aa7f848b8a863627
# 注意：本结果 RTL 路径与 #3 (MNIST LeNet-5) 完全一致（仅 weight + input
# fmap hex 不同），#3 已 byte-exact 板验通过。本 ablation 不重烧 ZCU102。

# (6) T-extension trade-off ablation（T=10 → T=30 → T=50 sweep）
# MNIST T=30:
python gen_convnet_golden.py --network lenet5 \
    --tag _t30 --t-override 30 --samples 10
# 归档 smoke cosim 输出：
#   python_multilayer/results_conv/lenet5_t30/cosim_smoke_log.txt
#   quant_snn_test_acc=0.9355, cosim SHA=45273d4bea77ee129446380d5f851e7bd962efe6fb1805f48310a846012a934d
# MNIST T=50:
python gen_convnet_golden.py --network lenet5 \
    --tag _t50 --t-override 50 --samples 10
# 归档 smoke cosim 输出：
#   python_multilayer/results_conv/lenet5_t50/cosim_smoke_log.txt
#   quant_snn_test_acc=0.9281, cosim SHA=aa1c33289d92e22abdb954e43cfb2f01626b295d676d0c2d66ad5319938a3d80
# Fashion T=30:
python gen_convnet_golden.py --network lenet5 \
    --dataset-override fashion_mnist --tag _fashion_t30 --t-override 30 --samples 10
# 归档 smoke cosim 输出：
#   python_multilayer/results_conv/lenet5_fashion_t30/cosim_smoke_log.txt
#   quant_snn_test_acc=0.8288, cosim SHA=f5ed992337659bcb3609a0f0640a2f4d83915d6c67a348f2b4b6f6c404d25bc3
# Fashion T=50:
python gen_convnet_golden.py --network lenet5 \
    --dataset-override fashion_mnist --tag _fashion_t50 --t-override 50 --samples 10
# 归档 smoke cosim 输出：
#   python_multilayer/results_conv/lenet5_fashion_t50/cosim_smoke_log.txt
#   quant_snn_test_acc=0.8194, cosim SHA=5ea5515990f9578640e7de2e6dbee35ed9f63762ffee85a04045b611c6f68525
```

每次跑都用 `--seed 42` 固定 RNG；多次跑可复现（已在 conv_extension_log §1
的 reproducibility caveats 里说明）。

---

## 5. T-extension trade-off（2026-05-03 新增）

> **目的**：回答"加长 SNN 时间步 T (10→30→50) 能否补上 4-bit 量化栈在 Fashion 上
> 的 9 pp 缺口（PyTorch float 90.94% → quant SNN 81.99%）"。

### 5.1 完整数据（T=10/30/50 × {MNIST, Fashion}，2×3 矩阵）

| 网络 | dataset | T | quant SNN test | vs T=10 | cosim PASS | cosim SHA |
|---|---|---|---|---|---|---|
| LeNet-5 | MNIST 28×28 | 10 | 93.03% | (baseline) | ✅ #3 board-verified | (M4 canonical) |
| LeNet-5 | MNIST 28×28 | **30** | **93.55%** | **+0.52 pp** | ✅ smoke | `45273d4b` |
| LeNet-5 | MNIST 28×28 | **50** | **92.81%** | **−0.22 pp** | ✅ smoke | `aa1c3328` |
| LeNet-5 | Fashion 28×28 | 10 | 81.99% | (baseline) | ✅ full | `d952f218` |
| LeNet-5 | Fashion 28×28 | **30** | **82.88%** | **+0.89 pp** | ✅ smoke | `f5ed9923` |
| LeNet-5 | Fashion 28×28 | **50** | **81.94%** | **−0.05 pp** | ✅ smoke | `5ea55159` |

### 5.2 解读

**核心发现：T=30 是普适 sweet spot，T=50 在两个 dataset 上都不再 buy 任何东西**：

| Dataset | 形状 | 解读 |
|---|---|---|
| MNIST | T=10 → +0.52 → −0.22 | 已接近饱和，T=30 给最后一点 marginal gain，T=50 进入训练噪声区 |
| Fashion | T=10 → +0.89 → −0.05 | T=30 更明显涨，T=50 全消失 |

两个 dataset 的曲线**形状一致**（T=30 sweet spot 然后掉头），只是绝对位置不同。这说明：

1. **T=30 是这套 8-epoch head training + 4000 train_subset 配置下的最优 T**——再多就把
   有限 head 训练预算分摊到太多时间步上，每个 timestep 的 surrogate gradient 信号变弱
2. **T-extension 不是 Fashion 9 pp 缺口的解药**——最高 +0.89 pp，离 PyTorch float
   90.94% 还有 8 pp。瓶颈在 4-bit weight + LIF spike 编码本身，不在时间步数
3. **这是工程上有用的 trade-off 信息**：如果将来 cosim 预算允许再多 3x runtime，
   把 T=10 升到 T=30 是稳赚 +0.5～0.9 pp 的；但 T=50 不要做

### 5.3 性能 trade-off

| T | head training time | cosim runtime（10 sample full）| fmap_sram bank usage（per sample）|
|---|---|---|---|
| 10 | ~3 min | ~30 min | conv1 4704 words, conv2 2304 words |
| 30 | ~8 min | ~75 min（est.）| 不变（stream_words=ceil(30/32)=1）|
| 50 | ~10 min | ~120 min（est.）| **2× words**（stream_words=ceil(50/32)=2，conv1 9408 words, conv2 4608 words）|

T=50 的 stream_words 翻倍意味着 fmap_sram bank A/B 占用翻倍；这是 RTL 路径已经
能 handle 的（V2B_FMAP_BANK_KIB×1024÷4 = 32K words per bank 余量充裕），但 cosim TB
之前按 stream_words=1 hardcode buffer 大小（M4 时只考虑 T=10），本次 ablation 顺手
fix（commit `1de8dd2c` 把 buffer 改成 `× stream_words`，T=10 byte-exact 不变）。

### 5.4 论文/简历叙事用法

**论文**：T-sweep 2×3 矩阵是 quantization-stack-ceiling narrative 的**关键** ablation 证据：
> "Across MNIST and Fashion-MNIST, the LeNet-5 SNN exhibits a consistent T-extension
> behaviour: T=30 yields a small lift (+0.52 pp on MNIST, +0.89 pp on Fashion) and
> T=50 regresses (−0.22 pp on MNIST, −0.05 pp on Fashion). The Fashion gap to PyTorch
> float (90.94%) remains open by 8 pp at the best T, indicating that T-extension is
> not the lever that closes it; further accuracy improvement on Fashion would require
> widening the weight bit-width or moving to graded spikes — both architectural
> changes outside V2.B's 4-bit / 1-bit-spike scope."

**简历**：T-sweep 不是简历的核心 number。引用时**只引用** MNIST T=30 = 93.55% 或
Fashion T=30 = 82.88% 作为"我跑了完整 2×3 T-sweep 曲线，知道 sweet spot 在哪"的工程
严谨性表达，**不要**单独 quote 任何 T=50 值（都是负 trade-off）。

### 5.5 红线（T-sweep 特有）

- ❌ "T=50 给 Fashion / MNIST 加成" — 都不行，两个 dataset 在 T=50 都掉头
- ❌ "T 是 Fashion 的解药" — 反了，最高 +0.89 pp（T=30），不够补 8 pp 缺口
- ❌ "MNIST T=10 已经天花板" — 不准确，T=30 还能再涨 +0.52 pp，但 T=50 才真饱和
- ✅ "T=30 是普适 sweet spot；T=50 在两个 dataset 都不 buy 任何东西" — 正确叙事
- ✅ "T-sweep 2×3 矩阵证明 quant stack 是 Fashion 的瓶颈，不是 T" — 正确叙事

---

## 6. 后续可考虑的 ablation（不在当前 scope，留作 future work）

如果论文 review 时被问"为什么没做 X 配置"，下面这些 ablation 是合理的扩展，
但都**不在当前评估周期 scope** 内：

| Ablation | 估计精度提升 | 工程代价 |
|---|---|---|
| MNIST 28×28 + 784→64→10 拓扑（同 #4 路线但跑 MNIST）| 96.48% → ~97-98% | 重用 #4 的 tile_mode=1 路径，只改 dataset_override，估计 0.5 天 |
| Fashion / MNIST 28×28 + tile_mode=1 RTL bit-exact 板验 | #4 84.05% → 板验同号 | 需要把 V2.B FC tile_mode=1 multi-tile partial-sum 接到 Python integer reference + cosim，估计 5-7 天 |
| LeNet-5 + ADC 升 10-bit | 93.03% → ~95-96% | 改 RTL 重新综合 + 板验，估计 3-5 天 |
| LeNet-5 + T 升 30-50 | 93.03% → ~95% | 仅训练 + cosim，但 board verify 时间显著拉长 |
| 784_128_10 / 784_256_10 大 FC（参考） | Fashion 84.05% → ~86-88% | 需要更多 hardware MAC capacity 或 weight memory，超出 V2.B 加速器单 stage 容量 |
| Plain-CNN-4 / Tiny VGG on CIFAR-10 with 6-bit weights + ADC=10 | 13% → 60-70% | **不在 V2.B scope**（量化堆栈上限），是 v3 工作 |

---

**封存声明**：本文档反映 2026-05-03 的训练结果状态（最近一次更新同时新增 #4
Fashion-MNIST 28×28 raw-input ablation 84.05% + #5 LeNet-5 on Fashion-MNIST
28×28 ablation 81.99% with cosim bit-exact PASS）。新增 ablation 时在 §1
表格末尾追加，**不重写历史行**；论文/简历引用时锁到本文件 + 对应训练
manifest（avoid drifting numbers）。
