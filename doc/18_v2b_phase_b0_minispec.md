# 18 - V2.B Phase B0 mini-spec (DRAFT)

**版本**：v0.1 (DRAFT — 2026-04-20)
**状态**：Phase B1 RTL 开工前必须 freeze。待 GPT + 用户 review。
**基础**：`plans/noble-soaring-beaver.md` REV 3.1 / 3.2 / 3.3（D1-D18 已吸收）
**范围**：Phase B 开始前的硬件接口冻结文档。涵盖 5 个 RTL primitive、寄存器表、buffer ownership 状态机、handshake 时序、cycle budget、resident-weight policy、TB sketches。
**不包含**：FPGA 板子/管脚/综合策略 —— 那些在 Phase D 阶段处理。

## 0. 设计原则回顾（REV 3 critical #3）

RTL **只提供 5 个 primitive**，任何 loop（layer / tile / chunk）由 E203 固件编排。

```
(1) program_stage_weights(stage_id, tile_id)    ← 现有 cim_program_ctrl
(2) load_input_stream(src_addr, length)         ← 现有 DMA
(3) run_streamed_stage(stage_desc)              ← ★ 核心新 RTL
(4) swap_stream_buffers()                       ← 寄存器 bit
(5) clear_or_preserve_state(boundary_type)      ← 寄存器 bit
```

对应 RTL 新建 / 大改模块：
- `rtl/snn/stream_buffer.sv`（替代旧 `spike_feedback.sv`，语义变了）
- `rtl/snn/input_stream_sram.sv`（D6 新建）
- `rtl/snn/tile_partial_buf.sv`（D1 新建，`[T][N_out]` signed BRAM）
- `rtl/snn/layer_sequencer.sv`（大简化：只驱动单 stage 完成）
- `rtl/snn/cim_array_ctrl.sv`（每 timestep 读 stream 一个 mask，binary MAC）
- `rtl/snn/lif_neuron_alu.sv`（tile mode + membrane 跨 timestep 累积）
- `rtl/top/snn_soc_pkg.sv`（常量：256×256，T_MAX，NEURON_DATA_WIDTH）
- `rtl/reg/reg_bank.sv`（本文档 B0.1 新增寄存器）

**不改的**：`cim_program_ctrl.sv`、`cim_macro_arbiter.sv`、`cim_macro_blackbox.sv`（只改阵列尺寸常量）、UART/SPI/DMA/JTAG/E203/ICB。

---

## B0.1 — 5 个 primitive 的寄存器接口（扩充到 reg_bank）

Base `0x4000_0000`。保留 V1 寄存器 0x00~0x44（不变）。V2.B 新增在 0x50~0xBF 和 0xE0~0xFF 段。

### STAGE_CTRL（run_streamed_stage primitive）

