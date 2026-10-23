package strace

import (
	"encoding/binary"
	"strings"
	"testing"
	"unsafe"

	"virelai/vi"
)

func TestRenderKindsAndNativeResults(t *testing.T) {
	r := vi.TraceRecord{Version: 1, PID: 2, Number: 23, Args: [6]uint64{0x123, 14, 1}}
	r.StringMask = 1
	r.StringLengths[0] = uint16(copy(r.Strings[0][:], "/host/TRACE.IN"))
	if got := Render(r); got != `[strace 2] sys_file_open(path="/host/TRACE.IN", len=14, flags=READ) = 0` {
		t.Fatal(got)
	}
	r.Number, r.Args, r.Result = 24, [6]uint64{3, 0x123, 12}, 12
	if got := Render(r); got != `[strace 2] sys_file_read(fd=3, buf=0x123, len=12) = 12` {
		t.Fatal(got)
	}
	r.Number, r.Args, r.Result, r.Errno = 29, [6]uint64{123}, -7, 7
	if got := Render(r); got != `[strace 2] sys_kill(arg0=123) = -EACCES` {
		t.Fatal(got)
	}
	r.Number, r.Args, r.Result, r.Errno = 0, [6]uint64{^uint64(0)}, -1, 1
	if got := Render(r); got != `[strace 2] sys_ping(arg0=-1) = -EINVAL` {
		t.Fatal(got)
	}
	r.Number, r.Flags = 3, vi.TraceNoReturn
	if !strings.HasSuffix(Render(r), " = <no-return>") {
		t.Fatal(Render(r))
	}
}

func TestRenderStringsRedactionAndAllMetadata(t *testing.T) {
	r := vi.TraceRecord{Version: 1, Number: 23, StringMask: 1, TruncatedMask: 1}
	r.StringLengths[0] = uint16(copy(r.Strings[0][:], "a\n\"\\\x00\xff"))
	if got := Render(r); !strings.Contains(got, `path="a\n\"\\\x00\xff"…`) {
		t.Fatal(got)
	}
	r.FaultMask = 1
	if !strings.Contains(Render(r), "path=<fault>") {
		t.Fatal(Render(r))
	}
	for _, slot := range []uint64{70, 71} {
		r.Number, r.Flags = slot, 0
		got := Render(r)
		if !strings.HasSuffix(got, "(<redacted>)") || strings.Contains(got, "path=") {
			t.Fatal(got)
		}
	}
	for _, slot := range vi.SyscallSlots {
		r = vi.TraceRecord{Version: 1, Number: uint64(slot.Number)}
		if got := Render(r); !strings.Contains(got, slot.Name+"(") {
			t.Fatal(got)
		}
	}
	for _, variant := range vi.SyscallVariants {
		r = vi.TraceRecord{Version: 1, Number: uint64(variant.Number)}
		r.Args[variant.Selector] = variant.Op
		if got := Render(r); !strings.Contains(got, vi.SyscallSlots[variant.Number].Name+"(") {
			t.Fatal(got)
		}
	}
}

func TestNamedFlagsAndUnknownBits(t *testing.T) {
	for _, test := range []struct {
		slot  uint64
		arg   int
		value uint64
		want  string
	}{
		{20, 1, 0, "HIDE"}, {20, 1, 1, "SHOW"},
		{23, 2, 31, "READ|WRITE|CREATE|APPEND|DIR"},
		{27, 3, uint64(1)<<63 | 2, "CURSOR_READ"},
		{28, 3, uint64(1)<<63 | 2, "STREAMS|0x2"},
		{35, 1, uint64(1)<<63 | 14, "REPLACE|0xe"},
		{43, 1, uint64(1)<<63 | 8, "AUDIO_STREAM|0x8"},
		{45, 0, 1, "MUTED"}, {53, 1, 1, "UNSAVED"},
		{63, 2, 3, "READ|WRITE"},
		{63, 3, 0x18022, "PRIVATE|ANON|POPULATE|SHARED"},
		{69, 2, 0600, "OWNER_READ|OWNER_WRITE"},
		{76, 1, 3, "READ|WRITE"}, {76, 1, 7, "READ|WRITE|0x4"},
	} {
		if got := flags(test.slot, test.arg, test.value); got != test.want {
			t.Fatalf("slot=%d arg=%d value=%x: %s, want %s",
				test.slot, test.arg, test.value, got, test.want)
		}
	}
}

