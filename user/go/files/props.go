// M155a (issue #2929): the `i` properties card — "what is this file and
// where does it live" in one key. The card is the QuickLook pane's sibling:
// a full-frame modal over the listing, Esc closes it, and every fact on it
// is either the row's own data, the M134a slot-79 stat wire (mtime and,
// since M160c #2994, ctime — meta_guest.go/meta_host.go own the platform
// half), a 512-byte mime.Sniff, the M160b op-15 facts wire (birth and
// allocated bytes) or slot-37 free space, or the kernel mount-table row
// the path's volume names (M134b). Facts the wires do not carry — a birth
// on /disk, free space on a usb row — keep a named "not available" row
// with its reason, never an invented value.
//
// The model stays pure: openProps decides and marks, render.go owns the
// frame, and every syscall is behind the same host-stubbed seams
// (readHead, statTimes, statFacts, volFree, mountRows) the rest of the
// app uses.
package main

import (
	"errors"

	"virelai/clockfmt"
	"virelai/mime"
	"virelai/rss/keys"
	"virelai/vi"
)

// propsHeadBytes is the card's sniff window — deeper than the mime
// table's own HeadBytes peek so the text heuristic reads a real prefix,
// still a bound so a large file costs nothing extra here.
const propsHeadBytes = 512

// statFacts is the M160b op-15 facts seam — vi.StatFacts on the guest,
// stubbed in host tests so each absent-flag arm is pinnable without a
// kernel.
var statFacts = vi.StatFacts

// volFree is the M160b slot-37 free-space seam — vi.VolumeFree on the
// guest (its svc1 rides vi's own syscallHook in host tests); a var so the
// refusal arms are pinnable too.
var volFree = vi.VolumeFree

// props is the open card's whole state. name/path/kind identify the row;
// size is the wire size; mimeID is the sniff word on files ("" on rows
// with no bytes to sniff); mtOK/mtSec and ctOK/ctSec carry the M134a
// stat's mtime and M160a ctime; birthOK/birthSec and allocOK/alloc carry
// the M160b facts wire's flagged facts (birthNo/allocNo name the reason
// when a flag is absent or the call refused); freeOK/free and freeNo are
// the slot-37 free-space answer or its refusal; the vol* fields are the
// mount-table row the path lives on (volOK=false when the path names no
// mounted row the table lists).
type props struct {
	name     string
	path     string
	kind     string // "file", "directory", "volume", "pin"
	size     uint64
	mimeID   string
	mtOK     bool
	mtSec    int64
	ctOK     bool
	ctSec    int64
	birthOK  bool
	birthSec int64
	birthNo  string
	allocOK  bool
	alloc    uint64
	allocNo  string
	freeOK   bool
	free     uint64
	freeNo   string
	vol      string
	volKind  string
	volSt    string
	volAcc   string // "rw"/"ro" when the row is mounted, "" otherwise
	volOK    bool
}

