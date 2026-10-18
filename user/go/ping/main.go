// Command ping is the M71n (issue #1573) Go successor to the Zig PING.BIN.
//
// It is the same ICMP story on the same syscall seam — slot 59
// `sys_ping_send` / slot 60 `sys_ping_poll` through virelai/vi — with the
// same CLI, the same grep-able markers and the same 0/1/2/3 exit contract,
// so tools/gate/specs/live-n1-ping.spec and live-net-offline.spec moved to
// it by binary name and nothing else. PING.BIN and user/src/ping.zig are
// deleted by that card (D2: ping is the one Zig net CLI this card retires).
//
// CLI: `exec GOPING.ELF [-c count] <a.b.c.d>` — and, since M117c (#2475),
// `exec GOPING.ELF [-c count] <v6-addr>` or `exec GOPING6.ELF ...`
// (GOSH links GOPING6.ELF to the same image): a v6 literal — bare `x::y`
// or bracketed — selects the ICMPv6 half (`vi.Ping6Send`/`Ping6Poll`, the
// tagged marshal on slots 59/60).
//
//	-c count: number of pings, 1..100 (default 5)
//	<a.b.c.d>: dotted IPv4 address; <v6-addr> a v6 literal
//	`exec GOPING.ELF -h` prints help
//
// Output shape (grep-able by the two specs):
//
//	PING 10.0.0.2 (10.0.0.2): 56 data bytes
//	64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=1 ms
//	...
//	--- 10.0.0.2 ping statistics ---
//	5 packets transmitted, 5 packets received, 0% packet loss
//	round-trip min/avg/max = 1/1/1 ms
//
// Exit statuses: 0 ok, 1 usage, 2 offline (no IP — net ip / net dhcp),
// 3 no route (net arp <a.b.c.d> first). 2 and 3 come from the N13/N14
// preflight (virelai/vi NetPreflight, the Go twin of
// user/src/lib/netstatus.zig) and exit FAST — no statistics footer.
//
// No window, no heap growth beyond the runtime's own: this is the console
// program the shell's `exec` verb runs, on the default seat, exactly as the
// monitor used to run PING.BIN.
package main

import (
	"virelai/vi"
	"virelai/vsys"
)

const (
	defaultCount = 5
	maxCount     = 100

	exitOK      = 0
	exitUsage   = 1
	exitOffline = 2
	exitNoRoute = 3
)

// ---------------------------------------------------------------------------
// Pure logic — host-testable
// ---------------------------------------------------------------------------

// Stats accumulates one run's sent/received counts and RTT samples.
type Stats struct {
	Sent     uint32
	Received uint32
	minMS    uint32
	maxMS    uint32
	sumMS    uint64
}

func (s *Stats) record(ms uint32) {
	s.Sent++
	s.Received++
	if s.Received == 1 || ms < s.minMS {
		s.minMS = ms
	}
	if ms > s.maxMS {
		s.maxMS = ms
	}
	s.sumMS += uint64(ms)
}

func (s *Stats) recordLoss() { s.Sent++ }

func (s *Stats) lossPercent() uint32 {
	if s.Sent == 0 {
		return 0
	}
	return (s.Sent - s.Received) * 100 / s.Sent
}

func (s *Stats) avgMS() uint32 {
	if s.Received == 0 {
		return 0
	}
	return uint32(s.sumMS / uint64(s.Received))
}

func (s *Stats) min() uint32 {
	if s.Received == 0 {
		return 0
	}
	return s.minMS
}

func (s *Stats) max() uint32 {
	if s.Received == 0 {
		return 0
	}
	return s.maxMS
}

// pingArgs is one parsed command line.
type pingArgs struct {
	IP    [4]byte
	IP6   [16]byte // the v6 literal (V6 only)
	IPStr string
	Count int
	V6    bool // M117c (#2475): the literal was v6 — Ping6Send/Ping6Poll
}

// isIPv4Literal reports whether s parses as a dotted quad (the guard that
// lets cliArgs tell the image name from the IPv4 positional).
func isIPv4Literal(s string) bool {
	_, err := vsys.ParseIPv4(s)
	return err == nil
}

