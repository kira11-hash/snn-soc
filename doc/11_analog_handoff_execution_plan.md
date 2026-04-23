# 11 数字-模拟接口对接文档

**文档目的**：数字芯片团队向模拟 CIM 芯片团队传递当前设计口径，并列出需要模拟侧确认/提供的全部信息，以推进 V1 双芯片 PCB 集成。
**版本**：v2.1
**日期**：2026-03-22（2026-03-31 审核确认：自 v2.1 以来数字侧参数无变更，全部冻结事项保持有效）
**集成架构**：数字芯片与模拟 CIM 芯片为**独立封装、分别流片**，通过 PCB 走线互联（非片上集成）。

> **2026-04-24 状态更新（必须先读）**
>
> 1. `main` 分支当前已经包含数字侧 `cim_program_ctrl + cim_macro_arbiter + PROG_*` 寄存器，项目要求已明确：
>    **V1 外部模拟 CIM die 必须支持由数字芯片发起的 erase / write / verify 编程序列**。
> 2. **外部编程 pad / 协议合同已于 2026-04-24 冻结为方案 α'**（7 new D→A pads：
>    `prog_op[2:0]` + `prog_level[3:0]`，pad 总数 48 → 55）。详细见本文 **A8 章节**
>    的冻结记录 + `doc/08_cim_analog_interface.md` §10 + `doc/03_cim_if_protocol.md`
>    "编程协议" 节 + `doc/15_asic_pad_map.md` pads 46..52。
> 3. 模拟同学现在可以**同时**按推理接口（`doc/08` §1-9 + `doc/03` 上半）和编程接口
>    （`doc/08` §10 + `doc/03` 下半）开做，不再需要等 A8 冻结。
> 4. 本文的 A8 章节保留，以文字形式记录冻结过程与决定——新接手的同学读本节即可。

---

## 【数字侧 P0 阻塞项快速清单】（2026-04-24）

> **🔥 这 18 项是数字侧进入后端 STA 签核前必须拿到的参数**。其他章节（A4~A7 剩余项 + P0/P1/P2 其余 + X1~X5）**可以延后回填**，不影响后端启动。
> **建议回填 deadline：2026-05-08（2 周）**。

| 类别 | 编号 | 数字侧用它做什么 |
|:---:|:---:|---|
| **A4 ADC/TIA** | A4-1 | Vref_high / Vref_low → 校准 `THRESHOLD_DEFAULT` 的物理电流含义 |
| | A4-2 | TIA 反馈电阻 R_f → BL 电流到电压的增益 |
| | A4-5 | HRS/LRS 对应 TIA 输出电压 → 验证落在 ADC 动态范围内 |
| **A5 时序** | A5-1 | WL 电压建立 → pkg `DAC_LATENCY_CYCLES` 占位 5 需校准 |
| | A5-2 | CIM 电流稳定 → pkg `CIM_LATENCY_CYCLES` 占位 10 需校准 |
| | A5-3 | ADC MUX 切换建立 → pkg `ADC_MUX_SETTLE_CYCLES` 占位 2 需校准 |
| | A5-4 | ADC 单次 SAR 转换 → pkg `ADC_SAMPLE_CYCLES` 占位 3 需校准 |
| | A5-5 | bl_data 有效建立 → 影响 Q3 verify 100 ns 窗口是否需放宽 |
| **A6 噪声** | A6-1 | ADC RMS 噪声 → 决定 verify 判据 ±2 LSB 是否需放宽 + retry 默认值 |
| | A6-7 | ADC offset 校准机制 → 决定 bring-up 固件是否需预留初始化时间 |
| **A7 时序合同** | A7-1 | cim_done 脉冲宽度 → 数字侧 FSM 分支（单拍/电平） |
| | A7-4 | bl_sel 在 cim_done 后 guard time → `adc_ctrl` 状态机 |
| | A7-5 | wl_spike=全 0 时 cim_done 行为 → 数字侧要不要加"全零短路"分支 |
| | A7-6 | worst-case cim_start→cim_done 延迟 → 数字侧 timeout 保护阈值 |
| **P0/P1 物理** | P0-2 | 模拟 die 尺寸 + 封装 → PCB 布局 + 两 die 互联走线长度 |
| | P0-3 | 模拟 die 各组信号 pad 引出方向 → PCB 走线对齐 |
| | P1-1/2/3 | 外部电源/偏置 pin 清单 → PCB BOM + 电源规划 |

**填法**：直接在本文 §三 对应章节的表格里填答案，每行末尾都标了"需要的答案形式"和单位。

---

