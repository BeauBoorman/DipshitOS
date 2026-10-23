package vi

import (
	"encoding/binary"
	"strings"
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

// TestGrantDenialsDispatchesSlot89Op2 pins the op-2 wire: cursor in a1,
// buffer in a2/a3, and the [next u64le][receipts] frame decoded back —
// including the drop gap when the ring wrapped past the cursor.
func TestGrantDenialsDispatchesSlot89Op2(t *testing.T) {
	payload := "RCPT stage=exec sha256=aa verdict=audit:net_denied name=CONFINE.BIN word=net\n" +
		"RCPT stage=exec sha256=bb verdict=audit:debug_denied name=GRANTD.BIN word=debug\n"
	var gotOp, gotCursor uintptr
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotOp, gotCursor = a0, a1
		if a3 < 8+GrantReceiptMax {
			return -ErrEINVAL
		}
		b := unsafe.Slice((*byte)(unsafe.Pointer(a2)), a3)
		binary.LittleEndian.PutUint64(b[:8], 44) // newest returned seq
		copy(b[8:], payload)
		return int64(8 + len(payload))
	})
	// cursor 40, two lines returned ending at seq 44: seqs 41-42 fell
	// out of the ring before the read — dropped = 44 - 40 - 2.
	lines, next, dropped, rc := GrantDenials(40)
	if rc != 0 {
		t.Fatalf("GrantDenials rc=%d", rc)
	}
	if gotOp != 2 || gotCursor != 40 {
		t.Fatalf("op=%d cursor=%d, want 2/40", gotOp, gotCursor)
	}
	if next != 44 || dropped != 2 {
		t.Fatalf("next=%d dropped=%d, want 44/2", next, dropped)
	}
	if len(lines) != 2 ||
		!strings.Contains(lines[0], "audit:net_denied name=CONFINE.BIN") ||
		!strings.Contains(lines[1], "audit:debug_denied name=GRANTD.BIN") {
		t.Fatalf("lines %v", lines)
	}
}

// TestGrantDenialsNoNewReceipts: the header-only answer — next is the
// caller's own cursor back, no lines, no gap.
func TestGrantDenialsNoNewReceipts(t *testing.T) {
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		binary.LittleEndian.PutUint64(
			unsafe.Slice((*byte)(unsafe.Pointer(a2)), a3)[:8], uint64(a1))
		return 8
	})
	lines, next, dropped, rc := GrantDenials(7)
	if rc != 0 || next != 7 || dropped != 0 || len(lines) != 0 {
		t.Fatalf("lines=%v next=%d dropped=%d rc=%d", lines, next, dropped, rc)
	}
}

// TestGrantDenialsRefusedStaysUnknown pins the honesty rule: EACCES is
// handed back, lines nil — a refused caller must never read as "none".
func TestGrantDenialsRefusedStaysUnknown(t *testing.T) {
	installHook(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return -ErrEACCES })
	lines, _, _, rc := GrantDenials(0)
	if rc != -ErrEACCES || lines != nil {
		t.Fatalf("lines=%v rc=%d", lines, rc)
	}
}

// TestCapsCeilingImpliesTheRuntimeFloor pins the M188a composition: the
// manifest's declared words plus the existence verbs the kernel unions
// in — memory, process, debug (grant.caps_floor).
func TestCapsCeilingImpliesTheRuntimeFloor(t *testing.T) {
	got := GrantWordsCanonical(CapsCeiling([]string{"file", "net"}))
	if got != "file,memory,process,debug,net" {
		t.Fatalf("ceiling = %q", got)
	}
	// A declared existence word is not duplicated, and an empty
	// declaration is the floor alone.
	if got := GrantWordsCanonical(CapsCeiling([]string{"debug"})); got != "memory,process,debug" {
		t.Fatalf("dup floor = %q", got)
	}
	if got := GrantWordsCanonical(CapsCeiling(nil)); got != "memory,process,debug" {
		t.Fatalf("empty = %q", got)
	}
}
