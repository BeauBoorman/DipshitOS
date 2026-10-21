// Serial markers for the M74a (issue #1644) file manager. Every line is
// printed only AFTER the event it describes has happened (after the frame is
// painted for frame markers), so the go-fileman class-B gate's serial asserts
// can only pass when the app really ran. These shapes are test surface:
// listing_test.go pins them on the host.
package main

const (
	markerOpen      = "gofiles: open id="
	markerDeclare   = "gofiles: declare accepted"
	markerDeclareNo = "gofiles: declare refused"
	markerList      = "gofiles: list "
	// M123b (#2576): the shared empty-state panel painted over a zero-entry
	// listing — emitted with the list marker family, flushed after the frame.
	markerEmpty   = "gofiles: empty "
	markerEntry   = "gofiles: entry "
	markerFound   = "gofiles: found KNOWN.TXT"
	markerView    = "gofiles: view "
	markerPresent = "gofiles: present"
	markerClose   = "gofiles: close"
	markerOK      = "gofiles OK"
	markerListErr = "gofiles: list error "
	markerCd      = "gofiles: cd "
	// M79e (#1708): the WM_RPC nav seam. `nav declare` is this app
	// announcing where it navigated; `nav back` is the proof the round
	// trip closed — the seat handed back a path and this app acted on it.
	markerNavDeclare = "gofiles: nav declare "
	markerNavBack    = "gofiles: nav back to "

	markerAttach  = "gofiles: attached"
	markerPainted = "gofiles: painted"
	markerReady   = "gofiles: ready"
	markerRepaint = "gofiles: repainted"
	markerKey     = "gofiles: key "
	markerMouse   = "gofiles: mouse b="
	markerResized = "gofiles: resized "

	markerRenamed       = "gofiles: renamed "
	markerRenameNo      = "gofiles: rename refused "
	markerDeleted       = "gofiles: deleted "
	markerDeleteNo      = "gofiles: delete refused "
	markerRestored      = "gofiles: restored "
	markerRestoreNo     = "gofiles: restore refused "
	markerTrashExpired  = "gofiles: trash expired "
	markerTrashExpireNo = "gofiles: trash expiry refused "
	markerClip          = "gofiles: clip "
	// M124c (#2582): the machine-clipboard half of a copy — the
	// text/uri-list publish through slot 38 (rc= names the refusal,
	// EACCES under the seat included).
	markerClipSys = "gofiles: clip-sys "
	markerPasted  = "gofiles: pasted "
	markerPasteNo = "gofiles: paste refused "
	// M79k (#1720): this app is the notify adopter. The seat owns the
	// toast; the app's own half is the round trip. `notify sent` follows
	// an accepted ack, `notify refused` an absent seat or a refused
	// request — the same declare accepted/refused pair this app already
	// uses, because a silent failure is a lie either way.
	markerNotify   = "gofiles: notify sent "
	markerNotifyNo = "gofiles: notify refused "

	// markerSettled is printed one yield after the rename frame has been
	// painted and its `gofiles: renamed …` marker flushed: the gate's close
	// script waits on it so the screenshot taken at the rename marker is
	// never raced by the window teardown.
	markerSettled = "gofiles: settled after rename"

	// M81b (#1762): the open dispatch. The DECISION markers
	// (`open`, `open no handler`, `open with`, `open chose`, `open
	// cancelled`) are printed by the pure model after the frame that shows
	// the status line; the OUTCOME markers (`open launched`, `open launch
	// refused`) are printed by main after vi.Exec returned, so a gate can
	// never read a launch that did not happen.
	markerOpenFile     = "gofiles: open file "
	markerOpenNo       = "gofiles: open refused "
	markerOpenWith     = "gofiles: open with "
	markerOpenChose    = "gofiles: open chose "
	markerOpenCancel   = "gofiles: open cancelled "
	markerOpenLaunched = "gofiles: open launched "
	markerOpenLaunchNo = "gofiles: open launch refused "

	// M121c (#2566): the '?' overlay's receipts — `hints n=` the registry
	// row count on the painted frame, one `hints row` per row the plate
	// shows (the serial-readable copy), `hints close` after the restored
	// list frame.
	markerHints    = "gofiles: hints "
	markerHintsRow = "gofiles: hints row "

	// M124d (#2583): the right-click context menu. `menu` is the DECISION
	// marker — the row, the mime spelling opens= matched against, and the
	// eligible-handler count; `menu openwith` is the submenu descent
	// (candidates= is named even when zero); the pick itself reuses
	// `open chose`/`open launched` so one launch vocabulary covers both
	// gestures; `menu closed` is the no-action dismissal.
	markerMenu      = "gofiles: menu "
	markerMenuSub   = "gofiles: menu openwith "
	markerMenuClose = "gofiles: menu closed "

	// M123d (#2578): the shared in-app error banner. `banner` is the raise
	// — the failure text the strip shows; `banner act` is the resolution,
	// naming the action ID that ran (replace/copy/cancel/dismiss) or the
	// refusal that kept it from running. Both ride `pending`, so each
	// line lands only after the frame that shows the strip.
	markerBanner    = "gofiles: banner "
	markerBannerAct = "gofiles: banner act "

	// M127d (#2602): "Export to Host". The marker names the staged
	// payload (and the OUTBOX name it landed under when it differs);
	// refusals carry the lane vocabulary word the stage returned.
	markerExport   = "gofiles: export "
	markerExportNo = "gofiles: export refused "

	// M100f (#2311): the volumes root. The listing reuses markerList /
	// markerEntry on "/", and every mount-table row's state is named each
	// list (`not_mounted` is the kernel's own refusal name, ADR 0050 D6 —
	// M134b #2760 makes the rows the kernel's, not fabricated ones).
	// `volume refused` is the enter attempt on an absent or unbrowsable row.
	markerVol            = "gofiles: volume "
	markerVolDiskMounted = "gofiles: volume disk mounted"
	markerVolDiskAbsent  = "gofiles: volume disk not_mounted"
	markerVolRefused     = "gofiles: volume refused "

	// M81f (#1766): the change feed. `watch armed` says the subscription is
	// live (the baseline listing is taken); the event markers name what the
	// feed observed since the previous poll, followed by the refreshed
	// listing rows that back them — all flushed only after the frame paints,
	// so a gate waiting on an event marker sees the screen that shows it.
	markerWatchArmed   = "gofiles: watch armed"
	markerWatchCreated = "gofiles: watch created "
	markerWatchRemoved = "gofiles: watch removed "
	markerWatchChanged = "gofiles: watch changed "
	markerWatchGone    = "gofiles: watch path gone"

	// M125c (#2588): the session-state protocol (M125a's save/restore).
	// `state save` is printed by the SaveState closure as the blob is
	// staged — an action marker, not a frame one. `state restored` rides
	// the first post-paint flush so it never precedes the listing it
	// describes; `state cwd` names the nearest-existing-parent fallback;
	// `state refused` is the app's own stale/malformed-blob verdict.
	markerStateSave    = "gofiles: state save "
	markerStateRestore = "gofiles: state restored "
	markerStateCwd     = "gofiles: state cwd "
	markerStateRefused = "gofiles: state refused "

	// M124a-2 (#2677): the drag source's receipts. `drag arm` follows the
	// seat's acked kind-24 (the payload is already staged under the source's
	// /host/DRAG.<id>); `drag refused` names why no arm happened — no row, a
	// volume/dir row, over the DragMax cap, a read rc, or the seat's own
	// refusal; `drag end` is the seat's kind-25 outcome notice for an armed
	// drag — `delivered win=<peer>` or `cancelled`.
	markerDragArm = "gofiles: drag arm "
	markerDragNo  = "gofiles: drag refused "
	markerDragEnd = "gofiles: drag end "

	// M149a (#2806): the spacebar QuickLook pane. `quicklook <name>
	// kind=…` is the open receipt — it states which arm the sniff chose
	// (kind=image carries the decoded and thumbnail dims, kind=text the
	// line count, kind=card the type word), so a gate never reads
	// "opened" without reading WHAT opened. `quicklook close` is the
	// dismiss. Both ride pending like every other frame marker.
	markerQuick      = "gofiles: quicklook "
	markerQuickClose = "gofiles: quicklook close"

	// The view/sort chords' own markers.
	markerViewMode = "gofiles: viewmode "
	markerSort     = "gofiles: sort "
)
