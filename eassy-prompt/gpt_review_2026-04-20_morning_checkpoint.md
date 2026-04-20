# GPT Review — SNN SoC V2.B Phase A 完成 + B1 skeleton 写完（未跑仿真）Checkpoint

**日期**：2026-04-20 上午
**Context**：你前几轮已经 review 过 REV 3 / 3.1 / 3.2 / 3.3 计划（在 `plans/noble-soaring-beaver.md`）。用户夜间让 Claude 自动推 Phase A + B1 skeleton。早上醒来后需要你对 **当前真实状态** check 一次，给出 verdict（GO / STOP / NEED FIX）和接下来最关键的 1-3 个动作。

---

## 1. Phase A 最终数字（夜间全跑完）

### 主 gate 实验矩阵（MNIST / Fashion 14×14 streamed rate）

| Exp | Dataset | Topology | T | Epoch | Best Acc | 备注 |
|---|---|---|---|---|---|---|
| P1 | MNIST | 196_10 (single) | 64 | 20 | **84.11%** | baseline |
| P2 | MNIST | 196_64_10 (multi) | 64 | 20 | **96.14%** | final |
| P3 | Fashion | 196_10 (single) | 64 | 20 | **52.42%** | baseline |
| P4 | Fashion | 196_64_10 (multi) | 64 | 20 | **82.38%** | final |
| P5 | MNIST | 196_10 | 256 | 15 | **84.29%** | T 对 single 无影响 |
| P6 | MNIST | 196_64_10 | 256 | 15 | **86.45%** | T=256 比 T=64 掉 9.7 pp |
| P7 | Fashion | 196_10 | 256 | 15 | **52.33%** | T 对 single 无影响 |
| P8 | Fashion | 196_64_10 | 256 | 15 | **74.45%** | T=256 比 T=64 掉 7.9 pp |
| **P9** | Fashion | 196_10 **strong-tune** | 64 | **50** | **58.42%** | A-gate 关键 |
| **P14-gate** | Fashion | 196_64_10 ADC 8-bit | 64 | 30 | **58.53%** | vs 10-bit 82.38% |

### Phase A gate verdict（我方自算）

- **Fashion gap（主 gate）**: P4 multi 82.38 − P9 strong-tune single 58.42 = **+23.96 pp** ✅ 远超 +4 pp 门槛
- **MNIST gap（bonus）**: 96.14 − 84.11 = **+12.03 pp** ✅
- **ADC ablation（D15 决策依据）**: 10-bit 82.38 vs 8-bit 58.53 = **10-bit 高 23.85 pp** → B1 锁定 compile-time 10-bit ADC
- **T=64 vs T=256 trend（新发现）**：T 对 single 几乎无影响（52.4→52.3, 84.1→84.3），对 multi 反而 **T=256 比 T=64 低 8-10 pp**。推测是 threshold calibration 是 T=64 调的不适配 T=256；**T=64 成为最优 config**

### 需要你 check 的 Phase A 问题

1. **P9 强精调 58.42% 算不算"足够强"**？plan 里 A2 规定 "30-50 ep + threshold sweep + LR cosine + weight init std sweep {0.05, 0.1, 0.15}"。实际 P9 只跑了 50 ep + 内置 threshold calib，**没跑 LR cosine，没做 weight init std sweep**。这会不会让 +23.96 pp 仍被质疑虚胖？
2. **T=256 multi 比 T=64 低** — 如果 reviewer 质疑 "why not T=256 as default"，我们怎么回答？是做一遍 T=256 专用 threshold recalibration 补数，还是在 paper 里标注 "T=64 is optimal under active_wl ADC scale, T scaling requires re-calibration"？
3. **ADC 8-bit 只拿到 1 点（P14-gate 58.53%）**，不是全 sweep。B1 compile-time 10-bit 决策够稳吗？还是应该补 12-bit 验证以防 10-bit 也不够？
4. **gap +23.96 pp 过于漂亮**—你之前 REV 3 顾虑 Fashion single 52% 可能"没训好"。现在强精调完只涨 6pp（52→58），而不是涨到 70%+。这是否足够反驳 "single 没训好" 的质疑？是否需要做更激进 recipe（更长、cosine、SGD+mom、teacher-student 等）？

