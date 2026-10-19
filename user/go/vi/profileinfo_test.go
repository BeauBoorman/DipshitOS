package vi

import "testing"

// M128d (#2608): the relayed `result` member parses into a ProfileInfo —
// NUL-terminated like the kernel leaves it, escapes resolved, every
// malformed/truncated shape refused whole.
func TestParseProfileInfo(t *testing.T) {
	raw := append([]byte(`{"profile":"work","base":"disk.img","rollback":true,"snapshots":3}`), 0)
	p, ok := ParseProfileInfo(raw)
	if !ok || p.Name != "work" || p.Base != "disk.img" || !p.Rollback || p.Snapshots != 3 {
		t.Fatalf("profile = %+v ok=%v", p, ok)
	}
	// A profile-less run carries "-" fields, which are still an answer.
	p, ok = ParseProfileInfo([]byte(`{"profile":"-","base":"-","rollback":false,"snapshots":0}`))
	if !ok || p.Name != "-" || p.Rollback || p.Snapshots != 0 {
		t.Fatalf("dash profile = %+v ok=%v", p, ok)
	}
	// An escaped name resolves to its real bytes.
	p, ok = ParseProfileInfo([]byte(`{"profile":"we\"ird","base":"b","rollback":false,"snapshots":1}`))
	if !ok || p.Name != `we"ird` || p.Snapshots != 1 {
		t.Fatalf("escaped profile = %+v ok=%v", p, ok)
	}
	// ctlEscape emits \u00xx for control bytes; the guest refuses
	// those whole — a control character in a profile name is not a name.
	if _, ok = ParseProfileInfo([]byte(`{"profile":"a\u001fb","base":"b","rollback":false,"snapshots":0}`)); ok {
		t.Fatal("\\u00xx-escaped profile unexpectedly parsed")
	}
	// A member-shaped substring inside an escaped value (\"profile\":)
	// must not shadow the real member — the backslash marks it as
	// string content, so extraction steps past it.
	p, ok = ParseProfileInfo([]byte(`{"base":"x\"profile\":y","profile":"real","rollback":false,"snapshots":1}`))
	if !ok || p.Name != "real" || p.Base != `x"profile":y` {
		t.Fatalf("embedded-pattern profile = %+v ok=%v", p, ok)
	}
	for _, bad := range []string{
		`{"profile":"work","base":"disk.img","rollback":true,"snapshots":2`, // truncated relay
		`{"base":"disk.img","rollback":true,"snapshots":2}`,                 // no identity
		`{"profile":"w","base":"b","rollback":true,"snapshots":"two"}`,      // mistyped count
		`{"profile":"w","deep":{"a":1}}`,                                    // nested member refused whole
		`not json`,
		``,
	} {
		if _, ok := ParseProfileInfo([]byte(bad)); ok {
			t.Fatalf("profile %q unexpectedly parsed", bad)
		}
	}
}

// FetchProfileInfo rides the injected slot-93 seam: r==0 carries the
// result, r>0 the refusal code bytes, r<0 a kernel errno name.
func TestFetchProfileInfo(t *testing.T) {
	var sawVerb string
	ctl := func(verb, name string, code []byte) int64 {
		sawVerb = verb
		if name != "" {
			t.Fatalf("profile-info must send a bare verb; name=%q", name)
		}
		copy(code, `{"profile":"prof","base":"disk.img","rollback":false,"snapshots":1}`)
		return 0
	}
	p, verdict := FetchProfileInfo(ctl)
	if sawVerb != VerbProfileInfo || verdict != "" {
		t.Fatalf("fetch verb=%q verdict=%q", sawVerb, verdict)
	}
	if p.Name != "prof" || p.Base != "disk.img" || p.Rollback || p.Snapshots != 1 {
		t.Fatalf("fetch profile=%+v", p)
	}

	p, verdict = FetchProfileInfo(func(_, _ string, code []byte) int64 {
		return int64(copy(code, "no_credential"))
	})
	if verdict != "no_credential" || p.Name != "" {
		t.Fatalf("refusal verdict=%q profile=%+v", verdict, p)
	}

	p, verdict = FetchProfileInfo(func(_, _ string, _ []byte) int64 {
		return -int64(ErrENOSYS)
	})
	if verdict != "ENOSYS" || p.Name != "" {
		t.Fatalf("errno verdict=%q profile=%+v", verdict, p)
	}

	// An ok return with no parseable relay is malformed, never a guess.
	_, verdict = FetchProfileInfo(func(_, _ string, code []byte) int64 {
		code[0] = 0
		return 0
	})
	if verdict != "malformed" {
		t.Fatalf("empty-relay verdict=%q want malformed", verdict)
	}
}
