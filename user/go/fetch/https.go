package main

import (
	"virelai/httpc"
	"virelai/tls"
)

// The windowed TLS consumer is a one-shot fetch: it speaks the same
// HTTP/1.1 request shape as the cleartext path (M135b), reads the
// response through the shared engine (Content-Length, chunked, gzip),
// and closes when the body is complete — a keep-alive-armed request is
// still honest here because the framing is real, not EOF-assumed.

func httpsDial(addr string, port uint16, sni string) (*tls.TLSConn, error) {
	return tls.Dial(addr, port, sni)
}

type tlsSource struct{ c *tls.TLSConn }

func (s tlsSource) Read(p []byte) (int, error) { return s.c.Read(p) }

func httpsGetOn(c *tls.TLSConn, sni, path string) ([]byte, error) {
	host := sni
	if host == "" {
		host = "localhost"
	}
	req := httpc.GetRequest(host, path, "")
	if _, err := c.Write([]byte(req)); err != nil {
		return nil, err
	}
	_, _, body, _, _, rerr := httpc.ReadResponse(tlsSource{c}, fetchPolicy)
	if rerr != "" {
		return nil, errStr(rerr)
	}
	return body, nil
}
