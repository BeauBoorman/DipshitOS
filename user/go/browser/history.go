package main

// history is the browser's navigation stack: back/forward over visited
// targets, with the standard "a new navigation truncates the forward tail"
// rule. Pure data, so it is host-tested without a VM.
type entry struct {
	Target string
	Title  string
}

type history struct {
	entries []entry
	pos     int
}

func newHistory() *history { return &history{pos: -1} }

func (h *history) current() (entry, bool) {
	if h.pos < 0 || h.pos >= len(h.entries) {
		return entry{}, false
	}
	return h.entries[h.pos], true
}

// push records a navigation. A push while not at the tail drops the forward
// entries (the browser rule).
func (h *history) push(e entry) {
	if h.pos+1 < len(h.entries) {
		h.entries = h.entries[:h.pos+1]
	}
	if h.pos >= 0 && h.entries[h.pos].Target == e.Target {
		if e.Title != "" {
			h.entries[h.pos].Title = e.Title
		}
		return
	}
	h.entries = append(h.entries, e)
	h.pos = len(h.entries) - 1
}

// replace updates the entry at the cursor without adding one (used when a
// reload changes a title).
func (h *history) replace(e entry) {
	if h.pos < 0 || h.pos >= len(h.entries) {
		h.push(e)
		return
	}
	h.entries[h.pos] = e
}

func (h *history) canBack() bool    { return h.pos > 0 }
func (h *history) canForward() bool { return h.pos >= 0 && h.pos+1 < len(h.entries) }
func (h *history) len() int         { return len(h.entries) }

// recent returns the newest-first tail of the stack, capped at n: the rows
// the history dropdown lists (M126a #2593). Row i is entries[len-1-i].
func (h *history) recent(n int) []entry {
	if n > len(h.entries) {
		n = len(h.entries)
	}
	out := make([]entry, n)
	for i := 0; i < n; i++ {
		out[i] = h.entries[len(h.entries)-1-i]
	}
	return out
}

// cursorRow is the row index recent() assigns the cursor entry, -1 when the
// stack is empty. The dropdown marks it as the "you are here" row.
func (h *history) cursorRow() int {
	if h.pos < 0 {
		return -1
	}
	return len(h.entries) - 1 - h.pos
}

// back moves the cursor one entry toward the oldest and returns it.
func (h *history) back() (entry, bool) {
	if !h.canBack() {
		return entry{}, false
	}
	h.pos--
	return h.entries[h.pos], true
}

// forward moves the cursor one entry toward the newest and returns it.
func (h *history) forward() (entry, bool) {
	if !h.canForward() {
		return entry{}, false
	}
	h.pos++
	return h.entries[h.pos], true
}
