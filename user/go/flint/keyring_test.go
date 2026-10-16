package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"virelai/sshlib"
)

// A second pinned publisher seed for wrong-key legs — not in the harness
// keyring unless a test adds it.
const testAltSeedHex = "4242424242424242424242424242424242424242424242424242424242424242"

func refuseCode(t *testing.T, err error, want string) {
	t.Helper()
	re, ok := err.(*RefuseError)
	if !ok || re.Code != want {
		t.Fatalf("expected refuse %s, got %v", want, err)
	}
}

func TestKeyringParse(t *testing.T) {
	altPub := pubHexForSeed(t, testAltSeedHex)

	kr, err := ParseKeyring([]byte(
		"#v1\n" +
			"# a comment line\n" +
			"\n" +
			"key=" + testRFC8032PubHex + " name=rfc8032\n" +
			"key=" + altPub + " name=alt-pub\n" +
			"revoked=" + altPub + "\n",
	))
	if err != nil {
		t.Fatalf("valid keyring refused: %v", err)
	}
	if err := kr.CheckAuthor(testRFC8032PubHex); err != nil {
		t.Fatalf("trusted key refused: %v", err)
	}
	refuseCode(t, kr.CheckAuthor(altPub), "key_revoked")
	refuseCode(t, kr.CheckAuthor(strings.Repeat("00", 32)), "key_unknown")

	// A revoked= row for a key that is NOT listed still names key_revoked.
	kr, err = ParseKeyring([]byte(
		"#v1\nrevoked=" + altPub + "\n",
	))
	if err != nil {
		t.Fatalf("revoked-only keyring refused: %v", err)
	}
	refuseCode(t, kr.CheckAuthor(altPub), "key_revoked")

	bad := []string{
		"",                                       // empty file
		"key=" + testRFC8032PubHex + " name=x\n", // no header
		"#v0\n",                                  // no such schema
		"#v2\n",                                  // newer schema
		"#v\n",                                   // header without digits
		" #v1\n",                                 // leading whitespace
		"#v1\nfoo=bar\n",                         // unknown row
		"#v1\nkey=" + testRFC8032PubHex + "\n",   // key row without name
		"#v1\nkey=" + testRFC8032PubHex + " name=\n",                                        // empty label
		"#v1\nname=x key=" + testRFC8032PubHex + "\n",                                       // wrong field order
		"#v1\nkey=zz" + testRFC8032PubHex[2:] + " name=x\n",                                 // non-hex key
		"#v1\nkey=" + testRFC8032PubHex[:62] + " name=x\n",                                  // short key
		"#v1\nkey=" + testRFC8032PubHex + " name=a b\n",                                     // label with space
		"#v1\nkey=" + testRFC8032PubHex + " name=a\nkey=" + testRFC8032PubHex + " name=b\n", // dup key
		"#v1\nrevoked=" + testRFC8032PubHex + " revoked=" + testRFC8032PubHex + "\n",        // dup revoked
		"#v1\nrevoked=" + testRFC8032PubHex + " extra=1\n",                                  // revoked with tail
	}
	for _, body := range bad {
		if _, err := ParseKeyring([]byte(body)); err == nil {
			t.Fatalf("corrupt keyring parsed: %q", body)
		} else {
			refuseCode(t, err, "keyring_malformed")
		}
	}
}

func TestKeyringLoadMissingAndCorrupt(t *testing.T) {
	h := newTestHarness(t)

	if _, err := LoadKeyring(h.fs, h.root); err == nil {
		t.Fatal("missing TRUSTED.TXT: expected refusal")
	} else {
		refuseCode(t, err, "keyring_missing")
	}

	if err := h.fs.WriteFileSafe(keyringPath(h.root), []byte("not a keyring\n")); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadKeyring(h.fs, h.root); err == nil {
		t.Fatal("corrupt TRUSTED.TXT: expected refusal")
	} else {
		refuseCode(t, err, "keyring_malformed")
	}
}

