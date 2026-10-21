package main

// GOMINE.ELF — the M145a minesweeper engine (issue #2796). Pure board
// logic, no vi calls: generation, seeded mine placement with a safe
// first click, explicit-stack flood reveal, flags, the number chord,
// win/loss tables, and the save_state wire format — all host-testable.
//
// Board sizes are the three classic presets. Mines are placed lazily on
// the first reveal from the game's seed: the clicked cell AND its eight
// neighbours are excluded, so a first click always opens a region (the
// "first click safe" rule — a lone safe cell would still be 'safe' but
// the flood reveal is what makes a first click useful).
//
// save_state wire (Save/Load): the seat owns the envelope; the app owns
// this byte format.
//
//	0      4   magic "GMS1"
//	4      1   version (1)
//	5      1   size index (0 beginner, 1 intermediate, 2 expert)
//	6      2   cols LE
//	8      2   rows LE
//	10     4   mines LE
//	14     8   seed LE (signed ok, bits preserved)
//	22     8   elapsed seconds LE
//	30     1   state: 0 new 1 playing 2 won 3 dead
//	31     4   revealed count LE
//	35     4   flagged count LE
//	39     ..  bitsets: mine, revealed, flagged — ceil(cells/8) bytes each,
//	           cell index = y*cols+x, bit = index&7
//
// M152d (issue #2918): version 2 appends the per-difficulty best times —
// 3 × u64 seconds (beginner, intermediate, expert; 0 = no win on that
// board yet). The record is session state like GOSOL's stats line: it
// carries board-to-board inside the app and through the blob, so it
// survives snapshot/restore but not a fresh launch (no `file` grant).
// A v1 blob still decodes with the record zeroed.
//
// Load refuses a short buffer, a bad magic/version, a size that does not
// match cols*rows, and counts that exceed the cell count — a stale or
// torn blob is a fresh game, never a misread board.

type Size struct {
	Name       string
	Cols, Rows int
	Mines      int
}

var sizes = [3]Size{
	{Name: "beginner", Cols: 9, Rows: 9, Mines: 10},
	{Name: "intermediate", Cols: 16, Rows: 16, Mines: 40},
	{Name: "expert", Cols: 30, Rows: 16, Mines: 99},
}

const (
	stateNew     = 0
	statePlaying = 1
	stateWon     = 2
	stateDead    = 3

	saveMagic = "GMS1"
	saveVer   = 2
	saveHead  = 39
	saveBest  = 3 * 8 // the v2 tail: one u64 best time per difficulty
)

// Board is one minesweeper game. Slices are indexed y*Cols+x.
type Board struct {
	Size
	seed      int64
	mine      []bool
	adj       []uint8
	revealed  []bool
	flagged   []bool
	started   bool // mines placed (first reveal consumed)
	state     int
	revealedN int
	flaggedN  int
	elapsed   int64     // seconds, owned by main; saved verbatim
	best      [3]uint64 // best win seconds per size index; 0 = none
}

// NewBoard returns a board for size index s (clamped 0..2). Mines are NOT
// placed yet — placeMines runs on the first Reveal so it can honour the
// safe-first-click exclusion.
func NewBoard(s int, seed int64) *Board {
	if s < 0 || s > 2 {
		s = 0
	}
	sz := sizes[s]
	cells := sz.Cols * sz.Rows
	return &Board{
		Size:     sz,
		seed:     seed,
		mine:     make([]bool, cells),
		adj:      make([]uint8, cells),
		revealed: make([]bool, cells),
		flagged:  make([]bool, cells),
		state:    stateNew,
	}
}

// xorshift64* — the seeded PRNG for mine placement. Deterministic across
// host and guest (no time, no crypto), so a seed fully pins a board.
type rng struct{ s uint64 }

func (r *rng) next() uint64 {
	r.s ^= r.s >> 12
	r.s ^= r.s << 25
	r.s ^= r.s >> 27
	return r.s * 0x2545F4914F6CDD1D
}

func (r *rng) intn(n int) int { return int(r.next() % uint64(n)) }

