package main

// state_test.go pins the M125d (#2589) codec and the restore rules the
// go-wm-tabs 16/17 legs drive: round-trip field identity, strict-decode
// refusals that never crash or half-apply, the 64 KiB envelope bound's
// trailing-field trim, and kind+name occurrence matching that skips a
// field whose page moved under it.

import (
	"strings"
	"testing"

	"virelai/vi"
	"virelai/webrender"
)

// stateApp builds an app on a laid-out page with the given controls —
// the shape initForms leaves for loadBody's applyState to land on.
func stateApp(t *testing.T, html string) *app {
	t.Helper()
	a := &app{hist: newHistory(), text: webrender.Bitmap{}}
	a.loadBody([]byte(html), "/host/FORM.HTML")
	if a.lay == nil {
		t.Fatal("fixture did not lay out")
	}
	return a
}

func decodeOK(t *testing.T, b []byte) *webState {
	t.Helper()
	st := decodeWebState(b)
	if st == nil {
		t.Fatal("decodeWebState refused a freshly encoded blob")
	}
	return st
}

// Round-trip: the blob carries url, scroll, zoom and every stateful
// control — and the applied restore rewrites the live controls.
func TestStateRoundTrip(t *testing.T) {
	a := stateApp(t, `<p style="height:800px">tall</p><form>`+
		`<input type="text" name="q">`+
		`<input type="checkbox" name="ck" checked>`+
		`<select name="pick"><option>alpha</option><option selected>beta</option></select>`+
		`</form>`)
	a.controls[0].value = "needle"
	a.controls[1].checked = false // user unchecked the DOM default
	a.controls[2].selected = 0
	a.controls[2].value = "alpha"
	a.target = "/host/FORM.HTML"
	a.scroll = 120

	st := decodeOK(t, a.saveState())
	if st.url != "/host/FORM.HTML" || st.scroll != 120 || st.zoom != 100 {
		t.Fatalf("url=%q scroll=%d zoom=%d", st.url, st.scroll, st.zoom)
	}
	if len(st.fields) != 3 {
		t.Fatalf("fields=%d want 3", len(st.fields))
	}
	if st.fields[0].kind != fieldText || st.fields[0].name != "q" || st.fields[0].value != "needle" {
		t.Fatalf("field0=%+v", st.fields[0])
	}
	if st.fields[1].kind != fieldCheckbox || st.fields[1].checked {
		t.Fatalf("field1=%+v", st.fields[1])
	}
	if st.fields[2].kind != fieldSelect || st.fields[2].value != "alpha" {
		t.Fatalf("field2=%+v", st.fields[2])
	}

	// The "next boot" half: a fresh app lays out the same page and the
	// blob re-applies.
	dst := stateApp(t, `<p style="height:800px">tall</p><form>`+
		`<input type="text" name="q">`+
		`<input type="checkbox" name="ck" checked>`+
		`<select name="pick"><option>alpha</option><option selected>beta</option></select>`+
		`</form>`)
	dst.target = "/host/FORM.HTML"
	dst.pend = st
	dst.applyState()
	if dst.scroll != 120 {
		t.Fatalf("restored scroll=%d want 120", dst.scroll)
	}
	if dst.controls[0].value != "needle" {
		t.Fatalf("text restored %q", dst.controls[0].value)
	}
	if dst.controls[1].checked {
		t.Fatal("checkbox restored checked against the saved unchecked")
	}
	if dst.controls[2].selected != 0 || dst.controls[2].value != "alpha" {
		t.Fatalf("select restored selected=%d value=%q", dst.controls[2].selected, dst.controls[2].value)
	}
	if dst.pend != nil {
		t.Fatal("applyState must consume pend")
	}
}

// scroll clamps against the NEW layout's bound — a page that grew shorter
// under the blob never restores an off-page offset.
func TestStateScrollClamps(t *testing.T) {
	a := stateApp(t, `<p>short</p>`)
	a.pend = &webState{url: "/host/FORM.HTML", scroll: 999999}
	a.applyState()
	if a.scroll != webrenderScrollMax(a) {
		t.Fatalf("scroll=%d max=%d", a.scroll, webrenderScrollMax(a))
	}
}

// A field whose kind+name no live control claims is skipped; the rest
// still land. Occurrence order disambiguates repeated names.
func TestStateFieldMatching(t *testing.T) {
	dst := stateApp(t, `<form>`+
		`<input type="text" name="a">`+
		`<input type="text" name="a">`+
		`<input type="text" name="b">`+
		`</form>`)
	dst.pend = &webState{fields: []stateField{
		{kind: fieldText, name: "a", value: "first"},
		{kind: fieldText, name: "a", value: "second"},
		{kind: fieldText, name: "gone", value: "x"}, // no live control: skip
		{kind: fieldText, name: "b", value: "third"},
	}}
	if n := dst.applyFields(dst.pend.fields); n != 3 {
		t.Fatalf("applied=%d want 3", n)
	}
	if dst.controls[0].value != "first" || dst.controls[1].value != "second" ||
		dst.controls[2].value != "third" {
		t.Fatalf("values %q %q %q", dst.controls[0].value,
			dst.controls[1].value, dst.controls[2].value)
	}
}

