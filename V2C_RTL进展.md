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
| 2 | TTFS-IF neuron/layer（积分+整数阈值+首spike早停）| `rtl/v2c/v2c_ttfs_layer.sv` | `forward.ttfs_layer_forward` | ⬜ |
| 3 | ramp bit-serial 输入层 | — | `convert.eval_ttfs_ramp` 第一层 | ⬜ |
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
