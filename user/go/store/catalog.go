package main

import (
	"strings"
)

// The catalog (ADR 0055 D3/D5) is a fold over signed release manifests:
// the wire `list` enumerates the remote's streams, and each release
// stream's head release.go is fetched off the untrusted channel,
// re-authenticated atom-for-atom against the signed folded set, and read
// out. The publisher fingerprint is DERIVED — the author key of the
// stream's head Change — labeled from TRUSTED.TXT; no const may claim
// identity.

// catalogEntry is one release stream's catalog card: the validated
// manifest consts plus the derived publisher fingerprint.
type catalogEntry struct {
	Stream string   // remote stream name (the channel's <stream>/ dir)
	Head   string   // local record head the manifest folded at
	Rel    *release // the authenticated consts
	// Publisher is the head Change's author key, 64 lowercase hex —
	// derived from the signature chain, never declared by the manifest.
	Publisher string
	// PubState is the keyring verdict: "trusted", "revoked", "unknown",
	// or "unverified" (no readable keyring). PubLabel is the TRUSTED.TXT
	// name= row, set only when PubState is "trusted".
	PubState string
	PubLabel string
}

// loadCatalogEntry folds rec's verified head into a catalog entry: the
// signed release.go atom set comes off the local replica, then the
// channel's copy is verified atom-for-atom and parsed. A stream whose
// head carries no release manifest returns (nil, nil); a missing,
// tampered, or out-of-grammar manifest returns the named refusal — the
// caller decides whether it is per-stream trivia (ls) or fatal (info).
func loadCatalogEntry(fs FS, root string, ch channel, rec *Stream, kr *keyring) (*catalogEntry, error) {
	logBytes, err := streamLogBytes(fs, root, rec.ID)
	if err != nil {
		return nil, err
	}
	signed, author, err := headReleaseOps(logBytes, rec.Head)
	if err != nil {
		return nil, err
	}
	if len(signed) == 0 {
		return nil, nil
	}
	src, err := ch.fetch(rec.Name+"/"+releaseFile, MaxReleaseBytes)
	if err != nil {
		return nil, err
	}
	if err := verifyRelease(src, signed); err != nil {
		return nil, err
	}
	rel, err := parseRelease(src)
	if err != nil {
		return nil, err
	}
	e := &catalogEntry{Stream: rec.Name, Rel: rel, Publisher: author}
	if rec.Head != nil {
		e.Head = *rec.Head
	}
	if kr == nil {
		e.PubState = "unverified"
	} else {
		e.PubState, e.PubLabel = kr.publisherState(author)
	}
	return e, nil
}

// matches applies the `store ls` filters: --category is an exact match
// on the closed vocabulary word, --search is a case-insensitive
// substring over the stream name and the manifest's display fields.
func (e *catalogEntry) matches(search, category string) bool {
	if category != "" && e.Rel.Category != category {
		return false
	}
	if search == "" {
		return true
	}
	needle := strings.ToLower(search)
	for _, hay := range []string{
		e.Stream, e.Rel.Name, e.Rel.Summary, e.Rel.Description, e.Rel.Category,
	} {
		if strings.Contains(strings.ToLower(hay), needle) {
			return true
		}
	}
	return false
}

// line renders the one-line catalog row printed after
// `store: stream <name> release` — summary last because it may hold
// spaces; "-" marks a const the publisher did not declare.
func (e *catalogEntry) line() string {
	return "name=" + e.Rel.Name +
		" version=" + e.Rel.Version +
		" category=" + orDash(e.Rel.Category) +
		" sha256=" + e.Rel.ELFSHA256 +
		" publisher=" + e.Publisher +
		" publisher_name=" + orDash(e.PubLabel) +
		" publisher_state=" + e.PubState +
		" summary=" + orDash(e.Rel.Summary)
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// refuseCodeOf extracts a refusal's code for the per-stream
// release-invalid marker; a non-refusal error renders "error".
func refuseCodeOf(err error) string {
	if re, ok := err.(*RefuseError); ok {
		return re.Code
	}
	return "error"
}
