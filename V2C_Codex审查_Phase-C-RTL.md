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

## 3. ★★★ 核心诉求：为「极致 PPA」做**论文级**架构/数据流/调度创新（请充分调研+搜索+深想）
> 这是本 prompt 最重要的部分。用户的最高指令是**极致压榨 PPA**（面积最好/时序最优/延迟最低/能效最高），且要的是**能写进论文的 novelty**，不是普通工程。**请你充分检索文献、对比 SOTA、放开想象，给出为实现极致 PPA 可以做哪些创新**。

**现状（诚实）**：当前 3 个 bit-exact 模块是**正确基线、非 novelty**——数据通路是 **1 输出/cycle 时分复用单 MAC**，每 cycle 一个 **IN_DIM(784) 位全 popcount**（关键路径长→fmax 受限；延迟=OUT×T≈4000）。**真正的极致-PPA 创新在接下来的 RTL。** 已沉淀方向在 `V2C_极致PPA创新点.md`（C1–C6），请你审阅、细化、补充、判 novelty。

**我已想到的方向（请评判+深化+补更强的）**：
- **C1 事件行串行 + 列并行单-bit 累加**：只串行 spiking 行（事件驱动稀疏）、128-bit 列读（W4→32 输出×4 bitplane 并行）、每 active row 对各输出**单 bit 累加**（消除每输出全 popcount 树→fmax↑面积↓）+ shift-add + 早停。
- **C2 把"决策"藏进"累积"**（类比 **ETH ITA**：attention 与 softmax 同时算、把延迟开销藏住）：阈值比较 + 首-spike 早停检测**融进膜累积同一流水级**，不另起决策周期；首 spike 一出即门控全阵列。
- **C3 bit-serial 输入相位 与 ramp 膜累积 流水重叠**藏住多比特输入开销；**C4 单份数据通路跨层时分复用**（无按层重编程）；**C5 skip-zero 稀疏跳过**。

**请你回答（务必充分调研后作答）**：
1. **检索 + 对标**：数字 CIM / TTFS / SNN / event-driven 加速器里，为极致 PPA 用过哪些**数据流/调度/架构/延迟隐藏**手法（举具体工作+做法+PPA 数）？哪些可迁移到 V2C？（类比 ITA 的 compute-fusion、GPU 的 fine-grain latency hiding、脉动、bit-serial、稀疏跳零、ping-pong、speculative early-stop…）
2. **给微架构**：C1 row-serial column-parallel 怎么排最优——active-row 串行扫描（priority encoder/leading-one？分组？）、128-bit 列读 + per-output 单bit累加 + W-项 shift-add 的流水/时序/寄存器划分？关键路径与瓶颈在哪？
3. **更强的 novelty**：除 C1–C6，**还有没有能把 V2C 推向极致 PPA 且可发表的 idea**？（哪怕激进——如 bit-serial-output、阈值预测推测早停、跨 timestep 流水、混合稀疏/稠密、近阈值/亚阈、数据相关时钟…）。每条标 novelty（vs 文献）+ PPA 收益量级 + 写论文的角度。
4. **取舍**：保留现功能版作 golden 参考 + 新建优化版（都 parity），还是重构？风险？给个粗 fmax/面积/延迟/能效 量级（SMIC55nm，784→246→10，W4，T16），对标 22nm TTFS ASIC（F-MNIST 95.67µJ/30FPS）。
> 把第 1、3 点当**重头**做——用户明确要"充分调研、搜索、思索为极致 PPA 怎么做创新，且是能写进论文的 idea"。结论凡值得写论文的，我会回填 `V2C_极致PPA创新点.md`。

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
