# 数字 0T1R RRAM-CIM + TTFS SoC 论文线计划

## Summary

- 新增独立 **paper/V2C 架构线**，保留现有 V2.B ARM-FPGA evidence，不直接改坏已验证路径。
- **Headline 定位**：**latency（硬件 cycle，RTL/FPGA 实测）为主测竞争指标**；**SOP/J 为 projected**（DC 数字功耗 + 器件/mixed-signal 能耗 estimate，明确标注、非实测）；二者皆自有、TTFS 主场。**density/area 作 motivation + 标 estimate 的支撑 Figure**（0T1R cell 0.64μm²@SMIC55nm 对 **SRAM-CIM cell ~2–3×**、非对纯 6T 存储；标 estimate/非流片），不作正面竞争主 claim。
- 架构定位：**1024×1024 物理二值 bit-cell 数字 RRAM-CIM**，权重精度参数化 `W` bit，逻辑容量 **1024 输入 × (1024/W) 输出**。主线 **signed 4-bit**（W=4 → 1024×256）；精度 sweep `W∈{1,2,4,8}`，W=8 作高精度锚点（双宏，分表）。
- 主实验：**单宏常驻 TTFS-MLP（宽而浅）** `784→246→10`（28×28 输入），W=4 下隐层 246 + 输出 10 = 占满 **256/256** 逻辑输出列，cell 利用率 ~74.5%；纯 FC、无 conv/pool/flatten。
- Ablation：3-FC `784→160→80→10`（Σ输出=250、利用率 ~53%），**验证是否**"FC 加深→利用率↓、accuracy≈不变、TTFS 级数+1 抬延迟/训练难度"（待 V2C 实测），佐证宽而浅取舍，非 headline。
- 数据集：**MNIST + Fashion-MNIST + KMNIST**（均 28×28/10 类，复用同一网络与映射；MNIST 作 sanity/对比锚点，非 headline accuracy）。
- TTFS 语义：每神经元每帧最多一次 spike；分类取最早输出 spike + **首 spike 早停**；无 spike/并列回退最终膜电位/SOP（并列取膜电位最高、再并列取最小类号），统计 fallback rate。**延迟双指标**：算法首发时间（fallback 样本=T）与**硬件 cycle latency**（按事件行串行的 time bins+active rows+stripes+层序实算），分开报。
- 不做外部异步 AER；只做片内同步 TTFS event stream。
- 所有架构选择优先压榨 PPA：低面积、低功耗、低延迟，不引入不必要并行度或按层重编程；但**护住 TTFS 延迟主场**。

## Key Changes

- **文档组织**
  - 新增 paper/V2C 入口文档，统一说明"数字 CIM、1024×1024 bit-cell、W-bit bit-slice、TTFS-MLP、P&V、PPA口径、headline 定位"。
  - 不删除 V2.B evidence；旧文档只加 scope banner，区分 V1/V2.B 模拟/ADC 叙事与 V2C 数字二值 CIM 叙事。
  - 新增 `V2C_设计决策与权衡记录.md`、`V2C_RTL_bug记录.md`，均置 repo 根，与现有 `已修复的bug原因及其解决办法.md` 区分。
- **Python 建模**
  - 从 `memristor_plugin.py` + `I-V.xlsx` 只导出器件标量（`g_min/g_max/R_on/R_off/on_off`、读判决裕量）做**标定**；其模拟 MVM/ADC/IR-drop/cubic 插值/漂移**不作为** V2C 非理想模型、不进 RTL。
  - **非理想参数蒸馏**：**读 BER 由 on/off + 读噪声 σ + 判决阈推导（给出公式）**；**stuck-at 率 / 写失败率 / 半选 disturb 在器件统计到位前作参数 sweep（标假设、不声称 derived）**。
  - 新增 TTFS-MLP 训练/推理路径：像素强度→首脉冲时间，零像素可不发放；扫 `T={16,32,64}`，主表取满足准确率与低 fallback 的最小 T。
  - 权重量化 W-bit signed，主线 W=4，sweep `{1,2,4,8}`：**W≥4 two's-complement、W=2 ternary `{-1,0,+1}` codebook、W=1 BNN `0→−1/1→+1`**（三套独立编码/解码）。
  - 加 MNIST + KMNIST loader；三数据集跑 sweep（执行序见 Test Plan 分阶段门禁）。
  - 导出 **W-bit 位平面权重（按上述三套编码）**、Python golden spike time/膜电位/fallback 标志，并出 accuracy/area/latency/能效 trade-off 曲线。
