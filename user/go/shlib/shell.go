// Package shlib is the GOSH shell core (M73b, issue #1626): the execution
// engine — the environment table, the job table (real background jobs — the
// M65c goroutine-to-guest-thread mapping makes the EL1 monitor's
// `exec &`/`jobs`/`fg` machine available at EL0 for the first time), the
// builtin set, and the pipe/redirect execution paths — plus the line editor,
// the parser and control flow, the toolbox, the history file at the host
// seam, and the net-auth verifier. It is the importable half of GOSH: no
// `package main`, and no per-process mutable globals (shell state lives in
// the Shell/Editor/History values the caller drives; the builtin/tool/help
// tables are write-once registries filled by init).
//
// Pure code: every kernel touch goes through the Host seam the front-end
// implements (user/go/sh's goshHost over vi; the host tests' fakeHost).
package shlib

import (
	"errors"
	"sort"
	"strings"

	"virelai/vsys"
)

// MaxPipeBytes mirrors the kernel's per-process 4 KiB pipe buffer: a
// pipeline hand-off carries at most that much (kernel/src/pipe.zig
// pipe_capacity; slots are per-process since M97g #2081).
const MaxPipeBytes = 4096

// maxJobs is the background-job table bound (the EL1 monitor's bg_jobs
// table holds 4; GOSH allows 8 — still bounded, honest refusal past it).
const maxJobs = 8

// maxRedirectBytes bounds one `>` capture. The engine must not import vi,
// so this mirrors vi.MaxFileBytes (256 KiB): past it the line fails loudly
// instead of growing the guest heap without bound.
const maxRedirectBytes = 256 * 1024

// maxSourceBytes bounds one `source FILE`. SH.BIN read the first 2048 bytes
// and said nothing about the rest; a file larger than the bound is refused
// loudly here instead, because silently running half a script is exactly the
// failure this shell refuses elsewhere (the 4 KiB pipe and redirect bounds).
const maxSourceBytes = 8192

// boundedCapture collects a command's output up to lim bytes and records
// whether the producer ran past it, so the caller can fail the line loudly
// rather than write a silently clipped file or hand a pipe stage short
// input (the kernel's atomic pipe refusal would never fire).
type boundedCapture struct {
	buf  []byte
	lim  int
	over bool
}

func (c *boundedCapture) write(b []byte) {
	if c.over {
		return
	}
	if len(c.buf)+len(b) > c.lim {
		c.over = true
		return
	}
	c.buf = append(c.buf, b...)
}

// errTooLarge is the bounded-read refusal: silent truncation is worse than
// an error, because the command would compute on short input and still
// exit 0.
var errTooLarge = errors.New("input exceeds the 4096-byte buffer")

// OpenError is a file-ABI refusal that carries the KERNEL's errno name. The
// M50 trust boundary makes the difference load-bearing: an ownership denial
// (EACCES) and an absent file (ENOENT) are different facts, and a shell that
// prints "not found" for both hides the whole trust surface from the user
// (and from the gate that asserts it).
type OpenError struct {
	path string
	name string
}

func (e *OpenError) Error() string { return e.name }

// deniedAs reports err as an OpenError when it is one.
func deniedAs(err error) (*OpenError, bool) {
	var oe *OpenError
	if errors.As(err, &oe) {
		return oe, true
	}
	return nil, false
}

// readBounded reads at most MaxPipeBytes of path, refusing a larger file.
// The path resolves against PWD first (M98j): every caller names the typed
// argument in its message, while the host sees the resolved form.
func (s *Shell) readBounded(path string) ([]byte, error) {
	rp, err := s.resolvePath(path)
	if err != nil {
		return nil, err
	}
	b, err := s.host.ReadFile(rp.host, MaxPipeBytes+1)
	if err != nil {
		return nil, err
	}
	if len(b) > MaxPipeBytes {
		return nil, errTooLarge
	}
	return b, nil
}

// readInput reads one redirect's input file, printing its own refusal.
func (s *Shell) readInput(path string) ([]byte, bool) {
	b, err := s.readBounded(path)
	switch {
	case err == errTooLarge:
		s.host.Out([]byte("gosh: " + path + ": " + errTooLarge.Error() + "\n"))
		return nil, false
	case err != nil:
		s.host.Out([]byte(openDenial(path, err)))
		return nil, false
	}
	return b, true
}

// openDenial renders a failed open the way the shell reports one: the
// kernel's errno name when the seam supplied one, a resolution refusal
// when the path never reached the seam, and the plain "not found"
// fallback otherwise. The path printed is always the TYPED one — the
// OpenError's own path field is the resolved form the host saw (M98j).
func openDenial(path string, err error) string {
	if oe, ok := deniedAs(err); ok {
		return "gosh: cannot open " + path + ": " + oe.name + "\n"
	}
	if msg := resolveDenial(err); msg != "" {
		return "gosh: " + path + ": " + msg + "\n"
	}
	return "gosh: " + path + ": not found\n"
}

// Action tells the glue what to do after the current line.
type Action int

const (
	ActionContinue Action = iota
	ActionExit            // exit [n]: leave the shell with the line's status
	ActionMonitor         // monitor: detach the front-end and return to the kernel monitor
)