// A select whose option list no longer carries the saved value keeps its
// DOM default instead of a forged selection.
func TestStateSelectMissingOption(t *testing.T) {
	dst := stateApp(t, `<form><select name="p">`+
		`<option>alpha</option><option>beta</option></select></form>`)
	n := dst.applyFields([]stateField{{kind: fieldSelect, name: "p", value: "gamma"}})
	if n != 0 || dst.controls[0].selected != 0 {
		t.Fatalf("applied=%d selected=%d", n, dst.controls[0].selected)
	}
}

// Every malformed shape refuses WHOLE — never a partial apply, never a
// panic.
func TestStateDecodeRefusals(t *testing.T) {
	a := stateApp(t, `<form><input type="text" name="q"></form>`)
	a.target = "/host/F.HTML"
	full := a.saveState()
	for i := 0; i < len(full); i++ {
		if st := decodeWebState(full[:i]); st != nil {
			t.Fatalf("truncated blob at %d decoded", i)
		}
	}
	for i := 0; i < len(full); i++ {
		mut := append([]byte{}, full...)
		mut[i] ^= 0xff
		_ = decodeWebState(mut) // may decode (e.g. a flipped url byte) — never panics
	}
	// Trailing garbage is refused.
	if decodeWebState(append(append([]byte{}, full...), 0)) != nil {
		t.Fatal("trailing byte accepted")
	}
	// Foreign fmtVer is refused.
	mut := append([]byte{}, full...)
	mut[0] = stateFmtVer + 1
	if decodeWebState(mut) != nil {
		t.Fatal("foreign fmtVer accepted")
	}
	// A control byte inside the URL is refused. Layout: fmtVer|flags|zoom(2)
	// |scroll(4)|urlLen(2) — url starts at byte 10.
	mut = append([]byte{}, full...)
	mut[10] = 0x01
	if decodeWebState(mut) != nil {
		t.Fatal("control byte in url accepted")
	}
}

// The 64 KiB envelope bound: saveState drops trailing fields until the
// blob fits; a url that alone will not fit answers nil — never an
// oversized answer.
func TestStateCapBound(t *testing.T) {
	// 64 text controls each carrying a 1200-byte value overrun the cap;
	// the save trims from the tail until it fits and stays decodable.
	var sb strings.Builder
	sb.WriteString("<form>")
	big := strings.Repeat("v", 1200)
	for i := 0; i < stateFieldMax; i++ {
		sb.WriteString(`<input type="text" name="n` + itoa(i) + `" value="` + big + `">`)
	}
	sb.WriteString("</form>")
	a := stateApp(t, sb.String())
	a.target = "/host/F.HTML"
	if len(a.controls) != stateFieldMax {
		t.Fatalf("controls=%d want %d", len(a.controls), stateFieldMax)
	}
	b := a.saveState()
	if b == nil || len(b) > stateCapBytes {
		t.Fatalf("saveState len=%d over cap %d", len(b), stateCapBytes)
	}
	st := decodeOK(t, b)
	if len(st.fields) == 0 || len(st.fields) >= stateFieldMax {
		t.Fatalf("fields=%d — tail trim expected", len(st.fields))
	}
	if st.fields[0].name != "n0" || len(st.fields[0].value) != 1200 {
		t.Fatalf("head field mangled: %+v", st.fields[0])
	}

	// A URL that alone cannot fit stores nothing.
	big2 := &webState{url: strings.Repeat("u", 0x10000)}
	a2 := stateApp(t, `<p>x</p>`)
	a2.target = big2.url
	if b := a2.saveState(); b != nil {
		t.Fatalf("oversized url answered %d bytes", len(b))
	}
}

// Envelope discipline: the blob the seat stores is exactly encode()'s
// product, and vi's framing takes it whole at both ends.
func TestStateEnvelope(t *testing.T) {
	a := stateApp(t, `<form><input type="text" name="q" value="z"></form>`)
	a.target = "/host/F.HTML"
	b := a.saveState()
	if b == nil {
		t.Fatal("saveState refused a trivial blob")
	}
	enc, ok := vi.EncodeAppState(stateAppVer, b)
	if !ok {
		t.Fatal("blob refused by the envelope")
	}
	v, blob, ok := vi.DecodeAppState(enc)
	if !ok || v != stateAppVer || string(blob) != string(b) {
		t.Fatal("envelope round-trip drifted")
	}
}

// A foreign appver is refused before decode — the seat's stored tag is
// the app's stale-serialization check.
func TestStateRefusedVersion(t *testing.T) {
	a := stateApp(t, `<p>x</p>`)
	a.noteState(stateAppVer+1, []byte{stateFmtVer, 0})
	if a.pend != nil {
		t.Fatal("a foreign appver parked a blob")
	}
}
