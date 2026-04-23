# CLAUDE.md — SNN SoC 项目关键约束

> 注：文档内 `feature/axi-lite` / `feature/spi` 相关条目是历史分支快照；当前 `main` 检出默认不包含这些独立 TB、filelist 和运行脚本。

## ⚠️ 必读规则（每次发言前强制执行）

**每次发言之前，必须先说"嘿嘿"，无一例外。**

---

## 工作原则

### 卡住时的处理流程（最多尝试 3 次）

同一个问题最多尝试 3 次，超过后必须停下来重新评估，不要盲目重试：

1. **记录失败**：写下尝试了什么、报错是什么、为什么认为会失败
2. **寻找替代路径**：找 2-3 种不同方向，看看有无更简单的角度
3. **质疑前提**：是不是抽象层级选错了？能不能拆分成更小的问题？
4. **换角度重来**：换工具、换模式、或者直接去掉那层抽象

### 决策框架

多个方案都可行时，按以下优先级选择：

1. **可验证性** — 能不能仿真/测试验证？
2. **可读性** — 6 个月后的自己还能看懂吗？
3. **一致性** — 和现有项目风格匹配吗？
4. **简单性** — 这是能跑通的最简单方案吗？
5. **可逆性** — 改错了多难回头？

### 禁止行为

- **绝不**使用 `--no-verify` 跳过 commit hook
- **绝不**在没有读过文件的情况下修改它
- **绝不**对现有逻辑做假设——不确定就先读代码确认
- **绝不**删除或禁用已有的仿真检查来掩盖问题
- **绝不**在参数、文档、RTL、TB 之间做不一致的修改

### 查阅库文档

需要查 API 用法、配置步骤或库文档时，优先使用 Context7 MCP 工具自动获取，不要依赖训练数据里的过时信息。

---

## RTL 漏洞报告规范（强制）

### 报告漏洞时必须同步生成仿真激励

每当 AI 报告一个 RTL 设计缺陷（bug、timing 问题、协议违例、断言失败等），**必须同时提供一段能够在仿真中触发该缺陷的具体激励**，格式如下：

```
【缺陷描述】<问题是什么，在哪个模块哪一行>
【触发条件】<需要满足什么前提状态>
【仿真激励】<具体的 SystemVerilog/Verilog 操作序列，或等价的 bus_write/信号赋值步骤>
【预期异常现象】<运行后应该看到什么错误信号、波形或断言失败>
```

**如果无法写出能触发该缺陷的具体激励，则该报告不得作为"确认 bug"提交，应直接标记为疑似误报，等待人工确认。**

### 误报自动标记流程

若提供的激励经过仿真验证后**无法复现**所描述的问题（即仿真正常通过、无异常信号），则：

1. 将该警报状态改为 `[误报]`
2. 记录误判原因（见下方经验知识库）
3. **不得**据此修改任何 RTL 源码

---

## 误报经验知识库（持续更新）

> 本节记录历史上被确认为误报的 AI 警报模式，防止重复误判。每次新增误报后必须在此追加。

### 已确认误报模式

#### FP-001：有符号移位运算误判（2026-04 确认）
- **误判描述**：AI 报告 `lif_neurons.sv` 中 `<<<` 算术左移对有符号数处理有误，认为符号扩展不正确
- **实际情况**：`$signed(neuron_in_data[i])` 后赋值给 `MEM_W` 位宽的有符号中间变量，再执行 `<<<`，完全符合 SV LRM §6.24.1 规范，符号扩展由编译器正确处理
- **根本原因**：AI 未读完完整赋值链，仅看到移位操作就下结论
- **识别规则**：凡涉及 `$signed()` + 类型转换 + `<<<` 的组合，**必须追踪完整赋值链并对照 SV LRM §6.24.1**，不可仅凭局部代码片段报告