// Host is the engine's single seam to the system (implemented over vi in
// main.go, faked in host tests).
type Host interface {
	// Marker prints a gate-observable lifecycle line (single write).
	Marker(line string)
	// Principal gives the calling process's identity (slot 68), or ok=false
	// when the seam cannot answer. `whoami`/`id` print it.
	Principal() (uid uint32, caps uint32, ok bool)
	// Chmod applies the owner-only mode change (slot 69). The kernel is the
	// authority; the shell only forwards the octal mode.
	Chmod(path string, mode uint16) error
	// SecretNames lists the CALLER's entry names from the secret store
	// (slot 70). Values are deliberately not part of this seam: the shell
	// prints names only (ADR 0024 D8).
	SecretNames() ([]string, bool)
	// Out writes command output (the tty grid in the glue's tab mode).
	Out(b []byte)
	// RunExternal tries the SH.BIN candidate names for name against the
	// exec seam and returns the new pid, or an error when none loads.
	RunExternal(name string, args []string) (int64, error)
	// WaitExternal blocks until pid exits and returns its status.
	WaitExternal(pid int64) (int64, error)
	// ProbeExternal scans the registry once: (status, state) with state
	// ProbeRunning/ProbeExited/ProbeAbsent (vi.Probe semantics).
	ProbeExternal(pid int64) (int64, int)
	// SleepTick parks the caller for one scheduler tick.
	SleepTick()
	// PipeWrite stores b in the kernel pipe (at most MaxPipeBytes).
	PipeWrite(b []byte) error
	// PipeReadAll drains the kernel pipe (never blocks past what is in it).
	PipeReadAll() ([]byte, error)
	// ReadFile reads at most max bytes of path.
	ReadFile(path string, max int) ([]byte, error)
	// WriteFile writes b to path (truncating, or appending when appendMode).
	WriteFile(path string, b []byte, appendMode bool) error
	// DeleteFile removes path; a missing path is not an error (M98h's
	// edit temp lifecycle).
	DeleteFile(path string) error
	// Chdir validates that path is enterable (a directory).
	Chdir(path string) error
	// ReadTTYLine reads one line from the terminal (`read VAR` unbound).
	ReadTTYLine() (string, bool)
	// SleepSeconds parks the caller for about n seconds.
	SleepSeconds(n int)
	// Suspend runs one virelai-ctl/1 `suspend` session on the caller's
	// behalf (M115d, slot 93): the kernel authenticates with its
	// uid_system credential and relays the host's verdict — the seam
	// carries no credential bytes by design. ok=true only when the reply
	// was `ok:true` (for suspend that return may land on the far side of
	// a host save/restore — the caller's next instruction is the
	// resume); a refused session reports its ADR 0056 code name.
	Suspend() (ok bool, code string)
}

// Env is the shell-local variable table: insertion-ordered, with the
// exported flag kept for `export`'s honesty (nothing reads it — the EL0
// exec seam carries argv only, exactly as SH.BIN documents its own table).
type Env struct {
	vars []envVar
}

type envVar struct {
	name     string
	val      string
	exported bool
}

// NewEnv seeds the table with PWD (SH.BIN seeds the same one variable).
func NewEnv() *Env {
	return &Env{vars: []envVar{{name: "PWD", val: "/", exported: true}}}
}

func (e *Env) Get(name string) (string, bool) {
	for i := range e.vars {
		if e.vars[i].name == name {
			return e.vars[i].val, true
		}
	}
	return "", false
}

func (e *Env) Set(name, val string) {
	if name == "" {
		return
	}
	for i := range e.vars {
		if e.vars[i].name == name {
			e.vars[i].val = val
			return
		}
	}
	e.vars = append(e.vars, envVar{name: name, val: val})
}

func (e *Env) Unset(name string) bool {
	for i := range e.vars {
		if e.vars[i].name == name {
			e.vars = append(e.vars[:i], e.vars[i+1:]...)
			return true
		}
	}
	return false
}

func (e *Env) Export(name string) bool {
	for i := range e.vars {
		if e.vars[i].name == name {
			e.vars[i].exported = true
			return true
		}
	}
	return false
}

// List returns the table in insertion order (env/set print it).
func (e *Env) List() []envVar { return e.vars }

// Pairs renders the table as "NAME=VALUE" strings in insertion order —
// the M125e (#2590) session-state surface: GOTERM serializes this list
// verbatim into its saved blob and a restore Set()s each pair back. The
// exported flag is bookkeeping nothing outside Env reads, so the wire
// does not carry it.
func (e *Env) Pairs() []string {
	out := make([]string, len(e.vars))
	for i, v := range e.vars {
		out[i] = v.name + "=" + v.val
	}
	return out
}

// Job is one background child. Reaping is main-loop polling (the EL1
// monitor's idle-path reaper shape): ReapJobs probes each live pid once
// per shell loop tick, and fg blocks by polling between ticks — no waiter
// thread, so a job's exec never races a sibling thread spawn.
type Job struct {
	N       int
	PID     int64
	Display string
	Done    bool
	Seen    bool // the child was observed running at least once
	Status  int64
}

// Probe states mirrored from vi (the engine must not import vi).
const (
	probeAbsent  = 0
	probeRunning = 1
	probeExited  = 2
)

// cmdCtx is one builtin/tool invocation.
type cmdCtx struct {
	sh    *Shell
	name  string   // the command word (tools like `[` branch on it)
	args  []string // after the command word
	stdin []byte
	out   func([]byte)
	// M98e (issue #2131): where stdin and out were wired, because nil bytes
	// cannot say it — an empty pipe and an unbound stdin look identical
	// (stdinBound), and a tool needs to know when its output is collected
	// rather than printed (outCaptured).
	stdinBound  bool // stdin came from a pipe or < FILE
	outCaptured bool // out is a pipe stage, redirect or $(...) capture
}

