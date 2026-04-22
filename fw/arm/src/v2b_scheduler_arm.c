/*
 * fw/arm/src/v2b_scheduler_arm.c
 *
 * ARM port of fw/src/v2b_scheduler.c. Intentionally 2 lines:
 *   1. Override V2B_SOC_BASE from platform.h before v2b_soc_regs.h kicks in.
 *   2. #include the original scheduler source so we get one compiled copy.
 *
 * This keeps the bit-exact scheduler logic (verified by
 * tb/fw_cosim_resident_14x14_tb.sv and tb/axi_arm_cosim_resident_14x14_tb.sv)
 * as the single source of truth across cosim / E203 / ARM. The only thing
 * that changes is the MMIO base address.
 */
#include "platform.h"
/* v2b_soc_regs.h does `#ifndef V2B_SOC_BASE` so the value above wins. */
#include "../../src/v2b_scheduler.c"