---

## 2. B1 RTL skeleton 状态（**已写，未仿真**）

### 新建文件（未 commit，untracked）

| 文件 | 行数 | 说明 |
|---|---|---|
| `rtl/snn/input_stream_sram.sv` | 89 | D6 新 primitive：T_MAX × NUM_INPUTS × 1bit binary stream 存储 |
| `rtl/snn/stream_buffer_v2.sv` | 83 | 取代 spike_feedback：stream_buf_A/B ping-pong |
| `rtl/snn/tile_partial_buf.sv` | 108 | D1 `[T_MAX][MAX_OUT_NEURONS]` signed 14-bit BRAM |
| `rtl/snn/stage_engine_v2.sv` | 394 | 核心 primitive `run_streamed_stage`；**内含 behavioral MAC 占位，未接 cim_array_ctrl** |
| `tb/input_stream_sram_tb.sv` | 118 | 基础写 / 读 TB |
| `tb/stream_buffer_v2_tb.sv` | 100 | ping-pong swap TB |
| `tb/tile_partial_buf_tb.sv` | 120 | partial-sum 累加 TB |
| `tb/stage_engine_v2_tb.sv` | 273 | FSM 驱动 TB（tile_mode=0 + tile_mode=1） |

### `snn_soc_pkg.sv` 更新方式

保守策略：**不改 V1 常量**（保 LIGHT/WEIGHTED/SAMPLE_ALIGN/E203 回归），新加 **V2B_\* 并行参数**：
```
V2B_NUM_INPUTS        = 256
V2B_MAX_BL_SCAN       = 256
V2B_MAX_OUT_NEURONS   = 128
V2B_MAX_TIMESTEPS     = 256
V2B_PARTIAL_WIDTH     = 14  (signed diff accumulator)
V2B_LIF_MEM_WIDTH     = 32
```

### 关键风险 —— **这批 RTL 根本没跑过 Icarus**

- 没 sim 脚本（`sim/sim_stage_engine_v2.f`, `sim/run_stage_engine_v2.sh` 都没写）
- 没编译过一次（iverilog 可能立即挂）
- 没 vvp 产物
- 4 个 TB 对应 RTL 模块的 port / 时序 / 参数名**可能不一致**（我写 RTL 和 TB 时都只用 mental model，没有编译器对齐）
- `stage_engine_v2` 里的 **behavioral MAC** 是占位，完全没接 `cim_array_ctrl` + `adc_ctrl` 真 path。这意味着任何 "bit-parity" 测试现在都是假的

### 需要你 check 的 B1 问题

5. **先跑 Icarus smoke 把 4 个新 TB 编译通过，还是先 commit 一个 "未验证 snapshot" 锁文件？** 倾向先 smoke，但 fear 是 debug 掉下去 1-2 小时还没到真 bit-parity
6. **behavioral MAC 占位**：这种策略是不是 OK？正常是不是应该先把 `cim_array_ctrl` 在单 timestep binary mode 下跑通，stage_engine 只做 FSM + buffer 编排？现在 behavioral_diff = `popcount(wl) × (wpos_base - wneg_base)` 作占位，**等 B2 再换真路径**
7. **4 个新 TB 是否需要先单独 commit + Icarus 绿，再进 B5 multilayer_sample_parity**？还是直接把 4 个合并到一个 sample_parity TB 里一起测？B0 mini-spec §B0.5 列了 4 项新 TB 但没定 "是否独立回归"
8. **V1 常量完全不动对不对**？有没有更清洁的 V2 migration 策略（比如 V1 常量全改成 function of `is_v2_mode`）？还是 V2B_\* 并行命名就是最稳的？
9. **没 commit 是风险** — 你建议我立刻 commit "B1 skeleton untested" 加警示 commit message，还是先 smoke 过再 commit 一个更稳的？

