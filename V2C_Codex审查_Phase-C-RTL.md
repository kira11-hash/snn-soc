# V2C Phase C（RTL 起步）+ 全天进展 审查/调研请求（喂给 Codex；只读仓库、勿改代码）

> 复制全文给 Codex。它读 `~/dev/snn-soc/`：进度在 `python_multilayer/v2c/PROGRESS.md`（Python）+ `V2C_RTL进展.md`（RTL+自审），RTL 在 `rtl/v2c/`、parity 在 `tb/v2c/`+`sim/v2c/`。前三轮审查见 `V2C_Codex审查_{Phase2,Phase-AB}.md`（已全采纳）。

---

## 0. 角色与约束
资深 RTL/数字 IC（CIM 数据通路、低功耗、TTFS）+ SNN/器件 审稿人。任务：**(A) 检查 RTL 与 deployed-robustness 有无问题；(B) 重点给 PPA-最优微架构的设计意见；(C) 调研/思考，给"下一步该干什么/怎么优化"**。这是进 DC 前的把关。
约束：**只读不改**（给 diff 建议）；**独立判断、可 push back**（多次驳回过你的误报）；分 P0/P1/P2，引 `文件:行号`，缺数据写 TBD。

## 1. 背景（一句话）
V2C = 数字二值 0T1R RRAM-CIM + TTFS 加速器（cell 二值、W=4 跨 cell、popcount/shift-add、TTFS-IF 早停、per-output 整数阈值、**无 ADC/无推理乘法**、1-bit 数字 sense）。主网 784→246→10。战略：**accuracy 非胜负手，鲁棒性是今天唯一可信 SOTA 轴；latency/power 需 RTL+能耗才能喊 headline**。**全 fork，不碰 V2.B**。架构规格在 `plan-v1.md`。

## 2. 自上轮（Codex#3）以来的进展
**(a) 鲁棒性返工（Codex#3 全采纳，`robustness.py`/`experiments.py E11`，数见 PROGRESS Phase B/A/B）**：
- **deployed 早停鲁棒性**（关键新视图）：冻结 clean 标定的 per-class θ_out（λ=0.5），故障下 strict 解码 → acc+latency 同时退化。Fashion 多 seed @2% 故障：deployed ~82%@t7-8（现实区优雅降级、延迟保持低）。
- 故障物理拆分：stuck0/1/invert（静态）+ read_ber（非对称 P(1→0)/P(0→1)，`read_ber_from_device` 从 HRS/LRS 电流+sense 阈值映射）。多 seed（ANN seed × fault trials）。
- analog 基线修了 ADC oracle full-scale 假象（改 per-output 固定标定 + column gain/offset/read-noise）；但 per-weight σ 被 fan-in 平均 → 仅作 **illustrative/optimistic**，"模拟崩"锚定文献。

**(b) ★ Phase C RTL 起步——3 个核心 compute 模块 bit-exact 对齐 Python golden（iverilog parity，理想模式）**：
- `rtl/v2c/v2c_cim_mac.sv` ↔ `encoding.mac`：per-output popcount→shift-add codebook（W=1 BNN/W=2 ternary/W≥4 two's-comp MSB 取负）。纯组合。parity `sim/v2c/run_cim_mac.sh`（W∈{1,2,4,8} + 784/W4 + 边界，全 bit-exact）。
- `rtl/v2c/v2c_ttfs_layer.sv` ↔ `forward.ttfs_layer_forward`：FSM 逐 timestep 积分（时分复用单 MAC）+ per-output 整数阈值 + 首 spike 锁存 + early-exit。parity 18 帧 bit-exact（spike_times+membrane+n_steps）。
- `rtl/v2c/v2c_ramp_layer.sv` ↔ `convert._ramp_hidden_times`：Phase A bit-serial `z1=Σ2^k·mac(bitplane_k)` + Phase B ramp TTFS（**full-frame**，输入/隐层无早停——自审抓到并修了误加 early-exit 的 bug）。parity 14 帧 bit-exact（z1+spike_times）。
- 方法：每模块 Python-golden 向量 parity + 严苛自审 + commit；详见 `V2C_RTL进展.md`。`cost.py` 冻结了 SOP/projected-cycle 公式。

