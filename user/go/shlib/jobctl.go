package shlib

// M98f (issue #2132): job control and Ctrl-C. One shared interrupt source
// (TTYPoll) for both front-ends, an interruptible foreground wait behind
// runExternal and fg, and the kill/jobs -l surface. The owner decision is
// no `bg` and no Ctrl-Z: nothing suspends a guest job, so there is nothing
// to resume — job control is `jobs`, `fg N` and `kill %N` only.

import (
	"strings"

	"virelai/vsys"
)

// ticksPerSleepSecond mirrors the front-ends' constant (and their actual
// behavior): `sleep N` converts seconds to ticks at 100:1 — on the real
// 1 Hz kernel tick that is 100·N seconds. The interruptible path keeps
// the same total so both hosts agree; Ctrl-C is the escape.
const ticksPerSleepSecond = 100

// killConfirmTicks bounds the post-Ctrl-C poll: sys_kill ARMS the target
// (the exit arrives at its next ring selection, with status 137), so the
// shell waits for the exit row rather than declaring death itself — but
// not forever. Two 1 Hz ticks ≈ the card's two seconds.
const killConfirmTicks = 2

// typeAheadMax bounds the keystroke stash: type-ahead exists so input made
// while a child runs is not lost, not to buffer a paste flood.
const typeAheadMax = 256

// interruptByte is Ctrl-C on the tty.
const interruptByte = 0x03

// statusInterrupted is bash's 128+SIGINT.
const statusInterrupted = 130

// TTYPoll is the shared Ctrl-C source: a thin non-blocking reader over the
// front-end's tty fd. Read is vi.FileRead wired by the host; host tests
// feed it a scripted byte stream.
type TTYPoll struct {
	Read  func([]byte) int
	ahead []byte
}

// Interrupted does one drain of the tty. It returns true when 0x03
// arrived; every other byte is stashed, in order, as type-ahead so a key
// pressed while a child ran is not lost. A child that also reads the tty
// can lose its input to this drain — every byte it did not get is kept for
// the shell, the card's documented trade.
func (p *TTYPoll) Interrupted() bool {
	if p == nil || p.Read == nil {
		return false
	}
	var buf [64]byte
	hit := false
	for {
		n := p.Read(buf[:])
		if n <= 0 {
			return hit
		}
		for i := 0; i < n; i++ {
			if buf[i] == interruptByte {
				hit = true
				continue
			}
			if len(p.ahead) < typeAheadMax {
				p.ahead = append(p.ahead, buf[i])
			}
		}
	}
}

// TypeAhead drains the stash; the front-end feeds it to the editor after
// each RunLine, before its next FileRead.
func (p *TTYPoll) TypeAhead() []byte {
	if p == nil {
		return nil
	}
	b := p.ahead
	p.ahead = nil
	return b
}

// interrupter is the optional host seam for Ctrl-C: an interactive
// front-end exposes its tty read; a headless one (`-c`) does not, and its
// waits keep the blocking WaitExternal path.
type interrupter interface {
	TTYInterrupter() *TTYPoll
}

// killer is the optional host seam behind `kill` and Ctrl-C (vi.Kill on
// the front-ends). The error carries the kernel's errno name.
type killer interface {
	Kill(pid int64) error
}

// exited is the optional host seam that keeps the blocking path's
// side-effects — GOSH's crash receipt on a nonzero exit and its
// children-table cleanup — alive on the interruptible wait. `killed`
// marks a kill the shell armed itself: the card says that is not a crash
// and must not write a receipt (cleanup still applies).
type exited interface {
	ExternalExited(pid int64, status int64, killed bool)
}

// notifyExited reports an observed exit row to the host when it can.
func (s *Shell) notifyExited(pid int64, status int64, killed bool) {
	if e, ok := s.host.(exited); ok {
		e.ExternalExited(pid, status, killed)
	}
}

// ttyPoll answers the host's interrupt source, or nil.
func (s *Shell) ttyPoll() *TTYPoll {
	if i, ok := s.host.(interrupter); ok {
		return i.TTYInterrupter()
	}
	return nil
}

// armKill forwards one kill to the host when it can. A refused arm still
// counts as armed for the confirm bound — the shell reports and moves on
// rather than wait forever.
func (s *Shell) armKill(pid int64) {
	if k, ok := s.host.(killer); ok {
		_ = k.Kill(pid)
	}
}

