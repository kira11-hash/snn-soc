# GPT Checkpoint — B5 multilayer sample parity PASS, Phase C 前 review

**日期**：2026-04-20 下午
**进度**：Phase A + B1 + B2 + B5 全绿。4 个 clean commit 落地。准备进 Phase C firmware。
**本次想问你三个小问题**（请简答即可，每题一两段）。

---

## 1. 本轮进展快照（5 小时）

```
Commit 历史（git log --oneline）:
1080457e  v2b B5: multilayer sample parity PASS — 10 Fashion 14x14 samples bit-exact
e385729a  v2b B2: real per-position MAC + streamed-stage Python<->RTL bit-parity PASS
94cb7940  v2b B1 skeleton: streamed-stage RTL primitives + smoke TBs (4/4 green)
b19108e4  v2b phase A: streamed-rate python stack + topology descriptor + tile/chunk engines
```

**Phase A 数字**（GPT 上次 verdict 已通过）：
- Fashion gap +23.96 pp，MNIST gap +12.03 pp，ADC 10-bit vs 8-bit +23.85 pp。

**Phase B 关键 TB 结果**：

| TB | 状态 | 说明 |
|---|---|---|
| input_stream_sram_tb | PASS | T×N bit SRAM, clear/read/write |
| stream_buffer_v2_tb | PASS | A/B ping-pong semantic |
| tile_partial_buf_tb | PASS | [T][N_out] signed 14-bit accumulate + clear |
| stage_engine_v2_tb | PASS | FSM end-to-end smoke w/ trivial weights |
| **streamed_stage_parity_tb** | **PASS** | Python golden ↔ RTL bit-exact, 小 case (in=8, out=4, T=16) |
| **multilayer_sample_parity_tb** | **PASS** | **10 Fashion 14×14 样本 × 2 stage × P4 真实权重 bit-exact** ← Phase B 硬 gate |
| V1 LIGHT smoke | PASS | V1 回归不破 |

**B5 关键结果**（复制自 TB 日志）：
```
[PASS] sample 0 counts = [63 0 0 34 0 0 0 0 0 0]  -> pred class 0
[PASS] sample 1 counts = [0 63 0 0 1 0 0 0 0 0]   -> class 1
[PASS] sample 2 counts = [0 0 61 0 1 0 0 0 0 0]   -> class 2
[PASS] sample 3 counts = [0 0 0 63 0 0 0 4 0 0]   -> class 3
[PASS] sample 4 counts = [0 0 0 0 63 0 1 0 0 0]   -> class 4
[PASS] sample 5 counts = [1 1 0 0 0 63 0 63 0 0]  -> class 5
[PASS] sample 6 counts = [0 0 0 0 0 11 6 0 0 0]   -> class 5 (Python 也误分，不影响 parity)
[PASS] sample 7 counts = [0 0 0 0 0 0 0 63 0 0]   -> class 7
[PASS] sample 8 counts = [0 0 0 0 0 6 0 0 63 0]   -> class 8
[PASS] sample 9 counts = [0 0 0 0 0 63 0 0 62 7]  -> class 5 (Python 也误分)
```

**B5 debug rounds（用 5/10）**：
- R1-R2：MAC 饱和逻辑 zero-width replication bug（fixed in B2 commit）
- R3-R4：stage_engine default pulse 漏 sbA_rd_en/sbB_rd_en 清零 → stream_buf 读信号一拉就不回
- R5：TB 里 `logic sbA_rd_en_mux = ...` 被 SV 当初始化赋值（只在 t=0 评估），改 `assign` 才连续

**当前 git worktree 其他 dirty 内容按 GPT 上次建议**仍未 commit：reg_bank / adc_ctrl / cim_array_ctrl / snn_soc_pkg 旧 V2 遗留等，还有 `fw/` 下一些 header 是之前 session 写的但没验证过。没用 `git add .`。

---

## 2. 三个问题

### Q1. Phase B 是否 gate 过，可以进 Phase C？

