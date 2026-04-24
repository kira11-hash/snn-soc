/* fw/v2_e203_smoke/src/crt0_v2_e203.S */
/* Minimal E203 start: set sp, copy .data from LMA->VMA, clear .bss, call main. */

.section .text.start
.global _start

_start:
    la sp, __stack_top

    /* Copy .data from LMA (in IMEM) to VMA (in DMEM) */
    la t0, _sidata
    la t1, _sdata
    la t2, _edata
1:
    bgeu t1, t2, 2f
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j 1b

2:
    /* Zero .bss */
    la t0, _sbss
    la t1, _ebss
3:
    bgeu t0, t1, 4f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 3b

4:
    call main

5:
    /* Infinite spin if main returns */
    j 5b