// placeMines scatters Mines on cells outside the (x,y) exclusion zone
// (the cell plus its neighbours). A partial Fisher–Yates over the
// candidate indices keeps the placement order-free — same seed, same
// board, every run.
func (b *Board) placeMines(x, y int) {
	cells := b.Cols * b.Rows
	cand := make([]int, 0, cells)
	for i := 0; i < cells; i++ {
		cx, cy := i%b.Cols, i/b.Cols
		if dx := cx - x; dx >= -1 && dx <= 1 {
			if dy := cy - y; dy >= -1 && dy <= 1 {
				continue
			}
		}
		cand = append(cand, i)
	}
	r := rng{s: uint64(b.seed) | 1}
	n := b.Mines
	if n > len(cand) {
		n = len(cand)
	}
	for i := 0; i < n; i++ {
		j := i + r.intn(len(cand)-i)
		cand[i], cand[j] = cand[j], cand[i]
		b.mine[cand[i]] = true
	}
	for i := 0; i < cells; i++ {
		if b.mine[i] {
			continue
		}
		var n8 uint8
		x0, y0 := i%b.Cols, i/b.Cols
		for dy := -1; dy <= 1; dy++ {
			for dx := -1; dx <= 1; dx++ {
				nx, ny := x0+dx, y0+dy
				if (dx != 0 || dy != 0) && nx >= 0 && nx < b.Cols && ny >= 0 && ny < b.Rows && b.mine[ny*b.Cols+nx] {
					n8++
				}
			}
		}
		b.adj[i] = n8
	}
	b.started = true
	b.state = statePlaying
}

// Reveal opens cell (x,y). The first call places the mines around it.
// Returns the number of cells this call revealed and whether a mine was
// hit (the board is then Dead()). Flagged or already-revealed cells are
// a no-op; a dead or won board refuses further reveals.
func (b *Board) Reveal(x, y int) (int, bool) {
	if b.state == stateWon || b.state == stateDead || !b.inside(x, y) {
		return 0, false
	}
	if !b.started {
		b.placeMines(x, y)
	}
	i := y*b.Cols + x
	if b.revealed[i] || b.flagged[i] {
		return 0, false
	}
	if b.mine[i] {
		b.revealed[i] = true
		b.revealedN++
		b.state = stateDead
		return 1, true
	}
	// Flood fill on an EXPLICIT stack — no recursion: a 30x16 open field
	// would blow a goroutine's initial stack in a freestanding guest.
	before := b.revealedN
	stack := []int{i}
	b.revealed[i] = true
	b.revealedN++
	for len(stack) > 0 {
		cur := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if b.adj[cur] != 0 {
			continue
		}
		cx, cy := cur%b.Cols, cur/b.Cols
		for dy := -1; dy <= 1; dy++ {
			for dx := -1; dx <= 1; dx++ {
				nx, ny := cx+dx, cy+dy
				if nx < 0 || nx >= b.Cols || ny < 0 || ny >= b.Rows {
					continue
				}
				ni := ny*b.Cols + nx
				if b.revealed[ni] || b.flagged[ni] || b.mine[ni] {
					continue
				}
				b.revealed[ni] = true
				b.revealedN++
				stack = append(stack, ni)
			}
		}
	}
	b.checkWin()
	return b.revealedN - before, false
}

// ToggleFlag flips a hidden cell's flag. Returns the new flag total and
// whether the flag is now set on (x,y).
func (b *Board) ToggleFlag(x, y int) (int, bool) {
	if b.state == stateWon || b.state == stateDead || !b.inside(x, y) {
		return b.flaggedN, false
	}
	i := y*b.Cols + x
	if b.revealed[i] {
		return b.flaggedN, false
	}
	b.flagged[i] = !b.flagged[i]
	if b.flagged[i] {
		b.flaggedN++
	} else {
		b.flaggedN--
	}
	return b.flaggedN, b.flagged[i]
}

