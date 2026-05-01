/*
 * fw/arm/include/platform.h — ZCU102 ARM Cortex-A53 PS-PL platform map.
 *
 * V2B_SOC_BASE is the proposed AXI-Lite window for v2b_axi_wrapper
 * (rtl/top/v2b_axi_wrapper.sv). Final value is bound by the Vivado
 * BD Address Editor (Phase C0) and flowed into `xparameters.h`.
 *
 * Build override: define V2B_SOC_BASE at the command line
 *   (e.g., -DV2B_SOC_BASE=0xB0000000u) to swap without code edits.
 *
 * ZCU102 board preset maps PS UART0 to MIO18/19 and PS UART1 to MIO20/21.
 * The known-good ARM board evidence on this branch used PS UART0 only.
 * Keep that simpler contract for LeNet-5 bring-up rather than depending on
 * mirrored dual-UART banners.
 */
#ifndef V2B_ARM_PLATFORM_H
#define V2B_ARM_PLATFORM_H

#include <stdint.h>

#ifndef V2B_SOC_BASE
#define V2B_SOC_BASE 0xA0000000u   /* proposed; Vivado BD final wins */
#endif

#ifndef UART0_BASE
#define UART0_BASE   0xFF000000u
#endif

#ifndef UART_BASE
#define UART_BASE    UART0_BASE    /* known-good board path: PS UART0 / COM4 */
#endif

/* PS UART input reference clock (LPD peripheral) used for BRGR divisor.
 * ZCU102 default PS ref = 100 MHz on uart_ref_clk. Do not confuse with
 * the PL-side `clk` fabric clock fed to v2b_axi_wrapper. */
#ifndef UART_REF_CLK_HZ
#define UART_REF_CLK_HZ  100000000u
#endif

#ifndef UART_BAUD
#define UART_BAUD        115200u
#endif

#endif /* V2B_ARM_PLATFORM_H */
