# CLAUDE.md — SNN SoC 项目关键约束

## ⚠️ 必读规则（每次发言前强制执行）

**每次发言之前，必须先说"嘿嘿"，无一例外。**

---

## 项目核心参数（绝不可改动，除非用户明确要求）

| 参数 | 值 | 说明 |
|------|----|------|
| NUM_INPUTS | 64 | 8×8 输入，已改（原 7×7=49）|
| ADC_BITS | 8 | 8-bit ADC，6-bit 留 V2 |
| ADC_CHANNELS | 20 | Scheme B 差分，20路 |
| PREPROCESS | avgpool8x8 | 当前默认离线压缩/预处理方式；RTL 仅冻结 64x8 接口 |
| TIMESTEPS | 10 | 工程冻结默认（ADC=8 / W=4 / ratio=1/255） |
| THRESHOLD_RATIO | 1 | ratio_code，对应 THRESHOLD_DEFAULT=2550 |
| THRESHOLD_DEFAULT | 2550 | = 1 × 255 × 10 |
| NEURON_DATA_WIDTH | 9 | signed 9-bit（Scheme B 差分输出）|

## 寄存器地址表（快速参考，权威以 doc/02_reg_map.md 为准）

> 注意：不同外设有不同基地址，不要把 offset 混成同一张表。

### REG_BANK（基地址 `0x4000_0000`）

| 绝对地址 | offset | 名称 | 说明 |
|------|------|------|------|
| 0x4000_0000 | 0x00 | REG_THRESHOLD | LIF 阈值（default 2550） |
| 0x4000_0014 | 0x14 | CIM_CTRL | [0]=START(W1P), [1]=SOFT_RESET(W1P), [7]=DONE(W1C) |
| 0x4000_0018 | 0x18 | STATUS | [0]=BUSY, [4:1]=FIFO 标志, [15:8]=TIMESTEP_CNT |
| 0x4000_0024 | 0x24 | REG_THRESHOLD_RATIO | 8-bit ratio_code（default 1，shadow） |
| 0x4000_002C | 0x2C | REG_CIM_TEST | [0]=test_mode, [15:8]=test_data_pos, [23:16]=test_data_neg |

### DMA（基地址 `0x4000_0100`）

| 绝对地址 | offset | 名称 | 说明 |
|------|------|------|------|
| 0x4000_0100 | 0x00 | DMA_SRC_ADDR | DMA 源地址 |
| 0x4000_0104 | 0x04 | DMA_LEN_WORDS | DMA 长度（单位：32-bit word） |
| 0x4000_0108 | 0x08 | DMA_CTRL | [0]=START(W1P), [1]=DONE(W1C), [2]=ERR(W1C), [3]=BUSY(RO) |

## CIM Test Mode（流片后自检关键）

- `test_mode=1` → 绕过模拟 CIM 宏，可在无模拟芯片情况下验证数字链路
- 写法：`wstrb=4'b0111`，`data=32'h0000_6400`（pos=0x64=100，neg=0）
- 结果：diff = 100，T=10 即可观察到 LIF 累加 → OUT_FIFO_COUNT > 0 = 数字链路正常
- MUX 逻辑：`bl_sel < NUM_OUTPUTS ? cim_test_data_pos : cim_test_data_neg`

## Scheme B 差分（核心架构决策）

- 20路 ADC 通道：ch 0-9 = pos列，ch 10-19 = neg列
- 数字侧计算：`diff[i] = raw[i] - raw[i+10]`（signed 9-bit）
- 这是确定方案（A1），不可改回 Scheme A

## 仿真环境