// storeSnapshot captures the whole memFS — files AND dirs — for
// byte-identical assertions after a refusal: verify-before-materialize
// means a refused clone/pull leaves zero writes behind, not even a mkdir.
type fsSnapshot struct {
	files map[string][]byte
	dirs  map[string]bool
}

func storeSnapshot(h *remoteHarness) fsSnapshot {
	snap := fsSnapshot{
		files: make(map[string][]byte, len(h.fs.files)),
		dirs:  make(map[string]bool, len(h.fs.dirs)),
	}
	for p, b := range h.fs.files {
		snap.files[p] = bytes.Clone(b)
	}
	for p := range h.fs.dirs {
		snap.dirs[p] = true
	}
	return snap
}

func assertStoreIdentical(t *testing.T, h *remoteHarness, snap fsSnapshot) {
	t.Helper()
	if len(h.fs.files) != len(snap.files) {
		t.Fatalf("store file count changed: %d -> %d", len(snap.files), len(h.fs.files))
	}
	for p, b := range snap.files {
		got, ok := h.fs.files[p]
		if !ok || !bytes.Equal(got, b) {
			t.Fatalf("store file %s changed or vanished", p)
		}
	}
	if len(h.fs.dirs) != len(snap.dirs) {
		t.Fatalf("store dir count changed: %d -> %d", len(snap.dirs), len(h.fs.dirs))
	}
	for p := range snap.dirs {
		if !h.fs.dirs[p] {
			t.Fatalf("store dir %s vanished", p)
		}
	}
}

// TestCloneKeyringMatrix is the card's acceptance: signed/unsigned/
// wrong-key/revoked/tampered each land as their named refusal (or pass) —
// and every refusal leaves the store byte-identical.
func TestCloneKeyringMatrix(t *testing.T) {
	altPub := pubHexForSeed(t, testAltSeedHex)

	cases := []struct {
		name    string
		seedHex string
		mutate  func(lines [][]byte) // tamper the wire lines before serving
		keyring string               // "" keeps the harness default; "-" removes it
		wantRef string               // "" means clone must succeed
	}{
		{name: "signed trusted key", seedHex: testRFC8032SeedHex, wantRef: ""},
		{name: "wrong key", seedHex: testAltSeedHex, wantRef: "key_unknown"},
		{
			name:    "revoked key",
			seedHex: testAltSeedHex,
			keyring: "#v1\nkey=" + testRFC8032PubHex + " name=rfc8032\nkey=" + altPub + " name=alt\nrevoked=" + altPub + "\n",
			wantRef: "key_revoked",
		},
		{
			name:    "tampered sig",
			seedHex: testRFC8032SeedHex,
			mutate: func(lines [][]byte) {
				bad := append([]byte(nil), lines[1]...)
				i := bytes.LastIndex(bad, []byte(`"sig":"`)) + len(`"sig":"`)
				if bad[i] == 'a' {
					bad[i] = 'b'
				} else {
					bad[i] = 'a'
				}
				lines[1] = bad
			},
			wantRef: "sig_invalid",
		},
		{
			name:    "unsigned (zero sig)",
			seedHex: testRFC8032SeedHex,
			mutate: func(lines [][]byte) {
				c, err := ParseChange(lines[1])
				if err != nil {
					return
				}
				c.Sig = strings.Repeat("0", 128)
				line, err := MarshalChangeLine(c)
				if err == nil {
					lines[1] = bytes.TrimRight(line, "\n")
				}
			},
			wantRef: "sig_invalid",
		},
		{
			name:    "unsigned (no sig field)",
			seedHex: testRFC8032SeedHex,
			mutate: func(lines [][]byte) {
				c, err := ParseChange(lines[1])
				if err != nil {
					return
				}
				// A Change marshaled without a sig field fails ParseChange.
				raw := `{"id":"` + c.ID + `","parent":` + q(*c.Parent) +
					`,"stream":"` + c.Stream + `","ts":1760000002000,"author":"` +
					c.Author + `","message":"srv change","ops":[],"merged":null}`
				lines[1] = []byte(raw)
			},
			wantRef: "change_malformed",
		},
		{name: "keyring missing", seedHex: testRFC8032SeedHex, keyring: "-", wantRef: "keyring_missing"},
		{name: "keyring corrupt", seedHex: testRFC8032SeedHex, keyring: "#v2\n", wantRef: "keyring_malformed"},
		{name: "keyring empty", seedHex: testRFC8032SeedHex, keyring: "#v1\n", wantRef: "key_unknown"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := newFakeServer()
			h := newRemoteHarness(t, srv)
			st, lines := mkSignedStreamSeed(t, h, "main", 2, tc.seedHex)
			if tc.mutate != nil {
				tc.mutate(lines)
			}
			srv.addStream(st, lines)

			if tc.keyring == "-" {
				if err := h.fs.Remove(keyringPath(h.root)); err != nil {
					t.Fatal(err)
				}
			} else if tc.keyring != "" {
				if err := h.fs.WriteFileSafe(keyringPath(h.root), []byte(tc.keyring)); err != nil {
					t.Fatal(err)
				}
			}

			snap := storeSnapshot(h)
			rc, logs := h.runCmd("clone", "10.0.0.2:4748", "main")
			if tc.wantRef == "" {
				if rc != 0 {
					t.Fatalf("clone rc=%d logs=%v", rc, logs)
				}
				if !h.fs.Exists("/host/FLINT/streams/" + st.ID + ".jsonl") {
					t.Fatal("clone ok but no stream log written")
				}
				return
			}
			if rc != 1 || len(logs) != 1 || !strings.HasPrefix(logs[0], "flint: refuse "+tc.wantRef) {
				t.Fatalf("clone: rc=%d logs=%v, want refuse %s", rc, logs, tc.wantRef)
			}
			assertStoreIdentical(t, h, snap)
		})
	}
}

