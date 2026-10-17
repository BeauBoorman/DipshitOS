package main

// The manifest layer for M112c (#2415). Three formats, all `#`-comment +
// tab-separated `key=value` rows, sharing FLEET.MF's conventions so the
// tools that read one can read all:
//
//   BOOTIN.MF   input pins: the sha256 and byte count the staged host-built
//               BOOTAA64.EFI / KERNEL.BIN must match before they go into
//               the image (the "sha-pinned inputs" the card names).
//   FLEET.MF    M112a's source->ELF manifest (read-only here): the fleet
//               ELFs the bundle carries are its `built` rows.
//   RELEASE.MF  this driver's output: one row per release artifact — the
//               image itself, the two members embedded in it, and every
//               bundle file. Hashes are recorded so the host can verify
//               the share without re-deriving anything.

import (
	"fmt"
	"strconv"
	"strings"
)

// pinRow is one BOOTIN.MF row: a staged input's expected digest.
type pinRow struct {
	Name   string
	SHA256 string
	Bytes  int64
}

// parsePins reads BOOTIN.MF: `<NAME>\tsha256=<hex>\tbytes=<n>` rows.
func parsePins(text string) ([]pinRow, error) {
	var rows []pinRow
	for n, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) < 3 {
			return nil, fmt.Errorf("pin row %d: expected <NAME>\\tsha256=..\\tbytes=.., got %q", n+1, line)
		}
		row := pinRow{Name: f[0]}
		for _, kv := range f[1:] {
			k, v, ok := strings.Cut(kv, "=")
			if !ok {
				return nil, fmt.Errorf("pin row %d: bad field %q", n+1, kv)
			}
			switch k {
			case "sha256":
				row.SHA256 = v
			case "bytes":
				b, err := strconv.ParseInt(v, 10, 64)
				if err != nil {
					return nil, fmt.Errorf("pin row %d: bad bytes %q", n+1, v)
				}
				row.Bytes = b
			}
		}
		if row.Name == "" || row.SHA256 == "" {
			return nil, fmt.Errorf("pin row %d: missing name or sha256", n+1)
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// fleetMFRow is one FLEET.MF line (M112a #v1): name, state, then k=v fields.
type fleetMFRow struct {
	Name   string
	State  string
	Guest  string // guest sha256 column
	Host   string
	Code   string
	Fields map[string]string
}

func parseFleetManifest(text string) ([]fleetMFRow, error) {
	var rows []fleetMFRow
	for n, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) < 2 {
			return nil, fmt.Errorf("fleet row %d: expected <NAME>\\t<state>\\t..., got %q", n+1, line)
		}
		row := fleetMFRow{Name: f[0], State: f[1], Fields: map[string]string{}}
		for _, kv := range f[2:] {
			k, v, ok := strings.Cut(kv, "=")
			if !ok {
				continue
			}
			row.Fields[k] = v
			switch k {
			case "guest":
				row.Guest = v
			case "host":
				row.Host = v
			case "code":
				row.Code = v
			}
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// relRow is one RELEASE.MF row: a release artifact's name, kind and digest.
// kind is one of:
//
//	image   — the RELEASE.IMG disk image itself
//	member  — a file embedded in the image (EFI/BOOT/BOOTAA64.EFI, KERNEL.BIN)
//	fleet   — a bundle ELF built by the in-guest fleet run
//	driver  — the bundle's own GORELEASE.ELF smoke driver
//	asset   — a data file the share seeds (APPS.TXT, fonts, wallpaper)
//	config  — a file the driver generated (SETTINGS.TXT)
type relRow struct {
	Path   string // bundle-relative for bundle files, canonical for members
	Kind   string
	SHA256 string
	Bytes  int64
}

func renderReleaseManifest(rows []relRow) string {
	var b strings.Builder
	b.WriteString("#v1 release manifest — M112c (#2415): the guest-assembled release\n")
	b.WriteString("# row: <path>\tkind=<image|member|fleet|driver|asset|config>" +
		"\tsha256=<hex>\tbytes=<n>\n")
	for _, r := range rows {
		b.WriteString(r.Path + "\tkind=" + r.Kind +
			"\tsha256=" + r.SHA256 +
			"\tbytes=" + strconv.FormatInt(r.Bytes, 10) + "\n")
	}
	return b.String()
}

func parseReleaseManifest(text string) ([]relRow, error) {
	var rows []relRow
	for n, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) < 2 {
			return nil, fmt.Errorf("release row %d: expected <path>\\tkind=.., got %q", n+1, line)
		}
		row := relRow{Path: f[0]}
		for _, kv := range f[1:] {
			k, v, ok := strings.Cut(kv, "=")
			if !ok {
				return nil, fmt.Errorf("release row %d: bad field %q", n+1, kv)
			}
			switch k {
			case "kind":
				row.Kind = v
			case "sha256":
				row.SHA256 = v
			case "bytes":
				b, err := strconv.ParseInt(v, 10, 64)
				if err != nil {
					return nil, fmt.Errorf("release row %d: bad bytes %q", n+1, v)
				}
				row.Bytes = b
			}
		}
		if row.Kind == "" || row.SHA256 == "" {
			return nil, fmt.Errorf("release row %d: missing kind or sha256", n+1)
		}
		rows = append(rows, row)
	}
	return rows, nil
}
