// Package main's doc.go is GOPAINT.ELF's pure half: the document model, the
// five tools' rasterization, the bounded undo history, and the canvas digest
// the markers report. Nothing in this file touches a syscall — every rule
// here is host-testable, and the class-B gate pins the same sums the host
// goldens pin.
//
// The document is a 0xAARRGGBB raster (the same word layout draw.BufferCanvas
// and webrender.Image use) painted 1:1 inside the window. Tools write through
// a txn so the first write to a pixel in a gesture records its old value —
// that sparse patch is the undo step, bounded by both a step count and a
// byte budget so a full-canvas flood fill cannot evict the heap.
package main

// Document bounds: the card's canvas cap. The default is the size a fresh
// window shows; an opened or dropped image adopts the file's own geometry.
const (
	docMaxW  = 1024
	docMaxH  = 768
	docMaxPx = docMaxW * docMaxH
	docDefW  = 640
	docDefH  = 480
)

// toolID names the five tools; toolName is the marker + state spelling.
type toolID uint8

const (
	toolBrush toolID = iota
	toolLine
	toolRect
	toolFill
	toolErase
	toolCount
)

var toolNames = [toolCount]string{"brush", "line", "rect", "fill", "erase"}

func toolName(t toolID) string {
	if int(t) < len(toolNames) {
		return toolNames[t]
	}
	return "?"
}

// palette is the fixed 16-color table (PICO-8's own set, alpha-forced
// opaque). Index 7 is the paper — a fresh canvas's fill and the eraser's
// paint — so "erase" restores exactly what a blank document holds.
var palette = [16]uint32{
	0xff000000, 0xff1d2b53, 0xff7e2553, 0xff008751,
	0xffab5236, 0xff5f574f, 0xffc2c3c7, 0xfffff1e8,
	0xffff004d, 0xffffa300, 0xffffec27, 0xff00e436,
	0xff29adff, 0xff83769c, 0xffff77a8, 0xffffccaa,
}

const paperIdx = 7

// brushSizes is the two-size table the size toggle walks.
var brushSizes = [2]int{4, 12}

// doc is the canvas under edit.
type doc struct {
	w, h  int
	pix   []uint32
	path  string // last saved/loaded share path, "" until one exists
	dirty bool
	hist  hist
}

func newDoc(w, h int) *doc {
	if w <= 0 || h <= 0 {
		w, h = docDefW, docDefH
	}
	if w > docMaxW {
		w = docMaxW
	}
	if h > docMaxH {
		h = docMaxH
	}
	d := &doc{w: w, h: h, pix: make([]uint32, w*h)}
	for i := range d.pix {
		d.pix[i] = palette[paperIdx]
	}
	return d
}

// adopt wraps a decoded image as the document. nil/bad geometry is refused
// by the caller before this runs.
func docFrom(w, h int, pix []uint32) *doc {
	return &doc{w: w, h: h, pix: pix, dirty: true}
}

func (d *doc) at(x, y int) uint32 {
	if x < 0 || y < 0 || x >= d.w || y >= d.h {
		return 0
	}
	return d.pix[y*d.w+x]
}

// sum is the doc's FNV-1a digest — the marker payload the gate asserts and
// the host goldens reproduce byte for byte.
func (d *doc) sum() uint64 {
	h := uint64(0xcbf29ce484222325)
	for _, p := range d.pix {
		for i := 0; i < 4; i++ {
			h ^= uint64(byte(p >> (8 * uint(i))))
			h *= 0x100000001b3
		}
	}
	return h
}

// probe reports one pixel — the named point a gate pins after each leg.
func (d *doc) probe(x, y int) uint32 { return d.at(x, y) }

// --- undo ------------------------------------------------------------------

// patch is one gesture's sparse before-image: idx lists the doc pixels the
// gesture touched (first-touch order, deduplicated) and old carries the
// values they held. A whole-canvas op is idx[0..w*h]; nothing denser exists.
type patch struct {
	idx []int32
	old []uint32
}

// txn records an in-progress gesture's first touches. The map is the dedup;
// a paint stamp revisits pixels constantly and only the FIRST old value is
// the revert.
type txn struct {
	d    *doc
	seen map[int32]struct{}
	p    patch
}

func (d *doc) begin() *txn {
	return &txn{d: d, seen: make(map[int32]struct{})}
}

// set writes v at (x,y), recording the pre-write value on first touch.
// Out-of-bounds is a no-op so tool rasterizers need no clipping of their own.
func (t *txn) set(x, y int, v uint32) {
	if x < 0 || y < 0 || x >= t.d.w || y >= t.d.h {
		return
	}
	i := int32(y*t.d.w + x)
	if _, ok := t.seen[i]; !ok {
		t.seen[i] = struct{}{}
		t.p.idx = append(t.p.idx, i)
		t.p.old = append(t.p.old, t.d.pix[i])
	}
	t.d.pix[i] = v
}

// touches reports the gesture's distinct-pixel count — the fill leg's bound
// proof and the marker's n= payload.
func (t *txn) touches() int { return len(t.p.idx) }

// commit seals the txn into the undo history and dirties the document.
func (d *doc) commit(t *txn) {
	if t == nil || len(t.p.idx) == 0 {
		return
	}
	d.hist.push(t.p)
	d.dirty = true
}

