// GOSH's builtin table — the daily-use set SH.BIN offered (M49 bar), minus
// the M68a non-goals (no vi-mode set -o, no functions/arith/conditionals).
package shlib

import (
	"errors"
	"sort"
	"strings"

	"virelai/clockfmt"
	"virelai/mime"
	"virelai/settings"
	"virelai/timesync"
	"virelai/vi"
	"virelai/vsys"
)

// parseInt is the guest-side decimal parser (the stdlib strconv is not
// ported to this GOOS). Accepts an optional sign; rejects overflow.
func parseInt(s string) (int, bool) {
	neg := false
	i := 0
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		neg = s[0] == '-'
		i = 1
	}
	if i >= len(s) {
		return 0, false
	}
	n := 0
	for ; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
		if n > 1<<30 {
			return 0, false
		}
	}
	if neg {
		n = -n
	}
	return n, true
}

var builtins map[string]func(*cmdCtx) int

func init() {
	builtins = map[string]func(*cmdCtx) int{
		"echo": bEcho, "cat": bCat, "pwd": bPwd, "cd": bCd,
		"pushd": bPushd, "popd": bPopd, "dirs": bDirs,
		"open": bOpen, "env": bEnv, "printenv": bPrintenv, "set": bSet, "unset": bUnset,
		"export": bExport, "read": bRead, "jobs": bJobs, "fg": bFg,
		"history": bHistory, "help": bHelp, "exit": bExit, "monitor": bMonitor,
		"sleep": bSleep, "clear": bClear, "log": bLog, "date": bDate,
		"time": bTime,
		// M50 trust surface (ADR 0024): identity, owner-only chmod, and the
		// secret store's names. Same verbs and the same output text as the
		// Zig shell, so the M50 gates retarget without weakening an assert.
		"whoami": bWhoami, "id": bID, "chmod": bChmod, "secrets": bSecrets,
		// M19 scripting (slice 4 of #1450): the control-flow verbs, and the
		// source that runs a file's lines in this shell.
		"true": bTrue, "false": bFalse, "source": bSource, ".": bSource,
		"break": bBreak, "continue": bContinue,
		// M98b (issue #2128): the session alias table.
		"alias": bAlias, "unalias": bUnalias,
	}
}

// uidSystem is the kernel's system principal (ADR 0024 D1). Duplicated here
// so the engine's output text does not depend on the guest syscall package.
const uidSystem = 0

// bTrue and bFalse are the M19 conditions: no output, just the status (the
// Zig shell registered both). for/while/if read that status.
func bTrue(c *cmdCtx) int  { return 0 }
func bFalse(c *cmdCtx) int { return 1 }

// bSource records a source request rather than running anything: sourcing
// needs the run loop, not a command, so the engine resolves the file after
// the line finishes (runSegment -> runSource). Only the name travels here.
func bSource(c *cmdCtx) int {
	if len(c.args) != 1 {
		c.out([]byte("gosh: source: usage: source FILE\n"))
		return 2
	}
	c.sh.sourceReq = c.args[0]
	return 0
}

// bBreak and bContinue raise the loop flags that runBody/runFor/runWhile
// clear at the top of each iteration.
func bBreak(c *cmdCtx) int {
	c.sh.loopBreak = true
	return 0
}

func bContinue(c *cmdCtx) int {
	c.sh.loopCont = true
	return 0
}

// bWhoami prints the caller's principal, exactly as the Zig shell did:
// `uid=<n> user` (or `system`), and a refusal when the seam cannot answer.
func bWhoami(c *cmdCtx) int {
	uid, _, ok := c.sh.host.Principal()
	if !ok {
		c.out([]byte("whoami: no principal\n"))
		return 1
	}
	c.out([]byte("uid=" + vsys.Itoa64(int64(uid)) + principalKind(uid) + "\n"))
	return 0
}

// bID adds the capability mask; the M50 gate asserts it agrees with whoami.
func bID(c *cmdCtx) int {
	uid, caps, ok := c.sh.host.Principal()
	if !ok {
		c.out([]byte("id: no principal\n"))
		return 1
	}
	c.out([]byte("uid=" + vsys.Itoa64(int64(uid)) + principalKind(uid) +
		" caps=" + vsys.Itoa64(int64(caps)) + "\n"))
	return 0
}

func principalKind(uid uint32) string {
	if uid == uidSystem {
		return " system"
	}
	return " user"
}

