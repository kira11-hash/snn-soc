# V2C 极致 PPA 创新点记录（论文 contribution 候选）

> **★ 标准指令（用户 2026-06-06）**：任何为"极致压榨 PPA（面积/功耗/延迟）"而采取的**手段/方法/架构/数据流/调度/算法**，只要**值得作为论文创新点**，都必须记录进本文档。PPA 是本项目最高指令（见记忆 `snn-soc-project`）；本文档专门沉淀其中**可发表的 novelty**。
> 每条标注成熟度：`概念固有`（V2C 定位自带）/ `基线工程`（标准做法，非 novelty）/ `候选创新`（待设计+验证，若新则写论文）/ `已验证`。
> 诚实红线：novelty 须经文献核对（别声称已知做法是首创）；PPA 数标实测/估算/projected，不混仿真与硅。

---

## A. V2C 概念层 PPA 优势（定位自带，部分是 novelty）
| # | 点 | PPA 收益 | 成熟度 / novelty 判断 |
|---|---|---|---|
| A1 | **数字二值 0T1R RRAM-CIM + TTFS**（全数字、cell 严格二值） | 去掉模拟 MVM | `概念固有`；"数字二值 CIM 上做 TTFS"组合**可能**新（待文献核） |
| A2 | **1-bit 数字 sense，无多比特 ADC** | 省 ADC 能耗/面积（模拟 CIM 大头，常≥50%）；by-design 抗 ADC 量化/variation | `概念固有`；无-ADC 二值 CIM 已有，但 + TTFS + 鲁棒性对照**叙事**新 |
| A3 | **TTFS 单脉冲稀疏**（每神经元每帧≤1 spike） | 低 SOP → 低能耗 | `概念固有`（TTFS 本性） |
| A4 | **首 spike 早停 + 数据相关延迟** | 推理一旦出首个输出 spike 即停 → 延迟随置信度自适应、时钟门控省功耗 | `概念固有` + `候选创新`（见 C2 的"延迟即答案"硬件化） |
| A5 | **bit-serial 多比特输入 on 二值 cell**（相位+shift-add） | 多比特输入不需多比特 DAC/模拟，cell 仍二值 | `基线工程`（bit-serial 已知）；但与 ramp-TTFS 融合**可能**新 |
| A6 | **per-output 整数阈值，推理零 BN/零乘法** | 无推理期乘法器/归一化 → 省面积/功耗 | `基线工程`（threshold-folding 已知） |

## B. 当前已写 RTL（模块 1–3）的 PPA 选择 —— 基线、**非论文 novelty**
> ⚠ 诚实：当前 3 个 bit-exact 模块**优先正确性 + parity**，PPA 选择是"合理工程"，**不是**论文级创新。真正的极致-PPA 创新在 C（接下来的 RTL）。
- B1 `v2c_cim_mac`：单输出组合 popcount→shift-add。`基线工程`。**当前短板**：每 cycle 一个 IN_DIM(784) 位全 popcount 树 → 关键路径长（fmax 受限）。
- B2 `v2c_ttfs_layer` / `v2c_ramp_layer`：**1 输出/cycle 时分复用单 MAC**（面积小、单份 ALU 跨输出复用）+ ramp **divide-free** 累加（避乘除）+ early-exit。`基线工程`。**当前短板**：延迟 = OUT×T cycle（隐层 ~4000）。

## C. ★ 候选论文级 PPA 创新（接下来的 RTL —— 待 Codex 调研+设计+验证）
> 目标：面积最好 / 时序最优 / 延迟最低 / 能效最高。下列为方向，需 Codex 充分调研文献后细化、判定 novelty、给微架构。
- **C1 事件行串行 + 列并行单-bit 累加（row-serial column-parallel）**：只串行**激活的 spiking 行**（事件驱动，稀疏→cycle 随有效 spike）；每次 128-bit 读宽（W=4→32 输出×4 bitplane 列并行）；每 active row 对各输出做**单 bit 累加**（**消除每输出全 popcount 树** → 关键路径短=fmax 高、面积省）+ W 项 shift-add。**取代 B 的 OUT-serial 全 popcount**。→ 同时赢面积+时序+延迟。novelty：TTFS 数字二值 CIM 的事件驱动 stripe 数据流（待核）。
- **C2 "延迟即答案"硬件化 / 把决策藏进累积**（类比 ETH **ITA**：attention 与 softmax 同时算、把延迟/开销藏住）：**把阈值比较 + 首-spike 早停检测融进膜累积的同一拍/流水级**，不另起决策周期 → 隐藏决策延迟；首 spike 一出立刻门控全阵列。
- **C3 bit-serial 输入相位 与 ramp 膜累积 流水重叠**：多比特输入的 in_bits 相位 与 (t+1)·z1 的 ramp 累积**流水并行**，藏住 bit-serial 的延迟开销。
- **C4 单份数字通路时分复用跨层（single-macro-resident，无按层重编程）**：hidden/output 层共用同一 ALU + 阵列不同列段，推理期不重载权重 → 面积（单份）+ 能耗（无重编程）。
- **C5 skip-zero / 稀疏跳过**：非 spiking 行/零输入位不进数据通路（与 C1 的事件驱动协同）→ 动态省功耗+延迟。
- **C6（开放，Codex 补）**：GPU 式 fine-grain 延迟隐藏、脉动/streaming decode、bit-serial-output、阈值预测/推测早停、跨 timestep 流水、stripe 间 ping-pong……凡能把 V2C 推向极致 PPA 且**可发表**的，都在此沉淀。

