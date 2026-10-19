// M123d (#2578): the shared appkit.ErrorBanner, adopted for the app's own
// failure surfaces.
//
//   - a failed load raises it in setError (the one funnel finishError and
//     the pipeline's error exits share) — Retry-able kinds get the Retry
//     arm, which re-navigates the target the error page already names;
//     "cancelled" never raises one because a user's own stop is not a
//     failure to answer
//   - a refused vi.Exec on the download plate's OPEN/FOLDER chips raises
//     it bare — Copy Error and dismiss are the honest answers
//   - a failed download fetch raises it with a Retry arm that refetches
//
// The strip is inline, not modal: it owns the top of the content band —
// keys route to it and presses inside are consumed — while everything
// outside keeps working; Esc or the × dismisses it.
package main

import (
	"virelai/appkit"
	"virelai/vi"
	"virelai/vsys"
	"virelai/widgets"
)

const (
	// markerBanner is the raise; markerBannerAct is the resolution — the
	// action ID that ran, or dismiss. Same `banner`/`banner act` pair
	// GOFILES prints (files/markers.go): one vocabulary across apps.
	markerBanner    = "web: banner "
	markerBannerAct = "web: banner act "
)

// clipSetTyped is the Copy Error arm's clipboard seam — vsys's slot-38
// typed write, swappable by the host tests.
var clipSetTyped = vsys.ClipboardSetTyped

// bannerRect is the strip's geometry: full-width, at the top of the
// content band under the URL row.
func (a *app) bannerRect() widgets.Rect {
	w, _ := a.canvasSize()
	return widgets.Rect{X: 0, Y: kernelBand + 32, W: w, H: appkit.BannerHeight()}
}

// bannerRetryable names the failure kinds a Retry can honestly answer —
// the transient network family. Permanent refusals (a refused scheme, a
// redirect loop, an over-cap body) and the user's own "cancelled" get no
// Retry: it would promise a different outcome the same load cannot give.
func bannerRetryable(kind string) bool {
	switch kind {
	case "dns", "tcp", "timeout", "tls", "http",
		"http-premature-eof", "network-request-limit":
		return true
	}
	return false
}

// raiseBanner opens the shared strip over the content band and marks the
// raise. op identifies the arm a retry replays ("load", "download", or ""
// for a copy/dismiss-only banner); target is what it replays against.
func (a *app) raiseBanner(op, text, target string, actions ...appkit.BannerAction) {
	a.bannerOp = op
	a.bannerTarget = target
	a.banner.R = a.bannerRect()
	a.banner.Show(text, actions...)
	vi.ConsoleLine(markerBanner + text)
	a.dirty = true
}

// raiseLoadBanner is setError's arm: the load failure's kind decides
// whether Retry is offered (bannerRetryable) or the text alone is the
// answer.
func (a *app) raiseLoadBanner(kind, target string) {
	if bannerRetryable(kind) {
		a.raiseBanner("load", "load failed: "+kind+" — "+target, target,
			appkit.BannerAction{ID: "retry", Label: "Retry"})
		return
	}
	a.raiseBanner("", "load failed: "+kind+" — "+target, "")
}

// bannerKeyEvent feeds one key event to the open banner — the appkit
// vocabulary on the window's wire event (Arg0 usage, Arg1 decoded rune).
// A resolved banner runs bannerResolve in the same pass.
func (a *app) bannerKeyEvent(ev vi.Event) {
	changed, done := a.banner.HandleKey(ev)
	if done {
		a.bannerResolve()
	}
	if changed || done {
		a.dirty = true
	}
}

// bannerClick routes a left press at (x, y): inside the strip the banner
// answers it (buttons choose, × dismisses, bare plate swallows); outside,
// the click is not the banner's and falls through to the page.
func (a *app) bannerClick(x, y int) bool {
	if !a.banner.Open {
		return false
	}
	a.banner.R = a.bannerRect()
	if !a.banner.Contains(x, y) {
		return false
	}
	_, done := a.banner.HandleMouse(x, y, true)
	if done {
		a.bannerResolve()
	}
	a.dirty = true
	return true
}

// bannerResolve acts on the banner's Choice once it closes: `retry`
// replays the stored arm (the failed navigation, or the failed download
// fetch), `copy` publishes the error text on the machine clipboard, and
// dismiss settles it. Every path names itself on `web: banner act …`.
func (a *app) bannerResolve() {
	choice := a.banner.Choice
	a.banner.Choice = ""
	op, target := a.bannerOp, a.bannerTarget
	a.bannerOp, a.bannerTarget = "", ""
	switch {
	case choice == appkit.BannerCopy:
		_, rc := clipSetTyped(vsys.ClipText, []byte(a.banner.Text))
		if rc < 0 {
			vi.ConsoleLine(markerBannerAct + "copy rc=" + itoa64(rc))
		} else {
			vi.ConsoleLine(markerBannerAct + "copy")
		}
		a.status = "error copied"
	case choice == "retry" && op == "load" && target != "":
		vi.ConsoleLine(markerBannerAct + "retry " + target)
		a.navigate(target, "")
	case choice == "retry" && op == "download" && target != "":
		vi.ConsoleLine(markerBannerAct + "retry " + target)
		a.startDownload(target, nil)
	default:
		vi.ConsoleLine(markerBannerAct + choice)
	}
	a.dirty = true
}

// paintBanner draws the strip on the window filler — the dlCanvas adapter
// (fill-only virender → widgets.RectCanvas) is the same seam the download
// progress bar already paints through.
func (a *app) paintBanner(vs virender) {
	if !a.banner.Open {
		return
	}
	a.banner.R = a.bannerRect()
	a.banner.Draw(dlCanvas{v: vs})
}
