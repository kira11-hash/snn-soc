# V2.B Non-Linearity Proof — feature axis

> **Scope**：本文件论证 V2.B 加速器的"non-linearity"是真实的、validated 的，
> 不是 marketing。Plan REV 5 §M7 要求在 M7 closure 时把 CONV extension 从
> "open extension" 移除——本次 closure 已完成，§7 为更新版。
>
> **Status**: M7 closure（2026-05-02）

---

## 1. 什么是 V2.B 的 "non-linearity"

V2.B 不是单层 SNN MAC，而是 **runtime-configurable multi-layer / multi-stage
inference engine**。"non-linearity" 在以下三个 axis 上证明：

1. **Layer chain non-linearity**：FC stage（全连接）+ CONV stage（卷积，本次
   extension 加入）+ flatten transition 可串成任意拓扑，每个 stage 之间通过
   spike stream（fmap_sram_v2 ping-pong A/B）传递，非线性 LIF 阈值在每个 stage
   内独立执行
2. **Conditional execution**：runtime CFG（CFG_CONV_MODE / CFG_FLATTEN_MODE /
   CFG_TILE_MODE / CFG_IS_TILE_FINAL）切换 stage_engine 行为，无需重 tape-out
   即可表达 FC-only / CONV-only / hybrid CNN+FC 拓扑
3. **Multi-tile partial-sum accumulation**：KKC > 256 时通过 tile_partial_buf 跨
   tile 累加 + 最后 tile final LIF compare，非线性激活函数施加在累加完成之后
   而非每个 tile

---

## 2. Axis A — Layer chain non-linearity

| Layer kind | RTL primitive | Validated by |
|---|---|---|
| FC（fully-connected） | stage_engine_v2 + cim_mac_behavioral_v2 + lif_neuron_alu | V2 baseline frozen tag `v2-permanent-gate-2026-04-25` |
| CONV | stage_engine_v2 + patch_unroller_v2 + dynamic WL ready/valid | M3-M4 LeNet-5 conv1 / conv2，详见 conv_extension_log.md |
| CONV→FC flatten | fmap_flatten_reader_v2（row-major gather） | M3-M4 LeNet-5 fc1（2304→120, 9 tiles） |
| LIF threshold | lif_neuron_alu（spike vs membrane） | 所有 stage 共享 |

每个 stage 的非线性来自 LIF 阈值 + 跨 stage spike stream 传递，这是 SNN
不是简单矩阵乘的根本原因。

---

## 3. Axis B — Runtime configurable, no tape-out

通过 5 + 15 = **20 个 register**（V2 baseline 5 + V2.B CONV extension 15），
CPU 在 runtime 完全 program 多层 stage 拓扑：

- STAGE_CTRL / STAGE_CFG0-5：FC stage 描述
- CONV_MODE_CFG / CONV_CFG_HW/C/K_S_P/OUT_HW/T/TILE/FMAP_BASE/OUT_BASE：CONV stage 描述
- CONV_CTRL / CONV_STATUS：CONV start / weight handshake / done
- CONV_FMAP_WR_DATA/ADDR/CTRL：FW 初始化输入 fmap 写口

LeNet-5 五层（conv1 / conv2 / fc1 / fc2 / fc3）就是同一颗硅 + 不同 register sequence
驱动；架构 capacity 上限受 V2B_NUM_INPUTS=256 + V2B_MAX_OUT_NEURONS=128 + V2B_CONV_MAX_KKC=1152
约束，但 capacity 内的拓扑组合是 runtime configurable。

---

## 4. Axis C — Multi-tile non-linearity boundary

KKC > 256 时（如 LeNet-5 fc1 KKC=2304），单 stage_engine run 拆成 9 个 tile：
- tile_idx 0..7：cfg_is_tile_final=0，每 tile 内 LIF compare 抑制，partial sum
  累加进 tile_partial_buf[t][j]
- tile_idx 8（last）：cfg_is_tile_final=1，stage_engine 对累加值做最终 LIF
  compare → 输出 spike

非线性激活施加在**全部 partial sums 累加完成之后**，不是 tile 边界。这保证
multi-tile 数学等价于单 tile（如果 KKC ≤ 256）的 LIF compare。

`tile_accumulator_parity_tb.sv` + LeNet-5 fc1 cosim 共同验证了这条等价性。

---

## 5. Implementation summary