## 零、已确认事项（2026-02-27 更新）
| 编号 | 事项 | 状态 |
|:---:|---|:---:|
| Q1 | **WL de-mux 归属**：模拟侧在芯片内部实现 8 组×8-bit 锁存器，接收 `wl_data/wl_group_sel/wl_latch`，还原 64 根字线驱动 | ✅ 已确认 |
| Q2 | **dac_ready 握手移除**：模拟侧固定时序 WL de-mux，无需 ready 回路；数字侧改为固定 `DAC_LATENCY_CYCLES` 延迟；已更新 dac_ctrl.sv、cim_macro_blackbox.sv、snn_soc_top.sv | ✅ 已实施 |
| Q3 | **chip_top 当前已完成 pad-facing 信号直连**：`rtl/top/chip_top.sv` 已把外部复用端口接到 `snn_soc_top` 的 `_ext` 端口，用于接口冻结/lint；但它仍不是最终工艺 pad-ring 实现，tapeout 前必须完成 pad cell 实例化、ESD/drive 配置与真实物理连线 | ✅ 已明确 |
| Q4 | **Step 3.4/3.5 Python↔RTL 数值对齐已通过（2026-03-16 复核）**：正式 100 样本语料的 `predicted_class` 与 RTL 完全一致（SAMPLE_ALIGN_PASS）。根因修复：`reg_bank.sv` 的 `REG_OUT_DATA` pop 机制从电平检测改为边沿检测，解决了 `bus_read()` 的 `m_valid` 保持 2 拍导致单次读多次 pop 的问题。参数强冻结版本：T=10, ratio_code=1, THRESHOLD_DEFAULT=2550 | ✅ 已通过 |
| Q5 | **双芯片 PCB 集成架构确认**：数字芯片与模拟 CIM 芯片为独立封装、分别流片，通过 PCB 走线互联。所有接口文档已按此架构更新。P0/P1/P2 问题需按"数字芯片侧"与"模拟芯片侧"分别讨论 | ✅ 已明确 |
| Q6 | **Phase 4 外设集成已完成**：AXI-Lite → UART → SPI → DMA 多目标扩展 → E203 接入 → Bootloader/SPI 启动 → JTAG 救援通路，全部集成并通过回归验证。数字芯片已进入 tapeout 准备阶段 | ✅ 已完成 |

---

## 一、模拟侧文档清单

| 优先级 | 文档                                        | 说明                                            |
| :-: | ----------------------------------------- | --------------------------------------------- |
| ★★★ | `doc/17_cim_macro_handoff_cover.md`       | **对外 handoff 封面**：先看这份，明确什么已经冻结、什么仍是 blocker |
| ★★★ | `doc/11_analog_handoff_execution_plan.md` | 执行主文档：对齐结论、待确认问题、会后回填模板                       |
| ★★★ | `doc/08_cim_analog_interface.md`          | 主合同：信号定义、时序协议、接口边界、待确认事项                      |
| ★★★ | `doc/03_cim_if_protocol.md`               | 快速版协议参考（固定时序、ADC MUX 流程）                      |
| ★★★ | `doc/02_reg_map.md`                       | 可调参数口径（THRESHOLD、TIMESTEPS、THRESHOLD_RATIO 等） |
| ★★  | `SNNSoC工程主文档.md` 中 §"关键决策点" + [`doc/15_asic_pad_map.md`](15_asic_pad_map.md) | 已定版参数、pad/pin 分配真源 |

**文档一致性约束（对外发送时请附带）**：
- 以上 5 份为当前唯一”对外有效口径”，均已更新为**双芯片 PCB 集成**架构描述。
- `项目相关文件/器件对齐/器件组合作对齐会议材料_demo.md` 属于历史讨论稿，含早期口径（如 10 通道/`dac_ready`/旧 pin 估算），不作为接口签版依据。
- 若历史文档与上述 5 份冲突，一律以上述 5 份为准（且以 RTL `rtl/top/snn_soc_pkg.sv` 参数为最终准绳）。
- **新增确认（2026-03-16）**：Step 3.4 Python↔RTL 数值对齐已通过，参数为强冻结版本。

**建议阅读顺序**：先看 `doc/17_cim_macro_handoff_cover.md` 掌握哪些事项已经冻结、哪些仍是 blocker；再看 11 文档掌握整体结论与待回填项，然后看 08 文档了解接口框架，再看 03 文档看协议细节，再看 02 文档了解可配参数，最后看主文档关键决策点确认定版结论。

---

## 二、当前数字侧已定版参数（供模拟侧了解背景）

| 参数 | 定版值 | 说明 |
|---|---|---|
| 输入维度（WL 数） | **64** | 默认 `avgpool8x8` 的 8×8 离线特征接口（不是原始像素；RTL 不在硬件里绑定前处理算法） |
| 输出维度（BL 组数） | **10** | MNIST 分类 0~9，Scheme B 差分 |
| ADC 精度 | **8-bit** | 建模验证最优（6-bit 精度降约1%） |
| 差分方案 | **Scheme B** | 数字侧差分减法，ADC通道数=20（10正+10负） |
| 推理帧数 | **T=10（工程默认）** | 当前冻结配置：同一输入重复10帧累积膜电位 |
| 阈值 ratio_code | **1**（1/255≈0.392%） | 上电默认，UART可覆写 |
| THRESHOLD_DEFAULT | **2550** | = 1 × 255 × 10，LIF阈值寄存器上电默认值 |
| 阵列物理规模 | 128×256 RRAM | 差分结构，V1有效使用 64 WL × 20 BL |
| 时钟频率 | **50 MHz**（目标） | 周期 20 ns |
| 总推理子时间步数 | **80** | T=10 帧 × PIXEL_BITS=8 bit-plane = 80 |
| 对齐精度口径 | spike-only；zero-spike=0.00% | 与当前 Python/RTL 定版口径一致 |
| 证据文件 | `项目相关文件/器件对齐/Python建模/summary.txt` | 对齐结果归档 |

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
| A5-4 | ADC 单次转换时间：模拟芯片内部从开始 SAR 转换到结果锁存完成，需多少 ns？（简化协议下 `adc_start/adc_done` 不作为外部信号，此时间包含在 `cim_start→cim_done` 总延迟内） | 3 cycles = 60 ns | [ns] / [cycles] |
| A5-5 | bl_data 数据有效建立/保持时间：`cim_done` 拉高后，数字侧扫描 `bl_sel` 读取 `bl_data`，从 `bl_sel` 切换到 `bl_data` 输出有效需多少 ns？（数字侧按 `ADC_MUX_SETTLE_CYCLES` 等待后读取） | 2 cycles = 40 ns | [ns] / [cycles] |
| A5-6 | DAC 建立时间：从 wl_latch 下降沿后（dac_valid 单拍脉冲触发，固定时序，无 dac_ready 握手），WL 驱动器建立稳定需多少 ns？（影响何时可以发 cim_start） | 5 cycles = 100 ns | [ns] / [cycles] |
| A5-7 | 一个完整 bit-plane 总时间（实测最坏情况）？50MHz 下能否 pipeline？ | ~125 cycles / 2.5 μs | [ns] |