| OFFSET | 名称 | 字段 | 位段 | 访问 | 默认 | 说明 |
|---:|---|---|---|---|---|---|
| 0x50 | STAGE_CTRL | START | [0] | W1P | 0 | 启动一次 `run_streamed_stage` |
| 0x50 | STAGE_CTRL | ABORT | [1] | W1P | 0 | 软停中断（debug 用；B1 可先省） |
| 0x50 | STAGE_CTRL | DONE | [7] | W1C | 0 | 完成 sticky，写 1 清零 |
| 0x54 | STAGE_STATUS | BUSY | [0] | RO | 0 | Stage engine 忙 |
| 0x54 | STAGE_STATUS | T_IDX | [15:8] | RO | 0 | 当前 timestep（debug） |
| 0x54 | STAGE_STATUS | ERR | [23:16] | RO | 0 | 错误码（见 B0.5） |
| 0x58 | STAGE_CFG0 | IN_DIM | [15:0] | RW | 0 | 本次 run 的 in_dim（1..256；0 非法） |
| 0x58 | STAGE_CFG0 | OUT_DIM | [31:16] | RW | 0 | 本次 run 的 out_dim（1..128） |
| 0x5C | STAGE_CFG1 | THRESHOLD | [31:0] | RW | 0 | LIF 阈值（unsigned） |
| 0x60 | STAGE_CFG2 | SUM_MAX | [31:0] | RW | 0 | 当前 tile 的 ADC full-scale |
| 0x64 | STAGE_CFG3 | INPUT_SRC | [1:0] | RW | 0 | 0=input_stream_sram, 1=stream_buf_A, 2=stream_buf_B |
| 0x64 | STAGE_CFG3 | OUTPUT_DST | [9:8] | RW | 0 | 0=stream_buf_A, 1=stream_buf_B, 2=output_fifo |
| 0x64 | STAGE_CFG3 | TILE_MODE | [16] | RW | 0 | 1=partial-sum 累加到 tile_partial_buf，不做 LIF |
| 0x64 | STAGE_CFG3 | IS_TILE_FINAL | [17] | RW | 1 | 1=最后 tile，触发 LIF + 写 output_stream_dst |
| 0x64 | STAGE_CFG3 | PRESERVE_MEMBRANE | [18] | RW | 0 | 1=stage 起始不清 membrane（特殊用途；默认清零） |
| 0x68 | STAGE_CFG4 | RESERVED | [31:0] | RW | 0 | 保留。未来 descriptor-DMA weight load 会占用此 slot（Phase C2） |
| 0x6C | STAGE_CFG5 | T_COUNT | [15:0] | RW | 0 | 本次 run 的 timestep 数（1..MAX_TIMESTEPS；0 非法会返回 DIM_OUT_OF_RANGE）|
| 0x6C | STAGE_CFG5 | RESERVED | [31:16] | RW | 0 | 保留 |

> **[BLOCK-V2-02 对齐说明，2026-04-22]** 早期草稿把 CFG4/CFG5 记为 weight 基址，但标准 standalone V2.B top (`rtl/top/snn_soc_v2b_top.sv`) 实际用 CFG5[15:0]=T_COUNT，CFG4 保留。权重加载走独立的 `MAC_W_LOAD_{ADDR,DATA,CTRL}` 寄存器（`v2b_soc_regs.h:50-52`）或 Phase C2 的 descriptor-DMA 路径，而不是 CFG4/CFG5。固件/RTL/doc 三方现已一致。

### STREAM_BUF（swap_stream_buffers primitive）

| OFFSET | 名称 | 字段 | 位段 | 访问 | 默认 | 说明 |
|---:|---|---|---|---|---|---|
| 0x70 | STREAM_BUF_CTRL | SWAP | [0] | W1P | 0 | 写 1 交换 A/B buffer ownership |
| 0x70 | STREAM_BUF_CTRL | CLEAR_A | [1] | W1P | 0 | 清零 stream_buf_A（用于 debug） |
| 0x70 | STREAM_BUF_CTRL | CLEAR_B | [2] | W1P | 0 | 清零 stream_buf_B |
| 0x70 | STREAM_BUF_CTRL | CLEAR_TILE_BUF | [3] | W1P | 0 | 清零 tile_partial_buf |
| 0x74 | STREAM_BUF_STATUS | OWN_A | [1:0] | RO | 0 | A 所属：0=FREE, 1=WRITING, 2=READY, 3=READING |
| 0x74 | STREAM_BUF_STATUS | OWN_B | [3:2] | RO | 0 | B 所属（同 OWN_A 编码） |
| 0x74 | STREAM_BUF_STATUS | OWN_INPUT | [5:4] | RO | 0 | input_stream_sram 所属 |

### STATE_CTRL（clear_or_preserve_state primitive）

| OFFSET | 名称 | 字段 | 位段 | 访问 | 默认 | 说明 |
|---:|---|---|---|---|---|---|
| 0x78 | STATE_CTRL | CLEAR_MEMBRANE | [0] | W1P | 0 | 清零 LIF membrane（chunk 边界必用） |
| 0x78 | STATE_CTRL | CLEAR_ALL | [1] | W1P | 0 | 清 membrane + stream_buf_A/B + tile_partial_buf |

### LAYER_DESC（load_input_stream 参数，DMA 目标约定）

