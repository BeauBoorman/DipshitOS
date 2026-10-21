package main

// The class-A model legs the card names: the expiry compare-before-clear
// rule, the shared-timer deadline math, and zeroing on lock. All pure —
// nanotime is a parameter, the clipboard is a byte slice the test owns.
import (
	"testing"

	"virelai/vi"
)

// The compare rule: the expiry clears ONLY when the clipboard still holds
// exactly our secret — a different body (longer, shorter, different bytes)
// is somebody else's copy and is kept.
func TestClipCompareBeforeClear(t *testing.T) {
	secret := []byte("s3cr3t")
	tag := setClipTag(secret)

	if !tag.holds(secret) {
		t.Fatal("the tag must recognize the secret it was taken from")
	}
	if tag.holds([]byte("s3cr3t!")) {
		t.Fatal("a longer body must not match — length is part of the tag")
	}
	if tag.holds([]byte("s3cr3")) {
		t.Fatal("a shorter body must not match")
	}
	if tag.holds([]byte("S3CR3T")) {
		t.Fatal("different bytes of the same length must not match")
	}
	if tag.holds(nil) {
		t.Fatal("an empty clipboard must not match")
	}
	// A copy of the same bytes matches — the tag is content, not identity.
	if !tag.holds(append([]byte(nil), secret...)) {
		t.Fatal("identical content must match")
	}
	// The tag itself carries no plaintext — wipe leaves an all-zero digest.
	tag.wipe()
	for _, b := range tag.sum {
		if b != 0 {
			t.Fatal("wipe left tag bytes behind")
		}
	}
}

// The two deadlines share one timer: nextDelay always counts toward the
// earlier one, and expired reports them independently.
func TestDeadlineMultiplex(t *testing.T) {
	var d deadlines
	if d.nextDelay(0) != 0 {
		t.Fatal("nothing armed must disarm the timer")
	}
	d.activity(0) // idle due at 300 s
	if got := d.nextDelay(0); got != 300 {
		t.Fatalf("idle-only arm = %d ticks, want 300", got)
	}
	d.armClip(100 * tickNs) // clip due at 130 s
	if got := d.nextDelay(100 * tickNs); got != 30 {
		t.Fatalf("clip arm = %d ticks, want 30 (the earlier deadline)", got)
	}
	// At t=131 the clip fired, the idle did not.
	idle, clip, _ := d.expired(131 * tickNs)
	if !clip || idle {
		t.Fatalf("expired(131s) = idle:%v clip:%v, want clip only", idle, clip)
	}
	// The clip deadline survives lock: only the idle side stops, and the
	// still-live (overdue) clip arm re-arms for one tick — fire now.
	d.stopIdle()
	if got := d.nextDelay(131 * tickNs); got != 1 {
		t.Fatalf("overdue clip must re-arm for 1 tick, got %d", got)
	}
	d.stopClip()
	if got := d.nextDelay(131 * tickNs); got != 0 {
		t.Fatalf("all deadlines done must disarm, got %d", got)
	}
}

// A deadline that arrives between ticks re-arms for one more tick — the
// ceiling rule means a deadline can only fire late, never early.
func TestDeadlineCeiling(t *testing.T) {
	var d deadlines
	d.idleDue = 1500_000_000 // 1.5 s out
	if got := d.nextDelay(0); got != 2 {
		t.Fatalf("1.5s must arm 2 ticks (ceiling), got %d", got)
	}
	if idle, _, _ := d.expired(1 * tickNs); idle {
		t.Fatal("fired early — the ceiling rule exists to prevent this")
	}
	// An overdue deadline arms 1 tick (fire now) rather than 0 or negative.
	d.idleDue = -1
	if got := d.nextDelay(0); got != 0 {
		t.Fatalf("a due-in-the-past 0 deadline must read as disarmed")
	}
	d.clipDue = 10
	if got := d.nextDelay(100 * tickNs); got != 1 {
		t.Fatalf("overdue clip must arm 1 tick, got %d", got)
	}
}

// Lock wipes every byte of session material: the derived key, every field of
// every entry, the passphrase-side state — and the clip lease survives (the
// shared buffer still holds our copy; clearing it is not the vault's choice
// to unmake).
func TestLockZeroesSession(t *testing.T) {
	m := &model{}
	key := []byte("0123456789abcdef0123456789abcdef")
	salt := []byte("fedcba9876543210")
	entries := []entry{
		{name: []byte("wifi"), secret: []byte("s3cr3t"), note: []byte("home")},
	}
	m.unlocked(entries, key, salt, testIters, 0)
	m.sel = 0
	m.toggleReveal()
	m.ctag = setClipTag([]byte("s3cr3t"))
	m.dl.armClip(0)

	keptEntry := m.entries[0]
	keptKey := m.key
	m.lock()

	if m.entries != nil || m.key != nil || m.shown != nil {
		t.Fatal("lock left session slices installed")
	}
	if m.scr != scrLocked {
		t.Fatalf("scr=%d, want scrLocked", m.scr)
	}
	for i, b := range keptKey {
		if b != 0 {
			t.Fatalf("key byte %d survived lock", i)
		}
	}
	for _, f := range [][]byte{keptEntry.name, keptEntry.secret, keptEntry.note} {
		for i, b := range f {
			if b != 0 {
				t.Fatalf("entry field byte %d survived lock", i)
			}
		}
	}
	if m.dl.idleDue != 0 {
		t.Fatal("idle deadline must stop on lock")
	}
	if m.dl.clipDue == 0 {
		t.Fatal("clip deadline must SURVIVE lock — the shared buffer still holds the copy")
	}
	if m.ctag.empty() {
		t.Fatal("the clip tag must also survive — it is the compare token")
	}
}

