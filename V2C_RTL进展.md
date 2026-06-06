# V2C RTL 进展 + 自审记录（Phase C，2026-06-06 起）

> 按 plan-v1.md 架构，全 fork 新建（不碰 V2.B：`rtl/snn/`、`rtl/top/snn_soc_v2b_top` 等原地不动）。
> V2C RTL 放 `rtl/v2c/`，TB 放 `tb/v2c/`，sim 脚本/产物放 `sim/v2c/`。
> **方法**：每模块 → iverilog parity 对齐 Python golden（bit-exact，理想模式）→ 严苛自审 → commit。
> DC（SMIC55nm 库）/FPGA（ZCU102/Vivado）由用户在其服务器/硬件跑；我出 RTL + parity + 脚本。
> 工具：iverilog 13.0 + verilator 本地可用。

## 模块状态
| # | 模块 | 文件 | parity 对齐 | 状态 |
|---|---|---|---|---|
| 1 | 数字 CIM MAC（popcount→shift-add codebook）| `rtl/v2c/v2c_cim_mac.sv` | `encoding.mac`（W=1/2/4/8 + 784/W4 + 边界）| ✅ bit-exact |
| 2 | TTFS-IF neuron/layer（积分+整数阈值+首spike早停）| `rtl/v2c/v2c_ttfs_layer.sv` | `forward.ttfs_layer_forward` | ✅ bit-exact（LANES 待加）|
| 3 | ramp bit-serial 输入层 | `rtl/v2c/v2c_ramp_layer.sv` | `convert._ramp_hidden_times`（z1+hid时间）| ✅ bit-exact |
| 4 | 多层链接/sequencer | — | `forward.multilayer_ttfs_forward` | ⬜ |
| 5 | 非理想注入（LFSR/ROM）| — | 理想模式==golden；故障模式 vs `robustness` | ⬜ |
| 6 | P&V FSM（V2C fork）| — | — | ⬜ |
| 7 | `snn_soc_v2c_top` | — | 完整 TTFS-MLP 若干样本 vs golden | ⬜ |

---

## 模块 1：v2c_cim_mac（数字 CIM MAC）— ✅
**功能**：给定一个逻辑输出的 W 个 bit-plane 列 + 当拍 active spike 向量，算有符号 partial sum。`col k = cells_flat[k*IN_DIM +: IN_DIM] == python cells[:, out*W+k]`。codebook：W=1 `2·pc0−popcount(spikes)`；W=2 `pc_pos−pc_neg`；W≥4 `Σ2^k·pc_k`，MSB 取负。纯组合。

**parity**：`sim/v2c/run_cim_mac.sh`（gen 向量←`encoding.mac` → iverilog → 比对）。W∈{1,2,4,8}@IN_DIM=64 各 156 向量 + 生产 IN_DIM=784/W=4 72 向量，**全 bit-exact**。含确定性边界：全0/全1/交替 spike × 极值权重(max+/min)。

**严苛自审**：
- ✅ 正确性：bit-exact 对齐 golden，含边界（accumulator 范围 + 符号/MSB-negate 都覆盖）。
- ✅ 可综合：`always @*` 组合、显式 popcount（综合器推 adder tree）、part-select `+:`、无 latch（psum 全分支赋值）、`default_nettype none`。W 是 parameter → 静态 elaborate 单分支。
- ✅ 范围：PSUM_W 默认 20，覆盖到 IN_DIM=1024/W=8（max |psum|=128·1024=131072 < 2^19）。
- ✅ PPA 定位：此为**单输出原语**。宏级 PPA（128-bit 读宽=32 输出/stripe 的时分复用、跨层单份 ALU 复用）在累积/sequencer 模块实现，不在此并行铺 256 份。popcount 树是主组合成本，综合器优化。
- 📌 后续可选：popcount 用显式 compressor tree 控时序（先交综合器推）；MSB-negate 的 two's-comp 已验，ternary (1,1) illegal 由上层 pack 保证不产生（非理想路径的 (1,1)→0 由差分式天然处理，计数在 Python 侧）。

