// GOTABWM.ELF — M57a (issue #1313): a Go window manager registers the kernel
// render-server seat (slot 65) and composites a blank desktop.
//
// The sequence, and the marker line each step proves:
//
//	vi.WmctlRegister (65/1)         -> gotabwm: registered
//	vi.WmctlRegister again (EACCES) -> gotabwm: seat-taken
//	vi.MmapScanout (63, scan tag)   -> gotabwm: scanout
//	paint the blank desktop         -> gotabwm: draw
//	seat held, awaiting ticks       -> gotabwm: holding seat
//	COMPOSITE_TICK (kind 18)        -> gotabwm: tick
//	paint the clock/status chrome   -> gotabwm: clock-source / gotabwm: clock
//	paint the notify strip (M79k)   -> gotabwm: notify paint id=<n> (once)
//	                                then gotabwm: notify dismiss id=<n> (expiry or click)
//	WM_POINTER (kind 19)            -> gotabwm: ptr
//	WM_KEY (kind 21)                -> gotabwm: key
//	vi.WmctlRequestPresent (65/3)   -> gotabwm: present
//	loop bound reached (demo only)  -> gotabwm: close
//	clean exit                      -> gotabwm OK
//
// M79a (#1704): the loop is LIVE by default -- it runs until the process is
// killed, never auto-closes a hosted tab, and never runs the strip
// choreography. The bounded M57-era demo (the maxTicks ceiling, the hostTicks
// auto-close, and the reorder/pin/split/close chain) is DEMO mode, entered
// only when the harness seeds /host/GOTABWM.DEMO. The mode is decided once at
// startup and named in one marker, before the window phase:
//
//	seeded /host/GOTABWM.DEMO       -> gotabwm: mode demo
//	absent (the product default)    -> gotabwm: mode live
//	live tick past the demo ceiling -> gotabwm: live steady tabs=<n>
//
// Each marker is printed ONLY after its syscall/step succeeded, so the marker
// chain IS the syscall chain. The kernel's exit path unregisters the seat and
// prints `wm: unregistered, shim resumed`; the class-B gate
// (tools/gate/specs/go-wm-seat.spec) asserts every line above, plus the `wm`
// monitor report naming the live seat.
//
// This card is the SEAT only: no window management (M57b), no Zig-app hosting
// (M57c), not the boot default (M59). No libc, no POSIX, no cgo — the guest
// talks only through the ADR 0007 `svc #0` seam (virelai/vi).
package main

