# 03_cim_if_protocol

**版本**：v2.1
**日期**：2026-03-16
**模块**：`cim_macro_blackbox`
**参数口径**：与时序相关的默认参数以 `rtl/top/snn_soc_pkg.sv` 为准，本文数值仅作说明，若不一致以 pkg 为准。
**架构说明**：本文描述的是数字芯片内部的 `snn_soc_top` 与行为模型 `cim_macro_blackbox` 之间的**内部并行接口**。实际流片后，数字芯片与模拟 CIM 芯片为独立封装，通过 PCB 互联，使用 `wl_mux_wrapper` 提供的**外部复用接口**（45 个可用 pad 口径）。详见 `doc/08_cim_analog_interface.md` §1.3 与 `doc/15_asic_pad_map.md`。

> **边界说明（2026-04-24 更新）**：本文描述的是数字芯片内部行为模型接口。
> - **推理链路**：本文 §"接口信号" / "时序与触发" / "ADC 时分复用" 节覆盖
> - **外部编程链路**（数字芯片 ↔ 模拟 CIM 芯片，V1 α' 方案已冻结 7 new pads）：见本文末尾 §"编程协议 (External Programming Protocol)" 节 + `doc/08_cim_analog_interface.md` §10 + `doc/15_asic_pad_map.md` pads 46..52

## 接口信号
| 方向 | 信号 | 位宽 | 类型 | 说明 |
|---|---|---:|---|---|
| input | wl_spike | NUM_INPUTS(=64) | 数据 | 单个 bit-plane（64 路并行），同一子时间步的特征向量第 x 位 |
| input | dac_valid | 1 | 脉冲 | 单拍触发信号；行为模型在该拍锁存 `wl_spike`（真实芯片由 `wl_latch` 时序控制） |
| input | cim_start | 1 | 脉冲 | CIM 计算启动 |
| output | cim_done | 1 | 脉冲 | CIM 计算完成 |
| input | adc_start | 1 | 脉冲 | ADC 启动（**仅内部仿真接口**，不在外部 45-pad 接口中；流片后由 `snn_soc_top` 内部固定延迟生成 `adc_done`） |
| output | adc_done | 1 | 脉冲 | ADC 完成（**仅内部仿真接口**，同上） |
| input | bl_sel | $clog2(ADC_CHANNELS)(=5) | 控制 | bitline 选择（0..ADC_CHANNELS-1，Scheme B: 0-9 正列, 10-19 负列） |
| output | bl_data | ADC_BITS(=8) | 数据 | 当前通道的 8-bit ADC 输出 |

## 时序与触发
1. `wl_mux_wrapper` 用 `wl_latch` 完成 8 组 WL 复用发送。
2. `dac_ctrl` 在 `wl_valid_pulse` 到来后锁存 `wl_bitmap` 到 `wl_spike`，并发出 `dac_valid` 单拍。
3. 行为模型在 `dac_valid` 单拍时锁存 `wl_spike`；真实芯片侧不依赖 `dac_ready`，采用固定时序。
4. 控制器等待固定 `DAC_LATENCY_CYCLES` 后发出 `cim_start`，Macro 经过 `CIM_LATENCY_CYCLES` 后拉高 `cim_done`。
5. 控制器发出 `adc_start`，进入 ADC 时分复用采样。

## ADC 时分复用（Scheme B）
- `bl_sel` 依次为 0..ADC_CHANNELS-1（共 20 通道）。
- 每次切换后等待 `ADC_MUX_SETTLE_CYCLES`。
- 对每个通道触发一次 `adc_start`，等待 `adc_done` 后锁存该通道的 `bl_data`。
- 20 路原始数据齐全后，ADC 控制器执行数字差分减法：`diff[i] = raw[i] - raw[i+10]`（i=0..9）。
- 输出 10 路有符号差分数据（NEURON_DATA_WIDTH=9 bit）+ `neuron_in_valid`。

**行为模型说明**：当前 CIM 行为模型在 `adc_done` 时更新所有 20 通道的内部结果，`bl_data` 由 `bl_sel` 选择输出。正列 (0..9) 产生较高值，负列 (10..19) 产生较低值。`adc_done` 的延迟由 `ADC_SAMPLE_CYCLES` 决定。

## 行为模型 bl_data 生成规则

> **注**：以下规则仅适用于数字芯片内的仿真行为模型（`cim_macro_blackbox.sv`）。流片后真实模拟芯片返回的 `bl_data` 由 RRAM 阵列的物理权重决定，公式不同。带权重仿真使用 `sim/models/cim_macro_blackbox_weighted_icarus.sv`，其 ADC 缩放公式为 `scaled = (raw_sum * 255 + 480) // 960`。

```
pop = popcount(wl_latched)
正列 (j < 10):  bl_data[j] = (pop * 2 + j) & 8'hFF
负列 (j >= 10): bl_data[j] = (pop / 2 + (j-10)) & 8'hFF
```
- `popcount` 统计锁存后 `wl_latched` 中 1 的个数（0..64）。

---

## 编程协议 (External Programming Protocol)

**冻结日期**：2026-04-24（方案 α'）
**适用范围**：数字芯片 ↔ 模拟 CIM 芯片跨 PCB 互联（非行为模型）

