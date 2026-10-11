package shlib

import (
	"strings"
	"testing"
)

// The M98j table: every spelling a path can take, with the canonical form
// PWD stores and the bytes the host seam receives. The pass-through rule
// is the interesting column — at `/` nothing is rewritten, so the gates
// that pin typed names stay byte-identical.
func TestCanonPathTable(t *testing.T) {
	cases := []struct {
		pwd, in, wantCanon, wantHost string
	}{
		// Absolute and relative-at-root pass through verbatim.
		{"/", "/data/x", "/data/x", "/data/x"},
		{"/", "X", "/X", "X"},
		{"/", "data/sub", "/data/sub", "data/sub"},
		// Relative at a moved PWD joins onto it.
		{"/data", "sub", "/data/sub", "/data/sub"},
		{"/data", "X", "/data/X", "/data/X"},
		{"/data/sub", "f", "/data/sub/f", "/data/sub/f"},
		// `.` and `..` resolve lexically; `..` clamps at the root.
		{"/data", ".", "/data", "/data"},
		{"/data", "..", "/", "/"},
		{"/", "..", "/", "/"},
		{"/data/sub", "../..", "/", "/"},
		{"/data", "a/../b", "/data/b", "/data/b"},
		{"/", "/data/../x", "/x", "/x"},
		{"/", "data/../x", "/x", "/x"},
		{"/", "a/./b", "/a/b", "/a/b"},
		{"/data/sub", "../sib", "/data/sib", "/data/sib"},
		// `//` collapses in canon but passes through verbatim.
		{"/", "//data//x", "/data/x", "//data//x"},
		{"/", "data/", "/data", "data/"},
		// The host volume maps to the share root, in every spelling.
		{"/", "/host", "/", "/host"},
		{"/", "/host/x", "/x", "/host/x"},
		{"/", "host:x", "/x", "host:x"},
		{"/", "host", "/", "host"},
		{"/", "host/x", "/x", "host/x"},
		{"/data", "/host/x", "/x", "/host/x"},
		{"/data", "host:x", "/x", "host:x"},
		{"/data", "host/sub", "/sub", "host/sub"},
		{"/", "hostile/x", "/hostile/x", "hostile/x"},
		{"/data", "hostile/x", "/data/hostile/x", "/data/hostile/x"},
		// USB volumes are roots wherever they are typed.
		{"/", "/usb1/DOCS", "/usb1/DOCS", "/usb1/DOCS"},
		{"/", "usb1/DOCS", "/usb1/DOCS", "usb1/DOCS"},
		{"/data", "usb1:DOCS", "/usb1/DOCS", "usb1:DOCS"},
		{"/data", "usb1/DOCS", "/usb1/DOCS", "usb1/DOCS"},
		{"/", "USB1/docs", "/usb1/docs", "USB1/docs"},
		{"/", "/usb/x", "/usb/x", "/usb/x"},
		{"/", "usb:x", "/usb/x", "usb:x"},
		{"/data", "usb/x", "/usb/x", "usb/x"},
		{"/data", "usb5:DOCS", "/usb5/DOCS", "usb5:DOCS"},
		// `usb0` is not a volume form — an ordinary host-share name.
		{"/", "usb0/x", "/usb0/x", "usb0/x"},
		// A PWD the user set by hand still resolves honestly.
		{"data", "x", "/data/x", "/data/x"},
		{"/host", "x", "/x", "x"},
		{"/usb1", "DOCS", "/usb1/DOCS", "/usb1/DOCS"},
	}
	for _, tc := range cases {
		h := newFakeHost()
		sh := NewShell(h, &History{})
		sh.env.Set("PWD", tc.pwd)
		rp, err := sh.resolvePath(tc.in)
		if err != nil {
			t.Fatalf("resolvePath(%q @ %q) refused: %v", tc.in, tc.pwd, err)
		}
		if rp.canon != tc.wantCanon || rp.host != tc.wantHost {
			t.Fatalf("resolvePath(%q @ %q) = canon %q host %q; want canon %q host %q",
				tc.in, tc.pwd, rp.canon, rp.host, tc.wantCanon, tc.wantHost)
		}
	}
}

