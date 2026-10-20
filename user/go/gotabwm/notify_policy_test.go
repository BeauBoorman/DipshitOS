// notify_policy_test.go — M82d2 (#1785): host tests for the notifications
// center's policy half (notify_policy.go): do-not-disturb, and the crash-safe
// persisted history. Everything runs on the host through the policy's file
// seams; the guest half (a real fsync'd publish over the share) is the
// go-dogfood / go-wm-default gates' job.
package main

import (
	"bytes"
	"strings"
	"testing"
	"unsafe"

	"virelai/settings"
	"virelai/theme"
	"virelai/vi"
)

// fakeNotifyShare is an in-memory /host/NOTIFY.HIST: the read seam serves its
// bytes (or "absent"), and the write seam records every publish.
type fakeNotifyShare struct {
	data    []byte
	present bool
	failing bool
	writes  [][]byte
}

func fakeNotifyFiles(t *testing.T) *fakeNotifyShare {
	t.Helper()
	f := &fakeNotifyShare{}
	readNotifyFile = func(path string, max int) ([]byte, int64) {
		if path != notifyHistoryPath {
			t.Fatalf("history read from %q, want %q", path, notifyHistoryPath)
		}
		if !f.present {
			return nil, -2
		}
		return append([]byte(nil), f.data...), int64(len(f.data))
	}
	writeNotifyFile = func(path string, b []byte) bool {
		if path != notifyHistoryPath {
			t.Fatalf("history written to %q, want %q", path, notifyHistoryPath)
		}
		if f.failing {
			return false
		}
		f.data, f.present = append([]byte(nil), b...), true
		f.writes = append(f.writes, f.data)
		return true
	}
	return f
}

func sampleHistory() []centerNotification {
	return []centerNotification{
		{source: "Files", text: "copied KNOWN.TXT"},
		{source: "", text: "no source"},
		{source: "Report", text: "finished"},
	}
}

// withSum re-seals a forged body with a VALID trailer, so a test can prove the
// structural checks refuse a file whose checksum is perfectly fine.
func withSum(body []byte) []byte {
	sum := fnv32(body)
	return append(append([]byte(nil), body...), byte(sum), byte(sum>>8), byte(sum>>16), byte(sum>>24))
}

func TestNotifyHistoryCodecRoundTrip(t *testing.T) {
	enc := encodeNotifyHistory(sampleHistory())
	got, ok := decodeNotifyHistory(enc)
	if !ok || len(got) != 3 {
		t.Fatalf("decode ok=%v n=%d, want 3 entries", ok, len(got))
	}
	for i, want := range sampleHistory() {
		if got[i].source != want.source || got[i].text != want.text {
			t.Fatalf("entry %d = %q/%q, want %q/%q", i, got[i].source, got[i].text, want.source, want.text)
		}
		if !got[i].sourceGone {
			t.Fatalf("entry %d restored with a live source latch: its sender died with the last seat", i)
		}
	}
	// An empty history is a valid file too: it is what the heal publishes.
	empty, ok := decodeNotifyHistory(encodeNotifyHistory(nil))
	if !ok || len(empty) != 0 {
		t.Fatalf("empty history decode ok=%v n=%d", ok, len(empty))
	}
}

func TestNotifyHistoryCodecBoundsAreEnforcedOnWrite(t *testing.T) {
	var many []centerNotification
	long := strings.Repeat("x", 200)
	for i := 0; i < NotifyCenterMax+5; i++ {
		many = append(many, centerNotification{source: long, text: long})
	}
	enc := encodeNotifyHistory(many)
	if len(enc) > notifyHistMaxBytes {
		t.Fatalf("encoded %d bytes, over the %d-byte bound", len(enc), notifyHistMaxBytes)
	}
	got, ok := decodeNotifyHistory(enc)
	if !ok || len(got) != NotifyCenterMax {
		t.Fatalf("decode ok=%v n=%d, want the newest %d", ok, len(got), NotifyCenterMax)
	}
	if len(got[0].text) != vi.WmRpcTitleMax || len(got[0].source) != notifyHistSrcMax {
		t.Fatalf("fields not clamped: text=%d source=%d", len(got[0].text), len(got[0].source))
	}
	// The NEWEST entries survive the cut, exactly as the live bound keeps them.
	var seq []centerNotification
	for i := 0; i < NotifyCenterMax+2; i++ {
		seq = append(seq, centerNotification{text: string(rune('a' + i))})
	}
	got, _ = decodeNotifyHistory(encodeNotifyHistory(seq))
	if got[0].text != "c" || got[len(got)-1].text != string(rune('a'+NotifyCenterMax+1)) {
		t.Fatalf("kept %q..%q, want the newest %d", got[0].text, got[len(got)-1].text, NotifyCenterMax)
	}
}

// The read-side promise: a file that fails ANY check yields NOTHING, never a
// prefix. Every single-bit flip and every truncation of a valid file is
// refused; so is trailing garbage.
func TestNotifyHistoryDecodeRefusesWholeOnAnyDamage(t *testing.T) {
	enc := encodeNotifyHistory(sampleHistory())
	for i := range enc {
		for bit := 0; bit < 8; bit++ {
			bad := append([]byte(nil), enc...)
			bad[i] ^= 1 << bit
			if got, ok := decodeNotifyHistory(bad); ok || got != nil {
				t.Fatalf("flip byte %d bit %d was accepted (n=%d)", i, bit, len(got))
			}
		}
	}
	for n := 0; n < len(enc); n++ {
		if got, ok := decodeNotifyHistory(enc[:n]); ok || got != nil {
			t.Fatalf("truncation to %d bytes was accepted (n=%d)", n, len(got))
		}
	}
	if _, ok := decodeNotifyHistory(append(append([]byte(nil), enc...), 0)); ok {
		t.Fatal("trailing garbage was accepted")
	}
	if _, ok := decodeNotifyHistory(nil); ok {
		t.Fatal("nil was accepted as a history")
	}
	if _, ok := decodeNotifyHistory([]byte{}); ok {
		t.Fatal("an empty file was accepted as a history")
	}
}

