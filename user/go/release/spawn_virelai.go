//go:build virelai

package main

import (
	"virelai/vi"
)

// The guest half of the spawn seam: vi.Exec (ADR 0007 slot 28) plus a wait
// that survives pid 0 — pid 0 is a REAL registry slot once create_as starts
// recycling exited descriptors, but vi.Probe/vi.WaitBudget treat pid <= 0 as
// EINVAL (user/go/vi/proc.go). The wait below is the pid-0-safe shape
// GOBUILD's fleet driver uses: WaitBudget for pid > 0, a sys_procs poll for
// pid 0 (exited -> status, vanished-after-seen -> 0).
func spawnAndWait(image string, args []string, budgetNs int64) (int64, error) {
	pid, err := vi.Exec(image, args...)
	if err != nil {
		return -1, err
	}
	return waitChild(pid, budgetNs)
}

func waitChild(pid int64, budgetNs int64) (int64, error) {
	if pid > 0 {
		return vi.WaitBudget(pid, budgetNs)
	}
	deadline := vi.Nanos() + budgetNs
	seen := false
	var rows [16]vi.ProcRow
	for vi.Nanos() < deadline {
		n, rc := vi.Procs(rows[:])
		if rc >= 0 {
			live := false
			for i := 0; i < n; i++ {
				if int64(rows[i].PID) == 0 {
					if rows[i].State == vi.ProcExited {
						return int64(rows[i].ExitStatus), nil
					}
					live = true
					break
				}
			}
			if live {
				seen = true
			} else if seen {
				return 0, nil
			}
		}
		vi.Sleep(1)
	}
	return -1, vi.ErrWaitGone
}
