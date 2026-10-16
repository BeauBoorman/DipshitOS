package pdfproof

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"virelai/pdf"
	"virelai/vi"
)

type fake struct {
	data, output                               []byte
	position                                   int
	handles, peak, opens, reads, closes, syncs int
	short                                      int
	readFail, writeFail, syncFail, exists      bool
}

func (f *fake) files() files {
	return files{
		open: func(_ string, mode uint32) (int64, int64) {
			if mode == vi.ModeRead && f.exists {
				f.handles++
				f.peak = max(f.peak, f.handles)
				return 1, 1
			}
			if mode == vi.ModeRead && f.output != nil {
				return -1, -vi.ErrENOENT
			}
			f.handles++
			f.peak = max(f.peak, f.handles)
			f.opens++
			f.position = 0
			return 1, 1
		},
		read: func(_ uint32, b []byte) (int, int64) {
			f.reads++
			if f.readFail {
				return 0, -vi.ErrEINVAL
			}
			n := len(b)
			if f.short > 0 {
				n = min(n, f.short)
			}
			n = copy(b[:n], f.data[f.position:])
			f.position += n
			return n, int64(n)
		},
		close: func(_ uint32) { f.handles--; f.closes++ },
		write: func(_ uint32, b []byte) (int, int64) {
			if f.writeFail {
				return 0, 0
			}
			n := len(b)
			if f.short > 0 {
				n = min(n, f.short)
			}
			f.output = append(f.output, b[:n]...)
			return n, int64(n)
		},
		sync: func(_ uint32) int64 {
			f.syncs++
			if f.syncFail {
				return -vi.ErrEINVAL
			}
			return 0
		},
	}
}

func source(f *fake) Source {
	s := NewSource("input", make([]byte, chunk))
	s.fs = f.files()
	return s
}
func ledger() pdf.Ledger { return pdf.Ledger{Max: pdf.MaxWork} }

func TestAdmissionReopenDiscardAndRecheck(t *testing.T) {
	f := fake{data: bytes.Repeat([]byte("abcdefg"), 20000), short: 113}
	s, l := source(&f), ledger()
	if c := s.Admit(&l); c != pdf.OK || s.Length() != int64(len(f.data)) || s.Hash() != sha256.Sum256(f.data) {
		t.Fatal(c, s.Length())
	}
	if l.Handles != 0 || f.handles != 0 || l.Counts[pdf.Hash] != uint64(len(f.data)+128) {
		t.Fatal("admission counters", l)
	}
	for _, off := range []int64{65536, 66000, 7, 100000, 0} {
		b := make([]byte, 256)
		n, c := s.ReadAt(b, off, &l)
		if c != pdf.OK || n != len(b) || !bytes.Equal(b, f.data[off:off+256]) {
			t.Fatal(off, n, c)
		}
	}
	if l.Rewinds != 2 || f.peak != 1 {
		t.Fatal(l.Rewinds, f.peak)
	}
	if c := s.Recheck(&l); c != pdf.OK || l.Rewinds != 3 || f.handles != 0 || l.Handles != 0 {
		t.Fatal(c, l)
	}
}

func TestSourceCapAndMutation(t *testing.T) {
	for _, n := range []int{pdf.MaxSource, pdf.MaxSource + 1} {
		f := fake{data: make([]byte, n)}
		s, l := source(&f), ledger()
		want := pdf.OK
		if n > pdf.MaxSource {
			want = pdf.SourceLimit
		}
		if c := s.Admit(&l); c != want || f.handles != 0 {
			t.Fatal(n, c)
		}
	}
	for _, kind := range []string{"hash", "short", "long", "io"} {
		f := fake{data: []byte("original")}
		s, l := source(&f), ledger()
		if c := s.Admit(&l); c != pdf.OK {
			t.Fatal(c)
		}
		switch kind {
		case "hash":
			f.data[0]++
		case "short":
			f.data = f.data[:3]
		case "long":
			f.data = append(f.data, 0)
		case "io":
			f.readFail = true
		}
		want := pdf.SourceChanged
		if kind == "io" {
			want = pdf.ReadFailed
		}
		if c := s.Recheck(&l); c != want || f.handles != 0 || l.Handles != 0 {
			t.Fatal(kind, c)
		}
	}
}

func TestFailedAttemptAndCleanupRemainCharged(t *testing.T) {
	f := fake{data: []byte("data")}
	s, l := source(&f), ledger()
	if c := s.Admit(&l); c != pdf.OK {
		t.Fatal(c)
	}
	before := l.Used
	f.readFail = true
	if _, c := s.ReadAt(make([]byte, 4), 0, &l); c != pdf.ReadFailed || l.Used <= before {
		t.Fatal(c)
	}
	l.Max = l.Used
	if c := s.Close(&l); c != pdf.WorkLimit || l.Handles != 0 || f.handles != 0 {
		t.Fatal(c, l.Handles)
	}
	l = ledger()
	l.Handles = 2
	if _, c := s.ReadAt(make([]byte, 4), 0, &l); c != pdf.HandleLimit || s.opened {
		t.Fatal(c)
	}
}