### 新增外部 pad

| pad 索引（参见 `doc/15_asic_pad_map.md`）| 信号 | 方向 | 位宽 | 说明 |
|:---:|---|:---:|---:|---|
| 46..48 | `prog_op[2:0]` | D→A | 3 | 编程操作类型编码，`cim_start` 脉冲时由模拟侧采样 |
| 49..52 | `prog_level[3:0]` | D→A | 4 | 目标电导等级 0..15，**仅 write (op=010) 时有效** |

### 操作编码

| `prog_op` | 操作 | 载体信号（共享推理 pad） |
|:---:|---|---|
| `3'b000` | 推理 (inference) | `wl_data / wl_group_sel / wl_latch / cim_start / cim_done / bl_sel / bl_data` |
| `3'b001` | 擦除单 cell | 同上；WL 发送 one-hot row，`bl_sel` = col |
| `3'b010` | 写入单 cell | 同上；`prog_level` 给出目标等级 |
| `3'b011` | 验证单 cell（读回） | `wl_data` / `bl_sel` 选 cell；模拟侧 ADC 采样后放到 `bl_data`，数字侧自己比对 pass/fail |
| `3'b100` | 全阵列擦除 | `wl_data` 被模拟侧忽略，所有 WL 同步擦除 |
| `3'b101..111` | 保留 | 模拟侧应视为 idle，不动作 |

### 数字侧 RTL 入口

- **编码器**：`rtl/top/snn_soc_top.sv` 在 `prog_op_ext` / `prog_level_ext` 输出端口生成编码（基于内部 `prog_busy`、`prog_en_sig`、`erase_en_sig`、`verify_en_sig`、`prog_full_array`、`prog_level`）。
- **顶层 pad 路由**：`rtl/top/chip_top.sv` 把 `prog_op_ext` → `prog_op_pad`，`prog_level_ext` → `prog_level_pad`。
- **脉冲宽度合同**：对 `erase_cell / write / erase_full_array`，`cim_start` 作为 external pulse-gate；模拟侧 seeing `cim_start=1` 时保持 pulse driver 开启，`cim_start=0` 时立即关闭。`PROG_PULSE_WIDTH` 档位 0/1/2 = 1/10/100 µs @ 50 MHz；擦除固定 1 ms。

### 编程时序不变量

1. `prog_op` / `prog_level` 在整个 `prog_busy` 期间保持稳定；模拟侧可以在 `cim_start` 上升沿或任一稳定窗口采样。
2. verify 的 PASS/FAIL 由数字侧 `cim_program_ctrl` 在读到 `bl_data` 后自行比对（`bl_data` 落在 `prog_level * 16 ± 2` 内即 PASS），**模拟侧不需要返回 pass 信号**，也没有 `prog_pass` pad。为保证 single-shot verify 稳定一次过，建议模拟侧把 verify 读回在数字 ADC code 上的散布控制在 target 附近约 ±1 LSB 内。
3. `prog_op==100`（全阵列擦除）时 `wl_data` / `wl_group_sel` / `wl_latch` 可为任意值，模拟侧忽略。
4. 推理 (`prog_op==000`) 与编程 (`prog_op!=000`) 在物理 pad 上**不会同时出现**——数字侧的 `cim_macro_arbiter` 保证 `prog_busy` 与推理 FSM 互斥。
5. verify (`prog_op==011`) 时，模拟侧需在默认 `ADC_MUX_SETTLE_CYCLES + ADC_SAMPLE_CYCLES = 5 cycles = 100 ns @ 50 MHz` 预算内把读回值放上 `bl_data`，并保持到下一次 `bl_sel` 或 `prog_op` 变化。

### 与行为模型的关系

`cim_macro_blackbox.sv` 内部用 `prog_en` / `erase_en` / `verify_en` 三个独立信号直接接收编程动作（不经过 pad 级的 `prog_op` 编码）。`prog_op` 编码器是为了把这三个内部信号打包成 3-bit 跨芯片传递，**仅在 ASIC 流片外部模拟 die 场景下起作用**，FPGA 仿真 / Icarus 仿真沿用内部并行接口，不受影响。

### 回归覆盖

- `tb/cim_program_ctrl_tb.sv`（8/8 PASS）— 数字侧编程 FSM
- `tb/prog_bypass_latch_tb.sv`（PROG_BYPASS_LATCH_TB_PASS）— BYPASS_HANDSHAKE 锁存语义
- `tb/silicon_bringup_tb.sv`（SILICON_BRINGUP_TB_PASS）— CPU 固件 E2E
- `tb/prog_pad_encoder_tb.sv` — 直接观察 `snn_soc_top.prog_op_ext / prog_level_ext`，断言四种非 idle 编码与内部 `prog_en / erase_en / verify_en / prog_full_array` 一致
- `tb/chip_top_rom_smoke_tb.sv`（CHIP_TOP_ROM_SMOKE_PASS）— chip_top 端到端 smoke

> **实现 follow-up 提醒**：当前 sideband pads 已接出，但 shared carrier pads (`wl_*`, `cim_start`, `bl_sel`) 还需要数字侧在 `prog_busy` 时切到 programming 源，之后数字+模拟 external programming 才能端到端联调。
