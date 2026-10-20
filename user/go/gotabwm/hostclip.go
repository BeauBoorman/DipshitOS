// GOTABWM.ELF — M108b (#2325, ADR 0051 D3): the clipboard lane, seat half.
// M124c (#2582) widened it from flat text to the typed vocabulary: the
// kernel buffer still holds raw bytes, the TYPE is the vsys classification
// of them, and non-plain content crosses on the dedicated CLIP_OUT_T /
// CLIP_IN_T tags (`mime_len|mime|blob`) so text records stay byte-identical.
//
// Guest → host: once per tick the seat reads slot 39 — lawful because the
// caller IS the registered seat (M97g's clipboard_authorized) — and diffs
// (len, FNV-1a) against last tick. A change emits one signed CLIP_OUT (or
// CLIP_OUT_T when the bytes classify typed). The seat observes the BUFFER,
// not the caller, so every write syncs — terminal chords, monitor `clip`,
// a capability holder's set, and the seat's own CLIP_IN applies are
// indistinguishable to it. That is the M97g story: the seat is the
// user-mediated observer, so what it sees is already consented.
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
// M124c: the typed records carry a `mime=` field — the type is lane
// metadata (a negotiation input), never payload bytes.
const (
	MarkerHostintClipOut  = "gotabwm: hostint clip-out "
	MarkerHostintClipIn   = "gotabwm: hostint clip-in "
	MarkerHostintClipOutT = "gotabwm: hostint clip-out-t "
	MarkerHostintClipInT  = "gotabwm: hostint clip-in-t "
	MarkerHostintClipInd  = "gotabwm: hostint clip-ind "
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
// hostClipLaneHeld latches once an adopted mask carries the clip bit: a
// lane the runner REVOKED keeps polling so the emit's lane_disabled
// refusal names the posture once per change — the documented re-ARMED
// contract — while a lane never consented stays off the diff path,
// silent like the flags-off steady state.
var hostClipLaneHeld bool

func hostclipPoll() {
	eng := hostintEngine
	if eng == nil || !eng.Armed() {
		return
	}
	if eng.LaneMask()&hostint.LaneClip != 0 {
		hostClipLaneHeld = true
	} else if !hostClipLaneHeld {
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
	if !hostClipSeen && n == 0 {
		// An empty buffer at first observation is the baseline, not a
		// clear — arming must not push an empty pasteboard item.
		hostClipSeen, hostClipHash, hostClipLen = true, h, n
		return
	}
	mime := vsys.ClipboardClassify(cur)
	if mime == vsys.ClipOctet {
		// Bytes no type can name still refuse — the lane widened for the
		// named types, not for arbitrary binary. The refusal consumes the
		// change: commit the seen-state and name it once — retrying
		// would re-log the refusal every tick.
		hostClipSeen, hostClipHash, hostClipLen = true, h, n
		eng.RefuseLane(hostint.TagClipOut, hostint.RefuseNotText)
		return
	}
	var seq uint32
	var refusal string
	if mime == vsys.ClipText {
		seq, refusal = eng.Emit(hostint.TagClipOut, 0, cur)
	} else {
		// Typed content crosses on the dedicated tag — text records stay
		// raw, so an un-upgraded peer never misreads an envelope. The
		// envelope is inside the record's own 512: a buffer the mime
		// header pushes past it is too_large, not a truncated record.
		env := hostint.EncodeTypedClip(mime, cur)
		if env == nil {
			hostClipSeen, hostClipHash, hostClipLen = true, h, n
			eng.RefuseLane(hostint.TagClipOutT, hostint.RefuseTooLarge)
			return
		}
		seq, refusal = eng.Emit(hostint.TagClipOutT, 0, env)
	}
	switch refusal {
	case "":
		// The seen-state commits only on a published record: a refused
		// emit leaves the diff live so the change retries next tick.
		hostClipSeen, hostClipHash, hostClipLen = true, h, n
		markClipSource(false)
		sum := shlib.SHA256Sum(cur)
		if mime == vsys.ClipText {
			hostintLog(MarkerHostintClipOut + "seq=" + vi.Itoa64(int64(seq)) +
				" len=" + vi.Itoa64(int64(n)) + " sha=" + hostint.HexDigest8(sum[:]))
		} else {
			hostintLog(MarkerHostintClipOutT + "seq=" + vi.Itoa64(int64(seq)) +
				" mime=" + mime + " len=" + vi.Itoa64(int64(n)) +
				" sha=" + hostint.HexDigest8(sum[:]))
		}
	case hostint.RefuseBackpressure:
		// The runner holds MaxOutstanding of ours unconsumed — stay
		// silent and hold the seen-state: the diff fires again next tick
		// (the 250 ms drain paces us), and a marker here would repeat
		// every tick for the whole stall.
	default:
		// A hard refusal (lane_disabled on a re-ARMED mask change, an
		// io_error, too_large) consumes the change: commit the
		// seen-state so it is named once — retrying would loop the
		// marker on a posture that cannot carry it.
		hostClipSeen, hostClipHash, hostClipLen = true, h, n
		eng.RefuseLane(hostint.TagClipOut, refusal)
	}
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

// hostclipApplyT is the CLIP_IN_T tenant (M124c): a typed clipboard item —
// envelope `mime_len|mime|blob`. The declared mime is negotiated metadata:
// the seat applies the BLOB, but only when the bytes can honestly carry
// the label (the SetTyped shape rule — a host that mislabels its payload
// gets unsupported_kind, the same answer a guest writer would get).
func hostclipApplyT(rec hostint.Record) string {
	mime, blob, ok := hostint.DecodeTypedClip(rec.Payload)
	if !ok || !vsys.ClipSpellingOK(mime) {
		return hostint.RefuseBadRecord
	}
	if !vsys.ClipShapeOK(mime, blob) {
		return hostint.RefuseUnsupported
	}
	n, rc := hostClipSet(blob)
	if rc < 0 {
		return hostint.RefuseIO
	}
	hostClipSeen = true
	hostClipHash = fnv1a(blob[:n])
	hostClipLen = n
	markClipSource(true)
	sum := shlib.SHA256Sum(blob[:n])
	trunc := "0"
	if rec.Flags&hostint.FlagTruncated != 0 {
		trunc = "1"
	}
	hostintLog(MarkerHostintClipInT + "seq=" + vi.Itoa64(int64(rec.Seq)) +
		" mime=" + mime + " len=" + vi.Itoa64(int64(n)) +
		" sha=" + hostint.HexDigest8(sum[:]) + " truncated=" + trunc)
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

// clipBadgeKind is the badge's type suffix — the classification of the
// bytes the seat last observed, never of what a writer claimed. The card's
// badge vocabulary is IMG (image/*) and FILE (text/uri-list); text/html
// and plain text keep the untyped tag.
func clipBadgeKind(b []byte) string {
	switch vsys.ClipboardClassify(b) {
	case vsys.ClipURIList:
		return ":FILE"
	case vsys.ClipPNG, vsys.ClipQOI, vsys.ClipGIF, vsys.ClipJPEG, vsys.ClipBMP:
		return ":IMG"
	}
	return ""
}

// hostClipBadge is the seat-painted clipboard indicator's content: while
// the lane is armed and the buffer holds something, a CLIP tag in the
// chrome panel — carrying the type suffix (CLIP:IMG, CLIP:FILE) when the
// bytes classify, tinted to the Accent and suffixed :H while the last
// write was host-sourced, so a host paste landing guest-side is never
// invisible.
func hostClipBadge() (text string, rgb uint32, ok bool) {
	eng := hostintEngine
	if eng == nil || !eng.Armed() || eng.LaneMask()&hostint.LaneClip == 0 || !hostClipSeen || hostClipLen == 0 {
		return "", 0, false
	}
	tok := theme.Current
	kind := clipBadgeKind(hostClipBuf[:hostClipLen])
	if hostClipSourceHost {
		return "CLIP" + kind + ":H", tok.Accent, true
	}
	return "CLIP" + kind, tok.Muted, true
}
