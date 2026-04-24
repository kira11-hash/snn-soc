/* fw/v2_e203_smoke/link_v2_e203_smoke.ld
 *
 * V2E203 smoke firmware linker script.
 * IMEM 64 KB @ 0x0, DMEM 8 KB @ 0x0001_0000.
 * DMEM tail reserved: marker (0x100) + stack (0xC00 = 3 KB).
 */

ENTRY(_start)

MEMORY {
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
    DMEM (rwx) : ORIGIN = 0x00010000, LENGTH = 8K
}

__marker_base   = ORIGIN(DMEM) + LENGTH(DMEM) - 0x100;  /* 0x0001_1F00 */
__stack_top     = __marker_base - 4;                    /* 0x0001_1EFC */
__stack_reserve = 0xC00;                                /* 3 KB */

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

    /* Smoke-specific NOLOAD scratch (counts + sample_done_flags), fixed DMEM slot */
    .smoke_bufs 0x00011000 (NOLOAD) : {
        *(.smoke_bufs*)
    } > DMEM

    /* Smoke build does not use encoder RPC buffer; keep slot reserved for
       symmetry with encoder build so TB addresses line up regardless. */

    /* DMEM overflow guard: _ebss must not collide with stack reserve window.
       _ebss <= __stack_top - __stack_reserve + 1 */
    ASSERT(_ebss <= __stack_top - __stack_reserve + 1,
           "DMEM overflow (smoke): _ebss collides with stack reserve")
}