// Bounds are refusals by name, matching the kernel's file-ABI contract
// (file_table.max_path_len = 512, directory.name_max = 255): a result past
// the bound fails loudly, one byte under it passes.
func TestResolvePathBounds(t *testing.T) {
	cases := []struct {
		pwd, in string
		wantErr error
	}{
		// Exactly 512 bytes with every component inside name_max passes.
		{"/", "/" + strings.Repeat("a", 255) + "/" + strings.Repeat("b", 255), nil},
		{"/", "/" + strings.Repeat("a", 255) + "/" + strings.Repeat("b", 255) + "/c", errPathTooLong},
		// One component may not exceed name_max, even inside the path bound.
		{"/", strings.Repeat("a", 255), nil},
		{"/", strings.Repeat("a", 256), errNameTooLong},
		{"/", "/" + strings.Repeat("a", 511), errNameTooLong}, // 512 bytes, one name
		// Joined onto a moved PWD, valid names still refuse over 512.
		{"/data", strings.Repeat("a", 200) + "/" + strings.Repeat("b", 200) + "/" + strings.Repeat("c", 200), errPathTooLong},
		{"/", "", errInvalidPath},
		{"/", "a\x00b", errInvalidPath},
	}
	for _, tc := range cases {
		h := newFakeHost()
		sh := NewShell(h, &History{})
		sh.env.Set("PWD", tc.pwd)
		_, err := sh.resolvePath(tc.in)
		if err != tc.wantErr {
			t.Fatalf("resolvePath(len=%d @ %q) err = %v, want %v",
				len(tc.in), tc.pwd, err, tc.wantErr)
		}
	}
}

// pathRecordingHost records every path handed to the seam so the tests can
// assert which spelling of the path actually left the shell.
type pathRecordingHost struct {
	*fakeHost
	reads  []string
	writes []string
	chmods []string
	chdirs []string
	execs  []string
}

func (h *pathRecordingHost) ReadFile(path string, max int) ([]byte, error) {
	h.reads = append(h.reads, path)
	return h.fakeHost.ReadFile(path, max)
}

func (h *pathRecordingHost) WriteFile(path string, b []byte, appendMode bool) error {
	h.writes = append(h.writes, path)
	return h.fakeHost.WriteFile(path, b, appendMode)
}

func (h *pathRecordingHost) Chmod(path string, mode uint16) error {
	h.chmods = append(h.chmods, path)
	return h.fakeHost.Chmod(path, mode)
}

func (h *pathRecordingHost) Chdir(path string) error {
	h.chdirs = append(h.chdirs, path)
	return h.fakeHost.Chdir(path)
}

func (h *pathRecordingHost) RunExternal(name string, args []string) (int64, error) {
	h.execs = append(h.execs, name)
	return h.fakeHost.RunExternal(name, args)
}

func newPathHost() *pathRecordingHost {
	return &pathRecordingHost{fakeHost: newFakeHost()}
}

func lastOf(list []string) string {
	if len(list) == 0 {
		return ""
	}
	return list[len(list)-1]
}

// After `cd /data` every path-taking verb hands the host the joined path —
// the card's "cd that still matches the share root was theater" checklist.
func TestPathsResolveAgainstRealPwd(t *testing.T) {
	h := newPathHost()
	h.files["/data/X"] = []byte("body\n")
	sh := NewShell(h, &History{})
	run := func(line string) int {
		st, _ := sh.RunLine(line)
		return st
	}
	if st := run("cd /data"); st != 0 {
		t.Fatalf("cd status = %d", st)
	}

	steps := []struct {
		line   string
		record func() string
	}{
		{"cat X", func() string { return lastOf(h.reads) }},
		{"wc -l X", func() string { return lastOf(h.reads) }},
		{"cat < X", func() string { return lastOf(h.reads) }},
		{"echo a > X", func() string { return lastOf(h.writes) }},
		{"echo a >> X", func() string { return lastOf(h.writes) }},
		{"source X", func() string { return lastOf(h.reads) }},
		{"test -e X", func() string { return lastOf(h.reads) }},
		{"chmod 600 X", func() string { return lastOf(h.chmods) }},
	}
	for _, step := range steps {
		run(step.line)
		if got := step.record(); got != "/data/X" {
			t.Fatalf("%q reached the host as %q, want /data/X", step.line, got)
		}
	}
}

// cd stores the canonical form in PWD — `cd sub` joins, `cd ..` climbs.
func TestCdCanonicalizesPwd(t *testing.T) {
	h := newPathHost()
	sh := NewShell(h, &History{})
	run := func(line string) int {
		st, _ := sh.RunLine(line)
		return st
	}
	run("cd /data")
	run("cd sub")
	if st := run("pwd"); st != 0 {
		t.Fatalf("pwd status = %d", st)
	}
	if got := h.outString(); !strings.HasSuffix(got, "/data/sub\n") {
		t.Fatalf("pwd after cd sub = %q, want /data/sub", got)
	}
	if got := lastOf(h.chdirs); got != "/data/sub" {
		t.Fatalf("cd sub reached the host as %q, want /data/sub", got)
	}
	run("cd ..")
	h.out = nil
	run("pwd")
	if got := h.outString(); got != "/data\n" {
		t.Fatalf("pwd after cd .. = %q, want /data", got)
	}
	// And `cd ..` at the root clamps there.
	run("cd /")
	run("cd ..")
	h.out = nil
	run("pwd")
	if got := h.outString(); got != "/\n" {
		t.Fatalf("pwd after cd .. at root = %q, want /", got)
	}
}

