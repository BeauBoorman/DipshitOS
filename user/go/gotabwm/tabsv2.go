// Guest-safe `.tabs` v2 codec (M62e / ADR 0033 D3). Layout matches
// tools/go/tabcodec (header v2, active+1, count, seq, 69-byte records),
// but it must not import that package: tabcodec uses fmt.Errorf, fmt
// pulls os, and os is not a GOOS=virelai guest import.
//
// Byte identity vs tabcodec.Encode is claimed only for Prefs=0 and an
// in-range focus (host tests pin Seq=1, Prefs=0). This writer always
// emits buf[5]=0; an out-of-range focus becomes "no active" rather than
// an error (tabcodec.Encode refuses a bad Active).
//
// M125a (#2586): the app_state trailer. After the count fixed records a
// file may carry one version-tagged blob section:
//
//	u8 'A' u8 'S' | u8 ver(1) | u8 count | u16 reserved
//	per entry: u8 index | u8 appver | u16 reserved | u32 len LE | blob[len]
//
// Each entry's `index` names the record it belongs to — a blob is stored
// positionally against the same file's own rows, so nothing outside the
// file can misattach state to the wrong tab. `appver` is the app's OWN
// format tag: the seat stores and returns it verbatim; the app decides
// staleness (apps own the format, the seat owns the lifecycle). A blob
// over vi.AppStateMax, an index outside the record count, or a truncated
// entry is DROPPED BY NAME — the record keeps its row while its state is
// refused. The whole file stays under tabsV2MaxBytes, below both the
// share reader's 256 KiB ceiling and the snapshot bundle's entry cap, so
// a session with blobs still reads whole and still bundles.
package main

const (
	tabsV2Version     uint8 = 2
	tabsV2HeaderBytes       = 6
	tabsV2TitleMax          = 32
	tabsV2GroupMax          = 12
	tabsV2BinMax            = 24
	tabsV2RecordBytes       = tabsV2TitleMax + 1 + tabsV2GroupMax + tabsV2BinMax // 69

	// M125a (#2586): the app_state section's framing constants and the
	// per-app blob bound (the card's 64 KiB).
	stateMaxBytes               = 64 * 1024
	tabsV2AppStateHdr           = 6 // 'A','S', ver, count, rsvd16
	tabsV2AppStateEntry         = 8 // index, appver, rsvd16, len32
	tabsV2AppStateMagic0        = 'A'
	tabsV2AppStateMagic1        = 'S'
	tabsV2AppStateVersion uint8 = 1

	// tabsV2MaxBytes is the WHOLE file bound — header, records and the
	// app_state trailer. It sits under the share reader's 256 KiB ceiling
	// (vi.MaxFileBytes) and under the snapshot bundle's MaxBody entry cap
	// (128 KiB), so a session carrying blobs still loads whole on restore
	// and still fits the capture.
	tabsV2MaxBytes = 96 * 1024
)

func putFixed(dst []byte, s string) int {
	n := copy(dst, s)
	for i := n; i < len(dst); i++ {
		dst[i] = 0
	}
	return len(dst)
}

func readFixed(src []byte) string {
	n := 0
	for n < len(src) && src[n] != 0 {
		n++
	}
	return string(src[:n])
}

func u32le(src []byte) uint32 {
	return uint32(src[0]) | uint32(src[1])<<8 | uint32(src[2])<<16 | uint32(src[3])<<24
}

// encodeTabsV2 serializes the strip as `.tabs` v2 with Prefs=0, then the
// app_state trailer for every row carrying a blob. Entries are emitted in
// strip order while the file bound holds; a row whose blob no longer fits
// is named in `dropped` — the record still encodes, its state is refused.
// See the file comment for where this is not a full tabcodec.Encode
// equivalent.
func (s *TabStrip) encodeTabsV2(seq uint16) (raw []byte, dropped []string, ok bool) {
	n := s.count
	if n > MaxTabs {
		return nil, nil, false
	}
	recs := make([]tabsV2Record, n)
	for i := 0; i < n; i++ {
		recs[i] = recordOf(s.tabs[i])
	}
	active := -1
	if n > 0 && s.focus >= 0 && s.focus < n {
		active = s.focus
	}
	return encodeRecordsV2(seq, recs, active)
}

