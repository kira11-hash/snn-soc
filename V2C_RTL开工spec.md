# V2C RTL 开工 spec（v1.0 两方汇总定稿 — Claude 8 + Codex 8 收敛）

> RTL 设计流程：Claude 8 subagent（§1-4）‖ Codex 8 subagent → **两方汇总定稿（§8/§9）** + 参考 `plan-v1.md`；创新点记 `V2C_极致PPA创新点.md §M`。**最终开工以 §9 为准；§1-7 是推导/分析过程。** ★ 读出 1-10μs 的重大影响见 §9.9（待澄清"1-bit sense 是否也慢"，不挡开工）。

## 0. 设计总纲（4 方面咬合成一条数据通路）
**A 喂（只送非零输入行）→ B 算（popcount-free 行流 MAC）→ C 决策（融进累积尾 + 门控）→ D 编排（单宏跨层 sequencer 全链 parity）。** 全程对现有 Python golden bit-exact（跳零无损=加 0）；全数字不伤抗 PVT；worst-case 必报（best+honest 双版本，见 §K0b）。

## 1. 方面 B（地基）：popcount-free 1-hot 行流 MAC
**两 agent 强收敛**：消除 per-output 784-bit popcount 树，改 **row-serial column-parallel**——每来 1 个非零输入行，读 128-bit（32 输出×4 bitplane），每输出做 **4-bit two's-comp 解码（MSB 取负 = 解码符号位，无独立减法器）→ 单累加器 +Δ**；shift-add 跨 4 bitplane + 跨 in_bits 相位用移位（wire）；**唯一算术树（carry-save 合成）摊到 stripe 边界**（每 784 行付一次 32×4 项，占比 ~4%）。
- 关键路径：784-树（~10 级）→ **~14-bit CPA**，fmax 与 IN_DIM 解耦（Colonnade 范式）；50MHz 极宽裕。（fmax 的实际价值视读出延迟而定，见 §9.9 待澄清；不挡本模块按 §9 开工。）
- **严禁近似截断**（§I0 实测丢 1 LSB 翻 9%，保序雷区）；行流下精确反而更小。
- **novelty B-N1**：数字二值 0T1R + TTFS bit-parallel-weight 上的 popcount-free 行流 MAC（消树，非优化树）；**B-N2**：shift-add 与膜累积同址融合（不落地 z1 再搬运）。
- **先做**：`v2c_mac_lane`（单输出解码+累加）×32 = `v2c_mac_array32`，替 `v2c_cim_mac` 接口，对 `encoding.mac` bit-exact（含乱序行 parity 证交换律）。

## 2. 方面 A（头号 PPA）：输入 bit-event 行串行跳零
**两 agent 收敛**：**喂图时建** nonzero-row index FIFO + per-bitplane 计数（藏进 I/O；索引跨 8 stripe 复用）→ 只把非零行喂 B。bit-exact = 集合恒等（零行加 0）。
- worst-case 硬上界 = dense（全非零=退化回 25088，**永不变慢**）；best/mean/worst 见 §K0b。
- **A 稳妥版**（兼容 plan 128b/stripe 读）：per-bitplane 跳零行。**A 激进增量**（agent2）：① **位平面并集事件**（per-pixel v≠0 串一次、4-bit 折进位权，服务 4 bitplane）② **列广播**（一行跨 8 stripe 同拍读 984 cell，消 stripe 维 8×，worst→784）——⚠ 依赖"跨 stripe 单行宽读"端口，**需器件方/读外围确认**；不支持则退稳妥版（仍 73-88%）。
- **novelty A-N1**：read-width-aligned 输入 bit-event 跳零 + 喂图建索引 + ramp 累积融合；**A-N2**：位平面并集事件压缩。
- **先做**：位图→非零行索引压缩器 + FIFO（独立于读端口假设，先兑现 73-88% 主力）。

