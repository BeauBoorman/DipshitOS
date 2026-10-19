package main

import (
	"strings"
	"testing"

	"virelai/hostint"
	"virelai/vi"
)

// dropOpenFixture stubs the dispatch's two seams — the head read (the
// share bytes mime.Open sniffs) and the exec arm — so the whole
// name -> mime -> binary routing is pinned on the host. The returned
// pointer's slice grows with each exec the dispatch runs.
func dropOpenFixture(t *testing.T, heads map[string][]byte) *[][2]string {
	t.Helper()
	oldRead, oldExec := dropReadFile, execApp
	got := new([][2]string)
	dropReadFile = func(path string, max int) ([]byte, int64) {
		b, ok := heads[path]
		if !ok {
			return nil, -vi.ErrENOENT
		}
		if len(b) > max {
			b = b[:max]
		}
		return b, int64(len(b))
	}
	execApp = func(bin string, args ...string) (int64, error) {
		arg := ""
		if len(args) > 0 {
			arg = args[0]
		}
		*got = append(*got, [2]string{bin, arg})
		return 42, nil
	}
	t.Cleanup(func() { dropReadFile, execApp = oldRead, oldExec })
	return got
}

func TestDropNameOK(t *testing.T) {
	for _, name := range []string{
		"PHOTO.QOI", "odd_name_.qoi", "DUP-2.QOI", "A", "9.txt",
		strings.Repeat("N", 48),
	} {
		if !dropNameOK(name) {
			t.Fatalf("dropNameOK(%q) = false want true", name)
		}
	}
	for _, name := range []string{
		"", "..", ".", ".hidden", "A/B", "A\\B", "A B", "A\nB",
		"A:B", "é.QOI", strings.Repeat("N", 49),
	} {
		if dropNameOK(name) {
			t.Fatalf("dropNameOK(%q) = true want false", name)
		}
	}
}

func TestDropOpenRoutesBySniff(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	execs := dropOpenFixture(t, map[string][]byte{
		"/host/INBOX/PHOTO.QOI": []byte("qoif" + strings.Repeat("x", 12)),
		"/host/INBOX/NOTES.TXT": []byte("plain hello\n"),
		"/host/INBOX/SONG.WAV":  []byte("RIFF\x04\x00\x00\x00WAVEfmt "),
		"/host/INBOX/PIC.PNG":   []byte("\x89PNG\r\n\x1a\n" + strings.Repeat("x", 8)),
		"/host/INBOX/DOC.MD":    []byte("# title\n\ntext"),
	})
	dropOpen("PHOTO.QOI")
	dropOpen("NOTES.TXT")
	dropOpen("SONG.WAV")
	dropOpen("PIC.PNG")
	dropOpen("DOC.MD")
	want := [][2]string{
		{"GOVIEW.ELF", "/host/INBOX/PHOTO.QOI"},
		{"GOEDIT.ELF", "/host/INBOX/NOTES.TXT"},
		{"GOSOUND.ELF", "/host/INBOX/SONG.WAV"},
		{"GOVIEW.ELF", "/host/INBOX/PIC.PNG"},
		{"GOEDIT.ELF", "/host/INBOX/DOC.MD"},
	}
	got := *execs
	if len(got) != len(want) {
		t.Fatalf("execs = %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("exec[%d] = %v want %v", i, got[i], want[i])
		}
	}
	if !f.hasLog(MarkerDropOpen + "name=SONG.WAV app=GOSOUND.ELF") {
		t.Fatalf("missing drop-open marker: %v", f.logs)
	}
}

func TestDropOpenNoHandlerFallsBackToGofiles(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	execs := dropOpenFixture(t, map[string][]byte{
		// An ELF payload: the binary type has no registered handler.
		"/host/INBOX/TOOL.ELF": []byte("\x7fELF" + strings.Repeat("x", 11)),
		// A zip: the archive type registers nothing either.
		"/host/INBOX/PACK.ZIP": []byte("PK\x03\x04" + strings.Repeat("x", 12)),
	})
	dropOpen("TOOL.ELF")
	dropOpen("PACK.ZIP")
	want := [][2]string{
		{"GOFILES.ELF", "/host/INBOX"},
		{"GOFILES.ELF", "/host/INBOX"},
	}
	got := *execs
	if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("execs = %v want %v", got, want)
	}
	if !f.hasLog(MarkerDropOpen + "name=TOOL.ELF app=GOFILES.ELF") {
		t.Fatalf("missing fallback marker: %v", f.logs)
	}
}

func TestDropOpenGoneWhenUnreadable(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	// The heads map is empty: every read is ENOENT — the file the record
	// announced vanished between drop and click.
	execs := dropOpenFixture(t, map[string][]byte{})
	dropOpen("VANISHED.QOI")
	if len(*execs) != 0 {
		t.Fatalf("exec ran on a vanished file: %v", *execs)
	}
	if !f.hasLog("refuse lane=drop reason=" + hostint.RefuseGone) {
		t.Fatalf("missing gone refusal: %v", f.logs)
	}
}

