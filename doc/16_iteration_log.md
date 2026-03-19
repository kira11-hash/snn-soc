# 16_iteration_log

本文档记录每次迭代的变更摘要、验证结果与后续计划，按时间倒序追加。

---

## Iteration 1 — AXI-Lite 基础骨架接入（2026-03-18）

### 变更内容

将 `feature/axi-lite` 分支的 AXI-Lite 协议转换桥移植到 `main` 分支。

**新增文件（5 个 RTL/TB/脚本，未改动任何现有文件）：**

| 文件 | 说明 |
|------|------|
| `rtl/bus/axi_lite_if.sv` | AXI4-Lite SystemVerilog interface 定义，含 master/slave modport |
| `rtl/bus/axi2simple_bridge.sv` | AXI-Lite slave → bus_simple master 协议转换桥，5 态 FSM |
| `tb/axi_bridge_tb.sv` | T1~T13 端到端测试（含字节写使能、AW/W 错拍、背压、DECERR、未对齐访问） |
| `sim/sim_axi_bridge.f` | Icarus 编译文件列表 |
| `sim/run_axi_bridge_icarus.sh` | Icarus 运行脚本，通过标准 `AXI_BRIDGE_SMOKETEST_PASS` |

### 集成策略

采用 **"interconnect 内部转换，slave 保持 simple 接口"** 方案：

- `axi2simple_bridge` 作为独立协议转换模块，不集成进 `snn_soc_top.sv`（E203 接入时再挂载）
- `bus_interconnect` 和所有下游 slave（reg_bank、dma_engine 等）接口不变
- 现阶段 `snn_soc_top.sv` 的主机仍是 `top_tb` 的 `bus_simple`，不影响任何现有测试

### 验证结果

```
AXI Bridge:   T1~T13 全部 PASS（13/13）  → AXI_BRIDGE_SMOKETEST_PASS
主链路回归:   OUT_FIFO_COUNT=100         → LIGHT_SMOKETEST_PASS（无回归）
```

### 桥时序

```
写事务：Cycle N (m_valid) → N+1 (m_ready) → N+2 (BVALID)，总 2 cycle
读事务：Cycle N (m_valid) → N+1 (m_rvalid) → N+2 (RVALID)，总 2 cycle
AW/W 错拍：先缓存先到的一侧（1-entry pending），另一侧到达后发 m_valid
```

### 未映射地址处理

`axi2simple_bridge` 内含地址校验逻辑，既覆盖 pkg.sv 的全部 8 个地址区间，也检查 4B 对齐约束。访问未映射地址或未对齐地址时，桥接层都直接返回 `DECERR`（2'b11），不发 simple bus 请求，防止下游 bus_interconnect 收到非法路由。

---

## Iteration 2 — UART stub → uart_ctrl 集成（2026-03-18）

### 变更内容

将 `feature/uart-tx` 分支的 UART TX 控制器移植到 `main` 分支，替换 uart_stub。

**新增文件（4 个 RTL/TB/脚本）：**

| 文件 | 说明 |
|------|------|
| `rtl/periph/uart_ctrl.sv` | UART TX 控制器（8N1，4态FSM，baud_div可配置，RX V1占位） |
| `tb/uart_tb.sv` | T1~T8 独立烟雾测试（含 baud_div 读写、多字节发送解码、STATUS、忙时忽略、CTRL 锁存） |
| `sim/sim_uart.f` | Icarus 编译文件列表 |
| `sim/run_uart_icarus.sh` | Icarus 运行脚本，通过标准 `UART_SMOKETEST_PASS` |

**修改文件（6 处）：**

| 文件 | 变更 |
|------|------|
| `rtl/top/snn_soc_top.sv` | `uart_stub u_uart` → `uart_ctrl u_uart`（端口完全兼容，仅改实例模块名） |
| `sim/sim_icarus_light.f` | `uart_stub.sv` → `uart_ctrl.sv` |
| `sim/sim_icarus_weighted.f` | `uart_stub.sv` → `uart_ctrl.sv` |
| `sim/sim.f` | `uart_stub.sv` → `uart_ctrl.sv`，保证默认 top_tb filelist 可编译 |
| `sim/sim_sample_align.f` | `uart_stub.sv` → `uart_ctrl.sv`，保证 sample-align 回归可编译 |
| `sim/sim_adc_sat_counter.f` / `sim/rtl_with_chip_top_check.f` | `uart_stub.sv` → `uart_ctrl.sv`，保证 ADC 饱和回归与 chip_top lint 可编译 |