// looksLikeAddress covers argv[0] detection for BOTH families — a bare or
// bracketed v6 literal must not be mistaken for the image name.
func looksLikeAddress(s string) bool {
	if vi.IsV6Literal(s) {
		_, err := vi.ParseIPv6(s)
		return err == nil
	}
	return isIPv4Literal(s)
}

// cliArgs returns the real arguments, dropping argv[0] when it is the image
// name. The kernel's ELF gap path prepends the image name (kernel/src/exec.zig
// exec_static_elf_gap: "Go's os.Args[0] is the program name"), while the
// older flat path does not, so the name is dropped only when it does not
// already look like an argument — the same rule GOSH's own argv handling
// uses. M117c: `GOPING6` / `GOPING6.ELF` as argv[0] is ALSO the v6 selector
// — it is dropped AND returned as the forced family.
func cliArgs(raw []string) (args []string, force6 bool) {
	if len(raw) == 0 {
		return nil, false
	}
	switch first := raw[0]; {
	case first == "-c" || first == "-h" || first == "--help":
		return raw, false
	case looksLikeAddress(first):
		return raw, false
	case first == "GOPING6" || first == "GOPING6.ELF" || first == "ping6":
		return raw[1:], true
	}
	return raw[1:], false
}

// parseArgs parses `[-c count] <addr>` where addr is a dotted quad, a bare
// v6 literal, or a bracketed one ([x::y]). ok is false on any usage error;
// help is true when -h/--help was named. force6 (the GOPING6 image name)
// makes a bare literal REQUIRE the v6 parse.
func parseArgs(args []string, force6 bool) (a pingArgs, ok bool, help bool) {
	a.Count = defaultCount
	i := 0
	if i < len(args) && args[i] == "-c" {
		if i+1 >= len(args) {
			return pingArgs{}, false, false
		}
		n, good := parseCount(args[i+1])
		if !good {
			return pingArgs{}, false, false
		}
		a.Count = n
		i += 2
	}
	for ; i < len(args); i++ {
		if args[i] == "-h" || args[i] == "--help" {
			return pingArgs{}, true, true
		}
		if a.IPStr != "" {
			return pingArgs{}, false, false
		}
		if force6 || vi.IsV6Literal(args[i]) {
			addr, err := vi.ParseIPv6(args[i])
			if err != nil {
				return pingArgs{}, false, false
			}
			a.IP6 = addr
			a.V6 = true
		} else {
			ip, err := vsys.ParseIPv4(args[i])
			if err != nil {
				return pingArgs{}, false, false
			}
			a.IP = ip
		}
		a.IPStr = args[i]
	}
	if a.IPStr == "" {
		return pingArgs{}, false, false
	}
	return a, true, false
}

// parseCount parses the -c bound: 1..100 (0 and above 100 are usage errors,
// as in the Zig original).
func parseCount(s string) (int, bool) {
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
		if n > maxCount {
			return 0, false
		}
	}
	if n < 1 {
		return 0, false
	}
	return n, true
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

func printHelp() {
	vi.Console("GOPING.ELF - VirelaiOS ICMP ping (M71n)\n" +
		"usage: exec GOPING.ELF [-c count] <a.b.c.d>\n" +
		"       exec GOPING.ELF -h   show this help\n" +
		"       exec GOPING6.ELF [-c count] <v6-addr>  ICMPv6 echo (M117c)\n" +
		"  -c count  number of pings, 1..100 (default 5)\n" +
		"exit statuses: 0 ok, 1 usage, 2 offline (no IP - net ip/net dhcp),\n" +
		"               3 no route (net arp <a.b.c.d> first)\n" +
		"example: exec GOPING.ELF -c 5 10.0.0.2\n")
}

