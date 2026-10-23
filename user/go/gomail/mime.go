package main

// mime.go — the BODYSTRUCTURE walk and the plaintext-only policy the
// card's "truth in bounds" names: text/plain renders, text/html renders
// as stripped text, every other leaf lists as an attachment by name and
// refuses to open. No decoders beyond the strip — no base64 payload is
// rendered (a base64 text part prints its refusal note, not decoded
// garbage).

import "strings"

// partInfo is one node of a decoded BODYSTRUCTURE.
type partInfo struct {
	num      string // MIME part number: "1", "2", "1.2"; "" = whole body
	media    string // lowercased: "text", "application", "multipart"
	sub      string // lowercased: "plain", "html", "pdf", "mixed"
	filename string // disposition filename or content-type "name"
	disp     string // lowercased disposition: "attachment", "inline", ""
	encoding string // lowercased: "7bit", "base64", ...
	size     int64
	kids     []*partInfo // multipart children
	multiSub string      // multipart subtype: "mixed", "alternative"
}

// walkPart decodes one BODYSTRUCTURE form. num is this node's part
// number ("" for the single-part root, which FETCHes as BODY[TEXT]).
func walkPart(f []form, num string) *partInfo {
	p := &partInfo{num: num}
	if len(f) == 0 {
		return p
	}
	// Multipart: consecutive list children then the subtype atom.
	if _, isList := formList(f[0]); isList {
		p.media = "multipart"
		i := 0
		for i < len(f) {
			kid, ok := formList(f[i])
			if !ok {
				break
			}
			knum := itoa(int64(i + 1))
			if num != "" {
				knum = num + "." + knum
			}
			p.kids = append(p.kids, walkPart(kid, knum))
			i++
		}
		if i < len(f) {
			p.multiSub = lowerASCII(formStrOr(f[i], ""))
			p.sub = p.multiSub
		}
		return p
	}
	// Leaf: type subtype params id desc encoding size [lines] ext...
	p.media = lowerASCII(formStrOr(f[0], ""))
	if len(f) > 1 {
		p.sub = lowerASCII(formStrOr(f[1], ""))
	}
	if len(f) > 2 {
		p.filename = formPairs(f[2])["name"]
	}
	if len(f) > 5 {
		p.encoding = lowerASCII(formStrOr(f[5], ""))
	}
	if len(f) > 6 {
		if s, ok := formStr(f[6]); ok {
			if n, ok := parseUint(s); ok {
				p.size = n
			}
		}
	}
	// Extension fields after the mandatory 7 (+ line-count for text/*):
	// scan for the disposition list — ("ATTACHMENT" ("FILENAME" "x")).
	for i := 7; i < len(f); i++ {
		dl, ok := formList(f[i])
		if !ok || len(dl) == 0 {
			continue
		}
		d, ok := formStr(dl[0])
		if !ok {
			continue
		}
		p.disp = lowerASCII(d)
		if len(dl) > 1 {
			if fn := formPairs(dl[1])["filename"]; fn != "" {
				p.filename = fn
			}
		}
		break
	}
	return p
}

// isReadable reports whether the part renders as guest text: text/plain
// directly, text/html stripped. text/calendar (.ics) is M187d's domain —
// it lists as an attachment here.
func (p *partInfo) isReadable() bool {
	return p.media == "text" && (p.sub == "plain" || p.sub == "html")
}

// isAttachment reports the "list by name, refuse to open" class: any
// leaf that is not readable text — a named part (filename/disposition)
// or a non-text body outright.
func (p *partInfo) isAttachment() bool {
	if p.media == "multipart" {
		return false
	}
	return !p.isReadable()
}

// attachName is the name an attachment lists and refuses under: the
// declared filename, else a synthesised part-N.subtype spelling.
func (p *partInfo) attachName() string {
	if p.filename != "" {
		return p.filename
	}
	n := p.num
	if n == "" {
		n = "0"
	}
	sub := p.sub
	if sub == "" {
		sub = "bin"
	}
	return "part-" + n + "." + sub
}

