# Codex 审查 Prompt — V2 python_multilayer/ 项目代码审查（开工前双保险）

## 背景

这是 Phase V2.A 的 **Day-0 代码交付**。目标是"用户睡觉后我（Claude）后台跑训练，醒来就能搬到服务器"，所以代码必须在开跑前双保险。

- **不要审查 RTL**（rtl/、tb/、sim/）—— V2 RTL 已 feature frozen 2026-04-18，回归 9/9 绿。
- **审查范围**：`d:/SoC Design/SoC Design/python_multilayer/` 下所有 Python 代码 + `topologies.yaml`
- **不审查**：`_vendored_from_v1/` 下的文件是从 V1 bit-for-bit copy 的，我已经手动验证和 V1 `export_expected_spike_ids.py` / `data_utils.py` / `train_ann.py` 语义一致（见下方"我已经做的验证"）。你只需要看 **依赖它们的 V2 新代码**

## 已经做的 3 轮自检

| 轮 | 内容 | 结果 |
|---|---|---|
| R1 | Claude Code code-reviewer agent 独立审查 | 1 HIGH（`--all-topologies` argparse crash）+ 2 MEDIUM + 2 LOW → 已修 |
| R2 | 自己 data-flow trace（类型边界、transpose 方向、pydantic alias、model state_dict key） | 核心路径 LGTM，修 1 处注释 + 加 1 个强约束测试 |
| R3 | pytest schema 24/24 绿 + V1 vs V2 vendored bit-identical 验证 | 全绿 |

关键 bit-parity 验证（R3 实跑）：

```
V1 rtl_snn_inference vs V2 _vendored rtl_snn_inference:
  spike_counts match:    True
  predicted match:       True
  membrane match:        True
  常量: NUM_INPUTS/OUTPUTS/LEVEL_MAX/SUM_MAX/ADC_MAX 全相等

V2 _run_stage_bitplane (A2.5 多层 reference 的 stage 0 路径) vs V1 rtl_snn_inference:
  counts match:    True (random 64x10 weights)
  predicted match: True
  membrane match:  True
```

## 审查任务

### Part 1：功能正确性（最高优先级）

**1. `trainer_multilayer.py` 的训练管线**
- `MultiLayerANN.forward_qat` 在 QAT fine-tune 阶段对每一层独立做 `fake_quantize_signed + apply_qat_noise + ir_drop_scale`。这和 V1 `train_ann.train_model` 的 QAT 实现是否语义等价？V1 是单层，每次 forward 只量化一次；V2 多层是否应该在每层 MAC 前独立量化/加噪声？
- SGD momentum + CrossEntropyLoss 配置是否合理？
- Seed 策略：`torch.manual_seed(seed)` + `DataLoader(generator=...)`，在 PyTorch CPU 上是否足够 deterministic

**2. `snn_engine_multilayer.py` 的 RTL-like 多层推理**
- `_run_stage_bitplane`（stage 0）已验证 bit-identical 于 V1
- `_run_stage_binary`（stage N>0）的语义：
  - 输入是 `spike_mask = (prev_spike_counts > 0).astype(int64)` 二值 0/1 向量
  - timesteps 通常 1，但我允许 YAML 配 > 1（会在同一 mask 上重复累加）
  - soft reset 和 stage 0 一致
  - 请确认这个语义真的匹配未来 RTL 的多层实现（`layer_sequencer.sv` + `spike_feedback.sv` + `lif_neuron_alu.sv`）
- 如果 spike_counts 全零（上一层没 spike），spike_mask 全零，下一层 MAC 结果全零，membrane 永远不过阈值 → final argmax 返回 0 → 可能误分类。这个边界情况是否需要特殊处理？

**3. `exporter_multilayer.py` 的量化 + HEX 导出**
- `_quantize_stage_weights`：`w [out_dim, in_dim] float → t() → [in_dim, out_dim] float → split_differential → quantize_to_levels → [in_dim, out_dim] int`
- HEX 写入是 row-major `[in_dim][out_dim]`（每行一个值）
- 加载回 `load_weight_hex_variable_shape` 返回 `list[list[int]]` shape `[in_dim][out_dim]` → `np.array` → shape `[in_dim, out_dim]`
- **请 double-check：V2 的 quantize_to_levels 实现（`_vendored_from_v1/quantization.py:81-112`）是否和 V1 `export_weight_map.py` 的 HEX 写法 bit-identical？** 我的 `quantize_to_levels` 是重新实现的，不是直接 copy V1（因为 V1 的 HEX 写法和 snn_engine.quantize_weights 耦合较多）。如果 V2 的量化结果和 V1 不一致，A3 bit parity 会 pass（因为 memory 和 hex 同源），但 RTL parity 会 fail