---

### A6【高优先级】最小可检电流、动态范围、噪声

> 影响：决定 zero-spike 率能否保持为 0%（阈值过高时微小电流差被噪声掩盖，导致所有神经元静默）

**已知前置条件（2026-04-24 从 `项目相关文件/器件对齐/` 校入）**：
- **Vread = 1.5 V**（RRAM 读电压，冻结）
- **On/off ratio = 5000:1**（来自 I-V 实测 + `memristor_plugin.py` 的 g_min/g_max 拟合）
- **HRS ≈ 1 TΩ / LRS ≈ 200 MΩ**（实测拟合值，非标称默认）
- **单 cell LRS 理论电流 ≈ 7.5 nA**（= 1.5 V / 200 MΩ），A6-5 只需确认实测是否符合该理论值

**编程 pulse / retry 预算（2026-04-24 器件老师已确认）**：
- 单脉冲宽度档位 `1 / 10 / 100 µs`：✅ 合理
- `PROG_CTRL.RETRY_LIMIT` 默认 3 / 上限 7：✅ 够用

| 编号 | 问题 | 需要的答案形式 |
|---|---|---|
| A6-1 | ADC 输入端的 RMS 噪声是多少？（包含热噪声、1/f噪声、量化噪声的总和） | [LSB RMS] 或 [μV RMS] |
| A6-2 | ADC 输入端的峰峰值噪声（3σ 或 6σ）？（用于估计最坏情况误判率） | [LSB pp] |
| A6-3 | ADC 有效噪声带宽（ENOB）在当前采样率下是多少位？ | [bit] |
| A6-4 | 当所有 64 根 WL 激活（wl_spike = 0xFF...FF）时，期望的 BL 电流总量是多少？**若超出 TIA 线性范围数字侧需知道**以决定是否加 clamp | [nA] |
| A6-5 | 单 cell LRS 实测电流是否符合理论 7.5 nA？ | [nA] |
| A6-6 | HRS 状态（R_off ≈ 1TΩ）下，单个存储单元的漏电流（含 sneak path）是多少？**决定 bl_data 在 HRS 权重下是否被漏电污染** | [pA] |
| A6-7 | ADC 有没有内置偏移校准？若有，上电后是否需要运行校准序列再做推理？**决定固件 bring-up 流程** | 是/否 + 校准时间 |
| A6-8 | 温度从 0°C 到 85°C 的变化对 ADC offset 有多大影响（温漂，单位 LSB/°C）？ | [LSB/°C] |

---

### A7【高优先级】最终时序合同（明确谁拉高、保持几拍、脉冲宽度）

> 影响：RTL 中 cim_array_ctrl.sv 的状态机转换条件，以及 adc_ctrl.sv 的 MUX 时序

| 编号 | 问题 | 说明 |
|---|---|---|
| A7-1 | cim_done 脉冲宽度：保持 1 拍还是多拍？（数字侧按单拍脉冲处理） | 请确认 1 cycle / n cycles |
| ~~A7-2~~ | ~~adc_done 脉冲宽度~~ | **已简化（2026-03-16）：简化协议下 `adc_done` 不作为外部信号。模拟芯片在 `cim_start` 后内部完成 CIM MAC + 全部 ADC 转换，以 `cim_done` 统一返回完成状态。数字侧仅需关注 `cim_done` 脉冲宽度（见 A7-1）。** |
| ~~A7-3~~ | ~~dac_ready 信号：在 cim_done 之后、下一个 dac_valid 之前，是否需要 de-assert（拉低）再重新拉高？还是可以持续保持高电平？~~ | **已解决（2026-02-27）：模拟侧采用固定时序 WL de-mux，dac_ready 握手已从接口中移除。数字侧改为固定 DAC_LATENCY_CYCLES 延迟，无需 ready 回路。** |
| A7-4 | bl_sel 可以在 cim_done 后立即切换，还是需要等待额外的 guard time？ | 请给出 guard time（0 或 n cycles） |
| A7-5 | 在 wl_spike = 64'b0（全 0 输入）时，CIM 是否正常运行 cim_done？还是会静默？ | 关键边界条件 |
| A7-6 | 最高时钟频率下，数字侧发出 cim_start 到模拟侧 cim_done，最大延迟是多少（包含 PVT 最坏情况）？ | [cycles] worst-case |
| A7-7 | 如果数字侧提前发出 cim_start（WL 未完全建立），会有什么后果？有无过早触发保护机制？ | 说明行为 |