// The structural checks stand on their own: a forged body with a VALID
// checksum still fails when its records are not what the seat would write.
func TestNotifyHistoryDecodeRefusesForgedButChecksummedBodies(t *testing.T) {
	head := []byte(notifyHistMagic)
	cases := []struct {
		name string
		body []byte
	}{
		{"wrong magic", append([]byte("VNH\x02"), 0)},
		{"count over the bound", append(append([]byte(nil), head...), byte(NotifyCenterMax+1))},
		{"count with no records", append(append([]byte(nil), head...), 2)},
		{"empty text", append(append([]byte(nil), head...), 1, 0, 0)},
		{"text over the bound", append(append([]byte(nil), head...), 1, 0, vi.WmRpcTitleMax+1)},
		{"source over the bound", append(append([]byte(nil), head...), 1, notifyHistSrcMax+1, 1)},
		{"record longer than the file", append(append([]byte(nil), head...), 1, 0, 9, 'a')},
		{"bytes after the last record", append(append([]byte(nil), head...), 0, 'z')},
	}
	for _, c := range cases {
		if got, ok := decodeNotifyHistory(withSum(c.body)); ok || got != nil {
			t.Errorf("%s: accepted (n=%d)", c.name, len(got))
		}
	}
	// The control: the same shape with sane numbers IS accepted, so the
	// cases above fail for the reason they name.
	ok := append(append([]byte(nil), head...), 1, 0, 1, 'a')
	if got, good := decodeNotifyHistory(withSum(ok)); !good || len(got) != 1 || got[0].text != "a" {
		t.Fatalf("control file refused: ok=%v got=%+v", good, got)
	}
}

func TestNotifyHistoryFileBoundCoversTheLargestHistory(t *testing.T) {
	var most []centerNotification
	for i := 0; i < NotifyCenterMax; i++ {
		most = append(most, centerNotification{
			source: strings.Repeat("s", notifyHistSrcMax),
			text:   strings.Repeat("t", notifyHistTextMax),
		})
	}
	if n := len(encodeNotifyHistory(most)); n != notifyHistMaxBytes {
		t.Fatalf("largest history encodes to %d bytes, bound is %d", n, notifyHistMaxBytes)
	}
	if notifyHistMaxBytes > vi.MaxFileBytes {
		t.Fatalf("history bound %d exceeds what ReadFileAll can return", notifyHistMaxBytes)
	}
}

func TestNotifyPolicyMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{MarkerNotifyDND, "gotabwm: notify dnd="},
		{MarkerNotifyHeld, "gotabwm: notify held id="},
		{MarkerNotifyHistRestore, "gotabwm: notify history restore n="},
		{MarkerNotifyHistBad, "gotabwm: notify history bad"},
		{MarkerNotifyHistHealed, "gotabwm: notify history healed"},
		{MarkerNotifyHistWrite, "gotabwm: notify history write n="},
		{MarkerNotifyHistFail, "gotabwm: notify history write fail"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
	if notifyHistoryPath != "/host/NOTIFY.HIST" {
		t.Fatalf("history path = %q", notifyHistoryPath)
	}
}

// --- do-not-disturb ---------------------------------------------------------

func openNotifyTab(t *testing.T, id uint32, title string) {
	t.Helper()
	saved := tabs
	t.Cleanup(func() { tabs = saved })
	tabs = TabStrip{}
	if !tabs.OpenTab(id, title) {
		t.Fatal("OpenTab")
	}
}

// The whole point: DND never loses a notice. It lands in the center, raises
// no toast, and the kind-12 ack is still applied so the app cannot tell.
func TestNotifyDNDHoldsTheToastButKeepsTheNotice(t *testing.T) {
	resetNotify(t)
	openNotifyTab(t, 4, "files")
	seatTick = 5
	notifyDND = true

	if !applyRPC(navRPC(vi.WmRpcKindNotify, 4, "copied KNOWN.TXT")) {
		t.Fatal("a notify under DND must still be acked (applied=1): the app must not learn the user is away")
	}
	if notifyCount() != 0 {
		t.Fatalf("DND queued %d toasts, want 0", notifyCount())
	}
	if len(notifyCenter) != 1 || notifyCenter[0].text != "copied KNOWN.TXT" || notifyCenter[0].source != "files" {
		t.Fatalf("center = %+v, want the held notice", notifyCenter)
	}
	if !notifyHistDirty {
		t.Fatal("a held notice did not mark the history for a publish")
	}
	// Refusals are unchanged by DND: an unknown sender and an empty message
	// are still applied=0, and neither reaches the history.
	if applyRPC(navRPC(vi.WmRpcKindNotify, 99, "ghost")) || applyRPC(navRPC(vi.WmRpcKindNotify, 4, "")) {
		t.Fatal("DND accepted a notice the seat would refuse")
	}
	if len(notifyCenter) != 1 {
		t.Fatalf("a refused notice reached the history: %+v", notifyCenter)
	}
	if notifyDropped != 0 {
		t.Fatalf("notifyDropped = %d under DND, want 0 (nothing was queued to drop)", notifyDropped)
	}
}

func TestNotifyDNDFloodKeepsTheNewestHistoryAndNoToasts(t *testing.T) {
	resetNotify(t)
	openNotifyTab(t, 4, "files")
	notifyDND = true
	for i := 0; i < NotifyCenterMax+6; i++ {
		if !applyRPC(navRPC(vi.WmRpcKindNotify, 4, "n"+string(rune('a'+i)))) {
			t.Fatalf("held notice %d refused", i)
		}
	}
	if notifyCount() != 0 || notifyDropped != 0 {
		t.Fatalf("flood raised toasts=%d dropped=%d, want none", notifyCount(), notifyDropped)
	}
	if len(notifyCenter) != NotifyCenterMax {
		t.Fatalf("history depth = %d, want the bound %d", len(notifyCenter), NotifyCenterMax)
	}
	if got, want := notifyCenter[NotifyCenterMax-1].text, "n"+string(rune('a'+NotifyCenterMax+5)); got != want {
		t.Fatalf("newest held notice = %q, want %q", got, want)
	}
}

// DND is a gate on NEW toasts only: what is already on the strip runs out
// normally, and turning DND off resumes toasts without replaying held ones.
func TestNotifyDNDLeavesShownToastsAndResumesOnOff(t *testing.T) {
	resetNotify(t)
	notifyPush(4, "before", 0)
	notifyDND = true
	notifyPush(4, "held", 0)
	if notifyCount() != 1 || notifyQueue[0].text != "before" {
		t.Fatalf("queue = %+v, want only the toast shown before DND", notifyQueue)
	}
	notifyDND = false
	notifyPush(4, "after", 0)
	if notifyCount() != 2 || notifyQueue[1].text != "after" {
		t.Fatalf("queue = %+v, want before+after (held is never replayed)", notifyQueue)
	}
	if len(notifyCenter) != 3 {
		t.Fatalf("center = %+v, want all three notices", notifyCenter)
	}
	// The toast's centerID still names its history row, so dismissing the
	// toast's row takes the toast with it.
	if notifyQueue[1].centerID != notifyCenter[2].id {
		t.Fatalf("toast centerID %d != history id %d", notifyQueue[1].centerID, notifyCenter[2].id)
	}
}

