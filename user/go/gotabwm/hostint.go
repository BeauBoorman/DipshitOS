// GOTABWM.ELF — M108b (#2325, ADR 0051): the seat-side end of the host
// integration lanes. The wire is signed VHI1 records under the share's
// /host/HOSTINT/ directory (the existing --cvc-file channel — no kernel
// surface moves). The seat is the ONLY lawful guest endpoint: slots 38/39
// already admit the registered seat (M97g's clipboard_authorized), and
// poll-on-tick is the notification channel — no new event kind exists or
// is needed.
//
// This file is the engine wiring: credential probe, file-op seams, the
// per-tick drive. The lane policy itself lives in hostclip.go (M108b); the
// drop and notify-out lanes (M108c/d) attach to the same engine.
package main

import (
	"virelai/hostint"
	"virelai/shlib"
	"virelai/vi"
)

// hostintMarkerPrefix is the seat's lane log prefix. The engine's own
// markers (armed, refuse) are built from it; lane markers hang off it too.
const hostintMarkerPrefix = "gotabwm: hostint"

// hostintEngine is the seat's live lane engine, or nil when the host-int
// credential is absent: ADR 0051 D7's byte-silence rule is "no row → the
// seat never even polls the lane directory".
var hostintEngine *hostint.Engine

// The IO seams, as vars so host tests drive the whole lane in memory. The
// production values wire the engine to the real file channel and console.
var (
	hostintSecretGet = shlib.StoreGet
	// The lane dir rides the --cvc-file channel (queue 5), so the listing
	// is slot-27 sys_dir_list — vi.ListDirAt's slot-79 snapshot needs the
	// virtio_fs backend, which is ContainmentUnavailable on this share.
	// The 16-row window is within the lane's own bound (≤ MaxOutstanding
	// per tag + the handshake, and consumers delete on sight, so a fuller
	// directory still drains a page per tick). ENOENT — a missing dir or a
	// channel that is not there — is the flags-off steady state: silent.
	hostintListDir = func() ([]vi.DirItem, bool) {
		var rows [vi.MaxDirEntries]vi.DirEntry
		n, rc := vi.DirList(hostint.HostDir, rows[:])
		if rc < 0 {
			return nil, rc == -vi.ErrENOENT
		}
		items := make([]vi.DirItem, 0, n)
		for i := 0; i < n; i++ {
			items = append(items, vi.DirItem{
				Name:  rows[i].NameString(),
				IsDir: rows[i].Dir(),
				Size:  uint64(rows[i].Size),
			})
		}
		return items, false
	}
	hostintReadFile = func(name string) ([]byte, int64) {
		// RecordMax+1 so an oversize lane file is visibly oversize to
		// Decode (a clean bad_record) rather than indistinguishably
		// truncated at the cap.
		return vi.ReadFileAll(hostint.HostDir+"/"+name, hostint.RecordMax+1)
	}
	hostintWriteFile = func(name string, b []byte) int64 {
		return vi.WriteFileSafe(hostint.HostDir+"/"+name, b)
	}
	hostintDeleteFile = func(name string) int64 {
		return vi.FileDelete(hostint.HostDir + "/" + name)
	}
	hostintLog = vi.ConsoleLine
)

// hostintSeatInit probes the host-int SECRETS.TXT row once, at seat
// startup. Absent or unreadable is silent — the engine simply never
// exists, which is the whole flags-off posture. The row is served only to
// this image (the ADR 0024 D8 app binding: uid_user + GOTABWM.ELF named
// against a uid_system-owned OWNERS.TXT row), so holding it is already the
// operator's statement that THIS seat may run lanes.
func hostintSeatInit() {
	var key [vi.SecretValMax]byte
	n := hostintSecretGet(hostint.SecretName, key[:])
	if n <= 0 {
		return
	}
	hostintEngine = hostint.NewEngine(key[:n], hostint.EngineIO{
		List:   hostintListDir,
		Read:   hostintReadFile,
		Write:  hostintWriteFile,
		Delete: hostintDeleteFile,
		// Indirection, not the value: armRefusalLaneWatch re-binds
		// hostintLog AFTER this init, and a captured function value would
		// bypass the watch — the engine's own `refuse lane=` lines would
		// print but never dispatch the seat's refusal toast (observed
		// go-wm-seat run 18: refuse logged, EACCES never raised).
		Log: func(s string) { hostintLog(s) },
	}, hostintMarkerPrefix)
	hostintEngine.Consume = hostintConsume
	hostClipBuf = make([]byte, clipKernelMax)
}

// The v2 hook vars (ADR 0051 V2-D7 — the shared seam): the dependent
// cards bind them from their own files, and the nil default is exactly
// the v1 behavior — an unbound NOTIFY_FOCUS consume refuses lane_disabled
// and the outbox drive is a no-op.
var (
	// hostfocusConsume is M127c's NOTIFY_FOCUS route (hostfocus.go binds
	// it): a verified click-through record asking the seat to focus a tab.
	hostfocusConsume func(rec hostint.Record) string
	// outboxTickFn is M127d's per-tick OUTBOX drive (hostoutbox.go binds
	// it): the REQ-marker scan that turns app intents into signed emits.
	outboxTickFn func()
)

// hostintConsume routes seat-inbound records to their lane — M108b owns
// CLIP_IN (hostclip.go), M108c owns DROP (hostdrop.go), M127c owns
// NOTIFY_FOCUS (hostfocus.go, bound through hostfocusConsume). A tag with
// no tenant is refused lane_disabled.
func hostintConsume(tag uint8, rec hostint.Record) string {
	switch tag {
	case hostint.TagClipIn:
		return hostclipApply(rec)
	case hostint.TagClipInT:
		return hostclipApplyT(rec)
	case hostint.TagDrop:
		return hostdropApply(rec)
	case hostint.TagNotifyFocus:
		if hostfocusConsume != nil {
			return hostfocusConsume(rec)
		}
	}
	return hostint.RefuseLaneDisabled
}

// hostintSeatTick is the per-composite-tick drive: consume what the lane
// directory holds (adoption first), then produce what changed (the
// clipboard lane's CLIP_OUT, M108b), what the strip staged (the notify-out
// lane's NOTIFY_OUT, M108d) and what the OUTBOX markers request (M127d).
// ~1 Hz, bounded file ops.
func hostintSeatTick() {
	if hostintEngine == nil {
		return
	}
	hostintEngine.Poll()
	hostclipPoll()
	hostnotifyPoll()
	if outboxTickFn != nil {
		outboxTickFn()
	}
}
