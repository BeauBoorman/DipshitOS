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
	})

	hostintSecretGet = func(name string, out []byte) int {
		if name != hostint.SecretName || f.key == nil {
			return -1
		}
		return copy(out, f.key)
	}
	hostintListDir = func() ([]vi.DirItem, bool) {
		var items []vi.DirItem
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
