package flate

import (
	"bytes"
	"compress/gzip"
	"testing"
)

func hostGzip(t *testing.T, body []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	w := gzip.NewWriter(&buf)
	if _, err := w.Write(body); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestInflateGzipRoundTrip(t *testing.T) {
	for _, body := range [][]byte{
		[]byte("Hello from VirelaiOS Host!\n"),
		{},
		[]byte{0, 1, 2, 3, 255, 254, 253},
		bytes.Repeat([]byte("chunky bacon "), 400),
	} {
		src := hostGzip(t, body)
		dst := make([]byte, len(body)+16)
		n, consumed, err := InflateGzip(dst, src)
		if err != nil {
			t.Fatalf("InflateGzip(%d bytes): %v", len(body), err)
		}
		if n != len(body) || !bytes.Equal(dst[:n], body) {
			t.Fatalf("decoded %d bytes, want %d", n, len(body))
		}
		if consumed != len(src) {
			t.Fatalf("consumed=%d want %d", consumed, len(src))
		}
	}
}

func TestInflateGzipMultiMember(t *testing.T) {
	a, b := []byte("first member "), []byte("second member")
	src := append(hostGzip(t, a), hostGzip(t, b)...)
	dst := make([]byte, 64)
	n, consumed, err := InflateGzip(dst, src)
	if err != nil {
		t.Fatalf("InflateGzip: %v", err)
	}
	if string(dst[:n]) != "first member second member" || consumed != len(src) {
		t.Fatalf("n=%d consumed=%d want full concatenation", n, consumed)
	}
}

func TestInflateGzipRefusesByName(t *testing.T) {
	body := []byte("integrity is checked")
	good := hostGzip(t, body)
	dst := make([]byte, 64)

	badCRC := append([]byte(nil), good...)
	badCRC[len(badCRC)-8] ^= 0xff
	if _, _, err := InflateGzip(dst, badCRC); err != errGzipCRC {
		t.Fatalf("corrupt CRC err = %v want %v", err, errGzipCRC)
	}

	badSize := append([]byte(nil), good...)
	badSize[len(badSize)-4] ^= 0xff
	if _, _, err := InflateGzip(dst, badSize); err != errGzipSize {
		t.Fatalf("corrupt ISIZE err = %v want %v", err, errGzipSize)
	}

	badMagic := append([]byte(nil), good...)
	badMagic[0] = 0
	if _, _, err := InflateGzip(dst, badMagic); err != errGzipMember {
		t.Fatalf("bad magic err = %v want %v", err, errGzipMember)
	}

	reserved := append([]byte(nil), good...)
	reserved[3] |= 0x80
	if _, _, err := InflateGzip(dst, reserved); err != errGzipMember {
		t.Fatalf("reserved FLG err = %v want %v", err, errGzipMember)
	}

	truncated := good[:len(good)-3]
	if _, _, err := InflateGzip(dst, truncated); err == nil {
		t.Fatal("truncated trailer accepted")
	}

	small := make([]byte, len(body)-1)
	if _, _, err := InflateGzip(small, good); err != errBufSmall {
		t.Fatalf("short dst err = %v want %v", err, errBufSmall)
	}
}

func TestGunzipHeaderOptionalFields(t *testing.T) {
	// A member carrying every optional field: FEXTRA + FNAME + FCOMMENT +
	// FHCRC + FTEXT, built by hand (host gzip emits none of them).
	body := []byte("fields")
	var src []byte
	hdr := []byte{gzipID1, gzipID2, gzipCM,
		gzipFText | gzipFHCRC | gzipFExtra | gzipFName | gzipFComm,
		0, 0, 0, 0, 0, 3}
	extra := []byte{2, 0, 'x', 'y'}
	head := append(append(append(append(hdr, extra...), "NAME"...), 0),
		append([]byte("comment"), 0)...)
	head = append(head, byte(crc32IEEE(head)), byte(crc32IEEE(head)>>8))
	// raw deflate of body via a stored block
	deflate := []byte{0x01, byte(len(body)), byte(len(body) >> 8),
		^byte(len(body)), ^byte(len(body) >> 8)}
	deflate = append(deflate, body...)
	trailer := []byte{byte(crc32IEEE(body)), byte(crc32IEEE(body) >> 8),
		byte(crc32IEEE(body) >> 16), byte(crc32IEEE(body) >> 24),
		byte(len(body)), 0, 0, 0}
	src = append(append(head, deflate...), trailer...)

	dst := make([]byte, 32)
	n, consumed, err := InflateGzip(dst, src)
	if err != nil {
		t.Fatalf("InflateGzip with optional fields: %v", err)
	}
	if string(dst[:n]) != "fields" || consumed != len(src) {
		t.Fatalf("n=%d consumed=%d", n, consumed)
	}
	// A wrong FHCRC refuses before the deflate stream is even read.
	bad := append([]byte(nil), src...)
	bad[len(head)-1] ^= 0xff
	if _, _, err := InflateGzip(dst, bad); err != errGzipMember {
		t.Fatalf("bad FHCRC err = %v want %v", err, errGzipMember)
	}
}
