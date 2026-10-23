# go-note.spec — NOTE.ELF (M192b #3247)
# class-B gate: the notepad's FIRST owning spec. Until now NOTE was exercised
# only incidentally (go-wm-hid, go-dogfood, live-desktop-typing); this leg
# pins the card's whole claim in one run under the live Go seat:
#
#   boot -> gotabwm autostart -> exec NOTE.ELF -> type "hello" -> ctrl-s
#   saves /host/notes.txt -> ctrl-shift-w closes the tab (the seat's kind-20
#   ask collects the appver-1 blob before the close lands) -> ctrl-shift-t
#   re-execs the recorded bin -> restore_state hands the envelope back ->
#   the open path and the caret round-trip, and the file on the share is
#   the typed text.
#
# NOTE saves on close only when dirty, so the clean close here must NOT
# rewrite notes.txt — and the restored blob carries no buffer bytes at all
# (the flag was clean), which is why the assert set has both a `state save`
# and a `state restore` seat marker.

vgate_name go-note "M192b #3247: NOTE.ELF appver 1 envelope — type/save/close/reopen round-trip, first owning gate"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-01.txt <<'EOF'
echo rx-go-note-boot
EOF

vgate_file script2-01.txt <<'EOF'
exec NOTE.ELF
EOF

vgate_file script3-01.txt <<'EOF'
echo rx-go-note-restored
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
for name, how in (("NOTE", "build-note.sh"),
                  ("GOTABWM", "build-gotabwm.sh")):
    src = os.path.join(".build", "go", name + ".ELF")
    if not os.path.exists(src):
        sys.exit(name + ".ELF missing (expected " + src + ") - build it first: "
                 "bash tools/go/" + how)
    shutil.copy(src, os.path.join(share, name + ".ELF"))
    print("staged %s.ELF into share (%d bytes)" %
          (name, os.path.getsize(os.path.join(share, name + ".ELF"))))
PY

# The seat autostarts (wm=gotabwm default); exec NOTE once the seat is live.
# chords1 types + ctrl-s saves; chords2 closes then reopens once the save
# marker proves the file is published; script3 rides the restore marker.
vgate_run 01 -- \
    --screen '$RUN_DIR/note-screen' \
    --via-virtio \
    --script '$RUN_DIR/script-01.txt' \
    --script2 '$RUN_DIR/script2-01.txt' \
    --script2-after 'gotabwm: mode live' \
    --input-chords 'h,e,l,l,o,ctrl-s' \
    --input-chords-after 'note: ready' \
    --input-chords2 'ctrl-shift-w,ctrl-shift-t' \
    --input-chords2-after 'note: saved ok n=5' \
    --script3 '$RUN_DIR/script3-01.txt' \
    --script3-after 'note: state restored' \
    --script-expect 'rx-go-note-restored' --timeout 300

vgate_assert 01 serial-contains 'wm: autostart gotabwm (settings wm=gotabwm)'
vgate_assert 01 serial-contains 'gotabwm: mode live'
vgate_assert 01 serial-contains 'exec: loaded NOTE.ELF'
vgate_assert 01 serial-contains 'note: open id='
vgate_assert 01 serial-contains 'note: tab-aware (full-viewport)'
vgate_assert 01 serial-contains 'note: load miss /host/notes.txt'
vgate_assert 01 serial-contains 'note: ready'

# The typed edit, the save, and the caret position at save time.
vgate_assert 01 serial-contains 'note: saved ok n=5'
vgate_assert 01 serial-contains 'note: cursor line=1 col=5 n=5'

# Close: the seat's ask is answered (appver 1 envelope staged and stored),
# then the tab close lands. The buffer was clean, so no save-on-close.
vgate_assert 01 serial-contains 'gotabwm: state ask id='
vgate_assert 01 serial-contains 'gotabwm: state save id='
vgate_assert 01 serial-contains ' ver=1'
vgate_assert 01 serial-contains 'gotabwm: tab close id='
vgate_assert 01 serial-contains 'note: win_close'
vgate_assert 01 serial-contains 'note OK'
vgate_assert 01 serial-contains 'note: exiting 0'

# Reopen: the seat re-execs the recorded bin, restore_state hands the blob
# back (its own copy is consumed on staging), and the app reports the
# round-trip — the blob's path opened the file, the caret is back at the
# byte offset the typist left.
vgate_assert 01 serial-contains 'gotabwm: reopen NOTE.ELF'
vgate_assert 01 serial-contains 'gotabwm: state restore id='
vgate_assert 01 serial-contains 'note: loaded ok n=5'
vgate_assert 01 serial-contains 'note: state restored cur=5 path=/host/notes.txt'
vgate_assert 01 serial-contains 'rx-go-note-restored'

# The typed text is what the save published on the share.
vgate_assert 01 share-equals notes.txt hello

vgate_assert 01 serial-absent 'note: state stale'
vgate_assert 01 serial-absent 'gotabwm: state drop'
vgate_assert 01 serial-absent 'note: save error'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
