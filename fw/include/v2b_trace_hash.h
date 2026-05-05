#ifndef V2B_TRACE_HASH_H
#define V2B_TRACE_HASH_H

/*
 * fw/include/v2b_trace_hash.h
 *
 * Host-side helper API for the V2.B M1 trace-hash recorder
 * (rtl/snn/trace_hash_recorder.sv, instantiated inside snn_soc_v2b_top).
 *
 * Used by both the ARM (PS-side, AXI) firmware path and the E203
 * (PL-side, ICB) firmware path. Both paths share this exact ABI so
 * that the Python diff tool (python_multilayer/trace_hash_diff.py) can
 * compare UART logs from the two hosts byte-for-byte.
 *
 * ABI locked by Codex Day Wed review (2026-05-05); see
 * essay/codex_review_m1_day_wed_integration_2026_05_05.md and the
 * commit `4e72597c`.
 *
 * Usage pattern in an inference loop:
 *
 *     v2b_trace_hash_clear();
 *     v2b_trace_hash_enable(layer_id_for_this_stage);
 *     // ... existing STAGE_CFG / STAGE_CTRL.START / poll BUSY ...
 *     v2b_trace_hash_disable();   // immediately after BUSY=0
 *     v2b_trace_hash_dump_uart("v2b_lenet5_mnist_28x28", "arm",
 *                              sample_id);
 */

#include <stdint.h>
#include "v2b_soc_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Single-write enable: sets ENABLE=1 and LAYER_ID in one MMIO store
 * (per Codex Day Thu prereq #1; do NOT split into two byte writes). */
void     v2b_trace_hash_enable(uint8_t layer_id);

/* Disable the recorder via a low-byte write; LAYER_ID is preserved. */
void     v2b_trace_hash_disable(void);

/* Pulse CLEAR_W1P; ENABLE/LAYER_ID untouched (per Codex Day Wed fix). */
void     v2b_trace_hash_clear(void);

/* Read TRACE_HASH_LOG_COUNT (16-bit count of logged entries). */
uint32_t v2b_trace_hash_log_count(void);

/* Read OVERFLOW_RO + LAYER_ID_FAULT_RO from CTRL. Bits per
 * V2B_TRACE_HASH_CTRL_*_BIT. */
uint32_t v2b_trace_hash_status(void);

/* Read one entry from the recorder log.
 *
 * Protocol:
 *   1) write LOG_RD_ADDR (0x070) <- addr
 *   2) read  LOG_RD_DATA (0x074) -> 32-bit hash
 *   3) read  LOG_RD_META (0x078) -> {buf_sel, layer_id, t_idx} packed
 *
 * Returns 0 on success; -1 if addr >= log_count.
 */
int      v2b_trace_hash_read_entry(uint32_t addr,
                                   uint32_t *out_hash,
                                   uint8_t  *out_t_idx,
                                   uint8_t  *out_layer_id,
                                   uint8_t  *out_buf_sel);

/* Dump the entire current log to UART in the canonical line format
 * shared by ARM and E203 paths:
 *
 *   TRACE_HASH_BEGIN config=<config> host=<host> sample=<sample>
 *   HASH layer=<L> t=<T> buf=<A|B> 0x<HHHHHHHH>
 *   ...
 *   TRACE_HASH_END count=<N>
 *
 * sample_id is intentionally 32-bit so ARM and E203 emit byte-identical
 * decimal text for the same sample number.
 *
 * Returns the number of HASH lines emitted. */
uint32_t v2b_trace_hash_dump_uart(const char *config_name,
                                  const char *host_name,
                                  uint32_t    sample_id);

#ifdef __cplusplus
}
#endif

#endif /* V2B_TRACE_HASH_H */
