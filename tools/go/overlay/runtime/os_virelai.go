// Copyright 2026 The VirelaiOS Authors. All rights reserved.
// Use of this source code is governed by the repo LICENSE.

//go:build virelai

package runtime

import (
	"internal/abi"
	"internal/goarch"
	"internal/runtime/atomic"
	"unsafe"
)

// The VirelaiOS GOOS layer (issue #1163, GOOS=virelai phase 0a).
//
// VirelaiOS is a from-scratch AArch64 kernel (Zig) booted by Apple's
// Virtualization.framework: NO POSIX, NO libc, NO Linux ABI, no signals,
// no fork/exec. The EL0 syscall seam is a single `svc #0` with the number
// in x8, args in x0-x5 and the result in x0 (negative = the kernel's own
// errno encoding, ADR 0007) — see kernel/src/syscall.zig.
//
// Phase 0b (ADR 0027) / M65c (#1441): the runtime is MULTI-THREADED.
// Slot 73 sys_thread maps every Go M onto a kernel task bound to the M's
// process (newosproc passes mp.g0.stack.hi / runtime.mstart / mp); slot 74
// sys_futex backs lock_sema.go's semasleep/semawakeup instead of the
// phase-0a yield-spin. Every proc.go fork delta is RETIRED — apply.sh
// reverses leftover 0a gates on an existing fork (haveSysmon, canCreateM,
// template thread, spare-M handoffs, dolock/dounlockOSThread, stopm) so
// proc.go is byte-identical to upstream (patch_proc.py stays deleted).
// Async preemption stays OFF (preemptMSupported = false; a call-free
// tight loop delays STW, shared with wasip1). Signals are phase 0c.
//
// Memory uses the runtime's sbrk platform (mem_sbrk.go, build-tagged for
// virelai): the heap grows contiguously from firstmoduledata.end via
// sys_mmap with an address hint — Linux-brk semantics over the kernel's
// demand-backed anonymous mmap (slot 63), with zero kernel-side heap
// changes. physPageSize must be 4096 (the kernel's page size; the arm64
// default of 64K would misalign every sbrk round).

// Syscall numbers (ADR 0007, kernel/src/syscall.zig).
const (
	virSysWrite     = 1  // sys_write(fd, buf, len): console, <=256B/call
	virSysYield     = 2  // sys_yield()
	virSysExit      = 3  // sys_exit(status)
	virSysTime      = 66 // sys_time(): boot wall-clock epoch, unix seconds
	virSysGetrandom = 72 // sys_getrandom(buf, len): CSPRNG bytes (M51 #1166)
	virSysThread    = 73 // sys_thread(op, ...): op 0 create, op 1 exit (ADR 0027 D3)
	virSysFutex     = 74 // sys_futex(op, uaddr, val, timeout_ns): op 0 wait, op 1 wake (D4)
)

// virWrite1 issues ONE sys_write (the kernel caps len at 256 bytes).
//
//go:noescape
func virWrite1(fd uintptr, p unsafe.Pointer, n int32) int32

func virYield()

//go:noescape
func virExit(code int32)

//go:noescape
func virTime() int64

//go:noescape
func virGetrandom(p *byte, n int) int

//go:noescape
func virCntFreq() uint64

//go:noescape
func virThreadCreate(entry, stackHi, arg unsafe.Pointer) int

//go:noescape
func virThreadExit()

//go:noescape
func virFutexWait(uaddr unsafe.Pointer, val uint32, timeoutNs int64) int

//go:noescape
func virFutexWake(uaddr unsafe.Pointer, n uint32) int

// nanotime1 reads CNTPCT_EL0 and scales by monoMul (below).
func nanotime1() int64

// write1 is the runtime's whole fatal/print output surface (writeErr ->
// write1). The kernel accepts <=256 bytes per call, so chunk here. The
// chunk loop keeps write1 nosplit-safe: it calls only NOSPLIT asm.
//
// virWriteStaging lives in the image's RW data segment, which the exec
// gap path registers as a task uaccess region. sys_write's copy_in
// validates the BUFFER address against those regions, and Go stacks live
// in the sbrk heap (an unregistered sys_mmap region) — printing straight
// from a stack buffer would EFAULT. Stage every chunk here first.
var virWriteStaging [256]byte