// Shell is the interpreter state for one GOSH process.
type Shell struct {
	env       *Env
	hist      *History
	host      Host
	status    int // $?
	jobs      []*Job
	nextN     int
	exitReq   bool
	monitorRq bool
	// M98h: the last top-level line's wall time feeds the \D prompt escape
	// and EditLine's temp names get a per-shell counter.
	lastDurNs int64
	editSeq   int
	// M19 scripting (slice 4 of #1450).
	funcs     funcTable
	sourceReq string  // set by the `source` builtin; runSegment resolves it
	capture   *[]byte // non-nil while a `$(...)` is collecting output
	loopBreak bool
	loopCont  bool
	dirstack  []string          // M98d pushd/popd stack, canonical paths, top at end
	aliases   map[string]string // M98b alias table; nil until first define
	// M138a: collected heredoc bodies, keyed by the marked path the
	// `<<WORD` rewrite produces; hdSeq makes each key unique.
	hdBodies map[string]hdBody
	hdSeq    int
}

// NewShell wires a fresh interpreter; hist may be shared with the editor.
func NewShell(host Host, hist *History) *Shell {
	return &Shell{env: NewEnv(), hist: hist, host: host}
}

// Status reports the last line's exit status ($?).
func (s *Shell) Status() int { return s.status }

// Pwd is the shell's working directory as the shell itself tracks it: the
// PWD that `cd` sets and `pwd` prints (NewEnv seeds "/"). The prompt's
// `\w` and `\W` read this, so they cannot disagree with `pwd` -- the point
// of the escape is to show the directory the shell is really in.
func (s *Shell) Pwd() string {
	if v, _ := s.env.Get("PWD"); v != "" {
		return v
	}
	return "/"
}

// Env exposes the variable table for M125e (#2590) session restore: the
// front-end applies a serialized Pairs() list through Set — the same
// primitive `set` uses — so a restored table is indistinguishable from
// a typed one.
func (s *Shell) Env() *Env { return s.env }

// RunLine interprets one command line and returns (status, Action). An
// empty or comment-only line is a no-op that leaves $? alone. The
// escMark strip lives here — at the true entry point — and in runSource,
// because runLine is also the recursion point for chain segments,
// construct bodies and if/while conditions: text those paths carry may
// legitimately hold marks that $(...) splicing inserted (M98a marks
// captured glob metacharacters literal), and stripping on every entry
// would silently un-literal them a hop later.
// RunLine is the front-end's entry point: one typed line. Depth-0 lines are
// timed for the \D prompt escape (M98h); an empty line leaves both the last
// duration and $? untouched, the way a bare Enter leaves $? alone.
func (s *Shell) RunLine(line string) (int, Action) {
	return s.RunLineBodies(line, nil)
}

// RunLineBodies is RunLine with the line's heredoc bodies already
// collected by the caller's line source (M138a): the front-end drives
// HeredocReader over continuation lines, a script reader feeds the file's
// next lines, and a caller with neither gets the named unterminated
// refusal for any `<<` the line declares.
func (s *Shell) RunLineBodies(line string, bodies [][]byte) (int, Action) {
	stripped := stripEscMarks(line)
	if trimSpace(stripped) == "" {
		return s.runLineBodies(stripped, bodies, 0)
	}
	start := timeMono()
	st, act := s.runLineBodies(stripped, bodies, 0)
	s.lastDurNs = timeMono() - start
	return st, act
}

// stripEscMarks removes the parser sentinels from a raw line. escMark
// only ever means "this byte was quoted" within one parse, so a byte
// arriving from a file, a sourced script, or a program's captured output
// must not be able to make the expander treat what follows as literal;
// hdMark (M138a) gets the same strip so outside text cannot forge a
// heredoc body reference. Byte-wise rather than rune-wise: an invalid
// UTF-8 byte is passed through instead of being folded to U+FFFD.
func stripEscMarks(line string) string {
	if strings.IndexByte(line, escMark) < 0 && strings.IndexByte(line, hdMark) < 0 {
		return line
	}
	out := make([]byte, 0, len(line))
	for i := 0; i < len(line); i++ {
		if line[i] != escMark && line[i] != hdMark {
			out = append(out, line[i])
		}
	}
	return string(out)
}