## E. ★★ 多-subagent 大调研综合（2026-06-06，4 路独立并行，避免单源偏差）
> 4 个独立研究 agent 各攻一轴（① 数据流融合/延迟隐藏 ② 事件驱动/TTFS 稀疏 ③ 数字二值 CIM-MAC 微架构 ④ 精度可伸缩/推测早停），**带引用**。**四路高度收敛到同一核心创新**（强信号）。

### E0. 核心收敛创新（4 路独立都指向）— ⚠ **2026-06-06 已被 §F2 可行性数据实证否决**（非最优 PPA；lossless 成立但部分和收紧太慢、不划算），保留作研究轨迹
**「双单调 MSB-first 推测首-spike 提交」(double-monotone speculative first-spike commit)**：V2C 有**两重单调性**——① ramp 膜 `membrane(t)=(t+1)·z` 对 t 单调（z>0）；② bit-serial 部分 popcount 对 bit-slice 单调。**用每输出一对廉价上下界 `z_lo/z_hi`（只处理高位 slice/相位即可得），在 full ramp 和 full bit-serial MAC 都没跑完前，就 provably 提交赢家（首个 `(t+1)·z_lo≥θ`）或淘汰输者（`(t+1)·z_hi<θ`），停掉该神经元剩余 slice/相位 + 时钟门控全阵列。** 完全 lossless（可证），比 naive ramp（等完整 z 累完才比阈值）严格更早出首 spike。
- **先验（须 positioning，别声称首创这些单点）**：MSB-first 单调界 = **BitSET**(TECS'23, 1.5×/1.4×, lossless)、**SnaPEA**(ISCA'18, exact 无损)、**ComPEND**(ICCAD'18 反码"一旦负恒负")；TTFS 首-spike argmin 解码 = arxiv 2410.23619；TTFS 阈值即延迟旋钮 = **TFSRAM**(TCASAI'24, 249.8 TOPS/W, Timing-Threshold Adjustment)；优先编码首-spike = **TQ-TTFS**(HPI/WTA detector)。
- **novelty（4 路一致判定）**：上述单点全已发表、别单claim；**「双单调界 + TTFS 首-spike 在数字二值 0T1R RRAM-CIM ramp 上的组合 = 未见发表」**。这是**论文最强 contribution**：co-design——不是"我们融了一级"，而是"TTFS fire-once + ramp 单调 provably 界定有效 CIM 行/拍，我们建了唯一把这个界转成 cycle 节省的微架构"。

### E1. 支撑创新（与 E0 协同，分别有中等 novelty）
- **TTFS fire-once 单调行压缩**：神经元一旦发放即"死"→ active-row 集**随 bit-plane 和 timestep 单调缩小**；只对**仍沉默的行**做 popcount。把脉冲语义耦合进 CIM 调度（模拟/event-CNN CIM 做不到）。(agent①③；novelty 中)
- **row-serial column-parallel bit-serial 累加**（取代 784 位全 popcount 树）：每列一个 bit-serial 累加器 → **fmax 与 IN_DIM/位宽解耦**（Colonnade JSSC'21 范式），代价 latency=行/位 cycle（但配 E1 稀疏 + 早停就少）。**解掉当前基线的关键路径瓶颈。**(agent③；primitive 已知、二值0T1R+TTFS 实例化新)
- **阈值/早停融进累积尾**（ITA 式 fusion）：popcount→shift-add 尾直接接比较器，`V≥θ` 立即发；输出层 10 路优先编码 → 首 spike 一出 assert done + 门控全局时钟（真省 cycle/能耗，非仅标志）。(agent①②；ITA arxiv 2307.03493、TQ-TTFS)
- **TTFS-spike-order 误差界定的近似 popcount-加法树**：TTFS 只需"谁先过阈"→ 用**截断/近似 compressor 树**(DIMC 式, 2219 TOPS/W)，只要误差 **provably < 类间 spike-time margin** 就无损序。"按 spike 序而非 MAC 值界定近似误差"是**新 framing**(agent③；novelty 中-高)
- **bit-plane / 相位跳零**（Pragmatic-for-spikes）：跳过全零 ramp 相位/权重 slice 的 popcount（数字域近乎免费）。(agent④；机制已知、脉冲输入 framing 新)
- **流水重叠 + ping-pong**：bit-plane k+1 popcount 与 plane k 的 shift-add 重叠；ping-pong 膜电位 bank → 层 L 累积与层 L+1 消费已发放神经元重叠（inter-layer spike streaming）。(agent①)

### E2. 必报的"催"（4 路都警告）
**数据相关延迟 → workload 不均衡**（Skydiver 98% 稀疏时利用率掉到 ~59%）。**必须报 worst-case cycle，不只 mean**，否则审稿人打折；把"有界 worst-case 延迟"反过来当**确定性延迟卖点**(agent②)。`z_hi` 上界需未处理 slice 的 max（二值 cell 廉价）。

### E3. 最该 positioning 的最近 prior art
**E-ReCON**(3T1R ReRAM spiking 数字 CIM, **419 TOPS/W @65nm**, AND-mul + 10T/28T interleaved 加法树, **arxiv 2605.20717 已核实存在**，见 §F3)——**与 V2C 最像的前作，related-work 主对标它**；**TFSRAM**(TTFS CIM 249.8 TOPS/W)；**Oh et al.**(22nm TTFS CNN, addition-only, 首-spike 早停, 3.88–64.6× 延迟↓)；**ADC-less 3T2R RRAM BNN**(51.3 TOPS/W, inverter-quantize, 确定性无校准)；**Colonnade/BitSET/SnaPEA/ITA/DIMC**(机制先验)。

