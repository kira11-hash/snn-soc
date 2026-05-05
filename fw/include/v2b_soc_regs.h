#ifndef V2B_SOC_REGS_H
#define V2B_SOC_REGS_H

/*
 * V2.B standalone SoC register map (matches rtl/top/snn_soc_v2b_top.sv).
 *
 * This is the register map used by the *standalone* V2.B pipeline that
 * was bit-exact-validated in tb/v2b_soc_top_parity_tb.sv (10 Fashion
 * 14×14 samples). The production register map (future E203 + reg_bank
 * integration at offset 0x50+) is documented in v2b_stage_regs.h and
 * retains the same semantic contract.
 *
 * Base address is platform-dependent (TB drives the bus directly). When
 * this header is consumed by firmware running on a CPU whose bus is
 * mapped to the V2B top, V2B_SOC_BASE should point at the v2b_top's
 * cmd_* interface decode.
 */

#include <stdint.h>

#ifndef V2B_SOC_BASE
#define V2B_SOC_BASE 0x50000000u
#endif

/* Cast through uintptr_t so this header is portable between 32-bit (E203)
 * and 64-bit (Cortex-A53 ARM) hosts without triggering -Wint-to-pointer-cast. */
#define V2B_SOC_REG(off) \
    (*(volatile uint32_t *)(uintptr_t)((V2B_SOC_BASE) + (off)))
#define V2B_SOC_REG8(off) \
    (*(volatile uint8_t *)(uintptr_t)((V2B_SOC_BASE) + (off)))

/* ── STAGE_CTRL / STATUS / CFG ─────────────────────────────────── */
#define V2B_SOC_STAGE_CTRL    V2B_SOC_REG(0x000u)
#define V2B_SOC_STAGE_STATUS  V2B_SOC_REG(0x004u)
#define V2B_SOC_STAGE_CFG0    V2B_SOC_REG(0x008u)  /* [15:0] in_dim, [31:16] out_dim */
#define V2B_SOC_STAGE_CFG1    V2B_SOC_REG(0x00Cu)  /* threshold */
#define V2B_SOC_STAGE_CFG2    V2B_SOC_REG(0x010u)  /* sum_max */
#define V2B_SOC_STAGE_CFG3    V2B_SOC_REG(0x014u)
#define V2B_SOC_STAGE_CFG4    V2B_SOC_REG(0x018u)
#define V2B_SOC_STAGE_CFG5    V2B_SOC_REG(0x01Cu)  /* [15:0] t_count */

/* ── Input SRAM write (256-bit row = 8 × 32-bit chunks) ───────── */
#define V2B_SOC_INPUT_SRAM_ADDR V2B_SOC_REG(0x020u)
#define V2B_SOC_INPUT_SRAM_W0   V2B_SOC_REG(0x024u)
#define V2B_SOC_INPUT_SRAM_W1   V2B_SOC_REG(0x028u)
#define V2B_SOC_INPUT_SRAM_W2   V2B_SOC_REG(0x02Cu)
#define V2B_SOC_INPUT_SRAM_W3   V2B_SOC_REG(0x030u)
#define V2B_SOC_INPUT_SRAM_W4   V2B_SOC_REG(0x034u)
#define V2B_SOC_INPUT_SRAM_W5   V2B_SOC_REG(0x038u)
#define V2B_SOC_INPUT_SRAM_W6   V2B_SOC_REG(0x03Cu)
#define V2B_SOC_INPUT_SRAM_W7   V2B_SOC_REG(0x040u)
#define V2B_SOC_INPUT_SRAM_CTRL V2B_SOC_REG(0x044u)

/* ── MAC weight load (per-cell single pos/neg 4-bit level) ────── */
#define V2B_SOC_MAC_W_LOAD_ADDR V2B_SOC_REG(0x050u)  /* [7:0] i, [14:8] j */
#define V2B_SOC_MAC_W_LOAD_DATA V2B_SOC_REG(0x054u)  /* [3:0] pos, [7:4] neg */
#define V2B_SOC_MAC_W_LOAD_CTRL V2B_SOC_REG(0x058u)  /* [0] = WRITE_STROBE */

/* ── Stream buffer / state control ────────────────────────────── */
#define V2B_SOC_STREAM_BUF_CTRL V2B_SOC_REG(0x060u)
#define V2B_SOC_STATE_CTRL      V2B_SOC_REG(0x064u)