func TestConfigureNotifyDNDReadsOnlyAnIntactExactOn(t *testing.T) {
	resetNotify(t)
	on := []settings.Setting{{Key: settings.NotifyDNDKey, Val: "on"}}
	cases := []struct {
		name string
		f    settings.File
		want bool
	}{
		{"missing file", settings.File{State: settings.StateMissing}, false},
		{"absent row", settings.File{State: settings.StateOK}, false},
		{"on", settings.File{State: settings.StateOK, Rows: on}, true},
		{"off", settings.File{State: settings.StateOK, Rows: []settings.Setting{{Key: "notify_dnd", Val: "off"}}}, false},
		{"corrupt file with an on row", settings.File{State: settings.StateCorrupt, Rows: on}, false},
		{"typo", settings.File{State: settings.StateOK, Rows: []settings.Setting{{Key: "notify_dnd", Val: "ON"}}}, false},
		{"garbage", settings.File{State: settings.StateOK, Rows: []settings.Setting{{Key: "notify_dnd", Val: "yes"}}}, false},
	}
	for _, c := range cases {
		notifyDND = !c.want // configure must overwrite, not merge
		configureNotifyDND(c.f)
		if notifyDND != c.want {
			t.Errorf("%s: notifyDND = %v, want %v", c.name, notifyDND, c.want)
		}
	}
}

// The seat control's state change persists through the seam and reports the
// origin; the other two origins (boot read, GOSET publish) do NOT write the
// file again, because they already have it.
func TestNotifyDNDPersistsOnlyForTheSeatControl(t *testing.T) {
	resetNotify(t)
	var saved []bool
	saveNotifyDND = func(on bool) bool {
		saved = append(saved, on)
		return true
	}
	toggleNotifyDND()
	toggleNotifyDND()
	if len(saved) != 2 || !saved[0] || saved[1] {
		t.Fatalf("seat toggles persisted %v, want [true false]", saved)
	}
	configureNotifyDND(settings.File{State: settings.StateOK,
		Rows: []settings.Setting{{Key: settings.NotifyDNDKey, Val: "on"}}})
	applyNotifyDNDSetting("off")
	applyNotifyDNDSetting("on")
	if len(saved) != 2 {
		t.Fatalf("boot/settings origins wrote the file: %v", saved)
	}
	if !notifyDND {
		t.Fatal("applyNotifyDNDSetting(on) left DND off")
	}
	// A value that is not exactly on/off means the default, like the boot read.
	applyNotifyDNDSetting("bogus")
	if notifyDND {
		t.Fatal("a non-on/off value left DND on")
	}
}

func TestNotifyDNDSeatControlSurvivesAFailedSave(t *testing.T) {
	resetNotify(t)
	saveNotifyDND = func(bool) bool { return false }
	toggleNotifyDND()
	if !notifyDND {
		t.Fatal("a failed persist reverted the live toggle: the user asked for quiet, this boot honours it")
	}
}

// GOSET's publish path: the value is on the bus and in the file, and the seat
// applies it live, no restart.
func TestSettingsPublishAppliesDND(t *testing.T) {
	resetNotify(t)
	savedTabs := tabs
	savedLoad, savedSend := loadSettingsForBus, sendSettingsNotice
	savedSubs := settingsSubscriptions
	savedValues := settingsBusValues
	t.Cleanup(func() {
		tabs = savedTabs
		loadSettingsForBus, sendSettingsNotice = savedLoad, savedSend
		settingsSubscriptions = savedSubs
		settingsBusValues = savedValues
	})
	tabs = TabStrip{}
	resetSettingsSubscriptions()
	if !tabs.OpenTab(4, "calc") || !tabs.OpenTab(5, "settings") {
		t.Fatal("open subscriber and publisher tabs")
	}
	var told vi.WmRpc
	sendSettingsNotice = func(pid uint32, body []byte) int64 {
		told, _ = vi.DecodeWmRpc(body)
		return int64(len(body))
	}
	sub := vi.WmRpc{Kind: vi.WmRpcKindSettingsSubscribe, ID: 4, ReplyTo: 77}
	sub.SetTitle(settings.NotifyDNDKey)
	if !applyRPC(sub) {
		t.Fatal("notify_dnd is a subscribable key")
	}

	seedSettingsBusValues(settings.File{State: settings.StateOK})
	file := func(val string) settings.File {
		return settings.File{State: settings.StateOK, Rows: []settings.Setting{{Key: settings.NotifyDNDKey, Val: val}}}
	}
	publish := vi.WmRpc{Kind: vi.WmRpcKindSettingsPublish, ID: 5, ReplyTo: 88}
	publish.SetTitle(settings.NotifyDNDKey)

	loadSettingsForBus = func() settings.File { return file("on") }
	if !applyRPC(publish) || !notifyDND {
		t.Fatalf("publishing notify_dnd=on: DND = %v", notifyDND)
	}
	if told.Kind != vi.WmRpcKindSettingsChanged || told.TitleString() != settings.NotifyDNDKey {
		t.Fatalf("subscriber told %+v", told)
	}
	loadSettingsForBus = func() settings.File { return file("off") }
	if !applyRPC(publish) || notifyDND {
		t.Fatalf("publishing notify_dnd=off: DND = %v", notifyDND)
	}
}

// The seat control (the center's header toggle) and the drawn control use one
// rect, so what is painted is what is clickable.
func TestNotifyCenterHeaderToggleClickTogglesAndPersists(t *testing.T) {
	resetNotify(t)
	var saved []bool
	saveNotifyDND = func(on bool) bool { saved = append(saved, on); return true }
	notifyCenterOpen = true
	dx, dy, dw, dh := notifyCenterDNDRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if dw <= 0 || dh != notifyHeaderH {
		t.Fatalf("toggle rect %d,%d %dx%d: absent on the default scanout", dx, dy, dw, dh)
	}
	px, py, pw, _ := notifyCenterRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if dx < px || dx+dw > px+pw-notifyDNDGapX+1 || dy != py {
		t.Fatalf("toggle rect %d..%d strays out of the header (panel %d..%d)", dx, dx+dw, px, px+pw)
	}
	// Edges: first and last pixel are inside, one past either side is not.
	if !notifyCenterClick(uint32(dx), uint32(dy)) || !notifyDND {
		t.Fatal("click on the toggle's first pixel did not turn DND on")
	}
	if !notifyCenterOpen {
		t.Fatal("toggling DND closed the center")
	}
	if !notifyCenterClick(uint32(dx+dw-1), uint32(dy+dh-1)) || notifyDND {
		t.Fatal("click on the toggle's last pixel did not turn DND off")
	}
	if len(saved) != 2 || !saved[0] || saved[1] {
		t.Fatalf("persisted %v, want [true false]", saved)
	}
	// Just left of the control is the title band: consumed by the panel but
	// it does nothing.
	notifyCenterClick(uint32(dx-1), uint32(dy))
	if notifyDND || len(saved) != 2 {
		t.Fatal("a click beside the toggle changed DND")
	}
}