### E4. 关键来源
ITA https://arxiv.org/abs/2307.03493 · BitSET https://dl.acm.org/doi/10.1145/3609093 · SnaPEA https://cseweb.ucsd.edu/~vakhlagh/ISCA18-SnaPEA.pdf · E-ReCON https://arxiv.org/abs/2605.20717 · TFSRAM https://ieeexplore.ieee.org/document/10665958/ · Colonnade https://ieeexplore.ieee.org/document/9373949/ · DIMC https://par.nsf.gov/servlets/purl/10342205 · FlexSpIM https://arxiv.org/html/2410.23082 · SpiDR https://arxiv.org/html/2411.02854v1 · Oh TTFS-CNN https://pmc.ncbi.nlm.nih.gov/articles/PMC10198466/ · TTFS argmin/early-exit https://arxiv.org/html/2410.23619v2 · Bit-Pragmatic https://arxiv.org/pdf/1610.06920 · WFWC https://www.sciencedirect.com/science/article/abs/pii/S0925231225001304 · ADC-less RRAM BNN https://ieeexplore.ieee.org/document/10004708/

## F. ★★ Codex#4 后可行性分析 — bit-serial 推测**否决** + 异构 co-design **选定**（2026-06-06，数据驱动）
> 用户拍板"做可行性分析、选最优 PPA、最有创新点方案"。在 gate-init SNN + 真实 Fashion 权重上量化（脚本 `/tmp/feas.py`，逻辑可复现）。**结论推翻 §E0**：双单调 bit-serial 推测不是最优；**异构数据流 co-design + skip-zero** 才是。§E 保留作研究轨迹（诚实留痕）。

### F0. 发现 C 已解：plan 的 bit-parallel-weight 与 §E0 的 bit-serial-slice 推测本质冲突
plan-v1.md:30/33 + 决策记录:30 既定 **shift-add = bit-parallel weight**（128-bit 读宽一次读一个输出的 W 个 bit-plane = 32 输出/stripe），理由"bit-serial ×W 拖延迟、50MHz 无压力"。§E0 第二重单调（bit-slice MSB-first 逐 slice 推测）需 **bit-serial weight 读出** → 与 plan 冲突。这是"哪个 PPA 更优"的实证问题 → 用数据定（F1）。

### F1. 实测数据（gate-init SNN, Fashion, 真实权重, n=1000）
- **hidden fire-rate = 22%**（54.2/246 active rows, p95=72, max=83）→ 输出层 event-driven active rows 少。
- **输出 t_exit = 5.15/16**（p95=12, max=16）算法早停。
- **输入层 MSB-first 推测 BEST-CASE**（忽略 stripe 共享行读，最乐观）：avg **14.49/16** bit-plane 才能 provably 判定发/不发，**0%** 在 4 项内判定。bit-parallel 仅 **4 拍/stripe** → bit-serial 推测差 **3.6×，LOSE**（换 MSB-first 顺序救不回）。根因：dense 输入 MAC、z1/阈值量级大 + 权重符号混合 → 部分和上下界收紧太慢。
- **projected cycle（cost.py 修订版, read_bits=128）**：输入(bit-parallel)=**25088**（占 **99.8%**）/ 输出(event-driven, 54 rows)=**54** / total 25142。→ 输入层 dense 是绝对瓶颈，**TTFS 早停在 RTL cycle 层面只省输出 <1%**。
- **输入层 skip-zero 潜力**：零行 skip 省 **52.8%**（Fashion 背景黑、仅 47% 非零像素行）；bit-level skip-zero 上限 **73.5%**（input-bit density 26.5%）。

### F2. ★ 结论 + 选定方案（最优 PPA + 最有创新点）
- **否决 §E0 双单调 bit-serial 推测**：输入层赢不了 bit-parallel（dense + ×W + 收紧慢），输出层即使能推测绝对收益 <54 cyc 可忽略。**不作论文 contribution。**
- **保持 plan bit-parallel 输入**（既定决策实证正确，不动）。
- **输入层（瓶颈）唯一大杠杆 = skip-zero**（零行/零位 popcount 跳过），省 50–73%。dense MAC 减 cycle 的正道（≈ §E1 bit-plane/相位跳零，升为主线）。
- **输出层 = event-driven row-serial**（active rows ~54/246）+ **首-spike 早停** + **决策融进累积尾**（ITA 式，§E1 仍有效）。
- **★ 选定 novelty = 异构 TTFS-aware 数字二值 0T1R CIM 数据流 co-design**：dense-input bit-parallel popcount + skip-zero ‖ sparse-output event-driven row-serial + 早停。可量化、不与 plan 冲突、对标 E-ReCON 有差异化。**取代 §E0 成为 PPA contribution 主线。**
- **诚实再定位**：RTL 延迟 headline 抓手 = **输入层 skip-zero**（非 TTFS 早停，后者只省输出 <1%）；TTFS 单脉冲稀疏的真实价值在 **能耗/SOP**（输出稀疏 + 时钟门控）+ **延迟确定性**（输入 dense 主导→worst≈mean，反当确定性卖点）。印证红线"算法 timestep ≠ RTL cycle"。

### F3. E-ReCON 核实（发现 A 闭合）
arxiv **2605.20717 确认存在**（不再"待核"）：「E-ReCON: Energy- and Resource-Efficient Precision-Configurable Sparse nvCIM Macro for Conventional and Spiking NN Edge Inference」。3T1R ReRAM, 0.85µm² bitcell, 65nm/1.2V, min latency 0.48ns, 2.31–3.1 TOPS, **419 TOPS/W**, AND-based in-mem mul + 10T/28T interleaved adder tree, CNN+SNN（LeNet-5 97.81% / AlexNet 93.23% / CNN-8 96.51%）。**related-work 主对标**；V2C 差异 = **0T1R**（更省 cell）+ TTFS ramp + 无 ADC 鲁棒性 + skip-zero 稀疏。