import (
	"virelai/draw"
	"virelai/settings"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

// The marker lines the class-B gate greps. Exported constants so seat_test.go
// pins the exact shapes (the repo pins gate grep targets this way in
// user/src/wndstub.zig and user/src/tabwm.zig).
const (
	MarkerRegistered = "gotabwm: registered"
	MarkerSeatTaken  = "gotabwm: seat-taken"
	MarkerScanout    = "gotabwm: scanout"
	MarkerDraw       = "gotabwm: draw"
	MarkerHolding    = "gotabwm: holding seat"
	MarkerTick       = "gotabwm: tick"
	MarkerPtr        = "gotabwm: ptr"
	MarkerKey        = "gotabwm: key"
	MarkerPresent    = "gotabwm: present"
	MarkerClose      = "gotabwm: close"
	MarkerOK         = "gotabwm OK"
	// M79a (#1704): the seat mode split. ModeDemo/ModeLive print once at
	// startup; LiveSteady prints once, and only after the live loop has
	// actually ticked PAST the demo ceiling (maxTicks) -- carrying the tab
	// count so the persistence proof and the "tab still open" fact are one
	// honest line.
	MarkerModeDemo = "gotabwm: mode demo"
	MarkerModeLive = "gotabwm: mode live"
	// The mailbox is live from the loop's first serviceRPC — the arming
	// marker for a guest exec that must not declare into an unserved seat
	// (the startup probe's bounded waits can outlast the client's 8-tick
	// ack budget; observed t3 'not-tab-aware' with the serve landing after
	// the client had already timed out).
	MarkerServing    = "gotabwm: serving"
	MarkerLiveSteady = "gotabwm: live steady "
	// M69a (issue #1528): the dogfood beat's own two markers, owned by
	// go-dogfood.spec. MarkerDogfoodSeat is the DEFAULT seat announcing it owns
	// the desktop (printed once the registration AND the one-seat probe both
	// returned). MarkerDogfoodOK closes the boot's hosted phase: it is printed
	// at host-done only when this boot actually hosted a tab (dogfoodHosted),
	// so a bare seat boot can never claim the beat.
	MarkerDogfoodSeat        = "dogfood: seat"
	MarkerDogfoodOK          = "dogfood: ok"
	MarkerFirstBootWorkspace = "gotabwm: first-boot workspace"
	// M122b (#2571): the seat's successful exec of the first-boot tour —
	// live mode only (the demo choreography's strip is asserted clean of
	// it); the app's own gowelcome: markers prove the surface painted.
	MarkerWelcomeTour = "gotabwm: welcome tour"
	welcomeBin        = "GOWELCOME.ELF"
	// M83g (#1780): emitted after a real composite tick. The VZ restore
	// runner waits for a fresh copy after resuming the saved VM.
	MarkerRestoreWitness = "gotabwm: restore witness "
	// M83f (#1779): transitions only, after a frame carrying the state was
	// presented. The curtain is visual, not authentication.
	MarkerIdleDim  = "gotabwm: idle dim"
	MarkerIdleLock = "gotabwm: idle lock"
	MarkerIdleWake = "gotabwm: idle wake"
)

const idleThresholdPath = "/host/GOTABWM.IDLE.TEST"

type idleStage uint8

const (
	idleActive idleStage = iota
	idleDim
	idleCurtain
)

// The composite heartbeat is ~1 Hz. The last input tick is owned by this
// seat, not the kernel or an app. Zero idleAfter disables the policy before
// main configures it (host tests call compositeTick without booting a seat).
var (
	idleAfter       uint64
	lastInputTick   uint64
	idleState       idleStage
	idlePresented   idleStage
	idleWakePending bool
)

// The host gate writes this one-shot fixture before exec. On a normal share
// there is no file, so one minute is 60 heartbeat ticks. It is deliberately
// a test-only threshold override, never a persisted settings value.
func idleTicksPerMinute() uint64 {
	b, r := vi.ReadFileAll(idleThresholdPath, 8)
	if r >= 0 && string(b) == "2" {
		return 2
	}
	return 60
}

func configureIdle(f settings.File, ticksPerMinute uint64) {
	value, _ := f.Effective("idle_minutes")
	minutes, ok := settings.IdleMinutes(value)
	if !ok || f.State == settings.StateCorrupt {
		minutes, _ = settings.IdleMinutes(settings.IdleKeys[0].Default)
	}
	idleAfter = minutes * ticksPerMinute
	lastInputTick, idleState, idlePresented, idleWakePending = 0, idleActive, idleActive, false
	vi.ConsoleLine("gotabwm: idle thresholds dim=" + vi.Itoa64(int64(idleAfter)) +
		" lock=" + vi.Itoa64(int64(2*idleAfter)))
}

func idleAdvance(ticks uint64) {
	if idleAfter == 0 || ticks < lastInputTick {
		return
	}
	// A wake still owed its presented frame cannot be regressed by
	// heartbeats counted while the paint was deferred (#2730): the drain
	// may consume newer ticks after the input that anchors to seatTick,
	// so elapsed would cross a threshold against the still-covered frame
	// and the wake marker would never print (observed go-wm-seat run 07:
	// ptr -> tick -> tick -> "idle dim"). The ramp resumes from the wake
	// frame itself — idlePresentedFrame re-anchors lastInputTick there.
	if idleWakePending {
		return
	}
	elapsed := ticks - lastInputTick
	switch {
	case elapsed >= 2*idleAfter:
		idleState = idleCurtain
	case elapsed >= idleAfter:
		idleState = idleDim
	default:
		idleState = idleActive
	}
}

// The waking edge is consumed by the seat instead of activating its chrome.
// This is NOT an input firewall: ADR 0009 still fans app events out, and the
// curtain neither authenticates a user nor protects a running app.
func idleInput(ticks uint64) bool {
	lastInputTick = ticks
	if idleState == idleActive && !idleWakePending {
		return false
	}
	idleState = idleActive
	idleWakePending = true
	return true
}

// Never announce a visual state before the scanout containing it was
// flushed. The wake's own frame is also the re-arm point: input anchors
// lastInputTick to the heartbeat count its drain position consumed, which
// a deferred batch leaves behind — counting quiet time from the frame the
// user actually sees keeps a deep queue from re-dimming instantly.
func idlePresentedFrame(presented bool, ticks uint64) {
	if !presented {
		return
	}
	if idleState != idlePresented {
		switch idleState {
		case idleDim:
			vi.ConsoleLine(MarkerIdleDim)
		case idleCurtain:
			vi.ConsoleLine(MarkerIdleLock)
		case idleActive:
			if idleWakePending {
				vi.ConsoleLine(MarkerIdleWake)
				lastInputTick = ticks
			}
		}
		idlePresented = idleState
	}
	if idleState == idleActive {
		idleWakePending = false
	}
}

// blankRGB is the blank desktop's colour, packed 0x00RRGGBB as the fill seam
// takes it (the scanout stores it B,G,R,X).
func blankRGB() uint32 { return theme.Current.Bg }

// demoTriggerPath is the harness's explicit opt-in to the bounded M57-era
// demo choreography (M79a). Its PRESENCE at seat startup selects demo mode;
// absence is the product default (live). The class-B specs stage it (a
// monitor `write GOTABWM.DEMO demo`, or a setup-python seed for autostart
// boots) and the one live run removes it (`vf rm GOTABWM.DEMO`). Nothing
// else may seed it -- a daily session must never run the choreography.
const demoTriggerPath = "/host/GOTABWM.DEMO"

// openFile is the FileOpen seam for the demo probe (the execApp pattern in
// hid.go): host tests inject a stub so the detection is testable off the
// guest, where every vi call degrades to -ENOSYS.
var openFile = vi.FileOpen

// demoMode is this process's seat mode, decided once in main via detectDemo.
// False (live) is the product default and the zero value.
var demoMode bool
var restoreWitnessMode bool
var restoreSettingsWM = "gotabwm"

const restoreWitnessPath = "/host/VZRESTORE.WITNESS"

func detectRestoreWitness() bool {
	data, n := vi.ReadFileAll(restoreWitnessPath, 64)
	return n == int64(len("wake-fuse-ok\n")) && string(data) == "wake-fuse-ok\n"
}

func restoreWitnessLine() string {
	// M120b (#2559): the session half is the FILE's echo, captured at load
	// before the re-exec fan-out mutates the strip — the fixture proves the
	// recorded titles survived the round trip, not which rows came back.
	return MarkerRestoreWitness + "wm=" + restoreSettingsWM +
		" theme=" + theme.Name() + " file=wake-fuse-ok " + sessionEcho
}

// detectDemo probes the trigger's existence: found -> demo, absent (or any
// open error, including the host's -ENOSYS) -> live. Content is deliberately
// irrelevant -- presence IS the opt-in.
func detectDemo() bool {
	h, r := openFile(demoTriggerPath, vi.ModeRead)
	if r < 0 {
		return false
	}
	vi.FileClose(uint32(h))
	return true
}

// maxTicks bounds the composite loop so a boot can never hang (~1 tick/s).
// Three Go runtimes (this seat + two clients) fit max_tasks=16 (M65d /
// #1442: 3 kernel + 3×4 Ms + 1 spare). GOMAXPROCS=1 still fits (3 kernel
// tasks each: primary + sysmon + helper). A
// `--pointer-virtio` click is 3 messages × 2.5 s; pointerClickHold is that
// budget in ticks. maxTicks must cover hostTicks + hidChordHold + the
// two-tab choreography (9) so M63 HID (click, type-in, drag, chords)
// lands before auto pin/close. Type-in and drag are separate boots.
// M73z (#1638): 48 ended go-dogfood boot 04 mid-chain (serial-04:
// `gotabwm: OK` at tick 48, before the drag's chords, the pasted
// submits, and script2's kresize could finish). 90 = the 16+32+9 = 57
// choreography budget plus the acceptance chain that starts at
// GOTERM's declare (~tick 20); maxEvents 500 stays above it.
// Claim 1747: 90 -> 120. hidChordHold went 32 -> 64 (the per-chord
// Sleep(1) amplification above), so the choreography's first
// destructive step moved to n==2 + 64 + 7 ~ tick 87 and 90 no longer
// cleared it. 120 keeps the same shape: 16+64+9 = 89 of choreography
// budget, the acceptance chain above it, and the bound still finite.
const maxTicks = 120

// demoTeardownHold is how far past the last seat-observable activity the
// demo run budget extends (#2703). The budget was a fixed count sized
// before the M125a seat changes; observed go-dogfood boot 04: tickLimit
// 120 swept both tabs while script2's `dui lower 4` was still in flight —
// the acceptance chain's tail now outlasts the pre-M125a window. Instead
// of re-sizing the number, the budget follows what the seat can see:
// every non-tick event (WM_KEY, WM_POINTER, window mirrors) and every
// mailbox request the seat serves re-arms it to lastActivity +
// demoTeardownHold, so a chain still in flight cannot be swept mid-leg
// and a genuinely idle boot exits on the same schedule as before. The
// cap (initial limit + maxTicks) keeps the boot bounded: a stream that
// never quiets extends to ~2x, never forever. The hold covers the
// observed post-activity tail — the `r` resize's mirror through
// script2's delayed monitor commands — plus margin.
const demoTeardownHold = 24

// lastActivityTick is the composite-tick count the seat last did anything
// externally visible at: an input/window event consumed (consumeSeatEvent)
// or a mailbox request served (serviceRPC in the main loop). seatTick is
// in the same units.
var lastActivityTick uint64

// pointerClickHold is how many composite ticks one `--pointer-virtio` click
// needs at the 1 Hz kind-18 heartbeat (3 messages × 2.5 s, rounded up).
const pointerClickHold = 8

// maxEvents bounds the wait loop regardless of which kinds arrive (ticks,
// WM pointer/key, window mirrors). The bound keeps a spurious event stream
// from spinning forever.
const maxEvents = 500

// drainPaintStride bounds how many events may be consumed while a
// composite is owed before the drain pays the paint mid-burst (#2730):
// a queued heartbeat's repaint is deferred behind the input it would
// otherwise delay, but a stream that never empties still earns a present
// per stride rather than starving the scanout until the bound trips.
const drainPaintStride = 32

// drainServiceStride bounds how many events may pass between mailbox
// services inside one drain: a WM_RPC's bounded-poll ack window
// (wmMailWaitTicks) cannot outlast a deep queue otherwise — observed on
// go-dogfood boot 08: `gofiles: drag refused seat` while the seat chewed
// a 6-deep tick backlog with the DragBegin un-served in its mailbox.
const drainServiceStride = 8

func main() {
	// 1. Register the seat (slot 65 cmd 1). ENXIO here means the compositor
	//    is not armed; EACCES means a seat is already taken.
	r := vi.WmctlRegister()
	if r != 0 {
		vi.ConsoleLine("gotabwm: register failed " + vi.Itoa64(r))
		vi.Exit(2)
	}
	vi.ConsoleLine(MarkerRegistered)

	// 1b. M82c (#1770): the global shortcuts registry — validate the table
	//     fail-closed, refuse the harness's conflicting fixture when seeded
	//     (/host/GOTABWM.CHORDCONFLICT), and print the summary line.
	chordRegistryPrologue()

	// 2. One-seat discipline: the kernel refuses a second registration with
	//    EACCES (-7). Fail the gate honestly if that is not what came back.
	if r2 := vi.WmctlRegister(); r2 != -vi.ErrEACCES {
		vi.ConsoleLine("gotabwm: seat-taken FAILED " + vi.Itoa64(r2))
		vi.Exit(3)
	}
	vi.ConsoleLine(MarkerSeatTaken)

	// M69a (#1528): the default seat is live and exclusive. The dogfood beat
	// gates its first exec on this line, so it must come after both the
	// registration and the one-seat probe succeeded.
	vi.ConsoleLine(MarkerDogfoodSeat)

	// 3. Map the scanout (seam B compose-N target) — full-frame, seat-only.
	scan, err := vi.MmapScanout()
	if err != nil {
		vi.ConsoleLine("gotabwm: scanout failed " + err.Error())
		vi.Exit(4)
	}
	vi.ConsoleLine(MarkerScanout)

	// 4. Composite the blank desktop.
	_ = paintBlank(scan, blankRGB())
	vi.ConsoleLine(MarkerDraw)
	vi.ConsoleLine(MarkerHolding)

	// M81g (#1767): the restore drill, BEFORE the settings decode below and
	// therefore before loadSession as well. A bundle rehydrates the three
	// files on the share, and the seat's ordinary boot then reads them
	// through the ordinary paths — so a restored settings table is decoded
	// by the M66b decode and a restored strip by the M62e one, and neither
	// needed to learn about bundles. It is a no-op unless the share carries
	// the one-shot SNAPSHOT.RESTORE request, and a corrupt or absent bundle
	// is refused WHOLE: nothing is written, the refusal is one line, and the
	// missing/corrupt handling below is the whole story from there.
	restoreSnapshot()

	// M83g (#1780): the restore gate starts the default Go seat without a
	// host script to drive runWindowPhase's interactive blur. The marker file
	// opts only that gate boot into the live composite loop, keeping the
	// session/settings witness independent of the window choreography.
	restoreWitnessMode = detectRestoreWitness()
	if restoreWitnessMode {
		vi.ConsoleLine("gotabwm: restore witness mode")
	}

	// M66b (#1444): decode /host/SETTINGS.TXT (schema v2) BEFORE any phase
	// that waits on the harness (the window choreography would otherwise
	// sit between boot and the decode). Missing is silent; corrupt fails
	// closed — one marker line, then the seat runs on its own defaults. A
	// marker only after its syscall returned.
	seatWM := loadSettings()
	restoreSettingsWM = seatWM
	emitTokens()

	// M79a (#1704): decide the seat mode once, and name it before the window
	// phase so every script anchor downstream sees it. Live is the product
	// default; demo is the harness's explicit opt-in (the seeded trigger).
	demoMode = detectDemo()
	seatSettings := settings.Load()
	configureIdle(seatSettings, idleTicksPerMinute())
	// M82d2 (#1785): the do-not-disturb key and the persisted center history
	// are both settled here, before the window phase and long before the
	// first composite paint, so the first frame already shows the restored
	// count and the first notice already obeys DND.
	configureNotifyDND(seatSettings)
	loadNotifyHistory(seatSettings)
	// M108b (#2325, ADR 0051): the host-integration lane engine. The probe
	// reads the host-int credential once; absent is byte-silent (D7). The
	// lane runs in BOTH seat modes — it is not demo choreography.
	hostintSeatInit()
	// M123a (#2575): lane refusals ride the seat-owned log sink into
	// toasts — armed only when the lane engine exists.
	armRefusalLaneWatch()
	// M109e (#2401, ADR 0052): the agent-activity watch on the M109c
	// receipt lane. Same credential posture — the agent-hmac row served
	// to this image is the whole flag; unserved is byte-silent.
	agentSeatInit()
	if demoMode {
		vi.ConsoleLine(MarkerModeDemo)
	} else {
		vi.ConsoleLine(MarkerModeLive)
	}

	// 5. The seat's OWN window lifecycle (M57b, issue #1317): open a Go
	//    window, submit a chrome descriptor and a kernel-clamped rect, take
	//    focus and lose it, close through the WM seam, and leave a window
	//    open at exit so the kernel's client-death seam must reap it. The
	//    M83g restore-witness fixture skips this interactive blur phase.
	if !restoreWitnessMode && !runWindowPhase() {
		vi.Exit(7)
	}
	// Explicit operator opt-in only. A normal/default boot never listens.
	// The RFB worker owns TCP; the seat alone owns paint and input policy.
	remote := startRFB(vi.Args(), scan)

	// M62e: restore `.tabs` v2 from /host/SESSION.TABS if a prior boot
	// wrote it. Missing is a no-op; corrupt fails closed (empty strip).
	sessionState := loadSession()
	firstBootStarted := false
	if firstBootWorkspace(sessionState, seatWM) && !anotherGuestProgram() {
		if _, err := vi.Exec("GOSH.ELF"); err == nil {
			firstBootStarted = true
			vi.ConsoleLine(MarkerFirstBootWorkspace)
		} else {
			vi.ConsoleLine("gotabwm: first-boot workspace failed " + err.Error())
		}
		// M122b (#2571): the welcome tour opens beside the starter shell on
		// a LIVE first boot only — the demo choreography owns the strip and
		// its auto-close would eat the tour as a second tab, and a restored
		// session replays the strip the user left without ever landing here.
		if !demoMode {
			if _, err := execApp(welcomeBin); err == nil {
				vi.ConsoleLine(MarkerWelcomeTour)
			} else {
				vi.ConsoleLine("gotabwm: welcome tour failed " + err.Error())
			}
		}
	}

	// M125f (#2591): a parked crash slot (CRASHSNAP.LAST written by the
	// previous boot's crash save) becomes the recovery toast — Restore
	// stages it as the next --resume image, Dismiss consumes the offer.
	crashSnapOffer()

	// 6. Composite/present loop paced by the kind-18 tick - and the WM_RPC
	//    serve loop (M57c / M62b): the seat hosts tabapp clients that declare
	//    over the mailbox, keeps them on the in-process strip, and paints a
	//    rail on the compose-N scanout. PollEvent (not WaitEvent) so a pending
	//    request is serviced between ticks.
	// Give the default GOSH starter its own normal hostTicks window before the
	// seat's existing bounded demo loop expires. Other boot paths keep maxTicks.
	// M79a (#1704): tickLimit and the whole run budget are DEMO mode only.
	// In live mode the loop has no ceiling -- it ends only when the process is
	// killed, and the kernel's exit seam still tears the seat down (M52).
	tickLimit := maxTicks
	if firstBootStarted {
		tickLimit += hostTicks
	}
	// #2703: the activity extension's hard bound — a stream that never
	// quiets pushes the exit out by at most one more maxTicks.
	tickLimitCap := tickLimit + maxTicks
	presents, ticks := 0, 0
	// #2730: a consumed heartbeat's PAINT is deferred past whatever input
	// queued behind it — drainSeatEvents accounts each tick through onTick
	// and calls flushComposite when the queue empties, when an owed paint
	// has already waited drainPaintStride events, or on the stop edge.
	// pendingComposite is the owed flag; one composite pass serves however
	// many heartbeats accumulated, so interleaved repaints can no longer
	// lag the queue seconds behind a scripted burst.
	pendingComposite, pendingHeartbeat = false, false
	liveSteadyMarked := false
	flushComposite := func() {
		if !pendingComposite {
			return
		}
		// card #3034 (ADR 0007 X4): a damage-tick debt pays the
		// compose+present only; a heartbeat's debt pays the full pass.
		// A mixed debt (damage queued beside a heartbeat) is a heartbeat.
		heartbeat := pendingHeartbeat
		pendingComposite = false
		pendingHeartbeat = false
		if remote != nil {
			remote.frameMu.Lock()
		}
		before := presents
		if heartbeat {
			compositeTick(scan, uint64(ticks), &presents)
		} else {
			damageCompositeTick(scan, uint64(ticks), &presents)
		}
		if remote != nil {
			if presents > before {
				remote.presented++
			}
			remote.frameMu.Unlock()
		}
		if !demoMode && ticks > maxTicks && !liveSteadyMarked {
			// The live-persistence proof: printed only once the loop has
			// ACTUALLY ticked past the demo ceiling, carrying how many
			// tabs are still open (live mode auto-closes nothing). A
			// merged batch can step over maxTicks+1, so the latch —
			// not an equality probe — is the once-only.
			liveSteadyMarked = true
			vi.ConsoleLine(MarkerLiveSteady + "tabs=" + vi.Itoa64(int64(tabs.Count())))
		}
	}
	// The mailbox gets the same mid-drain cadence as the paint: a deep
	// queue must not park a WM_RPC past its bounded-poll ack window.
	serviceMailbox := func() {
		if served := serviceRPC(); demoMode && served > 0 {
			lastActivityTick = uint64(ticks)
		}
	}
	vi.ConsoleLine(MarkerServing)
	for events := 0; !demoMode || (events < maxEvents && ticks < tickLimit); {
		serviceMailbox()
		noteBadgeTransition()
		if remote != nil {
			if remote.drainInput() {
				remote = nil
			}
		}
		if launch.open && launch.sink != 0 && !ensureLauncherFocus() {
			dismissLauncher()
		}
		// M115d (#2463): the power menu's sink is reaped on the same
		// dead-window discipline as the launcher's.
		if powerMenuOpen && powerSink != 0 && !ensurePowerFocus() {
			dismissPowerMenu()
		}
		e, ok := vi.PollEvent()
		if !ok {
			// #2260: block on the event queue instead of parking a whole
			// scheduler tick (~1 s at the 1 Hz tick) per empty poll. The
			// kernel wakes event waiters on every push, so input drains at
			// arrival rate instead of ~1 Hz — a key/pointer burst can no
			// longer pile past the 64-deep queue and drop-oldest while the
			// seat slept. COMPOSITE_TICK still lands each second, so the
			// serviceRPC/mailbox pass keeps at least its old cadence.
			w, r := vi.WaitEvent()
			if r <= 0 {
				if r < 0 {
					vi.Sleep(1) // never spin on a refused wait
				}
				continue
			}
			e = w
		}
		// Drain the complete event queue before yielding to another empty
		// poll. A virtio chord can enqueue several WM_KEY/POINTER events while
		// the seat is between ticks; processing only one leaves focus-dependent
		// input behind the heartbeat and makes the next chord race the prior
		// focus transition. #2730: a queued heartbeat no longer costs an
		// immediate composite — onTick accounts it (and still stops the drain
		// at the demo bound) while flushComposite pays the owed paint once,
		// after the input that queued behind it.
		bound := maxEvents - events
		if !demoMode {
			// Live mode has no run budget; the per-burst drain bound stays so
			// a flood still cannot starve the composite loop.
			bound = maxEvents
		}
		events += drainSeatEvents(e, vi.PollEvent, consumeSeatEvent, bound, serviceMailbox, func() bool {
			if demoMode {
				// #2703: re-arm the budget on observed activity BEFORE
				// the expiry check, so the extension the last event
				// earned is never beaten by the tick that grants it.
				tickLimit = demoTickLimit(tickLimit, tickLimitCap)
				if ticks >= tickLimit {
					return false
				}
			}
			ticks++
			// seatTick follows the last CONSUMED heartbeat, not the last
			// painted one: notifyPush anchors a toast's born/expiry to it
			// at RPC time, and a mid-drain service can now run while a
			// paint is still owed — anchoring to the stale painted tick
			// let a deep batch expire a fresh toast on its first
			// notifyTick (observed boot 05: dismiss without paint).
			seatTick = uint64(ticks)
			// One marker per consumed heartbeat, at its arrival position:
			// the gate's serial-count pins heartbeats, not composites —
			// a deferred batch still names each of them. The marker now
			// precedes the paint it earned rather than riding inside it.
			vi.ConsoleLine(MarkerTick)
			pendingComposite = true
			pendingHeartbeat = true
			return !demoMode || ticks < tickLimit
		}, flushComposite)
	}
	// M73z (#1638): the budget can expire with a tab still open — a late
	// declare's single-tab countdown (hostTicks) needs 16 MORE ticks and
	// cannot beat maxTicks (observed go-wm-default boot 01: GOCALC
	// declared near tick 88, the seat exited at 90, and the app never
	// saw WIN_CLOSE — no `gocalc: close`; an earlier-declaring run
	// closed cleanly, pure timing variance). Sweep whatever remains so
	// every hosted app still observes its close on the way out; a strip
	// the choreography or countdown already emptied is a no-op.
	dismissLauncher()
	sweepHosted(closeHosted)
	// M102e (#2169): WM shutdown closes every GPU3D context — the kernel's
	// unregister-time revoke_all is the final authority; these are the
	// seat's own CLOSEs for records still marked live.
	gpu3dCloseAll()
	// M82d2 (#1785): the tail of the center's history (whatever landed since
	// the last tick) is published before the seat says it is done.
	flushNotifyHistory()
	vi.ConsoleLine(MarkerHostDone)

	// M69a (#1528): the beat's closing marker for THIS boot. Gated on the
	// latch, not on tabs.Count(): the close choreography empties the strip
	// before host-done. A boot that hosted nothing prints nothing.
	if dogfoodHosted {
		vi.ConsoleLine(MarkerDogfoodOK)
	}

	// 6. Clean exit. The kernel's exit path unregisters the seat.
	vi.ConsoleLine(MarkerClose)
	if presents == 0 {
		vi.ConsoleLine("gotabwm: no present")
		vi.Exit(5)
	}
	if ticks == 0 {
		vi.ConsoleLine("gotabwm: no tick")
		vi.Exit(6)
	}
	vi.ConsoleLine(MarkerOK)
	vi.Exit(0)
}

// sweepHosted closes every remaining live tab before host-done. Restored
// session records use placeholder ids rather than kernel windows, so discard
// those local entries before asking the WM seam to close anything. A failed
// live close is terminal rather than a reason to spin forever: the seat must
// still publish its bounded-loop completion marker when the WM seam rejects a
// stale window.
func sweepHosted(close func() bool) {
	// Remove all restored placeholders before closing a live tab. Otherwise
	// closeHosted would try to taskbar-focus a placeholder while handling the
	// first live close and block on the WM seam.
	for i := 0; i < tabs.Count(); {
		id := tabs.At(i).ID
		if id >= sessionIDBase {
			_ = tabs.CloseTab(id)
			continue
		}
		i++
	}
	for tabs.Count() > 0 {
		if !close() {
			return
		}
	}
}

// demoTickLimit recomputes the demo run budget for the current tick:
// observed activity re-arms the exit to lastActivity + demoTeardownHold
// (#2703), bounded by the cap so a stream that never quiets still cannot
// hang the boot.
func demoTickLimit(tickLimit, cap int) int {
	if ext := int(lastActivityTick) + demoTeardownHold; ext > tickLimit {
		return min(ext, cap)
	}
	return tickLimit
}

// seatTick is the last consumed heartbeat — #2730: a composite pass is
// deferred behind the input that queued with it, so consumers anchoring to
// "now" (activity re-arm, idle) need the consumed count, not the painted
// one. compositeClock counts actual compositeTick passes and is the clock
// toast TTL/notify sweep anchor to: a toast lives NotifyTicks-1 PAINTS, and
// under a coalesced drain heartbeats no longer equal paints (observed boot
// 05: a fresh toast born on a stale painted tick expired on its first
// notifyTick — dismiss without paint).
var seatTick uint64
var compositeClock uint64

// pendingComposite is the drain's owed-paint flag and pendingHeartbeat
// records whether the debt includes a heartbeat's full bookkeeping pass.
// Package scope because the damage edge (card #3034, ADR 0007 X4) is marked
// inside consumeSeatEvent — deep inside drainSeatEvents — while the debt is
// paid by the main loop's flushComposite. A heartbeat sets both through
// onTick; a damage tick sets only pendingComposite, so the flush pays a
// compose+present without the heartbeat accounting.
var pendingComposite bool
var pendingHeartbeat bool

// compositeTick performs one bounded compositor pass after a COMPOSITE_TICK
// heartbeat. Keeping it separate lets the event drain preserve each tick's
// paint, present, and host-lifecycle ordering while still consuming a
// complete input burst in one queue pass. card #3034 (ADR 0007 X4): the
// frame half lives in compositePaint — a flags-bit0 damage tick pays it
// through damageCompositeTick without the heartbeat bookkeeping below.
func compositeTick(scan []byte, ticks uint64, presents *int) {
	compositeClock++
	seatTick = ticks
	// MarkerTick is printed by the drain's onTick accounting (#2730): one
	// marker per consumed heartbeat, whether or not this pass runs.
	idleAdvance(ticks)
	// M120b (#2559): pending session re-execs reap on the tick cadence —
	// a pid that died before its declare, or outlived the declare window,
	// drops its placeholder row rather than leaving a corpse on the rail.
	if reexecN > 0 {
		reapSessionReexec()
	}
	// M79k (#1720): the toast expiry sweep is heartbeat-paced — a toast
	// lives NotifyTicks-1 composite passes of the HEARTBEAT stream, so a
	// damage pass renders toasts but never ages them (card #3034). Expiry
	// runs first so a toast that has run out is never painted for one
	// more frame, and so the dismiss marker lands in the same tick the
	// pixels stop changing.
	notifyTick(compositeClock)
	presented := compositePaint(scan, ticks, presents)
	if restoreWitnessMode && presented && ticks%8 == 0 {
		vi.ConsoleLine(restoreWitnessLine())
	}
	// The parked snapshot ask runs on the composite cadence in both modes —
	// a deferred cs-s must not outlive the run that armed it, and a live
	// seat owes the user the same capture-after-quiet ordering.
	releaseSnapshotAsk(ticks)
	if demoMode {
		// #2703: the parked focus cycle's quiet-window release runs on
		// the composite cadence even when the strip choreography is
		// done — a deferred chord must not outlive the demo that armed
		// it unapplied.
		releaseFocusCycle(ticks)
	}
	if stripDone || !demoMode {
		// M79a (#1704): the auto-reorder/pin/split/close chain and the
		// single-tab hostTicks countdown are DEMO mode only. In live mode
		// the seat never touches the user's tabs -- it paints and hosts.
		return
	}
	n := tabs.Count()
	if n >= 2 || stripSawTwo {
		if !stripSawTwo {
			stripSawTwo = true
			stripStep = 0
			stripHoldLeft = hidChordHold
		}
		if stripHoldLeft > 0 {
			stripHoldLeft--
		} else {
			stripStep++
			switch stripStep {
			case 1:
				_ = applySwapUnpinned()
			case 2:
				if applyPinStay() {
					_ = writeSession()
				}
			case 3:
				_ = applySplit(SplitVert)
			case 4:
				_ = applyUnsplit()
			case 5:
				_ = applySplit(SplitHoriz)
			case 6:
				_ = applyUnsplit()
			case 7:
				closePinnedFirst()
				stripClosedOne = true
				if tabs.Count() == 0 {
					stripDone = true
				}
			default:
				closeHosted()
				stripDone = true
			}
		}
		return
	}
	if n == 1 {
		hostTicksLeft--
		if hostTicksLeft <= 0 {
			closeHosted()
			stripDone = true
		}
	}
}

// compositePaint is the frame half of a compositor pass — compose every
// layer (blank desktop or client surfaces under the seat's chrome, rail,
// launcher, power menu, toasts, drag ghost, idle overlay), present it, and
// run the per-frame publish markers and lane flushes. Both the heartbeat
// pass (compositeTick) and the damage pass (damageCompositeTick, card
// #3034 / ADR 0007 X4) pay it; everything heartbeat-paced lives in
// compositeTick's own wrapper. Returns whether the scanout present
// succeeded.
func compositePaint(scan []byte, ticks uint64, presents *int) (presented bool) {
	if tabs.Count() == 0 {
		_ = paintBlank(scan, blankRGB())
		startSurfaceTick(scan)
	}
	// #2236 defect #13: migrated (surface-backed) client windows are the
	// seat's compositing job — the kernel skipped their blit at tick time.
	// Compose them UNDER the seat's chrome like the kernel layer expects:
	// a full-viewport tab rect covers the rail band, and a record that
	// painted on top of it would hide the strip entirely. Runs on both
	// branches — a non-tab Attach surface is live with an empty strip.
	composeSurfaces(scan)
	railPx := 0
	if tabs.Count() != 0 {
		railPx = paintRail(scan, vi.ScanoutWidth, vi.ScanoutHeight, RailHeight, &tabs, railHover, railCloseHover)
		markRail()
	}
	// M108b (#2325): the lane pass runs before the chrome paint so a
	// host-sourced clipboard write this tick is already badged on the same
	// presented frame.
	hostintSeatTick()
	// M109e (#2401): the agent watch runs in the same lane pass — a
	// session receipt seen this tick is badged on the same frame.
	agentSeatTick()
	chromeTick(scan, ticks)
	if launch.open {
		_ = paintLauncher(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	}
	// M115d (#2463): the power menu floats above the rail and under the
	// toasts, matching its pointer priority (the toast hit test runs
	// first).
	if powerMenuOpen {
		_ = paintPowerMenu(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	}
	// M125f (#2591): a crash receipt's deferred re-exec runs here — off
	// the teardown event and clear of crashSave's whole-VM save.
	crashRestartTick()
	painted := paintNotify(scan, vi.ScanoutWidth, vi.ScanoutHeight, compositeClock)
	centerPainted := paintNotifyCenter(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	// M124a (#2580): the drag ghost paints over every other chrome layer
	// — the gesture owns the frame while the button is held — and under
	// the idle curtain like the rest (the curtain is visual, not input).
	ghostPainted := paintDragGhost(scan)
	switch idleState {
	case idleDim:
		_ = paintIdleDim(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	case idleCurtain:
		_ = paintIdleCurtain(scan, vi.ScanoutWidth, vi.ScanoutHeight)
	}
	if !demoMode {
		syncSeatChrome(scan)
	}
	presented = vi.WmctlRequestPresent() == 0
	if presented {
		*presents++
		if *presents == 1 {
			vi.ConsoleLine(MarkerPresent)
		}
	}
	// markRail's post-present twin: `gotabwm: rail n=` proves the strip
	// painted, this marker proves a frame carrying it actually flushed —
	// the earliest scanout a pixel probe may read the rail on. Run 10's
	// snap-10-0 anchored on `gotabwm: present` alone could stream a pass
	// whose rail was still a frame away (or a frame mid-repaint: the
	// zeroed-surface compose lands before paintRail).
	if line, once := railPaintMarker(railPx > 0, presented); once {
		vi.ConsoleLine(line)
	}
	// The paint marker follows the PRESENT, not the fill: "the toast is on
	// the scanout" is only true once the frame carrying it has been
	// flushed. A gate that keyed a pixel probe on `gotabwm: notify id=`
	// would be reading a frame the seat had not presented yet.
	if line, once := notifyPaintMarker(painted > 0 && presented); once {
		vi.ConsoleLine(line)
	}
	if line, once := notifyCenterPaintMarker(centerPainted > 0, presented); once {
		vi.ConsoleLine(line)
	}
	// M121d (#2567): the focus indicator's transition line — catches every
	// state the input/RPC paths did not (choreography closes, restores).
	noteBadgeTransition()
	if line, once := dragGhostPaintMarker(ghostPainted > 0, presented); once {
		vi.ConsoleLine(line)
	}
	idlePresentedFrame(presented, ticks)
	// M102e (#2169): a published GPU frame earns its `presented` marker only
	// now — after the ordinary present actually flushed it to the scanout.
	gpu3dPresented(presented)
	// M82d2 (#1785): AFTER the present, so the fsync'd publish never delays a
	// frame, and BEFORE the live-mode early return below.
	flushNotifyHistory()
	if launch.open && presented && launch.painted {
		vi.ConsoleLine("gotabwm: launcher presented")
	}
	return presented
}

// damageCompositeTick is the card #3034 (ADR 0007 X4) damage pass: a
// flags-bit0 COMPOSITE_TICK pays the frame — the same compositePaint the
// heartbeat pays — and nothing else. No MarkerTick, no seatTick advance,
// and no tick-counted budget moves: the idle ramp, the strip
// choreography's holds, the toast lane's NotifyTicks expiry, and the
// parked snapshot/focus-cycle releases all keep heartbeat cadence.
// compositeClock still counts the frame — a paint is a real composite
// pass, and that is what keeps a toast born mid-drain anchored to the
// frame it actually landed on.
func damageCompositeTick(scan []byte, ticks uint64, presents *int) {
	compositeClock++
	_ = compositePaint(scan, ticks, presents)
}

// drainSeatEvents consumes the first event and every event already queued
// behind it, preserving kernel arrival order. Non-tick events are handled in
// place; a COMPOSITE_TICK is accounted immediately through onTick (false
// still stops the drain) but the PAINT it owes is deferred to flush —
// invoked once when the queue empties or the bound trips, early when an owed
// paint has already waited drainPaintStride events, and once on the stop
// edge so the heartbeat that reached the demo bound still lands its frame
// (#2730: interleaved repaint work is what lagged the seat seconds behind a
// scripted burst — a tick queued ahead of input is worthless as a frame and
// worse as a delay). service runs mid-drain every drainServiceStride events
// so the mailbox's bounded-poll ack windows hold while the queue is deep;
// RPCs have a separate mailbox and therefore no jointly observable arrival
// order with the kernel event queue.
func drainSeatEvents(first vi.Event, poll func() (vi.Event, bool), consume func(vi.Event) bool, bound int, service func(), onTick func() bool, flush func()) (events int) {
	if bound < 1 {
		return 0
	}
	// heldDebt counts events consumed since a paint became owed (the owed
	// tick opens the window); sinceService paces the mailbox probe. Both
	// reset when their work is paid. flush is invoked only while a tick
	// event was consumed since the last flush — the callee still decides
	// whether the paint is owed (the demo bound refuses before owing).
	heldDebt, sinceService := 0, 0
	payPaint := func() {
		if heldDebt == 0 {
			return
		}
		heldDebt = 0
		if flush != nil {
			flush()
		}
	}
	consumeEvent := func(e vi.Event) bool {
		events++
		sinceService++
		if service != nil && sinceService >= drainServiceStride {
			sinceService = 0
			service()
		}
		if !consume(e) {
			if heldDebt > 0 {
				heldDebt++
				if heldDebt >= drainPaintStride {
					payPaint()
				}
			}
			return true
		}
		if heldDebt == 0 {
			heldDebt = 1
		}
		// card #3034 (ADR 0007 X4): a flags-bit0 damage tick opened the
		// paint debt like any tick — the owed-paint path below will flush
		// it — but it is not a heartbeat, so onTick's accounting (ticks,
		// seatTick, MarkerTick) does not run for it.
		if e.Kind == vi.EvCompositeTick && e.Flags&vi.WmTickDamage != 0 {
			return true
		}
		if onTick != nil && !onTick() {
			payPaint()
			return false
		}
		return true
	}
	if !consumeEvent(first) {
		return events
	}
	for events < bound {
		e, ok := poll()
		if !ok {
			break
		}
		if !consumeEvent(e) {
			return events
		}
	}
	payPaint()
	return events
}

// consumeSeatEvent handles one non-empty poll. Pointer and key log their
// markers and return false (not a tick). Kind 19 also hit-tests the top
// rail (M63c). Window mirrors are dropped; client-area clicks are ignored.
// Any other kind is the pre-M63a ignore-non-tick path. Only
// EvCompositeTick returns true.
func consumeSeatEvent(e vi.Event) bool {
	launcherWindowEvent(e)
	// M102e (#2169): the kind-20 registry mirror also feeds the GPU3D
	// publish geometry table — the seat's only legible live-rect source
	// (WinQuery is owner-only). The released-bit context drop rides
	// dropRpcBinding inside launcherWindowEvent.
	gpu3dNoteMirror(e)
	// #2236 defect #13: the same mirror's x|y arg feeds the compose-N
	// blit for handoff surfaces.
	surfaceNoteMirror(e)
	// #3126: the mirror's focused bit tracks the kernel's focused user
	// window — the routed-chord repair in applyUndo reads it.
	noteKernelFocus(e)
	// #2703: live input re-arms the demo strip hold. hidChordHold's job is
	// to keep the two-tab choreography's destructive steps (swap→pin→
	// split→closePinnedFirst/closeHosted) behind in-flight scripted input;
	// a fixed one-shot countdown cannot — the chain's own events burn it —
	// and a close that lands mid-chain parks the seat loop in the
	// close's state-ask drain while still-queued keystrokes decode to
	// whatever is left focused (observed go-dogfood boot 04: `return` +
	// `alt-tab` decoded to charmhello after GOTERM's close). Re-arming
	// matches the single-tab path's contract (`hostTicksLeft = hostTicks`
	// on user actions): the demo yields while the user is acting, and
	// resumes once input is quiet for hidChordHold ticks. maxTicks still
	// bounds the boot; this only reorders within it.
	if (e.Kind == vi.EvWmPointer || e.Kind == vi.EvWmKey) && demoMode && !stripDone {
		stripHoldLeft = hidChordHold
	}
	// #2703: any non-tick event is work the seat just observed — the demo
	// run budget re-arms on it so a still-running chain cannot be swept
	// mid-leg (the kind-20 mirror above counts too: an app resizing is
	// activity whether or not a key is flying).
	if e.Kind != vi.EvCompositeTick {
		lastActivityTick = seatTick
	}
	if e.Kind == vi.EvWmPointer {
		vi.ConsoleLine(MarkerPtr)
		if idleInput(seatTick) {
			return false
		}
		handleWmPointer(e)
		noteBadgeTransition()
		return false
	}
	if e.Kind == vi.EvWmKey {
		vi.ConsoleLine(MarkerKey)
		if idleInput(seatTick) {
			return false
		}
		handleWmKey(e)
		noteBadgeTransition()
		// M107e (#2322): poll the host-integration lane on the input path,
		// not only at the ~1 Hz composite tick — a host clipboard item the
		// user pastes with ctrl-v would otherwise sit unapplied for up to a
		// full tick after their gesture. Per-key polling makes the lane
		// land within the keystroke that asked for it.
		hostintSeatTick()
		// Yield only when the launcher is closed: a hosted client (GOEDIT
		// ctrl-s) needs a scheduling slice to drain KEY_DOWN before the
		// next virtio chord. #2260: this used to park a whole scheduler
		// tick (~1 s) per key — at 4 strokes/s of injected input the
		// seat's 16-deep queue overflowed and drop-oldest ate the batch
		// head (the alt-tab focus change or the paste-confirm return),
		// which is exactly how the wav-toast chain went silent. A yield
		// hands the client its slice without taking the seat off the wire.
		if !launch.open {
			vi.Yield()
		}
		return false
	}
	// card #3034 (ADR 0007 X4): a damage tick (kind 18, flags bit 0) owes
	// the seat a compose+present — mark the debt here, because the drain
	// skips the heartbeat accounting that would otherwise set it. A
	// heartbeat owes the same paint through onTick instead.
	if e.Kind == vi.EvCompositeTick && e.Flags&vi.WmTickDamage != 0 {
		pendingComposite = true
	}
	return e.Kind == vi.EvCompositeTick
}

// hidMarker is the serial line for a WM input-seam kind, or "" for ticks,
// window mirrors, empty polls, and everything else. Empty polls never call
// this — the loop Sleeps instead.
func hidMarker(kind uint16) string {
	switch kind {
	case vi.EvWmPointer:
		return MarkerPtr
	case vi.EvWmKey:
		return MarkerKey
	default:
		return ""
	}
}

// paintBlank fills every pixel of the mapped scanout with rgb and returns the
// pixel count written. Split out of main so the host test can pin the fill
// without a guest (an incomplete fill is the classic "the frame looks right on
// one half" bug).
func paintBlank(scan []byte, rgb uint32) int {
	n := len(scan) / 4
	if n == 0 {
		return 0
	}
	// One canvas row the whole buffer long: the opaque fill is the same
	// engine write every other seat painter makes. B,G,R,X scanout: the
	// X byte must be opaque (the kernel writes 0xff there too) — a 6-hex
	// token leaves it 0x00, which the host display honours as alpha. That
	// is why a seated scanout used to show the kernel's opaque layer and
	// none of the seat's. M71c (#1562); draw.Opaque carries it now.
	c, err := draw.BytesCanvas(scan, n, 1)
	if err != nil {
		return 0
	}
	draw.FillRect(c, widgets.Rect{X: 0, Y: 0, W: n, H: 1}, draw.Opaque(rgb))
	return n
}

// lastRailN / lastRailFocus suppress repeat rail markers; the gate greps
// the transition (n=2 then n=1), not a per-tick flood.
var (
	lastRailN     int
	lastRailFocus uint32
	lastRailSpace int
	railMarked    bool
)

func markRail() {
	n := tabs.Count()
	if n == 0 {
		return
	}
	f, _ := tabs.Focused()
	if railMarked && n == lastRailN && f == lastRailFocus &&
		spaceCur == lastRailSpace {
		return
	}
	railMarked = true
	lastRailN = n
	lastRailFocus = f
	lastRailSpace = spaceCur
	vi.ConsoleLine(MarkerRail + "n=" + vi.Itoa64(int64(n)) + " focus=" +
		vi.Itoa64(int64(f)) + " space=" + spaces[spaceCur].Name)
}

// railPainted latches MarkerRailPaint — once per boot is the whole
// contract: the gate wants the FIRST scanout the rail is already on, and
// markRail above already narrates every later transition (pre-present).
var railPainted bool

// railPaintMarker returns the presented-rail marker for the first frame
// that both painted the rail (paintRail wrote pixels) and presented it —
// the notifyPaintMarker rule applied to the strip: a snapshot anchored on
// this line reads a scanout the rail is already on. The n/focus/space
// payload mirrors markRail's line so the two reads diff cleanly.
func railPaintMarker(painted, presented bool) (string, bool) {
	if !painted || !presented || railPainted {
		return "", false
	}
	railPainted = true
	f, _ := tabs.Focused()
	return MarkerRailPaint + "n=" + vi.Itoa64(int64(tabs.Count())) +
		" focus=" + vi.Itoa64(int64(f)) + " space=" + spaces[spaceCur].Name, true
}