// bChmod forwards an owner-only mode change through slot 69. The kernel is
// the authority on ownership and on the group triplet; the shell only parses
// the octal mode and reports the kernel's own errno name.
func bChmod(c *cmdCtx) int {
	if len(c.args) < 2 {
		c.out([]byte("chmod: usage: chmod MODE FILE\n"))
		return 1
	}
	mode, ok := parseOctMode(c.args[0])
	if !ok {
		c.out([]byte("chmod: invalid mode (use octal, e.g. 600)\n"))
		return 1
	}
	file := c.args[1]
	rp, rerr := c.sh.resolvePath(file)
	if rerr != nil {
		c.out([]byte("chmod: " + file + ": " + rerr.Error() + "\n"))
		return 1
	}
	if err := c.sh.host.Chmod(rp.host, mode); err != nil {
		if oe, denial := deniedAs(err); denial {
			c.out([]byte("chmod: " + file + ": " + oe.name + "\n"))
		} else {
			c.out([]byte("chmod: " + file + ": " + err.Error() + "\n"))
		}
		return 1
	}
	c.out([]byte("chmod: ok\n"))
	return 0
}

// bSecrets lists the CALLER's store entry names (slot 70). Values never
// travel through this seam, so the never-logged contract holds here too
// (ADR 0024 D8).
func bSecrets(c *cmdCtx) int {
	names, ok := c.sh.host.SecretNames()
	if !ok {
		c.out([]byte("secrets: unavailable\n"))
		return 1
	}
	if len(names) == 0 {
		c.out([]byte("secrets: (none)\n"))
		return 0
	}
	for _, n := range names {
		c.out([]byte("  " + n + "\n"))
	}
	return 0
}

// parseOctMode parses a 1..4 digit octal mode (e.g. `600`, `0600`, `644`),
// bounded to the permission bits. The kernel re-validates.
func parseOctMode(s string) (uint16, bool) {
	if len(s) == 0 || len(s) > 4 {
		return 0, false
	}
	var v uint16
	for i := 0; i < len(s); i++ {
		ch := s[i]
		if ch < '0' || ch > '7' {
			return 0, false
		}
		v = v*8 + uint16(ch-'0')
	}
	if v > 0o777 {
		return 0, false
	}
	return v, true
}

func bEcho(c *cmdCtx) int {
	args := c.args
	nl := true
	if len(args) > 0 && args[0] == "-n" {
		nl = false
		args = args[1:]
	}
	c.out([]byte(strings.Join(args, " ")))
	if nl {
		c.out([]byte("\n"))
	}
	return 0
}

// bCat prints bound stdin, or the named files. `cat` with no redirect only
// makes sense with `< FILE` (SH.BIN's builtin behaves the same way).
func bCat(c *cmdCtx) int {
	if len(c.args) == 0 {
		c.out(c.stdin)
		return 0
	}
	for _, f := range c.args {
		b, err := c.sh.readBounded(f)
		if err != nil {
			if err == errTooLarge {
				c.out([]byte("gosh: cat: " + f + ": " + errTooLarge.Error() + "\n"))
				return 1
			}
			c.out([]byte(openDenial(f, err)))
			return 1
		}
		c.out(b)
	}
	return 0
}

// bOpen applies the shared MIME/URL decision, then launches through the same
// host seam as every other GOSH external. Like a desktop "open", it returns
// once the handler has started rather than holding the shell until its window
// closes. The marker is printed only after exec returned a pid.
func bOpen(c *cmdCtx) int {
	if len(c.args) != 1 {
		c.out([]byte("gosh: open: usage: open PATH|URL\n"))
		return 2
	}
	// File paths resolve against PWD here; URL schemes and volume-colon
	// forms pass through verbatim because mime's own routing owns them
	// (localVolumePath handles host:/usbN: itself).
	target := c.args[0]
	if !hasScheme(target) {
		rp, rerr := c.sh.resolvePath(target)
		if rerr != nil {
			c.sh.host.Marker("gosh: open refused target=" + c.args[0] +
				" reason=" + rerr.Error())
			c.out([]byte("gosh: open: " + c.args[0] + ": " + rerr.Error() + "\n"))
			return 1
		}
		target = rp.canon
	}
	req, err := mime.Open(target, "/", c.sh.host.ReadFile)
	if err != nil {
		c.sh.host.Marker("gosh: open refused target=" + c.args[0] +
			" reason=" + err.Error())
		c.out([]byte("gosh: open: " + c.args[0] + ": " + err.Error() + "\n"))
		return 1
	}
	args, ok := openTargetArgs(req.Target)
	if !ok {
		err := errOpenTargetTooLong
		c.sh.host.Marker("gosh: open refused target=" + req.Target +
			" reason=" + err.Error())
		c.out([]byte("gosh: open: " + req.Target + ": " + err.Error() + "\n"))
		return 1
	}
	pid, err := c.sh.host.RunExternal(req.Handler.Bin, args)
	if err != nil {
		c.sh.host.Marker("gosh: open refused target=" + req.Target +
			" handler=" + req.Handler.Bin + " unavailable")
		c.out([]byte("gosh: open: handler " + req.Handler.Bin + " unavailable\n"))
		return 127
	}
	c.sh.host.Marker("gosh: open launched scheme=" + req.Scheme +
		" target=" + req.Target + " handler=" + req.Handler.Bin +
		" pid=" + vsys.Itoa64(pid))
	return 0
}

