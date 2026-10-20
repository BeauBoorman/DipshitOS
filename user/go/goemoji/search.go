package main

// Fuzzy search over names and aliases (M146a). The matcher is a
// deterministic subsequence scorer: every query rune must appear in order;
// a contiguous run, a match at a word head and a shorter candidate all
// score better, so "fire" ranks fire first and "up" prefers thumbs up over
// longer incidental hits. No allocation beyond the result index list.

// scoreString returns the match score of q against s, or -1 when q's runes
// do not appear in order. Scoring is byte-oriented: names and aliases are
// ASCII by convention (the glyph table and the kaomoji names all are).
func scoreString(q, s string) int {
	if q == "" {
		return 0
	}
	qi := 0
	score, streak := 0, 0
	for i := 0; i < len(s) && qi < len(q); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		qc := q[qi]
		if qc >= 'A' && qc <= 'Z' {
			qc += 'a' - 'A'
		}
		if c != qc {
			streak = 0
			continue
		}
		score++
		if i == 0 || s[i-1] == ' ' || s[i-1] == '-' {
			score += 8 // a word head carries the name's meaning
		}
		if streak > 0 {
			score += 4 // contiguous run
		}
		streak++
		qi++
	}
	if qi < len(q) {
		return -1
	}
	// Prefer the tighter answer: a whole-name hit on a short candidate
	// outranks the same letters scattered through a long one.
	return score*64 - len(s)
}

// scoreCandidate is the best score over a name plus its aliases.
func scoreCandidate(q, name string, aliases []string) int {
	best := scoreString(q, name)
	for _, a := range aliases {
		if sc := scoreString(q, a); sc > best {
			best = sc
		}
	}
	return best
}

// filter returns indices into the table, best first, matching the query
// against each entry's name and aliases. Ties break on the table order —
// stable, and index-order preserves the kernel's curated sequence.
func filter(q string, n int, cand func(i int) (name string, aliases []string)) []int {
	var order []int
	var scores []int
	for i := 0; i < n; i++ {
		name, aliases := cand(i)
		sc := scoreCandidate(q, name, aliases)
		if sc < 0 {
			continue
		}
		// Insertion sort: ≤ a few dozen rows.
		j := len(order)
		order = append(order, i)
		scores = append(scores, sc)
		for j > 0 && scores[j-1] < scores[j] {
			order[j-1], order[j] = order[j], order[j-1]
			scores[j-1], scores[j] = scores[j], scores[j-1]
			j--
		}
	}
	return order
}
