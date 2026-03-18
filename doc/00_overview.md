# 00_overview

## 项目定位

**当前版本**：MVP（推理主链路已跑通，ASIC 主线继续推进）  
**目标版本**：V1（2026 年 6 月 30 日前完成数字 SoC 单独流片）  
**参数口径**：默认参数、地址映射与时序常量以 `rtl/top/snn_soc_pkg.sv` 为准；本文只做总览说明，若与 RTL 不一致，以 pkg 为准。

## 当前状态

- **当前集成架构**：数字芯片与模拟 CIM 芯片为**独立封装、分别流片**，通过 PCB 走线互联；V1 不是片上数模混合集成。
- **当前验证状态**：数字推理主链路已通过 smoke test，且正式 100 样本 `Python -> RTL` 对齐已通过，口径为 `predicted_class` 完全一致。
- **当前 pad 状态**：`rtl/top/chip_top.sv` 仍是 pad skeleton，用于接口冻结与 lint，不承担最终 pad cell 实例化和真实 pad 连线。
- **当前外设状态**：`uart_stub` / `spi_stub` / `jtag_stub` 仍为占位实现；真实 UART / SPI / CPU / AXI-Lite 仍处于后续集成阶段。

## V1 目标

在当前 MVP 基础上，补齐形成可运行固件系统所需的数字基础设施：

- RISC-V Core（E203）
- UART 控制器
- SPI 控制器
- AXI-Lite 总线升级
- 更完整的 DMA / 固件驱动流程

## 真源文档

阅读和决策时，建议按下面的真源优先级理解项目：

- `rtl/top/snn_soc_pkg.sv`：参数、地址和默认时序常量真源
- `doc/11_analog_handoff_execution_plan.md`：当前项目状态、双芯片 PCB 集成口径、阶段性结论
- `doc/15_asic_pad_map.md`：ASIC pad / pin 唯一真源
- `doc/08_cim_analog_interface.md`：数模接口和板级约束
- `doc/02_reg_map.md`：MMIO 寄存器定义
- `doc/01_memory_map.md`：地址空间与 `data_sram` / `weight_sram` 布局

## 系统结构

- 顶层：`snn_soc_top`
- `bus`：简化总线与地址译码
- `mem`：`instr_sram` / `data_sram` / `weight_sram` / FIFO
- `reg`：主寄存器 bank + FIFO 状态窗口
- `dma`：固定路径 DMA（`data_sram -> input_fifo`）
- `snn`：`cim_array_ctrl` + `wl_mux_wrapper` + `dac_ctrl` + `adc_ctrl` + `lif_neurons` + `cim_macro_blackbox`
- `periph`：UART / SPI / JTAG stub

## 当前主数据流

当前 RTL 已落地、并用于回归验证的主数据流是：

```text
data_sram
  -> dma_engine
    -> input_fifo
      -> dac_ctrl
        -> cim_macro_blackbox
          -> adc_ctrl
            -> lif_neurons
              -> output_fifo
```

当前 `main` 分支里，Testbench 直接通过总线事务模拟 CPU 行为；也就是说，**目前真实跑起来的是“TB 驱动 SoC”**，不是“CPU 驱动 SoC”。

## 目标控制流

当前版本：

```text
TB -> bus_if -> MMIO / SRAM -> DMA -> SNN datapath
```

目标 V1 版本：

```text
Flash / 外部输入
  -> SPI / UART
    -> CPU(E203)
      -> MMIO / SRAM
        -> DMA
          -> input_fifo
            -> SNN datapath
              -> output_fifo
```

也就是说，V1 的关键变化不是重写推理核心，而是把“Testbench 代替 CPU 做控制”的形态，升级为“CPU 跑固件真实控制 SoC”。

## 设计原则

