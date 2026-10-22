//go:build virelai

// Command rss is the VirelaiOS terminal RSS/Atom reader.
//
// It is a Bubble Tea program in the shape M72c proved on this guest: the Virelai
// port has no POSIX tty and no signals, so this app owns its loop — open a tab
// window (tabapp), bind /dev/tty, attach it to the window, decode the tty byte
// stream into tea key messages, paint View() back into the tty, and service the
// window lifecycle from the event queue.
//
// Persistence lives in the host share the guest sees as /host:
//
//	/host/RSS.OPML   subscriptions (OPML 2.0)
//	/host/RSS.STATE  read/unread state and last feed
//	/host/RSS.CACHE  bounded last-known article cache
//
// Every write goes through the store's vi.WriteFileSafe path, so a killed
// process cannot leave a half-written file behind.
package main

import (
	"errors"

	"virelai/rss/app"
	"virelai/rss/feed"
	"virelai/rss/store"
	"virelai/rss/ui"
	"virelai/tabapp"
	"virelai/vi"
)

const (
	appName  = "RSS.ELF"
	appTitle = "RSS Reader"
	natW     = 900
	natH     = 600

	ttyPath = "/dev/tty"

	// Native window size -> nominal text grid (the kernel paints the tty grid
	// into the bound window; these are layout hints only).
	cellW = 8
	cellH = 16

	markerOpen    = "rss: open id="
	markerAttach  = "rss: attached"
	markerStorage = "rss: storage "
	markerLoaded  = "rss: loaded feeds="
	markerCache   = "rss: cache entries="
	markerPainted = "rss: painted"
	markerReady   = "rss: ready"
	markerFetch   = "rss: fetch "
	markerGot     = "rss: got "
	markerSaved   = "rss: saved "
	markerError   = "rss: error "
	markerKey     = "rss: key"
	markerRepaint = "rss: repainted"
	markerClose   = "rss: close"
	markerOK      = "rss OK"
)

// Wait durations in nanoseconds (ADR 0060 audit): settles use the deadline
// overlay (vi.SleepNs, slot 94) instead of guessed scheduler ticks.
const (
	ms = 1_000_000

	// presentSettleNs yields after a paint so the barrier markers only
	// describe an already-presented frame.
	presentSettleNs = 200 * ms
	// keyRepaintSettleNs is the settle between a key-driven repaint and the
	// `rss: key`/`repainted` markers.
	keyRepaintSettleNs = 100 * ms
)

// viFileIO is the production store.FileIO: every write is atomic.
type viFileIO struct{}

func (viFileIO) Read(path string) ([]byte, error) {
	b, rc := vi.ReadFileAll(path, vi.MaxFileBytes)
	if rc < 0 {
		return nil, store.ErrNoFile
	}
	return b, nil
}

func (viFileIO) Write(path string, b []byte) error {
	if rc := vi.WriteFileSafe(path, b); rc < 0 {
		return errors.New("write failed: " + path + " rc=" + vi.Itoa64(rc))
	}
	return nil
}

func (viFileIO) Delete(path string) error {
	_ = vi.FileDelete(path)
	return nil
}

func main() {
	ta := tabapp.Init(tabapp.Config{
		Name:  appName,
		Title: appTitle,
		X:     48,
		Y:     40,
		W:     natW,
		H:     natH,
	})
	if ta == nil {
		vi.ConsoleLine("rss: open failed")
		vi.Exit(1)
	}
	vi.ConsoleLine(markerOpen + vi.Itoa64(int64(ta.Win)))

	h, rc := vi.FileOpen(ttyPath, vi.ModeRead|vi.ModeWrite)
	if rc < 0 {
		vi.ConsoleLine("rss: no /dev/tty")
		ta.CloseAndExit(2)
	}
	fd := uint32(h)
	if vi.TtyAttachWindow(ta.Win) != 0 {
		vi.FileClose(fd)
		vi.ConsoleLine("rss: attach failed")
		ta.CloseAndExit(3)
	}
	vi.ConsoleLine(markerAttach)

	vi.FileWrite(fd, []byte("\x1b[?1049h\x1b[?25l"))

	st := store.New(viFileIO{}, store.DefaultDir)
	subsPath, statePath, _ := st.Paths()
	vi.ConsoleLine(markerStorage + subsPath)
	_ = statePath

	m := ui.New(int(ta.W/cellW), int(ta.H/cellH))

	// Load persisted state; a missing file is the ordinary first-run case.
	if subs, err := st.LoadSubs(); err == nil {
		m.A.Subs = subs
	} else {
		vi.ConsoleLine("rss: no subscriptions yet (" + store.SubsFile + ")")
	}
	cache, _ := st.LoadCache()
	if stt, err := st.LoadState(); err == nil {
		m.A.Read = stt.Read
		if url := app.CacheKey(stt.LastFeed, m.A.Subs); url != "" {
			arts := cache[url]
			m.A.RestoreFeed(url, m.A.Subs, arts)
			if len(arts) > 0 {
				vi.ConsoleLine(markerCache + vi.Itoa64(int64(len(arts))) + " first=" + arts[0].Title)
			}
		}
	}
	vi.ConsoleLine(markerLoaded + vi.Itoa64(int64(len(m.A.Subs))))

	if !paint(fd, m) {
		shutdown(ta, fd, 4)
	}
	vi.SleepNs(presentSettleNs)
	vi.ConsoleLine(markerPainted)
	vi.ConsoleLine(markerReady)

	var in [256]byte
	for {
		n, _ := vi.FileRead(fd, in[:])
		if n > 0 {
			for _, msg := range ui.KeyMessages(in[:n]) {
				next, _ := m.Update(msg)
				m = next.(ui.Model)
				quit := discharge(&m, st, cache)
				if !paint(fd, m) {
					shutdown(ta, fd, 4)
				}
				vi.SleepNs(keyRepaintSettleNs)
				vi.ConsoleLine(markerKey)
				vi.ConsoleLine(markerRepaint)
				if quit {
					shutdown(ta, fd, 0)
				}
			}
		}

		ev, result, ok := vi.PollEventRaw()
		if !ok {
			if result < 0 {
				shutdown(ta, fd, 5)
			}
			if n <= 0 {
				vi.Sleep(1)
			}
			continue
		}
		switch ta.Dispatch(ev) {
		case tabapp.ActionClosed:
			shutdown(ta, fd, 0)
		case tabapp.ActionResized:
			m.A.Width = int(ta.W / cellW)
			m.A.Height = int(ta.H / cellH)
			if !paint(fd, m) {
				shutdown(ta, fd, 4)
			}
		}
	}
}

