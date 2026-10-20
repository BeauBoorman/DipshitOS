package main

// The guest transport: tls.Dial on 6697 (the only path a real network
// should take), plaintext vi.Dial only when the session config's
// AllowPlain consent bit is set — the card's rule, enforced HERE at the
// dial boundary so no caller path can bypass it. Both transports adapt
// onto WireConn (vi.Conn's Send/Recv + relative deadline, TLSConn's
// Read/Write + absolute deadline).

import (
	"virelai/tls"
	"virelai/vi"
)

// errPlainRefused is the named refusal a plaintext request without
// AllowPlain gets — the gate and the UI both match this string.
const errPlainRefused = "goirc: refuse plaintext — pass --plain only when the server has no TLS"

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

// dialGuest is the production Dialer: TLS via tls.Dial with ServerName
// (or the host when unset), plaintext via vi.Dial only under AllowPlain.
func dialGuest(cfg Config) Dialer {
	return func() (WireConn, error) {
		if cfg.TLS {
			name := cfg.ServerName
			if name == "" {
				name = cfg.Host
			}
			c, err := tls.Dial(cfg.Host, cfg.Port, name)
			if err != nil {
				return nil, err
			}
			return tlsDial{c: c}, nil
		}
		if !cfg.AllowPlain {
			return nil, fatalError{err: ircError(errPlainRefused)}
		}
		c, err := vi.Dial(cfg.Host, cfg.Port)
		if err != nil {
			return nil, err
		}
		return plainDial{c: c}, nil
	}
}

// sleepNs parks the caller until the vi.Nanos deadline — the reconnect
// backoff's guest clock. Tests inject their own sleep.
func sleepNs(ns int64) {
	deadline := vi.Nanos() + ns
	for i := 0; i < 360000; i++ {
		if vi.Nanos() >= deadline {
			return
		}
		vi.Sleep(1)
	}
}
