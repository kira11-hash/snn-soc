/*
 * fw/arm/link_arm.ld — AArch64 standalone linker script for Phase B Gate B.
 *
 * Memory model (Zynq UltraScale+ ZCU102):
 *   - OCM 0xFFFC_0000..0xFFFF_FFFF (256 KB, 4 × 64 KB banks). The Phase C0
 *     first-smoke ELF is deliberately linked into OCM so it does not depend on
 *     DDR training / address-line behavior in a raw psu_init.tcl + JTAG flow.
 *     Current image size is ~137 KB including 64 KB stack, so it fits.
 *   - A future Vitis BSP application can move .text/.rodata to DDR after FSBL
 *     initialization and MMU/cache attributes are under BSP control.
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

    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.ARM.exidx*)
        *(.ARM.extab*)
        *(.eh_frame*)
    }
}
