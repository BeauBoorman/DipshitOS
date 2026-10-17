package vi

import (
	"testing"
	"unsafe"
)

// TestGrantReadRowDispatchesSlot89Op0 pins the read wire: op 0, the row
// index in a1, the caller's buffer in a2/a3 — and a kernel-marshaled
// line handed back as bytes.
func TestGrantReadRowDispatchesSlot89Op0(t *testing.T) {
	line := "GOHELLO.ELF\tab\tfile,net"
	var gotSlot, gotOp, gotIndex uintptr
	var gotLen uintptr
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotSlot, gotOp, gotIndex, gotLen = num, a0, a1, a3
		if a2 == 0 {
			t.Fatal("op 0 passed a nil buffer")
		}
		copy(unsafe.Slice((*byte)(unsafe.Pointer(a2)), a3), line)
		return int64(len(line))
	})
	buf := make([]byte, GrantLineMax)
	n, rc := GrantReadRow(3, buf)
	if rc < 0 {
		t.Fatalf("GrantReadRow rc=%d", rc)
	}
	if gotSlot != SlotGrantAdmin || gotOp != 0 || gotIndex != 3 {
		t.Fatalf("slot=%d op=%d index=%d, want slot=%d op=0 index=3", gotSlot, gotOp, gotIndex, SlotGrantAdmin)
	}
	if gotLen != uintptr(GrantLineMax) {
		t.Fatalf("len arg=%d, want %d", gotLen, GrantLineMax)
	}
	if string(buf[:n]) != line {
		t.Fatalf("line %q, want %q", buf[:n], line)
	}
}

// TestGrantWriteLineDispatchesSlot89Op1 pins the write wire: op 1 with
// the line bytes, index ignored.
func TestGrantWriteLineDispatchesSlot89Op1(t *testing.T) {
	var gotOp uintptr
	var gotLine string
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotOp = a0
		gotLine = unsafe.String((*byte)(unsafe.Pointer(a2)), int(a3))
		return 0
	})
	if rc := GrantWriteRow(GrantRow{Name: "GOHELLO.ELF", SHA: "cd", Words: "file,net"}); rc != 0 {
		t.Fatalf("GrantWriteRow rc=%d", rc)
	}
	if gotOp != 1 {
		t.Fatalf("op=%d, want 1", gotOp)
	}
	if gotLine != "GOHELLO.ELF\tcd\tfile,net" {
		t.Fatalf("line %q", gotLine)
	}
}

// TestGrantRowsWalksToENOENT feeds a two-row table through the hook and
// pins both the iteration and the row decode.
func TestGrantRowsWalksToENOENT(t *testing.T) {
	lines := []string{
		"GOHELLO.ELF\tab\tfile,net",
		"ACMEAPP.ELF\t*\tfile",
	}
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		i := int(a1)
		if i >= len(lines) {
			return -ErrENOENT
		}
		copy(unsafe.Slice((*byte)(unsafe.Pointer(a2)), a3), lines[i])
		return int64(len(lines[i]))
	})
	rows, rc := GrantRows()
	if rc != 0 {
		t.Fatalf("GrantRows rc=%d", rc)
	}
	if len(rows) != 2 || rows[0].Name != "GOHELLO.ELF" || rows[0].SHA != "ab" ||
		rows[0].Words != "file,net" || rows[1].SHA != "*" {
		t.Fatalf("rows %+v", rows)
	}
}

// TestGrantRowsEACCESIsNotBaseline pins the pane's honesty rule: a
// refused table reads as an error, never as "no rows".
func TestGrantRowsEACCESIsNotBaseline(t *testing.T) {
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -ErrEACCES })
	rows, rc := GrantRows()
	if rc != -ErrEACCES || rows != nil {
		t.Fatalf("rows=%v rc=%d, want nil, %d", rows, rc, -ErrEACCES)
	}
}

// TestGrantRowLineRoundTrip pins the serialization shape.
func TestGrantRowLineRoundTrip(t *testing.T) {
	r := GrantRow{Name: "GOHELLO.ELF", SHA: "ff", Words: "file,net"}
	got, ok := ParseGrantLine(GrantLine(r))
	if !ok || got != r {
		t.Fatalf("round trip: %+v ok=%v", got, ok)
	}
	if _, ok := ParseGrantLine("no-tabs"); ok {
		t.Fatal("malformed line parsed")
	}
	if _, ok := ParseGrantLine("a\tb\tc\td"); ok {
		t.Fatal("four-field line parsed")
	}
	// Defaults: empty sha renders the wildcard, empty words render "-".
	if l := GrantLine(GrantRow{Name: "N", Words: "-"}); l != "N\t*\t-" {
		t.Fatalf("default line %q", l)
	}
}

// TestGrantWordsCanonical pins vocabulary-order rendering and the "-"
// empty form.
func TestGrantWordsCanonical(t *testing.T) {
	if got := GrantWordsCanonical([]string{"net", "file"}); got != "file,net" {
		t.Fatalf("canonical %q", got)
	}
	if got := GrantWordsCanonical(nil); got != "-" {
		t.Fatalf("empty %q", got)
	}
	if !GrantWordKnown("net") || GrantWordKnown("root") {
		t.Fatal("vocab wrong")
	}
}

// TestGrantWordsSubset pins the non-widening comparator.
func TestGrantWordsSubset(t *testing.T) {
	a := []string{"file"}
	b := []string{"file", "net"}
	if !GrantWordsSubset(a, b) {
		t.Fatal("file ⊆ file,net")
	}
	if GrantWordsSubset(b, a) {
		t.Fatal("file,net ⊄ file")
	}
	if !GrantWordsSubset(nil, b) {
		t.Fatal("empty ⊆ anything")
	}
}
