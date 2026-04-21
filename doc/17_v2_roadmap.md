# V2 路线图（DC 之前）

> **落地版本**：本文档是从 `eassy-prompt/v2_roadmap_draft.md` 第 4 稿晋升而来，
> 经过 GPT 4 轮路线图审阅 + Codex 3 轮 RTL 审查 + 本侧 Ultra Review 闭环。
> 当前为 v2 分支 DC 综合前的**权威执行路线图**。

**落地日期**：2026-04-18
**基线分支**：`v2`
**目标**：DC 综合前完成全部数字功能验证 + FPGA 端到端 + 可配多拓扑 MNIST demo

**核心定位**：论文 B 对外卖点是 **"Firmware-Driven, Configurable Multi-Layer FC SNN Accelerator with On-Chip RRAM CIM"**
——强调架构灵活性（FC stage 数可配 + 每 stage 输出神经元数可配 + 时间复用 + 真实编程闭环），
MNIST 8×8 只是 demo，不是精度卖点。

**术语约定**（路线图 + Python manifest + 固件 + 论文统一）：
- `num_fc_stages`：硬件 FC 计算阶段数（1-4），每 stage = 一次 CIM 推理
- `bl_scan_count`：每 stage 扫描通道数（2-128，**必须偶数**），差分后输出神经元数 = bl_scan_count/2
- 论文对外描述网络：`N-layer MLP`（含输入层），例 `64→32→16→10` = "4-layer MLP with 3 FC stages"
- 内部 RTL / 固件描述：`num_fc_stages`，例上述为 `num_fc_stages=3`

---

## 0. 当前状态快照（2026-04-18 夜）

### 已完成
- **V1 RTL feature freeze**（2026-03-21）：外设 + E203 + JTAG rescue + 完整回归
- **V2 Iter 10-11**：CIM 编程 + 多层调度 + `MULTILAYER_SMOKE_PASS`
- **V2 V2（今天白天）**：
  - ADC 扫描参数化（`MAX_BL_SCAN=128`，bl_sel 扩到 7-bit）
  - GPT 首轮 360° 审查 8 个 finding 修复（D1-001 ~ D1-007 + D4-001 + D5-001）
  - E203 TB 适配 V2 `cpu_reset_hold` 安全引导语义（**不是 RTL bug，是功能**）
- **Phase A0 闭环（今天晚上）**：Codex 第 2 轮 finding + Ultra Review + Codex 第 3 轮 finding

### Phase A0 完整修复清单（今日已完成）
| ID | 轮次 | 严重度 | 内容 |
|---|---|---|---|
| D2-001 | Codex 2 | HIGH | 逐 cell erase 路径 prog_col 越界 guard |
| D2-002 | Codex 2 | MED | weighted_icarus bl_sel 扩宽 |
| D2-003 | Codex 2 | MED | `multilayer_scan_ext_tb` 新 TB |
| D2-004 | Codex 2 | MED | pad map 53/72 更新 |
| D2-005 | Codex 2 | LOW | doc/03 推理接口更新 |
| D2-006 | Ultra Rev | HIGH | prog_row 越界 guard（与 prog_col 对称） |
| D2-007 | Ultra Rev | MED | reload task `@(negedge clk)` 防竞争 |
| D2-008 | Ultra Rev | LOW | e203_tb release + scan_ext 避边沿 |
| **D3-FIX** | Ultra Rev 2 | **CRITICAL** | **`6'(PROG_ROWS)=0` 位宽截断修复（改用 `int'()`）** |
| D3-002 | Codex 3 | MED | 解耦 P_USE_BRAM_WEIGHTS（新 ENABLE_BRAM_WEIGHT_MODEL）|
| D3-003 | Codex 3 | MED | scan_ext TB 加 pattern 检查（raw_data/neuron_in_data_wide） |
| D3-004 | Codex 3 | LOW | reload task 加 runtime guard（rst_n/cim_busy/prog_en） |
| D3-005 | Codex 3 | LOW | doc/03 同步 D2-006 row guard |
| D3-006 | Codex 3 | LOW | chip_top 注释 Pad 19-50 |

