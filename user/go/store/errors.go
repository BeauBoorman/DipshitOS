package store

// STORE is the M101c (#2315) install seam for VirelaiOS — verify the stream
// head against the publisher keyring (through FLINT.ELF's M101b gate), parse
// and re-authenticate the signed release.go manifest, fetch the ELF over an
// untrusted channel, check its SHA-256, and only then publish the ELF and the
// schema-v2 APPS.TXT row through WriteFileSafe.
//
// M110c (#2405) turns this package into the shared implementation both
// STORE.ELF (the scriptable path, user/go/store/main) and GOSTORE.ELF (the
// human path, user/go/gostore) link: GOSTORE calls the same exported verbs
// in-process — never a nested `STORE.ELF` exec — because seat + GOSTORE +
// STORE + FLINT would be four concurrent Go runtimes and four runtimes blow
// the kernel's 13-user-slot task pool (observed `newosproc: sys_thread
// create failed`; the seat's proven envelope is itself plus two clients,
// M65d/#1442). Every failure is a named refusal — `store: refuse <code>` —
// and a failed install leaves zero partial state.

import (
	"virelai/vi"
)

// ConsoleFn is the console-write seam; tests and in-process embedders
// (GOSTORE) replace it. The default is vi.ConsoleLine — STORE.ELF keeps it,
// GOSTORE tees it into its log pane.
var ConsoleFn = vi.ConsoleLine

// LegFn, when non-nil, runs at each signed-pipeline leg boundary — the
// verify → fetch → sha → publish → .prev narration the GOSTORE GUI renders
// live. Names: "sync" (clone/pull), "verify", "fetch", "deps" (ADR 0055
// D8 dependency resolution), "sha", "publish", "prev" (the post-commit
// .prev rotation — the leg a killed update must leave survivable). Leg
// calls fire at leg START, so a hook that pauses on "prev" freezes the
// pipeline after the STORE.TXT commit and before the .prev rotation —
// exactly the torn-publish shape readRollbackBytes recovers from
// .prev.new.
var LegFn func(leg string)

// emitLeg reports a leg boundary to the optional LegFn hook.
func emitLeg(leg string) {
	if LegFn != nil {
		LegFn(leg)
	}
}

// RefuseError is a named STORE refusal (`store: refuse <code> ...`).
type RefuseError struct {
	Code   string
	Detail string
}

func (e *RefuseError) Error() string {
	if e.Detail == "" {
		return "store: refuse " + e.Code
	}
	return "store: refuse " + e.Code + " " + e.Detail
}

func refuse(code, detail string) error {
	return &RefuseError{Code: code, Detail: detail}
}

func runErr(err error) int {
	if err == nil {
		return 0
	}
	if re, ok := err.(*RefuseError); ok {
		ConsoleFn(re.Error())
		if re.Code == "usage" {
			return 2
		}
		return 1
	}
	ConsoleFn("store: error " + err.Error())
	return 1
}
