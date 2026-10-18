package vi

import "unsafe"

// M58e (issue #1328): the EL0 audio seam — ADR 0007 slots 42/43, the Go half
// of what user/src/jingle.zig and user/src/chime.zig do in Zig. The kernel
// side has been frozen since M15; this file adds no syscall, it marshals.
//
// AudioInfo is slot 42's out struct: 16 bytes, little-endian, the kernel's
// field order and widths (kernel/src/virtio_snd.zig `AudioInfo`, mirrored by
// tests/virelai.h struct v_audio_info and docs/wasm-import-contract.md §5.3):
//
//	 0  ready        u32  transport + stream armed (0 = no device, not negotiated)
//	 4  format       u8   negotiated FMT_* (AudioFmtNone when there is no device)
//	 5  rate         u8   negotiated RATE_*
//	 6  channels     u8
//	 7  padding      u8
//	 8  period_bytes u32  the TX period the kernel submits (4096 on the device VZ reports)
//	12  max_len      u32  the slot-43 length bound (64 KiB)
//
// 16 bytes, not 24: the M15 card text said "24-byte AudioInfo", ADR 0007's
// slot-42 row and the kernel handler's comment both copied that, but the
// struct has been 16 bytes since it landed (asserted there by @sizeOf and in
// the frozen WAT contract). The stale comments are corrected with this card.
// TestAudioInfoWireSize pins the layout, because a struct that claims 24 bytes
// here would marshal 8 bytes of whatever follows the kernel's copy_out.
//
// A soundless VM (the default VM, no `--sound`) is NOT an error at slot 42:
// the kernel runs its first-call probe, fails to negotiate, and reports
// ready=0 with format/rate = 0xff. Slot 43 is where the honest refusal
// surfaces — ENXIO, the typed ErrNoAudioDevice — and that is what an app
// reports ("documented, not a failure" in the card's words).
//
// All four slots go through the HOOKABLE gateway (svc1/svc2 in vi.go) rather
// than the raw assembly, the same seam M66a (#1443) opened for the file
// surface. That is what lets a host test pin what this binding SENDS, not just
// what it returns: in particular that an out-of-range volume is handed to the
// kernel to refuse rather than quietly clamped here.
//
// M70f2 (#1476) adds slots 44/45 to this file, so the audio seam stays one
// place: 42/43 were already here and FART.ELF imports it. Splitting the four
// rows across `vi` and `vsys` would make one subsystem span two packages.

// AudioInfo is the 16-byte negotiated playback state (slot 42's out struct).
type AudioInfo struct {
	Ready       uint32 // transport + stream armed
	Format      uint8  // negotiated FMT_*; AudioFmtNone when there is no device
	Rate        uint8  // negotiated RATE_*
	Channels    uint8  //
	Padding     uint8  // wire padding (the kernel writes 0)
	PeriodBytes uint32 // the TX period sys_audio_play submits at once
	MaxLen      uint32 // the sys_audio_play length bound (AudioMaxLen)
}

// virtio-snd PCM format codes the kernel negotiates (FMT_*,
// kernel/src/virtio_snd.zig). The device VZ reports advertises S16|S32|FLOAT
// and negotiates FLOAT; an app must synthesize in whatever came back.
const (
	AudioFmtS16   uint8 = 5
	AudioFmtS32   uint8 = 17
	AudioFmtFloat uint8 = 19
	AudioFmtNone  uint8 = 0xff // the kernel's "nothing negotiated" sentinel
)

// The slot-43 geometry: one device period per syscall, and the kernel's own
// per-call bound. AudioPeriodBytes ≤ AudioMaxLen by construction, so splitting
// at the period can never trip the bound.
const (
	AudioPeriodBytes = 4096      // virtio_snd.beep_period_bytes (AudioInfo.PeriodBytes)
	AudioMaxLen      = 64 * 1024 // virtio_snd.audio_max_len
)

// AudioVolumeMax is the kernel's gain bound: slot 44 accepts 0..100 inclusive
// (virtio_snd's audio_volume, ADR 0007 row 44). It is exported so an app's
// marker, the spec's assertion and this binding all state the same number
// instead of three copies of 100.
const AudioVolumeMax = 100

