# 09 数字-模拟接口对接文档（发送给模拟同学）

**文档目的**：数字侧向模拟侧传递当前设计口径，并列出需要模拟侧确认/提供的全部信息，以推进 V1 RTL 收口和后端集成。
**版本**：v1.0
**日期**：2026-02-27
**数字侧联系人**：（填写你的名字）

---

## 一、发给模拟同学的文档清单

| 优先级 | 文档 | 说明 |
|:---:|---|---|
| ★★★ | `doc/08_cim_analog_interface.md` | 主合同：信号定义、时序协议、接口边界、待确认事项 |
| ★★★ | `doc/03_cim_if_protocol.md` | 快速版协议参考（握手时序、ADC MUX 流程） |
| ★★★ | `doc/02_reg_map.md` | 可调参数口径（THRESHOLD、TIMESTEPS、THRESHOLD_RATIO 等） |
| ★★ | `SNNSoC工程主文档.md` 中 §"关键决策点" + §"45-pin方案" | 已定版参数、pin 分配概况 |

**建议阅读顺序**：先看 08 文档了解整体接口框架，再看 03 文档看协议细节，然后看 02 文档了解可配参数，最后看主文档的关键决策点确认已对齐的结论。

---

## 二、当前数字侧已定版参数（供模拟侧了解背景）

| 参数 | 定版值 | 说明 |
|---|---|---|
| 输入维度（WL 数） | **64** | 8×8 离线投影特征（不是原始像素） |
| 输出维度（BL 组数） | **10** | MNIST 分类 0~9，Scheme B 差分 |
| ADC 精度 | **8-bit** | 建模验证最优（6-bit 精度降约1%） |
| 差分方案 | **Scheme B** | 数字侧差分减法，ADC通道数=20（10正+10负） |
| 推理帧数 | **T=10** | 同一输入重复10帧累积膜电位，spike-only精度90.42% |
| 阈值 ratio_code | **4**（4/255≈1.57%） | 上电默认，UART可覆写 |
| THRESHOLD_DEFAULT | **10200** | = 4 × 255 × 10，LIF阈值寄存器上电默认值 |
| 阵列物理规模 | 128×256 RRAM | 差分结构，V1有效使用 64 WL × 20 BL |
| 时钟频率 | **50 MHz**（目标） | 周期 20 ns |
| 总推理子时间步数 | **80** | T=10 帧 × PIXEL_BITS=8 bit-plane = 80 |

---

## 三、需要模拟同学确认/提供的信息（按优先级排序）

### A4【最高优先级】ADC 参考电压与 TIA 增益

> 影响：决定数字侧 THRESHOLD_DEFAULT 的实际物理含义（ADC 满量程 = 多少物理电流）

| 编号 | 问题 | 需要的答案形式 |
|---|---|---|
| A4-1 | ADC 参考电压 Vref_high 和 Vref_low 各是多少？（对应 ADC 输出 255 和 0 各自对应的模拟电压） | 标称值 ± 容差 [mV] |
| A4-2 | TIA（跨阻放大器）的反馈电阻 R_f 是多少？（将 BL 电流转换为电压的增益） | 标称值 ± 容差 [kΩ] |
| A4-3 | TIA 增益是否可调？如果可调，推荐的标称点和调节范围是什么？ | 档位列表或连续范围 |
| A4-4 | TIA/ADC 增益的温漂系数（TCC，ppm/°C）？工作温度范围内的变化量？ | [ppm/°C] |
| A4-5 | 对应 HRS（~1TΩ）和 LRS（~200MΩ）时，TIA 输出电压分别是多少？（验证是否在 ADC 动态范围内） | [mV] |

---

### A5【最高优先级】每个 bit-plane 真实时序分解

> 影响：数字侧需要用实际时序数字替换仿真中的占位参数（DAC_LATENCY=5, CIM_LATENCY=10, MUX_SETTLE=2, ADC_SAMPLE=3），以确保流水线不出现上溢/下溢

