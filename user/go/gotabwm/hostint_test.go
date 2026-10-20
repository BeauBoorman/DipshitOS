package main

import (
	"strings"
	"testing"

	"virelai/hostint"
	"virelai/vi"
)

// hostintFixture wires the real seat code to an in-memory lane directory
// and an in-memory kernel clipboard, so the whole lane policy — credential
// probe, ARMED adoption, CLIP_IN apply, CLIP_OUT emit, echo guard, badge —
// runs on the host without a VM.
type hostintFixture struct {
	t     *testing.T
	files map[string][]byte
	clip  []byte // the fake kernel clipboard
	logs  []string
	key   []byte
}

func newHostintFixture(t *testing.T, key string) *hostintFixture {
	f := &hostintFixture{t: t, files: map[string][]byte{}, key: []byte(key)}

	prevSecret := hostintSecretGet
	prevList := hostintListDir
	prevRead := hostintReadFile
	prevWrite := hostintWriteFile
	prevDel := hostintDeleteFile
	prevLog := hostintLog
	prevGet := hostClipGet
	prevSet := hostClipSet
	prevEng := hostintEngine
	prevBuf := hostClipBuf
	t.Cleanup(func() {
		hostintSecretGet = prevSecret
		hostintListDir = prevList
		hostintReadFile = prevRead
		hostintWriteFile = prevWrite
		hostintDeleteFile = prevDel
		hostintLog = prevLog
		hostClipGet = prevGet
		hostClipSet = prevSet
		hostintEngine = prevEng
		hostClipBuf = prevBuf
		hostClipSeen, hostClipHash, hostClipLen, hostClipSourceHost = false, 0, 0, false
		hostClipLaneHeld = false
	})

	hostintSecretGet = func(name string, out []byte) int {
		if name != hostint.SecretName || f.key == nil {
			return -1
		}
		return copy(out, f.key)
	}
	hostintListDir = func() ([]vi.DirItem, bool) {
		// Non-nil even when empty: a drained lane dir is a real listing,
		// not an io_error — same shape as the production DirList seam.
		items := make([]vi.DirItem, 0, len(f.files))
		for name := range f.files {
			items = append(items, vi.DirItem{Name: name})
		}
		return items, false
	}
	hostintReadFile = func(name string) ([]byte, int64) {
		b, ok := f.files[name]
		if !ok {
			return nil, -vi.ErrENOENT
		}
		out := make([]byte, len(b))
		copy(out, b)
		return out, int64(len(b))
	}
	hostintWriteFile = func(name string, b []byte) int64 {
		cp := make([]byte, len(b))
		copy(cp, b)
		f.files[name] = cp
		return 0
	}
	hostintDeleteFile = func(name string) int64 {
		delete(f.files, name)
		return 0
	}
	hostintLog = func(s string) { f.logs = append(f.logs, s) }
	hostClipGet = func(buf []byte) (int, int64) {
		n := copy(buf, f.clip)
		return n, int64(n)
	}
	hostClipSet = func(p []byte) (int, int64) {
		if len(p) > clipKernelMax {
			p = p[:clipKernelMax]
		}
		f.clip = append(f.clip[:0], p...)
		return len(p), int64(len(p))
	}
	return f
}

