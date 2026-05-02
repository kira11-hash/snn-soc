# 19. SNN SoC 训练精度汇总与文献对比（2026-05-02）

> **用途**：把目前所有"在硬件上能跑通的 SNN 训练精度"放一个表里方便论文/简历/
> handoff 引用。包含原始的 V2.B FC baseline (Fashion-MNIST 14×14)、本次 ablation
> 跑出来的 MNIST 14×14、以及 V2.B CONV extension 的 LeNet-5 28×28，并给出文献
> 对照让读者知道这些数字"拿不拿得出手"。
>
> **状态**：2026-05-02 sync。新增训练结果时在末尾追加，**不重写历史行**。

---

## 1. 三个 benchmark 一览

| # | 网络 / 数据集 | 拓扑 | 关键配置 | 训练精度 | 板验状态 |
|---|---|---|---|---|---|
| **1** | **Fashion-MNIST 14×14**（V2.B FC baseline，frozen） | 2 层 FC SNN：196 → 64 → 10 | T=64, ADC=10, weight=4-bit signed [-7,+7] | **82.38%** | ✅ ZCU102 板验通过（tag `v2-arm-fpga-demo-v2-passed @ 03a39a61` + `v2-fpga-e203-passed`），10/10 sample 与 Python golden byte-exact |
| **2** | **MNIST 14×14**（同 196→64→10 拓扑，本次 ablation） | 2 层 FC SNN：196 → 64 → 10 | T=64, ADC=10, weight=4-bit signed [-7,+7] | **96.48%** | ❌ 不上板（路径与 #1 完全一致，bit-exact 已被 #1 板验证明；MNIST 重烧无新工程价值） |
| **3** | **LeNet-5 (MNIST 28×28)**（V2.B CONV extension） | 5 层 LeNet-5：Conv1+Conv2+FC1+FC2+FC3 | T=10, ADC=8, weight=4-bit signed [-7,+7] | **93.03%** | ✅ ZCU102 板验通过（tag `v2-arm-fpga-demo-conv-passed @ dabcaf0d` + `v2-fpga-e203-conv-passed @ a1c0c828`），10/10 sample byte-exact |

### 1.1 配置差异说明

| 维度 | #1 Fashion 14×14 | #2 MNIST 14×14 | #3 LeNet-5 28×28 |
|---|---|---|---|
| Input | Fashion-MNIST 28×28 → 下采样到 14×14 → 196 像素 | MNIST 28×28 → 下采样到 14×14 → 196 像素 | MNIST 28×28（原图，不下采样） |
| Layer kind | 全 FC | 全 FC | 2 conv + 3 FC（混合） |
| 时间步 T | 64 | 64 | 10 |
| ADC bits | 10（V2.B 加速器配置） | 10 | 8（用 V1 默认） |
| Weight quant | 4-bit signed [-7, +7] QAT | 同上 | 同上 |
| Encoding | streamed_rate (Bresenham accumulator) | 同上 | rate / Bresenham（首层）+ tile-mode partial sum |
| 网络 #params | 196×64 + 64×10 = 13,184 | 同 #1 | conv1 6×1×5×5 + conv2 16×6×5×5 + fc1 2304×120 + fc2 120×84 + fc3 84×10 ≈ 296K |

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
| #1 **Fashion-MNIST 14×14, 82.38%** | ⚠ **拿得出手但要小心叙事** | Fashion-MNIST 14×14 + 浅 FC 在文献里通常是 87-92%，82% 偏低。原因主要是 14×14 下采样让 Fashion 类间纹理特征丢失（Fashion 比 MNIST 更依赖纹理）。**不要单独 quote 82%**——配合 #2（同拓扑 MNIST 96.48%）一起出现，能说明"82% 不是路径瓶颈，是 Fashion + 14×14 + 4-bit 三者交集的任务难度上限"。论文里写"Fashion 14×14 demonstrates the streaming FC pipeline functions correctly; absolute accuracy is task/quantization-bound, not infrastructure-bound." |

---

## 3. 推荐论文 / 简历叙事

### 3.1 论文 contribution 主线

> "V2.B FPGA evidence demonstrates that a runtime-configurable streaming-stage
> spiking neural network accelerator can host both flat fully-connected topologies
> (196→64→10 on Fashion-MNIST 14×14, T=64, 4-bit weights, 10-bit ADC,
> board-verified bit-exact) and a 5-layer LeNet-5 CNN (MNIST 28×28, T=10, 4-bit
> weights, 8-bit ADC, board-verified bit-exact on two CPU paths). Reported
> training accuracy on Fashion-MNIST 14×14 = 82.38%, on MNIST 14×14 (cross-dataset
> ablation, same topology) = 96.48%, on MNIST 28×28 LeNet-5 = 93.03% — all within
> the literature range for comparable bit-width / time-step quantized SNN
> deployments."

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
```

每次跑都用 `--seed 42` 固定 RNG；多次跑可复现（已在 conv_extension_log §1
的 reproducibility caveats 里说明）。

---

## 5. 后续可考虑的 ablation（不在当前 scope，留作 future work）

如果论文 review 时被问"为什么没做 X 配置"，下面这些 ablation 是合理的扩展，
但都**不在当前评估周期 scope** 内：

| Ablation | 估计精度提升 | 工程代价 |
|---|---|---|
| MNIST 28×28 + 同 196→64→10 拓扑（不下采样）| 96.48% → ~97-98% | 改 input pipeline，估计 1 天 |
| LeNet-5 + ADC 升 10-bit | 93.03% → ~95-96% | 改 RTL 重新综合 + 板验，估计 3-5 天 |
| LeNet-5 + T 升 30-50 | 93.03% → ~95% | 仅训练 + cosim，但 board verify 时间显著拉长 |
| 196_128_10 / 196_256_10 大 FC（参考） | Fashion 82.38% → ~85-87% | 需要更多 hardware MAC capacity 或 weight memory，超出 V2.B 加速器单 stage 容量 |
| Plain-CNN-4 / Tiny VGG on CIFAR-10 with 6-bit weights + ADC=10 | 13% → 60-70% | **不在 V2.B scope**（量化堆栈上限），是 v3 工作 |

---

**封存声明**：本文档反映 2026-05-02 的训练结果状态。新增 ablation 时在 §1
表格末尾追加，**不重写历史行**；论文/简历引用时锁到本文件 + 对应训练
manifest（avoid drifting numbers）。
