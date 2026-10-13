package main

import (
	"bytes"
	"compress/zlib"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"hash/crc32"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"sort"
	"testing"

	"virelai/webrender"
)

type gateRaster struct {
	Hash string
}

type gateManifest struct {
	Version       int
	Width, Height int
	Fixtures      map[string]gateRaster
	Verdict       string
	Fonts         map[string]string
}

func swatchSources() ([]byte, []byte) {
	colors := [][4]byte{{0x11, 0x7f, 0x33, 255}, {0xd0, 0x33, 0x99, 255},
		{0x22, 0x66, 0xdd, 255}, {0xee, 0xcc, 0x00, 255}}
	qoi := append([]byte("qoif"), 0, 0, 0, 32, 0, 0, 0, 32, 4, 0)
	var rows bytes.Buffer
	for y := 0; y < 32; y++ {
		rows.WriteByte(0)
		for x := 0; x < 32; x++ {
			c := colors[(y/16)*2+x/16]
			qoi = append(qoi, 0xfe, c[0], c[1], c[2])
			rows.Write(c[:])
		}
	}
	qoi = append(qoi, 0, 0, 0, 0, 0, 0, 0, 1)
	var compressed bytes.Buffer
	w := zlib.NewWriter(&compressed)
	_, _ = w.Write(rows.Bytes())
	_ = w.Close()
	pngData := []byte("\x89PNG\r\n\x1a\n")
	chunk := func(name string, data []byte) {
		var n [4]byte
		binary.BigEndian.PutUint32(n[:], uint32(len(data)))
		pngData = append(pngData, n[:]...)
		body := append([]byte(name), data...)
		pngData = append(pngData, body...)
		binary.BigEndian.PutUint32(n[:], crc32.ChecksumIEEE(body))
		pngData = append(pngData, n[:]...)
	}
	chunk("IHDR", []byte{0, 0, 0, 32, 0, 0, 0, 32, 8, 6, 0, 0, 0})
	chunk("IDAT", compressed.Bytes())
	chunk("IEND", nil)
	return qoi, pngData
}

func TestGatePresentationExpectations(t *testing.T) {
	pinnedData, err := os.ReadFile("testdata/presentation-expectations.json")
	stage := os.Getenv("M93F_STAGE_PRESENTATION")
	if err != nil && stage == "" {
		t.Fatal(err)
	}
	var pinned gateManifest
	if len(pinnedData) > 0 {
		if err := json.Unmarshal(pinnedData, &pinned); err != nil {
			t.Fatal(err)
		}
	}
	read := func(path string) []byte {
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	depth := []byte(`<p>MMMMMMMM</p><p><strong>MMMMMMMM</strong></p><h4>Depth</h4>` +
		`<table><thead><tr><th>Left</th><th>Right</th></tr></thead><tbody><tr><td>one</td><td>two</td></tr></tbody></table>` +
		`<p>An image:</p><img src="SWATCH.QOI" alt="swatch"><p><a href="NEXT.HTML">a link</a></p>`)
	lists := []byte(`<h4>Lists</h4><dl><dt>term</dt><dd>definition sits indented</dd></dl><p><img src="NOPE.QOI" alt="missing"></p>`)
	cases := map[string][]byte{
		"page": read("testdata/gate-page.html"), "next": read("testdata/gate-next.html"),
		"hostile": read("testdata/hostile.html"), "corpus": read("../webrender/testdata/corpus/cern-home.html"),
		"fetch":       []byte("Hello from VirelaiOS Host!\n"),
		"oliver":      read("../../../tests/oliver-spike/expect.html"),
		"oliver-grid": read("../../../tests/oliver-spike/expect.html"),
		"depth":       depth, "lists-grid": lists, "png-grid": []byte(`<img src="SWATCH.PNG" width="32" height="32" alt="guest PNG">`),
	}
	qoi, pngData := swatchSources()
	fonts := browserFonts(t)
	if stage == "" {
		// Five faces of provenance: the four the engine always loaded plus
		// Inter Bold Italic (M99o), which browserFonts resolves for a {B,I}
		// style even though none of the ten fixtures carries one.
		if pinned.Verdict != "Approve all ten presentation expectations" || len(pinned.Fonts) != 5 {
			t.Fatal("missing owner verdict or font provenance")
		}
		for name, want := range pinned.Fonts {
			data := read(filepath.Join("../../../image/fonts", name))
			h := sha256.Sum256(data)
			if want != hex.EncodeToString(h[:]) {
				t.Fatalf("font provenance changed: %s", name)
			}
		}
	}
	actual := gateManifest{Version: 1, Width: 512, Height: 288, Fixtures: map[string]gateRaster{}}
	contact := image.NewNRGBA(image.Rect(0, 0, 1024, 1440))
	contactIndex := 0
	names := make([]string, 0, len(cases))
	for name := range cases {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		body := cases[name]
		a := &app{hist: newHistory(), text: fonts, target: "/host/PAGE.HTML"}
		if name == "oliver-grid" || name == "lists-grid" || name == "png-grid" {
			a.text = webrender.Bitmap{}
		}
		a.resourceForTest = func(path string, _ int) ([]byte, string) {
			switch path {
			case "/host/SWATCH.QOI":
				return qoi, ""
			case "/host/SWATCH.PNG":
				return pngData, ""
			}
			return nil, "file"
		}
		a.loadBody(body, a.target)
		native := a.nativeSurface()
		native.Fill(0, 0, 1280, 720, webrender.ColorPageBg)
		webrender.Paint(a.lay, native, 0, 0, 1280, 720, 0)
		pix := make([]uint32, 512*288)
		a.sampleFrame(virender{pix: pix, w: 512, h: 288}, presentation{0, 0, 512, 288})
		actual.Fixtures[name] = gateRaster{Hash: frameHash(pix)}
		if stage == "" {
			if pinned.Version != 1 || pinned.Width != 512 || pinned.Height != 288 ||
				pinned.Fixtures[name] != actual.Fixtures[name] {
				t.Fatalf("%s host expectation changed: got=%v pinned=%v", name, actual.Fixtures[name], pinned.Fixtures[name])
			}
		} else {
			if err := os.MkdirAll(stage, 0o755); err != nil {
				t.Fatal(err)
			}
			im := image.NewNRGBA(image.Rect(0, 0, 512, 288))
			for i, p := range pix {
				im.Pix[i*4], im.Pix[i*4+1], im.Pix[i*4+2], im.Pix[i*4+3] = byte(p>>16), byte(p>>8), byte(p), 255
			}
			ox, oy := contactIndex%2*512, contactIndex/2*288
			for y := 0; y < 288; y++ {
				at := (oy+y)*contact.Stride + ox*4
				copy(contact.Pix[at:at+512*4], im.Pix[y*im.Stride:y*im.Stride+512*4])
			}
			contactIndex++
			var out bytes.Buffer
			if err := png.Encode(&out, im); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(stage, name+".png"), out.Bytes(), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}
	if stage != "" {
		data, _ := json.MarshalIndent(actual, "", "  ")
		if err := os.WriteFile(filepath.Join(stage, "presentation-expectations.json"), append(data, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		if err := png.Encode(&out, contact); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(stage, "contact-sheet.png"), out.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}