### F4. §E0 lossless 性独立结论（留痕：虽否决，推导有效）
独立验证 §E0 lossless 在三条件下成立——① **MSB-first 处理序**（two's-comp 唯一负权重位 MSB 先消化 → 剩余非负 → 界单调收紧）；② **z1 符号处理**（区间跨 0 不可 commit 发放、仍可淘汰）；③ **tie-break 一致**（同 timestep 按 golden index 序破）。**lossless 不是否决理由 — 否决理由是 PPA 收益（部分和收紧太慢）不划算。** Codex#4 只说"写成 interval-bound 即可"，既未做此推导也未做实测。

## G. ★★ 外部调研（2026-06-06，CIM技巧/替代范式/编码 攻 dense 第一层）— 带链接
> 目标：找能**结构性**砍 dense 输入层（占 99.8% cycle）PPA 的招，超越/互补 skip-zero。重点判可迁移性到「二值cell+popcount+无ADC+128b bit-parallel weight+TTFS ramp」+ TTFS 时间编码天然融合。

### G1. ★最强候选：Time-Domain Popcount（race-logic 化 popcount，TTFS 原生）
- **paper**：Efficient FPGA Implementation of Time-Domain Popcount, arxiv 2505.02181。做法一句：把 popcount 用**延迟链**算——置位数→正比的**传播延迟**（时间域 thermometer），不用二值加法树。
- **PPA**：去掉 log(N) 加法树 → 省面积/功耗/glitch；输出**天然是延迟值**。
- **可迁移性（高）**：当前基线短板 B1 = 每 cycle 784 位全 popcount 树（关键路径长、fmax 受限）。time-domain popcount **直接消除加法树**。**关键融合**：输出延迟可**直接喂 TTFS ramp / 阈值比较器**，无需转回二值再比阈——这正是 V2C 膜累积 `(t+1)·z≥θ` 要的。即 popcount→ramp→fire 全在时间域，省掉「popcount 二值化 + shift-add + 比较」整条数字尾。
- **novelty（高）**：race-logic/time-domain popcount 已有(FPGA)，但**在数字二值 0T1R RRAM-CIM 的 bit-plane 读出列上做、且延迟直连 TTFS ramp** = 未见。和 §E0 否决的 bit-serial 推测不同：这是换 popcount 的**物理实现范式**，dense 友好（不依赖部分和收紧）。⚠ 待评估：ASIC 延迟链 PVT 敏感性 vs 全数字鲁棒卖点是否冲突（可做"粗粒度数字延迟=计数器"折中，见 Catwalk）。

### G2. ★第二候选：操作数冗余复用 / popcount 记忆化（结构性砍 dense MAC，非 skip-zero）
- **papers**：CREW (arxiv 2107.09408, computation reuse + unique-weight，**省 98% 乘法**、FC 存储省 25%)；Transitive Array (arxiv 2504.16339, transitive sparsity 结果复用，**7.46×/3.97× speedup, 2.31×/1.65× energy** vs Olive/BitVert, multiplication-free)；ΔNN 差分计算 (w_{m+1}·i=Δ·i+w_m·i 复用前次 MAC)。
- **做法一句**：dense 第一层输入只有**极少 unique 模式**（4-bit 像素=仅 16 种值；或跨 784 维 bit-plane 内大量重复 bit-pattern），**算一次部分积/部分 popcount 然后复用**，不重复算。
- **可迁移性（中-高）**：V2C 每 stripe 32 输出共用同一段 128-bit 权重读；**bit-plane k 上，多个输出列对同一组激活做 popcount → 激活侧 bit-pattern 复用**。或像素 4-bit→16 值，预算 16 种"权重子集 popcount"查表(LUT 化 CIM)，dense MAC 变查表。**对标 skip-zero 正交**：skip-zero 砍零，reuse 砍**重复的非零计算**，可叠加。
- **novelty（中）**：computation-reuse 已知，但**在 TTFS 数字二值 CIM 上做 popcount-level 记忆化/unique-pattern 复用**未见；需实测 unique-pattern 率定收益（类比 §F 用真实 Fashion 权重跑）。

### G3. 第三候选：Catwalk ramp-no-leak 时间域 MAC（TTFS 直接对标，验证 V2C ramp 选择）
- **paper**：Catwalk: Unary Top-K for Ramp-No-Leak Neuron, arxiv 2508.21267。做法一句：ramp-no-leak 神经元在**时间域累积**加权脉冲，过阈 fire，结果即 spike timing（TTFS）；unary top-K 选择。
- **PPA**：去二值加法树→单积分器+比较器；省面积/能耗。**数字实现**（时步计数器或数字控延迟），桥接 neuromorphic 与数字。
- **可迁移性（中）**：直接验证 V2C 的 ramp-TTFS 路线（B2/A4）在 SOTA 是对的；可借其"数字时步 ramp"实现避 G1 的模拟延迟链 PVT 问题。**top-K 的硬件 WTA** 可用于输出层 10 路首-spike 优先编码（§E1 决策融合）。novelty 低（主要作 positioning + 借鉴），但**ramp-no-leak + 二值 CIM popcount 前端**组合可叙事。

