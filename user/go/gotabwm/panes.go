// GOTABWM.ELF — M137a (#2771): the pane-tree sidecar.
//
// `.tabs` v2 is frozen — byte-identical to tools/go/tabcodec — so the
// split tree cannot ride the records. It lives in its own file beside
// the session: /host/SESSION.PANES, one compact binary blob, written
// through the same crash-safe publish and read through the same
// fail-closed decode the session file already uses. A missing sidecar
// is the unsplit shape; corrupt bytes are refused whole (panes bad),
// never a partial tree.
//
// Wire shape ("PN" + ver 1, then a preorder walk):
//
//	leaf tag 0x00 + u8 record index (position in the SESSION.TABS
//		record list — the strip position at save time, so an adoption
//		or a placeholder swap cannot strand the pane)
//	split tag 'v'|'h' + u32 little-endian sash (absolute scanout px;
//		0 = midpoint tiling)
//
// Leaf indexes name record positions, not window ids: `.tabs` v2 rows
// carry no window id, so position is the only stable key the pair of
// files share. The bounds the encode checks are the mutation's own —
// depth <= MaxTreeDepth, leaves <= MaxPanes — so a decodable blob can
// never describe a shape the live tree could not have taken.
package main

import "virelai/vi"

// panesPath is the sidecar the seat reads at restore and writes on
// every persisted mutation — beside sessionPath on purpose: the pair
// is one session's truth, captured together by the snapshot bundle.
const panesPath = "/host/SESSION.PANES"

// Marker lines the class-B gate greps.
const (
	MarkerPanesWrite = "gotabwm: panes write n="
	MarkerPanesLoad  = "gotabwm: panes load n="
	MarkerPanesBad   = "gotabwm: panes bad"
)

const (
	panesMagic0   byte = 'P'
	panesMagic1   byte = 'N'
	panesVer      byte = 1
	panesTagLeaf       = 0x00
	panesTagVert       = 'v'
	panesTagHoriz      = 'h'

	// panesVerSpaces (M137c #2773): the multi-space sidecar. A v2 blob
	// carries every space — name, own preorder tree, and which space is
	// live — because the .tabs group field names a record's space but
	// cannot carry an EMPTY space or the live-space choice when the file
	// records no active row:
	//
	//	'P' 'N' 0x02 | u8 nspaces | u8 current |
	//	per space: u8 nameLen | name[nameLen] | u16 blobLen | blob
	//
	// Each blob is a complete v1 body (magic+ver+walk) so decodePanes
	// reuses the frozen v1 walk verbatim; blobLen 0 = the space keeps no
	// tree. A v1 file is still read — its single tree applies to the
	// current space, which for an all-""-groups session is space "1".
	panesVerSpaces byte = 2
)

// panesMaxBytes bounds one v1 read: 3-byte header + 15 nodes * 5 bytes.
// panesMaxBytesV2 bounds the multi-space read: 5-byte header + per space
// (1 nameLen + 12 name + 2 len + one v1 blob).
const (
	panesMaxBytes   = 3 + treeMaxNodes*5
	panesMaxBytesV2 = 5 + MaxSpaces*(1+tabsV2GroupMax+2+panesMaxBytes)
)

// panesDelete is the file-delete seam for dropping a stale sidecar
// (unsplit). A var like writeHostFile so host tests observe it.
var panesDelete = vi.FileDelete

// liveIndex returns id's position inside the session-record ordering —
// the index the sidecar encodes. -1 when the tab would not be a record
// row (a placeholder, or absent).
func (s *TabStrip) liveIndex(id uint32) int {
	live := s.sessionRows()
	for i := 0; i < live.count; i++ {
		if live.tabs[i].ID == id {
			return i
		}
	}
	return -1
}

// encodePanes serializes the tree. False when no tree stands (nothing
// to write — the absent-file shape) or a leaf cannot resolve to a
// record position (a mid-restore placeholder; skipping the write keeps
// the last-good blob rather than publishing a lie).
func (s *TabStrip) encodePanes() ([]byte, bool) {
	if s.treeN == 0 {
		return nil, false
	}
	out := make([]byte, 0, panesMaxBytes)
	out = append(out, panesMagic0, panesMagic1, panesVer)
	var walk func(i int) bool
	walk = func(i int) bool {
		n := s.tree[i]
		if n.kind == SplitNone {
			idx := s.liveIndex(n.tab)
			if idx < 0 || idx > 255 {
				return false
			}
			out = append(out, panesTagLeaf, byte(idx))
			return true
		}
		tag := byte(panesTagVert)
		if n.kind == SplitHoriz {
			tag = panesTagHoriz
		}
		sash := n.sash
		out = append(out, tag,
			byte(sash), byte(sash>>8), byte(sash>>16), byte(sash>>24))
		return walk(int(n.a)) && walk(int(n.b))
	}
	if !walk(0) {
		return nil, false
	}
	return out, true
}