### 回归状态（A0 全闭环后）
| TB | 结果 | 备注 |
|---|---|---|
| LIGHT_SMOKETEST | ✅ PASS | |
| WEIGHTED_SIM | ✅ PASS | 无 bl_sel 宽度告警 |
| MULTILAYER_SMOKE | ✅ PASS | |
| MULTILAYER_SCAN_EXT | ✅ PASS | T1/T2 含 D3-003 pattern 检查 |
| SAMPLE_ALIGN | ✅ PASS | 100/100 MNIST |
| ADC_SAT_COUNTER | ✅ PASS | |
| JTAG_RESCUE_TOP | ✅ PASS | |
| E203_SMOKETEST | ✅ PASS | |
| CIM_PROGRAM_CTRL | ✅ PASS | 7/7（D3-FIX 后真 PASS，之前的"7/7"是 stale vvp 假象） |

---

## 1. 关键决策（已与用户对齐，v4 更新）

| 决策点 | 选择 | 理由 |
|---|---|---|
| Python 项目组织 | 新建 `python_multilayer/` | 保留 V1 单层 MNIST 冻结版 |
| **V2 数据集（v4 变更）** | **MNIST（主），Fashion-MNIST 降级为可选 stretch** | 论文卖点改为"可配 FC 架构"，数据集难度不再是关键；MNIST 8×8 能稳定 95%+ 证明架构功能 |
| V1 实验 | **不重跑** | V1 MNIST 单层是论文 A 数据源（与 V2 多拓扑 MNIST 数据集一致，可直接对比）|
| **论文 B 定位（v4 变更）** | **"可配置多层 FC 网络加速器"**（FC stage 数 1-4 可配 + 每 stage 输出神经元数 1-64 可配，对应偶数 BL scan count 2-128 + 固件驱动时间复用） | MNIST 作为 demo；主卖点是架构灵活性而非精度 |
| **MNIST acc 门槛（v4 更新）** | hard **≥95%**，stretch **≥97%** | 4-bit + 64 维 MNIST 的经验值；低于 92% 说明架构有问题 |
| **多拓扑对比实验（v4 新增）** | 跑 3+ 种拓扑（64→10 / 64→32→10 / 64→32→16→10），MNIST 全 ≥95% | 论文 B 的核心 figure：证明"可配"真的能跑 |
| A4 架构建模 | 单 macro + reload 接口（不是 4 层常驻） | 真实时间多层是擦除重编程 |
| A4 黑盒合并 | A4a/A4b 必做，A4c 可选 | GPT 建议降低耦合 |
| 数值对齐口径 | RTL 等价性 100/100 + acc 分开报告 | 避免调参黑洞 |
| A3 口径 | Python exported-hex = Python quantized（不是 float） | 严格 bit 语义 |
| 跳过零权重 | 保留，配套"先全阵列擦除"才写非零 | 器件老师确认 |
| 编程闭环仿真 | 分级 shortcut / `+define+PROG_DEEP_SWEEP` | 平衡 CI 速度 |
| B3b cell 数估算 | 由 Python manifest 汇总（skip-zero 后实际 cell 数） | 避免凭空估算 |
| B2 表述 | 同一 weight_mem reload（不是多份权重切换） | 消除混淆 |
| FPGA 禁止 shortcut | C6 禁用 reload_layer_weights，必须走固件 PROG_CTRL | shortcut 不可综合 |
| FPGA 板 | ZCU102 | 资源富余，50MHz 无压力 |
| FPGA 目标频率 | 50MHz | 对齐未来流片目标 |
| C0 资源门槛 | 目标<30% 警戒50% 阻断>70% | 和风险矩阵一致 |
| 数字 CIM proxy | 先同板，后可选 Artix-7 跨 PCB | — |
| E203 reset hold 语义 | V2 安全引导保留；e203_tb helper 旁路 | 不是 bug |
| BRAM 权重模型开关 | `ENABLE_BRAM_WEIGHT_MODEL` 与 `ENABLE_PROGRAM_MODE` 解耦 | 允许多层对齐 TB 用 BRAM 但不带编程控制器 |

---

## 2. 阶段详细计划

### Phase V2.A：数值对齐开闸 + 多拓扑 demo — 预计 2-3 周

> ✅ **A0 已全闭环**（回归 9/9 绿）
> A1-A6 待启动

**目标（v4 更新）**：
1. 跑通 3 种 MNIST 多拓扑，Python 精度均 ≥ 95%
2. `multilayer_sample_align_tb` 达到 Python quantized-export 与 RTL 100/100 样本 predicted_class 一致
3. 生成论文 B 核心 figure 的原始数据（多拓扑精度/延迟/编程时间对比表）