当前仿真中一个 bit-plane 的时序预算（总约 125 cycles × 20ns = 2.5 μs）：

```
WL 复用发送：10 cycles（冻结，数字侧控制）
DAC 建立：   5 cycles（待确认）
CIM 计算：  10 cycles（待确认）
ADC × 20：  20 × (MUX_SETTLE=2 + ADC_SAMPLE=3) = 100 cycles（待确认）
```

| 编号 | 问题 | 当前仿真默认值 | 需要真实值 |
|---|---|---|---|
| A5-1 | WL 电压建立时间：从 wl_latch 下降沿到 WL 电压稳定，需多少 ns？（对应多少个 50MHz 周期？） | — | [ns] / [cycles] |
| A5-2 | CIM 电流稳定时间：从 WL 稳定到 BL 电流完全反映 RRAM 权重，需多少 ns？ | 10 cycles = 200 ns | [ns] / [cycles] |
| A5-3 | ADC MUX 切换建立时间：从 bl_sel 变化到 MUX 输出电压稳定（供 ADC 采样），需多少 ns？ | 2 cycles = 40 ns | [ns] / [cycles] |
| A5-4 | ADC 转换时间：从 adc_start 到 adc_done（SAR 完成），需多少 ns？ | 3 cycles = 60 ns | [ns] / [cycles] |
| A5-5 | bl_data 数据有效保持时间：adc_done 后 bl_data 需保持多少拍？（数字侧在 adc_done 后立即读取，需要至少 1 拍） | 1 cycle | [cycles] |
| A5-6 | DAC 建立时间：从 dac_valid && dac_ready 后，WL 驱动器建立稳定需多少 ns？（影响何时可以发 cim_start） | 5 cycles = 100 ns | [ns] / [cycles] |
| A5-7 | 一个完整 bit-plane 总时间（实测最坏情况）？50MHz 下能否 pipeline？ | ~125 cycles / 2.5 μs | [ns] |

---

### A6【高优先级】最小可检电流、动态范围、噪声

> 影响：决定 zero-spike 率能否保持为 0%（阈值过高时微小电流差被噪声掩盖，导致所有神经元静默）

| 编号 | 问题 | 需要的答案形式 |
|---|---|---|
| A6-1 | ADC 输入端的 RMS 噪声是多少？（包含热噪声、1/f噪声、量化噪声的总和） | [LSB RMS] 或 [μV RMS] |
| A6-2 | ADC 输入端的峰峰值噪声（3σ 或 6σ）？（用于估计最坏情况误判率） | [LSB pp] |
| A6-3 | ADC 有效噪声带宽（ENOB）在当前采样率下是多少位？ | [bit] |
| A6-4 | 当所有 64 根 WL 激活（wl_spike = 0xFF...FF）时，期望的 BL 电流总量是多少？ | [nA] |
| A6-5 | 当单根 WL 激活、权重为 LRS 时，单个存储单元产生的电流是多少？（R_on ≈ 200MΩ，Vread=1.5V → I≈7.5nA） | [nA]（确认理论值是否符合实测） |
| A6-6 | HRS 状态（R_off ≈ 1TΩ）下，单个存储单元的漏电流（包含 sneak path）是多少？ | [pA] |
| A6-7 | ADC 有没有内置偏移校准？如果有，上电后是否需要运行校准序列再做推理？ | 是/否，以及校准时间 |
| A6-8 | 温度从 0°C 到 85°C 的变化对 ADC offset 有多大影响（温漂，单位 LSB/°C）？ | [LSB/°C] |

---

### A7【高优先级】最终时序合同（明确谁拉高、保持几拍、脉冲宽度）

> 影响：RTL 中 cim_array_ctrl.sv 的状态机转换条件，以及 adc_ctrl.sv 的 MUX 时序

