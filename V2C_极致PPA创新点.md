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

## D. 待办
- [ ] Codex#4（`V2C_Codex审查_Phase-C-RTL.md`，已修订要求深挖 PPA 创新）回贴 → 把 C1–C6 细化成微架构 + 判 novelty。
- [ ] 实现 C1（row-serial column-parallel）作 PPA-最优数据通路，parity 不变（功能与数据流解耦）。
- [ ] 每落地一个 C 项，回填本文档（PPA 量级 + novelty 判断 + 写论文的角度）。