| 步骤 | 内容 | 估时 | 验收 |
|---|---|---|---|
| ~~A0~~ | ✅ **完成** | — | 9/9 绿 |
| **A1.0**（GPT 强推，第一天必做） | **建立 `python_multilayer/topologies.yaml` 作为 Python/TB/固件/论文的统一 manifest schema**（见下方） | 半天 | yaml 通过 pydantic/jsonschema 校验，三拓扑字段完整 |
| A1.1 | 新建 `python_multilayer/` 其余骨架，复用 V1 MNIST 加载和量化代码 | 1 天 | 目录建立，V1 数据路径 OK |
| A1.2 | **V1 `64→10` baseline 复跑**（对齐 V1 冻结结果） | 1 天 | V1 冻结 acc 和新 python_multilayer 完全一致（同 preprocessing/threshold/T/ratio） |
| **A2**（v4 更新）| 训练 3 种拓扑，每个 4-bit 量化 | 4 天 | MNIST float ≥ 95% on all topologies；stretch 97% |
| **A2.b**（v4 新增，核心 figure） | 多拓扑对比表：accuracy / 推理延迟 / 编程时间 / RRAM cell 数 | 1 天 | 表格进论文 |
| A2.c（可选，论文 bonus）| Fashion-MNIST 8×8 在同架构下的 demo | 1-2 天 | 论文附录"extendability" |
| A3 | 导出 hex + manifest（每拓扑） | 2 天 | Python exported-hex inference = Python quantized（bit 一致） |
| A4a | 修 weighted_icarus bl_sel | — | ✅ **A0 完成** |
| A4b | cim_macro_blackbox 支持 MAX_BL_SCAN + reload 接口 | — | ✅ **A0 完成 reload_layer_weights task** |
| A4c（可选） | 合并两份 blackbox | 2 天 | V1+V2 路径都通过 |
| A5 | `multilayer_sample_align_tb.sv` | 3 天 | 必须 `ENABLE_BRAM_WEIGHT_MODEL=1` 或 `ENABLE_PROGRAM_MODE=1` |
| A6.a 硬门槛 | RTL 等价性（每拓扑都要过） | 3 天 | Python quantized-export 与 RTL 100/100 predicted_class 一致 |
| A6.b | 多拓扑 MNIST accuracy 记录 | 并行 | Python float / quantized / RTL alignment 各自报告 |

**A2 拓扑清单（建议，使用 num_fc_stages 统一术语）**：
| 拓扑 | 参数数 | `num_fc_stages` | 网络描述（论文对外） | 用途 |
|---|---|---|---|---|
| 64→10 | 640 | **1** | 2-layer MLP (1 FC stage) | V1 baseline，冻结数据直接复用 |
| 64→32→10 | 2368 | **2** | 3-layer MLP (2 FC stages) | 多 vs 单 stage 对比 |
| 64→32→16→10 | 2720 | **3** | 4-layer MLP (3 FC stages) | 完整时间复用 demo |
| （可选）64→24→10 | 1776 | **2** | 3-layer MLP (2 FC stages) | 小拓扑，证明"任意配置" |

> **术语约定（本路线图 + Python manifest + 固件 layer descriptor + 论文 B 统一口径）**：
> - **`num_fc_stages`**：硬件视角的 FC 计算阶段数，每 stage = 一次 CIM 推理，**最大 4**
> - **"N-layer MLP"**：网络结构视角，含输入层计数（论文 abstract / figure caption 用）
> - 对外（论文）：`64→32→16→10` 说成 "4-layer MLP with 3 configurable FC stages"
> - 对内（RTL / firmware / reg_bank 层描述符）：`num_fc_stages=3`，和 `REG_ML_CTRL.num_layers` 对齐
> - **禁止**混用 "层数=4" 和 "层数=3" —— 要么明确"4-layer MLP"，要么明确"3 FC stages"

#### A1.0 Manifest Schema 骨架（`python_multilayer/topologies.yaml`）

GPT 强推：**A1 第一天必做**。所有下游（Python trainer / exporter / TB `$readmemh` / 固件 layer descriptor / 论文 Table 1）都从这份 manifest 读取，防止字段漂移。

