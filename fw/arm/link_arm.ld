/*
 * fw/arm/link_arm.ld — AArch64 standalone 链接脚本（Phase B Gate B 用）。
 *
 * 内存模型（Zynq UltraScale+ ZCU102）：
 *   - OCM 0xFFFC_0000..0xFFFF_FFFF（256 KB）：放启动代码、栈、UART 驱动、小运行时状态
 *   - DDR 0x0010_0000..：在 XSCT 已经通过 psu_init.tcl 完成 PS/DDR bring-up 之后，
 *                       可放大体积的 LeNet-5 黄金参考（权重 + 输入 fmap words）。
 *
 * 关于地址：
 *   - PHASE B GATE 阶段（仅 compile + link + size + nm 检查）：绝对地址不重要，
 *     只要 section 能 resolve 就过。
 *   - 上板 JTAG 烧写阶段（Phase C0+）：OCM 自包含可保证 smoke test 不依赖 DDR
 *     训练状态，先在 OCM 里跑通再说。
 *
 * crt0_aarch64.S 引用的符号：
 *   _stack_top     — 栈顶指针（栈向下生长）
 *   __bss_start    — .bss 起点（crt0 清零）
 *   __bss_end      — .bss 终点
 */

ENTRY(_start)

MEMORY {
    OCM  (rwx) : ORIGIN = 0xFFFC0000, LENGTH = 256K
    DDR  (rwx) : ORIGIN = 0x00100000, LENGTH = 64M
}

SECTIONS
{
    . = ORIGIN(OCM);

    .text : {
        KEEP(*(.text.startup))
        *(.text*)
        *(.rodata*)
        . = ALIGN(8);
    } > OCM

    .data : {
        __data_start = .;
        *(.data*)
        *(.sdata*)
        . = ALIGN(8);
        __data_end = .;
    } > OCM

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > OCM

    /* 64 KB stack */
    .stack (NOLOAD) : {
        . = ALIGN(16);
        _stack_bottom = .;
        . = . + 0x10000;
        _stack_top = .;
    } > OCM

    .ddr_rodata : {
        . = ALIGN(64);
        __ddr_rodata_start = .;
        *(.ddr_rodata*)
        . = ALIGN(64);
        __ddr_rodata_end = .;
    } > DDR

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.ARM.exidx*)
        *(.ARM.extab*)
        *(.eh_frame*)
    }
}
