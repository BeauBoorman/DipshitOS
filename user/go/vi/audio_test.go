package vi

import (
	"testing"
	"unsafe"
)

// The AudioInfo wire layout is the kernel's (kernel/src/virtio_snd.zig,
// 16 bytes). A struct with the wrong size here does not fail loudly on the
// guest — slot 42 copies exactly @sizeOf(AudioInfo) bytes out, so a 24-byte
// Go struct would read 8 bytes of whatever follows, silently. Hence the pin.
func TestAudioInfoWireSize(t *testing.T) {
	if got := unsafe.Sizeof(AudioInfo{}); got != 16 {
		t.Fatalf("AudioInfo size = %d want 16", got)
	}
	offsets := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"Ready", unsafe.Offsetof(AudioInfo{}.Ready), 0},
		{"Format", unsafe.Offsetof(AudioInfo{}.Format), 4},
		{"Rate", unsafe.Offsetof(AudioInfo{}.Rate), 5},
		{"Channels", unsafe.Offsetof(AudioInfo{}.Channels), 6},
		{"Padding", unsafe.Offsetof(AudioInfo{}.Padding), 7},
		{"PeriodBytes", unsafe.Offsetof(AudioInfo{}.PeriodBytes), 8},
		{"MaxLen", unsafe.Offsetof(AudioInfo{}.MaxLen), 12},
	}
	for _, o := range offsets {
		if o.got != o.want {
			t.Fatalf("AudioInfo.%s offset = %d want %d", o.name, o.got, o.want)
		}
	}
}

// The negotiated codes are virtio-snd's, not ours: an app that synthesizes
// the wrong format code plays noise. (The device VZ reports advertises
// S16|S32|FLOAT @ 48|96 kHz and negotiates FLOAT/48000/stereo.)
func TestAudioFormatCodes(t *testing.T) {
	if AudioFmtS16 != 5 || AudioFmtS32 != 17 || AudioFmtFloat != 19 || AudioFmtNone != 0xff {
		t.Fatalf("format codes drifted: S16=%d S32=%d FLOAT=%d none=%d",
			AudioFmtS16, AudioFmtS32, AudioFmtFloat, AudioFmtNone)
	}
}

// The chunk geometry must stay inside the kernel's own bound, or the
// chunker cannot make an over-bound buffer legal (the whole reason it exists).
func TestAudioGeometry(t *testing.T) {
	if AudioPeriodBytes != 4096 {
		t.Fatalf("AudioPeriodBytes = %d want 4096 (virtio_snd.beep_period_bytes)", AudioPeriodBytes)
	}
	if AudioMaxLen != 64*1024 {
		t.Fatalf("AudioMaxLen = %d want 65536 (virtio_snd.audio_max_len)", AudioMaxLen)
	}
	if AudioPeriodBytes > AudioMaxLen {
		t.Fatalf("period %d exceeds the per-call bound %d: chunking could never legalize a big buffer",
			AudioPeriodBytes, AudioMaxLen)
	}
}

// ErrNoAudioDevice is the kernel's ENXIO as a typed value — the app branches on
// it to tell "this VM has no sound device" (documented, not a failure) from a
// real error, and it is unexported errno on purpose.
func TestAudioErrNoAudioDevice(t *testing.T) {
	if ErrNoAudioDevice != errno(ErrENXIO) {
		t.Fatalf("ErrNoAudioDevice = %v want errno(ENXIO)", ErrNoAudioDevice)
	}
	if got := ErrNoAudioDevice.Error(); got != "ENXIO" {
		t.Fatalf("ErrNoAudioDevice.Error() = %q want \"ENXIO\"", got)
	}
}

// Host: every syscall is -ENOSYS, and the wrapper must degrade without
// touching the out struct or panicking.
func TestAudioHostFails(t *testing.T) {
	info, err := AudioQuery()
	if err != errno(ErrENOSYS) {
		t.Fatalf("host AudioQuery err = %v want ENOSYS", err)
	}
	if info != (AudioInfo{}) {
		t.Fatalf("host AudioQuery filled the struct on failure: %+v", info)
	}
	n, err := AudioPlay(make([]byte, AudioPeriodBytes))
	if n != 0 || err != errno(ErrENOSYS) {
		t.Fatalf("host AudioPlay = %d, %v want 0, ENOSYS", n, err)
	}
}

