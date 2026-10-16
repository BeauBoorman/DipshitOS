// GOTABWM.ELF — M108b (#2325, ADR 0051 D3): the clipboard lane, seat half.
//
// Guest → host: once per tick the seat reads slot 39 — lawful because the
// caller IS the registered seat (M97g's clipboard_authorized) — and diffs
// (len, FNV-1a) against last tick. A change emits one signed CLIP_OUT. The
// seat observes the BUFFER, not the caller, so every write syncs — terminal
// chords, monitor `clip`, a capability holder's set, and the seat's own
// CLIP_IN applies are indistinguishable to it. That is the M97g story: the
// seat is the user-mediated observer, so what it sees is already consented.
//
// Host → guest: the engine's verified CLIP_IN is applied through slot 38 —
// automatic while the lane is armed (the consent was the operator's flag
// plus the provisioned credential; the seat's M97g-F4 obligation is
// VISIBILITY, not interposition — the chrome badge marks host-sourced
// content distinctly).
//
// Echo guards: applying a CLIP_IN sets the observed state directly, so the
// next diff cannot echo the host's own text back — the mirror of the
// runner's changeCount guard.
package main

import (
	"unicode/utf8"

	"virelai/hostint"
	"virelai/shlib"
	"virelai/theme"
	"virelai/vi"
	"virelai/vsys"
)

// clipKernelMax is the lane bound: the kernel clipboard's own capacity
// (kernel/src/clipboard.zig). The vsys staging wrappers cap at 256, so the
// lane uses the caller-buffered slots.
const clipKernelMax = 512

// The lane markers the class-B gate greps. Payload text and MACs never
// appear — seq, len and sha256[:8] are the whole story (never-logged).
const (
	MarkerHostintClipOut = "gotabwm: hostint clip-out "
	MarkerHostintClipIn  = "gotabwm: hostint clip-in "
	MarkerHostintClipInd = "gotabwm: hostint clip-ind "
)

// The clipboard observe state. hostClipSourceHost is the seat-painted
// badge's truth: true while the last buffer write was host-sourced.
var (
	hostClipBuf        []byte
	hostClipSeen       bool
	hostClipHash       uint64
	hostClipLen        int
	hostClipSourceHost bool
)

// The slot-38/39 seams, as vars so host tests inject a fake kernel buffer.
var (
	hostClipGet = vsys.ClipboardGetInto
	hostClipSet = vsys.ClipboardSetAll
)

// fnv1a is the diff hash the ADR names — (len, FNV-1a) against last tick.
func fnv1a(b []byte) uint64 {
	h := uint64(14695981039346656037)
	for _, c := range b {
		h ^= uint64(c)
		h *= 1099511628211
	}
	return h
}

// hostclipPoll is the guest→host direction, run once per tick after the
// engine's consume pass: diff the kernel buffer and emit one CLIP_OUT on
// change. The first observation after adoption reports the buffer as it
// stands — arming a lane syncs the current state, it does not pretend the
// buffer was empty.
func hostclipPoll() {
	eng := hostintEngine
	if eng == nil || !eng.Armed() || eng.LaneMask()&hostint.LaneClip == 0 {
		return
	}
	n, rc := hostClipGet(hostClipBuf)
	if rc < 0 {
		return // the seat is always authorized; a fault is transient
	}
	cur := hostClipBuf[:n]
	h := fnv1a(cur)
	if hostClipSeen && h == hostClipHash && n == hostClipLen {
		return
	}
	wasSeen := hostClipSeen
	hostClipSeen, hostClipHash, hostClipLen = true, h, n
	if !wasSeen && n == 0 {
		// An empty buffer at first observation is the baseline, not a
		// clear — arming must not push an empty pasteboard item.
		return
	}
	if !utf8.Valid(cur) {
		eng.RefuseLane(hostint.TagClipOut, hostint.RefuseNotText)
		return
	}
	seq, refusal := eng.Emit(hostint.TagClipOut, 0, cur)
	if refusal != "" {
		eng.RefuseLane(hostint.TagClipOut, refusal)
		return
	}
	markClipSource(false)
	sum := shlib.SHA256Sum(cur)
	hostintLog(MarkerHostintClipOut + "seq=" + vi.Itoa64(int64(seq)) +
		" len=" + vi.Itoa64(int64(n)) + " sha=" + hostint.HexDigest8(sum[:]))
}

// hostclipApply is the CLIP_IN tenant of hostintConsume — the engine's
// per-tag dispatch (hostint.go) routes here; other tags live in their own
// lane files.
func hostclipApply(rec hostint.Record) string {
	if !utf8.Valid(rec.Payload) {
		return hostint.RefuseNotText
	}
	n, rc := hostClipSet(rec.Payload)
	if rc < 0 {
		return hostint.RefuseIO
	}
	// Book the applied content as the observed state — the echo guard:
	// the next diff sees no change, so the host's own text cannot bounce
	// back as a fresh CLIP_OUT.
	hostClipSeen = true
	hostClipHash = fnv1a(rec.Payload[:n])
	hostClipLen = n
	markClipSource(true)
	sum := shlib.SHA256Sum(rec.Payload[:n])
	trunc := "0"
	if rec.Flags&hostint.FlagTruncated != 0 {
		trunc = "1"
	}
	hostintLog(MarkerHostintClipIn + "seq=" + vi.Itoa64(int64(rec.Seq)) +
		" len=" + vi.Itoa64(int64(n)) + " sha=" + hostint.HexDigest8(sum[:]) +
		" truncated=" + trunc)
	return ""
}

// markClipSource records the last buffer write's provenance and emits the
// one-shot indicator marker on a host transition — the serial proof that
// the chrome badge reflects it (the pixels are asserted by the paint test).
func markClipSource(host bool) {
	if hostClipSourceHost == host {
		return
	}
	hostClipSourceHost = host
	if host {
		hostintLog(MarkerHostintClipInd + "host")
	} else {
		hostintLog(MarkerHostintClipInd + "local")
	}
}

// hostClipBadge is the seat-painted clipboard indicator's content: while
// the lane is armed and the buffer holds something, a CLIP tag in the
// chrome panel — tinted to the Accent and suffixed :H while the last write
// was host-sourced, so a host paste landing guest-side is never invisible.
func hostClipBadge() (text string, rgb uint32, ok bool) {
	eng := hostintEngine
	if eng == nil || !eng.Armed() || eng.LaneMask()&hostint.LaneClip == 0 || !hostClipSeen || hostClipLen == 0 {
		return "", 0, false
	}
	tok := theme.Current
	if hostClipSourceHost {
		return "CLIP:H", tok.Accent, true
	}
	return "CLIP", tok.Muted, true
}
