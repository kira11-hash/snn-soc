# SNN SoC MVP 工程

本仓库提供一个从零可看懂、可仿真跑通的 SNN SoC MVP：
- 支持寄存器配置阈值与时步数
- DMA 从 data_sram 搬运输入到 input_fifo
- CIM 控制器按 timesteps 循环调用 DAC/CIM/ADC
- LIF 神经元更新并产生 spike 写入 output_fifo
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
- 若平台/版本不同，可在 `sim/run_vcs.sh` 中调整 PLI 路径。

## 目录结构
```
rtl/   RTL 实现
  top/      顶层与参数包
  bus/      简化总线与地址译码
  mem/      SRAM + FIFO
  reg/      reg bank + fifo 状态
  dma/      DMA 引擎
  snn/      CIM 控制器 + DAC/ADC + LIF + Macro 行为模型
  periph/   UART/SPI/JTAG stub

tb/    Testbench
sim/   仿真脚本与波形
 doc/  中文说明文档
```

## 关键说明
- CIM Macro 提供仿真行为模型，综合时为黑盒（可替换真实宏）。
- UART/SPI/JTAG 为 stub，不产生真实协议波形。
- 总线固定 1-cycle 响应：写下一拍 ready=1，读下一拍 rvalid=1。

## 文档索引
- `doc/00_overview.md`：工程总览
- `doc/01_memory_map.md`：地址映射
- `doc/02_reg_map.md`：寄存器说明
- `doc/03_cim_if_protocol.md`：CIM 接口协议
- `doc/04_walkthrough.md`：流程详解
- `doc/05_debug_guide.md`：调试指南
