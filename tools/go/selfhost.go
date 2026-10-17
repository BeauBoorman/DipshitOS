// M70c-S2 (issue #1544): the in-guest build loop, in one guest process.
//
// This is the driver the card asks for: compile the pinned fixture with the
// guest's OWN cmd/compile, link it with the guest's OWN cmd/link, and run the
// result — sequenced by spawn-and-wait (ADR 0007 slot 28 plus the wait slot),
// NOT by a new kernel slot. The spike that chose this shape, and the reasons
// option (b) was rejected, are ADR 0035 amendment 6; nothing here invents a
// seam.
//
// "GOTOOLCHAIN=local" is literal for a guest that has no `go` command at all:
// nothing in this loop fetches anything. The two toolchain images, the pinned
// source and the import config that names the package archives are staged in
// the share by the host (tools/go/build-gotool.sh, tools/go/stage-selfhost.sh),
// and every byte the loop reads comes from /host.
//
// Why a driver and not three boots: the monitor's `exec` returns immediately
// (tools/gate/SPEC.md), so compile -> link in order is either two boots
// (go-hello runs 06-07 take exactly that route, one `exec` each) or one
// program that can wait. This is the second shape, and it is the shape a real
// build loop needs — cmd/go cannot be the driver on this GOOS until os/exec
// has a spawn-and-inherit story, which is why the loop lives here.
//
// The loop is TWO children, and that is now a CONSERVATIVE shape rather than a
// forced one. A third sequential child died once (a level-3 data abort in the
// child: `fault: HELLO2.ELF far=0x47c29000 ec=0x24 esr=0x9200004f`, status
// 139) -- the wall go-sh.spec documents against Go children ("A THIRD
// sequential exec from one EL0 parent currently dies in the Go runtime's own
// schedinit ... follow-up owed to the runtime/kernel owners", issue #1449),
// with a different symptom. The argv-gated `--spawn` measurement below then
// FAILED TO REPRODUCE it: three children of either kind survived 3/3, and the
// exact failing configuration (the loop's two children, then the product as the
// third) came back status=0 (four boots; ADR 0035 amendment 8 has the matrix,
// issue #1449 the report). So the RUN step stays the gate's second boot (one
// monitor `exec` of the product this loop built, which is also how go-hello run
// 08 executes it) because this shape is proven green -- NOT because a third
// child is known to be broken.
//
// M119d (#2488) grew the experiment into the spawn-shape matrix and answered
// the debt: depth x breadth x sequential-vs-concurrent legs are pinned in
// live-exec runs 02-04, and the third-child death does not reproduce at the
// post-#2437 head — the residual bound is breadth against the 16-slot task
// pool (ENOSPC at spawn past ~9 one-task children, or a status-2
// `newosproc` death for a third concurrent GOMAXPROCS=2 runtime), recorded
// in ADR 0035 amendment 11.
//
// One consequence of the above for anyone reading the driver's own output: a
// `status=0` on a step is a liveness observation, not proof.
// vi.WaitBudget counts a pid that was seen running and then left the registry as
// status 0 (reaped and recycled, vi/proc.go), which is also what a child that
// crashed and was reaped before a poll looks like. The driver therefore reports
// what it observed -- the child left the registry and the status it left -- and
// the proof that the step really worked is the gate's product checks: HELLO.o
// is a virelai object, HELLO2.ELF satisfies every loader rule, its pinned lines
// run.
//
// Every argv line below is checked against the kernel's 8 x 256-byte argv block
// (kernel/src/exec.zig max_exec_args / arg_slot_bytes) by
// tools/go/stage-selfhost.sh, so an over-long flag fails on the host instead of
// failing here as a truncated path.
package main

import (
	"virelai/vi"
	"virelai/vsys"
)

// The loop's inputs. Paths are share paths because that is where the host
// stages them; the object and the product are written back into the share, so
// the gate can check them from macOS afterwards.
const (
	compileImage = "GOCMDCOMPILE.ELF"
	linkImage    = "GOCMDLINK.ELF"
	source       = "/host/HELLO.GO"
	object       = "/host/HELLO.o"
	imports      = "/host/GOIMPORT.CFG"
	product      = "/host/HELLO2.ELF"
	workdir      = "/host"
)

// stepBudgetNs bounds one child's wait. It is a CEILING, not a prediction: each
// step's real elapsed time is printed, so the number that matters is in the log
// either way. Measured on the reference host: compile 2,000 ms, link 14,016 ms
// (the link reads 14.82 MiB of archives out of the share at the 2048-byte EL0
// read cap). This is 40x the measured link and stays strictly inside the gate's
// own budget for the boot (`live-selfhost-go.spec` runs it with --timeout 900),
// so the driver's ceiling is the one that fires and it fires with a diagnostic
// rather than in a race with the harness's kill -- the 900 s this used to be
// was exactly the run timeout, i.e. two deadlines expiring together.
const stepBudgetNs = int64(600) * int64(1e9)