// The control must not shadow the close X, the rows or the footer.
func TestNotifyCenterHeaderToggleLeavesTheOtherControlsAlone(t *testing.T) {
	resetNotify(t)
	notifyPush(4, "first", 0)
	notifyCenterOpen = true
	x, y, w, _ := notifyCenterRect(vi.ScanoutWidth, vi.ScanoutHeight)
	dx, _, dw, _ := notifyCenterDNDRect(vi.ScanoutWidth, vi.ScanoutHeight)
	if dx+dw > x+w-notifyDNDGapX {
		t.Fatalf("toggle ends at %d, into the close zone starting %d", dx+dw, x+w-notifyDNDGapX)
	}
	if !notifyCenterClick(uint32(x+w-10), uint32(y+notifyHeaderH/2)) || notifyCenterOpen {
		t.Fatal("the close X stopped working")
	}
	if notifyDND {
		t.Fatal("the close X toggled DND")
	}
	notifyCenterOpen = true
	// A row click below the header still reaches the row, not the toggle.
	notifyCenterClick(uint32(dx), uint32(y+notifyHeaderH+notifyRowH/2))
	if notifyDND {
		t.Fatal("a row click under the toggle's x toggled DND")
	}
}

func TestNotifyCenterHeaderToggleIsAbsentOnAPanelTooNarrowForIt(t *testing.T) {
	resetNotify(t)
	notifyCenterOpen = true
	narrow := notifyDNDMinW - 1 + 2*chromeInset
	if _, _, w, _ := notifyCenterDNDRect(narrow, vi.ScanoutHeight); w != 0 {
		t.Fatalf("a %dpx-wide scanout still drew a toggle (%dpx)", narrow, w)
	}
	// And a click where it would have been is not a toggle.
	x, y, pw, _ := notifyCenterRect(narrow, vi.ScanoutHeight)
	_ = pw
	before := notifyDND
	_ = notifyCenterClick(uint32(x+20), uint32(y+notifyHeaderH/2))
	if notifyDND != before {
		t.Fatal("a click on a control-less header toggled DND")
	}
}

func TestNotifyCenterHeaderShowsTheModeAtAGlance(t *testing.T) {
	resetNotify(t)
	notifyCenterOpen = true
	const w, h = 800, 600
	paint := func() []uint32 {
		scan := make([]byte, w*h*4)
		if paintNotifyCenter(scan, w, h) == 0 {
			t.Fatal("open center painted nothing")
		}
		return append([]uint32(nil), asUint32(scan)...)
	}
	off := paint()
	notifyDND = true
	on := paint()
	dx, dy, dw, dh := notifyCenterDNDRect(w, h)
	accent, differs := false, false
	for py := dy; py < dy+dh; py++ {
		for px := dx; px < dx+dw; px++ {
			if on[py*w+px]&0xffffff == theme.Current.Accent&0xffffff {
				accent = true
			}
			if on[py*w+px] != off[py*w+px] {
				differs = true
			}
		}
	}
	if !differs || !accent {
		t.Fatalf("DND on did not repaint the header control in the accent (differs=%v accent=%v)", differs, accent)
	}
	if notifyCenterDNDLabel() == "" || !strings.Contains(notifyCenterDNDLabel(), "[on]") {
		t.Fatalf("label = %q", notifyCenterDNDLabel())
	}
	notifyDND = false
	if !strings.Contains(notifyCenterDNDLabel(), "[off]") {
		t.Fatalf("label = %q", notifyCenterDNDLabel())
	}
	// The control is inside the panel; nothing paints outside the panel
	// and the §2.5 shadow's bounded falloff band (blur 16, dy 4).
	px, py, pw, ph := notifyCenterRect(w, h)
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			in := x >= px && x < px+pw && y >= py && y < py+ph
			inShadow := x >= px-16 && x < px+pw+16 && y >= py-16 && y < py+ph+20
			if !in && !inShadow && on[y*w+x] != 0 {
				t.Fatalf("center painted outside its panel and shadow at (%d,%d)", x, y)
			}
		}
	}
}

// --- the persisted history --------------------------------------------------

// A valid history is in the center before the loop runs, so the FIRST paint
// already reads it: the clock panel's hint is the observable, and the panel's
// rows are there the instant the user opens it.
func TestLoadNotifyHistoryRestoresBeforeTheFirstPaint(t *testing.T) {
	resetNotify(t)
	share := fakeNotifyFiles(t)
	share.data, share.present = encodeNotifyHistory(sampleHistory()), true
	if chromeStatusText() == "NOTIFY!" {
		t.Fatal("precondition: an empty center already shows the hint")
	}

	if state := loadNotifyHistory(settings.File{}); state != notifyHistRestored {
		t.Fatalf("state = %v, want restored", state)
	}
	if len(notifyCenter) != 3 {
		t.Fatalf("restored %d entries, want 3", len(notifyCenter))
	}
	if chromeStatusText() != "NOTIFY!" {
		t.Fatal("the clock panel's first paint does not know about the restored history")
	}
	if notifyHistDirty || len(share.writes) != 0 {
		t.Fatalf("a clean restore republished the file (dirty=%v writes=%d)", notifyHistDirty, len(share.writes))
	}
	for i, e := range notifyCenter {
		if !e.sourceGone {
			t.Errorf("entry %d links to a sender that no longer exists", i)
		}
		if e.id != uint32(i+1) {
			t.Errorf("entry %d id = %d, want %d", i, e.id, i+1)
		}
	}
	// The panel paints the restored rows, and a click on one is inert: the
	// source is gone, so it must not try to focus anything.
	focusNotifySource = func(uint32) bool {
		t.Fatal("a restored entry tried to focus a window")
		return false
	}
	notifyCenterOpen = true
	scan := make([]byte, 800*600*4)
	if paintNotifyCenter(scan, 800, 600) == 0 {
		t.Fatal("restored center painted nothing")
	}
	x, y, _, _ := notifyCenterRect(vi.ScanoutWidth, vi.ScanoutHeight)
	notifyCenterClick(uint32(x+notifyCenterPad+8), uint32(y+notifyHeaderH+notifyRowH/2))

	// A later push continues past the restored ids: no collision with a
	// row a toast could name.
	notifyPush(4, "fresh", 0)
	last := notifyCenter[len(notifyCenter)-1]
	if last.text != "fresh" || last.id != 4 {
		t.Fatalf("new entry = %+v, want id 4 after the 3 restored", last)
	}
}

