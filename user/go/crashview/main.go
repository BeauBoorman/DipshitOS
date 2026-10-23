// Command crashview is CRASHVIEW.ELF — the crash-receipt browser: it polls
// the tombstone directories (vi.CrashReceiptDir, plus /host/crash until a
// probe proves they alias) for the frozen APP.ELF.TXT/.STK receipts and
// pid-APP.txt kernel tombstones the crashguard publishes, newest observed
// first. R reopens the selected receipt's recorded basename under the
// in-process M94b tracer.
//
// Why I'm separate (the #3189 diagnostics census, docs/diagnostics.md):
// this is the post-mortem surface — what died and why, read from files
// frozen at crash time. logview shows the live rings those last-log tails
// were cut from, GOTOP shows what is running now, observe arms a session
// on a live target.
package main

import (
	"strconv"
	"strings"
	"time"

	"virelai/appkit"
	"virelai/draw"
	"virelai/strace"
	"virelai/tabapp"
	"virelai/theme"
	"virelai/vi"
	"virelai/widgets"
)

const usage = "CRASHVIEW.ELF [-text] [-polls N] [-exercise go|kernel|twice|reopen]"

type options struct {
	text     bool
	polls    int
	exercise string
}

func parseOptions(args []string) (options, bool) {
	var o options
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-text":
			o.text = true
		case "-polls", "-exercise":
			if i+1 == len(args) {
				return o, false
			}
			i++
			if args[i-1] == "-polls" {
				n, err := strconv.Atoi(args[i])
				if err != nil || n < 1 || n > 120 {
					return o, false
				}
				o.polls = n
			} else {
				switch args[i] {
				case "go", "kernel", "twice", "reopen":
					o.exercise = args[i]
				default:
					return o, false
				}
			}
		default:
			return o, false
		}
	}
	return o, true
}

type application struct {
	view       *viewer
	opts       options
	dirs       []string
	limited    map[string]bool
	trace      *strace.Session
	tracePID   uint64
	traceStart int64
	traceRows  []string
	status     string
	spawned    int
	shown      int
	lastStamp  int64
	started    int64
	done       bool
}

func main() {
	args := vi.Args()
	if len(args) > 0 {
		args = args[1:]
	}
	o, ok := parseOptions(args)
	if !ok {
		vi.ConsoleLine(usage)
		vi.Exit(2)
	}
	a := &application{view: newViewer(), opts: o,
		status: "Newest observed first | Up/Down: receipt | R: reopen in tracer | Esc: close"}
	same, rc := probeDirectories()
	if rc < 0 {
		fail(rc)
	}
	a.dirs = []string{vi.CrashReceiptDir}
	if !same {
		a.dirs = append(a.dirs, "/host/crash")
	}
	if _, rc := a.poll(); rc < 0 {
		fail(rc)
	}
	a.started = vi.Nanos()
	if o.exercise != "" {
		app := "CRASHFIX.ELF"
		if o.exercise == "kernel" {
			app = "CRASH.ELF"
		}
		if err := a.spawn(app, "first"); err != nil {
			failMessage(err.Error())
		}
	}
	if o.text {
		a.runText()
	} else {
		a.runWindow()
	}
}

func failMessage(message string) {
	vi.ConsoleLine("crashview: error " + message)
	vi.Exit(1)
}

func fail(rc int64) { failMessage("rc=" + vi.Itoa64(rc)) }

// The unique file is ours, not an existing receipt. Reading it through the
// other spelling proves aliasing rather than inferring it from two listings.
func probeDirectories() (bool, int64) {
	h, rc := vi.FileOpen(vi.CrashReceiptDir, vi.ModeWrite|vi.ModeCreate|vi.ModeDir)
	if rc < 0 && rc != vi.ErrFileExists {
		return false, rc
	}
	if rc >= 0 {
		vi.FileClose(uint32(h))
	}
	name := "CVPROBE-" + strconv.FormatInt(vi.Nanos(), 16)
	path := vi.CrashReceiptDir + "/" + name
	body := []byte("crashview-probe-" + vi.Itoa64(vi.Nanos()))
	if rc := vi.WriteFileSafe(path, body); rc < 0 {
		return false, rc
	}
	defer vi.FileDelete(path)
	got, rc := vi.ReadFileAll("/host/crash/"+name, len(body)+1)
	if rc < 0 && rc != vi.ErrFileNotFound {
		return false, rc
	}
	same := rc >= 0 && string(got) == string(body)
	answer := "distinct"
	if same {
		answer = "same"
	}
	vi.ConsoleLine("crashview: directories=" + answer)
	return same, 0
}