// An empty buffer is a no-op, not a syscall: the kernel refuses len == 0 with
// EINVAL, and a caller that hands us nothing should not see an error for it.
func TestAudioPlayEmptyIsNoop(t *testing.T) {
	for _, pcm := range [][]byte{nil, {}} {
		n, err := AudioPlay(pcm)
		if n != 0 || err != nil {
			t.Fatalf("AudioPlay(empty) = %d, %v want 0, nil", n, err)
		}
	}
}

// The chunker is the pure half of AudioPlay, so its arithmetic is pinned here
// — the live go-fart gate's `43 sys_audio_play calls=52` is this loop's output.
func TestAudioChunkArithmetic(t *testing.T) {
	cases := []struct {
		name  string
		n     int
		calls int
	}{
		{"empty", 0, 0},
		{"one byte", 1, 1},
		{"exactly one period", AudioPeriodBytes, 1},
		{"one byte over", AudioPeriodBytes + 1, 2},
		// FART.ELF's blip: 550 ms at 48 kHz stereo FLOAT. It is deliberately
		// larger than AudioMaxLen — one unchunked call would be ENAMETOOLONG.
		{"the fart blip", 26400 * 8, 52},
	}
	for _, c := range cases {
		calls, widest, sum := 0, 0, 0
		got, err := audioChunks(c.n, func(off, end int) (int, error) {
			if end <= off || end > c.n {
				t.Fatalf("%s: bad chunk [%d,%d) of %d", c.name, off, end, c.n)
			}
			calls++
			if end-off > widest {
				widest = end - off
			}
			sum += end - off
			return end - off, nil
		})
		if err != nil {
			t.Fatalf("%s: unexpected error %v", c.name, err)
		}
		if calls != c.calls {
			t.Fatalf("%s: %d calls want %d", c.name, calls, c.calls)
		}
		if widest > AudioPeriodBytes {
			t.Fatalf("%s: widest chunk %d exceeds the period %d", c.name, widest, AudioPeriodBytes)
		}
		if widest > AudioMaxLen {
			t.Fatalf("%s: widest chunk %d exceeds the kernel bound %d", c.name, widest, AudioMaxLen)
		}
		if sum != c.n || got != c.n {
			t.Fatalf("%s: covered %d / returned %d want %d", c.name, sum, got, c.n)
		}
	}
}

// A failure part-way through must report exactly the bytes already confirmed —
// never the whole buffer, never zero. This is what lets an app's marker
// (`played=`) be trusted.
func TestAudioChunkPartialOnError(t *testing.T) {
	const n = AudioPeriodBytes*3 + 17
	failAt := 2
	calls := 0
	got, err := audioChunks(n, func(off, end int) (int, error) {
		if calls == failAt {
			return 0, ErrNoAudioDevice
		}
		calls++
		return end - off, nil
	})
	if err != ErrNoAudioDevice {
		t.Fatalf("err = %v want ENXIO", err)
	}
	if calls != failAt {
		t.Fatalf("calls after failure = %d want %d (must stop at the first error)", calls, failAt)
	}
	if want := AudioPeriodBytes * failAt; got != want {
		t.Fatalf("confirmed = %d want %d (only the drained periods)", got, want)
	}
}

// The four audio rows are ADR 0007 slots 42-45, i.e. the kernel's numbering.
// A binding that called the wrong row looks identical on the host (every raw
// call is -ENOSYS there) and only misbehaves on the guest, so the numbers are
// pinned rather than trusted — the same argument as TestAudioInfoWireSize.
func TestAudioSlotNumbers(t *testing.T) {
	rows := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"SlotAudioInfo", SlotAudioInfo, 42},
		{"SlotAudioPlay", SlotAudioPlay, 43},
		{"SlotAudioVolume", SlotAudioVolume, 44},
		{"SlotAudioMute", SlotAudioMute, 45},
	}
	for _, r := range rows {
		if r.got != r.want {
			t.Fatalf("%s = %d want %d", r.name, r.got, r.want)
		}
	}
	if AudioVolumeMax != 100 {
		t.Fatalf("AudioVolumeMax = %d want 100 (slot 44's bound, ADR 0007 row 44)", AudioVolumeMax)
	}
}

