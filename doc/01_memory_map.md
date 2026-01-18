# 01_memory_map

## 地址空间表
| 起始地址 | 结束地址 | 大小 | 用途 |
|---|---|---:|---|
| 0x0000_0000 | 0x0000_FFFF | 64KB | instr_sram |
| 0x0001_0000 | 0x0002_FFFF | 128KB | data_sram |
| 0x0003_0000 | 0x0003_3FFF | 16KB | weight_sram |
| 0x4000_0000 | 0x4000_00FF | 256B | reg_bank |
| 0x4000_0100 | 0x4000_01FF | 256B | dma_regs |
| 0x4000_0200 | 0x4000_02FF | 256B | uart_regs (stub) |
| 0x4000_0300 | 0x4000_03FF | 256B | spi_regs (stub) |
| 0x4000_0400 | 0x4000_04FF | 256B | fifo_regs |

## 地址对应模块文件
- instr_sram: `rtl/mem/sram_simple.sv`
- data_sram: `rtl/mem/sram_simple_dp.sv`
- weight_sram: `rtl/mem/sram_simple.sv`
- reg_bank: `rtl/reg/reg_bank.sv`
- dma_regs + DMA 引擎: `rtl/dma/dma_engine.sv`
- uart_regs: `rtl/periph/uart_stub.sv`
- spi_regs: `rtl/periph/spi_stub.sv`
- fifo_regs: `rtl/reg/fifo_regs.sv`
