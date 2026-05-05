/*
 * fw/src/v2b_trace_hash.c
 *
 * Implementation of the V2.B M1 trace-hash recorder host helper.
 * See fw/include/v2b_trace_hash.h for the public ABI.
 *
 * This file is host-agnostic and meant to be compiled into both the
 * ARM path (audit-v2) and the E203 path (audit-v2-e203). The only
 * host-specific input is v2b_soc_regs.h's V2B_SOC_BASE override.
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

static inline void v2b_trace_hash_mmio_fence(void)
{
#if defined(__aarch64__)
    __asm__ volatile("dsb sy" ::: "memory");
#elif defined(__riscv)
    __asm__ volatile("fence iorw, iorw" ::: "memory");
#else
    __sync_synchronize();
#endif
}

/* ── Public API ─────────────────────────────────────────────────── */

void v2b_trace_hash_enable(uint8_t layer_id)
{
    if (layer_id > V2B_TRACE_HASH_MAX_LAYER_ID) {
        /* Avoid silent layer-id truncation; leave the recorder disabled so
         * the failure is visible to the caller and the UART log. */
        V2B_SOC_REG8(0x068u) = 0u;
        uart_puts("TRACE_HASH_ERR LAYER_ID_RANGE\n");
        v2b_trace_hash_mmio_fence();
        return;
    }

    /* Codex Day Thu prereq #1: SINGLE 32-bit MMIO store; do NOT split
     * into two byte writes. ENABLE=1 + LAYER_ID land in one cycle so
     * the recorder sees a clean enable transition with the correct
     * layer_id latched on the first commit. */
    V2B_SOC_TRACE_HASH_CTRL = pack_ctrl(/*enable=*/1, /*clear=*/0, layer_id);
    v2b_trace_hash_mmio_fence();
}

void v2b_trace_hash_disable(void)
{
    /* Low-byte write clears ENABLE without clobbering the stored LAYER_ID. */
    V2B_SOC_REG8(0x068u) = 0u;
    v2b_trace_hash_mmio_fence();
}

void v2b_trace_hash_clear(void)
{
    /* Codex Day Thu prereq #2: low-byte CLEAR_W1P, ENABLE/LAYER_ID
     * preserved by RTL. */
    V2B_SOC_REG8(0x068u) = (uint8_t)V2B_TRACE_HASH_CTRL_CLEAR_W1P_BIT;
    v2b_trace_hash_mmio_fence();
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
     * V2B_SOC_REG macro; add an explicit MMIO fence so AXI/ICB wrappers do
     * not speculate the following reads ahead of the address write. */
    V2B_SOC_TRACE_HASH_LOG_RD_ADDR = addr;
    v2b_trace_hash_mmio_fence();

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

    uart_puts("TRACE_HASH_BEGIN config=");
    uart_puts(config_name ? config_name : "?");
    uart_puts(" host=");
    uart_puts(host_name ? host_name : "?");
    uart_puts(" sample=");
    uart_put_u32(sample_id);
    uart_putc('\n');

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
        uart_puts("HASH layer=");
        uart_put_u32((uint32_t)layer_id);
        uart_puts(" t=");
        uart_put_u32((uint32_t)t_idx);
        uart_puts(" buf=");
        uart_putc(buf_sel ? 'B' : 'A');
        uart_puts(" 0x");
        uart_put_hex32(hash);
        uart_putc('\n');
    }

    uart_puts("TRACE_HASH_END count=");
    uart_put_u32(count);
    uart_putc('\n');
    return count;
}