// AudioVolume must SEND the caller's value unchanged, even when it is out of
// range. The kernel's EINVAL is the documented answer ("honest refusal, no
// silent clamping"); a clamp here would turn a caller's bug into silent
// success, and this is the only place that property is observable without a
// device — the audio rows route through the hookable gateway, so the fake
// kernel below sees the actual argument.
func TestAudioVolumeNoClamp(t *testing.T) {
	var gotNum, gotArg uintptr
	calls := 0
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		calls++
		gotNum, gotArg = num, a0
		return -ErrEINVAL // what the kernel answers for vol > AudioVolumeMax
	})
	defer SetSyscallHookForTest(prev)

	n, err := AudioVolume(AudioVolumeMax + 1)
	if calls != 1 {
		t.Fatalf("slot 44 called %d times want 1", calls)
	}
	if gotNum != SlotAudioVolume {
		t.Fatalf("called slot %d want %d", gotNum, SlotAudioVolume)
	}
	if gotArg != AudioVolumeMax+1 {
		t.Fatalf("AudioVolume sent %d want %d unchanged: clamping would hide the kernel's EINVAL",
			gotArg, AudioVolumeMax+1)
	}
	if n != 0 || err != errno(ErrEINVAL) {
		t.Fatalf("AudioVolume(over) = %d, %v want 0, EINVAL", n, err)
	}
}

// The in-range path sends the number it was given and returns the KERNEL's
// answer. Those are two different properties, and the second is the one worth
// proving: the app's marker prints this value, so a binding that restated its
// own argument would make every `echo=` in the gate a tautology.
func TestAudioVolumeEcho(t *testing.T) {
	var gotArg uintptr

	// The ordinary case: the kernel echoes what it accepted.
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotArg = a0
		return 40
	})
	n, err := AudioVolume(40)
	SetSyscallHookForTest(prev)
	if err != nil {
		t.Fatalf("AudioVolume(40) err = %v want nil", err)
	}
	if gotArg != 40 {
		t.Fatalf("slot 44 arg = %d want 40", gotArg)
	}
	if n != 40 {
		t.Fatalf("AudioVolume(40) = %d want the kernel's echo 40", n)
	}

	// And the one that separates the two: a kernel answer that is NOT the
	// argument. (7 is absurd as a volume and is not supposed to be plausible --
	// the property under test is that the value came back from the syscall at
	// all. A binding returning its own argument passes the case above and fails
	// here, which is exactly the mutation a marker-based gate cannot see.)
	prev = SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotArg = a0
		return 7
	})
	n, err = AudioVolume(60)
	SetSyscallHookForTest(prev)
	if err != nil {
		t.Fatalf("AudioVolume(60) err = %v want nil", err)
	}
	if gotArg != 60 {
		t.Fatalf("slot 44 arg = %d want 60 (passed through unchanged)", gotArg)
	}
	if n != 7 {
		t.Fatalf("AudioVolume(60) = %d want the kernel's 7: the return value is not being taken from the syscall", n)
	}

	// The bound itself is in range: AudioVolumeMax is a legal volume, not an
	// error, and pinning that keeps an off-by-one out of the app's arithmetic.
	prev = SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return int64(a0)
	})
	defer SetSyscallHookForTest(prev)
	if got, err := AudioVolume(AudioVolumeMax); err != nil || got != AudioVolumeMax {
		t.Fatalf("AudioVolume(AudioVolumeMax) = %d, %v want %d, nil", got, err, AudioVolumeMax)
	}
}

// A negative volume is out of range by construction. It is passed through as
// its two's-complement value — which the kernel refuses as out-of-range —
// rather than being rejected, clamped or silently converted here: one refusal
// path, in the kernel, is easier to reason about than two.
func TestAudioVolumeNegativePassedThrough(t *testing.T) {
	var gotArg uintptr
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotArg = a0
		return -ErrEINVAL
	})
	defer SetSyscallHookForTest(prev)

	if _, err := AudioVolume(-1); err != errno(ErrEINVAL) {
		t.Fatalf("AudioVolume(-1) err = %v want EINVAL", err)
	}
	if gotArg != ^uintptr(0) {
		t.Fatalf("AudioVolume(-1) sent %#x want the two's-complement value %#x", gotArg, ^uintptr(0))
	}
}

// AudioMute marshals exactly 1/0 — never another int — and surfaces the
// kernel's refusal. Nothing else about a bool needs proving; the point is that
// the wire carries the kernel's two states and no third.
func TestAudioMuteMapping(t *testing.T) {
	cases := []struct {
		name string
		arg  bool
		want uintptr
	}{
		{"muted", true, 1},
		{"unmuted", false, 0},
	}
	for _, c := range cases {
		// A subtest per case so the hook is restored by defer even when an
		// assertion fails: an inline restore leaks the fake kernel into every
		// later case in the file, which turns one failure into a confusing
		// cascade.
		t.Run(c.name, func(t *testing.T) {
			var gotNum, gotArg uintptr
			calls := 0
			prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
				calls++
				gotNum, gotArg = num, a0
				return 0 // slot 45 returns 0 on success
			})
			defer SetSyscallHookForTest(prev)

			if err := AudioMute(c.arg); err != nil {
				t.Fatalf("AudioMute err = %v want nil", err)
			}
			if calls != 1 || gotNum != SlotAudioMute {
				t.Fatalf("called slot %d %d times want %d once", gotNum, calls, SlotAudioMute)
			}
			if gotArg != c.want {
				t.Fatalf("slot 45 arg = %d want %d", gotArg, c.want)
			}
		})
	}

	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return -ErrEINVAL
	})
	defer SetSyscallHookForTest(prev)
	if err := AudioMute(true); err != errno(ErrEINVAL) {
		t.Fatalf("refused AudioMute err = %v want EINVAL", err)
	}
}

