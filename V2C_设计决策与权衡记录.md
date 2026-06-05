# V2C 设计决策与权衡记录

> 本文件外化 V2C 论文线（数字 0T1R RRAM-CIM + TTFS）的关键决策、权衡及其理由，供团队 / Codex / 未来会话查阅。配套计划见 `plan-v1.md`。
> 创建于 2026-06-04。每条决策带"决策 / 为什么 / 权衡了什么"。

## 1. 论文定位与目标
- **目标**：Q4 级 SCI（求稳"水"刊，但证据扎实、经得起追问）。
- **卖点组合**：数字 0T1R RRAM-CIM + TTFS 编码。新颖性在**组合**，非 TTFS 本身（已有 NYCU TTFS-SRAM / TFSRAM 等先例）→ 措辞收窄为"首次 TTFS on 0T1R 数字 CIM"，**需文献核对后定**。
- **Headline 定位**：正面竞争结果押 **latency**；SOP/J 作能效但仅 projected；density/area 作 **motivation + 标 estimate 的支撑 Figure**。
  - 为什么：**latency（硬件 cycle）可在 RTL/FPGA 实测**、是自有架构（TTFS + 首 spike 早停 + 数字单趟 CIM）主场；**SOP/J 仅 projected**（能量分母含器件/mixed-signal estimate，不称"可测"）；density 是**器件组的** cell 优势、**估算非实测**（无流片，审稿人会对估算打折）、**只赢存储**（数字逻辑与对手相当）。
  - 权衡：放弃"以面积为正面主 claim"（虽是更大的数字），换"可守、可测、可归属"的竞争结果。

## 2. 网络与数据集
- **CNN → 宽而浅 MLP `784→246→10`（W=4，单宏常驻，~74% 利用率）。**
  - 为什么：CNN 把 1024×1024 只填到 ~30%（conv 权重复用，永远填不满大阵列；conv 空间迭代抬 TTFS 延迟；深层 TTFS 难训），顶撞 density-first；MLP 宽而浅恰好把列预算 256 占满、阵列填到 ~74%、数据流简单、2 层 TTFS 易训。
  - 权衡：accuracy 比 CNN 低约 2–4pp（accuracy 已定为次要）。
- **宽而浅，不加深。**
  - 为什么：单宏常驻下"总输出列预算 = 1024/W"（W=4→256）固定；只有输入层吃 784 行、隐层输入 ≤246 行 → 加层 = 把预算切碎成"行稀疏"列段 → 利用率 74%→~53%；且每层 +1 抬 TTFS 延迟/训练难度；Fashion 类小任务 FC 加深基本不涨点。
- **3-FC `784→160→80→10` 作 ablation**（~53% 利用率）：正面**验证**"加深的 PPA 代价"（accuracy≈不变待实测），反向支撑宽而浅。
- **数据集 = MNIST + Fashion-MNIST + KMNIST**（同 28×28/10 类、同网络同映射，三数据集全 sweep）。
  - 为什么：KMNIST/MNIST 与 Fashion 同形状 → 零架构改动、跨数据集对比干净；MNIST 虽饱和，但大量前作报 MNIST，留作 sanity/对比锚点；多数据集增泛化分量（比加层划算）。

## 3. 量化（精度）
- **主线 4-bit + sweep {1,2,4,8}**，int8 作高精度锚点（非主线）。
  - 为什么："4-bit 暴跌"只发生于 PTQ / 大模型 / 激活量化；本项目 QAT + 小任务 + 仅权重量化 + 数字精确 MAC → 仓库实测 4-bit QAT 仅 ~1pp（`config_multilayer.py` 本就 4-bit）；4-bit 比 int8 省一半 cell、SNN 本就低精度域；同 1024 列下 4-bit 放 256 输出 vs int8 128，多神经元补回精度。
  - 权衡：单押 4-bit 有风险 → 做成 sweep 让数据定标，int8 锚点兜底。
- **三套编码**（W = cells/weight）：W=1 BNN `{−1,+1}`、W=2 ternary `{−1,0,+1}`（pos/neg cell 对）、W≥4 two's-complement。**列预算 = 1024/W**；accumulator **三套不同**（见 plan-v1.md「编码↔累积」表）：BNN=`2·popcount(1)−N_active`、ternary=`popcount(pos)−popcount(neg)`、two's-comp=带权 shift-add（MSB 取负）。数据通路用 **mode 位**选"带权 shift-add"或"单位权 popcount-差"两种累积。**ternary 码表**：`+1=(1,0)`、`−1=(0,1)`、`0=(0,0)`、**`(1,1)=illegal`**（理想 assert 永不产生；非理想 `(1,1)` 解码为 0 且计入 illegal/fault 率）。**stripe**：`outputs_per_stripe=128/W`、`stripes=⌈out_dim/(128/W)⌉`；W=8 双宏**并行**（非串行）→ latency≈单宏当量、面积×2。