// decodePanes rebuilds the tree from blob b into s. Leaves resolve by
// record index against the CURRENT strip (post-applyTabsV2 the i-th
// row is tabs[i]). Fail-closed: on any malformed byte the strip's tree
// is left empty, never half-built.
func (s *TabStrip) decodePanes(b []byte) bool {
	s.treeN = 0
	if len(b) < 3 || b[0] != panesMagic0 || b[1] != panesMagic1 || b[2] != panesVer {
		return false
	}
	var nodes [treeMaxNodes]paneNode
	pos := 3
	leaves := 0
	// Depth counts the split level (root = 1) so the bound is
	// MaxTreeDepth, and the preorder parse uses an explicit cursor into
	// the local pool — indexes never reference s.tree until the whole
	// blob validated.
	used := 0
	alloc := func() int {
		if used >= treeMaxNodes {
			return -1
		}
		used++
		return used - 1
	}
	pos = 3
	leaves = 0
	var read func(depth int) (int, bool)
	read = func(depth int) (int, bool) {
		// Internal nodes live at depth <= MaxTreeDepth (the third
		// nested split); their leaves reach depth MaxTreeDepth+1.
		if depth > MaxTreeDepth+1 || pos >= len(b) {
			return -1, false
		}
		tag := b[pos]
		pos++
		ni := alloc()
		if ni < 0 {
			return -1, false
		}
		switch tag {
		case panesTagLeaf:
			if pos >= len(b) {
				return -1, false
			}
			idx := int(b[pos])
			pos++
			if idx >= s.count {
				return -1, false
			}
			leaves++
			if leaves > MaxPanes {
				return -1, false
			}
			nodes[ni] = paneNode{kind: SplitNone, a: -1, b: -1,
				tab: s.tabs[idx].ID}
			return ni, true
		case panesTagVert, panesTagHoriz:
			if pos+4 > len(b) {
				return -1, false
			}
			sash := int(uint32(b[pos]) | uint32(b[pos+1])<<8 |
				uint32(b[pos+2])<<16 | uint32(b[pos+3])<<24)
			pos += 4
			kind := SplitVert
			if tag == panesTagHoriz {
				kind = SplitHoriz
			}
			a, ok := read(depth + 1)
			if !ok {
				return -1, false
			}
			c, ok := read(depth + 1)
			if !ok {
				return -1, false
			}
			nodes[ni] = paneNode{kind: kind, a: int8(a), b: int8(c),
				sash: sash}
			return ni, true
		}
		return -1, false
	}
	root, ok := read(1)
	if !ok || root != 0 || pos != len(b) || leaves == 0 {
		return false
	}
	s.tree = nodes
	s.treeN = used
	// Refuse a shape that cannot tile — a sash stored past a clamp is
	// clamped at layout time anyway, but a tree that yields zero rects
	// is corrupt by definition.
	var probe [MaxPanes]paneRect
	if s.treeRects(FullRect(uint32(scanoutW), uint32(scanoutH)), &probe) != leaves {
		s.treeN = 0
		return false
	}
	return true
}

// encodePanesSpaces serializes the space table as the v2 sidecar. Every
// live space emits an entry — even one with no tree — so a restored boot
// learns the space NAMES the records alone could not carry (an empty
// space has no records) plus which space was live.
func encodePanesSpaces() []byte {
	out := make([]byte, 0, panesMaxBytesV2)
	out = append(out, panesMagic0, panesMagic1, panesVerSpaces,
		byte(spaceN), byte(spaceCur))
	for si := 0; si < spaceN; si++ {
		name := spaces[si].Name
		if len(name) > tabsV2GroupMax {
			name = name[:tabsV2GroupMax]
		}
		out = append(out, byte(len(name)))
		out = append(out, name...)
		// encodePanes fails closed to len 0 when the space has no tree —
		// an empty blob is "unsplit shape", not a partial tree.
		blob, _ := stripOf(si).encodePanes()
		out = append(out, byte(len(blob)), byte(len(blob)>>8))
		out = append(out, blob...)
	}
	return out
}

