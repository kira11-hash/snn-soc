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

当前已经冻结、可以直接按文档做的，是**推理接口**：

- `wl_data[7:0]`
- `wl_group_sel[2:0]`
- `wl_latch`
- `cim_start`
- `cim_done`
- `bl_sel[4:0]`
- `bl_data[7:0]`
- `clk`
- `rst_n`

这些接口的时序、方向、职责分工，见：

- `doc/08_cim_analog_interface.md`
- `doc/03_cim_if_protocol.md`
- `doc/15_asic_pad_map.md`

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

## 三、最重要的现实情况：外部编程需求已经明确，但协议还没冻结

### 已经明确的需求

`main` 分支当前已经不是“只要求模拟 die 做推理”的口径了。  
现在项目要求已经明确：

> **V1 外部模拟 die 最终必须支持由数字芯片发起的 erase / write / verify。**

数字侧仓库里已经有：

- `PROG_CTRL / PROG_ROW / PROG_COL / PROG_STATUS / PROG_PULSE_WIDTH / PROG_ERASE_WIDTH`
- `cim_program_ctrl`
- `cim_macro_arbiter`

### 但还没冻结的关键点

当前仓库对外 pad 合同，仍然只把**推理接口**冻结了。  
也就是说，下面这些内容**还没有冻结成外部协议**：

- `erase / write / verify` 操作类型怎么跨芯片传递
- `prog_level[3:0]` 怎么跨芯片传递
- `full_array erase` 怎么编码
- 是复用现有推理 pad，还是要新增 sideband / pad

所以现在的真实状态是：

- **推理接口：可以直接执行**
- **外部编程接口：需求已经明确，但协议仍是 blocker**

请不要把 `doc/08` 当前的推理接口合同，误认为已经足以实现外部编程。

---

## 四、模拟同学这轮最该做的事

### A. 现在就可以开做

1. 推理接口实现
2. `wl_data / wl_group_sel / wl_latch` 的 de-mux / latch 架构
3. `cim_start -> cim_done` 的推理时序
4. `bl_sel -> bl_data` 的读出时序
5. ADC/TIA/Vref/噪声/动态范围
6. pad/pin/PCB 约束、电平兼容、供电/偏置方案

### B. 必须尽快和数字侧一起拍板

1. 外部编程是：
   - **新增 pad**
   - 还是 **复用现有推理 pad**
2. 如果复用，具体编码/时序是什么
3. 编程路径上模拟 die 需要提供哪些返回语义：
   - done
   - verify readback
   - pass/fail
   - full-array erase 行为

对应主文档位置：

- `doc/11_analog_handoff_execution_plan.md` 的 **A8 外部编程合同冻结**

---

## 五、这轮希望模拟同学回填/确认的内容

优先级最高：

- `A4`：Vref / TIA 增益 / 满量程电流映射
- `A5`：真实时序数字（DAC / CIM / MUX / ADC）
- `A6`：噪声 / 动态范围 / ENOB / 最小可检电流
- `A7`：时序合同（脉宽、guard time、worst-case delay）
- `A8`：**外部编程合同冻结**
- `P0`：模拟芯片 pinout / pad 排列 / PCB 走线约束
- `P1`：供电 / 偏置 / 参考电压 / IO 电平
- `P2`：RRAM 上电状态 / retention / read disturb / 权重写入策略

---

## 六、给模拟同学的一句话版本

> 现在请先按文档把 **V1 推理接口** 吃透并推进实现；同时和数字侧优先拍板 **外部编程协议 A8**。  
> 没有 A8，推理接口可以做，但“数字发起 erase/write/verify”这条需求还不能无脑落地。
