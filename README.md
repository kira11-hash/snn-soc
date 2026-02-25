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
- ADC 时分复用 10 路，neuron_in_valid 对应一次完整采样
- LIF 在有效拍按 bitplane_shift 左移累加并产生 spike 写入 output_fifo
- Testbench 自动跑完整流程并生成 FSDB

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

## 目录结构
```
rtl/   RTL 实现
  top/      顶层与参数包
  bus/      简化总线与地址译码
  mem/      SRAM + FIFO
  reg/      reg bank + fifo 状态窗
  dma/      DMA 引擎
  snn/      CIM 控制器 + DAC/ADC + LIF + Macro 行为模型
  periph/   UART/SPI/JTAG stub

tb/    Testbench
sim/   仿真脚本与波形
doc/   中文说明文档
```

## 关键说明
- **参数口径**：所有默认参数与时序常量以 `rtl/top/snn_soc_pkg.sv` 为准，文档中的数值仅作说明与示例，若不一致请以 pkg 为准。
- 输入编码：7x7 像素、每像素 8bit；同一子时间步并行送 49 个像素的第 x 位，顺序为 MSB->LSB。
- data_sram 排布：每个 bit-plane 为 49-bit，按 2 个 32-bit word 保存（word0=低32位，word1[16:0]=高17位）。
- TIMESTEPS 表示帧数；总子时间步 = TIMESTEPS × PIXEL_BITS。
- 当 TIMESTEPS=0 时，推理立即结束。
- LIF 位宽建议：`LIF_MEM_WIDTH >= ADC_BITS + PIXEL_BITS`。
- 默认阈值为 `THRESHOLD_DEFAULT`（按“同图重复 5 帧”估算，见 `snn_soc_pkg.sv`，可软件覆盖）。
- CIM Macro 在仿真中为行为模型，综合时为黑盒，可替换真实宏。
- UART/SPI/JTAG 仅为 stub，不产生真实协议，仅占位可读写寄存器。

## 建模定版补充（复位模式，2026-02-10）
- 对比对象：`SPIKE_RESET_MODE=soft` vs `SPIKE_RESET_MODE=hard`，其余参数固定为推荐配置（`proj_sup_64, Scheme B, ADC=8, W=4, T=1, threshold_ratio=0.40`）。
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
- `doc/develop docs/` 文件夹内容为早期草稿，已整合到上述正式文档中

## 片外/片上混合集成说明

本项目将分阶段完成数模集成：
- 数字部分：本项目的 RTL（SoC 控制器、DMA、LIF 神经元等）
- 模拟部分：真实 CIM Macro（由其他同学提供版图）
- V1：数字 SoC 单独流片，片外与模拟宏连接验证
- V2/V3：片上数模混合集成
- 接口约定：`cim_macro_blackbox.sv` 的端口定义保持不变
- 时钟频率：目标 50MHz（数模混合需要保守时序裕量）
