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

/* ── MAC_W_LOAD_ADDR encoding ─────────────────────────────────── */
#define V2B_SOC_MAC_W_LOAD_PACK(i, j)  (((uint32_t)(j) << 8) | ((uint32_t)(i) & 0xFFu))

/* ── MAC_W_LOAD_DATA encoding (pos + neg 4-bit levels) ────────── */
#define V2B_SOC_MAC_W_DATA_PACK(pos, neg) (((uint32_t)(neg) << 4) | ((uint32_t)(pos) & 0xFu))

/* ── STREAM_BUF_CTRL bits ─────────────────────────────────────── */
#define V2B_SOC_STREAM_BUF_SWAP            (1u << 0)
#define V2B_SOC_STREAM_BUF_CLEAR_A         (1u << 1)
#define V2B_SOC_STREAM_BUF_CLEAR_B         (1u << 2)
#define V2B_SOC_STREAM_BUF_CLEAR_TILE_BUF  (1u << 3)

#endif /* V2B_SOC_REGS_H */
