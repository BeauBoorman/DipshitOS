package main

// The guest transport, same shape as goirc's dial.go: tls.Dial on the
// TLS ports (993/465-style), plaintext vi.Dial only when the session
// config's AllowPlain consent bit is set — enforced HERE at the dial
// boundary so no verb path can bypass it. Both transports adapt onto
// WireConn (vi.Conn's Send/Recv + relative deadline, TLSConn's
// Read/Write + absolute deadline).

import (
	"virelai/tls"
	"virelai/vi"
)

// errPlainRefused is the named refusal a plaintext request without
// AllowPlain gets — the gate and the console both match this string.
const errPlainRefused = "gomail: refuse plaintext — pass --plain only when the server has no TLS"

// WireConn is the byte pipe both protocol clients drive: guest builds
// adapt vi.Conn (Send/Recv, relative recv deadline) and tls.TLSConn
// (Read/Write, absolute deadline) onto this shape; tests inject fakes.
type WireConn interface {
	Read(p []byte) (int, error)
	Write(p []byte) (int, error)
	SetReadDeadline(at int64) // absolute vi.Nanos instant
	Close() error
}

// plainDial adapts *vi.Conn (Send/Recv, relative recv deadline) onto
// WireConn.
type plainDial struct{ c *vi.Conn }

func (p plainDial) Read(b []byte) (int, error)  { return p.c.Recv(b) }
func (p plainDial) Write(b []byte) (int, error) { return p.c.Send(b) }
func (p plainDial) Close() error                { return p.c.Close() }
func (p plainDial) SetReadDeadline(at int64) {
	d := at - vi.Nanos()
	if d < 0 {
		d = 0
	}
	p.c.SetRecvDeadline(d)
}

// tlsDial adapts *tls.TLSConn (Read/Write, absolute deadline) onto
// WireConn.
type tlsDial struct{ c *tls.TLSConn }

func (t tlsDial) Read(b []byte) (int, error)  { return t.c.Read(b) }
func (t tlsDial) Write(b []byte) (int, error) { return t.c.Write(b) }
func (t tlsDial) Close() error                { return t.c.Close() }
func (t tlsDial) SetReadDeadline(at int64)    { t.c.SetDeadline(at) }

// dialOne builds one transport session to host:port. TLS rides tls.Dial
// with ServerName (or the host when unset); plaintext runs ONLY under
// AllowPlain — the session config's stored consent answer.
func dialOne(cfg Config, port uint16) (WireConn, error) {
	if cfg.TLS {
		name := cfg.ServerName
		if name == "" {
			name = cfg.Host
		}
		c, err := tls.Dial(cfg.Host, port, name)
		if err != nil {
			return nil, err
		}
		return tlsDial{c: c}, nil
	}
	if !cfg.AllowPlain {
		return nil, mailError{s: errPlainRefused}
	}
	c, err := vi.Dial(cfg.Host, port)
	if err != nil {
		return nil, err
	}
	return plainDial{c: c}, nil
}
