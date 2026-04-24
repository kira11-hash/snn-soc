/*
 * fw/v2_e203_smoke/include/soc_regs_v2_e203.h
 *
 * V2E203 FPGA 支线专用 MMIO/DMEM layout header.
 *
 * 【纪律】V2 固件**绝不** include `fw/include/soc_regs.h`（V1 layout）。
 * 本头文件是本支线 smoke + encoder 两套固件的唯一 register map 来源。
 * Phase A grep check: rg -n '#include.*soc_regs' fw/v2_e203_smoke | rg -v soc_regs_v2_e203
 * 必须 0 命中。
 */

#ifndef SOC_REGS_V2_E203_H
#define SOC_REGS_V2_E203_H

#include <stdint.h>

/* =======================================================================
 * UART (V2E203 专用窗口，不是 V1 的 0x4000_0200)
 * ======================================================================= */
#define UART_BASE_V2E203       0x02000000u
#define UART_TXDATA            (*(volatile uint32_t *)(UART_BASE_V2E203 + 0x00u))
#define UART_RXDATA            (*(volatile uint32_t *)(UART_BASE_V2E203 + 0x04u))
#define UART_STATUS            (*(volatile uint32_t *)(UART_BASE_V2E203 + 0x08u))
#define UART_CTRL              (*(volatile uint32_t *)(UART_BASE_V2E203 + 0x0Cu))
#define UART_STATUS_TX_BUSY    (1u << 0)
#define UART_BAUD_DIV          434u  /* 50 MHz / 115200 */

/* =======================================================================
 * V2B accelerator window (snn_soc_v2b_top cmd/rsp, 12-bit offsets)
 * ======================================================================= */
#define V2B_SOC_BASE           0xA0000000u

#define V2B_STAGE_CTRL         (*(volatile uint32_t *)(V2B_SOC_BASE + 0x000u))
#define V2B_STAGE_STATUS       (*(volatile uint32_t *)(V2B_SOC_BASE + 0x004u))
#define V2B_STAGE_CFG0         (*(volatile uint32_t *)(V2B_SOC_BASE + 0x008u))
#define V2B_STAGE_CFG1         (*(volatile uint32_t *)(V2B_SOC_BASE + 0x00Cu))
#define V2B_STAGE_CFG2         (*(volatile uint32_t *)(V2B_SOC_BASE + 0x010u))
#define V2B_STAGE_CFG3         (*(volatile uint32_t *)(V2B_SOC_BASE + 0x014u))
#define V2B_STAGE_CFG5         (*(volatile uint32_t *)(V2B_SOC_BASE + 0x01Cu))

#define V2B_STAGE_CTRL_START   (1u << 0)
#define V2B_STAGE_CTRL_DONE    (1u << 7)  /* W1C */
#define V2B_STAGE_STATUS_BUSY_MASK  (1u << 0)

#define V2B_CFG3_INPUT_SRC_SHIFT    0
#define V2B_CFG3_OUTPUT_DST_SHIFT   8
#define V2B_CFG3_IS_TILE_FINAL_SHIFT 17

#define V2B_BUF_SEL_INPUT_SRAM 0u
#define V2B_BUF_SEL_STREAM_A   1u
#define V2B_BUF_SEL_STREAM_B   2u

#define V2B_INPUT_SRAM_ADDR    (*(volatile uint32_t *)(V2B_SOC_BASE + 0x020u))
#define V2B_INPUT_SRAM_W0      (*(volatile uint32_t *)(V2B_SOC_BASE + 0x024u))
#define V2B_INPUT_SRAM_W7      (*(volatile uint32_t *)(V2B_SOC_BASE + 0x040u))
#define V2B_INPUT_SRAM_CTRL    (*(volatile uint32_t *)(V2B_SOC_BASE + 0x044u))

#define V2B_MAC_W_LOAD_ADDR    (*(volatile uint32_t *)(V2B_SOC_BASE + 0x050u))
#define V2B_MAC_W_LOAD_DATA    (*(volatile uint32_t *)(V2B_SOC_BASE + 0x054u))
#define V2B_MAC_W_LOAD_CTRL    (*(volatile uint32_t *)(V2B_SOC_BASE + 0x058u))

#define V2B_STREAM_BUF_CTRL    (*(volatile uint32_t *)(V2B_SOC_BASE + 0x060u))
#define V2B_STREAM_BUF_CLEAR_A (1u << 1)
#define V2B_STREAM_BUF_CLEAR_B (1u << 2)

#define V2B_READ_SBB_BASE      (V2B_SOC_BASE + 0x800u)
#define V2B_READ_SBB(t)        (*(volatile uint32_t *)(V2B_READ_SBB_BASE + ((t) << 2)))

/* =======================================================================
 * DMEM layout (8 KB @ 0x0001_0000..0x0001_1FFF)
 *
 * 0x0001_0000..0x0001_07FF : .bss + scratch (firmware-managed)
 * 0x0001_0800..0x0001_0FFF : .encoder_stream_buf (NOLOAD, encoder build only)
 *                            256-bit × 64 row = 2 KB
 * 0x0001_1000..0x0001_11FF : smoke counts buffer (10 samples × 10 classes × 4 B = 400 B)
 * 0x0001_1200..0x0001_129F : smoke sample-done flags (10 × 4 B = 40 B)
 * 0x0001_12A0..0x0001_1DFF : reserved / stack region
 * 0x0001_1DFF = __stack_reserve start (stack grows down from __stack_top)
 * 0x0001_1E00..0x0001_1E0F : encoder RPC handshake (req/done/all_done)
 * 0x0001_1F00..0x0001_1FFF : marker block (6 word + pad)
 * ======================================================================= */
#define DMEM_BASE                  0x00010000u
#define DMEM_END                   0x00011FFFu

#define ENCODER_STREAM_BASE        0x00010800u     /* 2 KB, NOLOAD */
#define SMOKE_COUNTS_BUF_BASE      0x00011000u     /* 400 B */
#define SAMPLE_DONE_FLAGS_BASE     0x00011200u     /* 40 B */

#define ENCODER_SAMPLE_REQ_ADDR    0x00011E00u     /* TB writes sample_idx; 0xFF = all done */
#define ENCODER_SAMPLE_DONE_ADDR   0x00011E04u     /* FW writes last-completed sample_idx */

#define MARKER_BASE                0x00011F00u
#define V2E203_BOOT_MARK_ADDR        (MARKER_BASE + 0x00u)
#define V2E203_INFER_DONE_MARK_ADDR  (MARKER_BASE + 0x04u)
#define V2E203_ENCODER_DONE_MARK_ADDR (MARKER_BASE + 0x08u)
#define BUFFER_PTR_0_ADDR          (MARKER_BASE + 0x0Cu)
#define BUFFER_PTR_1_ADDR          (MARKER_BASE + 0x10u)
#define BUFFER_PTR_2_ADDR          (MARKER_BASE + 0x14u)

/* Exact marker values (match plan v11 & doc/00_architecture.md §3.1) */
#define V2E203_BOOT_MARK           0xB0070001u
#define V2E203_INFER_DONE_MARK     0x1F4ED001u
#define V2E203_ENCODER_DONE_MARK   0x31C0D001u

#define MARKER_W(addr)  (*(volatile uint32_t *)(uintptr_t)(addr))

/* Runtime topology constants (shared by smoke + encoder) */
#define S0_IN_DIM   196u
#define S0_OUT_DIM   64u
#define S1_IN_DIM    64u
#define S1_OUT_DIM   10u
#define T_COUNT      64u
#define WORDS_PER_ROW 8u

#endif /* SOC_REGS_V2_E203_H */