**4. `run_baseline_64to10.py`**
- 完全不碰 V1 `.pt` 权重（V1 `.pt` 是 float，不是量化 level 索引）
- 直接加载 V1 `weight_pos.hex` + `weight_neg.hex`（已量化的 4-bit levels）
- 从 `alignment_manifest.json` 读 `threshold`（2550）+ `timesteps`（10）+ 100 样本的 `dataset_index` + `predicted_class`
- 用 `rtl_snn_inference`（V1 vendored）逐样本推理，对比 `predicted_class` bit
- **请 double-check：MNIST test split 从 `torchvision.datasets.MNIST(download=True)` 加载后，`images_all[idx]` 的样本是否和 V1 生成 `alignment_manifest.json` 时用的数据完全一致？**（torchvision 版本不同可能加载不同的 MNIST 字节？）

### Part 2：TB / CLI 完整性

**5. `run_multilayer.py` CLI 分支**
- R1 已修 `--all-topologies` argparse 问题 + `cmd_all` 传递 `sample_limit`
- 所有子命令是否都正确加载权重（`load_model` 之前有 `model.pt` 存在检查）
- 所有子命令是否都在 `get_topology_results_dir` 创建子目录

**6. `tests/` 3 个文件**
- `test_topology_schema.py` (24 测试，pytest 实跑全绿)
- `test_baseline_parity.py`（有条件 skip，V1 文件存在时才跑）
- `test_exported_hex_parity.py`（4 测试，无需 V1/torch 依赖）—— 里面刚加了 `test_v2_bitplane_matches_v1_rtl_inference` 强约束测试，**但这个测试依赖 pytest + V1 vendored**，如果 Codex 在没有 V1 路径时跑会 skip 吗？（答：`test_exported_hex_parity.py` 的这个新测试从 `_vendored_from_v1` import，vendored 是 V2 内部 copy，不需要 V1 路径，应该能跑）

### Part 3：跨文件一致性

**7. `model_state_dict` key 命名**
- `MultiLayerANN` 用 `nn.ModuleList` → key 为 `layers.0.weight` / `layers.1.weight`
- `exporter_multilayer.export_topology` 里 `f"layers.{i}.weight"` 取权重
- `trainer_multilayer.save_model` 用 `state_dict()`
- `trainer_multilayer.load_model` 用 `load_state_dict`
- 全链路名字是否一致？

**8. `topologies.yaml` 字段名**
- YAML 里用 `global` 作为 key
- pydantic schema 用 `global_config: GlobalConfig = Field(alias="global")` + `model_config = {"populate_by_name": True}`
- 请验证这个 alias 在 pydantic v2.13 下真的能从 YAML 解析（R3 schema test 实跑通过了，但如果有 pydantic 版本漂移？）

### Part 4：明天开跑的风险

**9. 环境风险**
- 明天 Claude 会在 Windows + Python 3.14 + 新装 torch/torchvision 上跑
- `torchvision.datasets.MNIST(download=True)` 在新环境首次下载，是否有网络 fallback？
- `memristor_plugin.py` 从 V1 `项目相关文件/器件对齐/器件相关参数与数据/` 的中文路径 import，`sys.path.insert` 后 Python import 是否能找到（Windows 文件系统 + 中文路径 + Python 3.14）？
- 如果 `memristor_plugin` 加载失败，V2 代码会 fallback 到 `torch.linspace(0, 1, 16)` 作为 levels——这是合理的降级吗？

**10. 训练时长预估**
- 3 个 v2_demo 拓扑：`64_24_10` / `64_32_10` / `64_32_16_10`
- 每个训练 40 epochs (20 float + 20 QAT) + 5 post-quant fine-tune
- 本机 16GB + 集成显卡 + CPU-only
- MNIST train 60k samples / batch 128 ≈ 470 batches/epoch
- 每 batch 小网络（<3k 参数）+ QAT 量化：估计 < 50ms/batch
- 预估每拓扑 20-40 分钟，3 拓扑总计 1-2 小时
- **这个估算合理吗？有没有漏掉什么会让训练爆炸的因素？**

