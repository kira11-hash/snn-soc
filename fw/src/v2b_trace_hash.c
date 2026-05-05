/*
 * fw/src/v2b_trace_hash.c
 *
 * Implementation of the V2.B M1 trace-hash recorder host helper.
 * See fw/include/v2b_trace_hash.h for the public ABI.
 *
 * This file is host-agnostic; it is included verbatim by both
 *   fw/arm/src/v2b_scheduler_arm.c    (V2B_SOC_BASE = 0x50000000)
 * and
 *   fw/v2_e203_smoke/src/v2_e203_*.c  (V2B_SOC_BASE = 0xA0000000)
 *
 * by virtue of v2b_soc_regs.h's V2B_SOC_BASE conditional.
 *
 * ABI lock source: essay/codex_review_m1_day_wed_integration_2026_05_05.md
 * RTL contract:    rtl/snn/trace_hash_recorder.sv (commit 90fdef2a) +
 *                  rtl/top/snn_soc_v2b_top.sv (commit 992bf0a5 / 4e72597c)
 */

#include "v2b_trace_hash.h"
#include "uart_printf.h"
#include <stdint.h>

/* ── Internal helpers ───────────────────────────────────────────── */

static inline uint32_t pack_ctrl(uint8_t enable, uint8_t clear_w1p, uint8_t layer_id)
{
    /* CTRL [0] ENABLE, [1] CLEAR_W1P, [10:8] LAYER_ID. RO bits ignored on write. */
    return (enable    ? V2B_TRACE_HASH_CTRL_ENABLE_BIT    : 0u)
         | (clear_w1p ? V2B_TRACE_HASH_CTRL_CLEAR_W1P_BIT : 0u)
         | (((uint32_t)layer_id & 0x7u) << V2B_TRACE_HASH_CTRL_LAYER_ID_LSB);
}

/* ── Public API ─────────────────────────────────────────────────── */

void v2b_trace_hash_enable(uint8_t layer_id)
{
    /* Codex Day Thu prereq #1: SINGLE 32-bit MMIO store; do NOT split
     * into two byte writes. ENABLE=1 + LAYER_ID land in one cycle so
     * the recorder sees a clean enable transition with the correct
     * layer_id latched on the first commit. */
    V2B_SOC_TRACE_HASH_CTRL = pack_ctrl(/*enable=*/1, /*clear=*/0, layer_id);
}

void v2b_trace_hash_disable(void)
{
    /* ENABLE=0; LAYER_ID untouched per Codex Day Wed RTL fix. */
    V2B_SOC_TRACE_HASH_CTRL = pack_ctrl(/*enable=*/0, /*clear=*/0, /*layer=*/0);
}

void v2b_trace_hash_clear(void)
{
    /* Codex Day Thu prereq #2: low-byte CLEAR_W1P, ENABLE/LAYER_ID
     * preserved by RTL. Direct store of bit[1] is now safe. */
    V2B_SOC_TRACE_HASH_CTRL = V2B_TRACE_HASH_CTRL_CLEAR_W1P_BIT;
}

uint32_t v2b_trace_hash_log_count(void)
{
    return V2B_SOC_TRACE_HASH_LOG_COUNT;
}

uint32_t v2b_trace_hash_status(void)
{
    return V2B_SOC_TRACE_HASH_CTRL
         & (V2B_TRACE_HASH_CTRL_OVERFLOW_RO_BIT
          | V2B_TRACE_HASH_CTRL_LAYER_ID_FAULT_BIT);
}

int v2b_trace_hash_read_entry(uint32_t addr,
                              uint32_t *out_hash,
                              uint8_t  *out_t_idx,
                              uint8_t  *out_layer_id,
                              uint8_t  *out_buf_sel)
{
    uint32_t count;
    uint32_t hash;
    uint32_t meta;

    if (out_hash == 0) return -1;

    count = V2B_SOC_TRACE_HASH_LOG_COUNT;
    if (addr >= count) return -1;

    /* Codex Day Thu prereq #3: write RD_ADDR -> read RD_DATA -> read RD_META.
     * volatile MMIO ordering at this granularity is enforced by the
     * V2B_SOC_REG macro; ARM-specific fence is added in the wrapper
     * v2b_trace_hash_arm_fence() if the platform requires it. */
    V2B_SOC_TRACE_HASH_LOG_RD_ADDR = addr;

    hash = V2B_SOC_TRACE_HASH_LOG_RD_DATA;
    meta = V2B_SOC_TRACE_HASH_LOG_RD_META;

    *out_hash = hash;
    if (out_t_idx)    *out_t_idx    = (uint8_t)V2B_TRACE_HASH_META_T_IDX(meta);
    if (out_layer_id) *out_layer_id = (uint8_t)V2B_TRACE_HASH_META_LAYER_ID(meta);
    if (out_buf_sel)  *out_buf_sel  = (uint8_t)V2B_TRACE_HASH_META_BUF_SEL(meta);
    return 0;
}

uint32_t v2b_trace_hash_dump_uart(const char *config_name,
                                  const char *host_name,
                                  uint32_t    sample_id)
{
    uint32_t count = V2B_SOC_TRACE_HASH_LOG_COUNT;
    uint32_t status = v2b_trace_hash_status();

    uart_printf("TRACE_HASH_BEGIN config=%s host=%s sample=%lu\n",
                config_name ? config_name : "?",
                host_name   ? host_name   : "?",
                (unsigned long)sample_id);

    if (status & V2B_TRACE_HASH_CTRL_OVERFLOW_RO_BIT)
        uart_puts("TRACE_HASH_WARN OVERFLOW\n");
    if (status & V2B_TRACE_HASH_CTRL_LAYER_ID_FAULT_BIT)
        uart_puts("TRACE_HASH_WARN LAYER_ID_FAULT\n");

    for (uint32_t i = 0; i < count; ++i) {
        uint32_t hash;
        uint8_t  t_idx;
        uint8_t  layer_id;
        uint8_t  buf_sel;

        if (v2b_trace_hash_read_entry(i, &hash, &t_idx, &layer_id, &buf_sel) != 0)
            break;

        /* Format must stay byte-identical between ARM and E203 paths;
         * any deviation breaks the Python diff tool's parser. */
        uart_printf("HASH layer=%u t=%u buf=%c 0x%08lX\n",
                    (unsigned int)layer_id,
                    (unsigned int)t_idx,
                    buf_sel ? 'B' : 'A',
                    (unsigned long)hash);
    }

    uart_printf("TRACE_HASH_END count=%lu\n", (unsigned long)count);
    return count;
}
