package main

import (
	"reflect"
	"strings"
	"testing"
)

// TestHasArg pins the argv scan both front-end dispatches share.
func TestHasArg(t *testing.T) {
	if !hasArg([]string{"GOSH.ELF", "serial"}, "serial") {
		t.Fatal("serial argv word not found")
	}
	if hasArg([]string{"GOSH.ELF", "serial"}, "net") || hasArg(nil, "serial") {
		t.Fatal("hasArg reported a word argv does not carry")
	}
}

// TestHeadlessLine pins the `-c LINE` child form at BOTH argv positions —
// the exec seam may supply argv[0] or not, and the serial gate's children
// run through this recognition.
func TestHeadlessLine(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want string
		ok   bool
	}{
		{[]string{"-c", "echo hi"}, "echo hi", true},
		{[]string{"GOSH.ELF", "-c", "ls /"}, "ls /", true},
		{[]string{"-c", ""}, "", true},
		{nil, "", false},
		{[]string{"-c"}, "", false},
		{[]string{"GOSH.ELF", "-c"}, "", false},
		{[]string{"serial"}, "", false},
		{[]string{"x-c", "echo hi"}, "", false},
	} {
		got, ok := headlessLine(tc.args)
		if got != tc.want || ok != tc.ok {
			t.Fatalf("headlessLine(%v) = (%q,%v), want (%q,%v)", tc.args, got, ok, tc.want, tc.ok)
		}
	}
}

// TestCandidateNames pins SH.BIN's resolution order — bare, .ELF, .BIN,
// then the same under the uppercase fold — and its dedup: an already-upper
// name must not double its own row.
func TestCandidateNames(t *testing.T) {
	got := candidateNames("goedit")
	want := []string{"goedit", "goedit.ELF", "goedit.BIN", "GOEDIT", "GOEDIT.ELF", "GOEDIT.BIN"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("candidateNames(goedit) = %v", got)
	}
	got = candidateNames("GOSH")
	want = []string{"GOSH", "GOSH.ELF", "GOSH.BIN"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("candidateNames(GOSH) = %v", got)
	}
}

// TestScriptSteps covers the startup contract's line folding the serial
// gate only sees end-to-end: blanks between steps are skipped, a `<<` line
// pulls the file's own following lines as its body (a blank inside the
// body is a body line, not a skip), and an unterminated collection still
// runs with what arrived.
func TestScriptSteps(t *testing.T) {
	steps := scriptSteps([]string{
		"",
		"echo a",
		"   ",
		"cat <<E > /host/H.TXT",
		"first",
		"",
		"E",
		"echo done",
	})
	if len(steps) != 3 {
		t.Fatalf("scriptSteps returned %d steps, want 3: %+v", len(steps), steps)
	}
	if steps[0].line != "echo a" || steps[0].bodies != nil {
		t.Fatalf("step 0 = %+v", steps[0])
	}
	if steps[1].line != "cat <<E > /host/H.TXT" {
		t.Fatalf("step 1 line = %q", steps[1].line)
	}
	if got := steps[1].bodies; len(got) != 1 || string(got[0]) != "first\n\n" {
		t.Fatalf("step 1 bodies = %q", got)
	}
	if steps[2].line != "echo done" {
		t.Fatalf("step 2 line = %q", steps[2].line)
	}
}

// TestScriptStepsUnterminated: a `<<` at end of script collects to EOF —
// the delimiter never arrived, so the step runs with NO bodies (the engine
// owns the unterminated-heredoc verdict; the folder's contract is only that
// the line is still emitted and the tail is consumed, not re-run).
func TestScriptStepsUnterminated(t *testing.T) {
	steps := scriptSteps([]string{"echo before", "cat <<NEVER", "x", "y"})
	if len(steps) != 2 {
		t.Fatalf("steps = %+v", steps)
	}
	if steps[1].line != "cat <<NEVER" || len(steps[1].bodies) != 0 {
		t.Fatalf("unterminated step = %+v", steps[1])
	}
}

// TestHeredocCollector is the interactive `<<` state machine: a declaring
// line parks, body lines join it, the delimiter completes the collection
// and hands back the ORIGINAL line with its bodies; reset abandons it.
func TestHeredocCollector(t *testing.T) {
	var hd heredocCollector
	if run, _, waiting := hd.accept("echo hi"); waiting || run != "echo hi" {
		t.Fatalf("plain line: run=%q waiting=%v", run, waiting)
	}
	if _, _, waiting := hd.accept("cat <<E"); !waiting || !hd.collecting() {
		t.Fatal("declaring line did not start a collection")
	}
	if _, _, waiting := hd.accept("body one"); !waiting {
		t.Fatal("body line ended the collection early")
	}
	run, bodies, waiting := hd.accept("E")
	if waiting || run != "cat <<E" || hd.collecting() {
		t.Fatalf("delimiter: run=%q waiting=%v collecting=%v", run, waiting, hd.collecting())
	}
	if len(bodies) != 1 || string(bodies[0]) != "body one\n" {
		t.Fatalf("bodies = %q", bodies)
	}

	// A collection abandoned by reset leaves the next line fresh.
	hd.accept("cat <<E")
	hd.reset()
	if hd.collecting() {
		t.Fatal("reset left the collector active")
	}
	if run, _, waiting := hd.accept("E"); waiting || run != "E" {
		t.Fatalf("post-reset line: run=%q waiting=%v", run, waiting)
	}
}

// TestLineEmitter: headless Out bytes reassemble into whole lines for emit
// regardless of chunk boundaries, and flush drains a trailing partial.
func TestLineEmitter(t *testing.T) {
	var got []string
	l := lineEmitter{emit: func(s string) { got = append(got, s) }}
	l.write([]byte("one\ntw"))
	l.write([]byte("o\nthree\n"))
	if strings.Join(got, ",") != "one,two,three" {
		t.Fatalf("emitted %v", got)
	}
	l.write([]byte("tail"))
	l.flush()
	if strings.Join(got, ",") != "one,two,three,tail" {
		t.Fatalf("after flush: %v", got)
	}
	l.flush()
	if len(got) != 4 {
		t.Fatalf("empty flush emitted: %v", got)
	}
}
