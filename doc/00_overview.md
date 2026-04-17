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
- 旧 `top_tb` 入口、shell 脚本语法、Python 主机工具语法，以及 Git 跟踪 Markdown 的本地链接已重新复核

## 重要边界

- [`rtl/top/chip_top.sv`](../rtl/top/chip_top.sv) 现在已经是**RTL 级 tapeout-intent 包装层**：默认启用 E203，并将外部 CIM 接口接到 pad 端口
- 但它仍未包含工艺库相关的真实 `pad cell / ESD / drive strength / package` 实现，这部分属于后续 pad-library 适配工作
- [`rtl/top/snn_soc_top.sv`](../rtl/top/snn_soc_top.sv) 的 `ENABLE_E203` 默认值仍是 `0`，这是为了不打扰既有主回归；真正 TO 路径由 `chip_top` 显式覆写为 `1`

## 论文写作口径备忘（V1 vs V2）

### 当前 V1 的真实形态

- 当前主线不是单芯片数模混合集成，而是**双芯片 PCB 集成**：数字 SoC 与模拟 `CIM Macro` 独立流片、独立封装，通过 `wl_data / wl_group_sel / wl_latch / cim_start / cim_done / bl_sel / bl_data` 等 pad 信号互联。
- 因此，现阶段所有关于“片上通信优势”“消除封装级互联瓶颈”的论点，都只能作为后续 `V2/V3` 的目标或 motivation，不能写成 `V1` 已实现事实。

### 当前可以安全使用的论文表述

- 本工作完成了完整数字 SoC 的设计与 RTL 级验证，并确认了其与外部 `CIM Macro` 协同工作的控制逻辑、接口协议和推理链路。
- 当前 `V1` 采用双芯片 PCB 集成，可用于验证数字侧控制链路、数据流组织方式和系统 bring-up 可行性。
- 该数字架构在系统组织上已面向后续单芯片数模混合集成进行预留，可为未来降低片间通信开销、实现更紧耦合的数模协同提供数字侧基础。

### 当前不应直接写成的说法

- “我们已经实现了片上数模混合集成”
- “我们已经解决了互联问题”
- “当前系统已经消除了封装级互联开销”

### 建议的 roadmap / motivation 写法

- `V1` 的局限性可以诚实表述为：数字 SoC 与模拟 `CIM Macro` 之间仍存在 chip-to-chip / PCB 互联，因此会引入额外的通信延迟、接口能耗和时序约束。
- `V2/V3` 的目标可以表述为：将数字控制器与 `CIM Macro` 进一步推进到单芯片数模混合集成，以减少片间数据搬运、降低接口功耗，并提升系统级紧耦合协同能力。
- 若未来仅做到同封装 `MCM/SiP`，应写作“封装级集成”；只有当数字与模拟模块位于同一颗 die 上时，才适合写“片上集成”。

> 推荐备用句式：本工作完成了完整数字 SoC 的设计与 RTL 级验证，并确认了其与外部 `CIM Macro` 协同工作的控制逻辑、接口协议和推理链路；当前 `V1` 采用双芯片 PCB 集成，后续 `V2/V3` 将进一步推进单芯片数模混合集成，以降低片间通信开销并实现更紧耦合的系统级协同。

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

## 2026-03-31 复核基线

- 主线 Icarus 回归、JTAG rescue 链路、E203 启动链与 `sample_align 100/100` 已于 2026-03-31 重新执行通过
- `chip_top` 已通过 `iverilog` 编译门禁与 `verilator` lint
- 旧 `top_tb` 入口已跑通，日志尾部出现 `[TB] Simulation finished.`
- `bash -n sim/*.sh fw/*.sh` 与 `python -m py_compile ...` 已通过
- `python scripts/check_markdown_links.py` 已通过
- RTL / TB / filelist / 文档全面交叉审计：参数一致性 100%，寄存器地址 100%，无硬件阻塞项

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

- [`doc/01_memory_map.md`](01_memory_map.md) — 地址映射
- [`doc/02_reg_map.md`](02_reg_map.md) — 寄存器定义（权威）
- [`doc/07_tapeout_schedule.md`](07_tapeout_schedule.md) — 流片路线图（以文末 2026-03-31 Status Sync 为准）
- [`doc/08_cim_analog_interface.md`](08_cim_analog_interface.md) — 数模接口规格
- [`doc/09_smoke_test_checklist.md`](09_smoke_test_checklist.md) — 全量仿真操作手册
- [`doc/11_analog_handoff_execution_plan.md`](11_analog_handoff_execution_plan.md) — 数模对接 handoff
- [`doc/15_asic_pad_map.md`](15_asic_pad_map.md) — Pad Map（冻结真源）
- [`doc/16_iteration_log.md`](16_iteration_log.md) — 迭代变更日志

## 当前还没完成的事情（Phase 6 后端）

- `chip_top` pad cell 实例化（ESD / drive strength / IO type 配置）
- 综合 / PPA / 后端 P&R / DFT scan chain / STA 签核
- 板级 bring-up：boot image 格式完善 / JTAG rescue 实测 / 真实 SPI Flash 验证

> **已冻结决策**：tapeout 版本 `chip_top` 显式启用 `ENABLE_E203=1` + `ENABLE_EXT_CIM_IF=1`；`snn_soc_top` 默认值仍为 `0` 以保护既有主回归 TB 不受影响。

## 阅读建议

- 想看地址和寄存器：先看 [`doc/01_memory_map.md`](01_memory_map.md) 和 [`doc/02_reg_map.md`](02_reg_map.md)
- 想看当前做到哪：先看 [`doc/16_iteration_log.md`](16_iteration_log.md)
- 想看 pad / pin：直接看 [`doc/15_asic_pad_map.md`](15_asic_pad_map.md)
- 想看 Python 对齐口径：直接看 `tb/top_tb_sample_align.sv` 和 `sim/run_sample_align.sh`
