# 01_memory_map

**参数口径**：本文涉及的默认参数与地址范围以 `rtl/top/snn_soc_pkg.sv` 为准，若与文档不一致以 pkg 为准。

| 地址范围                      |   大小 | 模块                |
| ------------------------- | ---: | ----------------- |
| 0x0000_0000 ~ 0x0000_3FFF | 16KB | instr_sram        |
| 0x0001_0000 ~ 0x0001_3FFF | 16KB | data_sram         |
| 0x0003_0000 ~ 0x0003_3FFF | 16KB | weight_sram（保留窗口） |
| 0x4000_0000 ~ 0x4000_00FF | 256B | reg_bank          |
| 0x4000_0100 ~ 0x4000_01FF | 256B | dma_regs          |
| 0x4000_0200 ~ 0x4000_02FF | 256B | uart_regs         |
| 0x4000_0300 ~ 0x4000_03FF | 256B | spi_regs          |
| 0x4000_0400 ~ 0x4000_04FF | 256B | fifo_regs         |
|                           |      |                   |

## SRAM 窗口的当前职责

| 窗口 | 当前主用途 | 典型写入方 | 典型读取方 | 备注 |
| --- | --- | --- | --- | --- |
| `instr_sram` | E203 bootloader / rescue 指令区 | TB、JTAG rescue loader | E203 IFU | 当前 `run_e203_icarus.sh` 和 `run_jtag_rescue_top_icarus.sh` 都会实际使用 |
| `data_sram` | 推理 bit-plane 暂存区；E203 app 装载区 | TB、E203 bootloader、JTAG rescue loader | DMA、E203 LSU | 当前主线默认 DMA 源窗口 |
| `weight_sram` | V1 保留/调试窗口，支持 live patch | DMA（`DST_SEL=WEIGHT_SRAM`）、JTAG rescue loader | 调试逻辑、V2 权重缓存扩展 | V1 不参与正式推理数据流；V2 计划用于片上权重缓存 |

## MMIO 窗口职责

- `reg_bank`：SNN 主控制寄存器，负责阈值、帧数、测试模式、推理启动、sticky done/status。
- `dma_regs`：DMA 源地址、长度、目标选择与 `DONE/ERR/BUSY` 状态。
- `uart_regs`：当前主线 TX 可用，RX 仍为预留。
- `spi_regs`：当前主线 Mode 0 主控接口，供 E203 bootloader 与 bare-metal 应用访问。
- `fifo_regs`：input/output FIFO 只读计数与满空状态，便于 bring-up 和回归排障。

## 当前主数据流

- 正式推理输入路径是 `data_sram -> dma_engine -> input_fifo -> cim_array_ctrl`。
- `weight_sram` 仍保留在地址空间内，但它不是当前 `main` 分支默认 DMA 源，也不是当前正式推理输入窗口。
- `instr_sram` / `data_sram` / `weight_sram` 三个 SRAM 窗口都可由 JTAG rescue loader 访问，这是当前硅上/板级救援路径的基础假设。

## data_sram 布局（bit-plane）
- 每个 bit-plane 为 64-bit（`NUM_INPUTS=64`），对应同一子时间步的 64 维特征向量第 `x` 位。
- 每个 bit-plane 在 `data_sram` 中拆成 2 个 32-bit word：
  - `word0 = bit[31:0]`
  - `word1 = bit[63:32]`
- 每帧包含 `PIXEL_BITS` 个 bit-plane，顺序为 `MSB -> LSB`。
- `DMA_LEN_WORDS = frames * PIXEL_BITS * 2`。
- `DMA_SRC_ADDR` 需 4B 对齐，且 `[SRC, SRC+LEN-1]` 不得越界 `data_sram`。

## 当前主线的地址使用约定

- E203 启动链中，bootloader 常驻 `instr_sram`，应用镜像经 SPI boot 装载到 `data_sram @ 0x0001_0000` 后再跳转执行。
- 纯 RTL 推理 smoke / sample align 中，TB 直接把 bit-plane 数据写入 `data_sram`，然后由 DMA 读出送往 `input_fifo`。
- 若同一次 bring-up 同时涉及 E203 应用和推理输入，需要软件自行规避 `data_sram` 地址重叠；仓库当前没有硬件级地址隔离机制。
- `weight_sram` 当前更适合作为保留、调试和 live patch 窗口使用，不应被误认为当前主线 sample-align 所依赖的正式权重来源。

## bring-up / tapeout 前复核点

- 若 DMA 目标是 `INPUT_FIFO`，则 `DMA_LEN_WORDS` 必须为偶数，因为硬件会把两个 32-bit word 拼成一个 64-bit bit-plane。
- 若需要验证纯数字链路，不依赖真实模拟宏，可优先使用 `CIM_TEST` 模式；此时地址空间和 SRAM 路径仍与正式流一致，只是模拟侧被 fake response 旁路。
- `OUT_FIFO_DATA` 是“读一次弹出一次”的语义；调试时若反复读取同一地址，必须把它视为消费操作，而不是无副作用窥视。
