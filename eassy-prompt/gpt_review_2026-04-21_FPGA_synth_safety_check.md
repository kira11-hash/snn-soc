# GPT Review — V2.B RTL FPGA 综合安全性复查

**日期**：2026-04-21
**背景**：Phase D 首次 Vivado 综合（xczu9eg，Vivado 2022.2）卡死 6 小时。定位 5 处同类型反模式，已系统扫完并修复。**想请你再独立扫一遍**，看是否还有我遗漏的 FPGA synthesis 风险。
**预期回复**：如果你觉得没问题，一句 YES；如果有风险，指出**具体文件:行号**和改法。不用客套。

---

## 1. 我识别的 5 处风险模式

| # | 文件 | 问题模式 | 修法 | Commit |
|---|---|---|---|---|
| 1 | `rtl/snn/cim_mac_behavioral_v2.sv` | 256-input 组合加法树（`always @*` 里 `for (si=0..255) pos_sum += w_pos[si][j]`）→ Vivado "Cross Boundary Optimization" 卡 6h | 改 WL-serial FSM（MS_ACCUM N_IN cycle × all-j-parallel 128 adders + MS_ADC N_OUT cycle）| `41790ff1` |
| 2 | `rtl/snn/tile_partial_buf.sv` | 2D unpacked `mem[0:255][0:127]` 被 Vivado 识别为 "3D-RAM with 458752 registers" 卡死 | 1D flat + `(* ram_style="distributed" *)` + `ifdef SYNTHESIS` counter-walker clear | `00717074` |
| 3 | `rtl/snn/cim_mac_behavioral_v2.sv` | `w_pos_mem/w_neg_mem [0:255][0:127]` 同 #2 问题 | 改 1D packed 512-bit row per si + `(* ram_style="block" *)` + subset write `mem[i][j*4 +: 4]` | `5e0cb552` |
| 4 | `rtl/snn/input_stream_sram.sv` | 256 × 256-bit reset + clear broadcast fan-out | `ifdef SYNTHESIS` 用 counter walker 逐 cell 清；仿真保留 1-cycle 广播清（TB 不动） | `5e0cb552` |
| 5 | `rtl/snn/stream_buffer_v2.sv` | 256 × 128-bit 同 #4 | 同 #4 | `5e0cb552` |

**所有 9 个 V2.B TB + V1 LIGHT 仍 bit-exact 通过**（Icarus 仿真时不走 `ifdef SYNTHESIS` 分支，行为等价原实现）。

## 2. 我认为剩余风险但未改的 3 处

1. **`stage_engine_v2.sv` 里 `logic signed [31:0] membrane [0:127]` + 3 处 `for (k=0;k<128;k++) membrane[k] <= 0`**
   - 128 × 32 = 4096 FF reset fan-out
   - 我判断：~1% xczu9eg budget，Vivado 自己能吞
   - **但你觉得如果 N_OUT 将来扩到 256 会不会就要修**？

2. **`cim_mac_behavioral_v2.sv` 里 `adc_scale` 函数的 `num[63:0] / sum_max`（64-bit / 32-bit 整数除法）**
   - 在 `always @*` 组合块里被调用
   - Vivado 2022.2 通常会推成 DSP48 + 迭代 sequential divider，但也可能综合成超大 combinational LUT divider
   - 如果这是下一个卡点，我准备改成 `MS_ADC` 状态里做多周期 divide（~32 cycle per j），保持 bit-parity
   - **你判断：这事该主动改，还是等 Vivado 报错再说？**

3. **stage_engine_v2 的 `unique case`** → Vivado info "implementing as parallel_case"
   - 非 blocker，但如果有隐患建议去掉 `unique` 改普通 `case`

## 3. 我的扫描方法（你看有没有漏项）

```bash
# 扫所有 V2.B RTL 文件里的 for-loop + 2D array + always @* + reset 模式
grep -nE "^\s*for \(|^\s*logic.*\[0:.*\]\s*\[0:|\[0:P_" <V2B RTL files>
grep -nE "always @\*" <V2B RTL files>  # 检查组合块里是否有巨大 for
```

我只扫了：
- `rtl/top/snn_soc_pkg.sv` (298 lines, 只有 parameter，无风险)
- `rtl/snn/input_stream_sram.sv` (89 lines)
- `rtl/snn/stream_buffer_v2.sv` (83 lines)
- `rtl/snn/tile_partial_buf.sv` (153 lines)
- `rtl/snn/cim_mac_behavioral_v2.sv` (255 lines)
- `rtl/snn/stage_engine_v2.sv` (441 lines)
- `rtl/top/snn_soc_v2b_top.sv` (471 lines)

**我没检查的**（但也没计划综合）：
- `rtl/snn/layer_sequencer.sv`（V1/V2A multilayer，不在 snn_soc_v2b_top 里）
- `rtl/snn/spike_feedback.sv`（V1 遗留）
- `rtl/snn/cim_program_ctrl.sv` 等 V1 模块

## 4. FPGA 反模式 checklist（我从这次踩坑总结的，想请你 review 完整性）

任何一条命中 = 必须 `ifdef SYNTHESIS` 分岔或 refactor：

1. 2D / 3D unpacked array `logic [W-1:0] mem [0:D1-1][0:D2-1]` → Vivado 常常推 RAM 失败
2. reset / clear 路径用 for 循环一次清所有 cell（> ~256 个 FF / 1024 bit）→ broadcast fan-out 爆
3. `always @*` 里 for-loop reduction 超过 ~64 input（popcount / conditional sum）→ 必须 FSM 串行化
4. 大 mem 没加 `(* ram_style = "block" | "distributed" *)` → Vivado 推测可能错
5. `always @*` 里含 `/` 或 `%` 操作 → Vivado 推迭代除法器风险

**你会不会再加几条？比如**：
- `initial` 块里 for-loop 初始化（我的代码里没用）
- `generate` 带参数的大循环展开
- 默认 multi-bit 信号的 X 传播

## 5. 回复格式

**如果你觉得没问题**：直接说 "GO" + 一句"理由"。

**如果你觉得有风险**：
- 指出具体文件:行号
- 改法方向（不用写代码，一两句说思路）
- 严重度（🔴 必须在 Vivado 跑前改 / 🟡 可等 Vivado 报错再说 / 🟢 信息性）

**附加建议**：这份 FPGA 反模式 checklist（§4）要不要合进 `doc/19_phase_d_synthesis_readiness.md` 永久保留？

---

**git log 参考**：
```
5e0cb552  v2b FPGA-synth fix 3: sweep all remaining broadcast-reset / 2D-unpacked risks
00717074  v2b FPGA-synth fix 2: tile_partial_buf flat 1D + ram_style distributed
41790ff1  v2b FPGA-synth fix: refactor cim_mac_behavioral_v2 to WL-serial + all-j-parallel
68f9d000  fpga: add Vivado batch synthesis script + cowork Claude instructions
c9000f9a  doc(phase D): synthesis readiness assessment + GPT Q3 checkpoint prompt
```