const (
	openExecArgBytes = 255
	// WEB.ELF uses one of the kernel's eight argv slots for argv[0].
	openExecArgSlots = 8 - 1
)

var errOpenTargetTooLong = errors.New("URL too long for WEB.ELF argv")

// openTargetArgs preserves the complete target within the kernel's
// per-argument and argv-slot limits. WEB.ELF concatenates split URL slots.
func openTargetArgs(target string) ([]string, bool) {
	n := (len(target) + openExecArgBytes - 1) / openExecArgBytes
	if n == 0 {
		return nil, false
	}
	if n > openExecArgSlots {
		return nil, false
	}
	args := make([]string, 0, n)
	for start := 0; start < len(target); start += openExecArgBytes {
		end := start + openExecArgBytes
		if end > len(target) {
			end = len(target)
		}
		args = append(args, target[start:end])
	}
	return args, true
}

func bPwd(c *cmdCtx) int {
	v, _ := c.sh.env.Get("PWD")
	c.out([]byte(v + "\n"))
	return 0
}

// bCd lives in dirstack.go with the rest of M98d's navigation state:
// `cd DIR`/`cd -`, the OLDPWD update shared with pushd/popd, and the
// bounded directory stack.

func bEnv(c *cmdCtx) int {
	for _, v := range c.sh.env.List() {
		c.out([]byte(v.name + "=" + v.val + "\n"))
	}
	return 0
}

func bPrintenv(c *cmdCtx) int {
	missing := false
	if len(c.args) == 0 {
		return bEnv(c)
	}
	for _, name := range c.args {
		if v, ok := c.sh.env.Get(name); ok {
			c.out([]byte(v + "\n"))
		} else {
			missing = true
		}
	}
	if missing {
		return 1
	}
	return 0
}

func bSet(c *cmdCtx) int {
	if len(c.args) == 0 {
		for _, v := range c.sh.env.List() {
			c.out([]byte(v.name + "=" + v.val + "\n"))
		}
		return 0
	}
	if c.args[0] == "-o" {
		c.out([]byte("gosh: set -o is not supported (no vi mode)\n"))
		return 1
	}
	eq := strings.IndexByte(c.args[0], '=')
	if eq <= 0 {
		c.out([]byte("gosh: set NAME=VALUE\n"))
		return 2
	}
	c.sh.env.Set(c.args[0][:eq], c.args[0][eq+1:])
	return 0
}

func bUnset(c *cmdCtx) int {
	if len(c.args) == 0 {
		c.out([]byte("gosh: unset NAME\n"))
		return 2
	}
	c.sh.env.Unset(c.args[0])
	return 0
}

func bExport(c *cmdCtx) int {
	if len(c.args) == 0 {
		for _, v := range c.sh.env.List() {
			if v.exported {
				c.out([]byte("export " + v.name + "=" + v.val + "\n"))
			}
		}
		return 0
	}
	eq := strings.IndexByte(c.args[0], '=')
	if eq < 0 {
		if !c.sh.env.Export(c.args[0]) {
			c.out([]byte("gosh: export: " + c.args[0] + ": not set\n"))
			return 1
		}
		return 0
	}
	if eq == 0 {
		c.out([]byte("gosh: export NAME=VALUE\n"))
		return 2
	}
	c.sh.env.Set(c.args[0][:eq], c.args[0][eq+1:])
	c.sh.env.Export(c.args[0][:eq])
	return 0
}

// bRead takes one line from bound stdin (a pipe or redirect), or from the
// terminal when stdin is unbound, into the named variable.
func bRead(c *cmdCtx) int {
	if len(c.args) != 1 {
		c.out([]byte("gosh: read VAR\n"))
		return 2
	}
	var line string
	ok := false
	if c.stdin != nil {
		if i := strings.IndexByte(string(c.stdin), '\n'); i >= 0 {
			line, ok = string(c.stdin[:i]), true
		} else {
			line, ok = string(c.stdin), true
		}
	} else {
		line, ok = c.sh.host.ReadTTYLine()
	}
	if !ok {
		return 1
	}
	c.sh.env.Set(c.args[0], strings.TrimSuffix(line, "\r"))
	return 0
}

