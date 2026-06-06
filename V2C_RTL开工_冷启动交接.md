# V2C RTL 开工 — 冷启动超级详细交接文档（2026-06-06）

> ⚠ **草稿 v0 — 待 Codex 最终检查（`V2C_Codex_最终检查.md`）+ 综合研判后定稿**。本会话末抢先起草；Codex 反馈逐条落地 + 老师两项澄清（1-bit sense 时间/读能耗）回来后，更新为定稿再用。
>
> **新对话第一步**：Read 本文件 → Read §1 核心文档 → 跑 §2 确认环境 → 按 §6 顺序开工写 RTL（严格守 §7 bit-exact 契约）。本文件是「RTL 开工」专用冷启动入口（比旧的 `V2C_接力文档_PhaseABC-RTL.md` 更新、更聚焦开工）。**自动记忆**（从 ~/Desktop/soc 启动会加载）覆盖协作风格/工作规则，本文件再内联一遍以防万一。

---

## 0. 一句话项目 + 协作风格 + 工作规则（必记）
- **项目**：数字二值 **0T1R RRAM-CIM + TTFS** 加速器（repo `~/dev/snn-soc`，branch `asic-v2b-noe203-base`），Q4 SCI 论文线。主网 **784→246→10**，W=4，数据集 MNIST/Fashion/KMNIST。
- **★ 最高指令**：一切朝**极致 PPA**（面积/功耗/延迟）；可发表 **novelty** 也要追。
- **协作风格**：用户用**中文、要大白话**（别堆术语、别只甩结论；关键处打比方 + 给"所以这意味着什么"）；用户技术很深（认真的硬件/RTL/ASIC 工程师），欢迎直说和有理有据 push back。
- **工作方式硬规则**（对 Claude 自己 + 写给 Codex 的 prompt 都适用）：① 每完成任务**全面自检**（全套测试 + RTL parity + 自洽性）；② **不拘泥旧决定**，发现更极致 PPA / 更大 novelty 就改（本会话已实证：数据推翻了"双单调推测"）；③ 给 Codex 的 prompt **必带 ①②④**；④ **写 Codex 审查 prompt 前，自己先完整最终检查一遍**（别把没自检过的丢给 Codex）。
- **数据原则**：任何结果都留 **best-case + honest/conservative（典型 mean + worst-case/p95）双版本**，明确标注。
- **待澄清/不阻塞信息**：只留**简短 flag**（事实+待确认问题+是否阻塞+一句潜在影响），**别基于未确认信息展开方案级改动**，等确认再微调。
- **git**：阶段成果就 commit（**只加相关文件、别 `git add -A`**；**别碰 `doc/arm-fpga-demo/uart_capture_*` = V2.B 外部改动**）；push 在 agent 环境跑不通 → **commit 本地即可，push 用户来**。
- **留痕**：实验数据/idea/novelty/决策原因进专门文档（§9 文档地图）。

## 1. 必读核心文档（按序）
1. **本文件**（开工入口 + 全局导航）。
2. `V2C_论文逻辑主线.md`（motivation ①–⑩ + 三桶评估 + "纯数字 CIM 非 mixed-signal"澄清）。
3. **`V2C_RTL开工spec.md`**（★ **§9 定稿为准**：模块划分/开工顺序 §9.2/counters §9.3/parity 路线 §9.4/风险 §9.5；**§9.7 bit-exact 契约**；§9.9 读时间待澄清 flag。§1-7 是推导过程）。
4. `V2C_极致PPA创新点.md`（§F 可行性否决 bit-serial、§G–§J 三轮调研+cross-check、§K/§K0b 真实权重实测、§L Codex 双方收敛、§M RTL 设计——**讲清为什么收敛到"输入跳零"**）。
5. `plan-v1.md`（架构规格权威：1024×1024 单宏常驻、128-bit 读宽、codebook、P&V FSM V/2 半选、50MHz、三桶评估）。
6. **`python_multilayer/v2c/encoding.py` + `robustness.py`**（★ RTL RRAM 模型必须 bit-exact 照它们，见 §7）。

## 2. 环境 + 确认现状
- venv：`~/dev/snn-soc/.venv-v2c`（py3.12 + numpy + torch；系统 pip 坏，只用这个 venv）。
- **全套测试（应 167 passed）**：`cd ~/dev/snn-soc && ./.venv-v2c/bin/python -m pytest -q -p no:cacheprovider python_multilayer/v2c/`
- **3 RTL parity（iverilog，应全 PASS）**：`bash sim/v2c/run_cim_mac.sh` / `run_ttfs_layer.sh` / `run_ramp_layer.sh`
- 现有 3 个 bit-exact 基线模块 `rtl/v2c/{v2c_cim_mac,v2c_ttfs_layer,v2c_ramp_layer}.sv`：**留作 golden ref，新建 PPA top 不改它们**。

