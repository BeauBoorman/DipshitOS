//go:build virelai || btmath

package main

import (
	"os"
	"strconv"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/atotto/clipboard"
	"github.com/charmbracelet/colorprofile"

	"virelai/tabapp"
	"virelai/vi"
)

// main wires Bubble Tea to the VirelaiOS seams and reports the outcome through
// console markers. With --selftest it then checks its own results and prints a
// machine-readable verdict, so the proof is produced inside the guest.
//
// --window sends the frames to a real TABWM window instead of the console: the
// kernel paints its tty grid into the window, so the app is visible on the
// guest's own screen (and therefore in a VM framebuffer capture). Input stays
// the scripted key source either way, which keeps the run deterministic.
func main() {
	rounds, seed := defaultRounds, int64(defaultSeed)
	keys, out := defaultKeys, defaultOut
	width, height := 80, 24
	sinkStdout, selfTest, windowed := false, false, false
	keyDelayMs := 90

	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		next := func() string {
			if i+1 < len(args) {
				i++
				return args[i]
			}
			return ""
		}
		switch args[i] {
		case "--rounds":
			if n, err := strconv.Atoi(next()); err == nil && n > 0 {
				rounds = n
			}
		case "--seed":
			if n, err := strconv.ParseInt(next(), 10, 64); err == nil {
				seed = n
			}
		case "--keys":
			keys = next()
		case "--out":
			out = next()
		case "--w":
			if n, err := strconv.Atoi(next()); err == nil && n > 0 {
				width = n
			}
		case "--h":
			if n, err := strconv.Atoi(next()); err == nil && n > 0 {
				height = n
			}
		case "--sink":
			sinkStdout = next() == "stdout"
		case "--selftest":
			selfTest = true
		case "--window":
			windowed = true
		case "--key-delay":
			if n, err := strconv.Atoi(next()); err == nil && n >= 0 {
				keyDelayMs = n
			}
		}
	}

	sink := consoleWriter{}
	var ta *tabapp.TabApp
	var ttyFD int64 = -1
	if sinkStdout {
		sink.alt = os.Stdout
		mirror = os.Stdout
	}
	if windowed {
		ta = tabapp.Init(tabapp.Config{
			Name: "BTMATH.ELF", Title: "Bubble Math",
			X: 80, Y: 60, W: 900, H: 520,
		})
		if ta == nil {
			note("btmath: window open failed")
			vi.Exit(3)
		}
		h, rc := vi.FileOpen("/dev/tty", vi.ModeRead|vi.ModeWrite)
		if rc < 0 {
			note("btmath: no /dev/tty")
			ta.CloseAndExit(4)
		}
		ttyFD = h
		if r := vi.TtyAttachWindow(ta.Win); r != 0 {
			note("btmath: tty attach failed")
			vi.FileClose(uint32(h))
			ta.CloseAndExit(5)
		}
		sink.alt = windowWriter{w: fdWriter(ttyFD)}
		note("btmath: window id=" + strconv.Itoa(ta.Win))
	}

	note(markerStart)

	// A VirelaiOS console is not a POSIX tty, so Bubble Tea cannot ioctl it for
	// a size, and it cannot detect colour support either. Both are declared.
	program := tea.NewProgram(
		newModel(seed, rounds),
		tea.WithInput(&keyScript{keys: parseKeys(keys), delay: time.Duration(keyDelayMs) * time.Millisecond}),
		tea.WithOutput(sink),
		tea.WithColorProfile(colorprofile.TrueColor),
		tea.WithWindowSize(width, height),
	)

	final, err := program.Run()
	if err != nil {
		note("btmath: run error " + err.Error())
	}
	if windowed {
		_ = vi.TtyAttach(vi.TtyDetach)
		vi.FileClose(uint32(ttyFD))
		note("btmath: window closed")
	}
	if err != nil {
		vi.Exit(1)
	}

	played, _ := final.(model)

	n, ok := save(out, played)
	if ok {
		note(markerSave + out + " " + strconv.Itoa(n) + "B")
	} else {
		note(markerSaveNo + out)
	}
	note(markerRound + "played=" + strconv.Itoa(played.correct+played.incorrect) +
		" score=" + strconv.Itoa(played.score) +
		" correct=" + strconv.Itoa(played.correct) +
		" wrong=" + strconv.Itoa(played.incorrect))
	note(markerQuit)

	rc := 0
	if selfTest {
		rc = runSelfTest(played, ok)
		if rc == 0 {
			note(markerOK)
		}
	} else if !ok {
		rc = 2
	} else {
		note(markerOK)
	}
	if windowed {
		ta.CloseAndExit(rc)
	}
	vi.Exit(rc)
}

