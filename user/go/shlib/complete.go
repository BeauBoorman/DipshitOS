// complete.go — M98g (issue #2133): contextual Tab completion, shared.
//
// keyTab hands the completer a CompleteRequest instead of a bare word, and
// NewCompleter answers the candidate set for the context that request is
// in: the head word completes commands (builtins, tools, functions,
// aliases, share executables); an argument completes by the command it
// belongs to (help, fg/kill, alias/unalias, log, cd/pushd); a `$` word
// completes env names; everything else — and every redirect target —
// completes files and directories.
//
// Listings go through the M98a dirLister seam exactly once per Tab press:
// one ListPath call, shared by every matcher that wants the directory.
// Both front-ends wire `editor.Complete = NewCompleter(sh, host)` — the
// duplicated completeFn copies in sh/ and term/ are gone.
package shlib

import (
	"sort"
	"strings"

	"virelai/vsys"
)

// CompleteRequest is the context the editor hands the completer for one
// Tab press. Word is the bytes being completed; everything else names
// where that word sits.
type CompleteRequest struct {
	Line      string // the whole line buffer
	Cursor    int    // cursor byte offset in Line
	WordStart int    // byte offset where Word begins
	Word      string // Line[WordStart:Cursor]
	ArgIndex  int    // 0 = the head word of the stage; N = its Nth argument
	Cmd       string // head word of the stage Word sits in
}

// appLogNamer is the optional host seam `log` completion lists through —
// the same one bLog already uses, minus the reader half.
type appLogNamer interface {
	AppLogNames() []string
}

// stageCtx finds the head word and argument index of the stage the word at
// wordStart belongs to: the last unquoted `|`, `;` or `&` in the text
// before the word starts a new stage, and tokens are space-separated (the
// editor's word boundary — unchanged by design).
func stageCtx(line string, wordStart int) (cmd string, argIndex int) {
	cut := 0
	inS, inD := false, false
	for i := 0; i < wordStart; i++ {
		switch c := line[i]; {
		case inS:
			inS = c != '\''
		case inD:
			inD = c != '"'
		case c == '\'':
			inS = true
		case c == '"':
			inD = true
		case c == '|' || c == ';' || c == '&':
			cut = i + 1
		}
	}
	// Tokenize the stage text that precedes the word: the first token is
	// the head, the count of tokens is the word's argument index.
	fields := strings.Fields(line[cut:wordStart])
	if len(fields) > 0 {
		cmd = fields[0]
	}
	return cmd, len(fields)
}

// NewCompleter is the shared Tab completer: one implementation over the
// Shell's state (env, aliases, functions, jobs, PWD) and the host's
// dirLister. A nil lister — or a listing refusal — leaves the name-based
// candidates working and the file set empty.
func NewCompleter(sh *Shell, l dirLister) func(CompleteRequest) []string {
	return func(req CompleteRequest) []string {
		// A `<`/`>`/`>>` prefix rides on the word (the boundary is space,
		// so `>FILE` arrives whole): strip it for matching, keep it on
		// every candidate.
		pre := 0
		for pre < len(req.Word) && (req.Word[pre] == '<' || req.Word[pre] == '>') {
			pre++
		}
		redir, word := req.Word[:pre], req.Word[pre:]

		// $NAME / ${NAME}: env names. The ${ form closes the brace.
		if strings.HasPrefix(word, "$") {
			return envCands(sh, redir, word)
		}

		// The head word (a bare name — anything with `/` or a redirect is
		// a path/exec, which the file context handles).
		if req.ArgIndex == 0 && pre == 0 && !strings.Contains(word, "/") {
			return headCands(sh, l, word)
		}

		// Per-command argument contexts.
		if req.ArgIndex > 0 {
			if req.Cmd == "cd" || req.Cmd == "pushd" {
				return fileCands(sh, l, redir, word, true)
			}
			if c, ok := argCands(sh, req.Cmd, word); ok {
				return prefixEach(c, redir)
			}
		}

		return fileCands(sh, l, redir, word, false)
	}
}

// envCands completes $NAME / ${NAME against the shell's env table.
func envCands(sh *Shell, redir, word string) []string {
	var names []string
	for _, v := range sh.env.List() {
		names = append(names, v.name)
	}
	sort.Strings(names)
	var out []string
	if strings.HasPrefix(word, "${") {
		want := word[2:]
		for _, n := range names {
			if strings.HasPrefix(n, want) {
				out = append(out, redir+"${"+n+"}")
			}
		}
		return out
	}
	want := word[1:]
	for _, n := range names {
		if strings.HasPrefix(n, want) {
			out = append(out, redir+"$"+n)
		}
	}
	return out
}

