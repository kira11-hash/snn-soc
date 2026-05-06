/*
 * fw/src/v2b_m3_cycles.c
 *
 * Implementation of the V2.B M3 latency / cycle-partition recorder.
 * See fw/include/v2b_m3_cycles.h for the public ABI.
 *
 * This file is host-agnostic and compiles into both the ARM path
 * (audit-v2 / fw/arm) and the E203 path (audit-v2-e203 /
 * fw/v2_e203_smoke). The only host-specific entry points are
 * v2b_m3_cycle_now() and v2b_m3_cycle_init_host(), supplied by
 * per-host source files.
 *
 * Spec lock source:
 *   - essay/m3_phase2a_kickoff_2026_05_06.md
 *   - essay/m3_phase2a_design_2026_05_06.md (Codex review PASS 2026-05-06)
 *
 * UART format invariant: cross-host byte-byte identical. Achieved with
 * file-local subtractive decimal emitters that bypass host libc and
 * libgcc (E203 RV32 has no native u64 div/mod, so the subtractive
 * pattern keeps us off __umoddi3 / __udivdi3 helpers).
 */

#include "v2b_m3_cycles.h"
#include "uart_printf.h"
#include <stdint.h>

/* ── File-local UART helpers ─────────────────────────────────────── */

/* Mirrors v2b_trace_hash.c's th_put_dec_u32; same pow10 subtractive
 * pattern, same digit emit. Kept file-local so the UART payload stays
 * under M3's exclusive byte-for-byte control on both hosts.  */
static void m3_put_dec_u32(uint32_t v)
{
    static const uint32_t pow10_u32[] = {
        1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
        10000u, 1000u, 100u, 10u, 1u
    };
    uint32_t started = 0u;
    if (v == 0u) {
        uart_putc('0');
        return;
    }
    for (uint32_t i = 0; i < (sizeof(pow10_u32) / sizeof(pow10_u32[0])); i++) {
        uint8_t digit = 0u;
        while (v >= pow10_u32[i]) {
            v -= pow10_u32[i];
            digit++;
        }
        if (digit != 0u || started) {
            uart_putc((char)('0' + digit));
            started = 1u;
        }
    }
}

/* u64 subtractive decimal emit. RV32 lacks native 64-bit div/mod; this
 * pattern uses only u64 compare + u64 subtract (which GCC inlines as
 * 32-bit cmp/sub-with-borrow on RV32, NO libgcc helper). The pow10_u64
 * table covers the full u64 range up to 10^19 < 2^64.  */
static void m3_put_dec_u64(uint64_t v)
{
    static const uint64_t pow10_u64[] = {
        10000000000000000000ULL,
         1000000000000000000ULL,
          100000000000000000ULL,
           10000000000000000ULL,
            1000000000000000ULL,
             100000000000000ULL,
              10000000000000ULL,
               1000000000000ULL,
                100000000000ULL,
                 10000000000ULL,
                  1000000000ULL,
                   100000000ULL,
                    10000000ULL,
                     1000000ULL,
                      100000ULL,
                       10000ULL,
                        1000ULL,
                         100ULL,
                          10ULL,
                           1ULL
    };
    uint32_t started = 0u;
    if (v == 0ULL) {
        uart_putc('0');
        return;
    }
    for (uint32_t i = 0; i < (sizeof(pow10_u64) / sizeof(pow10_u64[0])); i++) {
        uint32_t digit = 0u;
        while (v >= pow10_u64[i]) {
            v -= pow10_u64[i];
            digit++;
        }
        if (digit != 0u || started) {
            uart_putc((char)('0' + digit));
            started = 1u;
        }
    }
}

static void m3_put_lf(void)
{
    uart_putc('\n');
}

/* ── State machine ───────────────────────────────────────────────── */

void v2b_m3_init(v2b_m3_state_t *st)
{
    if (st == 0) return;
    for (int i = 0; i < V2B_M3_NUM_SEGMENTS; ++i) {
        st->cumulative[i] = 0ULL;
    }
    st->segment_start_cycle = 0ULL;
    st->infer_end_cycle     = 0ULL;
    st->active_seg          = -1;
    /* Anchor wall-clock LAST so any prep above doesn't pollute the
     * end-to-end measurement window. */
    st->infer_start_cycle   = v2b_m3_cycle_now();
}

