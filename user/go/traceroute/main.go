// Command traceroute is GOTRACEROUTE.ELF, the M78a Go replacement for
// TRACEROUTE.BIN. The frozen ICMP syscall reports echo replies only; it has
// no TTL control or ICMP time-exceeded payload, so this command is a bounded
// peer reachability diagnostic, not a route-discovery implementation.
package main

import (
	"virelai/vi"
	"virelai/vsys"
)

const (
	appName         = "GOTRACEROUTE.ELF"
	defaultTarget   = "10.0.0.2"
	defaultAttempts = 16
	defaultProbes   = 3
	maxAttemptLimit = 64
	maxProbeCount   = 5
	pollLimit       = 50
)

type traceArgs struct {
	ip          [4]byte
	ipText      string
	maxAttempts int
	probes      int
	help        bool
}

func cliArgs(raw []string) []string {
	if len(raw) > 0 && raw[0] == appName {
		return raw[1:]
	}
	return raw
}

func parsePositive(s string, limit int) (int, bool) {
	if s == "" {
		return 0, false
	}
	n := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
		if n > limit {
			return 0, false
		}
	}
	return n, n > 0
}

func parseArgs(raw []string) (traceArgs, bool) {
	args := cliArgs(raw)
	cfg := traceArgs{maxAttempts: defaultAttempts, probes: defaultProbes}
	if len(args) == 1 && (args[0] == "-h" || args[0] == "--help") {
		cfg.help = true
		return cfg, true
	}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-h", "--help":
			return traceArgs{}, false
		case "-m", "-q":
			if i+1 >= len(args) {
				return traceArgs{}, false
			}
			limit, which := maxAttemptLimit, &cfg.maxAttempts
			if args[i] == "-q" {
				limit, which = maxProbeCount, &cfg.probes
			}
			n, ok := parsePositive(args[i+1], limit)
			if !ok {
				return traceArgs{}, false
			}
			*which = n
			i++
		default:
			if cfg.ipText != "" {
				return traceArgs{}, false
			}
			ip, err := vsys.ParseIPv4(args[i])
			if err != nil {
				return traceArgs{}, false
			}
			cfg.ip, cfg.ipText = ip, args[i]
		}
	}
	if cfg.ipText == "" {
		ip, _ := vsys.ParseIPv4(defaultTarget)
		cfg.ip, cfg.ipText = ip, defaultTarget
	}
	return cfg, true
}

func usage() {
	vi.Console("GOTRACEROUTE.ELF - bounded ICMP echo reachability probe\n" +
		"usage: exec GOTRACEROUTE.ELF [-m max_attempts] [-q probes] [<ip>]\n" +
		"       exec GOTRACEROUTE.ELF -h   show this help\n" +
		"default target: 10.0.0.2; max_attempts: 16; probes: 3\n" +
		"note: current ICMP syscall reports echo replies only; intermediate hops are unavailable\n")
}

func probe(target [4]byte) (uint32, bool) {
	before := vi.PingPoll()
	if err := vi.PingSend(target); err != nil {
		return 0, false
	}
	for polls := 0; polls < pollLimit; polls++ {
		seq := vi.PingPoll()
		if seq != 0 && seq != before {
			return uint32(polls + 1), true
		}
		vi.Yield()
	}
	return 0, false
}

func run(cfg traceArgs) bool {
	vi.ConsoleLine("traceroute: starting")
	vi.ConsoleLine("traceroute: limitation: current ICMP syscall reports echo replies only; intermediate hops are unavailable")
	vi.ConsoleLine("ICMP echo reachability probe to " + cfg.ipText + " (" + cfg.ipText + "), max " + vi.Itoa64(int64(cfg.maxAttempts)) + " attempts")
	for attempt := 1; attempt <= cfg.maxAttempts; attempt++ {
		answered := false
		var best uint32
		for q := 0; q < cfg.probes; q++ {
			rtt, ok := probe(cfg.ip)
			if ok && (!answered || rtt < best) {
				answered, best = true, rtt
			}
		}
		if answered {
			vi.ConsoleLine("attempt " + vi.Itoa64(int64(attempt)) + "  echo reply from " + cfg.ipText + "  " + vi.Itoa64(int64(best)) + " ms")
			vi.ConsoleLine("traceroute: peer responded " + cfg.ipText + " after " + vi.Itoa64(int64(attempt)) + " attempt(s)")
			vi.ConsoleLine("traceroute: complete")
			return true
		}
		vi.ConsoleLine("attempt " + vi.Itoa64(int64(attempt)) + "  no echo reply")
	}
	vi.ConsoleLine("traceroute: no echo response from " + cfg.ipText + " after " + vi.Itoa64(int64(cfg.maxAttempts)) + " attempt(s)")
	vi.ConsoleLine("traceroute: complete")
	return false
}

func main() {
	cfg, ok := parseArgs(vi.Args())
	if !ok {
		vi.Console("traceroute: usage: exec GOTRACEROUTE.ELF [-m max_attempts] [-q probes] [<ip>]\n")
		vi.Exit(2)
	}
	if cfg.help {
		usage()
		vi.Exit(0)
	}
	switch verdict, _ := vi.NetPreflight(cfg.ip); verdict {
	case vi.NetOfflineNoIP, vi.NetNoRoute:
		vi.Console(vi.NetDiagnosisMessage("traceroute", verdict, cfg.ip))
		vi.Exit(2)
	}
	if run(cfg) {
		vi.Exit(0)
	}
	vi.Exit(1)
}
