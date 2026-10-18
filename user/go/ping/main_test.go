package main

import "testing"

func TestParseCount(t *testing.T) {
	for _, ok := range []string{"1", "5", "100"} {
		if n, good := parseCount(ok); !good || n != atoi(ok) {
			t.Fatalf("parseCount(%q) = (%d,%v)", ok, n, good)
		}
	}
	for _, bad := range []string{"", "0", "101", "-1", "1x", "abc", " 5"} {
		if n, good := parseCount(bad); good {
			t.Fatalf("parseCount(%q) = (%d,true), want refusal", bad, n)
		}
	}
	if n, _ := parseCount("100"); n != 100 {
		t.Fatalf("parseCount(100) = %d", n)
	}
}

func atoi(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		n = n*10 + int(s[i]-'0')
	}
	return n
}

func TestParseArgsDefaults(t *testing.T) {
	a, ok, help := parseArgs([]string{"10.0.0.2"}, false)
	if !ok || help {
		t.Fatalf("parseArgs ok=%v help=%v", ok, help)
	}
	if a.Count != defaultCount || a.IPStr != "10.0.0.2" || a.IP != [4]byte{10, 0, 0, 2} {
		t.Fatalf("parseArgs = %+v", a)
	}
}

func TestParseArgsCount(t *testing.T) {
	a, ok, _ := parseArgs([]string{"-c", "3", "10.0.0.2"}, false)
	if !ok || a.Count != 3 {
		t.Fatalf("parseArgs -c 3 = (%+v,%v)", a, ok)
	}
	if _, ok, _ := parseArgs([]string{"-c", "0", "10.0.0.2"}, false); ok {
		t.Fatal("-c 0 must be a usage error")
	}
	if _, ok, _ := parseArgs([]string{"-c", "101", "10.0.0.2"}, false); ok {
		t.Fatal("-c 101 must be a usage error")
	}
	if _, ok, _ := parseArgs([]string{"-c"}, false); ok {
		t.Fatal("-c with no value must be a usage error")
	}
}

func TestParseArgsHelp(t *testing.T) {
	for _, flag := range []string{"-h", "--help"} {
		if _, ok, help := parseArgs([]string{flag}, false); !ok || !help {
			t.Fatalf("parseArgs(%q) ok=%v help=%v, want help", flag, ok, help)
		}
	}
}

func TestParseArgsErrors(t *testing.T) {
	cases := [][]string{
		{},
		{"10.0.0.2", "extra"},
		{"not-an-ip"},
		{"10.0.0"},
		{"10.0.0.256"},
	}
	for _, c := range cases {
		if _, ok, help := parseArgs(c, false); ok || help {
			t.Fatalf("parseArgs(%v) accepted", c)
		}
	}
}

// M117c (#2475): the v6 literal selects the ping6 path — bare or
// bracketed — and GOPING6's argv[0] forces it.
func TestParseArgsV6(t *testing.T) {
	a, ok, _ := parseArgs([]string{"fe80::2"}, false)
	if !ok || !a.V6 {
		t.Fatalf("parseArgs bare v6 = (%+v,%v)", a, ok)
	}
	want := [16]byte{0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02}
	if a.IP6 != want {
		t.Fatalf("IP6 = %v, want fe80::2", a.IP6)
	}
	a, ok, _ = parseArgs([]string{"-c", "2", "[2001:db8:64::2]"}, false)
	if !ok || !a.V6 || a.Count != 2 || a.IPStr != "[2001:db8:64::2]" {
		t.Fatalf("parseArgs bracketed v6 = (%+v,%v)", a, ok)
	}
	// force6 (GOPING6 argv[0]): a bare literal that is not a v4 quad.
	a, ok, _ = parseArgs([]string{"fd00::64:1"}, true)
	if !ok || !a.V6 {
		t.Fatalf("parseArgs force6 = (%+v,%v)", a, ok)
	}
	// A malformed v6 literal is a usage error, never a v4 DNS name.
	if _, ok, _ := parseArgs([]string{"fe80:::"}, false); ok {
		t.Fatal("malformed v6 literal accepted")
	}
}

func TestCliArgsV6(t *testing.T) {
	// A bare v6 literal is an argument, not the image name.
	got, f6 := cliArgs([]string{"fe80::2"})
	if len(got) != 1 || f6 {
		t.Fatalf("cliArgs bare v6 = %v f6=%v", got, f6)
	}
	// GOPING6.ELF as argv[0] is the image name AND the v6 selector.
	got, f6 = cliArgs([]string{"GOPING6.ELF", "fe80::2"})
	if len(got) != 1 || got[0] != "fe80::2" || !f6 {
		t.Fatalf("cliArgs GOPING6 = %v f6=%v", got, f6)
	}
}

// TestCliArgsDropsImageName pins the argv[0] rule: the kernel's ELF gap path
// prepends the image name, and a raw argument list must not be mangled.
func TestCliArgsDropsImageName(t *testing.T) {
	got, _ := cliArgs([]string{"GOPING.ELF", "-c", "3", "10.0.0.2"})
	if len(got) != 3 || got[0] != "-c" {
		t.Fatalf("cliArgs with image name = %v", got)
	}
	// No image name (the flat path): the arguments are already clean.
	got, _ = cliArgs([]string{"-c", "3", "10.0.0.2"})
	if len(got) != 3 || got[0] != "-c" {
		t.Fatalf("cliArgs without image name = %v", got)
	}
	got, _ = cliArgs([]string{"10.0.0.2"})
	if len(got) != 1 || got[0] != "10.0.0.2" {
		t.Fatalf("cliArgs bare IP = %v", got)
	}
	if got, _ := cliArgs(nil); got != nil {
		t.Fatalf("cliArgs(nil) = %v", got)
	}
}

func TestStats(t *testing.T) {
	var s Stats
	s.record(10)
	s.record(20)
	s.record(30)
	if s.Sent != 3 || s.Received != 3 {
		t.Fatalf("counts: %+v", s)
	}
	if s.min() != 10 || s.max() != 30 || s.avgMS() != 20 || s.lossPercent() != 0 {
		t.Fatalf("stats: min=%d max=%d avg=%d loss=%d", s.min(), s.max(), s.avgMS(), s.lossPercent())
	}
	s.recordLoss()
	if s.Sent != 4 || s.Received != 3 {
		t.Fatalf("after loss: %+v", s)
	}
	if s.lossPercent() != 25 {
		t.Fatalf("loss = %d, want 25", s.lossPercent())
	}
}

// TestStatsEmpty pins the zero-reply shape: no min/max before any sample.
func TestStatsEmpty(t *testing.T) {
	var s Stats
	if s.min() != 0 || s.max() != 0 || s.avgMS() != 0 || s.lossPercent() != 0 {
		t.Fatalf("empty stats: min=%d max=%d avg=%d loss=%d",
			s.min(), s.max(), s.avgMS(), s.lossPercent())
	}
	s.recordLoss()
	if s.lossPercent() != 100 {
		t.Fatalf("all-lost loss = %d, want 100", s.lossPercent())
	}
}