B0 mini-spec §B0 gate 只列了：
- 10 Fashion 14×14 样本 Python↔RTL bit-identical ✅ (B5 做到了)
- 原 10+ TB 回归绿 ⚠️ (只跑了 V1 LIGHT，没跑 WEIGHTED / SAMPLE_ALIGN / E203 / JTAG / UART / SPI / DMA / AXI / ADC_SAT / CIM_PROG 其他 9 个)
- FPGA synthesis timing 收敛 ❌ (不做 FPGA)

**没跑的 parity TBs**（REV 3.3 B5 新 4 项里还差 2 项）：
- `tile_accumulator_tb`（纯 tile partial-sum 端到端，验证 D7 per-tile ADC 陷阱在 RTL 侧）
- `stream_chunk_tb`（stream_buf A/B ping-pong 跨 stage ownership 状态机）

**你的建议**：
- (a) B5 过就算 gate，其他 2 个 parity TB 留到论文阶段补做？
- (b) B3 + B4 parity 必须补完再进 Phase C（再加 30-60 min）？
- (c) 必须把 V1 10+ 回归全部再跑一遍再进 Phase C（我的 RTL 改动限在新模块 + snn_soc_pkg V2B_* 并行参数，V1 原 RTL 一行没碰）？

### Q2. Phase C scope 建议

Phase C 有两种做法：

**(a) 保守：standalone 继续**
- `fw/` 下的 5 primitive C wrappers 写成对 reg_bank offset 0x50-0x6F 的总线读写（但这些寄存器**还没**加到 reg_bank 里）
- 写个 C 版 pixel even_rate encoder + topology_desc.bin 解析器
- 写 Icarus-only co-sim TB：bus-driven, 跑 resident 14×14 2-stage, 对 10 样本 bit-exact
- **不触** snn_soc_top / chip_top / e203_min_wrap — stage_engine_v2 不进 SoC 顶层

**(b) 激进：full SoC 集成**
- stage_engine_v2 + 2 个 stream_buf + input_stream_sram + tile_partial_buf 全进 snn_soc_top
- reg_bank 加 B0.1 §里定义的 STAGE_CTRL / STAGE_CFG0-5 / STREAM_BUF_CTRL 等寄存器（0x50-0x80 区间）
- E203 bootloader 里加 SPI→SRAM→descriptor parse→启动推理路径
- 跑 top-level Icarus TB（新 multilayer_top_tb）

(b) 是论文"bit-exact full flow"最有说服力的证据；(a) 只能证明"primitive + 固件"但 SoC 层面黑盒。时间成本：(a) 约 2-3 h；(b) 约 4-6 h（估值）。

你倾向哪个？论文里画哪个图更稳？

### Q3. B0 mini-spec 5 个 open items 哪个必须 freeze

B0 doc/18 文末列了 5 个 open item：

1. WL scan 串行 vs group-mux（V1 用 group=8）
2. ADC 10-bit compile-time（已决）vs runtime（REG_ADC_CFG 里仍写 RW{8,10,12}）
3. input_stream_sram 是否 ping-pong 双 buffer
4. tile_partial_buf 主 demo（非 tile）是否也分配 BRAM
5. ML_CTRL (0x48) 废弃 vs 保留不驱动 layer loop

**你上次说**：item 2 必须在 Phase C 前 freeze（否则 firmware 以为能 runtime 切 12-bit）。

我现在实装：`cim_mac_behavioral_v2` 用 `parameter int P_ADC_BITS = 10`，compile-time 固定。`ADC_CFG` 寄存器目前还没加到 reg_bank。

**其他 4 item 能不能都留到 Phase C 之后**？还是 1/3/4 里有 Phase C 绕不过去的？

---

## 3. 我想要的回复格式

- **(A) Q1 verdict**：GO/补 tile+chunk/补 V1 全回归
- **(B) Q2 选项**：(a)/(b)/混合方案 + 一句理由
- **(C) Q3 freeze list**：哪几项必须现在敲定，值写什么默认
- **(D) blind spot**：我可能没看到的坑（比如 stage_engine_v2 接进 snn_soc_top 时会不会和 V1 的 layer_sequencer / spike_feedback 冲突？它们现在还没删但在 V1 top 里是启用状态的）

直接指 YES/NO 或 (a)/(b)/(c)。不用客套。
