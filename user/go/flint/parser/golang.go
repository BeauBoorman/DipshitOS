package parser

import (
	"go/ast"
	goparser "go/parser"
	"go/scanner"
	"go/token"
)

// goParser turns Go source into Atoms via go/parser + go/ast
// (parser.SkipObjectResolution — FLINT does not resolve identifiers, and
// the guest build keeps go/types out of the ELF). The qualified prefix is
// the package clause (ADR 0049 §3).
type goParser struct {
	sink map[string]string
}

func (goParser) Language() string { return "go" }

func (gp goParser) Parse(file string, src []byte) ([]Atom, error) {
	fset := token.NewFileSet()
	f, err := goparser.ParseFile(fset, file, src, goparser.SkipObjectResolution)
	if err != nil {
		return nil, &ParseError{File: file, Offset: errOffset(err), Code: "syntax"}
	}
	pkg := f.Name.Name
	var atoms []Atom
	for _, decl := range f.Decls {
		switch d := decl.(type) {
		case *ast.GenDecl:
			if d.Tok == token.IMPORT {
				continue
			}
			for i, spec := range d.Specs {
				switch sp := spec.(type) {
				case *ast.TypeSpec:
					if dropName(sp.Name.Name) {
						continue
					}
					kind := "type"
					switch {
					case sp.Assign.IsValid():
						kind = "type_alias"
					default:
						switch sp.Type.(type) {
						case *ast.StructType:
							kind = "struct"
						case *ast.InterfaceType:
							kind = "interface"
						}
					}
					atoms = append(atoms, goAtom(fset, file, src, kind,
						pkg+"."+sp.Name.Name,
						sp.Pos(), sp.End(), sp.Name.Pos(), -1, -1, gp.sink))
				case *ast.ValueSpec:
					kind := "var"
					if d.Tok == token.CONST {
						kind = "const"
					}
					iota := -1
					if d.Tok == token.CONST && len(sp.Values) == 0 {
						iota = i
					}
					for _, n := range sp.Names {
						if dropName(n.Name) {
							continue
						}
						atoms = append(atoms, goAtom(fset, file, src, kind,
							pkg+"."+n.Name,
							sp.Pos(), sp.End(), n.Pos(), -1, iota, gp.sink))
					}
				}
			}
		case *ast.FuncDecl:
			if dropName(d.Name.Name) {
				continue
			}
			body := int(fset.Position(d.End()).Offset)
			if d.Body != nil {
				body = int(fset.Position(d.Body.Pos()).Offset)
			}
			if d.Recv == nil || len(d.Recv.List) == 0 {
				kind, qname := "fn", pkg+"."+d.Name.Name
				if isTestFunc(d) {
					kind, qname = "test", pkg+".test:"+d.Name.Name
				}
				atoms = append(atoms, goAtom(fset, file, src, kind, qname,
					d.Pos(), d.End(), d.Name.Pos(), body, -1, gp.sink))
				continue
			}
			recvText, recvBase := goRecv(d.Recv.List[0].Type)
			a := goAtom(fset, file, src, "method",
				pkg+"."+recvBase+"."+d.Name.Name,
				d.Pos(), d.End(), d.Name.Pos(), body, -1, gp.sink)
			a.Meta = map[string]string{"receiver": recvText}
			atoms = append(atoms, a)
		}
	}
	return atoms, nil
}

func dropName(name string) bool { return name == "_" || name == "init" }

// errOffset pulls a byte offset out of a go/parser error (scanner.ErrorList
// carries Pos offsets; a bare error gets offset 0).
func errOffset(err error) int {
	if el, ok := err.(scanner.ErrorList); ok && len(el) > 0 {
		return el[0].Pos.Offset
	}
	return 0
}