// recordOf is the tab -> record projection shared by the single-strip and
// the M137c multi-space encoders. Group stays empty here: the space name
// is the session layer's field, not the tab's.
func recordOf(t Tab) tabsV2Record {
	return tabsV2Record{
		Title: t.Title, Bin: t.Bin,
		Pinned: t.Pinned, Frozen: t.Frozen,
		State: t.State, StateVer: t.StateVer,
	}
}

// encodeRecordsV2 writes the frozen `.tabs` v2 layout for an arbitrary
// record list — M137c (#2773) feeds it the concatenation of every space's
// session rows, each record's 12-byte group field naming its space. The
// single-strip encoder above is the Group="" degenerate case; active is
// the record's index in the file (-1 = no active). The count field is a
// u8, so MaxSpaces*MaxTabs = 64 records still fit one header.
func encodeRecordsV2(seq uint16, recs []tabsV2Record, active int) (raw []byte, dropped []string, ok bool) {
	n := len(recs)
	if n > 255 {
		return nil, nil, false
	}
	buf := make([]byte, 0, tabsV2HeaderBytes+n*tabsV2RecordBytes)
	buf = append(buf, make([]byte, tabsV2HeaderBytes)...)
	buf[0] = tabsV2Version
	if active >= 0 && active < n {
		buf[1] = byte(active + 1)
	}
	buf[2] = byte(n)
	buf[3] = byte(seq & 0xff)
	buf[4] = byte((seq >> 8) & 0xff)
	for i := 0; i < n; i++ {
		rec := make([]byte, tabsV2RecordBytes)
		putFixed(rec[:tabsV2TitleMax], recs[i].Title)
		var flags uint8
		if recs[i].Pinned {
			flags |= FlagPinned
		}
		if recs[i].Frozen {
			flags |= FlagFrozen
		}
		rec[tabsV2TitleMax] = flags
		putFixed(rec[tabsV2TitleMax+1:tabsV2TitleMax+1+tabsV2GroupMax], recs[i].Group)
		putFixed(rec[tabsV2TitleMax+1+tabsV2GroupMax:], recs[i].Bin)
		buf = append(buf, rec...)
	}
	states := 0
	for i := 0; i < n; i++ {
		if len(recs[i].State) > 0 {
			states++
		}
	}
	if states > 0 {
		hdr := len(buf)
		buf = append(buf, tabsV2AppStateMagic0, tabsV2AppStateMagic1,
			tabsV2AppStateVersion, 0, 0, 0)
		emitted := 0
		for i := 0; i < n; i++ {
			st := recs[i].State
			if len(st) == 0 {
				continue
			}
			// The per-app bound is enforced at store time; the budget
			// check here is the FILE cap — the blob that overflows the
			// file is the one dropped, named by its row's title.
			if len(buf)+tabsV2AppStateEntry+len(st) > tabsV2MaxBytes {
				dropped = append(dropped, recs[i].Title)
				continue
			}
			ent := make([]byte, tabsV2AppStateEntry)
			ent[0] = byte(i)
			ent[1] = recs[i].StateVer
			putU32LE(ent[4:], uint32(len(st)))
			buf = append(buf, ent...)
			buf = append(buf, st...)
			emitted++
		}
		buf[hdr+3] = byte(emitted)
		if emitted == 0 {
			// Nothing fit: no trailer, only the named drops.
			buf = buf[:hdr]
		}
	}
	return buf, dropped, true
}

type tabsV2Record struct {
	Title  string
	Bin    string
	Pinned bool
	// M71e (#1564): the frozen badge round-trips too. The codec already
	// defines bit 0x02; GOTABWM dropped it on both encode and decode.
	Frozen bool
	// M137c (#2773): the space name — the 12-byte group field the frozen
	// layout always carried, now used for what it was reserved for. ""
	// means the default first space.
	Group string
	// M125a (#2586): the app_state blob paired with this record, nil
	// when the file carried none.
	State    []byte
	StateVer uint8
}

