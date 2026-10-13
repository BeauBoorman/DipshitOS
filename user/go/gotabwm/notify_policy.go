// GOTABWM.ELF — M82d2 (issue #1785): the notifications center's POLICY half.
// M82d1 (#1771) built the center as an in-memory history; this file is what
// makes it a place rather than a flash. Two policies, both extending that one
// center (there is no second queue anywhere):
//
//   - Do-not-disturb. One settings key (`notify_dnd`, on|off — the GOSET row),
//     one seat control (the center's header toggle), one state (notifyDND).
//     While it is on, a NEW notice still lands in the center's history — that
//     is the whole point: suppression must never lose a notice — but it raises
//     no toast. The app cannot tell: the kind-12 ack is applied either way, so
//     an app never grows a "the user is away" code path. Toasts already on the
//     strip when DND turns on run out normally; only NEW notices are held.
//   - Persistence. The history survives a seat restart through the M66b path:
//     one file, published by temp + fsync + delete/rename (vi.WriteFileSafe),
//     so the live path only ever holds the old bytes, the new bytes, or none.
//     The bytes carry their own integrity (magic, count, length-framed
//     records, an FNV-1a trailer), because the promise on the read side is
//     stronger than "the write is atomic": a file that fails ANY check is
//     refused WHOLE — never a partial history — and heals to a valid empty
//     one, so a bad file costs the user their history once and is never
//     re-reported on the boot after.
//
// The write is coalesced to the composite tick. A notice is an app's to send
// at IPC speed, unlike a tab open or a user's click (session.go writes through
// on every mutation and says why that is fine there). One fsync'd publish per
// notice would put a stalled share on the seat's request path under a flood,
// which is exactly what the queue's drop-oldest bound exists to prevent. So a
// mutation only marks the history dirty; the next tick publishes ONCE however
// many changed, and a clean exit publishes the tail. A hard kill can lose the
// changes of the last tick, never corrupt the file.
//
// Restored entries name senders that no longer exist (window ids die with the
// seat's process), so every one is restored with its source LATCHED closed —
// the same latch M82d1 uses so a reused id can never turn a historical item
// into a link to an unrelated app.
package main

import (
	"unsafe"

	"virelai/settings"
	"virelai/vi"
)

const (
	// notifyHistoryPath is the persisted center history on the share.
	notifyHistoryPath = "/host/NOTIFY.HIST"

	// MarkerNotifyDND names a do-not-disturb transition and who asked for
	// it: `via=boot` (the persisted key, read at start — printed only when
	// it is ON, so a default boot's log is unchanged), `via=seat` (the
	// center's header control; carries `persisted=1|0`), `via=settings`
	// (GOSET's publish, applied live).
	MarkerNotifyDND = "gotabwm: notify dnd="
	// MarkerNotifyHeld replaces MarkerNotify for a notice DND kept off the
	// strip. `id=` is the SENDER's tab id, like every other notify marker.
	// The notice is in the center's history by the time this prints.
	MarkerNotifyHeld = "gotabwm: notify held id="
	// MarkerNotifyHistRestore is printed at seat start, before the loop and
	// therefore before the first composite paint, once a valid history file
	// was decoded into the center.
	MarkerNotifyHistRestore = "gotabwm: notify history restore n="
	// MarkerNotifyHistBad names a history file refused whole; the center
	// starts empty. MarkerNotifyHistHealed follows once the valid empty
	// replacement is published.
	MarkerNotifyHistBad    = "gotabwm: notify history bad"
	MarkerNotifyHistHealed = "gotabwm: notify history healed"
	// MarkerNotifyHistWrite is printed after a publish returned; the fail
	// marker prints once per failure streak, not once per retrying tick.
	MarkerNotifyHistWrite = "gotabwm: notify history write n="
	MarkerNotifyHistFail  = "gotabwm: notify history write fail"

	// Who asked for a do-not-disturb change (the marker's via= word).
	notifyViaBoot     = "boot"
	notifyViaSeat     = "seat"
	notifyViaSettings = "settings"
)

