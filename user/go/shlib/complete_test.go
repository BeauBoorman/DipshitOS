package shlib

// M98g (issue #2133): the shared completer's contexts — built straight on
// NewCompleter with globHost's scripted ListPath, plus stageCtx's head-word
// detection across | ; &.

import (
	"fmt"
	"testing"

	"virelai/vi"
)

// completeLine runs the completer the way keyTab does: the word is the
// bytes back to the previous space before the cursor (here always end of
// line), and Cmd/ArgIndex come from stageCtx.
func completeLine(sh *Shell, h *globHost, line string) []string {
	start := len(line)
	for start > 0 && line[start-1] != ' ' {
		start--
	}
	cmd, arg := stageCtx(line, start)
	return NewCompleter(sh, h)(CompleteRequest{
		Line: line, Cursor: len(line), WordStart: start,
		Word: line[start:], ArgIndex: arg, Cmd: cmd,
	})
}

func hasCand(c []string, want string) bool {
	for _, s := range c {
		if s == want {
			return true
		}
	}
	return false
}

func TestCompleteHeadWord(t *testing.T) {
	h := newGlobHost()
	h.dirs["/"] = files("GOSH.ELF", "NOTES.TXT", "GOHIDE.BIN")
	sh := newGlobShell(h)
	sh.RunLine("fn f() { echo hi }")
	sh.RunLine("alias ll='ls -l'")
	c := completeLine(sh, h, "e")
	if !hasCand(c, "echo ") || !hasCand(c, "export ") {
		t.Fatalf("builtins missing: %v", c)
	}
	for _, s := range c {
		if s == "NOTES.TXT" {
			t.Fatalf("a bare file completed at the head word: %v", c)
		}
	}
	before := len(h.calls)
	c = completeLine(sh, h, "GO")
	if !hasCand(c, "GOSH.ELF ") || !hasCand(c, "GOHIDE.BIN ") {
		t.Fatalf("executables missing: %v", c)
	}
	if len(h.calls)-before != 1 || h.calls[before] != "/" {
		t.Fatalf("one press listed %v, want exactly one call to /", h.calls)
	}
	c = completeLine(sh, h, "f")
	if !hasCand(c, "f ") || !hasCand(c, "fg ") {
		t.Fatalf("function missing: %v", c)
	}
	c = completeLine(sh, h, "l")
	if !hasCand(c, "ll ") {
		t.Fatalf("alias missing: %v", c)
	}
}

func TestCompleteEnvVars(t *testing.T) {
	h := newGlobHost()
	sh := newGlobShell(h)
	sh.RunLine("set COLOR=red; export PWDX=/x")
	c := completeLine(sh, h, "echo $C")
	if !hasCand(c, "$COLOR") {
		t.Fatalf("$C = %v", c)
	}
	c = completeLine(sh, h, "echo ${C")
	if !hasCand(c, "${COLOR}") {
		t.Fatalf("${C = %v", c)
	}
	if len(h.calls) != 0 {
		t.Fatalf("env completion listed: %v", h.calls)
	}
}

func TestCompletePerCommandArgs(t *testing.T) {
	h := newGlobHost()
	sh := newGlobShell(h)
	sh.RunLine("SLOW.BIN &") // job 1, pid 7 (the fake's pid)
	sh.RunLine("alias gs='git status'")

	c := completeLine(sh, h, "help jo")
	if !hasCand(c, "jobs") {
		t.Fatalf("help jo = %v", c)
	}
	c = completeLine(sh, h, "help fi")
	if !hasCand(c, "files") {
		t.Fatalf("help fi = %v (group names must complete)", c)
	}
	c = completeLine(sh, h, "fg %")
	if !hasCand(c, "%1") {
		t.Fatalf("fg %% = %v", c)
	}
	c = completeLine(sh, h, "kill %")
	if !hasCand(c, "%1") {
		t.Fatalf("kill %% = %v", c)
	}
	c = completeLine(sh, h, "unalias g")
	if !hasCand(c, "gs") {
		t.Fatalf("unalias g = %v", c)
	}
	h.appLogs = map[string][]byte{"vm": nil, "gosh": nil}
	c = completeLine(sh, h, "log v")
	if len(c) != 1 || c[0] != "vm" {
		t.Fatalf("log v = %v, want [vm] from AppLogNames", c)
	}
	if len(h.calls) != 0 {
		t.Fatalf("name contexts must not list: %v", h.calls)
	}
}