- **RTL / SoC**
  - 新增 `snn_soc_v2c_top` paper top，复用现有 simple bus/AXI 包装思路，不侵入 V2.B。
  - 数字 CIM 宏：物理 `1024×1024` bit-cell，列 `col=(layer_base+out_idx)*W+bit_idx`（单宏多层常驻、各层占不同列段，layer_base=前面各层输出累计），**按权重 codebook 解释**（W≥4 two's-complement→MSB bit-plane 取负；W=2 ternary；W=1 BNN）。**shift-add 用 bit-parallel**（顺 128-bit 读宽 + 列映射一次读出一个输出的 W 个 bit-plane，护延迟、面积微增）。**读出 = 每 BL 1-bit 电流 sense amp（判 LRS/HRS）**，无多比特 ADC、无 Scheme-B 差分；器件表征用的 TIA+多比特 ADC 不进 V2C 计算路径，cell 严格二值。
  - **累积微架构**：事件行串行下，每 timestep 对当前 active rows **逐 bit-plane popcount → shift-add（W 项，按 codebook）→ 膜电位更新 → 阈值/早停检测**；**SOP 口径 = 算法突触操作（每 input-spike × output 计 1）**，另报数字 bit-plane 操作数用于能耗。
  - **单宏常驻 MLP 权重**：各层放同一宏不同逻辑列段，推理期不按层重编程；P&V 只计装载成本、不计单张 inference latency。
  - 固定读宽 `P_READ_BITS=128`（主配置 W=4 → 32 输出/stripe）：hidden(246)=8 stripes、output(10)=1 stripe；其余 W 的 stripe 数见下「编码↔累积」表后的通用式。
  - **PPA 优化**：数字通路**单份时分复用跨层**——**复用时分遍历/ALU 思想、新建 V2C TTFS neuron bank**（不复用 `lif_neuron_alu` 本体：`P_MAX_NEURONS≥256`、膜电位位宽重推 ~16b、无 spike FIFO、单 spike/神经元用首发寄存器+fired 标志）；**首 spike 早停 + 时钟门控**。
  - W=8 同网络需双宏（256>128），仅作 high-accuracy upper-bound，**分表呈现，不与 W=4 同面积/能耗比**。
  - 双 RRAM 模型：**BRAM = 标称权重状态存储**；器件非理想由 BRAM 外**可综合注入逻辑**体现（LFSR 读 bit-flip vs per-cell 翻转概率阈值 + ROM/init stuck-at mask + P&V 写失败）→ **Verdi 与 FPGA 都反映 degradation**。仿真富模型可更富（高质 RNG/文件误差图/DPI/实数概率）；可综合模型用 LFSR/ROM/定点等价，理想模式与 Python golden bit-exact。
  - bit-cell P&V FSM（**V/2 半选通 + 双极性**，电压来自器件方；该 P&V 原为**模拟 CIM** 定，V2C 只取写/擦/半选/verify 偏置等**共性**部分，模拟读出 TIA+ADC 不属于 V2C）：**SET（置1/LRS）WL=3.3/BL=0；RESET（置0/HRS）WL=0/BL=3.3（反极性）；非目标半选偏置 1.5V**。**VERIFY** 用读条件（WL=1.5/BL=0、其余 BL=0.75 抑制）读回、1-bit 比对 desired_bit。**retry 上限耗尽 → `PV_STATUS` 先报 `program_fail`/`verify_fail`；只有经 SET/RESET 双向诊断 + 多次 readback 仍固定 0/1 才归类 `stuck-at-0/1`**；stuck-at 率由诊断统计反哺非理想模型。半选 disturb（反复 1.5V）作 write-error/stuck 来源（器件 disturb 数据 TBD）。
  - 拓扑系统扩展（`topologies.py`，**显式 fork V2C、不在 V2.B 模块上原地改**）：加 `role=v2c`、`dataset=kmnist`、`weight_encoding`、`weight_bits`(per sweep)；V2C 下 `physical_cols=out_dim*W`、放宽 `out_dim≤1024/W`、去 Scheme-B 2× 因子；位平面导出按三套编码。P&V FSM 与 TTFS neuron bank 同样新建 V2C 版，不在 `cim_program_ctrl.sv` 等 V2.B 模块原地改。

**「编码↔累积」表**（W=cells/weight；N_active=该输出累积的 active 行数；数据通路用 **mode 位**选两种累积）：

| W | 编码 | 有效值 | 列预算(1024/W) | accumulator（active rows 内）|
|---|---|---|---|---|
| 1 | BNN | {−1,+1} | 1024 | `2·popcount(cell=1) − N_active`（单位权 popcount-差）|
| 2 | ternary（pos/neg cell 对）| {−1,0,+1} | 512 | `popcount(pos) − popcount(neg)`（单位权 popcount-差）|
| 4 | two's-comp int4 | [−8,7] | 256 | `Σ_{k=0..3} 2^k·popcount(bp_k)`，k=3(MSB) 取负（带权 shift-add）|
| 8 | two's-comp int8 | [−128,127] | 128 | `Σ_{k=0..7} 2^k·popcount(bp_k)`，k=7(MSB) 取负（带权 shift-add）|