// waitForeground is the interruptible foreground wait: probe once per tick
// with NO deadline — Ctrl-C is the interactive escape hatch, which retires
// the 120 s WaitBudget ceiling for tty shells. A pid seen running and then
// absent is status 0 — the reaped-and-recycled rule copied from
// vi.WaitBudget (user/go/vi/proc.go); the two must never disagree.
//
// On 0x03 the shell arms sys_kill, writes ^C, and keeps polling: the exit
// row reports the child's real status (137, the reserved kill status), the
// serial marker makes the interrupt observable, and the answer to the
// caller is statusInterrupted. A child still running killConfirmTicks
// after the arm is reported, not waited on forever. The bool result tells
// the caller the wait ended on an interrupt (fg prints its own line).
func (s *Shell) waitForeground(name string, pid int64, intr *TTYPoll) (int, bool) {
	seen := false
	armed := false
	armedTicks := 0
	for {
		st, state := s.host.ProbeExternal(pid)
		switch state {
		case probeExited:
			s.notifyExited(pid, st, armed)
			if armed {
				s.host.Marker("gosh: interrupt pid=" + vsys.Itoa64(pid) + " exit=" + vsys.Itoa64(st))
				return statusInterrupted, true
			}
			return int(st), false
		case probeRunning:
			seen = true
		case probeAbsent:
			if seen {
				s.notifyExited(pid, st, armed)
				if armed {
					s.host.Marker("gosh: interrupt pid=" + vsys.Itoa64(pid) + " exit=" + vsys.Itoa64(st))
					return statusInterrupted, true
				}
				return 0, false // reaped and recycled, same as WaitBudget
			}
		}
		if !armed && intr.Interrupted() {
			armed = true
			s.armKill(pid)
			s.host.Out([]byte("^C\r\n"))
		}
		if armed {
			armedTicks++
			if armedTicks > killConfirmTicks {
				s.host.Out([]byte("gosh: " + name + ": kill armed, child still running\n"))
				return statusInterrupted, true
			}
		}
		s.host.SleepTick()
	}
}

// bJobs lists the job table; finished jobs are reported once and removed.
// `-l` adds the pid between the bracket and the state.
func bJobs(c *cmdCtx) int {
	long := false
	if len(c.args) == 1 && c.args[0] == "-l" {
		long = true
	} else if len(c.args) != 0 {
		c.out([]byte("gosh: jobs [-l]\n"))
		return 2
	}
	c.sh.ReapJobs()
	for _, j := range append([]*Job{}, c.sh.jobs...) {
		pid := ""
		if long {
			pid = " " + vsys.Itoa64(j.PID)
		}
		if j.Done {
			c.out([]byte("[" + vsys.Itoa64(int64(j.N)) + "]" + pid + " Done: " + j.Display +
				" (exit=" + vsys.Itoa64(j.Status) + ")\n"))
			c.sh.removeJob(j)
		} else {
			c.out([]byte("[" + vsys.Itoa64(int64(j.N)) + "]" + pid + " running: " + j.Display + "\n"))
		}
	}
	return 0
}

// bFg waits for one background job and propagates its exit status into $?.
// Nothing suspends a guest job, so there is no `bg` to return a job to and
// no `wait` for the table as a whole — fg is the way you wait, the same
// contract the kernel monitor's job table documents. Ctrl-C kills the job
// it was waiting on: the table drops it and $? is 130.
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
	intr := c.sh.ttyPoll()
	armed := false
	armedTicks := 0
	for !j.Done {
		// ReapJobs (not a bare probe) so the job's own `gosh: job N done`
		// marker fires even when the wait ends on Ctrl-C.
		c.sh.ReapJobs()
		if j.Done {
			break
		}
		if intr != nil && intr.Interrupted() {
			if !armed {
				armed = true
				c.sh.armKill(j.PID)
				c.sh.host.Out([]byte("^C\r\n"))
			}
		}
		if armed {
			armedTicks++
			if armedTicks > killConfirmTicks {
				c.sh.host.Out([]byte("gosh: " + j.Display + ": kill armed, child still running\n"))
				c.out([]byte("[" + vsys.Itoa64(int64(j.N)) + "] Interrupted: " + j.Display + "\n"))
				c.sh.removeJob(j)
				return statusInterrupted
			}
		}
		c.sh.host.SleepTick()
	}
	if armed {
		c.out([]byte("[" + vsys.Itoa64(int64(j.N)) + "] Interrupted: " + j.Display + "\n"))
		c.sh.removeJob(j)
		return statusInterrupted
	}
	c.out([]byte("[" + vsys.Itoa64(int64(j.N)) + "] Done: " + j.Display +
		" (exit=" + vsys.Itoa64(j.Status) + ")\n"))
	c.sh.removeJob(j)
	return int(j.Status)
}

// bKill arms sys_kill against each target: `%N` names a job-table row, a
// bare number a pid. Success is silent — the job's own ReapJobs line
// reports the exit (137) when it lands. Errors carry the kernel's errno
// name (EINVAL: the process is absent or already exited; EACCES: a
// cross-uid target, which a shell child cannot be).
func bKill(c *cmdCtx) int {
	if len(c.args) == 0 {
		c.out([]byte("gosh: kill [%N|PID]...\n"))
		return 2
	}
	k, ok := c.sh.host.(killer)
	if !ok {
		c.out([]byte("kill: unavailable\n"))
		return 1
	}
	rc := 0
	for _, a := range c.args {
		var pid int64
		if strings.HasPrefix(a, "%") {
			n, ok := parseInt(a[1:])
			var j *Job
			if ok {
				j = c.sh.jobByN(n)
			}
			if j == nil {
				c.out([]byte("gosh: kill: " + a + ": no such job\n"))
				rc = 1
				continue
			}
			pid = j.PID
		} else {
			n, ok := parseInt(a)
			if !ok || n <= 0 {
				c.out([]byte("gosh: kill: " + a + ": no such process\n"))
				rc = 1
				continue
			}
			pid = int64(n)
		}
		if err := k.Kill(pid); err != nil {
			if err.Error() == "EINVAL" {
				c.out([]byte("gosh: kill: " + a + ": no such process\n"))
			} else {
				c.out([]byte("gosh: kill: " + a + ": " + err.Error() + "\n"))
			}
			rc = 1
		}
	}
	return rc
}
