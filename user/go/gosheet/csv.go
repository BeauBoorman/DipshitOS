// The M142b (#2790) CSV half: an RFC 4180 codec behind the FilePicker
// import/export surface and the text/csv clipboard lane.
//
// Read side is deliberately tolerant — a clipboard body is prose before it
// is records. A '"' only opens a quoted field at field start, '""' inside a
// quoted field is one literal quote, and a '"' followed by anything but ','
// or a record end is literal text (an unclosed quote runs to end of record,
// not an error). Records split on CRLF, LF, or CR. The write side quotes a
// field exactly when it holds ',', '"', CR or LF and terminates every
// record with CRLF.
package main

import "strings"

// parseCSV decodes a CSV body into rows of fields. There is no fixed column
// count — later rows may run longer or shorter than the first.
func parseCSV(b []byte) [][]string {
	var rows [][]string
	var row []string
	i := 0
	for {
		f, next := csvField(b, i)
		row = append(row, f)
		i = next
		if i >= len(b) {
			break
		}
		if b[i] == ',' {
			i++
			continue
		}
		if b[i] == '\r' {
			i++
			if i < len(b) && b[i] == '\n' {
				i++
			}
		} else {
			i++
		}
		rows = append(rows, row)
		row = nil
		if i >= len(b) {
			return rows
		}
	}
	return append(rows, row)
}

// csvField reads one field starting at i and returns its text plus the
// index of the delimiter that ended it (or len(b)).
func csvField(b []byte, i int) (string, int) {
	if i < len(b) && b[i] == '"' {
		var sb strings.Builder
		j := i + 1
		for j < len(b) {
			c := b[j]
			if c != '"' {
				sb.WriteByte(c)
				j++
				continue
			}
			if j+1 < len(b) && b[j+1] == '"' {
				sb.WriteByte('"')
				j += 2
				continue
			}
			// A '"' ending quotes: ',' / EOL / EOF close the field
			// cleanly; anything else is a stray quote — the field ends
			// there and the trailing junk merges as literal text.
			if j+1 >= len(b) || b[j+1] == ',' || b[j+1] == '\r' || b[j+1] == '\n' {
				return sb.String(), j + 1
			}
			j++
			for j < len(b) && b[j] != ',' && b[j] != '\r' && b[j] != '\n' {
				sb.WriteByte(b[j])
				j++
			}
			return sb.String(), j
		}
		return sb.String(), j
	}
	j := i
	for j < len(b) && b[j] != ',' && b[j] != '\r' && b[j] != '\n' {
		j++
	}
	return string(b[i:j]), j
}

// writeCSV serializes rows RFC 4180-style: ','-joined fields, CRLF record
// ends, quotes only where the field body needs them.
func writeCSV(rows [][]string) []byte {
	var sb strings.Builder
	for _, row := range rows {
		for i, f := range row {
			if i > 0 {
				sb.WriteByte(',')
			}
			if strings.IndexAny(f, ",\"\r\n") >= 0 {
				sb.WriteByte('"')
				for k := 0; k < len(f); k++ {
					if f[k] == '"' {
						sb.WriteByte('"')
					}
					sb.WriteByte(f[k])
				}
				sb.WriteByte('"')
			} else {
				sb.WriteString(f)
			}
		}
		sb.WriteString("\r\n")
	}
	return []byte(sb.String())
}

// csvRows renders the closed range lo..hi as display values — formula cells
// export the value the grid shows, never the raw expression.
func (s *Sheet) csvRows(lo, hi cellRef) [][]string {
	var rows [][]string
	for r := lo.row; r <= hi.row; r++ {
		var row []string
		for c := lo.col; c <= hi.col; c++ {
			row = append(row, s.display(refAt(c, r)))
		}
		rows = append(rows, row)
	}
	return rows
}

// usedBBox is the bounding box of the sheet's filled cells — the range
// ctrl-a selects and the FilePicker export writes.
func (s *Sheet) usedBBox() (lo, hi cellRef, ok bool) {
	for r := range s.cells {
		if !ok {
			lo, hi, ok = r, r, true
			continue
		}
		lo.col = min(lo.col, r.col)
		lo.row = min(lo.row, r.row)
		hi.col = max(hi.col, r.col)
		hi.row = max(hi.row, r.row)
	}
	return lo, hi, ok
}