---

### A8【已冻结 2026-04-24】外部编程合同（方案 α'，7 new pads）

> 状态更新（2026-04-24）：**A8 不再是 blocker，已冻结为方案 α'**——新增 7 个
> D→A 外部 pad 承载编程语义；pad 总数从 48 扩到 55。模拟同学现在可以按文档
> 直接实现。详细协议与时序见 `doc/08_cim_analog_interface.md` §10 +
> `doc/03_cim_if_protocol.md` "编程协议" 节 + `doc/15_asic_pad_map.md` pads
> 46..52。

#### A8-DECISION（冻结记录）

| 项 | 冻结结果 |
|---|---|
| A8-1 `erase / write / verify` 操作类型 | 编码进 `prog_op[2:0]`（pads 46..48）：`001`=erase_cell, `010`=write, `011`=verify |
| A8-2 `prog_level[3:0]` | 独立 pad `prog_level[3:0]`（pads 49..52），D→A，仅 write 时有效 |
| A8-3 `full_array erase` | `prog_op[2:0] = 3'b100` 专用编码 |
| A8-4 新增 pad vs 复用 | **新增 7 pads 作为编程 sideband**（方案 α'）；推理 pad 维持 frozen 不变 |
| A8-5 编码与时序（2026-04-24 Q1/Q2/Q3 锁定） | (Q1) `cim_start` 在 programming 模式下是 LEVEL-hold gate，本次 pulse/verify 时长 = `cim_start` 高电平持续时间，模拟侧不自计时；(Q2) `prog_op` / `prog_level` 仅在同一 `cim_start=1` 窗口内稳定，write→verify 相位切换发生在 `cim_start=0` 的 ≥ 1 cycle gap 中；(Q3) verify 时 `bl_data` 必须在 `cim_start_ext` 上升沿后 ≤ 100 ns 稳定到 ±1 LSB，并保持到 `cim_start_ext` 下降沿；若要近似 3σ 落在数字侧 `±2 LSB` 判据内，建议 RMS 噪声 ≤ 0.67 LSB（RMS ≤ 1 LSB 时单次通过率约 95%，应依赖 retry）；脉宽档位 `PROG_PULSE_WIDTH` = 1/10/100 µs，擦除固定 1 ms；verify PASS/FAIL 由数字侧在 `bl_data` 读回后自己比对，无 `prog_pass` pad |
| A8-6 16-level 编码方式（2026-04-24 器件侧确认） | **通过"加 N 个 SET 脉冲"区分**，不是通过调幅度。数字侧 `cim_program_ctrl` FSM 实现：写等级 N 时发 N 个脉冲，每写完一次 verify 一次；`bl_data ∈ [N·16 ± 2]` 即 PASS，否则 retry 直到 `PROG_CTRL.RETRY_LIMIT`。 |
| A8-7 脉宽档位确认（2026-04-24 器件老师 OK） | **单脉冲宽度档位 1 / 10 / 100 µs 已确认合理**，pkg 参数 `PROG_WRITE_PULSE_{1,10,100}US_CYC` 保持不动 |
| A8-8 Retry 次数确认（2026-04-24 器件老师 OK） | **`PROG_CTRL.RETRY_LIMIT` 默认 3 次、上限 7 次已确认够用**，pkg 参数 `VERIFY_RETRY_MAX=7` 保持不动 |
| A8-9 上电初始态（待老师回复） | 当前假设：流片后 RRAM 可能为随机态 → bring-up 固件第一步跑 `prog_op=100` 全阵列擦除（fail-safe）。若老师确认上电默认 HRS，可跳过该步骤节省上电时间。**等器件老师答复中** |

#### 数字侧已完成的 RTL 落地（2026-04-24 全部完工）

- `rtl/top/snn_soc_top.sv`：
  - 新增输出端口 `prog_op_ext[2:0]` + `prog_level_ext[3:0]`；
  - 编码器根据内部 `prog_busy / prog_en_sig / erase_en_sig / verify_en_sig /
    prog_full_array / prog_level` 生成 `prog_op_raw`；
  - `prog_op_raw` / `prog_level` 经 10-stage pipeline (`prog_op_pipe` /
    `prog_level_pipe`) 与 `cim_start_ext` 相位对齐（Q2 锁定）；
  - `cim_start_ext = prog_busy ? shreg[(prog_dac_valid | verify_en_dly1)] :
    cim_start_pulse`（Q1 LEVEL-gate，延迟 10 拍对齐 WL）；
  - **共享载体 pad 路由已全部切通**：`wl_data / wl_group_sel / wl_latch` 在
    `prog_busy=1` 时由 `prog_wl_spike` 驱动；`bl_sel_ext = arb_bl_sel`（arbiter
    自动切换）。
