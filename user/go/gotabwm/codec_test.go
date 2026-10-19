package main

import (
	"bytes"
	"errors"
	"testing"

	"virelai/tools/go/tabcodec"
)

func pinnedCalcNotepad(t *testing.T) TabStrip {
	t.Helper()
	var s TabStrip
	if !s.OpenTab(3, "Calc") {
		t.Fatal("OpenTab Calc")
	}
	if !s.OpenTab(4, "Notepad") {
		t.Fatal("OpenTab Notepad")
	}
	if !s.Reorder(0, 1) {
		t.Fatal("Reorder")
	}
	if !s.Pin(3) {
		t.Fatal("Pin Calc")
	}
	if !s.FocusTab(4) {
		t.Fatal("FocusTab Notepad")
	}
	return s
}

func stripToTabcodec(s TabStrip) tabcodec.State {
	st := tabcodec.State{Tabs: make([]tabcodec.Tab, s.Count())}
	if s.Count() > 0 && s.focus >= 0 && s.focus < s.Count() {
		a := s.focus
		st.Active = &a
	}
	for i := 0; i < s.Count(); i++ {
		t0 := s.At(i)
		st.Tabs[i] = tabcodec.Tab{
			Title: t0.Title,
			Flags: tabFlags(t0),
			Bin:   t0.Bin,
		}
	}
	return st
}

// M62d/e: the strip's pin bit is the same byte tabcodec persists. The
// guest encoder matches tabcodec.Encode for Prefs=0 and in-range focus
// (this fixture: Seq=1, Prefs=0).
func TestSessionRoundTripTabcodec(t *testing.T) {
	if FlagPinned != tabcodec.FlagPinned {
		t.Fatalf("FlagPinned = %#x tabcodec.FlagPinned = %#x", FlagPinned, tabcodec.FlagPinned)
	}
	s := pinnedCalcNotepad(t)
	st := stripToTabcodec(s)
	st.Seq = 1
	want, err := tabcodec.Encode(st)
	if err != nil {
		t.Fatalf("tabcodec.Encode: %v", err)
	}
	got, _, ok := s.encodeTabsV2(1)
	if !ok {
		t.Fatal("encodeTabsV2")
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("guest bytes != tabcodec\n got %x\nwant %x", got, want)
	}
	decoded, err := tabcodec.Decode(got)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if decoded.Count() != 2 {
		t.Fatalf("count = %d", decoded.Count())
	}
	if decoded.Tabs[0].Title != "Calc" || decoded.Tabs[0].Flags&tabcodec.FlagPinned == 0 {
		t.Fatalf("record 0 = %+v; Calc must be pinned at left", decoded.Tabs[0])
	}
	if decoded.Tabs[1].Title != "Notepad" || decoded.Tabs[1].Flags&tabcodec.FlagPinned != 0 {
		t.Fatalf("record 1 = %+v", decoded.Tabs[1])
	}
	if decoded.Tabs[0].Bin != "GOCALC.ELF" || decoded.Tabs[1].Bin != "NOTE.ELF" {
		t.Fatalf("bins %q %q", decoded.Tabs[0].Bin, decoded.Tabs[1].Bin)
	}
	ai, aok := decoded.ActiveIndex()
	if !aok || ai != 1 {
		t.Fatalf("active = %d ok=%v want 1 (Notepad)", ai, aok)
	}
}

func TestApplyStateRestoresTitlesPinActive(t *testing.T) {
	s := pinnedCalcNotepad(t)
	raw, _, ok := s.encodeTabsV2(7)
	if !ok {
		t.Fatal("encodeTabsV2")
	}
	var restored TabStrip
	seq, ok := restored.applyTabsV2(raw)
	if !ok {
		t.Fatal("applyTabsV2")
	}
	if seq != 7 {
		t.Fatalf("seq = %d want 7", seq)
	}
	if restored.Count() != 2 {
		t.Fatalf("count = %d", restored.Count())
	}
	if restored.At(0).Title != "Calc" || !restored.At(0).Pinned || restored.At(0).Bin != "GOCALC.ELF" {
		t.Fatalf("tab 0 = %+v", restored.At(0))
	}
	if restored.At(1).Title != "Notepad" || restored.At(1).Pinned || restored.At(1).Bin != "NOTE.ELF" {
		t.Fatalf("tab 1 = %+v", restored.At(1))
	}
	if restored.focus != 1 {
		t.Fatalf("focus index = %d want 1", restored.focus)
	}
	if restored.At(0).ID == 0 || restored.At(1).ID == 0 {
		t.Fatal("placeholder ids must not be 0")
	}
	if line := MarkerSessionTitles + sessionTitlesLine(&restored); line != "gotabwm: session titles=Calc,Notepad pin=1,0 active=1" {
		t.Fatalf("titles line = %q", line)
	}
}

