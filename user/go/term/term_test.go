package main

import (
	"testing"

	"virelai/shlib"
)

// The marker values are gate contracts: go-term.spec asserts each of them
// and go-wm-hid asserts `goterm: attached` (and the ABSENCE of
// `goterm: line ` on a boot where nobody typed). Renaming any of these is
// a spec change, not a refactor.
func TestTermMarkerShapes(t *testing.T) {
	cases := []struct{ got, want string }{
		{markerOpen, "goterm: open id="},
		{markerDeclare, "goterm: declare accepted"},
		{markerReady, "goterm: ready"},
		{markerTty, "goterm: tty"},
		{markerAttach, "goterm: attached"},
		{markerPrompt, "goterm: prompt"},
		{markerLine, "goterm: line "},
		{markerDone, "goterm: done status="},
		{markerClose, "goterm: close"},
		{markerRestart, "goterm: restart"},
		{markerOK, "goterm OK"},
		{markerMonitor, "goterm: monitor"},
		{markerMonErr, "goterm: monitor failed"},
		{markerOpenErr, "goterm: error open "},
		{markerTtyErr, "goterm: no /dev/tty"},
		{markerAttErr, "goterm: attach failed"},
		{markerStateRestored, "goterm: state restored"},
		{markerStateRefused, "goterm: state refused"},
		{ttyPath, "/dev/tty"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Fatalf("marker = %q want %q", c.got, c.want)
		}
	}
}

// The default prompt is the shell's own (the same `gosh> ` GOSH falls
// back to); the live prompt comes from SETTINGS.TXT via
// shlib.PromptFromSettings, never from a hand-written constant in this app.
// M80n (#1730) moved the loader into shlib so GOSH and GOTERM share one
// implementation; this table is the GOTERM-side proof the shared loader still
// answers exactly what this front-end always got.
func TestDefaultPromptIsTheShellFallback(t *testing.T) {
	if defaultPrompt != "gosh> " {
		t.Fatalf("defaultPrompt = %q want %q", defaultPrompt, "gosh> ")
	}
}

func TestPromptFromSettings(t *testing.T) {
	cases := []struct {
		name, body, want string
	}{
		{"missing key falls back", "#v2\nwm=none\n", defaultPrompt},
		{"empty body falls back", "", defaultPrompt},
		{"empty value falls back", "prompt=\n", defaultPrompt},
		{"whitespace value falls back", "prompt=   \n", defaultPrompt},
		{"key wins with one trailing space", "prompt=sh$\n", "sh$ "},
		{"value is trimmed", "prompt=  sh$  \n", "sh$ "},
		{"first key wins", "prompt=one\nprompt=two\n", "one "},
		{"indented key counts", "  prompt=term> \n", "term> "},
		{"CRLF value carries no CR", "prompt=sh$\r\n", "sh$ "},
		{"substring of another key is not the key", "xprompt=nope\n", defaultPrompt},
	}
	for _, c := range cases {
		if got := shlib.PromptFromSettings(c.body, defaultPrompt); got != c.want {
			t.Errorf("%s: PromptFromSettings(%q) = %q want %q", c.name, c.body, got, c.want)
		}
	}
}

func TestRestartPolicyFromSettings(t *testing.T) {
	cases := []struct {
		name, body, want string
	}{
		{"missing defaults to stay", "#v2\nprompt=term> \n", restartStay},
		{"empty defaults to stay", "", restartStay},
		{"stay is explicit and valid", "#v2\nterm_restart=stay\n", restartStay},
		{"exit selects close", "#v2\nterm_restart=exit\n", restartExit},
		{"unknown fails safe to stay", "#v2\nterm_restart=maybe\n", restartStay},
		{"value is trimmed", "#v2\nterm_restart = exit \n", restartExit},
		{"substring is not the key", "#v2\nxterm_restart=exit\n", restartStay},
	}
	for _, c := range cases {
		if got := restartPolicyFromSettings(c.body); got != c.want {
			t.Errorf("%s: restartPolicyFromSettings(%q) = %q want %q", c.name, c.body, got, c.want)
		}
	}
}

func TestRestartMessageAndCloseRequest(t *testing.T) {
	if got := restartMessage(7); got != "\r\nshell exited status=7\r\n" {
		t.Fatalf("restartMessage(7) = %q", got)
	}
	for _, line := range []string{"exit --close", "  exit --close  "} {
		if !closeRequested(line) {
			t.Errorf("closeRequested(%q) = false", line)
		}
	}
	for _, line := range []string{"exit", "exit 7", "echo exit --close", "exit --close 7"} {
		if closeRequested(line) {
			t.Errorf("closeRequested(%q) = true", line)
		}
	}
}

func TestStartupLinesFrom(t *testing.T) {
	cases := []struct {
		name, body string
		want       []string
	}{
		{"empty", "", []string{""}},
		{"blank lines kept", "\n   \n\t\n", []string{"", "   ", "\t", ""}},
		{
			"CRLF folded, blanks kept for heredoc bodies, order kept",
			"echo one\r\n\r\n  \necho two\r\necho three",
			[]string{"echo one", "", "  ", "echo two", "echo three"},
		},
		{
			"lone CR terminated lines are trimmed",
			"line one\r\nline two\r",
			[]string{"line one", "line two"},
		},
		{
			"content whitespace is preserved (the engine parses it)",
			" echo  padded \n",
			[]string{" echo  padded ", ""},
		},
	}
	for _, c := range cases {
		got := startupLinesFrom(c.body)
		if len(got) != len(c.want) {
			t.Errorf("%s: got %d lines %q want %d %q", c.name, len(got), got, len(c.want), c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("%s: line %d = %q want %q", c.name, i, got[i], c.want[i])
			}
		}
	}
}
