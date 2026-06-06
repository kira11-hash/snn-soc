# V2C RTL 开工 spec（草案 v0.1 — Claude 8-subagent 收敛；待与 Codex 8 路汇总定稿）

> 用户指令的 RTL 设计流程：Claude 多 subagent（4 方面×2 cross-check，**本草案=已完成**）‖ Codex 多 subagent（prompt `V2C_Codex_RTL设计.md`，用户喂、待回）→ 两方汇总 + 多方审核 + 参考 `plan-v1.md` → 本 spec 定稿 → 开工。创新点同步记 `V2C_极致PPA创新点.md §M`。**4 方面各 2 agent 高度收敛。**

## 0. 设计总纲（4 方面咬合成一条数据通路）
**A 喂（只送非零输入行）→ B 算（popcount-free 行流 MAC）→ C 决策（融进累积尾 + 门控）→ D 编排（单宏跨层 sequencer 全链 parity）。** 全程对现有 Python golden bit-exact（跳零无损=加 0）；全数字不伤抗 PVT；worst-case 必报（best+honest 双版本，见 §K0b）。

## 1. 方面 B（地基）：popcount-free 1-hot 行流 MAC
**两 agent 强收敛**：消除 per-output 784-bit popcount 树，改 **row-serial column-parallel**——每来 1 个非零输入行，读 128-bit（32 输出×4 bitplane），每输出做 **4-bit two's-comp 解码（MSB 取负 = 解码符号位，无独立减法器）→ 单累加器 +Δ**；shift-add 跨 4 bitplane + 跨 in_bits 相位用移位（wire）；**唯一算术树（carry-save 合成）摊到 stripe 边界**（每 784 行付一次 32×4 项，占比 ~4%）。
- 关键路径：784-树（~10 级）→ **~14-bit CPA**，fmax 与 IN_DIM 解耦（Colonnade 范式）；50MHz 极宽裕。
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

## 5. 落地优先级路线（8 agent "最该先做"收敛）
1. **D 最简 sequencer 骨架 → 模块4 全链 parity**（风险最低、解锁端到端 + DC/FPGA）。
2. **B popcount-free 行流 MAC 原语**（PPA 拐点：fmax + 面积）。
3. **A 非零行索引压缩器 + FIFO**（头号 PPA 杠杆，无损增量，复跑 parity）。
4. **C 决策融合单元**（输出层 novelty + tie-break 命门）。
5. 增量：A 列广播（若读端口支持）、D inter-layer streaming、全局门控。
- 每步对现有 golden bit-exact parity；每落地一项回填 §M + commit。

## 6. 共识风险 / 命门
- ★ **RRAM 行随机寻址 / 跨-stripe 宽读端口**（A 列广播依赖）：最大落地不确定性，**需器件方/读外围确认**；不支持则 A 退稳妥版（仍 73-88%）。
- ★ **spike-time 保序**（行序累积带 (row,t_fire)）+ tie-break/fallback：bit-exact 命门，parity 必须覆盖。
- 索引/控制开销 vs 跳零收益净账：预期净正（dense 99.8%），DC 量化确认。
- 末 stripe mask（246%32=22；10 输出）：无效列清零，parity 边界覆盖。
- **严禁近似截断**（保序雷区 §I0）。

## 7. 待汇总 / 待确认
- [ ] Codex 8 路（`V2C_Codex_RTL设计.md`）回 → 两方交叉（一致/分歧）→ 本 spec 定稿。
- [ ] 器件方确认 RRAM 读端口（顺序 128b/stripe vs 跨-stripe 单行宽读）→ 定 A 稳妥/激进。
- [ ] 多方审核后开工，按 §5 路线；每步 best+honest 数据 + bit-exact parity。
