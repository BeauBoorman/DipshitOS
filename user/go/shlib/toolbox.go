// GOSH's toolbox: the M49 SD3 multicall set (head, tail, wc, grep, sort,
// cut, test, [, printf) as pure in-process tools. Running in-process is the
// point — it is what makes their output pipe- and redirect-visible, exactly
// as SH.BIN's toolbox works. Everything here is host-testable.
package shlib

import (
	"sort"
	"strings"

	"virelai/vsys"
)

var tools map[string]func(*cmdCtx) int

func init() {
	tools = map[string]func(*cmdCtx) int{
		"wc": tWc, "head": tHead, "tail": tTail, "grep": tGrep,
		"sort": tSort, "cut": tCut, "printf": tPrintf, "test": tTest, "[": tTest,
	}
}

// toolInput resolves a tool's input: the named files (read through the
// host seam) or the bound stdin when none are named.
func toolInput(c *cmdCtx, files []string) ([]byte, int) {
	if len(files) == 0 {
		return c.stdin, 0
	}
	var all []byte
	for _, f := range files {
		b, err := c.sh.readBounded(f)
		if err != nil {
			if err == errTooLarge {
				c.out([]byte("gosh: " + c.args[0] + ": " + f + ": " + errTooLarge.Error() + "\n"))
			} else if msg := resolveDenial(err); msg != "" {
				c.out([]byte("gosh: " + c.args[0] + ": " + f + ": " + msg + "\n"))
			} else {
				c.out([]byte("gosh: " + c.args[0] + ": " + f + ": not found\n"))
			}
			return nil, 1
		}
		all = append(all, b...)
	}
	return all, 0
}