// M99b: the mixer ABI's wire structs mirror kernel/src/virtio_snd.zig's
// StreamParams (8 bytes) and StreamStatus (104 bytes). Same pin argument as
// AudioInfo: the kernel copies exactly @sizeOf bytes through uaccess, so a
// drifted Go struct silently reads/writes past the contract.
func TestAudioStreamParamsWireSize(t *testing.T) {
	if got := unsafe.Sizeof(AudioStreamParams{}); got != 8 {
		t.Fatalf("AudioStreamParams size = %d want 8", got)
	}
	offsets := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"Format", unsafe.Offsetof(AudioStreamParams{}.Format), 0},
		{"Rate", unsafe.Offsetof(AudioStreamParams{}.Rate), 1},
		{"Channels", unsafe.Offsetof(AudioStreamParams{}.Channels), 2},
		{"Reserved", unsafe.Offsetof(AudioStreamParams{}.Reserved), 3},
		{"Version", unsafe.Offsetof(AudioStreamParams{}.Version), 4},
	}
	for _, o := range offsets {
		if o.got != o.want {
			t.Fatalf("AudioStreamParams.%s offset = %d want %d", o.name, o.got, o.want)
		}
	}
}

func TestAudioStreamStatusWireSize(t *testing.T) {
	if got := unsafe.Sizeof(AudioStreamStatus{}); got != 104 {
		t.Fatalf("AudioStreamStatus size = %d want 104", got)
	}
	offsets := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"Generation", unsafe.Offsetof(AudioStreamStatus{}.Generation), 0},
		{"Accepted", unsafe.Offsetof(AudioStreamStatus{}.Accepted), 8},
		{"Submitted", unsafe.Offsetof(AudioStreamStatus{}.Submitted), 16},
		{"Completed", unsafe.Offsetof(AudioStreamStatus{}.Completed), 24},
		{"Canceled", unsafe.Offsetof(AudioStreamStatus{}.Canceled), 32},
		{"Underruns", unsafe.Offsetof(AudioStreamStatus{}.Underruns), 40},
		{"Clipped", unsafe.Offsetof(AudioStreamStatus{}.Clipped), 48},
		{"State", unsafe.Offsetof(AudioStreamStatus{}.State), 56},
		{"Reason", unsafe.Offsetof(AudioStreamStatus{}.Reason), 60},
		{"Outstanding", unsafe.Offsetof(AudioStreamStatus{}.Outstanding), 64},
		{"Slots", unsafe.Offsetof(AudioStreamStatus{}.Slots), 68},
		{"Sources", unsafe.Offsetof(AudioStreamStatus{}.Sources), 72},
		{"PeakSources", unsafe.Offsetof(AudioStreamStatus{}.PeakSources), 76},
		{"Refused", unsafe.Offsetof(AudioStreamStatus{}.Refused), 80},
		{"Starts", unsafe.Offsetof(AudioStreamStatus{}.Starts), 84},
		{"Stops", unsafe.Offsetof(AudioStreamStatus{}.Stops), 88},
		{"Releases", unsafe.Offsetof(AudioStreamStatus{}.Releases), 92},
		{"Resets", unsafe.Offsetof(AudioStreamStatus{}.Resets), 96},
	}
	for _, o := range offsets {
		if o.got != o.want {
			t.Fatalf("AudioStreamStatus.%s offset = %d want %d", o.name, o.got, o.want)
		}
	}
}