| 编号 | 问题 | 说明 |
|---|---|---|
| A7-1 | cim_done 脉冲宽度：保持 1 拍还是多拍？（数字侧按单拍脉冲处理） | 请确认 1 cycle / n cycles |
| A7-2 | adc_done 脉冲宽度：1 拍还是多拍？（数字侧按单拍处理） | 请确认 1 cycle / n cycles |
| A7-3 | dac_ready 信号：在 cim_done 之后、下一个 dac_valid 之前，是否需要 de-assert（拉低）再重新拉高？还是可以持续保持高电平？ | 请确认 ready 信号的复位行为 |
| A7-4 | bl_sel 可以在 cim_done 后立即切换，还是需要等待额外的 guard time？ | 请给出 guard time（0 或 n cycles） |
| A7-5 | 在 wl_spike = 64'b0（全 0 输入）时，CIM 是否正常运行 cim_done？还是会静默？ | 关键边界条件 |
| A7-6 | 最高时钟频率下，数字侧发出 cim_start 到模拟侧 cim_done，最大延迟是多少（包含 PVT 最坏情况）？ | [cycles] worst-case |
| A7-7 | 如果数字侧提前发出 cim_start（WL 未完全建立），会有什么后果？有无过早触发保护机制？ | 说明行为 |

---

### P0【中等优先级】物理 pad 映射与 pin 分配

> 影响：chip_top.sv 的 pad wrapper 连法，后端 floorplan

| 编号 | 问题 | 说明 |
|---|---|---|
| P0-1 | 请确认最终 45-pin 分配表（数字侧当前方案见主文档 §45-pin方案），是否有调整需求？ | 需要双方确认一版定稿 pin list |
| P0-2 | 模拟宏（CIM Macro）的 footprint（长×宽，μm）？以及推荐的摆放位置？ | 影响 floorplan |
| P0-3 | CIM Macro 的 IO 口方向（信号从哪一侧进出宏）？wl_data 和 bl_data 各从哪侧出入？ | 影响顶层布线层叠 |
| P0-4 | 模拟供电分区：AVDD/AVSS 和 DVDD/DVSS 是否需要隔离 ring？面积预算如何？ | 影响 guard ring 宽度 |
| P0-5 | ESD 保护策略：wl_spike[63:0] 64 个 WL 信号是否各需独立 ESD 管？还是共用总线保护？ | 影响 pad 面积和引脚数 |

---

### P1【中等优先级】偏置电流与参考电压

| 编号 | 问题 | 说明 |
|---|---|---|
| P1-1 | TIA 偏置电流需要外部提供还是片内产生？如果需要外部引脚，需要几个 pin？ | 影响 pad 分配 |
| P1-2 | ADC 参考电压（Vref）是外部引入还是片内 bandgap？如需外部，精度要求是多少？ | 影响 pin 分配和外部器件 |
| P1-3 | WL 驱动器的 high-level 电压（V_WL_H）是几伏？是否需要单独的高压供电轨？ | 影响电源设计 |
| P1-4 | 整个 CIM 宏（含 DAC+RRAM+TIA+ADC）的静态功耗估计（全 WL=0 时）和动态功耗（全 WL=1 时）？ | 影响电源规划 |

---

### P2【低优先级，但需提前确认】RRAM 权重状态

> 影响：芯片上电后能否直接做推理，还是需要先写权重

| 编号 | 问题 | 说明 |
|---|---|---|
| P2-1 | 流片后 RRAM 单元的初始状态是 HRS（默认 LRS 或随机）？ | V1 只做推理，需确认出厂状态 |
| P2-2 | 权重的保留时间（retention time）在工作温度下估计是多少年/月？ | 评估权重写入后测试窗口 |
| P2-3 | 读取操作对 RRAM 状态有无干扰（read disturb）？连续推理 N 次后权重是否退化？ | 影响系统可靠性指标 |
| P2-4 | V1 流片前，是否需要数字侧提供写权重接口（Write/Erase/Verify）？还是由模拟侧 wafer 测试后直接写入？ | 决定 V1 RTL 是否需要额外控制逻辑 |

