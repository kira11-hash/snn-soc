/*
 * fw/arm/link_arm.ld — AArch64 standalone linker script for Phase B Gate B.
 *
 * Memory model (Zynq UltraScale+ ZCU102):
 *   - OCM 0x00000000..0x0003FFFF (256 KB, 4 × 64 KB banks). We pick the
 *     last 32 KB for the .stack to keep .text/.rodata in DDR.
 *   - DDR @ 0x0_0000_0000 (PS DDR Low) — BSP default base is usually 0x0.
 *     But to keep this linker script self-contained we pin the app at
 *     a non-zero address that the Vitis FSBL loader accepts: 0x0010_0000.
 *
 * For PHASE B GATE purposes (compile + link + size + nm check), the absolute
 * addresses don't matter as long as the sections resolve. On actual board
 * deployment (Phase C0+), Vitis will regenerate its own linker script using
 * xparameters.h derived from the Vivado XSA — this one is for offline
 * build-verify only.
 *
 * Symbols used by crt0_aarch64.S:
 *   _stack_top     — stack growth pointer (grows down)
 *   __bss_start    — start of .bss (zeroed by crt0)
 *   __bss_end      — end of .bss
 */

ENTRY(_start)

MEMORY {
    DDR_LO  (rwx) : ORIGIN = 0x00100000, LENGTH = 16M
}

SECTIONS
{
    . = ORIGIN(DDR_LO);

    .text : {
        KEEP(*(.text.startup))
        *(.text*)
        *(.rodata*)
        . = ALIGN(8);
    } > DDR_LO

    .data : {
        __data_start = .;
        *(.data*)
        *(.sdata*)
        . = ALIGN(8);
        __data_end = .;
    } > DDR_LO

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > DDR_LO

    /* 64 KB stack */
    .stack (NOLOAD) : {
        . = ALIGN(16);
        _stack_bottom = .;
        . = . + 0x10000;
        _stack_top = .;
    } > DDR_LO

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.ARM.exidx*)
        *(.ARM.extab*)
        *(.eh_frame*)
    }
}
