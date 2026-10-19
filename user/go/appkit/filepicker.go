package appkit

import (
	"strconv"
	"strings"
	"unicode/utf8"

	"virelai/draw"
	"virelai/icons"
	"virelai/mime"
	"virelai/theme"
	"virelai/ttf"
	"virelai/vi"
	"virelai/widgets"
)

// FilePicker is the M124b (issue #2581) shared open/save surface: one modal
// that every app embeds instead of growing its own path prompt. Like Dialog
// it is a pure state machine — no syscall or drawing dependency in its
// transitions — so host tests cover navigation, cancellation, restore and
// the open/save result without a window. Canvas apps paint it with Draw
// (GOEDIT, WEB); a text surface drives the same model through its own
// renderer (GOFILES's pick mode paints the rows as ANSI).
//
// The listing is three things in one scroll, in this order: the current
// directory (an `..` climb row, then subdirectories, then files), the vi
// recent log's newest distinct paths, and /host/TRASH's pending items —
// Enter on a trash row restores it in place rather than picking it.
type FilePicker struct {
	Kind    PickerKind
	Title   string
	Dir     string
	Rows    []PickerRow
	Sel     int
	Scroll  int
	Input   string
	Result  string
	Err     string
	Open    bool
	R       widgets.Rect
	Buttons []DialogButton
	// focus is -1 while the list owns Enter; Tab walks it across the
	// buttons and back, so the keyboard reaches Cancel too.
	Focus    int
	UIFace   *ttf.Face
	IconFace *ttf.Face
}

// PickerKind selects the picker's verb — the list and its rules are
// identical; only the button label and the meaning of Result differ.
type PickerKind uint8

const (
	PickOpen PickerKind = iota
	PickSave
)

// PickRowKind says what a row activation does.
type PickRowKind uint8

const (
	PickUp     PickRowKind = iota // ".." — climb to the parent directory
	PickDir                       // descend into Path
	PickFile                      // a regular file in Dir
	PickRecent                    // a path out of the vi recent log
	PickTrash                     // a /host/TRASH item — Enter restores it
)

// PickerRow is one selectable line. Path is the absolute /host/… target —
// for PickTrash it is the receipt's recorded ORIGINAL path (where a restore
// lands), with TrashID naming the item.
type PickerRow struct {
	Label   string
	Path    string
	Kind    PickRowKind
	Mime    mime.ID
	TrashID string
}

const (
	pickerRoot   = "/host"
	pickRowH     = 18
	pickMaxInput = 63 // share paths cap at 64 bytes (vi.validShareFilePath)
	pickMaxRec   = 8
	pickListTop  = 74 // header rows consumed above the list
	pickFooter   = 40 // input field + button row below the list
)

// The vi seams the state machine reads through, substituted in host tests
// (the bufRead precedent in user/go/edit). The real bindings are the only
// syscall sites; the picker never opens a handle itself.
var (
	pickerDirList      = vi.DirList
	pickerReadAll      = vi.ReadFileAll
	pickerTrashRead    = vi.TrashRead
	pickerTrashRestore = vi.TrashRestore
)

// NewFilePicker opens the picker at dir (clamped onto the share root when
// empty or off-share). Open mode titles itself "Open"; save mode "Save as".
func NewFilePicker(kind PickerKind, dir string) FilePicker {
	p := FilePicker{
		Kind: kind,
		Open: true,
		R:    widgets.Rect{X: 48, Y: 40, W: 416, H: 300},
	}
	verb := "Open"
	if kind == PickSave {
		verb = "Save as"
	}
	p.Title = verb
	p.Buttons = []DialogButton{
		{Label: verb},
		{Label: "Cancel"},
	}
	p.Focus = -1
	if dir == "" || !strings.HasPrefix(dir, pickerRoot) {
		dir = pickerRoot
	}
	p.Dir = dir
	p.refresh()
	return p
}

