// state.go — GOPAINT's half of the M125a per-app state protocol (the same
// shape GOEDIT's state.go keeps): the seat stores the blob verbatim and a
// reopen hands it back through tabapp's RestoreState. The card's payload is
// "the current file and tool" — plus the color/size selection, which is the
// same class of session chrome. Pixels are NOT in the blob: the document's
// identity is its file, and a dirty canvas restores the FILE's pixels (the
// undo ring does not cross the session boundary here — M141a scopes the
// blob to file+tool).
//
// The blob is versioned and bounded; a torn or foreign blob decodes to nil
// and the restore degrades to the argv path, never a crash.
package main

const (
	stateFmtVer = 1
	stateAppVer = 1

	flagDirty = 1 << 0
)

// paintState is the decoded blob.
type paintState struct {
	path  string
	tool  toolID
	size  int // index into brushSizes
	color int // palette index
	dirty bool
}

// encode renders the blob: [ver][flags][tool][size][color][pathlen][path].
func (s paintState) encode() []byte {
	if len(s.path) > 255 {
		s.path = s.path[:255]
	}
	out := make([]byte, 0, 6+len(s.path))
	flags := byte(0)
	if s.dirty {
		flags |= flagDirty
	}
	out = append(out, stateFmtVer, flags, byte(s.tool), byte(s.size), byte(s.color), byte(len(s.path)))
	return append(out, s.path...)
}

// decodeState parses a blob; ok=false means stale/foreign and the caller
// degrades to a plain open. Every length field is re-verified — the seat
// carries bytes, it does not vouch for them.
func decodeState(b []byte) (paintState, bool) {
	var s paintState
	if len(b) < 6 || b[0] != stateFmtVer {
		return s, false
	}
	s.dirty = b[1]&flagDirty != 0
	if b[1]&^flagDirty != 0 {
		return s, false
	}
	if b[2] >= byte(toolCount) || b[3] >= byte(len(brushSizes)) || b[4] >= byte(len(palette)) {
		return s, false
	}
	s.tool, s.size, s.color = toolID(b[2]), int(b[3]), int(b[4])
	if len(b) != 6+int(b[5]) {
		return s, false
	}
	s.path = string(b[6:])
	return s, true
}