func TestArmExecWireOrderingAndFailureDisarm(t *testing.T) {
	var ops []uintptr
	previous := vi.SetSyscallHookForTest(func(slot, op, token, ptr, size uintptr) int64 {
		if slot != vi.SlotTrace {
			t.Fatal(slot)
		}
		ops = append(ops, op)
		b := unsafe.Slice((*byte)(unsafe.Pointer(ptr)), size)
		switch op {
		case vi.TraceArm:
			if size != 88 || binary.LittleEndian.Uint32(b) != 1 ||
				binary.LittleEndian.Uint32(b[4:]) != 0 || binary.LittleEndian.Uint64(b[72:]) != 1<<23 {
				t.Fatal(b)
			}
			return 5
		case vi.TraceArmExec:
			if token != 5 || size != 32 || binary.LittleEndian.Uint64(b[8:]) != 8 ||
				binary.LittleEndian.Uint64(b[24:]) != 2 {
				t.Fatal(b)
			}
			path := unsafe.Slice((*byte)(unsafe.Pointer(uintptr(binary.LittleEndian.Uint64(b)))), 8)
			argv := unsafe.Slice((*byte)(unsafe.Pointer(uintptr(binary.LittleEndian.Uint64(b[16:])))), 512)
			if string(path) != "GOSH.ELF" || string(argv[:2]) != "-c" || string(argv[256:263]) != "echo hi" {
				t.Fatalf("%q %q", path, argv)
			}
			return -vi.ErrENOENT
		case vi.TraceDisarm:
			return 0
		}
		t.Fatal(op)
		return -vi.ErrEINVAL
	})
	defer vi.SetSyscallHookForTest(previous)
	_, _, err := ArmExec("GOSH.ELF", []string{"-c", "echo hi"}, []uint64{23})
	if err == nil || err.Error() != "ENOENT" || len(ops) != 3 ||
		ops[0] != vi.TraceArm || ops[1] != vi.TraceArmExec || ops[2] != vi.TraceDisarm {
		t.Fatalf("ops=%v err=%v", ops, err)
	}
}

// drainHook serves scripted TraceRead batches: counts[i] records and a
// cumulative dropped of drops[i] on call i, then empty batches. Each record
// carries slot 24 (sys_file_read) so the rendered line is deterministic.
func drainHook(t *testing.T, counts []uint32, drops []uint64, calls *int) func(num, a0, a1, a2, a3 uintptr) int64 {
	return func(num, a0, a1, a2, a3 uintptr) int64 {
		if num == vi.SlotWrite {
			return int64(a2) // the console write reports its length, nothing more
		}
		if num != vi.SlotTrace || a0 != vi.TraceRead {
			t.Fatalf("unexpected syscall num=%d op=%d", num, a0)
		}
		i := *calls
		*calls++
		count, dropped := uint32(0), uint64(0)
		if i < len(counts) {
			count, dropped = counts[i], drops[i]
		}
		b := unsafe.Slice((*byte)(unsafe.Pointer(a2)), a3)
		binary.LittleEndian.PutUint32(b, 1)
		binary.LittleEndian.PutUint32(b[4:], vi.TraceRecordBytes)
		binary.LittleEndian.PutUint32(b[8:], count)
		binary.LittleEndian.PutUint64(b[16:], dropped)
		for j := uint32(0); j < count; j++ {
			r := b[24+j*vi.TraceRecordBytes:]
			binary.LittleEndian.PutUint32(r, 1)
			binary.LittleEndian.PutUint64(r[8:], uint64(100+j))
			binary.LittleEndian.PutUint64(r[32:], 24)
			binary.LittleEndian.PutUint64(r[40:], 3)
			binary.LittleEndian.PutUint64(r[88:], uint64(j))
		}
		return int64(count)
	}
}

func TestDrainReadsRendersStopsAndDrops(t *testing.T) {
	calls := 0
	previous := vi.SetSyscallHookForTest(drainHook(t,
		[]uint32{3, 1, 0}, []uint64{0, 0, 9}, &calls))
	defer vi.SetSyscallHookForTest(previous)
	s := &Session{Token: 5}
	var seen []string
	dropped, err := s.Drain(0, func(r vi.TraceRecord, line string) bool {
		seen = append(seen, line)
		return true
	})
	if err != nil || dropped != 9 || calls != 3 || len(seen) != 4 ||
		seen[0] != "[strace 100] sys_file_read(fd=3, buf=0x0, len=0) = 0" {
		t.Fatalf("dropped=%d calls=%d seen=%v err=%v", dropped, calls, seen, err)
	}
}