## 4. 数据通路与 PPA 优化
- **shift-add = bit-parallel**（非 bit-serial）。为什么：顺 128-bit 读宽 + `col=(layer_base+out)*W+bit` 列映射（单宏多层常驻、各层占不同列段）一次读出一个输出的 W 个 bit-plane、护延迟主场；bit-serial 省的面积很小（大头是阵列 + popcount）却 ×W 拖延迟；50MHz 关键路径无压力。
- **阵列保 1024×1024**（非右尺寸 ~800）。为什么：cell 级密度 claim 与利用率无关；1024 是旗舰尺寸 + 低 W headroom；空 RRAM cell 零静态功耗、不伤能效；网络 footprint 单独报，无诚实问题。
- 单份数字通路（popcount+shift-add+LIF）**时分复用跨层**（省面积大头）：只复用 `lif_neuron_alu` 的时分遍历/ALU **思想**，**新建** V2C TTFS neuron bank（`P_MAX_NEURONS≥256`、无 FIFO、单 spike、膜电位重推 ~16b），**不复用本体**（本体 128 上限/32b/FIFO/多 spike，不兼容）。
- 膜电位位宽 32→~16 bit；删 V2.B 32 深 spike FIFO → 每输出神经元"首发寄存器 + fired 标志"（TTFS ≤1 spike/神经元）。
- **首 spike 早停 + 时钟门控**（省动态能耗 + 延迟；fallback 样本走满 T）。
- 去 Scheme-B 2× 列 + ADC（数字 two's-complement 不需要差分电流/ADC）。

## 5. RRAM 模型
- **BRAM = 标称权重状态存储 + 可综合注入逻辑（LFSR 读 bit-flip + ROM stuck-at mask + P&V 写失败）** → 器件特性在 **Verdi 与 FPGA 两边都在**（"用 BRAM 会不会丢器件特性"的疑虑已解：BRAM 只是存储底座）。
- 双模型：仿真富模型可更富（高质 RNG / 文件 per-cell 误差图 / DPI / 实数概率）；可综合模型用 LFSR/ROM/定点等价，理想模式与 Python golden bit-exact。
- `memristor_plugin.py` 的模拟物理（电导/IR-drop/cubic 插值/漂移）**只做标定、不进 RTL**：**read-BER 由 on/off + 读噪声 σ + 判决阈推导（给公式）**；**stuck-at 率 / 写失败率 / 半选 disturb 在器件统计到位前作参数 sweep（标假设、不声称 derived）**。

## 6. 器件参数
- **单元面积（SOW §2.2 版图几何，cite-pending）**：BL/WL pitch 0.8μm → cell **0.64 μm²**；**node = SMIC 55nm**。**V2C 1024×1024 core ≈ 0.671 mm²**。⚠ **不是 4F²@55nm**（0.64μm²≈210F²；"4F²" 用的是 RRAM 自己 0.4μm 半节距、≠55nm 的 F，不能对 6T 的 120F²——之前"30–40×"是混 F 的错，已废）。**诚实密度口径（绝对 μm² @55nm，联网调研后）**：对 **SRAM-CIM cell（8T/9T ~1–2.2μm²）≈ 2–3× 更小**（9T1C=2.22μm²@65nm 可引）；对**纯 6T 存储(~0.5μm²) 持平**。caveat：0.8μm 粗节距没吃 55nm 密度（F² 上偏大）；严格说 cell-vs-cell（我们算在外部数字逻辑里），macro 级要等 DC。
- **电压/脉宽（SOW，与 V2C 共性）**：写/擦 3.3V·**10μs pulse**；读 1.5V；半选 1.5V；抑制 0.75V。
- on/off = **5000:1（器件方称实测，仓库暂无可引用正式文档 → `Device Cite pending`）**；插件复算 `I-V.xlsx` ≈ 1680（仅内部 golden，不用于器件声称）。
- ⚠ SOW 的"单器件读流 10nA–0.1μA"是**模拟 4-bit 多级窗口、非 V2C 二值 on/off**；V2C 二值用 HRS/LRS 两极端、读裕量更大（1-bit sense 易判）。
- ⚠ 模拟设计 4-bit/cell（多级）每 bit 比 V2C 二值密 4×；V2C 二值**对纯 6T 存储不占便宜**，密度只立在**对 SRAM-CIM cell（~2–3×）**。V2C 真正价值 = 数字 CIM / 无 ADC / 大读裕量 / **非易失零待机**；**密度仅作辅助 motivation、非主 claim**（主 claim 是 latency/能效）。
- **能耗**：读能耗可由 `I_read×1.5V×t` 估；**写/擦能耗需写电流 I_write@3.3V**（SOW 未给）。read-BER 在拿到正式 on/off 前按 sweep 处理。