func TestLoadNotifyHistoryMissingFileIsSilentAndUntouched(t *testing.T) {
	resetNotify(t)
	share := fakeNotifyFiles(t)
	if state := loadNotifyHistory(settings.File{}); state != notifyHistMissing {
		t.Fatalf("state = %v, want missing", state)
	}
	if len(notifyCenter) != 0 || notifyHistDirty || len(share.writes) != 0 {
		t.Fatalf("a first boot wrote or dirtied: center=%d dirty=%v writes=%d",
			len(notifyCenter), notifyHistDirty, len(share.writes))
	}
}

// Corrupt is refused WHOLE (nothing from the file, even the entries that
// happen to parse), and the seat heals it with a valid empty file at once, so
// the boot after finds nothing wrong.
func TestLoadNotifyHistoryCorruptIsRefusedWholeAndHeals(t *testing.T) {
	good := encodeNotifyHistory(sampleHistory())
	torn := good[:len(good)-6] // a crash that lost the tail of the file
	flipped := append([]byte(nil), good...)
	flipped[6] ^= 0x40
	for name, data := range map[string][]byte{
		"torn":      torn,
		"bit flip":  flipped,
		"garbage":   []byte("this is not a history"),
		"empty":     {},
		"oversized": bytes.Repeat([]byte{'x'}, notifyHistMaxBytes+1),
	} {
		resetNotify(t)
		share := fakeNotifyFiles(t)
		share.data, share.present = data, true
		// Whatever the center held is not a survivor of a refused file.
		notifyCenter = []centerNotification{{text: "stale"}}

		if state := loadNotifyHistory(settings.File{}); state != notifyHistCorrupt {
			t.Fatalf("%s: state = %v, want corrupt", name, state)
		}
		if len(notifyCenter) != 0 {
			t.Fatalf("%s: a refused file left %d entries in the center", name, len(notifyCenter))
		}
		if len(share.writes) != 1 {
			t.Fatalf("%s: heal published %d times, want exactly 1", name, len(share.writes))
		}
		healed, ok := decodeNotifyHistory(share.data)
		if !ok || len(healed) != 0 {
			t.Fatalf("%s: healed file is not a valid empty history (ok=%v n=%d)", name, ok, len(healed))
		}
		if notifyHistDirty {
			t.Fatalf("%s: the heal left the history dirty", name)
		}
		// The next boot restores the healed file cleanly and says nothing.
		resetNotify(t)
		fakeAgain := fakeNotifyFiles(t)
		fakeAgain.data, fakeAgain.present = share.data, true
		if state := loadNotifyHistory(settings.File{}); state != notifyHistRestored || len(fakeAgain.writes) != 0 {
			t.Fatalf("%s: second boot state=%v writes=%d, want a clean restore", name, state, len(fakeAgain.writes))
		}
	}
}

func TestLoadNotifyHistoryCorruptWithAFailingShareStaysDirtyAndRetries(t *testing.T) {
	resetNotify(t)
	share := fakeNotifyFiles(t)
	share.data, share.present, share.failing = []byte("junk"), true, true
	if state := loadNotifyHistory(settings.File{}); state != notifyHistCorrupt {
		t.Fatalf("state = %v", state)
	}
	if !notifyHistDirty || !notifyHistFailLogged {
		t.Fatalf("a failed heal must stay dirty and be reported once: dirty=%v logged=%v",
			notifyHistDirty, notifyHistFailLogged)
	}
	share.failing = false
	flushNotifyHistory()
	if notifyHistDirty || notifyHistFailLogged {
		t.Fatal("the retry did not clear the failure state")
	}
	if got, ok := decodeNotifyHistory(share.data); !ok || len(got) != 0 {
		t.Fatalf("retry published %v/%v", ok, got)
	}
}

// Mutations only mark the history dirty; the tick publishes ONCE however many
// landed. A flood of notices costs one fsync'd write per tick, not one each.
func TestNotifyHistoryPublishIsCoalescedToTheTick(t *testing.T) {
	resetNotify(t)
	share := fakeNotifyFiles(t)
	flushNotifyHistory()
	if len(share.writes) != 0 {
		t.Fatal("a clean history was published")
	}
	for i := 0; i < 6; i++ {
		notifyPush(4, "n", uint64(i))
	}
	if len(share.writes) != 0 {
		t.Fatalf("pushes wrote %d times before the tick", len(share.writes))
	}
	flushNotifyHistory()
	flushNotifyHistory()
	if len(share.writes) != 1 {
		t.Fatalf("6 pushes then 2 flushes wrote %d times, want 1", len(share.writes))
	}
	got, ok := decodeNotifyHistory(share.data)
	if !ok || len(got) != 6 {
		t.Fatalf("published history ok=%v n=%d, want 6", ok, len(got))
	}

	// Dismiss and clear-all are history mutations too.
	dismissNotifyCenterEntry(0)
	flushNotifyHistory()
	if len(share.writes) != 2 {
		t.Fatalf("a dismiss did not republish (writes=%d)", len(share.writes))
	}
	if got, _ := decodeNotifyHistory(share.data); len(got) != 5 {
		t.Fatalf("after dismiss the file holds %d entries, want 5", len(got))
	}
	clearNotifyCenter()
	flushNotifyHistory()
	if got, ok := decodeNotifyHistory(share.data); !ok || len(got) != 0 || len(share.writes) != 3 {
		t.Fatalf("after clear-all ok=%v n=%d writes=%d, want a valid empty file", ok, len(got), len(share.writes))
	}
	// Clearing an already-empty center is not a change.
	clearNotifyCenter()
	flushNotifyHistory()
	if len(share.writes) != 3 {
		t.Fatalf("an empty clear republished (writes=%d)", len(share.writes))
	}
}

// The closed latch and a toast's expiry are not history mutations: they are
// not persisted, so they must not cost a write.
func TestNotifyHistoryIsNotRepublishedForEphemeralChanges(t *testing.T) {
	resetNotify(t)
	share := fakeNotifyFiles(t)
	openNotifyTab(t, 7, "Files")
	notifyPush(7, "copied", 10)
	flushNotifyHistory()
	writes := len(share.writes)
	notifyTick(10 + NotifyTicks)
	tabs.CloseTab(7)
	flushNotifyHistory()
	if len(share.writes) != writes {
		t.Fatalf("toast expiry / source close republished (%d -> %d writes)", writes, len(share.writes))
	}
}

