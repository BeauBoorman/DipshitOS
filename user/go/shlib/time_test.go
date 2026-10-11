package shlib

import (
	"strings"
	"testing"

	"virelai/timesync"
)

// stubSync swaps the SNTP call for the test and records what the builtin
// asked for, so no test here touches a socket.
func stubSync(t *testing.T, res timesync.Result) *[]string {
	t.Helper()
	prev := timeSync
	t.Cleanup(func() { timeSync = prev })
	var asked []string
	timeSync = func(server string) timesync.Result {
		asked = append(asked, server)
		res.Server = server
		return res
	}
	return &asked
}

func TestTimeSyncPrintsTheResultAndExitsZeroWhenSet(t *testing.T) {
	asked := stubSync(t, timesync.Result{
		Status: timesync.StatusSet, IP: [4]byte{10, 0, 0, 2}, Stratum: 2,
		DelayNs: 3_000_000, HadClock: true, Before: 1_789_000_000,
		Epoch: 1_789_003_600, Correction: 3600, Now: 1_789_003_600,
	})
	h := newFakeHost()
	run, _ := session(h)
	if st := run("time sync 10.0.0.2"); st != 0 {
		t.Fatalf("time sync status = %d, want 0 (output %q)", st, h.outString())
	}
	if len(*asked) != 1 || (*asked)[0] != "10.0.0.2" {
		t.Fatalf("asked %v, want exactly [10.0.0.2]", *asked)
	}
	want := "time sync: synced server=10.0.0.2 stratum=2 delay=3ms correction=+3600s epoch=1789003600\n"
	if got := h.outString(); got != want {
		t.Fatalf("output = %q, want %q", got, want)
	}
}

func TestTimeSyncDefaultsToTheAppleServer(t *testing.T) {
	asked := stubSync(t, timesync.Result{Status: timesync.StatusInSync, HadClock: true, Now: 1_789_000_000})
	h := newFakeHost()
	run, _ := session(h)
	if st := run("time sync"); st != 0 {
		t.Fatalf("in-sync status = %d, want 0 (output %q)", st, h.outString())
	}
	if len(*asked) != 1 || (*asked)[0] != timesync.DefaultServer {
		t.Fatalf("asked %v, want [%s]", *asked, timesync.DefaultServer)
	}
	if got := h.outString(); !strings.Contains(got, "time sync: in sync ") {
		t.Fatalf("output = %q, want the in-sync line", got)
	}
}

func TestTimeSyncFailuresExitOneAndSayClockUntouched(t *testing.T) {
	for name, st := range map[string]timesync.Status{
		"no reply":  timesync.StatusNoReply,
		"offline":   timesync.StatusOffline,
		"no route":  timesync.StatusNoRoute,
		"bad name":  timesync.StatusBadName,
		"bad reply": timesync.StatusBadReply,
		"exchange":  timesync.StatusExchangeFailed,
		"refused":   timesync.StatusKernelRefused,
	} {
		stubSync(t, timesync.Result{Status: st, BudgetNs: 5_000_000_000})
		h := newFakeHost()
		run, _ := session(h)
		if got := run("time sync 10.0.0.2"); got != 1 {
			t.Errorf("%s: status = %d, want 1", name, got)
		}
		if out := h.outString(); !strings.Contains(out, "clock untouched") {
			t.Errorf("%s: output %q does not say the clock was untouched", name, out)
		}
	}
}

func TestTimeUsageErrorsNeverTouchTheNetwork(t *testing.T) {
	prev := timeSync
	t.Cleanup(func() { timeSync = prev })
	timeSync = func(string) timesync.Result {
		t.Fatal("a mistyped `time` must not send a query")
		return timesync.Result{}
	}
	const usage = "gosh: time: usage: time CMD [ARGS...] | time sync [SERVER]\n"
	// The misuse forms still refuse with 2; M98h made every other word a
	// timed run — `time now` runs `now` (127, still no network).
	for _, line := range []string{"time", "time sync a b"} {
		h := newFakeHost()
		run, _ := session(h)
		if st := run(line); st != 2 {
			t.Errorf("%q: status = %d, want 2", line, st)
		}
		if got := h.outString(); got != usage {
			t.Errorf("%q: output = %q", line, got)
		}
	}
	h := newFakeHost()
	h.missing["now"] = true
	run, _ := session(h)
	if st := run("time now"); st != 127 {
		t.Errorf("time now: status = %d, want 127", st)
	}
	out := h.outString()
	if !strings.Contains(out, "now: not found") || !strings.Contains(out, "real ") {
		t.Errorf("time now: output = %q, want not-found plus a real line", out)
	}
}