// runLine is the M19 dispatcher (slice 4 of #1450): the ladder of
// user/src/sh.zig runLine, in the same order — function definition, command
// substitution, if/for/while/case, `;`/`&&`/`||` chains, then the
// per-segment pipeline/redirect/simple path.
func (s *Shell) runLine(raw string, depth int) (int, Action) {
	line := trimSpace(raw)
	if line == "" {
		return s.status, ActionContinue
	}
	if len(line) > maxLineBytes {
		s.fail("line exceeds " + vsys.Itoa64(maxLineBytes) + " bytes")
		s.status = 1
		return 1, ActionContinue
	}
	if depth > runDepthMax {
		// The reference returned silently; a shell that stops without saying
		// so turns a nesting bug into a mystery.
		s.fail("script nesting exceeds " + vsys.Itoa64(runDepthMax) + " levels")
		s.status = 2
		return 2, ActionContinue
	}
	if isFuncDefLine(line) {
		// Faithful to sh.zig: a successful definition reports `fn: ok` and
		// leaves $? alone; a refused one is the only failure.
		rest := line[2:]
		if len(line) > 2 && (line[2] == ' ' || line[2] == '\t') {
			rest = line[3:]
		}
		def, ok := parseFuncDef(rest)
		if !ok || !s.funcs.define(def) {
			s.out([]byte("fn: bad definition\n"))
			s.status = 1
			return 1, ActionContinue
		}
		s.out([]byte("fn: ok\n"))
		return s.status, ActionContinue
	}
	substituted := line
	if !strings.HasPrefix(line, "for") && !strings.HasPrefix(line, "while") {
		// A loop's body is expanded when each iteration runs it, so a
		// for/while line is not substituted as a whole (sh.zig runLine).
		var act Action
		substituted, act = s.commandSubst(line, depth)
		if act != ActionContinue {
			return s.status, act
		}
	}
	if st, ok := parseIf(substituted); ok {
		return s.runIf(st, depth)
	}
	// A `for` word list or `case` arm list past its bound is REFUSED rather
	// than truncated: the reference filled its fixed array and dropped the
	// tail, which silently ran a different loop / matched nothing.
	if f, ok, tooMany := parseFor(substituted); tooMany {
		s.fail("for word list too long (at most " + vsys.Itoa64(forWordMax) + " words)")
		s.status = 2
		return 2, ActionContinue
	} else if ok {
		return s.runFor(f, depth)
	}
	if w, ok := parseWhile(substituted); ok {
		return s.runWhile(w, depth)
	}
	if c, ok, tooMany := parseCase(substituted); tooMany {
		s.fail("case has too many arms (at most " + vsys.Itoa64(caseArmMax) + ")")
		s.status = 2
		return 2, ActionContinue
	} else if ok {
		return s.runCase(c, depth)
	}
	segs, ops, tooMany := chainSplit(substituted)
	if tooMany {
		s.fail("chain too long (at most " + vsys.Itoa64(chainMax) + " segments)")
		s.status = 2
		return 2, ActionContinue
	}
	if len(ops) == 0 {
		return s.runSegment(substituted, depth)
	}
	return s.runChain(segs, ops, depth)
}

// runChain runs `;`/`&&`/`||` segments left to right at equal precedence. A
// skipped segment leaves $? untouched, so `false && echo NOPE` still reports
// the failed condition.
func (s *Shell) runChain(segs []string, ops []chainOp, depth int) (int, Action) {
	for i := range segs {
		run := true
		if i > 0 {
			switch ops[i-1] {
			case opAnd:
				run = s.status == 0
			case opOr:
				run = s.status != 0
			}
		}
		if !run || segs[i] == "" {
			continue
		}
		st, act := s.runLine(segs[i], depth)
		if act != ActionContinue {
			return st, act
		}
	}
	return s.status, ActionContinue
}

// runSegment executes one chain segment: alias expansion on the raw text
// (M98b — the head word and the head after the single unquoted `|`), then
// arithmetic expansion, then the pipeline/redirect/background path, then
// a deferred `source`.
func (s *Shell) runSegment(line string, depth int) (int, Action) {
	line, aerr := s.expandAliases(line)
	if aerr != nil {
		s.fail(aerr.Error())
		s.status = 1
		return 1, ActionContinue
	}
	toks, err := tokenize(arithExpand(line))
	if err != nil {
		s.fail(err.Error())
		s.status = 1
		return 1, ActionContinue
	}
	if len(toks) == 0 {
		// Blank, whitespace-only, or comment-only: a no-op that leaves $?
		// alone. The guard has to live here — parsePlan reports zero tokens
		// as an empty command, so the error would fire before the p.left
		// check below could catch it.
		return s.status, ActionContinue
	}
	p, err := parsePlan(toks, s.env, s.status, s.globWord)
	if err != nil {
		s.fail(err.Error())
		s.status = 1
		return 1, ActionContinue
	}
	if len(p.left) == 0 {
		// Unreachable as the code stands (a zero-token line returned above,
		// and parsePlan refuses a plan with no command word); kept because
		// it is what makes the p.left[0] reads below safe.
		return s.status, ActionContinue
	}
	if p.left[0] == "exec" && len(p.left) > 1 {
		// The monitor's vocabulary: `exec NAME args...` runs NAME. It does
		// not replace this process (GOSH keeps its job table) — it is the
		// same seam as typing NAME directly, kept so monitor-style scripts
		// run unmodified.
		p.left = p.left[1:]
	}
	s.exitReq = false
	s.monitorRq = false
	var st int
	var act Action
	if p.background {
		st, act = s.runBackground(p, depth)
	} else if len(p.right) > 0 {
		st, act = s.runPipeline(p)
	} else {
		st, act = s.runSingle(p, depth)
	}
	s.status = st
	if act != ActionContinue {
		return st, act
	}
	// `source` needs the run loop rather than a command: the builtin only
	// records the request, and the engine resolves it here (sh.zig's
	// .source Action).
	if s.sourceReq != "" {
		path := s.sourceReq
		s.sourceReq = ""
		return s.runSource(path, depth)
	}
	return st, ActionContinue
}

