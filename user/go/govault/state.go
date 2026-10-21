// state.go — M156c (#2933): the M125a save_state blob GOVAULT lacked (the
// M151c audit names the gap). The blob carries the open vault's path and
// nothing else — never a passphrase, a derived key, an entry, or a revealed
// secret. A restored vault therefore restarts exactly where a fresh boot
// would: load() reads the path, finds the file, and lands on the LOCKED
// face. State is a convenience for which file to open, never a session
// resumption.
//
// The wire is deliberately minimal: the blob IS the path bytes, tagged by
// the Config.StateVersion envelope. decodeState refuses anything that is
// not a sane share path so a hand-edited SESSION.TABS row cannot steer the
// app at a hostile file — the codec answers the same refusal a bad picker
// path would.
package main

import "strings"

// stateVersion is the appver tag this blob's format stands at.
const stateVersion = 1

// encodeState serializes the blob. The path is all there is; a nil blob
// would be the honest "no state" answer, but the app always has a path —
// the locked vault's location is the only thing a restore needs to know.
func encodeState(path string) []byte {
	if path == "" {
		return nil
	}
	return []byte(path)
}

// decodeState is the restore half: accept only an absolute share path of
// share-contract shape (the same rules filepicker's resolve enforces —
// rooted under /host, no empty or dot segments, no control bytes, inside
// the 64-byte bound). Anything else is refused: ok=false means "start
// clean at the default path", never an error worth a face.
func decodeState(b []byte) (string, bool) {
	path := string(b)
	if !strings.HasPrefix(path, "/host/") || len(path) > 64 {
		return "", false
	}
	for _, part := range strings.Split(path[6:], "/") {
		if part == "" || part == "." || part == ".." {
			return "", false
		}
	}
	for i := 0; i < len(path); i++ {
		if path[i] < 0x20 || path[i] == 0x7f {
			return "", false
		}
	}
	return path, true
}
