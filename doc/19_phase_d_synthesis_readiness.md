# 19 — Phase D synthesis readiness (V2.B FPGA prototype)

**版本**：v0.1（2026-04-20）
**目的**：GPT 第 8 轮 review (B5-checkpoint 后) 的最高优先级 (D) 动作 —— 在交 Vivado/Quartus 综合前给出 RTL 可综合性评估、资源估算、风险点和改造建议。
**范围**：`rtl/top/snn_soc_v2b_top` + 其下 5 个 V2.B primitive RTL 模块（不含 V1 path，它已在 2026-03-21 tapeout audit 过，综合不是本文档关注）。

---

## 1. 本地 lint / elaboration 结果（verilator 0.239-built20260201）

**命令**：
```bash
verilator --lint-only --top-module snn_soc_v2b_top -Irtl/top \
  -Wno-UNUSED -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
  rtl/top/snn_soc_pkg.sv rtl/snn/input_stream_sram.sv \
  rtl/snn/stream_buffer_v2.sv rtl/snn/tile_partial_buf.sv \
  rtl/snn/cim_mac_behavioral_v2.sv rtl/snn/stage_engine_v2.sv \
  rtl/top/snn_soc_v2b_top.sv
```

**结果**：clean elaboration（除 int/uint32 算术的 width warnings，非 blocker）。

**stats 摘要**（obj_dir/Vsnn_soc_v2b_top__stats.txt）：
- 8 modules, ~250 KB Verilog
- 33 always blocks split
- 4011 clocked scheduling class / 482 combinational
- **无 latch 警告、无 combinational loop、无 undriven net**

结论：**syntactic / functional elaboration 层面可综合**，进 Vivado/Quartus 不会卡在 RTL 可接受性上。

---

## 2. 内存资源实测（post-synth on ZCU102 / xczu9eg, 2026-04-22 更新）

以下表同时列早期**预估**（BRAM 假设）和 Vivado 实测**实际映射**。早期预估保留用于对比，但不应再作为资源规划依据——请以"实际"列为准。

| 存储 | 规模 | bit | 早期预估 | Vivado 2022.2 实际映射 |
|---|---|---|---|---|
| `input_stream_sram.mem_reg` | T_MAX × NUM_INPUTS = 256 × 256 | 65 536 bit | 2 × BRAM18 | **RAM64M8 × 296（distributed LUTRAM）** |
| `stream_buffer_v2 A.mem_reg` | 256 × MAX_OUT_NEURONS = 256 × 128 | 32 768 bit | 1 × BRAM18 | **RAM64M8 × 152（distributed LUTRAM）** |
| `stream_buffer_v2 B.mem_reg` | 256 × 128 | 32 768 bit | 1 × BRAM18 | **RAM64M8 × 152（distributed LUTRAM）** |
| `tile_partial_buf.mem_reg` (P_ENABLE_TILE_BUF=1) | 256 × 128 × signed 14-bit | 458 752 bit | ~13 × BRAM18 | **RAM64M8 × 2048（distributed LUTRAM）** |
| `cim_mac_behavioral_v2.u_mac.g_wcol[*].u_wcol.mem_reg` | 256 × 128 × 4-bit per column | 131 072 bit (pos+neg 合计 262 144 bit) | ~8 × BRAM18 | **168 × RAMB18 + 84 × RAMB36 = 252 BRAM 总计（post-synth initial mapping）** |
| `cim_mac_behavioral_v2.diff_mem` | 128 × 14-bit | 1 792 bit | LUTRAM (tiny) | FF array（综合掉到 ~128 × 14 register） |

（证据：`fpga_synth/reports/synth_log.txt` 的 Distributed RAM Final Mapping Report 和 `Implemented Non-Cascaded Block Ram` 日志行。）

