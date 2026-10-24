// import.go — the headless .ics verbs (M187d #3185, export M193b #3254):
// `import <path>` / `export <path>` on argv, the opens=text/calendar exec
// line, and the live-list drop. importInto/exportBytes are the pure
// halves import_test.go pins without a console.
package main

import (
	"strings"

	"virelai/clockfmt"
	"virelai/ical"
	"virelai/settings"
	"virelai/tabapp"
	"virelai/vi"
)

// --- .ics import (M187d #3185) ---------------------------------------------
//
// Two doors, one core. The headless verb (`exec GOCLOCK.ELF import
// <path>`, or the opens=text/calendar exec line `exec GOCLOCK.ELF
// <path>.ics`) merges a file into the persisted gocal2 list and exits
// before a window exists; a drop delivered through the seat's opens=
// admission merges the payload into the LIVE list and republishes it
// like any other mutation. importInto is the shared pure half: bytes in,
// the merged list and the marker lines out — the lines are RETURNED so
// host tests pin every verdict without a console.
//
// The verb edits the file behind any running instance's back — the
// share file is last-writer-wins and a running app's next mutation
// republishes its in-memory list, so the honest wording is "merge into
// the store while the store is idle" (the same caveat any foreign
// writer of GOCLOCK.ALARM carries).

// icsFileRead is the verb's file seam (the alarmFileRead pattern).
var icsFileRead = vi.ReadFileAll

// verbArg decodes the launch line: `import <path>` and `export <path>`
// (M193b) are the explicit verbs; a bare argv path ending .ics is the
// opens= route's exec line — an import. A verb word takes the NEXT arg
// as its path, so `export /host/OUT.ICS` never reads as an import of
// that .ics. ("", true) is a bare verb — it names that refusal itself.
func verbArg() (verb, path string, ok bool) {
	args := vi.Args()
	for i := 1; i < len(args); i++ {
		a := args[i]
		switch a {
		case "import", "export":
			if i+1 < len(args) {
				return a, args[i+1], true
			}
			return a, "", true
		}
		if strings.HasSuffix(strings.ToLower(a), ".ics") {
			return "import", a, true
		}
	}
	return "", "", false
}

// runImport is the verb's whole life: read, merge, republish the file,
// exit. It never opens a window — the markers ARE the face.
func runImport(path string) {
	if path == "" {
		vi.ConsoleLine(markerImport + "refused path")
		vi.Exit(2)
	}
	b, rc := icsFileRead(path, vi.MaxFileBytes)
	if rc < 0 {
		vi.ConsoleLine(markerImport + "refused read rc=" + vi.Itoa64(rc))
		vi.Exit(2)
	}
	list := loadAlarmFile()
	out := importInto(list, b, vi.Now(), settings.Load().Timezone())
	if !out.ok {
		vi.ConsoleLine(markerImport + "refused not-vcalendar")
		vi.Exit(2)
	}
	for _, ln := range out.lines {
		vi.ConsoleLine("goclock: " + ln)
	}
	if out.added > 0 {
		if enc := encodeAlarms(out.list); enc == nil {
			vi.ConsoleLine(markerASaveBad + "-1")
			vi.Exit(3)
		} else if wrc := alarmFileWrite(alarmPath, enc); wrc != 0 {
			vi.ConsoleLine(markerASaveBad + vi.Itoa64(wrc))
			vi.Exit(3)
		} else {
			vi.ConsoleLine(markerASaved)
		}
	}
	vi.ConsoleLine(importDoneLine(out.added, out.refused))
	vi.Exit(0)
}

// loadAlarmFile reads the persisted half of the store — the file the
// verbs merge into (import) or serialize out of (export). A missing
// file is an empty list; a foreign one is named bad and still an empty
// list — the decode refused it, not the verb.
func loadAlarmFile() []Alarm {
	var list []Alarm
	if raw, r := alarmFileRead(alarmPath, alarmFileCap); r >= 0 {
		if l, ok := decodeAlarms(raw); ok {
			list = l
		} else {
			vi.ConsoleLine(markerAFileBad)
		}
	}
	return list
}

// importOut is importInto's report: the merged list, the counts the
// done line carries, and the marker bodies (the "goclock: " prefix is
// the caller's).
type importOut struct {
	list    []Alarm
	added   int
	refused int
	lines   []string
	ok      bool
}