type step struct {
	label string
	image string
	args  []string
}

// The #1449 / M119d (#2488) EXPERIMENT, off unless asked for:
//
//	exec GOSELFHOST.ELF [--after-loop] (--spawn|--spawn-par) <image> <count> [expected-status] [-- child-args...]
//
// --spawn runs the image count times SEQUENTIALLY (spawn -> wait -> next)
// from this one EL0 parent; --spawn-par is the BREADTH leg of the spawn-shape
// matrix — it spawns all count children back-to-back first, then waits each
// in spawn order, so the pool sees them all live at once. Tokens after `--`
// become every spawned child's own argv, which is what makes the tree-depth
// leg possible: a GOSELFHOST child carrying its own --spawn is a grandchild
// driver. With --after-loop the build loop's two children run first, i.e. the
// experiment's children are number 3+ of the same parent.
//
// It exists because both observed third-child deaths used a GO child (go-sh's
// children are GOSH.ELF; this loop's third was the linked product), so "a third
// sequential exec from one EL0 parent" and "a third live Go runtime" predict
// the same tombstone and the record could not tell them apart. A non-Go child
// that returns its own status discriminates: the seeded Zig STATUS43.BIN exits
// 43.
//
// Measured 2026-09-20, and it REFUTED the simple reading of the wall: three
// small children of EITHER kind survive (Zig STATUS43.BIN 3/3 status=43; Go
// GOHELLO.ELF 3/3 status=0), so "the third child dies" is not the rule. --after-loop
// is what isolates the real difference: the loop's first two children are
// cmd/compile (24 MiB image, 23 MiB mapped) and cmd/link.
//
// M119d (#2488) pins the matrix into live-exec: the verdict line now names
// the image (`selfhost: spawn-par verdict=K-of-M-survived IMAGE`) so a spec
// can stage-gate the NEXT leg on a marker that is unique within the boot, and
// a spawn refusal reports SPAWN-FAIL with the errno instead of silently
// counting as absent. A leg that cannot finish still prints its verdict line —
// K < M is the bound, not a hang.
const (
	spawnFlag     = "--spawn"
	spawnParFlag  = "--spawn-par"
	afterLoopFlag = "--after-loop"
	childSep      = "--"
)

// experiment is one parsed spawn leg: which image, how many children,
// sequential or concurrent, and the status each child is expected to leave
// (-1 = report whatever came back).
type experiment struct {
	par    bool
	image  string
	count  int64
	expect int64
}

func main() {
	rest := vi.Args()
	if len(rest) > 0 {
		rest = rest[1:] // argv[0] is this program's name
	}
	exp, childArgs, afterLoop, errMsg := parseExperimentArgs(rest)
	if errMsg != "" {
		vsys.Println("selfhost: " + errMsg)
		vsys.Exit(2)
	}
	// The normal path (no experiment) is the loop alone; an experiment alone
	// is the standalone baseline; experiment + --after-loop puts the spawns
	// behind the loop's two children, which is the configuration that failed.
	if exp == nil || afterLoop {
		if rc := buildLoop(); rc != 0 {
			if afterLoop {
				// The leg's verdict marker prints even when the loop died —
				// a spec stage gate keys on it, and a loop failure is itself
				// a bound observation (a status-2 toolchain child under pool
				// pressure), never a hang. 0-of-M is honest: no experiment
				// child survived because none ran.
				verb := "spawn"
				if exp.par {
					verb = "spawn-par"
				}
				vsys.Println("selfhost: " + verb + " verdict=0-of-" +
					vsys.Itoa64(exp.count) + "-survived " + exp.image)
			}
			vsys.Exit(rc)
		}
	}
	if exp != nil {
		runExperiment(*exp, childArgs)
	}
}

