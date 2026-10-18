// GOTABWM.ELF — M127d (#2602, ADR 0051 V2-D5): the OUTBOX export lane,
// seat half.
//
// The reverse drop. INBOX is host payload + signed notice; OUTBOX is
// guest payload + signed notice — but a guest app cannot sign (the
// host-int row is bound to this image), so intent and provenance split:
// the app (GOSH `export`, GOFILES "Export to Host") writes
// /host/OUTBOX/<name> and a REQ-<8hex> marker carrying the basename
// verbatim, and this file is the signer. Once per lane tick, while the
// adopted mask carries lane_outbox, the scan takes ONE well-formed REQ
// whose payload exists, emits the signed OUTBOX record (the DROP payload
// shape reversed) and deletes the marker. Refusals are named and the
// marker is still deleted — the payload is left in place: gone (payload
// absent), name_rejected (REQ content breaks the D4 name rule),
// unsupported_kind (a directory), payload_too_large (> 64 MiB).
//
// The REQ is unsigned by design — it is intent, not provenance. What the
// host trusts is the signed record; what the seat signs is only a
// REQ-marked payload, so an unmarked file sitting in OUTBOX/ is the
// mirror of an unannounced INBOX plant: inert, never attributed, never
// exported.
package main

import (
	"virelai/hostint"
	"virelai/outbox"
	"virelai/vi"
)

// MarkerHostintOutbox is the seat's outbox emit receipt — the shape the
// runner's `host-outbox: file` marker answers on the far side.
const MarkerHostintOutbox = "gotabwm: hostint outbox "

// The IO seams, as vars so host tests drive the whole lane in memory —
// the hostint fixture discipline. OUTBOX/ rides the same --cvc-file
// channel as the lane dir, but the 16-row sys_dir_list window would
// hide every REQ behind 16 payloads — vi.ListDirAt pages the v2
// open/page/close protocol (the kernel serves it on the legacy channel)
// up to the snapshot bound. ENOENT — a missing dir — is the flags-off
// steady state: silent. Any other failure (incl. ErrTreeLimit past the
// 256-row bound) reports absent=false and the tick names io_error once.
var (
	hostoutboxListDir = func() ([]vi.DirItem, bool) {
		items, err := vi.ListDirAt("/OUTBOX")
		if err != nil {
			// The errno error's name, the way agentwatch branches on it.
			return nil, err.Error() == "ENOENT"
		}
		return items, false
	}
	// hostoutboxListFailed latches the listing-failure refusal so a
	// persistently-broken share dir names io_error once, not once a tick.
	hostoutboxListFailed = false
	// REQ bodies are the basename verbatim — a file over the name bound
	// reads as oversize so the name check can still name the refusal.
	hostoutboxReadFile = func(name string) ([]byte, int64) {
		return vi.ReadFileAll(outbox.Dir+"/"+name, outbox.NameMax+1)
	}
	hostoutboxDeleteFile = func(name string) int64 {
		return vi.FileDelete(outbox.Dir + "/" + name)
	}
)

func init() { outboxTickFn = hostoutboxTick }

// hostoutboxTick is the outbox lane's per-tick drive, bound through the
// seam's outboxTickFn hook. It polls only while the adopted mask carries
// lane_outbox — the D7 posture: flags-off (or revoked) is byte-silent.
// At most one REQ outcome per tick — the emit-side bound every g→h lane
// already holds.
func hostoutboxTick() {
	eng := hostintEngine
	if eng == nil || !eng.Armed() || eng.LaneMask()&hostint.LaneOutbox == 0 {
		return
	}
	items, absent := hostoutboxListDir()
	if items == nil {
		if absent {
			return // OUTBOX never existed — silent, like the lane dir
		}
		if !hostoutboxListFailed {
			hostoutboxListFailed = true
			eng.RefuseLane(hostint.TagOutbox, hostint.RefuseIO)
		}
		return
	}
	hostoutboxListFailed = false
	// Name-ordered scan, mirroring the engine's own ordering. Payloads
	// are looked up in the same listing the REQs came from; directories
	// join the map too so a dir payload is unsupported_kind, not gone.
	names := make([]string, 0, len(items))
	byName := make(map[string]vi.DirItem, len(items))
	for _, it := range items {
		byName[it.Name] = it
		if !it.IsDir && outbox.IsReqName(it.Name) {
			names = append(names, it.Name)
		}
	}
	for i := 1; i < len(names); i++ {
		for j := i; j > 0 && names[j] < names[j-1]; j-- {
			names[j], names[j-1] = names[j-1], names[j]
		}
	}
	for _, req := range names {
		hostoutboxOne(eng, req, byName)
		return // ≤ 1 REQ consumed per tick
	}
}

// hostoutboxOne resolves one REQ marker: read the payload name it carries,
// check the payload's presence/kind/size against the same listing, and
// emit the signed record — or name the refusal and delete the marker.
func hostoutboxOne(eng *hostint.Engine, req string, byName map[string]vi.DirItem) {
	refuse := func(reason string) {
		eng.RefuseLane(hostint.TagOutbox, reason)
		_ = hostoutboxDeleteFile(req)
	}
	raw, rc := hostoutboxReadFile(req)
	if rc < 0 {
		// A transient read error leaves the marker for the next tick —
		// the engine's unreadable-file posture, named once.
		eng.RefuseLane(hostint.TagOutbox, hostint.RefuseIO)
		return
	}
	if len(raw) > outbox.NameMax || !outbox.NameValid(string(raw)) {
		refuse(hostint.RefuseNameRejected)
		return
	}
	name := string(raw)
	it, ok := byName[name]
	if !ok {
		refuse(hostint.RefuseGone)
		return
	}
	// The listing's kind view: a directory payload is unsupported_kind.
	// The size view is the seat's attest-time view — the host's live
	// fstat rules the move.
	if it.IsDir {
		refuse(hostint.RefuseUnsupported)
		return
	}
	if it.Size > outbox.FileMax {
		refuse(hostint.RefuseTooLarge)
		return
	}
	// The signed notice: the DROP shape, reversed — [name_len u8][name]
	// [size u64le].
	p := make([]byte, 0, 1+len(name)+8)
	p = append(p, byte(len(name)))
	p = append(p, name...)
	for i := 0; i < 8; i++ {
		p = append(p, byte(it.Size>>(8*i)))
	}
	seq, refusal := eng.Emit(hostint.TagOutbox, 0, p)
	switch refusal {
	case "":
		_ = hostoutboxDeleteFile(req)
		hostintLog(MarkerHostintOutbox + "seq=" + vi.Itoa64(int64(seq)) +
			" name=" + name + " size=" + vi.Itoa64(int64(it.Size)))
	case hostint.RefuseBackpressure:
		// The runner holds MaxOutstanding of ours — the REQ waits, a
		// retry next tick rather than a dropped intent.
	default:
		refuse(refusal)
	}
}
