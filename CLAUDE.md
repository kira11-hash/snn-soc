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
| TIMESTEPS | 10 | 定版，勿改 |
| THRESHOLD_RATIO | 4 | ratio_code，对应 THRESHOLD_DEFAULT=10200 |
| THRESHOLD_DEFAULT | 10200 | = 4 × 255 × 10 |
| NEURON_DATA_WIDTH | 9 | signed 9-bit（Scheme B 差分输出）|

## 寄存器地址表（关键寄存器）

| 地址 | 名称 | 说明 |
|------|------|------|
| 0x00 | DMA_CTRL | [0]=START(W1P), [1]=DONE(R/W1C) |
| 0x04 | DMA_SRC | DMA 源地址 |
| 0x08 | DMA_LEN | DMA 长度（单位：word） |
| 0x10 | CIM_CTRL | [0]=START(W1P), [7]=DONE(R/W1C) |
| 0x14 | CIM_STATUS | [0]=err_sticky |
| 0x20 | REG_THRESHOLD | LIF 阈值（default 10200）|
| 0x24 | REG_THRESHOLD_RATIO | 8-bit ratio_code（default 4）|
| 0x2C | REG_CIM_TEST | [0]=test_mode, [15:8]=test_data_pos, [23:16]=test_data_neg |

## CIM Test Mode（流片后自检关键）

- `test_mode=1` → 绕过模拟 CIM 宏，可在无模拟芯片情况下验证数字链路
- 写法：`wstrb=4'b0111`，`data=32'h0000_6400`（pos=0x64=100，neg=0）
- 结果：diff = 100，T=10 → LIF 累加 → OUT_FIFO_COUNT > 0 = 数字链路正常
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

## 当前迭代路径（顺序固定，不可跳步）

1. **AXI-Lite 基础骨架**：`axi_lite_if` + `interconnect` + `axi2simple_bridge`，用 TB master 验证读写通路。E203 后续所有接入都依赖它。
2. **UART**：最小可用（TX/RX + 状态寄存器），用于 bring-up 打印日志。
3. **SPI**：先做 Flash 读路径（读 ID + 连续读），暂不追求复杂模式，为 boot/data load 做准备。
4. **DMA 扩展**：先打通 SPI → SRAM，再 SRAM → input_fifo，每条路径单独写 TB，确认 done/err/busy。
5. **E203 最后接入**：先跑最小固件（UART 打印 → SPI 读 → DMA 搬运），出问题容易定位。

## 不可修改事项（除非用户明确授权）

- 不可修改上表中任何定版参数
- 不可删除 `ifndef SYNTHESIS` / `ifdef VCS` 宏保护
- 不可将 Scheme B 改回 Scheme A
- 不可提交 force push 到 main 分支
