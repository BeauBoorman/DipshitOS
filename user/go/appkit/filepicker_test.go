package appkit

import (
	"encoding/hex"
	"testing"

	"virelai/vi"
)

// stubPickerFiles installs an in-memory share: dirs maps a directory path to
// its entries, logBody is the recent log's bytes, trash maps an item id to
// (recorded original path, body) — the seam bundle refresh/handle paths read.
func stubPickerFiles(t *testing.T, dirs map[string][]vi.DirEntry, logBody string, trash map[string]string) {
	t.Helper()
	odl, ora, otr, ores := pickerDirList, pickerReadAll, pickerTrashRead, pickerTrashRestore
	pickerDirList = func(path string, buf []vi.DirEntry) (int, int64) {
		ents, ok := dirs[path]
		if !ok {
			return 0, vi.ErrFileNotFound
		}
		n := copy(buf, ents)
		return n, int64(n)
	}
	pickerReadAll = func(path string, max int) ([]byte, int64) {
		if path == vi.RecentLogPath {
			if logBody == "" {
				return nil, vi.ErrFileNotFound
			}
			return []byte(logBody), int64(len(logBody))
		}
		return nil, vi.ErrFileNotFound
	}
	pickerTrashRead = func(id string) (string, []byte, int64, int64) {
		if path, ok := trash[id]; ok {
			return path, []byte("body"), 1, 4
		}
		return "", nil, 0, vi.ErrFileNotFound
	}
	pickerTrashRestore = func(id string) (string, int64) {
		path, ok := trash[id]
		if !ok {
			return "", vi.ErrFileNotFound
		}
		delete(trash, id)
		return path, 0
	}
	t.Cleanup(func() {
		pickerDirList, pickerReadAll, pickerTrashRead, pickerTrashRestore = odl, ora, otr, ores
	})
}

func dirEnt(name string, isDir bool) vi.DirEntry {
	var e vi.DirEntry
	copy(e.Name[:], name)
	if isDir {
		e.IsDir = 1
	}
	return e
}

func keyEv(usage uint32, ch rune) vi.Event {
	return vi.Event{Kind: vi.EvKeyDown, Arg0: usage, Arg1: uint32(ch)}
}

func TestPickerListsDirsFilesRecentsAndTrash(t *testing.T) {
	log := "100|delete|aaaaaaaaaaaaaaaa|" + hex.EncodeToString([]byte("/host/OLD.TXT")) + "\n" +
		"101|restore|bbbbbbbbbbbbbbbb|" + hex.EncodeToString([]byte("/host/OLD.TXT")) + "\n" +
		"102|delete|cccccccccccccccc|" + hex.EncodeToString([]byte("/host/NEW.TXT")) + "\n"
	stubPickerFiles(t, map[string][]vi.DirEntry{
		"/host":     {dirEnt("DOCS", true), dirEnt("A.TXT", false), dirEnt("B.PNG", false)},
		vi.TrashDir: {dirEnt("dddddddddddddddd.meta", false)},
	}, log, map[string]string{"dddddddddddddddd": "/host/GONE.TXT"})

	p := NewFilePicker(PickOpen, "/host")
	var dirs, files, recents, trashs int
	for _, r := range p.Rows {
		switch r.Kind {
		case PickDir:
			dirs++
			if r.Path != "/host/DOCS" {
				t.Fatalf("dir row path %q", r.Path)
			}
		case PickFile:
			files++
		case PickRecent:
			recents++
		case PickTrash:
			trashs++
		}
	}
	if dirs != 1 || files != 2 || recents != 2 || trashs != 1 {
		t.Fatalf("row mix dirs=%d files=%d recents=%d trash=%d", dirs, files, recents, trashs)
	}
	// Recents dedupe to distinct paths, newest first.
	if p.Rows[3].Path != "/host/NEW.TXT" || p.Rows[4].Path != "/host/OLD.TXT" {
		t.Fatalf("recent order %q %q", p.Rows[3].Path, p.Rows[4].Path)
	}
	// The trash row keeps the receipt id and names the original path.
	if p.Rows[5].TrashID != "dddddddddddddddd" || p.Rows[5].Path != "/host/GONE.TXT" {
		t.Fatalf("trash row %+v", p.Rows[5])
	}
	// B.PNG's name-based sniff carries its mime onto the row.
	if p.Rows[2].Mime.String() != "image" {
		t.Fatalf("B.PNG mime %s", p.Rows[2].Mime)
	}
}

func TestPickerDescendsAndPicksAFile(t *testing.T) {
	stubPickerFiles(t, map[string][]vi.DirEntry{
		"/host":      {dirEnt("DOCS", true)},
		"/host/DOCS": {dirEnt("NOTE.TXT", false)},
	}, "", nil)

	p := NewFilePicker(PickOpen, "/host")
	if _, done := p.HandleKey(keyEv(0x28, '\r')); done {
		t.Fatal("enter on the dir row closed the picker instead of descending")
	}
	if p.Dir != "/host/DOCS" || !p.Open {
		t.Fatalf("after descend dir=%q open=%v", p.Dir, p.Open)
	}
	// Row 0 is now the climb row; row 1 is the file.
	if p.Rows[0].Kind != PickUp || p.Rows[1].Path != "/host/DOCS/NOTE.TXT" {
		t.Fatalf("rows %+v", p.Rows)
	}
	p.Move(1)
	if _, done := p.HandleKey(keyEv(0x28, '\r')); !done || p.Open {
		t.Fatal("enter on a file row did not pick")
	}
	if p.Result != "/host/DOCS/NOTE.TXT" {
		t.Fatalf("result %q", p.Result)
	}
}