// out writes COMMAND output — the capture buffer while a `$(...)` is
// collecting, the terminal otherwise. Diagnostics deliberately do not come
// through here (they call host.Out directly), so a substitution can never
// swallow the message explaining why it is empty.
//
// One deliberate DIVERGENCE from the reference is recorded here because this
// is the distinction that bites later: `fn: ok` is a success NOTICE, and it
// does ride this path, so a definition performed inside a substitution
// captures it instead of printing it to the session — the reference wrote it
// straight to the session. Treating it as command output is what a real
// shell's `$( )` does; a script that relied on seeing `fn: ok` on screen
// during a substitution was relying on the reference's behaviour.
func (s *Shell) out(b []byte) {
	if s.capture != nil {
		*s.capture = append(*s.capture, b...)
		return
	}
	s.host.Out(b)
}

// commandSubst splices the first `$(cmd)` with cmd's captured output.
//
// Substitution is TEXTUAL and happens before the line is tokenized, which is
// the reference's order (sh.zig runLine substitutes, then splits chains, then
// runs the segment). Two consequences are worth knowing, because both differ
// from a POSIX shell and neither is an accident here: the captured text is
// re-tokenized, so it can introduce word splits AND operators (a substitution
// that yields `a | b` becomes a pipeline stage), and `$(...)` inside single
// quotes is substituted anyway. Making substitution word-scoped is a parser
// change (the expander would have to run commands), deliberately not taken in
// this slice; the retargeted gates assert none of the divergent cases.
func (s *Shell) commandSubst(line string, depth int) (string, Action) {
	c, ok := locateCommandSubst(line)
	if !ok {
		return line, ActionContinue
	}
	out, act := s.captureLine(c.inner, depth)
	if act != ActionContinue {
		return line, act
	}
	return c.prefix + markGlobLiteral(out) + c.suffix, ActionContinue
}

// captureLine runs one line with its output collected, returning that text
// with trailing newlines trimmed (the reference's contract — `$(echo INNER)`
// is `INNER`, not `INNER\n`).
func (s *Shell) captureLine(line string, depth int) (string, Action) {
	var buf []byte
	prev := s.capture
	s.capture = &buf
	_, act := s.runLine(line, depth)
	s.capture = prev
	return string(trimEndBytes(buf, '\n', '\r')), act
}

// trimEndBytes strips any trailing bytes in cut from b.
func trimEndBytes(b []byte, cut ...byte) []byte {
	end := len(b)
	for end > 0 {
		hit := false
		for _, c := range cut {
			if b[end-1] == c {
				hit = true
				break
			}
		}
		if !hit {
			break
		}
		end--
	}
	return b[:end]
}

// runBody runs a construct body's `;`-separated commands in order. It
// reports whether `break` ended the body and whether the last command asked
// to leave the shell (`continue` ends one iteration without a break).
func (s *Shell) runBody(body string, depth int) (int, bool, Action) {
	cmds, tooMany := splitCommands(body)
	if tooMany {
		// REFUSED, not truncated: the reference ran its first 16 commands and
		// dropped the rest silently, so half a body executed without a word.
		// Nothing runs here, and `broke` stops a loop after reporting once
		// instead of repeating the refusal every iteration.
		s.fail("body too long (at most " + vsys.Itoa64(bodyCmdsMax) + " commands)")
		s.status = 2
		return 2, true, ActionContinue
	}
	for _, cmd := range cmds {
		st, act := s.runLine(cmd, depth)
		if act != ActionContinue {
			return st, false, act
		}
		if s.loopBreak {
			return st, true, ActionContinue
		}
		if s.loopCont {
			return st, false, ActionContinue // end this iteration
		}
	}
	return s.status, false, ActionContinue
}

// runIf runs `if COND; then BODY; [else BODY;] fi`. The status left behind is
// the branch that ran, or the condition's own when neither did.
func (s *Shell) runIf(st ifStmt, depth int) (int, Action) {
	if stStr, act := s.runLine(st.cond, depth); act != ActionContinue {
		return stStr, act
	}
	if s.status == 0 {
		_, _, act := s.runBody(st.thenBody, depth)
		return s.status, act
	}
	if st.hasElse {
		_, _, act := s.runBody(st.elseBody, depth)
		return s.status, act
	}
	return s.status, ActionContinue
}

// runFor runs `for VAR in W...; do BODY; done`, unsetting VAR afterwards
// exactly as sh.zig did (the loop variable does not leak). The word list
// gets its own glob pass here (M98a): parseFor keeps raw text, so this is
// where `for f in *.SH` becomes real names — and where the same refusal
// fires when the expansion would exceed the 16-word bound.
func (s *Shell) runFor(st forStmt, depth int) (int, Action) {
	words, gerr := s.forWordExpand(st.words)
	if gerr != nil {
		s.fail(gerr.Error())
		s.status = 1
		return 1, ActionContinue
	}
	if len(words) > forWordMax {
		s.fail("for word list too long (at most " + vsys.Itoa64(forWordMax) + " words)")
		s.status = 2
		return 2, ActionContinue
	}
	for _, w := range words {
		s.env.Set(st.varName, w)
		s.clearLoopFlags()
		_, brk, act := s.runBody(st.body, depth)
		if act != ActionContinue {
			return s.status, act
		}
		if brk {
			break
		}
	}
	s.env.Unset(st.varName)
	s.clearLoopFlags()
	return s.status, ActionContinue
}

