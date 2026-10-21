//go:build virelai || btmath

// Command btmath is "Bubble Math": the Bubble Tea arithmetic trainer running as
// a VirelaiOS userland app (GOOS=virelai, GOARCH=arm64).
//
// It is the portability proof for Bubble Tea on this operating system. Nothing
// in the framework is reimplemented: the same tea.Model / Init-Update-View
// program, the same tea.Cmd and tea.Msg plumbing, the same key decoding and
// window-size handling run here. Only two seams are supplied by the OS:
//
//	input  - Bubble Tea reads keys through an io.Reader (tea.WithInput). Here
//	         that reader is a paced byte script, so a gate can drive the app
//	         deterministically through the REAL decoding path.
//	output - Bubble Tea paints frames through an io.Writer (tea.WithOutput).
//	         Here that writer is the VirelaiOS kernel console.
//
// The app writes its session record to the host share, which is what makes the
// gate's assertion load-bearing: a stub that printed markers without playing
// the game cannot produce the file content. It also writes the frames it
// rendered, so the visual output can be inspected off the machine.
//
// Usage (in the guest console):
//
//	exec BTMATH.ELF
//	exec BTMATH.ELF --keys 1,7,ret --out /host/BTMATH/SESSION.TXT
package main

import (
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"charm.land/bubbles/v2/help"
	"charm.land/bubbles/v2/key"
	"charm.land/bubbles/v2/progress"
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"

	"virelai/vi"
)

// ---- markers (the gate asserts on these) -----------------------------------

const (
	markerStart  = "btmath: start"
	markerKey    = "btmath: key "
	markerRound  = "btmath: round "
	markerSave   = "btmath: saved "
	markerSaveNo = "btmath: save-failed "
	markerQuit   = "btmath: quit"
	markerOK     = "btmath: OK"
)

const (
	defaultRounds = 5
	defaultSeed   = 7
	defaultOut    = "/host/BTMATH/SESSION.TXT"
	// defaultKeys is the scripted session for defaultSeed: round 1 answered
	// correctly (9+8=17), round 2 answered wrong (8-3, keyed 6), round 3 skipped,
	// then rounds 4 and 5 answered correctly (93+59=152, 8/4=2). Expected
	// outcome: 5 played, 3 correct, 2 wrong, score 65 - asserted by the gate.
	defaultKeys = "1,7,ret,ret,6,ret,ret,s,ret,1,5,2,ret,ret,2,ret,q"
)

// ---- colour ----------------------------------------------------------------
//
// The app renders in colour, the way a Bubble Tea TUI normally does. Sequences
// are plain SGR, so they are inert wherever the output is not interpreted (the
// guest console passes bytes through untouched) and vivid wherever it is.
const sgr = "\x1b["

func col(s, code string) string { return sgr + code + "m" + s + sgr + "0m" }

const (
	cTitle  = "1;36" // bright cyan
	cDim    = "2"    // dim
	cTier   = "35"   // magenta
	cScore  = "1;32" // bright green
	cQuest  = "1;33" // bright yellow
	cRight  = "1;32" // bright green
	cWrong  = "1;31" // bright red
	cHint   = "33"   // yellow
	cPrompt = "36"   // cyan
	cInput  = "1;37" // bright white
)

// note emits an evidence marker: to the VirelaiOS kernel console always, and
// additionally to mirror when the same binary is built/run on a host.
func note(s string) {
	vi.ConsoleLine(s)
	if mirror != nil {
		fmt.Fprintln(mirror, s)
	}
}

// mirror, when non-nil, duplicates markers to a plain writer (host runs).
var mirror io.Writer

// ---- the model -------------------------------------------------------------

type tickMsg time.Time

// keyMap is the footer help.Model's binding set: the same key.Binding
// values Update matches against, so the rendered help can never drift from
// the keys that actually work.
type keyMap struct {
	submit key.Binding
	skip   key.Binding
	quit   key.Binding
}

func newKeyMap() keyMap {
	return keyMap{
		submit: key.NewBinding(key.WithKeys("enter"), key.WithHelp("enter", "submit")),
		skip:   key.NewBinding(key.WithKeys("s"), key.WithHelp("s", "skip")),
		quit:   key.NewBinding(key.WithKeys("q", "ctrl+c"), key.WithHelp("q", "quit")),
	}
}

func (k keyMap) ShortHelp() []key.Binding  { return []key.Binding{k.submit, k.skip, k.quit} }
func (k keyMap) FullHelp() [][]key.Binding { return [][]key.Binding{k.ShortHelp()} }

type model struct {
	total, round int
	a, b, answer int
	op           byte

	input     textinput.Model
	bar       progress.Model
	helpView  help.Model
	keys      keyMap
	score     int
	streak    int
	correct   int
	incorrect int
	feedback  string
	answered  bool
	done      bool

	width, height int
	started       time.Time
	seed          int64

	// rngState keeps the question stream reproducible without importing a
	// heavy RNG: a small LCG, advanced once per question.
	rngState int64

	// frames keeps every rendered frame, with the event that produced it, so
	// the visual output can be inspected after the run.
	frames      []string
	frameLabels []string

	quit bool
}