// The mixer op numbers are the kernel's StreamOp enum (slot 43's a2). Same
// argument as TestAudioSlotNumbers: a wrong op looks identical on the host.
func TestAudioStreamOpNumbers(t *testing.T) {
	ops := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"open", audioStreamOpen, 1},
		{"submit", audioStreamSubmit, 2},
		{"start", audioStreamStart, 3},
		{"end", audioStreamEnd, 4},
		{"abort", audioStreamAbort, 5},
		{"status", audioStreamStatus, 6},
	}
	for _, o := range ops {
		if o.got != o.want {
			t.Fatalf("%s op = %d want %d", o.name, o.got, o.want)
		}
	}
	if AudioStreamMaxSources != 4 || AudioStreamPeriodsPerSource != 4 {
		t.Fatalf("mixer bounds drifted: sources=%d periods=%d want 4,4",
			AudioStreamMaxSources, AudioStreamPeriodsPerSource)
	}
	if ErrAudioStreamFull != errno(ErrENOSPC) || ErrAudioBusy != errno(ErrEAGAIN) {
		t.Fatalf("typed errors drifted: full=%v busy=%v", ErrAudioStreamFull, ErrAudioBusy)
	}
}

// Open sends exactly one slot-43 call with the params pointer, flag|8 length,
// op 1 and a zero generation; the kernel's positive answer is the generation
// the stream carries into every later call.
func TestAudioStreamOpenWire(t *testing.T) {
	var gotNum, gotLen, gotOp, gotGen uintptr
	var params AudioStreamParams
	gotParams := params
	gotParams.Format, gotParams.Rate, gotParams.Channels, gotParams.Version = AudioFmtFloat, 7, 2, 1
	var gotParamBytes [8]byte
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotNum, gotLen, gotOp, gotGen = num, a1, a2, a3
		copy(gotParamBytes[:], unsafe.Slice((*byte)(unsafe.Pointer(a0)), 8))
		return 41 // the kernel's seat generation
	})
	defer SetSyscallHookForTest(prev)

	s, err := AudioStreamOpen(gotParams)
	if err != nil {
		t.Fatalf("AudioStreamOpen err = %v want nil", err)
	}
	if gotNum != SlotAudioPlay || gotOp != audioStreamOpen || gotGen != 0 {
		t.Fatalf("open call = slot %d op %d gen %d want 43/1/0", gotNum, gotOp, gotGen)
	}
	if gotLen != audioStreamFlag|8 {
		t.Fatalf("open len arg = %#x want flag|8", gotLen)
	}
	var sent AudioStreamParams
	copy(unsafe.Slice((*byte)(unsafe.Pointer(&sent)), 8), gotParamBytes[:])
	if sent != gotParams {
		t.Fatalf("params on the wire = %+v want %+v", sent, gotParams)
	}
	if s.Generation() != 41 {
		t.Fatalf("stream generation = %d want 41", s.Generation())
	}
}

// Every seat occupied is the kernel's ENOSPC — the binding surfaces it as the
// typed ErrAudioStreamFull, and a mid-teardown window as ErrAudioBusy.
func TestAudioStreamOpenRefusals(t *testing.T) {
	for _, c := range []struct {
		name string
		kern int64
		want error
	}{
		{"seats full", -ErrENOSPC, ErrAudioStreamFull},
		{"teardown busy", -ErrEAGAIN, ErrAudioBusy},
		{"no device", -ErrENXIO, ErrNoAudioDevice},
		{"tuple mismatch", -ErrEINVAL, errno(ErrEINVAL)},
	} {
		t.Run(c.name, func(t *testing.T) {
			prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
				return c.kern
			})
			defer SetSyscallHookForTest(prev)
			s, err := AudioStreamOpen(AudioStreamParams{Version: 1})
			if s != nil || err != c.want {
				t.Fatalf("AudioStreamOpen = %v, %v want nil, %v", s, err, c.want)
			}
		})
	}
}

// Submit is one call per period: the buffer pointer, flag|len, op 2, and the
// seat's generation in a3. A full queue is EAGAIN → ErrAudioBusy.
func TestAudioStreamSubmitWire(t *testing.T) {
	s := &AudioStream{generation: 9}
	period := make([]byte, AudioPeriodBytes)
	var gotOp, gotGen uintptr
	var gotLen uintptr
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotAudioPlay || a0 != uintptr(unsafe.Pointer(&period[0])) {
			t.Fatalf("submit call = slot %d ptr %#x want 43/%#x", num, a0, &period[0])
		}
		gotLen, gotOp, gotGen = a1, a2, a3
		return int64(len(period))
	})
	defer SetSyscallHookForTest(prev)

	n, err := s.Submit(period)
	if n != AudioPeriodBytes || err != nil {
		t.Fatalf("Submit = %d, %v want %d, nil", n, err, AudioPeriodBytes)
	}
	if gotLen != audioStreamFlag|AudioPeriodBytes || gotOp != audioStreamSubmit || gotGen != 9 {
		t.Fatalf("submit args = len %#x op %d gen %d", gotLen, gotOp, gotGen)
	}
}

