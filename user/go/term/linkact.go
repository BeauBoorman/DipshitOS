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
	// markerProfileFallback is restore's named marker for the absent-name
	// case: `goterm: profile fallback <applied> saved=<saved>`.
	markerProfileFallback = "goterm: profile fallback "
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

// profileUsage is the command's help half, appended to the bare list: the
// font is a kernel-global setting — font_size moves EVERY terminal window,
// there is no per-window font.
const profileUsage = "usage: term-profile NAME|next|prev — font_size is kernel-global (every terminal window shares it)"

// profileActiveName reads the settings store's record of the choice —
// the `term_profile=<name>` row applyProfileBody writes. It is the cycle
// base for next/prev and the star in the bare list; other writers (GOSET,
// another window) move it too, which is why it is re-read per command.
func profileActiveName() string {
	return shlib.SettingFromSettings(settingsBody(), "term_profile", "")
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
		linkNotice(ts, fd, editor, "goterm: no profiles ("+profilesPath+")\r\n"+profileUsage)
		return
	}
	ps := parseProfiles(string(body))
	if list {
		// `term-profile` bare answers with the names in-file, the active
		// one starred.
		cur := profileActiveName()
		names := profileNamesMarked(ps, cur)
		if len(names) == 0 {
			linkNotice(ts, fd, editor, "goterm: no profiles\r\n"+profileUsage)
			return
		}
		linkNotice(ts, fd, editor, "goterm: profiles: "+names+"\r\n"+profileUsage)
		marker := markerProfile + "list n=" + vi.Itoa64(int64(len(ps)))
		if cur != "" {
			marker += " active=" + cur
		}
		vi.ConsoleLine(marker)
		return
	}
	var p *termProfile
	switch name {
	case "next":
		p = cycleProfile(ps, profileActiveName(), 1)
	case "prev":
		p = cycleProfile(ps, profileActiveName(), -1)
	default:
		for i := range ps {
			if ps[i].name == name {
				p = &ps[i]
			}
		}
	}
	if p == nil {
		vi.ConsoleLine(markerProfileRefused + name)
		linkNotice(ts, fd, editor, "goterm: no such profile: "+name)
		return
	}
	if !applyProfileFile(ts, ta, p) {
		linkNotice(ts, fd, editor, "goterm: profile write failed")
		return
	}
	linkNotice(ts, fd, editor, "goterm: profile "+p.name)
}

// applyProfileFile merges p into SETTINGS.TXT through the crash-safe
// publish, records it as the live profile for the state blob, and
// publishes each changed key to the seat exactly as GOSET does after a
// save — the kernel applies the saved keys live; bound subscribers (its
// own panel, theme readers) re-resolve off the notices. The apply marker
// prints only after the write landed.
func applyProfileFile(ts *termState, ta *tabapp.TabApp, p *termProfile) bool {
	cur, _ := vi.ReadFileAll(settingsPath, maxStartupBytes)
	merged := applyProfileBody(string(cur), p)
	if rc := vi.WriteFileSafe(settingsPath, []byte(merged)); rc < 0 {
		vi.ConsoleLine(markerProfileRefused + p.name + " write rc=" + vi.Itoa64(rc))
		return false
	}
	ts.profile = p.name
	vi.ConsoleLine(markerProfile + p.name)
	for _, k := range p.keys {
		vi.PublishSettingChange(uint32(ta.Win), k, appName)
	}
	vi.PublishSettingChange(uint32(ta.Win), "term_profile", appName)
	return true
}

// applySavedProfile is restore's half of the command: applyEnv calls it
// once (restored session 0) to put the terminal back in the profile the
// blob named. The blob can name a profile the file no longer carries —
// a name missing from the file falls back to the default (the file's
// first entry) with the fallback marker naming both. No seat publish:
// RestoreState never hands the window id down, and the seat re-seeded
// its bus from the same file before it re-exec'd us.
func (ts *termState) applySavedProfile(hst *termHost) {
	saved := ts.savedProfile
	if saved == "" {
		return
	}
	var ps []termProfile
	if body, r := vi.ReadFileAll(profilesPath, profilesMax); r >= 0 {
		ps = parseProfiles(string(body))
	}
	p, fellBack := resolveRestore(ps, saved)
	if p == nil {
		vi.ConsoleLine(markerProfileRefused + "restore " + saved)
		return
	}
	cur, _ := vi.ReadFileAll(settingsPath, maxStartupBytes)
	merged := applyProfileBody(string(cur), p)
	if rc := vi.WriteFileSafe(settingsPath, []byte(merged)); rc < 0 {
		vi.ConsoleLine(markerProfileRefused + "restore " + saved + " write rc=" + vi.Itoa64(rc))
		return
	}
	ts.profile = p.name
	if fellBack {
		vi.ConsoleLine(markerProfileFallback + p.name + " saved=" + saved)
		writeTTY(ts, hst.fd, []byte("\r\ngoterm: profile "+p.name+" (restored; '"+saved+"' is gone — the default applies)\r\n"))
		return
	}
	vi.ConsoleLine(markerProfile + p.name)
	writeTTY(ts, hst.fd, []byte("\r\ngoterm: profile "+p.name+" (restored)\r\n"))
}
