/*
 * fw/arm/src/crt0_aarch64.S — minimal AArch64 startup for ZCU102 standalone.
 *
 * Called by Xilinx FSBL / Vitis BSP init chain AFTER:
 *   - PS DDR is trained and mapped
 *   - MMU + caches are enabled (Vitis BSP MMUTable.c does this)
 *   - Cortex-A53 core 0 is unparked
 *
 * This crt0 does the bare minimum that Vitis BSP's own _start doesn't
 * already cover:
 *   - Set up stack pointer to _stack_top (defined in link_arm.ld)
 *   - Zero .bss
 *   - Branch to arm_main
 *
 * For Phase B Gate verification (ELF link check only, no BSP yet), this
 * standalone crt0 is sufficient. On the actual board (Phase C0+), Vitis
 * would normally provide its own startup; if we replace Vitis's crt0
 * with this one we'd need to also do MMU + GIC + UART initialization
 * which this file skips. A future iteration may point Vitis at this file
 * via the linker script override.
 *
 * Memory model: the LDR= pseudo-instr resolves via the linker's literal
 * pool. The `adrp` + `add` sequence is the standard AArch64 way to load
 * a 64-bit symbol address without relying on a literal pool being within
 * ±1 MB.
 */
	.section .text.startup, "ax"
	.globl _start
	.type _start, @function
_start:
	/* Disable IRQ/FIQ while we set things up */
	msr     DAIFSet, #0xF

	/* Set SP to top of stack region (reserved in link_arm.ld) */
	adrp    x0, _stack_top
	add     x0, x0, :lo12:_stack_top
	mov     sp, x0

	/* Zero-fill .bss */
	adrp    x0, __bss_start
	add     x0, x0, :lo12:__bss_start
	adrp    x1, __bss_end
	add     x1, x1, :lo12:__bss_end
1:	cmp     x0, x1
	b.ge    2f
	str     xzr, [x0], #8
	b       1b
2:

	/* Unmask IRQ/FIQ (app may choose not to use them) */
	msr     DAIFClr, #0x3

	/* Branch to C entry */
	bl      arm_main

	/* If arm_main returns, hang forever */
3:	wfi
	b       3b
	.size _start, . - _start
