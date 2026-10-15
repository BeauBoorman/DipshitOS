package main

import (
	"bufio"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
)

// The committed golden fixtures are .regions files: a mostly-zero VLFS
// image described as its non-zero byte runs. An image volume must be at
// least 16 MiB (ADR 0050 D7), so the golden is the diff from zero, not the
// whole file — both language implementations reconstruct the same bytes
// from it and assert their own writer/reader against the result.
//
// Format:
//
//	vlfs-regions 1
//	bytes <volume_bytes>
//	<offset> <hex>
//	...
//
// Region lines are offset-sorted, non-overlapping, and every byte NOT
// covered by a region must be zero — a complete byte-exact description.

type region struct {
	off  uint64
	data []byte
}

// regionsOf collects img's maximal runs of non-zero bytes.
func regionsOf(img []byte) []region {
	var out []region
	for i := 0; i < len(img); {
		if img[i] == 0 {
			i++
			continue
		}
		j := i + 1
		for j < len(img) && img[j] != 0 {
			j++
		}
		out = append(out, region{uint64(i), append([]byte(nil), img[i:j]...)})
		i = j
	}
	return out
}

// regionsEncode renders img in the golden text form.
func regionsEncode(img []byte) string {
	var sb strings.Builder
	sb.WriteString("vlfs-regions 1\n")
	fmt.Fprintf(&sb, "bytes %d\n", len(img))
	for _, r := range regionsOf(img) {
		fmt.Fprintf(&sb, "%d %s\n", r.off, hex.EncodeToString(r.data))
	}
	return sb.String()
}

// regionsDecode rebuilds the image described by a .regions document.
func regionsDecode(text string) ([]byte, error) {
	var img []byte
	var haveHeader bool
	var last uint64
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 64*1024), 8*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if !haveHeader {
			if line != "vlfs-regions 1" {
				return nil, fmt.Errorf("bad header %q", line)
			}
			haveHeader = true
			continue
		}
		if img == nil {
			var n uint64
			if _, err := fmt.Sscanf(line, "bytes %d", &n); err != nil {
				return nil, fmt.Errorf("bad bytes line %q", line)
			}
			img = make([]byte, n)
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 2 {
			return nil, fmt.Errorf("bad region line %q", line)
		}
		off, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil {
			return nil, err
		}
		data, err := hex.DecodeString(fields[1])
		if err != nil {
			return nil, err
		}
		if off < last {
			return nil, fmt.Errorf("regions out of order at %d", off)
		}
		if off+uint64(len(data)) > uint64(len(img)) {
			return nil, fmt.Errorf("region at %d overflows image", off)
		}
		copy(img[off:], data)
		last = off + uint64(len(data))
	}
	if img == nil {
		return nil, fmt.Errorf("no bytes line")
	}
	return img, nil
}

// regionsVerify reports the first byte where img disagrees with the
// golden document: a region byte mismatch, or a non-zero byte outside
// every region. Returns (-1, ...) when clean.
func regionsVerify(img []byte, text string) error {
	want, err := regionsDecode(text)
	if err != nil {
		return err
	}
	if uint64(len(img)) != uint64(len(want)) {
		return fmt.Errorf("size %d, golden %d", len(img), len(want))
	}
	for i := range want {
		if img[i] != want[i] {
			return fmt.Errorf("byte %d: got %02x want %02x", i, img[i], want[i])
		}
	}
	return nil
}