// notifyDND is the seat's do-not-disturb state. Off is the zero value and the
// compiled default, so a host test that never configures it is unaffected.
var notifyDND bool

// saveNotifyDND is the persistence seam for the seat control, a var so a host
// test can observe it: settings.Load/Save degrade to ENOSYS off the guest.
var saveNotifyDND = persistNotifyDND

// persistNotifyDND writes the choice into SETTINGS.TXT through the codec's
// crash-safe save, the same publish GOSET uses. A corrupt file is refused
// whole (settings.File.Save returns SaveRefused), exactly as it is for GOSET:
// the seat control must not launder a file the kernel rejected.
func persistNotifyDND(on bool) bool {
	f := settings.Load()
	if f.State == settings.StateCorrupt {
		return false
	}
	val := "off"
	if on {
		val = "on"
	}
	f.Rows = settings.Set(f.Rows, settings.NotifyDNDKey, val)
	f.State = settings.StateOK
	return f.Save() == 0
}

// configureNotifyDND applies the persisted notify policy at seat start: the
// sound path first (M99d — it probes the device and seeds its bus value
// whatever the file's state), then DND. Only an intact file can turn DND on:
// a corrupt file is refused whole (compiled default, off), and a value that
// is not exactly `on`/`off` is the default too, so a typo can never silence
// the user's notifications.
func configureNotifyDND(f settings.File) {
	configureNotifySound(f)
	notifyDND = false
	if f.State != settings.StateOK {
		return
	}
	value, _ := f.Effective(settings.NotifyDNDKey)
	on, _ := settings.NotifyDND(value)
	if on {
		setNotifyDND(true, notifyViaBoot)
	}
}

// setNotifyDND applies a do-not-disturb state and reports it. The state
// change comes first and the marker after, so the line can never claim a mode
// the seat is not in. A seat-originated change is persisted and offered to
// the settings bus (an app subscribed to the key through appkit hears it);
// the other two origins already have the file and the bus value.
func setNotifyDND(on bool, via string) {
	notifyDND = on
	word := "off"
	if on {
		word = "on"
	}
	line := MarkerNotifyDND + word + " via=" + via
	if via == notifyViaSeat {
		persisted := "0"
		if saveNotifyDND(on) {
			persisted = "1"
		}
		line += " persisted=" + persisted
		if updateSettingsBusValue(settings.NotifyDNDKey, word) {
			broadcastSettingsChange(settings.NotifyDNDKey)
		}
	}
	vi.ConsoleLine(line)
}

// toggleNotifyDND is the seat control: the center header's toggle.
func toggleNotifyDND() { setNotifyDND(!notifyDND, notifyViaSeat) }

// applyNotifyDNDSetting is the GOSET publish path (settings_bus.go): the
// value is already persisted and already recorded on the bus. A value that is
// not exactly on/off means the default, like the boot read.
func applyNotifyDNDSetting(value string) {
	on, _ := settings.NotifyDND(value)
	setNotifyDND(on, notifyViaSettings)
}