//go:nosplit
func write1(fd uintptr, p unsafe.Pointer, n int32) int32 {
	const chunkMax = 256
	total := int32(0)
	for n > 0 {
		chunk := int32(chunkMax)
		if n < chunk {
			chunk = n
		}
		memmove(unsafe.Pointer(&virWriteStaging), p, uintptr(chunk))
		w := virWrite1(fd, unsafe.Pointer(&virWriteStaging), chunk)
		if w < 0 {
			if total == 0 {
				return w
			}
			break
		}
		total += w
		if w < chunk {
			break // short write: give up honestly
		}
		p = add(p, uintptr(w))
		n -= w
		_ = virWriteStaging
	}
	return total
}

//go:nosplit
func osyield() {
	virYield()
}

// usleep busy-yields to the scheduler until the deadline elapses (the
// kernel has no timed sleep yet; slot 75 nanosleep is phase 0b).
//
//go:nosplit
func usleep(usec uint32) {
	deadline := nanotime() + int64(usec)*1000
	for nanotime() < deadline {
		osyield()
	}
}

//go:nosplit
func osyield_no_g() {
	virYield()
}

//go:nosplit
func usleep_no_g(usec uint32) {
	usleep(usec)
}

func exit(code int32) {
	virExit(code)
	for {
		osyield() // not reached; belt and braces if the kernel ever returns
	}
}

// exitThread terminates the current OS thread after mexit has parked the
// m on the freem list. The linux contract: store freeMStack (0) into
// *wait — the reaper may now free the m's stack — then exit the thread
// only (slot 73 op 1; the process dies when its LAST task exits).
func exitThread(wait *atomic.Uint32) {
	wait.Store(0)
	virThreadExit()
	for {
		osyield() // not reached; belt and braces if the kernel ever returns
	}
}

// virArgvBlockBase is the kernel's packed argv block VA (R1 at EL0 entry),
// recorded by rt0_virelai_arm64.s before that stub converts the block into
// rt0_go's SysV array. 0 when the image was entered with argc == 0.
//
// It is load-bearing for exactly one decision — where the heap may start
// (see the floor in osinit); the block layout itself is the RT0's contract.
var virArgvBlockBase uintptr

// The kernel's argv/envp block sizes (kernel/src/exec.zig):
// arg_block_bytes = max_exec_args(8) x arg_slot_bytes(256),
// env_block_bytes = max_exec_envs(16) x env_slot_bytes(128).
const (
	virArgBlockBytes = 8 * 256
	virEnvBlockBytes = 16 * 128
)

// osinit runs before mallocinit; it must set physPageSize and
// numCPUStartup, and (sbrk platforms) init the break.
func osinit() {
	physPageSize = 4096
	// ADR 0027 D6 (ACCEPTED): the real phase-0b setting. Two Ps + the
	// sysmon/template Ms ride the kernel's bounded task pool (11 slots);
	// the go-goroutines gate proves cross-core scheduling of slot-73 tasks.
	// Issue #1226: GOMAXPROCS in the exec envp overrides this at schedinit;
	// the default stays 2 (two vCPUs) — no osinit bump.
	numCPUStartup = 2
	getg().m.procid = 1
	initMonoScale()
	wallEpochSec = virTime()
	initBloc()
	initBlocFloor()
}

// initBlocFloor raises the initial break past the memory the KERNEL packed
// into the image's own data aperture (M70c-S1L, issue #1540; M71m #1572
// grew the argv half to 8×256).
//
// initBloc() starts the heap at memRound(firstmoduledata.end). The loader
// maps the writable segment through align8(mem_size)+virArgBlockBytes+
// virEnvBlockBytes, which for this 4096-byte block is one page past the
// image. That block, placed at align8(mem_size), ends past memRound(end),
// so the break has to start on the page after the block. Otherwise the
// first mapping sbrk asks for is refused EINVAL and mallocinit dies with
// "cannot allocate memory". The two constants above must match the kernel
// or the floor lands inside the block.
func initBlocFloor() {
	if virArgvBlockBase == 0 || virArgvBlockBase < firstmoduledata.end {
		// No block this runtime knows about (argc == 0), or a shape where
		// the block does NOT sit past the image end (the DSK1/contiguous
		// entry convention packs it elsewhere): leave the break alone
		// rather than guess a floor that could land inside that aperture.
		return
	}
	if f := memRound(virArgvBlockBase + virArgBlockBytes + virEnvBlockBytes); f > bloc {
		bloc = f
		blocMax = f
	}
}