// refresh rebuilds Rows from the live share: up row, subdirectories, files,
// recent log's newest distinct paths, then trash items. The selection is
// re-clamped so a shrinking listing can never index out of range.
func (p *FilePicker) refresh() {
	var rows []PickerRow
	if p.Dir != pickerRoot {
		rows = append(rows, PickerRow{
			Label: "..", Path: parentPath(p.Dir), Kind: PickUp,
		})
	}
	var ents [vi.MaxDirEntries]vi.DirEntry
	n, rc := pickerDirList(p.Dir, ents[:])
	if rc < 0 {
		p.Err = "list rc=" + strconv.FormatInt(rc, 10)
	} else {
		p.Err = ""
		for i := 0; i < n; i++ {
			if ents[i].Dir() {
				name := ents[i].NameString()
				rows = append(rows, PickerRow{
					Label: name + "/", Path: joinPath(p.Dir, name),
					Kind: PickDir,
				})
			}
		}
		for i := 0; i < n; i++ {
			if !ents[i].Dir() {
				name := ents[i].NameString()
				rows = append(rows, PickerRow{
					Label: name, Path: joinPath(p.Dir, name),
					Kind: PickFile, Mime: mime.Sniff(name, nil),
				})
			}
		}
	}
	rows = append(rows, recentRows()...)
	rows = append(rows, trashRows()...)
	p.Rows = rows
	p.clampSel()
}

// recentRows decodes the vi recent log's bounded tail (the same
// timestamp|action|id|hex(path) rows the launcher palette reads) into
// PickRecent entries — newest first, one row per distinct path.
func recentRows() []PickerRow {
	body, rc := pickerReadAll(vi.RecentLogPath, 8192)
	if rc < 0 {
		return nil
	}
	lines := strings.Split(strings.TrimRight(string(body), "\n"), "\n")
	var out []PickerRow
	seen := make(map[string]bool)
	for i := len(lines) - 1; i >= 0 && len(out) < pickMaxRec; i-- {
		f := strings.Split(lines[i], "|")
		if len(f) != 4 {
			continue
		}
		path, ok := hexDecode(f[3])
		if !ok || path == "" || seen[path] ||
			!strings.HasPrefix(path, pickerRoot+"/") {
			continue
		}
		seen[path] = true
		out = append(out, PickerRow{
			Label: path, Path: path,
			Kind: PickRecent, Mime: mime.Sniff(baseName(path), nil),
		})
	}
	return out
}

// hexDecode reads the recent log's hex(path) field without dragging in
// encoding/hex — the GOEDIT link is within 160 bytes of exec_program_max.
func hexDecode(s string) (string, bool) {
	if len(s)%2 != 0 {
		return "", false
	}
	nib := func(c byte) (byte, bool) {
		switch {
		case c >= '0' && c <= '9':
			return c - '0', true
		case c >= 'a' && c <= 'f':
			return c - 'a' + 10, true
		case c >= 'A' && c <= 'F':
			return c - 'A' + 10, true
		}
		return 0, false
	}
	b := make([]byte, len(s)/2)
	for i := 0; i < len(b); i++ {
		hi, ok1 := nib(s[2*i])
		lo, ok2 := nib(s[2*i+1])
		if !ok1 || !ok2 {
			return "", false
		}
		b[i] = hi<<4 | lo
	}
	return string(b), true
}

// trashRows lists the pending /host/TRASH items. Each .meta receipt names an
// item id; TrashRead validates the pair and returns the original path, so a
// row only ever describes a restorable file.
func trashRows() []PickerRow {
	var ents [vi.MaxDirEntries]vi.DirEntry
	n, rc := pickerDirList(vi.TrashDir, ents[:])
	if rc < 0 {
		return nil
	}
	var out []PickerRow
	for i := 0; i < n; i++ {
		name := ents[i].NameString()
		id, ok := strings.CutSuffix(name, ".meta")
		if !ok || ents[i].Dir() {
			continue
		}
		path, _, _, tr := pickerTrashRead(id)
		if tr < 0 {
			continue
		}
		out = append(out, PickerRow{
			Label: baseName(path), Path: path,
			Kind: PickTrash, TrashID: id, Mime: mime.Sniff(baseName(path), nil),
		})
	}
	return out
}

// --- navigation -------------------------------------------------------------

func (p *FilePicker) clampSel() {
	if p.Sel < 0 {
		p.Sel = 0
	}
	if p.Sel >= len(p.Rows) {
		p.Sel = len(p.Rows) - 1
	}
	if p.Sel < 0 {
		p.Sel = 0
	}
	p.ensureVisible()
}

