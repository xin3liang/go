// Copyright 2014-2025 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#include "textflag.h"

// See memmove Go doc for important implementation constraints.

// Register map
#define dstin	R0
#define src	R1
#define count	R2
#define dst	R3
#define srcend	R4
#define dstend	R5
#define A_l	R6
#define A_h	R7
#define B_l	R8
#define B_h	R9
#define C_l	R10
#define tmp1	R14

#define A_q	F0
#define B_q	F1
#define C_q	F2
#define D_q	F3
#define E_q	F4
#define F_q	F5
#define G_q	F6
#define H_q	F7

// This implementation handles overlaps and supports both memcpy and memmove
// from a single entry point.  It uses unaligned accesses and branchless
// sequences to keep the code small, simple and improve performance.
//
// Copies are split into 3 main cases: small copies of up to 32 bytes, medium
// copies of up to 128 bytes, and large copies. The overhead of the overlap
// check is negligible since it is only required for large copies.
//
// Large copies use a software pipelined loop processing 64 bytes per iteration.
// The source pointer is 16-byte aligned to minimize unaligned accesses.
// The loop tail is handled by always copying 64 bytes from the end.

// func memmove(to, from unsafe.Pointer, n uintptr)
TEXT runtime·memmove<ABIInternal>(SB), NOSPLIT|NOFRAME, $0-24
	ADD	count, src, srcend
	CMP	$128, count
	BHI	copy_long
	ADD	count, dstin, dstend
	CMP	$32, count
	BHI	copy32_128
	NOOP

	// Small copies: 0..32 bytes
	CMP	$16, count
	BLO	copy16
	FMOVQ	(src), A_q
	FMOVQ	-16(srcend), B_q
	FMOVQ	A_q, (dstin)
	FMOVQ	B_q, -16(dstend)
	RET

	// Medium copies: 33..128 bytes
copy32_128:
	FLDPQ	(src), (A_q, B_q)
	FLDPQ	-32(srcend), (C_q, D_q)
	CMP	$64, count
	BHI	copy128
	FSTPQ	(A_q, B_q), (dstin)
	FSTPQ	(C_q, D_q), -32(dstend)
	RET

	// Copy 8-15 bytes
copy16:
	TBZ	$3, count, copy8
	MOVD	(src), A_l
	MOVD	-8(srcend), A_h
	MOVD	A_l, (dstin)
	MOVD	A_h, -8(dstend)
	RET

	// Copy 4-7 bytes
copy8:
	TBZ	$2, count, copy4
	MOVWU	(src), A_l
	MOVWU	-4(srcend), B_l
	MOVW	A_l, (dstin)
	MOVW	B_l, -4(dstend)
	RET

	// Copy 65..128 bytes
copy128:
	FLDPQ	32(src), (E_q, F_q)
	CMP	$96, count
	BLS	copy96
	FLDPQ	-64(srcend), (G_q, H_q)
	FSTPQ	(G_q, H_q), -64(dstend)
copy96:
	FSTPQ	(A_q, B_q), (dstin)
	FSTPQ	(E_q, F_q), 32(dstin)
	FSTPQ	(C_q, D_q), -32(dstend)
	RET

	// Copy 0..3 bytes using a branchless sequence.
copy4:
	CBZ	count, copy0
	LSR	$1, count, tmp1
	MOVBU	(src), A_l
	MOVBU	-1(srcend), C_l
	MOVBU	(src)(tmp1), B_l
	MOVB	A_l, (dstin)
	MOVB	B_l, (dstin)(tmp1)
	MOVB	C_l, -1(dstend)
copy0:
	RET

	// Copy more than 128 bytes.
copy_long:
	ADD	count, dstin, dstend

	// Use backwards copy if there is an overlap.
	SUB	src, dstin, tmp1
	CMP	count, tmp1
	BLO	copy_long_backwards

	// Copy 16 bytes and then align src to 16-byte alignment.
	FMOVQ	(src), D_q
	AND	$15, src, tmp1
	BIC	$15, src, src
	SUB	tmp1, dstin, dst
	ADD	tmp1, count, count  // count is now 16 too large.
	FLDPQ	16(src), (A_q, B_q)
	FMOVQ	D_q, (dstin)
	FLDPQ	48(src), (C_q, D_q)
	SUBS	$(128+16), count, count  // Test and readjust count.
	BLS	copy64_from_end

loop64:
	FSTPQ	(A_q, B_q), 16(dst)
	FLDPQ	80(src), (A_q, B_q)
	FSTPQ	(C_q, D_q), 48(dst)
	FLDPQ	112(src), (C_q, D_q)
	ADD	$64, src, src
	ADD	$64, dst, dst
	SUBS	$64, count, count
	BHI	loop64

	// Write the last iteration and copy 64 bytes from the end.
copy64_from_end:
	FLDPQ	-64(srcend), (E_q, F_q)
	FSTPQ	(A_q, B_q), 16(dst)
	FLDPQ	-32(srcend), (A_q, B_q)
	FSTPQ	(C_q, D_q), 48(dst)
	FSTPQ	(E_q, F_q), -64(dstend)
	FSTPQ	(A_q, B_q), -32(dstend)
	RET

	// Large backwards copy for overlapping copies.
	// Copy 16 bytes and then align srcend to 16-byte alignment.
copy_long_backwards:
	CBZ	tmp1, copy0
	FMOVQ	-16(srcend), D_q
	AND	$15, srcend, tmp1
	BIC	$15, srcend, srcend
	SUB	tmp1, count, count
	FLDPQ	-32(srcend), (A_q, B_q)
	FMOVQ	D_q, -16(dstend)
	FLDPQ	-64(srcend), (C_q, D_q)
	SUB	tmp1, dstend, dstend
	SUBS	$128, count, count
	BLS	copy64_from_start

loop64_backwards:
	FMOVQ	B_q, -16(dstend)
	FMOVQ	A_q, -32(dstend)
	FLDPQ	-96(srcend), (A_q, B_q)
	FMOVQ	D_q, -48(dstend)
	FMOVQ.W	C_q, -64(dstend)
	FLDPQ	-128(srcend), (C_q, D_q)
	SUB	$64, srcend, srcend
	SUBS	$64, count, count
	BHI	loop64_backwards

	// Write the last iteration and copy 64 bytes from the start
copy64_from_start:
	FLDPQ	32(src), (E_q, F_q)
	FSTPQ	(A_q, B_q), -32(dstend)
	FLDPQ	(src), (A_q, B_q)
	FSTPQ	(C_q, D_q), -64(dstend)
	FSTPQ	(E_q, F_q), 32(dstin)
	FSTPQ	(A_q, B_q), (dstin)
	RET