// discharge performs the IO the pure state machine asked for and reports
// whether the user quit.
func discharge(m *ui.Model, st *store.Store, cache store.Cache) bool {
	ef := m.Pending
	m.Reset()

	if ef.Reload {
		if subs, err := st.LoadSubs(); err == nil {
			m.A.Subs = subs
			m.A.SetStatus("Reloaded " + store.SubsFile)
		}
	}
	if ef.SaveSubs {
		if err := st.SaveSubs(m.A.Subs); err == nil {
			vi.ConsoleLine(markerSaved + store.SubsFile + " n=" + vi.Itoa64(int64(len(m.A.Subs))))
		} else {
			m.A.SetError(describe(err))
		}
	}
	if ef.FetchURL != "" {
		doFetch(m, st, cache, ef.FetchURL)
	}
	if ef.SaveState {
		last := m.A.FeedURL
		if last == "" {
			last = m.A.FeedTitle
		}
		stt := store.State{Read: m.A.Read, LastFeed: last}
		if err := st.SaveState(stt); err != nil {
			m.A.SetError(describe(err))
		} else {
			vi.ConsoleLine(markerSaved + store.StateFile)
		}
	}
	if ef.OpenLink != "" {
		// vi.Exec keeps 31 bytes of each argument, which is shorter than an
		// article URL. The full link is the file; WEB.ELF reads @path.
		// The console line is the full URL either way.
		vi.ConsoleLine("rss: open " + ef.OpenLink)
		path, body, arg, ok := browserHandoff(ef.OpenLink)
		if !ok {
			m.A.SetError("Link is empty")
		} else if rc := vi.WriteFileSafe(path, body); rc < 0 {
			m.A.SetError("Could not hand the link to the browser")
		} else {
			_, _ = vi.Exec("WEB.ELF", arg)
		}
	}
	return ef.Quit
}

func doFetch(m *ui.Model, st *store.Store, cache store.Cache, url string) {
	vi.ConsoleLine(markerFetch + url)
	f, raw, err := feed.Fetch(url)
	if err != nil {
		vi.ConsoleLine(markerError + err.Error())
		m.A.SetError(describe(err))
		return
	}
	title := f.Title
	if title == "" {
		title = url
	}
	vi.ConsoleLine(markerGot + vi.Itoa64(int64(len(raw))) + "B entries=" + vi.Itoa64(int64(len(f.Articles))))
	m.A.SetArticles(url, title, f.Articles)
	m.A.SetStatus("Loaded " + vi.Itoa64(int64(len(f.Articles))) + " entries")
	cache[url] = f.Articles
	if err := st.SaveCache(cache); err != nil {
		vi.ConsoleLine(markerError + err.Error())
	}
}

// describe turns a fetch failure into one legible TUI line. Every failure class
// the brief names has its own text; none of them is a bare "error".
func describe(err error) string {
	switch {
	case errors.Is(err, feed.ErrNotFeed):
		return "Not an RSS or Atom document"
	case errors.Is(err, feed.ErrMalformed):
		return "Malformed XML"
	case errors.Is(err, feed.ErrEmpty):
		return "Empty response body"
	case errors.Is(err, feed.ErrTLS):
		return "TLS verification failed (guest trust store)"
	}
	var he feed.HTTPError
	if errors.As(err, &he) {
		return "HTTP " + vi.Itoa64(int64(he.Status))
	}
	if errors.Is(err, feed.ErrNetwork) {
		return "Network or DNS failure"
	}
	return err.Error()
}

func paint(fd uint32, m ui.Model) bool {
	v := m.View()
	n, rc := vi.FileWrite(fd, []byte(v.Content))
	return rc >= 0 && n == len(v.Content)
}

func shutdown(ta *tabapp.TabApp, fd uint32, status int) {
	_, _ = vi.FileWrite(fd, []byte("\x1b[?1049l\x1b[?25h"))
	_ = vi.TtyAttach(vi.TtyDetach)
	vi.FileClose(fd)
	vi.ConsoleLine(markerClose)
	vi.ConsoleLine(markerOK)
	ta.CloseAndExit(status)
}
