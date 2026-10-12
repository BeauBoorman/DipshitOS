package shlib

import "testing"

// ADR 0044 D3, owner ruling: pin the redirect behavior the agent actually
// observed — not the capture guarantee a POSIX reader would assume. The
// daemon always appends ` > /host/AGENTD.OUT` itself (CheckAgentLine, which
// stays untouched), so this table runs every command in exactly that shape:
//
//   - a BUILTIN's stdout goes through the shell's output sink, so the
//     redirect captures it — success text and failure text alike;
//   - an EXTERNAL app writes fd 1 itself. Under `>` its bytes bypass the
//     capture entirely: the file is still written (empty), the external's
//     status is the line's status, and nothing diagnoses the loss;
//   - a PIPELINE that names an external refuses before any write, with the
//     shell's existing diagnostic on the console;
//   - CheckAgentLine's refusal classes never reach the shell at all.
//
// The agent reports what the shell did; these rows are the spec.
func TestAgentRedirectObservedTable(t *testing.T) {
	for _, tc := range []struct {
		name string
		line string
		// file is the path the fake kernel records the write under
		// ("/host/AGENTD.OUT" canonicalizes to "/host/AGENTD.OUT"); absent
		// means no WriteFile must happen at all.
		file   string
		want   string
		status int
		con    string
	}{
		{"builtin output captured", `echo hello > /host/AGENTD.OUT`,
			"/host/AGENTD.OUT", "hello\n", 0, ""},
		{"builtin failure text captured", `cat MISSING.TXT > /host/AGENTD.OUT`,
			"/host/AGENTD.OUT", "", 1, ""}, // error text pinned below
		{"pipeline last stage captured", `echo a | cat > /host/AGENTD.OUT`,
			"/host/AGENTD.OUT", "a\n", 0, ""},
		{"external bypasses the capture", `GOCALC.ELF > /host/AGENTD.OUT`,
			"/host/AGENTD.OUT", "", 43, ""},
		{"external-left pipeline refuses", `GOCALC.ELF | cat > /host/AGENTD.OUT`,
			"", "", 1, "gosh: cannot capture an external app's output yet\n"},
		{"external-right pipeline refuses", `echo a | GOCALC.ELF > /host/AGENTD.OUT`,
			"", "", 1, "gosh: a piped command must be a builtin or tool (an external app would not read the pipe)\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newFakeHost()
			h.released = 43 // the external's own exit status
			run, _ := session(h)
			st := run(tc.line)
			if st != tc.status {
				t.Fatalf("status = %d want %d", st, tc.status)
			}
			if tc.con != "" && h.outString() != tc.con {
				t.Fatalf("console = %q want %q", h.outString(), tc.con)
			}
			if tc.file == "" {
				if len(h.files) != 0 {
					t.Fatalf("a write happened: %v", h.files)
				}
				return
			}
			body, ok := h.files[tc.file]
			if !ok {
				t.Fatalf("no write to %s: files = %v", tc.file, h.files)
			}
			if tc.name == "builtin failure text captured" {
				// A failing builtin's message is still capture-channel
				// output — the file holds the error text, not a clean
				// stream.
				if len(body) == 0 || string(body) == "hello\n" {
					t.Fatalf("captured failure = %q", body)
				}
				return
			}
			if string(body) != tc.want {
				t.Fatalf("captured = %q want %q", body, tc.want)
			}
		})
	}
}

// The external case deserves its own pin: the file is WRITTEN — empty —
// because the write happens after runExternal returns, with nothing in the
// capture buffer. The child's fd-1 bytes go to the console in the guest;
// the daemon reads back an empty AGENTD.OUT and reports it honestly.
func TestAgentRedirectExternalWritesEmptyFile(t *testing.T) {
	h := newFakeHost()
	h.released = 0
	run, _ := session(h)
	if st := run(`GOCALC.ELF > /host/AGENTD.OUT`); st != 0 {
		t.Fatalf("external status = %d want 0", st)
	}
	body, ok := h.files["/host/AGENTD.OUT"]
	if !ok {
		t.Fatalf("external redirect wrote nothing: files = %v", h.files)
	}
	if len(body) != 0 {
		t.Fatalf("external captured %q want empty file", body)
	}
	if len(h.externArgs) != 1 || h.externArgs[0][0] != "GOCALC.ELF" {
		t.Fatalf("external never ran: %v", h.externArgs)
	}
	if h.outString() != "" {
		t.Fatalf("external redirect diagnosed itself: %q", h.outString())
	}
}