### G4. 评估过但**次优/不迁移**（诚实留痕）
- **Stochastic computing**（all-in-mem SC ReRAM arxiv 2504.08340；StoX-Net 16×/8×/10× E/L/A）：超省面积，但 **PRNG 占 >80% 能耗/面积**，且位流长→延迟，dense 第一层精度/延迟不划算；与"无 ADC 确定性鲁棒"卖点冲突（SC 引入随机误差）。**不推荐**作 dense 层主线。
- **RNS（剩余数系）**：分解大乘加，但 popcount-MAC 已无乘法器，RNS 收益不明显 + 转换开销；**不迁移**。
- **纯 race-logic min/max（DNA/排序）**：AND/OR=min/max，无法做一般加法（causality 限制）→ 不能直接做加权和；只 G1 的 time-domain popcount 这种"延迟正比计数"形式可用。
- **bit-level weight 列相似/重排**（arxiv 2511.14202 column similarity, 2410.21730 weight sorting）：合并相同/相似 bit 列省读出，**模拟 CIM 省 ADC 为主**；V2C 无 ADC，收益缩水，但"省权重列读出/复用"思路可与 G2 合流。

### G5. 关键来源（带链接）
- Time-Domain Popcount https://arxiv.org/pdf/2505.02181
- CREW（98%乘法省）https://arxiv.org/pdf/2107.09408
- Transitive Array https://arxiv.org/pdf/2504.16339 · ΔNN/CoDR https://arxiv.org/pdf/2104.09798
- Catwalk ramp-no-leak https://arxiv.org/pdf/2508.21267
- 时间域脉冲加权和(237.7 TOPS/W) https://pmc.ncbi.nlm.nih.gov/articles/PMC12463932/
- all-in-mem SC ReRAM https://arxiv.org/html/2504.08340v1 · StoX-Net https://arxiv.org/pdf/2407.12378
- 列相似 bit 重排 https://arxiv.org/html/2511.14202 · weight sorting/bit-stucking https://arxiv.org/html/2410.21730
- Race Logic 综述 https://www.ncbi.nlm.nih.gov/pmc/articles/PMC9792072/ · 含 in-mem sorting 37×/138× energy

## H. ★★ 多领域综合（2026-06-06，4 路 subagent：DNN/CNN加速器·LLM·DL模型算法·CIM范式）— dense 第一层多轴压缩
> 在"否决 bit-serial 推测、选定异构 co-design+skip-zero"(§F) 后，分 4 路 subagent 从外部领域找**结构性砍 dense 第一层（占 99.8% cycle）**的招。**核心认知更新：dense 第一层瓶颈有 4 个正交、可叠乘的面**（之前只想到面①）。CIM 范式那路详见 §G。

### H0. 4 个正交可叠乘的面（综合框架）
| 面 | 攻击点 | 主手段 | 收益量级 | novelty | 风险/代价 |
|---|---|---|---|---|---|
| ① 输入激活侧 | 零像素/零位 | skip-zero（§F）| 50–73% | 中（机制已知，TTFS framing 新）| 低（已选定）|
| ② 权重 bit 侧 | 权重 4 bit-plane 当前 100% dense | CSD/signed-digit bit 稀疏 + 冗余复用/LUT | bit 稀疏 ~33%+，reuse 叠加 | **高**（数字二值CIM+TTFS 上未见）| 低（复用现有 two's-comp shift-add）|
| ③ 瓶颈本身大小 | 第一层 784×246×4b 过参数化 | 输入降维(28²→14²)+降比特(4→2)+低秩(784→r→246)| 单项 50–90%，叠加 ~87% | 中（降维老）/ **高**（低秩+TTFS-CIM 空白）| 精度 ~1–2%（accuracy 非胜负手可吃）|
| ④ 计算物理范式 | popcount 加法树关键路径 | time-domain popcount（延迟链直喂 TTFS ramp）| 去 log(N) 加法树，fmax↑面积↓ | **高**（§G1）| PVT 敏感 vs 数字鲁棒卖点（数字计数器折中）|

### H1. 面②权重 bit 稀疏（Agent DNN/CNN + LLM 收敛）
- **CSD/signed-digit 权重编码**（DB-PIM HPCA'24 7.69×/83%能耗↓/<1%损失；BBS MICRO'24 3.03×；BitWave 列级 bit 稀疏+重排）：权重重编码成 {-1,0,+1} 无相邻非零，免费砍 ~33% 非零权重位，加 Fixed-Threshold(≤2 非零位/权重) 可更多。**落地**：复用 V2C two's-comp shift-add（符号机制已有），全零 bit-column 像 skip-zero 一样跳过 → 与面①叠乘(>85%)。**headline novelty 候选**。
- **LUT-GEMM/BiQGEMM 二值权重部分积复用**（LUT-GEMM ICLR'24, BiQGEMM）：激活切 μ-子向量预算与所有 2^μ 二值模式点积存 LUT，权重行查表+累加，O(mn)→O(mn/μ)。**契合**：128-bit bit-parallel 读宽下同一权重 bit-pattern 跨 246 列高频复现。⚠ 待解：bit-serial 4-bit 激活与 LUT 建表耦合（也是 novelty 点）。
- **冗余复用/popcount 记忆化**（CREW 98%乘法省；Transitive Array 7.46×）：像素仅 16 种值，重复模式算一次复用（详见 §G2，与 skip-zero 正交）。

### H2. 面③瓶颈缩小（Agent DL 模型算法；利用 accuracy 非胜负手）
- **输入降维** 28²→14² avg-pool/strided → 第一层 MAC↓75%、精度掉 1–2%。最稳、不动硬件（ANN 端做）、不破坏 ANN→SNN 解析映射。
- **输入降比特** in_bits 4→2（learned 量化）→ bit-serial 周期↓50%、精度 <1%。与降维叠乘 ≈ 砍 87%、代价 ~2%。
- **低秩分解** 784→r→246（r≈48）→ MAC↓~75%，需短 fine-tune + 中间 ReLU1 保单调映射。**novelty 高**（低秩+TTFS-CIM 空白），论文头条候选。
- **固定二值稀疏随机投影**前置降维层（可直接烧进 RRAM 当免费降维，二值天然 popcount）。频域 DCT 低频输入砍 ~90% 但负值伤解析映射、风险高。

