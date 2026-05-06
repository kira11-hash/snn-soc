/*
 * fw/arm/src/v2b_m3_cycles_arm.c
 *
 * ARM AArch64 (Cortex-A53 / ZCU102 PS) implementation of the host-specific
 * portion of v2b_m3_cycles.h:
 *   - v2b_m3_cycle_now()       reads PMCCNTR_EL0 (64-bit cycle counter)
 *   - v2b_m3_cycle_init_host() enables PMCR_EL0 + PMCNTENSET_EL0 once
 *
 * Bring-up assumption (locked by Codex M3 review 2026-05-06):
 *   The current ZCU102 ARM bring-up is `xsct rst -processor` + `dow ELF` +
 *   `con` (see scripts/program_zcu102_c1.tcl). FSBL/BL31 are NOT in the
 *   path, so the firmware runs at the highest exception level reachable
 *   via JTAG (typically EL3 or EL2) — i.e. PMU access is not trapped.
 *
 *   If a future board flow routes through FSBL/BL31 and ends up at EL1 or
 *   EL0 user mode, additional setup is required:
 *     - PMUSERENR_EL0.EN     so EL0 can read PMCCNTR_EL0
 *     - MDCR_EL2.{HPMN,TPM}  so EL2 doesn't trap EL1 PMU access
 *     - MDCR_EL3.TPM         so EL3 doesn't trap lower-EL PMU access
 *   None of those are required today.
 */

#include <stdint.h>
#include "v2b_m3_cycles.h"

/* PMCCNTR_EL0: 64-bit unsigned counter; counts CPU cycles when enabled.
 * Reading is a single MRS instruction; no atomicity issue (unlike
 * RV32 mcycle/mcycleh which are split). */
uint64_t v2b_m3_cycle_now(void)
{
    uint64_t v;
    __asm__ volatile ("mrs %0, pmccntr_el0" : "=r"(v) :: "memory");
    return v;
}

/* PMCR_EL0 bits used here:
 *   [0] E — global enable for the cycle/event counters
 *   [2] C — reset cycle counter to zero (write-only, self-clearing)
 *
 * PMCNTENSET_EL0 bits:
 *   [31] C — per-counter enable for PMCCNTR_EL0 (the cycle counter)
 *
 * We do NOT touch PMUSERENR_EL0 because the current ZCU102 baremetal
 * bring-up runs above EL0 (see file header for the assumption).
 */
void v2b_m3_cycle_init_host(void)
{
    uint64_t pmcr;
    /* Read-modify-write PMCR so we don't accidentally clobber other PMU
     * implementer-defined bits (e.g. event counter behavior on Cortex-A53). */
    __asm__ volatile ("mrs %0, pmcr_el0" : "=r"(pmcr));
    pmcr |= (1ULL << 0)   /* E: enable */
          | (1ULL << 2);  /* C: reset cycle counter */
    __asm__ volatile ("msr pmcr_el0, %0" :: "r"(pmcr));
    /* ISB so the PMCR write completes before any subsequent PMCCNTR_EL0
     * read in the same firmware boot path. */
    __asm__ volatile ("isb" ::: "memory");

    /* Enable the cycle counter via PMCNTENSET (write-only enable mask). */
    uint64_t set = (1ULL << 31);
    __asm__ volatile ("msr pmcntenset_el0, %0" :: "r"(set));
    __asm__ volatile ("isb" ::: "memory");
}
