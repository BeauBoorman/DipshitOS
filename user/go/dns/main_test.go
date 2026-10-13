package main

import (
	"testing"

	"virelai/vi"
)

func TestParseArgs(t *testing.T) {
	cases := []struct {
		name       string
		args       []string
		wantHost   string
		wantServer [4]byte
		wantQtype  uint16
		twice      bool
		gap        uint64
		ok, help   bool
	}{
		{"image argv and default server", []string{"GODNS.ELF", "example.com"}, "example.com", [4]byte{10, 0, 0, 2}, vi.DNSQueryA, false, 0, true, false},
		{"explicit server", []string{"example.com", "1.1.1.1"}, "example.com", [4]byte{1, 1, 1, 1}, vi.DNSQueryA, false, 0, true, false},
		{"aaaa flag", []string{"-6", "example.com"}, "example.com", [4]byte{10, 0, 0, 2}, vi.DNSQueryAAAA, false, 0, true, false},
		{"aaaa long flag with server", []string{"--aaaa", "example.com", "10.0.0.2"}, "example.com", [4]byte{10, 0, 0, 2}, vi.DNSQueryAAAA, false, 0, true, false},
		{"twice for cache leg", []string{"--twice", "example.com"}, "example.com", [4]byte{10, 0, 0, 2}, vi.DNSQueryA, true, 0, true, false},
		{"gap for expiry leg", []string{"--twice", "--gap", "6", "example.com"}, "example.com", [4]byte{10, 0, 0, 2}, vi.DNSQueryA, true, 6, true, false},
		{"empty help", nil, "", [4]byte{}, 0, false, 0, true, true},
		{"flag help", []string{"--help"}, "", [4]byte{}, 0, false, 0, true, true},
		{"bad resolver", []string{"example.com", "nope"}, "", [4]byte{}, 0, false, 0, false, false},
		{"extra argument", []string{"example.com", "10.0.0.2", "extra"}, "", [4]byte{}, 0, false, 0, false, false},
		{"gap missing value", []string{"--gap"}, "", [4]byte{}, 0, false, 0, false, false},
		{"gap not a number", []string{"--gap", "x", "example.com"}, "", [4]byte{}, 0, false, 0, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := parseArgs(tc.args)
			if ok != tc.ok || got.help != tc.help {
				t.Fatalf("parseArgs(%v) = (%+v,%v)", tc.args, got, ok)
			}
			if !ok {
				return
			}
			if got.host != tc.wantHost || got.server != tc.wantServer ||
				got.qtype != tc.wantQtype || got.twice != tc.twice || got.gap != tc.gap {
				t.Fatalf("parseArgs(%v) = %+v", tc.args, got)
			}
		})
	}
}

func TestAddrString(t *testing.T) {
	if got := addrString(vi.DNSAddr{IPv4: [4]byte{93, 184, 216, 34}}); got != "93.184.216.34" {
		t.Fatalf("v4 = %q", got)
	}
	var v6 vi.DNSAddr
	v6.V6 = true
	v6.IPv6 = [16]byte{0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
	if got := addrString(v6); got != "2001:0db8:0000:0000:0000:0000:0000:0001" {
		t.Fatalf("v6 = %q", got)
	}
}