func TestPickerClimbRowAndBackspaceGoUp(t *testing.T) {
	stubPickerFiles(t, map[string][]vi.DirEntry{
		"/host":      {dirEnt("DOCS", true)},
		"/host/DOCS": {},
	}, "", nil)
	p := NewFilePicker(PickOpen, "/host/DOCS")
	// Backspace with no input climbs.
	if changed, _ := p.HandleKey(keyEv(0x2a, 0x7f)); !changed || p.Dir != "/host" {
		t.Fatalf("backspace climb dir=%q", p.Dir)
	}
}

func TestPickerTypedPathResolvesAndDirDescends(t *testing.T) {
	stubPickerFiles(t, map[string][]vi.DirEntry{
		"/host":      {dirEnt("DOCS", true), dirEnt("A.TXT", false)},
		"/host/DOCS": {},
	}, "", nil)
	p := NewFilePicker(PickOpen, "/host")
	for _, r := range "DOCS" {
		p.HandleKey(keyEv(0, r))
	}
	if _, done := p.HandleKey(keyEv(0x28, '\r')); done {
		t.Fatal("typed dir was picked instead of descending")
	}
	if p.Dir != "/host/DOCS" {
		t.Fatalf("dir %q", p.Dir)
	}
	// A typed file name resolves against the current dir.
	for _, r := range "/host/A.TXT" {
		p.HandleKey(keyEv(0, r))
	}
	if _, done := p.HandleKey(keyEv(0x28, '\r')); !done {
		t.Fatal("typed file was not picked")
	}
	if p.Result != "/host/A.TXT" {
		t.Fatalf("result %q", p.Result)
	}
}

func TestPickerRejectsBadPaths(t *testing.T) {
	stubPickerFiles(t, map[string][]vi.DirEntry{"/host": {}}, "", nil)
	p := NewFilePicker(PickSave, "/host")
	for _, r := range "../escape" {
		p.HandleKey(keyEv(0, r))
	}
	if _, done := p.HandleKey(keyEv(0x28, '\r')); done {
		t.Fatal("dot-segment path was accepted")
	}
	if p.Err == "" || p.Open == false {
		t.Fatalf("refusal did not stay open with an error: %+v", p)
	}
}

func TestPickerTrashRowRestoresInPlace(t *testing.T) {
	stubPickerFiles(t, map[string][]vi.DirEntry{
		"/host":     {},
		vi.TrashDir: {dirEnt("dddddddddddddddd.meta", false)},
	}, "", map[string]string{"dddddddddddddddd": "/host/GONE.TXT"})
	p := NewFilePicker(PickOpen, "/host")
	if p.Rows[0].Kind != PickTrash {
		t.Fatalf("row 0 %+v", p.Rows[0])
	}
	if _, done := p.HandleKey(keyEv(0x28, '\r')); done {
		t.Fatal("trash row was picked instead of restored")
	}
	if !p.Open || p.Result != "" {
		t.Fatalf("restore closed the picker: %+v", p)
	}
	// The item is gone from the refresh (the stub deleted it).
	for _, r := range p.Rows {
		if r.Kind == PickTrash {
			t.Fatalf("restored row still listed: %+v", r)
		}
	}
}

func TestPickerCancelAndEscape(t *testing.T) {
	stubPickerFiles(t, map[string][]vi.DirEntry{"/host": {}}, "", nil)
	p := NewFilePicker(PickOpen, "/host")
	if _, done := p.HandleKey(keyEv(0x29, 0x1b)); !done || p.Open {
		t.Fatal("escape did not close")
	}
	if p.Result != "cancel" {
		t.Fatalf("result %q", p.Result)
	}
}

func TestPickerSaveModeVerbsAndTabsFocus(t *testing.T) {
	stubPickerFiles(t, map[string][]vi.DirEntry{"/host": {dirEnt("A.TXT", false)}}, "", nil)
	p := NewFilePicker(PickSave, "/host")
	if p.Buttons[0].Label != "Save as" {
		t.Fatalf("verb %q", p.Buttons[0].Label)
	}
	// Tab walks list -> verb -> cancel -> list.
	p.HandleKey(keyEv(0x2b, '\t'))
	if p.Focus != 0 {
		t.Fatalf("focus %d", p.Focus)
	}
	p.HandleKey(keyEv(0x2b, '\t'))
	if p.Focus != 1 {
		t.Fatalf("focus %d", p.Focus)
	}
	// Enter on the cancel button cancels.
	if _, done := p.HandleKey(keyEv(0x28, '\r')); !done || p.Result != "cancel" {
		t.Fatalf("cancel-button enter: %+v", p)
	}
}

func TestPickerMouseSelectThenActivate(t *testing.T) {
	stubPickerFiles(t, map[string][]vi.DirEntry{
		"/host": {dirEnt("A.TXT", false), dirEnt("B.TXT", false)},
	}, "", nil)
	p := NewFilePicker(PickOpen, "/host")
	lr := p.listRect()
	x, y := lr.X+8, lr.Y+pickRowH+1 // row 1
	if _, done := p.HandleMouse(x, y, true); done || p.Sel != 1 {
		t.Fatalf("click did not select row 1: sel=%d done=%v", p.Sel, done)
	}
	if _, done := p.HandleMouse(x, y, true); !done {
		t.Fatal("second click on the selected row did not activate")
	}
	if p.Result != "/host/B.TXT" {
		t.Fatalf("result %q", p.Result)
	}
}