// Move steps the selection by delta rows (clamped), keeping it on screen.
func (p *FilePicker) Move(delta int) bool {
	if len(p.Rows) == 0 {
		return false
	}
	p.Sel += delta
	p.clampSel()
	return true
}

// ensureVisible scrolls the window so Sel is inside it.
func (p *FilePicker) ensureVisible() {
	vis := p.visibleRows()
	if p.Sel < p.Scroll {
		p.Scroll = p.Sel
	}
	if p.Sel >= p.Scroll+vis {
		p.Scroll = p.Sel - vis + 1
	}
	if p.Scroll < 0 {
		p.Scroll = 0
	}
}

func (p *FilePicker) visibleRows() int {
	h := p.R.H - pickListTop - pickFooter
	if h < pickRowH {
		return 1
	}
	return h / pickRowH
}

// Selected returns the row the cursor is on, when one exists.
func (p *FilePicker) Selected() (PickerRow, bool) {
	if p.Sel < 0 || p.Sel >= len(p.Rows) {
		return PickerRow{}, false
	}
	return p.Rows[p.Sel], true
}

// UpDir climbs to the parent directory; a no-op at the share root.
func (p *FilePicker) UpDir() bool {
	if p.Dir == pickerRoot {
		return false
	}
	p.Dir = parentPath(p.Dir)
	p.Sel = 0
	p.refresh()
	return true
}

// Activate is Enter: with a typed Input it resolves the typed path (an
// existing directory descends instead of being picked); otherwise it runs
// the selected row — descend, pick, or restore-in-place for trash.
func (p *FilePicker) Activate() {
	if p.Input != "" {
		path := p.resolve(p.Input)
		if path == "" {
			p.Err = "bad path"
			return
		}
		if p.isDir(path) {
			p.Dir, p.Input, p.Sel = path, "", 0
			p.refresh()
			return
		}
		p.Result = path
		p.Open = false
		return
	}
	row, ok := p.Selected()
	if !ok {
		return
	}
	switch row.Kind {
	case PickUp, PickDir:
		p.Dir, p.Sel = row.Path, 0
		p.refresh()
	case PickFile, PickRecent:
		p.Result = row.Path
		p.Open = false
	case PickTrash:
		if _, rc := pickerTrashRestore(row.TrashID); rc < 0 {
			p.Err = "restore rc=" + strconv.FormatInt(rc, 10)
			return
		}
		p.Err = ""
		p.refresh()
	}
}

// isDir reports whether path lists as a directory — one DirList probe, the
// only existence check that costs a single round trip.
func (p *FilePicker) isDir(path string) bool {
	var ents [1]vi.DirEntry
	_, rc := pickerDirList(path, ents[:])
	return rc >= 0
}

// resolve turns Input into an absolute share path: an absolute spelling
// stays (it must root on /host), a bare name joins onto Dir. It refuses the
// shapes the share contract refuses — over-long, empty or dot segments,
// control bytes — returning "" so the caller can name the refusal.
func (p *FilePicker) resolve(in string) string {
	in = strings.TrimSpace(in)
	if in == "" {
		return ""
	}
	var path string
	if strings.HasPrefix(in, "/") {
		path = in
	} else {
		path = joinPath(p.Dir, in)
	}
	if !strings.HasPrefix(path, pickerRoot+"/") || len(path) > 64 {
		return ""
	}
	for _, part := range strings.Split(path[len(pickerRoot)+1:], "/") {
		if part == "" || part == "." || part == ".." {
			return ""
		}
	}
	for i := 0; i < len(path); i++ {
		if path[i] < 0x20 || path[i] == 0x7f {
			return ""
		}
	}
	return path
}

// Cancel closes the picker without a path, the same receipt Dialog gives.
func (p *FilePicker) Cancel() {
	p.Result = "cancel"
	p.Open = false
}

// choose runs the focused button: the verb button is Activate, Cancel is
// Cancel — identical outcomes to the list path, so focus is only about
// which Enter the user meant.
func (p *FilePicker) choose() {
	if p.Focus == 1 {
		p.Cancel()
		return
	}
	p.Activate()
}