func splitLines(b []byte) []string {
	s := strings.ReplaceAll(string(b), "\r\n", "\n")
	s = strings.TrimSuffix(s, "\n")
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

// tWc counts lines (-l), words (-w) or bytes (-c); all three by default.
// With one input name the count line carries it, like TOOL.BIN's wc.
func tWc(c *cmdCtx) int {
	mode := ""
	var files []string
	for _, a := range c.args {
		switch {
		case a == "-l" || a == "-w" || a == "-c":
			mode = string(a[1])
		case strings.HasPrefix(a, "-"):
			c.out([]byte("gosh: wc [-l|-w|-c] [FILE...]\n"))
			return 2
		default:
			files = append(files, a)
		}
	}
	in, st := toolInput(c, files)
	if st != 0 {
		return st
	}
	count := func(b []byte) []int64 {
		var lines, words, bytes int64
		lines = int64(len(splitLines(b)))
		if len(b) > 0 {
			lines = int64(strings.Count(string(b), "\n"))
			if b[len(b)-1] != '\n' {
				lines++
			}
		}
		words = int64(len(strings.Fields(string(b))))
		bytes = int64(len(b))
		return []int64{lines, words, bytes}
	}
	vals := count(in)
	var parts []string
	switch mode {
	case "l":
		parts = []string{vsys.Itoa64(vals[0])}
	case "w":
		parts = []string{vsys.Itoa64(vals[1])}
	case "c":
		parts = []string{vsys.Itoa64(vals[2])}
	default:
		parts = []string{vsys.Itoa64(vals[0]), vsys.Itoa64(vals[1]), vsys.Itoa64(vals[2])}
	}
	line := strings.Join(parts, " ")
	if len(files) == 1 {
		line += " " + files[0]
	}
	c.out([]byte(line + "\n"))
	return 0
}

func tHead(c *cmdCtx) int {
	n := 10
	var files []string
	for i := 0; i < len(c.args); i++ {
		a := c.args[i]
		switch {
		case a == "-n" && i+1 < len(c.args):
			i++
			v, ok := parseInt(c.args[i])
			if !ok || v < 0 {
				c.out([]byte("gosh: head [-n LINES] [FILE...]\n"))
				return 2
			}
			n = v
		case strings.HasPrefix(a, "-"):
			c.out([]byte("gosh: head [-n LINES] [FILE...]\n"))
			return 2
		default:
			files = append(files, a)
		}
	}
	in, st := toolInput(c, files)
	if st != 0 {
		return st
	}
	lines := splitLines(in)
	if len(lines) > n {
		lines = lines[:n]
	}
	if len(lines) > 0 {
		c.out([]byte(strings.Join(lines, "\n") + "\n"))
	}
	return 0
}

func tTail(c *cmdCtx) int {
	n := 10
	var files []string
	for i := 0; i < len(c.args); i++ {
		a := c.args[i]
		switch {
		case a == "-n" && i+1 < len(c.args):
			i++
			v, ok := parseInt(c.args[i])
			if !ok || v < 0 {
				c.out([]byte("gosh: tail [-n LINES] [FILE...]\n"))
				return 2
			}
			n = v
		case strings.HasPrefix(a, "-"):
			c.out([]byte("gosh: tail [-n LINES] [FILE...]\n"))
			return 2
		default:
			files = append(files, a)
		}
	}
	in, st := toolInput(c, files)
	if st != 0 {
		return st
	}
	lines := splitLines(in)
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	if len(lines) > 0 {
		c.out([]byte(strings.Join(lines, "\n") + "\n"))
	}
	return 0
}

// tGrep prints the lines containing PATTERN (substring; -i folds case).
func tGrep(c *cmdCtx) int {
	fold := false
	var files []string
	var pattern string
	for _, a := range c.args {
		switch {
		case a == "-i":
			fold = true
		case strings.HasPrefix(a, "-") && a != "-":
			c.out([]byte("gosh: grep [-i] PATTERN [FILE...]\n"))
			return 2
		case pattern == "":
			pattern = a
		default:
			files = append(files, a)
		}
	}
	if pattern == "" {
		c.out([]byte("gosh: grep [-i] PATTERN [FILE...]\n"))
		return 2
	}
	in, st := toolInput(c, files)
	if st != 0 {
		return st
	}
	if fold {
		pattern = strings.ToLower(pattern)
	}
	found := false
	for _, line := range splitLines(in) {
		hay := line
		if fold {
			hay = strings.ToLower(hay)
		}
		if strings.Contains(hay, pattern) {
			found = true
			c.out([]byte(line + "\n"))
		}
	}
	if !found {
		return 1
	}
	return 0
}

// tSort sorts input lines; -r reverses, -u deduplicates.
func tSort(c *cmdCtx) int {
	rev, uniq := false, false
	var files []string
	for _, a := range c.args {
		switch a {
		case "-r":
			rev = true
		case "-u":
			uniq = true
		case "-ru", "-ur":
			rev, uniq = true, true
		default:
			if strings.HasPrefix(a, "-") {
				c.out([]byte("gosh: sort [-r] [-u] [FILE...]\n"))
				return 2
			}
			files = append(files, a)
		}
	}
	in, st := toolInput(c, files)
	if st != 0 {
		return st
	}
	lines := splitLines(in)
	sort.Strings(lines)
	if uniq {
		lines = dedup(lines)
	}
	if rev {
		for i, j := 0, len(lines)-1; i < j; i, j = i+1, j-1 {
			lines[i], lines[j] = lines[j], lines[i]
		}
	}
	if len(lines) > 0 {
		c.out([]byte(strings.Join(lines, "\n") + "\n"))
	}
	return 0
}

func dedup(sorted []string) []string {
	out := sorted[:0]
	for i, s := range sorted {
		if i == 0 || s != sorted[i-1] {
			out = append(out, s)
		}
	}
	return out
}

// tCut selects fields split on a one-byte delimiter (-d, default tab).
func tCut(c *cmdCtx) int {
	delim := byte('\t')
	var fields []int // 1-based, from -f LIST
	var files []string
	for i := 0; i < len(c.args); i++ {
		a := c.args[i]
		switch {
		case a == "-d" && i+1 < len(c.args):
			i++
			if len(c.args[i]) == 0 {
				// `cut -d ""` tokenizes to a genuine empty word (quoting
				// makes a word, not a separator), so indexing byte 0 here
				// would panic the shell on a typed line. GNU cut refuses the
				// same argument.
				c.out([]byte("gosh: cut: -d needs one delimiter character\n"))
				return 2
			}
			delim = c.args[i][0]
		case a == "-f" && i+1 < len(c.args):
			i++
			list, ok := parseFieldList(c.args[i])
			if !ok {
				c.out([]byte("gosh: cut -f LIST [-d C] [FILE...]\n"))
				return 2
			}
			fields = list
		default:
			if strings.HasPrefix(a, "-") {
				c.out([]byte("gosh: cut -f LIST [-d C] [FILE...]\n"))
				return 2
			}
			files = append(files, a)
		}
	}
	if len(fields) == 0 {
		c.out([]byte("gosh: cut -f LIST [-d C] [FILE...]\n"))
		return 2
	}
	in, st := toolInput(c, files)
	if st != 0 {
		return st
	}
	for _, line := range splitLines(in) {
		parts := strings.Split(line, string(delim))
		var sel []string
		for _, f := range fields {
			if f >= 1 && f <= len(parts) {
				sel = append(sel, parts[f-1])
			}
		}
		c.out([]byte(strings.Join(sel, string(delim)) + "\n"))
	}
	return 0
}

// parseFieldList accepts "2", "1,3" and "2-4" (1-based, ascending).
func parseFieldList(s string) ([]int, bool) {
	var out []int
	for _, part := range strings.Split(s, ",") {
		if lo, hi, ok := strings.Cut(part, "-"); ok {
			a, ok1 := parseInt(lo)
			b, ok2 := parseInt(hi)
			if !ok1 || !ok2 || a < 1 || b < a {
				return nil, false
			}
			for n := a; n <= b; n++ {
				out = append(out, n)
			}
			continue
		}
		n, ok := parseInt(part)
		if !ok || n < 1 {
			return nil, false
		}
		out = append(out, n)
	}
	return out, true
}

// printfHexNibble reads a hex nibble at index i, reporting whether one
// sits there (bounds-safe: \x at the end of the format is not a pair).
func printfHexNibble(s string, i int) (byte, bool) {
	if i < 0 || i >= len(s) {
		return 0, false
	}
	switch ch := s[i]; {
	case ch >= '0' && ch <= '9':
		return ch - '0', true
	case ch >= 'a' && ch <= 'f':
		return ch - 'a' + 10, true
	case ch >= 'A' && ch <= 'F':
		return ch - 'A' + 10, true
	default:
		return 0, false
	}
}

// tPrintf implements %s, %d and %%, plus the escape set of the retired Zig
// toolbox (user/src/lib/toolbox.zig runPrintf): \n \t \r \e \xHH \\ \0,
// any other backslash escape staying literal. \e and \xHH are the bounded
// way a typed line emits ANSI CSI sequences and UTF-8 rune bytes — M73a-2
// (#1631) added them to the Zig tool; shlib lacked them until M73d (#1628),
// observed 2026-09-22: live-term's whole SGR burst reached GOTERM as
// literal text, so the grid never cleared and never painted the burst.
func tPrintf(c *cmdCtx) int {
	if len(c.args) == 0 {
		c.out([]byte("gosh: printf FORMAT [ARGS...]\n"))
		return 2
	}
	fmt_ := c.args[0]
	argv := c.args[1:]
	argi := 0
	var b strings.Builder
	for i := 0; i < len(fmt_); i++ {
		ch := fmt_[i]
		switch ch {
		case '\\':
			if i+1 < len(fmt_) {
				i++
				switch fmt_[i] {
				case 'n':
					b.WriteByte('\n')
				case 't':
					b.WriteByte('\t')
				case 'r':
					b.WriteByte('\r')
				case 'e':
					b.WriteByte(0x1b)
				case 'x':
					hi, ok1 := printfHexNibble(fmt_, i+1)
					lo, ok2 := printfHexNibble(fmt_, i+2)
					if ok1 && ok2 {
						b.WriteByte(hi<<4 | lo)
						i += 2
					} else {
						// Not a hex pair: emit `\x` literally (Zig parity).
						b.WriteByte('\\')
						b.WriteByte('x')
					}
				case '0':
					b.WriteByte(0)
				case '\\':
					b.WriteByte('\\')
				default:
					b.WriteByte('\\')
					b.WriteByte(fmt_[i])
				}
			}
		case '%':
			if i+1 < len(fmt_) {
				i++
				switch fmt_[i] {
				case '%':
					b.WriteByte('%')
				case 's':
					if argi < len(argv) {
						b.WriteString(argv[argi])
						argi++
					}
				case 'd':
					if argi < len(argv) {
						if n, ok := parseInt(argv[argi]); ok {
							b.WriteString(vsys.Itoa64(int64(n)))
						}
						argi++
					}
				default:
					b.WriteByte('%')
					b.WriteByte(fmt_[i])
				}
			}
		default:
			b.WriteByte(ch)
		}
	}
	c.out([]byte(b.String()))
	return 0
}

// tTest evaluates the M49 test subset: string truth/-n/-z, = and !=,
// -e PATH, the integer comparisons, and a leading !. `[` drops its
// trailing bracket before this runs.
func tTest(c *cmdCtx) int {
	args := c.args
	if c.name == "[" {
		if len(args) > 0 && args[len(args)-1] == "]" {
			args = args[:len(args)-1]
		} else {
			c.out([]byte("gosh: [: missing ]\n"))
			return 2
		}
	}
	var eval func(a []string) (bool, int)
	eval = func(a []string) (bool, int) {
		switch len(a) {
		case 1:
			return a[0] != "", 0
		case 2:
			switch a[0] {
			case "-n":
				return a[1] != "", 0
			case "-z":
				return a[1] == "", 0
			case "-e":
				rp, rerr := c.sh.resolvePath(a[1])
				if rerr != nil {
					return false, 0
				}
				_, err := c.sh.host.ReadFile(rp.host, 1)
				return err == nil, 0
			case "!":
				v, st := eval(a[1:])
				return !v, st
			}
			return false, 2
		case 3:
			switch a[1] {
			case "=":
				return a[0] == a[2], 0
			case "!=":
				return a[0] != a[2], 0
			case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
				x, ok1 := parseInt(a[0])
				y, ok2 := parseInt(a[2])
				if !ok1 || !ok2 {
					return false, 2
				}
				switch a[1] {
				case "-eq":
					return x == y, 0
				case "-ne":
					return x != y, 0
				case "-lt":
					return x < y, 0
				case "-le":
					return x <= y, 0
				case "-gt":
					return x > y, 0
				default:
					return x >= y, 0
				}
			case "-e":
				rp, rerr := c.sh.resolvePath(a[2])
				if rerr != nil {
					return false, 0
				}
				_, err := c.sh.host.ReadFile(rp.host, 1)
				return err == nil, 0
			}
			return false, 2
		}
		return false, 2
	}
	v, st := eval(args)
	if st != 0 {
		c.out([]byte("gosh: test: unsupported expression\n"))
		return st
	}
	if v {
		return 0
	}
	return 1
}