func TestAudioStreamSubmitRefusals(t *testing.T) {
	s := &AudioStream{generation: 9}
	period := make([]byte, AudioPeriodBytes)
	for _, c := range []struct {
		name string
		kern int64
		want error
	}{
		{"queue full", -ErrEAGAIN, ErrAudioBusy},
		{"bad pointer", -ErrEFAULT, errno(ErrEFAULT)},
		{"seat gone", -ErrEINVAL, errno(ErrEINVAL)},
	} {
		t.Run(c.name, func(t *testing.T) {
			prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
				return c.kern
			})
			defer SetSyscallHookForTest(prev)
			n, err := s.Submit(period)
			if n != 0 || err != c.want {
				t.Fatalf("Submit = %d, %v want 0, %v", n, err, c.want)
			}
		})
	}
}

// Bounds checked without a syscall at all: an empty period is EINVAL, an
// over-period submit is ENAMETOOLONG — both decided here, matching the
// kernel's answers (it would refuse the same way, so no behavior is hidden).
func TestAudioStreamSubmitBounds(t *testing.T) {
	calls := 0
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		calls++
		return 0
	})
	defer SetSyscallHookForTest(prev)
	s := &AudioStream{generation: 9}
	if n, err := s.Submit(nil); n != 0 || err != errno(ErrEINVAL) {
		t.Fatalf("Submit(empty) = %d, %v want 0, EINVAL", n, err)
	}
	if n, err := s.Submit(make([]byte, AudioPeriodBytes+1)); n != 0 || err != errno(ErrENAMETOOLONG) {
		t.Fatalf("Submit(over) = %d, %v want 0, ENAMETOOLONG", n, err)
	}
	if calls != 0 {
		t.Fatalf("bounds sent %d syscalls want 0", calls)
	}
}

// Start/End/Abort are one shape: no pointer, no payload length — op and the
// generation only. Any payload bytes are the kernel's EINVAL.
func TestAudioStreamLifecycleWire(t *testing.T) {
	for _, c := range []struct {
		name string
		call func(*AudioStream) error
		op   uintptr
	}{
		{"start", (*AudioStream).Start, audioStreamStart},
		{"end", (*AudioStream).End, audioStreamEnd},
		{"abort", (*AudioStream).Abort, audioStreamAbort},
	} {
		t.Run(c.name, func(t *testing.T) {
			s := &AudioStream{generation: 33}
			var gotA0, gotLen, gotOp, gotGen uintptr
			prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
				gotA0, gotLen, gotOp, gotGen = a0, a1, a2, a3
				if num != SlotAudioPlay {
					t.Fatalf("%s called slot %d want %d", c.name, num, SlotAudioPlay)
				}
				return 0
			})
			defer SetSyscallHookForTest(prev)
			if err := c.call(s); err != nil {
				t.Fatalf("%s err = %v want nil", c.name, err)
			}
			if gotA0 != 0 || gotLen != audioStreamFlag || gotOp != c.op || gotGen != 33 {
				t.Fatalf("%s args = ptr %#x len %#x op %d gen %d", c.name, gotA0, gotLen, gotOp, gotGen)
			}
		})
	}
}

// Status sends op 6 with the out pointer and flag|104, and returns the
// kernel's struct verbatim — including after the seat is gone, which is what
// makes the post-close snapshot observable from Go.
func TestAudioStreamStatusWire(t *testing.T) {
	s := &AudioStream{generation: 7}
	want := AudioStreamStatus{Generation: 7, Accepted: 8192, Completed: 8192, Slots: 4, Sources: 2}
	var gotLen, gotOp, gotGen uintptr
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		gotLen, gotOp, gotGen = a1, a2, a3
		dst := (*AudioStreamStatus)(unsafe.Pointer(a0))
		*dst = want
		return 0
	})
	defer SetSyscallHookForTest(prev)
	got, err := s.Status()
	if err != nil {
		t.Fatalf("Status err = %v want nil", err)
	}
	if gotLen != audioStreamFlag|104 || gotOp != audioStreamStatus || gotGen != 7 {
		t.Fatalf("status args = len %#x op %d gen %d", gotLen, gotOp, gotGen)
	}
	if got != want {
		t.Fatalf("Status = %+v want %+v", got, want)
	}
}