// openProps is the `i` chord: build the card for the cursor row and take
// the frame. No selection is a status line, like every other
// nothing-selected op.
func (m *model) openProps() {
	e, ok := m.selEntry()
	if !ok {
		m.status = "props: nothing selected"
		return
	}
	p := props{name: e.NameString(), size: uint64(e.Size)}
	switch {
	case m.path == volsPath:
		p.kind = "volume"
	case m.path == favsView:
		p.kind = "pin"
	case m.tar != nil:
		// M167c: the card answers off the member header — class, size,
		// the header's own mtime, a sniff of the streamed head. No stat
		// wire exists for a path inside an archive, so the facts rows
		// keep their named reason rather than stat the virtual path.
		p.kind = "file"
		p.birthNo = "not in the archive header"
		p.allocNo = "not in the archive header"
		if ent, ok := m.tarEntAt(m.sel); ok {
			p.size = ent.size
			if ent.mt > 0 {
				p.mtOK = true
				p.mtSec = ent.mt
			}
			switch e.Reserved[0] {
			case tarClsDir:
				p.kind = "directory"
			case tarClsLink:
				p.kind = "symlink"
			case tarClsRefused:
				p.kind = "refused"
			case tarClsOther:
				p.kind = "unsupported"
			default:
				head, rc := m.tar.readEnt(ent, propsHeadBytes)
				if rc < 0 {
					head = nil
				}
				p.mimeID = mime.Sniff(p.name, head).String()
			}
		}
	case e.Dir():
		p.kind = "directory"
	default:
		p.kind = "file"
	}
	var path string
	switch {
	case m.path == favsView:
		// M167b: the row's path IS the pin — the card answers for the
		// real directory the pin names (a gone one stats nothing).
		if m.sel < len(m.favs) {
			path = m.favs[m.sel]
		}
	case m.tar != nil:
		path = m.path + p.name
	default:
		var ok bool
		path, ok = joinPath(m.path, p.name)
		if !ok {
			m.status = "props: path too long"
			return
		}
	}
	p.path = path
	if p.kind == "volume" {
		// A mount-table row IS the volume fact: the reserved bytes carry
		// the live state/kind/ro flag (M134b) — no second call.
		mt := vi.MountFromEntry(e)
		p.vol, p.volKind, p.volSt = mt.Name, mt.KindName(), mt.StateName()
		if mt.Mounted() {
			p.volAcc = mt.AccessName()
		}
		p.volOK = true
	} else {
		if p.kind == "file" && m.tar == nil {
			data, rc := readHead(path, propsHeadBytes)
			var head []byte
			if rc >= 0 {
				head = data
			}
			p.mimeID = mime.Sniff(p.name, head).String()
		}
		// The path's volume is its first component; the mount-table row
		// it names carries kind/state/ro. A row that names no volume
		// (never the case for a path this app navigates to) stays volOK
		// false and the card says "—", honestly.
		if v := volumeOf(path); v != "" {
			if mounts, rc := mountRows(); rc >= 0 {
				for i := range mounts {
					if mounts[i].Name == v {
						mt := mounts[i]
						p.vol, p.volKind, p.volSt =
							mt.Name, mt.KindName(), mt.StateName()
						if mt.Mounted() {
							p.volAcc = mt.AccessName()
						}
						p.volOK = true
						break
					}
				}
			}
		}
	}
	// Free space is the slot-37 answer for the path's volume name —
	// /host's STATFS or /disk's bitmap — or a named refusal: a usb row
	// has no free-space source at all, an unmounted /disk answers
	// ENOENT, an old host EINVAL.
	if v := volumeOf(path); v != "" {
		if n, err := volFree(v); err == nil {
			p.freeOK = true
			p.free = n
		} else if errors.Is(err, vi.ErrNoVolumeRow) {
			p.freeNo = "no free-space row"
		} else {
			p.freeNo = "volume refused " + err.Error()
		}
	} else {
		p.freeNo = "path names no volume"
	}
	// mtime and ctime ride the SAME M134a slot-79 stat wire — one call,
	// each stamp flagged on its own. Absent reads "—" on the card and
	// mtime=none/ctime=- on the marker, never a fabricated stamp.
	mt, ct, mtOK, ctOK := statTimes(path)
	if mtOK {
		p.mtOK = true
		p.mtSec = mt / 1e9
	}
	if ctOK {
		p.ctOK = true
		p.ctSec = ct / 1e9
	}
	// M160b's op-15 record carries what the stat wire cannot: the birth
	// time and the allocated (on-disk) bytes, each presence-flagged. A
	// refusal — a path the ABI does not root, an unmounted /disk —
	// leaves both rows on the named errno; a tar member's reasons were
	// named with its class, no wire exists inside the archive.
	if m.tar == nil {
		if f, err := statFacts(path); err != nil {
			p.birthNo = "facts refused " + err.Error()
			p.allocNo = p.birthNo
		} else {
			if f.HasBirth {
				p.birthOK, p.birthSec = true, f.BirthSec
			} else {
				p.birthNo = "not on the facts wire"
			}
			if f.HasAlloc {
				p.allocOK, p.alloc = true, f.Alloc
			} else {
				p.allocNo = "not on the facts wire"
			}
		}
	}
	m.props = p
	m.mode = modeProps
	mtWord, ctWord, allocWord, freeWord := "none", "-", "-", "-"
	mimeWord, volWord := "none", "none"
	if p.mtOK {
		mtWord = vi.Itoa64(p.mtSec)
	}
	if p.ctOK {
		ctWord = vi.Itoa64(p.ctSec)
	}
	if p.allocOK {
		allocWord = vi.Itoa64(int64(p.alloc))
	}
	if p.freeOK {
		freeWord = vi.Itoa64(int64(p.free))
	}
	if p.mimeID != "" {
		mimeWord = p.mimeID
	}
	if p.volOK {
		volWord = p.vol
	}
	m.emit(markerProps + p.path + " mtime=" + mtWord +
		" ctime=" + ctWord + " alloc=" + allocWord + " free=" + freeWord +
		" mime=" + mimeWord + " vol=" + volWord)
	m.status = "props " + p.name
}