// ErrNoAudioDevice is the kernel's ENXIO: no sound device is attached (the
// default VM without `--sound`), or the device refused a submission. Slot 42
// cannot report it (a soundless device is a successful call with Ready == 0);
// slot 43 is where it arrives. Compare with == or errors.Is.
var ErrNoAudioDevice = errno(ErrENXIO)

// AudioQuery reads the device's negotiated playback state (slot 42).
//
// The FIRST call drives the kernel's probe + SET_PARAMS negotiation, so after
// it returns an app knows exactly what to synthesize (format/frame and rate);
// later calls report the cached state. A soundless VM still succeeds, with
// Ready == 0 and Format == AudioFmtNone — the absence of a device is not an
// error here, it is what the state says. Off the guest, or for a kernel
// refusal (EINVAL for a non-process caller), the error is the kernel's code.
func AudioQuery() (AudioInfo, error) {
	var out AudioInfo
	r := svc1(SlotAudioInfo, uintptr(unsafe.Pointer(&out)))
	if r < 0 {
		return AudioInfo{}, errno(-r)
	}
	return out, nil
}

// AudioPlay plays pcm — format, rate and channels exactly as AudioQuery
// reported them — through slot 43, and returns the total bytes the kernel
// confirmed played.
//
// The buffer is submitted in AudioPeriodBytes pieces, one device period per
// syscall. Two things fall out of that, both load-bearing: no single call can
// exceed the kernel's AudioMaxLen bound (so a buffer of ANY length is legal —
// a 200 KiB blip is 52 legal 4 KiB calls, and the unchunked call would have
// been refused with ENAMETOOLONG), and the accounting is per period, so a
// failure names how much sound was already confirmed. Chunking allocates
// nothing: the chunks are sub-slices of pcm.
//
// A mid-buffer failure returns the bytes confirmed so far alongside the error,
// so a caller can never over-claim what played. A submission the kernel
// answers with FEWER bytes than it was handed is a device-level refusal
// (ErrNoAudioDevice), not data loss to ignore. An empty buffer is a no-op:
// (0, nil) — the kernel's own EINVAL for a zero length never fires.
func AudioPlay(pcm []byte) (int, error) {
	return audioChunks(len(pcm), func(off, end int) (int, error) {
		return audioPlayPeriod(pcm[off:end])
	})
}

// audioPlayPeriod is one slot-43 call for one period-sized chunk. len(chunk)
// is always ≥ 1: the chunker never calls it for an empty range.
func audioPlayPeriod(chunk []byte) (int, error) {
	r := svc2(SlotAudioPlay, uintptr(unsafe.Pointer(&chunk[0])), uintptr(len(chunk)))
	if r < 0 {
		return 0, errno(-r)
	}
	if int(r) != len(chunk) {
		return int(r), ErrNoAudioDevice
	}
	return int(r), nil
}

// AudioVolume sets the kernel-side stream gain (slot 44) and returns the
// volume the kernel echoed back.
//
// The gain applies at the TX submit choke point — the same knob `beep` and the
// boot chime share — so it changes what a LATER AudioPlay produces and never a
// period already submitted.
//
// Out-of-range is the KERNEL's refusal, not ours. ADR 0007 row 44 reads
// "`EINVAL` for a non-process caller or an out-of-range value (honest refusal,
// no silent clamping)", and this binding passes vol through unchanged so the
// caller sees that EINVAL. Clamping to AudioVolumeMax here would convert a
// caller's bug — or an attempt to overdrive a shared stream — into silent
// success, which is the exact behavior the row exists to prevent. A negative
// vol is passed as its two's-complement value: out of range by construction,
// and refused the same way.
func AudioVolume(vol int) (int, error) {
	r := svc1(SlotAudioVolume, uintptr(vol))
	if r < 0 {
		return 0, errno(-r)
	}
	return int(r), nil
}

