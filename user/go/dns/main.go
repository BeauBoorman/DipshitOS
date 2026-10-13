// Command dns is GODNS.ELF, the M78a Go replacement for DNS.BIN.
// RFC 1035 framing, UDP bounds, resolver deadlines, and refusal behavior are
// provided by the existing guest Go network layer (vi.Resolve, M99i).
package main

import (
	"virelai/vi"
	"virelai/vsys"
)

const (
	appName     = "GODNS.ELF"
	dnsPort     = 53
	exitOK      = 0
	exitUsage   = 2
	exitFailure = 1
)

// Preserve space for the kernel's fixed argv/envp block in the writable
// segment so the guest Go runtime can initialize its heap.
var argvEnvpGuard [0x1000]byte

type dnsArgs struct {
	host   string
	server [4]byte
	qtype  uint16
	twice  bool // resolve twice in-process: exercises the TTL cache
	gap    uint64
	help   bool
}

func cliArgs(raw []string) []string {
	if len(raw) > 0 && raw[0] == appName {
		return raw[1:]
	}
	return raw
}

// parseArgs walks flags first, then the positional host and optional
// server — `GODNS.ELF -6 --twice example.com 10.0.0.2`.
func parseArgs(raw []string) (dnsArgs, bool) {
	args := cliArgs(raw)
	cfg := dnsArgs{qtype: vi.DNSQueryA}
	var pos []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-h", "--help":
			return dnsArgs{help: true}, true
		case "-6", "--aaaa":
			cfg.qtype = vi.DNSQueryAAAA
		case "--twice":
			cfg.twice = true
		case "--gap":
			if i+1 >= len(args) || !parseUint(args[i+1], &cfg.gap) {
				return dnsArgs{}, false
			}
			i++
		default:
			pos = append(pos, args[i])
		}
	}
	if len(pos) == 0 {
		return dnsArgs{help: true}, true
	}
	if len(pos) > 2 {
		return dnsArgs{}, false
	}
	cfg.host = pos[0]
	cfg.server = vi.DefaultDNSServer
	if len(pos) == 2 {
		parsed, err := vsys.ParseIPv4(pos[1])
		if err != nil {
			return dnsArgs{}, false
		}
		cfg.server = parsed
	}
	return cfg, true
}

func parseUint(s string, out *uint64) bool {
	if s == "" {
		return false
	}
	var v uint64
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
		v = v*10 + uint64(s[i]-'0')
	}
	*out = v
	return true
}

func usage() {
	vi.Console("GODNS.ELF - VirelaiOS DNS query (A and AAAA)\n" +
		"usage: exec GODNS.ELF [-6|--aaaa] [--twice] [--gap <ticks>] <hostname> [<server_ip>]\n" +
		"       exec GODNS.ELF -h   show this help\n" +
		"example: exec GODNS.ELF example.com 10.0.0.2\n")
}

func typeName(qtype uint16) string {
	if qtype == vi.DNSQueryAAAA {
		return "AAAA"
	}
	return "A"
}

func addrString(a vi.DNSAddr) string {
	if a.V6 {
		var out string
		for i := 0; i < 16; i += 2 {
			if i > 0 {
				out += ":"
			}
			const hexd = "0123456789abcdef"
			w := uint16(a.IPv6[i])<<8 | uint16(a.IPv6[i+1])
			out += string([]byte{hexd[w>>12&0xf], hexd[w>>8&0xf], hexd[w>>4&0xf], hexd[w&0xf]})
		}
		return out
	}
	return vi.FormatIPv4(a.IPv4)
}

// report prints one line per usable address; the first carries the
// transaction's metadata (TTL, answers walked, ignored datagrams, cache).
func report(host string, r vi.DNSResult) {
	for i, a := range r.Addrs {
		if i == 0 {
			line := "Answer: " + host + " -> " + addrString(a) +
				" (ttl=" + itoa(r.TTLNs/1_000_000_000) + "s answers=" + itoa(int64(r.Answers)) +
				" ignored=" + itoa(int64(r.Ignored))
			if r.Cached {
				line += " cached"
			}
			vi.ConsoleLine(line + ")")
		} else {
			vi.ConsoleLine("Answer: " + host + " -> " + addrString(a))
		}
	}
}

func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}

func main() {
	argvEnvpGuard[0] = 1
	cfg, ok := parseArgs(vi.Args())
	if !ok {
		vi.Console("dns: usage: exec GODNS.ELF [-6|--aaaa] [--twice] [--gap <ticks>] <hostname> [<server_ip>]\n")
		vi.Exit(exitUsage)
	}
	if cfg.help {
		usage()
		vi.Exit(exitOK)
	}
	server := vi.FormatIPv4(cfg.server)
	vi.ConsoleLine("DNS query for " + cfg.host + " (" + typeName(cfg.qtype) + ") via " + server + ":53")
	r, err := vi.Resolve(cfg.host, cfg.server, cfg.qtype, 0)
	if err != nil {
		vi.ConsoleLine("dns: error: " + err.Error())
		vi.ConsoleLine("dns: status=err")
		vi.Exit(exitFailure)
	}
	report(cfg.host, r)
	if cfg.twice {
		if cfg.gap > 0 {
			vi.Sleep(cfg.gap)
		}
		r2, err := vi.Resolve(cfg.host, cfg.server, cfg.qtype, 0)
		if err != nil {
			vi.ConsoleLine("dns: error: " + err.Error())
			vi.ConsoleLine("dns: status=err")
			vi.Exit(exitFailure)
		}
		report(cfg.host, r2)
	}
	vi.ConsoleLine("dns: status=ok")
	vi.Exit(exitOK)
}
