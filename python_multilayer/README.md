# python_multilayer — V2 多层 SNN 建模

> **Phase V2.A 产物**。配合 RTL `v2` 分支（feature frozen 2026-04-18）和 `doc/17_v2_roadmap.md` 使用。
>
> 论文 B 卖点：**"Firmware-Driven, Configurable Multi-Layer FC SNN Accelerator"**
> —— 架构灵活性（`num_fc_stages` 1-4 可配 + 每 stage 输出神经元数 1-64 可配）
> MNIST 8×8 作为 demo，**3 个 V2 demo 拓扑均 ≥ 95% test accuracy**。

## 目录

```
python_multilayer/
├── topologies.yaml              ← 权威 manifest（所有 consumer 共读）
├── topologies.py                ← pydantic schema + loader
├── config_multilayer.py         ← V1 冻结参数 + V2 新增常量
│
├── _vendored_from_v1/           ← 从 V1 copy 的 bit-frozen 函数（不改）
│   ├── data_utils.py            ← downsample_batch (MNIST avgpool8x8)
│   ├── integer_reference.py     ← rtl_snn_inference / rtl_adc_scale (V1 整数路径)
│   └── quantization.py          ← _fake_quantize_signed / _apply_qat_noise
│
├── trainer_multilayer.py        ← MultiLayerANN + train_multilayer()
├── snn_engine_multilayer.py     ← RTL-like multilayer reference (A2.5)
├── exporter_multilayer.py       ← 分层 HEX + manifest.json
│
├── run_baseline_64to10.py       ← A1.2 V1 baseline bit parity
├── run_multilayer.py            ← 主入口（训练 / rtl-like-ref / export）
│
├── tests/
│   ├── test_topology_schema.py
│   ├── test_baseline_parity.py
│   └── test_exported_hex_parity.py
│
├── results_multilayer/          ← 输出（每拓扑一子目录）
│   └── <topology_name>/
│       ├── weights/              (L{i}_{pos,neg}.hex)
│       ├── manifest.json         (stage meta + nonzero_cells + SHA-256)
│       └── summary.txt
│
├── requirements.txt
└── README.md
```

## 拓扑

| name | role | `num_fc_stages` | 拓扑 | 用途 |
|---|---|---|---|---|
| `64to10_baseline` | `v1_frozen_baseline` | 1 | 64→10 | A1.2 bit parity，不训练 |
| `64_24_10` | `v2_demo` | 2 | 64→24→10 | 小拓扑，demo |
| `64_32_10` | `v2_demo` | 2 | 64→32→10 | 标准 demo |
| `64_32_16_10` | `v2_demo` | 3 | 64→32→16→10 | 完整时间复用 demo |

## 快速开始

```bash
# 1. 安装依赖
pip install -r requirements.txt

# 2. schema 校验（最快 sanity check）
pytest tests/test_topology_schema.py -v

# 3. V1 baseline bit parity（A1.2 硬门槛）
python run_baseline_64to10.py          # 期望 PASS 100/100

# 4. V2 demo 拓扑训练（A2，每个 30-60 min CPU）
python run_multilayer.py --train --topology 64_24_10
python run_multilayer.py --train --topology 64_32_10
python run_multilayer.py --train --topology 64_32_16_10

# 5. RTL-like multilayer reference（A2.5）
python run_multilayer.py --rtl-like-ref --topology 64_32_10

# 6. 导出 HEX + manifest（A3）
python run_multilayer.py --export --topology 64_32_10

# 7. 全流程（训练 + reference + export）
python run_multilayer.py --all --topology 64_32_10

# 8. 导出 bit parity 测试
pytest tests/test_exported_hex_parity.py -v
```

## H1 follow-up gates

- `python h1_smoke_full_set.py`
  - Config #2 (`v2b_fc_fashion14_2L`) smoke for the H1 full-set flow.
  - Rebuilds `essay/exp_h1_schedule_ablation/summary_v2b_fc_fashion14_2L.csv`
    from the current raw CSVs and emits `H1_SMOKE_FULL_SET_PASS`.
- `python h1_lenet5_equivalence_check.py`
  - 100-sample LeNet-5 slow/fast equivalence gate on Config #4
    (`v2b_lenet5_mnist_28x28`) using the same deterministic subset as
    `m2_real_inference.py`.
  - Checks both `baseline` and `reset_mixed_soft_early`, writes
    `essay/exp_h1_schedule_ablation/h1_lenet5_equivalence_check.json`,
    and emits `H1_LENET5_EQUIVALENCE_PASS` on zero mismatches.

## 关键口径

### 数据集 + 预处理
- MNIST 28×28 → `torch.nn.functional.adaptive_avg_pool2d` → 8×8 (=64 维 uint8)
- **预处理必须 bit 一致**（V1 _vendored_from_v1/data_utils.py）

### 训练口径
- `MultiLayerANN`（PyTorch）使用 `nn.Linear(bias=False)` + 中间层 `ReLU`
- **ReLU 只是训练代理**，RTL 多层实际是 binary spike mask + LIF
- QAT: 4-bit 量化 + 器件电导级 + 噪声注入（`_fake_quantize_signed` + `_apply_qat_noise`）
- 30-40 epochs，SGD + momentum 0.9

### 三级 accuracy 口径（严格区分）
1. **Python float** test accuracy — ReLU 连续激活，最理想
2. **Python quantized** test accuracy — 4-bit 量化后，float 推理
3. **RTL-like integer** accuracy — `snn_engine_multilayer.snn_inference_multilayer`，这是 RTL 真正会产生的结果
4. **A6.a bit parity** — Python quantized-export vs Python quantized-from-hex 必须 100/100 一致（不是 accuracy 对比，是 bit 对比）

### 层间语义（关键！）
- **Stage 0**：uint8 输入 → bit-plane 展开 8 次 → `timesteps=10` → 累积膜电位 + LIF → `spike_counts`
- **Stage N>0**：**binary spike mask**（上一层 `spike_counts > 0`）→ 一次 MAC → `timesteps=1` → binary mask

### 阈值
- Stage 0：绝对阈值 2550（= 1/255 × 255 × 10）
- Stage N>0：**默认 100**，A2.5 要做 calibration（sweep [50, 300]）

## 搬到服务器

```bash
# 本机执行完后，把这 2 个目录一起 scp 到服务器
scp -r python_multilayer/ user@server:/path/
scp -r "项目相关文件/器件对齐/器件相关参数与数据/" user@server:/path/项目相关文件/器件对齐/

# 服务器上
cd /path/python_multilayer
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
pytest tests/ -v
python run_multilayer.py --all --topology 64_32_16_10
```

## 外部依赖

V2 项目本身完全独立，但依赖 V1 的器件物理模型（`memristor_plugin.py` + `I-V.xlsx`），通过 `config_multilayer.setup_v1_import_paths()` 加入 sys.path（不 copy，因为 `I-V.xlsx` 是测量数据，V2 应该跟随最新物理）。

V1 baseline bit parity（A1.2）需要 V1 的预量化 hex：
- `项目相关文件/器件对齐/Python建模/results/exports/weight_pos.hex`
- `项目相关文件/器件对齐/Python建模/results/exports/weight_neg.hex`
- `项目相关文件/器件对齐/Python建模/results/exports/rtl_stimulus_batch100/alignment_manifest.json`

## 不修改 V1

V1 代码（`项目相关文件/器件对齐/Python建模/`）已 **2026-03 冻结**，V2 绝不修改 V1 任何文件。
需要复用的函数以 bit-identical copy 方式存入 `_vendored_from_v1/`，复制时保留原始 docstring 和源位置注释。