func TestNotifyHistoryFailedPublishRetriesAndReportsOnce(t *testing.T) {
	resetNotify(t)
	share := fakeNotifyFiles(t)
	share.failing = true
	notifyPush(4, "n", 0)
	flushNotifyHistory()
	if !notifyHistDirty || !notifyHistFailLogged {
		t.Fatalf("failed publish: dirty=%v logged=%v", notifyHistDirty, notifyHistFailLogged)
	}
	flushNotifyHistory()
	if !notifyHistDirty {
		t.Fatal("history forgot it was unpublished")
	}
	share.failing = false
	flushNotifyHistory()
	if notifyHistDirty || notifyHistFailLogged || len(share.writes) != 1 {
		t.Fatalf("recovery: dirty=%v logged=%v writes=%d", notifyHistDirty, notifyHistFailLogged, len(share.writes))
	}
}

// A notice that arrives under DND is durable across a restart: it is the
// promise "suppressed is not lost", end to end through the codec.
func TestHeldNoticeSurvivesARestart(t *testing.T) {
	resetNotify(t)
	share := fakeNotifyFiles(t)
	openNotifyTab(t, 4, "files")
	notifyDND = true
	if !applyRPC(navRPC(vi.WmRpcKindNotify, 4, "held while away")) {
		t.Fatal("notify refused")
	}
	flushNotifyHistory()

	// "Restart": a fresh center, the same share.
	notifyCenter, notifyCenterNextID, notifyHistDirty = nil, 0, false
	if state := loadNotifyHistory(settings.File{}); state != notifyHistRestored {
		t.Fatalf("state = %v", state)
	}
	if len(notifyCenter) != 1 || notifyCenter[0].text != "held while away" || notifyCenter[0].source != "files" {
		t.Fatalf("restored center = %+v", notifyCenter)
	}
	if len(share.writes) != 1 {
		t.Fatalf("writes = %d, want the single pre-restart publish", len(share.writes))
	}
}

// compositeTick is where the seat publishes, after the present and before the
// live-mode early return: a tick in live mode still flushes.
func TestCompositeTickPublishesTheHistoryOnce(t *testing.T) {
	resetNotify(t)
	share := fakeNotifyFiles(t)
	savedTabs, savedDemo := tabs, demoMode
	savedDone, savedCount := stripDone, hostTicksLeft
	savedLaunch := launch
	t.Cleanup(func() {
		tabs, demoMode = savedTabs, savedDemo
		stripDone, hostTicksLeft = savedDone, savedCount
		// syncSeatChrome names the host's failed WinOpen in launch.err
		// every live tick; hand the launcher state back (#2545).
		launch = savedLaunch
	})
	demoMode = false
	tabs = TabStrip{}
	stripDone, hostTicksLeft = false, 0
	notifyDND = true
	notifyPush(4, "quiet one", 0)
	notifyPush(4, "quiet two", 0)

	scan := make([]byte, vi.ScanoutWidth*vi.ScanoutHeight*4)
	presents := 0
	compositeTick(scan, 1, &presents)
	compositeTick(scan, 2, &presents)
	if len(share.writes) != 1 {
		t.Fatalf("two ticks after two pushes wrote %d times, want 1", len(share.writes))
	}
	if got, ok := decodeNotifyHistory(share.data); !ok || len(got) != 2 {
		t.Fatalf("published ok=%v n=%d, want 2", ok, len(got))
	}
}

// Off the guest the file seams degrade rather than panic: the default seams
// are the real vi calls, which return ENOSYS on the host.
func TestNotifyHistoryDefaultSeamsDegradeOffGuest(t *testing.T) {
	resetNotify(t)
	readNotifyFile, writeNotifyFile = vi.ReadFileAll, func(path string, data []byte) bool {
		return vi.WriteFileSafe(path, data) == 0
	}
	if state := loadNotifyHistory(settings.File{}); state != notifyHistMissing {
		t.Fatalf("host read state = %v, want missing", state)
	}
	notifyPush(4, "n", 0)
	flushNotifyHistory()
	if !notifyHistDirty {
		t.Fatal("a failed host publish forgot it owed a write")
	}
}

// --- M99d (#2182): the notification chime -------------------------------------
//
// Host coverage splits at the syscalls, like the history half: the synthesis,
// the switch, the DND order and the seat seams are plain Go; the device probe,
// the stream play and the kernel echo are the go-wm-seat gate's job (a host
// svc returns ENOSYS, which is itself the no-device path).

// chimePush counts notifyPlayChime calls: the seam sits between "an accepted
// toast happened" and the stream work, so it is how the host sees every
// policy the push path applies.
func chimePush(t *testing.T) *int {
	t.Helper()
	n := new(int)
	notifyPlayChime = func() { *n++ }
	return n
}

// An accepted toast is audible: one play call per queued toast, none for a
// refused push and none for a held one — the policy's DND ordering is what
// makes "held" silent without the chime path knowing why.
func TestNotifyPushCallsTheChimeForAcceptedToasts(t *testing.T) {
	resetNotify(t)
	plays := chimePush(t)
	if _, ok, _ := notifyPush(4, "ding", 0); !ok || *plays != 1 {
		t.Fatalf("accepted toast: ok=%v plays=%d", ok, *plays)
	}
	notifyPush(4, "ding again", 0)
	if *plays != 2 {
		t.Fatalf("two toasts played %d times", *plays)
	}
	if _, ok, _ := notifyPush(4, "", 0); ok || *plays != 2 {
		t.Fatalf("an empty notice played: ok=%v plays=%d", ok, *plays)
	}
	notifyDND = true
	if _, ok, _ := notifyPush(4, "held", 0); !ok || *plays != 2 {
		t.Fatalf("a DND-held notice played: ok=%v plays=%d", ok, *plays)
	}
	// The queue-bound eviction is still an accepted toast — it chimes like
	// any other; the drop is about pixels, not policy.
	notifyDND = false
	for i := 0; i < NotifyMax+1; i++ {
		notifyPush(4, "flood", 0)
	}
	if *plays != 2+NotifyMax+1 {
		t.Fatalf("a full queue played %d times", *plays)
	}
}