- `rtl/top/chip_top.sv`：新增 pad 端口 `prog_op_pad[2:0]` + `prog_level_pad[3:0]`，
  连接到 `snn_soc_top`。
- `doc/15_asic_pad_map.md`：pad 表扩到 55 项，46..52 给新编程接口。
- Gate A 回归 16/16 全绿：`LIGHT / WEIGHTED / DMA / UART / SPI / AXI_BRIDGE /
  CIM_PROGRAM_CTRL / PROG_PULSE_CFG / PROG_START_INTERLOCK / BOOT_ROM /
  SILICON_BRINGUP / E203 / CHIP_TOP_ROM_SMOKE / PROG_BYPASS_LATCH /
  PROG_PAD_ENCODER / PROG_WL_PAD_ROUTE` 均过。

#### 模拟侧可以直接开始做的事

1. **解码 `prog_op[2:0]`**：在 **`cim_start` 上升沿**锁存（数字侧保证此时
   `prog_op` 稳定）；`000` → 推理常态；`001/010/011/100` → 对应编程；其它视为 idle。
2. **解码 `prog_level[3:0]`**：仅 `prog_op==010` (write) 时读取；与 `prog_op`
   相位一致，同时锁存即可。
3. **复用推理 pad 载 row/col**：编程的 row 来自 `wl_data / wl_group_sel /
   wl_latch` 的 8×8 TDM one-hot（在 `cim_start` 上升沿前已经 latch 完毕）；
   col 来自 `bl_sel[4:0]`，在整个 `cim_start=1` 窗口内稳定。
4. **脉冲驱动器（Q1）**：seeing `cim_start=1` → 打开 pulse driver 并按当前
   `prog_op` 执行对应操作；seeing `cim_start=0` → 立即关闭。**不要**自己
   做脉宽定时。
5. **verify 读回路径（Q3）**：收到 `prog_op=011` + `cim_start=1` 后，**≤ 100 ns**
   内把 8-bit ADC 读回值稳定到 `bl_data[7:0]`，保持到 `cim_start` 下降沿；
   若要近似 3σ 落在数字侧 `±2 LSB` 判据内，建议模拟+ADC 合计 RMS 噪声
   ≤ **0.67 LSB**。若只能做到 RMS ≤ **1 LSB**，系统仍可工作，但默认应依赖
   retry；**不需要**上报 pass/fail。

#### 仍然是开放项（非 A8 blocker，最终完工清单）

- 脉冲驱动器的**电压**与**上升/下降沿**规格 → A4 / A7（器件老师侧回填）
- FPGA Phase C 上板端到端验证（`main-fpga-e203-alpha` 分支）：三个 PASS tag
  `FPGA_E203_BOOT_UART_PASS` / `FPGA_E203_PROGRAM_ERASE_WRITE_PASS` /
  `FPGA_E203_PROGRAMMED_INFERENCE_PASS`，证明 Q1/Q2/Q3 在综合后的真实
  硅时序上仍成立
- 模拟芯片 pinout 最终落位（如 `doc/15_asic_pad_map.md` pad 索引要不要重排）→ P0（两边联合确认）
- verify 读电压与推理读电压是否共用同一 TIA/ADC 通路 → A5 / A6 细化

---

### P0【中等优先级】物理 pad 映射与 pin 分配

> 影响：两颗芯片各自的 pad 布局 + PCB 互联走线规划

> **双芯片架构说明**：数字芯片与模拟芯片独立封装、分别流片，各自有独立的 pad ring。两颗芯片的信号 pad 需一一对应，通过 PCB 走线互联。

| 编号 | 问题 | 适用范围 | 说明 |
|---|---|---|---|
| P0-1 | 请确认最终 55 pad 全表（数字侧真源见 [`doc/15_asic_pad_map.md`](15_asic_pad_map.md)），是否有调整需求？ | 双方 | 需要双方确认一版定稿 pin list，两颗芯片 pad 一一对应 |
| P0-2 | 模拟芯片的 die size（长×宽，mm）和封装形式？ | 模拟芯片 | 影响 PCB 布局和走线长度 |
| P0-3 | 模拟芯片信号 pad 的排列顺序（wl_data/bl_data 各从哪侧引出）？ | 模拟芯片 | 影响 PCB 走线对齐和信号完整性 |
| P0-4 | 两颗芯片的供电方案：AVDD/AVSS（模拟）和 DVDD/DVSS（数字）在 PCB 上如何分区？是否需要独立 LDO？ | PCB 设计 | 影响电源完整性和噪声隔离 |
| P0-5 | ESD 保护策略：两颗芯片的互联信号 pad 各需什么级别的 ESD 保护？（片间走线已有 PCB 布局保护，ESD 等级可能低于对外 IO） | 双方 | 影响 pad 面积和 IO 驱动能力 |

---

### P1【中等优先级】偏置电流与参考电压

> **双芯片架构说明**：偏置和参考电压相关问题仅涉及模拟芯片内部设计，但若需外部引脚则影响 PCB 设计和 BOM。

