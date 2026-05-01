/*
 * fw/arm/link_arm.ld — AArch64 standalone linker script for Phase B Gate B.
 *
 * Memory model (Zynq UltraScale+ ZCU102):
 *   - OCM 0xFFFC_0000..0xFFFF_FFFF (256 KB) for startup code, stack, UART,
 *     and small runtime state.
 *   - DDR 0x0010_0000.. for the large LeNet-5 golden bundle (weights + input
 *     words) after `psu_init.tcl` has completed PS/DDR bring-up in XSCT.
 *
 * For PHASE B GATE purposes (compile + link + size + nm check), the absolute
 * addresses don't matter as long as the sections resolve. For direct JTAG
 * board deployment (Phase C0+), OCM keeps the smoke test hermetic.
 *
 * Symbols used by crt0_aarch64.S:
 *   _stack_top     — stack growth pointer (grows down)
 *   __bss_start    — start of .bss (zeroed by crt0)
 *   __bss_end      — end of .bss
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