### 功能说明

| 特性 | 实现状态 |
|------|---------|
| TX：8N1 帧格式（1起始+8数据+1停止） | ✅ 4态FSM（IDLE/START/DATA/STOP） |
| 波特率配置（CTRL.baud_div，默认434=115200@50MHz） | ✅ 帧间热更新，发送中改配下帧生效 |
| baud_div=0 防御（钳位到1，防止倒计数异常） | ✅ |
| 忙时写 TXDATA 忽略（tx_busy=1 时不加载新字节） | ✅ |
| STATUS[0]=tx_busy 可读 | ✅ |
| TXDATA 影子寄存器可读回 | ✅ |
| RX 路径 | V1 占位（读回0），V2 实现 |

### 验证结果

```
UART独立TB:   T1~T8 全部 PASS（12/12）  → UART_SMOKETEST_PASS
黑盒smoke回归: OUT_FIFO_COUNT=100       → LIGHT_SMOKETEST_PASS（无回归）
带权重回归:   OUT_FIFO_COUNT=55         → WEIGHTED_SIM_PASS（无回归）
```

---

## Iteration 3 — SPI stub → spi_ctrl 集成（2026-03-18）

### 变更内容

将 `feature/spi` 分支的 SPI Master 控制器移植到 `main` 分支，替换 spi_stub。

**新增文件（5 个 RTL/TB/脚本）：**

| 文件 | 说明 |
|------|------|
| `rtl/periph/spi_ctrl.sv` | SPI Master 控制器（Mode 0，8-bit 全双工，3态FSM，软件控 CS，baud_div 7级） |
| `tb/spi_flash_model.sv` | SPI Flash 行为模型（支持 RDID/READ 命令，64KB 窗口） |
| `tb/spi_tb.sv` | T1~T3 + T1b 烟雾测试（CTRL读写、clamp、RDID、READ 4字节、rx_valid清零） |
| `sim/sim_spi.f` | Icarus 编译文件列表 |
| `sim/run_spi_icarus.sh` | Icarus 运行脚本，通过标准 `SPI_SMOKETEST_PASS` |

**修改文件（5 处）：**

| 文件 | 变更 |
|------|------|
| `rtl/top/snn_soc_top.sv` | `spi_stub u_spi` → `spi_ctrl u_spi`（端口完全兼容，仅改实例模块名） |
| `sim/sim_icarus_light.f` | `spi_stub.sv` → `spi_ctrl.sv` |
| `sim/sim_icarus_weighted.f` | `spi_stub.sv` → `spi_ctrl.sv` |
| `sim/sim.f` / `sim/sim_sample_align.f` | `spi_stub.sv` → `spi_ctrl.sv`，补齐默认 top_tb 与 sample-align filelist |
| `sim/sim_adc_sat_counter.f` / `sim/rtl_with_chip_top_check.f` | `spi_stub.sv` → `spi_ctrl.sv`，补齐 ADC 饱和回归与 chip_top lint filelist |

### 功能说明

| 特性 | 实现状态 |
|------|---------|
| SPI Master，Mode 0（CPOL=0, CPHA=0） | ✅ 3态FSM（IDLE/SHIFT/DONE） |
| 8-bit 全双工（MOSI/MISO 同步收发） | ✅ |
| CS 软件控制（CTRL[8]=cs_force） | ✅ |
| baud_div 7级可配（÷2~÷256，CTRL[3:1]） | ✅ |
| clk_div=0+spi_en=1 安全钳位→clk_div=2 | ✅（防止 25MHz SCK 损坏 Flash） |
| rx_valid 读 RXDATA 后自动清零 | ✅ |
| TX/RX 1-deep shadow buffer | ✅ |
| Mode 3 | V1 仅 Mode 0，V2 扩展 |

