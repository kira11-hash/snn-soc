# SNN SoC 工程

本仓库提供一个**数模混合 SNN SoC**，当前为 MVP 版本，目标迭代到 V1 版本流片（数字单独流片 + 片外混合集成验证），后续再进行片上混合集成。

## 项目目标

| 版本      |   状态   | 说明                              |
| :------ | :----: | :------------------------------ |
| **MVP** |  ✅ 完成  | 基础功能可仿真跑通                       |
| **V1**  | 🚧 开发中 | 完整版本，支持 E203 + UART + SPI + AXI |

**流片目标**：2026年6月30日，数字 SoC 单独流片 + 片外混合集成验证（数字 SoC + 模拟 CIM Macro）
**时钟频率**：50MHz

## MVP 功能
- 支持寄存器配置阈值与推理帧数（TIMESTEPS）
- DMA 从 data_sram 搬运 bit-plane 输入到 input_fifo
- CIM 控制器按 帧 × PIXEL_BITS 子时间步循环 DAC/CIM/ADC
- ADC 时分复用 20 路（Scheme B：10 正 + 10 负），`neuron_in_valid` 对应一次完整扫描后的 10 路差分结果
- LIF 在有效拍按 bitplane_shift 左移累加并产生 spike 写入 output_fifo
- Testbench 自动跑完整流程，并按仿真器生成 FSDB 或 VCD 波形

## 快速开始（VCS + Verdi）
> 使用 bash 运行脚本（Linux/WSL/Git Bash 均可）。

1) 编译并仿真（生成 FSDB）
```
./sim/run_vcs.sh
```

2) 打开 Verdi
```
./sim/run_verdi.sh
```

### 环境变量要求
- `VERDI_HOME`：指向 Verdi 安装目录（用于 FSDB PLI）。
- 若平台版本不同，可在 `sim/run_vcs.sh` 中调整 PLI 路径。
- Windows 下请优先使用 Git for Windows 自带的 `bash.exe` / `sh.exe` 运行 `sim/*.sh`；不要直接用 `C:\Windows\System32\bash.exe`（WSL bash），否则可能找不到本机安装的 `iverilog` / `verilator`。
- 若在 `bash`/WSL 中看到 `$'\r': command not found`，说明本地 checkout 把 `.sh` 脚本变成了 CRLF；仓库期望 `*.sh` 为 LF（见 `.gitattributes`），请先按 LF 重新检出后再运行。
- 带权重的 Icarus/VCS 流程依赖外部生成的 `weight_pos.hex` / `weight_neg.hex`；仓库默认不提交这些导出物，可放在任意 `results/exports/` 目录、`fpga/cim_model/` 或 `sim/` 下；如需显式指定来源，可设置 `WEIGHT_SRC_DIR=<目录>`。
- `run_sample_align.sh` 额外依赖 `all_samples.hex` / `expected_classes.hex`；脚本会在仓库内自动查找 `rtl_stimulus/` 目录，也可通过 `STIMULUS_DIR=<目录>` 强制指定。

## 常用回归入口
> Windows 日常回归建议用 Git Bash；`run_e203_icarus.sh` 额外依赖 WSL 中可用的 `riscv64-unknown-elf-gcc / objcopy`。

- `cd sim && bash run_uart_icarus.sh`：UART 单测，期望 `UART_SMOKETEST_PASS`
- `cd sim && bash run_spi_icarus.sh`：SPI 单测，期望 `SPI_SMOKETEST_PASS`
- `cd sim && bash run_dma_icarus.sh`：DMA 单测，期望 `DMA_SMOKETEST_PASS`
- `cd sim && bash run_axi_bridge_icarus.sh`：AXI-Lite bridge 单测，期望 `AXI_BRIDGE_SMOKETEST_PASS`
- `cd sim && bash run_icarus_light.sh`：黑盒顶层 smoke，期望 `LIGHT_SMOKETEST_PASS`
- `cd sim && bash run_icarus_weighted.sh +FAIL_ON_ZERO_SPIKE=1`：带权重顶层回归，期望 `WEIGHTED_SIM_PASS`
- `cd sim && bash run_sample_align.sh`：Python↔RTL 100 样本对齐，期望 `SAMPLE_ALIGN_PASS`
- `cd sim && bash run_adc_sat_counter.sh`：ADC 饱和计数回归，期望 `ADC_SAT_COUNTER_PASS`
- `cd sim && bash run_jtag_loader_icarus.sh`：JTAG rescue loader 单测，期望 `JTAG_MEM_LOADER_PASS`
- `cd sim && bash run_jtag_pyhost_selftest.sh`：Python 主机侧无硬件自测，期望 `JTAG_PYHOST_SELFTEST_PASS`
- `cd sim && bash run_jtag_rescue_top_icarus.sh`：JTAG rescue 顶层回归，期望 `JTAG_RESCUE_TOP_PASS`
- `cd sim && bash run_e203_icarus.sh`：E203 最小启动链回归，期望 `E203_SMOKETEST_PASS`
- `cd sim && iverilog -g2012 -gno-assertions -f rtl_with_chip_top_check.f -s chip_top -o chip_top_check.out`：TO 路径的 `chip_top` 编译门禁
- `verilator.cmd -Wall --lint-only --top-module chip_top -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -f sim\\rtl_with_chip_top_check.f`：`chip_top` lint 门禁