**ternary 码表**：`+1=(pos,neg)=(1,0)`、`−1=(0,1)`、`0=(0,0)`、**`(1,1)=illegal`**。理想 pack 永不产生 `(1,1)` + RTL assert；非理想路径 `(1,1)` 会被差分式静默解成 0 → **显式解码为 0 并计入 illegal/fault 率**（不静默吞）。
**stripe 通用式**：`outputs_per_stripe=128/W`、`stripes=⌈out_dim/(128/W)⌉`（W=1→128、W=2→64、W=4→32、W=8→16 输出/stripe）；**W=8 双宏并行**（两宏同时算、非串行）→ latency≈单宏当量、面积×2。

## Test Plan

- Python：TTFS 编码、**W-bit pack/unpack（two's-complement / ternary / BNN 三套解码各覆盖）**、MLP ideal/nonideal accuracy（三数据集）、fallback rate、双延迟（算法首发时间 + 硬件 cycle）分布。
- 精度 sweep（**分阶段门禁**）：① 先 `W=4 × T∈{16,32,64}` on 三数据集（定 T、过门）② 再 `W∈{1,2,4,8}` sweep ③ 数字非理想**只对主点 + 少量边界点**注入、不在全网格乘。输出 accuracy/fallback/双延迟/阵列占用/估算面积/能效曲线；标实测或待实测，不预设 4-bit 优于 8-bit。
- **主测指标 = 硬件 cycle latency**（RTL/FPGA cycle-accurate，含首 spike 早停）；**SOP/J = projected**（= 精确 SOP ÷ **E_total**；`E_total = P_digital×cycles/f_clk + E_array + E_periphery`，**P&V 装载能耗不入单张 inference**；标 projected，非实测）；算法首发时间另报（fallback 样本=T）。density 作 motivation Figure 标 estimate。
- 器件参数：on/off = **5000:1（器件方称实测，仓库暂无正式可引用文档 → `Device Cite pending`）**；单元面积 + set/reset/read 能耗引器件组正式数据。Python 模型复算值（~1680）不用于器件声称，仅作内部 golden。
- RTL：小尺寸 CIM parity、W=4 完整单宏 MLP parity、P&V program/verify/retry/诊断、TTFS layer parity、完整 TTFS-MLP 若干样本与 Python golden 对齐；理想模式 Python==RTL(sim)==RTL(synth) bit-exact。
- DC：脚本 50MHz/20ns，库由服务器后填；**只综合加速器数字逻辑、TB 驱动、不含 CPU**；输出 area/power/timing。芯片 PPA 分**三桶**：①数字逻辑（DC）②RRAM 阵列（器件估算）③**mixed-signal 外围**（sense amp / WL-BL 驱动 / 3.3·1.5·0.75V 生成，estimate）；分开报 + 相加 + breakdown。**后仿（门级）同样 TB 驱动、无 CPU。**
- FPGA：**仅此处接 ARM PS**（复用 V2.B 路径）；ZCU102 @ 50MHz OOC synth、资源/timing、固定 golden set smoke；先验 W=4 理想模式，再验数字非理想注入看 degradation。
- 论文表：①同单宏公平 sweep（W=1/2/4）一张表 ②W=8 双宏 upper-bound 分表。所有结果标 `Python Sim./RTL Sim./FPGA Prototype/DC Synth./RRAM Estimate/Device Cite`，不把仿真/估算当实测芯片。

## Assumptions

- DC 工艺库 = **SMIC 55nm**（标准单元）；工况/电压后续提供；当前固定脚本接口与 50MHz 基线。
- RRAM array 面积：cell **0.64μm² @0.8μm pitch，SMIC 55nm** → 1024×1024 ≈ **0.671 mm²**（cite-pending）。诚实密度：对 **SRAM-CIM cell(8T/9T ~1–2.2μm²) ≈ 2–3×**（**非 4F²/30–40×**、非对纯 6T 存储；详见决策记录 §6）。写/擦 10μs@3.3V、读@1.5V。**仍需**：写电流 I_write（写/擦能耗；读能耗可由 I_read×1.5V×t 估）、V2C 二值 on/off 正式出处、node-matched SRAM-CIM cell 面积。SOW 的 10nA–0.1μA 是模拟 4-bit 窗口、非二值 on/off。
- **器件数字非理想统计（stuck-at / write-fail / disturb / read-BER）是门禁**：到位前一律作参数 sweep（假设）、不声称 derived；read-BER 给出由 on/off + 噪声 + 阈值的推导公式。
- 旧 V2.B 作 baseline/ablation 保留，rate coding 可作 TTFS 对照，不作新主线。
- 精度风险主要来自 TTFS 时间分辨率 T、fallback rate、器件数字非理想；权重精度由 sweep 实测定标。
- "首次 TTFS on 0T1R" 仅作**待核查假设**，文献核对前不在 plan/摘要写成已确认 novelty。
- 待补输入：器件面积/能耗数值 + 可引用来源；半选 disturb 统计；fallback_rate 验收阈值（首轮训练后定标）。
