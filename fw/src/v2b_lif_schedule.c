/*
 * fw/src/v2b_lif_schedule.c
 *
 * Implementation of the H1-full V2.B LIF per-layer schedule helper.
 * See fw/include/v2b_lif_schedule.h for the public ABI.
 *
 * This file is host-agnostic and meant to be compiled into both the
 * ARM path (audit-v2 fw/arm) and the E203 path (audit-v2-e203
 * fw/v2_e203_smoke). The only host-specific input is V2B_SOC_BASE,
 * which the E203 wrapper overrides via #define before #include of
 * this source. ARM uses the build-script -D override.
 *
 * Discipline (essay/h1_full_design_2026_05_07.md §3.3):
 *   - 32-bit aligned MMIO stores only; the volatile macros in
 *     v2b_soc_regs.h enforce this. No 8/16-bit writes.
 *   - No host-ISA preprocessor branches in this file.
 *     Host-specific concerns are pushed to the wrapper.
 *   - No dynamic allocation, formatted I/O, or persistent state.
 *
 * RTL contract:
 *   rtl/top/snn_soc_v2b_top.sv lines 0x0C0-0x0E4 CSR window +
 *   the lif_per_layer_threshold_eff / lif_per_layer_reset_mode_eff
 *   muxes feeding stage_engine_v2.sv u_se.cfg_threshold /
 *   u_se.cfg_reset_mode.
 */

#include "v2b_lif_schedule.h"
#include "v2b_soc_regs.h"
#include <stdint.h>

extern void uart_putc(char c);
extern void uart_puts(const char *s);

/* Local digit emitters mirror the v2b_trace_hash.c style so the dump
 * format is byte-identical between ARM and E203 paths regardless of
 * each host's uart_put_hex32 / uart_put_u32 conventions. */
void lifs_put_hex16_raw(uint16_t v)
{
    const char HEX[] = "0123456789ABCDEF";
    for (int i = 3; i >= 0; i--)
        uart_putc(HEX[(v >> (i * 4)) & 0xFu]);
}

void lifs_put_dec_u32(uint32_t v)
{
    const uint32_t pow10[] = {
        1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
        10000u, 1000u, 100u, 10u, 1u
    };
    uint32_t started = 0u;
    if (v == 0u) {
        uart_putc('0');
        return;
    }
    for (uint32_t i = 0; i < (sizeof(pow10) / sizeof(pow10[0])); i++) {
        uint8_t digit = 0u;
        while (v >= pow10[i]) {
            v -= pow10[i];
            digit++;
        }
        if (digit != 0u || started) {
            uart_putc((char)('0' + digit));
            started = 1u;
        }
    }
}

void lifs_put_lf(void)
{
    uart_putc('\n');
}

/* Pack a LIF_LAYERn_CFG word per the RTL bit layout. */
uint32_t pack_lif_layer_cfg(uint16_t threshold, uint8_t reset_mode)
{
    return ((uint32_t)threshold & 0xFFFFu)
         | (((uint32_t)reset_mode & 0x1u) << 16);
}

/* ── Public API ─────────────────────────────────────────────────── */

int v2b_lif_schedule_reset_to_global(void)
{
    /* GLOBAL_MODE=1 restores byte-bit identity with the v2.B HEAD path.
     * Reset LAYER_IDX to 0 as well so a later switch to per-layer mode
     * starts from a known anchor. LUT contents are intentionally left
     * untouched — caller decides whether to clear them. */
    V2B_SOC_LIF_GLOBAL_MODE = 0x00000001u;
    V2B_SOC_LIF_LAYER_IDX   = 0x00000000u;
    return 0;
}

int v2b_lif_schedule_enable_per_layer(void)
{
    V2B_SOC_LIF_GLOBAL_MODE = 0x00000000u;
    return 0;
}

int v2b_lif_schedule_set_layer(uint8_t  layer_idx,
                               uint16_t threshold,
                               uint8_t  reset_mode)
{
    if (layer_idx >= V2B_LIF_LAYER_MAX) return -1;

    /* Single 32-bit MMIO store; apply_wstrb() in the RTL will use
     * wstrb=4'b1111 by default (full-word write) so all bytes land
     * atomically and SVA-3 holds. */
    V2B_LIF_LAYERn_CFG(layer_idx) = pack_lif_layer_cfg(threshold, reset_mode);
    return 0;
}

int v2b_lif_schedule_get_layer(uint8_t   layer_idx,
                               uint16_t *out_threshold,
                               uint8_t  *out_reset_mode)
{
    uint32_t v;
    if (layer_idx >= V2B_LIF_LAYER_MAX) return -1;
    if (out_threshold == 0 || out_reset_mode == 0) return -1;

    v = V2B_LIF_LAYERn_CFG(layer_idx);
    *out_threshold  = (uint16_t)(v & 0xFFFFu);
    *out_reset_mode = (uint8_t)((v >> 16) & 0x1u);
    return 0;
}

uint32_t v2b_lif_schedule_dump_uart(const char *config_name,
                                    const char *host_name)
{
    uart_puts("LIF_SCHED_BEGIN config=");
    uart_puts(config_name ? config_name : "?");
    uart_puts(" host=");
    uart_puts(host_name ? host_name : "?");
    lifs_put_lf();

    uart_puts("LIF_SCHED global_mode=");
    lifs_put_dec_u32(V2B_SOC_LIF_GLOBAL_MODE & 0x1u);
    lifs_put_lf();

    uart_puts("LIF_SCHED layer_idx=");
    lifs_put_dec_u32(V2B_SOC_LIF_LAYER_IDX & 0x7u);
    lifs_put_lf();

    for (uint32_t n = 0; n < V2B_LIF_LAYER_MAX; n++) {
        uint16_t thr;
        uint8_t  rmode;
        if (v2b_lif_schedule_get_layer((uint8_t)n, &thr, &rmode) != 0)
            break;
        uart_puts("LIF_SCHED layer=");
        lifs_put_dec_u32(n);
        uart_puts(" threshold=0x");
        lifs_put_hex16_raw(thr);
        uart_puts(" reset_mode=");
        lifs_put_dec_u32((uint32_t)rmode);
        lifs_put_lf();
    }

    uart_puts("LIF_SCHED_END");
    lifs_put_lf();
    return V2B_LIF_LAYER_MAX;
}
