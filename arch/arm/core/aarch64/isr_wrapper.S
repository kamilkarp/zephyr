/*
 * Copyright (c) 2019 Carlo Caione <ccaione@baylibre.com>
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/**
 * @file
 * @brief ARM64 Cortex-A ISRs wrapper
 */

#include <toolchain.h>
#include <linker/sections.h>
#include <offsets_short.h>
#include <arch/cpu.h>
#include <sw_isr_table.h>
#include "macro.inc"

_ASM_FILE_PROLOGUE

GDATA(_sw_isr_table)

/**
 * @brief Wrapper around ISRs when inserted in software ISR table
 *
 * When inserted in the vector table, _isr_wrapper() demuxes the ISR table
 * using the running interrupt number as the index, and invokes the registered
 * ISR with its corresponding argument. When returning from the ISR, it
 * determines if a context switch needs to happen.
 *
 * @return N/A
 */

GTEXT(_isr_wrapper)
SECTION_FUNC(TEXT, _isr_wrapper)
	z_arm64_enter_exc

	/* ++(_kernel->nested) to be checked by arch_is_in_isr() */
	ldr	x1, =_kernel
	ldr	x2, [x1, #_kernel_offset_to_nested]
	add	x2, x2, #1
	str	x2, [x1, #_kernel_offset_to_nested]

#ifdef CONFIG_TRACING
	bl	sys_trace_isr_enter
#endif

	/* Get active IRQ number from the interrupt controller */
#if !defined(CONFIG_ARM_CUSTOM_INTERRUPT_CONTROLLER)
	bl arm_gic_get_active
#else
	bl z_soc_irq_get_active
#endif /* !CONFIG_ARM_CUSTOM_INTERRUPT_CONTROLLER */
	stp x0, x1, [sp, #-16]!
	lsl x0, x0, #4 /* table is 16-byte wide */

	/* Call interrupt service routine */
	ldr	x1, =_sw_isr_table
	add	x1, x1, x0
	ldp	x0, x3, [x1] /* arg in x0, ISR in x3 */

	blr	x3

	/* Signal end-of-interrupt */
	ldp x0, x1, [sp], #16
#if !defined(CONFIG_ARM_CUSTOM_INTERRUPT_CONTROLLER)
	bl arm_gic_eoi
#else
	bl z_soc_irq_eoi
#endif /* !CONFIG_ARM_CUSTOM_INTERRUPT_CONTROLLER */

#ifdef CONFIG_TRACING
	bl	sys_trace_isr_exit
#endif

	/* --(_kernel->nested) */
	ldr	x1, =_kernel
	ldr	x2, [x1, #_kernel_offset_to_nested]
	sub	x2, x2, #1
	str	x2, [x1, #_kernel_offset_to_nested]

	/* Check if we need to context switch */
	ldr	x2, [x1, #_kernel_offset_to_current]
	ldr	x3, [x1, #_kernel_offset_to_ready_q_cache]
	cmp	x2, x3
	beq	exit

	/* Switch thread */
	bl	z_arm64_pendsv

	/* We return here in two cases:
	 *
	 * - The ISR was taken and no context switch was performed.
	 * - A context-switch was performed during the ISR in the past and now
	 *   the thread has been switched in again and we return here from the
	 *   ret in z_arm64_pendsv() because x30 was saved and restored.
	 */
exit:
#ifdef CONFIG_STACK_SENTINEL
	bl	z_check_stack_sentinel
#endif
	z_arm64_exit_exc

