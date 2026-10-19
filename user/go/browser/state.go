// state.go — M125d (#2589): WEB's half of the M125a per-app state
// protocol. The seat carries the blob verbatim (kind-20/21 over the
// staged /host/APPSTATE.<id> file; vi.EncodeAppState, AppStateMax =
// 64 KiB); WEB owns the format. A re-exec'd WEB.ELF gets no argv — the
// blob is the only place the tab's URL survives a session restore, and
// the scroll offset, the zoom rung and the live form control values ride
// with it.
//
// Wire v1 (little-endian):
//
//	u8  fmtVer (=1)        WEB's own staleness tag — the seat never
//	u8  flags (reserved 0) interprets it; the envelope's appver
//	u16 zoomPct            (stateAppVer) is the seat-stored twin
//	u32 scroll             the content offset, clamped on apply
//	u16 urlLen | url       the tab's target ("" = the start surface)
//	u8  nFields | fields   controls with user-visible state:
//	                       u8 kind | u16 nameLen | name |
//	                       u16 valueLen | value | u8 checked
//
// Decode is total: every declared length is checked against what remains,
// the blob must be consumed exactly, and any overrun, unknown kind or
// foreign fmtVer refuses the WHOLE blob (`web: state refused`) — never
// half-applied, never a panic. Apply skips a serialized field whose
// kind+name no live control claims: a page that changed under the blob
// restores its other fields rather than mis-assigning a value.
package main

import "virelai/vi"

const (
	// stateFmtVer is this serialization's own version — byte 0 of the
	// blob. stateAppVer is the envelope appver the seat stores and
	// returns verbatim; noteState refuses a foreign one by name even
	// when the blob itself decodes (the seat carries both and owns no
	// opinion about either).
	stateFmtVer = 1
	stateAppVer = 1

	// stateCapBytes is the envelope bound — saveState never answers
	// over it; a session that cannot fit drops trailing fields before
	// it drops the page.
	stateCapBytes = vi.AppStateMax

	// stateFieldMax mirrors initForms' control bound (form-control-limit):
	// this build cannot produce more, so a blob declaring more is foreign.
	stateFieldMax = 64

	// Field kind codes — the subset of controls whose state is
	// user-visible. submit/button carry no user state and are never
	// serialized; a code the codec does not know fails the decode whole.
	fieldText     = 1
	fieldSearch   = 2
	fieldHidden   = 3
	fieldCheckbox = 4
	fieldSelect   = 5
)

// webState is the decoded blob. fields are page-order stateField records.
type webState struct {
	zoom   int
	scroll int
	url    string
	fields []stateField
}

// stateField is one control's live state: kind+name are the apply-time
// match key, value/checked the state it carries (select stores its
// selected option's value; apply re-resolves the index).
type stateField struct {
	kind    int
	name    string
	value   string
	checked bool
}

// stateKindCode maps a control's kind onto its wire code; ok=false marks
// a kind that carries no user state (submit, button, the unsupported
// kinds) — it never enters the blob.
func stateKindCode(kind string) (int, bool) {
	switch kind {
	case "text":
		return fieldText, true
	case "search":
		return fieldSearch, true
	case "hidden":
		return fieldHidden, true
	case "checkbox":
		return fieldCheckbox, true
	case "select":
		return fieldSelect, true
	}
	return 0, false
}

func appendU16(b []byte, v int) []byte {
	return append(b, byte(v), byte(v>>8))
}

func appendU32(b []byte, v uint32) []byte {
	return append(b, byte(v), byte(v>>8), byte(v>>16), byte(v>>24))
}

// encode renders the blob. Writers are infallible; the cap check runs on
// the finished length in saveState.
func (st *webState) encode() []byte {
	out := make([]byte, 0, 12+len(st.url))
	out = append(out, stateFmtVer, 0)
	out = appendU16(out, st.zoom)
	out = appendU32(out, uint32(max(0, st.scroll)))
	out = appendU16(out, len(st.url))
	out = append(out, st.url...)
	out = append(out, byte(len(st.fields)))
	for _, f := range st.fields {
		out = append(out, byte(f.kind))
		out = appendU16(out, len(f.name))
		out = append(out, f.name...)
		out = appendU16(out, len(f.value))
		out = append(out, f.value...)
		var c byte
		if f.checked {
			c = 1
		}
		out = append(out, c)
	}
	return out
}

