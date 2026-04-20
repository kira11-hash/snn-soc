# GPT Checkpoint — Phase C Milestone-1 PASS + B3 tile parity PASS + V1 11/11 regression

**日期**：2026-04-20 下午（比 B5-checkpoint 之后约 2 小时）
**进度摘要**：按你上轮 b-lite verdict 执行，**Phase C Milestone-1 通过** + **B3 tile parity 通过** + **V1 11/11 回归全绿**。
**想问你三件事**（简短即可）。

---

## 1. 本轮进展（7 个 clean commits）

```
08ded4f7  v2b B3: tile_accumulator_parity_tb PASS + stage_engine_v2 tile-mode FSM fixes
a5ee1977  v2b Phase C Milestone-1: firmware scheduler + co-sim bit-exact PASS
83d52c08  v2b Phase C-pre: standalone V2B SoC top + bus-driven 10 Fashion sample parity
1080457e  v2b B5: multilayer sample parity 10 Fashion 14x14 bit-exact
e385729a  v2b B2: real per-position MAC + streamed stage parity
94cb7940  v2b B1 skeleton: 4 primitive RTL + 4 smoke TBs
b19108e4  v2b Phase A: Python stack + gate +23.96pp
```

**TB 清单全绿**：

| TB | 状态 |
|---|---|
| input_stream_sram / stream_buffer_v2 / tile_partial_buf | PASS |
| stage_engine_v2 smoke | PASS |
| streamed_stage_parity（Python golden ↔ RTL bit-exact 小 case） | PASS |
| multilayer_sample_parity（10 Fashion 14×14 直接驱动） | PASS |
| v2b_soc_top_parity（bus-driven 10 Fashion samples） | PASS |
| fw_cosim_resident_14x14（C scheduler mirror → Verilog TB） | PASS |
| **tile_accumulator_parity（B3：2-tile partial-sum LIF sweep）** | **PASS** |
| V1 LIGHT / WEIGHTED / SAMPLE_ALIGN / E203 / JTAG_LOADER / JTAG_RESCUE / ADC_SAT / AXI / DMA / SPI / UART | **11/11 PASS** |

**关键 claim 链条**（bit-exact 从 Python 到 firmware）：
```
Python _run_stage_streamed_rate (numpy golden)
   ↓ streamed_stage_parity (direct drive)
RTL cim_mac_behavioral_v2 + stage_engine_v2
   ↓ multilayer_sample_parity (direct drive 2-stage)
RTL 2-stage resident flow
   ↓ v2b_soc_top_parity (bus-driven 2-stage)
SystemVerilog TB as CPU proxy (writes STAGE_CTRL/CFG/INPUT_SRAM regs)
   ↓ fw_cosim_resident_14x14 (C scheduler mirror in SV tasks)
fw/src/v2b_scheduler.c firmware reference

PLUS tile parity (Python _run_stage_streamed_rate_tiled → RTL tile_mode)
```

---

## 2. B3 debug journey（3 轮，都在 10 轮预算内）

B3 tile 模式发现 stage_engine_v2 FSM 有 3 个连环 bug，都在本轮 commit 一起修了：

1. **S_SETUP 自动清 tpb**：多-tile 时每个 stage invocation 都会清 tile_partial_buf，第二个 tile 累加前先被清零。改成固件显式 `STREAM_BUF_CTRL.CLEAR_TILE_BUF`，`S_CLEAR_TPB` 保留但 unreachable。

2. **S_FINAL_READ → S_FINAL_NEURON 直连**：tile_partial_buf 是 sync read（1 cycle 延迟），S_FINAL_NEURON 直接下一 cycle 消费 rd_data 读的是 stale（上一 j 的值），造成"counts 循环左移 1"。加了 `S_FINAL_WAIT` 中间态。

3. **S_FINAL_NEURON 末 j 写 sbA**：`sbA_wr_data <= spike_this_t` 和 `spike_this_t[last_j] <= fire` 同 cycle NBA，RHS 在 NBA 前评估，导致 last_j 的 spike 丢失。加了 `S_FINAL_WRITE` 延 1 cycle。

FSM 状态从 14 个扩到 16 个（4'd14 → 5'd16 bit width）。

V1 / 非 tile path 不受影响（multilayer / v2b_soc_top / fw_cosim 全绿确认）。

---

## 3. 三个问题

### Q1. Phase B 是否完整"过"了？

| GPT B0 gate 项 | 状态 |
|---|---|
| multilayer_sample_parity bit-exact | ✅ |
| tile_accumulator_parity | ✅（本轮 B3 新补） |
| stream_chunk_parity（REV 3.3 D14 ping-pong 状态机） | ❌ 没写 |
| V1 10+ 回归绿 | ✅ 11/11 |
| FPGA synthesis timing 收敛 | N/A（不做 FPGA 阶段，直到 Phase D） |