| 编号 | 问题 | 适用范围 | 说明 |
|---|---|---|---|
| P1-1 | TIA 偏置电流需要外部提供还是模拟芯片片内产生？如需外部引脚，需几个 pin？ | 模拟芯片 + PCB | 影响模拟芯片 pad 分配和 PCB 外部器件 |
| P1-2 | ADC 参考电压（Vref）是外部引入还是模拟芯片片内 bandgap？如需外部，精度要求？ | 模拟芯片 + PCB | 影响 PCB 外部精密参考源选型 |
| P1-3 | WL 驱动器的 high-level 电压（V_WL_H）是几伏？是否需要单独的高压供电轨？ | 模拟芯片 + PCB | 影响 PCB 电源设计（可能需要额外 LDO/charge pump） |
| P1-4 | 模拟芯片（含 DAC+RRAM+TIA+ADC）的静态功耗（全 WL=0 时）和动态功耗（全 WL=1 时）？ | PCB 电源 | 影响 PCB 电源规划和散热 |

---

### P2【低优先级，但需提前确认】RRAM 权重状态

> 影响：模拟芯片上电后能否直接做推理，还是需要先写权重
> **双芯片架构说明（2026-04-23 更新）**：RRAM 位于模拟芯片内部。`main` 分支数字侧已经引入编程控制器与 `PROG_*` 寄存器，项目目标也已经调整为：**V1 外部模拟 die 最终要支持由数字芯片发起的 erase / write / verify。**
> 外部编程 pad / 协议合同已经在 A8 冻结；当前 remaining gap 不是协议，而是数字侧 external programming 共享载体信号 routing 的 RTL follow-up。系统 bring-up 仍建议保留“预烧录 / 外部测试写入”作为兜底方案。

| 编号 | 问题 | 适用范围 | 说明 |
|---|---|---|---|
| P2-1 | 流片后 RRAM 单元的初始状态是 HRS（默认 LRS 或随机）？ **状态（2026-04-24）：已向器件老师提问，等回复** | 模拟芯片 | 决定上电后是否必须先跑数字发起的编程流程 |
| P2-2 | 权重的保留时间（retention time）在工作温度下估计是多少年/月？ | 模拟芯片 | 评估权重写入后测试窗口 |
| P2-3 | 读取操作对 RRAM 状态有无干扰（read disturb）？连续推理 N 次后权重是否退化？ | 模拟芯片 | 影响系统可靠性指标 |
| P2-4 | V1 模拟芯片的权重写入方案：由数字芯片发起 erase/write/verify，还是仅保留 wafer 测试设备写入作为 fallback？ | 模拟芯片 + 数字芯片 | 主路径已要求支持数字发起编程；bring-up 仍建议保留外部测试写入 fallback |

---

### 额外补充问题

| 编号 | 问题 | 优先级 |
|---|---|---|
| X1 | 单根 WL 选中、全部其他 WL 接地时，sneak path 电流约为多少（最坏 64 行中选 1 行）？该值是否会被 ADC 当作有效信号误判？ | 高 |
| X2 | ADC 是否需要上电校准序列（offset/gain trim）？如需要，校准时间估计是多少 us？这段时间数字控制器需要做什么？ | 高 |
| X3 | 满量程的 WL 激活（全 64 根，全 LRS 权重）会产生约多大的 BL 电流？该电流是否超出 TIA 线性范围？ | 高 |
| X4 | 差分对（正列 vs 负列）的匹配精度（mismatch）预计是多少 LSB？对建模精度有无影响？ | 中 |
| X5 | 读电压 Vread=1.5V 是直接施加到 WL，还是经过调整？写电压/擦除电压（V2 规划用）各是多少？ | 低（V2 参考） |

---

### 参数回填状态表（会后持续维护）