// getCPUCount backs cgroup_stubs.go's defaultGOMAXPROCS path: matches the
// numCPUStartup setting (ADR 0027 D6) — the VZ guest has 2 vCPUs.
func getCPUCount() int32 {
	return 2
}

// Per-GOOS extensions of m (runtime2.go embeds mOS) and the unused
// signal-stack type (plan9/wasm shape — no signals exist on virelai).
type mOS struct {
	// lock_sema.go's semaphore slot (the openbsd shape). Slot 74
	// sys_futex parks the task while waitsemacount is 0; semawakeup
	// increments and wakes one peer. Contended Ms are the 0b default.
	waitsemacount uint32
}

// gsignalStack is unused on virelai (no async signals; 0c is synchronous).
type gsignalStack struct{}

// ---- lock_sema.go's required semaphore primitives (futex-backed) ----
// ADR 0027 D4 (phase 0b): the slot-74 futex parks the task in the kernel
// while *uaddr == val (the kernel verifies the word under the caller's
// uaccess window), replacing the phase-0a yield-spin. The wait word is the
// m's waitsemacount; semawakeup increments it and wakes one parked peer,
// whose re-check then observes the nonzero count. A -ETIMEDOUT return
// (the kernel's distinct timeout errno) maps to semasleep's -1.

//go:nosplit
func semacreate(mp *m) {}

//go:nosplit
func semasleep(ns int64) int32 {
	gp := getg()
	var timeout int64
	if ns >= 0 {
		timeout = ns
	}
	for {
		v := atomic.Load(&gp.m.waitsemacount)
		for v > 0 {
			if atomic.Cas(&gp.m.waitsemacount, v, v-1) {
				return 0 // acquired
			}
			v = atomic.Load(&gp.m.waitsemacount)
		}
		// Go's contract: ns == 0 is a non-blocking attempt — the kernel's
		// timeout 0 means WAIT FOREVER (that is how ns < 0 arrives), so a
		// zero timeout must return here after the lost race, not park.
		if ns == 0 {
			return -1
		}
		// Park until a wake bumps the count; the kernel returns -EAGAIN
		// (re-check) if it changed concurrently, -ETIMEDOUT on expiry.
		r := virFutexWait(noescape(unsafe.Pointer(&gp.m.waitsemacount)), 0, timeout)
		if r == _virEtimedout {
			return -1 // timed out
		}
		// 0 (woken) or -EAGAIN: loop and re-check the count.
	}
}

//go:nosplit
func semawakeup(mp *m) {
	atomic.Xadd(&mp.waitsemacount, 1)
	virFutexWake(noescape(unsafe.Pointer(&mp.waitsemacount)), 1)
}

// The kernel's futex errnos (ADR 0007 amendment): EAGAIN -11, ETIMEDOUT -12.
const (
	_virEagain    = -11
	_virEtimedout = -12
)

// libpreinit: hook for libc-initialized systems (libinit.go); a no-op —
// virelai has no libc and no constructor phase.
func libpreinit() {
}

// Time: the guest counter is EL0-readable (CNTKCTL_EL1 arms EL0VCTEN, the
// kernel's timer.allow_el0_counter), so nanotime is a pure register read
// scaled by a per-boot multiplier — no syscall on the hot path.
//
// ns = (ticks * monoMul) >> monoShift, with monoMul = floor(2^monoShift *
// 1e9 / cntfrq_el0) computed once at boot. monoShift = 44 keeps monoMul
// under 64 bits for any counter frequency above ~1 MHz (VZ guests run at
// 24 MHz) and the 128/64 division's high word (1e9 >> 20 = 953) below the
// divisor.
const monoShift = 44

var monoMul uint64

// wallEpochSec is the wall-clock (unix) second at CNTPCT=0 — the boot
// epoch from sys_time (slot 66). wall = epoch + elapsed monotonic.
var wallEpochSec int64

