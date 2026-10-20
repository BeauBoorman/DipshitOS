package main

// Per-channel scrollback ring. BacklogCap is the card's bound: each
// channel keeps the newest 256 entries and drops the oldest; the drop
// count is kept so the UI can render "N earlier lines dropped" honestly
// rather than pretending the ring is the whole history. The ring is
// internally synchronised: the session goroutine Add()s while the UI
// goroutine snapshots with Entries()/At().

import "sync"

const BacklogCap = 256

// EntryKind names the backlog line's origin so the UI can style it.
type EntryKind int

const (
	EntryMsg    EntryKind = iota // PRIVMSG
	EntryNotice                  // NOTICE
	EntryJoin                    // a JOIN (ours or a peer's)
	EntryPart                    // a PART
	EntryKick                    // a KICK
	EntryNick                    // a nick change we observed
	EntryStatus                  // server numeric / local status line
	EntryError                   // local error line (overlong, refused, ...)
)

// Entry is one backlog line. Channel is the channel the entry belongs to
// ("" for the server/status buffer), From the originating nick or server
// name, Text the rendered body, At the vi.Nanos instant it was recorded.
type Entry struct {
	Kind    EntryKind
	Channel string
	From    string
	Text    string
	At      int64
}

// Backlog is a bounded, internally-synchronised ring of Entry,
// oldest-evicting.
type Backlog struct {
	mu      sync.Mutex
	buf     []Entry
	head    int // index of oldest entry when n > 0
	n       int
	dropped uint64
}

// NewBacklog returns a ring that keeps at most cap entries; cap <= 0
// takes BacklogCap.
func NewBacklog(cap int) *Backlog {
	if cap <= 0 {
		cap = BacklogCap
	}
	return &Backlog{buf: make([]Entry, cap)}
}

// Add appends e, evicting the oldest entry when the ring is full.
func (b *Backlog) Add(e Entry) {
	b.mu.Lock()
	defer b.mu.Unlock()
	cap_ := len(b.buf)
	if b.n == cap_ {
		b.buf[b.head] = e
		b.head = (b.head + 1) % cap_
		b.dropped++
		return
	}
	b.buf[(b.head+b.n)%cap_] = e
	b.n++
}

// Len returns the live entry count.
func (b *Backlog) Len() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.n
}

// Dropped returns how many entries were evicted since creation.
func (b *Backlog) Dropped() uint64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.dropped
}

// At returns the i-th entry in oldest→newest order; out-of-range is the
// zero Entry.
func (b *Backlog) At(i int) Entry {
	b.mu.Lock()
	defer b.mu.Unlock()
	if i < 0 || i >= b.n {
		return Entry{}
	}
	return b.buf[(b.head+i)%len(b.buf)]
}

// Entries copies the ring out oldest→newest — the UI's snapshot for a
// repaint; the ring keeps ownership of its storage.
func (b *Backlog) Entries() []Entry {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]Entry, b.n)
	for i := 0; i < b.n; i++ {
		out[i] = b.buf[(b.head+i)%len(b.buf)]
	}
	return out
}
