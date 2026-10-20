package mime

import (
	"errors"
	"strings"
	"testing"
)

func TestOpenResolvesAndDispatchesFiles(t *testing.T) {
	var readPath string
	req, err := Open("README.TXT", "/host/docs", func(path string, max int) ([]byte, error) {
		readPath = path
		if max != HeadBytes {
			t.Errorf("read cap = %d, want HeadBytes (%d)", max, HeadBytes)
		}
		return []byte("plain text from the share"), nil
	})
	if err != nil {
		t.Fatalf("Open returned error: %v", err)
	}
	if readPath != "/host/docs/README.TXT" {
		t.Fatalf("read path = %q", readPath)
	}
	if req.Handler.Bin != "GOEDIT.ELF" || req.Target != readPath ||
		req.Type != Text || req.Scheme != "file" {
		t.Fatalf("Open request = %+v", req)
	}
}

func TestOpenUsesMagicAndNamesMissingHandlers(t *testing.T) {
	req, err := Open("README.TXT", "/", func(string, int) ([]byte, error) {
		return []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"), nil
	})
	if err != nil {
		t.Fatalf("PNG Open returned error: %v", err)
	}
	if req.Type != Image || req.Handler.Bin != "GOVIEW.ELF" {
		t.Fatalf("PNG named .TXT resolved to %+v", req)
	}

	_, err = Open("/host/BUNDLE.ZIP", "/", func(string, int) ([]byte, error) {
		return []byte("PK\x03\x04"), nil
	})
	var openErr *OpenError
	if !errors.As(err, &openErr) || openErr.Kind != OpenNoHandler || openErr.Type != Archive {
		t.Fatalf("archive refusal = %#v, want named no-handler error", err)
	}
}

func TestOpenRoutesHTTPSToWeb(t *testing.T) {
	const target = "HTTPS://10.0.0.2:443/guide?q=one"
	req, err := Open(target, "/", nil)
	if err != nil {
		t.Fatalf("HTTPS Open returned error: %v", err)
	}
	if req.Handler.Bin != "WEB.ELF" || req.Target != target || req.Scheme != "https" {
		t.Fatalf("HTTPS request = %+v", req)
	}
}

func TestOpenResolvesFileURLsWithinTheShare(t *testing.T) {
	for _, tc := range []struct{ target, want string }{
		{"file:///host/README.TXT", "/host/README.TXT"},
		{"file://localhost/host/README.TXT", "/host/README.TXT"},
		{"file:///host/docs/notes%20one.md", "/host/docs/notes one.md"},
	} {
		t.Run(tc.target, func(t *testing.T) {
			var readPath string
			req, err := Open(tc.target, "/", func(path string, _ int) ([]byte, error) {
				readPath = path
				return []byte("text"), nil
			})
			if err != nil {
				t.Fatalf("Open returned error: %v", err)
			}
			if readPath != tc.want || req.Target != tc.want {
				t.Fatalf("path read=%q target=%q, want %q", readPath, req.Target, tc.want)
			}
		})
	}
}

func TestOpenRefusesBadTargetsAndSchemesByName(t *testing.T) {
	for _, target := range []string{"", "https://", "file://example.com/secret", "file:///host/../secret"} {
		if _, err := Open(target, "/", func(string, int) ([]byte, error) {
			t.Fatal("invalid target reached file reader")
			return nil, nil
		}); err == nil {
			t.Errorf("Open(%q) unexpectedly succeeded", target)
		}
	}

	_, err := Open("ftp://example.com/file", "/", nil)
	var openErr *OpenError
	if !errors.As(err, &openErr) || openErr.Kind != OpenUnsupportedScheme ||
		openErr.Scheme != "ftp" {
		t.Fatalf("FTP refusal = %#v, want unsupported URL scheme", err)
	}
}

// M132b (#2753): /disk is a first-class local volume, canonicalized like
// /host and /usbN rather than refused as a foreign path.
func TestOpenRetainsTheDiskVolume(t *testing.T) {
	var readPath string
	_, err := Open("/disk/DOCS/PAPER.PDF", "/", func(path string, _ int) ([]byte, error) {
		readPath = path
		return []byte("%PDF-1.4\n"), nil
	})
	if err != nil {
		t.Fatalf("Open(/disk/...) returned error: %v", err)
	}
	if readPath != "/disk/DOCS/PAPER.PDF" {
		t.Fatalf("read path = %q, want the /disk volume retained", readPath)
	}
}

func TestOpenDistinguishesUnreadableFiles(t *testing.T) {
	_, err := Open("/host/README.TXT", "/", func(string, int) ([]byte, error) {
		return nil, errors.New("EACCES")
	})
	var openErr *OpenError
	if !errors.As(err, &openErr) || openErr.Kind != OpenUnreadable {
		t.Fatalf("unreadable refusal = %#v, want OpenUnreadable", err)
	}
}

func TestOpenRejectsTraversalAndOversizedPaths(t *testing.T) {
	for _, target := range []string{"../README.TXT", "/host/docs/../README.TXT", "/" + strings.Repeat("a", 64)} {
		_, err := Open(target, "/", func(string, int) ([]byte, error) {
			t.Fatal("invalid path reached file reader")
			return nil, nil
		})
		if err == nil {
			t.Errorf("Open(%q) unexpectedly succeeded", target)
		}
	}
}