// decodeWebState is encode's strict inverse — read cursor with hard
// bounds; nil means refuse whole.
func decodeWebState(b []byte) *webState {
	off := 0
	take := func(n int) []byte {
		if n < 0 || len(b)-off < n {
			off = len(b) + 1 // poison the cursor: every later take fails too
			return nil
		}
		s := b[off : off+n]
		off += n
		return s
	}
	u8v := func() int {
		s := take(1)
		if s == nil {
			return -1
		}
		return int(s[0])
	}
	u16v := func() int {
		s := take(2)
		if s == nil {
			return -1
		}
		return int(s[0]) | int(s[1])<<8
	}
	if len(b) < 8 || u8v() != stateFmtVer || u8v() != 0 {
		return nil
	}
	st := &webState{}
	if st.zoom = u16v(); st.zoom < 0 {
		return nil
	}
	if s := take(4); s == nil {
		return nil
	} else {
		st.scroll = int(uint32(s[0]) | uint32(s[1])<<8 | uint32(s[2])<<16 | uint32(s[3])<<24)
	}
	n := u16v()
	if n < 0 {
		return nil
	}
	if s := take(n); s == nil {
		return nil
	} else {
		st.url = string(s)
	}
	// The URL drives a navigation: it must be something resolveInput could
	// have produced — no control bytes, inside the wire's u16 width.
	for i := 0; i < len(st.url); i++ {
		if st.url[i] < 0x20 || st.url[i] == 0x7f {
			return nil
		}
	}
	nf := u8v()
	if nf < 0 || nf > stateFieldMax {
		return nil
	}
	for i := 0; i < nf; i++ {
		var f stateField
		if f.kind = u8v(); f.kind < fieldText || f.kind > fieldSelect {
			return nil
		}
		if n = u16v(); n < 0 {
			return nil
		}
		if s := take(n); s == nil {
			return nil
		} else {
			f.name = string(s)
		}
		if n = u16v(); n < 0 {
			return nil
		}
		if s := take(n); s == nil {
			return nil
		} else {
			f.value = string(s)
		}
		if c := u8v(); c < 0 || c > 1 {
			return nil
		} else {
			f.checked = c == 1
		}
		st.fields = append(st.fields, f)
	}
	if off != len(b) {
		return nil // trailing garbage: not this codec's product
	}
	return st
}

// --- the app's half of the lifecycle --------------------------------------

// stateZoom is the tab's zoom rung in percent. The field rides the v1
// wire so a build carrying M126d's (#2596) zoom ladder restores its rung
// instead of silently flattening it — until zoom.go lands the contract's
// only rung is 100 and that is what every save writes.
func (a *app) stateZoom() int { return 100 }

// stateZoomApply re-arms the saved rung. The zoom feature is M126d's; when
// zoom.go lands this becomes `a.zoomSet(pct)` (or zoomPct + relayout at
// this call site — loadBody's own layout already ran). A non-default rung
// on a no-zoom build is reported by the restored marker, never silently
// re-armed.
func (a *app) stateZoomApply(int) {}

// collectState snapshots the tab into a webState.
func (a *app) collectState() *webState {
	st := &webState{zoom: a.stateZoom(), scroll: a.scroll, url: a.target}
	for _, c := range a.controls {
		if c == nil {
			continue
		}
		k, ok := stateKindCode(c.kind)
		if !ok {
			continue
		}
		v := c.value
		if c.kind == "select" && c.selected >= 0 && c.selected < len(c.options) {
			v = c.options[c.selected]
		}
		st.fields = append(st.fields, stateField{
			kind: k, name: c.name, value: v, checked: c.checked,
		})
	}
	return st
}

