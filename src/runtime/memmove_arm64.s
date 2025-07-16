// Copyright 2014 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#include "textflag.h"

// See memmove Go doc for important implementation constraints.

// Register map
//
// dstin  R0
// src    R1
// count  R2
// dst    R3 (same as R0, but gets modified in unaligned cases)
// srcend R4
// dstend R5
// data   R6-R17
// tmp1   R14

// Copies are split into 3 main cases: small copies of up to 32 bytes, medium
// copies of up to 128 bytes, and large copies. The overhead of the overlap
// check is negligible since it is only required for large copies.
//
// Large copies use a software pipelined loop processing 64 bytes per iteration.
// The destination pointer is 16-byte aligned to minimize unaligned accesses.
// The loop tail is handled by always copying 64 bytes from the end.

// func memmove(to, from unsafe.Pointer, n uintptr)
TEXT runtime·memmove<ABIInternal>(SB), NOSPLIT|NOFRAME, $0-24
	CBZ	R2, copy0

	ADD R1, R2, R4 	//  R4 points just past the last source byte
	// Large copies
	CMP	$128, R2
	BHI	copy_long
	ADD R0, R2, R5 	//  R5 points just past the last destination byte
	CMP	$32, R2
	BHI	copy32_128
	// Small copies: 1..16 bytes
	CMP	$16, R2
	BLO	copy16

	// Small copies: 17..32 bytes.
	FMOVQ (R1), F0
	FMOVQ -16(R4), F1
	FMOVQ F0, (R0)
	FMOVQ F1, -16(R5)
	RET

// Small copies: 1..16 bytes.
copy16:
//	ADD	R1, R2, R4 // R4 points just past the last source byte
//	ADD	R0, R2, R5 // R5 points just past the last destination byte
	CMP	$8, R2
	BLT	copy7
	MOVD	(R1), R6
	MOVD	-8(R4), R7
	MOVD	R6, (R0)
	MOVD	R7, -8(R5)
	RET

copy7:
	TBZ	$2, R2, copy3
	MOVWU	(R1), R6
	MOVWU	-4(R4), R7
	MOVW	R6, (R0)
	MOVW	R7, -4(R5)
	RET

copy3:
	TBZ	$1, R2, copy1
	MOVHU	(R1), R6
	MOVHU	-2(R4), R7
	MOVH	R6, (R0)
	MOVH	R7, -2(R5)
	RET

copy1:
	MOVBU	(R1), R6
	MOVB	R6, (R0)

copy0:
	RET

	// Medium copies: 33..128 bytes.
copy32_128:
	FLDPQ (R1), (F0, F1)
	FLDPQ -32(R4), (F2, F3)
	CMP $64, R2
	BHI copy128
	FSTPQ (F0, F1), (R0)
	FSTPQ (F2, F3), -32(R5)
	RET

	// Copy 65..128 bytes.
copy128:
	FLDPQ 32(R1), (F4, F5)
	CMP $96, R2
	BLS	copy96
	FLDPQ -64(R4), (F6, F7)
	FSTPQ (F6, F7), -64(R5)

copy96:
	FSTPQ (F0, F1), (R0)
	FSTPQ (F4, F5), 32(R0)
	FSTPQ (F2, F3), -32(R5)
	RET

	// Copy more than 128 bytes.
copy_long:
	ADD	R0, R2, R5 // R5 points just past the last destination byte
	MOVD	ZR, R7
	MOVD	ZR, R8

	CMP	$1024, R2
	BLT	backward_check
	// feature detect to decide how to align
	MOVBU	runtime·arm64UseAlignedLoads(SB), R6
	CBNZ	R6, use_aligned_loads
	MOVD	R0, R7
	MOVD	R5, R8
	B	backward_check
use_aligned_loads:
	MOVD	R1, R7
	MOVD	R4, R8
	// R7 and R8 are used here for the realignment calculation. In
	// the use_aligned_loads case, R7 is the src pointer and R8 is
	// srcend pointer, which is used in the backward copy case.
	// When doing aligned stores, R7 is the dst pointer and R8 is
	// the dstend pointer.

backward_check:
	// Use backward copy if there is an overlap.
	SUB	R1, R0, R14
	CMP	R2, R14
	BLO	copy_long_backward

	// Copy 16 bytes and then align src (R1) or dst (R0) to 16-byte alignment.
	FMOVQ(R1), F3               // Load D
	AND	$15, R7, R14         // Calculate the realignment offset
	SUB	R14, R1, R1
	SUB	R14, R0, R3          // move dst back same amount as src
	ADD	R14, R2, R2
	FLDPQ 16(R1), (F0, F1)        // Load A, B
	FMOVQ F3, (R0)                // Store D
	FLDPQ 48(R1), (F2, F3)        // Load C, D
	SUBS	$144, R2, R2
	BLS	copy64_from_end

loop64:
	FSTPQ (F0, F1), 16(R3)      // Store A, B
	FLDPQ 80(R1), (F0, F1)      // Load A, B
	FSTPQ (F2, F3), 48(R3)      // Store C, D
	FLDPQ 112(R1), (F2, F3)     // Load C, D
	ADD $64, R3, R3 // Move dst pointer forward by 64 bytes
	ADD $64, R1, R1 // Move src pointer forward by 64 bytes
	SUBS $64, R2, R2 // Decrease count by 64 bytes
	BHI	loop64

	// Write the last iteration and copy 64 bytes from the end.
copy64_from_end:
	FLDPQ -64(R4), (F4, F5) 	// Load E, F
	FSTPQ (F0, F1), 16(R3)      // Store A, B
	FLDPQ -32(R4), (F0, F1)      // Load A, B
	FSTPQ (F2, F3), 48(R3)      // Store C, D
	FSTPQ (F4, F5), -64(R5)      // Store E, F
	FSTPQ (F0, F1), -32(R5)      // Store A, B
	RET

	// Large backward copy for overlapping copies.
	// Copy 16 bytes and then align srcend (R4) or dstend (R5) to 16-byte alignment.
copy_long_backward:
	CBZ	R14, copy0
	FMOVQ -16(R4), F3
	AND	$15, R8, R14
	SUB	R14, R4, R4
	SUB	R14, R2, R2
	FLDPQ -32(R4), (F0, F1)
	FMOVQ F3, -16(R5)
	FLDPQ -64(R4), (F2, F3)
	SUB R14, R5, R5
	SUBS $128, R2, R2
	BLS	copy64_from_start

loop64_backward:
	FMOVQ F1, -16(R5)
	FMOVQ F0, -32(R5)
	FLDPQ -96(R4), (F0, F1)
	FMOVQ F3, -48(R5)
	FMOVQ.W F2, -64(R5)
	FLDPQ -128(R4), (F2, F3)
	SUB $64, R4, R4
	SUBS $64, R2, R2
	BHI	loop64_backward

	// Write the last iteration and copy 64 bytes from the start.
copy64_from_start:
	FLDPQ 32(R1), (F4, F5)
	FSTPQ (F0, F1), -32(R5)
	FLDPQ (R1), (F0, F1)
	FSTPQ (F2, F3), -64(R5)
	FSTPQ (F4, F5), 32(R0)
	FSTPQ (F0, F1), (R0)
	RET