保留 V2.A `ML_CTRL` (0x48) 形式不变，但不再用于 layer loop（layer loop 改固件）。
DMA 目标寄存器 `DMA_DST_SEL` (0x010C) 增加选项：
- `2'b11 = INPUT_STREAM_SRAM`（REV 3.3 D6 新增目标）

详见 B0.2 buffer ownership 图。

### ADC_CFG（global，不属 primitive 但必须冻结）

| OFFSET | 名称 | 字段 | 位段 | 访问 | 默认 | 说明 |
|---:|---|---|---|---|---|---|
| 0x80 | ADC_CFG | ADC_BITS | [3:0] | RW | 4'd10 | REV 3.3 D15：compile-time 10-bit。runtime 只做 clip/scale 切换。合法值 {8, 10, 12}，RTL 实装 10-bit path |
| 0x80 | ADC_CFG | FULL_SCALE_MODE | [5:4] | RW | 2'd1 | 0=array (fixed HW_NUM_INPUTS×15), 1=active_wl (follow stage.in_dim) |

---

## B0.2 — Buffer Ownership 图

```
                 ┌─────────────────────────────────┐
                 │        input_stream_sram        │  T_MAX × MAX_NUM_INPUTS × 1bit
  DMA ─── write ─┤  (ping-pong optional future)    │  ≈ 6.3 KB @ T=256, in=196
                 └────┬──────────────────────── ────┘
                      │ read (per timestep, in_dim mask)
                      ▼
        ┌────────────────────────────┐
        │    cim_array_ctrl          │ ── binary MAC (scheme B) ──► ADC
        └────────────────────────────┘                               │
                                                                     ▼
                              ┌────────────────────────────────────────┐
                              │  tile_partial_buf[T_MAX][MAX_OUT_NEURONS]│ signed 14-bit
              TILE_MODE=1 ───►│  partial_diff_buffer[t][j] accumulate   │  ~14 KB @ T=64
                              └──────────┬──────────────────────── ─────┘
                  IS_TILE_FINAL=1 ───────┤ LIF sweep once (t=0..T-1)
                                         ▼
                              ┌────────────────────────────────┐
                              │  lif_neuron_alu (membrane + LIF)│
                              └──────────┬──────────────────────┘
                                         │ spike_stream[T][out_dim]
                         OUTPUT_DST=0 ───┤──► stream_buf_A
                         OUTPUT_DST=1 ───┤──► stream_buf_B
                         OUTPUT_DST=2 ───┘──► output_fifo (final stage)
```

**严格规则**（编码在 `STREAM_BUF_STATUS`）：

- `INPUT_SRC` 和 `OUTPUT_DST` **不能指同一个 buffer**（同周期读写禁止）
- 每个 buffer 的 4 状态状态机（REV 3.3 D14）：

```
            ┌──── CLEAR / reset ────┐
            │                        ▼
    ┌─────┐ swap_release    ┌─────────┐
    │FREE │ ─────────────── │READING  │
    └──┬──┘                 └─────────┘
       │ STAGE_CTRL.START                      ▲
       │ (OUTPUT_DST=this)                      │
       ▼                                        │ stage done + swap
    ┌──────────┐                                │
    │ WRITING  │  engine writes [T][N]          │
    └────┬─────┘                                │
         │ stage BUSY→idle                      │
         ▼                                      │
    ┌──────┐   STAGE_CTRL.START      ┌─────────┐
    │READY │ ─────────────────────── │READING  │
    │      │   (INPUT_SRC=this)      │         │
    └──────┘                         └─────────┘
```

状态机不变量：
1. `FREE → WRITING`：`STAGE_CTRL.START` 带 `OUTPUT_DST=this`，引擎锁定此 buffer
2. `WRITING → READY`：本 stage engine done，写指针稳定
3. `READY → READING`：下一个 `STAGE_CTRL.START` 带 `INPUT_SRC=this`，读指针锁定
4. `READING → FREE`：下一个 stage engine done（已经消费完当前 buffer 的全部 T timestep）
5. 禁止：`WRITING` 和 `READING` 在同周期同 buffer（除非 true dual-port SRAM，暂不做）