## 7. 报告口径与真实性红线
- 芯片 PPA = **三桶**：数字逻辑（DC，TB 驱动、**不含 CPU**）+ RRAM 阵列（器件估算）+ **mixed-signal 外围**（sense amp / WL-BL 驱动 / 3.3·1.5·0.75V 生成，estimate），分开报 + 相加 + breakdown 图。
- **SOP/J = SOP ÷ E_total**，`E_total = P_digital×cycles/f_clk + E_array + E_periphery`（**P&V 装载能耗不入单张 inference**）；latency 可测、SOP/J projected。
- DC / 后仿不含 CPU；**仅 FPGA 接 ARM PS**（端到端/批量，复用 V2.B 路径）。
- 所有结果标 `Sim./FPGA/DC/Estimate/Device-Cite`，不混仿真与实测；缺数据写 TBD 不硬编。
- **延迟双指标**：算法首发时间（fallback 样本=T）；硬件 cycle latency 另按 active rows/stripes/层序实算。并列取膜电位最高 → 再取最小类号。

## 8. 仍 open 的输入
- ✅ **0T1R 写/擦/验方式**：已提供（见 §9）；1-bit sense 读出已确认。
- 器件 **on/off 正式可引用出处**（5000:1 当前 `Device Cite pending`）。
- 器件**半选 disturb 数据** —— TBD（用于 write-error/stuck 模型）。
- 器件**单元面积** —— ✅ 由模拟 SOW 几何得 0.64μm²/cell(4F²) → V2C array ≈0.67mm²（cite-pending）。**仍需**：technology **node**（SRAM 对比 + DC 库）、**写电流 I_write@3.3V**（写/擦能耗）、V2C **二值 on/off** 正式出处。
- `fallback_rate` 验收阈值 —— 首轮训练后定标。
- "首次 TTFS on 0T1R" 措辞 —— 需文献核对后定。

## 9. 写/擦/验（P&V）方案 + 读出电路（器件方提供，2026-06-04）

> ⚠ 此方案原为**模拟 CIM** 制定、含模拟成分。V2C 只吸收与数字 CIM **共性**的部分：编程（写/擦/半选/verify 偏置）共性、原样用；**模拟读出（TIA + 多比特 ADC / 电流求和 MAC）非 V2C**，已用 1-bit sense + 数字 popcount 取代。

- **V/2 半选通 + 双极性**：SET（置 1/LRS）目标 WL=3.3V、BL=0V；RESET（置 0/HRS）目标 WL=0V、BL=3.3V（反极性）；非目标半选偏置 1.5V（同列半选 1.5V、同行半选 ≤1.8V，远低于 3.3V 翻转阈）。
- **读**：WL=1.5V、BL=0V（cell 1.5V）；**抑制读** BL=0.75V（cell 0.75V，读不出）。
- **读出电路（已确认）**：V2C 用**每 BL 1-bit 电流 sense amp** 判 LRS/HRS，MAC 走数字 popcount/shift-add，**无多比特 ADC**；器件表征用的 TIA+ADC 仅测电导、不进 V2C 计算路径，cell 严格二值。
- **VERIFY**：写后用读条件读回、1-bit 比对 desired_bit；错则重试，retry 上限耗尽 → `PV_STATUS` 先报 `program_fail`/`verify_fail`；经 SET/RESET 双向诊断 + 多次 readback 仍固定 0/1 才判 `stuck-at-0/1`；stuck-at 率由诊断统计反哺非理想模型。
- **半选 disturb**：反复 1.5V 半选可能累积扰动 → write-error/stuck 来源；器件 disturb 数据 **TBD**。
- **PPA 第三桶**：读写外围（sense amp / WL-BL 驱动 / 3.3·1.5·0.75V 多电压生成）= mixed-signal，单列 estimate，与数字逻辑(DC)、阵列(器件估算)分开报。

## 10. Codex 复审采纳的修订（2026-06-04，两轮）

第 1 轮（无 P0）采纳：SOP/J 降级 projected；延迟双指标；P&V 失败分类（program/verify_fail → 诊断 → stuck-at）；权重三套编码（移除统一 two's-complement）；TTFS neuron bank 新建（不复用 `lif_neuron_alu` 本体）；非理想蒸馏门禁；sweep 分阶段；微架构+SOP 口径；W=8 双宏分表；ablation 标待实测；novelty 不预声称。

第 2 轮（无 P0）采纳：① 补三套编码的「编码↔累积」表（ternary=popcount 差、BNN=2·popcount−N_active、two's-comp=带权 shift-add）；② SOP/J 量纲修正（`SOP÷E_total`，能量非功率）；③ `col` 加 layer_base（单宏多层常驻）；④ 同步本记录 §1/§4/§5/§6/§7/§9 到 plan（消除与 §10 的内部矛盾）；⑤ on/off 5000:1 标 `Device Cite pending`；⑥ RTL bug 提示"MSB 取负"限定为 two's-complement；⑦ 实现清单显式 fork V2C、不原地改 V2.B 的 `topologies.py`/`cim_program_ctrl.sv`。

第 3 轮（无 P0，窄窗口验证 PASS 为主）采纳：① **ternary `(1,1)` 非法态**显式定义码表 + 理想 assert / 非理想计 illegal-fault（避免差分式静默吞成 0）；② 补 **stripe 通用式** `outputs_per_stripe=128/W` 及 **W=8 双宏并行**口径；③ plan 的 on/off 措辞收窄为 `Device Cite pending`（与本记录一致）。
