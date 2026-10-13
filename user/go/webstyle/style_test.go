package webstyle

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestZeroValueContract(t *testing.T) {
	// Pin every field, not just a sample. Resolution of the sentinel values is
	// normative in ADR 0028 D §3; this package intentionally has no resolver.
	initial := Length{Kind: LengthInitial}
	edges := Edges{Top: initial, Right: initial, Bottom: initial, Left: initial}
	border := Border{Width: initial, Style: BorderNone, Color: Color{Kind: ColorInitial}}
	want := ComputedStyle{
		Display: DisplayInline,
		Width:   initial, Height: initial, MinWidth: initial, MaxWidth: initial,
		MinHeight: initial, MaxHeight: initial, Margin: edges, Padding: edges,
		Border:     Borders{Top: border, Right: border, Bottom: border, Left: border},
		FontFamily: FontSans, FontSize: initial, LineHeight: initial,
		FontWeight: WeightNormal, FontStyle: StyleNormal,
		Color: Color{Kind: ColorInitial}, BackgroundColor: Color{Kind: ColorInitial},
		TextAlign: AlignLeft, WhiteSpace: WhiteSpaceNormal,
		FlexDirection: FlexRow, FlexWrap: FlexNoWrap,
		JustifyContent: JustifyStart, AlignItems: ItemsStretch,
		FlexGrow: FlexFactor{}, FlexShrink: FlexFactor{}, FlexBasis: initial,
		RowGap: initial, ColumnGap: initial,
	}
	if got := (ComputedStyle{}); got != want {
		t.Fatalf("zero style changed:\ngot  %+v\nwant %+v", got, want)
	}
	if reflect.TypeOf(want).NumField() != 28 {
		t.Fatal("style fields changed; update the frozen-contract review")
	}
	if (Length{}) != initial || (Color{}) != (Color{Kind: ColorInitial}) ||
		(Diagnostic{}) != (Diagnostic{Kind: DiagnosticUnsupported}) ||
		(Viewport{}) != (Viewport{Width: 0, Height: 0}) {
		t.Fatal("zero value changed")
	}
}

func TestExplicitZeroIsNotInitial(t *testing.T) {
	if (Length{Kind: LengthPx}) == (Length{}) || (Length{Kind: LengthAuto}) == (Length{}) ||
		(Color{Kind: ColorRGBA}) == (Color{}) ||
		(FlexFactor{Set: true}) == (FlexFactor{}) {
		t.Fatal("explicit zero must remain distinct from an initial value")
	}
}

func TestTypeOnlyContract(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range files {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		if len(f.Imports) != 0 {
			t.Fatalf("%s: type package must have no imports", path)
		}
		for _, decl := range f.Decls {
			d, ok := decl.(*ast.GenDecl)
			if !ok || (d.Tok != token.TYPE && d.Tok != token.CONST) {
				t.Fatalf("%s: only types and constants belong here", path)
			}
		}
	}
}

func TestReferenceSetBounds(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "tests", "fixtures", "web", "reference")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	pages := 0
	for _, entry := range entries {
		if entry.IsDir() {
			t.Fatalf("reference set must stay flat: %s", entry.Name())
		}
		b, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		if len(b) > MaxReferenceFileBytes {
			t.Fatalf("%s: %d bytes > %d", entry.Name(), len(b), MaxReferenceFileBytes)
		}
		if strings.HasSuffix(entry.Name(), ".html") {
			pages++
			if !strings.Contains(string(b), "Authored for VirelaiOS") {
				t.Fatalf("%s: missing provenance header", entry.Name())
			}
		}
	}
	if pages != 17 {
		t.Fatalf("reference page inventory changed: got %d, want 17", pages)
	}
}
