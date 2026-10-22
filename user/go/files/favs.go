// M167b (issue #2992): pinned places — the `b` toggle, the `f`
// pseudo-listing, and the /host/FILES.FAV store (owner decision D9).
//
// `b` pins the cursor's directory — the selected dir row itself, or the
// cwd on a file row or an empty listing — and unpins it when it is
// already pinned (on a favorites row it unpins that pin). `f` lists the
// pins like the volumes root: Enter or `l` opens a live pin, a pin whose
// directory is gone shows a "missing" row and opens nothing.
//
// The store is one absolute path per line, read once at start and
// published with vi.WriteFileSafe on each change: a missing file means
// no pins, malformed lines are skipped and counted on the load marker,
// and a failed write raises the shared error banner while the in-memory
// list stands. The model stays pure — every syscall sits behind the
// host-stubbed seams (favRead/favWrite/favDirProbe).
package main

import (
	"strings"

	"virelai/vi"
)

const (
	// favsView is the pseudo path m.path holds while the favorites
	// listing stands — parenthesized so neither joinPath nor an argv
	// entry can ever spell a real directory this way.
	favsView = "(favorites)"
	// favStore is the pin file's share path (D9): one absolute path
	// per line.
	favStore = "/host/FILES.FAV"
	// favMax is the pin bound — the goemoji shelfMax precedent: a full
	// shelf refuses by name rather than evicting, because the pin order
	// is the user's, not the app's to rewrite.
	favMax = 16
	// favStoreMax bounds the store read: favMax capped paths plus their
	// newlines, with headroom so an over-long file still parses its own
	// bound.
	favStoreMax = favMax*(maxPath+1) + 256
	// favMissFlag marks a pin row whose directory no longer lists — the
	// Reserved byte the mount-table rows carry their state on.
	favMissFlag = 1
)

var (
	// favRead/favWrite are the store's seams — vi.ReadFileAll /
	// vi.WriteFileSafe on the guest, stubbed by the host tests (the
	// readAppsFile pattern: one seam, fixtures without a guest).
	favRead  = vi.ReadFileAll
	favWrite = vi.WriteFileSafe
	// favDirProbe is the missing check — the same DirList rc probe
	// stateDirProbe defaults to, kept a separate variable so a test can
	// stub one without the other.
	favDirProbe = stateDirProbe
)

// favIndex finds path in the pin list (-1 when absent).
func favIndex(favs []string, path string) int {
	for i, p := range favs {
		if p == path {
			return i
		}
	}
	return -1
}

// validFav is the store's line rule: an absolute path within the kernel
// cap — never the volumes root (a mount table is not a pinnable place)
// and never a trailing-slash spelling this app does not produce.
func validFav(p string) bool {
	return len(p) > 1 && len(p) <= maxPath && p[0] == '/' &&
		!strings.HasSuffix(p, "/")
}

// parseFavs decodes the store's body: blank lines are ignored; every
// other line that is not a fresh valid pin — malformed, a duplicate, or
// past the pin bound — is skipped and counted in bad.
func parseFavs(text string) (favs []string, bad int) {
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if line == "" {
			continue
		}
		if !validFav(line) || favIndex(favs, line) >= 0 || len(favs) >= favMax {
			bad++
			continue
		}
		favs = append(favs, line)
	}
	return favs, bad
}

// loadFavs reads the store once at start. A missing file is an empty
// pin list — named `absent` on the marker, not counted malformed.
func (m *model) loadFavs() {
	body, rc := favRead(favStore, favStoreMax)
	if rc < 0 {
		m.emit(markerFavsLoad + "n=0 absent")
		return
	}
	favs, bad := parseFavs(string(body))
	m.favs = favs
	m.emit(markerFavsLoad + "n=" + vi.Itoa64(int64(len(favs))) +
		" bad=" + vi.Itoa64(int64(bad)))
}

// saveFavs publishes the pin list through WriteFileSafe — one absolute
// path per line. A failed write raises the shared error banner and the
// in-memory list STAYS: the user sees the pins they set, and the next
// change republishes the whole list.
func (m *model) saveFavs() {
	var b strings.Builder
	for _, p := range m.favs {
		b.WriteString(p)
		b.WriteByte('\n')
	}
	if rc := favWrite(favStore, []byte(b.String())); rc < 0 {
		m.bannerOp = ""
		m.raiseBanner("favorites write failed rc=" + vi.Itoa64(rc))
		m.status = "favorites: write failed"
	}
}

// favMissing reports whether a favorites row's pin target no longer lists.
func (m model) favMissing(e vi.DirEntry) bool {
	return e.Reserved[0] == favMissFlag
}