- **黑盒 Icarus**（test mode，无权重）：`cd sim && bash run_icarus_light.sh`，通过标准：`LIGHT_SMOKETEST_PASS`
- **带权重 Icarus**（真实权重 hex）：`cd sim && bash run_icarus_weighted.sh`，通过标准：`WEIGHTED_SIM_PASS` + `OUT_FIFO_COUNT > 0`
- **VCS + Verdi**（SVA 断言 + 波形）：Linux，`+define+VCS`，通过标准：`WEIGHTED_SIM_PASS` + 零 assertion failure
- SVA 断言在 `` `ifdef VCS `` 内，Icarus 用 `-gno-assertions` 跳过

## 文件编码注意

- `SNNSoC工程主文档.md` 含 `\xa0`（non-breaking space），Edit 工具无法匹配时改用 Python 脚本
- 部分 `.sv` 文件有 UTF-8 BOM，注意编辑器设置

## AXI-Lite 分支状态（feature/axi-lite，2026-03-01）

- **已完成**：`rtl/bus/axi_lite_if.sv`（接口定义）、`rtl/bus/axi2simple_bridge.sv`（5态 FSM 桥接）
- **已完成**：`tb/axi_bridge_tb.sv`（T1~T9，含字节写使能、AW/W错拍与B/R背压测试）、`sim/sim_axi_bridge.f`、`sim/run_axi_bridge_icarus.sh`
- **待做**：`rtl/bus/axi_lite_interconnect.sv`（可选，E203 接入前不急）、集成进 `snn_soc_top.sv`
- 运行测试：`cd sim && bash run_axi_bridge_icarus.sh`，通过标准：`AXI_BRIDGE_SMOKETEST_PASS`
- 桥时序：写/读均为 2 cycle（IDLE→PEND→RSP），bus_simple 固定 1-cycle 响应与之匹配

## SPI 分支状态（feature/spi，2026-03-02）

- **已完成**：`rtl/periph/spi_ctrl.sv`（SPI Master，Mode0，MSB first）
- **已完成**：`tb/spi_flash_model.sv`、`tb/spi_tb.sv`（T1~T4+T1b，9/9 PASS）
- **已完成**：`sim/sim_spi.f`、`sim/run_spi_icarus.sh`（Icarus 独立回归入口）
- **已完成**：`clk_div` 安全钳位与 50MHz 频率口径修正（分支文档与实现一致）
- **待做**：`snn_soc_top.sv` 中 `spi_stub` → `spi_ctrl` 集成（主线仍为 stub）

## 完整工作流（Python 定参 → 外设集成）

### Phase 1: Python 定参数

- **Step 1.1**：`python run_all.py`（全网格 ≈ 52,920 组合，约 12-24h）
- **Step 1.2**：读 `results/summary.txt` 锁定 `method / ratio_code / ADC / W / T / reset`；确认 `results/exports/weight_export_manifest.json`
- **Step 1.3**（可选）：若最优 ratio 卡在边界，加密候选后 `--skip-train` 重跑（约 2h）
- **Step 1.4**：确认 `results/exports/` 下有 `weight_pos.hex`、`weight_neg.hex`、`weight_map*.csv`
- **Step 1.5**：备份 `results/`、`weights_full/`、`backups/`、`full_run.log`

### Phase 2: RTL 参数同步（只改数值，不改逻辑）

- **Step 2.1**：改 `snn_soc_pkg.sv` — `THRESHOLD_RATIO_DEFAULT`、`THRESHOLD_DEFAULT = ratio_code × 255 × T`、`TIMESTEPS_DEFAULT`
- **Step 2.2**：若推荐 `reset_mode=hard`，在 TB 初始化加 `bus_write(REG_RESET_MODE, 32'h1, 4'h1)`（light TB + weighted TB）
- **Step 2.3**：`grep -rn` 全项目确认参数一致性，更新所有文档旧值
- **Step 2.4**：每次改完 GPT + Claude 双重审查：参数 / Python / RTL / TB / 文档一致性

### 模拟 CIM macro 同步时机

- **第一次正式同步**：Step 3.1 + 3.2 过了之后。参数已从 Python 落到 RTL 且 smoke 没炸，发 `doc/11_analog_handoff_execution_plan.md` + `doc/08_cim_analog_interface.md` 为主，附 `summary.txt` + `snn_soc_pkg.sv`。若 THRESHOLD/TIMESTEPS/RESET_MODE 改了，带上 `doc/02_reg_map.md`。
- **第二次确认同步**：Step 3.4 过了之后。告知对方参数已过 Python↔RTL 数值对齐，属强冻结版本。
- **不要在** `run_all.py` 还没跑完或 RTL 还没同步前正式发参数文档。

### Phase 3: 仿真三级递进

- **Step 3.1 黑盒 Icarus**：`run_icarus_light.sh` → `LIGHT_SMOKETEST_PASS`
- **Step 3.2 带权重 Icarus**：`run_icarus_weighted.sh` → `WEIGHTED_SIM_PASS` + `OUT_FIFO_COUNT > 0` + 改 threshold 后输出变化合理 + 重跑结果稳定
- **Step 3.3 VCS/Verdi**：`run_vcs_weighted.sh` → `WEIGHTED_SIM_PASS` + 零 assertion failure + 波形检查（wl_spike / bl_data / diff / membrane / spike）
- **Step 3.4 ★Python↔RTL 数值对齐★（开闸点）**：
  - 前提：recommendation 冻结 + weight hex 导出 + weighted Icarus + VCS 均已通过
  - Python 侧：`export_mnist_bitplane_hex.py` 导出 10 样本激励 + 补写预期 spike_id 导出脚本
  - TB 侧：补写 sample-alignment TB，`$readmemh` 加载样本 hex，跑完对比 spike_id
  - bit-plane 顺序：导出 hex 每帧 8 行，bit7（MSB）在前 bit0（LSB）在后，TB 按此顺序写入 data_sram
  - 通过标准：10/10 样本 spike_id 完全一致；不一致时按 ADC→diff→membrane→threshold→bit-plane 顺序排查
  - **此步未过，不进 Phase 4**
- **Step 3.5**（可选）：扩到 100 样本 batch 回归
- **Step 3.6**：每通过一个子阶段，GPT + Claude 双重审查

### Phase 4: 外设集成（顺序固定，每步双回归）

1. **AXI-Lite**：`axi_lite_interconnect` → `snn_soc_top` 集成 → AXI bridge TB → 黑盒 smoke → 带权重仿真
2. **UART**：`uart_stub` → `uart_ctrl` → UART TB → 黑盒 smoke → 带权重仿真
3. **SPI**：`spi_stub` → `spi_ctrl` → SPI TB → 黑盒 smoke → 带权重仿真
4. **DMA 扩展**：SPI→SRAM + SRAM→input_fifo 各通路独立 TB → 黑盒 smoke → 带权重仿真
5. **E203 接入**：最小固件（UART 打印 → SPI 读权重 → DMA 搬运 → CIM 推理）→ 端到端验证 → 双回归
- 每步完成后 GPT + Claude 双重审查，确认控制链 + 推理链无回归

### 核心原则

- 先定参数再改 RTL，先黑盒再 weighted 再 VCS
- Python↔RTL 对齐是开闸点，没过不进外设集成
- 每次关键修改后双重审查：参数 / 文档 / 脚本一致性

## 不可修改事项（除非用户明确授权）

- 不可修改上表中任何定版参数。
- 不可删除 `ifndef SYNTHESIS` / `ifdef VCS` 宏保护。
- 不可将 Scheme B 改回 Scheme A。
- 不可提交或执行 force push 到 `main` 分支。
- 当前工程默认 T=10（ADC=8 / W=4 / ratio=1/255 冻结配置）；如需 trade-off，可额外比较其他 T。