## 3. 方面 C：TTFS 决策融合 + 门控（输出层 = 能耗/语义，非 latency）
**两 agent 收敛**：决策融进累积尾（ITA 式：阈值比较 + 首脉冲锁存 + 10 路 WTA 优先编码，挂 shift-add 尾巴同拍，**0 额外决策周期**）；首脉冲→全局时钟门控（关 dense 输入阵列剩余翻转，能耗大头）。输出层 event-driven 只串 ~54 active hidden rows（fire-once 单调压缩）。
- **bit-exact 命门（两 agent 都标）**：① tie-break = 首脉冲那拍扫完全部输出 → 该 timestep 膜 max → min index；② fallback = argmax final 膜；③ **行序累积丢 spike-time → fire-list 必须带 (row, t_fire) 按 (t_fire, idx) 升序入队**（C2 关键洞察）；④ 门控晚一拍（`freeze<=any_fired`）防丢决策。
- worst-case：active rows worst=246（全发火），mean ~54，占总 <2%。
- **novelty C-N1**：决策融进累积尾零周期 argmin；**C-N2**：fire-once 行序累积单调压缩 + (row,t_fire) 保序。
- **先做**：`v2c_ttfs_decode`（10 路 tie-break/fallback 优先编码 + first-spike 膜锁存），对 `forward.ttfs_classify` / `convert.strict_decode_from_traj` bit-exact（含 tie/fallback/同步 tie）。

## 4. 方面 D：单宏跨层 sequencer + 0T1R 读写
**两 agent 收敛**：单一主 FSM（PV_LOAD→IDLE→层循环 RAMP/TTFS→CLASSIFY→DONE），**单宏 1024×1024 列段常驻、`layer_base` 切列段、不按层重编程**（省面积/能耗）；层间桥复用 `ttfs_times_to_stream` 流式（spike_time→行选通即时驱动，**不物化 [T,in]**）；ping-pong hidden-spike-time bank（inter-layer/帧间流水重叠）；P&V 写擦验证 FSM（V/2 半选+双极性+verify+stuck-at，fork V2.B `cim_program_ctrl`）与推理 **write-once 时分互斥**（装载一次、推理纯读、装载能耗不入 inference latency）。
- **novelty D-N1**：单宏跨层列段常驻零重编程 + TTFS inter-layer spike streaming on 0T1R（对标 OpenSpike/SpiDR/FlexSpIM/E-ReCON 差异化）；**D-N2**：层间桥不物化 [T,in]。
- **先做**（两 agent 一致）：**最简 sequencer 骨架**——用现有 3 个 bit-exact 模块串成 784→246→10，先**不带跳零/streaming**，对 `eval_ttfs_ramp` 全链 parity（填 plan 剩余模块4）；再增量叠 A 跳零 + D streaming（功能无损、复跑同 parity）。

## 5. 落地优先级路线（草案；**定稿顺序以 §9.2 为准**）
⚠ 本节是 Claude 8 路初始顺序（D 骨架先）；两方汇总后**统一为 §9.2**（B 地基 mac_array32 → A → hidden → C → top/D → P&V）。其中 D 的"最简 sequencer 骨架（旧模块串全链 parity、填模块4）"作为 **top 步骤的第一子步**先跑通端到端基线，再确认新模块替换不回归。每步对 golden bit-exact + 回填 §M + commit。

## 6. 共识风险 / 命门
- ★ **RRAM 行随机寻址 / 跨-stripe 宽读端口**（A 列广播依赖）：最大落地不确定性，**需器件方/读外围确认**；不支持则 A 退稳妥版（仍 73-88%）。
- ★ **spike-time 保序**（行序累积带 (row,t_fire)）+ tie-break/fallback：bit-exact 命门，parity 必须覆盖。
- 索引/控制开销 vs 跳零收益净账：预期净正（dense 99.8%），DC 量化确认。
- 末 stripe mask（246%32=22；10 输出）：无效列清零，parity 边界覆盖。
- **严禁近似截断**（保序雷区 §I0）。

