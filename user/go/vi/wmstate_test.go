package vi

// M125a (#2586): the staged-file envelope and the client helpers' bounds.
// The file seams stand in for the share the way gotabwm's writeHostFile
// does — WriteFileSafe/ReadFileAll degrade to -ENOSYS off the guest.

import (
	"bytes"
	"testing"
)

func TestAppStateEnvelopeRoundTrip(t *testing.T) {
	blob := []byte("gotabapp state v1: hello strip")
	enc, ok := EncodeAppState(3, blob)
	if !ok {
		t.Fatal("EncodeAppState refused an in-bounds blob")
	}
	ver, got, ok := DecodeAppState(enc)
	if !ok || ver != 3 || !bytes.Equal(got, blob) {
		t.Fatalf("round-trip ver=%d blob=%x ok=%v", ver, got, ok)
	}
	// An empty blob is a legal envelope — the app's own "no state".
	enc, ok = EncodeAppState(0, nil)
	if !ok {
		t.Fatal("EncodeAppState refused empty")
	}
	ver, got, ok = DecodeAppState(enc)
	if !ok || ver != 0 || len(got) != 0 {
		t.Fatalf("empty round-trip ver=%d len=%d ok=%v", ver, len(got), ok)
	}
}

func TestAppStateEnvelopeBounds(t *testing.T) {
	// Exactly 64 KiB encodes and decodes — the card's bound is inclusive.
	max := make([]byte, AppStateMax)
	for i := range max {
		max[i] = byte(i)
	}
	enc, ok := EncodeAppState(1, max)
	if !ok {
		t.Fatal("EncodeAppState refused exactly AppStateMax")
	}
	_, got, ok := DecodeAppState(enc)
	if !ok || !bytes.Equal(got, max) {
		t.Fatal("AppStateMax round-trip failed")
	}
	// +1 is refused at encode, before a byte is published.
	if _, ok := EncodeAppState(1, make([]byte, AppStateMax+1)); ok {
		t.Fatal("EncodeAppState encoded AppStateMax+1")
	}
	// Decode refuses: short header, a declared length over the cap, and
	// a length that does not match the file's exact size.
	if _, _, ok := DecodeAppState([]byte{1, 0, 0}); ok {
		t.Fatal("short header decoded")
	}
	// A header alone declaring 65537 is refused before the body is read.
	if _, _, ok := DecodeAppState([]byte{1, 0x01, 0x00, 0x01, 0x00}); ok {
		t.Fatal("over-cap declared length decoded")
	}
	if _, _, ok := DecodeAppState(enc[:len(enc)-1]); ok {
		t.Fatal("a truncated body decoded")
	}
	if _, _, ok := DecodeAppState(append(append([]byte(nil), enc...), 0)); ok {
		t.Fatal("a padded body decoded")
	}
}

func TestAppStatePathShape(t *testing.T) {
	if got := AppStatePath(9); got != "/host/APPSTATE.9" {
		t.Fatalf("AppStatePath(9) = %q", got)
	}
	if got := AppStatePath(0); got != "/host/APPSTATE.0" {
		t.Fatalf("AppStatePath(0) = %q", got)
	}
}

// PostStateSave/RequestStateRestore's mailbox half is exercised by the
// seat's applyRPC arm in gotabwm's tests (wmRequest stubs the IPC layer);
// here the file seam verifies the publish/consume ordering around it.
func TestPostStateSaveRefusalCleansStaging(t *testing.T) {
	oldWrite, oldRead, oldDel := appStateWrite, appStateRead, appStateDel
	t.Cleanup(func() {
		appStateWrite, appStateRead, appStateDel = oldWrite, oldRead, oldDel
	})
	files := map[string][]byte{}
	deleted := []string{}
	appStateWrite = func(path string, data []byte) int64 {
		files[path] = append([]byte(nil), data...)
		return 0
	}
	appStateRead = func(path string, max int) ([]byte, int64) {
		b, ok := files[path]
		if !ok {
			return nil, -2
		}
		return b, int64(len(b))
	}
	appStateDel = func(path string) int64 {
		delete(files, path)
		deleted = append(deleted, path)
		return 0
	}
	// The request itself cannot complete off the guest (no mailbox), so
	// PostStateSave's refusal path runs: it must delete the staging file
	// it published rather than leave a blob a later id-9 window would read.
	if PostStateSave(9, 1, []byte("x"), "GOTABAPP.ELF") {
		t.Fatal("PostStateSave answered off the guest")
	}
	if len(files) != 0 || len(deleted) != 1 || deleted[0] != AppStatePath(9) {
		t.Fatalf("staging left behind: files=%v deleted=%v", files, deleted)
	}
}