## 3. 项目逻辑一句话（详见逻辑主线）
边缘 memory-wall → CIM+SNN → 0T1R RRAM（真器件，组里发过 IEDM/NC）→ **数字 CIM**（非模拟：cell 二值+popcount+无 ADC，换鲁棒/精确/可复现）→ 第一层必须 **dense 多比特输入**保精度（纯 TTFS 单脉冲输入会把图二值化、精度掉到 ~68%；多比特 → ~87%）+ 隐层/输出层 **TTFS 单脉冲稀疏** → **dense 第一层占 99.8% cycle = 瓶颈** → **输入跳零**（无损省 73-88%）。**novelty = 全数字无 ADC 0T1R + TTFS 上的输入跳零极简数据通路 + 鲁棒性 + 硅化（组合，非单一技巧）；打鲁棒/能效/延迟轴，不拼准确率。**

## 4. 当前状态
- Python golden 全绿（167 测试）、3 RTL 模块 bit-exact、鲁棒性曲线完成（数字优雅降级 vs 模拟崩，对照用文献）。
- 三轮 20+ subagent 调研 + Codex 8 路 + 真实权重实测，**双盲收敛：输入跳零是唯一真实 PPA 主力**。其余花招——列对齐打包（真实整列零率=0）/ 权重位平面 skip（bit-parallel 下整块零=0）/ BBS 双向（bit-serial PE 招）/ 保序早停（=被否的双单调换皮）/ 低秩/CSD（4-bit 收益小）/ LUT-GEMM（batch-1 净负）/ time-domain popcount（砸数字卖点）——**全被真实数据或架构约束否决**（留痕 §G–§L）。
- **RTL spec v1.0 两方汇总定稿**（`V2C_RTL开工spec.md` §8/§9 + 创新点 §M）。

## 5. ★ RTL 数据通路精要（详见 spec §9）
**A 喂（只送非零输入行）→ B 算（popcount-free 行流 MAC）→ C 决策（融进累积尾+门控）→ D 编排（单宏跨层 sequencer 全链 parity）。** 全数字、对现有 golden bit-exact（跳零无损=加 0）。
**模块（`v2c_top_core`）**：`input_event_builder`（{row,bitmask[3:0]} list + dense_bypass：8·N_evt+overhead≥25088 走 dense，对抗最坏不比 dense 慢）→ `read_scheduler`（128b 对齐，出 {aligned_col_base, lane_offset, valid_lanes}）→ `mac_array32`（32 lane int4 解码加：`w=b0+2b1+4b2−8b3`；输入层 `z1+=w<<k`、输出层 `mem+=w`）→ `hidden_timegen_bucket_writer`（z1→spike_time→bucket[t]，**无 hidden early-exit**）→ `output_bucket_engine`（桶累积+融合决策，**禁 row 内提前比**）→ `fault_injector`（ideal bypass）→ `pv_fsm/arbiter`（frame-level lock，P&V 与 compute 互斥）→ `counters/CSR`。
- cycle 模型：`C_z1 = 8 × N_evt`（N_evt=Σpopcount(vq)）；实测（§K0b 全测试集 best/mean/worst）Fashion 1208/6632/15784、KMNIST 712/4636/13416、MNIST 776/3320/8272（dense=25088；worst 仍省 37-67%）。

## 6. ★ 开工顺序（spec §9.2，每步对 golden bit-exact）
1. **`layer_map` + `mac_array32`**（地基）→ exhaustive parity vs `encoding.mac`（W=1/2/4/8 + 乱序行证交换律）。
2. `input_event_builder` + `ramp_z1_rowstream` → `event_count==Σpopcount(vq)`、`z1==convert._ramp_hidden_times`。
3. `hidden_timegen_bucket_writer` → spike_time vs `_ramp_hidden_times`。
4. `output_bucket_engine` → vs `forward.ttfs_layer_forward(early_exit=True)`（重点防 row 内提前比）。
5. `v2c_top_core` + counters → full top vs `convert.eval_ttfs_ramp`（pred/fallback/membrane/spike/counters）。**先用现有 3 模块串"最简 sequencer 骨架"跑通全链 parity（填 plan 剩余模块4），再换新模块、复跑同 parity 防回归。**
6. P&V + fault injection（ideal bypass 先通；故障模式 vs `robustness.py`）。
- counters（§9.3 必内建）：cycle_total/input_event_count(+by_bit[4])/input_cycles/hidden_timegen_cycles/output_cycles/macro_read_count/skipped_zero_events/hidden_fire_count/bucket_count[16]/max_bucket_depth/t_exit/fallback_used/fault_flip_count/ternary_illegal_count/pv_retry_count/pv_fail_kind + **read_count+读时间**。
- parity 框架复用 `sim/v2c/run_*.sh` + `tb/v2c/gen_*`。

