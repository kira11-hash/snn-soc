/* fw/v2_e203_smoke/link_v2_e203_encoder.ld
 *
 * V2E203 encoder-parity firmware linker script.
 * Same memory map as smoke, but reserves .encoder_bufs at 0x00010800 for
 * the 2 KB stream buffer (64 rows × 32 B). RPC slots at 0x00011E00/04.
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

    /* Encoder stream output buffer: 2 KB, fixed slot for TB readback */
    .encoder_bufs 0x00010800 (NOLOAD) : {
        *(.encoder_bufs*)
    } > DMEM

    ASSERT(_ebss <= __stack_top - __stack_reserve + 1,
           "DMEM overflow (encoder): _ebss collides with stack reserve")
}
