/* fw/v2_e203_smoke/link_v2_e203_encoder.ld
 *
 * V2E203 encoder-parity firmware linker script.
 * Same memory map as smoke, but .encoder_bufs is placed dynamically after
 * .bss. The firmware publishes runtime BUFFER_PTR_* fields for TB access.
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

    /* Encoder stream output buffer + RPC slots, dynamically placed after .bss. */
    .encoder_bufs (NOLOAD) : {
        . = ALIGN(0x40);
        __encoder_stream_base = .;
        . += 0x800;  /* 2 KB = 64 rows x 8 words x 4 B */
        __encoder_sample_req = .;
        . += 4;
        __encoder_sample_done = .;
        . += 4;
        __encoder_all_done = .;
        . += 4;
        __encoder_bufs_end = .;
    } > DMEM

    ASSERT(__encoder_bufs_end <= __stack_top - __stack_reserve + 1,
           "DMEM overflow (encoder): buffers collide with stack reserve")
}