func TestPublishConfirmedWritesAndNoOverwrite(t *testing.T) {
	p := pdf.Page{Width: 2, Height: 1, Stride: 2, Pix: []uint32{0xff123456, 0xffffffff}}
	for _, kind := range []string{"good", "exists", "write", "sync"} {
		f := fake{output: make([]byte, 0), short: 3}
		switch kind {
		case "exists":
			f.exists = true
		case "write":
			f.writeFail = true
		case "sync":
			f.syncFail = true
		}
		l := ledger()
		c := publish(f.files(), "fresh", p, make([]byte, 16), &l)
		want := pdf.OK
		if kind == "exists" {
			want = pdf.OutputExists
		}
		if kind == "write" || kind == "sync" {
			want = pdf.WriteFailed
		}
		if c != want || l.Handles != 0 || f.handles != 0 || f.peak > 1 {
			t.Fatal(kind, c, f.handles)
		}
		if kind == "good" {
			if string(f.output[:4]) != "PDF1" || len(f.output) != 24 || binary.LittleEndian.Uint32(f.output[16:]) != p.Pix[0] || f.syncs != 1 {
				t.Fatal(f.output)
			}
		}
		if kind == "exists" && len(f.output) != 0 {
			t.Fatal("overwritten")
		}
	}
}

func TestReuseWithoutAllocation(t *testing.T) {
	f := fake{data: bytes.Repeat([]byte("x"), 10000)}
	s, l := source(&f), ledger()
	b := make([]byte, 64)
	if c := s.Admit(&l); c != pdf.OK {
		t.Fatal(c)
	}
	allocs := testing.AllocsPerRun(100, func() {
		l = ledger()
		if _, c := s.ReadAt(b, 9000, &l); c != pdf.OK {
			panic(c)
		}
		if _, c := s.ReadAt(b, 0, &l); c != pdf.OK {
			panic(c)
		}
		if c := s.Recheck(&l); c != pdf.OK {
			panic(c)
		}
	})
	if allocs != 0 || f.peak != 1 || f.handles != 0 {
		t.Fatal(allocs, f.peak, f.handles)
	}
}

// The acceptance corpus uses the real native adapter algorithm with a host
// sequential file seam, never os.File.ReadAt. PDF engine files stay read-only.
func TestAcceptanceCorpus(t *testing.T) {
	root := "../../../tests/fixtures/pdf/acceptance"
	paths, _ := filepath.Glob(filepath.Join(root, "*.pdf"))
	accepted := paths[:0]
	for _, p := range paths {
		if !bytes.HasPrefix([]byte(filepath.Base(p)), []byte("negative-")) {
			accepted = append(accepted, p)
		}
	}
	paths = accepted
	if len(paths) != 16 {
		t.Fatalf("authored pages: %d", len(paths))
	}
	arena := make([]byte, pdf.ArenaBytes)
	for _, path := range paths {
		t.Run(filepath.Base(path), func(t *testing.T) {
			b, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			f := fake{data: b}
			s, l := source(&f), ledger()
			if c := s.Admit(&l); c != pdf.OK {
				t.Fatal(c)
			}
			p, _, failure := pdf.Render(&s, 0, arena, &l)
			_ = s.Close(&l)
			if failure.Code != pdf.OK {
				t.Fatalf("%s offset=%d object=%d page=%d", failure.Error(), failure.Offset, failure.Object, failure.Page)
			}
			if len(p.Pix) != p.Width*p.Height {
				t.Fatal("missing page")
			}
			saveHostPage(t, filepath.Base(path), p)
		})
	}
}

func saveHostPage(t *testing.T, name string, p pdf.Page) {
	t.Helper()
	out := os.Getenv("PDF_PROOF_HOST_OUT")
	if out == "" {
		return
	}
	if err := os.MkdirAll(out, 0755); err != nil {
		t.Fatal(err)
	}
	b := make([]byte, 16+len(p.Pix)*4)
	copy(b, "PDF1")
	put(b[4:8], uint32(p.Width))
	put(b[8:12], uint32(p.Height))
	put(b[12:16], uint32(p.Stride))
	for i, word := range p.Pix {
		put(b[16+i*4:], word)
	}
	if err := os.WriteFile(filepath.Join(out, name[:len(name)-4]+".bgra"), b, 0644); err != nil {
		t.Fatal(err)
	}
}