### Part 5：语义正确性 deep dive

**11. A2.5 RTL-like reference 的 stage 1+ 语义是否真的对应 RTL?**

我在 `_run_stage_binary` 里的实现：
```python
wl_spike = (spike_mask_in).astype(np.int64)  # binary 0/1 from upstream
for _frame in range(stage.timesteps):         # yaml 里通常 timesteps=1
    diff = _cim_mac_scheme_b_integer(wl_spike, w_pos, w_neg)  # same integer MAC
    membrane += diff                          # 不乘 2^bit
    fired = membrane >= stage.threshold
    spike_counts += fired.astype(np.int64)
    membrane[fired] -= stage.threshold        # soft reset
```

这是对照 RTL `layer_sequencer.sv` + `cim_array_ctrl.sv` + `spike_feedback.sv` 的行为。我的假设是：
- RTL `layer_sequencer` 把上一 stage 的 spike_counts 通过 `spike_feedback` 转成 mask，然后作为下一 stage 的 `wl_spike` 输入
- 没有 bit-plane 展开（use_bitplane=0 时 `cim_array_ctrl` 跳过展开，直接用 wl_spike）
- 没有 bit-weighted 累加（直接 membrane += diff）
- 同样的 LIF 阈值比较 + soft reset

**请 Codex 对照 RTL 代码（`rtl/snn/cim_array_ctrl.sv` 和 `rtl/snn/lif_neuron_alu.sv`）确认这个假设成立**。如果 RTL 实际上有不同的 LIF 复位策略、或者 stage 间 mask 生成逻辑不同，A6.a 就会 fail。

### Part 6：开放问题

**12. 后续层 threshold=100 是拍脑袋给的**
- Stage 0 threshold=2550 是 V1 公式 `1/255 × 255 × 10` 来的
- Stage N>0 threshold 没有公式，YAML 里我填了 100
- A2.5 可能需要 sweep 校准
- 问题：100 这个初始值合理吗？如果 10 个 ADC 通道（out_dim=10）上差分平均 30 左右，threshold=100 意味着需要 ~3 个强 spike 才过阈值，timesteps=1 就可能完全没 spike

---

## 输出要求

按严重度排列的 finding 列表：

```
【发现 PM-XXX】
【严重度】CRITICAL / HIGH / MEDIUM / LOW
【文件:行号】
【问题】...
【建议修复】...
```

最后给 verdict：

```
Verdict: GO / WARN / STOP
- GO = 明天可以直接开跑训练
- WARN = 有 MEDIUM 问题但不阻塞，可以边跑边修
- STOP = 有 HIGH/CRITICAL 必须修完才能跑
```

## 特殊约束

- 不要说 "should use dataclass instead of pydantic" 这种风格建议
- 不要改 `_vendored_from_v1/` 下的任何文件（那是 V1 bit-identical copy）
- 重点关注"明天跑起来不炸" + "RTL bit parity 前提不要破坏"
- 如果发现 R1/R2/R3 没覆盖到的 edge case，明确指出

## 审查基线命令

```bash
cd python_multilayer

# Schema tests（应该 24/24 绿，不需要 torch）
python -m pytest tests/test_topology_schema.py -v

# Exported hex parity tests（不需要 V1 文件）
python -m pytest tests/test_exported_hex_parity.py -v  # 需要 torch + numpy

# V1 baseline parity（需要 V1 文件 + torchvision）
python run_baseline_64to10.py

# 训练（明天跑，今晚不跑）
python run_multilayer.py --all --topology 64_24_10
python run_multilayer.py --all --topology 64_32_10
python run_multilayer.py --all --topology 64_32_16_10
```

## 交付物

- `d:/SoC Design/SoC Design/python_multilayer/` 全部代码
- `d:/SoC Design/SoC Design/已修复的bug原因及其解决办法.md` 尚未更新（今晚只加代码，bug 记录等明天训练完）
- 本审查 prompt：`d:/SoC Design/SoC Design/eassy-prompt/codex_python_multilayer_review_prompt.md`

祝审查顺利，明天开跑前希望看到你的 verdict。