```yaml
# python_multilayer/topologies.yaml
schema_version: "1.0"

topologies:
  - name: "64to10_baseline"              # V1 baseline（复用冻结结果）
    num_fc_stages: 1
    input_dim: 64                        # avgpool8x8 MNIST
    timesteps: 10
    threshold_ratio: 1                   # 对齐 V1 THRESHOLD_RATIO_DEFAULT
    quant_bits: 4
    stages:
      - in_dim: 64
        out_dim: 10
        bl_scan_count: 20                # = 2 × out_dim（Scheme B 正负对）
        wl_count: 64                     # = in_dim
        threshold: 2550                  # = ratio × (2^PIXEL_BITS-1) × T = 1×255×10
        weight_pos_hex: "weights/64to10_L0_pos.hex"
        weight_neg_hex: "weights/64to10_L0_neg.hex"
        nonzero_cells: null              # by exporter after skip-zero

  - name: "64_32_10"
    num_fc_stages: 2
    input_dim: 64
    timesteps: 10
    threshold_ratio: 1
    quant_bits: 4
    stages:
      - in_dim: 64
        out_dim: 32
        bl_scan_count: 64                # = 2 × 32
        wl_count: 64
        threshold: 2550                  # per-stage 可不同，这里 V2 默认同值
        weight_pos_hex: "weights/64_32_10_L0_pos.hex"
        weight_neg_hex: "weights/64_32_10_L0_neg.hex"
        nonzero_cells: null
      - in_dim: 32
        out_dim: 10
        bl_scan_count: 20
        wl_count: 32
        threshold: 2550
        weight_pos_hex: "weights/64_32_10_L1_pos.hex"
        weight_neg_hex: "weights/64_32_10_L1_neg.hex"
        nonzero_cells: null

  - name: "64_32_16_10"
    num_fc_stages: 3
    # ... 类似展开
```

**字段语义守则**（供所有消费者参考）：
- `bl_scan_count = 2 × out_dim`（Scheme B 硬约束，必须偶数）
- `wl_count = in_dim`（上一 stage 的 out_dim）
- `nonzero_cells` 由 exporter 填，用于 B3b 编程时间估算
- `schema_version` 改动 = breaking change，需要同步所有 consumer（建议用 pydantic 自动校验）

**消费者清单**（manifest 必须能驱动这些）：
| 消费者 | 用途 |
|---|---|
| Python trainer | 读 topology 决定网络结构、训练 |
| Python exporter | 按 `stages[i].weight_*_hex` 输出 hex 文件 |
| Python reference inference | 做 quantized-export 推理，作为 RTL 对齐 golden |
| RTL TB (`multilayer_sample_align_tb`) | `$readmemh(weight_pos_hex, dut.u_macro.weight_mem)` |
| E203 固件（Phase B1） | 读 manifest header 决定层数、每层 bl_count、编程脚本 |
| 论文 B Table 1 | `num_fc_stages` / 参数数 / MNIST acc / nonzero_cells → 论文原始数据 |

#### A1.2 V1 baseline 口径对齐清单

复跑 `64to10_baseline` 前必须确认新 `python_multilayer/` 和 V1 冻结结果**完全一致**（GPT 提醒）：

| 口径 | V1 冻结值 | 新项目必须匹配 |
|---|---|---|
| 输入预处理 | avgpool8x8 | ✅ |
| `threshold_ratio` | 1（1/255） | ✅ |
| `TIMESTEPS` | 10 | ✅ |
| `THRESHOLD_DEFAULT` | 2550（1×255×10） | ✅ |
| 量化位数 | 4-bit（16 级） | ✅ |
| Scheme B 差分 | pos - neg | ✅ |
| MNIST test split | 前 100 样本 class-major | ✅ |
| `expected_classes.hex` | V1 生成的 | **直接复用，不要重生成** |

**验证口径**：跑 `python run_baseline_64to10.py` 产生的 `predicted_class` 应该和 V1 `results/exports/expected_classes.hex` **bit 一致**。如果不一致 → 新项目有 preprocessing 漂移，**必须先修**，不然多拓扑对比表失去基准。

**验收三级口径**：
- Python full test accuracy（10k 样本，论文性能指标）
- RTL alignment subset（100/100 样本 bit 一致，Phase A 硬门槛）
- FPGA demo subset（100 样本，用于 Phase C 演示）

**风险/触发器**：
- A2 某个拓扑 MNIST float acc < 92% → **架构有问题**（比如 bit-plane encoding 丢信息、量化粒度不够），而不是拓扑本身问题
- A6.a 100/100 不过 → 排查导出链路，不等于调网络
- A2.c Fashion-MNIST 低于 75% → 只放附录不作卖点