// saveState is the SaveState body the ask poll posts: encode, then trim
// trailing fields until the blob fits the envelope bound. An answer that
// still will not fit is nil — "no state" — never an oversized answer.
func (a *app) saveState() []byte {
	st := a.collectState()
	if len(st.url) > 0xffff || len(st.fields) > stateFieldMax {
		st.fields = nil
		if len(st.url) > 0xffff {
			return nil
		}
	}
	b := st.encode()
	for len(b) > stateCapBytes && len(st.fields) > 0 {
		st.fields = st.fields[:len(st.fields)-1]
		b = st.encode()
	}
	if len(b) > stateCapBytes {
		return nil
	}
	return b
}

// noteState runs in main between the tab declaration and the first
// navigation: the seat's stored envelope arrives, the appver is checked
// before decode (a foreign version is refused by name), and a decoded
// blob parks in pend for the first real layout — loadBody's applyState
// consumes it. The URL applies immediately: navigate() opens it instead
// of argv's target.
func (a *app) noteState(ver uint8, blob []byte) {
	if ver != stateAppVer {
		vi.ConsoleLine(markerStateRefused + "ver=" + itoa(int(ver)))
		return
	}
	st := decodeWebState(blob)
	if st == nil {
		vi.ConsoleLine(markerStateRefused + "bad")
		return
	}
	a.pend = st
}

// applyState consumes the pending blob on the first laid-out page after
// restore — the reload the card pins ("restore reloads the URL then
// reapplies"). It runs at the end of loadBody, after initForms re-derived
// the live controls from the fresh DOM and applyFragment settled the
// fragment scroll: the saved offset wins over both because it records
// where the user actually left the page. scroll clamps against the NEW
// layout's bound; each field is claimed by the first unconsumed live
// control with the same kind+name — a page that changed under the blob
// skips what no longer matches instead of mis-assigning values.
func (a *app) applyState() {
	st := a.pend
	a.pend = nil
	if st == nil || a.lay == nil {
		return
	}
	a.scroll = max(0, min(st.scroll, webrenderScrollMax(a)))
	applied := a.applyFields(st.fields)
	a.stateZoomApply(st.zoom)
	a.dirty = true
	vi.ConsoleLine(markerStateRestored + " url=" + a.target +
		" scroll=" + itoa(a.scroll) +
		" zoom=" + itoa(st.zoom) +
		" forms=" + itoa(applied) + "/" + itoa(len(st.fields)))
}

// applyFields claims serialized fields against the live controls in page
// order and returns how many landed. A control already claimed by an
// earlier field is never matched twice.
func (a *app) applyFields(fields []stateField) int {
	applied := 0
	used := make([]bool, len(a.controls))
	for _, f := range fields {
		for i, c := range a.controls {
			if c == nil || used[i] {
				continue
			}
			k, ok := stateKindCode(c.kind)
			if !ok || k != f.kind || c.name != f.name {
				continue
			}
			used[i] = true
			if fieldApply(c, f) {
				applied++
			}
			break
		}
	}
	return applied
}

// fieldApply writes one serialized record into its live control; ok=false
// means the value did not fit the control (a select whose option list no
// longer carries the saved value) and the field restores as its DOM
// default instead of a forged state.
func fieldApply(c *formControl, f stateField) bool {
	switch f.kind {
	case fieldCheckbox:
		c.checked = f.checked
	case fieldSelect:
		idx := -1
		for i, o := range c.options {
			if o == f.value {
				idx = i
				break
			}
		}
		if idx < 0 {
			return false
		}
		c.selected = idx
		c.value = f.value
	default:
		c.value = f.value
	}
	c.changed = true
	return true
}

// pollStateAsk answers the seat's kind-20 save notice when one is waiting —
// called once per event-loop pass, the same discipline tabapp apps keep.
// The envelope is appver-tagged and staged through PostStateSave's
// rendezvous file; the seat's `state save`/`state drop` markers are the
// verdict on whether the handoff landed.
func (a *app) pollStateAsk() {
	if !vi.PollStateAsk(uint32(a.win)) {
		return
	}
	vi.PostStateSave(uint32(a.win), stateAppVer, a.saveState(), appName)
}