---

### 额外补充问题（不在 A4-A7/P0-P2 但同样重要）

| 编号 | 问题 | 优先级 |
|---|---|---|
| X1 | 单根 WL 选中、全部其他 WL 接地时，sneak path 电流约为多少（最坏 64 行中选 1 行）？该值是否会被 ADC 当作有效信号误判？ | 高 |
| X2 | ADC 是否需要上电校准序列（offset/gain trim）？如需要，校准时间估计是多少 us？这段时间数字控制器需要做什么？ | 高 |
| X3 | 满量程的 WL 激活（全 64 根，全 LRS 权重）会产生约多大的 BL 电流？该电流是否超出 TIA 线性范围？ | 高 |
| X4 | 差分对（正列 vs 负列）的匹配精度（mismatch）预计是多少 LSB？对建模精度有无影响？ | 中 |
| X5 | 模拟宏提供 LEF/Liberty/GDS 文件的时间节点？（数字侧需要用于 PR 后端） | 中 |
| X6 | 是否有 CIM 宏的 AMS 仿真模型（用于数字-模拟混合仿真验证）？如有，格式是什么（Verilog-A, Spectre netlist）？ | 中 |
| X7 | 读电压 Vread=1.5V 是直接施加到 WL，还是经过调整？写电压/擦除电压（V2 规划用）各是多少？ | 低（V2 参考） |

---

## 四、会议议程建议（优先级排序）

建议第一次对接会按以下顺序讨论（约 1.5 小时）：

```
[0-10 min]  双方确认 08 文档中的信号表格无异议（信号名、位宽、方向）
[10-25 min] A7：确认时序合同（cim_done/adc_done脉宽、dac_ready行为）→ 输出一版时序合同签字版
[25-45 min] A5：逐项填写真实时序数字 → 输出填好的 3.2 节表格
[45-60 min] A4：确认 ADC Vref 和 TIA 增益 → 输出物理参数表
[60-75 min] A6：确认噪声水平 → 评估阈值是否需要调整
[75-90 min] P0：过 pin 分配表，双方签字确认最终 45-pin 版本
```

---

## 五、数字侧拿到信息后需要做的事

### 拿到 A5（真实时序数字）后：

1. **更新 snn_soc_pkg.sv**：
   ```systemverilog
   parameter int DAC_LATENCY_CYCLES    = <A5-6 实测值>;  // 原 5
   parameter int CIM_LATENCY_CYCLES    = <A5-2 实测值>;  // 原 10
   parameter int ADC_MUX_SETTLE_CYCLES = <A5-3 实测值>;  // 原 2
   parameter int ADC_SAMPLE_CYCLES     = <A5-4 实测值>;  // 原 3
   ```
2. 重新计算一个 bit-plane 的总时钟周期数，评估 80 个 bit-plane（T=10）的总推理时间
3. 评估 50MHz 时钟是否足够，或者是否需要降频

### 拿到 A6（噪声数字）后：

1. 根据 ADC noise floor（单位 LSB）评估当前 THRESHOLD_DEFAULT=10200 是否足够健壮
2. 如果噪声比预期大，考虑调高阈值（改 THRESHOLD_RATIO_DEFAULT），或回服务器跑一次 Python 建模重新标定
3. 更新 Python 建模的 READ_NOISE_SIGMA 参数以反映真实噪声水平，重新验证精度

### 拿到 A4（TIA 增益/Vref）后：

1. 确认 ADC 满量程对应的物理电流（Full_scale_current = Vref_range / R_TIA）
2. 比对建模中 `ADC_FULL_SCALE_MODE = "fixed"` 的假设是否成立
3. 如有偏差，更新 snn_engine.py 中的 full_scale 参数

### 拿到 P0（LEF/Liberty/GDS）后：

