package main

import (
	"fmt"
	"strconv"
	"strings"

	"virelai/strace"
	"virelai/vi"
)

func die(err error) {
	vi.ConsoleLine("strace: " + err.Error())
	vi.Exit(1)
}

func main() {
	args := vi.Args()
	if len(args) > 0 {
		args = args[1:]
	}
	var slots []uint64
	if len(args) >= 2 && args[0] == "-e" {
		var err error
		slots, err = parseSlots(args[1])
		if err != nil {
			die(err)
		}
		args = args[2:]
	}
	var session *strace.Session
	var pid uint64
	var err error
	switch {
	case len(args) >= 2 && args[0] == "exec":
		session, pid, err = strace.ArmExec(args[1], args[2:], slots)
	case len(args) >= 2 && args[0] == "-p":
		pid, err = resolve(args[1])
		if err == nil && len(args) == 4 && args[2] == "-e" {
			slots, err = parseSlots(args[3])
		} else if len(args) != 2 {
			err = strace.Error{Code: vi.ErrEINVAL}
		}
		if err == nil {
			session, err = strace.Arm([]uint64{pid}, slots)
		}
	default:
		vi.ConsoleLine("usage: strace -p <pid|name> [-e slot,...] | [-e slot,...] exec <file> [args...]")
		vi.Exit(1)
	}
	if err != nil {
		die(err)
	}
	vi.ConsoleLine(fmt.Sprintf("strace: session=%d pid=%d", session.Token, pid))
	deadline := vi.Nanos() + 120*1e9
	for vi.Nanos() < deadline {
		dropped, err := session.Drain(0, nil)
		if err != nil {
			die(err)
		}
		if dropped != 0 {
			vi.ConsoleLine(fmt.Sprintf("strace: dropped=%d", dropped))
		}
		_, state := vi.Probe(int64(pid))
		if state != vi.ProbeRunning {
			if err := session.Disarm(); err != nil {
				die(err)
			}
			// Drain the last records after disarming. Disarm never clears them.
			dropped, err = session.Drain(0, nil)
			if err != nil {
				die(err)
			}
			vi.ConsoleLine(fmt.Sprintf("strace: done dropped=%d", dropped))
			return
		}
		vi.Sleep(1)
	}
	_ = session.Disarm()
	die(fmt.Errorf("target still running after 120 seconds"))
}

func parseSlots(value string) ([]uint64, error) {
	slots := make([]uint64, 0)
	for _, word := range strings.Split(value, ",") {
		slot, err := strconv.ParseUint(word, 10, 7)
		if err != nil {
			return nil, err
		}
		slots = append(slots, slot)
	}
	return slots, nil
}

func resolve(value string) (uint64, error) {
	if pid, err := strconv.ParseUint(value, 10, 64); err == nil {
		return pid, nil
	}
	var rows [16]vi.ProcRow
	n, rc := vi.Procs(rows[:])
	if rc < 0 {
		return 0, strace.Error{Code: -rc}
	}
	var found uint64
	count := 0
	for _, row := range rows[:n] {
		if strings.EqualFold(row.Name(), value) && row.State != vi.ProcExited {
			found = row.PID
			count++
		}
	}
	if count != 1 {
		return 0, fmt.Errorf("target name must match one live process")
	}
	return found, nil
}