func (a *application) poll() (bool, int64) {
	dirty := false
	for _, dir := range a.dirs {
		var entries [vi.MaxDirEntries]vi.DirEntry
		n, rc := vi.DirList(dir, entries[:])
		if rc == vi.ErrFileNotFound {
			continue
		}
		if rc < 0 {
			return dirty, rc
		}
		if n == len(entries) {
			if a.limited == nil {
				a.limited = make(map[string]bool)
			}
			if !a.limited[dir] {
				a.status = "Directory listing at 16-entry ABI limit; later names may be hidden"
				vi.ConsoleLine("crashview: directory window full path=" + dir)
				a.limited[dir] = true
				dirty = true
			}
		}
		for _, entry := range entries[:n] {
			name := entry.NameString()
			kind, app := classify(name)
			if entry.Dir() || (kind != receiptEntry && kind != kernelEntry) {
				continue
			}
			path := dir + "/" + name
			limit := receiptLimit
			if kind == kernelEntry {
				limit = kernelLimit
			}
			body, rc := vi.ReadFileAll(path, limit+1)
			if rc == vi.ErrFileNotFound {
				continue // safe publish briefly has no live target
			}
			if rc < 0 {
				return dirty, rc
			}
			var stack []byte
			if kind == receiptEntry {
				stack, rc = vi.ReadFileAll(dir+"/"+app+".STK", vi.CrashStackMaxBytes+1)
				if rc < 0 && rc != vi.ErrFileNotFound {
					return dirty, rc
				}
			}
			if r, changed := a.view.observe(path, name, body, stack); changed {
				dirty = true
				a.mirror(r)
				if (a.opts.exercise == "kernel" && r.app == "CRASH.ELF") ||
					(r.app == "CRASHFIX.ELF" && r.kind == "go" && len(r.frames) >= 3 &&
						r.generation != a.lastStamp) {
					a.shown++
					a.lastStamp = r.generation
				}
			}
		}
	}
	return dirty, 0
}

func (a *application) mirror(r record) {
	vi.ConsoleLine("crashview: shown app=" + r.app + " kind=" + r.kind +
		" frames=" + strconv.Itoa(len(r.frames)) + " t1=" + vi.Itoa64(vi.Nanos()) +
		" generation=" + vi.Itoa64(r.generation))
	vi.ConsoleLine("crashview: " + r.outcome)
	vi.ConsoleLine("crashview: " + r.stackNote())
	for _, f := range r.frames {
		vi.ConsoleLine("crashview: frame " + f.function)
		if f.source != "" {
			vi.ConsoleLine("crashview: source " + f.source)
		}
	}
	for _, tail := range []struct{ label, body string }{{"log", r.log}, {"serial", r.serial}} {
		for _, line := range strings.Split(strings.TrimSuffix(tail.body, "\n"), "\n") {
			if line != "" {
				vi.ConsoleLine("crashview: " + tail.label + " " + line)
			}
		}
	}
}

func (a *application) spawn(app, token string) error {
	now := vi.Nanos()
	vi.ConsoleLine("crashview: spawn app=" + app + " t0=" + vi.Itoa64(now))
	args := []string(nil)
	if app == "CRASHFIX.ELF" {
		args = []string{token}
	}
	if _, err := vi.Exec(app, args...); err != nil {
		return err
	}
	a.spawned++
	return nil
}

func (a *application) reopen() {
	if a.trace != nil || len(a.view.records) == 0 {
		return
	}
	r := a.view.records[a.view.selected]
	// Frozen receipts contain no argv. Do not invent the original arguments.
	session, pid, err := strace.ArmExec(r.app, nil, []uint64{1, 3, 23, 24, 25, 26, 77})
	if err != nil {
		a.status = "Reopen failed: " + err.Error()
		vi.ConsoleLine("crashview: " + a.status)
		return
	}
	a.trace, a.tracePID, a.traceStart = session, pid, vi.Nanos()
	a.traceRows = nil
	a.status = "Tracing " + r.app + " (recorded basename, arguments unavailable)"
	vi.ConsoleLine("crashview: reopened app=" + r.app + " pid=" + strconv.FormatUint(pid, 10))
}