// AudioMute sets the kernel-side mute state (slot 45): muted true zeroes every
// sample the TX path submits; false restores the gain the last AudioVolume
// set.
//
// Mute is NOT a stop. The stream lifecycle and the accounting are untouched,
// so a muted AudioPlay confirms the same byte count as an unmuted one and the
// samples still drain. That identity is the reason a Go consumer exists at all
// (the go-fart gate asserts it): "silent" must never become "short", because
// a short return is how this seam reports a device refusal
// (ErrNoAudioDevice) — a mute that shortened the return would be
// indistinguishable from a broken device.
//
// muted is marshalled as exactly 1 or 0; the kernel refuses anything else with
// EINVAL, and deciding what a third state would mean is not this binding's job
// (hence a bool in the signature rather than an int).
func AudioMute(muted bool) error {
	arg := uintptr(0)
	if muted {
		arg = 1
	}
	r := svc1(SlotAudioMute, arg)
	if r < 0 {
		return errno(-r)
	}
	return nil
}

// M99b (#2180, ADR 0046): slot 43 also carries an opt-in mixer stream ABI —
// the same syscall number, distinguished by the high bit of the length
// argument. Each OPEN takes a bounded source seat on the kernel mixer (up to
// AudioStreamMaxSources at once); all live sources share the one negotiated
// format/rate/channels and are summed in f32 into the single device stream,
// with slots 44/45 applied once to the composed output. AudioPlay (the
// legacy form, no high bit) refuses EAGAIN while any seat is open, and vice
// versa: one ABI, one physical stream, two mutually exclusive clients.
//
// AudioStream is the Go half of that ABI — what PCM.BIN's helpers do raw.
// A stream is a source token (owner = the calling process, generation =
// the kernel's seat generation): process death reaps the seat kernel-side,
// so there is no Close — End drains and frees, Abort frees without
// draining, and doing nothing is the owner-death path.

// AudioStreamParams is the 8-byte open argument (kernel StreamParams): the
// tuple the caller wants, which for a seat on an already-running stream
// must equal what AudioQuery reported — the mixer does not resample.
// Version is the ABI rev (1); Reserved must be 0.
type AudioStreamParams struct {
	Format   uint8
	Rate     uint8
	Channels uint8
	Reserved uint8
	Version  uint32
}

// AudioStreamStatus is the 104-byte per-source status (kernel StreamStatus).
// Accepted/Submitted/Completed/Canceled/Underruns count THIS source's bytes
// through the mix; Slots is its queue bound; Sources/PeakSources/Refused and
// Clipped are mixer-wide; Starts/Stops/Releases/Resets count the shared
// device stream's lifecycle. State is pcm.Model's numbering for the shared
// stream while the seat is open, the seat's post-close snapshot after.
type AudioStreamStatus struct {
	Generation  uint64
	Accepted    uint64
	Submitted   uint64
	Completed   uint64
	Canceled    uint64
	Underruns   uint64
	Clipped     uint64
	State       uint32
	Reason      uint32
	Outstanding uint32
	Slots       uint32
	Sources     uint32
	PeakSources uint32
	Refused     uint32
	Starts      uint32
	Stops       uint32
	Releases    uint32
	Resets      uint32
}

// The mixer ABI's bounds, exported for the same reason AudioPeriodBytes is:
// the guest gate and this binding state the kernel's numbers once.
const (
	AudioStreamMaxSources               = 4 // mixer source seats; the (N+1)th open is ENOSPC
	AudioStreamPeriodsPerSource         = 4 // queued periods per seat; full is EAGAIN
	audioStreamFlag             uintptr = 1 << 63
)

const (
	audioStreamOpen   uintptr = 1
	audioStreamSubmit uintptr = 2
	audioStreamStart  uintptr = 3
	audioStreamEnd    uintptr = 4
	audioStreamAbort  uintptr = 5
	audioStreamStatus uintptr = 6
)

// ErrAudioStreamFull is the kernel's ENOSPC from open: all
// AudioStreamMaxSources seats are occupied. Compare with == or errors.Is.
var ErrAudioStreamFull = errno(ErrENOSPC)

// ErrAudioBusy is the kernel's EAGAIN: a submit found the source's queue
// full, or a lifecycle op found the shared stream between phases (the
// documented backpressure answer — retry, don't tear down).
var ErrAudioBusy = errno(ErrEAGAIN)

// AudioStream is one mixer source seat: the kernel's (owner, generation)
// token for this process's stream. It is not safe for concurrent use.
type AudioStream struct {
	generation uint64
}