## 7. ★ bit-exact 契约（spec §9.7，开工第一红线，用户强调）
RTL 的 RRAM cells 模型 + 权重解码 + 故障注入**必须 bit-exact 照 Python**（`encoding.py` 自述第 31-32 行即"the bit-exact golden the RTL CIM macro must match in ideal mode"）：
- **cells**：`[in_dim, out_dim*W]` uint8{0,1}，**col = out*W + bit**（单宏多层 layer_base 偏移由放置加）。
- **三套编码**（mac_array32 逐一对）：W=1 BNN（cell=1→+1/=0→−1；MAC=2·pc−N_active）；W=2 ternary（col0=pos/+1、col1=neg/−1；MAC=pc_pos−pc_neg；**(1,1)=illegal→0 且计 ternary_illegal_count**）；W≥4 two's-comp（`cells[:,k::W]=(wu>>k)&1`，`wu=w&((1<<W)-1)`；MAC=Σ2^k·pc_k，**MSB(k=W-1) 取负**）。`w=b0+2b1+4b2−8b3` 仅 W=4 特例。
- **故障**：`fault_injector` 照 `robustness.inject_cell_faults`（stuck0/1/invert/read_ber）；理想模式无故障 bypass=对 golden bit-exact。

## 8. ★ 命门/风险（会崩 parity 或被审稿人挑，开工必守）
- ① **output 禁 row 内提前比**（同 timestep signed 贡献可正可负，整 bucket/timestep 累完再比）；② **tie-break**=首脉冲那拍膜 max→min idx，**fallback**=argmax final 膜；③ 行序累积丢 spike-time → **fire-list 带 (row, t_fire)** 按 (t_fire, idx) 升序入队；④ **output lane-offset 22**（output 落 aligned block 7，hidden stripe7 用 lane0-21、output 用 lane22-31，禁从 phys col 984 未对齐读）；⑤ **末 stripe mask**（246%32=22 无效列清零）；⑥ 门控 **registered enable**（`freeze<=any_fired`，晚一拍防丢决策）；⑦ **严禁近似截断**（保序雷区，§I0 实测丢 1 LSB 翻 top-1 9%）。

## 9. 待澄清（不挡开工）+ Codex 检查（可选）+ 文档地图
- **待澄清（问老师，只影响 headline、不挡开工）**：① **1-bit 数字 sense（判 LRS/HRS）要多久**（老师给读出 1-10μs，待确认是否模拟 ADC 读；决定读是否瓶颈 → 若数字也慢则延迟 ms 级、headline 转能效/鲁棒，详见 spec §9.9）；② **读能耗** → 桶② 能效。器件参数从我们自己 0T1R（IEDM/NC）拿；数字 vs 模拟对照用**文献**（同学的模拟 CIM SOW/`memristor_plugin.py` 是另一款芯片/模拟模型，已排除，见 `V2C_器件与SOW参考.md`）。
- **Codex 最终检查 prompt 已备**：`V2C_Codex_最终检查.md`（多 subagent 独立查 bit-exact/自洽/PPA/novelty）。可选发；回来逐条独立判定后落地。
- **文档地图**：spec=`V2C_RTL开工spec.md`、逻辑=`V2C_论文逻辑主线.md`、PPA创新+调研=`V2C_极致PPA创新点.md`、架构=`plan-v1.md`、决策权衡=`V2C_设计决策与权衡记录.md`、RTL进展自审=`V2C_RTL进展.md`、器件=`V2C_器件与SOW参考.md`、旧接力=`V2C_接力文档_PhaseABC-RTL.md`、Codex prompt=`V2C_Codex_RTL设计.md`/`V2C_Codex_最终检查.md`、Python golden=`python_multilayer/v2c/{encoding,forward,convert,ttfs,robustness,cost}.py`。

## 10. 红线/gotcha（别踩）
- **不碰 V2.B**（`rtl/snn/`、`snn_soc_v2b_top`、uart_capture）；V2C 全 fork（`rtl/v2c/`）。
- **每模块对 Python golden bit-exact（理想模式）+ 严苛自审 + commit**（项目铁律；现有 ramp 层曾因误加 early-exit 翻车，已修——隐层 full-frame、只输出层早停）。
- 严禁近似截断（保序雷区）；accuracy 非胜负手（别为精度破 PPA）；latency=算法 timestep ≠ RTL cycle（分开报）。
- DC（SMIC55nm）/FPGA（ZCU102）用户在其服务器/硬件跑；Claude 出 RTL+parity+脚本。
- 给 Codex prompt 带工作规则 §0①②④；Codex 高质量但要独立判断（本会话驳回过其误报、也发现其没做独立调研）。

## 11. 开工第一步（具体）
写 `rtl/v2c/v2c_mac_lane.sv`（单输出 int4 解码+累加）+ `rtl/v2c/v2c_mac_array32.sv`（32 lane 例化 + stripe 收尾 carry-save 合成，MSB 取负），配 `tb/v2c/gen_mac_array32_vectors.py` + `tb/v2c/v2c_mac_array32_tb.sv` + `sim/v2c/run_mac_array32.sh`，对 `encoding.mac` bit-exact（W=1/2/4/8 + 全零/全一/乱序行/负权 MSB/边界）。**严格照 §7 契约**。绿了 commit，回填 §M + `V2C_RTL进展.md`。