// A kernel answer short of the submitted length is a device-level refusal,
// same convention as AudioPlay's — never a silent partial accept.
func TestAudioStreamSubmitShortCount(t *testing.T) {
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		return 2048 // half a period
	})
	defer SetSyscallHookForTest(prev)
	s := &AudioStream{generation: 9}
	n, err := s.Submit(make([]byte, AudioPeriodBytes))
	if n != 2048 || err != ErrNoAudioDevice {
		t.Fatalf("Submit short = %d, %v want 2048, ENXIO", n, err)
	}
}

// Host: every raw call is -ENOSYS; the stream API must degrade like the rest
// of the seam — no panic, no fabricated seat.
func TestAudioStreamHostFails(t *testing.T) {
	if s, err := AudioStreamOpen(AudioStreamParams{Version: 1}); s != nil || err != errno(ErrENOSYS) {
		t.Fatalf("host AudioStreamOpen = %v, %v want nil, ENOSYS", s, err)
	}
	s := &AudioStream{generation: 1}
	if n, err := s.Submit(make([]byte, AudioPeriodBytes)); n != 0 || err != errno(ErrENOSYS) {
		t.Fatalf("host Submit = %d, %v want 0, ENOSYS", n, err)
	}
	if err := s.Start(); err != errno(ErrENOSYS) {
		t.Fatalf("host Start err = %v want ENOSYS", err)
	}
	if err := s.End(); err != errno(ErrENOSYS) {
		t.Fatalf("host End err = %v want ENOSYS", err)
	}
	if err := s.Abort(); err != errno(ErrENOSYS) {
		t.Fatalf("host Abort err = %v want ENOSYS", err)
	}
	if _, err := s.Status(); err != errno(ErrENOSYS) {
		t.Fatalf("host Status err = %v want ENOSYS", err)
	}
}

// Host: the two new rows degrade exactly like the rest of the seam (no hook,
// so the raw gateway answers -ENOSYS) — an app that runs the host suite must
// not see a panic or a fabricated success.
func TestAudioVolumeMuteHostFails(t *testing.T) {
	if n, err := AudioVolume(50); n != 0 || err != errno(ErrENOSYS) {
		t.Fatalf("host AudioVolume = %d, %v want 0, ENOSYS", n, err)
	}
	if err := AudioMute(true); err != errno(ErrENOSYS) {
		t.Fatalf("host AudioMute = %v want ENOSYS", err)
	}
}

// M118c (#2481): the capture seam — slots 91/92.

// The AudioCapInfo wire layout is the kernel's (kernel/src/virtio_snd.zig
// AudioCapInfo, 16 bytes — the slot-42 shape for the RX direction).
func TestAudioCapInfoWireSize(t *testing.T) {
	if got := unsafe.Sizeof(AudioCapInfo{}); got != 16 {
		t.Fatalf("AudioCapInfo size = %d want 16", got)
	}
	offsets := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"Ready", unsafe.Offsetof(AudioCapInfo{}.Ready), 0},
		{"Format", unsafe.Offsetof(AudioCapInfo{}.Format), 4},
		{"Rate", unsafe.Offsetof(AudioCapInfo{}.Rate), 5},
		{"Channels", unsafe.Offsetof(AudioCapInfo{}.Channels), 6},
		{"Padding", unsafe.Offsetof(AudioCapInfo{}.Padding), 7},
		{"PeriodBytes", unsafe.Offsetof(AudioCapInfo{}.PeriodBytes), 8},
		{"RingBytes", unsafe.Offsetof(AudioCapInfo{}.RingBytes), 12},
	}
	for _, o := range offsets {
		if o.got != o.want {
			t.Fatalf("AudioCapInfo.%s offset = %d want %d", o.name, o.got, o.want)
		}
	}
}

// The v1 tuple constants are the kernel's cap_* values (virtio_snd.zig):
// fmt 5 = FMT_S16, rate 7 = RATE_48000, ch 1 = mono. The ring is the
// per-call byte bound.
func TestAudioCapGeometry(t *testing.T) {
	if AudioCapFormat != 5 || AudioCapRate != 7 || AudioCapChannels != 1 {
		t.Fatalf("v1 tuple drifted: fmt=%d rate=%d ch=%d",
			AudioCapFormat, AudioCapRate, AudioCapChannels)
	}
	if AudioCapPeriodBytes != 2048 {
		t.Fatalf("AudioCapPeriodBytes = %d want 2048 (virtio_snd.cap_period_bytes)", AudioCapPeriodBytes)
	}
	if AudioCapRingBytes != 64*1024 {
		t.Fatalf("AudioCapRingBytes = %d want 65536 (virtio_snd.cap_ring_bytes)", AudioCapRingBytes)
	}
	if SlotAudioRecInfo != 91 || SlotAudioRec != 92 {
		t.Fatalf("capture slot numbers drifted: %d %d want 91 92", SlotAudioRecInfo, SlotAudioRec)
	}
	if ErrAudioCaptureTimeout != errno(ErrETIMEDOUT) {
		t.Fatalf("ErrAudioCaptureTimeout = %v want errno(ETIMEDOUT)", ErrAudioCaptureTimeout)
	}
}

