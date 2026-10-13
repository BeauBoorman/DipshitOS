// GOHTTPD.ELF — Content-Type table (the card's "small mime table off
// /host"). Pure: no imports, no syscalls, host-testable.
package main

import "strings"

// mimeForPath maps a share path's extension to a Content-Type value. The
// table is deliberately the handful the share and index actually serve —
// an unknown extension is application/octet-stream, never a guess.
func mimeForPath(path string) string {
	i := strings.LastIndexByte(path, '.')
	if i < 0 {
		return "application/octet-stream"
	}
	switch strings.ToLower(path[i:]) {
	case ".html", ".htm":
		return "text/html; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".txt":
		return "text/plain; charset=utf-8"
	case ".json":
		return "application/json"
	case ".png":
		return "image/png"
	case ".qoi":
		return "image/qoi"
	case ".svg":
		return "image/svg+xml"
	default:
		return "application/octet-stream"
	}
}