func initMonoScale() {
	freq := virCntFreq()
	if freq < 1_000_000 {
		freq = 1_000_000 // paranoia: never scale time faster than real
	}
	// 128/64 restoring division: q = (hi:lo) / y, valid because hi < y.
	// (hi:lo) is the 128-bit representation of 1e9 * 2^monoShift: runtime
	// shifts (not constants — 1e9<<44 overflows a uint64 constant).
	oneE9 := uint64(1_000_000_000)
	hi := oneE9 >> (64 - monoShift)
	lo := oneE9 << monoShift
	r := hi
	var q uint64
	for i := 0; i < 64; i++ {
		r = r<<1 | lo>>63
		lo <<= 1
		q <<= 1
		if r >= freq {
			r -= freq
			q |= 1
		}
	}
	monoMul = q
}

func walltime() (sec int64, nsec int32) {
	ns := nanotime()
	sec = wallEpochSec + ns/1_000_000_000
	nsec = int32(ns % 1_000_000_000)
	return
}

func cputicks() int64 {
	return nanotime()
}

// readRandom seeds the runtime PRNG (randinit calls it unconditionally).
// Returns the byte count filled; 0 on failure (randinit falls back to
// time-based seeding).
func readRandom(r []byte) int {
	if len(r) == 0 {
		return 0
	}
	n := virGetrandom(&r[0], len(r))
	if n < 0 {
		return 0
	}
	return n
}

// VirelaiArgs returns the argument vector for programs that predate the
// phase-2 `os` package (the go-args gate fixture linknames it). The
// self-referencing //go:linkname marks the symbol pullable — cmd/link's
// checklinkname otherwise refuses ANY pull from the runtime package.
// Phase 2 deletes this when os.Args works for real.
//
//go:linkname VirelaiArgs runtime.VirelaiArgs
func VirelaiArgs() []string {
	return argslice
}

// VirelaiEnvs returns the environment vector for programs that predate
// the phase-2 `os` package (the go-args gate fixture linknames it).
//
//go:linkname VirelaiEnvs runtime.VirelaiEnvs
func VirelaiEnvs() []string {
	return envs
}

// VirelaiNanotime / VirelaiSleep are the pre-phase-2 timer accessors
// (issue #1227). Package time imports syscall, which is unported until
// phase 2, so the go-stress fixture linknames these instead of calling
// time.Now / time.Sleep. VirelaiSleep is the real timer-heap path
// (runtime.timeSleep → sysmon), not the busy-yield usleep.
//
//go:linkname VirelaiNanotime runtime.VirelaiNanotime
func VirelaiNanotime() int64 {
	return nanotime()
}

//go:linkname VirelaiSleep runtime.VirelaiSleep
func VirelaiSleep(ns int64) {
	timeSleep(ns)
}

// goenvs builds os.Args and the environment from the exec entry contract
// (issue #1163 B2 + #1226, slot stride M71m #1572): the kernel packs argv
// as 256-byte slots and envp as 128-byte KEY=VALUE slots; the rt0 stub hands rt0_go a SysV
// char* array (argv…/NULL/envp…/NULL), so argc/argv are the plain SysV
// shapes runtime.args stored. gogetenv("GOMAXPROCS") then drives
// schedinit's override — numCPUStartup stays 2 (ADR 0027 D6).
func goenvs() {
	if argc == 0 || argv == nil {
		argslice = make([]string, 0)
		envs = make([]string, 0)
		return
	}
	argslice = make([]string, argc)
	for i := uintptr(0); i < uintptr(argc); i++ {
		p := *(**byte)(add(unsafe.Pointer(argv), i*goarch.PtrSize))
		if p == nil {
			argslice = argslice[:i]
			break
		}
		argslice[i] = gostring(p)
	}
	n := 0
	for {
		p := *(**byte)(add(unsafe.Pointer(argv), (uintptr(argc)+1+uintptr(n))*goarch.PtrSize))
		if p == nil {
			break
		}
		n++
	}
	envs = make([]string, n)
	for i := 0; i < n; i++ {
		p := *(**byte)(add(unsafe.Pointer(argv), (uintptr(argc)+1+uintptr(i))*goarch.PtrSize))
		envs[i] = gostring(p)
	}
}

// ---- signals: phase 0c fault delivery (issue #1228) ----
// The whole signal surface lives in signal_virelai.go now: initsig
// registers sigtramp via slot 75, virfaulthandler arms sigpanic, crash()
// exits through the syscall. Nothing signal-shaped remains here.

// ---- threads (ADR 0027 D3/D5: slot 73, the clone-shaped seam) ----