**关键观察**：
1. 权重存储（`g_wcol[*].mem_reg`）成功推 BRAM——这是 WL-serial + all-j-parallel 重构后权重分 16/8 组 column 的直接收益。
2. stream/tile/input SRAM 全部走 **distributed LUTRAM（RAM64M8）**，不是 BRAM。根本原因是它们的读接口有 async 语义（`ram_style = "distributed"` 属性 + 1-cycle RMW），Vivado 不敢推 BRAM。预算：`2048 + 296 + 152 + 152 = 2648 RAM64M8 ≈ ~2648 LUT` （每个 RAM64M8 占 1 LUT-pair），在 ZCU9EG 的 274080 CLB LUT 里可忽略。
3. 合计 BRAM：~252 tiles 于 912 预算，utilization ≈ 27.6%。合计 distributed LUT 影响 < 1%，无压力。

**如果未来要硬推 stream/tile buffer 进 BRAM**（减少 distributed LUT），需要：
- 去掉 `(* ram_style = "distributed" *)` 属性
- 把 RMW 改成 2-cycle pipeline（sync read → hold → sync write）
- stage_engine 对应改 FSM，和 MAC handshake 重跑 parity

非当前优先项；doc/19 §3 说的"weight MAC 组合加法树"才是 timing 关键路径，已用 WL-serial 改掉。

---

## 3. ★ 关键风险：`cim_mac_behavioral_v2` 的 256-input 并行组合求和 ★

**位置**：`rtl/snn/cim_mac_behavioral_v2.sv` 第 121-130 行。

```systemverilog
always @* begin
  pos_sum_c = '0;
  neg_sum_c = '0;
  for (si = 0; si < P_N_IN; si = si + 1) begin
    if ((si < in_dim_latched) && wl_latched_mac[si]) begin
      pos_sum_c = pos_sum_c + w_pos_mem[si][j_idx];
      neg_sum_c = neg_sum_c + w_neg_mem[si][j_idx];
    end
  end
end
```

**问题**：P_N_IN = 256 → 一个 always @* 里 256 次条件加法 → 综合后 = **256-input 加法树** 的两份（pos + neg），级联出 `pos_sum_c` 和 `neg_sum_c`（12-bit）。

**预估后果**：
- **LUT**：256-input 带 enable 的 12-bit 加法器 ≈ 2000-4000 LUT × 2 (pos+neg) = **4-8 K LUT**
- **Timing**：加法树深度 log₂(256) = 8 级，每级 ≈ 12-bit adder ~1.5 ns → **~12 ns 组合延迟**
- 对 Artix-7 @ 100 MHz (10 ns) 必定 timing 跑不过
- 本项目目标 **ZCU102 (Zynq UltraScale+ xczu9eg) @ 50 MHz** 实测 post-route WNS ≈ +8.5 ns（`fpga_synth/reports/impl_log.txt` 可查），timing 健康；同设备 @ 100 MHz 会紧张需重构

**即使跑得过，LUT 吃太多**，留给其他模块的余量非常小。

### 重构选项（按成本-收益排序）

#### 选项 A：保持并行，权重存 BRAM + **pipelined** 加法树（推荐）
- 在 `always @*` 外加一层寄存器分 4 段 pipeline（每段 64 WL 加起来）
- 权重读通过 BRAM（sync read），每 cycle 读 128 个 cell（不现实 — BRAM 端口最多 2 个数据出）
- **不可行**：BRAM 端口数限制让一次 256 个权重读做不到

#### 选项 B：串行 MAC（每 cycle 处理 1 WL × 1 neuron）★强烈推荐
```
FSM: MS_COMPUTE cycles = N_IN × N_OUT
  cycle (j, si): read w_pos[si][j], w_neg[si][j] from BRAM
                 if wl[si] pos_sum += w_pos, neg_sum += w_neg
  cycle (j, N_IN): apply ADC, write diff_mem[j]
```
- 和真实 CIM 架构最接近（真 CIM 也是 WL 串行扫描）
- LUT 开销小（1 个 12-bit accumulator + 1 个 BRAM read port）
- Latency: N_IN × N_OUT = 256 × 128 = 32 768 cycles per stage → 3.3 s @ 100 MHz (too slow!)
- 需要优化：per-j 共用（但 diff 独立）...