// Reveal is per entry: one row face-up, the rest still masked; a lock drops
// every reveal with the session.
func TestRevealIsPerEntry(t *testing.T) {
	m := &model{}
	entries := []entry{
		{name: []byte("a"), secret: []byte("sa")},
		{name: []byte("b"), secret: []byte("sb")},
	}
	m.unlocked(entries, make([]byte, 32), make([]byte, 16), testIters, 0)
	m.sel = 1
	m.toggleReveal()
	if !m.revealed(1) || m.revealed(0) {
		t.Fatal("reveal must be per-entry: sel 1 up, sel 0 down")
	}
	m.toggleReveal()
	if m.revealed(1) {
		t.Fatal("second toggle must hide the entry again")
	}
	m.sel = 0
	m.toggleReveal()
	if !m.revealed(0) || m.revealed(1) {
		t.Fatal("reveal state must not leak between entries")
	}
	m.lock()
	if m.shown != nil {
		t.Fatal("lock dropped the reveal table")
	}
}

// The masked field stores bytes so it can be wiped: backspace removes a
// whole rune (and zeroes its bytes), clear() leaves nothing recoverable.
func TestFieldWipesItsBytes(t *testing.T) {
	f := newField("secret", 8, true)
	f.insert('p')
	f.insert('a')
	f.insert('é') // two bytes — the rune-whole case
	if got := f.shown(); got != "***" {
		t.Fatalf("masked show=%q, want three bullets", got)
	}
	f.backspace()
	if string(f.buf) != "pa" {
		t.Fatalf("backspace left %q — must remove the whole é", f.buf)
	}
	f.insert('x')
	f.clear()
	for _, b := range f.buf[:cap(f.buf)] {
		if b != 0 {
			t.Fatal("clear left bytes in the field buffer")
		}
	}
	if got := f.shown(); got != "" {
		t.Fatalf("cleared field shows %q", got)
	}
}

// ensureDirs never offers the mount root the mkdir triple — "/host" answers
// it with EINVAL, not EEXIST (observed on the run-01 gate leg: `save refused
// rc=-1 /host`, and the whole vault chain died behind it). Only components
// BELOW the root are created; EEXIST is a pass and a real refusal propagates.
func TestEnsureDirsSkipsMountRoot(t *testing.T) {
	oldOpen, oldClose := fileOpen, fileClose
	defer func() { fileOpen, fileClose = oldOpen, oldClose }()

	var opened []string
	fileOpen = func(path string, flags uint32) (int64, int64) {
		opened = append(opened, path)
		return 0, int64(vi.ErrFileExists)
	}
	fileClose = func(h int64) {}
	if !ensureDirs("/host/GOVAULT/VAULT.BIN") {
		t.Fatal("ensureDirs refused an all-EEXIST chain")
	}
	if len(opened) != 1 || opened[0] != "/host/GOVAULT" {
		t.Fatalf("opened %v, want exactly [/host/GOVAULT] — the mount root is never created", opened)
	}

	fileOpen = func(path string, flags uint32) (int64, int64) {
		return -1, -int64(vi.ErrEACCES)
	}
	if ensureDirs("/host/GOVAULT/VAULT.BIN") {
		t.Fatal("a refused mkdir below the root must propagate")
	}
}

// addEntry keeps its own copies — the caller's field buffers can be cleared
// without aliasing the stored secret.
func TestAddEntryClones(t *testing.T) {
	m := &model{}
	name, secret, note := []byte("n"), []byte("s"), []byte("t")
	if !m.addEntry(name, secret, note, nil) {
		t.Fatal("addEntry refused a valid entry")
	}
	zero(name)
	zero(secret)
	zero(note)
	if string(m.entries[0].secret) != "s" {
		t.Fatal("the stored entry must not alias the field buffer")
	}
	if m.addEntry(nil, []byte("s"), nil, nil) {
		t.Fatal("a nameless entry must refuse")
	}
	if m.sel != 0 {
		t.Fatalf("sel=%d, want the new row selected", m.sel)
	}
}
