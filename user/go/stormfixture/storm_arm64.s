// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

// M129b (#2611) — the spawn-storm fixture's syscall seam. One `svc #0`
// per call: x8 = slot (ADR 0007), x0-x5 = arguments, x0 = result
// (negative = kernel errno; EAGAIN -11 is the pool/thread-bound refusal).

//go:build virelai

#include "textflag.h"

#define VIR_SYS_YIELD  2
#define VIR_SYS_SLEEP  4
#define VIR_SYS_THREAD 73

// func threadCreate(stackHi, arg uintptr) int32 — slot 73 op 0, entry =
// ·stormChild. Returns the new kernel tid (>= 0) or a negative errno
// (EAGAIN when the task pool or the per-process thread bound is full).
TEXT ·threadCreate(SB), NOSPLIT|NOFRAME, $0-24
	MOVD	$·stormChild(SB), R1 // entry — inside this process's text aperture
	MOVD	stackHi+0(FP), R2
	MOVD	arg+8(FP), R3
	MOVD	$0, R0               // op 0 = create
	MOVD	$0, R4               // tls = 0
	MOVD	$VIR_SYS_THREAD, R8
	SVC
	MOVW	R0, ret+16(FP)
	RET

// The spawned task's whole life: sleep ~1 h of ticks, yield once, repeat.
// A leaf — no calls, no stack growth, no g (pure-Go arm64's R28 stays
// unset); it exists to occupy a pool slot + its 48-page EL1 kstack.
TEXT ·stormChild(SB), NOSPLIT|NOFRAME, $0-0
again:
	MOVD	$3600, R0            // ticks (~1 s each)
	MOVD	$VIR_SYS_SLEEP, R8
	SVC
	MOVD	$VIR_SYS_YIELD, R8
	SVC
	B	again
