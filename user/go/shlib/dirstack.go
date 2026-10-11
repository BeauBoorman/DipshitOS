// Directory navigation state (M98d, issue #2130): `cd -` toggles through
// OLDPWD, and pushd/popd/dirs keep a bounded per-session directory stack.
// Every entry holds the canonical /-rooted form resolvePath produces, so
// `dirs` never prints `/host/...` or `..`, and a stack entry works as a
// `cd` target unchanged. The stack lives on Shell, so `$(pushd X)` and a
// `source`d file share it — there are no subshells.
package shlib

import (
	"strings"

	"virelai/vsys"
)

// dirStackMax bounds the pushd/popd stack: a shell that cannot grow a
// structure loudly refuses rather than silently dropping entries.
const dirStackMax = 8

// chdirTo performs one directory change exactly as `cd TARGET` reports
// it: resolve against PWD, host.Chdir on the resolved host path, and on
// success move PWD and set OLDPWD to the directory left (every successful
// change — cd, cd -, pushd, popd — feeds OLDPWD). The stack is never
// touched here: callers that manage it get ok=true only when the move
// really happened, so a failed pushd/popd leaves it unchanged.
func (s *Shell) chdirTo(c *cmdCtx, target string) (int, bool) {
	rp, rerr := s.resolvePath(target)
	if rerr != nil {
		c.out([]byte("gosh: cd: " + target + ": " + rerr.Error() + "\n"))
		return 1, false
	}
	if err := s.host.Chdir(rp.host); err != nil {
		if oe, denial := deniedAs(err); denial {
			c.out([]byte("gosh: cd: " + target + ": " + oe.name + "\n"))
		} else {
			c.out([]byte("gosh: cd: " + target + ": not a directory\n"))
		}
		return 1, false
	}
	old, _ := s.env.Get("PWD")
	s.env.Set("PWD", rp.canon)
	s.env.Set("OLDPWD", old)
	s.env.Export("OLDPWD")
	return 0, true
}

// dirsLine is the `dirs` report and the line pushd/popd print after a
// successful move: the current directory, then the stack top-first.
func (s *Shell) dirsLine() string {
	var b strings.Builder
	b.WriteString(s.Pwd())
	for i := len(s.dirstack) - 1; i >= 0; i-- {
		b.WriteByte(' ')
		b.WriteString(s.dirstack[i])
	}
	return b.String()
}

// bCd moves the working directory, or toggles to OLDPWD with `cd -`
// (bash's idiom: it prints the new directory on its own line). A bare
// `cd` goes to `/` — there is no HOME.
func bCd(c *cmdCtx) int {
	target := "/"
	if len(c.args) > 0 {
		target = c.args[0]
	}
	dash := false
	if target == "-" {
		v, ok := c.sh.env.Get("OLDPWD")
		if !ok || v == "" {
			c.out([]byte("gosh: cd: OLDPWD not set\n"))
			return 1
		}
		target, dash = v, true
	}
	st, ok := c.sh.chdirTo(c, target)
	if ok && dash {
		c.out([]byte(c.sh.Pwd() + "\n"))
	}
	return st
}

// bPushd changes to DIR and pushes the directory left; bare, it swaps
// PWD with the stack top (bash's `pushd` with no arguments). The move
// happens first and the stack changes only on success — a refused pushd
// or a failed cd alters nothing.
func bPushd(c *cmdCtx) int {
	if len(c.args) > 1 {
		c.out([]byte("gosh: pushd: usage: pushd [DIR]\n"))
		return 2
	}
	pwd := c.sh.Pwd()
	if len(c.args) == 0 {
		n := len(c.sh.dirstack)
		if n == 0 {
			c.out([]byte("gosh: pushd: no other directory\n"))
			return 1
		}
		top := c.sh.dirstack[n-1]
		if st, ok := c.sh.chdirTo(c, top); !ok {
			return st
		}
		c.sh.dirstack[n-1] = pwd
	} else {
		if len(c.sh.dirstack) >= dirStackMax {
			c.out([]byte("gosh: pushd: directory stack full (" + vsys.Itoa64(dirStackMax) + ")\n"))
			return 1
		}
		if st, ok := c.sh.chdirTo(c, c.args[0]); !ok {
			return st
		}
		c.sh.dirstack = append(c.sh.dirstack, pwd)
	}
	c.out([]byte(c.sh.dirsLine() + "\n"))
	return 0
}

// bPopd changes to the stack's top entry and pops it. A failed move
// reports exactly what `cd` would and leaves the stack unchanged — a
// stale entry stays so the user can see what was lost.
func bPopd(c *cmdCtx) int {
	if len(c.args) > 0 {
		c.out([]byte("gosh: popd: usage: popd\n"))
		return 2
	}
	n := len(c.sh.dirstack)
	if n == 0 {
		c.out([]byte("gosh: popd: directory stack empty\n"))
		return 1
	}
	top := c.sh.dirstack[n-1]
	if st, ok := c.sh.chdirTo(c, top); !ok {
		return st
	}
	c.sh.dirstack = c.sh.dirstack[:n-1]
	c.out([]byte(c.sh.dirsLine() + "\n"))
	return 0
}

// bDirs prints the current directory then the stack top-first, one line.
// No flags exist in this shell — `-c`, `-v` and `+N` are out of scope.
func bDirs(c *cmdCtx) int {
	if len(c.args) > 0 {
		c.out([]byte("gosh: dirs: usage: dirs\n"))
		return 2
	}
	c.out([]byte(c.sh.dirsLine() + "\n"))
	return 0
}