---

## 3. 其他进展（Python 侧已完成，已全绿 pytest）

- `python_multilayer/exporter_multilayer.py` 加 `export_topology_descriptor`（D3 binary descriptor + C header），8 tests 绿
- `python_multilayer/snn_engine_multilayer.py` 加 `_run_stage_streamed_rate_tiled`（D1 `T × out_dim` 累加 + D7 per-tile ADC），9 tests 绿
- `python_multilayer/snn_engine_multilayer.py` 加 `run_streamed_rate_chunked`（A3 stream vs count boundary ablation），7 tests 绿
- `doc/18_v2b_phase_b0_minispec.md` B0 mini-spec draft v0.1 已写，open items 见文末

---

## 4. B0 mini-spec 仍有 5 个 open items 没 freeze

1. WL scan 策略：1 WL/cycle 串行 vs group=8 time-division mux（V1 方式）。倾向保留 V1 group mux，但 `in_dim=196` 时 196/8=25 cycle/timestep 仍 OK
2. `ADC_BITS` compile-time 10-bit vs runtime programmable → 你 REV 3.3 D15 建议 compile-time 10-bit，**我们已按 P14-gate ADC 数据确认**
3. `input_stream_sram` 是否做 ping-pong 双 buffer？现在 B1 没实装，主 14×14 demo 单 buffer 够用
4. `tile_partial_buf` 在非 tile 模式下是否物理存在？现在占 14 KB BRAM（T=64）～56KB（T=256），主 demo 用不到 tile 的话是浪费
5. `ML_CTRL` (0x48) 废弃 vs 保留不驱动 layer loop

### 需要你 check 的 B0 问题

10. 这 5 个 open item **哪几个必须在 B5 multilayer_sample_parity TB 动工前 freeze**？哪些可以留到 B6 回归后？

---

## 5. 我请你给出 verdict 的格式

请按以下结构回复：

### (A) **Phase A 通过 / 不通过**
- 是 / 否 / 需要补做什么实验
- 若需要补：优先级（阻塞 B 的 / 可以并行的）

### (B) B1 下一步 **最关键的 1-3 个动作**
- e.g. "先跑 Icarus smoke；若卡在 X，按 Y 排查；否则先 commit"

### (C) **deal-breaker 或 blind spot**
- 我可能没看到的问题（比如 V2B_\* 并行参数方式有什么隐患、behavioral MAC 占位后续会不会被迫全部返工、等等）

### (D) 论文叙事层面
- +23.96 pp gap 够不够作为 top claim？
- T=256 反而低这事要不要藏起来？
- 强精调只涨 6pp 会不会被 reviewer 质疑？

### (E) 时间建议
- 如果一天内要推到 **B5 sample_parity 过 + Phase C C-Milestone-1 (resident 14×14 bit-exact)**，你觉得可行吗？如果不可行，分阶段建议

---

## 6. 附录：关键参数 / 文件路径

- Plan: `C:\Users\24201\.claude\plans\noble-soaring-beaver.md`（REV 3/3.1/3.2/3.3 全追加在末尾）
- B0 mini-spec: `doc/18_v2b_phase_b0_minispec.md`
- V2.B constants: `rtl/top/snn_soc_pkg.sv` lines ~245-268
- Phase A training logs: `python_multilayer/train_*_T256*.log`, `train_196_10_strongtune.log`, `train_196_64_10_adc8.log`
- Phase A models saved: `python_multilayer/results_multilayer/<topology>/model.pt`
- Python test suite: `python_multilayer/tests/` 共 86 tests，85 passed 1 pre-existing legacy failure
- Git branch: `v2`，没 overnight commits

回复请尽量直接指出问题（YES/NO），避免模棱两可。需要我补数据就明说。
