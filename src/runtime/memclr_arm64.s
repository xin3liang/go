// Copyright 2014 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#include "textflag.h"

// See memclrNoHeapPointers Go doc for important implementation constraints.

#define dstin	R0
#define val	ZR
#define count	R1
#define dst	R2
#define dstend	R3
#define zva_val	R4
#define off	R2
#define dstend2	R4

// func memclrNoHeapPointers(ptr unsafe.Pointer, n uintptr)
// Also called from assembly in sys_windows_arm64.s without g (but using Go stack convention).
TEXT runtime·memclrNoHeapPointers<ABIInternal>(SB),NOSPLIT,$0-16
	VDUP	val, V0.B16
	CMP	$16, count
	BLO	set_small

	ADD	count, dstin, dstend
	CMP	$64, count
	BHS	set_128

	// Set 16..63 bytes.
	MOVD	$16, off
	AND	count>>1, off, off
	SUB	off, dstend, dstend2
	FMOVQ	F0, (dstin)
	// Go arm64 asm doesn't support register's value as offset.
	// E.g. FMOVQ F0, (R0)(R2)
	// See issue: https://github.com/golang/go/issues/74753
	WORD	$0x3CA26800 // FMOVQ F0, (dstin)(off) a.k.a str q0, [x0, x2]
	FMOVQ	F0, -16(dstend2)
	FMOVQ	F0, -16(dstend)
	RET

	PCALIGN	$16
	// Set 0..15 bytes.
	// Note(xin3liang): For count >= 8 bytes, operate with 8-byte
	// alignment to ensure atomic writing of 64-bit pointers.
set_small:
	ADD	count, dstin, dstend
	TBZ	$3, count, set_7
	MOVD	val, (dstin)
	MOVD	val, -8(dstend)
	RET

	// Set 0..7 bytes.
set_7:
	TBZ	$2, count, set_3
	MOVW	val, (dstin)
	MOVW	val, -4(dstend)
	RET

set_3:
	// Set 0..3 bytes.
	CBZ	count, set_0
	LSR	$1, count, off
	MOVB	val, (dstin)
	MOVB	val, (dstin)(off)
	MOVB	val, -1(dstend)
set_0:
	RET

	PCALIGN	$16
set_128:
	BIC	$15, dstin, dst
	CMP	$128, count
	BHI	set_long
	FSTPQ	(F0, F0), (dstin)
	FSTPQ	(F0, F0), 32(dstin)
	FSTPQ	(F0, F0), -64(dstend)
	FSTPQ	(F0, F0), -32(dstend)
	RET

	PCALIGN	$16
set_long:
	FMOVQ	F0, (dstin)
	FMOVQ	F0, 16(dst)
//	TSTW	$255, val
//	BNE	no_zva
	MRS	DCZID_EL0, zva_val
	AND	$31, zva_val, zva_val
	CMP	$4, zva_val			// ZVA size is 64 bytes.
	BNE	no_zva
	FSTPQ	(F0, F0), 32(dst)
	BIC	$63, dstin, dst
	SUB	dst, dstend, count		// Count is now 64 too large.
	SUB	$(64 + 64), count, count	// Adjust count and bias for loop.

	// Write last bytes before ZVA loop.
	FSTPQ	(F0, F0), -64(dstend)
	FSTPQ	(F0, F0), -32(dstend)

	PCALIGN	$16
zva64_loop:
	ADD	$64, dst, dst
	DC	ZVA, dst
	SUBS	$64, count, count
	BHI	zva64_loop
	RET

	PCALIGN	$8
no_zva:
	SUB	dst, dstend, count		// Count is 32 too large.
	SUB	$(64 + 32), count, count	// Adjust count and bias for loop.
no_zva_loop:
	FSTPQ	(F0, F0), 32(dst)
	FSTPQ	(F0, F0), 64(dst)
	ADD	$64, dst, dst
	SUBS	$64, count, count
	BHI	no_zva_loop
	FSTPQ	(F0, F0), -64(dstend)
	FSTPQ	(F0, F0), -32(dstend)
	RET