// --- the notification chime (M99d, #2182) -----------------------------------
//
// An accepted toast is also AUDIBLE: a short synthesized chime played through
// the M99b continuous stream (vi.AudioStream), never the legacy blocking
// playback — slot 43's plain form holds an IRQ-save spinlock through the
// whole drain, which on the seat's composite path would freeze the desktop
// for the length of every notice.
//
// The shape of it, and why the play can sit inside the kind-12 RPC handler
// at all:
//
//   - The chime is synthesized ONCE at seat start, for the tuple the device
//     negotiated (AudioQuery drives the kernel's first-call probe). Two
//     partials under an exponential decay, bounded at ~40 ms AND at the
//     source queue's whole prefill (AudioStreamPeriodsPerSource periods),
//     so the seat submits it all before starting and never feeds the stream
//     twice.
//   - A toast's play is open → submit(all) → start → end: one bounded
//     operation, no cross-tick feeding. The drain is confirmed on the next
//     composite tick (notifySoundTick); the seat never sleeps on it.
//   - Skips are counted, never retried: a busy mix (EAGAIN), all source
//     seats taken (ENOSPC), a device that vanished mid-run, or a chime
//     still draining — the seat keeps its tick either way.
//   - Policy: `notify_sound` (on|off, default on — the settings row), the
//     one-time device probe, and DND. A notice DND holds never reaches the
//     chime call at all.
const (
	// MarkerNotifySoundReady names the synthesized chime: printed once at
	// seat start after the device probe and the build both succeeded. The
	// negotiated tuple follows the byte count.
	MarkerNotifySoundReady = "gotabwm: notify-sound ready bytes="
	// MarkerNotifySoundOff is the boot marker for `notify_sound=off`: the
	// probe is skipped entirely — a sound policy fact, not a device one.
	MarkerNotifySoundOff = "gotabwm: notify-sound off"
	// MarkerNotifySoundNoDevice is the one-time verdict when AudioQuery
	// reports no usable device (or a tuple the synth cannot encode): the
	// path stays off and the seat never probes again — no per-toast ENXIO.
	MarkerNotifySoundNoDevice = "gotabwm: notify-sound unavailable"
	// MarkerNotifySoundPlayed confirms a chime drained through the mix;
	// printed on the composite tick AFTER the play, with the kernel's own
	// counters — `completed` can only match `bytes` when the device really
	// played them. Serial order: MarkerNotify before this line is
	// "accepted a toast, played its chime".
	MarkerNotifySoundPlayed = "gotabwm: notify-sound played bytes="
	// MarkerNotifySoundSkipped counts a chime that could not play — busy
	// mix, all seats taken, a vanished device, or one still draining.
	// Cumulative since boot, the MarkerNotifyDrop convention.
	MarkerNotifySoundSkipped = "gotabwm: notify-sound skipped total="
	// MarkerNotifySoundVolume names a persisted audio_volume row the seat
	// re-applied at start: slot 44 is kernel state that boots at 100, so
	// the stored choice needs a consumer to apply it — the seat, here,
	// echoing the gain the kernel reports back.
	MarkerNotifySoundVolume = "gotabwm: notify-sound volume="
)

var (
	// notifySoundChime is the synthesized PCM for the negotiated tuple;
	// nil while the sound path is off (notify_sound=off, no device, or a
	// tuple the synth refused). notifySoundParams is the tuple its open
	// must quote.
	notifySoundChime  []byte
	notifySoundParams vi.AudioStreamParams
	// notifySoundPending is the one chime in flight (submitted, started,
	// ended — drain pending). The seat tracks at most one: a toast that
	// arrives while it is set is a counted skip, which is what keeps a
	// flood of toasts from stacking unseen streams on the mixer.
	notifySoundPending *vi.AudioStream
	notifySoundBytes   int
	notifySoundSkipped int
)

// notifyPlayChime is the seam between "an accepted toast happened" and the
// stream work — a var so a host test can count plays without a device.
var notifyPlayChime = playNotifyChime