> 用法：每次会后更新“状态/负责人/日期/版本号”，避免口径漂移。
> 说明：这里不再只写“待补充”，而是同时标明**当前数字侧临时口径/阻塞点**，便于 handoff 会议直接聚焦未闭环项。
| 条目 | 当前状态 | 负责人 | 目标日期 | 回填值/文档链接 | 备注 |
|---|---|---|---|---|---|
| A4（Vref/TIA） | 待模拟侧给出量化值；数字侧当前仅冻结逻辑阈值 `THRESHOLD_DEFAULT=2550`，尚未建立物理电流映射 | 模拟团队 | 首轮 handoff 会后回填 | 本文 A4；数字默认阈值见 `doc/02_reg_map.md` / `rtl/top/snn_soc_pkg.sv` | 未回填前不调整默认 `ratio_code` / `threshold` |
| A5（时序数字） | 待模拟侧给出实测 ns/cycles；数字侧当前临时值为 `DAC=5 / CIM=10 / MUX_SETTLE=2 / ADC_SAMPLE=3` cycles | 模拟团队 | 首轮 handoff 会后回填 | 本文 A5；当前占位值见 `rtl/top/snn_soc_pkg.sv` | 未回填前不冻结最终 STA/时序合同 |
| A6（噪声/动态范围） | **部分已知**（Vread=1.5 V / On-off=5000:1 / HRS≈1TΩ / LRS≈200MΩ 已从 I-V 实测拟合入；来自 `项目相关文件/器件对齐/`）；待模拟侧给出 A6-1..A6-8 的量化噪声 + 动态范围 | 模拟团队 | 首轮 handoff 会后回填 | 本文 A6；证据见 `项目相关文件/器件对齐/Python建模/summary.txt` + `memristor_plugin.py` | 未回填前不重标定 Python 噪声参数 |
| A7（时序合同） | 部分已冻结：`dac_ready` 已删除、外部协议统一到 `cim_start/cim_done/bl_sel/bl_data`；仍待确认脉宽与 guard time | 数字+模拟联合 | 首轮联合对齐会 | 本文 A7；协议主合同见 `doc/08_cim_analog_interface.md` / `doc/03_cim_if_protocol.md` | 这是 RTL 状态机和板级 bring-up 的关键收口项 |
| A8（外部编程合同） | **已冻结（方案 α'）**：新增 `prog_op[2:0] + prog_level[3:0]` 7 个 D→A pads；verify PASS/FAIL 由数字侧自己比对 | 数字+模拟联合 | 已完成 | 本文 A8；关联 `doc/08_cim_analog_interface.md` / `doc/15_asic_pad_map.md` / `doc/02_reg_map.md` | 当前剩余的是数字侧 shared-carrier routing follow-up，不是协议 blocker |
| P0（pin/pad/PCB布局） | 数字侧 pad 真源已冻结；待模拟芯片 pad 排列与 PCB 约束回填 | 模拟+PCB | pad 定稿前 | 数字侧真源：`doc/15_asic_pad_map.md`、`rtl/top/chip_top.sv` | 未回填前不提交最终 pad-ring/PCB 定稿 |
| P1（供电/偏置） | 待模拟侧确认外部偏置/参考是否需要独立引脚；数字侧当前未新增相关 pad | 模拟+PCB | 电源方案评审前 | 本文 P1；数字侧现状见 `doc/15_asic_pad_map.md` | 直接影响 PCB BOM 与电源隔离方案 |
| P2（RRAM 状态） | 待器件/模拟侧确认上电状态与写入方案；数字侧主目标已改为支持数字发起外部编程，但 bring-up 仍建议保留 fallback | 器件团队 | V1 bring-up 方案冻结前 | 本文 P2 | 未回填前不能只按“上电即推理”假设准备系统 |

### 收口准入条件

- `A7`：每个时序信号的主从、有效沿、脉宽（cycles）、是否允许 back-to-back。
- `A8`：外部编程协议本身已冻结；后续只需跟踪 shared-carrier routing 的数字 RTL 落地。
- `A5`：每阶段延迟（ns/cycles）+ 最坏 PVT 数值。
- `A4`：Vref 高低点、TIA 增益标称/容差、是否可调、温漂。
- `A6`：噪声（LSB RMS / pp）、最小可检电流、ENOB、温漂影响。
- `P0`：两颗芯片的最终 pin list（55 pad 全表，其中 52 个可用 pad + 3 个 ESD/保留 pad）、pad 排列、PCB 走线长度预估。
- `P1`：AVDD/DVDD 约束、偏置来源、PCB 电源方案、是否新增外部引脚。
- `P2`：RRAM 上电状态、retention/read-disturb、模拟芯片权重写入方案（主路径=数字发起编程；fallback=外部测试写入）。

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

1. 根据 ADC noise floor（单位 LSB）评估当前 THRESHOLD_DEFAULT=2550 是否足够健壮
2. 如果噪声比预期大，考虑调高阈值（改 THRESHOLD_RATIO_DEFAULT），或回服务器跑一次 Python 建模重新标定
3. 更新 Python 建模的 READ_NOISE_SIGMA 参数以反映真实噪声水平，重新验证精度

### 拿到 A4（TIA 增益/Vref）后：

1. 确认 ADC 满量程对应的物理电流（Full_scale_current = Vref_range / R_TIA）
2. 比对建模中 `ADC_FULL_SCALE_MODE = "fixed"` 的假设是否成立
3. 如有偏差，更新 snn_engine.py 中的 full_scale 参数

### 拿到 P0（模拟芯片 pad 信息 + IO 时序模型）后：

1. 数字芯片侧：根据模拟芯片 IO 时序模型更新 `chip_top.sv` 的 STA 约束（output_delay/input_delay 纳入 PCB 走线延迟）
2. 数字芯片侧：完成 `chip_top.sv` 的 pad cell 实例化与 pad ring 布局
3. PCB 设计：根据两颗芯片的 pad 排列规划走线方案，进行信号完整性分析
4. 数字芯片侧：启动 DC 综合 + PR 后端流程（独立于模拟芯片）
5. 模拟芯片侧：独立完成自身后端流程（数字芯片无需介入模拟芯片的 LEF/Liberty/GDS 交付）

---

## 五、等待期间数字侧任务清单

> 在等待模拟回复期间，数字侧按以下顺序并行推进。

### 第一阶段（已完成 ✅）

```
✅ 优先级 1：Smoke Test（Icarus + VCS/Verdi 仿真）
  已完成：
    - LIGHT_SMOKETEST_PASS（黑盒 CIM test mode）
    - WEIGHTED_SIM_PASS（真实权重 hex，OUT_FIFO_COUNT > 0）
    - SAMPLE_ALIGN_PASS（Step 3.4/3.5 Python↔RTL 数值对齐，100/100 样本完全一致）

✅ 优先级 2：学习代码（按 doc/06_learning_path.md Stage A→E 顺序）
  已完成全部 Stage A~E
```