func TestDrainMaxBatchesAndEarlyStop(t *testing.T) {
	calls := 0
	previous := vi.SetSyscallHookForTest(drainHook(t,
		[]uint32{3, 1, 0}, []uint64{0, 0, 9}, &calls))
	defer vi.SetSyscallHookForTest(previous)
	s := &Session{Token: 5}
	var seen []string
	if _, err := s.Drain(1, func(r vi.TraceRecord, line string) bool {
		seen = append(seen, line)
		return true
	}); err != nil || calls != 1 || len(seen) != 3 {
		t.Fatalf("bounded drain: calls=%d seen=%v err=%v", calls, seen, err)
	}
	calls = 0
	seen = seen[:0]
	dropped, err := s.Drain(0, func(r vi.TraceRecord, line string) bool {
		seen = append(seen, line)
		return len(seen) != 2
	})
	if err != nil || dropped != 0 || calls != 1 || len(seen) != 2 {
		t.Fatalf("early stop: dropped=%d calls=%d seen=%v err=%v", dropped, calls, seen, err)
	}
}

func TestDrainErrorPropagates(t *testing.T) {
	calls := 0
	previous := vi.SetSyscallHookForTest(func(num, a0, a1, a2, a3 uintptr) int64 {
		if num == vi.SlotWrite {
			return int64(a2)
		}
		calls++
		if calls == 2 {
			return -vi.ErrENOENT
		}
		b := unsafe.Slice((*byte)(unsafe.Pointer(a2)), a3)
		binary.LittleEndian.PutUint32(b, 1)
		binary.LittleEndian.PutUint32(b[4:], vi.TraceRecordBytes)
		binary.LittleEndian.PutUint32(b[8:], 1)
		binary.LittleEndian.PutUint64(b[16:], 7)
		r := b[24:]
		binary.LittleEndian.PutUint32(r, 1)
		binary.LittleEndian.PutUint64(r[8:], 100)
		binary.LittleEndian.PutUint64(r[32:], 24)
		return 1
	})
	defer vi.SetSyscallHookForTest(previous)
	s := &Session{Token: 5}
	dropped, err := s.Drain(0, nil)
	if err == nil || err.Error() != "ENOENT" || dropped != 7 || calls != 2 {
		t.Fatalf("dropped=%d calls=%d err=%v", dropped, calls, err)
	}
}

func TestReadBatchWireAndBounds(t *testing.T) {
	previous := vi.SetSyscallHookForTest(func(slot, op, token, ptr, size uintptr) int64 {
		b := unsafe.Slice((*byte)(unsafe.Pointer(ptr)), size)
		binary.LittleEndian.PutUint32(b, 1)
		binary.LittleEndian.PutUint32(b[4:], vi.TraceRecordBytes)
		binary.LittleEndian.PutUint32(b[8:], 1)
		binary.LittleEndian.PutUint64(b[16:], 44)
		r := b[24:]
		binary.LittleEndian.PutUint32(r, 1)
		binary.LittleEndian.PutUint64(r[8:], 2)
		binary.LittleEndian.PutUint64(r[16:], 3)
		binary.LittleEndian.PutUint64(r[24:], 4)
		binary.LittleEndian.PutUint64(r[32:], 23)
		binary.LittleEndian.PutUint64(r[80:], 123) // Sixth argument.
		binary.LittleEndian.PutUint64(r[88:], 3)
		binary.LittleEndian.PutUint32(r[100:], 1)
		binary.LittleEndian.PutUint16(r[112:], 4)
		copy(r[128:], "test")
		return 1
	})
	defer vi.SetSyscallHookForTest(previous)
	s := &Session{Token: 5}
	records, dropped, err := s.Read()
	if err != nil || dropped != 44 || len(records) != 1 ||
		records[0].Args[5] != 123 || records[0].Result != 3 ||
		string(records[0].Strings[0][:4]) != "test" {
		t.Fatalf("records=%v dropped=%d err=%v", records, dropped, err)
	}
	if _, err := config(nil, []uint64{128}); err == nil {
		t.Fatal("out-of-range slot accepted")
	}
	if _, err := config(make([]uint64, 9), nil); err == nil {
		t.Fatal("oversized pid set accepted")
	}
}