// configureNotifySound settles the whole sound path at seat start, in the
// order the card wants the device fact decided: persisted volume first
// (slot 44 works with or without a device), then notify_sound (off skips
// the probe entirely), then the one AudioQuery that drives the kernel's
// first-call negotiation, then the one synthesis. With no device the path
// simply stays off — one marker, and the seat never probes again.
func configureNotifySound(f settings.File) {
	// A persisted audio_volume row is the consumer-side half of the
	// volume control: the kernel's gain boots at 100 and never reads the
	// file, so the seat re-applies the stored choice — the same
	// seat-interprets-the-row contract idle_minutes already holds.
	if v, ok := settings.Get(f.Rows, settings.AudioVolumeKey); ok {
		if vol, ok := settings.AudioVolume(v); ok {
			if echo, err := settings.AudioVolumeApply(vol); err == nil {
				vi.ConsoleLine(MarkerNotifySoundVolume + vi.Itoa64(int64(echo)))
			}
		}
	}
	// Seed the settings-bus value for notify_sound here: the bus's own
	// seeding lives in settings_bus.go (outside this card), and an
	// unseeded key is one a GOSET publish can never reach — the publish
	// refuses an unknown key. Seeding it where the seat configures its
	// policy makes the live path whole: a publish updates the bus value,
	// and notifySoundOn reads it at push time.
	val, _ := f.Effective(settings.NotifySoundKey)
	seedNotifySoundBusValue(val)
	on, _ := settings.NotifySound(val)
	if !on {
		vi.ConsoleLine(MarkerNotifySoundOff)
		return
	}
	info, err := vi.AudioQuery()
	if err != nil || info.Ready == 0 || info.Format == vi.AudioFmtNone {
		vi.ConsoleLine(MarkerNotifySoundNoDevice)
		return
	}
	chime := synthNotifyChime(info)
	if len(chime) == 0 {
		vi.ConsoleLine(MarkerNotifySoundNoDevice)
		return
	}
	notifySoundChime = chime
	notifySoundParams = vi.AudioStreamParams{
		Format:   info.Format,
		Rate:     info.Rate,
		Channels: info.Channels,
		Version:  1,
	}
	vi.ConsoleLine(MarkerNotifySoundReady + vi.Itoa64(int64(len(chime))) +
		" fmt=" + vi.Itoa64(int64(info.Format)) +
		" rate=" + vi.Itoa64(int64(info.Rate)) +
		" ch=" + vi.Itoa64(int64(info.Channels)))
}

// seedNotifySoundBusValue puts notify_sound into the bus's value table the
// way seedSettingsBusValues puts the iterated keys — appended into the
// first free slot so a publish can find it (the table's contract: a key
// that is not there is a publish refused). Idempotent: the slot is found
// by name first, so a second configure updates rather than appends.
func seedNotifySoundBusValue(val string) {
	free := -1
	for i := range settingsBusValues {
		if settingsBusValues[i].key == settings.NotifySoundKey {
			settingsBusValues[i].value = val
			return
		}
		if settingsBusValues[i].key == "" {
			free = i
			break
		}
	}
	if free >= 0 {
		settingsBusValues[free] = settingValue{key: settings.NotifySoundKey, value: val}
	}
}

// notifySoundOn is the live read of the chime switch: the bus value, which
// the boot seed and every accepted publish keep current. An absent entry —
// a host test that never configured the bus — is the default, on; a value
// the file could not produce parses to the default through
// settings.NotifySound the same way.
func notifySoundOn() bool {
	for i := range settingsBusValues {
		e := &settingsBusValues[i]
		if e.key == "" {
			break
		}
		if e.key == settings.NotifySoundKey {
			if on, ok := settings.NotifySound(e.value); ok {
				return on
			}
			return true // not exactly on/off means the default: a typo never silences
		}
	}
	return true
}

// notifySoundSkip counts a refused or lost chime — the marker is the
// seat's honest answer to "the toast was there, where was the sound?".
func notifySoundSkip() {
	notifySoundSkipped++
	vi.ConsoleLine(MarkerNotifySoundSkipped + vi.Itoa64(int64(notifySoundSkipped)))
}

// playNotifyChime plays the synthesized chime through a fresh stream seat:
// open, prefill the whole buffer (it fits by construction), start, end —
// then hand the drain to the composite tick. The seat never feeds a period
// twice and never retries inside the handler: any refusal aborts the seat,
// counts a skip, and the toast still stands.
func playNotifyChime() {
	if len(notifySoundChime) == 0 || !notifySoundOn() {
		return
	}
	// Retire a finished chime first so its `played` marker lands before
	// any later `skipped` line it would otherwise overtake.
	notifySoundTick()
	if notifySoundPending != nil {
		notifySoundSkip()
		return
	}
	s, err := vi.AudioStreamOpen(notifySoundParams)
	if err != nil {
		notifySoundSkip()
		return
	}
	submitted := 0
	for submitted < len(notifySoundChime) {
		end := submitted + vi.AudioPeriodBytes
		if end > len(notifySoundChime) {
			end = len(notifySoundChime)
		}
		n, err := s.Submit(notifySoundChime[submitted:end])
		submitted += n
		if err != nil {
			break
		}
	}
	if submitted != len(notifySoundChime) {
		_ = s.Abort()
		notifySoundSkip()
		return
	}
	if err := s.Start(); err != nil {
		_ = s.Abort()
		notifySoundSkip()
		return
	}
	if err := s.End(); err != nil {
		_ = s.Abort()
		notifySoundSkip()
		return
	}
	notifySoundPending = s
	notifySoundBytes = submitted
}