## 7. 待汇总 / 待确认（已更新）
- [x] Codex 8 路回 → 两方交叉 → 定稿（见 §8/§9）。**高度收敛**，cycle 模型一致（C_z1=8×N_evt=§K0b）。
- [x] 读端口：用户定"**正常做我们自己的阵列**"，不追跨-stripe 宽读 → 首版逐 stripe row-event（列广播作 future）。
- [ ] **问老师（两项，不挡开工）**：① ★ **1-bit 数字 sense（判 LRS/HRS）要多久**（老师给的 1-10μs 是否为模拟 ADC 读？决定读是否瓶颈，见 §9.9）② 读能耗 → 桶② 能效。
- 阵列/对照已定：阵列用 plan 自己的（同学 SOW 是另一款芯片，排除，见 `V2C_器件与SOW参考.md`）；数字 vs 模拟对照用**文献现成数**。

## 8. ★★ 两方汇总（Claude 8 路 §1-4 + Codex 8 路，2026-06-06）— 高度收敛
**两方一致**：不改 1-output/cycle 基线（留 golden ref）→ **新建 PPA top `v2c_top_core`**；A=row-event 行串行跳零（Codex 选 `{row, bitmask[3:0]}` list，省 row index）；B=**signed row-event add**（int4 解码加，popcount-free），counter 版留 DC 对照；C=output **bucket engine**（bucket[t]=spike_time==t 的 hidden rows），**禁 row 内提前比较**（同 timestep signed 贡献可正可负、整拍累完再比），门控 registered enable；D=单宏不追宏级 ping-pong，P&V 与 compute frame-level 互斥。
**Codex 补的关键细节（采纳）**：
1. **dense_bypass guardrail**：`8·N_evt + overhead ≥ 25088` → 走 dense schedule，adversarial（全 15）不比 dense 慢（worst-case 兜底）。
2. **★ output lane-offset mapping 坑**：`phys_col=(layer_base+out)·W+bit`；output layer_base=246 → phys col 984-1023 落 aligned block 7（896-1023）：**hidden stripe 7 用 lane 0-21、output 用 lane 22-31**。read scheduler 须输出 `{aligned_col_base, lane_offset, valid_lanes}`，**禁未对齐读**。
3. 完整 **counters** 清单（§9.3）。4. 详细 **parity 路线 + directed cases**（§9.4）。
**差异**：列广播（Claude A2 激进）Codex 未取 → 首版逐 stripe row-event（每 event 读 8 stripe）；列广播作 future（用户已定不追宽读）。

