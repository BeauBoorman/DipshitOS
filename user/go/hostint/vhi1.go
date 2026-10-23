// Package hostint is the M108 host-integration lane wire (ADR 0051 D2):
// signed VHI1 records carried as files in the --cvc-file share's HOSTINT/
// directory. No new virtqueue, no new syscall, no kernel diff — the lanes
// ride the existing host file channel, and the ADR 0044 HMAC-SHA256 shape
// (a SECRETS.TXT app-bound row) is what makes a lane file attributable:
// a guest app can write files into HOSTINT/ but cannot sign them.
//
// This package is lane-agnostic plumbing — the record codec, the filename
// grammar, the refusal vocabulary, and the seat-side consume/emit engine.
// M108b wires the clipboard lane onto it; M108c (drop) and M108d
// (notify-out) register their own tags on the same engine.
//
// The guest side is the registered seat alone (the kernel admits slots
// 38/39 to the seat pid, and no other process may read the buffer); the
// host side is the runner process. A flags-off boot is byte-silent: the
// runner never creates HOSTINT/ and the seat polls a directory that never
// exists — or never polls at all when the credential row is absent.
package hostint

import "virelai/shlib"

// VHI1 record layout (ADR 0051 D2 + the v2 amendment — fixed binary
// header, payload, tag):
//
//	0..3    magic  "VHI1"
//	4       tag    u8: 0=ARMED 1=CLIP_OUT 2=CLIP_IN 3=NOTIFY_OUT 4=DROP
//	               5=OUTBOX 6=NOTIFY_FOCUS (v2) 7=CLIP_OUT_T 8=CLIP_IN_T
//	               (M124c typed clipboard) 9=DRAGOUT (M184b)
//	5       flags  u8: bit0 TRUNCATED; bits 1-7 reserved (writer sends 0)
//	6..7    sender_id u16le — the kernel window id the record is about;
//	        v1 wrote reserved zeros, so v1 records carry 0 here and a v1
//	        reader's bad_record on nonzero is the correct skew answer
//	8..11   seq    u32le — per-tag monotonic, starts at 1 per epoch
//	12..15  epoch  u32le — the runner's per-boot nonce
//	16..17  plen   u16le — payload bytes, 0..512
//	18..    payload[plen]
//	+32     mac    HMAC-SHA256(host-int key, bytes[0 .. 18+plen))
const (
	HeaderLen  = 18
	PayloadMax = 512
	MACLen     = 32
	// RecordMax is the largest wire record: 18 + 512 + 32.
	RecordMax = HeaderLen + PayloadMax + MACLen

	// MaxOutstanding bounds a producer's unconsumed records per tag — the
	// toast queue's own depth as the shared bound.
	MaxOutstanding = 4

	// SecretName is the SECRETS.TXT row both ends read: the seat through
	// sys_secret_get, the runner as a host file. The value bytes are the
	// HMAC key verbatim (no decoding — the agentd `a5`x32 precedent).
	SecretName = "host-int"

	// HostDir is the lane directory in kernel path form — what the slot-27
	// dir_list window and the file ops take. The runner serves it as
	// <share>/HOSTINT/.
	HostDir = "/host/HOSTINT"
)

// Record tags (direction is in the tag; each tag's consumer is fixed).
const (
	TagArmed       uint8 = 0 // h→g runner → seat: payload [lane_mask u8]
	TagClipOut     uint8 = 1 // g→h seat → runner: clipboard bytes (0 = clear)
	TagClipIn      uint8 = 2 // h→g runner → seat: UTF-8 text ≤ 512
	TagNotifyOut   uint8 = 3 // g→h seat → runner: toast text ≤ 24
	TagDrop        uint8 = 4 // h→g runner → seat: [name_len u8][name][size u64le]
	TagOutbox      uint8 = 5 // g→h seat → runner: the DROP shape, reversed (v2)
	TagNotifyFocus uint8 = 6 // h→g runner → seat: plen MUST be 0 (v2)
	// M124c (#2582): the typed clip tags. Tags 1/2 still carry raw UTF-8
	// text — a record shape an un-upgraded reader can pin — while 7/8
	// carry the typed envelope `u8 mime_len | mime | blob`. Dedicated
	// tags, not an in-band marker: a text payload can never be mistaken
	// for an envelope because the tag, not a magic prefix, names the
	// shape (the same call ParseName already makes per file).
	TagClipOutT uint8 = 7 // g→h seat → runner: mime_len|mime|blob
	TagClipInT  uint8 = 8 // h→g runner → seat: mime_len|mime|blob
	// M184b (#3175): the drag-out notice — a held drag's payload staged
	// in OUTBOX/, signed like an OUTBOX record and riding the same lane
	// bit; the sender is the source window id (the V2-D1 correlation).
	TagDragOut uint8 = 9 // g→h seat → runner: the DROP shape, reversed
	tagCount          = 10
)