// notifySoundTick retires the in-flight chime. The play call already did
// its bounded part (open, prefill, start, end); the drain is confirmed
// here, on the composite tick, so the `played` marker can never precede
// the kernel's own completed counter. A stream still draining just waits
// for the next tick — the seat never sleeps on audio.
func notifySoundTick() {
	s := notifySoundPending
	if s == nil {
		return
	}
	st, err := s.Status()
	if err != nil {
		// The seat's snapshot is gone with the drain unconfirmed — count
		// it like any other refusal so the marker stream stays honest.
		notifySoundPending = nil
		notifySoundSkip()
		return
	}
	if st.Completed < uint64(notifySoundBytes) {
		return
	}
	notifySoundPending = nil
	vi.ConsoleLine(MarkerNotifySoundPlayed + vi.Itoa64(int64(notifySoundBytes)) +
		" completed=" + vi.Itoa64(int64(st.Completed)))
}

// --- the chime's synthesis ----------------------------------------------------
//
// The same approach fart took for its sines (#1769): no `math`, so a host
// run and the guest build the same bytes; a range-reduced Taylor sine; the
// negotiated format written per sample with mono duplicated across the
// channels; and the honesty rule — a tuple the synth cannot encode returns
// nothing rather than a buffer of zeros.
const (
	notifyChimeMS   = 40     // target length; the prefill bound may shorten it
	notifyChimeF0   = 880.0  // A5, the fundamental
	notifyChimeF1   = 1320.0 // E6, the fifth above it
	notifyChimePart = 0.4    // the fifth's weight against the fundamental
	notifyChimeAmp  = 0.5    // peak after normalization
	notifyChimeTau  = 5.0    // decay constant: env = e^(-Tau·u) over the chime
)

// notifyChimeMaxBytes is the stream's whole prefill: one source queues at
// most AudioStreamPeriodsPerSource periods, and the chime must fit inside
// so the seat never feeds the stream after starting.
const notifyChimeMaxBytes = int(vi.AudioStreamPeriodsPerSource) * vi.AudioPeriodBytes

// synthNotifyChime builds the notification chime for the negotiated tuple.
// A device with no format, a rate off the ladder, or a channel count the
// frame math cannot carry gets an empty buffer — the caller reports the
// path unavailable rather than opening on silence.
func synthNotifyChime(info vi.AudioInfo) []byte {
	fb, ok := notifyFrameBytes(info.Format, info.Channels)
	hz := notifyRateHz(info.Rate)
	if !ok || hz == 0 {
		return nil
	}
	frames := notifyFramesFor(notifyChimeMS, hz)
	if max := notifyChimeMaxBytes / int(fb); frames > max {
		frames = max
	}
	if frames == 0 {
		return nil
	}
	pcm := make([]byte, frames*int(fb))
	sb := int(fb) / int(info.Channels)
	attack := int(hz) / 500 // ~2 ms ramp-in: a leading click is worse than a soft start
	if attack < 1 {
		attack = 1
	}
	for i := 0; i < frames; i++ {
		t := float64(i) / float64(hz)
		env := expDecay(notifyChimeTau * float64(i) / float64(frames))
		if i < attack {
			env *= float64(i+1) / float64(attack)
		}
		s := notifyChimeAmp * env *
			(sinApprox(twoPi*notifyChimeF0*t) + notifyChimePart*sinApprox(twoPi*notifyChimeF1*t)) /
			(1.0 + notifyChimePart)
		if s > 1 {
			s = 1
		} else if s < -1 {
			s = -1
		}
		for c := 0; c < int(info.Channels); c++ {
			at := i*int(fb) + c*sb
			switch info.Format {
			case vi.AudioFmtFloat:
				putF32(pcm[at:], float32(s))
			case vi.AudioFmtS16:
				putI16(pcm[at:], int16(s*32767))
			case vi.AudioFmtS32:
				putI32(pcm[at:], int32(s*2147483647))
			}
		}
	}
	return pcm
}

