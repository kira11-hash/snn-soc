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
| TIMESTEPS | 3 | 工程默认（精度/时延性价比最优；论文可用 T=10 做高精度对照） |
| THRESHOLD_RATIO | 4 | ratio_code，对应 THRESHOLD_DEFAULT=3060 |
| THRESHOLD_DEFAULT | 3060 | = 4 × 255 × 3 |
| NEURON_DATA_WIDTH | 9 | signed 9-bit（Scheme B 差分输出）|

## 寄存器地址表（快速参考，权威以 doc/02_reg_map.md 为准）

> 注意：不同外设有不同基地址，不要把 offset 混成同一张表。

### REG_BANK（基地址 `0x4000_0000`）

| 绝对地址 | offset | 名称 | 说明 |
|------|------|------|------|
| 0x4000_0000 | 0x00 | REG_THRESHOLD | LIF 阈值（default 3060） |
| 0x4000_0014 | 0x14 | CIM_CTRL | [0]=START(W1P), [1]=SOFT_RESET(W1P), [7]=DONE(W1C) |
| 0x4000_0018 | 0x18 | STATUS | [0]=BUSY, [4:1]=FIFO 标志, [15:8]=TIMESTEP_CNT |
| 0x4000_0024 | 0x24 | REG_THRESHOLD_RATIO | 8-bit ratio_code（default 4，shadow） |
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
- 结果：diff = 100，T=3 即可观察到 LIF 累加 → OUT_FIFO_COUNT > 0 = 数字链路正常
- MUX 逻辑：`bl_sel < NUM_OUTPUTS ? cim_test_data_pos : cim_test_data_neg`

## Scheme B 差分（核心架构决策）

- 20路 ADC 通道：ch 0-9 = pos列，ch 10-19 = neg列
- 数字侧计算：`diff[i] = raw[i] - raw[i+10]`（signed 9-bit）
- 这是确定方案（A1），不可改回 Scheme A

## 仿真环境

- **完整仿真**：Linux + VCS + Verdi（入口：`sim/run_vcs.sh`）
- **本地轻量**：Icarus（`cd sim && bash run_icarus_light.sh`）
- **通过标准**：`LIGHT_SMOKETEST_PASS`，OUT_FIFO_COUNT=20（非零即可）
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

## 当前迭代路径（顺序固定，不可跳步）

1. **AXI-Lite 基础骨架** ✅（进行中）：`axi_lite_if` + `axi2simple_bridge` + AXI TB（T1~T9）已完成；下一步是 `axi_lite_interconnect` 与 `snn_soc_top.sv` 集成。
2. **UART**：最小可用（TX/RX + 状态寄存器），用于 bring-up 打印日志。
3. **SPI Master** ✅（分支完成）：`spi_ctrl` + Flash model + TB 已完成（9/9 PASS）；下一步是主线 `spi_stub` 替换与顶层集成。
4. **DMA 扩展**：先打通 SPI → SRAM，再 SRAM → input_fifo，每条路径单独写 TB，确认 done/err/busy。
5. **E203 最后接入**：先跑最小固件（UART 打印 → SPI 读 → DMA 搬运），出问题容易定位。

## 不可修改事项（除非用户明确授权）

- 不可修改上表中任何定版参数。
- 不可删除 `ifndef SYNTHESIS` / `ifdef VCS` 宏保护。
- 不可将 Scheme B 改回 Scheme A。
- 不可提交或执行 force push 到 `main` 分支。
- 工程默认 T=3（精度/时延最优折中）；论文可附加 T=10 作为高精度对照档位（做 trade-off 图）。