#### FP-002：输出 FIFO 位宽不足误判（2026-04 确认）
- **误判描述**：AI 报告 output FIFO 的 `WIDTH=4` 不足以存储神经元编号，可能溢出
- **实际情况**：`NUM_OUTPUTS=10`（0-9），4-bit 足以表示（最大值 9 = `4'b1001`），无溢出风险
- **识别规则**：报告位宽不足前，**必须先查 `snn_soc_pkg.sv` 中的 `NUM_OUTPUTS` 实际值**，结合 $clog2 计算后再下结论

#### FP-003：DMA 地址指针回退误判（2026-04 确认）
- **误判描述**：AI 报告 `dma_engine.sv` 中 ST_WR 状态写地址使用 `addr_ptr - 32'd4`，认为会写到错误地址
- **实际情况**：`addr_ptr` 在 ST_RD1 中已以非阻塞赋值递增，ST_WR 同拍读取的是递增前的旧值，`-4` 是对此行为的补偿，设计正确
- **识别规则**：分析 FSM 状态机中的地址/指针计算时，**必须区分阻塞赋值（=）和非阻塞赋值（<=）的时序语义**，不可混淆

#### FP-004：零长度 DMA 误判（2026-04 确认）
- **误判描述**：AI 报告当 `DMA_LEN_WORDS=0` 时 DMA 会进入异常状态
- **实际情况**：零长度 DMA 是有意设计的 no-op，直接跳转到 DONE 状态，属于合理的边界处理
- **识别规则**：报告边界条件问题前，**必须先确认该边界是否已在设计文档或注释中明确定义为合法输入**

#### FP-005：单时钟域 CDC 误判（2026-04 确认）
- **误判描述**：AI 报告 FIFO 模块存在跨时钟域（CDC）问题
- **实际情况**：`fifo_sync.sv` 是同步 FIFO，整个 SoC 数字部分为单时钟域（`clk`），不存在 CDC 问题；JTAG 的 `jtag_tck` 跨域已有专门的 toggle + 2-FF sync 处理
- **识别规则**：报告 CDC 问题前，**必须先确认该模块是否真的存在多个时钟域**；对于 `fifo_sync` 这类名称中含 `sync` 的模块，默认假设为单时钟

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

### CIM 编程寄存器（基地址 `0x4000_0000`，2026-04-22 从 v2 移植）

> 仅在 `snn_soc_top.ENABLE_PROGRAM_MODE=1` 时真正连接到 cim_program_ctrl；
> 默认参数下（=0）寄存器存在但写入无任何硬件副作用。

| 绝对地址 | offset | 名称 | 说明 |
|------|------|------|------|
| 0x4000_0038 | 0x38 | PROG_CTRL | [0]=START(W1P), [1]=ERASE(RW), [2]=FULL_ARRAY(RW), [7:4]=LEVEL(RW), [10:8]=RETRY_LIMIT(RW) |
| 0x4000_003C | 0x3C | PROG_ROW | [5:0]=目标行（0~63） |
| 0x4000_0040 | 0x40 | PROG_COL | [4:0]=目标列（0~19） |
| 0x4000_0044 | 0x44 | PROG_STATUS | [0]=BUSY(RO), [1]=PASS(RO), [2]=FAIL(RO), [5:3]=RETRY_COUNT(RO), [7]=DONE(W1C) |
| 0x4000_0090 | 0x90 | PROG_PULSE_WIDTH | [17:16]=写入脉冲档位 RW（0=1us/1=10us/2=100us/3=保留按100us），[15:0]=resolved cycles RO（default=50=1us@50MHz） |
| 0x4000_0094 | 0x94 | PROG_ERASE_WIDTH | [15:0]=擦除脉冲宽度 RO（固定 50000=1ms@50MHz，逐 cell 与全阵列擦除共用，写入忽略） |

### DMA（基地址 `0x4000_0100`）