### H3. 优先级 + 落地路线（综合判断）
1. **先做面③降维+降比特**（最稳/最快/不动硬件）：第一层 25088→~3000 cycle；Python 验精度（3 数据集，目标掉 ≤2–3pp）。
2. **叠面②CSD 权重 bit 稀疏 + 面①skip-zero**：headline novelty，复用现有 shift-add；先 Python 实测 bit-稀疏率（类比 §F 真实权重）。
3. **面④time-domain popcount** 作激进 novelty：先评 PVT vs 鲁棒卖点（数字计数器折中）。
4. **低秩分解**作论文 novelty 头条候选。
- 4 面正交可叠乘 → 第一层有望 25088 砍到几百–一两千。**"多轴正交压缩 dense 第一层 on 数字二值 CIM+TTFS" = 比被否的双单调推测扎实得多的可发表故事。**
- ⚠ 全部需像 §F 一样**用真实权重/数据实测收益 + parity 保功能**，别只引文献量级。

### H4. 关键来源
- DB-PIM https://arxiv.org/html/2404.09497v1 · BBS https://arxiv.org/abs/2409.05227 · BitWave https://arxiv.org/pdf/2507.12444
- LUT-GEMM https://arxiv.org/html/2206.09557v4 · BiQGEMM https://ar5iv.labs.arxiv.org/html/2005.09904 · CIMPool https://arxiv.org/html/2503.22044
- 低秩 SVD-FC https://www.mdpi.com/2076-3417/13/4/2704 · 二值稀疏随机投影 https://link.springer.com/chapter/10.1007/978-3-658-33198-6_51 · LC-TTFS https://arxiv.org/abs/2310.14978
- 频域 DCT https://openaccess.thecvf.com/content_CVPR_2020/papers/Xu_Learning_in_the_Frequency_Domain_CVPR_2020_paper.pdf · Monarch 结构化矩阵 https://proceedings.mlr.press/v162/dao22a/dao22a.pdf
- （CIM 范式那路 time-domain popcount / CREW / Catwalk 见 §G5）

## I. ★★ Cross-check 二轮（2026-06-06，4 路新 subagent 独立验证/挑战 §G/§H）— 多个 headline 被实测推翻
> 用户要求对 §G/§H 做 cross-check。4 路新 subagent 各拿上一轮该路结论、独立查证+挑战+补漏（不附和）。**结果：第一轮多个"最强招"被修正/推翻**——体现"不拘泥旧结论、用证据该改就改"。

### I0. 被推翻/降级（诚实留痕）
| 第一轮结论 | cross-check 裁决 | 关键证据 | 路 |
|---|---|---|---|
| CSD 砍 33% 权重位（headline）| **降级** | 4-bit 下只 ~28%（NAF 1.44/2.00 精确枚举）；DB-PIM 7.69× 是 **8-bit SRAM 组合数**、单 bit 稀疏 5.2×、迁 4-bit 二值 RRAM 现实 ~1.3-1.5×；三值 {-1,0,+1} 不适配 write-once 二值 cell | 1 |
| 截断/近似加法树"对 TTFS 免费" | **推翻** | 仿真丢 1 LSB plane 翻 top-1 ~9%、2 planes ~20%（TTFS 比谁先发，近平局被误差翻序）→ 必须 per-output 有界 | 1 |
| LUT-GEMM/BiQGEMM 最强 | **推翻（净负）** | 它复用**激活跨 batch**、假设 FP 激活+亿级矩阵+大 batch；我们 batch=1/4-bit 激活/246 小矩阵 → 建表一次用一次、build 开销主导；"权重跨 246 列复现"说反了 | 2 |
| time-domain popcount 最强 | **推翻（砸卖点）** | delay-chain 本质模拟时序，砸"全数字抗 PVT"核心卖点；arXiv 2403.18367 定量证严格精度下纯数字全面胜 TD；数字计数器折中后收益归零；延迟单元 300-615 ppm/°C | 4 |
| 降维 1-2% + 降比特 <1%，叠加~2% | **修正（过度乐观）** | 1-2% 是 CNN(LeNet) 数；1-bit 隐层 dense MLP 真实 **3-6pp**；叠加**超线性** → 总代价 **5-9pp**，KMNIST 可能破 80% 底线 | 3 |
| 低秩 784→r→246 作 novelty 头条 | **降级为高风险赌注** | 第二段 factor 动态范围宽（文献都保高精度/残差），强塞双 1-bit=双倍信息损失；"插 ReLU1 保单调"未证、累积 TTFS 误差 | 3 |
| 冗余复用 CREW 98%/Transitive 7.46× | **推翻（机理讲反）** | CREW 复用**权重重复**、FC 层每输入对应 unique 权重列（784×246 无重复）、CREW 论文点名"对 FC 失效"；像素 16 值是输入端复用但 246 输出权重各异、省不掉乘加列；7.46× 是 LLM+弱基线不可移植 | 4 |

### I1. ★ Cross-check 后收敛的真正主线（多路独立指向，全数字/有硅证/不伤鲁棒卖点）
1. **bit 级零跳过（最稳主线，路1+路4 收敛）**：skip-zero（输入零，已选定）+ **bit-level sparsity skip**（4-bit bit-serial 高 bitplane 2³/2² 天然稀疏→跳零 bit；硅证 38.21 TOPS/W 数字 CIM）+ **离线列对齐 bit-零打包**（权重 bit 重排+flip 制造可跳零列，arxiv 2511.14202，一次性离线、零 RRAM 重写、crossbar 原生）。全数字、零 PVT 代价、与 skip-zero 叠加。**两轮调研收敛的 PPA 头条候选。**
2. **KD 蒸馏找回精度（路3 力荐）**：FP teacher→1-bit student，纯训练侧、推理免费、最可靠找回 1-bit 隐层损失 → 让我们能更激进砍 PPA 而守 accuracy 底线。
3. **像素 codebook LUT（输入端复用，路2+路4 收敛）**：MADDNESS/LUT-DLA/TLMAC，像素 16 值做首层激活 codebook、查表+移位加替代乘加，全数字无乘法。⚠ 需实测真实收益（246 输出权重各异）。
4. **降维 or 降比特（单轴+蒸馏，路3）**：代价比想象大（叠加 5-9pp），**只选一个轴+蒸馏**，守 KMNIST 80% 底线。

