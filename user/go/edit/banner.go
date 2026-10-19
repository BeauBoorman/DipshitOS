// M123d (#2578): the shared appkit.ErrorBanner, adopted for the editor's own
// failure surfaces — the deferred GOEDIT leg of the card (the file was held
// by #2584 until #2693 merged). GOEDIT never runs vi.Exec itself — GOFILES
// launches it, never the reverse — so the card's exec arm lands on
// GOFILES/WEB and the editor's strip covers its two FS failure paths:
//
//   - load()'s read refusal raises it — except a plain missing file, which
//     is the documented create path (the empty buffer is the answer), not
//     a failure.
//   - save()'s refusal raises it — the held-lease refusal and a failed
//     safe-write alike.
//
// Both are copy/dismiss banners with no contextual actions: there is no
// Replace-shaped decision an open/save failure carries — the retry is the
// next Ctrl-S — and Copy Error is how the refusal's text leaves the VM.
//
// The strip is inline, not modal: it owns the top of the document band and
// the keyboard while it stands, paints its own plate over whatever the
// frame already drew, and Esc/Backspace or the × dismisses it.
package main

import (
	"virelai/appkit"
	"virelai/vi"
	"virelai/widgets"
)

// bannerRect is the strip's geometry: full-width across the document band's
// top edge, just under the chrome row.
func (e *editor) bannerRect() widgets.Rect {
	w := natW
	if e.ta != nil && e.ta.W > 0 {
		w = int(e.ta.W)
	}
	return widgets.Rect{X: 0, Y: chromeH, W: w, H: appkit.BannerHeight()}
}

// raiseBanner opens the strip with the failure's text and latches
// bannerFresh: the raise marker prints from bannerFlush, AFTER the frame
// that shows the strip is presented — the same post-paint rule GOFILES'
// raiseBanner holds, because a marker that precedes its frame is a
// screenshot the gate cannot take.
func (e *editor) raiseBanner(text string, actions ...appkit.BannerAction) {
	e.banner.R = e.bannerRect()
	e.banner.Show(text, actions...)
	e.bannerFresh = true
}

// bannerFlush emits the `goedit: banner …` raise marker once, from the
// event loop's post-Present points, while a raised banner still stands.
func (e *editor) bannerFlush() {
	if !e.bannerFresh {
		return
	}
	e.bannerFresh = false
	if e.banner.Open {
		vi.ConsoleLine(markerBanner + e.banner.Text)
	}
}

// bannerKey routes one key to the open strip — the appkit vocabulary on the
// window's wire event — and resolves it in the same pass when it closes.
// Every key is consumed: nothing types into the document while the strip
// stands.
func (e *editor) bannerKey(ev vi.Event) bool {
	_, done := e.banner.HandleKey(ev)
	if done {
		e.bannerResolve()
	}
	return true
}

// bannerPress routes a left press at a window point: inside the strip the
// banner answers it (a button chooses, the × dismisses, a bare-plate press
// is swallowed); outside it is not the banner's and falls through.
func (e *editor) bannerPress(x, y int) bool {
	e.banner.R = e.bannerRect()
	if !e.banner.Contains(x, y) {
		return false
	}
	if _, done := e.banner.HandleMouse(x, y, true); done {
		e.bannerResolve()
	}
	return true
}

// bannerResolve acts on the strip's Choice once it closes: `copy` publishes
// the failure text on the machine clipboard through the app's own slot-38
// seam — an unprivileged editor reports the refusal code on the act marker
// instead — and anything else (dismiss) names itself. A banner that
// resolved silently would be a failure nobody saw answered.
func (e *editor) bannerResolve() {
	choice := e.banner.Choice
	e.banner.Choice = ""
	if choice == appkit.BannerCopy {
		if _, rc := clipWrite([]byte(e.banner.Text)); rc < 0 {
			vi.ConsoleLine(markerBannerAct + "copy rc=" + vi.Itoa64(rc))
		} else {
			vi.ConsoleLine(markerBannerAct + "copy")
		}
		return
	}
	vi.ConsoleLine(markerBannerAct + choice)
}
