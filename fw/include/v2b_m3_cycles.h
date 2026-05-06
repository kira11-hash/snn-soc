#ifndef V2B_M3_CYCLES_H
#define V2B_M3_CYCLES_H

/*
 * fw/include/v2b_m3_cycles.h
 *
 * Host-side helper API for M3 Phase 2A (latency / cycle partition).
 *
 * Mirrors v2b_trace_hash.h's host-agnostic pattern: the same C source
 * file (fw/src/v2b_m3_cycles.c) compiles into both the ARM (PS-side,
 * AXI) firmware path and the E203 (PL-side, ICB) firmware path, with
 * only the 2 host-specific primitives v2b_m3_cycle_now() and
 * v2b_m3_cycle_init_host() supplied per host:
 *
 *   - ARM:  fw/arm/src/v2b_m3_cycles_arm.c           (PMCCNTR_EL0)
 *   - E203: fw/v2_e203_smoke/src/v2b_m3_cycles_e203.c (mcycle/mcycleh)
 *
 * The 5-segment partition matches essay/m3_phase2a_kickoff_2026_05_06.md
 * §2 and essay/m3_phase2a_design_2026_05_06.md §2:
 *
 *   0  HOST_SETUP    pre-START bookkeeping (CFG writes, buffer clear)
 *   1  TRANSFER      input fmap + weight load (incl. WAIT_WEIGHT_REQ)
 *   2  ACCEL_ACTIVE  STAGE_CTRL.START -> STATUS.BUSY=0 busy-poll
 *   3  READBACK      stream-buffer drain
 *   4  DECODE        argmax over per-class spike counts
 *
 * Spec lock source:
 *   - essay/m3_phase2a_design_2026_05_06.md (Codex review PASS 2026-05-06)
 *   - commit 32bb4eb3 (Codex verdict applied)
 *
 * Usage pattern (mirrors trace_hash):
 *
 *     v2b_m3_state_t  m3;
 *     v2b_m3_cycle_init_host();   // call once per boot
 *     for (sample = 0; sample < N; ++sample) {
 *         v2b_m3_init(&m3);
 *         v2b_infer_*_m3(..., &m3);
 *         v2b_m3_dump_uart(&m3, "v2b_fc_fashion14_2L", "arm", sample);
 *     }
 */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define V2B_M3_NUM_SEGMENTS      5
#define V2B_M3_SEG_HOST_SETUP    0
#define V2B_M3_SEG_TRANSFER      1
#define V2B_M3_SEG_ACCEL_ACTIVE  2
#define V2B_M3_SEG_READBACK      3
#define V2B_M3_SEG_DECODE        4

/* §13 #1 Codex nice-to-have: jitter PASS threshold = max(0.5%, 1024 cycles).
 * Exposed so unit tests / firmware self-check share the same constant. */
#define V2B_M3_JITTER_ABS_FLOOR_CYCLES   1024u
/* Seg-sum vs end-to-end relative threshold expressed as parts-per-thousand.
 * 5 = 0.5% so we avoid a floating-point compare on E203. */
#define V2B_M3_JITTER_REL_PERMILLE       5u

typedef struct {
    /* Per-segment cumulative cycle counts; updated only by seg_end / seg_switch. */
    uint64_t cumulative[V2B_M3_NUM_SEGMENTS];

    /* Most recent cycle_now() snapshot taken in seg_begin / seg_switch.
     * Zero when active_seg == -1. */
    uint64_t segment_start_cycle;

    /* End-to-end wall-clock anchor: snapshot at v2b_m3_init() so dump_uart()
     * can compute seg-sum vs total jitter (Codex §13 nice-to-have #1). */
    uint64_t infer_start_cycle;
    uint64_t infer_end_cycle;     /* set by v2b_m3_finalize() */

    /* Currently-running segment id; -1 = idle. */
    int      active_seg;
} v2b_m3_state_t;

/* ── Host-specific primitives (provided by per-host source) ───────── */

/* Read the host's free-running cycle counter. Must be 64-bit on both hosts.
 * Implementations:
 *   ARM AArch64: mrs %, pmccntr_el0  (after v2b_m3_cycle_init_host enables it)
 *   E203 RV32:   csrr mcycleh / mcycle / mcycleh  (double-read for atomicity) */
uint64_t v2b_m3_cycle_now(void);

/* One-time host-side setup. Called once per boot before any inference loop.
 * ARM: enable PMCR_EL0 + PMCNTENSET_EL0.C bits.
 * E203: no-op (mcycle is free-running from reset). */
void     v2b_m3_cycle_init_host(void);

/* ── Host-agnostic state machine ──────────────────────────────────── */

/* Reset state at the start of one inference sample. Records the wall-clock
 * anchor in infer_start_cycle. Caller must invoke before the first seg_begin. */
void     v2b_m3_init(v2b_m3_state_t *st);

/* Begin segment seg_id (must be 0..4 and active_seg must be -1). */
void     v2b_m3_seg_begin(v2b_m3_state_t *st, int seg_id);

/* End the active segment; accumulates delta into cumulative[active_seg]. */
void     v2b_m3_seg_end(v2b_m3_state_t *st);

/* Atomic end-then-begin: 1 cycle_now() call captures both the end of the
 * current segment and the start of next_seg_id (no double-read jitter). */
void     v2b_m3_seg_switch(v2b_m3_state_t *st, int next_seg_id);

/* Snapshot the wall-clock end after the inference returns. If a segment is
 * still active, finalize closes it implicitly (defensive; correct usage
 * always calls seg_end before finalize). */
void     v2b_m3_finalize(v2b_m3_state_t *st);

/* ── UART dump (cross-host byte-byte identical) ───────────────────── */

/* Output line:
 *   M3_CYCLES <config> <host> <sample> <seg0> <seg1> <seg2> <seg3> <seg4>\n
 *
 * If seg-sum vs (infer_end - infer_start) jitter exceeds
 * max(V2B_M3_JITTER_REL_PERMILLE, V2B_M3_JITTER_ABS_FLOOR_CYCLES), an
 * additional warning line is emitted before the data line:
 *   M3_JITTER_FAIL <config> <host> <sample> sum=<S> total=<T> delta=<D>\n
 *
 * Returns 1 if data line was emitted (always 1 on success), 0 on
 * defensive failure (st is NULL).
 */
uint32_t v2b_m3_dump_uart(const v2b_m3_state_t *st,
                          const char *config_name,
                          const char *host_name,
                          uint32_t    sample_id);

#ifdef __cplusplus
}
#endif

#endif /* V2B_M3_CYCLES_H */
