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

- **编码器**：`rtl/top/snn_soc_top.sv` 在 `prog_op_raw` 基于内部
  `prog_busy / prog_en_sig / erase_en_sig / verify_en_sig / prog_full_array /
  prog_level` 生成编码，然后经过 10-stage pipeline (`prog_op_pipe` /
  `prog_level_pipe`) 与 `cim_start_ext` 相位对齐后，从 `prog_op_ext[2:0]` /
  `prog_level_ext[3:0]` 输出端口给出。
- **顶层 pad 路由**：`rtl/top/chip_top.sv` 把 `prog_op_ext` → `prog_op_pad`，
  `prog_level_ext` → `prog_level_pad`。
- **共享载体 pad 路由（2026-04-24 完成）**：`prog_busy=1` 时 `wl_data /
  wl_group_sel / wl_latch` 由 `wl_mux_wrapper` 以 `prog_wl_spike` 为输入驱动；
  `bl_sel_ext` 始终 = `arb_bl_sel`（arbiter 根据 `prog_busy` 自动切到
  `prog_bl_sel`）。
- **脉冲宽度合同（Q1 LEVEL-gate 锁定）**：对 `erase_cell / write / verify /
  erase_full_array`，`cim_start_ext` 作为 external **LEVEL-hold pulse-gate**：
  模拟侧 seeing `cim_start=1` 时保持 pulse driver / read-voltage 驱动开启，
  `cim_start=0` 时立即关闭。**本次 pulse 时长 = `cim_start` 高电平持续时间**，
  模拟侧不要自己做脉宽定时。`PROG_PULSE_WIDTH` 档位 0/1/2 = 1/10/100 µs
  @ 50 MHz；擦除固定 1 ms。
- **内部 gate 源**：`cim_start_ext = prog_busy ? shreg[(prog_dac_valid |
  verify_en_dly1)] : cim_start_pulse`，延迟 10 拍以保证 `wl_data` TDM 先
  完成；`verify_en_dly1` 引入 1-cycle gap，使 pulse 窗口与 verify 窗口
  之间 `cim_start` 必然落到 0。

### 编程时序不变量（2026-04-24 Q1/Q2/Q3 锁定）

1. **`cim_start` LEVEL-gate 语义（Q1）**：`cim_start=1` 高电平持续时间 = 本次
   pulse 或 verify 读回时长；模拟侧以此为唯一开/关控制，不要自计时。
2. **`prog_op` 稳定性（Q2）**：`prog_op` 在每个 `cim_start=1` 窗口内稳定，
   **不保证**跨窗口稳定。write → verify 相位切换发生在 `cim_start=0` 的
   gap cycle 中（至少 1 clk）。模拟侧在 `cim_start` 上升沿锁存 `prog_op` 即可。
3. **`prog_level` 相位对齐**：`prog_level` 和 `prog_op` 通过同一 10-stage
   pipeline 输出，相位相同；只在 `prog_op==010` 时有效。
4. **verify 时序预算（Q3）**：`prog_op==011` 时模拟侧必须在 `cim_start_ext`
   上升沿后 **≤ 100 ns**（5 cycles @ 50 MHz，= `ADC_MUX_SETTLE_CYCLES=2` +
   `ADC_SAMPLE_CYCLES=3`）把 8-bit 读回值稳定到 `bl_data[7:0]`，并保持到
   **`cim_start_ext` 下降沿**（或下一次 `bl_sel` 变化）。
5. **verify 噪声预算（Q3）**：数字侧判据 `bl_data ∈ [level*16 - 2, level*16 + 2]`；
   要求模拟+ADC 合计 RMS 噪声 ≤ **1 LSB**。噪声不达标时用 `PROG_CTRL.RETRY_LIMIT`
   多次重试救良率。
6. **PASS/FAIL 由数字侧判**：**没有** `prog_pass` pad，模拟侧不要返回 pass 信号。
7. **`prog_op==100`（全阵列擦除）**：`wl_data` / `wl_group_sel` / `wl_latch`
   可为任意值，模拟侧忽略；`cim_start=1` 时驱动全阵列同步 RESET。
8. **推理与编程互斥**：推理 (`prog_op==000`) 与编程 (`prog_op!=000`) 在物理
   pad 上不会同时出现（`cim_macro_arbiter` 保证）。

### 与行为模型的关系

`cim_macro_blackbox.sv` 内部用 `prog_en` / `erase_en` / `verify_en` 三个独立信号直接接收编程动作（不经过 pad 级的 `prog_op` 编码）。`prog_op` 编码器是为了把这三个内部信号打包成 3-bit 跨芯片传递，**仅在 ASIC 流片外部模拟 die 场景下起作用**，FPGA 仿真 / Icarus 仿真沿用内部并行接口，不受影响。

### 回归覆盖

- `tb/cim_program_ctrl_tb.sv`（8/8 PASS）— 数字侧编程 FSM
- `tb/prog_bypass_latch_tb.sv`（PROG_BYPASS_LATCH_TB_PASS）— BYPASS_HANDSHAKE 锁存语义
- `tb/prog_pulse_cfg_tb.sv`（PROG_PULSE_CFG_TB_PASS）— 脉宽寄存器 4 档 preset
- `tb/prog_start_interlock_tb.sv`（PROG_START_INTERLOCK_TB_PASS）— START 互锁
- `tb/silicon_bringup_tb.sv`（SILICON_BRINGUP_TB_PASS）— CPU 固件 E2E
- `tb/prog_pad_encoder_tb.sv`（PROG_PAD_ENCODER_TB_PASS）— 断言 `prog_op_ext` /
  `prog_level_ext` 与 10-stage 延迟对齐后的内部 raw 编码匹配
- `tb/prog_wl_pad_route_tb.sv`（PROG_WL_PAD_ROUTE_TB_PASS）— 断言：
  (a) WL 8×8 TDM 重组 = 编程目标行 one-hot；
  (b) `cim_start_ext` 上升沿距离 `wl_latch` 最后一拍 ≥ 9 cycles；
  (c) `cim_start_ext` 是 LEVEL gate（首窗口 ≥ 40 cycles，排除 1-cycle strobe）；
  (d) `prog_op_ext` 在单个 `cim_start=1` 窗口内稳定（Q2）。
- `tb/chip_top_rom_smoke_tb.sv`（CHIP_TOP_ROM_SMOKE_PASS）— chip_top 端到端 smoke

**2026-04-24 状态**：shared carrier pads (`wl_* / cim_start / bl_sel`) 已全部
接通 programming 路径；sideband pads (`prog_op / prog_level`) 已通过 10-stage
pipeline 与 `cim_start_ext` 相位对齐。数字侧 RTL 已满足本文所有不变量，待
FPGA Phase C 端到端上板验证（`main-fpga-e203-alpha` 分支）。