固件由软件确保 swap 之前 busy=0。RTL 用 SVA 断言守护（B0.5）。

**容量预算（D16 精确化）**：
```
input_stream_sram:   T_MAX × MAX_NUM_INPUTS × 1 bit
                     = 256 × 256 × 1 bit = 65536 bit ≈ 8 KB
                     ≈ 2 × 36Kb BRAM (Xilinx 7-series)

stream_buf_A/B:      T_MAX × MAX_OUT_NEURONS × 1 bit each
                     = 256 × 128 × 1 bit = 32768 bit ≈ 4 KB each
                     ≈ 1 × 36Kb BRAM each

tile_partial_buf:    T_MAX × MAX_OUT_NEURONS × signed 14-bit
                     = 256 × 128 × 14 bit = 458752 bit ≈ 56 KB
                     (T=64 case: 14 KB)
                     ≈ 13 × 36Kb BRAM (T=256) / 4 × 36Kb BRAM (T=64)
```

---

## B0.3 — Handshake 时序（run_streamed_stage）

### 基础单 stage 时序（resident 14×14，单 tile，T=64）

```
CPU write STAGE_CFG0-5, STAGE_CTRL.START=1
  │
  ▼
stage_engine: BUSY=1
  for t in 0..T-1 {
    ┌─────────────────────────────────────────┐
    │ read input_stream_sram[t] → wl[in_dim]  │ 1 cycle
    │ cim_array_ctrl: program WL (serial)     │ in_dim cycles @ 1 WL/cycle (V1 legacy behavior; tile below)
    │ cim_done pulse                          │
    │ bl_scan sweep (2*out_dim cycles)        │ 2*out_dim cycles
    │ ADC read + diff                         │ 2*out_dim cycles
    │   - TILE_MODE=1: partial_buf[t] += diff │
    │   - TILE_MODE=0: membrane += diff;      │
    │                  fire? stream_buf[t]=1  │
    └─────────────────────────────────────────┘
  }
  IS_TILE_FINAL=1 + TILE_MODE was used?
    yes → LIF sweep partial_buf[0..T-1], write stream_buf
  mark OWN_<output> = READY
  STATUS.DONE ← 1, BUSY=0

CPU: poll STATUS.BUSY == 0 or STATUS.DONE == 1
CPU: write STAGE_CTRL.DONE = 1 (W1C)
```

### 关键 handshake 不变量（REV 3.3 D14）

- `STAGE_CTRL.START` 被 latched 一次后 `STAGE_CFG0-5` 寄存器可以被 CPU 修改（供 tile 模式下连续发起多次 START）
- 每次 START 之前 CPU 必须确保 `STATUS.BUSY == 0`；否则引擎忽略 START 并置 ERR bit
- 引擎对 `ALU spike_mask_valid` 必须显式握手（REV 2 GPT fix #5：最大风险点）；spike_mask_valid 未返回前**不得**进入下一 timestep
- `DONE` sticky 只在 CPU 写 W1C 清零；START 不自动清 DONE

### 串行 WL 程控 vs 并行扫描（REV 3.2 D11 配合）

14×14 resident 主 demo：
- stage 0 `in_dim=196`：每 timestep 196 cycle 串行扫 WL（或者按 group 扫，B0.5 讨论）
- T=64: 64 × 196 ≈ 12544 cycle / stage. @ 50MHz = 250 µs / stage
- 两层 multi: ~500 µs inference

### Cycle Budget（B0.4）

| Case | in_dim | out_dim | T | tiles | cycle/stage | @ 50MHz |
|---|---:|---:|---:|---:|---:|---:|
| 14×14 single (196_10) | 196 | 10 | 64 | 1 | ~13K | 260 µs |
| 14×14 single (196_10) | 196 | 10 | 256 | 1 | ~52K | 1.04 ms |
| 14×14 multi (196_64_10) stage 0 | 196 | 64 | 64 | 1 | ~13K | 260 µs |
| 14×14 multi stage 1 | 64 | 10 | 64 | 1 | ~5K | 100 µs |
| 14×14 multi total | - | - | 64 | - | ~18K | 360 µs |
| 28×28 tile (4 tile × 196) | 196/tile | 10 | 64 | 4 | 4×13K=52K | 1.04 ms（忽略 reprogram） |
| 28×28 + tile reprogram | - | - | - | - | +4×26368 cell × 1000 cycle/cell prog | ~2 s（主 bottleneck） |

