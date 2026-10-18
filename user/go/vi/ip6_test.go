package vi

// M117c (#2475, ADR 0057): the v6 literal seam's host tests — the parser's
// RFC 4291 shapes (the kernel's parse_ip6 mirror), the Dial marshal's
// tagged-op10 shape (slot 80: op=10, args[1]=familyV6Tag, args[2]=port|tmo,
// args[3]=&addr16), and the ping6 marshal on slots 59/60. All run through
// the syscallHook seam — no kernel, no NIC.

import (
	"errors"
	"testing"
	"unsafe"
)

func TestParseIPv6(t *testing.T) {
	cases := []struct {
		in   string
		want [16]byte
	}{
		{"::", [16]byte{}},
		{"::1", [16]byte{15: 1}},
		{"fe80::2", [16]byte{0: 0xfe, 1: 0x80, 15: 2}},
		{"fe80::ff:fe00:2", [16]byte{0: 0xfe, 1: 0x80, 11: 0xff, 12: 0xfe, 15: 2}},
		{"2001:db8:64::ff:fe00:2", [16]byte{0: 0x20, 1: 0x01, 2: 0x0d, 3: 0xb8, 5: 0x64, 11: 0xff, 12: 0xfe, 15: 2}},
		{"1:2:3:4:5:6:7:8", [16]byte{0: 0, 1: 1, 2: 0, 3: 2, 4: 0, 5: 3, 6: 0, 7: 4, 8: 0, 9: 5, 10: 0, 11: 6, 12: 0, 13: 7, 14: 0, 15: 8}},
		{"[fe80::2]", [16]byte{0: 0xfe, 1: 0x80, 15: 2}},
		{"FFFF::ABCD", [16]byte{0: 0xff, 1: 0xff, 14: 0xab, 15: 0xcd}},
	}
	for _, c := range cases {
		got, err := ParseIPv6(c.in)
		if err != nil || got != c.want {
			t.Fatalf("ParseIPv6(%q) = %v, %v; want %v", c.in, got, err, c.want)
		}
	}
}

func TestParseIPv6Refusals(t *testing.T) {
	for _, bad := range []string{
		"",
		"[]",
		"[fe80::2",       // unterminated bracket
		"fe80::2]",       // stray close bracket
		"1:2:3:4:5:6:7",  // seven groups, no compression
		"1:2:3:4:5:6:7:8:9", // nine groups
		"fe80:::2",       // triple colon (two ::)
		"::1::2",         // two elisions
		"fe80::gggg",     // non-hex
		"12345::",        // a group over 4 digits
		"::ffff:10.0.0.2", // mapped dotted tail — refused (D8, never translated)
		"fe80::2%eth0",   // zone id out of scope
		":",              // a lone colon
		"fe80::2 extra",
	} {
		if got, err := ParseIPv6(bad); err == nil {
			t.Fatalf("ParseIPv6(%q) = %v, nil; want refusal", bad, got)
		}
	}
}

func TestIsV6Literal(t *testing.T) {
	for _, s := range []string{"fe80::2", "[fe80::2]", "::1", "a:b::c:d"} {
		if !IsV6Literal(s) {
			t.Fatalf("IsV6Literal(%q) = false", s)
		}
	}
	for _, s := range []string{"10.0.0.2", "myhost.local", "", "[", "8080"} {
		if IsV6Literal(s) {
			t.Fatalf("IsV6Literal(%q) = true", s)
		}
	}
}

// The v6 Dial rides slot 80 op 10 with the family tag in args[1] and the
// 16-byte literal through args[3] — the kernel's copy_in seam.
func TestDialV6Marshal(t *testing.T) {
	var gotA1, gotA2, gotA3 uintptr
	var gotOp uintptr
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotOp = a0
		gotA1, gotA2, gotA3 = a1, a2, a3
		return 0x24 // a minted-looking handle
	})
	defer SetSyscallHookForTest(prev)

	for _, literal := range []string{"2001:db8:64::ff:fe00:2", "[2001:db8:64::ff:fe00:2]"} {
		gotA1, gotA2, gotA3, gotOp = 0, 0, 0, 0
		c, err := DialTimeout(literal, 8080, 5*1_000_000_000) // 5 s
		if err != nil || c == nil {
			t.Fatalf("Dial(%q) = %v, %v", literal, c, err)
		}
		if gotOp != SockOpConnect {
			t.Fatalf("Dial(%q): op=%d, want %d", literal, gotOp, SockOpConnect)
		}
		if gotA1 != familyV6Tag {
			t.Fatalf("Dial(%q): a1=%#x, want the family tag", literal, gotA1)
		}
		wantPortTmo := uintptr(8080) | uintptr(5000)<<16 // 5 s -> 5000 ms
		if gotA2 != wantPortTmo {
			t.Fatalf("Dial(%q): a2=%#x, want port|timeout %#x", literal, gotA2, wantPortTmo)
		}
		want := [16]byte{0x20, 0x01, 0x0d, 0xb8, 0, 0x64, 0, 0, 0, 0, 0, 0xff, 0xfe, 0, 0, 2}
		// The pointer payload is the wire-order literal.
		got := *(*[16]byte)(unsafe.Pointer(gotA3))
		if got != want {
			t.Fatalf("Dial(%q): literal bytes %v, want %v", literal, got, want)
		}
		if !c.IsV6() || c.IP6() != want {
			t.Fatalf("Dial(%q): conn v6=%v ip6=%v", literal, c.IsV6(), c.IP6())
		}
	}
}

func TestDialV6Refusals(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return -ErrEINVAL // the kernel's refusal shape
	})
	defer SetSyscallHookForTest(prev)

	// A malformed literal never reaches the kernel.
	calls := 0
	SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		calls++
		return 0x24
	})
	if c, err := Dial("::ffff:10.0.0.2", 8080); c != nil || err == nil {
		t.Fatalf("Dial(mapped) = %v, %v; want refusal", c, err)
	}
	if calls != 0 {
		t.Fatalf("malformed v6 literal reached the kernel (%d calls)", calls)
	}
	if _, err := Dial("fe80::", 0); !errors.Is(err, errno(ErrEINVAL)) {
		t.Fatalf("Dial v6 port 0 = %v, want EINVAL", err)
	}
}

// The ping6 marshal: slot 59 carries (tag, &addr16), slot 60 the tag —
// the kernel answers the v6 counters.
func TestPing6Marshal(t *testing.T) {
	var sends [][4]uintptr
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		sends = append(sends, [4]uintptr{num, a0, a1, a2})
		if num == SlotPingPoll {
			return 7 // a landed pong sequence
		}
		return 0
	})
	defer SetSyscallHookForTest(prev)

	addr := [16]byte{0: 0xfe, 1: 0x80, 15: 2}
	if err := Ping6Send(addr); err != nil {
		t.Fatalf("Ping6Send = %v", err)
	}
	if seq := Ping6Poll(); seq != 7 {
		t.Fatalf("Ping6Poll = %d, want 7", seq)
	}
	if len(sends) != 2 {
		t.Fatalf("marshal calls = %v", sends)
	}
	if sends[0][0] != SlotPingSend || sends[0][1] != familyV6Tag {
		t.Fatalf("Ping6Send marshal = %v, want (59, tag, ptr)", sends[0])
	}
	if *(*[16]byte)(unsafe.Pointer(sends[0][2])) != addr {
		t.Fatalf("Ping6Send literal bytes wrong")
	}
	if sends[1][0] != SlotPingPoll || sends[1][1] != familyV6Tag {
		t.Fatalf("Ping6Poll marshal = %v, want (60, tag)", sends[1])
	}
}
