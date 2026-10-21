// M153e (#2925): save-as .pdf — a page copy any PDF reader opens.
//
// A picked save name ending in .pdf leaves the raw-body leg for a raster
// one: the already-laid-out document (a.lay, the same items on the
// scanout) is repainted full-height off-screen at the 1280-wide layout,
// center-sampled down to pdfwrite's 1024 px image ceiling — the same
// (2k+1)/2 rule presentation.go's letterbox uses — and sliced into
// Letter pages. Each slice is a DeviceRGB image stretched over the
// 612x792 pt page by pdfwrite, so a slice's aspect must match the
// page's: 1024*792/612 = 1325.18 rows; 1324 is the nearest multiple of
// four, keeping the 5:4 source mapping exact (1655 source rows per
// page) at a 0.05% vertical squeeze no eye finds.
//
// Bounds are the card's: at most 16 pages and pdfwrite's own 4 MiB
// output / 16 MiB decoded budgets. A document that cannot become a
// conforming file is a named refusal (`web: saveas pdf refused <why>`)
// and no file — never a silently different PDF. Paint runs in bounded
// strips rather than one full-page band so the raster's transient cost
// stays beside the download path's instead of the decode ledger's.
package main

import (
	"strings"

	"virelai/pdfwrite"
	"virelai/vi"
	"virelai/webrender"
)

const (
	markerSavePDF        = "web: saveas pdf "
	markerSavePDFRefused = "web: saveas pdf refused "

	// pdfRasterW is the page-slice width — pdfwrite's image ceiling and
	// the card's "1024 px wide".
	pdfRasterW = 1024
	// pdfPageRows is the slice height that keeps content aspect on the
	// 612x792 Letter page (see header); pdfSrcRows is the same span in
	// 1280-wide layout rows (1324*1280/1024).
	pdfPageRows = 1324
	pdfSrcRows  = 1655
	pdfMaxPages = 16
	// pdfStripRows bounds the off-screen band Paint renders before the
	// downsample consumes it: four strips cover a page.
	pdfStripRows = 415
)

// isPDFName reports whether a save path asks for the raster-PDF leg.
// The share's names are uppercase; the check is case-insensitive ASCII.
func isPDFName(path string) bool {
	return len(path) >= 4 && strings.EqualFold(path[len(path)-4:], ".pdf")
}

// savePDFTo is the .pdf arm of the shared save leg: render the laid-out
// document into a bounded pdfwrite document, publish it through the same
// crash-safe write and record it on the same downloads ledger the raw
// save uses. Refusals are named on serial and leave no file.
func (a *app) savePDFTo(path string) bool {
	data, pages, why := a.renderPDF()
	if why == "" {
		if writeFileAll(path, data) {
			ledgerAppend("/host/WEB-DOWNLOADS.TXT",
				"# virelai-web-downloads v1 (unix-seconds<TAB>target<TAB>file<TAB>bytes)",
				itoa64(vi.Time())+"\t"+a.target+"\t"+path+"\t"+itoa(len(data)))
			vi.ConsoleLine(markerSavePDF + path + " pages=" + itoa(pages) +
				" bytes=" + itoa(len(data)))
			return true
		}
		why = "file"
	}
	vi.ConsoleLine(markerSavePDFRefused + why)
	return false
}

// renderPDF builds the whole document before any write: page count and
// both pdfwrite budgets are settled up front, so a refusal never
// publishes a prefix. why is "" on success.
func (a *app) renderPDF() ([]byte, int, string) {
	lay := a.lay
	if lay == nil || lay.Height <= 0 {
		return nil, 0, "document"
	}
	pages := (lay.Height + pdfSrcRows - 1) / pdfSrcRows
	if pages > pdfMaxPages {
		return nil, 0, "pages"
	}
	doc := pdfwrite.New(pdfwrite.Meta{Title: docTitle(a.doc), Producer: "virelai web"})
	band := make([]uint32, contentW*pdfStripRows)
	rgb := make([]byte, pdfRasterW*pdfPageRows*3)
	for p := 0; p < pages; p++ {
		pdfPageSlice(lay, p, rgb, band)
		if err := doc.AddRasterPage(rgb, pdfRasterW, pdfPageRows); err != nil {
			return nil, 0, "bytes"
		}
	}
	out, err := doc.Bytes()
	if err != nil {
		return nil, 0, "bytes"
	}
	return out, pages, ""
}

// pdfPageSlice paints page p's source rows (layout rows
// [p*pdfSrcRows, +pdfSrcRows)) strip by strip and center-samples each
// strip into dst's page rows. Rows past the document end keep the page
// background, matching the letterboxed viewport's own tail fill.
func pdfPageSlice(lay *webrender.Layout, p int, dst []byte, band []uint32) {
	for stripTop := 0; stripTop < pdfSrcRows; stripTop += pdfStripRows {
		stripH := min(pdfStripRows, pdfSrcRows-stripTop)
		v := virender{pix: band, w: contentW, h: stripH}
		v.Fill(0, 0, contentW, stripH, webrender.ColorPageBg)
		webrender.Paint(lay, v, 0, 0, contentW, stripH, p*pdfSrcRows+stripTop)
		// dst row y samples source row (2y+1)*5/8 of the page band; the
		// rows whose centers land in this strip are
		// [ceil((8*top-5)/10), ceil((8*bot-5)/10)).
		y0 := (8*stripTop + 4) / 10
		y1 := (8*(stripTop+stripH) + 4) / 10
		for y := y0; y < y1; y++ {
			sy := (2*y+1)*pdfSrcRows/(2*pdfPageRows) - stripTop
			row := band[sy*contentW : sy*contentW+contentW]
			out := dst[y*pdfRasterW*3:]
			for x := 0; x < pdfRasterW; x++ {
				px := row[(2*x+1)*contentW/(2*pdfRasterW)]
				out[3*x] = byte(px >> 16)
				out[3*x+1] = byte(px >> 8)
				out[3*x+2] = byte(px)
			}
		}
	}
}

// docTitle extracts the document's <title> for the PDF Info entry —
// separate from pageTitle, which prefers a visible heading and falls
// back to the file name for chrome purposes. TextContent is no help
// here: <title> is a metadata tag, so its own subtree flattens to "".
func docTitle(doc *webrender.Document) string {
	if doc == nil || doc.Root == nil {
		return ""
	}
	var title func(*webrender.Node) string
	title = func(n *webrender.Node) string {
		var b strings.Builder
		var text func(*webrender.Node)
		text = func(x *webrender.Node) {
			if x.Kind == webrender.KindText {
				b.WriteString(x.Text)
				return
			}
			for _, c := range x.Children {
				text(c)
			}
		}
		text(n)
		return strings.TrimSpace(b.String())
	}
	var walk func(*webrender.Node) string
	walk = func(n *webrender.Node) string {
		if n.Tag == "title" {
			return title(n)
		}
		for _, c := range n.Children {
			if t := walk(c); t != "" {
				return t
			}
		}
		return ""
	}
	return walk(doc.Root)
}