func TestCompleteDirsOnlyForCd(t *testing.T) {
	h := newGlobHost()
	h.dirs["/"] = []vi.DirItem{
		{Name: "DATA.TXT"}, {Name: "SUB", IsDir: true},
	}
	sh := newGlobShell(h)
	c := completeLine(sh, h, "cd ")
	if len(c) != 1 || c[0] != "SUB/" {
		t.Fatalf("cd  = %v, want [SUB/] only", c)
	}
	c = completeLine(sh, h, "pushd ")
	if len(c) != 1 || c[0] != "SUB/" {
		t.Fatalf("pushd = %v, want [SUB/] only", c)
	}
	// The default arg context keeps files.
	c = completeLine(sh, h, "cat ")
	if !hasCand(c, "DATA.TXT") || !hasCand(c, "SUB/") {
		t.Fatalf("cat  = %v, want files + dirs", c)
	}
	if len(h.calls) != 3 {
		t.Fatalf("lister calls = %d, want one per press (3)", len(h.calls))
	}
}

func TestCompletePathNarrowing(t *testing.T) {
	h := newGlobHost()
	h.dirs["/docs"] = append(files("README.TXT", "REBUILD.TXT", "NOTES.TXT"),
		vi.DirItem{Name: "INNER", IsDir: true})
	sh := newGlobShell(h)
	c := completeLine(sh, h, "cat docs/RE")
	if len(c) != 2 || c[0] != "docs/README.TXT" || c[1] != "docs/REBUILD.TXT" {
		t.Fatalf("docs/RE = %v", c)
	}
	if h.calls[0] != "/docs" {
		t.Fatalf("listed %v, want /docs", h.calls)
	}
	c = completeLine(sh, h, "cat docs/I")
	if len(c) != 1 || c[0] != "docs/INNER/" {
		t.Fatalf("dir narrowing = %v, want [docs/INNER/]", c)
	}
}

func TestCompleteHiddenRuleAndSize(t *testing.T) {
	h := newGlobHost()
	var items []vi.DirItem
	for i := 0; i < 40; i++ {
		items = append(items, vi.DirItem{Name: "F" + fmt.Sprintf("%02d", i) + ".TXT"})
	}
	items = append(items, vi.DirItem{Name: ".SECRET"})
	h.dirs["/"] = items
	sh := newGlobShell(h)
	c := completeLine(sh, h, "cat F")
	if len(c) != 40 {
		t.Fatalf("cat F = %d cands, want all 40 (past the old 16-row window)", len(c))
	}
	if hasCand(c, ".SECRET") {
		t.Fatal("hidden entry offered without a leading dot")
	}
	c = completeLine(sh, h, "cat .S")
	if len(c) != 1 || c[0] != ".SECRET" {
		t.Fatalf("cat .S = %v, want [.SECRET]", c)
	}
}

func TestCompletePipeStageHead(t *testing.T) {
	h := newGlobHost()
	sh := newGlobShell(h)
	c := completeLine(sh, h, "ls /host | c")
	if !hasCand(c, "cat ") || !hasCand(c, "cd ") {
		t.Fatalf("post-| head = %v, want command candidates", c)
	}
	c = completeLine(sh, h, "ls /host ; c")
	if !hasCand(c, "cat ") {
		t.Fatalf("post-; head = %v", c)
	}
	c = completeLine(sh, h, "cat 'a|b' | c")
	if !hasCand(c, "cat ") {
		t.Fatalf("quoted | must not split: %v", c)
	}
}

func TestCompleteRedirectWords(t *testing.T) {
	h := newGlobHost()
	h.dirs["/"] = files("OUT.TXT")
	sh := newGlobShell(h)
	c := completeLine(sh, h, "cat >O")
	if len(c) != 1 || c[0] != ">OUT.TXT" {
		t.Fatalf(">O = %v, want [>OUT.TXT] — the op stays on the word", c)
	}
	c = completeLine(sh, h, "cat <O")
	if len(c) != 1 || c[0] != "<OUT.TXT" {
		t.Fatalf("<O = %v, want [<OUT.TXT]", c)
	}
}