| 绝对地址 | offset | 名称 | 说明 |
|------|------|------|------|
| 0x4000_0100 | 0x00 | DMA_SRC_ADDR | DMA 源地址 |
| 0x4000_0104 | 0x04 | DMA_LEN_WORDS | DMA 长度（单位：32-bit word） |
| 0x4000_0108 | 0x08 | DMA_CTRL | [0]=START(W1P), [1]=DONE(W1C), [2]=ERR(W1C), [3]=BUSY(RO) |
| 0x4000_010C | 0x0C | DMA_DST_SEL | [1:0] 目标选择：0=INPUT_FIFO, 1=WEIGHT_SRAM, 2=INSTR_SRAM; 3=非法; IDLE时可写 |

## CIM Test Mode（流片后自检关键）

- `test_mode=1` → 绕过模拟 CIM 宏，可在无模拟芯片情况下验证数字链路
- 写法：`wstrb=4'b0111`，`data=32'h0000_6401`（pos=0x64=100，neg=0，bit[0]=test_mode=1）
- 结果：diff = 100，T=10 即可观察到 LIF 累加 → OUT_FIFO_COUNT > 0 = 数字链路正常
- MUX 逻辑：`bl_sel < NUM_OUTPUTS ? cim_test_data_pos : cim_test_data_neg`

## Scheme B 差分（核心架构决策）

- 20路 ADC 通道：ch 0-9 = pos列，ch 10-19 = neg列
- 数字侧计算：`diff[i] = raw[i] - raw[i+10]`（signed 9-bit）
- 这是确定方案（A1），不可改回 Scheme A

## Pad 预算 + 外部编程合同（tape-out 口径，2026-04-24 冻结）

- **总 pad 数：55**（之前 48，2026-04-24 扩 +7 给外部编程接口）
  - 52 usable signal + 6 power/ground + 3 ESD-reserved
  - 权威：`doc/15_asic_pad_map.md`
- **外部编程方案：α'**（7 new D→A pads）
  - `prog_op[2:0]` (pads 46..48) 编码 inference/erase/write/verify/full_array_erase
  - `prog_level[3:0]` (pads 49..52) 目标电导等级，write 时有效
  - verify PASS/FAIL 由数字侧比对 `bl_data` 自己算，不需要 `prog_pass` pad
  - 详细协议：`doc/08_cim_analog_interface.md` §10 + `doc/03_cim_if_protocol.md` 末节
- RTL 入口：`rtl/top/snn_soc_top.sv` 的 `prog_op_ext` / `prog_level_ext` 编码器 + `rtl/top/chip_top.sv` pad 路由

## 仿真环境

- **黑盒 Icarus**（test mode，无权重）：`cd sim && bash run_icarus_light.sh`，通过标准：`LIGHT_SMOKETEST_PASS`
- **带权重 Icarus**（真实权重 hex）：`cd sim && bash run_icarus_weighted.sh`，通过标准：`WEIGHTED_SIM_PASS` + `OUT_FIFO_COUNT > 0`
- **VCS + Verdi**（SVA 断言 + 波形）：Linux，`+define+VCS`，通过标准：`WEIGHTED_SIM_PASS` + 零 assertion failure
- **CIM 编程 FSM**：`bash run_cim_program_ctrl.sh` → `CIM_PROGRAM_CTRL_PASS`（8 个子测试）
- **编程脉宽寄存器**：`bash run_prog_pulse_cfg.sh` → `PROG_PULSE_CFG_TB_PASS`（4 档 preset + erase fixed）
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
  - Python 侧：`export_mnist_bitplane_hex.py`/`export_expected_spike_ids.py` 生成正式 100 样本激励（MNIST test split，每类前 10 个，class-major）
  - TB 侧：补写 sample-alignment TB，`$readmemh` 加载样本 hex，跑完对比 spike_id
  - bit-plane 顺序：导出 hex 每帧 8 行，bit7（MSB）在前 bit0（LSB）在后，TB 按此顺序写入 data_sram
  - 通过标准：100/100 样本 predicted_class 完全一致；不一致时按 stimulus/manifest → TB 流程 → FIFO pop/read → ADC→diff→membrane→threshold→bit-plane 顺序排查
  - **此步未过，不进 Phase 4**
- **Step 3.5**：正式 100 样本 batch 回归与资产固化
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