// bJobs lists the job table; finished jobs are reported once and removed.
func bJobs(c *cmdCtx) int {
	c.sh.ReapJobs()
	for _, j := range append([]*Job{}, c.sh.jobs...) {
		if j.Done {
			c.out([]byte("[" + vsys.Itoa64(int64(j.N)) + "] Done: " + j.Display +
				" (exit=" + vsys.Itoa64(j.Status) + ")\n"))
			c.sh.removeJob(j)
		} else {
			c.out([]byte("[" + vsys.Itoa64(int64(j.N)) + "] running: " + j.Display + "\n"))
		}
	}
	return 0
}

// bFg waits for one background job and propagates its exit status into $?.
// There is no `bg` to return to (nothing suspends a guest job) and no
// `wait` for the table as a whole — fg is the way you wait, the same
// contract the kernel monitor's job table documents.
func bFg(c *cmdCtx) int {
	if len(c.args) != 1 {
		c.out([]byte("gosh: fg N\n"))
		return 2
	}
	id := strings.TrimPrefix(c.args[0], "%")
	n, ok := parseInt(id)
	if !ok {
		c.out([]byte("gosh: fg N\n"))
		return 2
	}
	j := c.sh.jobByN(n)
	if j == nil {
		c.out([]byte("fg: no such job\n"))
		return 1
	}
	for !j.Done {
		c.sh.ReapJobs()
		if j.Done {
			break
		}
		c.sh.host.SleepTick()
	}
	c.out([]byte("[" + vsys.Itoa64(int64(j.N)) + "] Done: " + j.Display +
		" (exit=" + vsys.Itoa64(j.Status) + ")\n"))
	c.sh.removeJob(j)
	return int(j.Status)
}

func bHistory(c *cmdCtx) int {
	for i, h := range c.sh.hist.Entries() {
		c.out([]byte(vsys.Itoa64(int64(i+1)) + "  " + h + "\n"))
	}
	return 0
}

// bLog reads one per-app log ring, or all rings in stable app-name order.
func bLog(c *cmdCtx) int {
	reader, ok := c.sh.host.(interface {
		AppLogNames() []string
		ReadAppLog(app string) ([]byte, error)
	})
	if !ok {
		c.out([]byte("log: unavailable\n"))
		return 1
	}
	if len(c.args) > 1 {
		c.out([]byte("gosh: log [APP]\n"))
		return 2
	}
	if len(c.args) == 1 {
		body, err := reader.ReadAppLog(c.args[0])
		if err != nil {
			c.out([]byte("log: " + c.args[0] + ": not found\n"))
			return 1
		}
		c.out(body)
		return 0
	}
	names := reader.AppLogNames()
	if len(names) == 0 {
		c.out([]byte("log: (no app logs)\n"))
		return 0
	}
	for _, app := range names {
		body, err := reader.ReadAppLog(app)
		if err != nil {
			continue
		}
		c.out([]byte(app + ":\n"))
		c.out(body)
	}
	return 0
}

// These clock sources are replaceable in host tests. The guest takes the
// epoch from the kernel and the fallback from the monotonic counter.
var dateNow = vi.Now
var dateMonotonic = vi.Nanos

// dateZone resolves the `timezone` row through the shared settings codec
// (M83c #1776): the file's fixed offset when it parses, UTC otherwise.
// Replaceable in host tests, like the clock sources above.
var dateZone = func() clockfmt.Zone { return settings.Load().Timezone() }

func bDate(c *cmdCtx) int {
	if len(c.args) != 0 {
		c.out([]byte("gosh: date: usage: date\n"))
		return 2
	}
	epoch := dateNow()
	if epoch == -vi.ErrENOSYS {
		c.out([]byte("date: no firmware epoch; monotonic=" +
			vsys.Itoa64(dateMonotonic()/1_000_000_000) + "s\n"))
		return 1
	}
	if epoch < 0 {
		c.out([]byte("date: clock error " + vsys.Itoa64(epoch) + "\n"))
		return 1
	}
	// EFI's broken-down wall-clock fields were converted to an epoch as
	// written; clockfmt shifts that epoch by the configured fixed offset
	// (M83c) and labels the face with it.
	c.out([]byte(clockfmt.Format(epoch, dateZone()) +
		" (epoch=" + vsys.Itoa64(epoch) + ")\n"))
	return 0
}