reprogram latency 决定 28×28 scalability demo 不进 accuracy 主表。

---

## B0.5 — TB sketches（B1 写 RTL 时并行起草）

### TB 新增（4 项）

1. **`tb/streamed_stage_tb.sv`**
   - Golden: Python `_run_stage_streamed_rate`
   - Cases: T ∈ {32, 64, 128, 256}, in_dim ∈ {8, 64, 196, 256}, out_dim ∈ {4, 10, 64, 128}
   - 每 case 10 样本 bit-exact
   - 边界：`threshold` 触发 / 不触发 fire

2. **`tb/tile_accumulator_tb.sv`**
   - Golden: Python `_run_stage_streamed_rate_tiled`
   - Cases: 2/3/4 tiles, 平均 / 末 tile 小
   - 验证 D7：per-tile ADC → accumulate → 最后 LIF 顺序
   - 陷阱测试：`tile_partial_buf` 写入时 `IS_TILE_FINAL` 配置错误 → ERR bit

3. **`tb/stream_chunk_tb.sv`**
   - Golden: Python `run_streamed_rate_chunked`
   - Cases: 2-stage chunked with boundary=[1], stream mode
   - 验证 stream_buf_A/B ping-pong ownership 状态机（D14）
   - SVA：禁止 WRITING + READING 同 buffer（double-port violation）

4. **`tb/multilayer_sample_parity_tb.sv`**
   - Python ↔ RTL 10 Fashion 14×14 样本 bit-identical 对齐（Phase B gate）
   - 用 P4 权重
   - 10 样本 counts + stream 逐 timestep 对比

### 原 TB 全部保持绿
- MULTILAYER / LIGHT / WEIGHTED / SAMPLE_ALIGN / E203 / JTAG_* / UART / SPI / DMA / AXI_BRIDGE / ADC_SAT / CIM_PROG 共 ≥ 10 项

### 错误码 ERR[7:0] 约定

- `0x00` = OK
- `0x01` = START 时 BUSY=1 冲突
- `0x02` = INPUT_SRC == OUTPUT_DST 违规
- `0x03` = TILE_MODE 无 tile_partial_buf 可用（buf state ≠ FREE）
- `0x04` = CIM programming 未完成便发起 stage
- `0x05` = IN_DIM > HW_NUM_INPUTS 或 OUT_DIM > HW_MAX_OUT_NEURONS

---

## B0.6 — Resident-weight Policy 决策表（REV 3.2 D11）

| 拓扑类型 | 权重策略 | 说明 | 本 plan 用途 |
|---|---|---|---|
| 14×14 single (196_10) | **resident** | 3920 cell (×2 = 7840 cell for diff), 装 256×256=65536 OK | P1/P3/P5/P7 主 demo |
| 14×14 multi (196_64_10) | **resident** | 26368 cell (diff×2), OK | P2/P4/P6/P8 主 demo |
| 14×14 wide (196_128_10) | **resident** | 待 MAX_BL_SCAN=256 确认；55040 cell, OK | 可选 ablation |
| 28×28 tile (784_*) | **tile reprogram** | 784 > 256 WL，必须 4 tile 切分 | P12 scalability |
| 8+ 层 chunk deep | **chunk reprogram** | 层数 > MAX_LAYERS，分 chunk 重编权重 | P10 scalability |

**B0.6 gate**：14×14 主 demo 必须 resident，不 reprogram。否则 accelerator 叙事弱。14×14 resident 启动 `STAGE_CTRL.START` 时权重已通过 boot 阶段的 `MAC_W_LOAD_{ADDR,DATA,CTRL}`（标准 V2.B top）或 Phase C2 descriptor-DMA 路径提前写好，stage-run 期间不切权重，也不调 `cim_program_ctrl`。（早期草稿用过 "切 WEIGHT_POS_ADDR/WEIGHT_NEG_ADDR 寄存器" 的说法；那套 CFG4/CFG5=weight-addr 方案已在 BLOCK-V2-02 对齐中废弃，详见 B0.1 末尾的对齐说明。）