// HandleKey consumes one event while the picker is open. changed means the
// caller should repaint; done means the picker has produced its Result and
// closed. The event wire exposes the HID usage in Arg0 and the decoded
// symbol in Arg1; both spellings are accepted, matching Dialog.
func (p *FilePicker) HandleKey(ev vi.Event) (changed, done bool) {
	if !p.Open || ev.Kind != vi.EvKeyDown {
		return false, false
	}
	usage, ch := ev.Arg0, ev.Arg1
	switch {
	case usage == 0x28 || ch == '\r' || ch == '\n':
		p.choose()
		return true, !p.Open
	case usage == 0x29 || ch == 0x1b:
		p.Cancel()
		return true, true
	case usage == 0x2b || ch == '\t':
		// -1 (the list) -> buttons -> back to the list.
		p.Focus++
		if p.Focus >= len(p.Buttons) {
			p.Focus = -1
		}
		return true, false
	case usage == 0x52:
		return p.Move(-1), false
	case usage == 0x51:
		return p.Move(1), false
	case usage == 0x4a:
		p.Sel = 0
		p.clampSel()
		return true, false
	case usage == 0x4d:
		p.Sel = len(p.Rows) - 1
		p.clampSel()
		return true, false
	case usage == 0x4b:
		return p.Move(-p.visibleRows()), false
	case usage == 0x4e:
		return p.Move(p.visibleRows()), false
	case usage == 0x2a || ch == 0x08 || ch == 0x7f:
		if p.Input != "" {
			_, size := utf8.DecodeLastRuneInString(p.Input)
			p.Input = p.Input[:len(p.Input)-size]
			return true, false
		}
		return p.UpDir(), false
	case ch >= 0x20 && ch != 0x7f && utf8.RuneLen(rune(ch)) > 0 &&
		len(p.Input)+utf8.RuneLen(rune(ch)) <= pickMaxInput:
		p.Input += string(rune(ch))
		return true, false
	}
	return false, false
}

// HandleMouse handles a left-button press at a canvas point: a click on a
// row selects it, a click on the already-selected row activates it (the
// poor-man's double-click), and a click on a button chooses it.
func (p *FilePicker) HandleMouse(x, y int, down bool) (changed, done bool) {
	if !p.Open || !down {
		return false, false
	}
	p.layoutButtons()
	for i := range p.Buttons {
		if p.Buttons[i].R.Contains(x, y) {
			p.Focus = i
			p.choose()
			return true, !p.Open
		}
	}
	if i := p.rowAt(x, y); i >= 0 {
		if i == p.Sel {
			p.Focus = -1
			p.Activate()
			return true, !p.Open
		}
		p.Sel = i
		p.Focus = -1
		p.clampSel()
		return true, false
	}
	return false, false
}

// rowAt maps a canvas point to a Rows index through the same rect math Draw
// uses — the widgets rule that hit and paint share one geometry source.
func (p *FilePicker) rowAt(x, y int) int {
	lr := p.listRect()
	if !lr.Contains(x, y) {
		return -1
	}
	i := (y-lr.Y)/pickRowH + p.Scroll
	if i < 0 || i >= len(p.Rows) {
		return -1
	}
	return i
}

// --- geometry ---------------------------------------------------------------

func (p *FilePicker) listRect() widgets.Rect {
	tok := theme.Current
	inset := tok.PadMD + tok.PadSM
	return widgets.Rect{
		X: p.R.X + inset,
		Y: p.R.Y + pickListTop,
		W: p.R.W - 2*inset,
		H: p.R.H - pickListTop - pickFooter - 8,
	}
}

func (p *FilePicker) inputRect() widgets.Rect {
	lr := p.listRect()
	return widgets.Rect{X: lr.X, Y: lr.Bottom() + 6, W: lr.W, H: 22}
}