// timeSync is replaceable in host tests: the real one puts a datagram on the
// wire and, on a valid reply, steps the kernel clock.
var timeSync = timesync.Sync

// bTime is `time sync [SERVER]`: one SNTP query (M83b #1775). `sync` is the
// only subcommand; the verb is `time` so that a later `time zone` has a home
// without another top-level name. Exit 0 when the clock is correct afterward
// (stepped, or already within a tick), 1 for every failure, 2 for misuse.
func bTime(c *cmdCtx) int {
	if len(c.args) < 1 || len(c.args) > 2 || c.args[0] != "sync" {
		c.out([]byte("gosh: time: usage: time sync [SERVER]\n"))
		return 2
	}
	server := timesync.DefaultServer
	if len(c.args) == 2 {
		server = c.args[1]
	}
	res := timeSync(server)
	c.out([]byte(res.Line()))
	if !res.OK() {
		return 1
	}
	return 0
}

// --- ADR 0008 D1 discovery for the guest verbs (#1538) -------------------
//
// The milestone-eight ADR pinned a grouped catalog, `help <cmd>` and topic
// pages for the kernel monitor. GOSH's `help` was one concatenated line of
// names -- fine for a gate grep, useless when you are sitting in the shell.
// The table below is that catalog for the verbs this shell actually runs.
//
// It is DATA, not a second command table: a class-A test pins that every
// builtin, every toolbox tool and the one external has exactly one row, and
// that every row names a verb that exists, so the catalog cannot drift away
// from the tables it describes.

// helpEntry is one catalog row: the group `help` lists the verb under, the
// D1 usage string, and the one-line blurb `help <cmd>` prints.
type helpEntry struct {
	group string
	usage string
	blurb string
	// notes is the extra description line `help <cmd>` appends (D1's "a few
	// lines of description"). Empty for most verbs.
	notes string
}

// helpGroups fixes the catalog's section order. A group with no members is
// skipped, so a build with a trimmed table still prints a coherent catalog.
var helpGroups = []string{"shell", "files", "environment", "scripts", "jobs", "identity"}

// helpExternal is the non-builtin VERB that gets a row: `exec` is resolved by
// the engine's parser, not by the builtin map, and it is where a daily user
// looks for "how do I run a program".
const helpExternal = "exec"

// subsetBlurb is the scripting subset's one-line contract (M68a). Kept
// verbatim: it describes what the engine really runs.
const subsetBlurb = "one pipe per line, > >> < redirects, $VAR ${VAR} $?"