// TestPullKeyringMatrix proves pull refuses by name before materializing and
// that revocation only blocks the revoked key's NEW Changes — installed
// content and other trusted keys are unaffected.
func TestPullKeyringMatrix(t *testing.T) {
	altPub := pubHexForSeed(t, testAltSeedHex)

	appendServerChange := func(t *testing.T, h *remoteHarness, srv *fakeServer, streamID string, seedHex string) {
		t.Helper()
		fs := srv.streams[streamID]
		cid, err := h.uuid.New()
		if err != nil {
			t.Fatal(err)
		}
		c := Change{
			ID: cid, Parent: fs.rec.Head, Stream: streamID,
			TS: 1760000009000, Message: "srv new",
			Ops: []Op{}, Merged: nil,
		}
		signChangeHexSeed(t, &c, seedHex)
		line, err := MarshalChangeLine(c)
		if err != nil {
			t.Fatal(err)
		}
		fs.lines = append(fs.lines, bytes.TrimRight(line, "\n"))
		fs.rec.Head = &c.ID
	}

	// New remote Change from an unknown key → key_unknown, store identical.
	srv := newFakeServer()
	h := newRemoteHarness(t, srv)
	st, lines := mkSignedStream(t, h, "main", 1)
	srv.addStream(st, lines)
	if rc, logs := h.runCmd("clone", "10.0.0.2:4748", "main"); rc != 0 {
		t.Fatalf("clone: %v", logs)
	}
	appendServerChange(t, h, srv, st.ID, testAltSeedHex)
	snap := storeSnapshot(h)
	rc, logs := h.runCmd("pull")
	if rc != 1 || len(logs) != 1 || !strings.HasPrefix(logs[0], "flint: refuse key_unknown") {
		t.Fatalf("pull unknown key: rc=%d logs=%v", rc, logs)
	}
	assertStoreIdentical(t, h, snap)

	// New remote Change from a revoked key → key_revoked, store identical.
	// The revoked key is also listed: revocation still wins.
	srv2 := newFakeServer()
	h2 := newRemoteHarness(t, srv2)
	if err := h2.fs.WriteFileSafe(keyringPath(h2.root), []byte(
		"#v1\nkey="+testRFC8032PubHex+" name=rfc8032\nkey="+altPub+" name=alt\n",
	)); err != nil {
		t.Fatal(err)
	}
	st2, lines2 := mkSignedStream(t, h2, "main", 1)
	srv2.addStream(st2, lines2)
	origHead2 := *st2.Head // addStream aliases rec; capture before appends mutate it
	if rc, logs := h2.runCmd("clone", "10.0.0.2:4748", "main"); rc != 0 {
		t.Fatalf("clone: %v", logs)
	}
	appendServerChange(t, h2, srv2, st2.ID, testAltSeedHex)
	if err := h2.fs.WriteFileSafe(keyringPath(h2.root), []byte(
		"#v1\nkey="+testRFC8032PubHex+" name=rfc8032\nkey="+altPub+" name=alt\nrevoked="+altPub+"\n",
	)); err != nil {
		t.Fatal(err)
	}
	snap2 := storeSnapshot(h2)
	rc, logs = h2.runCmd("pull")
	if rc != 1 || len(logs) != 1 || !strings.HasPrefix(logs[0], "flint: refuse key_revoked") {
		t.Fatalf("pull revoked key: rc=%d logs=%v", rc, logs)
	}
	assertStoreIdentical(t, h2, snap2)

	// The same revocation does NOT gate a new Change by a still-trusted
	// key, and already-installed content keeps verifying locally. Rewind
	// the server log first so the new trusted Change's parent chain is
	// honest (parent = the original head, not the rejected alien Change).
	srv2.streams[st2.ID].lines = lines2
	srv2.streams[st2.ID].rec.Head = &origHead2
	appendServerChange(t, h2, srv2, st2.ID, testRFC8032SeedHex)
	rc, logs = h2.runCmd("pull")
	if rc != 0 {
		t.Fatalf("pull trusted-after-revoke: rc=%d logs=%v", rc, logs)
	}
	mustOneLog(t, logs, "flint: pull ok stream=main changes=1")
	rc, logs = h2.runCmd("verify", "--all")
	if rc != 0 {
		t.Fatalf("verify --all after revoke: rc=%d logs=%v", rc, logs)
	}
}