func main() {
	args, force6 := cliArgs(vi.Args())
	if len(args) == 0 {
		printHelp()
		vi.Exit(exitOK)
	}
	cfg, ok, help := parseArgs(args, force6)
	if help {
		printHelp()
		vi.Exit(exitOK)
	}
	if !ok {
		vi.Console("ping: usage: exec GOPING.ELF [-c count] <a.b.c.d>\n")
		vi.Exit(exitUsage)
	}

	// N13/N14 preflight: one sys_net_stats snapshot before the first send.
	// Offline / no-route exit FAST with the human message instead of burning
	// the per-ping bounded poll. A refused snapshot is NetUnknown, which
	// keeps the legacy path rather than inventing a verdict. M117c: the v6
	// half has no preflight verdict — Ping6Send's named refusal (bad_dst6 /
	// no_src6 / no_route6 / no_peer → EINVAL) is the honest answer instead.
	if !cfg.V6 {
		switch verdict, _ := vi.NetPreflight(cfg.IP); verdict {
		case vi.NetOfflineNoIP:
			vi.Console(vi.NetDiagnosisMessage("ping", verdict, cfg.IP))
			vi.Exit(exitOffline)
		case vi.NetNoRoute:
			vi.Console(vi.NetDiagnosisMessage("ping", verdict, cfg.IP))
			vi.Exit(exitNoRoute)
		}
	}

	runPing(cfg)
	vi.Exit(exitOK)
}

func runPing(cfg pingArgs) {
	// Header
	if cfg.V6 {
		vi.Console("PING6 " + cfg.IPStr + " (" + cfg.IPStr + "): 56 data bytes\n")
	} else {
		vi.Console("PING " + cfg.IPStr + " (" + cfg.IPStr + "): 56 data bytes\n")
	}

	var stats Stats
	for seq := 1; seq <= cfg.Count; seq++ {
		// The poll sequence is read BEFORE the send so a stale reply from the
		// previous sequence cannot be mistaken for this one's.
		var prev uint64
		if cfg.V6 {
			prev = vi.Ping6Poll()
		} else {
			prev = vi.PingPoll()
		}
		var err error
		if cfg.V6 {
			err = vi.Ping6Send(cfg.IP6)
		} else {
			err = vi.PingSend(cfg.IP)
		}
		if err != nil {
			// Send refused — peer not in ARP/NDP, no source address, or no
			// device. Honest loss, not a fabricated reply.
			vi.Console("ping: send to " + cfg.IPStr + " failed (" + err.Error() + ")\n")
			stats.recordLoss()
			if seq < cfg.Count {
				vi.Sleep(1)
			}
			continue
		}
		got := false
		var rtt uint32
		for polls := 0; polls < 200; polls++ {
			var p uint64
			if cfg.V6 {
				p = vi.Ping6Poll()
			} else {
				p = vi.PingPoll()
			}
			if p != 0 && p != prev {
				got = true
				rtt = uint32(polls + 1)
				break
			}
			vi.Yield()
		}
		if !got {
			stats.recordLoss()
			vi.Console("no answer from " + cfg.IPStr + ": icmp_seq=" + vsys.Itoa64(int64(seq)) + "\n")
			if seq < cfg.Count {
				vi.Sleep(1)
			}
			continue
		}
		stats.record(rtt)
		seqToken := "icmp_seq="
		if cfg.V6 {
			seqToken = "icmp6_seq="
		}
		vi.Console("64 bytes from " + cfg.IPStr + ": " + seqToken + vsys.Itoa64(int64(seq)) +
			" ttl=64 time=" + vsys.Itoa64(int64(rtt)) + " ms\n")
		if seq < cfg.Count {
			vi.Sleep(1)
		}
	}

	// Footer — statistics
	vi.Console("--- " + cfg.IPStr + " ping statistics ---\n")
	vi.Console(vsys.Itoa64(int64(stats.Sent)) + " packets transmitted, " +
		vsys.Itoa64(int64(stats.Received)) + " packets received, " +
		vsys.Itoa64(int64(stats.lossPercent())) + "% packet loss\n")
	vi.Console("round-trip min/avg/max = " + vsys.Itoa64(int64(stats.min())) + "/" +
		vsys.Itoa64(int64(stats.avgMS())) + "/" + vsys.Itoa64(int64(stats.max())) + " ms\n")
}