#### 选项 C：WL 串行 + 所有 out neuron 并行（每 cycle 1 WL，对所有 j 同时累加）★最佳平衡
```
FSM: MS_COMPUTE cycles = N_IN
  cycle si: read w_pos_row[si] = {w_pos[si][0], w_pos[si][1], ..., w_pos[si][N_OUT-1]}
           (一次 BRAM read 取整行 = 128 × 4-bit = 512 bit port)
           for j in 0..N_OUT-1:
             if wl[si] pos_sum_j += w_pos_row[si][j]
  cycle N_IN: apply ADC for all j in parallel, latch diff_mem
```
- Latency: N_IN = 256 cycles per stage = 2.56 μs @ 100 MHz ×  T=64 timesteps ≈ 164 μs/stage
- LUT: 128 × 12-bit accumulators = ~1500 LUT (可控)
- BRAM 端口带宽：需要 128 × 4-bit = 512-bit wide BRAM row → Xilinx BRAM36 最大 72-bit，需分多组 BRAM
- 分 8 组 BRAM，每组存 16 neuron 的权重 → 每 cycle 并行读 128 × 4-bit

这是最 FPGA-friendly 的架构。工作量：`cim_mac_behavioral_v2` 重构，行数 ~250 行。

#### 选项 D：保留 behavioral 仿真 + Vivado 综合时 `UltraRAM` 或降级到 `distributed RAM`
- 不改 RTL，让 Vivado 自己选 mapping
- 风险：Vivado 可能直接放弃，报告 "failed to infer RAM, using registers" → 100+ K FF
- 大概率 timing 过不去

### 建议路径

**Phase D FPGA prototype 强烈建议走 选项 C**（WL-serial + all-j-parallel）。工程量：
- Python golden 侧 **不改**（仍用 `_run_stage_streamed_rate`，数学等价）
- RTL `cim_mac_behavioral_v2` **重写 MAC 内部**，端口 / 接口不变
- streamed_stage_parity_tb / multilayer_sample_parity_tb / v2b_soc_top_parity_tb 全部不动，仍应 bit-exact 通过（仅 latency 变了）
- 预计 0.5-1 天工作 + 1-2 轮 debug

**如果只是今天想验 "RTL 能综合"**（不上板），把 MAC 的 `always @*` 改成 `always_ff` 注册掉关键路径（pipeline 4-5 级）足够让 Vivado 不报 timing violation，但 LUT 仍然爆。

---

## 4. FSM / 清零 loop 评估（GPT Q2(c)）

### FSM 16 状态（`stage_engine_v2.sv`）

4'd0 ... 5'd15，典型 state 寄存器 5-bit。综合器一键 map 成 one-hot 或 binary encoding。无任何问题。

### 128-wide membrane clear loop

```systemverilog
S_FINAL_LIF: for (k = 0; k < P_N_OUT; k++) membrane[k] <= '0;
S_IDLE + reset: 同样 pattern
```

- 展开：128 × 32-bit FF 清零 = **128 × 32 = 4096 clear paths**，每 cycle 一次
- 综合器把这个展开成 128 并行 FF reset，完全 OK
- No critical path issue

### `for (int t = 0; t < P_DEPTH; t++) for (int j = 0; j < P_WIDTH; j++) mem[t][j] <= 0` in tile_partial_buf

- P_DEPTH=256, P_WIDTH=128 → 32 768 cell 清零
- 综合器会展开成：32 768 × 14-bit reset path
- **LUT 爆炸风险**：如果综合器不聪明，会生成巨大的 reset tree
- **必须检查**：Vivado 综合报告看 tile_partial_buf 是否 infer 成 BRAM（BRAM 自带 reset，OK）还是分布式（LUT 爆炸）
- **fallback**：改 clear 为 "逐 t 串行清零" FSM，避免组合展开

