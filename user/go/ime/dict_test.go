package ime

import (
	"os"
	"path/filepath"
	"testing"
)

// dictPath is the committed packed dictionary — the same bytes the
// guest reads at /host/KANADICT.BIN when a boot stages
// image/kanadict/KANADICT.BIN. Testing against it pins the reader to
// the real artifact, not a synthetic blob. Tests read it with os (the
// host side) — Open goes through the guest file channel, which reports
// -ENOSYS off-virelai.
const dictPath = "../../../image/kanadict/KANADICT.BIN"

func load(t *testing.T) *Dict {
	t.Helper()
	b, err := os.ReadFile(dictPath)
	if err != nil {
		t.Fatalf("read committed dict: %v", err)
	}
	d, err := Parse(b)
	if err != nil {
		t.Fatalf("parse committed dict: %v", err)
	}
	return d
}

func TestCommittedDictParsesAndLooksUp(t *testing.T) {
	d := load(t)
	if d.Len() != 150 {
		t.Fatalf("Len = %d, want 150 readings", d.Len())
	}
	if got := d.Lookup("にほんご"); len(got) != 1 || got[0] != "日本語" {
		t.Fatalf("にほんご -> %v, want [日本語]", got)
	}
	// Rank order is the frequency proxy: 易しい before 優しい.
	if got := d.Lookup("やさしい"); len(got) != 2 || got[0] != "易しい" || got[1] != "優しい" {
		t.Fatalf("やさしい -> %v, want [易しい 優しい]", got)
	}
}

func TestLookupMissIsHonest(t *testing.T) {
	d := load(t)
	for _, absent := range []string{"ふがふが", "にほn", "すし", ""} {
		if got := d.Lookup(absent); got != nil {
			t.Errorf("Lookup(%q) = %v, want nil", absent, got)
		}
	}
}

func TestParseRejectsCorruptBlobs(t *testing.T) {
	good, err := os.ReadFile(dictPath)
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string][]byte{
		"empty":        nil,
		"short header": good[:4],
		"bad magic":    append([]byte("XXXX"), good[4:]...),
		"truncated":    good[:len(good)/2],
	}
	// n lies about the real count: the index overruns the blob.
	lied := append([]byte{}, good...)
	lied[4], lied[5], lied[6], lied[7] = 0xff, 0xff, 0xff, 0x7f
	cases["count overrun"] = lied
	// An unsorted index: swap the first two keys' order by swapping
	// their index entries.
	unsorted := append([]byte{}, good...)
	for i := 0; i < indexEntry; i++ {
		unsorted[headerLen+i], unsorted[headerLen+indexEntry+i] =
			unsorted[headerLen+indexEntry+i], unsorted[headerLen+i]
	}
	cases["unsorted index"] = unsorted
	for name, blob := range cases {
		if _, err := Parse(blob); err == nil {
			t.Errorf("%s: Parse accepted a corrupt blob", name)
		}
	}
}

func TestEveryKeyResolves(t *testing.T) {
	// Walk the index: every key must round-trip through Lookup and pay
	// out at least one non-empty surface.
	d := load(t)
	for i := 0; i < d.n; i++ {
		e := headerLen + i*indexEntry
		koff, klen := int(u32(d.blob, e)), int(u16(d.blob, e+8))
		key := string(d.blob[koff : koff+klen])
		got := d.Lookup(key)
		if len(got) == 0 {
			t.Fatalf("index key %q not found by Lookup", key)
		}
		for _, s := range got {
			if s == "" {
				t.Fatalf("%q: empty surface", key)
			}
		}
	}
}

func TestDefaultIsNilWithoutTheStagedFile(t *testing.T) {
	// The host has no /host/KANADICT.BIN: Default must degrade to nil,
	// not error or crash. (On the guest the spec stages the file.)
	if _, err := os.Stat(filepath.Clean(DefaultPath)); err == nil {
		t.Skip("a staged dict exists at the guest path — running on-device?")
	}
	if Default() != nil {
		t.Fatal("Default() must be nil when the staged file is absent")
	}
}