### 验证结果

```
SPI独立TB:    T1~T3+T1b 全部 PASS（9/9）  → SPI_SMOKETEST_PASS
黑盒smoke回归: OUT_FIFO_COUNT=100          → LIGHT_SMOKETEST_PASS（无回归）
带权重回归:   OUT_FIFO_COUNT=55            → WEIGHTED_SIM_PASS（无回归）
sample-align: 100/100 samples matched       → SAMPLE_ALIGN_PASS
ADC饱和回归:   pass                         → ADC_SAT_COUNTER_PASS
chip_top lint: pass                         → verilator lint clean
```

---

## Iteration 4 — DMA 引擎多目标扩展（2026-03-18）

### 变更内容

扩展 `dma_engine.sv`，新增 `REG_DST_SEL` 寄存器支持多目标路由；同步新增 `sram_simple.sv` DMA 写端口，更新 `snn_soc_top.sv` 连线。

**修改文件（3 个 RTL）：**

| 文件 | 变更 |
|------|------|
| `rtl/dma/dma_engine.sv` | 新增 `REG_DST_SEL`（offset 0x0C，2-bit）、`ST_WR` 状态、`weight_wr_*` / `instr_wr_*` 输出端口；奇数长度约束仅对 `DST_INPUT_FIFO` 生效；busy 期间忽略 `DST_SEL` 改写，`2'b11` 非法值直接报错 |
| `rtl/mem/sram_simple.sv` | 新增 `dma_wr_en/addr/data/strb` DMA 写端口（Port B），供 `instr_sram` / `weight_sram` 接收 DMA 写 |
| `rtl/top/snn_soc_top.sv` | 连接 `dma_engine` 的新端口到 `u_weight_sram` 和 `u_instr_sram` 的 DMA 写端口 |

**新增文件（3 个 TB/脚本）：**

| 文件 | 说明 |
|------|------|
| `tb/dma_tb.sv` | T1~T10 独立烟雾测试（含三路目标、奇数长度、对齐错误、W1C、背压、busy 期间写保护、非法 DST_SEL） |
| `sim/sim_dma.f` | Icarus 编译文件列表 |
| `sim/run_dma_icarus.sh` | Icarus 运行脚本，通过标准 `DMA_SMOKETEST_PASS` |

### DST_SEL 功能说明

| `DST_SEL[1:0]` | 目标 | 行为 |
|----------------|------|------|
| `2'b00` (`DST_INPUT_FIFO`) | `input_fifo` | 每两个 word 拼成 64-bit push（原有行为，兼容） |
| `2'b01` (`DST_WEIGHT_BUF`) | `weight_sram` DMA 写端口 | 逐 word 写入，允许奇数长度 |
| `2'b10` (`DST_INSTR_SRAM`) | `instr_sram` DMA 写端口 | 逐 word 写入，允许奇数长度 |

源地址始终来自 `data_sram`（`addr_ptr = src - ADDR_DATA_BASE`）；目标偏移与源偏移相同，保持相对位置一致。SPI→SRAM 通路：固件通过 SPI 读数据写入 `data_sram`，再由 DMA 以 `DST_INSTR_SRAM` / `DST_WEIGHT_BUF` 搬运。

### FSM 扩展

```
DST_INPUT_FIFO：IDLE → SETUP → RD0 → RD1 → PUSH → (RD0 or IDLE)   [原有，兼容]
DST_WEIGHT/INSTR：IDLE → SETUP → RD0 → WR → (RD0 or IDLE)          [新增 ST_WR]
```

### 验证结果

```
DMA 独立 TB:  T1~T10 全部 PASS（39/39） → DMA_SMOKETEST_PASS
黑盒 smoke:  OUT_FIFO_COUNT=100         → LIGHT_SMOKETEST_PASS（无回归）
带权重回归:  OUT_FIFO_COUNT=55          → WEIGHTED_SIM_PASS（无回归）
```

---

## Iteration 5 — E203 最小面积接入（2026-03-18）

### 变更内容

将 E203 以“最小侵入、最小面积”的方式接入 `main`：