### 第二阶段（已完成：Phase 4 外设集成，2026-03-21）

```
数字芯片外设集成顺序（全部完成）：
  1. ✅ AXI-Lite：interconnect → snn_soc_top 集成 → AXI bridge TB → 黑盒 smoke → 带权重仿真
  2. ✅ UART：uart_stub → uart_ctrl → UART TB → 黑盒 smoke → 带权重仿真
  3. ✅ SPI：spi_stub → spi_ctrl → SPI TB → 黑盒 smoke → 带权重仿真
  4. ✅ DMA 扩展：多目标路由（INPUT_FIFO / WEIGHT_SRAM / INSTR_SRAM）→ DMA TB → 黑盒 smoke → 带权重仿真
  5. ✅ E203 接入：ICB→simple bridge + 最小 wrap → bootloader/SPI 启动 → UART printf → 端到端推理
  6. ✅ JTAG 救援通路：自定义 TAP（IDCODE/MEMACC/CPUCTL/BYPASS）→ SRAM 直写 → CPU 局部复位

每步完成后均进行了多层回归验证，推理链路无回归。
详见 doc/16_iteration_log.md。
```

### 第三阶段（拿到模拟侧 A5 之后）

```
1. 更新仿真时序参数（snn_soc_pkg.sv）
2. 重跑 Smoke Test 验证新参数下 DMA+CIM+ADC 时序无违例
3. 如 CIM 计算时间 > 当前 10 cycles，检查 cim_array_ctrl 状态机是否需要扩容
```

### 第四阶段（拿到模拟侧 A6 之后）

```
1. 更新 Python 建模的 READ_NOISE_SIGMA
2. 重跑 python run_all.py --skip-train（约 2-3 小时）
3. 若精度下降 >2%，考虑重新标定阈值 ratio_code
4. 若需要调整 THRESHOLD_DEFAULT，同步更新 snn_soc_pkg.sv
```

### 第五阶段（拿到模拟芯片 IO 时序模型之后）

```
1. 更新数字芯片 chip_top.sv 的 STA 约束（纳入 PCB 走线延迟）
2. 完成数字芯片 pad cell 实例化
3. 启动数字芯片 DC 综合（合成）
4. 启动数字芯片 PR 后端（P&R）
5. PCB 设计启动（两颗芯片走线规划 + 信号完整性分析）
```

### 返工触发条件（避免反复改）

- 若 `A7` 未定：先不改时序 RTL。
- 若 `A5` 未给最坏值：先不冻结周期参数。
- 若 `A4/A6` 只有定性没有定量：先不改 Python 噪声/满量程。
- 若 `P0` 未给最终 pin list：先不做数字芯片 pad-level 定稿提交，先不启动 PCB 设计。
- Phase 4 外设集成与模拟侧回复**解耦**——外设集成不改变数模接口协议，可并行推进。

---

## 六、本文档附带的关键数字（供模拟芯片团队快速核对）

| 参数 | 值 | 来源 |
|---|---|---|
| WL 数（输入维度） | 64 | snn_soc_pkg::NUM_INPUTS |
| BL 通道数（Scheme B） | 20（10正+10负） | snn_soc_pkg::ADC_CHANNELS |
| ADC 精度 | 8-bit | snn_soc_pkg::ADC_BITS |
| 每次推理总 bit-plane 数 | 80（T=10 × PIXEL_BITS=8） | TIMESTEPS_DEFAULT × PIXEL_BITS |
| 数字侧 LIF 阈值（上电默认） | 2550 | THRESHOLD_DEFAULT = 1×255×10 |
| 差分结果位宽 | 9-bit 有符号（[-255, +255]） | NEURON_DATA_WIDTH = ADC_BITS+1 |
| 仿真时钟频率 | 50 MHz | 目标值，待工艺确认 |
| 单 bit-plane 仿真延迟（含20通道ADC） | ~125 cycles ≈ 2.5 μs | 待模拟侧确认真实值 |
| 总推理延迟（80 bit-plane） | 80 × 125 = 10000 cycles ≈ 200 μs | 估算（T=10 默认） |
| 集成架构 | 双芯片 PCB 互联 | 数字芯片 + 模拟 CIM 芯片，独立封装 |
| 数字侧验证状态 | Step 3.4/3.5 PASS（正式 100 样本口径） | Python↔RTL 100/100 样本对齐；`expected_classes.hex` 为 Python `predicted_class` |
| 数字侧当前阶段 | Phase 4 已完成，进入 tapeout 准备 | AXI-Lite / UART / SPI / DMA / E203 / JTAG 全部集成 |
## 2026-03-19 Status Sync

下面关于 `AXI-Lite -> UART -> SPI -> DMA -> E203` 的阶段描述保留了原始 handoff 计划口径。当前实际进度已经前推到：

- `UART / SPI / DMA / AXI-Lite bridge` 已完成主线集成
- `E203` 已完成最小面积接入
- `bootloader / SPI 启动 / UART printf` 已在专用 Icarus 链路验证通过

补充说明：

- 当前验证标准以 `doc/09_smoke_test_checklist.md` 为准
- 对于本轮最小 E203 + SPI 启动闭环，`Icarus` 已足够；`VCS/Verdi` 不是这一轮的必跑前置条件
