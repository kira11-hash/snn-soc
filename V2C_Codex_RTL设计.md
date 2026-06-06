# V2C PPA-最优 RTL 设计 — 深度构思请求（Codex；多 subagent；只读仓库、产出设计 spec、勿改 RTL）

> 读 `~/dev/snn-soc/`：**逻辑主线 `V2C_论文逻辑主线.md`**、**PPA 调研+实测 `V2C_极致PPA创新点.md`**（§A–§L，尤其 §K/§K0b 实测 + §L 双方收敛）、**架构规格 `plan-v1.md`**、现有 RTL `rtl/v2c/`（3 个 bit-exact 基线模块）、Python golden `python_multilayer/v2c/`（`convert.py`/`forward.py`/`encoding.py`/`cost.py`）、RTL 进展 `V2C_RTL进展.md`。

## 0. 任务 + 硬性要求（用户指令，务必照做）
为 V2C 的 **PPA-最优 RTL 数据通路**做深度设计构思，产出**可开工的设计 spec 草案**（只出设计，勿改 RTL）。
- ★ **你必须派多个独立 subagent：4 个设计方面 × 每方面 ≥2 个（共 ≥8），每方面 2 个各自独立构思再 cross-check（暴露分歧、别互抄）。**
- ★ **各方面力求极致 PPA（面积/时序/延迟/能效），允许重构**（别被现有 3 个基线模块锁死），**主动挖架构/数据流/调度/编码等各种可发表创新并标注 novelty（vs 文献）**。
- ★ 全数字、**不伤抗 PVT 鲁棒卖点**；**对现有 Python golden bit-exact parity**（功能不变，只变数据流/时序/面积）；**best + honest 数据都给**（典型 + worst-case）；参考 plan 既定（128-bit 读宽、单宏常驻、P&V FSM、50MHz、三桶评估）。
- ★ 每完成做自检；不拘泥旧结论、发现更极致 PPA / 更大创新就提（哪怕推翻现有基线）。

## 1. 背景 + 已收敛主线（详见仓库，简述）
V2C = 数字二值 0T1R RRAM-CIM + TTFS 加速器（cell 二值、4-bit 权重=4 cell two's-comp、popcount+移位加、**无模拟/无 ADC/无乘法器**、128-bit bit-parallel weight 读宽、RRAM write-once）；MLP 784→246→10；ANN→SNN 解析 gate-init 零训练部署、1-bit 隐层。
- **瓶颈**：dense 第一层占 **99.8%** cycle（dense=25088=in_bits4×stripes8×in_dim784）。
- **已收敛唯一真实主力 = 输入 bit-event 跳零**（§K/§K0b 实测，三数据集 best/mean/worst）：Fashion 6632(mean,省74%)/worst 15784(省37%)；KMNIST 4636(82%)/worst 13416(47%)；MNIST 3320(87%)/worst 8272(67%)。**worst-case 仍省 37-67% → 有界确定性延迟。** 无损（跳的是加 0）→ 只 RTL、不改 golden。
- **已否决/不适用**（别再提为主线）：列对齐整列零打包（真实整列零率=0）、权重位平面 skip（bit-parallel 下整块零=0）、BBS 双向（bit-serial PE 招）、保序早停/双单调推测（输入层 §F 实测 14.49/16 不划算）、time-domain popcount（砸数字卖点）、CSD/LUT-GEMM（4-bit/batch1 净负）。

## 2. 四个设计方面（每方面 ≥2 subagent 独立 + cross-check）
- **A. 输入跳零事件行串行数据通路（核心头号）**：非零输入行检测 + 地址/索引生成、按 bitplane 跳零、128-bit 读宽对齐、负载均衡（每图非零数不同→变长）、**worst-case 有界**、与 ramp 累积 `(t+1)·z1` 融合。怎么在不破坏 bit-exact 的前提下只读非零行？索引/控制开销 vs 跳零收益的净账？
- **B. 数字 CIM MAC 核心**：popcount + shift-add 的面积/时序最优（compressor/adder tree、流水、跨输出/跨层时分复用单份 ALU）。**解当前基线"每 cycle 一个 IN_DIM 位全 popcount → 关键路径长/fmax 受限"**。
- **C. TTFS 神经元 + 决策融合 + 时钟门控**：膜累积、per-output 整数阈值比较、首脉冲锁存、early-exit、**决策藏进累积尾（ITA 式 fusion，不另起决策周期）**、首脉冲一出全局时钟门控。
- **D. 顶层 sequencer + 单宏跨层复用 + 0T1R 读写协同**：ramp→ttfs 多层链、单宏常驻不按层重编程、ping-pong/inter-layer 流水重叠、P&V 写擦验证 FSM 与计算的调度。

## 3. 每方面要回答
微架构（寄存器/流水级划分/关键路径在哪）+ 极致 PPA 取舍 + **创新点（标 novelty vs 文献）** + **worst-case cycle**（数据相关，必报）+ **与 plan/golden 一致性**（怎么保证 bit-exact parity）+ 风险 + 落地步骤。

## 4. 输出格式
**详细 RTL 开工 spec 草案**：分 4 方面，每方面给【2 个 subagent 的独立方案 + 交叉一致/分歧】+ 微架构 + 创新点 + PPA 量级（best+honest）+ parity 方案 + worst-case + 风险；最后给**带优先级的开工路线** + **你认为最该先实现的模块 + 最大的 PPA/novelty 机会**。
我（Claude）这边也并行多 subagent 构思，最后**两方汇总 + 多方审核 + 参考 plan → 合并出最终开工 spec**，再开工。
