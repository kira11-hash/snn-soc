#ifndef SOC_REGS_H
#define SOC_REGS_H

#include <stdint.h>

#define REG_BANK_BASE      0x40000000u
#define DMA_BASE           0x40000100u
#define UART_BASE          0x40000200u
#define SPI_BASE           0x40000300u

#define APP_LOAD_ADDR      0x00010000u
#define APP_LOAD_MAX_BYTES 0x00003000u
#define MARKER_BASE        0x00013F00u

#define BOOT_MARK_ADDR     (*(volatile uint32_t *)(MARKER_BASE + 0x00u))
#define APP_SIGN_ADDR      (*(volatile uint32_t *)(MARKER_BASE + 0x04u))
#define APP_RESULT_ADDR    (*(volatile uint32_t *)(MARKER_BASE + 0x08u))
#define APP_DONE_ADDR      (*(volatile uint32_t *)(MARKER_BASE + 0x0Cu))

#define REG_THRESHOLD      (*(volatile uint32_t *)(REG_BANK_BASE + 0x00u))
#define REG_TIMESTEPS      (*(volatile uint32_t *)(REG_BANK_BASE + 0x04u))
#define REG_OUT_DATA       (*(volatile uint32_t *)(REG_BANK_BASE + 0x1Cu))
#define REG_OUT_COUNT      (*(volatile uint32_t *)(REG_BANK_BASE + 0x20u))
#define CIM_CTRL           (*(volatile uint32_t *)(REG_BANK_BASE + 0x14u))

#define DMA_SRC_ADDR       (*(volatile uint32_t *)(DMA_BASE + 0x00u))
#define DMA_LEN_WORDS      (*(volatile uint32_t *)(DMA_BASE + 0x04u))
#define DMA_CTRL           (*(volatile uint32_t *)(DMA_BASE + 0x08u))

#define UART_TXDATA        (*(volatile uint32_t *)(UART_BASE + 0x00u))
#define UART_STATUS        (*(volatile uint32_t *)(UART_BASE + 0x08u))
#define UART_CTRL          (*(volatile uint32_t *)(UART_BASE + 0x0Cu))

#define SPI_CTRL           (*(volatile uint32_t *)(SPI_BASE + 0x00u))
#define SPI_STATUS         (*(volatile uint32_t *)(SPI_BASE + 0x04u))
#define SPI_TXDATA         (*(volatile uint32_t *)(SPI_BASE + 0x08u))
#define SPI_RXDATA         (*(volatile uint32_t *)(SPI_BASE + 0x0Cu))

#define BOOT_MARK_VALUE    0xB00710ADu
#define APP_SIGN_VALUE     0x12345067u
#define APP_DONE_VALUE     0xC0DE0002u

#define THRESHOLD_VALUE    2550u
#define TIMESTEPS_VALUE    10u
#define DMA_LEN_VALUE      160u
#define UART_BAUD_DIV      2u

#define BOOT_IMAGE_MAGIC   0x544F4F42u /* 'BOOT' */

#endif
