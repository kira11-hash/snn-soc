ENTRY(_start)

MEMORY {
    APPMEM (rx)  : ORIGIN = 0x00004800, LENGTH = 2K
    DMEM   (rwx) : ORIGIN = 0x00013800, LENGTH = 1792
}

SECTIONS {
    .text : {
        KEEP(*(.text.start))
        *(.text*)
        . = ALIGN(4);
    } > APPMEM

    .rodata : {
        *(.rodata*)
        . = ALIGN(4);
    } > APPMEM

    .data : {
        _sdata = .;
        *(.data*)
        . = ALIGN(4);
        _edata = .;
    } > DMEM AT > APPMEM
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