// TestVerifyAllTrusted covers `verify --all --trusted` — the
// materialization gate STORE execs: the publisher keyring runs over the
// LOCAL replica (a share writer's appended Change refuses by name), and
// --expect binds the folded log bytes so a mid-flight swap refuses
// log_changed.
func TestVerifyAllTrusted(t *testing.T) {
	altPub := pubHexForSeed(t, testAltSeedHex)

	seedLocal := func(t *testing.T, h *remoteHarness, seedHex string) *Stream {
		st, lines := mkSignedStreamSeed(t, h, "main", 2, seedHex)
		rec, _ := json.Marshal(st)
		if err := h.fs.WriteFileSafe(streamRecordPath(h.root, st.ID), append(rec, '\n')); err != nil {
			t.Fatal(err)
		}
		var buf bytes.Buffer
		for _, l := range lines {
			buf.Write(l)
			buf.WriteByte('\n')
		}
		if err := h.fs.WriteFileSafe(streamLogPath(h.root, st.ID), buf.Bytes()); err != nil {
			t.Fatal(err)
		}
		return st
	}

	// Trusted author: per-change verified lines, then the bound log hash.
	h := newRemoteHarness(t, newFakeServer())
	st := seedLocal(t, h, testRFC8032SeedHex)
	logBytes, err := h.fs.ReadFile(streamLogPath(h.root, st.ID), MaxFileReadBytes)
	if err != nil {
		t.Fatal(err)
	}
	sum := sshlib.SHA256Sum(logBytes)
	logSHA := sshlib.EncodeHex(sum[:])
	rc, logs := h.runCmd("verify", "--all", "--trusted", "--expect="+st.ID+":"+logSHA)
	if rc != 0 {
		t.Fatalf("verify --all --trusted: rc=%d logs=%v", rc, logs)
	}
	if len(logs) != 3 || !strings.HasSuffix(logs[0], "sig: verified") ||
		!strings.HasSuffix(logs[1], "sig: verified") ||
		logs[2] != "flint: log "+st.ID+" sha256="+logSHA {
		t.Fatalf("logs=%v", logs)
	}

	// The bind refuses when the log the gate re-reads is not the log the
	// caller hashed.
	rc, logs = h.runCmd("verify", "--all", "--trusted",
		"--expect="+st.ID+":"+strings.Repeat("0", 64))
	if rc != 1 || logs[len(logs)-1] != "flint: refuse log_changed "+st.ID {
		t.Fatalf("log_changed: rc=%d logs=%v", rc, logs)
	}

	// An unpinned author in the local replica → key_unknown; the same
	// store passes plain --all because only the signature gate runs.
	h2 := newRemoteHarness(t, newFakeServer())
	seedLocal(t, h2, testAltSeedHex)
	rc, logs = h2.runCmd("verify", "--all", "--trusted")
	if rc != 1 || len(logs) != 1 || !strings.HasPrefix(logs[0], "flint: refuse key_unknown") {
		t.Fatalf("key_unknown: rc=%d logs=%v", rc, logs)
	}
	if rc, _ := h2.runCmd("verify", "--all"); rc != 0 {
		t.Fatal("plain --all refused a well-signed log")
	}

	// Listed-but-revoked publisher → key_revoked at materialization.
	if err := h2.fs.WriteFileSafe(keyringPath(h2.root), []byte(
		"#v1\nkey="+testRFC8032PubHex+" name=rfc8032\nkey="+altPub+" name=alt\nrevoked="+altPub+"\n",
	)); err != nil {
		t.Fatal(err)
	}
	rc, logs = h2.runCmd("verify", "--all", "--trusted")
	if rc != 1 || len(logs) != 1 || !strings.HasPrefix(logs[0], "flint: refuse key_revoked") {
		t.Fatalf("key_revoked: rc=%d logs=%v", rc, logs)
	}

	// No keyring → keyring_missing; --expect without --all → usage.
	h3 := newRemoteHarness(t, newFakeServer())
	if err := h3.fs.Remove(keyringPath(h3.root)); err != nil {
		t.Fatal(err)
	}
	seedLocal(t, h3, testRFC8032SeedHex)
	rc, logs = h3.runCmd("verify", "--all", "--trusted")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse keyring_missing" {
		t.Fatalf("keyring_missing: rc=%d logs=%v", rc, logs)
	}
	rc, logs = h.runCmd("verify", "--expect="+st.ID+":"+logSHA)
	if rc != 2 || len(logs) != 1 || logs[0] != "flint: refuse usage" {
		t.Fatalf("expect without --all: rc=%d logs=%v", rc, logs)
	}
}

