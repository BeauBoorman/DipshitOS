package ttf

// The font registry (M99l, #2189): one manifest describes the staged faces,
// and a chain maps each rune to the (face, glyph) pair that covers it.
//
// The manifest is image/fonts/fonts.txt, staged as /host/FONTS.TXT, in the
// APPS.TXT v2 shape: `FILE.TTF | role=ui|mono|serif|symbol | order=N |
// weight=N | style=normal|italic`. Coverage is never declared — a chain reads
// each face's cmap at lookup, so the manifest cannot lie about what a face
// has.
//
// A chain is the cascade for one request: the selected primary face first,
// then the role's other faces in manifest order, then the symbol faces. Only
// primaries are loaded up front; every other face is read on the first miss,
// so a page that never misses reads only its primary faces. A rune nothing
// covers paints the primary's .notdef and is counted — never a silent hole.
//
// This file stays pure: face bytes arrive through the caller's Loader, and
// the marker stream through OnNotdef, so the registry never touches the OS.

// Manifest row cap: a registry is a handful of faces, not a collection.
const maxManifestFaces = 32

// FaceSpec is one manifest row.
type FaceSpec struct {
	File   string // share file name, e.g. "INTER.TTF"
	Role   string // "ui", "mono", "serif", "symbol"
	Order  int    // cascade rank inside the role; lowest is the default
	Weight int    // CSS-style weight; 400 normal, 700 bold
	Italic bool
}

// ManifestError is one refused manifest line. ParseManifest returns the first
// problem by name — a malformed manifest is refused whole, never half-read.
type ManifestError struct {
	Line int
	Why  string
}

func (e *ManifestError) Error() string {
	return "fonts.txt: line " + uitoa(e.Line) + ": " + e.Why
}

// uitoa is a small non-negative decimal formatter: the package stays off
// strconv/fmt so the guest image keeps its footprint discipline.
func uitoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

// ParseManifest decodes fonts.txt. Comments (#) and blank lines are skipped;
// every other line must be a `FILE | key=value ...` row with a known role. A
// malformed row — no file, no role, an unknown role, a non-numeric order or
// weight, an unknown style, or more than maxManifestFaces rows — refuses the
// whole manifest by name. Unknown keys are ignored (additive rows, the
// APPS.TXT v2 rule).
func ParseManifest(data []byte) ([]FaceSpec, error) {
	var specs []FaceSpec
	lineNo := 0
	rest := data
	for len(rest) > 0 {
		var line []byte
		if i := indexByte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i+1:]
		} else {
			line, rest = rest, nil
		}
		lineNo++
		line = trimBytes(line)
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		spec, err := parseManifestRow(line, lineNo)
		if err != nil {
			return nil, err
		}
		specs = append(specs, spec)
		if len(specs) > maxManifestFaces {
			return nil, &ManifestError{Line: lineNo, Why: "more than " + uitoa(maxManifestFaces) + " face rows"}
		}
	}
	if len(specs) == 0 {
		return nil, &ManifestError{Line: 0, Why: "no face rows"}
	}
	return specs, nil
}

func parseManifestRow(line []byte, lineNo int) (FaceSpec, error) {
	spec := FaceSpec{Weight: 400}
	fields := splitFields(line, '|')
	spec.File = string(trimBytes(fields[0]))
	if spec.File == "" || !bareShareName(spec.File) {
		return spec, &ManifestError{Line: lineNo, Why: "missing or invalid face file name"}
	}
	for _, f := range fields[1:] {
		key, val, ok := cutPair(trimBytes(f))
		if !ok {
			continue // not a key=value tail — ignored like an APPS.TXT v1 tail
		}
		switch string(key) {
		case "role":
			v := string(val)
			switch v {
			case "ui", "mono", "serif", "symbol":
				spec.Role = v
			default:
				return spec, &ManifestError{Line: lineNo, Why: "unknown role " + quote(v)}
			}
		case "order":
			n, ok := parseUint(val)
			if !ok {
				return spec, &ManifestError{Line: lineNo, Why: "order is not a number"}
			}
			spec.Order = n
		case "weight":
			n, ok := parseUint(val)
			if !ok || n == 0 {
				return spec, &ManifestError{Line: lineNo, Why: "weight is not a positive number"}
			}
			spec.Weight = n
		case "style":
			switch string(val) {
			case "normal":
			case "italic":
				spec.Italic = true
			default:
				return spec, &ManifestError{Line: lineNo, Why: "unknown style " + quote(string(val))}
			}
		default:
			// Unknown keys are a newer manifest, not a bad one.
		}
	}
	if spec.Role == "" {
		return spec, &ManifestError{Line: lineNo, Why: "row has no role="}
	}
	return spec, nil
}

func quote(s string) string { return `"` + s + `"` }