// notifyRateHz decodes the kernel's rate code (virtio_snd.h's RATE_* enum —
// discrete negotiated rungs, not arbitrary Hz). 0 is the un-decodable
// code: no synth, no play.
func notifyRateHz(rate uint8) uint32 {
	switch rate {
	case 1:
		return 8000
	case 3:
		return 16000
	case 4:
		return 22050
	case 5:
		return 32000
	case 6:
		return 44100
	case 7:
		return 48000
	}
	return 0
}

// notifyFrameBytes is the on-wire frame size for the negotiated tuple, or
// 0 when the format is not one the stream carries — U8 arrives as
// AudioFmtNone in practice, so a 0 here is the "no usable format" verdict.
func notifyFrameBytes(format uint8, channels uint8) (uint8, bool) {
	if channels == 0 {
		return 0, false
	}
	var sb uint8
	switch format {
	case vi.AudioFmtFloat:
		sb = 4
	case vi.AudioFmtS16:
		sb = 2
	case vi.AudioFmtS32:
		sb = 4
	default:
		return 0, false
	}
	return sb * channels, true
}

// notifyFramesFor is ms at hz, in whole frames.
func notifyFramesFor(ms, hz uint32) int {
	return int(uint64(hz) * uint64(ms) / 1000)
}

// expDecay is e^-x for x in [0, 16] — the chime's envelope, as deterministic
// as the sine: split e^-x into e^-n · e^-f with f in [0, 1), the integer
// part a repeated multiply by e^-1 and the fraction a Horner polynomial
// whose error stays under 1e-5. Beyond x=16 the envelope is ~-110 dB and
// the answer rounds to silence.
func expDecay(x float64) float64 {
	if x <= 0 {
		return 1
	}
	if x >= 16 {
		return 0
	}
	n := int(x)
	f := x - float64(n)
	v := 1.0
	for i := 0; i < n; i++ {
		v *= 0.36787944117144232159552377016146087 // e^-1
	}
	// e^-f = sum (-f)^k / k! through k=7, Horner order.
	p := -1.0 / 5040.0
	p = 1.0/720.0 + f*p
	p = -1.0/120.0 + f*p
	p = 1.0/24.0 + f*p
	p = -1.0/6.0 + f*p
	p = 1.0/2.0 + f*p
	p = -1.0 + f*p
	p = 1.0 + f*p
	return v * p
}

const pi = 3.14159265358979323846264338327950288

// twoPi is the angular circle fart uses for its sines.
const twoPi = 2 * pi

// sinApprox is sin over the reals — fart's degree-15 odd Taylor in Horner
// form, copied verbatim: absolute error < 1e-6 on the reduced range (below
// -120 dB), and unlike math.Sin byte-stable across Go releases, which is
// what keeps the guest's bytes and a host test's bytes identical.
func sinApprox(x float64) float64 {
	n := int64(x / twoPi)
	x -= float64(n) * twoPi
	if x > pi {
		x -= twoPi
	} else if x < -pi {
		x += twoPi
	}
	z := x * x
	// c0 + z(c1 + z(c2 + ... )), the x^(2k+1) coefficients of sin / x.
	p := -1.0 / 1307674368000.0 // x^15 (15!)
	p = 1.0/6227020800.0 + z*p  // x^13
	p = -1.0/39916800.0 + z*p   // x^11
	p = 1.0/362880.0 + z*p      // x^9
	p = -1.0/5040.0 + z*p       // x^7
	p = 1.0/120.0 + z*p         // x^5
	p = -1.0/6.0 + z*p          // x^3
	p = 1.0 + z*p               // x^1
	return x * p
}