func (a *application) drainTrace() (uint64, int64, bool, error) {
	var status int64
	exited := false
	dropped, err := a.trace.Drain(16, func(r vi.TraceRecord, line string) bool {
		a.traceRows = append(a.traceRows, line)
		if len(a.traceRows) > 64 {
			a.traceRows = a.traceRows[len(a.traceRows)-64:]
		}
		if r.PID == a.tracePID && r.Number == uint64(vi.SlotExit) && r.Flags&vi.TraceNoReturn != 0 {
			// The registry can reuse this PID before our next poll. The
			// captured exit is authoritative; do not show a successor's calls.
			status, exited = int64(r.Args[0]), true
			return false
		}
		return true
	})
	return dropped, status, exited, err
}

func (a *application) pollTrace() bool {
	if a.trace == nil {
		return false
	}
	dropped, status, recordedExit, err := a.drainTrace()
	state := vi.ProbeRunning
	if !recordedExit {
		status, state = vi.Probe(int64(a.tracePID))
	}
	timedOut := vi.Nanos()-a.traceStart >= 120_000_000_000
	if err != nil || recordedExit || state == vi.ProbeExited || timedOut {
		disarmErr := a.trace.Disarm()
		if err == nil && !recordedExit {
			var exitStatus int64
			dropped, exitStatus, recordedExit, err = a.drainTrace()
			if recordedExit {
				status = exitStatus
			}
		}
		a.trace = nil
		a.status = "Trace ended, dropped=" + strconv.FormatUint(dropped, 10)
		if err != nil || disarmErr != nil || timedOut {
			a.status = "Trace stopped (error or 120 s ceiling), dropped=" + strconv.FormatUint(dropped, 10)
		}
		vi.ConsoleLine("crashview: trace done status=" + vi.Itoa64(status) +
			" dropped=" + strconv.FormatUint(dropped, 10))
	}
	return true
}

func (a *application) step() bool {
	dirty, rc := a.poll()
	if rc < 0 {
		fail(rc)
	}
	if a.pollTrace() {
		dirty = true
	}
	switch a.opts.exercise {
	case "twice":
		if a.shown == 1 && a.spawned == 1 {
			// Preserve the first real bytes for independent same-size assertions.
			for _, ext := range []string{"TXT", "STK"} {
				body, rc := vi.ReadFileAll(vi.CrashReceiptDir+"/CRASHFIX.ELF."+ext, vi.CrashStackMaxBytes)
				if rc < 0 {
					fail(rc)
				}
				if rc := vi.WriteFileSafe("/host/FIRST."+ext, body); rc < 0 {
					fail(rc)
				}
			}
			if err := a.spawn("CRASHFIX.ELF", "other"); err != nil {
				failMessage(err.Error())
			}
		}
		a.done = a.shown >= 2
	case "reopen":
		if a.shown >= 1 && a.tracePID == 0 {
			a.reopen()
		}
		a.done = a.tracePID != 0 && a.trace == nil
	case "go", "kernel":
		a.done = a.shown >= 1
	}
	// End a negative drill deterministically; assertions, not this marker,
	// decide success. A size-only mutation must fail the second-shown assert.
	if a.opts.exercise != "" && vi.Nanos()-a.started >= 20_000_000_000 {
		a.done = true
	}
	return dirty
}

func (a *application) finish() {
	if a.trace != nil {
		_ = a.trace.Disarm()
	}
	vi.ConsoleLine("crashview: done shown=" + strconv.Itoa(a.shown))
}

func (a *application) runText() {
	vi.ConsoleLine("crashview: ready text")
	for polls := 1; ; polls++ {
		a.step()
		if a.done || (a.opts.polls != 0 && polls >= a.opts.polls) {
			break
		}
		time.Sleep(time.Second)
	}
	a.finish()
}