// The boot configure wires the whole sound path off one settings.File:
// notify_sound seeds the bus value the live read uses, and on the host the
// device probe honestly reports itself unavailable rather than pretending.
func TestConfigureNotifySoundSeedsTheSwitchAndStaysHonest(t *testing.T) {
	resetNotify(t)
	configureNotifyDND(settings.File{State: settings.StateOK,
		Rows: []settings.Setting{{Key: settings.NotifySoundKey, Val: "off"}}})
	if notifySoundOn() {
		t.Fatal("notify_sound=off left the chime switch on")
	}
	if notifySoundChime != nil {
		t.Fatal("notify_sound=off still synthesized a chime")
	}
	// A second configure is idempotent: the bus slot is found by name.
	configureNotifyDND(settings.File{State: settings.StateOK,
		Rows: []settings.Setting{{Key: settings.NotifySoundKey, Val: "on"}}})
	n := 0
	for i := range settingsBusValues {
		if settingsBusValues[i].key == settings.NotifySoundKey {
			n++
		}
	}
	if n != 1 || !notifySoundOn() {
		t.Fatalf("reconfigure: %d notify_sound slots, on=%v", n, notifySoundOn())
	}
	// No device on the host: the probe fails, the path stays off and the
	// seat never chimes — exactly the soundless-VM contract.
	if notifySoundChime != nil {
		t.Fatal("a failed device probe still synthesized a chime")
	}
	plays := chimePush(t)
	notifyPush(4, "silent", 0)
	if *plays != 1 || notifySoundPending != nil || notifySoundSkipped != 0 {
		t.Fatalf("soundless push: plays=%d pending=%v skipped=%d", *plays, notifySoundPending != nil, notifySoundSkipped)
	}
}

// A corrupt file is the defaults: notify_sound absent means on, the bus seed
// still lands, and the (host-absent) device is named unavailable — never a
// boot failure.
func TestConfigureNotifySoundOnACorruptFileDefaultsOn(t *testing.T) {
	resetNotify(t)
	configureNotifyDND(settings.File{State: settings.StateCorrupt})
	if !notifySoundOn() {
		t.Fatal("a corrupt file switched the chime off")
	}
}

// The bus seed is what makes GOSET's publish reach the seat live: a
// notify_sound row that is not in the value table is a publish refused, so
// the seed exists for the update path, not for the boot read alone.
func TestNotifySoundBusValueTakesThePublishPath(t *testing.T) {
	resetNotify(t)
	seedNotifySoundBusValue("on")
	if !notifySoundOn() {
		t.Fatal("a seeded on read off")
	}
	if !updateSettingsBusValue(settings.NotifySoundKey, "off") || notifySoundOn() {
		t.Fatal("a published notify_sound=off did not reach the switch")
	}
	if !updateSettingsBusValue(settings.NotifySoundKey, "on") || !notifySoundOn() {
		t.Fatal("a published notify_sound=on did not restore the switch")
	}
	// A value that is not exactly on/off is the default, like the boot read:
	// a typo can never silence the chime.
	seedNotifySoundBusValue("loud")
	if !notifySoundOn() {
		t.Fatal("a bogus bus value switched the chime off")
	}
}

// playNotifyChime counts a refused open and keeps the seat's tick: the guest
// gate sees the skip marker; the host sees the counter and the early exits.
func TestPlayNotifyChimeCountsRefusalsAndHonoursTheSwitch(t *testing.T) {
	resetNotify(t)
	notifySoundChime = make([]byte, 8)
	// The host's open is ENOSYS: a refusal, counted — the toast stands
	// either way.
	playNotifyChime()
	if notifySoundSkipped != 1 || notifySoundPending != nil {
		t.Fatalf("a refused open: skipped=%d pending=%v", notifySoundSkipped, notifySoundPending != nil)
	}
	// notify_sound=off and an absent chime are silent no-ops, not skips —
	// the counter is for attempts that failed, never for policy.
	seedNotifySoundBusValue("off")
	playNotifyChime()
	notifySoundChime = nil
	seedNotifySoundBusValue("on")
	playNotifyChime()
	if notifySoundSkipped != 1 {
		t.Fatalf("policy exits counted as skips: %d", notifySoundSkipped)
	}
}

// notifySoundTick retires the in-flight stream honestly: on the host a
// Status call fails, which is the unconfirmed-drain path — the seat clears
// the seat and counts it rather than claiming a play it cannot prove.
func TestNotifySoundTickClearsAnUnconfirmableDrain(t *testing.T) {
	resetNotify(t)
	notifySoundPending = &vi.AudioStream{}
	notifySoundBytes = 8
	notifySoundTick()
	if notifySoundPending != nil || notifySoundSkipped != 1 {
		t.Fatalf("a lost stream: pending=%v skipped=%d", notifySoundPending != nil, notifySoundSkipped)
	}
}

// --- the chime's synthesis -----------------------------------------------------

// f32le reads one little-endian f32 sample back — the putF32 inverse, kept
// guest-safe the same way (no math/bits package).
func f32le(b []byte) float32 {
	u := uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
	return *(*float32)(unsafe.Pointer(&u))
}
func s16le(b []byte) int16 { return int16(uint16(b[0]) | uint16(b[1])<<8) }
func s32le(b []byte) int32 {
	return int32(uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24)
}

// The chime's hard bound is the source queue's whole prefill: the seat
// submits it all before start and never feeds the stream twice, so a chime
// that cannot fit is a chime that must not exist. The worst tuple (FLOAT
// stereo 48 kHz) is the bound's own witness.
func TestSynthNotifyChimeFitsThePrefillEverywhere(t *testing.T) {
	worst := synthNotifyChime(vi.AudioInfo{Ready: 1, Format: vi.AudioFmtFloat, Rate: 7, Channels: 2})
	if len(worst) == 0 || len(worst) > notifyChimeMaxBytes {
		t.Fatalf("FLOAT stereo 48 kHz chime = %d bytes, bound %d", len(worst), notifyChimeMaxBytes)
	}
	for _, info := range []vi.AudioInfo{
		{Ready: 1, Format: vi.AudioFmtFloat, Rate: 6, Channels: 1},
		{Ready: 1, Format: vi.AudioFmtS16, Rate: 7, Channels: 2},
		{Ready: 1, Format: vi.AudioFmtS32, Rate: 5, Channels: 1},
		{Ready: 1, Format: vi.AudioFmtFloat, Rate: 1, Channels: 2},
	} {
		pcm := synthNotifyChime(info)
		if len(pcm) == 0 || len(pcm) > notifyChimeMaxBytes {
			t.Fatalf("%+v: %d bytes, bound %d", info, len(pcm), notifyChimeMaxBytes)
		}
		if fb, ok := notifyFrameBytes(info.Format, info.Channels); !ok || len(pcm)%int(fb) != 0 {
			t.Fatalf("%+v: %d bytes is not frame-aligned", info, len(pcm))
		}
	}
	// Deterministic, like fart's sines: a guest and a host build the same
	// bytes, so the gate's serial marker and this byte count name one sound.
	again := synthNotifyChime(vi.AudioInfo{Ready: 1, Format: vi.AudioFmtFloat, Rate: 7, Channels: 2})
	if !bytes.Equal(worst, again) {
		t.Fatal("the chime is not deterministic")
	}
}