// closeProps dismisses the card — Esc (the card's own key), Backspace, a
// second `i`, or a pointer press — restoring the list frame underneath.
// The close marker rides pending like the open's.
func (m *model) closeProps() {
	if m.mode != modeProps {
		return
	}
	m.mode = modeNormal
	m.props = props{}
	m.emit(markerPropsClose)
	m.status = "listed"
}

// propsKey is the modeProps keyboard contract: the card is a read-only
// surface, so the only keys are the closes, `i` again, and Ctrl-C —
// every other key is swallowed while the card owns the frame.
func (m *model) propsKey(ev keys.Event) {
	switch ev.Key {
	case keys.KeyEsc, keys.KeyBackspace:
		m.closeProps()
	case keys.KeyCtrlC:
		m.quit = true
	case keys.KeyRune:
		if ev.Rune == 'i' {
			m.closeProps()
		}
	}
}

// propsRows is the card's body: name, full path, kind, size (bytes and
// human), the stat wire's mtime and ctime as UTC ISO-8601, the sniff
// word, the volume row, then the M160b facts — birth, allocated bytes,
// the volume's free space — each a real value or its named "not
// available" reason, never an invented one.
func (m model) propsRows() []string {
	p := m.props
	size, mod, mimeWord, vol := "—", "—", "—", "—"
	changed := "not available — not on the stat wire"
	created := "not available — " + p.birthNo
	disk := "not available — " + p.allocNo
	free := "not available — " + p.freeNo
	if p.kind == "file" {
		size = vi.Itoa64(int64(p.size)) + " bytes (" + humanSize(p.size) + ")"
	}
	if p.mtOK {
		mod = isoUTC(p.mtSec)
	}
	if p.ctOK {
		changed = isoUTC(p.ctSec)
	}
	if p.birthOK {
		created = isoUTC(p.birthSec)
	}
	if p.allocOK {
		disk = vi.Itoa64(int64(p.alloc)) + " bytes (" + humanSize(p.alloc) + ")"
	}
	if p.freeOK {
		free = vi.Itoa64(int64(p.free)) + " bytes (" + humanSize(p.free) + ")"
	}
	if p.mimeID != "" {
		mimeWord = p.mimeID
	}
	if p.volOK {
		vol = p.vol + " · " + p.volKind + " · " + p.volSt
		if p.volAcc != "" {
			vol += " · " + p.volAcc
		}
	}
	return []string{
		"  name      " + p.name,
		"  path      " + p.path,
		"  kind      " + p.kind,
		"  size      " + size,
		"  modified  " + mod,
		"  changed   " + changed,
		"  created   " + created,
		"  mime      " + mimeWord,
		"  volume    " + vol,
		"  on disk   " + disk,
		"  vol free  " + free,
	}
}

// isoUTC renders an epoch second as strict UTC ISO-8601 — the card's
// "when" column, the same civil breakdown clockfmt owns, without the
// zone label (Z says it).
func isoUTC(sec int64) string {
	c := clockfmt.At(sec, clockfmt.UTC)
	return padN(c.Year, 4) + "-" + padN(c.Month, 2) + "-" + padN(c.Day, 2) +
		"T" + padN(c.Hour, 2) + ":" + padN(c.Minute, 2) + ":" +
		padN(c.Second, 2) + "Z"
}

func padN(v, w int) string {
	s := vi.Itoa64(int64(v))
	for len(s) < w {
		s = "0" + s
	}
	return s
}

// humanSize is the card's second size word: bytes as a bounded
// binary-magnitude string (KiB/MiB/GiB/TiB), one truncated decimal under
// 10, whole otherwise — "512 B", "1.5 KiB", "12 MiB".
func humanSize(n uint64) string {
	if n < 1024 {
		return vi.Itoa64(int64(n)) + " B"
	}
	suffix := []string{"KiB", "MiB", "GiB", "TiB"}
	i := 0
	for i < len(suffix)-1 && n>>(10*(i+2)) >= 1 {
		i++
	}
	shift := uint(10 * (i + 1))
	whole := n >> shift
	if whole < 10 {
		tenths := (n * 10) >> shift
		return vi.Itoa64(int64(tenths/10)) + "." +
			vi.Itoa64(int64(tenths%10)) + " " + suffix[i]
	}
	return vi.Itoa64(int64(whole)) + " " + suffix[i]
}
