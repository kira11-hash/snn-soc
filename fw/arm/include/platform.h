/*
 * fw/arm/include/platform.h — ZCU102 ARM Cortex-A53 PS-PL 平台地址 map。
 *
 * V2B_SOC_BASE 是 v2b_axi_wrapper（rtl/top/v2b_axi_wrapper.sv）的 AXI-Lite
 * 提议窗口。最终值由 Vivado BD Address Editor（Phase C0）锁定后写入
 * `xparameters.h`；本头文件给出 default，板上烧写脚本读 BD 真值即可。
 *
 * 编译期覆盖：在命令行加 -DV2B_SOC_BASE=0xB0000000u 即可改基址而不动 C 源码。
 *
 * ZCU102 board preset 把 PS UART0 映射到 MIO18/19，PS UART1 映射到 MIO20/21。
 * 本分支板验已确认走 PS UART0（COM4）即可；为简化 LeNet-5 bring-up 路径，
 * 不做双 UART 镜像 banner，避免引入额外的依赖。
 */
#ifndef V2B_ARM_PLATFORM_H
#define V2B_ARM_PLATFORM_H

#include <stdint.h>

#ifndef V2B_SOC_BASE
#define V2B_SOC_BASE 0xA0000000u   /* 提议值；以 Vivado BD 最终决议为准 */
#endif

#ifndef UART0_BASE
#define UART0_BASE   0xFF000000u
#endif

#ifndef UART_BASE
#define UART_BASE    UART0_BASE    /* 已板验路径：PS UART0 / COM4 */
#endif

/* PS UART 输入参考时钟（LPD 外设），用于计算 BRGR 分频。
 * ZCU102 默认 uart_ref_clk = 100 MHz。注意：这个是 PS LPD 时钟，
 * 不要与 PL fabric 端给 v2b_axi_wrapper 的 `clk`（默认 50 MHz）混淆。 */
#ifndef UART_REF_CLK_HZ
#define UART_REF_CLK_HZ  100000000u
#endif

#ifndef UART_BAUD
#define UART_BAUD        115200u
#endif

#endif /* V2B_ARM_PLATFORM_H */