// parseExperimentArgs pulls the argv-gated experiment out of the program's own
// arguments: one --spawn/--spawn-par flag followed by its positional tail
// (image, count, optional expected-status — everything up to the next flag),
// --after-loop anywhere, and `--` closing the driver's own argv so the rest is
// the spawned children's argv.
func parseExperimentArgs(args []string) (exp *experiment, childArgs []string, afterLoop bool, errMsg string) {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case childSep:
			return exp, args[i+1:], afterLoop, ""
		case afterLoopFlag:
			afterLoop = true
		case spawnFlag, spawnParFlag:
			if exp != nil {
				return nil, nil, false, "one spawn experiment per invocation"
			}
			e := experiment{par: args[i] == spawnParFlag, expect: -1}
			var pos []string
			for i+1 < len(args) && !isFlag(args[i+1]) {
				i++
				pos = append(pos, args[i])
			}
			if len(pos) < 2 {
				return nil, nil, false, "spawn needs <image> <count> [expected-status]"
			}
			e.image = pos[0]
			count, ok := parseInt(pos[1])
			if !ok || count < 1 {
				return nil, nil, false, "spawn count must be a positive integer: " + pos[1]
			}
			e.count = count
			if len(pos) > 2 {
				if e.expect, ok = parseInt(pos[2]); !ok {
					return nil, nil, false, "spawn expected-status must be an integer: " + pos[2]
				}
			}
			if len(pos) > 3 {
				return nil, nil, false, "child argv goes after `--`, not in the spawn tail"
			}
			exp = &e
		default:
			return nil, nil, false, "unknown argument: " + args[i]
		}
	}
	return exp, nil, afterLoop, ""
}

// isFlag reports whether tok starts a new option rather than belonging to the
// current flag's positional tail. The `--` separator is a flag for this
// purpose — the parser sees it and hands the rest to the children.
func isFlag(tok string) bool {
	return len(tok) >= 2 && tok[0] == '-' && tok[1] == '-'
}

// buildLoop is the card's deliverable: compile -> link, in this process, with
// the guest's own toolchain, then the marker the gate waits on.
func buildLoop() int64 {
	steps := []step{
		// cmd/compile: source -> object. No -p flag: the default package
		// path is what the linker needs to find main.main, verified on the
		// host twin and in-guest (go-hello run 06).
		{label: "compile", image: compileImage,
			args: []string{"-o", object, "-importcfg", imports, source}},
		// cmd/link: object -> ELF, resolving symbols out of the staged
		// archives. -tmpdir is explicit because the port has no /tmp.
		{label: "link", image: linkImage,
			args: []string{"-importcfg", imports, "-tmpdir", workdir, "-o", product, object}},
		// NO third step. The product is built here and RUN by the gate's
		// second boot — the shape is proven green, and the matrix found no
		// surviving third-child bound to route around (ADR 0035 amendment
		// 11). Kept for shape stability, not because a third child fails.
	}

	for _, s := range steps {
		status, ms, err := runStep(s)
		if err != nil {
			// The ceiling travels with the failure: "it never finished" and "it
			// finished badly" are different findings about the guest.
			vsys.Println("selfhost: FAIL " + s.label + " err=" + err.Error() +
				" budget_s=" + vsys.Itoa64(stepBudgetNs/1000000000))
			return 1
		}
		vsys.Println("selfhost: " + s.label + " " + s.image +
			" status=" + vsys.Itoa64(status) + " ms=" + vsys.Itoa64(ms))
		if status != 0 {
			vsys.Println("selfhost: FAIL " + s.label + " status=" + vsys.Itoa64(status))
			return 1
		}
	}
	// The marker the gate waits on: both steps of the build ran, in the
	// guest, with the guest's own toolchain.
	vsys.Println("selfhost: build loop OK")
	return 0
}

// runExperiment is the #1449 discriminator grown into the M119d (#2488)
// spawn-shape matrix. It deliberately shares runStep — the same exec slot,
// the same wait rule and the same ceiling as the build loop, because the
// question is about THIS parent's children, not about a fresh one.
//
// Sequential mode (--spawn) is the original measurement: spawn, wait, repeat —
// depth. Parallel mode (--spawn-par) spawns all count children BEFORE waiting
// any — breadth: the pool holds every child live at once, which is the shape
// sequential legs never produce and the one the task-pool bound
// (scheduler.max_tasks, 16) bites first.
//
// Both modes end on the same verdict line — `verdict=K-of-M-survived IMAGE`,
// printed even when a leg fails partway, because a spec stage gate keys on it
// and K < M is itself the finding. "Survived" means the child spawned AND left
// the registry with a status that matches the expectation when one was given.
func runExperiment(e experiment, childArgs []string) {
	verb := "spawn"
	if e.par {
		verb = "spawn-par"
	}
	survived := int64(0)
	if e.par {
		survived = runPar(e, childArgs, verb)
	} else {
		survived = runSeq(e, childArgs, verb)
	}
	vsys.Println("selfhost: " + verb + " verdict=" + vsys.Itoa64(survived) +
		"-of-" + vsys.Itoa64(e.count) + "-survived " + e.image)
	if survived < e.count {
		vsys.Exit(1)
	}
}