// importInto merges b's honoured VEVENTs into list. The verdicts are
// marker bodies, in event order: a landed row prints its civil time,
// mode and summary; a refused event names the parser's why (all-day,
// dtstart-tzid, rrule, dtstart) or the store's (dup, full); an overflow
// tail counts as one truncated line. ok=false is the file-level
// refusal — nothing in the bytes was a VEVENT.
func importInto(list []Alarm, b []byte, now int64, local clockfmt.Zone) importOut {
	res, ok := ical.Parse(b)
	out := importOut{list: list, ok: ok}
	if !ok {
		return out
	}
	seen := make(map[int64]bool, len(list))
	for _, al := range list {
		seen[al.At] = true
	}
	for _, ev := range res.Events {
		at := importAt(ev.Start, now, local)
		switch {
		case seen[at]:
			out.refused++
			out.lines = append(out.lines, "import refused dup")
		case len(out.list) >= MaxAlarms:
			out.refused++
			out.lines = append(out.lines, "import refused full")
		default:
			c := clockfmt.At(at, local)
			out.list = append(out.list, Alarm{
				At:      at,
				HHMM:    c.Hour*100 + c.Minute,
				Daily:   ev.Daily,
				Enabled: true,
				// M193b: the event's SUMMARY rides the row to the
				// export — cleaned to the bounded single-line field.
				Summary: cleanSummary(ev.Summary),
			})
			seen[at] = true
			out.added++
			summary := ev.Summary
			if summary == "" {
				summary = "-"
			}
			out.lines = append(out.lines, "import "+
				two(int64(c.Hour))+":"+two(int64(c.Minute))+
				" "+alarmMode(ev.Daily)+" "+summary)
		}
	}
	for _, rf := range res.Refusals {
		out.refused++
		out.lines = append(out.lines, "import refused "+rf.Why)
	}
	if over := res.Total - len(res.Events) - len(res.Refusals); over > 0 {
		out.lines = append(out.lines, "import truncated n="+itoa(int64(over)))
	}
	return out
}

// importAt resolves a parsed stamp to a wall-clock epoch: a Z value's
// Wall IS the epoch; a floating value is the civil reading the user's
// zone resolves (the same solve an alarm arm runs).
func importAt(st ical.Stamp, now int64, local clockfmt.Zone) int64 {
	if st.UTC {
		return st.Wall
	}
	return localEpoch(st.Wall, now, local)
}

// importDoneLine is the verb/drop receipt: what landed and what was
// refused, in one line a gate can end on.
func importDoneLine(added, refused int) string {
	return markerImport + "done added=" + itoa(int64(added)) +
		" refused=" + itoa(int64(refused))
}

// dropICS is the DropTarget hook: the seat already filtered the mime to
// text/calendar, so the payload parses where it lands — each verdict
// prints the same lines the verb's file read would.
func (a *app) dropICS(offer tabapp.DragOffer) {
	if offer.Blob == nil {
		vi.ConsoleLine(markerImport + "refused no-payload")
		return
	}
	vi.ConsoleLine(markerImpDrop + vi.Itoa64(int64(len(offer.Blob))))
	out := importInto(a.alarms, offer.Blob, a.now(), a.local)
	if !out.ok {
		vi.ConsoleLine(markerImport + "refused not-vcalendar")
		return
	}
	for _, ln := range out.lines {
		vi.ConsoleLine("goclock: " + ln)
	}
	a.alarms = out.list
	if out.added > 0 {
		a.alarmSel = len(a.alarms) - 1
		a.syncAlarms()
		a.persistAlarms()
		a.armTimer()
		a.dirty = true
	}
	vi.ConsoleLine(importDoneLine(out.added, out.refused))
}

// --- .ics export (M193b #3254) ---------------------------------------------
//
// The write-back half of the import door: `exec GOCLOCK.ELF export
// /host/<name>.ics` serializes the persisted list as a VCALENDAR through
// ical.Emit and publishes it with WriteFileSafe — headless like the
// import verb, the markers ARE the face. The emit covers exactly the
// fields the parser honours, so the file re-parses through the same
// reader the import verb runs — the round-trip the go-clock edit leg
// closes by re-importing its own export.
//
// Every row exports — a switched-off row is still an event; the toggle
// is the app's arm state, not the event's. MaxAlarms (7) sits under
// ical.MaxEvents (8), so the whole list always fits the reader's
// honoured prefix — the done line names that bound.

// exportBytes is the verb's pure half: the alarm list as a VCALENDAR
// document. ok=false refuses whole — an empty store has no events to
// name, a list past ical.MaxEvents would truncate on re-read, and an
// emit the bound cannot honour never becomes a partial file.
func exportBytes(list []Alarm) ([]byte, bool) {
	if len(list) == 0 || len(list) > ical.MaxEvents {
		return nil, false
	}
	evs := make([]ical.Event, len(list))
	for i, al := range list {
		// The armed instant exports as the UTC stamp it IS — a
		// re-import resolves the Z value to the same epoch, so the
		// round-trip is exact whatever the reader's zone is.
		evs[i] = ical.Event{
			Summary: al.Summary,
			Start:   ical.Stamp{Wall: al.At, UTC: true},
			Daily:   al.Daily,
		}
	}
	return ical.Emit(evs)
}

// runExport is the verb's whole life: read the store, emit, publish,
// exit. It never opens a window — the markers ARE the face.
func runExport(path string) {
	if path == "" {
		vi.ConsoleLine(markerExport + "refused path")
		vi.Exit(2)
	}
	list := loadAlarmFile()
	b, ok := exportBytes(list)
	if !ok {
		if len(list) == 0 {
			vi.ConsoleLine(markerExport + "refused empty")
		} else {
			vi.ConsoleLine(markerExport + "refused emit")
		}
		vi.Exit(3)
	}
	if rc := alarmFileWrite(path, b); rc != 0 {
		vi.ConsoleLine(markerExport + "refused write rc=" + vi.Itoa64(rc))
		vi.Exit(3)
	}
	vi.ConsoleLine(markerExport + "done n=" + itoa(int64(len(list))) +
		" bound=" + itoa(int64(ical.MaxEvents)))
	vi.Exit(0)
}
