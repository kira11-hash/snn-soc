# 17 CIM Macro Handoff Cover

**用途**：这是发给做模拟 `CIM macro` 同学的封面说明。  
**目标**：让对方先在 5 分钟内搞清楚三件事：

1. 哪些合同已经冻结，可以直接照着做；
2. 哪些事项仍然是 blocker，不能凭感觉实现；
3. 这轮 handoff 之后，他需要回填/确认什么信息。

---

## 一、这次请直接发给模拟同学的文档

按下面顺序发：

1. `doc/17_cim_macro_handoff_cover.md`（本文件）
2. `doc/11_analog_handoff_execution_plan.md`
3. `doc/08_cim_analog_interface.md`
4. `doc/03_cim_if_protocol.md`
5. `doc/15_asic_pad_map.md`
6. `doc/02_reg_map.md`
7. `rtl/top/snn_soc_pkg.sv`
8. `rtl/top/chip_top.sv`

**不要发历史讨论稿 / 早期 demo / 旧会议材料**。  
如果历史文档和以上文件冲突，**一律以上述文件为准**。

---

## 二、当前已经冻结、可以直接执行的内容

### 1. 双芯片集成形态

- 数字芯片和模拟 `CIM macro` 是**独立流片、独立封装、PCB 互联**
- 不是单 die 片上集成

### 2. 当前已经冻结的外部接口合同

两部分全部都已冻结，可以按文档直接做：

**A. 推理接口**（pads 19..45，frozen 2026-03-16）

- `wl_data[7:0]`, `wl_group_sel[2:0]`, `wl_latch`
- `cim_start`, `cim_done`
- `bl_sel[4:0]`, `bl_data[7:0]`
- `clk`, `rst_n`

**B. 外部编程接口**（pads 46..52，frozen 2026-04-24，方案 α'）

- `prog_op[2:0]` — 编程操作类型编码
- `prog_level[3:0]` — 目标电导等级，仅 write 时有效

推理 pad 与编程 pad 在物理上分开；但载体信号（row/col/readback）仍用推理 pad 复用，模拟侧按 `prog_op` 判断当前 `cim_start` 对应什么操作。

这些接口的时序、方向、职责分工，见：

- `doc/08_cim_analog_interface.md`（§1-9 推理，**§10 编程**）
- `doc/03_cim_if_protocol.md`（上半 推理，**下半 编程**）
- `doc/15_asic_pad_map.md`（pads 19-52 完整接口表）

### 3. 当前已经冻结的系统参数

- `NUM_INPUTS = 64`
- `ADC_CHANNELS = 20`（Scheme B：10 正 + 10 负）
- `ADC_BITS = 8`
- `TIMESTEPS_DEFAULT = 10`
- `THRESHOLD_DEFAULT = 2550`
- 目标时钟：`50 MHz`

最终真源以：

- `rtl/top/snn_soc_pkg.sv`

为准。

---

## 三、外部编程合同已于 2026-04-24 冻结（方案 α'，Q1/Q2/Q3 已全部收口）

> **状态更新（2026-04-24 终版）**：A8 外部编程 pad / 协议合同**已冻结**，
> 模拟同学现在可以**同时**实现推理和外部编程，不再是协议 blocker。  
> **共享载体 pad 路由 + `cim_start` LEVEL-gate 语义 + prog_op/prog_level 与
> cim_start 相位对齐 + verify 时序/噪声预算**均已于 2026-04-24 在数字侧 RTL
> 全部落地并通过回归（`PROG_WL_PAD_ROUTE_TB_PASS` + `PROG_PAD_ENCODER_TB_PASS`
> + `CIM_PROGRAM_CTRL_PASS` 等 16 项 Gate A 全绿）。你这边按本文合同做出来，
> 后续数字+模拟端到端联调不会有协议返工。

### 冻结方案（α'）

**新增 7 个 D→A pad**（pad 总数 48 → 55）：

| pad 索引 | 信号 | 位宽 | 说明 |
|:---:|---|:---:|---|
| 46..48 | `prog_op[2:0]` | 3 | 编程操作类型编码（见下表） |
| 49..52 | `prog_level[3:0]` | 4 | 目标电导等级 0..15，仅 write 有效 |

**不需要**新增 A→D pad（verify PASS/FAIL 由数字侧自己比对 `bl_data`）。

### 操作编码表

| `prog_op[2:0]` | 操作 | `prog_level` 有效？ | row/col 来源 |
|:---:|---|:---:|---|
| `3'b000` | 推理 | — | `wl_data`/`wl_group_sel`/`wl_latch` + `bl_sel`|
| `3'b001` | 擦除单 cell | 否 | 同上（WL 发送 one-hot row） |
| `3'b010` | 写入单 cell | **是** | 同上 |
| `3'b011` | 验证单 cell | 否 | 同上；模拟把 ADC 读回放 `bl_data` |
| `3'b100` | 全阵列擦除 | 否 | 忽略 `wl_data`，所有 WL 同时擦除 |
| `3'b101..111` | 保留 | — | 模拟侧视作 idle |

### 详细协议

- **编码 / 时序 / 电气**：`doc/08_cim_analog_interface.md` §10
- **协议 + RTL 入口**：`doc/03_cim_if_protocol.md` "编程协议" 节
- **pad 索引 + 方向 + 类型**：`doc/15_asic_pad_map.md`（pads 46..52）
- **A8 冻结记录**：`doc/11_analog_handoff_execution_plan.md` §A8

### 时序不变量（模拟侧必须遵守，2026-04-24 Q1/Q2/Q3 锁定）