// AudioStreamOpen takes a mixer seat for this process (slot 43, op open).
// The first seat negotiates the physical stream's tuple with the device;
// later seats must match it exactly (EINVAL otherwise). All seats occupied
// is ErrAudioStreamFull; a stream mid-teardown retry window is ErrAudioBusy;
// no device is ErrNoAudioDevice. The returned generation identifies the seat
// in every later call.
func AudioStreamOpen(params AudioStreamParams) (*AudioStream, error) {
	r := svc4(SlotAudioPlay,
		uintptr(unsafe.Pointer(&params)),
		audioStreamFlag|uintptr(unsafe.Sizeof(params)),
		audioStreamOpen, 0)
	if r < 0 {
		return nil, errno(-r)
	}
	return &AudioStream{generation: uint64(r)}, nil
}

// Generation is the kernel's seat generation — the identity Status exposes
// too, here so a caller can correlate without a syscall.
func (s *AudioStream) Generation() uint64 {
	return s.generation
}

// Submit copies one period (≤ AudioPeriodBytes, frame-aligned) into the
// source's bounded queue and returns the bytes accepted. A full queue is
// ErrAudioBusy — backpressure, not an error the caller should act on beyond
// retrying. A kernel answer of fewer bytes than submitted would be a
// device-level refusal, reported as ErrNoAudioDevice like AudioPlay's.
func (s *AudioStream) Submit(period []byte) (int, error) {
	if len(period) == 0 {
		return 0, errno(ErrEINVAL)
	}
	if len(period) > AudioPeriodBytes {
		return 0, errno(ErrENAMETOOLONG)
	}
	r := svc4(SlotAudioPlay,
		uintptr(unsafe.Pointer(&period[0])),
		audioStreamFlag|uintptr(len(period)),
		audioStreamSubmit, uintptr(s.generation))
	if r < 0 {
		return 0, errno(-r)
	}
	if int(r) != len(period) {
		return int(r), ErrNoAudioDevice
	}
	return int(r), nil
}

// Start moves the seat from idle to live: its queue joins the mix (and the
// shared stream starts if this is the first source). A seat with an empty
// queue is EINVAL — submit before starting.
func (s *AudioStream) Start() error {
	return s.lifecycle(audioStreamStart)
}

// End frees the seat after its queued periods drain through the mix. When
// it is the last source, the shared stream drains, stops and releases.
func (s *AudioStream) End() error {
	return s.lifecycle(audioStreamEnd)
}

// Abort frees the seat immediately; queued-and-uncomposed bytes are
// canceled and counted, never played.
func (s *AudioStream) Abort() error {
	return s.lifecycle(audioStreamAbort)
}

func (s *AudioStream) lifecycle(op uintptr) error {
	r := svc4(SlotAudioPlay, 0, audioStreamFlag, op, uintptr(s.generation))
	if r < 0 {
		return errno(-r)
	}
	return nil
}

// Status reads the seat's counters (slot 43, op status). After End or Abort
// the seat is gone and the kernel answers with the post-close snapshot, so
// Status still works — the accounting survives the seat.
func (s *AudioStream) Status() (AudioStreamStatus, error) {
	var out AudioStreamStatus
	r := svc4(SlotAudioPlay,
		uintptr(unsafe.Pointer(&out)),
		audioStreamFlag|uintptr(unsafe.Sizeof(out)),
		audioStreamStatus, uintptr(s.generation))
	if r < 0 {
		return AudioStreamStatus{}, errno(-r)
	}
	return out, nil
}