var helpCatalog = map[string]helpEntry{
	// shell
	"clear":   {group: "shell", usage: "clear", blurb: "clear the tty screen"},
	"date":    {group: "shell", usage: "date", blurb: "show the firmware wall clock, or name the monotonic fallback", notes: "The calendar face carries the timezone setting's fixed offset (UTC by default); without a firmware epoch the command exits 1."},
	"echo":    {group: "shell", usage: "echo [ARG...]", blurb: "write ARG... separated by single spaces and a newline", notes: "The engine expands $VAR, ${VAR} and $? before echo runs."},
	"exit":    {group: "shell", usage: "exit [STATUS]", blurb: "leave GOSH with STATUS (the last status when omitted)"},
	"alias":   {group: "shell", usage: "alias [NAME=VALUE ...]", blurb: "define or list session aliases", notes: "An unquoted head word naming an alias expands before the line runs — `\\name`, 'name' and \"name\" bypass it. Any builtin can be shadowed, including `exit` and `alias` itself."},
	"unalias": {group: "shell", usage: "unalias NAME...|-a", blurb: "remove aliases (-a clears the table)"},
	"help":    {group: "shell", usage: "help [CMD|GROUP]", blurb: "the grouped catalog, or one verb's usage and description"},
	"history": {group: "shell", usage: "history", blurb: "list this session's submitted lines, oldest first"},
	"log":     {group: "shell", usage: "log [APP]", blurb: "read one app's bounded log ring, or all app rings"},
	"monitor": {group: "shell", usage: "monitor", blurb: "hand the console back to the kernel monitor"},
	"time":    {group: "shell", usage: "time sync [SERVER]", blurb: "set the clock from one SNTP query (default time.apple.com)", notes: "SERVER is a name or a dotted IPv4 address. One query, no retry; on no reply the clock is left untouched and the exit is 1."},

	// files
	"cat":    {group: "files", usage: "cat [FILE...]", blurb: "write FILE... (the bound stdin when none is named)"},
	"cd":     {group: "files", usage: "cd [DIR|-]", blurb: "change the working directory (checked against the share)", notes: "DIR resolves against PWD and `..` is resolved lexically. `cd -` returns to the previous directory. Arguments to an external app still resolve at the share root — the exec ABI carries no per-process cwd — so use an absolute path, or open PATH."},
	"pushd":  {group: "files", usage: "pushd [DIR]", blurb: "change to DIR and push the old directory (bare: swap with the stack top)"},
	"popd":   {group: "files", usage: "popd", blurb: "change to the directory stack's top entry and pop it"},
	"dirs":   {group: "files", usage: "dirs", blurb: "print the directory stack, current directory first"},
	"open":   {group: "files", usage: "open PATH|URL", blurb: "open a file with its MIME handler or an HTTPS URL in WEB.ELF", notes: "Supports local paths, file://, and https://. Other URL schemes are refused by name."},
	"pwd":    {group: "files", usage: "pwd", blurb: "print the working directory"},
	"read":   {group: "files", usage: "read VAR", blurb: "read one line into VAR, preferring the bound stdin"},
	"source": {group: "files", usage: "source FILE", blurb: "run FILE's lines in this shell"},
	".":      {group: "files", usage: ". FILE", blurb: "run FILE's lines in this shell (source)"},

	// environment
	"env":      {group: "environment", usage: "env", blurb: "list the environment as NAME=VALUE"},
	"printenv": {group: "environment", usage: "printenv [NAME...]", blurb: "print the named variables' values"},
	"set":      {group: "environment", usage: "set [NAME=VALUE]", blurb: "set a variable, or list the environment", notes: "`set -o` is refused: this shell has one fixed editing model, no vi mode."},
	"unset":    {group: "environment", usage: "unset NAME", blurb: "remove one variable"},
	"export":   {group: "environment", usage: "export [NAME=VALUE]", blurb: "set a variable and pass it to executed children"},

	// scripts
	"true":     {group: "scripts", usage: "true", blurb: "succeed (status 0)"},
	"false":    {group: "scripts", usage: "false", blurb: "fail (status 1)"},
	"break":    {group: "scripts", usage: "break", blurb: "leave the innermost for/while loop"},
	"continue": {group: "scripts", usage: "continue", blurb: "skip to the innermost loop's next iteration"},

	// jobs
	"jobs":  {group: "jobs", usage: "jobs", blurb: "list the shell's jobs (done jobs are reaped as they are shown)"},
	"fg":    {group: "jobs", usage: "fg N", blurb: "bring job N to the foreground and wait for it"},
	"sleep": {group: "jobs", usage: "sleep SECONDS", blurb: "park the shell for SECONDS (0..60)"},

	// identity (ADR 0024)
	"whoami":  {group: "identity", usage: "whoami", blurb: "print the caller's principal"},
	"id":      {group: "identity", usage: "id", blurb: "print the caller's principal and capability mask"},
	"chmod":   {group: "identity", usage: "chmod MODE FILE", blurb: "owner-only mode change on FILE"},
	"secrets": {group: "identity", usage: "secrets", blurb: "list the caller's store entry names (values stay in the kernel)"},

	// tools (M49 SD3 multicall set; usages mirror the mistyped-invocation text)
	"wc":   {group: "tools", usage: "wc [-l|-w|-c] [FILE...]", blurb: "count lines, words and bytes"},
	"head": {group: "tools", usage: "head [-n LINES] [FILE...]", blurb: "write the first LINES of each input"},
	"tail": {group: "tools", usage: "tail [-n LINES] [FILE...]", blurb: "write the last LINES of each input"},
	"grep": {group: "tools", usage: "grep [-i] PATTERN [FILE...]", blurb: "write the lines that match PATTERN (-i folds case)"},
	"sort": {group: "tools", usage: "sort [-r] [-u] [FILE...]", blurb: "sort lines (-r reverses, -u removes duplicates)"},
	"cut":  {group: "tools", usage: "cut -f LIST [-d C] [FILE...]", blurb: "select fields by LIST ('-d C' sets the delimiter, tab by default)"}, "printf": {group: "tools", usage: "printf FORMAT [ARGS...]", blurb: `write FORMAT with %s/%d/%% substitutions and the escapes \n \t \r \e \xHH \\ \0 (unknown escapes stay literal)`},
	"test": {group: "tools", usage: "test EXPR", blurb: "evaluate EXPR and set $? (no output)"},
	"[":    {group: "tools", usage: "[ EXPR ]", blurb: "evaluate EXPR and set $? (the closing ] is required)"},
	// M98e (issue #2131): the filter-loop composers.
	"tee":      {group: "tools", usage: "tee [-a] FILE...", blurb: "copy stdin to stdout and each FILE (at most 4)", notes: "Needs piped or redirected input — bare `tee F` refuses rather than truncate F."},
	"xargs":    {group: "tools", usage: "xargs [-n N] CMD [ARG...]", blurb: "run CMD once per chunk of stdin lines", notes: "One non-empty line is one item — no quoting or splitting, so names may contain spaces (not POSIX). An external CMD under a redirect or $( ) is refused: its output cannot be captured."},
	"tr":       {group: "tools", usage: "tr [-d] SET1 [SET2]", blurb: "map or delete stdin bytes (a-z ranges; \\n \\t \\\\ escapes)", notes: "[:class:] is refused. Quote bracketed sets — an unquoted [...] word globs."},
	"basename": {group: "tools", usage: "basename PATH [SUFFIX]", blurb: "the last component of PATH, minus SUFFIX", notes: "Pure string op — no filesystem access."},
	"dirname":  {group: "tools", usage: "dirname PATH", blurb: "PATH minus its last component", notes: "Pure string op — no filesystem access."},

	// externals: the verb, then the Go net CLIs a daily user reaches from
	// this prompt by name (M71n #1573 — `exec GOTGIT.ELF` and `exec
	// GOFETCH.ELF` worked but nothing in `help` named them, and GOPING.ELF
	// replaced Zig PING.BIN as the ping a user can discover). They are
	// listed only: the engine execs them like any other image, so D1 ("exec
	// Go binaries; do not grow a POSIX inetutils builtin table") is
	// untouched — no builtin, no tool, just a catalog row.
	helpExternal:       {group: "externals", usage: "exec NAME [args...]", blurb: "(& backgrounds it; jobs/fg track it)", notes: "NAME resolves bare, then with .ELF and .BIN, case-insensitively, out of the share."},
	"GOFETCH.ELF":      {group: "externals", usage: "exec GOFETCH.ELF {https://HOST[:PORT]/ [sni [name|expired|chain]] | http://HOST[:PORT]/[PATH] | --download [URL [DEST]]}", blurb: "fetch a page over in-process TLS, or fetch/save one over cleartext HTTP (Go)", notes: "An https URL is never rewritten to http. Cleartext fetch prints to the console (exit 42; 3 offline, 4 no route); --download saves the body to /host/DOWNLOAD.OUT (or DEST)."},
	"GOPING.ELF":       {group: "externals", usage: "exec GOPING.ELF [-c count] <a.b.c.d>", blurb: "ICMP echo to a dotted IPv4 address (Go)", notes: "Exits 2 when no IP is set and 3 when the destination is not ARP-resolved."},
	"GONETSTAT.ELF":    {group: "externals", usage: "exec GONETSTAT.ELF", blurb: "network interface and connection dashboard (Go)", notes: "Refreshes interface, DHCP, TCP, UDP, ARP and counters on the app timer."},
	"GODNS.ELF":        {group: "externals", usage: "exec GODNS.ELF <hostname> [<server_ip>]", blurb: "resolve a DNS A record over UDP (Go)", notes: "The default resolver is 10.0.0.2; lookup failures exit nonzero."},
	"GOTRACEROUTE.ELF": {group: "externals", usage: "exec GOTRACEROUTE.ELF [-m max_attempts] [-q probes] [<ip>]", blurb: "bounded ICMP echo reachability probe (Go)", notes: "The ICMP syscall reports echo replies only; this does not discover routes."},
	"GOTGIT.ELF":       {group: "externals", usage: "exec GOTGIT.ELF clone https://HOST[:PORT]/REPO [DIR]", blurb: "clone a git repository over in-process TLS (Go)", notes: "Clone is the supported verb; the work tree lands on the share."},
}