---

## B0.7 — Phase B 开工依赖与里程碑

### 依赖（B0 完成前必须齐）

- [ ] B0 文档本身过 GPT + 用户 review（**本 PR**）
- [ ] Python Phase A gate 通过：P1-P4 + P9 强精调 + Fashion gap ≥ +4pp（见 plan REV 3.2 A-gate-required）
- [ ] P14-gate 至少 8-bit / 10-bit ADC 两点数据拿到（用于确认 D15 compile-time 10-bit 决定）
- [ ] `topology_desc.bin` 格式实装并 pytest 绿（本 session 已完成 ✅）
- [ ] `_run_stage_streamed_rate_tiled` 实装并 pytest 绿（本 session 已完成 ✅）
- [ ] `run_streamed_rate_chunked` 实装并 pytest 绿（本 session 已完成 ✅）

### B1 开工顺序（B0 过 review 后）

1. `snn_soc_pkg.sv` 常量（256×256, T_MAX=64, NEURON_DATA_WIDTH 按 adc_bits 派生）
2. `input_stream_sram.sv` 新模块 + 单元 TB
3. `stream_buffer.sv` 重写（取代 spike_feedback）+ ping-pong 状态机
4. `tile_partial_buf.sv` 新模块 + 单元 TB
5. `reg_bank.sv` 按本 B0.1 扩充
6. `layer_sequencer.sv` 简化为单 stage driver
7. `cim_array_ctrl.sv` / `lif_neuron_alu.sv` 改走 stream path
8. 4 项新 TB（streamed_stage / tile_acc / stream_chunk / multilayer_sample_parity）
9. 原 TB 回归

预计 6-8 周。

---

## Open items — FREEZE 记录（GPT review 2026-04-20 后）

| # | Item | 决议 | 说明 |
|---|---|---|---|
| 1 | WL 扫描策略 | **保留 V1 group=8 time-division mux**（功能冻结，不 freeze cycle count） | parity TB 只验 MAC 结果值正确；真 cycle latency 留到 Phase D synthesis 前精化 |
| 2 | ADC_BITS policy | **compile-time 10-bit**，`P_ADC_BITS = 10` 参数化；ADC_CFG 寄存器若保留做 RO build info | firmware 不能 runtime 切 8/12；`topology_desc.required_adc_bits` 必须 == 10 否则 boot 报错 |
| 3 | input_stream_sram ping-pong | **单 buffer**（C-Milestone-1 resident 14×14 单 buffer 够）；ping-pong 留给 tile/chunk/overlap 优化 |
| 4 | tile_partial_buf 物理 | **参数化 `V2B_ENABLE_TILE`**；默认 resident demo 可关闭以节省 14 KB BRAM；tile demo (Phase C4) 前开启 | C-Milestone-1 不依赖 |
| 5 | ML_CTRL (0x48) | **保留 legacy，不驱动 V2B**；V2B 新寄存器从 0x50 开始 | 避免 V1 multilayer legacy 和 V2B stage engine 语义冲突 |

执行级影响：
- `cim_mac_behavioral_v2.sv`：P_ADC_BITS=10 已按此实装 ✅
- `reg_bank` (将在 C integration 中扩充)：STAGE_CTRL/CFG 从 0x50 起，0x48 ML_CTRL 保持 legacy 不动
- `snn_soc_v2b_top.sv` (新 top，避免 V1 冲突)：单 input_stream_sram，tile_partial_buf 可 config parameter
- WL mux 实际实现：V2B `cim_mac_behavioral_v2` 当前用 parallel popcount（不 time-div mux）。真 CIM path 集成时才需 group mux (Phase B2-real 或 Phase D)

---

**签字**：
- 本 doc 作者：Claude (session 2026-04-20)
- Review needed：GPT + 用户
- 实施前 approver：用户
