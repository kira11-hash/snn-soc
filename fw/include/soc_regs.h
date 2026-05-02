#ifndef SOC_REGS_H
#define SOC_REGS_H

#include <stdint.h>

#define INSTR_SRAM_BASE   0x00000000u
#define DATA_SRAM_BASE    0x00010000u
#define WEIGHT_SRAM_BASE  0x00030000u

#define REG_BANK_BASE      0x40000000u
#define DMA_BASE           0x40000100u
#define UART_BASE          0x40000200u
#define SPI_BASE           0x40000300u
#define FIFO_BASE          0x40000400u

#define APP_LOAD_ADDR      DATA_SRAM_BASE
#define APP_LOAD_MAX_BYTES 0x00003000u
#define MARKER_BASE        0x00013F00u

#define BOOT_MARK_ADDR     (*(volatile uint32_t *)(MARKER_BASE + 0x00u))
#define APP_SIGN_ADDR      (*(volatile uint32_t *)(MARKER_BASE + 0x04u))
#define APP_RESULT_ADDR    (*(volatile uint32_t *)(MARKER_BASE + 0x08u))
#define APP_DONE_ADDR      (*(volatile uint32_t *)(MARKER_BASE + 0x0Cu))

#define REG_THRESHOLD      (*(volatile uint32_t *)(REG_BANK_BASE + 0x00u))
#define REG_TIMESTEPS      (*(volatile uint32_t *)(REG_BANK_BASE + 0x04u))
#define REG_NUM_INPUTS     (*(volatile uint32_t *)(REG_BANK_BASE + 0x08u))  /* RO */
#define REG_NUM_OUTPUTS    (*(volatile uint32_t *)(REG_BANK_BASE + 0x0Cu))  /* RO */
#define REG_RESET_MODE     (*(volatile uint32_t *)(REG_BANK_BASE + 0x10u))
#define REG_OUT_DATA       (*(volatile uint32_t *)(REG_BANK_BASE + 0x1Cu))
#define REG_OUT_COUNT      (*(volatile uint32_t *)(REG_BANK_BASE + 0x20u))
#define REG_THRESHOLD_RATIO (*(volatile uint32_t *)(REG_BANK_BASE + 0x24u))
#define REG_ADC_SAT_COUNT  (*(volatile uint32_t *)(REG_BANK_BASE + 0x28u))
#define REG_CIM_TEST       (*(volatile uint32_t *)(REG_BANK_BASE + 0x2Cu))
#define REG_DBG_CNT_0      (*(volatile uint32_t *)(REG_BANK_BASE + 0x30u))
#define REG_DBG_CNT_1      (*(volatile uint32_t *)(REG_BANK_BASE + 0x34u))
#define REG_STATUS         (*(volatile uint32_t *)(REG_BANK_BASE + 0x18u))
#define CIM_CTRL           (*(volatile uint32_t *)(REG_BANK_BASE + 0x14u))

/* CIM programming registers (only present when ENABLE_PROGRAM_MODE=1).
 * Authoritative offsets: doc/02_reg_map.md / CLAUDE.md "CIM 编程寄存器".
 * Centralized in soc_regs.h (audit-pass4 M-2) so silicon_bringup.c / main.c /
 * e203_fpga_smoke.c stop carrying their own drift-prone aliases. */
#define PROG_CTRL          (*(volatile uint32_t *)(REG_BANK_BASE + 0x38u))
#define PROG_ROW           (*(volatile uint32_t *)(REG_BANK_BASE + 0x3Cu))
#define PROG_COL           (*(volatile uint32_t *)(REG_BANK_BASE + 0x40u))
#define PROG_STATUS        (*(volatile uint32_t *)(REG_BANK_BASE + 0x44u))
#define PROG_PULSE_WIDTH   (*(volatile uint32_t *)(REG_BANK_BASE + 0x90u))
#define PROG_ERASE_WIDTH   (*(volatile uint32_t *)(REG_BANK_BASE + 0x94u))

#define DMA_SRC_ADDR       (*(volatile uint32_t *)(DMA_BASE + 0x00u))
#define DMA_LEN_WORDS      (*(volatile uint32_t *)(DMA_BASE + 0x04u))
#define DMA_CTRL           (*(volatile uint32_t *)(DMA_BASE + 0x08u))
#define DMA_DST_SEL        (*(volatile uint32_t *)(DMA_BASE + 0x0Cu))

#define UART_TXDATA        (*(volatile uint32_t *)(UART_BASE + 0x00u))
#define UART_RXDATA        (*(volatile uint32_t *)(UART_BASE + 0x04u))  /* RX V2, read-only */
#define UART_STATUS        (*(volatile uint32_t *)(UART_BASE + 0x08u))
#define UART_CTRL          (*(volatile uint32_t *)(UART_BASE + 0x0Cu))

#define SPI_CTRL           (*(volatile uint32_t *)(SPI_BASE + 0x00u))
#define SPI_STATUS         (*(volatile uint32_t *)(SPI_BASE + 0x04u))
#define SPI_TXDATA         (*(volatile uint32_t *)(SPI_BASE + 0x08u))
#define SPI_RXDATA         (*(volatile uint32_t *)(SPI_BASE + 0x0Cu))

#define FIFO_IN_COUNT      (*(volatile uint32_t *)(FIFO_BASE + 0x00u))
#define FIFO_OUT_COUNT     (*(volatile uint32_t *)(FIFO_BASE + 0x04u))
#define FIFO_STATUS        (*(volatile uint32_t *)(FIFO_BASE + 0x08u))