// helpGroupNames lists one group's verbs, sorted, or nil when the group is
// empty or unknown.
func helpGroupNames(group string) []string {
	var out []string
	for name, e := range helpCatalog {
		if e.group == group {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

// HelpRow is the public read-only shape of one catalog row (M74c #1646):
// everything `help <cmd>` prints, without the printing. GOHELP.ELF renders
// these rows directly, so the help browser cannot fork the shell's help
// text — when GOSH's help changes, the browser follows (the class-A drift
// test pins the map against the real tables, so both faces stay honest).
type HelpRow struct {
	Name  string
	Group string
	Usage string
	Blurb string
	Notes string
}

// HelpSections lists the catalog's sections in display order: the six D1
// groups, then tools, then externals — helpCatalogText's order.
func HelpSections() []string {
	out := make([]string, 0, len(helpGroups)+2)
	out = append(out, helpGroups...)
	return append(out, "tools", "externals")
}

// HelpRows returns every catalog row ordered by HelpSections, then by name
// within a section — the order `help` lists them. Single-sourced from
// helpCatalog: there is no second table for the browser to drift onto.
func HelpRows() []HelpRow {
	rows := make([]HelpRow, 0, len(helpCatalog))
	for _, g := range HelpSections() {
		for _, name := range helpGroupNames(g) {
			e := helpCatalog[name]
			rows = append(rows, HelpRow{Name: name, Group: g, Usage: e.usage,
				Blurb: e.blurb, Notes: e.notes})
		}
	}
	return rows
}

// helpCatalogText renders the D1 grouped catalog. The leading `builtins:`
// line is load-bearing: live-sh-complete and live-sh4 both sequence their
// typed `help` on it, so it stays the first line of the catalog.
func helpCatalogText() string {
	var b strings.Builder
	b.WriteString("builtins:\n")
	for _, g := range helpGroups {
		names := helpGroupNames(g)
		if len(names) == 0 {
			continue
		}
		b.WriteString("  " + g + ": " + strings.Join(names, " ") + "\n")
	}
	b.WriteString("tools: " + strings.Join(ToolNames(), " ") + "\n")
	// The externals section lists the verb AND the app names a user can type
	// (M71n/M78a); `help <name>` gives any row's usage and description.
	b.WriteString("externals: " + strings.Join(helpGroupNames("externals"), " ") + "\n")
	b.WriteString("subset: " + subsetBlurb + "\n")
	b.WriteString("help <cmd> for one verb, help <group> for one group\n")
	return b.String()
}

// helpOne prints one verb's page, one group's member list, or the D3
// unknown-verb shape. The order matters: a verb name always wins over a
// group name, so `help jobs` is the builtin and `help identity` the group.
func helpOne(c *cmdCtx, name string) int {
	if e, ok := helpCatalog[name]; ok {
		var b strings.Builder
		b.WriteString(name + " \u2014 " + e.blurb + "\n")
		b.WriteString("usage: " + e.usage + "\n")
		if e.notes != "" {
			b.WriteString(e.notes + "\n")
		}
		c.out([]byte(b.String()))
		return 0
	}
	if names := helpGroupNames(name); names != nil {
		c.out([]byte(name + ": " + strings.Join(names, " ") + "\n"))
		return 0
	}
	if name == "tools" {
		c.out([]byte("tools: " + strings.Join(ToolNames(), " ") + "\n"))
		return 0
	}
	// `help externals` is served by the group branch above (the group is never
	// empty — `exec` is a member).
	c.out([]byte("unknown command '" + name + "' \u2014 try 'help'\n"))
	return 1
}

// bHelp is D1 discovery: a grouped catalog with no argument, one verb's
// usage and description with a name, and D3's unknown-verb shape for a name
// that is neither a verb nor a group.
func bHelp(c *cmdCtx) int {
	switch len(c.args) {
	case 0:
		c.out([]byte(helpCatalogText()))
		return 0
	case 1:
		return helpOne(c, c.args[0])
	default:
		c.out([]byte("usage: help [CMD|GROUP]\n  hint: try 'help' for the grouped catalog\n"))
		return 2
	}
}

func bExit(c *cmdCtx) int {
	c.sh.exitReq = true
	if len(c.args) > 0 {
		if n, ok := parseInt(c.args[0]); ok {
			return n
		}
		c.out([]byte("gosh: exit [status]\n"))
		return 2
	}
	return c.sh.status
}

func bMonitor(c *cmdCtx) int {
	c.sh.monitorRq = true
	return 0
}

// bSleep parks the shell for about n seconds (the scheduler runs at about
// 100 Hz; the glue converts seconds to ticks). Bound at 60 so a typo can
// not wedge the front-end forever.
func bSleep(c *cmdCtx) int {
	if len(c.args) != 1 {
		c.out([]byte("gosh: sleep SECONDS\n"))
		return 2
	}
	n, ok := parseInt(c.args[0])
	if !ok || n < 0 || n > 60 {
		c.out([]byte("gosh: sleep 0..60\n"))
		return 2
	}
	if n > 0 {
		c.sh.host.SleepSeconds(n)
	}
	return 0
}

func bClear(c *cmdCtx) int {
	c.out([]byte("\x1b[2J\x1b[H"))
	return 0
}
