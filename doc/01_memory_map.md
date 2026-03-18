# 01_memory_map

**参数口径**：本文涉及的默认参数与地址范围以 `rtl/top/snn_soc_pkg.sv` 为准，若与文档不一致以 pkg 为准。

| 地址范围                      |   大小 | 模块                |
| ------------------------- | ---: | ----------------- |
| 0x0000_0000 ~ 0x0000_3FFF | 16KB | instr_sram        |
| 0x0001_0000 ~ 0x0001_3FFF | 16KB | data_sram         |
| 0x0003_0000 ~ 0x0003_3FFF | 16KB | weight_sram（保留窗口） |
| 0x4000_0000 ~ 0x4000_00FF | 256B | reg_bank          |
| 0x4000_0100 ~ 0x4000_01FF | 256B | dma_regs          |
| 0x4000_0200 ~ 0x4000_02FF | 256B | uart_regs (stub)  |
| 0x4000_0300 ~ 0x4000_03FF | 256B | spi_regs (stub)   |
| 0x4000_0400 ~ 0x4000_04FF | 256B | fifo_regs         |
|                           |      |                   |

## 当前主数据流
- 当前正式推理输入路径是 `data_sram -> dma_engine -> input_fifo -> cim_array_ctrl`。
- `weight_sram` 仍保留在地址空间内，但它不是当前 `main` 分支默认 DMA 源，也不是当前正式推理输入窗口。

## data_sram 布局（bit-plane）
- 每个 bit-plane 为 64-bit（`NUM_INPUTS=64`），对应同一子时间步的 64 维特征向量第 `x` 位。
- 每个 bit-plane 在 `data_sram` 中拆成 2 个 32-bit word：
  - `word0 = bit[31:0]`
  - `word1 = bit[63:32]`
- 每帧包含 `PIXEL_BITS` 个 bit-plane，顺序为 `MSB -> LSB`。
- `DMA_LEN_WORDS = frames * PIXEL_BITS * 2`。
- `DMA_SRC_ADDR` 需 4B 对齐，且 `[SRC, SRC+LEN-1]` 不得越界 `data_sram`。