/* ── M1 trace-hash recorder CSR window (0x068-0x078) ──────────────
 * Phase 1 add-on per essay/m1_design_doc_2026_05_05.md (Codex PASS).
 * 0x07C / 0x080 reserved for H1 Phase 2B; do NOT use here.
 *
 * CTRL bit layout (RW unless noted):
 *   [0]     ENABLE
 *   [1]     CLEAR_W1P (W1P; reads as 0)
 *   [10:8]  LAYER_ID (3-bit)
 *   [16]    OVERFLOW_RO  (read-only mirror of trace_hash_recorder.log_overflow)
 *   [17]    LAYER_ID_FAULT_RO
 *
 * RD_META bit layout (read-only; high [31:16] = 0):
 *   [7:0]   t_idx
 *   [10:8]  layer_id
 *   [11]    buf_sel  (0=A, 1=B)
 */
#define V2B_SOC_TRACE_HASH_CTRL        V2B_SOC_REG(0x068u)
#define V2B_SOC_TRACE_HASH_LOG_COUNT   V2B_SOC_REG(0x06Cu)
#define V2B_SOC_TRACE_HASH_LOG_RD_ADDR V2B_SOC_REG(0x070u)
#define V2B_SOC_TRACE_HASH_LOG_RD_DATA V2B_SOC_REG(0x074u)
#define V2B_SOC_TRACE_HASH_LOG_RD_META V2B_SOC_REG(0x078u)

/* CTRL bit field encoders / decoders */
#define V2B_TRACE_HASH_CTRL_ENABLE_BIT          (1u << 0)
#define V2B_TRACE_HASH_CTRL_CLEAR_W1P_BIT       (1u << 1)
#define V2B_TRACE_HASH_CTRL_LAYER_ID_LSB        8
#define V2B_TRACE_HASH_CTRL_LAYER_ID_MASK       (0x7u << V2B_TRACE_HASH_CTRL_LAYER_ID_LSB)
#define V2B_TRACE_HASH_CTRL_OVERFLOW_RO_BIT     (1u << 16)
#define V2B_TRACE_HASH_CTRL_LAYER_ID_FAULT_BIT  (1u << 17)
#define V2B_TRACE_HASH_MAX_LAYER_ID             7u

/* RD_META decoders */
#define V2B_TRACE_HASH_META_RAW16(m)     ((uint32_t)(m) & 0xFFFFu)
#define V2B_TRACE_HASH_META_T_IDX(m)     (V2B_TRACE_HASH_META_RAW16(m) & 0xFFu)
#define V2B_TRACE_HASH_META_LAYER_ID(m)  ((V2B_TRACE_HASH_META_RAW16(m) >> 8) & 0x7u)
#define V2B_TRACE_HASH_META_BUF_SEL(m)   ((V2B_TRACE_HASH_META_RAW16(m) >> 11) & 0x1u)

/* Recorder log depth (informational only; runtime code should trust LOG_COUNT). */
#define V2B_TRACE_HASH_LOG_DEPTH 2048u

/* ── CONV extension registers ─────────────────────────────────── */
#define V2B_SOC_CONV_MODE_CFG      V2B_SOC_REG(0x084u)
#define V2B_SOC_CONV_CFG_HW        V2B_SOC_REG(0x088u)
#define V2B_SOC_CONV_CFG_C         V2B_SOC_REG(0x08Cu)
#define V2B_SOC_CONV_CFG_K_S_P     V2B_SOC_REG(0x090u)
#define V2B_SOC_CONV_CFG_OUT_HW    V2B_SOC_REG(0x094u)
#define V2B_SOC_CONV_CFG_T         V2B_SOC_REG(0x098u)
#define V2B_SOC_CONV_CFG_TILE      V2B_SOC_REG(0x09Cu)
#define V2B_SOC_CONV_CFG_FMAP_BASE V2B_SOC_REG(0x0A0u)
#define V2B_SOC_CONV_CFG_OUT_BASE  V2B_SOC_REG(0x0A4u)
#define V2B_SOC_CONV_CTRL          V2B_SOC_REG(0x0A8u)
#define V2B_SOC_CONV_STATUS        V2B_SOC_REG(0x0ACu)
#define V2B_SOC_CONV_FMAP_WR_DATA  V2B_SOC_REG(0x0B0u)
#define V2B_SOC_CONV_FMAP_WR_ADDR  V2B_SOC_REG(0x0B4u)
#define V2B_SOC_CONV_PERF_CYCLES   V2B_SOC_REG(0x0B8u)
#define V2B_SOC_CONV_FMAP_WR_CTRL  V2B_SOC_REG(0x0BCu)

/* ── Bulk read of stream buffers (RO) ─────────────────────────── */
/* READ_SBA[t]: 0x400 + t*4  (32 low bits of stream_buf_A[t], t in [0, 255]) */
/* READ_SBB[t]: 0x800 + t*4  (32 low bits of stream_buf_B[t])              */
#define V2B_SOC_READ_SBA_BASE   0x400u
#define V2B_SOC_READ_SBB_BASE   0x800u
#define V2B_SOC_READ_SBA(t)     V2B_SOC_REG(V2B_SOC_READ_SBA_BASE + (uint32_t)(t) * 4u)
#define V2B_SOC_READ_SBB(t)     V2B_SOC_REG(V2B_SOC_READ_SBB_BASE + (uint32_t)(t) * 4u)

