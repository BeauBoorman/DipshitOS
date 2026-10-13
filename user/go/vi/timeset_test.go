package vi

import "testing"

func TestTimeSetCallsSlot78WithTheEpoch(t *testing.T) {
	var gotNum, gotA0 uintptr
	calls := 0
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotNum, gotA0 = num, a0
		calls++
		return 0
	})
	t.Cleanup(func() { SetSyscallHookForTest(prev) })

	if rc := TimeSet(1_789_043_696); rc != 0 {
		t.Fatalf("TimeSet rc=%d, want 0", rc)
	}
	if calls != 1 || gotNum != 78 || gotA0 != 1_789_043_696 {
		t.Fatalf("hook saw calls=%d num=%d a0=%d, want one call to slot 78 with the epoch", calls, gotNum, gotA0)
	}
	if SlotTimeSet != 78 {
		t.Fatalf("SlotTimeSet=%d, ADR 0007 pins 78", SlotTimeSet)
	}
}

func TestTimeSetPassesTheKernelsRefusalThrough(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return -ErrEINVAL // the kernel's range check
	})
	t.Cleanup(func() { SetSyscallHookForTest(prev) })
	if rc := TimeSet(1_000); rc != -ErrEINVAL {
		t.Fatalf("TimeSet rc=%d, want -EINVAL", rc)
	}
}

func TestTimeSetRefusesANonPositiveEpochWithoutASyscall(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		t.Fatalf("a non-positive epoch reached the kernel (slot %d a0=%#x)", num, a0)
		return 0
	})
	t.Cleanup(func() { SetSyscallHookForTest(prev) })
	for _, epoch := range []int64{0, -1, -4} {
		if rc := TimeSet(epoch); rc != -ErrEINVAL {
			t.Fatalf("TimeSet(%d) rc=%d, want -EINVAL", epoch, rc)
		}
	}
}

// The exported seam bounds pin the LEGACY fixed-port contract timesync
// was written against (M99i raised the KERNEL bound to 512, but the
// slot-10/11 wrapper keeps its 64/72 refusal for its existing clients;
// the owned DNS seam uses the real 512/524).
func TestUDPSeamBoundsAreTheLegacyOnes(t *testing.T) {
	if UDPSourcePort != 7000 || UDPPayloadMax != 64 || UDPDatagramMax != 72 {
		t.Fatalf("seam bounds drifted: port=%d payload=%d datagram=%d", UDPSourcePort, UDPPayloadMax, UDPDatagramMax)
	}
	if udpFromPayloadMax != 512 || udpRecvFromMax != 524 {
		t.Fatalf("owned seam bounds drifted: payload=%d recv=%d", udpFromPayloadMax, udpRecvFromMax)
	}
}