## 9. ★ 最终开工 spec（两方汇总定稿 v1.0）
### 9.1 模块（`v2c_top_core`）
`input_event_builder`（{row,bitmask} list + dense_bypass）→ `read_scheduler`（128b 对齐，出 {aligned_col_base,lane_offset,valid_lanes}）→【**`fault_injector` 在此**：作用于 cells/read path、**取数前**注入；理想模式 bypass】→ `mac_array32`（32 lane：int4 解码 `w=b0+2b1+4b2−8b3` + W1/W2 码本 + **ternary (1,1)→0 且出 `ternary_illegal_count`**；输入层 `z1+=w<<k`[bit-event 首版] / 一行融合 `Σ_k bit_k?(w<<k)`[value-event 候选]、输出层 `mem+=w`；**W8 单宏 top 显式 reject → 双宏分流**）→ `hidden_timegen_bucket_writer`（z1→spike_time→bucket[t]，无 hidden early-exit）→ `output_bucket_engine`（桶累积+融合决策，禁 row 内提前比，**出 `pred/fallback/t_exit`**）→ `pv_fsm/arbiter`（**sideband**，frame-level lock）→ `counters/CSR`（**sideband**）。
- ★ **event 口径（Codex P0，钉死；`cost.input_skip_cycles` 已统一+测试）**：`row_event`=非零像素数 / `bit_event`=Σpopcount(vq)（首版=§K0b）/ `value_event`=row_event（一行融合 in_bits、~½ bit_event、DC A/B 候选）。**spec / RTL counter / cost.py / 论文必须同口径**（否则各自"看着对、最后对不上"）。
- `fault_injector` + `pv_fsm` + `counters` 都是 **sideband**，不在线性数据通路末尾。
### 9.2 开工优先级（两方一致）
1. `layer_map + mac_array32`（地基）→ exhaustive parity vs `encoding.mac`（W=1/2/4/8）。
2. `input_event_builder + ramp_z1_rowstream` → `event_count` 对三口径（`cost.input_skip_cycles`）、**`z1 == Σ_k 2^k·encoding.mac(bitplane_k)`**（z1 的定义；⚠ Codex P1：`_ramp_hidden_times` 返回 **spike time、不返回 z1**，别对错对象）。
3. `hidden_timegen_bucket_writer` → **spike_time == `convert._ramp_hidden_times`**。
4. `output_bucket_engine` → vs `ttfs_layer_forward(early_exit=True)`（重点防 row 内提前比）。
5. `v2c_top_core + counters` → full top vs `eval_ttfs_ramp`（pred/fallback/membrane/spike/counters）。
6. P&V + fault injection（ideal bypass 先通；故障模式 vs `robustness.py`）。
### 9.3 Counters（必内建，PPA 可信度核心）
cycle_total / **各 stage cycle**(input/hidden_timegen/output) / **row_event_count + bit_event_count(+by_bit[4])** / **macro_read_count(input/output/by_bit/by_stripe)** / skipped_zero_events / hidden_fire_count / bucket_count[16] / max_bucket_depth / output_rows_consumed / t_exit / fallback_used / **dense_bypass_used + reason** / **index_fifo_max_depth + overflow** / **read_latency_cycles_cfg** / fault_flip_count / ternary_illegal_count / pv_retry_count / pv_fail_kind。（Codex P1：read_count + event 双口径 + fifo + 读延迟配置必须有，否则 DC cycle / RRAM 读延迟 / 能耗账会混。）
### 9.4 Parity（每步 bit-exact + best/honest counters）
layer_map → mac_array32(W1/2/4/8 exhaustive) → input_event_builder → z1 → hidden spike_time → output bucket → full top vs `eval_ttfs_ramp`。directed：全零/全15/单row单bit/负权MSB/末stripe mask/**output lane offset 22**/同timestep tie/fallback/no-spike/early-exit后future bucket squashed。
### 9.5 关键风险（两方共识）
★ 功能：**output 层 mid-bucket 提前比较**（必整拍累完再比）+ **output lane-offset 22 未对齐 mapping**。★ worst-case：dense_bypass 兜底。严禁近似截断（保序雷区 §I0）。
### 9.6 评估 & 对照
三桶：① 数字逻辑 DC 实测 + FPGA；② RRAM 阵列用**我们自己 0T1R 器件数据（IEDM/NC）**估算；③ 模拟外围 estimate。数字 vs 模拟 CIM 对照**用文献**。阵列用 plan 自己的。