// fdWriter writes straight to an open guest file descriptor (the tty).
type fdWriter int64

func (f fdWriter) Write(p []byte) (int, error) {
	n, _ := vi.FileWriteAll(uint32(f), p)
	return n, nil
}

// windowWriter clears the tty grid before each frame. The kernel's grid stores
// plain bytes and handles CSI J/H only, so a clear-then-draw is what makes
// Bubble Tea's successive frames replace one another instead of piling up.
type windowWriter struct {
	w interface{ Write([]byte) (int, error) }
}

func (w windowWriter) Write(p []byte) (int, error) {
	if _, err := w.w.Write([]byte("\x1b[2J")); err != nil {
		return 0, err
	}
	return w.w.Write(p)
}

// runSelfTest checks the session the guest just played against the documented
// outcome and prints one line per check. It runs IN the guest: the console is
// the evidence, and a reviewer reads the verdict without leaving the OS.
//
// Exit status: 0 all checks passed, 1 any failed. Nothing here needs a shell.
func runSelfTest(m model, saved bool) int {
	type check struct {
		name string
		got  string
		want string
		ok   bool
	}
	frames := strings.Join(m.frames, "\n")
	has := func(s string) bool { return strings.Contains(frames, s) }

	checks := []check{
		{"rounds", strconv.Itoa(m.correct + m.incorrect), strconv.Itoa(defaultRounds), m.correct+m.incorrect == defaultRounds},
		{"score", strconv.Itoa(m.score), "65", m.score == 65},
		{"correct", strconv.Itoa(m.correct), "3", m.correct == 3},
		{"incorrect", strconv.Itoa(m.incorrect), "2", m.incorrect == 2},
		{"frames", strconv.Itoa(len(m.frames)), ">0", len(m.frames) > 0},
		{"frame-header", "Bubble Math", "present", has("Bubble Math")},
		{"frame-correct", "Correct. +10 points", "present", has("Correct. +10 points")},
		{"frame-wrong", "Not quite: 5, not 6.", "present", has("Not quite: 5, not 6.")},
		{"frame-skip", "Skipped.", "present", has("Skipped.")},
		{"frame-final", "Session over. Final score 65.", "present", has("Session over. Final score 65.")},
		{"frame-tiers", "Times & divide", "present", has("Times & divide")},
		{"record-written", "SESSION.TXT", "written", saved},
	}

	// The clipboard check is the guest-side proof for the atotto/clipboard
	// virelai backend: the final score round-trips through the kernel's
	// shared 512-byte seat clipboard via WriteAll/ReadAll.
	clipGot, clipOK := clipboardRoundTrip(m.score)
	checks = append(checks, check{"clipboard", clipGot, "65", clipOK && clipGot == "65"})

	failed := 0
	note("btmath: selftest begin checks=" + strconv.Itoa(len(checks)))
	for _, c := range checks {
		verdict := "PASS"
		if !c.ok {
			verdict = "FAIL"
			failed++
		}
		note("btmath: selftest " + c.name + " got=" + c.got + " want=" + c.want + " " + verdict)
	}

	result := "PASS"
	if failed > 0 {
		result = "FAIL"
	}
	note("btmath: selftest RESULT " + result +
		" checks=" + strconv.Itoa(len(checks)) + " failed=" + strconv.Itoa(failed))
	if failed > 0 {
		return 1
	}
	return 0
}

// clipboardRoundTrip proves the atotto/clipboard virelai backend end-to-end:
// the final score goes out through WriteAll and comes back through ReadAll
// unchanged. The guest owns the verdict — the gate only reads the marker.
func clipboardRoundTrip(score int) (string, bool) {
	want := strconv.Itoa(score)
	if err := clipboard.WriteAll(want); err != nil {
		return "write-failed", false
	}
	got, err := clipboard.ReadAll()
	if err != nil {
		return "read-failed", false
	}
	return got, got == want
}
