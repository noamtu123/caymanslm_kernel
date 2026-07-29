// ksu-fd-probe.S -- verify that an untrusted process cannot obtain KSU's fd.
//
// This is intentionally libc-free and statically linked so it can run from
// /data/local/tmp on the target.  KernelSU's reboot hook previously wrote an
// anonymous KSU file descriptor through result before the stock syscall
// rejected the caller for lacking CAP_SYS_BOOT.  A protected kernel leaves the
// sentinel intact and exits 0; a descriptor exposure changes it and exits 1.

	.global _start
	.text
_start:
	adrp	x3, result
	add	x3, x3, :lo12:result

	// reboot(KSU_INSTALL_MAGIC1, KSU_INSTALL_MAGIC2, 0, &result)
	mov	x0, #0xbeef
	movk	x0, #0xdead, lsl #16
	mov	x1, #0xbabe
	movk	x1, #0xcafe, lsl #16
	mov	x2, #0
	mov	x8, #142		// __NR_reboot on arm64
	svc	#0

	ldr	w0, [x3]
	mov	w1, #0x5a5a
	movk	w1, #0x5a5a, lsl #16
	cmp	w0, w1
	b.ne	1f
	mov	x0, #0		// no KSU descriptor was exposed
	b	2f
1:
	mov	x0, #1		// KSU wrote a descriptor: exposure remains
2:
	mov	x8, #93		// __NR_exit on arm64
	svc	#0

	.data
	.align	2
result:
	.word	0x5a5a5a5a