// runWhile runs `while COND; do BODY; done`, bounded to whileIterMax
// iterations. The reference stopped silently at the bound; a forced stop is
// reported and fails, because a loop that quietly ends is indistinguishable
// from one that finished.
func (s *Shell) runWhile(st whileStmt, depth int) (int, Action) {
	for i := 0; i < whileIterMax; i++ {
		s.clearLoopFlags()
		if cst, act := s.runLine(st.cond, depth); act != ActionContinue {
			return cst, act
		}
		if s.status != 0 {
			s.clearLoopFlags()
			return s.status, ActionContinue
		}
		_, brk, act := s.runBody(st.body, depth)
		if act != ActionContinue {
			return s.status, act
		}
		if brk {
			s.clearLoopFlags()
			return s.status, ActionContinue
		}
	}
	s.clearLoopFlags()
	s.fail("while: iteration cap (" + vsys.Itoa64(whileIterMax) + ") reached")
	s.status = 1
	return 1, ActionContinue
}

// runCase runs the first arm whose pattern matches the expanded subject. No
// matching arm is a success (sh.zig runCase).
func (s *Shell) runCase(st caseStmt, depth int) (int, Action) {
	subject := expand(token{kind: tokWord, text: st.subject}, s.env, s.status)
	for _, arm := range st.arms {
		pat, pact := marksToFlags(arm.pattern)
		if caseMatchFlagged(pat, pact, subject) {
			_, _, act := s.runBody(arm.body, depth)
			return s.status, act
		}
	}
	s.status = 0
	return 0, ActionContinue
}

// clearLoopFlags resets break/continue for the next iteration.
func (s *Shell) clearLoopFlags() {
	s.loopBreak = false
	s.loopCont = false
}

// bindFuncArgs binds $0, $1..$N and the declared argument names for a call
// (shell.zig bindFuncArgs). `args` excludes the command word, which is where
// the reference's index arithmetic came from — there argv[0] WAS the function
// name, so its argv[1] is this args[0].
func (s *Shell) bindFuncArgs(f *progFunc, args []string) {
	s.env.Set("0", f.name)
	for i := 0; i < len(args) && i < funcArgMax; i++ {
		s.env.Set(vsys.Itoa64(int64(i+1)), args[i])
	}
	for i := 0; i < len(args) && i < len(f.argNames); i++ {
		s.env.Set(f.argNames[i], args[i])
	}
}

// runFuncBody runs a function's pre-split body one command at a time at
// depth+1 (sh.zig runFunction).
func (s *Shell) runFuncBody(f *progFunc, depth int) (int, Action) {
	for _, cmd := range f.body {
		st, act := s.runLine(cmd, depth+1)
		if act != ActionContinue {
			return st, act
		}
	}
	return s.status, ActionContinue
}

// runSource runs a file's lines in this shell, CRLF-aware and silent about
// blank lines (sh.zig runSource). Nesting is bounded and the bound is
// reported rather than passed over.
func (s *Shell) runSource(path string, depth int) (int, Action) {
	if depth > sourceDepthMax {
		s.fail("source nesting exceeds " + vsys.Itoa64(sourceDepthMax) + " levels")
		s.status = 2
		return 2, ActionContinue
	}
	rp, rerr := s.resolvePath(path)
	if rerr != nil {
		s.host.Out([]byte("gosh: source: " + path + ": " + rerr.Error() + "\n"))
		s.status = 1
		return 1, ActionContinue
	}
	b, err := s.host.ReadFile(rp.host, maxSourceBytes+1)
	if err != nil {
		s.host.Out([]byte("gosh: source: " + strings.TrimPrefix(openDenial(path, err), "gosh: ")))
		s.status = 1
		return 1, ActionContinue
	}
	if len(b) > maxSourceBytes {
		s.host.Out([]byte("gosh: source: " + path + ": exceeds the " +
			vsys.Itoa64(maxSourceBytes) + "-byte source buffer\n"))
		s.status = 1
		return 1, ActionContinue
	}
	body := strings.ReplaceAll(string(b), "\r\n", "\n")
	lines := strings.Split(body, "\n")
	for i := 0; i < len(lines); i++ {
		ln := strings.TrimRight(lines[i], "\r")
		if strings.TrimSpace(ln) == "" {
			continue
		}
		ln = stripEscMarks(ln)
		// A `<<` line pulls the file's own following lines as its body;
		// an end of file mid-collection is the named unterminated refusal.
		var bodies [][]byte
		if r, rerr := NewHeredocReader(ln); rerr == nil && r.Waiting() {
			for r.Waiting() && i+1 < len(lines) {
				i++
				r.Feed(strings.TrimRight(lines[i], "\r"))
			}
			bodies = r.Bodies()
		}
		st, act := s.runLineBodies(ln, bodies, depth+1)
		if act != ActionContinue {
			return st, act
		}
	}
	return s.status, ActionContinue
}

func (s *Shell) fail(msg string) {
	s.host.Out([]byte("gosh: " + strings.TrimPrefix(msg, "gosh: ") + "\n"))
}

// classify: 0 builtin, 1 toolbox tool, 2 external.
func classify(name string) int {
	if _, ok := builtins[name]; ok {
		return 0
	}
	if _, ok := tools[name]; ok {
		return 1
	}
	return 2
}