#define CIM_CTRL_START_MASK       (1u << 0)
#define CIM_CTRL_SOFT_RESET_MASK  (1u << 1)
#define CIM_CTRL_DONE_MASK        (1u << 7)

#define REG_STATUS_BUSY_MASK            (1u << 0)
#define REG_STATUS_IN_FIFO_EMPTY_MASK   (1u << 1)
#define REG_STATUS_IN_FIFO_FULL_MASK    (1u << 2)
#define REG_STATUS_OUT_FIFO_EMPTY_MASK  (1u << 3)
#define REG_STATUS_OUT_FIFO_FULL_MASK   (1u << 4)
#define REG_STATUS_TIMESTEP_CNT_SHIFT   8u
#define REG_STATUS_TIMESTEP_CNT_MASK    (0xFFu << REG_STATUS_TIMESTEP_CNT_SHIFT)

#define DMA_CTRL_START_MASK  (1u << 0)
#define DMA_CTRL_DONE_MASK   (1u << 1)
#define DMA_CTRL_ERR_MASK    (1u << 2)
#define DMA_CTRL_BUSY_MASK   (1u << 3)

#define DMA_DST_INPUT_FIFO   0u
#define DMA_DST_WEIGHT_SRAM  1u
#define DMA_DST_INSTR_SRAM   2u

#define UART_STATUS_TX_BUSY_MASK  (1u << 0)

#define SPI_CTRL_ENABLE_MASK       (1u << 0)
#define SPI_CTRL_CLKDIV_SHIFT      1u
#define SPI_CTRL_CLKDIV_MASK       (0x7u << SPI_CTRL_CLKDIV_SHIFT)
#define SPI_CTRL_CS_FORCE_MASK     (1u << 8)
#define SPI_STATUS_BUSY_MASK       (1u << 0)
#define SPI_STATUS_RX_VALID_MASK   (1u << 1)

/* PROG_CTRL bit fields (REG_BANK + 0x38).  See CLAUDE.md "PROG_CTRL" row. */
#define PROG_CTRL_START_MASK       (1u << 0)
#define PROG_CTRL_ERASE_MASK       (1u << 1)
#define PROG_CTRL_FULL_ARRAY_MASK  (1u << 2)
#define PROG_CTRL_BYPASS_MASK      (1u << 3)  /* BYPASS_HANDSHAKE; silicon-bringup only */
#define PROG_CTRL_LEVEL_SHIFT      4u
#define PROG_CTRL_LEVEL_MASK       (0xFu << PROG_CTRL_LEVEL_SHIFT)
#define PROG_CTRL_RETRY_LIMIT_SHIFT 8u
#define PROG_CTRL_RETRY_LIMIT_MASK (0x7u << PROG_CTRL_RETRY_LIMIT_SHIFT)
/* Low-byte mask: covers START/ERASE/FULL_ARRAY/BYPASS/LEVEL[3:0].
 * Use for read-modify-write so RETRY_LIMIT (bits[10:8]) is preserved. */
#define PROG_CTRL_LOW_MASK         0xFFu

/* PROG_STATUS bit fields (REG_BANK + 0x44).
 * bit[6] = PROG_FSM_PRESENT (RO, high if cim_program_ctrl is instantiated;
 * lets fw skip the cycle-bound BUSY probe and avoid races where a fast op
 * completes before BUSY is observed). */
#define PROG_STATUS_BUSY_MASK         (1u << 0)
#define PROG_STATUS_PASS_MASK         (1u << 1)
#define PROG_STATUS_FAIL_MASK         (1u << 2)
#define PROG_STATUS_RETRY_COUNT_SHIFT 3u
#define PROG_STATUS_RETRY_COUNT_MASK  (0x7u << PROG_STATUS_RETRY_COUNT_SHIFT)
#define PROG_STATUS_FSM_PRESENT_MASK  (1u << 6)
#define PROG_STATUS_DONE_MASK         (1u << 7)

#define FIFO_STATUS_IN_EMPTY_MASK   (1u << 0)
#define FIFO_STATUS_IN_FULL_MASK    (1u << 1)
#define FIFO_STATUS_OUT_EMPTY_MASK  (1u << 2)
#define FIFO_STATUS_OUT_FULL_MASK   (1u << 3)

#define BOOT_MARK_VALUE    0xB00710ADu
#define APP_SIGN_VALUE     0x12345067u
#define APP_DONE_VALUE     0xC0DE0002u

#define NUM_INPUTS_VALUE       64u
#define NUM_OUTPUTS_VALUE      10u
#define PIXEL_BITS_VALUE       8u
#define THRESHOLD_RATIO_VALUE  1u
#define THRESHOLD_VALUE    2550u
#define TIMESTEPS_VALUE    10u
#define DMA_LEN_VALUE      (TIMESTEPS_VALUE * PIXEL_BITS_VALUE * 2u)
/*
 * Default board / FPGA bring-up UART divider:
 *   50 MHz / 115200 ~= 434
 * Icarus-only smoke scripts may override this at build time with
 * -DUART_BAUD_DIV=<small value> to shorten simulation runtime.
 */
#ifndef UART_BAUD_DIV
#define UART_BAUD_DIV      434u
#endif

#define BOOT_IMAGE_MAGIC   0x544F4F42u /* 'BOOT' */

#endif