// The PCM writers mirror fart's exactly: little-endian, the guest's wire
// order for every sample format the stream carries.
func putF32(b []byte, v float32) { putU32(b, *(*uint32)(unsafe.Pointer(&v))) }
func putU32(b []byte, v uint32) {
	b[0] = byte(v)
	b[1] = byte(v >> 8)
	b[2] = byte(v >> 16)
	b[3] = byte(v >> 24)
}
func putI16(b []byte, v int16) {
	u := uint16(v)
	b[0] = byte(u)
	b[1] = byte(u >> 8)
}
func putI32(b []byte, v int32) { putU32(b, uint32(v)) }

// --- the persisted history --------------------------------------------------

// The file: "VNH" + version 1, a count byte, that many records of
// (source length, text length, source, text), then the FNV-1a 32 of every
// byte before it, little-endian. Guest-safe by construction (no fmt, no os,
// no hash package), like the `.tabs` codec beside it.
const (
	notifyHistMagic    = "VNH\x01"
	notifyHistSrcMax   = 48 // the center's own display bound (centerText)
	notifyHistTextMax  = vi.WmRpcTitleMax
	notifyHistMaxBytes = len(notifyHistMagic) + 1 +
		NotifyCenterMax*(2+notifyHistSrcMax+notifyHistTextMax) + 4
)

func fnv32(b []byte) uint32 {
	h := uint32(2166136261)
	for _, c := range b {
		h ^= uint32(c)
		h *= 16777619
	}
	return h
}

func clampNotifyField(s string, max int) string {
	if len(s) > max {
		return s[:max]
	}
	return s
}

// encodeNotifyHistory serializes the newest NotifyCenterMax entries. Sender
// ids and the closed latch are not written: neither means anything to the
// next seat process (see the file comment).
func encodeNotifyHistory(h []centerNotification) []byte {
	if len(h) > NotifyCenterMax {
		h = h[len(h)-NotifyCenterMax:]
	}
	buf := make([]byte, 0, notifyHistMaxBytes)
	buf = append(buf, notifyHistMagic...)
	buf = append(buf, byte(len(h)))
	for _, e := range h {
		src := clampNotifyField(e.source, notifyHistSrcMax)
		text := clampNotifyField(e.text, notifyHistTextMax)
		buf = append(buf, byte(len(src)), byte(len(text)))
		buf = append(buf, src...)
		buf = append(buf, text...)
	}
	sum := fnv32(buf)
	return append(buf, byte(sum), byte(sum>>8), byte(sum>>16), byte(sum>>24))
}

// decodeNotifyHistory is all-or-nothing: any check that fails — size, magic,
// checksum, count, a field bound, an empty text (the seat never accepts one),
// or bytes left over after the last record — returns ok=false and NO entries.
// The checksum is verified before a single record is read, so a torn or
// bit-flipped file cannot yield a plausible-looking prefix.
func decodeNotifyHistory(b []byte) ([]centerNotification, bool) {
	head := len(notifyHistMagic)
	if len(b) < head+1+4 || len(b) > notifyHistMaxBytes || string(b[:head]) != notifyHistMagic {
		return nil, false
	}
	body, tail := b[:len(b)-4], b[len(b)-4:]
	want := uint32(tail[0]) | uint32(tail[1])<<8 | uint32(tail[2])<<16 | uint32(tail[3])<<24
	if fnv32(body) != want {
		return nil, false
	}
	n := int(body[head])
	if n > NotifyCenterMax {
		return nil, false
	}
	out := make([]centerNotification, 0, n)
	off := head + 1
	for i := 0; i < n; i++ {
		if off+2 > len(body) {
			return nil, false
		}
		srcLen, textLen := int(body[off]), int(body[off+1])
		off += 2
		if textLen == 0 || srcLen > notifyHistSrcMax || textLen > notifyHistTextMax ||
			off+srcLen+textLen > len(body) {
			return nil, false
		}
		source := string(body[off : off+srcLen])
		off += srcLen
		text := string(body[off : off+textLen])
		off += textLen
		out = append(out, centerNotification{source: source, text: text, sourceGone: true})
	}
	if off != len(body) {
		return nil, false
	}
	return out, true
}

