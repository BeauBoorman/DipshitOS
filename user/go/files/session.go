// M125c (issue #2588): GOFILES session state on the M125a (#2586)
// save/restore protocol — cwd, cursor, scroll, view mode and sort,
// serialized as one bounded versioned blob.
//
// The seat owns the lifecycle (it asks on snapshot and tab close, stores
// the blob on the tab's `.tabs` record, hands it back on re-exec); the app
// owns the format. The blob is what a user would notice losing:
//
//	u8  fmtver          — the blob's own version byte; also the Config's
//	                      StateVersion, so the envelope's appver and the
//	                      payload agree (a stale serialization is refused
//	                      twice over, never silently misread)
//	u16 pathLen LE | u8 path[pathLen]  — cwd, <= maxPath (the kernel's
//	                      64-byte path cap keeps the whole blob ~73 B)
//	u16 sel LE          — cursor (listing index)
//	u16 top LE          — scroll (first visible row; a tile-row index in
//	                      the M167a grid, still first-entry units)
//	u8  view            — viewMode (M167a added the grid value; the byte
//	                      layout is unchanged)
//	u8  sort            — sortMode
//
// Multi-byte fields are little-endian, matching the seat's envelope
// (`u8 appver | u32 len LE | blob`) and the .tabs trailer's own u32 LE.
//
// Decode is total: a short blob, a wrong version, a length that does not
// match the file's size, or a path that is not absolute is refused as a
// whole — a torn handoff can never land half-applied. Scalar fields clamp
// rather than fail (a bigger sel than today's listing just means the
// directory shrank). A saved cwd that no longer exists walks up to the
// nearest existing parent — the volumes root is the floor, because it is
// the mount table and always lists.
package main

import "virelai/vi"

// stateFmtVer is the blob's format version — both the Config.StateVersion
// the envelope carries and the payload's first byte.
const stateFmtVer = 1

// stateTail is the fixed field run after the path: sel u16 + top u16 +
// view u8 + sort u8.
const stateTail = 6

// filesState is one decoded session blob.
type filesState struct {
	path string
	sel  int
	top  int
	view viewMode
	sort sortMode
}

// stateDirProbe is the restore path's existence check — vi.DirList on the
// guest, a stub in host tests (the same seam shape as mountRows).
var stateDirProbe = func(path string) int64 {
	var scratch [1]vi.DirEntry
	_, rc := vi.DirList(path, scratch[:])
	return rc
}

// encodeState serializes the session fields. Bounded by construction:
// path <= maxPath and every other field is fixed-width, so the blob can
// never exceed ~73 bytes — far under the seat's 64 KiB cap.
func (m model) encodeState() []byte {
	out := make([]byte, 0, 3+len(m.path)+stateTail)
	out = append(out, stateFmtVer, byte(len(m.path)), byte(len(m.path)>>8))
	out = append(out, m.path...)
	out = append(out,
		byte(m.sel), byte(m.sel>>8),
		byte(m.top), byte(m.top>>8),
		byte(m.view), byte(m.sort))
	return out
}

// decodeState is encodeState's total inverse. ok=false means the blob is
// refused wholesale — a wrong version, a torn length, or a non-absolute
// path. Field VALUES never refuse: unknown view/sort bytes clamp to the
// defaults and sel/top clamp into the listing window, so a stale-but-
// well-formed blob degrades to a sane session rather than a crash.
func decodeState(b []byte) (filesState, bool) {
	var st filesState
	if len(b) < 3+stateTail || b[0] != stateFmtVer {
		return st, false
	}
	plen := int(b[1]) | int(b[2])<<8
	if plen < 1 || plen > maxPath || len(b) != 3+plen+stateTail {
		return st, false
	}
	if b[3] != '/' {
		return st, false
	}
	st.path = string(b[3 : 3+plen])
	o := 3 + plen
	st.sel = int(b[o]) | int(b[o+1])<<8
	st.top = int(b[o+2]) | int(b[o+3])<<8
	st.view = viewMode(b[o+4])
	st.sort = sortMode(b[o+5])
	// The listing window is the bound: a cursor/scroll outside it is
	// stale, not corrupt — clamp to the nearest in-range row.
	if st.sel >= vi.MaxDirEntries {
		st.sel = vi.MaxDirEntries - 1
	}
	if st.top >= vi.MaxDirEntries {
		st.top = vi.MaxDirEntries - 1
	}
	if st.view > viewGrid {
		st.view = viewSplit
	}
	if st.sort >= sortModeCount {
		st.sort = sortDirs
	}
	return st, true
}

// resolveStatePath walks a saved cwd up to the nearest directory that
// actually lists — the card's "missing cwd falls back" rule. Mount roots
// stop at the volumes list (above a mount root is "/", never another
// volume), which is also the floor when nothing lists at all.
// fell reports that resolved != saved.
func resolveStatePath(saved string) (resolved string, fell bool) {
	p := saved
	for p != volsPath {
		if stateDirProbe(p) >= 0 {
			return p, p != saved
		}
		if isMountRoot(p) {
			break
		}
		next := parentPath(p)
		if next == p {
			break
		}
		p = next
	}
	return volsPath, saved != volsPath
}

// applyState lands a decoded blob on a freshly listed model: view and
// sort first (the listing re-sorts under them so a saved cursor indexes
// the same order the user saved), then cursor/scroll clamped to what the
// directory actually holds now — a listing that shrank since the save
// clamps to its last row, never indexes past its end.
func (m *model) applyState(st filesState) {
	m.view = st.view
	m.sort = st.sort
	if m.path != volsPath && m.n > 0 {
		sortEntries(m.entries[:], m.n, m.sort)
	}
	m.sel = st.sel
	if m.sel >= m.n {
		m.sel = m.n - 1
	}
	if m.sel < 0 {
		m.sel = 0
	}
	m.top = st.top
	m.ensureSelVisible()
	if m.view == viewGrid {
		// M167a: a restored grid session reopens in the grid — the tile
		// queue is rebuilt against the fresh listing (the cache, keyed by
		// path+size+mtime, serves what still matches).
		m.viewUnder = viewSplit
		m.gridSync()
	}
	m.loadPreview()
}
