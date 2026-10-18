package outbox

import (
	"strings"
	"testing"

	"virelai/vi"
)

// memIO is an in-memory IO: files holds path -> bytes, dirs the
// directory set. Opens hand out monotonically-numbered handles into
// openFiles so reads and writes drive the same buffers the map holds.
type memIO struct {
	IO
	files map[string][]byte
	dirs  map[string]bool
	open  map[uint32]*memHandle
	next  uint32
	rand  uint32
}

type memHandle struct {
	path   string
	writes bool // data may be committed on close
	buf    []byte
	off    int
}

func newMemIO(dirs ...string) *memIO {
	m := &memIO{
		files: map[string][]byte{},
		dirs:  map[string]bool{},
		open:  map[uint32]*memHandle{},
	}
	for _, d := range dirs {
		m.dirs[d] = true
	}
	m.IO = IO{
		Open: func(path string, flags uint32) (int64, int64) {
			if m.dirs[path] {
				return vi.ErrFileIsDir, vi.ErrFileIsDir
			}
			if flags&vi.ModeRead != 0 {
				if _, ok := m.files[path]; !ok {
					return vi.ErrFileNotFound, vi.ErrFileNotFound
				}
			}
			m.next++
			h := &memHandle{path: path, writes: flags&vi.ModeWrite != 0}
			if flags&vi.ModeRead != 0 {
				h.buf = m.files[path]
			}
			m.open[m.next] = h
			return int64(m.next), int64(m.next)
		},
		Read: func(h uint32, buf []byte) (int, int64) {
			f, ok := m.open[h]
			if !ok {
				return 0, -vi.ErrEINVAL
			}
			if f.off >= len(f.buf) {
				return 0, 0
			}
			n := copy(buf, f.buf[f.off:])
			f.off += n
			return n, int64(n)
		},
		WriteAll: func(h uint32, b []byte) (int, int64) {
			f, ok := m.open[h]
			if !ok || !f.writes {
				return 0, -vi.ErrEINVAL
			}
			f.buf = append(f.buf, b...)
			return len(b), 0
		},
		Sync: func(h uint32) int64 { return 0 },
		Close: func(h uint32) {
			if f, ok := m.open[h]; ok && f.writes {
				m.files[f.path] = f.buf
			}
			delete(m.open, h)
		},
		Delete: func(path string) int64 {
			if _, ok := m.files[path]; !ok {
				return vi.ErrFileNotFound
			}
			delete(m.files, path)
			return 0
		},
		Rename: func(oldPath, newPath string) int64 {
			b, ok := m.files[oldPath]
			if !ok {
				return vi.ErrFileNotFound
			}
			if _, exists := m.files[newPath]; exists {
				return -9 // the HF rename refuses a live target
			}
			delete(m.files, oldPath)
			m.files[newPath] = b
			return 0
		},
		IsDir: func(path string) bool { return m.dirs[path] },
		WriteSafe: func(path string, b []byte) int64 {
			m.files[path] = append([]byte(nil), b...)
			return 0
		},
		Rand: func(p []byte) (int, error) {
			m.rand++
			for i := range p {
				p[i] = byte(m.rand >> (8 * i))
			}
			return len(p), nil
		},
	}
	return m
}

func TestNameSanitizeAndValidate(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"PHOTO.QOI", "PHOTO.QOI"},
		{"odd name!.qoi", "odd_name_.qoi"},
		{"-leading", "F-leading"},
		{".hidden", "F.hidden"},
		{"a/b/c.txt", "c.txt"},
	} {
		base := tc.in
		for i := len(base) - 1; i >= 0; i-- {
			if base[i] == '/' {
				base = base[i+1:]
				break
			}
		}
		got, ok := Name(base)
		if !ok || got != tc.want {
			t.Fatalf("Name(%q) = %q,%v want %q", tc.in, got, ok, tc.want)
		}
		if !NameValid(got) {
			t.Fatalf("sanitized name %q fails the validator", got)
		}
	}
	long, ok := Name(strings.Repeat("x", 60) + ".txt")
	if !ok || len(long) != NameMax {
		t.Fatalf("long name = %q (%d bytes)", long, len(long))
	}
	for _, bad := range []string{"", "../etc", ".", "a/b", "x y", "REQ-00000001~", "na\nme"} {
		if NameValid(bad) {
			t.Fatalf("NameValid(%q) held", bad)
		}
	}
	// The traversal pins: no byte the charset admits can walk a path —
	// '/' and control bytes fold or fail, '.' alone can never lead.
	for _, bad := range []string{"..", "..x", ".x", "a/../b"} {
		if NameValid(bad) {
			t.Fatalf("NameValid(%q) held a traversal name", bad)
		}
	}
}

