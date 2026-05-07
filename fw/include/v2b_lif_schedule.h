#ifndef V2B_LIF_SCHEDULE_H
#define V2B_LIF_SCHEDULE_H

/*
 * fw/include/v2b_lif_schedule.h
 *
 * H1-full host helper API for the V2.B LIF per-layer schedule LUT
 * (rtl/top/snn_soc_v2b_top.sv lines 0x0C0-0x0E4 CSR window).
 *
 * Used by both the ARM (PS-side, AXI) firmware path and the E203
 * (PL-side, ICB) firmware path. Both paths share this exact ABI so the
 * 3 backward-compat configs + 2 non-uniform schedules planned for the
 * board-validation phase emit byte-identical UART trace.
 *
 * Design contract:
 *  * Reset state is GLOBAL_MODE=1 (LUT bypassed, byte-bit identical to
 *    v2.B HEAD). Firmware that does not need per-layer schedule must
 *    leave GLOBAL_MODE=1; the legacy STAGE_CFG1 / CONV stage_cfg path
 *    remains in effect.
 *  * Per-layer mode (GLOBAL_MODE=0): firmware writes
 *      LIF_LAYERn_CFG[15:0]  = threshold
 *      LIF_LAYERn_CFG[16]    = reset_mode (0=soft, 1=hard)
 *    for each n in 0..7, then writes LIF_LAYER_IDX before EVERY
 *    STAGE_CTRL.START — including each CONV tile launch (the RTL
 *    samples the LUT on every stage launch, not per-logical-layer).
 *
 * Discipline (essay/h1_full_design_2026_05_07.md §3.3):
 *  * All MMIO writes are 32-bit aligned stores via volatile uint32_t *
 *    casts of V2B_SOC_BASE+offset. No 8-bit / 16-bit stores.
 *  * The shared core (.c) contains no #ifdef __aarch64__ / #ifdef
 *    __riscv branches; host-specific concerns (base override, fence
 *    semantics) live in per-host wrappers mirroring the M1 helper
 *    (v2b_trace_hash_arm.c / v2b_trace_hash_e203.c).
 *  * No malloc, no printf, no hidden static state. UART dump uses
 *    existing uart_puts / uart_putc only.
 */

#include <stdint.h>
#include "v2b_soc_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Restore reset-default schedule: GLOBAL_MODE=1, LUT bypassed, LAYER_IDX=0.
 * Returns 0 on success. */
int v2b_lif_schedule_reset_to_global(void);

/* Switch to per-layer LUT mode (GLOBAL_MODE=0). Caller must have
 * populated the LUT slots and written LIF_LAYER_IDX prior to the next
 * STAGE_CTRL.START (the RTL samples the index on every launch).
 * Returns 0 on success. */
int v2b_lif_schedule_enable_per_layer(void);

/* Program one LUT slot. layer_idx must be in [0, V2B_LIF_LAYER_MAX).
 * threshold is 16-bit unsigned; reset_mode is 0 (soft) or 1 (hard).
 * Returns 0 on success, -1 on layer_idx out of range. */
int v2b_lif_schedule_set_layer(uint8_t  layer_idx,
                               uint16_t threshold,
                               uint8_t  reset_mode);

/* Read back one LUT slot. layer_idx must be in [0, V2B_LIF_LAYER_MAX).
 * out_threshold and out_reset_mode are populated on success.
 * Returns 0 on success, -1 on layer_idx out of range or NULL out_*. */
int v2b_lif_schedule_get_layer(uint8_t   layer_idx,
                               uint16_t *out_threshold,
                               uint8_t  *out_reset_mode);

/* Dump the entire LUT + GLOBAL_MODE + LAYER_IDX over UART using a fixed
 * line format (matches the trace_hash dump style):
 *
 *   LIF_SCHED_BEGIN config=<config> host=<host>
 *   LIF_SCHED global_mode=<0|1>
 *   LIF_SCHED layer_idx=<0..7>
 *   LIF_SCHED layer=<n> threshold=0x<HHHH> reset_mode=<0|1>
 *   ...
 *   LIF_SCHED_END
 *
 * Returns the number of LUT slots dumped (== V2B_LIF_LAYER_MAX). */
uint32_t v2b_lif_schedule_dump_uart(const char *config_name,
                                    const char *host_name);

#ifdef __cplusplus
}
#endif

#endif /* V2B_LIF_SCHEDULE_H */
