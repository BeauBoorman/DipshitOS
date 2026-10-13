package css

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"virelai/webrender"
)

// This independent deletion oracle covers the deliberately unsupported
// constructs in the authored reference corpus. It does not call the CSS parser
// to decide which bytes to delete.
func deleteExcluded(src string) string {
	clean, _ := excludedOracle(src)
	return clean
}

func excludedOracle(src string) (string, int) {
	count := 0
	for {
		at := strings.Index(src, "@")
		if at < 0 {
			break
		}
		end, depth := at, 0
		for ; end < len(src); end++ {
			switch src[end] {
			case '{':
				depth++
			case '}':
				depth--
				if depth == 0 {
					end++
					goto removed
				}
			case ';':
				if depth == 0 {
					end++
					goto removed
				}
			}
		}
	removed:
		src = src[:at] + src[end:]
		count++
	}
	selectors := regexp.MustCompile(`[^{}]*[:>\[+~][^{}]*\{[^{}]*\}`)
	count += len(selectors.FindAllStringIndex(src, -1))
	src = selectors.ReplaceAllString(src, "")
	excluded := regexp.MustCompile(`(?im)(^|[;{])(\s*)(float|position|top|z-index|grid-template-columns|transform|animation|background-image|opacity|content)\s*:[^;{}]*;?`)
	for {
		next := excluded.ReplaceAllString(src, "$1$2")
		if next == src {
			break
		}
		count += len(excluded.FindAllStringIndex(src, -1))
		src = next
	}
	// Exact excluded values in degradation.html and fonts-family.html,
	// independently pinned to the authored references, not inferred by
	// calling the product's value parser. (M99p removed font-size:2em here:
	// it is supported now, so the oracle must keep it.)
	values := regexp.MustCompile(`(?im)(^|[;{])(\s*)(width\s*:\s*calc\([^;{}]*\)|border\s*:\s*dashed[^;{}]*|display\s*:\s*grid|font-family\s*:\s*VirelaiMissing)\s*;?`)
	for {
		next := values.ReplaceAllString(src, "$1$2")
		if next == src {
			break
		}
		count += len(values.FindAllStringIndex(src, -1))
		src = next
	}
	return src, count
}

func assertEquivalent(t *testing.T, html, source string) {
	t.Helper()
	doc := webrender.ParseHTML([]byte(html))
	deleted, excludedCount := excludedOracle(source)
	mixed, parsed := Parse([]byte(source))
	clean, cleaned := Parse([]byte(deleted))
	a, page := Cascade(doc, []*Stylesheet{mixed})
	b, cleanPage := Cascade(doc, []*Stylesheet{clean})
	if len(parsed) != excludedCount || len(page) != excludedCount || len(cleaned) != 0 || len(cleanPage) != 0 {
		t.Errorf("one diagnostic per excluded construct (%d): parsed=%+v page=%+v clean=%+v", excludedCount, parsed, page, cleanPage)
	}
	var walk func(*webrender.Node)
	walk = func(n *webrender.Node) {
		if a.ForNode(n) != b.ForNode(n) {
			t.Errorf("unsupported CSS changed node %s", n.Tag)
		}
		for _, child := range n.Children {
			walk(child)
		}
	}
	walk(doc.Root)
}

func TestUnsupportedEquivalence(t *testing.T) {
	assertEquivalent(t, `<main><p class="x">Visible</p></main>`, `
		p { color:green; float:right; position:absolute; grid-template-columns:1fr; }
		p:hover { display:none; } p::before { content:"hidden"; }
		@media print { p { display:none; } }
		@import "never.css"; @font-face { font-family:Remote; src:url(never.ttf); }
	`)
}

func TestReferenceUnsupportedEquivalence(t *testing.T) {
	files, err := filepath.Glob("../../../tests/fixtures/web/reference/*.html")
	if err != nil || len(files) != 17 {
		t.Fatalf("reference inventory: %d, %v", len(files), err)
	}
	styleRE := regexp.MustCompile(`(?s)<style>(.*?)</style>`)
	for _, path := range files {
		t.Run(filepath.Base(path), func(t *testing.T) {
			buf, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			html := string(buf)
			var sources []string
			for _, match := range styleRE.FindAllStringSubmatch(html, -1) {
				sources = append(sources, match[1])
			}
			// Extract before parsing: the pre-M93b HTML parser has no raw-text
			// state. CSS equivalence is independent of that other lane.
			assertEquivalent(t, styleRE.ReplaceAllString(html, ""), strings.Join(sources, "\n"))
		})
	}
}
