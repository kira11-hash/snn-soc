#ifndef V2B_STAGE_REGS_H
#define V2B_STAGE_REGS_H

/*
 * V2.B register offsets per doc/18_v2b_phase_b0_minispec.md §B0.1.
 *
 * These addresses live inside reg_bank (base 0x4000_0000). The
 * reg_bank expansion covering 0x50-0x7F is part of B1 RTL work
 * (not yet implemented — firmware uses the offsets here as the
 * definitive contract).
 */

#include <stdint.h>
#include "soc_regs.h"  /* REG_BANK_BASE */

/* ── STAGE_CTRL / STATUS / CFG0..5 (run_streamed_stage) ────────── */
#define V2B_REG_STAGE_CTRL   (*(volatile uint32_t *)(REG_BANK_BASE + 0x50u))
#define V2B_REG_STAGE_STATUS (*(volatile uint32_t *)(REG_BANK_BASE + 0x54u))
#define V2B_REG_STAGE_CFG0   (*(volatile uint32_t *)(REG_BANK_BASE + 0x58u))
#define V2B_REG_STAGE_CFG1   (*(volatile uint32_t *)(REG_BANK_BASE + 0x5Cu))
#define V2B_REG_STAGE_CFG2   (*(volatile uint32_t *)(REG_BANK_BASE + 0x60u))
#define V2B_REG_STAGE_CFG3   (*(volatile uint32_t *)(REG_BANK_BASE + 0x64u))
#define V2B_REG_STAGE_CFG4   (*(volatile uint32_t *)(REG_BANK_BASE + 0x68u))
#define V2B_REG_STAGE_CFG5   (*(volatile uint32_t *)(REG_BANK_BASE + 0x6Cu))

/* ── Stream buffer ownership ───────────────────────────────────── */
#define V2B_REG_STREAM_BUF_CTRL   (*(volatile uint32_t *)(REG_BANK_BASE + 0x70u))
#define V2B_REG_STREAM_BUF_STATUS (*(volatile uint32_t *)(REG_BANK_BASE + 0x74u))

/* ── LIF / membrane state control ─────────────────────────────── */
#define V2B_REG_STATE_CTRL  (*(volatile uint32_t *)(REG_BANK_BASE + 0x78u))

/* ── ADC policy ───────────────────────────────────────────────── */
#define V2B_REG_ADC_CFG     (*(volatile uint32_t *)(REG_BANK_BASE + 0x80u))

/* ── STAGE_CTRL bit fields ────────────────────────────────────── */
#define V2B_STAGE_CTRL_START  (1u << 0)
#define V2B_STAGE_CTRL_ABORT  (1u << 1)
#define V2B_STAGE_CTRL_DONE   (1u << 7)

/* ── STAGE_STATUS bit fields ──────────────────────────────────── */
#define V2B_STAGE_STATUS_BUSY(x)  ((x) & 0x1u)
#define V2B_STAGE_STATUS_TPB_CLEAR_BUSY(x) (((x) >> 1) & 0x1u)
#define V2B_STAGE_STATUS_T_IDX(x) (((x) >> 8) & 0xFFu)
#define V2B_STAGE_STATUS_ERR(x)   (((x) >> 16) & 0xFFu)

/* ── STAGE_CFG3 bit fields ────────────────────────────────────── */
#define V2B_CFG3_INPUT_SRC_SHIFT          0
#define V2B_CFG3_OUTPUT_DST_SHIFT         8
#define V2B_CFG3_TILE_MODE_SHIFT          16
#define V2B_CFG3_IS_TILE_FINAL_SHIFT      17
#define V2B_CFG3_PRESERVE_MEMBRANE_SHIFT  18

/* ── Buffer selection encoding (per snn_soc_pkg::V2B_BUF_SEL_*) ── */
#define V2B_BUF_SEL_INPUT_SRAM   0u
#define V2B_BUF_SEL_STREAM_A     1u
#define V2B_BUF_SEL_STREAM_B     2u
#define V2B_BUF_SEL_OUTPUT_FIFO  3u

/* ── STREAM_BUF_CTRL bit fields ───────────────────────────────── */
#define V2B_STREAM_BUF_SWAP              (1u << 0)
#define V2B_STREAM_BUF_CLEAR_A           (1u << 1)
#define V2B_STREAM_BUF_CLEAR_B           (1u << 2)
#define V2B_STREAM_BUF_CLEAR_TILE_BUF    (1u << 3)

/* ── STATE_CTRL bit fields ────────────────────────────────────── */
#define V2B_STATE_CLEAR_MEMBRANE  (1u << 0)
#define V2B_STATE_CLEAR_ALL       (1u << 1)

/* ── ADC_CFG bit fields ───────────────────────────────────────── */
#define V2B_ADC_CFG_BITS(x)          ((x) & 0xFu)
#define V2B_ADC_CFG_FULL_SCALE(x)    (((x) >> 4) & 0x3u)
#define V2B_ADC_FULL_SCALE_ARRAY     0u
#define V2B_ADC_FULL_SCALE_ACTIVE_WL 1u

/* ── Error codes (STAGE_STATUS.ERR) ───────────────────────────── */
#define V2B_STAGE_ERR_OK                   0x00u
#define V2B_STAGE_ERR_START_WHILE_BUSY     0x01u
#define V2B_STAGE_ERR_SRC_DST_CONFLICT     0x02u
#define V2B_STAGE_ERR_TILE_BUF_UNAVAILABLE 0x03u
#define V2B_STAGE_ERR_CIM_NOT_READY        0x04u
#define V2B_STAGE_ERR_DIM_OUT_OF_RANGE     0x05u

/* ── input_stream_sram / stream_buf_A / stream_buf_B base addrs ── */
/* Placeholder (B0.6 WIP). Firmware writes pre-encoded pixel streams here. */
#define V2B_INPUT_STREAM_SRAM_BASE   0x00040000u
#define V2B_STREAM_BUF_A_BASE        0x00044000u
#define V2B_STREAM_BUF_B_BASE        0x00048000u
#define V2B_TOPOLOGY_DESC_BASE       0x0004C000u

/* ── Topology descriptor constants (mirror exporter_multilayer.py) ── */
#define V2B_TOPO_DESC_MAGIC      0x544F504Fu  /* "TOPO" LE */
#define V2B_TOPO_DESC_VERSION    0x0001u
#define V2B_TOPO_DESC_MAX_STAGES 8

#endif /* V2B_STAGE_REGS_H */