// headCands completes the command word: builtins, tools, functions and
// aliases plus *.ELF/*.BIN from the share root — bare names always resolve
// at the root (candidateNames is the shell's PATH), so the root listing is
// the right and only list, keeping one ListPath call per press. Command
// candidates carry the trailing space, as they always have.
func headCands(sh *Shell, l dirLister, word string) []string {
	var out []string
	seen := map[string]bool{}
	add := func(n string) {
		if n == "" || seen[n] || !strings.HasPrefix(n, word) {
			return
		}
		if strings.HasPrefix(n, ".") && !strings.HasPrefix(word, ".") {
			return
		}
		seen[n] = true
		out = append(out, n+" ")
	}
	for _, n := range BuiltinNames() {
		add(n)
	}
	for _, n := range ToolNames() {
		add(n)
	}
	for _, f := range sh.funcs.funcs {
		add(f.name)
	}
	for _, n := range sh.aliasNames() {
		add(n)
	}
	if l != nil {
		if items, err := l.ListPath("/"); err == nil {
			for _, it := range items {
				if it.IsDir {
					continue
				}
				up := strings.ToUpper(it.Name)
				if strings.HasSuffix(up, ".ELF") || strings.HasSuffix(up, ".BIN") {
					add(it.Name)
				}
			}
		}
	}
	return out
}

// argCands is the per-command argument context switch. ok=false means the
// command has no special context and the caller falls to files+dirs.
func argCands(sh *Shell, cmd, word string) ([]string, bool) {
	switch cmd {
	case "help":
		return helpCands(word), true
	case "fg", "kill":
		var out []string
		for _, j := range sh.jobs {
			n := "%" + vsys.Itoa64(int64(j.N))
			if strings.HasPrefix(n, word) {
				out = append(out, n)
			}
		}
		return out, true
	case "alias", "unalias":
		var out []string
		for _, n := range sh.aliasNames() {
			if strings.HasPrefix(n, word) {
				out = append(out, n)
			}
		}
		return out, true
	case "log":
		if r, ok := sh.host.(appLogNamer); ok {
			var out []string
			for _, n := range r.AppLogNames() {
				if strings.HasPrefix(n, word) {
					out = append(out, n)
				}
			}
			return out, true
		}
		return nil, true
	}
	return nil, false
}

// helpCands completes help's argument: catalog names plus group names.
func helpCands(word string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(n string) {
		if !seen[n] && strings.HasPrefix(n, word) {
			seen[n] = true
			out = append(out, n)
		}
	}
	for name, e := range helpCatalog {
		add(name)
		add(e.group)
	}
	sort.Strings(out)
	return out
}

// fileCands completes files (and directories, with a trailing `/`) for the
// word: a `/` in it narrows to that directory's listing, resolved against
// PWD. dirsOnly is the cd/pushd context. Exactly one ListPath call.
func fileCands(sh *Shell, l dirLister, redir, word string, dirsOnly bool) []string {
	if l == nil {
		return nil
	}
	dirPart, tail := "", word
	if i := strings.LastIndexByte(word, '/'); i >= 0 {
		dirPart, tail = word[:i+1], word[i+1:]
	}
	dir := dirPart
	if dir == "" {
		dir = sh.Pwd()
	}
	rp, err := sh.resolvePath(dir)
	if err != nil {
		return nil
	}
	items, err := l.ListPath(rp.canon)
	if err != nil {
		return nil
	}
	showHidden := strings.HasPrefix(tail, ".")
	var out []string
	for _, it := range items {
		if !showHidden && strings.HasPrefix(it.Name, ".") {
			continue
		}
		if !strings.HasPrefix(it.Name, tail) {
			continue
		}
		cand := redir + dirPart + it.Name
		if it.IsDir {
			out = append(out, cand+"/")
		} else if !dirsOnly {
			out = append(out, cand)
		}
	}
	return out
}

// prefixEach prepends the kept redirect prefix to every candidate.
func prefixEach(c []string, redir string) []string {
	if redir == "" {
		return c
	}
	out := make([]string, len(c))
	for i, s := range c {
		out[i] = redir + s
	}
	return out
}
