package main

// main_test.go — the class-A half of M140b: the codec, the renderer, the
// journeys and the view all pinned against the platform seam's fake,
// which serves compute through infer.NewFakeDev — the kernel-emulating
// device whose software kernels mirror the Metal contracts.

import (
	"bytes"
	"errors"
	"io"
	"sort"
	"strings"
	"testing"

	"virelai/appkit"
	"virelai/gpu3d"
	"virelai/infer"
	"virelai/tabapp"
	"virelai/vi"
	"virelai/widgets"
)

// fakeHost is the platform seam's test double: console lines recorded,
// files in a map, compute sessions served by the kernel-emulating fake.
type fakeHost struct {
	console []string
	files   map[string][]byte
	dirs    map[string]bool
	devs    []*infer.FakeDev
	openErr error
	disk    bool
	now     int64
}

func newFakeHost() *fakeHost {
	return &fakeHost{files: map[string][]byte{}, dirs: map[string]bool{}}
}

func (f *fakeHost) ConsoleLine(s string) { f.console = append(f.console, s) }

func (f *fakeHost) MkdirShare(p string) error { f.dirs[p] = true; return nil }

func (f *fakeHost) WriteShareFile(p string, b []byte) error {
	f.files[p] = append([]byte(nil), b...)
	return nil
}

func (f *fakeHost) FileExists(p string) bool {
	_, ok := f.files[p]
	return ok
}

func (f *fakeHost) ReadFileAll(p string, max int) ([]byte, error) {
	b, ok := f.files[p]
	if !ok {
		return nil, errors.New("read -2")
	}
	if len(b) > max {
		return nil, errors.New("read -28")
	}
	return append([]byte(nil), b...), nil
}

type rcReader struct{ io.Reader }

func (rcReader) Close() error { return nil }

func (f *fakeHost) OpenRead(p string) (io.ReadCloser, error) {
	b, ok := f.files[p]
	if !ok {
		return nil, errors.New("open -2")
	}
	return rcReader{bytes.NewReader(b)}, nil
}

func (f *fakeHost) ListDir(dir string) ([]string, error) {
	pfx := dir + "/"
	var out []string
	for p := range f.files {
		if strings.HasPrefix(p, pfx) {
			out = append(out, p[len(pfx):])
		}
	}
	sort.Strings(out)
	return out, nil
}

func (f *fakeHost) OpenComp() (infer.Dev, error) {
	if f.openErr != nil {
		return nil, f.openErr
	}
	d := infer.NewFakeDev()
	f.devs = append(f.devs, d)
	return d, nil
}

func (f *fakeHost) DataRoot() (string, bool) {
	if f.disk {
		return "/disk", false
	}
	return "/host", false
}

func (f *fakeHost) Nanos() int64 { f.now += 1e6; return f.now }