func (a *application) runWindow() {
	ta := tabapp.Init(tabapp.Config{Name: "CRASHVIEW.ELF", Title: "Crash receipts",
		X: 32, Y: 32, W: 920, H: 560})
	if ta == nil {
		fail(-1)
	}
	vi.ConsoleLine("crashview: open id=" + vi.Itoa64(int64(ta.Win)))
	quit := false
	scroll := 0
	drag := false
	var bar widgets.Scrollbar // the receipt-list chrome, rebuilt every frame
	loop := appkit.NewLoop(ta, func() {
		c := ta.Canvas()
		c.FillRect(widgets.Rect{W: int(ta.W), H: int(ta.H)}, draw.Opaque(theme.Current.Bg))
		rows := []string{a.status}
		for i, r := range a.view.records {
			prefix := "  "
			if i == a.view.selected {
				prefix = "> "
			}
			rows = append(rows, prefix+r.app+" ["+r.kind+"] "+r.outcome)
		}
		if len(a.view.records) != 0 {
			r := a.view.records[a.view.selected]
			rows = append(rows, r.stackNote())
			for _, f := range r.frames {
				rows = append(rows, f.function, f.source)
			}
			rows = append(rows, "Last log:", r.log, "Last serial:", r.serial)
		}
		rows = append(rows, "Tracer (last 64 records):")
		rows = append(rows, a.traceRows...)
		lines := strings.Split(strings.Join(rows, "\n"), "\n")
		vp := (int(ta.H)-28)/16 + 1
		if vp < 1 {
			vp = 1
		}
		maxTop := len(lines) - vp
		if maxTop < 0 {
			maxTop = 0
		}
		if scroll < 0 {
			scroll = 0
		}
		if scroll > maxTop {
			scroll = maxTop
		}
		rowW := int(ta.W) - 24
		if len(lines) > vp {
			bar = widgets.Scrollbar{
				R:        widgets.Rect{X: int(ta.W) - 12 - widgets.ScrollbarW, Y: 12, W: widgets.ScrollbarW, H: vp * 16},
				Total:    len(lines),
				Viewport: vp,
				Offset:   scroll,
				Pressed:  drag,
			}
			rowW = bar.R.X - theme.Current.PadXS - 12
		} else {
			bar = widgets.Scrollbar{}
		}
		if bc, ok := c.(*draw.BufferCanvas); ok {
			bc.PushClip(widgets.Rect{X: 12, Y: 0, W: rowW, H: int(ta.H)})
		}
		end := scroll + vp
		if end > len(lines) {
			end = len(lines)
		}
		for i, line := range lines[scroll:end] {
			row := widgets.Text{R: widgets.Rect{X: 12, Y: 12 + i*16, W: rowW, H: 16},
				Label: strings.ReplaceAll(line, "\t", " "), Fg: theme.Current.Text, Bg: theme.Current.Bg}
			row.Draw(c)
		}
		if bc, ok := c.(*draw.BufferCanvas); ok {
			bc.PopClip()
		}
		bar.Draw(c)
	}, func(ev vi.Event) bool {
		switch ev.Kind {
		case vi.EvMouseDown:
			if ev.Flags&vi.BtnLeft == 0 || !bar.HitTest(int(ev.Arg0), int(ev.Arg1)) {
				return false
			}
			switch bar.PageAt(int(ev.Arg0), int(ev.Arg1)) {
			case 0:
				drag = true
			case -1:
				scroll -= bar.Viewport
			case 1:
				scroll += bar.Viewport
			}
			return true
		case vi.EvMouseMove:
			if !drag {
				return false
			}
			scroll = bar.OffsetAt(int(ev.Arg1))
			return true
		case vi.EvMouseUp:
			if !drag {
				return false
			}
			drag = false
			return true
		}
		if ev.Kind != vi.EvKeyDown {
			return false
		}
		switch ev.Arg0 {
		case 0x29: // Escape
			quit = true
		case 0x15: // R: the one-action reopen
			a.reopen()
		case 0x52: // Up
			if a.view.selected > 0 {
				a.view.selected--
			}
			scroll = 0
		case 0x51: // Down
			if a.view.selected+1 < len(a.view.records) {
				a.view.selected++
			}
			scroll = 0
		case 0x4b: // Page Up
			scroll -= 8
			if scroll < 0 {
				scroll = 0
			}
		case 0x4e: // Page Down
			scroll += 8
		default:
			return false
		}
		return true
	})
	loop.OnInitialPresent = func() { vi.ConsoleLine("crashview: present") }
	loop.OnExit = func(status int) {
		a.finish()
		ta.CloseAndExit(status)
	}
	loop.ShouldQuit = func() (int, bool) { return 0, quit }
	next := int64(0)
	vi.ConsoleLine("crashview: ready window")
	loop.RunWith(func() (vi.Event, int64, bool) {
		now := vi.Nanos()
		if now >= next {
			if a.step() {
				loop.Present()
			}
			next = now + 1_000_000_000
		}
		return vi.PollEventRaw()
	}, func(uint64) { time.Sleep(time.Second) })
	a.finish()
}