type notifyHistState uint8

const (
	notifyHistMissing notifyHistState = iota
	notifyHistRestored
	notifyHistCorrupt
)

// The file seams: host tests inject stubs, since vi.WriteFileSafe and
// vi.ReadFileAll degrade to ENOSYS off the guest. Deliberately NOT the
// session's writeHostFile, so a test that stubs that seam cannot have a
// history publish land in its capture.
var (
	readNotifyFile  = vi.ReadFileAll
	writeNotifyFile = func(path string, data []byte) bool {
		return vi.WriteFileSafe(path, data) == 0
	}
)

var (
	notifyHistDirty      bool
	notifyHistFailLogged bool
)

// restoreNotifyHistoryBytes keeps the missing/corrupt/present decision
// testable on the host. Missing is the first boot (or a share that never held
// a notice) and is silent. A file that opened but holds nothing is NOT
// missing: it is a file that failed every check, which is corrupt.
func restoreNotifyHistoryBytes(b []byte, readResult int64) ([]centerNotification, notifyHistState) {
	if readResult < 0 {
		return nil, notifyHistMissing
	}
	h, ok := decodeNotifyHistory(b)
	if !ok {
		return nil, notifyHistCorrupt
	}
	return h, notifyHistRestored
}

// loadNotifyHistory restores the center at seat start. It runs before the
// composite loop, so the history is in place before the first frame is
// painted (the clock panel's hint reads it) and before the user can open the
// panel: there is no flash of an empty center that then fills in.
func loadNotifyHistory() notifyHistState {
	b, r := readNotifyFile(notifyHistoryPath, notifyHistMaxBytes+1)
	h, state := restoreNotifyHistoryBytes(b, r)
	switch state {
	case notifyHistRestored:
		notifyCenter = h
		// Fresh ids, continuing past the restored ones so a later push can
		// never collide with an entry a toast could name.
		for i := range notifyCenter {
			notifyCenter[i].id = uint32(i + 1)
		}
		notifyCenterNextID = uint32(len(notifyCenter))
		notifyHistDirty = false
		vi.ConsoleLine(MarkerNotifyHistRestore + vi.Itoa64(int64(len(notifyCenter))))
	case notifyHistCorrupt:
		// Refused WHOLE: nothing from the file is trusted, and the center
		// is explicitly emptied rather than left to whatever it held. The
		// heal publishes a valid empty history immediately, so the file is
		// not re-refused on every later boot.
		notifyCenter = nil
		notifyCenterNextID = 0
		vi.ConsoleLine(MarkerNotifyHistBad)
		notifyHistDirty = true
		if publishNotifyHistory() {
			vi.ConsoleLine(MarkerNotifyHistHealed)
		}
	}
	return state
}

// notifyHistoryChanged marks the center's history as needing a publish. Every
// mutation of the history itself calls it; the closed latch does not (it is
// not persisted).
func notifyHistoryChanged() { notifyHistDirty = true }

// flushNotifyHistory publishes a changed history: once per tick however many
// mutations landed, and at a clean exit. A failed publish stays dirty and is
// retried on the next tick.
func flushNotifyHistory() {
	if notifyHistDirty {
		publishNotifyHistory()
	}
}

func publishNotifyHistory() bool {
	if !writeNotifyFile(notifyHistoryPath, encodeNotifyHistory(notifyCenter)) {
		if !notifyHistFailLogged {
			notifyHistFailLogged = true
			vi.ConsoleLine(MarkerNotifyHistFail)
		}
		return false
	}
	notifyHistDirty = false
	notifyHistFailLogged = false
	vi.ConsoleLine(MarkerNotifyHistWrite + vi.Itoa64(int64(len(notifyCenter))))
	return true
}
