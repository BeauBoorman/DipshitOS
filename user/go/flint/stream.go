package main

import (
	"encoding/json"
	"sort"
	"strings"
)

func ptrEqual(a, b *string) bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	return *a == *b
}

func copyStrPtr(p *string) *string {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}

// ReadStreamChanges reads and parses streams/<id>.jsonl via M103b's
// torn-aware ReadJSONLLines.
func ReadStreamChanges(fs FS, root, streamID string) ([]Change, error) {
	p := streamLogPath(root, streamID)
	if !fs.Exists(p) {
		return nil, nil
	}
	b, err := fs.ReadFile(p, MaxFileReadBytes)
	if err != nil {
		return nil, err
	}
	lines, err := ReadJSONLLines(b)
	if err != nil {
		return nil, err
	}
	if len(lines) > MaxChanges {
		return nil, refuse("store_too_large", "changes")
	}
	changes := make([]Change, 0, len(lines))
	for _, line := range lines {
		c, err := ParseChange(line)
		if err != nil {
			return nil, err
		}
		changes = append(changes, c)
	}
	return changes, nil
}

// WriteStreamRecord writes streams/<id>.json crash-safely via WriteJSONSafe.
func WriteStreamRecord(fs FS, root string, st *Stream) error {
	return WriteJSONSafe(fs, streamRecordPath(root, st.ID), st)
}

// LoadStream reads the Stream record and its Change log, rolling a stale
// record head forward when the log's last Change has `parent == record.head`
// (ADR 0049 §Store).
func LoadStream(fs FS, root, streamID string) (*Stream, []Change, error) {
	recPath := streamRecordPath(root, streamID)
	if !fs.Exists(recPath) {
		return nil, nil, refuse("stream_missing", streamID)
	}
	b, err := fs.ReadFile(recPath, MaxFileReadBytes)
	if err != nil {
		return nil, nil, err
	}
	var st Stream
	if err := json.Unmarshal(b, &st); err != nil || st.ID == "" || st.Name == "" {
		return nil, nil, refuse("stream_malformed", streamID)
	}
	changes, err := ReadStreamChanges(fs, root, streamID)
	if err != nil {
		return nil, nil, err
	}
	if len(changes) > 0 {
		last := changes[len(changes)-1]
		if ptrEqual(last.Parent, st.Head) && (st.Head == nil || *st.Head != last.ID) {
			head := last.ID
			st.Head = &head
			if err := WriteStreamRecord(fs, root, &st); err != nil {
				return nil, nil, err
			}
		}
	}
	return &st, changes, nil
}

// CheckStaleHead re-reads the Stream record (rolling forward if the log moved)
// and refuses with `stale_head` if the head no longer equals expectedHead.
func CheckStaleHead(fs FS, root, streamID string, expectedHead *string) (*Stream, error) {
	st, _, err := LoadStream(fs, root, streamID)
	if err != nil {
		return nil, err
	}
	if !ptrEqual(st.Head, expectedHead) {
		return nil, refuse("stale_head", "")
	}
	return st, nil
}

// AppendStreamChange executes steps (1) and (2) of ADR 0049's commit order:
// re-read the Stream record to check `stale_head`, append the Change JSON line
// with FileSync, and rewrite the Stream record with the new head.
func AppendStreamChange(fs FS, root, streamID string, expectedHead *string, c Change) (*Stream, error) {
	st, err := CheckStaleHead(fs, root, streamID, expectedHead)
	if err != nil {
		return nil, err
	}
	line, err := MarshalChangeLine(c)
	if err != nil {
		return nil, err
	}
	if err := fs.AppendSync(streamLogPath(root, streamID), line); err != nil {
		return nil, err
	}
	head := c.ID
	st.Head = &head
	if err := WriteStreamRecord(fs, root, st); err != nil {
		return nil, err
	}
	return st, nil
}

// LoadAllStreamChanges scans all streams in deterministic ID order, rolling
// any stale records forward and returning all Changes across the store.
func LoadAllStreamChanges(fs FS, root string, idx *StoreIndex) ([]Change, error) {
	ids := make([]string, 0, len(idx.StreamsByID))
	for id := range idx.StreamsByID {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	seenLog := make(map[string]bool, len(ids))
	var all []Change
	for _, id := range ids {
		st, changes, err := LoadStream(fs, root, id)
		if err != nil {
			return nil, err
		}
		idx.StreamsByID[st.ID] = st
		idx.StreamsByName[st.Name] = st
		seenLog[id+".jsonl"] = true
		all = append(all, changes...)
	}

	// Also inspect any orphan .jsonl files in streams/ so malformed logs are caught.
	sDir := streamsDir(root)
	if fs.Exists(sDir) {
		entries, err := fs.List(sDir)
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			if e.IsDir || !strings.HasSuffix(e.Name, ".jsonl") || seenLog[e.Name] {
				continue
			}
			sid := strings.TrimSuffix(e.Name, ".jsonl")
			changes, err := ReadStreamChanges(fs, root, sid)
			if err != nil {
				return nil, err
			}
			all = append(all, changes...)
		}
	}
	if len(all) > MaxChanges {
		return nil, refuse("store_too_large", "changes")
	}
	return all, nil
}