// virThreadTrampoline is written in assembly (sys_virelai_arm64.s, ABI0):
// the slot-73 child entry — loads g = mp.g0 from the m in x0 and jumps
// runtime.mstart.
func virThreadTrampoline()

// newosproc starts one kernel task per M: the child enters the trampoline
// (sys_virelai_arm64.s) with mp in x0 — it sets g = mp.g0 and jumps
// runtime.mstart, which runs on mp.g0.stack.hi exactly like every other
// GOOS. The kernel binds the task to the CALLER'S
// process — same TTBR0 root, inherited principal — and returns the tid
// that Go keeps in m.procid. Placement is unpinned (the claim-9498 SMP
// rule), which is exactly the cross-core scheduling the go-goroutines
// gate asserts.
func newosproc(mp *m) {
	tid := virThreadCreate(unsafe.Pointer(abi.FuncPCABI0(virThreadTrampoline)),
		noescape(unsafe.Pointer(mp.g0.stack.hi)), noescape(unsafe.Pointer(mp)))
	if tid < 0 {
		throw("newosproc: sys_thread create failed")
	}
	mp.procid = uint64(tid)
}

// newosproc0 backs libinit.go's rt0_lib path (a raw thread with no m).
// It is unreachable from the virelai rt0 (rt0_go calls mstart directly);
// implemented honestly over slot 73 so the runtime links with upstream
// semantics — the child runs fn directly on a freshly sysAlloc'd stack.
func newosproc0(stacksize uintptr, fn unsafe.Pointer) {
	stack := sysAlloc(stacksize, &memstats.stacks_sys, "OS thread stack")
	if stack == nil {
		throw("newosproc0: out of memory")
	}
	tid := virThreadCreate(fn, unsafe.Pointer(uintptr(stack)+stacksize), nil)
	if tid < 0 {
		throw("newosproc0: sys_thread create failed")
	}
}

const preemptMSupported = false

func preemptM(mp *m) {
	// No async preemption (no signals). STW stays cooperative: a
	// call-free tight loop delays it — the same caveat as wasip1
	// (ADR 0027 D5 / M65c).
}

// sbrk backs the mem_sbrk.go platform layer: grow the break to bl+n by
// mapping CONTIGUOUSLY at the current mapped end (sys_mmap honors
// page-aligned address hints), demand-backed — untouched pages cost
// nothing physical.
//
// Under memlock, every returned byte is zero: [bloc, blocMax) was cleared
// by sysFreeOS before lowering bloc; bytes beyond blocMax are demand-zero
// anonymous pages. initBloc rounds past the ELF end, and initBlocFloor
// rounds past the entire argv/envp block, excluding its partially filled
// tail page (the loader does NOT zero that page's slack). A successful
// virMmap cannot overlap an image/argv aperture (process.mmap_collides).
// Neither live allocations nor free-list headers are above bloc. Thus
// apply.sh can link ONLY this path's alignment padding without clearing
// it again. Ordinary frees, free-list trims and shrinking keep their clear;
// memAllocNoGrow clears each removed header before returning reused bytes.
func sbrk(n uintptr) unsafe.Pointer {
	bl := bloc
	n = memRound(n)
	if bl+n > blocMax {
		if virMmap(unsafe.Pointer(blocMax), bl+n-blocMax) < 0 {
			return nil
		}
		blocMax = bl + n
	}
	bloc += n
	return unsafe.Pointer(bl)
}

// virMmap maps [addr, addr+n) anonymously (sys_mmap slot 63: x0=addr
// hint — page-aligned → honored, x1=len, x2=prot RW, x3=MAP_ANONYMOUS,
// no POPULATE: demand faults zero-fill and the kernel records touched
// pages). Returns the kernel's negative errno on failure, >= 0 on
// success (the mapped base).
//
//go:noescape
func virMmap(addr unsafe.Pointer, n uintptr) int

// virMunmap unmaps [addr, addr+n) (sys_munmap slot 64): the kernel unmaps
// the leaves, unrefs the recorded dynamic pages, and returns the phys to
// the pool. A partial unmap keeps the mmap region record, so a later
// touch demand-faults a fresh zero page back in — the scavenged span's
// reuse path is unchanged while its pages stop being held.
//
//go:noescape
func virMunmap(addr unsafe.Pointer, n uintptr) int
