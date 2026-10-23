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
	// The real ReadFileAll truncates at max rather than failing — the
	// sidebar's title scan depends on that for large transcripts.
	if len(b) > max {
		b = b[:max]
	}
	return append([]byte(nil), b...), nil
}

func (f *fakeHost) DeleteFile(p string) error {
	if _, ok := f.files[p]; !ok {
		return errors.New("delete -2")
	}
	delete(f.files, p)
	return nil
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
	// Armed like runView's prompt, minus the registry: Chain stays nil so
	// the host tests ride the bitmap degrade, and the notdef report reads
	// 0 — honest, since the bitmap path counts no misses.
	v.armIME(nil)
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
		"bad magic":  "GOASSIST-CHAT v3\n@@user\nhi\n",
		"bad role":   "GOASSIST-CHAT v1\n@@system\nhi\n",
		"empty role": "GOASSIST-CHAT v1\n@@\nhi\n",
		"body first": "GOASSIST-CHAT v1\nhi\n@@user\nx\n",
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

	if !h.hasConsole(markerSend + "C0001") {
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
	v.restoreState([]byte{stateVer, 5, 0, 'C', '0', '0', '0', '3', 0, 0, 0, 0, 0, 0})
	v.applyRestore()
	if v.cur == nil || v.cur.name != "C0003" || len(v.cur.turns) != 2 {
		t.Fatalf("restore reopened %+v", v.cur)
	}
	if !h.hasConsole(markerRestored + "C0003 turns=2") {
		t.Fatalf("restore marker missing: %v", h.console)
	}
}

// --- codec v2: titles and the system turn (card #2920) ------------------------

func TestConvCodecV2TitleRoundTrip(t *testing.T) {
	c := &conversation{name: "C0001", title: "Trip plan", turns: []turn{
		{role: roleSystem, text: "You are a terse travel agent."},
		{role: roleUser, text: "three days in lisbon"},
		{role: roleModel, text: "day one: ..."},
	}}
	b := encodeConv(c)
	if !strings.HasPrefix(string(b), "GOASSIST-CHAT v2\n@@title Trip plan\n@@system\n") {
		t.Fatalf("v2 head wrong:\n%s", b)
	}
	d, ok := decodeConv(b)
	if !ok {
		t.Fatal("v2 round trip refused")
	}
	if d.title != "Trip plan" || len(d.turns) != 3 || d.turns[0].role != roleSystem {
		t.Fatalf("decoded %+v", d)
	}
	for i, w := range c.turns {
		if d.turns[i] != w {
			t.Fatalf("turn %d = %+v want %+v", i, d.turns[i], w)
		}
	}
}

// An untitled, preset-less conversation stays v1 — the M140b bytes are
// unchanged when nothing v2 is in play.
func TestConvCodecV2OnlyWhenNeeded(t *testing.T) {
	c := &conversation{name: "C0001", turns: []turn{
		{role: roleUser, text: "hi"},
	}}
	b := encodeConv(c)
	if !strings.HasPrefix(string(b), convMagicV1+"\n") {
		t.Fatalf("untitled conv must stay v1:\n%s", b)
	}
	d, ok := decodeConv(b)
	if !ok || d.title != "" {
		t.Fatalf("v1 decode: title=%q", d.title)
	}
	// A title alone promotes to v2 even without a preset.
	b2 := encodeConv(&conversation{name: "C0001", title: "x"})
	if !strings.HasPrefix(string(b2), convMagicV2+"\n@@title x\n") {
		t.Fatalf("title must promote to v2:\n%s", b2)
	}
}

func TestConvCodecV2Refuses(t *testing.T) {
	cases := map[string]string{
		"system in v1":     "GOASSIST-CHAT v1\n@@system\nbe terse\n@@user\nhi\n",
		"system not first": "GOASSIST-CHAT v2\n@@user\nhi\n@@system\nbe terse\n",
		"title over-long":  "GOASSIST-CHAT v2\n@@title " + strings.Repeat("t", convTitleMax+1) + "\n@@user\nhi\n",
		"title empty":      "GOASSIST-CHAT v2\n@@title \n@@user\nhi\n",
		"title not first":  "GOASSIST-CHAT v2\n@@user\nhi\n@@title late\n",
		"bare title":       "GOASSIST-CHAT v2\n@@title\n@@user\nhi\n",
	}
	for name, body := range cases {
		if _, ok := decodeConv([]byte(body)); ok {
			t.Fatalf("%s: accepted %q", name, body)
		}
	}
	// A v1 file keeps reading with an empty title (the "Conversation N"
	// fallback lives in displayTitle, not the codec).
	d, ok := decodeConv([]byte("GOASSIST-CHAT v1\n@@user\nhi\n"))
	if !ok || d.title != "" {
		t.Fatalf("v1 file must read with empty title: %+v", d)
	}
}

func TestConvTitleOfAndDisplay(t *testing.T) {
	b := encodeConv(&conversation{title: "Trip plan", turns: []turn{{role: roleUser, text: "x"}}})
	if got := convTitleOf(b); got != "Trip plan" {
		t.Fatalf("convTitleOf = %q", got)
	}
	if got := convTitleOf([]byte("GOASSIST-CHAT v1\n@@user\nx\n")); got != "" {
		t.Fatalf("v1 title must be empty: %q", got)
	}
	if got := convTitleOf([]byte("GOASSIST-CHAT v2\n@@title " + strings.Repeat("z", 60) + "\n")); got != "" {
		t.Fatalf("over-long title must read empty: %q", got)
	}
	if got := displayTitle("C0003", ""); got != "Conversation 3" {
		t.Fatalf("v1 fallback = %q", got)
	}
	if got := displayTitle("C0003", "Trip plan"); got != "Trip plan" {
		t.Fatalf("titled = %q", got)
	}
	if got := displayTitle("notes", ""); got != "notes" {
		t.Fatalf("dropped file = %q", got)
	}
}

// --- preset file codec ----------------------------------------------------------

func TestPresetsDecode(t *testing.T) {
	body := "GOASSIST-PRESETS v1\n@@coder\nYou are terse.\n @@not a marker\n@@poet\nAnswer in couplets.\n"
	ps, ok := decodePresets([]byte(body))
	if !ok || len(ps) != 2 {
		t.Fatalf("decode: ok=%v ps=%+v", ok, ps)
	}
	if ps[0].name != "coder" || ps[0].prompt != "You are terse.\n@@not a marker" {
		t.Fatalf("coder = %+v", ps[0])
	}
	if ps[1].name != "poet" || ps[1].prompt != "Answer in couplets." {
		t.Fatalf("poet = %+v", ps[1])
	}
}

func TestPresetsRefuse(t *testing.T) {
	long := strings.Repeat("p", presetPromptMax+1)
	many := "GOASSIST-PRESETS v1\n"
	for i := 0; i <= presetMax; i++ {
		many += "@@p" + is(i) + "\nx\n"
	}
	cases := map[string]string{
		"bad magic":    "GOASSIST-PRESETS v2\n@@a\nx\n",
		"empty":        "",
		"body first":   "GOASSIST-PRESETS v1\ntext\n@@a\nx\n",
		"dup name":     "GOASSIST-PRESETS v1\n@@a\nx\n@@a\ny\n",
		"empty name":   "GOASSIST-PRESETS v1\n@@\nx\n",
		"empty prompt": "GOASSIST-PRESETS v1\n@@a\n",
		"no presets":   "GOASSIST-PRESETS v1\n",
		"too many":     many,
		"prompt over":  "GOASSIST-PRESETS v1\n@@a\n" + long + "\n",
	}
	for name, body := range cases {
		if _, ok := decodePresets([]byte(body)); ok {
			t.Fatalf("%s: accepted", name)
		}
	}
}

func TestLoadPresets(t *testing.T) {
	h := newFakeHost()
	if ps, refused := loadPresets(h, "/host/ASSIST"); refused || ps != nil {
		t.Fatal("absent file is no-presets, not a refusal")
	}
	h.files["/host/ASSIST/PRESETS.TXT"] = []byte("GOASSIST-PRESETS v1\n@@coder\nTerse.\n")
	ps, refused := loadPresets(h, "/host/ASSIST")
	if refused || len(ps) != 1 || ps[0].name != "coder" {
		t.Fatalf("load: %+v refused=%v", ps, refused)
	}
	h.files["/host/ASSIST/PRESETS.TXT"] = []byte("garbage")
	if _, refused := loadPresets(h, "/host/ASSIST"); !refused {
		t.Fatal("a malformed file must refuse")
	}
}

// --- view: rename / delete / preset picker --------------------------------------

func TestRenameOpenConv(t *testing.T) {
	h := newFakeHost()
	v := newTestView(h, true)
	v.newConv(-1)
	v.applyRename("C0001", "Trip plan")
	if !h.hasConsole(markerRenamed + "C0001 title=Trip plan") {
		t.Fatalf("rename marker missing: %v", h.console)
	}
	if v.cur.title != "Trip plan" || v.titles["C0001"] != "Trip plan" {
		t.Fatalf("title not applied: %+v", v.cur)
	}
	d, ok := decodeConv(h.files["/host/ASSIST/C0001.CHAT"])
	if !ok || d.title != "Trip plan" {
		t.Fatalf("file head: %v", h.files["/host/ASSIST/C0001.CHAT"])
	}
	// Clearing the title drops the file back to v1.
	v.applyRename("C0001", "")
	if v.cur.title != "" {
		t.Fatalf("clear failed: %+v", v.cur)
	}
	d, ok = decodeConv(h.files["/host/ASSIST/C0001.CHAT"])
	if !ok || d.title != "" {
		t.Fatalf("cleared title must read back empty: %+v", d)
	}
	if !strings.HasPrefix(string(h.files["/host/ASSIST/C0001.CHAT"]), convMagicV1+"\n") {
		t.Fatalf("cleared title must demote to v1:\n%s", h.files["/host/ASSIST/C0001.CHAT"])
	}
}

func TestRenameClosedConv(t *testing.T) {
	h := newFakeHost()
	v := newTestView(h, true)
	v.convs = []string{"C0001", "C0002"}
	h.files["/host/ASSIST/C0002.CHAT"] = encodeConv(&conversation{
		name: "C0002",
		turns: []turn{
			{role: roleUser, text: "before"},
			{role: roleModel, text: "the answer"},
		},
	})
	v.cur = &conversation{name: "C0001"}
	v.applyRename("C0002", "Trip plan")
	d, ok := decodeConv(h.files["/host/ASSIST/C0002.CHAT"])
	if !ok || d.title != "Trip plan" || len(d.turns) != 2 {
		t.Fatalf("closed conv retitle lost turns: %+v", d)
	}
	if v.titles["C0002"] != "Trip plan" {
		t.Fatalf("titles map: %v", v.titles)
	}
	// The over-bound refusal leaves the file untouched.
	v.applyRename("C0002", strings.Repeat("x", convTitleMax+1))
	if !h.hasConsole(markerRenBad + "C0002") {
		t.Fatalf("refusal marker missing: %v", h.console)
	}
	d, _ = decodeConv(h.files["/host/ASSIST/C0002.CHAT"])
	if d == nil || d.title != "Trip plan" {
		t.Fatal("a refused rename must not touch the file")
	}
	// An undecodable file is never clobbered.
	h.files["/host/ASSIST/C0003.CHAT"] = []byte("not a conv")
	v.convs = append(v.convs, "C0003")
	v.applyRename("C0003", "x")
	if string(h.files["/host/ASSIST/C0003.CHAT"]) != "not a conv" {
		t.Fatal("an unreadable file was clobbered")
	}
}

func TestDeleteConvRefreshesAndOpensNext(t *testing.T) {
	h := newFakeHost()
	v := newTestView(h, true)
	for _, n := range []string{"C0001", "C0002", "C0003"} {
		h.files["/host/ASSIST/"+n+".CHAT"] = encodeConv(&conversation{
			name:  n,
			turns: []turn{{role: roleUser, text: "in " + n}},
		})
	}
	v.convs = []string{"C0001", "C0002", "C0003"}
	v.loadTitles()
	v.openConv("C0002")
	v.deleteConv("C0002")
	if h.FileExists("/host/ASSIST/C0002.CHAT") {
		t.Fatal("the file must be gone")
	}
	if !h.hasConsole(markerDeleted + "C0002") {
		t.Fatalf("delete marker missing: %v", h.console)
	}
	if len(v.convs) != 2 || v.convs[0] != "C0001" || v.convs[1] != "C0003" {
		t.Fatalf("list: %v", v.convs)
	}
	// The open conversation moves to the next row.
	if v.cur == nil || v.cur.name != "C0003" {
		t.Fatalf("open next: %+v", v.cur)
	}
	// Deleting the tail opens the previous one.
	v.deleteConv("C0003")
	if v.cur == nil || v.cur.name != "C0001" {
		t.Fatalf("tail delete: %+v", v.cur)
	}
	// Deleting the last leaves nothing open.
	v.deleteConv("C0001")
	if v.cur != nil || len(v.convs) != 0 {
		t.Fatalf("empty store: cur=%+v convs=%v", v.cur, v.convs)
	}
}

func TestDeleteClosedConvKeepsOpen(t *testing.T) {
	h := newFakeHost()
	v := newTestView(h, true)
	h.files["/host/ASSIST/C0001.CHAT"] = encodeConv(&conversation{
		name: "C0001", turns: []turn{{role: roleUser, text: "keep me"}},
	})
	h.files["/host/ASSIST/C0002.CHAT"] = encodeConv(&conversation{
		name: "C0002", turns: []turn{{role: roleUser, text: "drop me"}},
	})
	v.convs = []string{"C0001", "C0002"}
	v.openConv("C0001")
	v.deleteConv("C0002")
	if v.cur == nil || v.cur.name != "C0001" {
		t.Fatalf("closed delete must not move the open conv: %+v", v.cur)
	}
	if h.FileExists("/host/ASSIST/C0002.CHAT") || len(v.convs) != 1 {
		t.Fatal("delete did not land")
	}
}

// The confirm gate: delete only lands when the dialog's answer is Yes.
func TestDeleteBehindConfirm(t *testing.T) {
	h := newFakeHost()
	v := newTestView(h, true)
	h.files["/host/ASSIST/C0001.CHAT"] = encodeConv(&conversation{
		name: "C0001", turns: []turn{{role: roleUser, text: "x"}},
	})
	v.convs = []string{"C0001"}
	v.askDelete("C0001")
	if v.dlg == nil || v.dlg.Kind != appkit.ConfirmDialog {
		t.Fatal("delete must raise a confirm")
	}
	// A No keeps the file.
	v.dlg.Result = "No"
	v.applyDialog()
	if !h.FileExists("/host/ASSIST/C0001.CHAT") {
		t.Fatal("a No answer must not delete")
	}
	v.askDelete("C0001")
	v.dlg.Result = "Yes"
	v.applyDialog()
	if h.FileExists("/host/ASSIST/C0001.CHAT") {
		t.Fatal("a Yes answer must delete")
	}
}

func TestPresetPickNewConv(t *testing.T) {
	h := newFakeHost()
	h.files["/host/ASSIST/PRESETS.TXT"] = []byte(
		"GOASSIST-PRESETS v1\n@@coder\nYou are terse.\n")
	v := newTestView(h, true)
	var refused bool
	v.presets, refused = loadPresets(h, v.dir)
	if refused || len(v.presets) != 1 {
		t.Fatal("preset load failed")
	}
	// The New gesture raises the picker rather than opening a conv.
	v.startNewConv()
	if v.pick == nil || v.cur != nil {
		t.Fatal("the picker must own the new-conversation gesture")
	}
	// Down moves onto the preset, Enter chooses: conv carries @@system.
	v.pick.sel = 1
	v.finishPick(1)
	if v.cur == nil || v.cur.name != "C0001" {
		t.Fatalf("pick did not open a conv: %+v", v.cur)
	}
	if len(v.cur.turns) != 1 || v.cur.turns[0].role != roleSystem ||
		v.cur.turns[0].text != "You are terse." {
		t.Fatalf("system turn wrong: %+v", v.cur.turns)
	}
	if !h.hasConsole("goassist: conv new C0001 preset=coder") {
		t.Fatalf("preset marker missing: %v", h.console)
	}
	d, ok := decodeConv(h.files["/host/ASSIST/C0001.CHAT"])
	if !ok || d.turns[0].role != roleSystem {
		t.Fatal("the preset must persist in the file")
	}
	// Esc cancels without creating anything.
	v.pick = &presetPick{}
	v.finishPick(-1)
	if len(v.convs) != 1 {
		t.Fatal("a cancelled pick must not create a conversation")
	}
}

// A send into an empty store parks behind the picker, then lands in the
// chosen persona's conversation.
func TestSendBehindPresetPick(t *testing.T) {
	h := newFakeHost()
	h.files["/host/ASSIST/PRESETS.TXT"] = []byte(
		"GOASSIST-PRESETS v1\n@@coder\nYou are terse.\n")
	oldPoll := pollEvent
	pollEvent = scriptedPoll(nil)
	defer func() { pollEvent = oldPoll }()

	v := newTestView(h, true)
	v.presets, _ = loadPresets(h, v.dir)
	v.prompt.SetValue("hi there")
	v.send()
	if v.pick == nil || v.cur != nil || v.pendingSend != "hi there" {
		t.Fatalf("the send must park behind the picker: %+v", v.cur)
	}
	v.finishPick(1)
	if v.cur == nil || v.cur.turns[0].role != roleSystem {
		t.Fatalf("preset turn missing: %+v", v.cur)
	}
	if v.cur.turns[1].role != roleUser || v.cur.turns[1].text != "hi there" {
		t.Fatalf("the parked send lost its text: %+v", v.cur.turns)
	}
	if !h.hasConsole(markerAnswer) {
		t.Fatalf("no answer streamed: %v", h.console)
	}
}

// The preset reaches the model prompt as the system message.
func TestPresetDrivesSystemPrompt(t *testing.T) {
	h := newFakeHost()
	e := &engine{stub: true}
	if err := e.ensure(h); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	defer e.close()
	c := &conversation{turns: []turn{
		{role: roleSystem, text: "You are a terse travel agent."},
		{role: roleUser, text: "lisbon"},
	}}
	ids := e.prompt(c)
	text := e.model.Tokenizer().Decode(ids)
	if !strings.Contains(text, "You are a terse travel agent.") {
		t.Fatalf("preset not in prompt: %q", text)
	}
	if strings.Contains(text, sysPromptDefault) {
		t.Fatal("the default persona must not double up")
	}
	// Without a preset the default stays byte-identical.
	ids = e.prompt(&conversation{turns: []turn{{role: roleUser, text: "x"}}})
	if !strings.Contains(e.model.Tokenizer().Decode(ids), sysPromptDefault) {
		t.Fatal("default persona missing")
	}
}

// --- save_state v2: the blob carries the title ---------------------------------

func TestStateBlobV2CarriesTitle(t *testing.T) {
	h := newFakeHost()
	v := newTestView(h, true)
	v.cur = &conversation{name: "C0009", title: "Trip plan"}
	v.scroll = 7
	b := v.saveState()

	w := newTestView(h, true)
	w.restoreState(b)
	if !w.restOK || w.restBad {
		t.Fatal("v2 blob refused")
	}
	if w.restName != "C0009" || w.restTitle != "Trip plan" || w.restScroll != 7 {
		t.Fatalf("restored %q/%q/%d", w.restName, w.restTitle, w.restScroll)
	}
	// The title sits inside the blob itself.
	if !bytes.Contains(b, []byte("Trip plan")) {
		t.Fatalf("blob lacks the title: %v", b)
	}
}

func TestStateBlobV2Refuses(t *testing.T) {
	v := newTestView(newFakeHost(), true)
	// A v1-era blob must refuse — the layout grew a field.
	v.restoreState([]byte{1, 5, 0, 'C', '0', '0', '0', '9', 0, 0, 0, 0})
	if !v.restBad {
		t.Fatal("a v1 blob must be refused")
	}
	v2 := newTestView(newFakeHost(), true)
	v2.restoreState(v2.saveState()[:6]) // torn inside the title field
	if !v2.restBad {
		t.Fatal("a torn v2 blob must be refused")
	}
	v3 := newTestView(newFakeHost(), true)
	bad := v3.saveState()
	bad[0] = 9
	v3.restoreState(bad)
	if !v3.restBad {
		t.Fatal("a bad-version v2 blob must be refused")
	}
}

// The blob's title disagreeing with the file's is a named mismatch, never
// a silent pick.
func TestRestoreTitleMismatchIsNamed(t *testing.T) {
	h := newFakeHost()
	h.files["/host/ASSIST/C0003.CHAT"] = encodeConv(&conversation{
		name:  "C0003",
		title: "Trip plan",
		turns: []turn{{role: roleUser, text: "before"}},
	})
	v := newTestView(h, true)
	v.convs = []string{"C0003"}
	// Blob claims "Road trip"; the file says "Trip plan".
	blob := append([]byte{stateVer, 5, 0}, []byte("C0003")...)
	blob = append(blob, 9, 0)
	blob = append(blob, []byte("Road trip")...)
	blob = append(blob, 0, 0, 0, 0)
	v.restoreState(blob)
	v.applyRestore()
	if !h.hasConsole(markerMismatch) {
		t.Fatalf("mismatch marker missing: %v", h.console)
	}
	if v.cur.title != "Trip plan" {
		t.Fatalf("the file's title wins: %+v", v.cur)
	}
	if !h.hasConsole(markerRestored + "C0003 turns=1 scroll=0 title=Trip plan") {
		t.Fatalf("restored marker missing: %v", h.console)
	}
}

// --- prompt composition (M178b #3145) ---------------------------------------

// keyDown builds the key event the seat forwards for one press: usage in
// Arg0, the translated symbol in Arg1, modifiers in Flags.
func keyDown(usage uint32, sym rune, flags uint16) vi.Event {
	return vi.Event{Kind: vi.EvKeyDown, Arg0: usage, Arg1: uint32(sym), Flags: flags}
}

func TestViewIMEComposesAndCommits(t *testing.T) {
	h := newFakeHost()
	v := newTestView(h, true)

	// The toggle chord arms the prompt's composer; the serial line says so.
	if !v.key(keyDown(0x0d, 0, vi.ModCtrl)) {
		t.Fatal("ctrl-j must be consumed as the composition toggle")
	}
	if !h.hasConsole(markerIMEOn) || !v.prompt.Composing() {
		t.Fatalf("ime on marker/composer state missing: %v", h.console)
	}
	// n,i,h,o,n,g,o paints the hiragana pre-edit, Return commits it.
	for _, r := range "nihongo" {
		v.key(keyDown(0x04, r, 0))
	}
	if v.prompt.Preedit() != "にほんご" {
		t.Fatalf("preedit = %q, want にほんご", v.prompt.Preedit())
	}
	v.key(keyDown(0x28, 0, 0)) // return commits, does not send
	if v.prompt.Value() != "にほんご" || v.prompt.Preedit() != "" {
		t.Fatalf("prompt = %q preedit = %q", v.prompt.Value(), v.prompt.Preedit())
	}
	if !h.hasConsole(markerIMECommit + "にほんご") {
		t.Fatalf("commit marker missing: %v", h.console)
	}
	if !h.hasConsole(markerNotdef + "0") {
		t.Fatalf("notdef report missing: %v", h.console)
	}
	if h.hasConsole(markerSend) {
		t.Fatal("the committing Return must not have sent")
	}
	// The settled Return sends the kana prompt like any other text.
	v.key(keyDown(0x28, 0, 0))
	if !h.hasConsole(markerSend + "C0001") {
		t.Fatalf("send marker missing: %v", h.console)
	}
	d, ok := decodeConv(h.files["/host/ASSIST/C0001.CHAT"])
	if !ok || len(d.turns) == 0 || d.turns[0].text != "にほんご" {
		t.Fatalf("saved turn lost the kana: %+v", d)
	}
}

func TestViewIMECycleAndCancel(t *testing.T) {
	h := newFakeHost()
	v := newTestView(h, true)
	v.key(keyDown(0x0d, 0, vi.ModCtrl))
	for _, r := range "sushi" {
		v.key(keyDown(0x04, r, 0))
	}
	// Space cycles the candidate: katakana commits.
	v.key(keyDown(0x2c, ' ', 0))
	if v.prompt.Preedit() != "スシ" {
		t.Fatalf("cycle: preedit = %q", v.prompt.Preedit())
	}
	v.key(keyDown(0x28, 0, 0))
	if !h.hasConsole(markerIMECommit + "スシ") {
		t.Fatalf("katakana commit missing: %v", h.console)
	}
	// Escape on a live pre-edit cancels the composition — it is not the
	// app's close gesture.
	for _, r := range "kana" {
		v.key(keyDown(0x04, r, 0))
	}
	v.key(keyDown(0x29, 0, 0))
	if v.prompt.Preedit() != "" || v.wantQuit {
		t.Fatalf("escape must cancel the pre-edit, not the window: %v", v.wantQuit)
	}
	// Toggling off reports the flip and returns to plain typing.
	v.key(keyDown(0x0d, 0, vi.ModCtrl))
	if !h.hasConsole(markerIMEOff) || v.prompt.Composing() {
		t.Fatalf("ime off missing: %v", h.console)
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
