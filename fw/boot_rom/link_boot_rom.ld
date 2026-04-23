ENTRY(_start)

MEMORY {
    ROM  (rx)  : ORIGIN = 0x00000000, LENGTH = 4K
    DMEM (rwx) : ORIGIN = 0x00013800, LENGTH = 1792
}

SECTIONS {
    .text : {
        KEEP(*(.text.start))
        *(.text*)
        . = ALIGN(4);
    } > ROM

    .rodata : {
        *(.rodata*)
        . = ALIGN(4);
    } > ROM

    .data : {
        _sdata = .;
        *(.data*)
        . = ALIGN(4);
        _edata = .;
    } > DMEM AT > ROM
    _sidata = LOADADDR(.data);

    .bss (NOLOAD) : {
        _sbss = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > DMEM

    _stack_top = ORIGIN(DMEM) + LENGTH(DMEM);
}