// layoutButtons right-aligns the verb then Cancel inside the plate's footer,
// the same rule Dialog keeps (so a moved dialog re-derives them too).
func (p *FilePicker) layoutButtons() {
	tok := theme.Current
	x := p.R.Right() - (tok.PadMD + tok.PadSM)
	y := p.R.Bottom() - (tok.PadMD + tok.PadSM) - 26
	for i := len(p.Buttons) - 1; i >= 0; i-- {
		x -= 72
		p.Buttons[i].R = widgets.Rect{X: x, Y: y, W: 72, H: 26}
		x -= tok.PadSM
	}
}

// --- drawing ----------------------------------------------------------------

// Draw paints the picker plate on the caller's own window canvas: title row,
// the current directory, the row list with per-kind glyphs and the selected
// row's highlight, the path/name field, and the buttons. A nil UIFace keeps
// the §3.4 bitmap-face degrade; a nil IconFace drops the glyph column only —
// the mime tag on file rows still names the type.
func (p *FilePicker) Draw(c widgets.Canvas) {
	if !p.Open {
		return
	}
	p.layoutButtons()
	tok := theme.Current
	inset := tok.PadMD + tok.PadSM
	c.FillRoundedRect(p.R, 8, draw.Opaque(tok.Surface))
	c.StrokeRoundedRect(p.R, 8, tok.BorderW, draw.Opaque(tok.Border))

	// Title and directory.
	title := widgets.Rect{X: p.R.X + inset + 20, Y: p.R.Y + inset, W: p.R.W - 2*inset - 20, H: 24}
	p.icon(c, "folder", widgets.Rect{X: p.R.X + inset, Y: p.R.Y + inset, W: 16, H: 24})
	dialogText(c, p.UIFace, title, p.Title, tok.Text, false)
	dirbar := widgets.Rect{X: p.R.X + inset, Y: p.R.Y + 36, W: p.R.W - 2*inset, H: 18}
	dirText := p.Dir
	if p.Err != "" {
		dirText += "  ·  " + p.Err
	}
	dialogText(c, p.UIFace, dirbar, dirText, tok.Muted, false)

	// Rows.
	lr := p.listRect()
	for i := p.Scroll; i < len(p.Rows); i++ {
		rr := widgets.Rect{X: lr.X, Y: lr.Y + (i-p.Scroll)*pickRowH, W: lr.W, H: pickRowH}
		if rr.Y >= lr.Bottom() {
			break
		}
		row := p.Rows[i]
		if i == p.Sel && p.Focus == -1 {
			sel := tok.Selection
			if sel == 0 {
				sel = tok.ChromeBg
			}
			c.FillRect(rr, draw.Opaque(sel))
			c.FillRect(widgets.Rect{X: rr.X, Y: rr.Y + 1, W: 3, H: rr.H - 2}, draw.Opaque(tok.Accent))
		}
		icon := pickIcon(row)
		label := widgets.Rect{X: rr.X + 20, Y: rr.Y, W: rr.W - 20, H: rr.H}
		if icon == "" {
			label.X = rr.X + 4
			label.W = rr.W - 4
		}
		p.icon(c, icon, widgets.Rect{X: rr.X + 2, Y: rr.Y, W: 16, H: rr.H})
		fg := tok.Text
		detail := pickDetail(row)
		if row.Kind == PickTrash || row.Kind == PickRecent {
			fg = tok.Muted
		}
		dialogText(c, p.UIFace, label, row.Label, fg, false)
		if detail != "" {
			dr := widgets.Rect{X: label.X, Y: rr.Y, W: label.W, H: rr.H}
			dialogText(c, p.UIFace, rightAligned(dr, detail, p.UIFace), detail, tok.Muted, false)
		}
	}

	// The typed path/name field: labelled Path: or Name: by verb, bordered,
	// with the caret rule Dialog's prompt row keeps.
	ir := p.inputRect()
	prompt := "Path: "
	if p.Kind == PickSave {
		prompt = "Name: "
	}
	labelR := widgets.Rect{X: ir.X, Y: ir.Y, W: 48, H: ir.H}
	dialogText(c, p.UIFace, labelR, prompt, tok.Muted, false)
	field := widgets.Rect{X: ir.X + 48, Y: ir.Y, W: ir.W - 48, H: ir.H}
	c.FillRoundedRect(field, 4, draw.Opaque(tok.ChromeBg))
	c.StrokeRoundedRect(field, 4, tok.BorderW, draw.Opaque(tok.Border))
	dialogText(c, p.UIFace, field.Inset(tok.PadSM), p.Input, tok.Ink, false)
	caretX := field.X + tok.PadSM + 1
	if p.UIFace != nil {
		for _, ch := range p.Input {
			caretX += p.UIFace.AdvancePx(ch, 13)
		}
	} else {
		caretX += len(p.Input) * 8
	}
	caretX = min(caretX, field.Right()-tok.PadSM-1)
	c.FillRect(widgets.Rect{X: caretX, Y: field.Y + 4, W: 1, H: 14}, draw.Opaque(tok.Caret))

	// Buttons — the verb carries the accent edge, the focus ring follows Tab.
	for i := range p.Buttons {
		b := p.Buttons[i]
		face, border, label := tok.BtnIdle, tok.Border, tok.Text
		if i == p.Focus {
			face, border = tok.BtnHover, tok.Accent
		}
		if i == 0 {
			border, label = tok.Accent, tok.OnAccent
		}
		c.FillRoundedRect(b.R, 4, draw.Opaque(face))
		c.StrokeRoundedRect(b.R, 4, tok.BorderW, draw.Opaque(border))
		if i == p.Focus {
			c.StrokeRoundedRect(b.R, 4, tok.FocusW, draw.Opaque(tok.Accent))
		}
		dialogText(c, p.UIFace, b.R.Inset(tok.PadSM), b.Label, label, true)
	}
}

