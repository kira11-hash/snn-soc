# 11 数字-模拟接口对接文档

**文档目的**：数字侧向模拟侧传递当前设计口径，并列出需要模拟侧确认/提供的全部信息，以推进 V1 RTL 收口和后端集成。
**版本**：v1.3
**日期**：2026-02-27

---

## 零、已确认事项（2026-02-27 更新）
| 编号 | 事项 | 状态 |
|:---:|---|:---:|
| Q1 | **WL de-mux 归属**：模拟侧在芯片内部实现 8 组×8-bit 锁存器，接收 `wl_data/wl_group_sel/wl_latch`，还原 64 根字线驱动 | ✅ 已确认 |
| Q2 | **dac_ready 握手移除**：模拟侧固定时序 WL de-mux，无需 ready 回路；数字侧改为固定 `DAC_LATENCY_CYCLES` 延迟；已更新 dac_ctrl.sv、cim_macro_blackbox.sv、snn_soc_top.sv | ✅ 已实施 |
| Q3 | **chip_top 当前为 pad 骨架占位**：`rtl/top/chip_top.sv` 当前用于接口冻结/lint，不承担最终 pad 连线；不影响当前接口协议发送，但 tapeout 前必须完成 pad cell 实例化与真实连线 | ✅ 已明确 |

---

## 一、模拟侧文档清单

| 优先级 | 文档                                        | 说明                                            |
| :-: | ----------------------------------------- | --------------------------------------------- |
| ★★★ | `doc/11_analog_handoff_execution_plan.md` | 执行主文档：对齐结论、待确认问题、会后回填模板                       |
| ★★★ | `doc/08_cim_analog_interface.md`          | 主合同：信号定义、时序协议、接口边界、待确认事项                      |
| ★★★ | `doc/03_cim_if_protocol.md`               | 快速版协议参考（固定时序、ADC MUX 流程）                      |
| ★★★ | `doc/02_reg_map.md`                       | 可调参数口径（THRESHOLD、TIMESTEPS、THRESHOLD_RATIO 等） |
| ★★  | `SNNSoC工程主文档.md` 中 §"关键决策点" + §"45-pin方案" | 已定版参数、pin 分配概况                                |

**文档一致性约束（对外发送时请附带）**：
- 以上 5 份为当前唯一“对外有效口径”。
- `项目相关文件/器件对齐/器件组合作对齐会议材料_demo.md` 属于历史讨论稿，含早期口径（如 10 通道/`dac_ready`/旧 pin 估算），不作为接口签版依据。
- 若历史文档与上述 5 份冲突，一律以上述 5 份为准（且以 RTL `rtl/top/snn_soc_pkg.sv` 参数为最终准绳）。

**建议阅读顺序**：先看 11 文档掌握整体结论与待回填项，再看 08 文档了解接口框架，然后看 03 文档看协议细节，再看 02 文档了解可配参数，最后看主文档关键决策点确认定版结论。

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
| 对齐精度口径 | spike-only；zero-spike=0.00% | 与当前 Python/RTL 定版口径一致 |
| 证据文件 | `项目相关文件/器件对齐/Python建模/results/summary.txt` | 对齐结果归档 |

---

## 三、需要模拟侧确认/提供的信息（按优先级排序）

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
| A5-6 | DAC 建立时间：从 wl_latch 下降沿后（dac_valid 单拍脉冲触发，固定时序，无 dac_ready 握手），WL 驱动器建立稳定需多少 ns？（影响何时可以发 cim_start） | 5 cycles = 100 ns | [ns] / [cycles] |
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
| ~~A7-3~~ | ~~dac_ready 信号：在 cim_done 之后、下一个 dac_valid 之前，是否需要 de-assert（拉低）再重新拉高？还是可以持续保持高电平？~~ | **已解决（2026-02-27）：模拟侧采用固定时序 WL de-mux，dac_ready 握手已从接口中移除。数字侧改为固定 DAC_LATENCY_CYCLES 延迟，无需 ready 回路。** |
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

### 额外补充问题

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

### 参数回填状态表（会后持续维护）

> 用法：每次会后更新“状态/负责人/日期/版本号”，避免口径漂移。
| 条目 | 当前状态 | 负责人 | 目标日期 | 回填值/文档链接 | 备注 |
|---|---|---|---|---|---|
| A4（Vref/TIA） | 待回填 | 模拟团队 | 待定 | 待补充 | 影响阈值物理映射 |
| A5（时序数字） | 待回填 | 模拟团队 | 待定 | 待补充 | 影响 pkg 时序参数 |
| A6（噪声/动态范围） | 待回填 | 模拟团队 | 待定 | 待补充 | 影响阈值鲁棒性 |
| A7（时序合同） | 待回填 | 数字+模拟联合 | 待定 | 待补充 | 需明确脉宽/guard time |
| P0（pin/pad/floorplan） | 待回填 | 模拟+后端 | 待定 | 待补充 | 影响 chip_top/pad 定稿 |
| P1（供电/偏置） | 待回填 | 模拟+器件 | 待定 | 待补充 | 影响电源与外部引脚 |
| P2（RRAM 状态） | 待回填 | 器件团队 | 待定 | 待补充 | 影响 V1 是否需写入流程 |

### 收口准入条件

- `A7`：每个时序信号的主从、有效沿、脉宽（cycles）、是否允许 back-to-back。
- `A5`：每阶段延迟（ns/cycles）+ 最坏 PVT 数值。
- `A4`：Vref 高低点、TIA 增益标称/容差、是否可调、温漂。
- `A6`：噪声（LSB RMS / pp）、最小可检电流、ENOB、温漂影响。
- `P0`：最终 pin list（45-pin 定稿）与宏接口方位。
- `P1`：AVDD/DVDD 约束、偏置来源、是否新增外部引脚。
- `P2`：RRAM 上电状态、retention/read-disturb、V1 是否需写入流程。

---

## 四、数字侧拿到信息后需要做的事

### 固定改码顺序（避免反复改）

1. 先改时序参数（A5）：`rtl/top/snn_soc_pkg.sv`
2. 重跑 SV lint + smoke test（先确认数字状态机无回归）
3. 再改建模噪声/量程（A4/A6）：`项目相关文件/器件对齐/Python建模/config.py`
4. 先跑 `--skip-train` 做快速一致性回归（只验推理链路）
5. 若精度或稳定性变化超阈值，再决定是否回跑 full
6. 最后处理 pad/物理映射（P0/P1/P2）：`rtl/top/chip_top.sv` + 文档

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

## 五、等待期间数字侧任务清单

> 在等待模拟回复期间，数字侧按以下顺序并行推进。

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

### 返工触发条件（避免反复改）

- 若 `A7` 未定：先不改时序 RTL。
- 若 `A5` 未给最坏值：先不冻结周期参数。
- 若 `A4/A6` 只有定性没有定量：先不改 Python 噪声/满量程。
- 若 `P0` 未给最终 pin list：先不做 pad-level 定稿提交。

---

## 六、本文档附带的关键数字（供模拟侧快速核对）

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