// Chord reveals the neighbours of a satisfied number: cell (x,y) must be
// a revealed cell whose adjacent flag count equals its number. Returns
// the cells revealed and whether the chord opened a mine (a wrong flag
// can lose the game). Right-click on a revealed cell routes here; the
// same call serves the both-buttons chord.
func (b *Board) Chord(x, y int) (int, bool) {
	if b.state != statePlaying || !b.inside(x, y) {
		return 0, false
	}
	i := y*b.Cols + x
	if !b.revealed[i] || b.adj[i] == 0 || b.flagsAround(x, y) != int(b.adj[i]) {
		return 0, false
	}
	total, hit := 0, false
	for dy := -1; dy <= 1 && b.state == statePlaying; dy++ {
		for dx := -1; dx <= 1; dx++ {
			nx, ny := x+dx, y+dy
			if !b.inside(nx, ny) {
				continue
			}
			ni := ny*b.Cols + nx
			if b.revealed[ni] || b.flagged[ni] {
				continue
			}
			n, boom := b.Reveal(nx, ny)
			total += n
			hit = hit || boom
		}
	}
	return total, hit
}

func (b *Board) flagsAround(x, y int) int {
	n := 0
	for dy := -1; dy <= 1; dy++ {
		for dx := -1; dx <= 1; dx++ {
			nx, ny := x+dx, y+dy
			if b.inside(nx, ny) && b.flagged[ny*b.Cols+nx] {
				n++
			}
		}
	}
	return n
}

func (b *Board) checkWin() {
	if b.state == statePlaying && b.revealedN == b.Cols*b.Rows-b.Mines {
		b.state = stateWon
		// A won board's mines are auto-flagged: the counter reads zero and
		// the user sees every mine marked.
		for i := 0; i < len(b.mine); i++ {
			if b.mine[i] && !b.flagged[i] {
				b.flagged[i] = true
				b.flaggedN++
			}
		}
		// The difficulty's best time scores only on a named preset — a
		// restored "custom" board (sizeIndex 0 by default) must not write
		// beginner's record.
		if i := b.sizeIndex(); sizes[i] == b.Size {
			if e := uint64(b.elapsed); b.elapsed >= 0 && (b.best[i] == 0 || e < b.best[i]) {
				b.best[i] = e
			}
		}
	}
}

func (b *Board) inside(x, y int) bool { return x >= 0 && x < b.Cols && y >= 0 && y < b.Rows }

// --- queries (draw + tests read through these, never the slices) --------

func (b *Board) Seed() int64            { return b.seed }
func (b *Board) State() int             { return b.state }
func (b *Board) Started() bool          { return b.started }
func (b *Board) Won() bool              { return b.state == stateWon }
func (b *Board) Dead() bool             { return b.state == stateDead }
func (b *Board) RevealedN() int         { return b.revealedN }
func (b *Board) FlaggedN() int          { return b.flaggedN }
func (b *Board) MineLeft() int          { return b.Mines - b.flaggedN }
func (b *Board) Revealed(x, y int) bool { return b.revealed[y*b.Cols+x] }
func (b *Board) Flagged(x, y int) bool  { return b.flagged[y*b.Cols+x] }
func (b *Board) Mine(x, y int) bool     { return b.mine[y*b.Cols+x] }
func (b *Board) Adj(x, y int) int       { return int(b.adj[y*b.Cols+x]) }
func (b *Board) SetElapsed(s int64)     { b.elapsed = s }
func (b *Board) Elapsed() int64         { return b.elapsed }

// Best is this board's own difficulty best; BestAt reads one slot.
func (b *Board) Best() int64 { return int64(b.best[b.sizeIndex()]) }
func (b *Board) BestAt(i int) int64 {
	if i < 0 || i > 2 {
		return 0
	}
	return int64(b.best[i])
}

// --- save_state ---------------------------------------------------------

func putLE(b []byte, off, n int, v uint64) {
	for i := 0; i < n; i++ {
		b[off+i] = byte(v >> (8 * i))
	}
}

func getLE(b []byte, off, n int) uint64 {
	var v uint64
	for i := 0; i < n; i++ {
		v |= uint64(b[off+i]) << (8 * i)
	}
	return v
}

func bitsetBytes(cells int) int { return (cells + 7) / 8 }

func packBits(dst []byte, src []bool) {
	for i, v := range src {
		if v {
			dst[i/8] |= 1 << (i % 8)
		}
	}
}

func unpackBits(dst []bool, src []byte) {
	for i := range dst {
		dst[i] = src[i/8]>>(i%8)&1 == 1
	}
}

