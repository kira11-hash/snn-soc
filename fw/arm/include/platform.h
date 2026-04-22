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
 * UART_BASE defaults to ZCU102 PS UART0 (0xFF000000). UART1 at 0xFF010000
 * is the alternate; pick the one pinned to the USB-JTAG MicroUSB cable
 * (on ZCU102 boards shipped post-2018 that's typically UART0).
 */
#ifndef V2B_ARM_PLATFORM_H
#define V2B_ARM_PLATFORM_H

#include <stdint.h>

#ifndef V2B_SOC_BASE
#define V2B_SOC_BASE 0xA0000000u   /* proposed; Vivado BD final wins */
#endif

#ifndef UART_BASE
#define UART_BASE    0xFF000000u   /* Zynq Ultrascale+ PS UART0 */
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