// FlagTruncated is the record flags bit0: the producer cut the payload at
// the 512 bound and said so (truncation is honest, never silent).
const FlagTruncated uint8 = 0x01

// TypedClipMaxMime bounds the typed envelope's mime field: 24, the same
// title budget the drag arm lives inside — a type too wide for a frame
// title is too wide for the clipboard too.
const TypedClipMaxMime = 24

// EncodeTypedClip frames a typed clip payload: `u8 mime_len | mime |
// blob`. nil when the mime is empty or wider than the bound, or the total
// cannot ride a record — the caller refuses rather than emit a body the
// other end must drop.
func EncodeTypedClip(mime string, blob []byte) []byte {
	if len(mime) == 0 || len(mime) > TypedClipMaxMime || 1+len(mime)+len(blob) > PayloadMax {
		return nil
	}
	out := make([]byte, 1+len(mime)+len(blob))
	out[0] = byte(len(mime))
	copy(out[1:], mime)
	copy(out[1+len(mime):], blob)
	return out
}

// DecodeTypedClip is the total inverse: a mime_len that cannot fit the
// body is a bad record, not a truncated mime.
func DecodeTypedClip(payload []byte) (mime string, blob []byte, ok bool) {
	if len(payload) < 2 {
		return "", nil, false
	}
	ml := int(payload[0])
	if ml == 0 || ml > TypedClipMaxMime || len(payload) <= 1+ml {
		return "", nil, false
	}
	return string(payload[1 : 1+ml]), payload[1+ml:], true
}

// ARMED lane_mask bits — the runner names every lane its flags enabled.
// NOTIFY_FOCUS rides lane_notify: both directions of a lane share one
// bit (the LaneBit rule).
const (
	LaneClip   uint8 = 1 << 0
	LaneDrop   uint8 = 1 << 1
	LaneNotify uint8 = 1 << 2
	LaneOutbox uint8 = 1 << 3
)

// The refusal vocabulary (ADR 0051 D2): one set of names, both ends,
// surfaced as `host-int: refuse lane=<l> reason=<code>` on the runner's
// stdout and `gotabwm: hostint refuse lane=<l> reason=<code>` on serial.
// Payload bytes never appear in either — never-logged contract.
const (
	RefuseLaneDisabled = "lane_disabled"
	RefuseNoCredential = "no_credential"
	RefuseBadRecord    = "bad_record"
	RefuseBadMAC       = "bad_mac"
	RefuseStaleEpoch   = "stale_epoch"
	RefuseStaleSeq     = "stale_seq"
	RefuseBackpressure = "backpressured"
	RefuseTooLarge     = "payload_too_large"
	RefuseNotText      = "payload_not_text"
	RefuseNameRejected = "name_rejected"
	RefuseUnsupported  = "unsupported_kind"
	RefuseConsent      = "consent_denied"
	RefuseNoBundle     = "no_bundle"
	RefuseAuthDenied   = "auth_denied"
	RefuseIO           = "io_error"
	// v2 additions (ADR 0051 V2-D6): gone names a target that no longer
	// exists (a REQ's absent payload, a dead focus tab, a vanished INBOX
	// file); quota_exceeded is the per-epoch OUTBOX export cap.
	RefuseGone  = "gone"
	RefuseQuota = "quota_exceeded"
)

// tagStem is the filename stem per tag (ARMED-00000001, CLIPIN-00000007,
// CLIPOUT-…, NOTIFY-…, DROP-…, OUTBOX-…, NFOCUS-…). "" marks an
// out-of-range tag.
func tagStem(tag uint8) string {
	switch tag {
	case TagArmed:
		return "ARMED"
	case TagClipOut:
		return "CLIPOUT"
	case TagClipIn:
		return "CLIPIN"
	case TagNotifyOut:
		return "NOTIFY"
	case TagDrop:
		return "DROP"
	case TagOutbox:
		return "OUTBOX"
	case TagNotifyFocus:
		return "NFOCUS"
	case TagClipOutT:
		return "CLIPTOUT"
	case TagClipInT:
		return "CLIPTIN"
	case TagDragOut:
		return "DRAGOUT"
	}
	return ""
}