1. 将 cim_macro_blackbox.sv 替换为真实宏的端口定义
2. 修改 chip_top.sv 的 pad wrapper 连接（WL 复用 IO 连到真实 pad 宏）
3. 启动 PR 后端流程

---

## 六、等待期间数字侧任务清单

> 在等待模拟同学回复期间，数字侧按以下顺序并行推进。

### 第一阶段（立即开始，约 1 周）

```
优先级 1：Smoke Test（VCS/Verdi 仿真）
  目标：确认 RTL 编译无报错，基本数据通路可走通
  步骤：
    1. 同步最新 RTL 到 shannon 服务器
    2. 运行 vcs 编译（见 sim/run_vcs.sh 或手动写 filelist）
    3. 观察 top_tb.sv 输出：
       - THRESHOLD_RATIO readback = 4 ✓
       - DMA 传输 160 words 完成 ✓
       - CIM DONE 拉高 ✓
       - output_fifo 有 spike_id 输出 ✓
    4. 若有 X 态或 timeout：用 Verdi 追波形定位

优先级 2：学习代码（按 doc/06_learning_path.md Stage A→E 顺序）
  Stage A：snn_soc_pkg.sv → 理解所有参数含义
  Stage B：reg_bank.sv + bus_simple_if.sv → 理解寄存器读写协议
  Stage C：dma_engine.sv + fifo_sync.sv → 理解数据通路
  Stage D：cim_array_ctrl.sv + adc_ctrl.sv + lif_neurons.sv → 理解推理核
  Stage E：wl_mux_wrapper.sv + chip_top.sv → 理解 pad 接口
```

### 第二阶段（拿到模拟侧 A5 之后）

```
1. 更新仿真时序参数（snn_soc_pkg.sv）
2. 重跑 Smoke Test 验证新参数下 DMA+CIM+ADC 时序无违例
3. 如 CIM 计算时间 > 当前 10 cycles，检查 cim_array_ctrl 状态机是否需要扩容
```

### 第三阶段（拿到模拟侧 A6 之后）

```
1. 更新 Python 建模的 READ_NOISE_SIGMA
2. 重跑 python run_all.py --skip-train（约 2-3 小时）
3. 若精度下降 >2%，考虑重新标定阈值 ratio_code
4. 若需要调整 THRESHOLD_DEFAULT，同步更新 snn_soc_pkg.sv
```

### 第四阶段（拿到 LEF/Liberty/GDS 之后）

```
1. 更新 cim_macro_blackbox.sv 端口为真实宏端口
2. 修改 chip_top.sv pad wrapper
3. 启动 DC 综合（合成）
4. 启动 PR 后端（P&R）
```

---

## 七、本文档附带的关键数字（供模拟同学快速核对）

| 参数 | 值 | 来源 |
|---|---|---|
| WL 数（输入维度） | 64 | snn_soc_pkg::NUM_INPUTS |
| BL 通道数（Scheme B） | 20（10正+10负） | snn_soc_pkg::ADC_CHANNELS |
| ADC 精度 | 8-bit | snn_soc_pkg::ADC_BITS |
| 每次推理总 bit-plane 数 | 80（T=10 × PIXEL_BITS=8） | TIMESTEPS_DEFAULT × PIXEL_BITS |
| 数字侧 LIF 阈值（上电默认） | 10200 | THRESHOLD_DEFAULT = 4×255×10 |
| 差分结果位宽 | 9-bit 有符号（[-255, +255]） | NEURON_DATA_WIDTH = ADC_BITS+1 |
| 仿真时钟频率 | 50 MHz | 目标值，待工艺确认 |
| 单 bit-plane 仿真延迟（含20通道ADC） | ~125 cycles ≈ 2.5 μs | 待模拟侧确认真实值 |
| 总推理延迟（80 bit-plane） | 80 × 125 = 10000 cycles ≈ 200 μs | 估算，待更新 |