- **数据流与控制流分离**：数据固定走 `data_sram -> DMA -> input_fifo -> CIM -> output_fifo`，控制通过寄存器配置和状态轮询完成。
- **DMA 与 FIFO 解耦**：DMA 负责搬运，FIFO 负责速率缓冲；两者职责不同，不合并。
- **外围逐步替换**：先保留 stub 接口和主链路稳定，再逐步换成真实 UART / SPI / CPU / AXI-Lite。
- **ASIC 主线优先**：当前以 ASIC 版本为准，不以 FPGA 分支口径约束主文档。

## 一次推理的高层流程

1. 软件或 TB 写寄存器，配置 `THRESHOLD`、`TIMESTEPS` 等参数。
2. 向 `data_sram` 写入 bit-plane 编码后的输入数据。
3. DMA 从 `data_sram` 读取两个 32-bit word，拼成一个 64-bit bit-plane，写入 `input_fifo`。
4. `cim_array_ctrl` 逐帧逐 bit-plane 驱动 `DAC -> CIM -> ADC` 流程。
5. `adc_ctrl` 对 20 路通道做时分复用采样，并进行 Scheme B 数字差分。
6. `lif_neurons` 按 `bitplane_shift` 累加膜电位，产生 spike 并写入 `output_fifo`。
7. 软件或 TB 通过寄存器读取输出结果。

补充：当 `TIMESTEPS=0` 时，控制器应立即结束，不进入完整推理流程。

## 当前冻结参数

| 参数                        |    值 | 说明                                     |
| ------------------------- | ---: | -------------------------------------- |
| `NUM_INPUTS`              |   64 | 输入维度，当前默认口径为 `avgpool8x8` 产生的 64 维离线特征 |
| `NUM_OUTPUTS`             |   10 | 输出类别数                                  |
| `PIXEL_BITS`              |    8 | bit-plane 编码位宽                         |
| `ADC_BITS`                |    8 | ADC 输出位宽                               |
| `ADC_CHANNELS`            |   20 | Scheme B：10 正 + 10 负                   |
| `NEURON_DATA_WIDTH`       |    9 | 差分后有符号位宽                               |
| `LIF_MEM_WIDTH`           |   32 | LIF 膜电位位宽                              |
| `TIMESTEPS_DEFAULT`       |   10 | 当前工程默认帧数                               |
| `THRESHOLD_RATIO_DEFAULT` |    1 | `ratio_code=1`，即 `1/255`               |
| `THRESHOLD_DEFAULT`       | 2550 | `1 * 255 * 10`                         |
| `INPUT_FIFO_DEPTH`        |  256 | 输入 FIFO 深度                             |
| `OUTPUT_FIFO_DEPTH`       | 4096 | 输出 FIFO 深度                             |
| `DAC_LATENCY_CYCLES`      |    5 | 仿真时序参数                                 |
| `CIM_LATENCY_CYCLES`      |   10 | 仿真时序参数                                 |
| `ADC_MUX_SETTLE_CYCLES`   |    2 | 仿真时序参数                                 |
| `ADC_SAMPLE_CYCLES`       |    3 | 仿真时序参数                                 |

## 当前实现 vs 占位实现

- **已真实实现**：总线、SRAM、FIFO、寄存器、DMA、SNN 控制链、LIF 神经元
- **行为模型**：`cim_macro_blackbox.sv`
- **占位模块**：`uart_stub`、`spi_stub`、`jtag_stub`
- **占位顶层**：`chip_top.sv` 仍是 pad skeleton

## 读这份文档时要注意

- 这份 `00_overview` 负责给你建立**整体图景**，不是细节真源。
- 若要看当前项目到底“已经做到哪一步”，优先看 `doc/11_analog_handoff_execution_plan.md`。
- 若要看 pad / pin，直接看 `doc/15_asic_pad_map.md`，不要在旧文档里自己重新算 pin。
- 若要看正式对齐口径，直接看 `tb/top_tb_sample_align.sv`、`sim/run_sample_align.sh` 和 `项目相关文件/器件对齐/Python建模/export_expected_spike_ids.py`。