// stemTag is the tagStem inverse for ParseName.
func stemTag(stem string) (uint8, bool) {
	switch stem {
	case "ARMED":
		return TagArmed, true
	case "CLIPOUT":
		return TagClipOut, true
	case "CLIPIN":
		return TagClipIn, true
	case "NOTIFY":
		return TagNotifyOut, true
	case "DROP":
		return TagDrop, true
	case "OUTBOX":
		return TagOutbox, true
	case "NFOCUS":
		return TagNotifyFocus, true
	case "CLIPTOUT":
		return TagClipOutT, true
	case "CLIPTIN":
		return TagClipInT, true
	case "DRAGOUT":
		return TagDragOut, true
	}
	return 0, false
}

// LaneName is the tag's lane name for the refuse markers ("clip", "drop",
// "notify"). ARMED is the handshake itself, not a lane: tag-0 refusals are
// the engine's own scan-level ones (the dir-list io_error, a malformed
// ARMED) and render "dirlist" so `lane=` never goes empty.
func LaneName(tag uint8) string {
	switch tag {
	case TagArmed:
		return "dirlist"
	case TagClipIn, TagClipOut, TagClipInT, TagClipOutT:
		return "clip"
	case TagDrop:
		return "drop"
	case TagNotifyOut, TagNotifyFocus:
		return "notify"
	case TagOutbox:
		return "outbox"
	case TagDragOut:
		return "dragout"
	}
	return ""
}

// LaneBit is the tag's ARMED lane_mask bit (both directions of a lane share
// one bit — clip is one lane). ARMED itself has none: 0.
func LaneBit(tag uint8) uint8 {
	switch tag {
	case TagClipIn, TagClipOut, TagClipInT, TagClipOutT:
		return LaneClip
	case TagDrop:
		return LaneDrop
	case TagNotifyOut, TagNotifyFocus:
		return LaneNotify
	case TagOutbox, TagDragOut:
		return LaneOutbox
	}
	return 0
}

// MaskNames renders an ARMED lane_mask as the `lanes=` csv the armed
// markers carry: "clip,drop,notify" (or "-" for none).
func MaskNames(mask uint8) string {
	out := ""
	if mask&LaneClip != 0 {
		out = "clip"
	}
	if mask&LaneDrop != 0 {
		if out != "" {
			out += ","
		}
		out += "drop"
	}
	if mask&LaneNotify != 0 {
		if out != "" {
			out += ","
		}
		out += "notify"
	}
	if mask&LaneOutbox != 0 {
		if out != "" {
			out += ","
		}
		out += "outbox"
	}
	if out == "" {
		return "-"
	}
	return out
}

const hexDigits = "0123456789abcdef"

// hex8 renders v as exactly 8 lowercase hex digits — the seq field of a
// lane filename. Lowercase is the emit form; ParseName accepts both cases
// because the share's filesystem is case-insensitive anyway.
func hex8(v uint32) string {
	var b [8]byte
	for i := 0; i < 8; i++ {
		b[i] = hexDigits[(v>>uint((7-i)*4))&0xf]
	}
	return string(b[:])
}

// HexDigest8 renders the first 4 bytes of digest as 8 hex chars — the
// sha256[:8] both ends log (the never-logged contract's payload stand-in).
func HexDigest8(digest []byte) string {
	var b [8]byte
	for i := 0; i < 4 && i < len(digest); i++ {
		b[2*i] = hexDigits[digest[i]>>4]
		b[2*i+1] = hexDigits[digest[i]&0xf]
	}
	return string(b[:])
}

// RecordName is the lane filename for (tag, seq): "<STEM>-<seq:8hex>".
func RecordName(tag uint8, seq uint32) string {
	stem := tagStem(tag)
	if stem == "" {
		return ""
	}
	return stem + "-" + hex8(seq)
}

// ParseName parses a lane filename back to (tag, seq). Names that are not
// records — the `~` publish temps, foreign files — return ok=false and are
// never consumed (a consumer deletes only what it could attribute).
func ParseName(name string) (tag uint8, seq uint32, ok bool) {
	dash := -1
	for i := 0; i < len(name); i++ {
		if name[i] == '-' {
			dash = i
		}
	}
	if dash <= 0 || dash+9 != len(name) {
		return 0, 0, false
	}
	t, tok := stemTag(name[:dash])
	if !tok {
		return 0, 0, false
	}
	var v uint32
	for i := dash + 1; i < len(name); i++ {
		c := name[i]
		var nib uint32
		switch {
		case c >= '0' && c <= '9':
			nib = uint32(c - '0')
		case c >= 'a' && c <= 'f':
			nib = uint32(c - 'a' + 10)
		case c >= 'A' && c <= 'F':
			nib = uint32(c - 'A' + 10)
		default:
			return 0, 0, false
		}
		v = v<<4 | nib
	}
	return t, v, true
}