---

### Phase V2.B：时间多层闭环（固件驱动） — 预计 1-2 周

**目标**：E203 固件跑完整"推理 → 读 spike → 全擦 → 重编程 → 下一层"循环，**在 3 种拓扑上都能 work**

| 步骤 | 内容 | 估时 | 验收 |
|---|---|---|---|
| B1 | E203 固件（C）：层循环 + spike 读 + 全擦 + 逐 cell 编程 | 4 天 | 单层循环通 |
| B2 | 默认 shortcut：TB 调 `dut.u_macro.reload_layer_weights()` | 1 天 | 固件控制流验证，不走编程 FSM |
| B3a | 完整编程闭环 smoke：少量 cell（~32 cells × N 层） | 2 天 | 控制流 + 脉宽自计时验证 |
| B3b | 完整编程闭环 stress：**按 manifest 汇总真实 nonzero cell 数** | 3-5 天 | 3 拓扑都跑通 |
| B4 | `multilayer_e203_tb` 端到端回归 | 2 天 | 每拓扑 MNIST 100 样本 PASS |

**B3b 估算**（按 manifest）：
- 64→10 单层：物理容量 64×20=1280 个差分 cell 位置，实际编程数以 skip-zero 后 `nonzero_cells` 为准
- 64→32→10：物理容量 64×64 + 32×20 = 4736 个差分 cell 位置，实际编程数以 manifest 为准
- 64→32→16→10：物理容量 64×64 + 32×32 + 16×20 = 5440 个差分 cell 位置，实际编程数以 manifest 为准
- Deep sweep 运行时间不硬编码：先由 B3a 实测 `wall_clock / programmed_cell_count`，再用 manifest 的 `total_nonzero_with_skip_zero` 自动外推并打印到 regression log

**关键决策**：
- 固件实现"skip-zero + 每层开头全擦"
- 多拓扑固件需要通用：读 manifest.json 头部（或 boot 参数）决定层数和每层大小

---

### Phase V2.C：FPGA 上板（ZCU102） — 预计 2-4 周

**目标**：在 ZCU102 上 demo **可配多拓扑**（这是论文 B 最关键的 FPGA evidence）

| 步骤 | 内容 | 估时 | 验收 |
|---|---|---|---|
| C0 | Vivado synthesis-only 跑资源预估 | 2 天 | 目标 <30%，警戒 50%，阻断 >70% |
| C1 | Vivado 工程 + XDC + 主时钟 50MHz | 3 天 | Synthesis pass |
| C2 | P&R + 时序分析 | 4 天 | WNS > 0 @ 50MHz |
| C3 | Bitstream + SPI Flash + 上电 UART "BOOT OK" | 2 天 | UART 打印 OK |
| C4 | JTAG rescue 链路 | 2 天 | JTAG loader 写 SRAM + 释放 CPU |
| C5 | DMA 装样本 + 单层 MNIST 推理 + UART 打印 spike_id | 3 天 | 与仿真一致 |
| **C6**（v4 多拓扑） | 3 种拓扑都通过 E203 固件跑完整 MNIST 推理 | 5 天 | 每拓扑 100 样本 accuracy 与 A6.b 一致。**禁止使用 `reload_layer_weights` shortcut**，必须走 B3 路径 |
| C7a | 数字 CIM proxy 同板 | 3 天 | 全链路跑通 |
| C7b（可选） | Proxy 搬 Artix-7，FMC/LVDS 互联 | 5 天 | 跨 PCB 时序验证 |

---

### Phase V2.D：Codex 闭环 + 文档 + 论文 — 贯穿

| 步骤 | 内容 | 估时 |
|---|---|---|
| D1 | Codex 后续 finding 处理 | 按数量 |
| D2 | 全矩阵回归 | 1 天 |
| D4 | `doc/07_tapeout_schedule.md` 里程碑 | 半天 |
| D5 | `doc/16_iteration_log.md` Iter 17/18/19 | 半天 |
| D6 | `已修复的bug原因及其解决办法.md` 持续追加 | 每次 |
| **D7（v4 重定位）** | **论文 B 初稿：可配多层 FC 架构 + MNIST 多拓扑 demo** | 2 周 |
| D8（可选）| 论文 A 初稿：器件-算法协同（V1 单层 MNIST） | 2 周 |

---

## 3. 时间线汇总