// bareShareName keeps the manifest honest: a face file is one share entry,
// never a path, so no row can reach outside the staged set.
func bareShareName(s string) bool {
	if len(s) == 0 || len(s) > 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		ok := c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' ||
			c >= '0' && c <= '9' || c == '_' || c == '.' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

func indexByte(b []byte, c byte) int {
	for i, v := range b {
		if v == c {
			return i
		}
	}
	return -1
}

func trimBytes(b []byte) []byte {
	i, j := 0, len(b)
	for i < j && (b[i] == ' ' || b[i] == '\t' || b[i] == '\r') {
		i++
	}
	for j > i && (b[j-1] == ' ' || b[j-1] == '\t' || b[j-1] == '\r') {
		j--
	}
	return b[i:j]
}

func splitFields(s []byte, sep byte) [][]byte {
	var out [][]byte
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == sep {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}

func cutPair(f []byte) (key, val []byte, ok bool) {
	for i := 0; i < len(f); i++ {
		if f[i] == '=' {
			return f[:i], trimBytes(f[i+1:]), i > 0
		}
	}
	return nil, nil, false
}

func parseUint(b []byte) (int, bool) {
	if len(b) == 0 || len(b) > 4 {
		return 0, false
	}
	n := 0
	for _, c := range b {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
	}
	return n, true
}

// Query is the face a run of text wants: a role plus the weight/style
// attributes the requester asked for.
type Query struct {
	Role   string // "ui", "mono", "serif", "symbol"
	Bold   bool   // wants weight >= 600
	Italic bool   // wants style=italic
}

// Loader turns a manifest File name into a parsed face. It is the only byte
// seam: the registry itself never reads a file, so host tests inject fixtures
// and the guests inject their bounded share reads.
type Loader func(file string) (*Face, error)

// loadResult caches one file's outcome: a parsed face, or failed so the same
// missing file is not re-read for every uncovered rune on a page.
type loadResult struct {
	face *Face
	ok   bool
}

// Registry is the parsed manifest plus its lazy faces. The zero value is not
// useful; build one with NewRegistry.
type Registry struct {
	specs  []FaceSpec
	load   Loader
	faces  map[string]loadResult
	chains map[Query]*Chain
	notdef int

	// OnNotdef, when set, runs each time a rune exhausts its chain, with the
	// running miss count. The browser wires it to the serial marker
	// `fonts: notdef=N`; nil keeps counting without a line.
	OnNotdef func(n int)
}

// NewRegistry builds a registry over a parsed manifest. Faces are lazy: the
// loader runs when a chain first selects a face, and a failed read is cached
// rather than retried per rune.
func NewRegistry(specs []FaceSpec, load Loader) *Registry {
	return &Registry{
		specs:  specs,
		load:   load,
		faces:  map[string]loadResult{},
		chains: map[Query]*Chain{},
	}
}

// Specs is the decoded manifest, in file order.
func (r *Registry) Specs() []FaceSpec { return r.specs }

// Notdef is the count of rune lookups that exhausted their chain.
func (r *Registry) Notdef() int { return r.notdef }

func (r *Registry) face(i int) *Face {
	if r == nil || i < 0 || i >= len(r.specs) || r.load == nil {
		return nil
	}
	name := r.specs[i].File
	res, seen := r.faces[name]
	if !seen {
		f, err := r.load(name)
		res = loadResult{face: f, ok: err == nil && f != nil}
		r.faces[name] = res
	}
	return res.face
}

func (r *Registry) noteNotdef() {
	r.notdef++
	if r.OnNotdef != nil {
		r.OnNotdef(r.notdef)
	}
}

// attrMatch reports whether spec is the face q asks for. Bold wants
// weight >= 600, Italic wants style=italic, Bold+Italic wants both on one
// face, and a plain query wants both absent. The exact rule RegistryFonts
// uses, so a manifested-only-in-name bold face cannot silently take
// regular's slot — or vice versa.
func attrMatch(s FaceSpec, q Query) bool {
	switch {
	case q.Bold && q.Italic:
		return s.Weight >= 600 && s.Italic
	case q.Bold:
		return s.Weight >= 600 && !s.Italic
	case q.Italic:
		return s.Italic && s.Weight < 600
	default:
		return s.Weight < 600 && !s.Italic
	}
}

// order returns the spec indices for a role, sorted by (Order, file order).
func (r *Registry) order(role string) []int {
	var idx []int
	for i, s := range r.specs {
		if s.Role == role {
			idx = append(idx, i)
		}
	}
	// Insertion sort; a manifest has at most maxManifestFaces rows.
	for i := 1; i < len(idx); i++ {
		for j := i; j > 0 && r.specs[idx[j]].Order < r.specs[idx[j-1]].Order; j-- {
			idx[j], idx[j-1] = idx[j-1], idx[j]
		}
	}
	return idx
}

// Primary resolves the strictly matching face for q and loads it now — this
// is the eager end of the lazy spectrum, used by callers that report per-role
// presence (the browser's ui=/mono= states). A query with no strict match
// returns nil rather than borrowing a different-looking face.
func (r *Registry) Primary(q Query) *Face {
	for _, i := range r.order(q.Role) {
		if attrMatch(r.specs[i], q) {
			if f := r.face(i); f != nil {
				return f
			}
		}
	}
	return nil
}

// Chain is the cascade for one query: primary first, then the role's other
// faces in order, then the symbol faces in order. It is the run-splitting
// unit — pieces of a text run are grouped by which chain face covers them, so
// shaping later never crosses a face boundary. A chain whose named primary
// failed to load re-anchors on the role's next loadable face.
type Chain struct {
	reg   *Registry
	slots []int // spec indices in cascade order; slots[0] is the primary
}

// Chain resolves q to its cascade. The primary is the strictly matching face
// when one exists; a Bold+Italic query next tries {Bold} then {Italic}, then
// every query falls to the role's normal face, then the role's first face —
// the same degraded selection the callers' own fallbacks encode. A role the
// manifest does not list at all — or whose faces all fail to load — yields
// nil, and the caller falls back to its own no-face path (the renderer's
// bitmap).
func (r *Registry) Chain(q Query) *Chain {
	if r == nil {
		return nil
	}
	if c, ok := r.chains[q]; ok {
		return c
	}
	role := r.order(q.Role)
	if len(role) == 0 {
		return nil
	}
	// A Bold+Italic request degrades through Bold, then Italic, before the
	// role's normal face — a manifest without a BI row paints a styled face,
	// never Regular, while a manifest without any styled faces still answers.
	wants := []Query{q}
	if q.Bold && q.Italic {
		wants = append(wants, Query{Role: q.Role, Bold: true}, Query{Role: q.Role, Italic: true})
	}
	primary := -1
	for _, want := range wants {
		for _, i := range role {
			if attrMatch(r.specs[i], want) && r.face(i) != nil {
				primary = i
				break
			}
		}
		if primary >= 0 {
			break
		}
	}
	if primary < 0 {
		// No strict match: the role's normal face, then its first face, is
		// the primary — a bold request with no bold face still paints text.
		for _, i := range role {
			if r.specs[i].Weight < 600 && !r.specs[i].Italic && r.face(i) != nil {
				primary = i
				break
			}
		}
	}
	if primary < 0 {
		// The role's first loadable face keeps a broken-manifest row from
		// taking the whole cascade down with it.
		for _, i := range role {
			if r.face(i) != nil {
				primary = i
				break
			}
		}
	}
	if primary < 0 {
		return nil
	}
	slots := []int{primary}
	for _, i := range role {
		if i != primary {
			slots = append(slots, i)
		}
	}
	for _, i := range r.order("symbol") {
		slots = append(slots, i)
	}
	c := &Chain{reg: r, slots: slots}
	r.chains[q] = c
	return c
}

// Primary returns the chain's first face, loading it if needed. A nil primary
// means the chain cannot paint anything and the caller degrades.
func (c *Chain) Primary() *Face {
	if c == nil || len(c.slots) == 0 {
		return nil
	}
	return c.reg.face(c.slots[0])
}

// Piece is a slice of a text run painted by one face. Face is nil only when
// no chain face could be loaded at all; callers treat it as their no-face
// fallback rather than painting.
type Piece struct {
	Face *Face
	Text string
}

// resolve maps one rune to the chain face that covers it, loading faces
// lazily on the way. A rune nothing covers takes the primary (its .notdef
// paints there) and is counted. Control runes never cascade: they carry no
// ink, so they answer the primary without spending a load.
func (c *Chain) resolve(r rune) *Face {
	if r < 0x20 {
		return c.Primary()
	}
	for _, i := range c.slots {
		f := c.reg.face(i)
		if f == nil {
			continue
		}
		if f.GlyphIndex(r) != 0 {
			return f
		}
	}
	c.reg.noteNotdef()
	return c.Primary()
}

// Split divides text at face boundaries: maximal runs of runes resolved to
// the same face become one Piece, in text order. Measure sums the pieces and
// Paint walks them, so layout and paint can never disagree about where the
// fallback boundary sits.
func (c *Chain) Split(text string) []Piece {
	if c == nil {
		return nil
	}
	var out []Piece
	start := 0
	for i, r := range text {
		f := c.resolve(r)
		if len(out) == 0 {
			out = append(out, Piece{Face: f})
			continue
		}
		if out[len(out)-1].Face != f {
			out[len(out)-1].Text = text[start:i]
			out = append(out, Piece{Face: f})
			start = i
		}
	}
	if len(out) > 0 {
		out[len(out)-1].Text = text[start:]
	}
	return out
}

// Measure is the pixel width of a run under this chain: the per-piece widths
// summed, which is exactly what a Paint walk of the same pieces advances.
func (c *Chain) Measure(text string, px int) int {
	if c == nil {
		return 0
	}
	total := 0
	for _, p := range c.Split(text) {
		if p.Face != nil {
			total += p.Face.Measure(p.Text, px)
		}
	}
	return total
}