// runBuiltin dispatches name to the builtin/tool table, translating the
// exit/monitor requests into the returned Action.
func (s *Shell) runBuiltin(name string, c *cmdCtx) (int, Action) {
	fn := builtins[name]
	if fn == nil {
		fn = tools[name]
	}
	c.name = name
	st := fn(c)
	switch {
	case s.exitReq:
		s.exitReq = false
		return st, ActionExit
	case s.monitorRq:
		s.monitorRq = false
		return st, ActionMonitor
	}
	return st, ActionContinue
}

func (s *Shell) runSingle(p *plan, depth int) (int, Action) {
	name := p.left[0]
	args := p.left[1:]
	var stdin []byte
	if p.in != nil {
		b, ok := s.stdinFor(p.in)
		if !ok {
			return 1, ActionContinue
		}
		stdin = b
	}
	var outPath string
	if p.out != nil {
		rp, err := s.resolvePath(p.out.path)
		if err != nil {
			s.host.Out([]byte("gosh: " + p.out.path + ": " + err.Error() + "\n"))
			return 1, ActionContinue
		}
		outPath = rp.host
	}
	var cap boundedCapture
	cap.lim = maxRedirectBytes
	sink := func(b []byte) { s.out(b) }
	if p.out != nil {
		sink = cap.write
	}
	var st int
	var act Action
	switch classify(name) {
	case 0, 1:
		st, act = s.runBuiltin(name, &cmdCtx{sh: s, args: args, stdin: stdin,
			out: sink, stdinBound: p.in != nil, outCaptured: p.out != nil || s.capture != nil})
	default:
		if f := s.funcs.find(name); f != nil {
			// A function resolves before the exec seam (sh.zig execute), so a
			// definition shadows an external app of the same name. A builtin
			// or tool still wins over a function, because classify ran first.
			s.bindFuncArgs(f, args)
			st, act = s.runFuncBody(f, depth)
			break
		}
		if s.capture != nil {
			// An external app writes fd 1 itself, so its output cannot be
			// collected; say so rather than interleave it into a
			// substitution (the reference's notice).
			s.host.Out([]byte("gosh: cannot capture an external app's output yet\n"))
			return 1, ActionContinue
		}
		stv, err := s.runExternal(name, args)
		st = stv
		if err != nil {
			act = ActionContinue
		}
	}
	if act != ActionContinue {
		return st, act
	}
	if p.out != nil {
		if cap.over {
			s.host.Out([]byte("gosh: " + p.out.path + ": output exceeds the " + vsys.Itoa64(maxRedirectBytes) + "-byte redirect buffer\n"))
			return 1, ActionContinue
		}
		if err := s.host.WriteFile(outPath, cap.buf, p.out.append); err != nil {
			s.host.Out([]byte("gosh: " + p.out.path + ": write failed\n"))
			return 1, ActionContinue
		}
	}
	return st, act
}

// execName resolves a program name for the exec seam: a bare name keeps
// the front-end's share-root lookup (candidateNames is the shell's PATH),
// while a name containing '/' resolves against PWD like any other path
// (M98j). The kernel's exec names paths relative to the share root, so the
// resolved form is what it wants.
func (s *Shell) execName(name string) (string, error) {
	if !strings.Contains(name, "/") {
		return name, nil
	}
	rp, err := s.resolvePath(name)
	if err != nil {
		return "", err
	}
	return rp.host, nil
}

// runExternal spawns name in the foreground and waits, returning its exit
// status (127 when nothing loads or the wait fails).
func (s *Shell) runExternal(name string, args []string) (int, error) {
	en, err := s.execName(name)
	if err != nil {
		s.host.Out([]byte("gosh: " + name + ": " + err.Error() + "\n"))
		return 127, err
	}
	pid, err := s.host.RunExternal(en, args)
	if err != nil {
		s.host.Out([]byte("gosh: " + name + ": not found\n"))
		return 127, err
	}
	if intr := s.ttyPoll(); intr != nil {
		// M98f: the interactive wait polls + watches for Ctrl-C instead of
		// blocking in WaitExternal (and writes no crash receipt — a kill
		// the shell armed is not a crash).
		st, _ := s.waitForeground(name, pid, intr)
		return st, nil
	}
	st, err := s.host.WaitExternal(pid)
	if err != nil {
		s.host.Out([]byte("gosh: " + name + ": wait failed\n"))
		return 127, err
	}
	return int(st), nil
}

