# 00_overview

## 项目定位

当前仓库主线是一个面向 SNN/CIM 验证的数字 SoC。

- 数字顶层：`rtl/top/snn_soc_top.sv`
- 计算主链：`data_sram -> dma_engine -> input_fifo -> DAC/CIM/ADC -> lif_neurons -> output_fifo`
- 外设：`uart_ctrl`、`spi_ctrl`
- CPU：E203
- 启动链：最小 `bootloader + SPI boot + UART printf`

参数、地址映射和默认常量以 [`rtl/top/snn_soc_pkg.sv`](../rtl/top/snn_soc_pkg.sv) 为准。

## 当前状态

- 推理主链稳定，`sample_align` 已通过 `100/100`
- `uart_ctrl` 已接入主线：TX 可用，RX 仍为 V1 占位
- `spi_ctrl` 已接入主线：V1 为 Mode 0，软件控制 `CS`
- `DMA` 已支持 `input_fifo / weight_sram / instr_sram` 三路目标
- `AXI-Lite bridge` 已完成独立验证
- `E203` 已接入，并已通过最小 bare-metal 固件验证
- `bootloader / SPI 启动 / UART printf` 已在专用 E203 Icarus TB 中验证通过
- `chip_top` 已通过 Icarus 编译门禁与 Verilator lint
- 旧 `top_tb` 入口、shell 脚本语法和 Python 主机工具语法已重新复核

## 重要边界

- [`rtl/top/chip_top.sv`](../rtl/top/chip_top.sv) 现在已经是**RTL 级 tapeout-intent 包装层**：默认启用 E203，并将外部 CIM 接口接到 pad 端口
- 但它仍未包含工艺库相关的真实 `pad cell / ESD / drive strength / package` 实现，这部分属于后续 pad-library 适配工作
- [`rtl/top/snn_soc_top.sv`](../rtl/top/snn_soc_top.sv) 的 `ENABLE_E203` 默认值仍是 `0`，这是为了不打扰既有主回归；真正 TO 路径由 `chip_top` 显式覆写为 `1`

## 当前执行形态

### 默认主线回归

```text
Testbench -> bus_if -> MMIO / SRAM -> DMA -> SNN datapath
```

用于：
- `LIGHT_SMOKETEST_PASS`
- `WEIGHTED_SIM_PASS`
- `SAMPLE_ALIGN_PASS`

### E203 专用启动链

```text
reset
  -> bootloader @ instr_sram
  -> SPI RDID
  -> SPI READ header + app payload
  -> load app to data_sram @ 0x0001_0000
  -> jump to app
  -> UART printf
  -> DMA + SNN inference
```

用于：
- `E203_SMOKETEST_PASS`

## 2026-03-24 复核基线

- 主线 Icarus 回归、JTAG rescue 链路、E203 启动链与 `sample_align 100/100` 已于 2026-03-24 重新执行
- `chip_top` 已通过 `iverilog` 编译门禁与 `verilator` lint
- 旧 `top_tb` 入口已跑通，日志尾部出现 `[TB] Simulation finished.`
- `bash -n sim/*.sh fw/*.sh` 与 `python -m py_compile ...` 已通过

## 关键验证结论

- `LIGHT_SMOKETEST_PASS`
- `WEIGHTED_SIM_PASS`
- `SAMPLE_ALIGN_PASS (100/100)`
- `AXI_BRIDGE_SMOKETEST_PASS`
- `UART_SMOKETEST_PASS`
- `SPI_SMOKETEST_PASS`
- `DMA_SMOKETEST_PASS`
- `ADC_SAT_COUNTER_PASS`
- `E203_SMOKETEST_PASS`（bootloader / SPI boot / UART printf）
- `JTAG_MEM_LOADER_PASS`
- `JTAG_RESCUE_TOP_PASS`
- `JTAG_PYHOST_SELFTEST_PASS`
- `chip_top` Icarus compile gate 通过
- `chip_top` Verilator lint 通过

## 真源文档

- [`doc/01_memory_map.md`](01_memory_map.md)
- [`doc/02_reg_map.md`](02_reg_map.md)
- [`doc/08_cim_analog_interface.md`](08_cim_analog_interface.md)
- [`doc/09_smoke_test_checklist.md`](09_smoke_test_checklist.md)
- [`doc/15_asic_pad_map.md`](15_asic_pad_map.md)
- [`doc/16_iteration_log.md`](16_iteration_log.md)

## 当前还没完成的事情

- `chip_top` 到 pad 级的真实集成
- tapeout 版本到底是否默认启用 E203 的冻结决策
- 综合 / PPA / 后端 / DFT / 签核闭环

## 阅读建议

- 想看地址和寄存器：先看 [`doc/01_memory_map.md`](01_memory_map.md) 和 [`doc/02_reg_map.md`](02_reg_map.md)
- 想看当前做到哪：先看 [`doc/16_iteration_log.md`](16_iteration_log.md)
- 想看 pad / pin：直接看 [`doc/15_asic_pad_map.md`](15_asic_pad_map.md)
- 想看 Python 对齐口径：直接看 `tb/top_tb_sample_align.sv` 和 `sim/run_sample_align.sh`
