ENTRY(_start)

MEMORY {
    APPMEM (rwx) : ORIGIN = 0x00010000, LENGTH = 12K
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
    } > APPMEM
    _sidata = LOADADDR(.data);

    .bss (NOLOAD) : {
        _sbss = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > APPMEM

    _stack_top = ORIGIN(APPMEM) + LENGTH(APPMEM);
}