// decodePanesSpaces applies a v2 sidecar to the just-restored space
// table (applySpacesV2 already distributed records). Fail-closed: any
// malformed byte refuses the whole blob — partial trees never land.
// Entry order resolves through entryIndexes so `current` names a sidecar
// entry, not a raw array slot (the table's order can differ when the
// sidecar recorded an empty space the records never named).
func decodePanesSpaces(b []byte) bool {
	if len(b) < 5 || b[0] != panesMagic0 || b[1] != panesMagic1 ||
		b[2] != panesVerSpaces {
		return false
	}
	ns := int(b[3])
	cur := int(b[4])
	if ns < 1 || ns > MaxSpaces || cur >= ns {
		return false
	}
	pos := 5
	var entryIndexes [MaxSpaces]int
	leaves := 0
	for e := 0; e < ns; e++ {
		if pos+1 > len(b) {
			return false
		}
		nameLen := int(b[pos])
		pos++
		if nameLen > tabsV2GroupMax || pos+nameLen+2 > len(b) {
			return false
		}
		name := string(b[pos : pos+nameLen])
		pos += nameLen
		blen := int(b[pos]) | int(b[pos+1])<<8
		pos += 2
		if blen > panesMaxBytes || pos+blen > len(b) {
			return false
		}
		if name == "" {
			return false
		}
		si := spaceIndexByName(name)
		if si < 0 {
			if spaceN >= MaxSpaces {
				return false
			}
			si = spaceN
			spaces[si].Name = name
			spaceN++
		}
		entryIndexes[e] = si
		if blen > 0 {
			if !stripOf(si).decodePanes(b[pos : pos+blen]) {
				return false
			}
			leaves += stripOf(si).leafCount()
		}
		pos += blen
	}
	if pos != len(b) {
		return false
	}
	// Reconcile the live space through the entry map; park the decode's
	// default before the adopt.
	if si := entryIndexes[cur]; si != spaceCur {
		spaces[spaceCur].Strip = tabs
		spaceCur = si
		tabs = spaces[si].Strip
	}
	vi.ConsoleLine(MarkerPanesLoad + vi.Itoa64(int64(leaves)) +
		" spaces=" + vi.Itoa64(int64(spaceN)))
	return true
}

// writePanesFile publishes the sidecar — or deletes it when the tree
// is gone, so a restored session cannot pick up a stale split. Part of
// the session write path: writeSession calls it after the .tabs blob
// lands, so the pair publishes together. M137c: with more than one
// space the v2 frame always writes — the space names + live index are
// session truth even when no space carries a tree.
func writePanesFile() {
	if spaceN > 1 {
		if writeHostFile(panesPath, encodePanesSpaces()) {
			leaves := 0
			for si := 0; si < spaceN; si++ {
				leaves += stripOf(si).leafCount()
			}
			vi.ConsoleLine(MarkerPanesWrite + vi.Itoa64(int64(leaves)) +
				" spaces=" + vi.Itoa64(int64(spaceN)))
		}
		return
	}
	if tabs.treeN == 0 {
		if panesDelete(panesPath) == 0 {
			// A deleted sidecar is itself a state change worth one line —
			// silent deletion would leave the share unexplained.
			vi.ConsoleLine(MarkerPanesWrite + "0")
		}
		return
	}
	b, ok := tabs.encodePanes()
	if !ok {
		return
	}
	if writeHostFile(panesPath, b) {
		vi.ConsoleLine(MarkerPanesWrite + vi.Itoa64(int64(tabs.leafCount())))
	}
}

// loadPanesFile reads the sidecar onto the just-restored strip(s). Absent
// is the unsplit shape (silent); corrupt refuses whole with a marker.
// Called from loadSession AFTER applySpacesV2 so leaf indexes resolve
// against the restored rows. A v1 blob applies to the live strip as
// before; a v2 blob distributes per space and reconciles which is live.
func loadPanesFile() {
	b, r := readSessionFile(panesPath, panesMaxBytesV2+1)
	if r < 0 || b == nil {
		return
	}
	if len(b) < 3 || b[0] != panesMagic0 || b[1] != panesMagic1 {
		vi.ConsoleLine(MarkerPanesBad)
		return
	}
	if b[2] == panesVerSpaces {
		if len(b) > panesMaxBytesV2 || !decodePanesSpaces(b) {
			vi.ConsoleLine(MarkerPanesBad)
		}
		return
	}
	if len(b) > panesMaxBytes || b[2] != panesVer || !tabs.decodePanes(b) {
		vi.ConsoleLine(MarkerPanesBad)
		return
	}
	vi.ConsoleLine(MarkerPanesLoad + vi.Itoa64(int64(tabs.leafCount())))
}