| Component | RTL file | spec doc |
|---|---|---|
| stage_engine_v2 | `rtl/snn/stage_engine_v2.sv` | M0 spec §3.4（dynamic WL handshake） |
| fmap_sram_v2 | `rtl/snn/fmap_sram_v2.sv` | M0 spec §3.5（32-bit padded layout） |
| patch_unroller_v2 | `rtl/snn/patch_unroller_v2.sv` | M0 spec §3.1 |
| fmap_flatten_reader_v2 | `rtl/snn/fmap_flatten_reader_v2.sv` | M0 spec §3.3 |
| conv_ctrl_v2 | `rtl/snn/conv_ctrl_v2.sv` | M0 spec §3.4.1（错误码 + WAIT_WEIGHT 握手） |
| tile_partial_buf | `rtl/snn/tile_partial_buf.sv` | V2 baseline（M3 重新覆盖） |
| lif_neuron_alu | `rtl/snn/lif_neuron_alu.sv` | V2 baseline（不动） |

详细设计 spec：`C:/tmp/v2-conv-extension/doc/v2-architecture/conv_extension_design.md`
（M0 design freeze，REV 5 时锁定）。

---

## 6. Validation summary

| Layer | Test | Result |
|---|---|---|
| stage_engine_v2 | `tb/stage_engine_v2_tb.sv` + `stage_engine_v2_invalid_cfg_tb.sv` (10/10 incl. T9/T10 PATCH/FLATTEN reject) | PASS |
| dynamic WL protocol | `tb/patch_unroller_v2_unit_tb.sv` (5/5) + `fmap_flatten_reader_v2_unit_tb.sv` (5/5) | PASS |
| fmap_sram_v2 layout | `tb/fmap_sram_v2_unit_tb.sv` (8/8 incl. OOB / cross-bank isolation) | PASS |
| conv_ctrl_v2 error codes | `tb/conv_ctrl_v2_unit_tb.sv` (10/10 incl. ERR_BAD_T/ERR_ILLEGAL_KKC/ERR_BAD_COUT) | PASS |
| byte-mask invariant | `tb/v2b_partial_write_invariant_tb.sv` (33/33: 12 baseline + 21 CONV-reg negative) | PASS |
| End-to-end LeNet-5 cosim | `tb/lenet5_cosim_tb.sv`（仅 evidence 分支） | 10/10 byte-exact |
| End-to-end FPGA 板验（双 CPU） | `ARM_FPGA_DEMO_LENET5_PASS` + `FPGA_V2_E203_BOOT_UART_PASS` | 双侧 PASS |

---

## 7. CONV extension status — UPDATED M7 closure（2026-05-02）

### 旧表述（pre-M7，"open extension"）

> **CONV layer support**: Open extension. V2.B FC infrastructure provides the
> primitives (stage_engine_v2 + tile_partial_buf + lif_neuron_alu); CONV-specific
> patch unrolling + fmap pingpong + tile sequencing are TBD. Scope and gating
> are deferred to a future plan / branch.

### 新表述（M7 closure 之后）

> **CONV layer support**: ✅ **Validated** (M4 LeNet-5 byte-exact + ZCU102 board
> verified on two CPU paths). See `conv_extension_log.md` for closure evidence,
> tag `v2-arm-fpga-demo-conv-passed @ e5d43a05` and `v2-fpga-e203-conv-passed @ 8642c84e`
> for sealed evidence branches.

具体：
- M0 spec frozen（dynamic WL ready/valid + 32-bit padded fmap + WAIT_WEIGHT handshake）
- M3 RTL 4 个新模块 + stage_engine 扩展 + 19 sim gate 全 PASS
- M4 LeNet-5 cosim 10/10 byte-exact + ZCU102 ARM + E203 双路径板验 PASS
- M5 Tiny VGG / Plain-CNN-4 主动收兵（13% 训练精度上限，非 path bug）—— 论文
  叙事不当 contribution
- M6 Phase D port 到两条 evidence 分支完成
- M7 closure tag + 本文件 + `conv_extension_log.md` evidence seal

CONV extension **不再是 open extension**；下一个 architectural rev（v3）才会
扩展到 CIFAR-10 capacity / Spikformer attention / wider weight bit-width 等
（详见 `conv_extension_log.md` §8）。

---

**封存声明**：本文件 §7 描述锁定于 2026-05-02 M7 closure 节点。后续若再加
CONV-related extension（如 weight-stationary 优化），是 v3 plan 的事，不改写
本节"已 validated"叙事。