### 9.7 ★ RTL RRAM 行为模型 ↔ Python golden 契约（开工第一红线，用户强调）
RTL 的 RRAM cells 行为模型 + 权重解码 + 故障注入**必须 bit-exact 复现 Python**（`encoding.py` 自述即第 31-32 行"the bit-exact golden the RTL CIM macro must match in ideal mode"）：
- **cells 布局**：`cells[in_dim, out_dim*W]` uint8{0,1}，**col = out*W + bit**（单宏多层 layer_base 偏移由放置层加）。
- **三套编码解码（`mac_array32` 必须逐一对）**：W=1 BNN（cell=1→+1、=0→−1；MAC=2·pc−N_active）；W=2 ternary（col0=pos/w=+1、col1=neg/w=−1；MAC=pc_pos−pc_neg；**(1,1)=illegal→解 0 且计 `ternary_illegal_count`**）；W≥4 two's-comp（`cells[:,k::W]=(wu>>k)&1`，`wu=w&((1<<W)-1)`；MAC=Σ2^k·pc_k，**MSB(k=W-1) 取负**）。§9.1 的 `w=b0+2b1+4b2−8b3` 仅 W=4 特例，W=1/2 走各自码本。
- **故障注入**：`fault_injector` 复现 `robustness.py` 的 `inject_cell_faults`（stuck0/1/invert 静态 + read_ber 非对称 P10/P01）+ `read_ber_from_device` 映射，作用在 packed cells（**read 端、取数前，§9.1**）；**理想模式=无故障 bypass=对 golden bit-exact**。★ **fault 合约（Codex P1）：parity 用静态可加载 fault mask**（和 Python 每 trial 一份固定 faulted cells 一致）；**禁动态 per-read LFSR 翻转**（会和当前 golden 不 bit-exact）；若要 per-read BER 须另建 Python golden。W2 illegal (1,1) 故障向量手工注入。
- **范围/边界**：`value_range`（W1/2 [-1,1]、W4 [-8,7]）、BNN 不可表 0。
- **验证**：每模块对 `encoding.pack/unpack/mac` + `robustness.inject_cell_faults` 逐向量 bit-exact（复用现有 `v2c_cim_mac` parity 框架）。

### 9.8 PPA 增量候选（首版不做，待数据/确认后评估）
- **★ value-event 融合（最值得，Codex 荐；不需宽读口、bit-exact）**：同一非零像素只读一次权重行、lane 内 `z+=Σ_k bit_k?(w<<k)`（4 个 gated shift-add）→ cycle 从 bit_event(8×Σpopcount ~6632) 降到 value_event(8×nnz ~2960)、**再 ½**；全 15 对抗最坏 25088→6272。代价 lane 内 4 gated shift-add（面积/时序 **DC A/B** vs bit-event 版）。**首版 bit-event 最稳，value-event 并行做 DC 对比**（比"列广播"更实在——不依赖跨-stripe 宽读口）。
- **读-算流水（read-compute pipeline）**：边读下一行边算这一行，藏 RRAM 读延迟。**待老师"读延迟"数据**：读延迟 > 1 时钟周期才做（实在 PPA），否则不需要；无损（不改结果）。
- **列广播**（一次读整行跨 8 stripe，再省 ~8×）：待器件/读出电路确认"跨-stripe 宽读口"。用户已定首版正常做、不追，作 future。
- **帧间流水**：单宏单 ALU 下层间不能真重叠；连续多帧场景可帧间流水。待应用场景定。
- 定性：延迟隐藏藏的是"读/判决/层间"附加开销，**非核心计算量**（核心靠跳零）；锦上添花。

### 9.9 读出延迟 1-10μs（老师 2026-06-06）— ★ 待澄清 flag，不挡开工
老师给读出 1-10μs/次。**★ 待澄清（需老师认真回复）：这是模拟 ADC 读的时间，还是我们 1-bit 数字 sense（判 LRS/HRS）也这么久？**（1-bit sense 通常远快于多比特 ADC。）
- **不挡 RTL 开工**——功能 bit-exact 不依赖读时间/能耗，按 §9 照常写。
- **只影响 headline 定性，待确认后再据情况微调（现不展开方案，避免基于未确认信息过度改动）**：粗略——数字 sense 也慢→延迟 ms 级、headline 转能效/鲁棒、减读次数/一次多读/读-算流水更重要；数字 sense 快→原 cycle/延迟卖点成立 +「数字读快 vs 模拟慢」额外优势。
- counter 内建 `read_count` + 读时间（无论哪种都要，论文 PPA 用）。