## 模块 2：v2c_ttfs_layer（TTFS-IF FC 层）— ✅（LANES 待加）
**功能**：每 timestep 用 v2c_cim_mac 累积膜电位，per-output 整数阈值，首 spike 锁存时间，early_exit 在首个有 spike 的 timestep 末停。FSM（IDLE/RUN/DONE），1 输出/cycle 时分复用单份 MAC。memories（cells/spike/thr）行为级（TB $readmemh；硅上 cells=RRAM 宏、spike/θ=BRAM）。
**parity**：`sim/v2c/run_ttfs_layer.sh`，18 帧 **bit-exact**（spike_times + membrane + n_steps）：W∈{1,2,4}、early_exit on/off、生产输出层 IN=784/OUT=10/W4/T16。
**严苛自审**：
- ✅ 正确性：18 帧 bit-exact，覆盖 fire/no-fire（spike_time=T→Python −1）、早停、首输出即发的边界（`any_fired || will_fire`）。
- ✅ 可综合：FSM 寄存器化、membrane/stime/fired regfile（OUT_DIM 份 flop，OUT=246 ~8k flop）、无 latch（全 cased）。cells_mem 行为级=parity 模型，硅上是宏读出（W 读/cycle → 宏读宽/调度在宏集成步）。
- ⚠ **PPA/延迟关键**：当前 **1 输出/cycle**（面积最优、单 MAC），延迟 = OUT_DIM×T cycle（隐层 246×16≈3936，输出 10×16=160）。**plan-v1.md 要 128-bit 读宽 = 32 输出/stripe（W=4）**——加 `LANES` 并行（32 输出/cycle）可把隐层降到 ~8 stripe×16≈128 cycle。**功能 parity 与 LANES 无关**（只变 cycle 数）→ 下一增量加 LANES 并复跑 parity。这是"延迟最低"的主旋钮。
- ✅ 范围：MEM_W=28 / PSUM_W=22 覆盖 T·max|psum|。membrane 有符号、阈值正。

## 模块 3：v2c_ramp_layer（ramp 多比特输入层）— ✅
**功能**：Phase A bit-serial：`z1[o]=Σ_k 2^k·mac(bitplane_k, w_o)`（输入无符号多比特→无输入侧 MSB 取负；权重符号在 MAC codebook 内）。Phase B ramp TTFS：`membrane(t)=(t+1)·z1`，首 t 满足 `(t+1)·z1≥θ` 发放（z1>0），divide-free（每拍 +z1）。时分复用单 MAC。
**parity**：`sim/v2c/run_ramp_layer.sh`，14 帧 **bit-exact**（z1 + hidden spike_times），W∈{1,2,4}、IN/OUT 多尺寸。z1（Phase A）与 spike_times（Phase B）独立校验。
**严苛自审**（★抓到 1 个真 bug）：
- 🐛→✅ **bug 修复（留痕）**：初版给 ramp 层加了 early_exit（any-fired 停），但 **ramp=输入/隐层，必须算出所有隐层 spike 时间喂下一层**，golden `_ramp_hidden_times` 无早停 → early_exit=1 时 2 处 mismatch。**修：ramp 层恒 full-frame，去掉 early_exit；首 spike 早停只属输出层（v2c_ttfs_layer）**。per-neuron `fired` 锁存（单 spike）保留。复跑全 PASS。
- ✅ 正确性：14 帧 bit-exact，z1 范围/符号 + 发放早/中/晚/不发 全覆盖。
- ✅ 可综合：两相 FSM、无 latch、复用 MAC、Z_W/MEM_W 覆盖 Σ2^k·mac 与 T·z1。
- 📌 PPA：同 row-serial column-parallel 优化方向（见下）。z1 计算可与宏读出融合。

## ★ PPA 架构说明（DC 阶段关键，Codex 待审）
当前 3 个 compute 模块**功能 bit-exact 对齐 Python**（理想模式 RTL==golden），数据通路是 **1 输出/cycle 时分复用单 MAC**（面积小、单份），但每 cycle 一个 **IN_DIM 位全 popcount** → **关键路径长（fmax 受限）+ 延迟=OUT×(T 或 in_bits) cycle**。
**plan-v1.md 的 PPA-最优架构 = 事件行串行 + 列并行单bit累加**：激活的 spiking 行串行（事件驱动，稀疏→cycle 少）、每次读 128-bit 读宽（W=4→32 输出×4 bitplane 的列并行），每 active row 对各输出做 **单 bit 累加**（无每输出全 popcount 树）→ **关键路径短(fmax 高)、面积省(无大 popcount 树)、延迟随有效 spike + 早停**。
→ **下一 RTL 增量 = 把数据通路改成 row-serial column-parallel（功能 parity 不变，只变 cycle/时序/面积）**；这是"时序最优延迟最低"的主架构，建议 Codex 审 + DC 量化。cost.py 已给 projected_cycles 公式。
**★ 极致 PPA 创新（论文 contribution 候选）专门记在 `V2C_极致PPA创新点.md`**——当前 3 模块是基线（非 novelty），论文级 PPA 创新（C1 事件行串行列并行、C2 决策藏进累积/ITA 式 fusion、C3 流水重叠…）在接下来的 RTL，Codex#4 prompt 已要求深挖。
**剩余模块**：多层 top（ramp→ttfs 链，parity vs eval_ttfs_ramp 全程）、非理想注入（LFSR/ROM）、P&V FSM、snn_soc_v2c_top、DC/FPGA 脚本（用户跑）。
