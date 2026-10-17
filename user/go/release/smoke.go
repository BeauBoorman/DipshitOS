package main

// The run-2 driver (M112c, issue #2415): under the guest-built image and
// with the guest-built bundle armed as the share, `gorelease smoke` execs
// each fleet ELF the manifest records and prints a one-token verdict per
// row — the "fleet smoke markers" the card's run 2 asserts.
//
// The verdicts mirror the fleet driver's smoke seam (M112a spawn_guest.go):
// "exited=<status>" for a self-exiting product, "ran:killed" for an
// event-loop app still running at the budget (loaded + runtime-started is
// the proof, not a feature test), "spawn=<err>" / "gone" for failures.

import (
	"virelai/vi"
	"virelai/vsys"
)

// smokeBudgetNs bounds one smoke exec, matching the fleet driver's 8 s.
const smokeBudgetNs = int64(8) * int64(1e9)

// smokeOne is the spawn seam — the guest impl is in spawn_virelai.go's
// spawnAndWait; tests stub it.
var smokeOne = func(name string) string {
	// argv[0] is the kernel-injected image name; no args are needed —
	// argv[1]=name would just be a stray positional for flag-parsing
	// fleet members like GOBUILD.
	pid, err := vi.Exec(name)
	if err != nil {
		return "spawn=" + err.Error()
	}
	st, werr := waitChild(pid, smokeBudgetNs)
	if werr == nil {
		return "exited=" + itoa(int(st))
	}
	if rc := vi.Kill(uint64(pid)); rc == 0 {
		_, _ = waitChild(pid, int64(2)*int64(1e9))
		return "ran:killed"
	}
	return "gone"
}

func runSmoke(cfg relCfg) int {
	cfg.defaults()
	body, err := fileBytes(cfg.Manifest)
	if err != nil {
		vsys.Println("release: FAIL smoke: read " + cfg.Manifest + ": " + err.Error())
		return 1
	}
	rows, err := parseReleaseManifest(string(body))
	if err != nil {
		vsys.Println("release: FAIL smoke: " + err.Error())
		return 1
	}
	ran, bad := 0, 0
	for _, r := range rows {
		if r.Kind != "fleet" {
			continue
		}
		v := smokeOne(r.Path)
		vsys.Println("release: smoke " + r.Path + " " + v)
		if len(v) >= 6 && v[:6] == "spawn=" {
			bad++
		} else {
			ran++
		}
	}
	if ran == 0 {
		vsys.Println("release: FAIL smoke: manifest has no fleet rows")
		return 1
	}
	if bad > 0 {
		vsys.Println("release: smoke FAIL ran=" + itoa(ran) + " spawn_errors=" + itoa(bad))
		return 1
	}
	vsys.Println("release: smoke OK ran=" + itoa(ran))
	return 0
}