// digitsOnly is the textinput's contract: every generated question answers
// to a nonnegative integer (subtraction rounds are built a >= b, and the
// times/divide tier is all-positive), so a non-digit keystroke is refused —
// Update rolls the input back when this flags Err.
var errDigitsOnly = errors.New("digits only")

func digitsOnly(s string) error {
	for _, r := range s {
		if r < '0' || r > '9' {
			return errDigitsOnly
		}
	}
	return nil
}

func newModel(seed int64, rounds int) model {
	ti := textinput.New()
	ti.Prompt = "> "
	ti.CharLimit = 9
	ti.Validate = digitsOnly
	ti.Focus()
	m := model{
		total: rounds, round: 1, started: time.Now(), seed: seed, rngState: seed,
		input:    ti,
		bar:      progress.New(progress.WithWidth(24)),
		helpView: help.New(),
		keys:     newKeyMap(),
	}
	m.next()
	return m
}

// next advances the LCG and builds the question for the current round.
func (m *model) next() {
	m.rngState = (m.rngState*6364136223846793005 + 1442695040888963407) & 0x7fffffffffffffff
	s := m.rngState
	m.input.Reset()
	m.feedback, m.answered = "", false

	lvl := (m.round + 1) / 2
	if lvl > 3 {
		lvl = 3
	}
	opIdx := int(s % 3)
	switch lvl {
	case 1:
		m.a, m.b = int(s%9)+1, int((s/9)%9)+1
		if opIdx == 1 {
			m.op = '-'
			if m.a < m.b {
				m.a, m.b = m.b, m.a
			}
			m.answer = m.a - m.b
		} else {
			m.op = '+'
			m.answer = m.a + m.b
		}
	case 2:
		m.a, m.b = int(s%90)+10, int((s/97)%90)+10
		if opIdx == 1 && m.a >= m.b {
			m.op = '-'
			m.answer = m.a - m.b
		} else {
			m.op = '+'
			m.answer = m.a + m.b
		}
	default:
		if opIdx == 0 {
			m.a, m.b = int(s%12)+2, int((s/13)%12)+2
			m.op = '*'
			m.answer = m.a * m.b
		} else {
			d, q := int(s%11)+2, int((s/11)%11)+2
			m.a, m.b, m.op = d*q, d, '/'
			m.answer = q
		}
	}
}

func (m model) question() string { return fmt.Sprintf("%d %c %d = ?", m.a, m.op, m.b) }

func (m model) tierName() string {
	switch (m.round + 1) / 2 {
	case 1:
		return "Warm-up"
	case 2:
		return "Two digits"
	default:
		return "Times & divide"
	}
}

func (m model) Init() tea.Cmd {
	// A real tea.Cmd: the clock starts the first frame's timer. This exercises
	// the command -> message round trip on this OS.
	return tea.Tick(120*time.Millisecond, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height

	case tickMsg:
		return m, nil

	case tea.KeyPressMsg:
		ks := msg.String()
		note(markerKey + ks)

		switch {
		case key.Matches(msg, m.keys.quit):
			m.quit = true
			m.done = true
			m.record("quit")
			return m, tea.Quit
		case key.Matches(msg, m.keys.submit):
			if m.answered {
				m.round++
				if m.round > m.total {
					m.done = true
					m.record("finished")
					return m, tea.Quit
				}
				m.next()
				m.record("round" + strconv.Itoa(m.round))
				return m, nil
			}
			m.evaluate()
			m.record("submit")
			return m, nil
		case key.Matches(msg, m.keys.skip) && !m.answered:
			m.answered, m.feedback = true, "Skipped."
			m.streak, m.incorrect = 0, m.incorrect+1
			m.record("skip")
			return m, nil
		}

		if !m.answered {
			// Everything else is the textinput's: digits insert, editing
			// keys edit. A Validate-flagged candidate is rolled back —
			// the input refuses non-digits, not merely their submission.
			prev := m.input.Value()
			var cmd tea.Cmd
			m.input, cmd = m.input.Update(msg)
			if m.input.Err != nil {
				m.input.SetValue(prev)
			}
			return m, cmd
		}
	}
	return m, nil
}

// record snapshots the frame this event produced, labelled with the event.
func (m *model) record(label string) {
	if len(m.frames) > 64 {
		return
	}
	m.frames = append(m.frames, m.View().Content)
	m.frameLabels = append(m.frameLabels, label)
}

