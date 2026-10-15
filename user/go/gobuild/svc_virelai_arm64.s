//go:build virelai

// gobuild's raw six-argument syscall gateway (slot 28 with the B1 stream
// request needs x4/x5, past vi.Exec's four-arg call). Mirrors the idiom of
// user/go/vi/vi_arm64.s: x8 = slot, x0-x5 = args, x0 = result.

#include "textflag.h"

// func execsvc6(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64
TEXT ·execsvc6(SB),NOSPLIT|NOFRAME,$0-64
	MOVD	num+0(FP), R8
	MOVD	a0+8(FP), R0
	MOVD	a1+16(FP), R1
	MOVD	a2+24(FP), R2
	MOVD	a3+32(FP), R3
	MOVD	a4+40(FP), R4
	MOVD	a5+48(FP), R5
	SVC
	MOVD	R0, ret+56(FP)
	RET
