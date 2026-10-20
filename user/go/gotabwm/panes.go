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
)

// panesMaxBytes bounds one read: 3-byte header + 15 nodes * 5 bytes.
const panesMaxBytes = 3 + treeMaxNodes*5

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

// writePanesFile publishes the sidecar — or deletes it when the tree
// is gone, so a restored session cannot pick up a stale split. Part of
// the session write path: writeSession calls it after the .tabs blob
// lands, so the pair publishes together.
func writePanesFile() {
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

// loadPanesFile reads the sidecar onto the just-restored strip. Absent
// is the unsplit shape (silent); corrupt refuses whole with a marker.
// Called from loadSession AFTER applyTabsV2 so leaf indexes resolve
// against the restored rows.
func loadPanesFile() {
	b, r := readSessionFile(panesPath, panesMaxBytes+1)
	if r < 0 || b == nil {
		return
	}
	if len(b) > panesMaxBytes || !tabs.decodePanes(b) {
		vi.ConsoleLine(MarkerPanesBad)
		return
	}
	vi.ConsoleLine(MarkerPanesLoad + vi.Itoa64(int64(tabs.leafCount())))
}
