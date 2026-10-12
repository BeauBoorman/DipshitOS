package gitread

// Commit walk for the log view: first-parent chain from HEAD, subject only.

// Rev is one log row.
type Rev struct {
	Sha     [20]byte
	Subject string
}

// parseCommit splits tree, parents and the first message line out of raw
// commit bytes ("tree ...\nparent ...\n...\n\nmessage").
func parseCommit(data []byte) (tree [20]byte, parents [][20]byte, subject string, ok bool) {
	tree, ok = CommitTree(data)
	if !ok {
		return tree, nil, "", false
	}
	rest := data
	for {
		nl := indexByteByte(rest, '\n')
		if nl < 0 {
			break
		}
		line := rest[:nl]
		rest = rest[nl+1:]
		if len(line) == 0 {
			// header end: message begins
			msg := rest
			if end := indexByteByte(msg, '\n'); end >= 0 {
				msg = msg[:end]
			}
			return tree, parents, string(msg), true
		}
		if len(line) > 7 && string(line[:7]) == "parent " && len(line) >= 47 {
			if id, ok := HexDecode(string(line[7:47])); ok {
				parents = append(parents, id)
			}
		}
	}
	return tree, parents, "", true
}

// CommitParents returns the parent ids recorded in a raw commit body —
// the ancestry links a pull's fast-forward check walks (#2203).
func CommitParents(data []byte) ([][20]byte, bool) {
	_, parents, _, ok := parseCommit(data)
	return parents, ok
}

func indexByteByte(b []byte, c byte) int {
	for i, v := range b {
		if v == c {
			return i
		}
	}
	return -1
}

// Log walks the first-parent chain up to limit commits (0 -> 50). The walk
// stops at a missing object or a cycle; a commit with an unreadable message
// is skipped rather than fatal.
func (r *Repo) Log(limit int) ([]Rev, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 100 {
		limit = 100
	}
	head, err := r.Head()
	if err != nil {
		return nil, err
	}
	seen := map[[20]byte]bool{}
	var out []Rev
	cur := head
	for len(out) < limit {
		if seen[cur] {
			break
		}
		seen[cur] = true
		o, ok := r.Get(cur)
		if !ok || o.Type != ObjCommit {
			break
		}
		_, parents, subject, ok := parseCommit(o.Data)
		if !ok {
			break
		}
		out = append(out, Rev{Sha: cur, Subject: subject})
		if len(parents) == 0 {
			break
		}
		cur = parents[0]
	}
	return out, nil
}

// ShortHex is the 7-hex display prefix of a sha.
func ShortHex(id [20]byte) string {
	s := HexEncode(id[:])
	if len(s) > 7 {
		s = s[:7]
	}
	return s
}
