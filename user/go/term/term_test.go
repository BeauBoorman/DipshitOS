package main

import (
	"strings"
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
		{markerNotify, "goterm: notify sent "},
		{markerNotifyNo, "goterm: notify refused "},
		{markerFindOpen, "goterm: find open"},
		{markerFindN, "goterm: find n="},
		{markerFindHit, "goterm: find hit "},
		{markerFindMiss, "goterm: find miss"},
		{markerFindClose, "goterm: find close"},
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

// M192f (#3251): the threshold key — absent/junk falls to the 5 s
// default, a positive integer is seconds, `off` is the disable sentinel
// the caller maps to never-notify.
func TestNotifyThresholdNs(t *testing.T) {
	cases := []struct {
		name, body string
		want       int64
	}{
		{"missing defaults to 5s", "#v2\nwm=none\n", 5e9},
		{"empty body defaults", "", 5e9},
		{"explicit seconds", "#v2\nterm_notify_seconds=12\n", 12e9},
		{"value is trimmed", "term_notify_seconds = 30 \n", 30e9},
		{"off disables", "term_notify_seconds=off\n", -1},
		{"zero falls back to default", "term_notify_seconds=0\n", 5e9},
		{"non-numeric falls back", "term_notify_seconds=later\n", 5e9},
		{"substring is not the key", "xterm_notify_seconds=99\n", 5e9},
	}
	for _, c := range cases {
		if got := notifyThresholdNs(c.body); got != c.want {
			t.Errorf("%s: notifyThresholdNs(%q) = %d want %d", c.name, c.body, got, c.want)
		}
	}
}

// The toast's `name` is the line's first word — the command the user
// would call it by — with a fallback for an empty submit.
func TestNotifyName(t *testing.T) {
	cases := []struct{ line, want string }{
		{"sleep 7", "sleep"},
		{"  cd /data", "cd"},
		{"go build ./...", "go"},
		{"a | b", "a"},
		{"", "command"},
	}
	for _, c := range cases {
		if got := notifyName(c.line); got != c.want {
			t.Errorf("notifyName(%q) = %q want %q", c.line, got, c.want)
		}
	}
}

func TestNotifyDuration(t *testing.T) {
	cases := []struct {
		ns   int64
		want string
	}{
		{7 * 1e9, "7s"},
		{59 * 1e9, "59s"},
		{65 * 1e9, "1m5s"},
		{3599 * 1e9, "59m59s"},
		{3600 * 1e9, "1h0m"},
		{3720 * 1e9, "1h2m"},
	}
	for _, c := range cases {
		if got := notifyDuration(c.ns); got != c.want {
			t.Errorf("notifyDuration(%d) = %q want %q", c.ns, got, c.want)
		}
	}
}

// The 24-byte frame title is the whole budget: a short name rides
// verbatim, a long name yields to the status+duration suffix, and the
// total never exceeds the wire cap.
func TestNotifyText(t *testing.T) {
	if got, want := notifyText("sleep", 0, 7e9), "sleep exited st=0 in 7s"; got != want {
		t.Fatalf("notifyText = %q want %q", got, want)
	}
	got := notifyText("someverylongcommandname", 127, 65e9)
	if len(got) > notifyTextMax {
		t.Fatalf("notifyText len = %d want <= %d (%q)", len(got), notifyTextMax, got)
	}
	if !strings.HasSuffix(got, " exited st=127 in 1m5s") {
		t.Fatalf("notifyText = %q — the status/duration suffix was clipped", got)
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