// runSeq spawns the image count times, waiting for each child before the next
// spawn — the depth leg. It stops at the first failure: a child whose spawn or
// wait fails leaves no status to count, and a sequential leg that kept going
// would hide WHICH child died behind the survivors.
func runSeq(e experiment, childArgs []string, verb string) int64 {
	for i := int64(1); i <= e.count; i++ {
		prefix := "selfhost: " + verb + " " + vsys.Itoa64(i) + "/" +
			vsys.Itoa64(e.count) + " " + e.image
		start := vsys.Nanotime()
		pid, err := vi.Exec(e.image, childArgs...)
		if err != nil {
			// A refused spawn says the bound's name (ENOSPC), same as runPar —
			// it is not the child dying and it is not a lost status.
			vsys.Println(prefix + " SPAWN-FAIL err=" + err.Error())
			return i - 1
		}
		status, err := vi.WaitBudget(pid, stepBudgetNs)
		if err != nil {
			// No status at all: the child never left the registry with one.
			vsys.Println(prefix + " NO-STATUS err=" + err.Error() +
				" budget_s=" + vsys.Itoa64(stepBudgetNs/1000000000))
			return i - 1
		}
		ms := (vsys.Nanotime() - start) / 1000000
		vsys.Println(prefix + " status=" + vsys.Itoa64(status) +
			" ms=" + vsys.Itoa64(ms))
		if e.expect >= 0 && status != e.expect {
			// The child that dies is the one whose status does not match; a
			// tombstone arrives here as the kernel's own 139.
			vsys.Println(prefix + " unexpected status (expected " + vsys.Itoa64(e.expect) + ")")
			return i - 1
		}
	}
	return e.count
}

// runPar is the breadth leg: spawn count children back-to-back — a refusal
// mid-sweep (a pool-full sys_exec) is a SPAWN-FAIL line, not a stop — then
// wait each spawned child in order. The pool sees all children live at once;
// a Go child's schedinit newosproc transients and a refused exec surface
// here as different markers (status!=expect / NO-STATUS vs SPAWN-FAIL err=).
// ms is the WAIT time for that child, not its runtime — children that finished
// before their turn in the wait order report small ms by construction.
func runPar(e experiment, childArgs []string, verb string) int64 {
	pids := make([]int64, e.count)
	spawned := make([]bool, e.count)
	for i := int64(1); i <= e.count; i++ {
		prefix := "selfhost: " + verb + " " + vsys.Itoa64(i) + "/" +
			vsys.Itoa64(e.count) + " " + e.image
		pid, err := vi.Exec(e.image, childArgs...)
		if err != nil {
			// A refused spawn is the bound the matrix is looking for, said
			// by name — it is not the child dying and it is not this driver.
			vsys.Println(prefix + " SPAWN-FAIL err=" + err.Error())
			continue
		}
		pids[i-1] = pid
		spawned[i-1] = true
		vsys.Println(prefix + " spawned pid=" + vsys.Itoa64(pid))
	}
	survived := int64(0)
	for i := int64(1); i <= e.count; i++ {
		if !spawned[i-1] {
			continue
		}
		prefix := "selfhost: " + verb + " " + vsys.Itoa64(i) + "/" +
			vsys.Itoa64(e.count) + " " + e.image
		status, err := vi.WaitBudget(pids[i-1], stepBudgetNs)
		if err != nil {
			vsys.Println(prefix + " NO-STATUS err=" + err.Error() +
				" budget_s=" + vsys.Itoa64(stepBudgetNs/1000000000))
			continue
		}
		vsys.Println(prefix + " status=" + vsys.Itoa64(status))
		if e.expect >= 0 && status != e.expect {
			vsys.Println(prefix + " unexpected status (expected " + vsys.Itoa64(e.expect) + ")")
			continue
		}
		survived++
	}
	return survived
}

// parseInt is the tiny decimal reader the experiment's argv needs; vsys has
// Itoa64 but no Atoi, and this file is not going to grow a strconv.
func parseInt(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	n := int64(0)
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		n = n*10 + int64(s[i]-'0')
	}
	return n, true
}

// runStep spawns one child, waits for it, and reports its exit status and how
// long it took. A spawn failure and a non-zero status are different facts, so
// they are reported differently by the caller.
func runStep(s step) (status int64, ms int64, err error) {
	start := vsys.Nanotime()
	pid, err := vi.Exec(s.image, s.args...)
	if err != nil {
		return -1, 0, err
	}
	// vi.WaitBudget, not vi.Wait: this is Wait's contract with a ceiling that
	// can hold a linker, and it is the ONE copy of that rule (vi/proc.go) -- a
	// fix there reaches this driver instead of silently missing a second copy.
	status, err = vi.WaitBudget(pid, stepBudgetNs)
	if err != nil {
		return -1, 0, err
	}
	return status, (vsys.Nanotime() - start) / 1000000, nil
}