// A tuple the synth cannot encode returns nothing — the caller reports the
// path unavailable rather than opening the stream on a buffer of zeros.
func TestSynthNotifyChimeRefusesTuplesItCannotEncode(t *testing.T) {
	for _, info := range []vi.AudioInfo{
		{Ready: 1, Format: vi.AudioFmtNone, Rate: 7, Channels: 2}, // no negotiated format
		{Ready: 1, Format: 1, Rate: 7, Channels: 2},               // U8: not a stream format
		{Ready: 1, Format: vi.AudioFmtFloat, Rate: 0, Channels: 2},
		{Ready: 1, Format: vi.AudioFmtFloat, Rate: 2, Channels: 2}, // off the rate ladder
		{Ready: 1, Format: vi.AudioFmtFloat, Rate: 7, Channels: 0},
		{Ready: 1, Format: vi.AudioFmtS16, Rate: 7, Channels: 0},
	} {
		if pcm := synthNotifyChime(info); len(pcm) != 0 {
			t.Fatalf("%+v: synthesized %d bytes on an unencodable tuple", info, len(pcm))
		}
	}
}

// The shape the card asks for: an attack that ramps in (a leading click is
// worse than a soft start), a body that is loud, a decay that lands near
// silence, and mono duplicated across every channel — the f32 readback is
// the same bytes the device would get.
func TestSynthNotifyChimeEnvelopeAndChannels(t *testing.T) {
	pcm := synthNotifyChime(vi.AudioInfo{Ready: 1, Format: vi.AudioFmtFloat, Rate: 7, Channels: 2})
	frames := len(pcm) / 8
	first := f32le(pcm[0:4])
	if first != 0 {
		t.Fatalf("the attack does not start at silence: first sample %v", first)
	}
	// Any one instant can sit on a node where the two partials cancel, and
	// the envelope is already decaying through the middle — so the body's
	// claim is a PEAK across the first half, not a sample.
	peak := float32(0)
	for i := 0; i < frames/2; i++ {
		v := f32le(pcm[i*8 : i*8+4])
		if v > peak {
			peak = v
		} else if -v > peak {
			peak = -v
		}
	}
	if peak < 0.05 {
		t.Fatalf("the body is silent: first-half peak %v", peak)
	}
	last := f32le(pcm[len(pcm)-8 : len(pcm)-4])
	if last > 0.02 || last < -0.02 {
		t.Fatalf("the decay does not land near silence: last sample %v", last)
	}
	// Stereo is the same wave twice.
	for i := 0; i < 8; i++ {
		l, r := f32le(pcm[i*8:i*8+4]), f32le(pcm[i*8+4:i*8+8])
		if l != r {
			t.Fatalf("frame %d: channels differ (%v vs %v)", i, l, r)
		}
	}
	// The other formats carry the same envelope in their own encoding.
	p16 := synthNotifyChime(vi.AudioInfo{Ready: 1, Format: vi.AudioFmtS16, Rate: 7, Channels: 2})
	if s16le(p16[len(p16)/4*2:]) == 0 && s16le(p16[len(p16)/2:]) == 0 {
		t.Fatal("the S16 body is silent")
	}
	p32 := synthNotifyChime(vi.AudioInfo{Ready: 1, Format: vi.AudioFmtS32, Rate: 7, Channels: 1})
	if s32le(p32[len(p32)/2:]) == 0 {
		t.Fatal("the S32 body is silent")
	}
}

// The synth's two approximations: the sine's known anchors, and the decay's
// endpoints (e^-x lands at 1 for x<=0 and at silence past the tail).
func TestChimeApproximationsHitTheirAnchors(t *testing.T) {
	for _, p := range []struct {
		x, want float64
	}{
		{0, 0},
		{pi / 2, 1},
		{-pi / 2, -1},
		{pi, 0},
		{2 * pi, 0},
		{7 * pi / 2, -1},
	} {
		if got := sinApprox(p.x); got-p.want > 0.001 || p.want-got > 0.001 {
			t.Fatalf("sinApprox(%v) = %v, want %v", p.x, got, p.want)
		}
	}
	if expDecay(0) != 1 || expDecay(-1) != 1 {
		t.Fatal("the decay does not start at 1")
	}
	if expDecay(16) != 0 || expDecay(100) != 0 {
		t.Fatal("the decay does not reach silence")
	}
	prev := 1.0
	for i := 1; i < 15; i++ {
		v := expDecay(float64(i))
		if v >= prev || v < 0 {
			t.Fatalf("the decay is not monotone: e^-%d = %v after %v", i, v, prev)
		}
		prev = v
	}
}

// M100f (#2311): the notify history is part of the movable set — an opted-in
// boot with a mounted VLFS volume reads and publishes /disk/NOTIFY.HIST, and
// a set-but-absent disk keeps the share path. The resolver seam is stubbed;
// the file seams still see whatever path the resolution chose.
func TestNotifyHistoryFollowsTheDataRoot(t *testing.T) {
	resetNotify(t)
	notifyDataRoot = func(f settings.File) (string, bool) { return "/disk", false }
	var reads, writes []string
	readNotifyFile = func(path string, max int) ([]byte, int64) {
		reads = append(reads, path)
		return nil, -2
	}
	writeNotifyFile = func(path string, b []byte) bool {
		writes = append(writes, path)
		return true
	}
	if state := loadNotifyHistory(settings.File{Rows: []settings.Setting{{Key: settings.DataRootKey, Val: "disk"}}, State: settings.StateOK}); state != notifyHistMissing {
		t.Fatalf("state = %v, want missing (an empty new volume)", state)
	}
	if notifyHistoryPath != "/disk/NOTIFY.HIST" {
		t.Fatalf("history path = %q, want the disk path", notifyHistoryPath)
	}
	if len(reads) != 1 || reads[0] != "/disk/NOTIFY.HIST" {
		t.Fatalf("load read %v, want /disk/NOTIFY.HIST", reads)
	}
	notifyPush(4, "n", 0)
	flushNotifyHistory()
	if len(writes) != 1 || writes[0] != "/disk/NOTIFY.HIST" {
		t.Fatalf("publish wrote %v, want /disk/NOTIFY.HIST", writes)
	}
}

func TestNotifyHistoryDataRootFallback(t *testing.T) {
	resetNotify(t)
	notifyDataRoot = func(f settings.File) (string, bool) { return "/host", true }
	var readPath string
	readNotifyFile = func(path string, max int) ([]byte, int64) {
		readPath = path
		return nil, -2
	}
	loadNotifyHistory(settings.File{Rows: []settings.Setting{{Key: settings.DataRootKey, Val: "disk"}}, State: settings.StateOK})
	if notifyHistoryPath != "/host/NOTIFY.HIST" || readPath != "/host/NOTIFY.HIST" {
		t.Fatalf("fallback path = %q read %q, want the share path", notifyHistoryPath, readPath)
	}
}