## 目录结构
```
rtl/   RTL 实现
  top/      顶层与参数包
  bus/      简化总线与地址译码
  mem/      SRAM + FIFO
  reg/      reg bank + fifo 状态窗
  dma/      DMA 引擎
  snn/      CIM 控制器 + DAC/ADC + LIF + Macro 行为模型
  periph/   UART/SPI 外设 + Rescue JTAG loader

tb/    Testbench
sim/   仿真脚本与波形
scripts/ Python 主机工具
doc/   中文说明文档
```

## 关键说明
- **参数口径**：所有默认参数与时序常量以 `rtl/top/snn_soc_pkg.sv` 为准，文档中的数值仅作说明与示例，若不一致请以 pkg 为准。
- 当前工程冻结的 RTL / bring-up 参数：`ADC=8`、`PIXEL_BITS=8`、`T=10`、`ratio_code=1`、`THRESHOLD_DEFAULT=2550`、`reset_mode=soft`，默认离线压缩/预处理口径为 `avgpool8x8`。
- `W=4` 仅属于历史训练/量化实验口径，用于解释部分建模结果；它不是当前 `rtl/top/snn_soc_pkg.sv` 中的冻结参数。
- 输入编码：当前默认离线压缩/预处理口径为 `avgpool8x8`，得到 8x8=64 维特征（NUM_INPUTS=64）、每维 8bit；RTL 仅冻结 64x8 接口，不在硬件中固化前处理算法。同一子时间步并行送 64 维特征的第 x 位，顺序为 MSB->LSB。
- data_sram 排布：每个 bit-plane 为 64-bit，按 2 个 32-bit word 保存（word0=低32位，word1=高32位）。
- TIMESTEPS 表示帧数；总子时间步 = TIMESTEPS × PIXEL_BITS。
- 当 TIMESTEPS=0 时，推理立即结束。
- LIF 位宽建议：`LIF_MEM_WIDTH >= NEURON_DATA_WIDTH + PIXEL_BITS`。
- 默认阈值为 `THRESHOLD_DEFAULT`（工程默认计算：`THRESHOLD_RATIO_DEFAULT × (2^PIXEL_BITS - 1) × TIMESTEPS_DEFAULT = 1 × 255 × 10 = 2550`，可软件覆盖）。
- CIM Macro 在仿真中为行为模型，综合时为黑盒，可替换真实宏。
- UART 已实现最小 TX 路径（RX 仍为 V1 预留），SPI 已实现 Mode 0 主控，JTAG 已切换为独立 rescue loader：仅开放 `instr_sram / data_sram / weight_sram` 访问与 CPU 局部重启。
- tapeout 前全量回归的建议检查面与逐项操作说明见 `doc/09_smoke_test_checklist.md`。

## 建模定版补充（复位模式，2026-02-10）
- 对比对象：`SPIKE_RESET_MODE=soft` vs `SPIKE_RESET_MODE=hard`；当前 RTL 默认 `reset_mode=soft`，其余建模参数以各次对比实验冻结配置为准。
- 当前工程默认 `T=10`；如需做精度/时延 trade-off，可额外比较更小的 `T`。
- 对比入口：`run_all.py` 的 `[3f]`（噪声影响，`add_noise=True`）和 `[3l]`（test 多 seed noisy，`add_noise=True`）。
- soft（历史基线）：
  - val noisy mean：`90.41% +/- 0.0031`
  - test noisy（multi-seed）：`90.98% +/- 0.0012`
- hard（2026-02-10 复跑）：
  - val noisy mean：`90.51% +/- 0.0034`
  - test noisy（multi-seed）：`90.98% +/- 0.0012`
- 结论：
  - 当前推荐配置下，soft/hard 在 noisy test 指标上等效（数值一致）。
  - val 侧 `0.10%` 差异小于统计波动量级（`~0.31%-0.34%`），不具显著性。
  - V1 参数继续沿用 `soft`，理由是与既有 RTL/文档口径一致，且无需引入额外改动风险。
- 结果证据：
  - `项目相关文件/器件对齐/Python建模/results/summary.txt`
  - `项目相关文件/器件对齐/Python建模/results/run_all_skiptrain_hard_20260210_161450.log`

## 文档索引

### 正式文档（推荐阅读）
- `doc/00_overview.md`：工程总览
- `doc/01_memory_map.md`：地址映射
- `doc/02_reg_map.md`：寄存器说明
- `doc/03_cim_if_protocol.md`：CIM 接口协议
- `doc/04_walkthrough.md`：流程详解
- `doc/05_debug_guide.md`：调试指南
- `doc/06_learning_path.md`：**学习路径（新手必读！）**
- `doc/07_tapeout_schedule.md`：**流片时间规划（V1路线图）**

### 草稿文档（已整合到正式文档）
- 早期 `develop docs` 草稿目录已从仓库移除，相关内容已整合到上述 `doc/*.md` 正式文档中；如需追溯演进过程，请查看 Git 历史。

## 片外/片上混合集成说明

本项目将分阶段完成数模集成：
- 数字部分：本项目的 RTL（SoC 控制器、DMA、LIF 神经元等）
- 模拟部分：真实 CIM Macro（由其他同学提供版图）
- V1：数字 SoC 单独流片，片外与模拟宏连接验证
- V2/V3：片上数模混合集成
- 接口约定：`cim_macro_blackbox.sv` 的端口定义保持不变
- 时钟频率：目标 50MHz（数模混合需要保守时序裕量）