func TestMaximaRetainEarlierCycles(t *testing.T) {
	var m maxima
	l := ledger()
	l.Used, l.ReadBytes, l.Rewinds, l.Expanded, l.VectorBudget.Used = 9, 8, 7, 6, 5
	m.observe(10, &l)
	l.Used, l.ReadBytes, l.Rewinds, l.Expanded, l.VectorBudget.Used = 1, 1, 1, 1, 1
	m.observe(1, &l)
	if m != (maxima{10, 9, 8, 7, 6, 5}) {
		t.Fatal("earlier cycle maxima lost", m)
	}
}

func TestNegativeCorpusAndRecovery(t *testing.T) {
	b, err := os.ReadFile("../../../tests/fixtures/pdf/acceptance/manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	var m struct {
		Negatives []struct{ File, Expected string }
	}
	if err = json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	arena := make([]byte, pdf.ArenaBytes)
	good, err := os.ReadFile("../../../tests/fixtures/pdf/acceptance/empty.pdf")
	if err != nil {
		t.Fatal(err)
	}
	f := fake{}
	s := source(&f)
	for _, row := range m.Negatives {
		t.Run(row.File, func(t *testing.T) {
			f.data, err = os.ReadFile("../../../tests/fixtures/pdf/acceptance/" + row.File)
			if err != nil {
				t.Fatal(err)
			}
			l := ledger()
			if c := s.Admit(&l); c != pdf.OK {
				t.Fatal(c)
			}
			p, _, failure := pdf.Render(&s, 0, arena, &l)
			_ = s.Close(&l)
			if failure.Error() != row.Expected || p.Pix != nil || l.Handles != 0 || l.Decoders != 0 {
				t.Fatal(failure.Error(), row.Expected, failure.Offset, failure.Object, failure.Page)
			}
			f.data = good
			l = ledger()
			if c := s.Admit(&l); c != pdf.OK {
				t.Fatal(c)
			}
			p, _, failure = pdf.Render(&s, 0, arena, &l)
			if failure.Code != pdf.OK {
				t.Fatal("recovery", failure)
			}
			if c := s.Recheck(&l); c != pdf.OK {
				t.Fatal(c)
			}
			for _, word := range p.Pix {
				if word != 0xffffffff {
					t.Fatal("recovery not white")
				}
			}
		})
	}
}

func TestGeneratedMaxima(t *testing.T) {
	in := os.Getenv("PDF_PROOF_MAXIMA")
	if in == "" {
		in = "../../../artifacts/m89-acceptance/reference/sources"
		if _, err := os.Stat(in); os.IsNotExist(err) {
			t.Skip("artifacts/m89-acceptance/reference/sources is not materialized; " +
				"run `python3 -B tools/pdf-proof/oracle.py generate artifacts/m89-acceptance/reference` (tools/pdf-proof/README.md)")
		}
	}
	paths, err := filepath.Glob(filepath.Join(in, "*.pdf"))
	if err != nil || len(paths) != 4 {
		t.Fatal("missing generated maxima", paths, err)
	}
	arena := make([]byte, pdf.ArenaBytes)
	for _, path := range paths {
		t.Run(filepath.Base(path), func(t *testing.T) {
			b, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			f := fake{data: b}
			s, l := source(&f), ledger()
			if c := s.Admit(&l); c != pdf.OK {
				t.Fatal(c)
			}
			p, _, failure := pdf.Render(&s, 0, arena, &l)
			_ = s.Close(&l)
			if failure.Code != pdf.OK {
				t.Fatal(failure.Error(), failure.Offset, failure.Object, failure.Page, l.Used, l.Rewinds)
			}
			if c := s.Recheck(&l); c != pdf.OK {
				t.Fatal(c)
			}
			saveHostPage(t, filepath.Base(path), p)
		})
	}
}

func TestGeneratedCapacities(t *testing.T) {
	b, err := os.ReadFile("../../../tests/fixtures/pdf/acceptance/recipes.json")
	if err != nil {
		t.Fatal(err)
	}
	var recipe struct {
		Capacities []struct{ ID, Expected string }
	}
	if err = json.Unmarshal(b, &recipe); err != nil {
		t.Fatal(err)
	}
	const capDir = "../../../artifacts/m89-acceptance/reference/sources/capacity"
	if _, err := os.Stat(capDir); os.IsNotExist(err) {
		t.Skip("artifacts/m89-acceptance/reference/sources/capacity is not materialized; " +
			"run `python3 -B tools/pdf-proof/oracle.py generate artifacts/m89-acceptance/reference` (tools/pdf-proof/README.md)")
	}
	arena := make([]byte, pdf.ArenaBytes)
	for _, row := range recipe.Capacities {
		t.Run(row.ID, func(t *testing.T) {
			b, err := os.ReadFile(capDir + "/" + row.ID + ".pdf")
			if err != nil {
				t.Fatal(err)
			}
			f := fake{data: b}
			s, l := source(&f), ledger()
			c := s.Admit(&l)
			if c == pdf.OK {
				p, _, failure := pdf.Render(&s, 0, arena, &l)
				c = failure.Code
				if c == pdf.OK {
					c = s.Recheck(&l)
					saveHostPage(t, "capacity-"+row.ID+".pdf", p)
				}
			}
			_ = s.Close(&l)
			got := (pdf.Failure{Code: c}).Error()
			if c == pdf.OK {
				got = "OK"
			}
			if got != row.Expected || l.Handles != 0 {
				t.Fatal(got, row.Expected, "work", l.Used, "rewinds", l.Rewinds)
			}
		})
	}
}