// Save serializes the board for the seat's save_state handoff.
func (b *Board) Save() []byte {
	cells := b.Cols * b.Rows
	bs := bitsetBytes(cells)
	out := make([]byte, saveHead+3*bs+saveBest)
	copy(out, saveMagic)
	out[4] = saveVer
	out[5] = byte(b.sizeIndex())
	putLE(out, 6, 2, uint64(b.Cols))
	putLE(out, 8, 2, uint64(b.Rows))
	putLE(out, 10, 4, uint64(b.Mines))
	putLE(out, 14, 8, uint64(b.seed))
	putLE(out, 22, 8, uint64(b.elapsed))
	out[30] = byte(b.state)
	putLE(out, 31, 4, uint64(b.revealedN))
	putLE(out, 35, 4, uint64(b.flaggedN))
	packBits(out[saveHead:saveHead+bs], b.mine)
	packBits(out[saveHead+bs:saveHead+2*bs], b.revealed)
	packBits(out[saveHead+2*bs:saveHead+3*bs], b.flagged)
	for i := 0; i < 3; i++ {
		putLE(out, saveHead+3*bs+i*8, 8, b.best[i])
	}
	return out
}

func (b *Board) sizeIndex() int {
	for i, s := range sizes {
		if s.Cols == b.Cols && s.Rows == b.Rows && s.Mines == b.Mines {
			return i
		}
	}
	return 0
}

// LoadSave decodes a saved blob. The second return is false for any
// malformed or inconsistent blob — the caller starts a fresh game.
func LoadSave(buf []byte) (*Board, bool) {
	if len(buf) < saveHead || string(buf[:4]) != saveMagic ||
		buf[4] == 0 || buf[4] > saveVer {
		return nil, false
	}
	ver := buf[4]
	cols, rows := int(getLE(buf, 6, 2)), int(getLE(buf, 8, 2))
	mines := int(getLE(buf, 10, 4))
	cells := cols * rows
	if cols <= 0 || rows <= 0 || cells > 30*16 || mines <= 0 || mines >= cells {
		return nil, false
	}
	bs := bitsetBytes(cells)
	want := saveHead + 3*bs
	if ver >= 2 {
		want += saveBest
	}
	if len(buf) != want {
		return nil, false
	}
	b := &Board{
		Size:     Size{Name: "custom", Cols: cols, Rows: rows, Mines: mines},
		seed:     int64(getLE(buf, 14, 8)),
		mine:     make([]bool, cells),
		adj:      make([]uint8, cells),
		revealed: make([]bool, cells),
		flagged:  make([]bool, cells),
		started:  true,
		state:    int(buf[30]),
		elapsed:  int64(getLE(buf, 22, 8)),
	}
	if s := int(buf[5]); s >= 0 && s <= 2 {
		b.Size = sizes[s]
	}
	if b.state < stateNew || b.state > stateDead {
		return nil, false
	}
	unpackBits(b.mine, buf[saveHead:saveHead+bs])
	unpackBits(b.revealed, buf[saveHead+bs:saveHead+2*bs])
	unpackBits(b.flagged, buf[saveHead+2*bs:])
	b.revealedN = int(getLE(buf, 31, 4))
	b.flaggedN = int(getLE(buf, 35, 4))
	if b.revealedN > cells || b.flaggedN > cells {
		return nil, false
	}
	if ver >= 2 {
		for i := 0; i < 3; i++ {
			b.best[i] = getLE(buf, saveHead+3*bs+i*8, 8)
		}
	}
	// Rebuild the adjacency table — it is derived state, never serialized.
	for i := 0; i < cells; i++ {
		if b.mine[i] {
			continue
		}
		x0, y0 := i%cols, i/cols
		for dy := -1; dy <= 1; dy++ {
			for dx := -1; dx <= 1; dx++ {
				nx, ny := x0+dx, y0+dy
				if (dx != 0 || dy != 0) && nx >= 0 && nx < cols && ny >= 0 && ny < rows && b.mine[ny*cols+nx] {
					b.adj[i]++
				}
			}
		}
	}
	return b, true
}