// At the share root the typed bytes go through unchanged — the rule that
// keeps every pinned message byte-identical.
func TestPathsAtRootAreByteIdentical(t *testing.T) {
	h := newPathHost()
	h.files["X"] = []byte("body\n")
	sh := NewShell(h, &History{})
	run := func(line string) int {
		st, _ := sh.RunLine(line)
		return st
	}
	run("cat X")
	run("echo a > OUT")
	run("cd data")
	if got := lastOf(h.reads); got != "X" {
		t.Fatalf("cat X reached the host as %q, want X", got)
	}
	if got := lastOf(h.writes); got != "OUT" {
		t.Fatalf("> OUT reached the host as %q, want OUT", got)
	}
	if got := lastOf(h.chdirs); got != "data" {
		t.Fatalf("cd data reached the host as %q, want data", got)
	}
	// But PWD is still the canonical form.
	h.out = nil
	run("pwd")
	if got := h.outString(); got != "/data\n" {
		t.Fatalf("pwd after cd data = %q, want /data", got)
	}
}

// Errors name the typed path even though the host saw the resolved one —
// `cat MISSING` at /data says MISSING, not /data/MISSING.
func TestMessagesNameTheTypedPath(t *testing.T) {
	h := newPathHost()
	sh := NewShell(h, &History{})
	run := func(line string) int {
		st, _ := sh.RunLine(line)
		return st
	}
	run("cd /data")
	if st := run("cat MISSING"); st != 1 {
		t.Fatalf("cat MISSING status = %d, want 1", st)
	}
	if got := h.outString(); !strings.HasSuffix(got, "gosh: MISSING: not found\n") {
		t.Fatalf("cat MISSING message = %q", got)
	}
	// The errno name travels too, still against the typed path.
	h.out = nil
	h.denied = map[string]string{"/data/SECRET": "EACCES"}
	if st := run("cat SECRET"); st != 1 {
		t.Fatalf("cat SECRET status = %d, want 1", st)
	}
	if got := h.outString(); got != "gosh: cannot open SECRET: EACCES\n" {
		t.Fatalf("cat SECRET message = %q", got)
	}
	// And a resolver refusal names the typed path too.
	h.out = nil
	if st := run("cat ''"); st != 1 {
		t.Fatalf("cat '' status = %d, want 1", st)
	}
	if got := h.outString(); !strings.Contains(got, "invalid path") {
		t.Fatalf("cat '' message = %q", got)
	}
}

// `$(cd X)` runs in this Shell — captureLine is in-process — so it moves
// the real PWD. Pinning the side effect keeps a later "fix" from changing
// semantics silently.
func TestDollarCdMovesRealPwd(t *testing.T) {
	h := newPathHost()
	sh := NewShell(h, &History{})
	run := func(line string) int {
		st, _ := sh.RunLine(line)
		return st
	}
	run("cd /data")
	run("echo $(cd sub)")
	h.out = nil
	run("pwd")
	if got := h.outString(); got != "/data/sub\n" {
		t.Fatalf("pwd after $(cd sub) = %q, want /data/sub", got)
	}
}

// A program name containing '/' resolves against PWD; a bare name keeps
// the share-root candidateNames lookup untouched.
func TestExecNameResolvesAgainstPwd(t *testing.T) {
	h := newPathHost()
	sh := NewShell(h, &History{})
	run := func(line string) int {
		st, _ := sh.RunLine(line)
		return st
	}
	run("cd /data")
	run("sub/TOOL arg")
	if got := lastOf(h.execs); got != "/data/sub/TOOL" {
		t.Fatalf("sub/TOOL reached exec as %q, want /data/sub/TOOL", got)
	}
	run("BARETOOL")
	if got := lastOf(h.execs); got != "BARETOOL" {
		t.Fatalf("BARETOOL reached exec as %q, want verbatim", got)
	}
}

// The resolver's own refusals reach the user by name — never a truncated
// path handed to the kernel to fail some other way.
func TestResolveRefusalsAreLoud(t *testing.T) {
	h := newPathHost()
	sh := NewShell(h, &History{})
	run := func(line string) int {
		st, _ := sh.RunLine(line)
		return st
	}
	long := strings.Repeat("a", 256)
	if st := run("cat " + long); st != 1 {
		t.Fatalf("cat long status = %d, want 1", st)
	}
	if got := h.outString(); !strings.Contains(got, "name too long") {
		t.Fatalf("cat long message = %q", got)
	}
	h.out = nil
	if st := run("echo x > " + long); st != 1 {
		t.Fatalf("redirect long status = %d, want 1", st)
	}
	if got := h.outString(); !strings.Contains(got, "name too long") {
		t.Fatalf("redirect long message = %q", got)
	}
	// The line failed before running: nothing was written.
	if len(h.writes) != 0 {
		t.Fatalf("refused redirect still wrote: %v", h.writes)
	}
}