func TestAdapterBoundaryPairs(t *testing.T) {
	for _, row := range []struct {
		check func(uint64) pdf.Code
		max   uint64
		code  pdf.Code
	}{
		{pdf.CheckOutput, pdf.MaxOutput, pdf.OutputLimit},
		{pdf.CheckReceipt, pdf.MaxReceipt, pdf.ReceiptLimit},
		{pdf.CheckDiagnostics, pdf.MaxDiagnostics, pdf.ReceiptLimit},
	} {
		if row.check(row.max) != pdf.OK || row.check(row.max+1) != row.code {
			t.Fatal(row.max)
		}
	}
	if pdf.CheckRuntime(768*4096, 11) != pdf.OK || pdf.CheckRuntime(768*4096+1, 11) != pdf.MemoryLimit ||
		pdf.CheckRuntime(0, 12) != pdf.MemoryLimit {
		t.Fatal("runtime partition")
	}
	if pdf.CheckEngineSize(2097152, 2097152) != pdf.OK ||
		pdf.CheckEngineSize(2097153, 0) != pdf.EngineSizeLimit ||
		pdf.CheckEngineSize(0, 2097153) != pdf.EngineSizeLimit {
		t.Fatal("ELF delta")
	}
	if pdf.Operation().Code != pdf.UnsupportedOperation {
		t.Fatal("operation boundary")
	}
}

func TestTransactionReuseAndPlanBounds(t *testing.T) {
	good, err := os.ReadFile("../../../tests/fixtures/pdf/acceptance/empty.pdf")
	if err != nil {
		t.Fatal(err)
	}
	bad, err := os.ReadFile("../../../tests/fixtures/pdf/acceptance/negative-stroke.pdf")
	if err != nil {
		t.Fatal(err)
	}
	f := fake{data: good}
	s := source(&f)
	arena := make([]byte, pdf.ArenaBytes)
	l := ledger()
	allocs := testing.AllocsPerRun(100, func() {
		for _, b := range [][]byte{good, bad, good} {
			f.data = b
			l = ledger()
			if c := s.Admit(&l); c != pdf.OK {
				panic(c)
			}
			p, _, failure := pdf.Render(&s, 0, arena, &l)
			if failure.Code == pdf.OK {
				if c := s.Recheck(&l); c != pdf.OK || len(p.Pix) != 4096 {
					panic(c)
				}
			} else if failure.Code != pdf.UnsupportedStroke || p.Pix != nil {
				panic(failure.Code)
			}
			if c := s.Close(&l); c != pdf.OK || l.Handles != 0 || l.Decoders != 0 {
				panic(c)
			}
		}
	})
	if allocs != 0 || f.peak != 1 || f.handles != 0 {
		t.Fatal("retained adapter growth", allocs, f.peak, f.handles)
	}
	var rows [128]caseRow
	for _, test := range []struct {
		plan string
		code pdf.Code
	}{
		{"empty\t/host/a.pdf\t/host/a.bgra\t0\t0\t21\n", pdf.OK},
		{"empty\t/host/a.pdf\t-\t0\t0\t0\n", pdf.InvalidBuffer},
		{"empty\t/host/a.pdf\t-\t0\t0\t22\n", pdf.InvalidBuffer},
		{"empty\t/host/a.pdf\t-\t-1\t0\t1\n", pdf.InvalidBuffer},
		{"empty\t/host/a.pdf\t-\t0\t999\t1\n", pdf.InvalidBuffer},
		{"empty\t/host/a.pdf\t-\t0\t0\t1", pdf.InvalidBuffer},
	} {
		if _, c := parsePlan([]byte(test.plan), &rows); c != test.code {
			t.Fatal(test.plan, c)
		}
	}
	r := receipt{b: make([]byte, pdf.MaxReceipt)}
	r.number(^uint64(0))
	if string(r.b[:r.n]) != "18446744073709551615" {
		t.Fatal("integer receipt")
	}
	r.n = len(r.b)
	r.text("x")
	if r.c != pdf.ReceiptLimit {
		t.Fatal("receipt cap+1")
	}
}