func (s *Shell) runPipeline(p *plan) (int, Action) {
	lname := p.left[0]
	if classify(lname) == 2 {
		s.host.Out([]byte("gosh: cannot capture an external app's output yet\n"))
		return 1, ActionContinue
	}
	var stdin []byte
	if p.in != nil {
		b, ok := s.stdinFor(p.in)
		if !ok {
			return 1, ActionContinue
		}
		stdin = b
	}
	var outPath string
	if p.out != nil {
		rp, err := s.resolvePath(p.out.path)
		if err != nil {
			s.host.Out([]byte("gosh: " + p.out.path + ": " + err.Error() + "\n"))
			return 1, ActionContinue
		}
		outPath = rp.host
	}
	var stage boundedCapture
	stage.lim = MaxPipeBytes
	fn := builtins[lname]
	if fn == nil {
		fn = tools[lname]
	}
	st, act := s.runBuiltin(lname, &cmdCtx{sh: s, args: p.left[1:], stdin: stdin,
		out: stage.write, stdinBound: p.in != nil, outCaptured: true})
	if act != ActionContinue {
		return st, act
	}
	if stage.over {
		// Writing the clipped capture would hand the right stage short
		// input that still reports success, so the line fails instead.
		s.host.Out([]byte("gosh: pipe stage output exceeds the " + vsys.Itoa64(MaxPipeBytes) + "-byte pipe buffer\n"))
		return 1, ActionContinue
	}
	if err := s.host.PipeWrite(stage.buf); err != nil {
		s.host.Out([]byte("gosh: pipe write failed\n"))
		return 1, ActionContinue
	}
	rightStdin, err := s.host.PipeReadAll()
	if err != nil {
		s.host.Out([]byte("gosh: pipe read failed\n"))
		return 1, ActionContinue
	}
	rname := p.right[0]
	if classify(rname) == 2 {
		s.host.Out([]byte("gosh: a piped command must be a builtin or tool (an external app would not read the pipe)\n"))
		return 1, ActionContinue
	}
	var rcap boundedCapture
	rcap.lim = maxRedirectBytes
	rsink := func(b []byte) { s.out(b) }
	if p.out != nil {
		rsink = rcap.write
	}
	rst, ract := s.runBuiltin(rname, &cmdCtx{sh: s, args: p.right[1:], stdin: rightStdin,
		out: rsink, stdinBound: true, outCaptured: p.out != nil || s.capture != nil})
	if ract != ActionContinue {
		return rst, ract
	}
	if p.out != nil {
		if rcap.over {
			s.host.Out([]byte("gosh: " + p.out.path + ": output exceeds the " + vsys.Itoa64(maxRedirectBytes) + "-byte redirect buffer\n"))
			return 1, ActionContinue
		}
		if err := s.host.WriteFile(outPath, rcap.buf, p.out.append); err != nil {
			s.host.Out([]byte("gosh: " + p.out.path + ": write failed\n"))
			return 1, ActionContinue
		}
	}
	return rst, ActionContinue
}

func (s *Shell) runBackground(p *plan, depth int) (int, Action) {
	name := p.left[0]
	if classify(name) != 2 {
		// A builtin has nothing to background (it runs inside this
		// process); say so and run it in the foreground instead.
		s.host.Out([]byte("gosh: " + name + " is a builtin; & runs external apps only\n"))
		return s.runSingle(&plan{left: p.left, in: p.in, out: p.out}, depth)
	}
	if len(s.jobs) >= maxJobs {
		s.host.Out([]byte("gosh: too many background jobs\n"))
		return 1, ActionContinue
	}
	en, err := s.execName(name)
	if err != nil {
		s.host.Out([]byte("gosh: " + name + ": " + err.Error() + "\n"))
		return 127, ActionContinue
	}
	pid, err := s.host.RunExternal(en, p.left[1:])
	if err != nil {
		s.host.Out([]byte("gosh: " + name + ": not found\n"))
		return 127, ActionContinue
	}
	s.nextN++
	j := &Job{N: s.nextN, PID: pid, Display: strings.Join(p.left, " ")}
	s.jobs = append(s.jobs, j)
	s.host.Marker("gosh: job " + vsys.Itoa64(int64(j.N)) + " pid=" + vsys.Itoa64(pid))
	return 0, ActionContinue
}

// ReapJobs probes every live background job once and reports finished ones
// exactly once (the serial marker is the gate's evidence of the cycle).
// The shell loop calls it every tick; jobs/fg call it before reading.
func (s *Shell) ReapJobs() {
	for _, j := range append([]*Job{}, s.jobs...) {
		if j.Done {
			continue
		}
		st, state := s.host.ProbeExternal(j.PID)
		switch state {
		case probeRunning:
			j.Seen = true
		case probeExited:
			s.finishJob(j, st)
		case probeAbsent:
			if j.Seen {
				s.finishJob(j, 0) // reaped and recycled: status 0
			}
		}
	}
}

func (s *Shell) finishJob(j *Job, st int64) {
	j.Done = true
	j.Status = st
	s.host.Marker("gosh: job " + vsys.Itoa64(int64(j.N)) + " done exit=" + vsys.Itoa64(st))
}

// jobByN finds job n, or nil.
func (s *Shell) jobByN(n int) *Job {
	for _, j := range s.jobs {
		if j.N == n {
			return j
		}
	}
	return nil
}

func (s *Shell) removeJob(j *Job) {
	for i := range s.jobs {
		if s.jobs[i] == j {
			s.jobs = append(s.jobs[:i], s.jobs[i+1:]...)
			return
		}
	}
}

// names lists builtin and tool names (completion + help).
func BuiltinNames() []string { return tableNames(builtins) }
func ToolNames() []string    { return tableNames(tools) }

func tableNames(m map[string]func(*cmdCtx) int) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// ErrNotFound and ErrWriteFailed are the host seam's plain refusals: the
// engine only reports them, so plain sentinels suffice. goshHost (the
// front-end) and fakeHost (the tests) return these very values, so an
// engine-side identity check still holds across the package line.
var ErrNotFound = &shellError{"not found"}
var ErrWriteFailed = &shellError{"write failed"}

type shellError struct{ s string }

func (e *shellError) Error() string { return e.s }

// NewOpenError builds a file-ABI refusal that carries the KERNEL's errno
// name (OpenError above). The front-end's host seam constructs it; the
// fields stay private because only the engine renders them.
func NewOpenError(path, name string) *OpenError {
	return &OpenError{path: path, name: name}
}