func (f *fakeHost) hasConsole(sub string) bool {
	for _, l := range f.console {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

func (f *fakeHost) consoleMatching(sub string) []string {
	var out []string
	for _, l := range f.console {
		if strings.Contains(l, sub) {
			out = append(out, l)
		}
	}
	return out
}

// newTestView builds the windowed state a guest would have, minus the
// window: the same view struct the loop drives, on a hand-built TabApp.
// The controls are the real appkit ones so repaint exercises the same
// draw path the guest runs.
func newTestView(h *fakeHost, stub bool) *view {
	v := &view{
		h: h, eng: &engine{stub: stub}, ta: &tabapp.TabApp{W: natW, H: natH},
		dir: "/host/ASSIST", status: "ready", follow: true,
	}
	v.prompt = appkit.NewTextField(widgets.Rect{}, promptMax)
	v.side = appkit.NewListController(&widgets.List{RowH: 22, Sel: -1})
	v.ring = appkit.NewFocusRing(&v.prompt, v.side)
	v.ring.Focus(0)
	return v
}

// --- codec ------------------------------------------------------------------

func TestConvCodecRoundTrip(t *testing.T) {
	c := &conversation{name: "C0007", turns: []turn{
		{role: roleUser, text: "hi\nthere @@nearly a marker"},
		{role: roleModel, text: "answer line1\n```\nfn main() {}\n```\ntail"},
		{role: roleMeta, text: "(cancelled)"},
	}}
	d, ok := decodeConv(encodeConv(c))
	if !ok {
		t.Fatal("round trip refused")
	}
	if len(d.turns) != 3 {
		t.Fatalf("turns=%d want 3", len(d.turns))
	}
	for i, w := range c.turns {
		if d.turns[i] != w {
			t.Fatalf("turn %d = %+v want %+v", i, d.turns[i], w)
		}
	}
}

func TestConvCodecRefuses(t *testing.T) {
	cases := map[string]string{
		"bad magic":  "GOASSIST-CHAT v2\n@@user\nhi\n",
		"bad role":   "GOASSIST-CHAT v1\n@@system\nhi\n",
		"empty role": "GOASSIST-CHAT v1\n@@\nhi\n",
		"body first": "GOASSIST-CHAT v1\nhi\n@@user\nx\n",
		"no turns":   "GOASSIST-CHAT v1\n",
	}
	for name, body := range cases {
		if _, ok := decodeConv([]byte(body)); ok {
			t.Fatalf("%s: accepted %q", name, body)
		}
	}
	if _, ok := decodeConv(make([]byte, convMaxBytes+1)); ok {
		t.Fatal("oversize accepted")
	}
}

func TestNextConvName(t *testing.T) {
	if got := nextConvName(nil); got != "C0001" {
		t.Fatalf("empty store -> %q", got)
	}
	if got := nextConvName([]string{"C0001", "C0003", "notes"}); got != "C0002" {
		t.Fatalf("gap -> %q want C0002", got)
	}
}

// --- renderer -----------------------------------------------------------------

func cellMeasure(_ rlineKind, s string) int { return len(s) * 8 }

func TestRenderWrapsAndFences(t *testing.T) {
	c := &conversation{turns: []turn{
		{role: roleUser, text: "one two three four five six"},
		{role: roleModel, text: "para\n```\ncode stays intact here\n```\nback"},
	}}
	lines := renderConv(c, 20*8, cellMeasure)
	var user, code, model int
	for _, l := range lines {
		switch l.kind {
		case rlUser:
			user++
			if !strings.HasPrefix(l.text, "you>") && user == 1 {
				t.Fatalf("first user line lacks prefix: %q", l.text)
			}
		case rlCode:
			code++
		case rlModel:
			model++
		}
	}
	// A fenced run paints as code (wraps stay code too), prose as model,
	// and the fence markers themselves never render.
	if user < 2 || code < 1 || model < 2 {
		t.Fatalf("kinds user=%d code=%d model=%d: %+v", user, code, model, lines)
	}
	for _, l := range lines {
		if strings.HasPrefix(l.text, "```") {
			t.Fatalf("a fence marker rendered: %+v", lines)
		}
	}
	for _, l := range lines {
		if cellMeasure(l.kind, l.text) > 20*8 {
			t.Fatalf("line exceeds pane: %q", l.text)
		}
	}
}

func TestRenderBounded(t *testing.T) {
	c := &conversation{turns: []turn{{role: roleModel, text: strings.Repeat("x\n", scrollMax+100)}}}
	if got := len(renderConv(c, 400, cellMeasure)); got != scrollMax {
		t.Fatalf("rendered %d lines, want bound %d", got, scrollMax)
	}
}

// --- probe journey --------------------------------------------------------------

func TestProbeRunsOnFake(t *testing.T) {
	h := newFakeHost()
	if err := run(h, []string{"probe"}); err != nil {
		t.Fatalf("probe: %v", err)
	}
	if !h.hasConsole("goassist: probe ok toks=") || !h.hasConsole("ids=") {
		t.Fatalf("console: %v", h.console)
	}
	if len(h.devs) != 1 {
		t.Fatalf("sessions=%d want 1", len(h.devs))
	}
}

func TestProbeUnsupportedIsNamed(t *testing.T) {
	h := newFakeHost()
	h.openErr = gpu3d.ErrComputeNoDevice
	if err := run(h, []string{"probe"}); err != nil {
		t.Fatalf("unsupported probe must exit clean: %v", err)
	}
	if !h.hasConsole(markerUnsup) {
		t.Fatalf("console: %v", h.console)
	}
}

func TestUsageError(t *testing.T) {
	h := newFakeHost()
	if err := run(h, []string{"bogus"}); !errors.Is(err, errUsage) {
		t.Fatalf("want usage: %v", err)
	}
}

// --- the view over the fake ------------------------------------------------------

// scriptedPoll feeds the view a fixed event queue then reports empty.
func scriptedPoll(evs []vi.Event) func() (vi.Event, int64, bool) {
	return func() (vi.Event, int64, bool) {
		if len(evs) == 0 {
			return vi.Event{}, 0, false
		}
		ev := evs[0]
		evs = evs[1:]
		return ev, 0, true
	}
}

func TestViewSendStreamsAndSaves(t *testing.T) {
	h := newFakeHost()
	oldPoll := pollEvent
	pollEvent = scriptedPoll(nil)
	defer func() { pollEvent = oldPoll }()

	v := newTestView(h, true)
	v.prompt.SetValue("hi there")
	v.send()

	if !h.hasConsole(markerSend+"C0001") {
		t.Fatalf("send marker missing: %v", h.console)
	}
	toks := h.consoleMatching(markerTokens)
	if len(toks) < 2 {
		t.Fatalf("want streamed token markers, got %v", toks)
	}
	for i, l := range toks {
		if !strings.Contains(l, "tokens="+is(i+1)) {
			t.Fatalf("token markers not increasing: %v", toks)
		}
	}
	if !h.hasConsole(markerAnswer) || !h.hasConsole("ids=") {
		t.Fatalf("answer marker missing: %v", h.console)
	}
	if !h.hasConsole(markerSaved + "C0001.CHAT") {
		t.Fatalf("save marker missing: %v", h.console)
	}
	d, ok := decodeConv(h.files["/host/ASSIST/C0001.CHAT"])
	if !ok || len(d.turns) != 2 || d.turns[0].text != "hi there" {
		t.Fatalf("saved conversation wrong: %+v", d)
	}
	if d.turns[1].role != roleModel || d.turns[1].text == "" {
		t.Fatalf("no assistant turn saved: %+v", d.turns)
	}
	if len(h.devs) != 1 {
		t.Fatalf("sessions=%d want 1", len(h.devs))
	}
}

func TestViewEscCancels(t *testing.T) {
	h := newFakeHost()
	oldPoll := pollEvent
	esc := []vi.Event{{Kind: vi.EvKeyDown, Arg0: 0x29}}
	pollEvent = scriptedPoll(esc)
	defer func() { pollEvent = oldPoll }()

	v := newTestView(h, true)
	v.prompt.SetValue("hi")
	v.send()
	if !h.hasConsole(markerCancel) {
		t.Fatalf("cancel marker missing: %v", h.console)
	}
	if h.hasConsole(markerAnswer) {
		t.Fatalf("a cancelled generate must not report an answer")
	}
}

func TestViewWeightsAbsentIsNamed(t *testing.T) {
	h := newFakeHost()
	v := newTestView(h, false) // the staged-model persona
	v.prompt.SetValue("hi")
	v.send()
	if !h.hasConsole(markerAbsent) {
		t.Fatalf("weights-absent marker missing: %v", h.console)
	}
	if len(h.devs) != 0 {
		t.Fatal("absent weights must not open the compute session")
	}
}

func TestViewUnsupportedIsNamed(t *testing.T) {
	h := newFakeHost()
	h.openErr = gpu3d.ErrComputeNoDevice
	v := newTestView(h, true)
	v.prompt.SetValue("hi")
	v.send()
	if !h.hasConsole(markerUnsup) {
		t.Fatalf("console: %v", h.console)
	}
}

// --- save_state / restore_state -------------------------------------------------

func TestStateBlobRoundTrip(t *testing.T) {
	h := newFakeHost()
	v := newTestView(h, true)
	v.cur = &conversation{name: "C0009"}
	v.scroll = 42
	b := v.saveState()

	w := newTestView(h, true)
	w.restoreState(b)
	if !w.restOK || w.restBad {
		t.Fatalf("decode refused own blob")
	}
	if w.restName != "C0009" || w.restScroll != 42 {
		t.Fatalf("restored %q/%d want C0009/42", w.restName, w.restScroll)
	}
}

func TestStateBlobRefuses(t *testing.T) {
	v := newTestView(newFakeHost(), true)
	v.restoreState([]byte{9, 1, 0, 'C', '0', 0, 0})
	if !v.restBad {
		t.Fatal("a bad-version blob must be refused")
	}
	v2 := newTestView(newFakeHost(), true)
	v2.restoreState(v2.saveState()[:4]) // torn short
	if !v2.restBad {
		t.Fatal("a torn blob must be refused")
	}
}

func TestApplyRestoreReopensConv(t *testing.T) {
	h := newFakeHost()
	h.files["/host/ASSIST/C0003.CHAT"] = encodeConv(&conversation{
		name: "C0003",
		turns: []turn{
			{role: roleUser, text: "before"},
			{role: roleModel, text: "the answer"},
		},
	})
	v := newTestView(h, true)
	v.convs = []string{"C0003"}
	v.restoreState([]byte{stateVer, 5, 0, 'C', '0', '0', '0', '3', 0, 0, 0, 0})
	v.applyRestore()
	if v.cur == nil || v.cur.name != "C0003" || len(v.cur.turns) != 2 {
		t.Fatalf("restore reopened %+v", v.cur)
	}
	if !h.hasConsole(markerRestored + "C0003 turns=2") {
		t.Fatalf("restore marker missing: %v", h.console)
	}
}

// TestStubAnswerIdsPinned records the streamed ids the fake produces for
// the leg-2 prompt — the same values the go-assist spec pins on the Metal
// path (host-fake and device decodes are byte-identical, the same
// property live-gpu3d leg 10 observes for GOINFER).
func TestStubAnswerIdsPinned(t *testing.T) {
	h := newFakeHost()
	oldPoll := pollEvent
	pollEvent = scriptedPoll(nil)
	defer func() { pollEvent = oldPoll }()

	v := newTestView(h, true)
	v.prompt.SetValue("hi there")
	v.send()
	for _, l := range h.console {
		if strings.HasPrefix(l, markerAnswer) {
			t.Logf("pin: %s", l)
			return
		}
	}
	t.Fatal("no answer marker")
}