/* ── STAGE_CTRL bits ──────────────────────────────────────────── */
#define V2B_SOC_STAGE_CTRL_START  (1u << 0)
#define V2B_SOC_STAGE_CTRL_ABORT  (1u << 1)
#define V2B_SOC_STAGE_CTRL_DONE   (1u << 7)

/* ── STAGE_STATUS decoders ────────────────────────────────────── */
#define V2B_SOC_STAGE_BUSY(x)  ((x) & 0x1u)
#define V2B_SOC_STAGE_T_IDX(x) (((x) >> 8) & 0xFFu)
#define V2B_SOC_STAGE_ERR(x)   (((x) >> 16) & 0xFFu)

/* ── STAGE_CFG3 layout ────────────────────────────────────────── */
#define V2B_SOC_CFG3_INPUT_SRC_SHIFT          0
#define V2B_SOC_CFG3_OUTPUT_DST_SHIFT         8
#define V2B_SOC_CFG3_TILE_MODE_SHIFT          16
#define V2B_SOC_CFG3_IS_TILE_FINAL_SHIFT      17
#define V2B_SOC_CFG3_PRESERVE_MEMBRANE_SHIFT  18

/* ── Buffer selects (must match rtl/top/snn_soc_pkg::V2B_BUF_SEL_*) ── */
#define V2B_SOC_BUF_SEL_INPUT_SRAM  0u
#define V2B_SOC_BUF_SEL_STREAM_A    1u
#define V2B_SOC_BUF_SEL_STREAM_B    2u
#define V2B_SOC_BUF_SEL_OUTPUT_FIFO 3u
#define V2B_SOC_BUF_SEL_PATCH_UNROLLER 4u
#define V2B_SOC_BUF_SEL_FMAP_FLATTEN  5u

/* ── MAC_W_LOAD_ADDR encoding ─────────────────────────────────── */
#define V2B_SOC_MAC_W_LOAD_PACK(i, j)  (((uint32_t)(j) << 8) | ((uint32_t)(i) & 0xFFu))

/* ── MAC_W_LOAD_DATA encoding (pos + neg 4-bit levels) ────────── */
#define V2B_SOC_MAC_W_DATA_PACK(pos, neg) (((uint32_t)(neg) << 4) | ((uint32_t)(pos) & 0xFu))

/* ── STREAM_BUF_CTRL bits ─────────────────────────────────────── */
#define V2B_SOC_STREAM_BUF_SWAP            (1u << 0)
#define V2B_SOC_STREAM_BUF_CLEAR_A         (1u << 1)
#define V2B_SOC_STREAM_BUF_CLEAR_B         (1u << 2)
#define V2B_SOC_STREAM_BUF_CLEAR_TILE_BUF  (1u << 3)

/* ── CONV_MODE_CFG / CONV_CTRL / CONV_STATUS / FMAP_WR_CTRL bits ── */
#define V2B_SOC_CONV_MODE_EN             (1u << 0)
#define V2B_SOC_CONV_FLATTEN_MODE        (1u << 1)
#define V2B_SOC_CONV_FMAP_PP_SEL         (1u << 2)
#define V2B_SOC_CONV_WEIGHT_TIMEOUT_EN   (1u << 3)

#define V2B_SOC_CONV_CTRL_START          (1u << 0)
#define V2B_SOC_CONV_CTRL_ABORT          (1u << 1)
#define V2B_SOC_CONV_CTRL_WEIGHT_READY   (1u << 2)

#define V2B_SOC_CONV_STATUS_BUSY         (1u << 0)
#define V2B_SOC_CONV_STATUS_DONE         (1u << 1)
#define V2B_SOC_CONV_STATUS_WEIGHT_REQ   (1u << 2)
#define V2B_SOC_CONV_STATUS_ERR(x)       (((x) >> 4) & 0xFu)
#define V2B_SOC_CONV_STATUS_CUR_H(x)     (((x) >> 8) & 0xFFu)
#define V2B_SOC_CONV_STATUS_CUR_W(x)     (((x) >> 16) & 0xFFu)
#define V2B_SOC_CONV_STATUS_CUR_TILE(x)  (((x) >> 24) & 0xFFu)

#define V2B_SOC_CONV_FMAP_WR_COMMIT      (1u << 0)
#define V2B_SOC_CONV_FMAP_WR_AUTO_INC    (1u << 1)
#define V2B_SOC_CONV_FMAP_WR_TARGET_BANK (1u << 2)

#endif /* V2B_SOC_REGS_H */
