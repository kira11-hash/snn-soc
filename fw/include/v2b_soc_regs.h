#ifndef V2B_SOC_REGS_H
#define V2B_SOC_REGS_H

/*
 * V2.B standalone SoC 寄存器地址映射（与 rtl/top/snn_soc_v2b_top.sv 一致）。
 *
 * 这是 *standalone* V2.B 流水线使用的寄存器映射；该映射通过
 * tb/v2b_soc_top_parity_tb.sv 在 10 个 Fashion-MNIST 14×14 样本上做过 bit-exact
 * 校验。生产路径下（未来 E203 + reg_bank 集成会从 0x50+ 开始）保留同样的语义合约，
 * 详见 v2b_stage_regs.h。
 *
 * 基址（V2B_SOC_BASE）是平台依赖：TB 直接驱总线时基址无所谓；当固件运行在 CPU 上、
 * 总线被映射到 V2B top 时，V2B_SOC_BASE 应指向 v2b_top 的 cmd_* 接口译码窗口起点。
 *
 * v2-conv 分支扩展：从 0x84 起新增了 CONV_* 寄存器组，覆盖卷积层调度（CONV_CFG_*
 * + CONV_CTRL + CONV_STATUS + CONV_FMAP_WR_* 等），是 LeNet-5 上板的关键。
 */

#include <stdint.h>

#ifndef V2B_SOC_BASE
#define V2B_SOC_BASE 0x50000000u
#endif

/* 经过 uintptr_t 转换，保证 header 在 32-bit (E203) 和 64-bit (Cortex-A53 ARM)
 * host 之间都可移植，避免触发 -Wint-to-pointer-cast 警告。 */
#define V2B_SOC_REG(off) \
    (*(volatile uint32_t *)(uintptr_t)((V2B_SOC_BASE) + (off)))

/* ── STAGE_CTRL / STATUS / CFG（单 stage 调度，Fashion-MNIST 14×14 路径用） ── */
#define V2B_SOC_STAGE_CTRL    V2B_SOC_REG(0x000u)
#define V2B_SOC_STAGE_STATUS  V2B_SOC_REG(0x004u)
#define V2B_SOC_STAGE_CFG0    V2B_SOC_REG(0x008u)  /* [15:0] in_dim, [31:16] out_dim */
#define V2B_SOC_STAGE_CFG1    V2B_SOC_REG(0x00Cu)  /* threshold */
#define V2B_SOC_STAGE_CFG2    V2B_SOC_REG(0x010u)  /* sum_max */
#define V2B_SOC_STAGE_CFG3    V2B_SOC_REG(0x014u)
#define V2B_SOC_STAGE_CFG4    V2B_SOC_REG(0x018u)
#define V2B_SOC_STAGE_CFG5    V2B_SOC_REG(0x01Cu)  /* [15:0] t_count */

/* ── Input SRAM 写入端口（每行 256-bit = 8 个 32-bit chunk） ──────── */
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

/* ── MAC 权重加载（每 cell 写一对 pos/neg 4-bit 电导等级） ────────── */
#define V2B_SOC_MAC_W_LOAD_ADDR V2B_SOC_REG(0x050u)  /* [7:0] i, [14:8] j */
#define V2B_SOC_MAC_W_LOAD_DATA V2B_SOC_REG(0x054u)  /* [3:0] pos, [7:4] neg */
#define V2B_SOC_MAC_W_LOAD_CTRL V2B_SOC_REG(0x058u)  /* [0] = WRITE_STROBE */

/* ── Stream buffer / state 控制 ───────────────────────────────────── */
#define V2B_SOC_STREAM_BUF_CTRL V2B_SOC_REG(0x060u)
#define V2B_SOC_STATE_CTRL      V2B_SOC_REG(0x064u)

/* ── CONV 扩展寄存器组（v2-conv 分支新增；conv_ctrl_v2 / fmap_sram_v2 路径用） ── */
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

/* ── 批量读 stream buffer（只读） ──────────────────────────────────── */
/* READ_SBA[t]: 0x400 + t*4  → stream_buf_A[t] 的低 32 bit，t ∈ [0, 255] */
/* READ_SBB[t]: 0x800 + t*4  → stream_buf_B[t] 的低 32 bit                */
#define V2B_SOC_READ_SBA_BASE   0x400u
#define V2B_SOC_READ_SBB_BASE   0x800u
#define V2B_SOC_READ_SBA(t)     V2B_SOC_REG(V2B_SOC_READ_SBA_BASE + (uint32_t)(t) * 4u)
#define V2B_SOC_READ_SBB(t)     V2B_SOC_REG(V2B_SOC_READ_SBB_BASE + (uint32_t)(t) * 4u)

/* ── STAGE_CTRL 位段 ──────────────────────────────────────────────── */
#define V2B_SOC_STAGE_CTRL_START  (1u << 0)
#define V2B_SOC_STAGE_CTRL_ABORT  (1u << 1)
#define V2B_SOC_STAGE_CTRL_DONE   (1u << 7)

/* ── STAGE_STATUS 解码工具 ────────────────────────────────────────── */
#define V2B_SOC_STAGE_BUSY(x)  ((x) & 0x1u)
#define V2B_SOC_STAGE_T_IDX(x) (((x) >> 8) & 0xFFu)
#define V2B_SOC_STAGE_ERR(x)   (((x) >> 16) & 0xFFu)

/* ── STAGE_CFG3 位段排布 ─────────────────────────────────────────── */
#define V2B_SOC_CFG3_INPUT_SRC_SHIFT          0
#define V2B_SOC_CFG3_OUTPUT_DST_SHIFT         8
#define V2B_SOC_CFG3_TILE_MODE_SHIFT          16
#define V2B_SOC_CFG3_IS_TILE_FINAL_SHIFT      17
#define V2B_SOC_CFG3_PRESERVE_MEMBRANE_SHIFT  18

/* ── Buffer 选择编码（必须与 rtl/top/snn_soc_pkg::V2B_BUF_SEL_* 一致） ── */
#define V2B_SOC_BUF_SEL_INPUT_SRAM  0u
#define V2B_SOC_BUF_SEL_STREAM_A    1u
#define V2B_SOC_BUF_SEL_STREAM_B    2u
#define V2B_SOC_BUF_SEL_OUTPUT_FIFO 3u
#define V2B_SOC_BUF_SEL_PATCH_UNROLLER 4u
#define V2B_SOC_BUF_SEL_FMAP_FLATTEN  5u

/* ── MAC_W_LOAD_ADDR 编码：把 (lane i, out_c j) 打包成寄存器值 ────── */
#define V2B_SOC_MAC_W_LOAD_PACK(i, j)  (((uint32_t)(j) << 8) | ((uint32_t)(i) & 0xFFu))

/* ── MAC_W_LOAD_DATA 编码：把 pos/neg 4-bit 电导等级打包 ─────────── */
#define V2B_SOC_MAC_W_DATA_PACK(pos, neg) (((uint32_t)(neg) << 4) | ((uint32_t)(pos) & 0xFu))

/* ── STREAM_BUF_CTRL 位段 ──────────────────────────────────────── */
#define V2B_SOC_STREAM_BUF_SWAP            (1u << 0)
#define V2B_SOC_STREAM_BUF_CLEAR_A         (1u << 1)
#define V2B_SOC_STREAM_BUF_CLEAR_B         (1u << 2)
#define V2B_SOC_STREAM_BUF_CLEAR_TILE_BUF  (1u << 3)

/* ── CONV_MODE_CFG / CONV_CTRL / CONV_STATUS / FMAP_WR_CTRL 位段（v2-conv 用） ── */
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
