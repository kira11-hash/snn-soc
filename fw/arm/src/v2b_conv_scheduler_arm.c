/*
 * fw/arm/src/v2b_conv_scheduler_arm.c — ARM 端薄包装层。
 *
 * 设计意图：fw/src/v2b_conv_scheduler.c 是「平台无关」的调度逻辑，但它
 * 的实现里直接引用了 LENET5_T_COUNT / lenet5_*_offsets 等来自 golden_lenet5.h
 * 的符号（这是为了让 v2b_run_lenet5_demo 能在不同 host 上零修改地复用）。
 *
 * 这层 wrapper 做两件事：
 *   1) 在 include 平台无关 .c 之前，先把 platform.h（V2B_SOC_BASE 等）和
 *      golden_lenet5.h 都纳入翻译单元，让 .c 里的宏/数组都有定义；
 *   2) 通过 include source-into-source 让 ARM 路径直接复用同一份 .c，避免
 *      维护两份调度器代码。
 *
 * 限制：v2b_conv_scheduler.c 因此不能独立编译；任何重构必须保持这个
 * include 顺序合约。如果未来要让该 .c 真正自包含，需要把 LENET5_* 宏
 * 与 sparse 数组的声明搬到 v2b_conv_scheduler.h（或新加一个 lenet5_specs.h）。
 */
#include "platform.h"
#define V2B_TRACE_HASH_HOST_NAME "arm"
#include "golden_lenet5.h"
#include "v2b_conv_scheduler.h"
#include "../../src/v2b_conv_scheduler.c"