func (m *model) evaluate() {
	s := strings.TrimSpace(m.input.Value())
	n, err := strconv.Atoi(s)
	switch {
	case s == "":
		m.feedback = "Type a number first."
		return
	case err != nil:
		m.feedback = "Numbers only."
		m.input.Reset()
		return
	case n == m.answer:
		m.streak++
		m.correct++
		pts := 10*((m.round+1)/2) + 5*minInt(m.streak-1, 5)
		m.score += pts
		m.feedback = fmt.Sprintf("Correct. +%d points", pts)
	default:
		m.streak, m.incorrect = 0, m.incorrect+1
		m.feedback = fmt.Sprintf("Not quite: %d, not %d.", m.answer, n)
	}
	m.answered = true
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func (m model) View() tea.View {
	var b strings.Builder
	b.WriteString(col("Bubble Math", cTitle) + col("  (Bubble Tea on VirelaiOS)", cDim) + "\r\n")
	b.WriteString(col(fmt.Sprintf("Round %d of %d", m.round, m.total), "1") + "   " + col("Tier "+m.tierName(), cTier) + "\r\n")
	b.WriteString(col(fmt.Sprintf("Score %d   Streak %d   Correct %d   Wrong %d",
		m.score, m.streak, m.correct, m.incorrect), cScore) + "\r\n")
	b.WriteString(m.bar.ViewAs(float64(m.correct+m.incorrect)/float64(m.total)) + "\r\n\r\n")

	if m.done {
		b.WriteString(col(fmt.Sprintf("Session over. Final score %d.", m.score), "1;33") + "\r\n")
	} else {
		b.WriteString("   " + col(m.question(), cQuest) + "\r\n")
		if m.answered {
			code := cWrong
			if strings.HasPrefix(m.feedback, "Correct") {
				code = cRight
			}
			b.WriteString("   " + col(m.feedback, code) + "\r\n\r\n")
			b.WriteString("   " + col("press Enter for the next question", cDim) + "\r\n")
		} else {
			b.WriteString(m.input.View() + "\r\n")
			if m.feedback != "" {
				b.WriteString("   " + col(m.feedback, cHint) + "\r\n")
			}
		}
	}
	b.WriteString("\r\n" + m.helpView.View(m.keys) + "\r\n")

	return tea.NewView(b.String())
}

// ---- OS seams --------------------------------------------------------------

// consoleWriter is Bubble Tea's output seam: frames land on the VirelaiOS
// kernel console. alt (if set) redirects to a plain writer instead, which is
// how the identical program is exercised by `go test` on the host, where the
// guest console degrades to -ENOSYS.
type consoleWriter struct{ alt io.Writer }

func (w consoleWriter) Write(p []byte) (int, error) {
	if w.alt != nil {
		return w.alt.Write(p)
	}
	vi.Console(string(p))
	return len(p), nil
}

// keyScript is Bubble Tea's input seam: a paced byte script. Pacing matters -
// one key per frame, so the console log holds real, distinguishable frames.
type keyScript struct {
	keys  []string
	delay time.Duration
	i     int
	buf   []byte
}

func (r *keyScript) Read(p []byte) (int, error) {
	if len(r.buf) == 0 {
		if r.i >= len(r.keys) {
			return 0, io.EOF
		}
		time.Sleep(r.delay)
		r.buf = []byte(r.keys[r.i])
		r.i++
	}
	n := copy(p, r.buf)
	r.buf = r.buf[n:]
	return n, nil
}

// parseKeys turns "3,ret,s,q" into Bubble Tea key bytes.
func parseKeys(s string) []string {
	var out []string
	for _, k := range strings.Split(s, ",") {
		switch k {
		case "ret", "enter":
			out = append(out, "\r")
		case "bs":
			out = append(out, "\x7f")
		case "":
		default:
			out = append(out, k)
		}
	}
	return out
}

// save writes the session record to the share and reports the byte count.
// The record is fully in memory, so it publishes through vi.WriteFileSafe
// (temp + fsync + rename): a crash mid-write can never tear SESSION.TXT into
// a partial file the gate reads as complete (M81e2 #1787).
func save(path string, m model) (int, bool) {
	rec := fmt.Sprintf(
		"app=%s\nscore=%d\nrounds=%d\ncorrect=%d\nincorrect=%d\nseed=%d\ntier=%s\nkeys=%s\n",
		"BTMATH", m.score, m.correct+m.incorrect, m.correct, m.incorrect,
		m.seed, m.tierName(), "scripted")
	rc := vi.WriteFileSafe(path, []byte(rec))
	writeFrames(path+".FRAMES", m)
	return len(rec), rc == 0
}

// writeFrames dumps every rendered frame beside the session record so the
// visual output of the guest run can be inspected off the machine. Each frame
// keeps its escape sequences: they are the colour.
func writeFrames(path string, m model) {
	var b strings.Builder
	for i, f := range m.frames {
		label := ""
		if i < len(m.frameLabels) {
			label = m.frameLabels[i]
		}
		fmt.Fprintf(&b, "----- frame %d  event=%s -----\n%s\n", i, label, f)
	}
	_ = vi.WriteFileSafe(path, []byte(b.String()))
}