// audioChunks splits n bytes into AudioPeriodBytes-sized [off,end) ranges and
// calls f for each. It is the AudioPlay loop as a pure function — no syscall,
// no allocation — so the host suite can pin the arithmetic the live gate's
// syscall count reflects. Returns the summed byte count and f's first error.
func audioChunks(n int, f func(off, end int) (int, error)) (int, error) {
	total := 0
	for off := 0; off < n; off += AudioPeriodBytes {
		end := off + AudioPeriodBytes
		if end > n {
			end = n
		}
		got, err := f(off, end)
		total += got
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// M118c (#2481, ADR 0007 amendment): the capture half of the audio seam —
// slots 91/92, the RX twins of 42/43. The kernel owns ONE capture stream
// capped at the v1 tuple (S16 / 48 kHz / mono) feeding a bounded 64 KiB
// ring; these bindings marshal that seam, they do not negotiate.

// AudioCapInfo is slot 91's out struct: 16 bytes, the kernel's
// field order and widths (kernel/src/virtio_snd.zig `AudioCapInfo`):
//
//	 0  ready        u32  RX queue armed AND stream 0 last observed INPUT
//	                     speaking the v1 tuple (0 = no usable capture source)
//	 4  format       u8   the v1 tuple when ready, AudioFmtNone when not
//	 5  rate         u8   (0xff when not ready)
//	 6  channels     u8   (0 when not ready)
//	 7  padding      u8
//	 8  period_bytes u32  one posted RX period (2048)
//	12  ring_bytes   u32  the bounded ring — also the per-call byte bound
//
// `ready` reports the LAST OBSERVED stream-0 topology — slot 91 runs no
// device exchange of its own (the rearm-time kernel self-test and every
// slot-92 call refresh the observation). A soundless VM or an output-only
// stream is a successful call with Ready == 0, the same honesty rule as
// slot 42: absence is not an error at the info seam.
type AudioCapInfo struct {
	Ready       uint32
	Format      uint8
	Rate        uint8
	Channels    uint8
	Padding     uint8
	PeriodBytes uint32
	RingBytes   uint32
}

// The v1 capture tuple — the ONLY tuple slot 92 accepts. Exported so the
// gate and this binding state the kernel's constants (cap_format /
// cap_rate / cap_channels in virtio_snd.zig) instead of three copies.
const (
	AudioCapFormat   uint8 = AudioFmtS16 // FMT_S16
	AudioCapRate     uint8 = 7           // RATE_48000
	AudioCapChannels uint8 = 1           // mono
)

// The slot-92 geometry: the posted RX period and the per-call byte bound
// (the ring's capacity — a call can never ask for more than the ring).
const (
	AudioCapPeriodBytes = 2048
	AudioCapRingBytes   = 64 * 1024
)

// ErrAudioCaptureTimeout is the kernel's ETIMEDOUT: the bounded RX drain
// expired before the request landed. On a host whose mic consent is
// denied the device completes nothing, so this is the honest answer —
// zero frames is a refusal, never a short read. Compare with == or
// errors.Is.
var ErrAudioCaptureTimeout = errno(ErrETIMEDOUT)

// AudioCapQuery reads the capture capability report (slot 91). It never
// fails on a healthy EL0 caller: a guest with no capture source gets
// Ready == 0, not an error.
func AudioCapQuery() (AudioCapInfo, error) {
	var out AudioCapInfo
	r := svc1(SlotAudioRecInfo, uintptr(unsafe.Pointer(&out)))
	if r < 0 {
		return AudioCapInfo{}, errno(-r)
	}
	return out, nil
}

// AudioCapture records len(buf) bytes (len(buf)/2 frames) at the
// requested tuple into buf and returns the bytes landed — len(buf) on a
// complete capture. The request is ONE bounded read: the kernel fills its
// ring from the RX queue and copies it out in bounded chunks.
//
// The refusals are the kernel's, passed through unchanged like
// AudioVolume's out-of-range EINVAL: an over-cap tuple is EINVAL (the
// named over-cap refusal — nothing is silently converted), a zero or
// non-frame-aligned length is EINVAL, over AudioCapRingBytes is
// ENAMETOOLONG, device-absent / unarmed RX / a non-INPUT stream 0 is
// ErrNoAudioDevice, an expired bounded drain is ErrAudioCaptureTimeout, a
// full ring is ENOSPC, and a device-level refusal is EIO.
//
// An empty buffer is a no-op: (0, nil) — the kernel's EINVAL for a zero
// length never fires, same rule as AudioPlay.
func AudioCapture(format, rate, channels uint8, buf []byte) (int, error) {
	if len(buf) == 0 {
		return 0, nil
	}
	r := svc6(SlotAudioRec, uintptr(format), uintptr(rate), uintptr(channels),
		uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0)
	if r < 0 {
		return 0, errno(-r)
	}
	return int(r), nil
}