void v2b_m3_seg_begin(v2b_m3_state_t *st, int seg_id)
{
    if (st == 0) return;
    if (seg_id < 0 || seg_id >= V2B_M3_NUM_SEGMENTS) return;
    /* Defensive: if a seg was already active, close it before opening. */
    if (st->active_seg >= 0) {
        v2b_m3_seg_end(st);
    }
    st->segment_start_cycle = v2b_m3_cycle_now();
    st->active_seg          = seg_id;
}

void v2b_m3_seg_end(v2b_m3_state_t *st)
{
    if (st == 0) return;
    if (st->active_seg < 0 || st->active_seg >= V2B_M3_NUM_SEGMENTS) return;
    uint64_t now = v2b_m3_cycle_now();
    uint64_t delta = now - st->segment_start_cycle;
    st->cumulative[st->active_seg] += delta;
    st->active_seg = -1;
    st->segment_start_cycle = 0ULL;
}

void v2b_m3_seg_switch(v2b_m3_state_t *st, int next_seg_id)
{
    if (st == 0) return;
    if (next_seg_id < 0 || next_seg_id >= V2B_M3_NUM_SEGMENTS) return;
    /* Single cycle_now() for both end + begin to minimize jitter from
     * the reader itself. If active_seg is -1 (defensive), this collapses
     * to a plain begin. */
    uint64_t now = v2b_m3_cycle_now();
    if (st->active_seg >= 0 && st->active_seg < V2B_M3_NUM_SEGMENTS) {
        uint64_t delta = now - st->segment_start_cycle;
        st->cumulative[st->active_seg] += delta;
    }
    st->segment_start_cycle = now;
    st->active_seg          = next_seg_id;
}

void v2b_m3_finalize(v2b_m3_state_t *st)
{
    if (st == 0) return;
    if (st->active_seg >= 0) {
        v2b_m3_seg_end(st);
    }
    st->infer_end_cycle = v2b_m3_cycle_now();
}

/* ── UART dump ───────────────────────────────────────────────────── */

uint32_t v2b_m3_dump_uart(const v2b_m3_state_t *st,
                          const char *config_name,
                          const char *host_name,
                          uint32_t    sample_id)
{
    if (st == 0) return 0u;

    /* Compute seg-sum for jitter sanity (Codex §13 nice-to-have #1). */
    uint64_t seg_sum = 0ULL;
    for (int i = 0; i < V2B_M3_NUM_SEGMENTS; ++i) {
        seg_sum += st->cumulative[i];
    }

    /* End-to-end wall clock (only valid if v2b_m3_finalize was called). */
    uint64_t total = (st->infer_end_cycle >= st->infer_start_cycle)
                   ? (st->infer_end_cycle - st->infer_start_cycle)
                   : 0ULL;

    /* Jitter PASS = (delta*1000 <= total*permille) OR (delta <= abs_floor).
     * Multiplication-based to avoid u64 division (E203 RV32 has no native
     * udivdi3; we don't want to pull in libgcc soft div). For LeNet-5 worst
     * case total ≈ 2^33 cycles, * 1000 = 2^43, well within u64 range. */
    if (total != 0ULL) {
        uint64_t delta = (seg_sum >= total) ? (seg_sum - total) : (total - seg_sum);
        uint64_t lhs   = delta * 1000ULL;
        uint64_t rhs   = total * (uint64_t)V2B_M3_JITTER_REL_PERMILLE;
        int rel_pass   = (lhs <= rhs);
        int abs_pass   = (delta <= (uint64_t)V2B_M3_JITTER_ABS_FLOOR_CYCLES);
        if (!rel_pass && !abs_pass) {
            uart_puts("M3_JITTER_FAIL ");
            uart_puts(config_name ? config_name : "?");
            uart_putc(' ');
            uart_puts(host_name ? host_name : "?");
            uart_putc(' ');
            m3_put_dec_u32(sample_id);
            uart_puts(" sum=");
            m3_put_dec_u64(seg_sum);
            uart_puts(" total=");
            m3_put_dec_u64(total);
            uart_puts(" delta=");
            m3_put_dec_u64(delta);
            m3_put_lf();
        }
    }

    /* Canonical data line. Format must stay byte-identical between ARM
     * and E203 paths; any deviation breaks the Python parser invariant. */
    uart_puts("M3_CYCLES ");
    uart_puts(config_name ? config_name : "?");
    uart_putc(' ');
    uart_puts(host_name ? host_name : "?");
    uart_putc(' ');
    m3_put_dec_u32(sample_id);
    for (int i = 0; i < V2B_M3_NUM_SEGMENTS; ++i) {
        uart_putc(' ');
        m3_put_dec_u64(st->cumulative[i]);
    }
    m3_put_lf();
    return 1u;
}
