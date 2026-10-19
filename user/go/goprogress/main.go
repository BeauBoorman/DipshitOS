// Command goprogress is the M123c (#2577) class-B driver: the smallest
// app that owns a window, binds it to the Go seat, and drives the
// progress wire — so the seat's notification-center row and its Cancel
// are exercised end to end over real WM_RPC frames, not stubs.
//
// It posts one op-1 report ("Copying", 40%), then polls for the seat's
// kind-23 cancel once a tick; each marker names the observed step, so a
// gate reads the chain: bound -> progress sent -> progress cancel.
//
// Build:  bash tools/go/build-web.sh goprogress GOPROGRESS
// Run:    exec GOPROGRESS.ELF
package main

import (
	"virelai/vi"
)

const selfName = "GOPROGRESS.ELF"

func fail(what string) {
	vi.ConsoleLine("goprogress: FAIL " + what)
	vi.Exit(1)
}

func main() {
	id, r := vi.WinOpen(96, 96, 320, 200)
	if r < 0 {
		fail("win open " + vi.Itoa64(r))
	}
	vi.ConsoleLine("goprogress: win id=" + vi.Itoa64(int64(id)))
	if !vi.WmMailRequest(vi.WmRpcKindDeclareFullscreen, uint32(id), 0, 0, 0, 0, "goprogress", selfName) {
		fail("declare refused")
	}
	vi.ConsoleLine("goprogress: bound id=" + vi.Itoa64(int64(id)))
	if !vi.NotifyProgress(uint32(id), 1, 40, "Copying", selfName) {
		fail("progress refused")
	}
	vi.ConsoleLine("goprogress: progress sent op=1")
	// The cancel is asynchronous (kind 23, reply_to=0): poll the mailbox
	// once a tick, bounded, so a seat that never sends one fails honestly
	// instead of hanging the script.
	for i := 0; i < 240; i++ {
		if op, ok := vi.PollProgressCancel(uint32(id)); ok {
			vi.ConsoleLine("goprogress: progress cancel op=" + vi.Itoa64(int64(op)))
			vi.WinClose(id)
			vi.Exit(0)
		}
		vi.Sleep(1)
	}
	fail("no cancel after 240 ticks")
}