// Record is a decoded lane record. Payload and signed alias the caller's
// raw buffer — callers must not retain either past the buffer's reuse.
type Record struct {
	Tag   uint8
	Flags uint8
	// Sender is the v2 sender_id — the kernel window id the record is
	// about (0 = none). Tags that carry no correlation send 0.
	Sender  uint16
	Seq     uint32
	Epoch   uint32
	Payload []byte
	MAC     [MACLen]byte
	// signed is bytes[0 .. 18+plen) of the wire form — the MAC'd region.
	signed []byte
}

func le16(b []byte) uint16 { return uint16(b[0]) | uint16(b[1])<<8 }
func le32(b []byte) uint32 {
	return uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
}
func putLe16(b []byte, v uint16) { b[0], b[1] = byte(v), byte(v>>8) }
func putLe32(b []byte, v uint32) {
	b[0], b[1], b[2], b[3] = byte(v), byte(v>>8), byte(v>>16), byte(v>>24)
}

// EncodeRecord builds one wire record: header + payload + HMAC-SHA256 tag.
// A payload over PayloadMax is refused with nil — producers truncate first
// (and set FlagTruncated) rather than emit a record that cannot be read.
// Flags outside bit0 are refused the same way: bits 1-7 are reserved, and
// a decoder that names them bad_record must never see a record this writer
// signed. The v1 form — every tag that carries no correlation sends
// sender_id 0.
func EncodeRecord(key []byte, tag, flags uint8, seq, epoch uint32, payload []byte) []byte {
	return EncodeRecordSender(key, tag, flags, 0, seq, epoch, payload)
}

// EncodeRecordSender is the v2 form: sender is the kernel window id the
// record is about (NOTIFY_OUT's toast source, NOTIFY_FOCUS's target). A
// NOTIFY_FOCUS record is refused unless plen is 0 and sender is nonzero —
// the header is its whole payload, so a senderless focus request is
// malformed, not "focus nothing".
func EncodeRecordSender(key []byte, tag, flags uint8, sender uint16, seq, epoch uint32, payload []byte) []byte {
	if len(payload) > PayloadMax || tagStem(tag) == "" || flags&^FlagTruncated != 0 {
		return nil
	}
	if tag == TagNotifyFocus && (len(payload) != 0 || sender == 0) {
		return nil
	}
	out := make([]byte, HeaderLen+len(payload)+MACLen)
	copy(out[0:4], "VHI1")
	out[4] = tag
	out[5] = flags
	putLe16(out[6:8], sender)
	putLe32(out[8:12], seq)
	putLe32(out[12:16], epoch)
	putLe16(out[16:18], uint16(len(payload)))
	copy(out[HeaderLen:], payload)
	mac := shlib.HMACSHA256(key, out[:HeaderLen+len(payload)])
	copy(out[HeaderLen+len(payload):], mac[:])
	return out
}

// DecodeRecord parses the wire form. ok=false means a bad_record refusal:
// wrong magic, bad tag, a flag bit outside FlagTruncated, plen > 512, a
// NOTIFY_FOCUS with a nonempty payload, or a total size that does not
// match header+payload+mac exactly. MAC verification is a separate step
// (Verify) so the two refusal names stay distinct.
func DecodeRecord(raw []byte) (rec Record, ok bool) {
	if len(raw) < HeaderLen+MACLen || len(raw) > RecordMax {
		return rec, false
	}
	if raw[0] != 'V' || raw[1] != 'H' || raw[2] != 'I' || raw[3] != '1' {
		return rec, false
	}
	if tagStem(raw[4]) == "" {
		return rec, false
	}
	if raw[5]&^FlagTruncated != 0 {
		return rec, false
	}
	plen := int(le16(raw[16:18]))
	if plen > PayloadMax || len(raw) != HeaderLen+plen+MACLen {
		return rec, false
	}
	if raw[4] == TagNotifyFocus && plen != 0 {
		return rec, false
	}
	rec.Tag = raw[4]
	rec.Flags = raw[5]
	rec.Sender = le16(raw[6:8])
	rec.Seq = le32(raw[8:12])
	rec.Epoch = le32(raw[12:16])
	rec.Payload = raw[HeaderLen : HeaderLen+plen]
	copy(rec.MAC[:], raw[HeaderLen+plen:])
	rec.signed = raw[:HeaderLen+plen]
	return rec, true
}

// Verify reports whether the record's MAC matches under key — the forgery
// check every consumer runs before any field is trusted. Constant-time
// over the fixed 32-byte tag.
func (r Record) Verify(key []byte) bool {
	mac := shlib.HMACSHA256(key, r.signed)
	var v byte
	for i := 0; i < MACLen; i++ {
		v |= mac[i] ^ r.MAC[i]
	}
	return v == 0
}