// hist is the undo stack: newest last. Two bounds apply on push — histSteps
// entries and histBytes of payload — and the oldest step is what evicts.
// A single step larger than histBytes still lands (an op you cannot undo at
// all would be a lie); it just stands alone.
type hist struct {
	steps []patch
	bytes int
}

const (
	histSteps = 16
	histBytes = 8 << 20
)

func (h *hist) push(p patch) {
	pb := len(p.idx)*4 + len(p.old)*4
	h.steps = append(h.steps, p)
	h.bytes += pb
	for len(h.steps) > 1 && (len(h.steps) > histSteps || h.bytes > histBytes) {
		h.bytes -= len(h.steps[0].idx)*4 + len(h.steps[0].old)*4
		h.steps = h.steps[1:]
	}
}

// undo reverts the newest step; false when the ring is empty — the app's
// marker prints `undo empty` and no repaint is owed.
func (h *hist) undo(d *doc) bool {
	n := len(h.steps)
	if n == 0 {
		return false
	}
	p := h.steps[n-1]
	h.steps = h.steps[:n-1]
	h.bytes -= len(p.idx)*4 + len(p.old)*4
	for k, i := range p.idx {
		d.pix[i] = p.old[k]
	}
	d.dirty = true
	return true
}

func (h *hist) depth() int { return len(h.steps) }
func (h *hist) clear()     { h.steps = nil; h.bytes = 0 }

// --- tool rasterization ------------------------------------------------------
// All tools write through the txn; none allocate on the pixel hot path.
// Stamps are hard-edged (a paint program's brush, not the seat's AA chrome).

// disk stamps a filled circle of radius r centered at (cx,cy).
func (t *txn) disk(cx, cy, r int, v uint32) {
	for dy := -r; dy <= r; dy++ {
		for dx := -r; dx <= r; dx++ {
			if dx*dx+dy*dy <= r*r {
				t.set(cx+dx, cy+dy, v)
			}
		}
	}
}

// segment strokes a round brush of radius r along a→b — the brush and
// eraser's drag path and the line tool's commit all share it. The step is
// the pixel-accurate line length, so a fast drag cannot skip pixels.
func (t *txn) segment(a, b pt, r int, v uint32) {
	dx, dy := b.x-a.x, b.y-a.y
	n := abs(dx)
	if abs(dy) > n {
		n = abs(dy)
	}
	if n == 0 {
		t.disk(a.x, a.y, r, v)
		return
	}
	for k := 0; k <= n; k++ {
		t.disk(a.x+dx*k/n, a.y+dy*k/n, r, v)
	}
}

// band fills an axis-aligned rect inside the txn — the rect tool's outline
// edges and any wide stamp share it.
func (t *txn) band(x, y, w, h int, v uint32) {
	for yy := y; yy < y+h; yy++ {
		for xx := x; xx < x+w; xx++ {
			t.set(xx, yy, v)
		}
	}
}

// rectOutline strokes a weight-px rectangle outline on r — the rect tool's
// commit. An outline (not a fill) is what makes the fill tool demonstrable:
// the gesture leaves an enclosed same-color region to flood.
func (t *txn) rectOutline(r rect, weight int, v uint32) {
	if weight < 1 {
		weight = 1
	}
	t.band(r.x, r.y, r.w, weight, v)
	t.band(r.x, r.y+r.h-weight, r.w, weight, v)
	t.band(r.x, r.y+weight, weight, r.h-2*weight, v)
	t.band(r.x+r.w-weight, r.y+weight, weight, r.h-2*weight, v)
}

// fill is the bounded flood fill: 4-way spread from (x,y) over pixels equal
// to the seed color, written as v. The stack is explicit and bounded —
// the visited bitset means a pixel pushes at most once, so cap is w*h by
// construction — never recursion. The bitset is per-call so a 1024×768 doc
// costs ~98 KiB of book-keeping plus touched pixels.
func (t *txn) fill(x, y int, v uint32) (touched int) {
	d := t.d
	if x < 0 || y < 0 || x >= d.w || y >= d.h {
		return 0
	}
	seed := d.pix[y*d.w+x]
	if seed == v {
		return 0
	}
	seen := make([]uint64, (d.w*d.h+63)/64)
	stack := make([]int32, 0, 1024)
	push := func(i int32) bool {
		if seen[i>>6]&(1<<uint(i&63)) != 0 {
			return true
		}
		seen[i>>6] |= 1 << uint(i&63)
		if len(stack) >= d.w*d.h { // the structural bound: unreachable with `seen`
			return false
		}
		stack = append(stack, i)
		return true
	}
	push(int32(y*d.w + x))
	for len(stack) > 0 {
		i := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		px, py := int(i)%d.w, int(i)/d.w
		if d.pix[i] != seed {
			continue
		}
		t.set(px, py, v)
		touched++
		if px > 0 && !push(i-1) {
			break
		}
		if px < d.w-1 && !push(i+1) {
			break
		}
		if py > 0 && !push(i-int32(d.w)) {
			break
		}
		if py < d.h-1 && !push(i+int32(d.w)) {
			break
		}
	}
	return touched
}

// --- small geometry ----------------------------------------------------------

type pt struct{ x, y int }

type rect struct{ x, y, w, h int }

func rectFrom(a, b pt) rect {
	x0, y0 := min(a.x, b.x), min(a.y, b.y)
	return rect{x: x0, y: y0, w: abs(b.x-a.x) + 1, h: abs(b.y-a.y) + 1}
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