// TestVerifyRemote exercises `flint verify --remote`: the remote head's
// chain is checked against the keyring and prints per-change verdicts.
func TestVerifyRemote(t *testing.T) {
	altPub := pubHexForSeed(t, testAltSeedHex)

	// Trusted chain → per-change verified lines, no writes.
	srv := newFakeServer()
	h := newRemoteHarness(t, srv)
	st, lines := mkSignedStream(t, h, "main", 2)
	srv.addStream(st, lines)

	snap := storeSnapshot(h)
	rc, logs := h.runCmd("verify", "--remote=10.0.0.2:4748", "--stream=main")
	if rc != 0 || len(logs) != 2 {
		t.Fatalf("verify --remote: rc=%d logs=%v", rc, logs)
	}
	for _, l := range logs {
		if !strings.HasSuffix(l, "sig: verified") {
			t.Fatalf("verify line: %q", l)
		}
	}
	assertStoreIdentical(t, h, snap)

	// REMOTE.json binding supplies both remote and stream — bare --remote.
	if err := writeRemoteConfig(h.fs, h.root, RemoteConfig{Remote: "tcp://10.0.0.2:4748", Stream: st.ID}); err != nil {
		t.Fatal(err)
	}
	rc, logs = h.runCmd("verify", "--remote")
	if rc != 0 || len(logs) != 2 {
		t.Fatalf("verify --remote bound: rc=%d logs=%v", rc, logs)
	}
	// --remote=<url> with the binding's stream, no --stream flag.
	rc, logs = h.runCmd("verify", "--remote=10.0.0.2:4748")
	if rc != 0 || len(logs) != 2 {
		t.Fatalf("verify --remote=<url> bound stream: rc=%d logs=%v", rc, logs)
	}

	// Wrong-key publisher → key_unknown.
	srv2 := newFakeServer()
	h2 := newRemoteHarness(t, srv2)
	st2, lines2 := mkSignedStreamSeed(t, h2, "main", 2, testAltSeedHex)
	srv2.addStream(st2, lines2)
	rc, logs = h2.runCmd("verify", "--remote=10.0.0.2:4748", "--stream=main")
	if rc != 1 || len(logs) != 1 || !strings.HasPrefix(logs[0], "flint: refuse key_unknown") {
		t.Fatalf("verify remote wrong key: rc=%d logs=%v", rc, logs)
	}

	// Revoked publisher → key_revoked.
	if err := h2.fs.WriteFileSafe(keyringPath(h2.root), []byte(
		"#v1\nkey="+altPub+" name=alt\nrevoked="+altPub+"\n",
	)); err != nil {
		t.Fatal(err)
	}
	rc, logs = h2.runCmd("verify", "--remote=10.0.0.2:4748", "--stream=main")
	if rc != 1 || len(logs) != 1 || !strings.HasPrefix(logs[0], "flint: refuse key_revoked") {
		t.Fatalf("verify remote revoked: rc=%d logs=%v", rc, logs)
	}

	// Tampered sig from a trusted key → sig_invalid.
	srv3 := newFakeServer()
	h3 := newRemoteHarness(t, srv3)
	st3, lines3 := mkSignedStream(t, h3, "main", 1)
	bad := append([]byte(nil), lines3[0]...)
	i := bytes.LastIndex(bad, []byte(`"sig":"`)) + len(`"sig":"`)
	bad[i] = 'b'
	lines3[0] = bad
	srv3.addStream(st3, lines3)
	rc, logs = h3.runCmd("verify", "--remote=10.0.0.2:4748", "--stream=main")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse sig_invalid" {
		t.Fatalf("verify remote tampered: rc=%d logs=%v", rc, logs)
	}

	// No remote anywhere → remote_missing; unknown stream → stream_missing
	// (with the available-streams hint).
	h4srv := newFakeServer()
	h4 := newRemoteHarness(t, h4srv)
	rc, logs = h4.runCmd("verify", "--remote")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse remote_missing" {
		t.Fatalf("verify remote_missing: rc=%d logs=%v", rc, logs)
	}
	rc, logs = h4.runCmd("verify", "--remote=10.0.0.2:4748")
	if rc != 1 || len(logs) != 1 || logs[0] != "flint: refuse stream_missing" {
		t.Fatalf("verify no stream selector: rc=%d logs=%v", rc, logs)
	}
	st4, lines4 := mkSignedStream(t, h4, "main", 1)
	h4srv.addStream(st4, lines4)
	rc, logs = h4.runCmd("verify", "--remote=10.0.0.2:4748", "--stream=nope")
	if rc != 1 || len(logs) != 1 || !strings.HasPrefix(logs[0], "flint: refuse stream_missing") {
		t.Fatalf("verify stream_missing: rc=%d logs=%v", rc, logs)
	}
}
