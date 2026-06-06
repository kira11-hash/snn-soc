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

## D. 待办
- [x] Codex#4 回贴 → 逐条独立判定（采纳/驳回/降级），见 git + §F。
- [x] 可行性分析选最优方案 → §F：否决 bit-serial 推测，选定异构 co-design + skip-zero。
- [ ] **量化 skip-zero 落地收益**（零行/零位调度的 RTL 微架构 + 实测 cycle 节省，输入瓶颈主杠杆）。
- [ ] 实现异构数据通路（dense-input bit-parallel + skip-zero ‖ event-driven output row-serial），parity 不变（功能与数据流解耦）。
- [ ] 多层 top（模块4：ramp→output 全链 vs eval_ttfs_ramp）作优化数据通路的 parity 基线。
- [ ] 每落地一项回填本文档（PPA 量级 + novelty 判断 + 写论文角度）。