// toggleFav is the `b` chord. On the favorites rows it unpins the
// selected pin — the toggle reads the same there — and on the volumes
// root it refuses by name: a mount table is browse-only, not a place.
func (m *model) toggleFav() {
	if m.tar != nil {
		m.tarReadOnly("pin")
		return
	}
	switch m.path {
	case volsPath:
		m.emit(markerFavNo + volsPath + " volumes")
		m.status = "fav: volumes are browse-only"
		return
	case favsView:
		if m.sel < 0 || m.sel >= len(m.favs) {
			m.status = "fav: nothing selected"
			return
		}
		m.dropFav(m.favs[m.sel])
		m.refresh()
		return
	}
	target := m.path
	if e, ok := m.selEntry(); ok && e.Dir() {
		child, ok := joinPath(m.path, e.NameString())
		if !ok {
			m.emit(markerFavNo + e.NameString() + " path")
			m.status = "fav: path too long"
			return
		}
		target = child
	}
	if favIndex(m.favs, target) >= 0 {
		m.dropFav(target)
		return
	}
	if !validFav(target) {
		m.emit(markerFavNo + target + " path")
		m.status = "fav: not pinnable"
		return
	}
	if len(m.favs) >= favMax {
		m.emit(markerFavNo + target + " full")
		m.status = "fav: pins full"
		return
	}
	m.favs = append(m.favs, target)
	m.emit(markerFavAdd + target + " n=" + vi.Itoa64(int64(len(m.favs))))
	m.status = "pinned " + target
	m.saveFavs()
}

// dropFav removes path from the pin list and republishes — the toggle's
// unpin arm, and `b` on a favorites row (the honest way to drop a gone
// pin too).
func (m *model) dropFav(path string) {
	i := favIndex(m.favs, path)
	if i < 0 {
		return
	}
	m.favs = append(m.favs[:i:i], m.favs[i+1:]...)
	m.emit(markerFavDel + path + " n=" + vi.Itoa64(int64(len(m.favs))))
	m.status = "unpinned " + path
	m.saveFavs()
}

// showFavs is the `f` chord: the pins as a pseudo-listing in the volumes
// root's shape — or, when it already stands, a re-probe so a folder that
// came or went re-marks its row.
func (m *model) showFavs() {
	if m.path == favsView {
		m.refresh()
		return
	}
	m.tar = nil
	m.tarSub = ""
	m.tarRows = nil
	m.path = favsView
	m.sel = 0
	m.emit(markerCd + favsView)
	m.refresh()
}

// refreshFavs lists the pins in the user's order (never sorted — row i
// is favs[i]), probing each for "missing". A gone pin stays shown: the
// row says missing and opens nothing — a pin is the user's to drop, not
// the app's to lose.
func (m *model) refreshFavs() {
	m.n = 0
	missing := 0
	for _, p := range m.favs {
		if m.n == len(m.entries) {
			break
		}
		var e vi.DirEntry
		copy(e.Name[:], baseName(p))
		e.IsDir = 1
		if favDirProbe(p) < 0 {
			e.Reserved[0] = favMissFlag
			missing++
		}
		m.entries[m.n] = e
		m.n++
	}
	m.clampSel()
	// The feed never watches the pseudo-listing — the same adopted-empty
	// baseline the volumes root takes, so the next real listing's first
	// poll is primed, not diffed against this.
	m.watcher.Adopt(vi.DirSnapshot{OK: false})
	m.emit(markerFavs + "n=" + vi.Itoa64(int64(m.n)) +
		" missing=" + vi.Itoa64(int64(missing)))
	for i := 0; i < m.n; i++ {
		e := m.entries[i]
		kind := "dir"
		line := markerFav + m.favs[i]
		if m.favMissing(e) {
			kind = "missing"
			line += " missing"
		}
		m.emit(markerEntry + e.NameString() + " " + kind)
		m.emit(line)
	}
	m.status = "favs"
	if m.view == viewGrid {
		m.gridSync()
	}
	m.loadPreview()
}

// enterFav opens the selected pin: a live pin's directory by the same
// cd/refresh a listed dir takes, a gone pin's refusal by name.
func (m *model) enterFav(e vi.DirEntry) {
	if m.sel < 0 || m.sel >= len(m.favs) {
		return
	}
	p := m.favs[m.sel]
	if m.favMissing(e) {
		m.emit(markerFavNo + p + " missing")
		m.status = "fav: gone — b unpins"
		return
	}
	m.path = p
	m.sel = 0
	m.emit(markerCd + m.path)
	m.refresh()
}