- 顶层不走 `ICB -> AXI -> simple bus` 双桥路径，而是直接新增 `ICB -> simple bus` 轻量桥，减少一层协议转换面积和时序负担。
- `snn_soc_top.sv` 新增 `ENABLE_E203` 参数，默认仍由 `bus_if` 驱动；只有在专用 E203 TB 中才切换到 CPU 主控，因此原有主线回归无需改测试用例。
- 新增 `e203_min_wrap.sv` 包装层，仅暴露 `mem_icb` 到 SoC fabric；PPI / CLINT / PLIC / FIO 一律接到错误应答从设备，避免为了 V1 bring-up 额外引入不必要外设。
- 裁剪 vendor `config.v`：关闭 `JTAG / ITCM / DTCM / NICE / ECC / AMO / share-muldiv`，保留 RV32I 主路径与 `mem_icb`。  
  说明：`MCYCLE/MINSTRET` 原本也尝试关闭，但 vendor `e203_exu_csr.v` 对这组信号有非对称 ifdef 依赖，直接关闭会导致编译失败，因此本轮保留这组 CSR，避免在 vendor RTL 内做高风险手术。

### 新增 / 修改文件

| 文件 | 变更 |
|------|------|
| `rtl/bus/icb2simple_bridge.sv` | 新增 E203 `mem_icb` 到 `bus_simple` 的轻量桥；单 outstanding；SRAM 区允许 byte/halfword 访问，MMIO 区强制 4B 对齐，非法访问返回 error |
| `rtl/bus/icb_err_slave.sv` | 新增 ICB 错误应答从设备，供 PPI / CLINT / PLIC / FIO 占位 |
| `rtl/top/e203_min_wrap.sv` | 新增 E203 最小包装层；内部 tie-off debug/interrupt/TCM 电源控制，并将未使用 ICB 口接到 `icb_err_slave` |
| `rtl/top/snn_soc_top.sv` | 新增 `ENABLE_E203` 参数，加入 E203 wrapper + `icb2simple_bridge`，并将 bus fabric 改成“外部 TB / E203 二选一” |
| `项目相关文件/未添加的IP的源代码/e203_hbirdv2-master/rtl/e203/core/config.v` | 裁剪 E203 配置，关闭不需要的大块功能，仅保留本轮用到的最小子集 |
| `fw/crt0.S` / `fw/main.c` / `fw/link.ld` | 新增 E203 最小 bare-metal C 固件工程 |
| `fw/build_e203_firmware.sh` / `fw/bin_to_readmemh.py` | 新增固件构建脚本与 binary→`$readmemh` 转换脚本，输出 `fw/out/firmware.hex` |
| `tb/e203_tb.sv` | 新增 E203 专用 Icarus 烟测 TB：预加载 `instr_sram`，预填 `data_sram` 输入模式，检查签名 / UART / `OUT_FIFO_COUNT` |
| `sim/sim_e203.f` | 新增 E203 专用 filelist，使用 `rtl/vendor_e203` 本地 ASCII 映射规避 Icarus 对 vendor 路径的读取问题 |
| `sim/run_e203_icarus.sh` | 新增 E203 专用运行脚本，PASS 标准为 `E203_SMOKETEST_PASS` |
| `sim/sim*.f` / `sim/rtl_with_chip_top_check.f` | 补齐 `icb2simple_bridge.sv`、`icb_err_slave.sv`、`e203_min_wrap.sv`，保证原有 top 相关回归仍可编译 |

### 固件 / 验证策略

本轮 E203 bring-up 已切换到真实 **C 固件 + WSL toolchain** 流程：

- 使用 WSL 内的 `riscv64-unknown-elf-gcc / objcopy`，编译 `fw/crt0.S + fw/main.c + fw/link.ld`
- 通过 `fw/build_e203_firmware.sh` 生成 `fw/out/firmware.elf / firmware.dump / firmware.hex`
- `sim/run_e203_icarus.sh` 会先自动构建固件，再跑 Icarus
- 当前固件只依赖 RV32I：写签名到 `data_sram`、配置 UART、启动 DMA、轮询 `DONE`、启动 SNN、读取 `OUT_FIFO_COUNT` 并写回 SRAM

