package main

import "testing"

// Mode selection (main.go): a non-empty cmd is the one-shot exec mode; an
// empty cmd is the interactive shell — which sshlib then refuses without a
// tty (TestClientShellModeNeedsTty). The parse contract is what selects it,
// so it is pinned here.
func TestModeSelectionExecVsShell(t *testing.T) {
	cases := []struct {
		name     string
		args     []string
		wantMode string
	}{
		{"no command → shell", []string{"10.0.0.2"}, "shell"},
		{"empty joined command → shell", []string{"10.0.0.2", ""}, "shell"}, // cmd stays ""
		{"one arg → exec", []string{"10.0.0.2", "id"}, "exec"},
		{"multi arg → exec", []string{"alice@10.0.0.2:2222", "uname", "-a"}, "exec"},
	}
	for _, tc := range cases {
		tgt, ok := parseTarget(tc.args)
		if !ok {
			t.Fatalf("%s: parseTarget refused", tc.name)
		}
		mode := "shell"
		if tgt.cmd != "" {
			mode = "exec"
		}
		if mode != tc.wantMode {
			t.Fatalf("%s: mode=%s cmd=%q", tc.name, mode, tgt.cmd)
		}
	}
}

func TestUitoa(t *testing.T) {
	cases := []struct {
		in   uint
		want string
	}{
		{0, "0"},
		{1, "1"},
		{22, "22"},
		{2222, "2222"},
		{65535, "65535"},
		{4294967295, "4294967295"},
	}
	for _, tc := range cases {
		if got := uitoa(tc.in); got != tc.want {
			t.Fatalf("uitoa(%d) = %q want %q", tc.in, got, tc.want)
		}
	}
}

func TestErrString(t *testing.T) {
	if errString("recv timeout").Error() != "recv timeout" {
		t.Fatal("errString mismatch")
	}
}