1. **Q1 — `cim_start` LEVEL-gate**：`cim_start=1` 时驱动 pulse driver /
   read-voltage 打开并按当前 `prog_op` 执行对应操作，`cim_start=0` 时立即
   关闭。**本次 pulse 时长 = `cim_start` 高电平持续时间**。模拟侧**不要**
   自计时，也不要自己查 `prog_op→脉宽` 表。
2. **Q2 — `prog_op` 稳定性**：`prog_op[2:0]` 在**每个** `cim_start=1` 窗口内
   稳定，**不保证**跨整个 `prog_busy` 窗口稳定。write → verify 相位切换
   发生在 `cim_start=0` 的 ≥ 1 cycle gap 中。模拟侧在 `cim_start` 上升沿
   锁存 `prog_op` 即可拿到正确编码。`prog_level` 与 `prog_op` 相位一致。
3. **`prog_level[3:0]` 有效性**：只在 `prog_op==010`（write）时读取；其它
   状态可忽略。
4. **脉宽档位**：`PROG_PULSE_WIDTH` 寄存器档位 0/1/2 = 1/10/100 µs @ 50 MHz
   （数字侧自计时到 `cim_start` 高电平时长）；擦除固定 1 ms。
5. **verify PASS/FAIL 由数字侧判**：数字侧比 `bl_data ∈ [level*16 - 2,
   level*16 + 2]`；**模拟侧不上报 pass 信号**，没有 `prog_pass` pad。
6. **Q3 — verify 时序预算**：`prog_op==011` + `cim_start=1` 后，模拟侧必须
   在 **≤ 100 ns**（5 cycles @ 50 MHz = `ADC_MUX_SETTLE + ADC_SAMPLE`）内
   把 8-bit 读回值稳定到 `bl_data[7:0]`，并保持到 `cim_start` 下降沿
   （或下一次 `bl_sel` 变化）。
7. **Q3 — verify 噪声预算**：模拟+ADC 合计 RMS 噪声 ≤ **1 LSB**（约 ±0.4% FS）；
   噪声达不到时会导致 false-fail，需靠 `PROG_CTRL.RETRY_LIMIT` 多次重试
   救良率（默认 3 次，可配到 7 次）。
8. **保留编码**：`prog_op==101..111` 应视作 idle，不动作。

---

## 四、模拟同学这轮最该做的事（A8 冻结后更新）

### A. 推理侧（原计划不变，继续做）

1. 推理接口实现
2. `wl_data / wl_group_sel / wl_latch` 的 de-mux / latch 架构
3. `cim_start -> cim_done` 的推理时序
4. `bl_sel -> bl_data` 的读出时序
5. ADC/TIA/Vref/噪声/动态范围
6. pad/pin/PCB 约束、电平兼容、供电/偏置方案

### B. 编程侧（A8 已冻结，数字侧已全部 ready，可开做到端到端）

1. 按 §3 在 `cim_start` 上升沿**锁存** `prog_op[2:0]` 和 `prog_level[3:0]`，
   接到内部 `erase / write / verify / full_array_erase` 控制通路
2. 实现 SET / RESET 脉冲驱动电路（电压幅度、上升/下降沿、pulse shape）——
   数字侧保证 `cim_start` 上升沿时 `prog_op` / `prog_level` 已经稳定；
   pulse 时长由 `cim_start` 高电平持续时间决定，模拟侧**不要**自计时
3. 实现 verify 读回通路（单 cell ADC 读，从 `cim_start` 上升沿起 ≤ 100 ns 内
   把结果稳定到 `bl_data[7:0]`，保持到 `cim_start` 下降沿）；RMS 噪声 ≤ 1 LSB
4. 明确 erase / write / verify 的**模拟电压规格**（A4 + A7 会进一步细化）
5. 数字侧已把 shared carrier pads 的 programming routing 补齐（回归
   `PROG_WL_PAD_ROUTE_TB_PASS`），协议层不会再变；你这边直接按本文做到
   可测，就是下一步端到端联调的输入

### C. 需要模拟/器件侧回填的电气参数（非 A8 blocker）

1. 脉冲驱动器的电压 / 上升沿 / 下降沿规格（见 `doc/11` A4 / A7）
2. 模拟芯片 pinout 最终落位 / PCB 走线约束（见 `doc/11` P0）
3. verify 读电压 vs 推理读电压是否共用同一 TIA / ADC 通路（见 `doc/11` A5 / A6）

---

## 五、这轮希望模拟同学回填/确认的内容

优先级最高：

- `A4`：Vref / TIA 增益 / 满量程电流映射
- `A5`：真实时序数字（DAC / CIM / MUX / ADC）
- `A6`：噪声 / 动态范围 / ENOB / 最小可检电流
- `A7`：时序合同（脉宽、guard time、worst-case delay，编程 pulse 电压与时序规格）
- ~~`A8`：外部编程合同冻结~~ → **已由数字侧冻结（2026-04-24，方案 α'）**
- `P0`：模拟芯片 pinout / pad 排列 / PCB 走线约束（需要覆盖新 pads 46..52）
- `P1`：供电 / 偏置 / 参考电压 / IO 电平
- `P2`：RRAM 上电状态 / retention / read disturb / 权重写入策略

---

## 六、给模拟同学的一句话版本

> **推理接口 frozen，外部编程接口 (α', 7 new pads) 也 frozen**。现在请按 `doc/08` §1-9（推理）+ `doc/08` §10（编程）+ `doc/15` pads 19-52 同时推进实现；
> 需要你们回填的是脉冲电压/噪声/电流映射这些**电气参数**，而不是协议本身。