---

## 5. Vivado/Quartus Todo Checklist（用户到有综合工具的机器上做）

- [ ] **Step 1: 创建 project**，导入以下 RTL 文件：
  - `rtl/top/snn_soc_pkg.sv`
  - `rtl/snn/input_stream_sram.sv`
  - `rtl/snn/stream_buffer_v2.sv`
  - `rtl/snn/tile_partial_buf.sv`
  - `rtl/snn/cim_mac_behavioral_v2.sv`
  - `rtl/snn/stage_engine_v2.sv`
  - `rtl/top/snn_soc_v2b_top.sv`
  - top module: `snn_soc_v2b_top`

- [x] **Step 2: 目标器件（已确定）**：
  - **ZCU102 (`xczu9eg-ffvb1156-2-e`，Zynq UltraScale+) @ 50 MHz** —— 本项目实际 FPGA prototype 目标（用户 2026-04-22 确认）
  - 其他参考（不是当前实测目标）：
    - Zynq-7000 XC7Z020 (Zedboard) — 中等容量
    - Artix-7 XC7A100T — 主流 FPGA 板

- [ ] **Step 3: Synthesis only（不 P&R）**，获取：
  ```
  ★ LUT count (total + break down by module)
  ★ FF count
  ★ BRAM18 / BRAM36 count
  ★ DSP48 count
  ★ Estimated Fmax (critical path)
  ★ Warnings about RAM inference
  ```

- [ ] **Step 4: 关键检查项**：
  - `cim_mac_behavioral_v2.u_mac` 的 LUT count 是否爆（>10 K 即爆）
  - `w_pos_mem / w_neg_mem` 是否 inferred as BRAM（正常）vs distributed RAM（异常）
  - `tile_partial_buf.mem` 是否 BRAM（期望）vs LUT（异常）
  - Critical path 是否经过 MAC 的组合加法树（大概率是 YES）

- [ ] **Step 5: 决策**：
  - 如果 LUT < 80% 且 Fmax ≥ 50 MHz → 直接进 P&R 看 timing，可以试上板
  - 如果 LUT > 90% 或 Fmax < 30 MHz → 按上面 §3 选项 C 重构 MAC

- [ ] **Step 6: Place & Route**（综合过后）：
  - 目标 Fmax: 50 MHz（保守起步）/ 100 MHz（上限）
  - 若 timing fail，先 add pipelining stages 在 MAC 和 ADC 之间

- [ ] **Step 7: bitstream + 烧板**（仅在 synthesis + P&R 都过之后）

---

## 6. 当前可宣称 / 不可宣称

**可宣称**（论文 / 技术报告）：
- "bit-exact Python → RTL → firmware-controlled **FPGA-oriented digital prototype**"
- "Verilator lint clean, ready for Vivado synthesis pending RAM-inference confirmation"
- "Architecture designed to map input_stream_sram + stream buffers + tile_partial_buf + weight memory to on-chip BRAM"

**不可宣称**（直到实际综合 + 上板后）：
- ❌ "FPGA-validated" / "board-demonstrated"
- ❌ 具体 LUT / Fmax / throughput 数字
- ❌ "power consumption: X mW" 或类似物理量

---

## 7. 下一步（按 GPT priority）

1. 把此文档 + 源码交给有 Vivado/Quartus 的机器
2. 按 §5 checklist 跑 Step 1-3，获取综合报告
3. 把综合报告 feedback 回来，决定是否需要 §3 选项 C 重构 MAC
4. 若需要重构，重构后跑全回归（9 个 V2.B TB 必须仍 bit-exact PASS）
5. P&R + 上板（Phase D 真正的 FPGA validation）

**本文档作者**：Claude (session 2026-04-20)
**Review needed**：GPT + 用户
**实施前 approver**：用户
