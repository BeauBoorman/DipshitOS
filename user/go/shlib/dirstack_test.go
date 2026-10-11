// M98d directory-stack tests (issue #2130): cd -/OLDPWD, the bounded
// pushd/popd/dirs stack, and the shared-state guarantees — a `source`d
// file and a `$(...)` capture move the real PWD because there are no
// subshells.
package shlib

import (
	"strings"
	"testing"
)

func TestCdDashToggles(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	if st := run("cd data"); st != 0 {
		t.Fatalf("cd data st=%d", st)
	}
	h.out = nil
	if st := run("cd -"); st != 0 || h.outString() != "/\n" {
		t.Fatalf("cd - = %q (st %d), want / printed", h.outString(), st)
	}
	h.out = nil
	if st := run("cd -"); st != 0 || h.outString() != "/data\n" {
		t.Fatalf("second cd - = %q (st %d), want /data", h.outString(), st)
	}
}

func TestCdDashNoOldpwd(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	st, _ := sh.RunLine("cd -")
	if st != 1 || h.outString() != "gosh: cd: OLDPWD not set\n" {
		t.Fatalf("cd - unset = %q (st %d)", h.outString(), st)
	}
	if sh.Pwd() != "/" {
		t.Fatalf("PWD moved on refused cd -: %q", sh.Pwd())
	}
	// An emptied OLDPWD is the same refusal.
	h.out = nil
	sh.RunLine("set OLDPWD=")
	st, _ = sh.RunLine("cd -")
	if st != 1 || h.outString() != "gosh: cd: OLDPWD not set\n" {
		t.Fatalf("cd - empty = %q (st %d)", h.outString(), st)
	}
}

func TestOldpwdOnlyOnSuccess(t *testing.T) {
	h := newFakeHost()
	h.chdirErr = map[string]string{"/gone": "ENOENT"}
	sh := NewShell(h, &History{})
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	run("cd data")
	h.out = nil
	run("cd /gone")
	if !strings.Contains(h.outString(), "ENOENT") {
		t.Fatalf("failed cd message = %q", h.outString())
	}
	h.out = nil
	run("echo OLD=$OLDPWD")
	if h.outString() != "OLD=/\n" {
		t.Fatalf("OLDPWD after failed cd = %q, want OLD=/", h.outString())
	}
}

func TestPushdPopdRoundTrip(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	st := run("pushd data")
	if st != 0 || h.outString() != "/data /\n" {
		t.Fatalf("pushd data = %q (st %d)", h.outString(), st)
	}
	h.out = nil
	run("pushd sub")
	if h.outString() != "/data/sub /data /\n" {
		t.Fatalf("second pushd = %q", h.outString())
	}
	h.out = nil
	run("dirs")
	if h.outString() != "/data/sub /data /\n" {
		t.Fatalf("dirs = %q", h.outString())
	}
	h.out = nil
	run("popd")
	if h.outString() != "/data /\n" || sh.Pwd() != "/data" {
		t.Fatalf("popd = %q PWD=%q", h.outString(), sh.Pwd())
	}
	h.out = nil
	run("popd")
	if h.outString() != "/\n" || sh.Pwd() != "/" {
		t.Fatalf("second popd = %q PWD=%q", h.outString(), sh.Pwd())
	}
}

func TestPushdBoundRefuses(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	for i := 0; i < 8; i++ {
		run("pushd d" + string(rune('a'+i)))
	}
	pwd := sh.Pwd()
	h.out = nil
	st := run("pushd ninth")
	if st != 1 || h.outString() != "gosh: pushd: directory stack full (8)\n" {
		t.Fatalf("9th pushd = %q (st %d)", h.outString(), st)
	}
	if sh.Pwd() != pwd || len(sh.dirstack) != 8 {
		t.Fatalf("refused pushd changed state: PWD=%q stack=%d", sh.Pwd(), len(sh.dirstack))
	}
}

func TestPopdEmptyAndStale(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	st := run("popd")
	if st != 1 || h.outString() != "gosh: popd: directory stack empty\n" {
		t.Fatalf("empty popd = %q (st %d)", h.outString(), st)
	}
	// A stale entry — the host now refuses the stack top — reports like
	// `cd` would and stays on the stack. (/ok lands on the stack via a
	// cd into it followed by a pushd out.)
	run("cd ok")
	run("pushd elsewhere")
	h.chdirErr = map[string]string{"/ok": "ENOENT"}
	h.out = nil
	st = run("popd")
	if st != 1 || h.outString() != "gosh: cd: /ok: ENOENT\n" {
		t.Fatalf("stale popd = %q (st %d)", h.outString(), st)
	}
	if len(sh.dirstack) != 1 || sh.dirstack[0] != "/ok" {
		t.Fatalf("stale popd popped the stack: %v", sh.dirstack)
	}
	if sh.Pwd() != "/ok/elsewhere" {
		t.Fatalf("stale popd moved PWD: %q", sh.Pwd())
	}
}

func TestPushdBareSwap(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	st := run("pushd")
	if st != 1 || h.outString() != "gosh: pushd: no other directory\n" {
		t.Fatalf("bare pushd empty = %q (st %d)", h.outString(), st)
	}
	run("pushd data")
	h.out = nil
	run("pushd")
	if h.outString() != "/ /data\n" || sh.Pwd() != "/" {
		t.Fatalf("bare pushd swap = %q PWD=%q", h.outString(), sh.Pwd())
	}
	h.out = nil
	run("pushd")
	if h.outString() != "/data /\n" || sh.Pwd() != "/data" {
		t.Fatalf("swap back = %q PWD=%q", h.outString(), sh.Pwd())
	}
}

func TestStackSharedBySourceAndSubst(t *testing.T) {
	h := newFakeHost()
	h.files["PUSH.SH"] = []byte("pushd /via\n")
	sh := NewShell(h, &History{})
	run := func(line string) int { st, _ := sh.RunLine(line); return st }
	st := run("source PUSH.SH")
	if st != 0 {
		t.Fatalf("source st=%d out=%q", st, h.outString())
	}
	if sh.Pwd() != "/via" || len(sh.dirstack) != 1 || sh.dirstack[0] != "/" {
		t.Fatalf("sourced pushd: PWD=%q stack=%v", sh.Pwd(), sh.dirstack)
	}
	// `$(pushd X)` moves the REAL PWD — no subshell — and the captured
	// dirs line splices into the outer word.
	h.out = nil
	run("echo $(pushd /cap)")
	if h.outString() != "/cap /via /\n" {
		t.Fatalf("captured pushd = %q", h.outString())
	}
	if sh.Pwd() != "/cap" {
		t.Fatalf("$(pushd) did not move PWD: %q", sh.Pwd())
	}
}

func TestDirsArgsRefused(t *testing.T) {
	h := newFakeHost()
	sh := NewShell(h, &History{})
	st, _ := sh.RunLine("dirs -v")
	if st != 2 || h.outString() != "gosh: dirs: usage: dirs\n" {
		t.Fatalf("dirs -v = %q (st %d)", h.outString(), st)
	}
}