## 3. ★★ 最想要你意见的：PPA-最优微架构（数据通路）
**现状**：3 模块的数据通路是 **1 输出/cycle 时分复用单 MAC**，每 cycle 做一次 **IN_DIM(=784/1024) 位全 popcount**。→ 功能对、面积小（单份），但 **关键路径 = 784 位 popcount 加法树（fmax 受限）**，延迟 = OUT×(T 或 in_bits) cycle（隐层 246×16≈4000）。
**plan-v1.md 的目标架构 = 事件行串行 + 列并行单bit累加**：只串行激活的 spiking 行（事件驱动，稀疏）；每次 128-bit 读宽（W=4→32 输出×4 bitplane 列并行）；每 active row 对各输出做 **单 bit 累加**（无每输出全 popcount 树）+ W 项 shift-add；首 spike 早停。→ 关键路径短（fmax 高）、面积省（无大 popcount 树）、延迟随有效 spike+早停。
**请回答**：
1. 这个 row-serial column-parallel 判断对吗？对"时序最优/延迟最低/面积最好"是不是正解？有没有更优的（如 bit-serial output、脉动、混合）？
2. 怎么干净地实现 active-row 串行（priority encoder/leading-one 扫 spike 向量？每拍一行？还是分组）？128-bit 列读 + per-output 单bit累加 + shift-add 的微架构怎么排（寄存器/流水/时序）？
3. 我该 **保留现功能版作 golden 参考模型 + 新建优化版**（两者都 parity），还是直接重构？风险？
4. 给个粗 fmax/面积/延迟 量级直觉（SMIC55nm，784→246→10，W4，T16）——好让我对齐 22nm TTFS ASIC baseline（F-MNIST 95.67µJ/30FPS）。

## 4. (A) 检查（P0/P1/P2）
1. **RTL 正确性/可综合**：parity 是理想模式 bit-exact，但请审 FSM 边界、signed/位宽（PSUM_W/MEM_W/Z_W 够不够，溢出？）、reset/start 握手、行为级 memory→宏/BRAM 映射的隐患、`always @*` 组合 popcount 的可综合性。
2. **deployed robustness 方法学**：冻结 λ=0.5 标定 θ_out 在故障下 strict 解码——这个"部署鲁棒性"口径对吗？故障率该不该从器件参数映射（已做 read_ber_from_device）？还缺什么。
3. **analog 基线**：现在是 illustrative+文献锚定，措辞是否够稳、审稿人会不会还挑。

## 5. (B/C) 调研 + 下一步该干什么
1. **进 DC 前的关键路径**：剩余 RTL（多层 top ↔ eval_ttfs_ramp 全程 parity、非理想注入 LFSR/ROM 理想模式 bit-exact+故障模式、P&V FSM、snn_soc_v2c_top）——**优先级排序**？哪些是 DC/FPGA 的硬前提？
2. **非理想注入 RTL**：怎么做到"理想模式与 Python golden bit-exact、故障模式 vs `robustness.py` 一致、且可综合（Verdi+FPGA 都反映）"？LFSR read-flip vs ROM stuck-at mask 的接法。
3. **latency/energy 量化**：`cost.py` 的 SOP + projected_cycle 公式对吗？DC 需要我先定死哪些（读宽/stripe/调度/时钟）？SOP-J 的 E_total 三桶（数字 DC + 阵列器件估 + mixed-signal 外围估）怎么对齐 plan。
4. **战略**：站在"鲁棒性=SOTA 轴、latency/power 靠 RTL"的定位，**RTL 阶段最该先量化哪几个数支撑 headline**？还有没有我**根本性漏掉**的（架构/编码/方法）？

## 6. 输出格式
P0/P1/P2 分组（问题 + `文件:行号` + 对/错/存疑 + 建议）；第 3 节给"我若是你会怎么设计 row-serial column-parallel 数据通路 + 粗 PPA 量级"；第 5 节按"进 DC 前必做 / 可选"排序，并明确"下一步先干什么"。
