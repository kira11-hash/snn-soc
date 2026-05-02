/* fw/v2_e203_smoke/link_v2_e203_lenet5.ld
 *
 * V2E203 LeNet-5 firmware linker script.
 * IMEM 64 KB @ 0x0, DMEM 8 KB @ 0x0001_0000.
 * DMEM tail reserved: marker (0x100) + stack (0xC00 = 3 KB).
 */

ENTRY(_start)

MEMORY {
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
    DMEM (rwx) : ORIGIN = 0x00010000, LENGTH = 8K
}

__marker_base   = ORIGIN(DMEM) + LENGTH(DMEM) - 0x100;
__stack_top     = __marker_base - 4;
__stack_reserve = 0xC00;

SECTIONS {
    .text : {
        KEEP(*(.text.start))
        *(.text*)
        . = ALIGN(4);
    } > IMEM

    .rodata : {
        *(.rodata*)
        . = ALIGN(4);
    } > IMEM

    .data : {
        _sdata = .;
        *(.data*)
        . = ALIGN(4);
        _edata = .;
    } > DMEM AT > IMEM
    _sidata = LOADADDR(.data);

    .bss (NOLOAD) : {
        _sbss = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > DMEM

    ASSERT(_ebss <= __stack_top - __stack_reserve + 1,
           "DMEM overflow (lenet5): .bss collides with stack reserve")
}
