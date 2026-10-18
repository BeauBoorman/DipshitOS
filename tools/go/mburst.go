// mburst.go -- M119c (#2487): seat-mailbox burst-absorption fixture for
// the live-bench `seat-mbox-burst` leg.
//
// What it measures: how many WM-RPC frames a stalled seat's mailbox ring
// holds before sends start refusing with ENOSPC — the ring bound IS the
// measurement. Before the M119c raise the ring was 8 deep, and a seat
// stalled behind an input burst under sustained PCM refused posts (the
// lost-notify signature; pending high-water measured 7/8 on a healthy
// live-sound-playback run). The burst is `total` back-to-back sends: a
// concurrently-draining seat clears at most one serviceRPC pass, so
// `accepted` lands on one side of the ring bound or the other — at most
// 8+8 before the fix, at least 32 after.
//
// Frame shape: 64 bytes with kind 0x60 — long enough to decode as a
// WM_RPC frame at the seat (>= 38 B), a kind the seat refuses cheaply
// after the ring accepts it. The post is what the ring holds; the seat's
// per-message verdict is deliberately not measured.
package main

import "virelai/vi"

const total = 40

func main() {
	seat := vi.WmctlSeatPid()
	if seat <= 0 {
		// Honest failure, not an empty measurement: a leg that finds no
		// registered seat is a different bug than a full ring.
		vi.ConsoleLine("mburst: FAIL no registered seat rc=" + vi.Itoa64(seat))
		return
	}
	self, _ := vi.SelfPid()
	var frame [vi.MailboxMessageMax]byte
	frame[0] = 0x60 // kind: decodes as a request; unknown to the seat's registry
	frame[3] = byte(self)
	copy(frame[14:38], "mburst seat probe")
	accepted, refused, other := 0, 0, 0
	for i := 0; i < total; i++ {
		frame[1] = byte(i) // id: distinct frames, same weight
		frame[2] = byte(i) // seq
		r := vi.IpcSend(uint32(seat), frame[:])
		switch {
		case r > 0:
			accepted++
		case r == -vi.ErrENOSPC:
			refused++
		default:
			other++
		}
	}
	vi.ConsoleLine("mburst: accepted=" + vi.Itoa64(int64(accepted)) +
		" of " + vi.Itoa64(total) +
		" refused=" + vi.Itoa64(int64(refused)) +
		" other=" + vi.Itoa64(int64(other)) +
		" seat=" + vi.Itoa64(seat))
	vi.ConsoleLine("mburst: done")
}