// mimeType renders the listing's type column.
func (p *partInfo) mimeType() string {
	m, s := p.media, p.sub
	if m == "" {
		m = "application"
	}
	if s == "" {
		s = "octet-stream"
	}
	return m + "/" + s
}

// pickBody chooses the part FETCH renders: the first text/plain leaf in
// walk order, else the first text/html leaf (rendered stripped), else
// nil — no readable text is itself a named refusal.
func pickBody(root *partInfo) *partInfo {
	if root == nil {
		return nil
	}
	if root.media != "multipart" {
		if root.isReadable() {
			return root
		}
		return nil
	}
	var html *partInfo
	for _, k := range root.kids {
		if pick := pickLeaf(k, "plain"); pick != nil {
			return pick
		}
		if html == nil {
			html = pickLeaf(k, "html")
		}
	}
	return html
}

func pickLeaf(p *partInfo, wantSub string) *partInfo {
	if p.media == "multipart" {
		for _, k := range p.kids {
			if r := pickLeaf(k, wantSub); r != nil {
				return r
			}
		}
		return nil
	}
	if p.media == "text" && p.sub == wantSub {
		return p
	}
	return nil
}

// attachments lists every attachment leaf in walk order.
func attachments(root *partInfo) []*partInfo {
	var out []*partInfo
	var walk func(p *partInfo)
	walk = func(p *partInfo) {
		if p == nil {
			return
		}
		if p.media == "multipart" {
			for _, k := range p.kids {
				walk(k)
			}
			return
		}
		if p.isAttachment() {
			out = append(out, p)
		}
	}
	walk(root)
	return out
}

// section is the BODY[...] section string a FETCH asks for: a leaf part
// number inside a multipart, or "TEXT" for the single-part root.
func (p *partInfo) section() string {
	if p.num == "" {
		return "TEXT"
	}
	return p.num
}

// stripHTML flattens HTML to text: <script>/<style> bodies dropped,
// block-level tags become newlines, all other tags vanish, the six
// common entities decode, blank runs collapse. It is deliberately
// simple — the honest answer to HTML mail in a plaintext client.
func stripHTML(s string) string {
	var b strings.Builder
	low := lowerASCII(s)
	i := 0
	for i < len(s) {
		if s[i] != '<' {
			b.WriteByte(s[i])
			i++
			continue
		}
		// Scan the tag.
		j := i + 1
		for j < len(s) && s[j] != '>' {
			j++
		}
		tag := low[i+1 : min(j, len(s))]
		name := tag
		if k := strings.IndexAny(name, " \t/"); k >= 0 {
			name = name[:k]
		}
		i = min(j+1, len(s))
		switch name {
		case "script", "style", "head":
			// Drop the element body entirely.
			close := "</" + name
			if k := strings.Index(low[i:], close); k >= 0 {
				i += k
				if e := strings.IndexByte(low[i:], '>'); e >= 0 {
					i += e + 1
				}
			} else {
				return b.String()
			}
		case "br", "p", "/p", "div", "/div", "li", "tr", "/tr", "h1", "h2",
			"h3", "h4", "/h1", "/h2", "/h3", "/h4", "blockquote", "/blockquote", "hr", "ul", "/ul", "ol", "/ol":
			b.WriteByte('\n')
		}
	}
	return decodeEntities(collapseBlank(b.String()))
}

// decodeEntities resolves the six common entities.
func decodeEntities(s string) string {
	r := strings.NewReplacer(
		"&nbsp;", " ",
		"&amp;", "&",
		"&lt;", "<",
		"&gt;", ">",
		"&quot;", "\"",
		"&#39;", "'",
		"&apos;", "'",
	)
	return r.Replace(s)
}

// collapseBlank trims each line and drops empty lines.
func collapseBlank(s string) string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		l = strings.TrimSpace(l)
		if l != "" {
			out = append(out, l)
		}
	}
	return strings.Join(out, "\n")
}
