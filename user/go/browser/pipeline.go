package main

import (
	"strings"
	"unicode/utf8"

	"virelai/css"
	"virelai/webrender"
	"virelai/webstyle"
)

func (a *app) diagnostic(kind webstyle.DiagnosticKind, text string) {
	a.mergeDiagnostics([]webstyle.Diagnostic{{Kind: kind, Text: text}})
}

func (a *app) mergeDiagnostics(ds []webstyle.Diagnostic) {
	for _, d := range ds {
		if len(a.diagnostics) >= webstyle.MaxDiagnostics {
			return
		}
		if len(d.Text) > webstyle.MaxDiagnosticTextBytes {
			d.Text = d.Text[:webstyle.MaxDiagnosticTextBytes]
			for !utf8.ValidString(d.Text) {
				d.Text = d.Text[:len(d.Text)-1]
			}
		}
		if len(a.diagnostics) == webstyle.MaxDiagnostics-1 {
			a.diagnostics = append(a.diagnostics, webstyle.Diagnostic{
				Kind: webstyle.DiagnosticLimit, Text: "diagnostics-truncated"})
			return
		}
		a.diagnostics = append(a.diagnostics, d)
	}
}

func (a *app) authorSheets(doc *webrender.Document) []*css.Stylesheet {
	var sheets []*css.Stylesheet
	bytes := 0
	count := 0
	var walk func(*webrender.Node)
	walk = func(n *webrender.Node) {
		if a.pageCancelled || a.quit {
			return
		}
		source := ""
		linked := n.Tag == "link" && hasToken(n.Attr("rel"), "stylesheet") && !n.HasAttr("disabled")
		if n.Tag == "style" || linked {
			count++
			if count > webstyle.MaxStylesheets {
				a.diagnostic(webstyle.DiagnosticLimit, "css-sheet-limit")
				return
			}
			if linked {
				if n.Attr("href") == "" {
					a.diagnostic(webstyle.DiagnosticResource, "css-resource: missing href")
					return
				}
				data, err := a.fetchResource(relativeTo(a.target, n.Attr("href")), webstyle.MaxCSSBytes-bytes)
				if err != "" {
					a.diagnostic(webstyle.DiagnosticResource, "css-resource: "+err)
					return
				}
				source = string(data)
			} else {
				var raw strings.Builder
				for _, child := range n.Children {
					if child.Kind == webrender.KindText {
						raw.WriteString(child.Text)
					}
				}
				source = raw.String()
			}
			if len(source) > webstyle.MaxCSSBytes-bytes {
				a.diagnostic(webstyle.DiagnosticLimit, "css-byte-limit")
				return // never apply a cut declaration
			}
			bytes += len(source)
			if !a.reserveCSS(source) {
				return
			}
			sheet, _ := css.Parse([]byte(source))
			sheets = append(sheets, sheet)
			return // metadata children cannot contain additional resources
		}
		if n.Tag == "script" || n.Tag == "template" {
			return
		}
		for _, child := range n.Children {
			walk(child)
		}
	}
	walk(doc.Root)
	return sheets
}

func hasToken(value, token string) bool {
	for _, v := range strings.Fields(value) {
		if strings.EqualFold(v, token) {
			return true
		}
	}
	return false
}

func (a *app) layoutPage() {
	sheets := a.authorSheets(a.doc)
	if a.pageCancelled || a.quit {
		return
	}
	var inline func(*webrender.Node)
	inline = func(n *webrender.Node) {
		if source := n.Attr("style"); source != "" && !a.reserveCSS(source) {
			attrs := make([]webrender.Attr, 0, len(n.Attrs))
			for _, attr := range n.Attrs {
				if attr.Name != "style" {
					attrs = append(attrs, attr)
				}
			}
			n.Attrs = attrs // omit this complete source, never a half declaration
		}
		for _, child := range n.Children {
			inline(child)
		}
	}
	inline(a.doc.Root)
	// M126d (#2596): the font_size rung is the cascade's initial text size;
	// the tab's zoom then scales every resolved px uniformly. Both re-run
	// through here on change, so a zoomed font still wraps honestly.
	styles, ds := css.CascadeBase(a.doc, sheets, int32(a.fontBase))
	a.mergeDiagnostics(ds)
	styles.Scale(a.zoomPct)
	a.preflightImages(a.doc, styles)
	if a.pageCancelled || a.quit {
		return
	}
	tree, ds := webrender.BuildBoxTree(a.doc, styles.ForNode)
	a.mergeDiagnostics(ds)
	a.lay, ds = webrender.LayoutBoxes(tree, webstyle.Viewport{
		Width: webstyle.ViewportWidth, Height: webstyle.ViewportHeight}, a.text, a.resolveImage)
	a.mergeDiagnostics(ds)
}

func (a *app) preflightImages(doc *webrender.Document, styles *css.Styles) {
	a.imageSources = make(map[string][]byte)
	rejected := map[string]bool{}
	count := 0
	var walk func(*webrender.Node)
	walk = func(n *webrender.Node) {
		if a.pageCancelled || a.quit {
			return
		}
		if styles.ForNode(n).Display == webstyle.DisplayNone || webrender.SkipSubtree(n.Tag) {
			return
		}
		if n.Tag == "img" {
			count++
			src, reason := n.Attr("src"), ""
			if count > webstyle.MaxImages {
				reason = "image-limit"
			} else if src == "" || rejected[src] {
				reason = "image-missing"
			} else {
				data, present := a.imageSources[src]
				if !present {
					var kind string
					data, kind = a.fetchResource(relativeTo(a.target, src), webstyle.MaxImageBytes)
					if kind != "" {
						reason = "image-missing: " + kind
						rejected[src] = true
					}
				}
				if reason == "" && !a.canDecodeImage(len(data)) {
					reason = "page-memory-limit: image"
				}
				if reason == "" {
					image, err := webrender.DecodeImage(data)
					if err != nil {
						reason = err.Error()
						rejected[src] = true
					} else if len(image.Pix)*4 > webstyle.MaxPageImageBytes-a.imageBytes ||
						int64(len(data)+len(image.Pix)*4) > a.memoryRemaining {
						reason = "image-limit"
					} else {
						a.imageBytes += len(image.Pix) * 4
						a.imageSources[src] = data
						a.memoryRemaining -= int64(len(data) + len(image.Pix)*4)
					}
				}
			}
			if reason != "" {
				a.diagnostic(webstyle.DiagnosticResource, reason)
				// Resource policy is the browser's, not the cascade's. Replace
				// only this refused source with an inert, unresolvable key;
				// preserve alt/dimensions and the original saved HTML bytes.
				attrs := append([]webrender.Attr(nil), n.Attrs...)
				for i := range attrs {
					if attrs[i].Name == "src" {
						attrs[i].Value = "virelai-image-refused:"
					}
				}
				n.Attrs = attrs
			}
			return
		}
		for _, child := range n.Children {
			walk(child)
		}
	}
	walk(doc.Root)
}