// isTestFunc reports `func TestXxx(t *testing.T)` — one parameter of
// *testing.T, no results, no type parameters (ADR 0049 §3 kind table).
func isTestFunc(d *ast.FuncDecl) bool {
	if len(d.Name.Name) < 5 || d.Name.Name[:4] != "Test" {
		return false
	}
	if d.Type.TypeParams != nil && len(d.Type.TypeParams.List) > 0 {
		return false
	}
	if d.Type.Results != nil && len(d.Type.Results.List) > 0 {
		return false
	}
	if d.Type.Params == nil || len(d.Type.Params.List) != 1 {
		return false
	}
	p := d.Type.Params.List[0]
	star, ok := p.Type.(*ast.StarExpr)
	if !ok {
		return false
	}
	sel, ok := star.X.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	pkg, ok := sel.X.(*ast.Ident)
	return ok && pkg.Name == "testing" && sel.Sel.Name == "T"
}

// goRecv renders a receiver type as (written form, base name with the
// pointer stripped): `*T` -> ("*T", "T"), `T[P]` -> ("T[P]", "T").
func goRecv(e ast.Expr) (string, string) {
	switch t := e.(type) {
	case *ast.StarExpr:
		inner, base := goRecv(t.X)
		return "*" + inner, base
	case *ast.ParenExpr:
		return goRecv(t.X)
	case *ast.IndexExpr:
		inner, base := goRecv(t.X)
		return inner + "[" + goExprText(t.Index) + "]", base
	case *ast.IndexListExpr:
		inner, base := goRecv(t.X)
		parts := ""
		for i, ix := range t.Indices {
			if i > 0 {
				parts += ","
			}
			parts += goExprText(ix)
		}
		return inner + "[" + parts + "]", base
	case *ast.Ident:
		return t.Name, t.Name
	case *ast.SelectorExpr:
		inner, base := goRecv(t.X)
		return inner + "." + t.Sel.Name, base + "." + t.Sel.Name
	}
	return "_", "_"
}

// goExprText is a minimal expr renderer for receiver type-parameter lists.
func goExprText(e ast.Expr) string {
	switch t := e.(type) {
	case *ast.Ident:
		return t.Name
	case *ast.StarExpr:
		return "*" + goExprText(t.X)
	case *ast.SelectorExpr:
		return goExprText(t.X) + "." + t.Sel.Name
	}
	return "_"
}

// goAtom scans the declaration range, blanks the declared-name token at
// namePos, applies the signature cut (sigOff >= 0: tokens before it) and
// the implicit-iota suffix, and hashes.
func goAtom(fset *token.FileSet, file string, src []byte, kind, qname string,
	pos, end, namePos token.Pos, sigOff, iota int, sink map[string]string) Atom {
	start := int(fset.Position(pos).Offset)
	stop := int(fset.Position(end).Offset)
	toks := goScan(src)
	var in []ctok
	for _, t := range toks {
		if t.text != "" && t.start >= start && t.start < stop {
			in = append(in, t)
		}
	}
	blank := int(fset.Position(namePos).Offset)
	sigCut := 1 << 60
	switch {
	case sigOff >= 0:
		sigCut = sigOff
	case kind == "var":
		for _, t := range in {
			if t.text == "=" {
				sigCut = t.start
				break
			}
		}
	}
	sh, ss := canonize(kind, qname, in, blank, sigCut, iota, sink)
	return Atom{
		Kind: kind, Name: qname, File: file,
		Start: uint32(start), End: uint32(stop),
		Hash: sh, SigHash: ss,
	}
}

// goScan tokenizes a whole file with go/scanner; comments and synthetic
// newline semicolons are dropped so line-wrapping is whitespace-invariant.
func goScan(src []byte) []ctok {
	fset := token.NewFileSet()
	f := fset.AddFile("", 1, len(src))
	var s scanner.Scanner
	s.Init(f, src, nil, 0)
	var out []ctok
	for {
		pos, tok, lit := s.Scan()
		if tok == token.EOF {
			return out
		}
		if tok == token.SEMICOLON && lit == "\n" {
			continue
		}
		off := fset.Position(pos).Offset
		text := lit
		if text == "" {
			text = tok.String()
		}
		end := off + len(text)
		out = append(out, ctok{start: off, end: end, text: text})
	}
}