### I2. ★ 红线更新
- 别再吹 CSD 33% / DB-PIM 7.69× / LUT-GEMM / time-domain popcount / CREW 复用 —— 已被 cross-check 修正或推翻（理由见 I0）。
- 任何"砍 PPA"招都要：① **全数字、不伤抗 PVT 鲁棒卖点**；② **真实权重/数据实测收益**（别引文献量级）；③ **parity 保功能**；④ **守 KMNIST 80% 底线**（TTFS 比谁先发、近平局对误差敏感）。
- novelty 排序：bit 级零跳过（含列对齐打包）> KD+单轴降维/降比特 > 像素 codebook LUT >（低秩/time-domain/CSD 降为研究赌注或弃）。

### I3. 来源（cross-check 新增）
列对齐 bit 重排 https://arxiv.org/html/2511.14202 · TD 计算定量劣势 https://arxiv.org/html/2403.18367v1 · 剪枝+量化超线性 https://arxiv.org/html/2509.04244v1 · 低秩+低精度动态范围 LPLR https://arxiv.org/pdf/2310.11028 · SVDQuant https://arxiv.org/html/2411.05007v3 · 全数字 LUT-MAC https://arxiv.org/pdf/2506.16800 · LUT-DLA https://arxiv.org/pdf/2501.10658 · MVQ https://arxiv.org/html/2412.10261 · 分离卷积二值首级 https://arxiv.org/pdf/1707.04693 · BiMLP https://arxiv.org/pdf/2212.14158

## J. ★★ 第三轮 cross-check（2026-06-06，8 subagent：稀疏数据流硬件·神经形态·保序近似·离线mapping 各2）+ 真实权重实测颠覆
> 用户要求"每领域≥2 subagent cross-check、Claude 自己收敛"。8 subagent + 我用 §F 真实实测校验 → **几个 §I 主线被真实数据修正**。

### J0. ★ 决定性发现（真实权重实测 > 文献乐观）
- **"列对齐整列零打包"在真实权重上≈无效**（方向D-agent2 实测仓库真实首层权重）：**整列零率=0.00%**（two's & sign-mag），最稀疏列仍 292/784 个 1、中位 387，bit-flip 救不动。根因：输入维 784 太长、popcount 一次读全列 → 无短列可对齐成零。2511.14202 为短 OU（ADC 分块）设计，我们无 ADC 读全 784 行 → 不适用。**→ §I1 把"列对齐 bit-零打包"列头号是错的，降级。**
- **但 cell 级权重零率真实高：two's-comp 51.6% / sign-magnitude 59.3%**（与 BitWave 一致）。兑现需 **per-bitplane skip**（不能整列跳）。sign-mag 重编码离线零成本 +7.7pp。
- **输入侧零（§F 已实测，校正 subagent 乐观）**：方向B-agent1 称"输入 98% 零、省 10-50×"——**被我 §F 实测打假**：Fashion 真实 47% 非零像素（省 ~53%）、input-bit density 26.5%（bit-plane 73.5% 零，省 ~2-4×）。B1 的 1-2% 是 N-MNIST(DVS 事件)非灰度图。**用真实数据校正文献乐观 = cross-check 的价值。**

### J1. 真正收敛的 PPA 主力（三轮 + 实测校验后）
1. **输入侧零跳过（实测主力）**：像素零 ~53% + 输入 bit-plane 零 ~73%（§F 数据支撑）。全数字、稳。
2. **权重位平面 skip（cell 零 51-59%，sign-mag 重编码 +7.7pp）**：兑现需 per-bitplane skip。
3. **BBS 双向位稀疏 + 负载均衡兜底**（方向A 两 agent 收敛）：high-bitplane 全一时"跳一代替跳零"把有效列下界钉 ≥50%，解 dense worst-case 退化；Dyn-Bitpool 跨-lane 均衡解负载不均。**列粒度（非 bit 粒度）保 bit-parallel 读宽。**
4. TTFS 早终止 = 全局时钟门控（输出侧小优化）。

### J2. 降级/警惕（诚实留痕）
- ❌ **列对齐整列零打包**：真实整列零率 0%，降级（仅 OU-H≤8 行分块 marginal 7-15%，但要放弃单发全列 popcount → go/no-go 偏 no）。
- ⚠ **保序早停/anytime MSB-first（方向C 两 agent 高度收敛：MCBP/SnaPEA/LeOPArd，可证零翻转）= 第一轮"双单调推测"换皮**：用在【输入层发火判定】已被 §F 否决（best-case 14.49/16 bitplane、0% 在 4 项内）；用在【输出层 argmin】可能可行但输出层仅 0.2% cycle、收益绝对值小。**别第三次入坑**；若做只在输出层试、先用真实数据测翻转率。
- ⚠ **novelty 被占**：2511.14202 / 2512.18459（2025）已覆盖"离线 bit-flip+sign-mag+permutation 制造可跳零 slice、write-once 友好"。纯 mapping 创新空间小。真实空白 = **"全数字二值无-ADC 0T1R + TTFS 上的输入侧+位平面双零跳过 + 鲁棒性"组合叙事 + 硅化**。
- ❌ 打假（多 agent 一致）：SCNN/Cambricon-X/SparTen/Eyeriss-v2（值级双边稀疏+复杂索引，batch=1 dense write-once 净负担）；AER 路由（单芯小网纯开销）；逐 bit 跳零 Bitlet/Pragmatic（负载不均砸 bit-parallel）；rate/burst/log 编码（第一层 dense 代价与编码无关）；sorted weight sectioning（收益全在 ADC）。