func (f *hostintFixture) hasLog(sub string) bool {
	for _, l := range f.logs {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

// plantArmed stages a valid runner ARMED for epoch with the clip bit.
func (f *hostintFixture) plantArmed(epoch uint32, mask uint8) {
	f.files["ARMED-00000001"] = hostint.EncodeRecord(f.key, hostint.TagArmed, 0, 1, epoch, []byte{mask})
}

func (f *hostintFixture) plantClipIn(epoch, seq uint32, payload string) {
	f.files[hostint.RecordName(hostint.TagClipIn, seq)] =
		hostint.EncodeRecord(f.key, hostint.TagClipIn, 0, seq, epoch, []byte(payload))
}

func (f *hostintFixture) clipOutPayloads() [][]byte {
	var out [][]byte
	for name, b := range f.files {
		if strings.HasPrefix(name, "CLIPOUT-") {
			if rec, ok := hostint.DecodeRecord(b); ok {
				out = append(out, rec.Payload)
			}
		}
	}
	return out
}

// drainClipOut simulates the runner's consume: delete every CLIPOUT-* file.
func (f *hostintFixture) drainClipOut() {
	for name := range f.files {
		if strings.HasPrefix(name, "CLIPOUT-") {
			delete(f.files, name)
		}
	}
}

func TestHostintSeatInitAbsentCredentialIsSilent(t *testing.T) {
	f := newHostintFixture(t, "")
	f.key = nil
	hostintSeatInit()
	if hostintEngine != nil {
		t.Fatal("engine exists without a credential")
	}
	for i := 0; i < 3; i++ {
		hostintSeatTick()
	}
	if len(f.logs) != 0 || len(f.files) != 0 {
		t.Fatalf("credentialless lane produced traffic: %v %v", f.logs, f.files)
	}
}

func TestHostintFullLoopBothDirections(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	if hostintEngine == nil {
		t.Fatal("credential present but engine nil")
	}
	f.plantArmed(0xBEEF, hostint.LaneClip)
	hostintSeatTick()
	if !f.hasLog(hostintMarkerPrefix+" armed epoch=48879 lanes=clip") {
		t.Fatalf("missing armed marker: %v", f.logs)
	}

	// h→g: a signed CLIP_IN lands, is applied through the fake slot 38,
	// and the badge flips host-marked.
	f.plantClipIn(0xBEEF, 1, "host says hi")
	hostintSeatTick()
	if string(f.clip) != "host says hi" {
		t.Fatalf("guest clipboard = %q", f.clip)
	}
	if !f.hasLog(MarkerHostintClipIn+"seq=1 len=12") {
		t.Fatalf("missing clip-in marker: %v", f.logs)
	}
	if !f.hasLog(MarkerHostintClipInd + "host") {
		t.Fatalf("missing host-source indicator marker: %v", f.logs)
	}
	if tag, _, ok := hostClipBadge(); !ok || tag != "CLIP:H" {
		t.Fatal("badge not host-marked after apply")
	}

	// Echo guard: the applied content must NOT emit a CLIP_OUT.
	if n := len(f.clipOutPayloads()); n != 0 {
		t.Fatalf("echo emitted %d CLIP_OUT records", n)
	}

	// g→h: a local write (monitor clip, a chord, a cap holder — the seat
	// sees the buffer change, not the caller) emits a signed CLIP_OUT.
	f.clip = []byte("guest says hi")
	hostintSeatTick()
	outs := f.clipOutPayloads()
	if len(outs) != 1 || string(outs[0]) != "guest says hi" {
		t.Fatalf("clipOutPayloads = %v", outs)
	}
	if !f.hasLog(MarkerHostintClipOut+"seq=1 len=13") {
		t.Fatalf("missing clip-out marker: %v", f.logs)
	}
	if !f.hasLog(MarkerHostintClipInd + "local") {
		t.Fatalf("missing local-source indicator marker: %v", f.logs)
	}
}

func TestHostintClipInBadMACRefused(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	f.plantArmed(9, hostint.LaneClip)
	hostintSeatTick()
	// A forged CLIP_IN: right shape, signed under the wrong key.
	f.files["CLIPIN-00000001"] = hostint.EncodeRecord(
		[]byte("attacker"), hostint.TagClipIn, 0, 1, 9, []byte("forged"))
	hostintSeatTick()
	if len(f.clip) != 0 {
		t.Fatal("forged record applied to the clipboard")
	}
	if !f.hasLog("reason=bad_mac") {
		t.Fatalf("missing bad_mac refusal: %v", f.logs)
	}
}

func TestHostintClipOutBackpressuredRetries(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	f.plantArmed(9, hostint.LaneClip)
	hostintSeatTick()

	// Fill the runner-visible window: four emitted, none consumed.
	for i, text := range []string{"c1", "c2", "c3", "c4"} {
		f.clip = []byte(text)
		hostintSeatTick()
		if n := len(f.clipOutPayloads()); n != i+1 {
			t.Fatalf("tick %d: %d CLIP_OUT records", i, n)
		}
	}
	// A fifth change diffs but cannot emit while four are outstanding:
	// silent — no refuse marker — and the seen-state stays uncommitted
	// so the change retries next tick rather than dropping for good.
	f.clip = []byte("held")
	hostintSeatTick()
	if n := len(f.clipOutPayloads()); n != hostint.MaxOutstanding {
		t.Fatalf("emitted past the bound: %d", n)
	}
	if f.hasLog("refuse lane=clip") {
		t.Fatalf("backpressure logged a refuse marker: %v", f.logs)
	}
	// The runner drains; the held change emits next tick with the next
	// seq — without the retry the host pasteboard would have diverged
	// until the next guest-side write.
	f.drainClipOut()
	hostintSeatTick()
	outs := f.clipOutPayloads()
	if len(outs) != 1 || string(outs[0]) != "held" {
		t.Fatalf("resumed emit: %v", outs)
	}
	if !f.hasLog(MarkerHostintClipOut + "seq=5 len=4") {
		t.Fatalf("missing resumed clip-out marker: %v", f.logs)
	}
	// The retried emit committed the seen-state: one more tick emits
	// nothing for the same buffer.
	hostintSeatTick()
	if n := len(f.clipOutPayloads()); n != 1 {
		t.Fatalf("re-emitted a committed change: %d records", n)
	}
}

// M124c: a typed buffer crosses on the dedicated tag with the envelope —
// and the badge takes the type suffix off the same classification.
func TestHostintClipOutTyped(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	f.plantArmed(9, hostint.LaneClip)
	hostintSeatTick()

	png := []byte("\x89PNG\r\n\x1a\nfakebody")
	f.clip = png
	hostintSeatTick()
	var typed [][]byte
	for name, b := range f.files {
		if strings.HasPrefix(name, "CLIPTOUT-") {
			if rec, ok := hostint.DecodeRecord(b); ok {
				typed = append(typed, rec.Payload)
			}
		}
	}
	if len(typed) != 1 {
		t.Fatalf("CLIPTOUT records = %d want 1 (files %v)", len(typed), f.files)
	}
	mime, blob, ok := hostint.DecodeTypedClip(typed[0])
	if !ok || mime != "image/png" || string(blob) != string(png) {
		t.Fatalf("typed envelope = %q %q %v", mime, blob, ok)
	}
	if !f.hasLog(MarkerHostintClipOutT + "seq=1 mime=image/png len=") {
		t.Fatalf("missing typed clip-out marker: %v", f.logs)
	}
	if tag, _, ok := hostClipBadge(); !ok || tag != "CLIP:IMG" {
		t.Fatalf("badge after image buffer = %q", tag)
	}

	// A uri-list badges FILE on the same rule.
	f.clip = []byte("file:///host/NOTES.TXT")
	hostintSeatTick()
	if tag, _, ok := hostClipBadge(); !ok || tag != "CLIP:FILE" {
		t.Fatalf("badge after uri-list = %q", tag)
	}
}

// The h→g half: a verified CLIP_IN_T applies its blob through slot 38 and
// the badge carries type + host mark. A mislabeled payload refuses
// unsupported_kind and never touches the buffer.
func TestHostintClipInTyped(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	f.plantArmed(7, hostint.LaneClip)
	hostintSeatTick()

	png := []byte("\x89PNG\r\n\x1a\nfromhost")
	f.files[hostint.RecordName(hostint.TagClipInT, 1)] = hostint.EncodeRecord(
		f.key, hostint.TagClipInT, 0, 1, 7,
		hostint.EncodeTypedClip("image/png", png))
	hostintSeatTick()
	if string(f.clip) != string(png) {
		t.Fatalf("guest clipboard = %q", f.clip)
	}
	if !f.hasLog(MarkerHostintClipInT + "seq=1 mime=image/png len=") {
		t.Fatalf("missing typed clip-in marker: %v", f.logs)
	}
	if tag, _, ok := hostClipBadge(); !ok || tag != "CLIP:IMG:H" {
		t.Fatalf("badge = %q want CLIP:IMG:H", tag)
	}

	// The label must not lie about the bytes: a png-labelled text body is
	// unsupported_kind and the buffer is untouched.
	f.files[hostint.RecordName(hostint.TagClipInT, 2)] = hostint.EncodeRecord(
		f.key, hostint.TagClipInT, 0, 2, 7,
		hostint.EncodeTypedClip("image/png", []byte("not a png")))
	hostintSeatTick()
	if string(f.clip) != string(png) {
		t.Fatal("mislabeled record overwrote the buffer")
	}
	if !f.hasLog("lane=clip reason=" + hostint.RefuseUnsupported) {
		t.Fatalf("missing unsupported_kind: %v", f.logs)
	}
}

func TestHostintClipOutNotText(t *testing.T) {
	f := newHostintFixture(t, strings.Repeat("b7", 32))
	hostintSeatInit()
	f.plantArmed(9, hostint.LaneClip)
	hostintSeatTick()
	f.clip = []byte{0xff, 0xfe, 'n'}
	hostintSeatTick()
	if len(f.clipOutPayloads()) != 0 {
		t.Fatal("non-UTF-8 buffer emitted as CLIP_OUT")
	}
	if !f.hasLog("lane=clip reason="+hostint.RefuseNotText) {
		t.Fatalf("missing payload_not_text refusal: %v", f.logs)
	}
}