### 验证结果

```
E203 专用 smoke: Signature/UART/SNN 全部通过      -> E203_SMOKETEST_PASS
黑盒 smoke 回归: OUT_FIFO_COUNT=100               -> LIGHT_SMOKETEST_PASS
带权重回归:     OUT_FIFO_COUNT=55                -> WEIGHTED_SIM_PASS
sample-align:   100/100 samples matched          -> SAMPLE_ALIGN_PASS
ADC 饱和回归:   pass                             -> ADC_SAT_COUNTER_PASS
chip_top lint:  pass                             -> verilator lint clean
```

---

## Iteration 6 — Bootloader / SPI 启动 + UART printf（2026-03-19）

### 变更内容

在已有 E203 最小接入的基础上，补齐了真实上电启动链：

- `bootloader` 预加载在 `instr_sram`，上电后先运行引导程序
- `bootloader` 通过 `spi_ctrl` 访问外部 SPI Flash 模型，读取应用镜像头和 payload
- `bootloader` 将 `app` 装载到 `data_sram @ 0x0001_0000`，执行 `fence.i` 后跳转
- `app` 运行后通过 `UART printf` 输出阶段日志，并继续完成 DMA + SNN 推理

### 新增 / 修改文件

| 文件 | 变更 |
|------|------|
| `fw/include/soc_regs.h` | 统一定义 E203 / DMA / UART / SPI / marker 地址和启动常量 |
| `fw/include/uart_printf.h` / `fw/uart_printf.c` | 新增最小 `uart_printf` 实现，支持 `%c / %s / %x / %u`，供 bootloader 和 app 共用 |
| `fw/boot_main.c` | 新增 bootloader：读 `RDID`、读取镜像头、SPI 逐字节搬运 app、写 boot marker、跳转到 app |
| `fw/main.c` | 切换为 app 固件：生成 DMA 输入、运行推理、用 UART 输出 `APP start` / `APP inference done count=...` |
| `fw/link.ld` | 调整为 bootloader 链接脚本，`DMEM` 仅保留高地址小窗口，避免与 app 装载区冲突 |
| `fw/app_link.ld` | 新增 app 链接脚本，app 代码运行在 `data_sram @ 0x0001_0000` |
| `fw/build_flash_image.py` | 新增 SPI Flash 镜像生成脚本：写入 boot header（magic/size/load/entry）+ app payload |
| `fw/build_e203_firmware.sh` | 扩展为同时生成 `bootloader.hex`、`app.elf/bin/dump`、`flash_image.hex` |
| `tb/spi_flash_model.sv` | 支持通过参数加载外部 `flash_image.hex`，默认行为仍兼容原 SPI 单测 |
| `tb/e203_tb.sv` | 切换到 bootloader/SPI 启动路径，实例化 flash model，检查 boot marker / app signature / result / done，并打印 UART 日志 |

### 启动流程

```
reset
  -> bootloader @ instr_sram
  -> UART: "BL start"
  -> SPI RDID
  -> SPI READ header + app payload
  -> app load to data_sram @ 0x0001_0000
  -> write boot marker
  -> jump to app
  -> UART: "APP start"
  -> DMA + SNN inference
  -> UART: "APP inference done count=100"
  -> write app signature / result / done marker
```

### 验证结果

```
bootloader / SPI 启动 / UART printf: 通过 -> E203_SMOKETEST_PASS
黑盒 smoke 回归: OUT_FIFO_COUNT=100  -> LIGHT_SMOKETEST_PASS
带权重回归:     OUT_FIFO_COUNT=55   -> WEIGHTED_SIM_PASS
SPI 单测回归:                        -> SPI_SMOKETEST_PASS
ADC 饱和计数器回归:                   -> ADC_SAT_COUNTER_PASS
chip_top Verilator lint:             -> 通过
```

---

## 后续迭代计划（Phase 4 剩余）

| 迭代 | 内容 | 验证标准 |
|------|------|---------|
| Iter 7 | 更完整 boot image 格式 / 校验 / 真实板级 bring-up 流程 | 从仿真启动链过渡到板级启动链 |

每次迭代完成后在本文档追加一节记录。
