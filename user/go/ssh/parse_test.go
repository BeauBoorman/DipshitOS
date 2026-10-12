package main

import (
	"strings"
	"testing"
)

// parseTarget table beyond cli_test.go's floor: every field combination and
// every bound the parser declares (user ≤64, host numeric IPv4, port
// 1–65535, cmd ≤512 joined by spaces).
func TestParseTargetTable(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want target
		ok   bool
	}{
		{"host only", []string{"10.0.0.2"}, target{user: "virelai", host: "10.0.0.2", port: 22}, true},
		{"user@host", []string{"alice@10.0.0.2"}, target{user: "alice", host: "10.0.0.2", port: 22}, true},
		{"host:port", []string{"10.0.0.2:2222"}, target{user: "virelai", host: "10.0.0.2", port: 2222}, true},
		{"full", []string{"bob@192.168.64.3:2200", "id"}, target{user: "bob", host: "192.168.64.3", port: 2200, cmd: "id"}, true},
		{"port max", []string{"10.0.0.2:65535"}, target{user: "virelai", host: "10.0.0.2", port: 65535}, true},
		{"port leading zeros", []string{"10.0.0.2:022"}, target{user: "virelai", host: "10.0.0.2", port: 22}, true},
		{"ipv4 leading zeros", []string{"010.0.0.1"}, target{user: "virelai", host: "010.0.0.1", port: 22}, true}, // observed: parsed as decimal
		{"ipv4 zeros", []string{"0.0.0.0"}, target{user: "virelai", host: "0.0.0.0", port: 22}, true},
		{"ipv4 max", []string{"255.255.255.255"}, target{user: "virelai", host: "255.255.255.255", port: 22}, true},
		{"user 64 chars", []string{strings.Repeat("u", 64) + "@10.0.0.2"}, target{user: strings.Repeat("u", 64), host: "10.0.0.2", port: 22}, true},
		{"cmd joins args", []string{"10.0.0.2", "echo", "a", "b"}, target{user: "virelai", host: "10.0.0.2", port: 22, cmd: "echo a b"}, true},
		{"cmd 512 chars", []string{"10.0.0.2", strings.Repeat("c", 512)}, target{user: "virelai", host: "10.0.0.2", port: 22, cmd: strings.Repeat("c", 512)}, true},

		{"no args", nil, target{}, false},
		{"empty target", []string{""}, target{}, false},
		{"empty user", []string{"@10.0.0.2"}, target{}, false},
		{"user 65 chars", []string{strings.Repeat("u", 65) + "@10.0.0.2"}, target{}, false},
		{"empty host", []string{"alice@"}, target{}, false},
		{"empty host with port", []string{"alice@:22"}, target{}, false},
		{"host empty before port", []string{":22"}, target{}, false},
		{"double @", []string{"a@b@10.0.0.2"}, target{}, false}, // host "b@10.0.0.2" is not IPv4
		{"empty port", []string{"10.0.0.2:"}, target{}, false},
		{"port 0", []string{"10.0.0.2:0"}, target{}, false},
		{"port 65536", []string{"10.0.0.2:65536"}, target{}, false},
		{"port 6 digits", []string{"10.0.0.2:123456"}, target{}, false},
		{"port non-numeric", []string{"10.0.0.2:ssh"}, target{}, false},
		{"port double colon", []string{"10.0.0.2:22:33"}, target{}, false},
		{"ipv4 3 octets", []string{"10.0.0"}, target{}, false},
		{"ipv4 5 octets", []string{"1.2.3.4.5"}, target{}, false},
		{"ipv4 octet 256", []string{"256.0.0.1"}, target{}, false},
		{"ipv4 empty octet", []string{"10..0.2"}, target{}, false},
		{"ipv4 trailing dot", []string{"10.0.0.2."}, target{}, false},
		{"ipv4 alpha", []string{"10.0.0.x"}, target{}, false},
		{"ipv4 4-digit octet", []string{"1234.0.0.1"}, target{}, false},
		{"hostname", []string{"host.example"}, target{}, false},
		{"ipv6", []string{"::1"}, target{}, false},
		{"ipv6 bracket", []string{"[::1]:22"}, target{}, false},
		{"cmd 513 chars", []string{"10.0.0.2", strings.Repeat("c", 513)}, target{}, false},
		{"cmd 512 joined over bound", []string{"10.0.0.2", strings.Repeat("c", 300), strings.Repeat("d", 300)}, target{}, false}, // join = 601 > 512
	}
	for _, tc := range cases {
		got, ok := parseTarget(tc.args)
		if ok != tc.ok {
			t.Fatalf("%s: ok=%v want %v", tc.name, ok, tc.ok)
		}
		if !tc.ok {
			continue
		}
		if got != tc.want {
			t.Fatalf("%s: %+v want %+v", tc.name, got, tc.want)
		}
	}
}
