// M149b (issue #2807): the click-to-open dispatch and the term-profile
// line command — the parts of OSC-8/profile handling that touch syscalls.
// The pure halves (mirror, filters, parsers) live in links.go/profiles.go.
package main

import (
	"virelai/mime"
	"virelai/shlib"
	"virelai/tabapp"
	"virelai/vi"
)

const (
	markerLinkOpen       = "goterm: link open "
	markerLinkRefused    = "goterm: link refused "
	markerProfile        = "goterm: profile "
	markerProfileRefused = "goterm: profile refused "
	mouseEnable          = "\x1b[?1000h\x1b[?1006h"

	// webArgBytes/webArgSlots mirror shlib's openTargetArgs contract for
	// WEB.ELF argv (kernel 255-byte slots, eight argv slots minus argv[0]).
	webArgBytes = 255
	webArgSlots = 7
)

// openLink runs the card's dispatch for one clicked URI: mime.Open owns
// the decision — HTTPS routes to WEB.ELF at the table; HTTP is refused by
// name THERE (mime's table covers https only), but the URI is still a
// WEB.ELF target the browser itself accepts (argv cleartext fetch), so
// the OSC-8 layer completes the card's "http and https" with the same
// handler rather than lying that http has no opener. Any other scheme is
// refused BY NAME — the marker and the tty notice carry it.
func openLink(ts *termState, ta *tabapp.TabApp, fd uint32, editor *shlib.Editor, hst *termHost, uri string) {
	scheme := linkURIScheme(uri)
	req, err := mime.Open(uri, "/", hst.ReadFile)
	if err != nil {
		// A concrete assertion, not errors.As: reflect-based unwrapping
		// would drag the reflect package into this already-tight ELF.
		if oe, ok := err.(*mime.OpenError); ok && oe.Kind == mime.OpenUnsupportedScheme && oe.Scheme == "http" {
			req = mime.OpenRequest{
				Handler: mime.Handler{Bin: "WEB.ELF", Label: "Web Browser"},
				Target:  uri,
				Type:    mime.Unknown,
				Scheme:  "http",
			}
		} else {
			name := scheme
			if oe, ok := err.(*mime.OpenError); ok && oe.Scheme != "" {
				name = oe.Scheme
			}
			vi.ConsoleLine(markerLinkRefused + "scheme=" + name + " target=" + uri)
			linkNotice(ts, fd, editor, "goterm: link refused: "+err.Error())
			return
		}
	}
	args, ok := webArgv(req.Target)
	if !ok {
		vi.ConsoleLine(markerLinkRefused + "target too long " + req.Target)
		linkNotice(ts, fd, editor, "goterm: link refused: target too long")
		return
	}
	pid, err := vi.Exec(req.Handler.Bin, args...)
	if err != nil {
		vi.ConsoleLine(markerLinkRefused + "handler=" + req.Handler.Bin + " unavailable")
		linkNotice(ts, fd, editor, "goterm: link refused: "+req.Handler.Bin+" unavailable")
		return
	}
	vi.ConsoleLine(markerLinkOpen + "scheme=" + req.Scheme +
		" target=" + req.Target + " handler=" + req.Handler.Bin +
		" pid=" + vi.Itoa64(pid))
}

// webArgv preserves the complete target inside WEB.ELF's argv limits the
// same way shlib's `open` builtin does: the URL splits across argv slots
// and WEB.ELF concatenates them.
func webArgv(target string) ([]string, bool) {
	n := (len(target) + webArgBytes - 1) / webArgBytes
	if n == 0 || n > webArgSlots {
		return nil, false
	}
	args := make([]string, 0, n)
	for start := 0; start < len(target); start += webArgBytes {
		end := start + webArgBytes
		if end > len(target) {
			end = len(target)
		}
		args = append(args, target[start:end])
	}
	return args, true
}

// linkNotice reports a refused open INSIDE the terminal — the same shape
// the shell's error text has (newline, line, then the editor's repaint).
func linkNotice(ts *termState, fd uint32, editor *shlib.Editor, msg string) {
	writeTTY(ts, fd, []byte("\r\n"+msg+"\r\n"))
	writeTTY(ts, fd, editor.Repaint())
}

// rowsVisible mirrors the kernel's rows_visible for THIS window: client
// height under the title band divided by the active cell rung. Click
// resolution needs it to map a reported visible row into the mirror's
// unified line space.
func rowsVisible(winH uint32) int {
	_, ch := vi.TerminalCell()
	if ch == 0 {
		ch = 16
	}
	if winH <= 16 {
		return 1
	}
	return int((winH - 16) / ch)
}

// handleProfileCmd runs the `term-profile` line command. It never reaches
// the engine — the front-end answers it the way it answers `exit --close`.
// Applying a profile merges its keys into SETTINGS.TXT via the same
// crash-safe publish every settings writer uses, then publishes each
// changed key to the seat exactly as GOSET does after a save.
func handleProfileCmd(ts *termState, ta *tabapp.TabApp, fd uint32, editor *shlib.Editor, name string, list bool) {
	body, r := vi.ReadFileAll(profilesPath, profilesMax)
	if r < 0 || len(body) == 0 {
		vi.ConsoleLine(markerProfileRefused + "no file " + profilesPath)
		linkNotice(ts, fd, editor, "goterm: no profiles ("+profilesPath+")")
		return
	}
	ps := parseProfiles(string(body))
	if list {
		// `term-profile` bare answers with the names in-file.
		var names []byte
		for i := range ps {
			if i > 0 {
				names = append(names, ' ')
			}
			names = append(names, ps[i].name...)
		}
		if len(names) == 0 {
			linkNotice(ts, fd, editor, "goterm: no profiles")
			return
		}
		linkNotice(ts, fd, editor, "goterm: profiles: "+string(names))
		vi.ConsoleLine(markerProfile + "list n=" + vi.Itoa64(int64(len(ps))))
		return
	}
	var p *termProfile
	for i := range ps {
		if ps[i].name == name {
			p = &ps[i]
		}
	}
	if p == nil {
		vi.ConsoleLine(markerProfileRefused + name)
		linkNotice(ts, fd, editor, "goterm: no such profile: "+name)
		return
	}
	cur, _ := vi.ReadFileAll(settingsPath, maxStartupBytes)
	merged := applyProfileBody(string(cur), p)
	if rc := vi.WriteFileSafe(settingsPath, []byte(merged)); rc < 0 {
		vi.ConsoleLine(markerProfileRefused + name + " write rc=" + vi.Itoa64(rc))
		linkNotice(ts, fd, editor, "goterm: profile write failed")
		return
	}
	vi.ConsoleLine(markerProfile + name)
	// The kernel applies the saved keys live; the seat publish is the
	// same notice GOSET sends so bound subscribers (its own panel,
	// theme readers) re-resolve — best-effort per key.
	for _, k := range p.keys {
		vi.PublishSettingChange(uint32(ta.Win), k, appName)
	}
	vi.PublishSettingChange(uint32(ta.Win), "term_profile", appName)
	linkNotice(ts, fd, editor, "goterm: profile "+name)
}