func TestReqNameShape(t *testing.T) {
	if got := ReqName(0xdeadbeef); got != "REQ-deadbeef" {
		t.Fatalf("ReqName = %q", got)
	}
	for _, n := range []string{"REQ-deadbeef", "REQ-00000000", "REQ-DEADBEEF"} {
		if !IsReqName(n) {
			t.Fatalf("IsReqName(%q) = false", n)
		}
	}
	for _, n := range []string{"REQ-", "REQ-1234567", "REQ-123456789", "REQ-zzzzzzzz",
		"req-00000001", "XREQ-00000001", "OUTBOX-00000001"} {
		if IsReqName(n) {
			t.Fatalf("IsReqName(%q) = true", n)
		}
	}
}

func TestExportStagesPayloadThenMarker(t *testing.T) {
	m := newMemIO(Dir)
	m.files["/host/docs/notes.txt"] = []byte("round trip\n")
	name, refusal := m.IO.Export("/host/docs/notes.txt")
	if refusal != "" || name != "notes.txt" {
		t.Fatalf("Export = %q,%q", name, refusal)
	}
	if string(m.files[Dir+"/notes.txt"]) != "round trip\n" {
		t.Fatal("payload did not land")
	}
	var reqs []string
	for p := range m.files {
		if strings.HasPrefix(p, Dir+"/REQ-") {
			reqs = append(reqs, p)
		}
	}
	if len(reqs) != 1 {
		t.Fatalf("REQ markers = %v", reqs)
	}
	if string(m.files[reqs[0]]) != "notes.txt" {
		t.Fatalf("REQ content = %q", m.files[reqs[0]])
	}
	if _, ok := m.files[Dir+"/notes.txt~"]; ok {
		t.Fatal("publish temp survived")
	}
}

func TestExportRefusals(t *testing.T) {
	m := newMemIO(Dir)
	// Missing source: gone.
	if _, r := m.IO.Export("/host/nothing.txt"); r != RefuseGone {
		t.Fatalf("missing source = %q want gone", r)
	}
	// A directory: unsupported_kind.
	m.dirs["/host/subdir"] = true
	if _, r := m.IO.Export("/host/subdir"); r != RefuseUnsupported {
		t.Fatalf("dir source = %q want unsupported_kind", r)
	}
	// No honest name: name_rejected.
	if _, r := m.IO.Export("/host/"); r != RefuseNameRejected {
		t.Fatalf("empty basename = %q want name_rejected", r)
	}
}

func TestExportOverCapRefused(t *testing.T) {
	m := newMemIO(Dir)
	// The copy counts as it streams; a file over FileMax must be refused
	// and leave neither payload nor temp nor marker. Feeding real bytes
	// of 64 MiB is heavy for a unit test — the fake reads report the
	// size in ONE shot past the cap via a custom Read.
	m.IO.Read = func(h uint32, buf []byte) (int, int64) {
		f := m.open[h]
		if f.off == 0 {
			f.off = 1
			return len(buf), int64(len(buf))
		}
		if f.off == 1 {
			f.off = 2
			return int(FileMax), int64(FileMax)
		}
		return 0, 0
	}
	m.files["/host/big.bin"] = []byte("x")
	if _, r := m.IO.Export("/host/big.bin"); r != RefuseTooLarge {
		t.Fatalf("over-cap export = %q want payload_too_large", r)
	}
	for p := range m.files {
		if strings.HasPrefix(p, Dir+"/") {
			t.Fatalf("refused export left %q behind", p)
		}
	}
}