// icon paints one row glyph through the Chrome face; a missing name or face
// skips the glyph — callers never see a blank box for an absent icon.
func (p *FilePicker) icon(c widgets.Canvas, name string, r widgets.Rect) {
	if name == "" || p.IconFace == nil {
		return
	}
	if cp, ok := icons.Codepoint(name); ok {
		draw.Glyph(c, p.IconFace, r, r.X, r.Y+r.H-2, icons.NominalPx, cp, draw.Opaque(theme.Current.Accent))
	}
}

// pickIcon maps a row onto its glyph: the class the mime table names where a
// glyph exists (audio plays, a guest binary is the gear), folder/chevron for
// the nav rows, and the window-restore glyph for trash — its action IS a
// restore.
func pickIcon(row PickerRow) string {
	switch row.Kind {
	case PickUp:
		return "chevron-up"
	case PickDir:
		return "folder"
	case PickTrash:
		return "window-restore"
	case PickRecent:
		return "file"
	}
	switch row.Mime {
	case mime.Audio:
		return "volume"
	case mime.Binary:
		return "settings-gear"
	}
	return "file"
}

// pickDetail is the right-aligned muted tag: the mime name for files (the
// part the glyph cannot spell), or the row's role for the synthetic kinds.
func pickDetail(row PickerRow) string {
	switch row.Kind {
	case PickDir:
		return "dir"
	case PickRecent:
		return "recent"
	case PickTrash:
		return "trash · enter restores"
	case PickUp:
		return "up"
	}
	if s := row.Mime.String(); s != "" {
		return s
	}
	return ""
}

// rightAligned shifts a text rect so a face-rendered detail ends at the
// list's right edge; with no face the 8px cell estimate does the same.
func rightAligned(r widgets.Rect, s string, face *ttf.Face) widgets.Rect {
	w := len(s) * 8
	if face != nil {
		w = 0
		for _, ch := range s {
			w += face.AdvancePx(ch, 13)
		}
	}
	if w >= r.W {
		return r
	}
	return widgets.Rect{X: r.Right() - w, Y: r.Y, W: w, H: r.H}
}

// --- path helpers (share-local, no syscall) -----------------------------------

// parentPath strips the last segment; "/host" is the floor — the picker
// never climbs off the share.
func parentPath(path string) string {
	if i := strings.LastIndexByte(path, '/'); i > len(pickerRoot) {
		return path[:i]
	}
	return pickerRoot
}

// joinPath appends name under dir; the root keeps its single slash.
func joinPath(dir, name string) string {
	if dir == "/" || dir == "" {
		return "/" + name
	}
	return dir + "/" + name
}

// baseName is the path's last segment.
func baseName(path string) string {
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		return path[i+1:]
	}
	return path
}
