package main

import (
	"bytes"
	"encoding/json"
	"sort"
	"strings"

	"virelai/vi"
)

// MaxTags bounds TAGS.jsonl at the store root.
const MaxTags = 1024

// Tag is a stored tag record: an atom-shaped row (kind="tag") in
// TAGS.jsonl at the store root, naming a Change on a Stream (M138c
// #2777). Tags are unsigned local metadata — signed tags are out of
// scope — but they travel the store's existing JSONL + WriteFileSafe
// path, so a tag survives reboots the way atoms do.
type Tag struct {
	ID     string `json:"id"`
	Kind   string `json:"kind"` // always "tag"
	Name   string `json:"name"`
	Change string `json:"change"`
	Stream string `json:"stream"`
	TS     int64  `json:"ts"`
}

func tagsPath(root string) string { return root + "/TAGS.jsonl" }

// LoadTags reads TAGS.jsonl; an absent file means no tags.
func LoadTags(fs FS, root string) ([]Tag, error) {
	p := tagsPath(root)
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
	if len(lines) > MaxTags {
		return nil, refuse("store_too_large", "tags")
	}
	tags := make([]Tag, 0, len(lines))
	for _, line := range lines {
		var t Tag
		if err := json.Unmarshal(line, &t); err != nil || t.Kind != "tag" || t.Name == "" || t.Change == "" || t.Stream == "" {
			return nil, refuse("tag_malformed", "")
		}
		tags = append(tags, t)
	}
	return tags, nil
}

// WriteTags writes TAGS.jsonl deterministically (name-sorted) via WriteFileSafe.
func WriteTags(fs FS, root string, tags []Tag) error {
	if len(tags) > MaxTags {
		return refuse("store_too_large", "tags")
	}
	sorted := make([]Tag, len(tags))
	copy(sorted, tags)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].Name != sorted[j].Name {
			return sorted[i].Name < sorted[j].Name
		}
		return sorted[i].ID < sorted[j].ID
	})
	var buf bytes.Buffer
	for _, t := range sorted {
		line, err := json.Marshal(t)
		if err != nil {
			return err
		}
		buf.Write(line)
		buf.WriteByte('\n')
	}
	return fs.WriteFileSafe(tagsPath(root), buf.Bytes())
}

// validTagName: 1..64 chars of [a-zA-Z0-9._-], not starting with '-' or '.'
// (a leading dash would collide with -l/-d; a leading dot is a hidden name).
func validTagName(name string) bool {
	if len(name) < 1 || len(name) > 64 || name[0] == '-' || name[0] == '.' {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// cmdTag implements `flint tag [--ws=<name>] NAME [CHANGE]`,
// `flint tag [-l]`, and `flint tag -d NAME` (M138c #2777). With no CHANGE
// the tag names the resolved workspace's stream head.
func cmdTag(fs FS, root string, uuidGen *UUIDGen, args []string) error {
	var wsFlag, name, changeArg string
	list, del := false, false
	for _, a := range args {
		switch {
		case a == "-l":
			list = true
		case a == "-d":
			del = true
		case strings.HasPrefix(a, "--ws="):
			wsFlag = a[len("--ws="):]
		case strings.HasPrefix(a, "-"):
			return refuse("usage", "")
		default:
			switch {
			case name == "":
				name = a
			case changeArg == "":
				changeArg = a
			default:
				return refuse("usage", "")
			}
		}
	}
	if (list && del) || (del && (name == "" || changeArg != "")) ||
		(list && (name != "" || changeArg != "")) {
		return refuse("usage", "")
	}

	idx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return err
	}
	tags, err := LoadTags(fs, root)
	if err != nil {
		return err
	}

	switch {
	case del:
		var kept []Tag
		found := false
		for _, t := range tags {
			if t.Name == name {
				found = true
				continue
			}
			kept = append(kept, t)
		}
		if !found {
			return refuse("tag_missing", name)
		}
		if err := WriteTags(fs, root, kept); err != nil {
			return err
		}
		consoleFn("flint: tag rm " + name)
		return nil
	case name == "":
		for _, t := range tags {
			streamName := t.Stream
			if st, ok := idx.StreamsByID[t.Stream]; ok {
				streamName = st.Name
			}
			consoleFn("flint: tag " + t.Name + " " + t.Change + " " + streamName)
		}
		consoleFn("flint: tags " + vi.Itoa64(int64(len(tags))))
		return nil
	}

	// Create: name validity, uniqueness, target resolution.
	if !validTagName(name) {
		return refuse("usage", "")
	}
	for _, t := range tags {
		if t.Name == name {
			return refuse("tag_exists", name)
		}
	}

	var target, streamID string
	if changeArg != "" {
		all, err := LoadAllStreamChanges(fs, root, idx)
		if err != nil {
			return err
		}
		for _, c := range all {
			if c.ID == changeArg {
				target = c.ID
				streamID = c.Stream
				break
			}
		}
		if target == "" {
			return refuse("change_missing", changeArg)
		}
	} else {
		ws, err := resolveWorkspace(fs, idx, wsFlag, nil)
		if err != nil {
			return err
		}
		st, _, err := LoadStream(fs, root, ws.Stream)
		if err != nil {
			return err
		}
		if st.Head == nil || *st.Head == "" {
			return refuse("change_missing", "")
		}
		target = *st.Head
		streamID = st.ID
	}

	ts, err := uuidGen.NowMs()
	if err != nil {
		return err
	}
	id, err := uuidGen.New()
	if err != nil {
		return err
	}
	tags = append(tags, Tag{ID: id, Kind: "tag", Name: name, Change: target, Stream: streamID, TS: ts})
	if err := WriteTags(fs, root, tags); err != nil {
		return err
	}
	consoleFn("flint: tag ok " + name + " " + target)
	return nil
}
