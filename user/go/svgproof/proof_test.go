package svgproof

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"virelai/vector"
)

func TestCorpusAndNoAllocations(t *testing.T) {
	v := View(make([]byte, ArenaBytes))
	files, err := filepath.Glob("../../../tests/fixtures/svg/acceptance/*.svg")
	if err != nil || len(files) < 16 {
		t.Fatal("missing corpus", err)
	}
	for _, path := range files {
		source, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		copy(v.Source, source)
		run := func() {
			b := vector.Budget{Max: vector.MaxWork}
			s, c, stats, f := v.Render(len(source), 0, &b)
			if f.Code != vector.OK || c.Width < 1 || stats.Work > b.Used || b.Used > vector.MaxWork {
				t.Fatalf("%s: %+v %+v", path, f, stats)
			}
			if !strings.Contains(path, "max-") && (len(s.Commands) > 128 || len(s.Paints) > 16 || stats.Edges > 512 || len(source) > 16384) {
				t.Fatal("icon corpus complexity", path)
			}
		}
		run()
		if !strings.Contains(path, "max-") && testing.AllocsPerRun(10, run) != 0 {
			t.Fatal("render allocated", path)
		}
		if !bytes.Equal(v.Source[:len(source)], source) {
			t.Fatal("source changed", path)
		}
	}
}

func TestExclusionsBoundariesAnd100CycleReuse(t *testing.T) {
	base := "../../../artifacts/m90-acceptance/negatives"
	data, err := os.ReadFile(filepath.Join(base, "negative.tsv"))
	if os.IsNotExist(err) {
		t.Skip("artifacts/m90-acceptance/negatives is not materialized; " +
			"run `bash tools/svg-proof/build.sh` (needs the provisioned Go fork; tools/svg-proof/README.md)")
	}
	if err != nil {
		t.Fatal("negative corpus must be materialized first", err)
	}
	v := View(make([]byte, ArenaBytes))
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		fields := strings.Split(line, "\t")
		code, err := strconv.Atoi(fields[1])
		if err != nil {
			t.Fatal(err)
		}
		src, err := os.ReadFile(filepath.Join(base, fields[0]))
		if err != nil {
			t.Fatal(err)
		}
		copy(v.Source, src)
		for i := range v.Pixels {
			v.Pixels[i] = 0x71345678
		}
		b := vector.Budget{Max: vector.MaxWork}
		s, c, _, f := v.Render(len(src), 0, &b)
		if int(f.Code) != code {
			t.Errorf("%s: %+v want code=%d", fields[2], f, code)
		}
		if code != 0 {
			if len(s.Commands) != 0 || len(s.Paints) != 0 || c.Width != 0 || c.Height != 0 {
				t.Fatal("partial scene on refusal", fields[2])
			}
			for _, pixel := range v.Pixels {
				if pixel != 0x71345678 {
					t.Fatal("partial output on parse refusal", fields[2])
				}
			}
		}
	}
	good := []byte(`<svg width="64" height="64"><rect width="64" height="64" fill="red"/></svg>`)
	bad := []byte(`<svg width="64" height="64"><g fill-opacity="0"><text/></g></svg>`)
	if n := testing.AllocsPerRun(100, func() {
		copy(v.Source, bad)
		b := vector.Budget{Max: vector.MaxWork}
		_, _, _, f := v.Render(len(bad), 0, &b)
		if f.Code != vector.UnsupportedText {
			t.Fatal(f)
		}
		copy(v.Source, good)
		b = vector.Budget{Max: vector.MaxWork}
		_, _, _, f = v.Render(len(good), 0, &b)
		if f.Code != vector.OK || v.Pixels[4095] != 0xffff0000 {
			t.Fatal("recovery", f)
		}
	}); n != 0 {
		t.Fatal("success/refusal cycles allocated", n)
	}
}