func TestDropOpenNameRejected(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	execs := dropOpenFixture(t, map[string][]byte{
		"/host/INBOX/A.QOI": []byte("qoif" + strings.Repeat("x", 12)),
	})
	for _, name := range []string{"../A.QOI", "A/B.QOI", ".hidden", "A B.QOI"} {
		dropOpen(name)
	}
	if len(*execs) != 0 {
		t.Fatalf("a bad name dispatched: %v", *execs)
	}
	count := 0
	for _, l := range f.logs {
		if strings.Contains(l, "refuse lane=drop reason="+hostint.RefuseNameRejected) {
			count++
		}
	}
	if count != 4 {
		t.Fatalf("name_rejected count = %d want 4: %v", count, f.logs)
	}
}

// The whole gesture: a verified DROP's toast click dispatches the
// announced file through the mime table — and resolves the report on
// both surfaces, like every action toast.
func TestDropToastClickOpens(t *testing.T) {
	resetNotify(t)
	resetRefusal(t)
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	f.plantArmed(0xBEEF, hostint.LaneDrop)
	hostintSeatTick()
	execs := dropOpenFixture(t, map[string][]byte{
		"/host/INBOX/PHOTO.QOI": []byte("qoif" + strings.Repeat("x", 12)),
	})

	f.plantDrop(0xBEEF, 1, "PHOTO.QOI", 4100)
	hostintSeatTick()
	if len(notifyQueue) != 1 {
		t.Fatalf("queue = %+v", notifyQueue)
	}
	toast := notifyQueue[0]
	if toast.action != notifyActionDropOpen || toast.snap != "PHOTO.QOI" {
		t.Fatalf("drop toast = %+v want open-drop bound to PHOTO.QOI", toast)
	}
	if len(notifyCenter) != 1 || notifyCenter[0].action != notifyActionDropOpen ||
		notifyCenter[0].snap != "PHOTO.QOI" {
		t.Fatalf("center row = %+v want the same binding", notifyCenter[0])
	}

	notifyClicked(112, 702)
	if len(*execs) != 1 ||
		(*execs)[0] != [2]string{"GOVIEW.ELF", "/host/INBOX/PHOTO.QOI"} {
		t.Fatalf("execs = %v want GOVIEW on the INBOX path", *execs)
	}
	if !f.hasLog(MarkerDropOpen + "name=PHOTO.QOI app=GOVIEW.ELF") {
		t.Fatalf("missing drop-open marker: %v", f.logs)
	}
	if notifyCount() != 0 || len(notifyCenter) != 0 {
		t.Fatalf("a resolved report left surfaces: %d %d",
			notifyCount(), len(notifyCenter))
	}
}

// Enter on the notify-center row runs the same dispatch — the row and the
// toast share one binding, so a DND-held notice stays actionable.
func TestDropCenterRowOpensHeldNotice(t *testing.T) {
	resetNotify(t)
	resetRefusal(t)
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	f.plantArmed(0xBEEF, hostint.LaneDrop)
	hostintSeatTick()
	execs := dropOpenFixture(t, map[string][]byte{
		"/host/INBOX/PHOTO.QOI": []byte("qoif" + strings.Repeat("x", 12)),
	})

	notifyDND = true
	f.plantDrop(0xBEEF, 1, "PHOTO.QOI", 4100)
	hostintSeatTick()
	if notifyCount() != 0 {
		t.Fatalf("DND leaked a toast: %d", notifyCount())
	}
	if len(notifyCenter) != 1 || notifyCenter[0].action != notifyActionDropOpen {
		t.Fatalf("held row = %+v", notifyCenter)
	}

	// The row's activation gesture: a click on the row body runs the
	// row's bound action (the same arm the toast click takes).
	notifyCenterOpen = true
	if !notifyCenterClick(400, 220) {
		t.Fatal("center click not consumed")
	}
	if len(*execs) != 1 ||
		(*execs)[0] != [2]string{"GOVIEW.ELF", "/host/INBOX/PHOTO.QOI"} {
		t.Fatalf("execs = %v want GOVIEW on the INBOX path", *execs)
	}
	if !f.hasLog(MarkerDropOpen + "name=PHOTO.QOI app=GOVIEW.ELF") {
		t.Fatalf("missing drop-open marker: %v", f.logs)
	}
	if len(notifyCenter) != 0 {
		t.Fatalf("resolved row survived: %+v", notifyCenter)
	}
}

// An exec refusal keeps its serial marker and earns the M123a errno
// toast — the dispatch reported what the kernel answered.
func TestDropOpenExecRefusedToasts(t *testing.T) {
	resetNotify(t)
	resetRefusal(t)
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	oldRead, oldExec := dropReadFile, execApp
	dropReadFile = func(string, int) ([]byte, int64) {
		return []byte("qoif" + strings.Repeat("x", 12)), 16
	}
	execApp = func(string, ...string) (int64, error) { return 0, errnoForTest }
	t.Cleanup(func() { dropReadFile, execApp = oldRead, oldExec })

	dropOpen("PHOTO.QOI")
	if f.hasLog(MarkerDropOpen) {
		t.Fatalf("a refused exec claimed a dispatch: %v", f.logs)
	}
	if notifyCount() != 1 || notifyQueue[0].action != notifyActionRetry {
		t.Fatalf("queue = %+v want the ENOENT retry toast", notifyQueue)
	}
}