// Slot 91 marshals the out pointer and returns the kernel's struct as-is.
func TestAudioCapQueryWire(t *testing.T) {
	var got [5]uintptr
	prev := SetSyscallHookForTest(func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		got = [5]uintptr{num, a0, a1, a2, a3}
		return -ErrENOSYS
	})
	defer SetSyscallHookForTest(prev)
	if _, err := AudioCapQuery(); err != errno(ErrENOSYS) {
		t.Fatalf("AudioCapQuery err = %v want ENOSYS", err)
	}
	if got[0] != SlotAudioRecInfo || got[1] == 0 || got[2] != 0 {
		t.Fatalf("slot 91 args = %v want (91, &out, 0, …)", got)
	}
}

// Slot 92 must SEND the tuple and length unchanged — an over-cap tuple is
// the kernel's EINVAL to answer, not ours to clamp (the same property
// TestAudioVolumeNoClamp pins on slot 44). And a fake kernel's refusal
// codes must pass through by value.
func TestAudioCaptureWire(t *testing.T) {
	var got [7]uintptr
	prev := SetSyscallHook6ForTest(func(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 {
		got = [7]uintptr{num, a0, a1, a2, a3, a4, a5}
		return -ErrEINVAL // the kernel's named over-cap refusal
	})
	defer SetSyscallHook6ForTest(prev)
	buf := make([]byte, 4096)
	n, err := AudioCapture(AudioFmtFloat, AudioCapRate, AudioCapChannels, buf)
	if got[0] != SlotAudioRec || got[1] != uintptr(AudioFmtFloat) ||
		got[2] != uintptr(AudioCapRate) || got[3] != uintptr(AudioCapChannels) ||
		got[4] != uintptr(unsafe.Pointer(&buf[0])) || got[5] != uintptr(len(buf)) {
		t.Fatalf("slot 92 args = %v want (92, fmt, rate, ch, &buf, len)", got)
	}
	if n != 0 || err != errno(ErrEINVAL) {
		t.Fatalf("over-cap capture = %d, %v want 0, EINVAL passed through", n, err)
	}
}

// The bounded-read shape: the kernel's byte count is the receipt — a short
// or over answer passes through untouched, and every named refusal maps to
// its errno row.
func TestAudioCaptureReceipt(t *testing.T) {
	prev := SetSyscallHook6ForTest(func(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 {
		return int64(a4) // echo the length: a complete capture
	})
	buf := make([]byte, 8192)
	n, err := AudioCapture(AudioCapFormat, AudioCapRate, AudioCapChannels, buf)
	if n != len(buf) || err != nil {
		t.Fatalf("capture = %d, %v want %d, nil", n, err, len(buf))
	}
	SetSyscallHook6ForTest(func(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 {
		return -ErrENXIO
	})
	if _, err = AudioCapture(AudioCapFormat, AudioCapRate, AudioCapChannels, buf); err != ErrNoAudioDevice {
		t.Fatalf("device-absent capture err = %v want ErrNoAudioDevice", err)
	}
	SetSyscallHook6ForTest(func(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 {
		return -ErrETIMEDOUT
	})
	if _, err = AudioCapture(AudioCapFormat, AudioCapRate, AudioCapChannels, buf); err != ErrAudioCaptureTimeout {
		t.Fatalf("drain-timeout capture err = %v want ErrAudioCaptureTimeout", err)
	}
	SetSyscallHook6ForTest(prev)

	// An empty buffer is a no-op like AudioPlay — no syscall at all.
	calls := 0
	prev2 := SetSyscallHook6ForTest(func(num uintptr, a0, a1, a2, a3, a4, a5 uintptr) int64 {
		calls++
		return 0
	})
	defer SetSyscallHook6ForTest(prev2)
	if n, err = AudioCapture(AudioCapFormat, AudioCapRate, AudioCapChannels, nil); n != 0 || err != nil || calls != 0 {
		t.Fatalf("empty capture = %d, %v over %d calls, want 0, nil, 0", n, err, calls)
	}
}