| 阶段 | 起 | 止 | 累计 |
|---|---|---|---|
| ~~A0~~ | ✅ 2026-04-18 | ✅ 2026-04-18 | 1 天 |
| V2.A 实质 | 2026-04-21 | ~2026-05-12 | +3 周 |
| V2.B | ~2026-05-12 | ~2026-05-26 | +2 周 |
| V2.C | ~2026-05-26 | ~2026-06-23 | +4 周 |
| V2.D | 并行 | 并行 | - |
| **DC 开闸窗口** | — | **~2026-06-23** | **约 9 周** |

---

## 4. DC 开闸硬指标

1. ✅ 所有 RTL TB 回归 PASS（含 `PROG_DEEP_SWEEP` 深度版）
2. ✅ Python quantized-export inference 与 RTL 100/100 predicted_class 一致（**3 种拓扑都要过**）
3. ✅ E203 固件在 ZCU102 上通过真实可综合路径跑完 3 种拓扑的 MNIST 推理（不能用 reload shortcut）
4. ✅ `doc/15_asic_pad_map.md` 最终 pad 分配与 `chip_top.sv` 一致
5. ✅ Codex / GPT 最新一轮审查无 CRITICAL/HIGH 未处理项
6. ✅ scan128/scan64 参数化 ADC 回归 PASS（A0 完成）

---

## 5. 开放问题（待确认）

1. **器件老师**：跳过零权重 + 每层开头全擦的策略可否
2. **器件老师**：编程脉宽默认 160ns 是否合适
3. **器件老师**：V2-4 / V2-5 / V2-6 参数窗口
4. **器件老师**：V2-7 bl_sel 扩 7-bit 模拟侧 BL MUX 是否跟进
5. **资源**：是否有第二块 FPGA 做跨 PCB proxy（C7b）
6. **论文**：A2.c Fashion-MNIST stretch demo 做不做
7. **训练**：MNIST 4 层 acc < 92% 时如何排查（应该是架构问题而非拓扑问题）

---

## 6. 风险矩阵

| 风险 | 影响 | 触发条件 | 应对方案 |
|---|---|---|---|
| MNIST 多拓扑某个 < 92% | 中 | A2 某拓扑 float acc < 92% | 架构层面排查（bit-plane / 量化），不是拓扑问题 |
| A6.a 100/100 不过 | 高 | RTL 与 Python quantized 有数值偏差 | 排查导出链路 |
| ZCU102 时序不收敛 | 低 | C2 WNS < 0 | 降频到 25MHz |
| C0 资源超标 | 中 | Synthesis > 70% | 拆模块 / 降配 |
| 器件老师参数大改 | 高 | 脉宽/阈值窗口要改 | RTL 已参数化，重跑 A6 对齐即可 |
| Codex 后续 HIGH finding | 中 | 新轮次出 HIGH | 回 Phase D1 闭环 |
| B3b cell 数超预期 | 中 | manifest 显示 total_nonzero > 10k | 压缩脉宽 / 增量 regression |
| C6 无法走真实编程路径 | 高 | FPGA 固件编程闭环失败 | 不能用 shortcut 兜底；延期 1-2 周 |
| 流片窗口压力 | 高 | 学校要求早推 DC | 砍 C7 / 并行论文 |

---

## 7. 论文 B 卖点（v4 新增）

本项目对外宣传的核心卖点：

> **"A Firmware-Driven, Configurable Multi-Layer FC SNN Accelerator with On-Chip RRAM CIM"**
>
> 支持：
> - FC stage 数 1-4 可配（demo 覆盖 1/2/3 stages，对应 2/3/4 层网络拓扑）
> - 每 stage 输出神经元数 1-64 可配，对应偶数 BL scan count 2-128（Scheme B pos/neg 成对）
> - 每层独立阈值 / timestep
> - 运行时重配（固件驱动，无需重综合）
> - 片上 RRAM CIM 编程通路（write/erase/verify 全闭环）
>
> 验证：MNIST 8×8 在 3 种拓扑均达 ≥95% 精度，<2% 精度波动。

**这段 abstract 是目标口径，不是精度卖点。**

---

## 8. 本文档去向

- **现在**：交 GPT 第 4 轮审查
- **审阅无异议**：落地为 `doc/17_v2_roadmap.md`
- **有异议**：修订第 5 稿
- **落地后**：每周刷新，Iter 17/18/19 在 `doc/16_iteration_log.md` 追踪