**stream_chunk_parity 的"工程价值"我持怀疑态度**：
- 现有 multilayer_sample_parity 和 fw_cosim_resident_14x14 已经包含了"stage 0 写 STREAM_A + stage 1 从 STREAM_A 读写 STREAM_B"的实际 ping-pong 流程，bit-exact 都通过
- 剩下的"chunk boundary"语义是 firmware 级（firmware 在 chunk N+1 复用 STREAM_A 作为 chunk N 的输出），在 Milestone-1 的 resident 14×14 场景下用不到（只 2 stage）
- REV 3.3 D14 提到的状态机（`FREE → WRITING → READY → READING`）是**架构级别的 documentation/assertion**，我们目前没实装——因为现在 buffer 读写并发由 bus mux 和 stage_engine FSM 隐式保证，没真正需要 ownership 状态机

**你建议**：
- (a) 不管 stream_chunk_parity，宣布 Phase B 过
- (b) 必须补一个 stream_chunk_parity（即使只是个"跑 2 次 stage，第二次写 B，然后第三次再从 B 读"的烟雾测试）
- (c) 加 SVA 断言在 stream_buffer_v2 里（concurrent WRITE+READ 同 buffer 触发 error），作为状态机"近似"

### Q2. 现在去投稿 / 做 Phase D FPGA，有啥 blocker？

目前交付物：
- **Python**: 24 tests 绿，Phase A +23.96 pp gap，topology_desc.bin exporter
- **RTL**: 5 个新模块（input_stream_sram / stream_buffer_v2 / tile_partial_buf / cim_mac_behavioral_v2 / stage_engine_v2）+ standalone `snn_soc_v2b_top`
- **Firmware**: `fw/include/v2b_soc_regs.h` + `fw/src/v2b_scheduler.c`（host-gcc 语法 clean；C-Milestone-1 co-sim 通过）
- **TB**: 9 个 V2.B 新 TB + V1 11/11 回归
- **Docs**: doc/18 B0 mini-spec（5 open items 全 freeze）
- **8 个 clean commits**

**Phase D 准备度**：RTL 是 behavioral MAC（没接真 CIM analog），FPGA 是纯数字 prototype。Vivado/Quartus 综合这套应该直接能跑（都是 BRAM-inferrable + 合成器友好的结构），但没验证过。

你看还有啥 blind spot？特别问：
- (a) behavioral MAC 数字化 FPGA 是否直接 OK？还是需要先把 MAC 替换成 cim_array_ctrl + 行为模型 RRAM？
- (b) `cim_mac_behavioral_v2` 里 256×128×4-bit 权重 ≈ 16 KB 的 2D array，综合时应该 map 到 BRAM，不会爆 LUT？
- (c) stage_engine_v2 的 FSM 16 状态 + `for (k=0; k<P_N_OUT; k++) membrane[k] <= '0` 这种 for loop 会不会因 P_N_OUT=128 展开太大？

### Q3. 论文叙事是否可以 lock 了？

三个硬数据点：
- MNIST 14×14 multi 96.14% − single 84.11% = +12.03 pp
- Fashion 14×14 multi 82.38% − strong-tune single 58.42% = +23.96 pp
- ADC 10-bit 82.38% vs 8-bit 58.53% = +23.85 pp（ablation）

主 claim（符合你上轮建议）：
> "Configurable, bit-exact Python → RTL → firmware flow, with firmware-managed stream-buffer multiplexing and tile partial-sum accumulator. Validated on MNIST/Fashion 14×14 streamed-rate spiking inference at 10-bit ADC resolution, demonstrating +23.96 pp Fashion-MNIST depth gain via 2-stage architecture."

**Venue 建议（你上轮给的分层）**：Stretch FCCM/FPL/DATE vs 主攻 TRETS/ASAP/ICFPT vs 保底 Q4 (IEICE/Microelectronics J/Integration/JSPS)。

现在可投吗？还是必须要先上 FPGA board 才能投 FCCM/FPL？

---

## 4. 回复格式

请按：
- **(A) Q1 verdict**：Phase B 关门了 / 必须补 stream_chunk / 可选
- **(B) Q2 blind spot**：FPGA 前的具体阻塞点（RTL 结构、MAC 替换、综合风险）
- **(C) Q3 投稿**：现在可投的档次 / 必须补的实验数据 / 必须 FPGA board
- **(D) 下一步最高优先级 1 件事**：直接告诉我做啥

直接 YES/NO。不用客套。