### J3. 来源（第三轮新增）
BBS 双向 https://arxiv.org/html/2409.05227 · BitWave https://arxiv.org/abs/2507.12444 · 2512.18459 bit-sliced crossbar weight transform · SnaPEA https://cseweb.ucsd.edu/~vakhlagh/ISCA18-SnaPEA.pdf · LeOPArd https://arxiv.org/pdf/2204.03227 · SpiDR https://arxiv.org/abs/2411.02854 · IMPULSE https://arxiv.org/abs/2105.08217 · SpikeCP https://arxiv.org/abs/2305.11322 · sorted weight sectioning https://arxiv.org/html/2410.11298v1

## K. ★★ 实测拍板（2026-06-06，真实主网 gate-init 权重 + 三数据集，go/no-go）— 收敛到"输入侧跳零"单一主力
> 三轮调研后进实测拍板。脚本 `/tmp/feas3.py`（gate-init SNN 真实权重 + Fashion/KMNIST/MNIST，纯统计不改 golden，类比 §F）。**结论极简：唯一真实 cycle 杠杆 = 输入侧跳零（省 73–88%）；权重侧零、BBS 双向在我们 bit-parallel popcount 架构上都不是杠杆。**

### K0. 实测数据（三数据集一致）
| 数据集 | Q1 输入跳零 dense→skip / 省 | Q2 cell零 / 整列零 / 各bit列零 | Q3 weight列可跳(max 0/1) |
|---|---|---|---|
| Fashion | 25088→6640 / **73.5%** | 0.530 / **0.0000** / 全 0 | mean 0.54, min 0.50 |
| KMNIST | 25088→4644 / **81.5%** | 0.531 / **0.0000** / 全 0 | mean 0.54, min 0.50 |
| MNIST | 25088→3028 / **87.9%** | 0.534 / **0.0000** / 全 0 | mean 0.54, min 0.50 |

### K1. ★ 拍板结论
1. ✅ **输入侧跳零 = 唯一真实大杠杆**：三数据集第一层 25088 cycle → **3028–6640（省 73.5–87.9%）**。全数字、不伤鲁棒卖点、真实数据撑（每图非零行 379–830 / 3136）。**这是头号、也基本是全部。**
2. ❌ **权重侧零不是 cycle 杠杆**：cell 零率 53%（复核 D2 一致），但 **整列零率 = 0.0000、各 weight-bit 列零率 = 0**（输入维 784 太长）。"一次读整列 popcount"无法跳单个零 cell；兑现需 bit-serial/行分块 → 砸 bit-parallel 优势。**权重 cell 零是 popcount 免费的、不额外省 cycle。** §J1"权重位平面 skip"在当前 bit-parallel 架构否决。
3. ❌ **BBS 双向不适用**：weight 列 0/1 ≈50/50（min 可跳=0.50，一次读整列跳不了）；input bitplane 已全是 0 多（one-frac 0.12–0.32，直接跳零即可、无需"跳 1"）。BBS 是 bit-serial PE 的招，我们 bit-parallel 用不上。

### K2. ★ 最终收敛（三轮调研 + 实测）
**真正的 PPA 主力 = 输入侧跳零（省 73–88%），把 dense 第一层从 25088 砍到 3000–6600。** 三轮挖出的其余招（列对齐打包 / 权重位平面 skip / BBS / 保序早停 / 低秩 / CSD / LUT-GEMM / time-domain popcount）在真实数据或架构约束下**全部不是杠杆或被否**。
- **诚实大结论**：20+ subagent 调研最大价值 = **排除花招**，收敛到一招朴素"输入跳零"。论文卖点 = **"全数字无 ADC 0T1R + TTFS 上输入跳零的极简数据通路 + 鲁棒性 + 硅化"**，不是某个花哨技巧。
- ⚠ 输入跳零的真实代价（要 RTL 量）：稀疏行索引 / 负载不均（每图非零行数不同 → 变长延迟，**必报 worst-case**）；非零行地址生成逻辑面积。
- ⚠ 跳零的功能是无损的（跳的是加 0）→ **只 RTL（事件行串行 only-nonzero-rows）、对现有 golden bit-exact parity，不改 Python 数值 golden**。

## D. 待办（实测拍板后）
- [x] 三轮调研（§G–§J）+ 实测拍板（§K）：收敛到**输入侧跳零**为唯一真实主力（省 73–88%）。
- [ ] Codex#5（8 subagent，prompt 已发 `V2C_Codex审查_PPA创新调研.md`）回贴 → 两方汇总（我 20+ 路 + Codex 8 路）定最终创新点。
- [ ] **输入跳零进 RTL**：事件行串行（only 非零输入行 + per-bitplane），对现有 golden bit-exact parity（功能不变）；**必报 worst-case cycle**（稀疏行负载不均）。
- [ ] 模块4 多层 top（ramp→output 全链 parity vs eval_ttfs_ramp）。
- [ ] （可选低优先）若要精度换 PPA：单轴降维 or 降比特 + 蒸馏，先 Python 重训守 KMNIST 80%。
- [ ] 每落地一项回填本文档（真实实测 PPA + novelty + 论文角度）。