func decodeTabsV2(b []byte) (seq uint16, recs []tabsV2Record, active int, hasActive bool, drops []string, ok bool) {
	if len(b) < tabsV2HeaderBytes {
		return
	}
	if b[0] != tabsV2Version {
		return
	}
	count := int(b[2])
	if count > MaxTabs {
		return
	}
	if len(b) < tabsV2HeaderBytes+count*tabsV2RecordBytes {
		return
	}
	if b[1] != 0 {
		a := int(b[1]) - 1
		if a >= count {
			return
		}
		active = a
		hasActive = true
	}
	seq = uint16(b[3]) | uint16(b[4])<<8
	recs = make([]tabsV2Record, count)
	off := tabsV2HeaderBytes
	for i := 0; i < count; i++ {
		recs[i].Title = readFixed(b[off : off+tabsV2TitleMax])
		off += tabsV2TitleMax
		recs[i].Pinned = b[off]&FlagPinned != 0
		recs[i].Frozen = b[off]&FlagFrozen != 0
		off++
		// M137c (#2773): the 12-byte group field names the record's
		// space. Old files carry zeros here — readFixed returns "" and
		// the record lands on the default first space.
		recs[i].Group = readFixed(b[off : off+tabsV2GroupMax])
		off += tabsV2GroupMax
		recs[i].Bin = readFixed(b[off : off+tabsV2BinMax])
		off += tabsV2BinMax
	}
	drops = decodeAppStates(b[off:], recs)
	ok = true
	return
}

// decodeAppStates parses the trailing app_state section into the records
// it indexes. A file with no trailer is a file with no state; a trailer
// whose magic or version is foreign is ignored wholesale (the record
// region's "trailing bytes are ignored" rule extends to a section this
// codec does not own). Inside a well-formed section each bad entry is
// dropped BY NAME — the record's title when resolvable, the index when
// not — and the next entry still parses: a stale or oversized blob never
// costs its siblings.
func decodeAppStates(t []byte, recs []tabsV2Record) []string {
	var drops []string
	if len(t) < tabsV2AppStateHdr ||
		t[0] != tabsV2AppStateMagic0 || t[1] != tabsV2AppStateMagic1 {
		return nil
	}
	if t[2] != tabsV2AppStateVersion {
		return nil
	}
	off := tabsV2AppStateHdr
	for e := 0; e < int(t[3]); e++ {
		if len(t) < off+tabsV2AppStateEntry {
			drops = append(drops, "#"+dec(uint32(e))+" truncated")
			return drops
		}
		idx := int(t[off])
		ver := t[off+1]
		ln := int(u32le(t[off+4:]))
		off += tabsV2AppStateEntry
		name := "#" + dec(uint32(idx))
		if idx < len(recs) && recs[idx].Title != "" {
			name = recs[idx].Title
		}
		// A bad entry is named and skipped — the walk steps over its
		// declared body so the next entry still parses. Only a body the
		// buffer does not actually hold ends the walk.
		switch {
		case idx >= len(recs):
			drops = append(drops, name+" orphan")
		case ln > stateMaxBytes:
			drops = append(drops, name+" oversize")
		case len(t) < off+ln:
			drops = append(drops, name+" truncated")
			return drops
		default:
			recs[idx].State = append([]byte(nil), t[off:off+ln]...)
			recs[idx].StateVer = ver
		}
		if len(t) < off+ln {
			return drops // the skipped entry's body outruns the buffer
		}
		off += ln
	}
	return drops
}

// applyTabsV2 replaces the strip with decoded records. Order and pin bits
// are taken as written (no Pin() partition). Placeholder ids start at
// sessionIDBase so they cannot be 0 (OpenTab refuses 0). Each record's
// app_state blob rides its placeholder row — adoptReexec swaps only the
// window id, so the state lands on the live tab when the pid declares.
func (s *TabStrip) applyTabsV2(raw []byte) (uint16, bool) {
	seq, recs, active, hasActive, drops, ok := decodeTabsV2(raw)
	if !ok {
		return 0, false
	}
	*s = TabStrip{}
	for i := 0; i < len(recs); i++ {
		id := sessionIDBase + uint32(i)
		if !s.OpenTab(id, recs[i].Title) {
			*s = TabStrip{}
			return 0, false
		}
		// OpenTab fills Bin via guessBin(title). The record wins, including
		// empty: a generic `.tabs` file must round-trip, not grow a guessed bin.
		s.tabs[i].Bin = recs[i].Bin
		s.tabs[i].Pinned = recs[i].Pinned
		s.tabs[i].Frozen = recs[i].Frozen
		s.tabs[i].State = recs[i].State
		s.tabs[i].StateVer = recs[i].StateVer
	}
	for _, d := range drops {
		stateLog(MarkerStateDrop + d)
	}
	if hasActive && active >= 0 && active < s.count {
		s.focus = active
	}
	return seq, true
}