func TestApplyPreservesEmptyBin(t *testing.T) {
	st := tabcodec.State{Tabs: []tabcodec.Tab{{Title: "Calc"}}}
	raw, err := tabcodec.Encode(st)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	var s TabStrip
	if _, ok := s.applyTabsV2(raw); !ok {
		t.Fatal("applyTabsV2")
	}
	if s.At(0).Bin != "" {
		t.Fatalf("empty bin became %q (must not guessBin on restore)", s.At(0).Bin)
	}
	out, _, ok := s.encodeTabsV2(0)
	if !ok {
		t.Fatal("encodeTabsV2")
	}
	got, err := tabcodec.Decode(out)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if got.Tabs[0].Bin != "" {
		t.Fatalf("re-encode bin = %q want empty", got.Tabs[0].Bin)
	}
}

// M71e (#1564): the frozen badge is `.tabs` v2 bit 0x02, and it must survive
// BOTH directions — the guest must write it where tabcodec reads it, and it
// must come back when a writer set it.
func TestFrozenBadgeRoundTripsTabcodec(t *testing.T) {
	if FlagFrozen != tabcodec.FlagFrozen {
		t.Fatalf("FlagFrozen = %#x tabcodec.FlagFrozen = %#x", FlagFrozen, tabcodec.FlagFrozen)
	}
	if FlagFrozen != 0x02 {
		t.Fatalf("FlagFrozen = %#x want 0x02 (the frozen bit)", FlagFrozen)
	}
	// Guest -> tabcodec: freeze the second tab and check the byte tabcodec sees.
	s := pinnedCalcNotepad(t)
	if !s.Freeze(4) {
		t.Fatal("Freeze Notepad")
	}
	st := stripToTabcodec(s)
	st.Seq = 1
	want, err := tabcodec.Encode(st)
	if err != nil {
		t.Fatalf("tabcodec.Encode: %v", err)
	}
	got, _, ok := s.encodeTabsV2(1)
	if !ok {
		t.Fatal("encodeTabsV2")
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("frozen guest bytes != tabcodec\n got %x\nwant %x", got, want)
	}
	decoded, err := tabcodec.Decode(got)
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if decoded.Tabs[1].Flags&tabcodec.FlagFrozen == 0 {
		t.Fatalf("record 1 flags %#x has no frozen bit", decoded.Tabs[1].Flags)
	}
	if decoded.Tabs[0].Flags&tabcodec.FlagFrozen != 0 {
		t.Fatalf("record 0 flags %#x must stay thawed", decoded.Tabs[0].Flags)
	}

	// tabcodec -> guest: a file written by the other language restores frozen.
	foreign := tabcodec.State{Tabs: []tabcodec.Tab{
		{Title: "Calc", Flags: tabcodec.FlagPinned | tabcodec.FlagFrozen, Bin: "GOCALC.ELF"},
		{Title: "Notepad", Bin: "NOTE.ELF"},
	}}
	raw, err := tabcodec.Encode(foreign)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	var restored TabStrip
	if _, ok := restored.applyTabsV2(raw); !ok {
		t.Fatal("applyTabsV2")
	}
	if !restored.At(0).Frozen || !restored.At(0).Pinned {
		t.Fatalf("tab 0 = %+v want pinned+frozen", restored.At(0))
	}
	if restored.At(1).Frozen {
		t.Fatalf("tab 1 = %+v want thawed", restored.At(1))
	}
	if n := restored.FrozenCount(); n != 1 {
		t.Fatalf("FrozenCount = %d want 1", n)
	}
	// A re-encode reproduces the same flag byte (the round-trip is lossless).
	out, _, ok := restored.encodeTabsV2(0)
	if !ok {
		t.Fatal("re-encode")
	}
	again, err := tabcodec.Decode(out)
	if err != nil {
		t.Fatalf("Decode re-encode: %v", err)
	}
	if again.Tabs[0].Flags != (tabcodec.FlagPinned | tabcodec.FlagFrozen) {
		t.Fatalf("re-encode flags %#x want pinned|frozen", again.Tabs[0].Flags)
	}
}

func TestCorruptSessionFailsClosed(t *testing.T) {
	cases := [][]byte{
		{},
		{2},
		{2, 1, 2, 0, 0, 0}, // header claims 2 records, no body
		{1, 1, 0, 0, 0, 0}, // version 1
	}
	for i, raw := range cases {
		_, err := tabcodec.Decode(raw)
		if err == nil {
			t.Fatalf("case %d: tabcodec.Decode accepted corrupt bytes", i)
		}
		if !errors.Is(err, tabcodec.ErrCorrupt) {
			t.Fatalf("case %d: Decode %v, want ErrCorrupt", i, err)
		}
		_, _, _, _, _, ok := decodeTabsV2(raw)
		if ok {
			t.Fatalf("case %d: guest decode accepted corrupt bytes", i)
		}
		var s TabStrip
		if _, ok := s.applyTabsV2(raw); ok {
			t.Fatalf("case %d: applyTabsV2 accepted corrupt bytes", i)
		}
		if s.Count() != 0 {
			t.Fatalf("case %d: fail-closed left count = %d", i, s.Count())
		}
	}
}
