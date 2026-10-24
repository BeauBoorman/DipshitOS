# go-term.spec -- M58c (issue #1307) class-B gate: a Go terminal window opens
# over the existing /dev/tty seam, attaches selector 2, types a line, and
# closes, full-viewport inside Zig TABWM. M80j (#1726) also drives `exit`:
# the default `term_restart=stay` keeps the same window/fd, announces the
# shell status, and starts a second prompt before the harness closes it.
#
# user/go/term is a tabapp client: init -> declare (kind-8 WM_RPC) -> open
# /dev/tty -> sys_tty_attach(2, window_id) -> startup block through the tty
# (M73c #1627: startup contract banner, SETTINGS prompt load, history load,
# `goterm: ready`, first prompt painted by shlib's editor) -> injected
# keystrokes (ADR 0020 A5) feed editor.Feed, and each EvSubmit runs the line
# through shlib's Shell.RunLine -> a shell exit restarts the session (or
# closes it under term_restart=exit), and WIN_CLOSE detaches and exits.
# Zig TERM.BIN / SH.BIN are untouched; kernel untouched; no second renderer.
#
# M73c (#1627) execution proof: observed on the first reshaped run --
# WINDOWED tty bytes never reach serial (ADR 0020 selector 2 paints the
# window grid; only ConsoleLine lines are serial-observable), so output
# text (live-sh's `PWD=/data` shape) can never vouch for execution here.
# The proof is instead `goterm: done status=N`, printed by the app AFTER
# Shell.RunLine returned, carrying the engine's OWN status: the typed line
# `cd /data` yields status=0 only after host.Chdir verified the real
# directory (term's cd checks sys_dir_list, same as GOSH; `data/` is
# seeded in setup), and the negative control `cd /nosuchdir` yields a
# nonzero status -- so neither marker can come from a constant, an echo
# stub, or an unexecuted line. Chords are limited to characters both key
# tables map (`$`, `%`, `>` are unmapped in macKey/hidUsage -- observed in
# host/vm-runner main.swift), which is why the lines are cd forms typed
# over --input-chords.
#
# M149b (#2807) adds leg 02: OSC-8 hyperlinks — a sourced script paints an
# https and an ftp link, SGR mouse reports over ?1000/?1006 resolve the
# clicks against the app's own cell mirror, ftp refuses by name and https
# opens through mime.Open -> WEB.ELF; `term-profile` applies a seeded named
# profile into SETTINGS.TXT.
#
# Card #2927 adds legs 03/04: profiles cycle (`term-profile next`) and the
# save_state blob carries the active name — a seat snapshot under GOTABWM,
# then a restore boot that comes back in the same profile (serial markers
# and palette pixel probes on both halves).
#
# M154d (#2928) adds tagged legs d1/d2/d3: the daily loop, K=3 — an OSC 52
# "remote" copy read back by the monitor `clip`, a Ctrl+Shift+V bracketed
# paste (one edit, one Enter submit), a Ctrl+Shift+F find over the search
# space, and `term-profile next` under the seat with leg 03's rail probe.
#
# Issue #3251 adds leg 05: notify-on-finish — a foreground command that ran
# past term_notify_seconds (default 5 s) while the tab was unfocused posts
# a vi.Notify toast naming it, its exit status and the duration; a focused
# tab or a fast command posts nothing.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goterm.sh   ->  .build/go/GOTERM.ELF
#   bash tools/go/build-web.sh browser  ->  .build/go/WEB.ELF  (leg 02)
#   bash tools/go/build-gotabwm.sh  ->  .build/go/GOTABWM.ELF  (legs 03/04)
#
# exec-order: assert-proven -- the run ends on `rx-goterm-ok`, which only the
# script prints, and the stage gate that forwards the close waits on the app's
# own `goterm: restart` marker; a program that never ran, or one that echoed
# without executing, cannot pass (the two `goterm: done status=` markers
# carry engine-computed statuses 0 then nonzero, and the ordering python
# asserts the whole chain).

vgate_name go-term "issue #1307 M58c + #3251: a Go terminal attaches /dev/tty selector 2 in Zig TABWM on VZ; notify-on-finish toasts a >5s command that ended unfocused"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec GOTERM.ELF
EOF

# The close is driven from the harness after the app's own `goterm: restart`
# marker, so the replacement session reached its prompt before teardown.
vgate_file script3.txt <<'EOF'
dui close 2
echo rx-goterm-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTERM.ELF")
if not os.path.exists(src):
    sys.exit("GOTERM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goterm.sh")
shutil.copy(src, os.path.join(share, "GOTERM.ELF"))
print("staged GOTERM.ELF into share (%d bytes)" %
      os.path.getsize(os.path.join(share, "GOTERM.ELF")))
# The `cd /data` target must EXIST: term's cd verifies through sys_dir_list
# (same as GOSH's), so the assert below would otherwise never fire.
os.makedirs(os.path.join(share, "data"), exist_ok=True)
print("seeded data/ for cd")
# M81e2 (#1787): seed GOSH-HISTORY.TXT with a body LONGER than anything this
# run appends, so the history save is a write over existing bytes. The two
# lines the harness types are APPENDED (one per submit), so the file grows
# rather than shrinks here; what this run proves is that the append adds to
# the seeded body instead of replacing it, and leaves no orphan temp.
with open(os.path.join(share, "GOSH-HISTORY.TXT"), "w") as fh:
    fh.write("seeded-history-line\n" * 3)
print("seeded GOSH-HISTORY.TXT (3 lines) for the append half")
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'c,d,space,/,d,a,t,a,return,c,d,space,/,n,o,s,u,c,h,d,i,r,return,e,x,i,t,return' \
    --input-chords-after 'goterm: prompt' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'goterm: restart' \
    --script-expect 'rx-goterm-ok' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 01 serial-contains 'goterm: open id='
vgate_assert 01 serial-contains 'goterm: declare accepted'
vgate_assert 01 serial-contains 'goterm: tty'
vgate_assert 01 serial-contains 'goterm: attached'
# M73c: the shlib startup block announced itself before the first prompt.
vgate_assert 01 serial-contains 'goterm: ready'
# Prompt bytes went through /dev/tty so the kernel has something to paint.
vgate_assert 01 serial-contains 'goterm: prompt'
# The injected keystrokes reached the tty input queue and submitted two
# lines, each announced by the app AFTER the editor cut it, each finished
# with the engine-computed status AFTER RunLine returned.
vgate_assert 01 serial-contains 'goterm: line cd /data'
vgate_assert 01 serial-contains 'goterm: done status=0'
vgate_assert 01 serial-contains 'goterm: line cd /nosuchdir'
vgate_assert 01 serial-contains 'goterm: restart'
vgate_assert 01 serial-contains 'goterm: close'
vgate_assert 01 serial-contains 'goterm OK'
vgate_assert 01 serial-contains 'rx-goterm-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
# M81e2 (#1787): the history save, on the share. GOTERM calls
# shlib.SaveHistory on every submit through the SAME termHost.WriteFile the
# shell hook uses, so this is the second front-end's half of the card. The
# file must still carry the three seeded lines AND the typed ones (an append
# that replaced would drop the seeded body), and the sacrificial temp must
# not be beside it.
vgate_assert 01 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
hist = os.path.join(share, "GOSH-HISTORY.TXT")
if not os.path.exists(hist):
    sys.exit("GOSH-HISTORY.TXT is missing - the history save never landed")
body = open(hist, errors="replace").read()
if body.count("seeded-history-line") != 3:
    sys.exit("the seeded history body is %d lines, want 3 - the save " +
             "replaced instead of appending:\n%s" %
             (body.count("seeded-history-line"), body))
for want in ("cd /data", "cd /nosuchdir"):
    if want not in body:
        sys.exit("the typed line %r is not in the history file:\n%s" % (want, body))
orphan = hist + "~"
if os.path.exists(orphan):
    sys.exit("GOSH-HISTORY.TXT~ survived the history save")
PY
# THE execution proof + the whole chain in order: prompt, submit 1, its
# done marker with status=0 (host.Chdir verified /data -- `data/` is
# seeded), submit 2, its done marker with a NONZERO status (the negative
# control: the status is the engine's, not a constant), then the
# WIN_CLOSE teardown the harness only sends after the restart marker.
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read().splitlines()
done_re = re.compile(r"^goterm: done status=(-?\d+)$")

def first_after(sub, start=0):
    for i in range(start, len(ser)):
        if sub in ser[i]:
            return i
    sys.exit("missing %r (after %d)" % (sub, start))

def first_done_after(start):
    for i in range(start, len(ser)):
        m = done_re.match(ser[i].rstrip("\r"))
        if m:
            return i, int(m.group(1))
    sys.exit("no done marker after %d" % start)

ready_i = first_after("goterm: ready")
prompt_i = first_after("goterm: prompt", ready_i)
line1_i = first_after("goterm: line cd /data", prompt_i)
done1_i, st1 = first_done_after(line1_i)
if st1 != 0:
    sys.exit("cd /data status=%d want 0 (dir not verified?)" % st1)
line2_i = first_after("goterm: line cd /nosuchdir", done1_i)
done2_i, st2 = first_done_after(line2_i)
if st2 == 0:
    sys.exit("cd /nosuchdir status=0: the status is not the engine's")
# The replacement prompt is painted before restart is announced, and the
# harness only types script3 after restart. rx can race close on the
# console task, so it is chained to the restart rather than to close.
prompt2_i = first_after("goterm: prompt", done2_i)
restart_i = first_after("goterm: restart", prompt2_i)
close_i = first_after("goterm: close", restart_i)
rx_i = first_after("rx-goterm-ok", restart_i)
print("order ok: ready@%d prompt@%d cd/data@%d status=%d "
      "cd/nosuchdir@%d status=%d prompt2@%d restart@%d close@%d rx@%d" %
      (ready_i, prompt_i, line1_i, st1, line2_i, st2, prompt2_i,
       restart_i, close_i, rx_i))
PY

# --- M149b (#2807): OSC-8 link -> click -> WEB.ELF, and named profiles ----
# GOTERM owns OSC-8 inside its own write/read seams: the kernel emulator
# consumes `ESC]8;params;URI ST` whole, so the app mirrors link cells on the
# write path (injecting SGR 4/24 around the span) and extracts the kernel's
# SGR mouse reports (?1000/?1006 armed at session start) on the read path.
# The link text is painted by a SOURCED script (grid-only output, no klog)
# so its row is deterministic after `clear`: `webdoc` paints grid row 0
# cols 0-5, `ftplink` row 1 cols 0-6. Leg 02 seats NO WM: under zig TABWM
# every content-area pointer sample dies in handle_pointer's sidebar gate
# (it never calls wmctl_content_ptr), so terminal mouse reports are
# impossible there — the kernel shim's pointer_tick -> content_pointer_pass
# is the path that reports. Declare is then refused honestly and the plain
# user window paints at GOTERM's declared 64,48,640,400 (the same shape
# live-term-depth run 01 proves): client top_y = 64, 8x16 cells, so
# (92,88) hits ftplink's cell (x=4,y=2) and (84,72) hits webdoc's
# (x=3,y=1).
# Click order matters: the ftp refusal spawns nothing, so it clicks first;
# the https click spawns WEB.ELF over GOTERM's region, so it must be the
# LAST pointer step (the sequence is one burst). Each click REPEATS: the
# cv-input drain (poll_input) consumes the whole used ring in one pass, so
# a down+up pair decoded between two pointer_ticks collapses the release
# edge — observed as a lone press with no report pair. A collapsed attempt
# leaves the press latched at the same cell, so the next repetition's
# release pairs and resolves (self-healing); WEB isn't a bound terminal,
# so its over-window never shields GOTERM's cells from later attempts.
# `term-profile dusk` merges the seeded profile into SETTINGS.TXT through
# the crash-safe publish (share-checked) before the click burst.

vgate_file linkboot.txt <<'EOF'
set GOMAXPROCS=1
exec GOTERM.ELF
EOF

vgate_file linkclose.txt <<'EOF'
dui close 2
echo rx-goterm-link-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "WEB.ELF")
if not os.path.exists(src):
    sys.exit("WEB.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-web.sh browser")
shutil.copy(src, os.path.join(share, "WEB.ELF"))
print("staged WEB.ELF into share (%d bytes)" % os.path.getsize(src))
# Legs 03/04 seat GOTABWM — the snapshot chord and SESSION.TABS restore
# are seat features (like go-emoji's 05/06 pair).
src = os.path.join(".build", "go", "GOTABWM.ELF")
if not os.path.exists(src):
    sys.exit("GOTABWM.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotabwm.sh")
shutil.copy(src, os.path.join(share, "GOTABWM.ELF"))
print("staged GOTABWM.ELF into share (%d bytes)" % os.path.getsize(src))
# The OSC-8 fixture: `clear` makes the painted rows deterministic, then two
# printf links — https at grid row 0, ftp at row 1 (params field empty; ST
# is ESC-\\ inside the single quotes).
with open(os.path.join(share, "LINK.SH"), "w") as fh:
    fh.write("clear\n")
    fh.write("printf '\\e]8;;https://example.com/\\e\\\\webdoc\\e]8;;\\e\\\\\\n'\n")
    fh.write("printf '\\e]8;;ftp://example.com/\\e\\\\ftplink\\e]8;;\\e\\\\\\n'\n")
# A named profile: colours only — no font_size — so the click geometry
# (8x16 cells) survives its application. Card #2927's legs 03/04 add a
# second profile AFTER dusk in file order — `term-profile next` cycles
# dusk -> day, and day's theme=light is what the seat repaints live (the
# kernel's own theme re-read happens on leg 04's boot).
with open(os.path.join(share, "GOTERM-PROFILES.TXT"), "w") as fh:
    fh.write("# M149b gate fixture\n")
    fh.write("dusk.theme = custom\n")
    fh.write("dusk.palette_fg = e0e6ed\n")
    fh.write("dusk.palette_bg = 0b1020\n")
    fh.write("dusk.palette_accent = 7aa2f7\n")
    fh.write("day.theme = light\n")
print("seeded LINK.SH + GOTERM-PROFILES.TXT")
# Legs 03/04 need SETTINGS.TXT to be schema-v2 from the start: the kernel
# REFUSES a headerless file at load_from_share (M66b), which is what turns
# the merged theme into pixels on leg 04's restore boot — and GOTABWM.ELF
# is now staged, so wm=none keeps the compiled auto-seat default from
# launching a second seat in legs 01/02 (go-assist's precedent).
with open(os.path.join(share, "SETTINGS.TXT"), "w") as fh:
    fh.write("#v2\nwm=none\n")
print("seeded SETTINGS.TXT (#v2 wm=none)")
PY

vgate_run 02 -- --display --input \
    --screen '$RUN_DIR/screen-link' \
    --via-virtio \
    --script '$RUN_DIR/linkboot.txt' \
    --input-string $'source LINK.SH\nterm-profile dusk\necho LINKED\n' \
    --input-string-after 'goterm: prompt' \
    --pointer-virtio '92,88,c;92,88,c;92,88,c;84,72,c;84,72,c;84,72,c' \
    --pointer-virtio-after 'goterm: line echo LINKED' \
    --script3 '$RUN_DIR/linkclose.txt' \
    --script3-after 'web: ready' \
    --script-expect 'rx-goterm-link-ok' --timeout 300

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 02 serial-contains 'goterm: attached'
vgate_assert 02 serial-contains 'goterm: ready'
vgate_assert 02 serial-contains 'goterm: prompt'
# The sourced line + the front-end profile command + the barrier echo all
# submitted through the editor; the click sequence fired only after the
# last one (pointer-virtio-after pins the choreography).
vgate_assert 02 serial-contains 'goterm: line source LINK.SH'
vgate_assert 02 serial-contains 'goterm: done status=0'
vgate_assert 02 serial-contains 'goterm: profile dusk'
vgate_assert 02 serial-contains 'goterm: line echo LINKED'
# The ftp scheme is refused BY NAME — the marker carries it, and no app
# spawned for it (the serial would carry a second WEB load otherwise).
vgate_assert 02 serial-contains 'goterm: link refused scheme=ftp target=ftp://example.com/'
# The https click opened the link through mime.Open -> WEB.ELF. mime.Open
# spawns the handler itself (no monitor `exec`, so no `exec: loaded` klog) —
# the serial proof is WEB's window open owned by GOTERM's pid, then WEB
# taking the argv target far enough to try (and name) DNS — the same
# observed refusal go-sh's `open` leg asserts.
vgate_assert 02 serial-contains 'goterm: link open scheme=https target=https://example.com/ handler=WEB.ELF pid='
vgate_assert 02 serial-contains 'open: id=3 owner=2 rect=40,28 512x384'
vgate_assert 02 serial-contains 'web: url https://example.com/'
vgate_assert 02 serial-contains 'web: error dns'
vgate_assert 02 serial-contains 'web: ready'
vgate_assert 02 serial-contains 'goterm: close'
vgate_assert 02 serial-contains 'goterm OK'
vgate_assert 02 serial-contains 'rx-goterm-link-ok'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
# The profile merge landed on the share through the crash-safe publish:
# the chosen keys and the term_profile record, no orphan temp beside it.
vgate_assert 02 share-contains SETTINGS.TXT 'theme=custom'
vgate_assert 02 share-contains SETTINGS.TXT 'palette_bg=0b1020'
vgate_assert 02 share-contains SETTINGS.TXT 'term_profile=dusk'

# --- card #2927: profile cycle + remembered restore -------------------------
# Legs 03/04 seat GOTABWM (the snapshot chord and SESSION.TABS restore are
# seat features). Leg 03 seeds two profiles (dusk then day, day carrying
# theme=light), applies dusk by name then `term-profile next` wraps it to
# day — the publish re-themes the seat's rail, so the post-snapshot frame's
# rail band carries a light palette pixel where the dark default stood.
# ctrl-shift-s asks the app for its v2 blob (the profile name rides it),
# and leg 04 is the restore boot: the kernel loads the merged SETTINGS.TXT
# (theme=light paints the terminal grid), the seat session-loads GOTERM
# mode=restore, and the blob's profile re-applies — `goterm: profile day`
# lands before `goterm: state restored` (the apply runs inside applyEnv,
# ahead of the summary marker).
vgate_file script-seat3.txt <<'EOF'
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
set GOMAXPROCS=1
wm
exec -u0 GOTABWM.ELF
EOF

vgate_file script2-03.txt <<'EOF'
exec -u0 GOTERM.ELF
EOF

vgate_file script3-03.txt <<'EOF'
echo rx-goterm-03-ok
EOF

vgate_run 03 -- --display --input \
    --screen '$RUN_DIR/screen-03' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-03' \
    --script '$RUN_DIR/script-seat3.txt' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'term-profile dusk\nterm-profile next\nterm-profile\n' \
    --input-string-after 'goterm: prompt' \
    --input-chords 'ctrl-shift-s' \
    --input-chords-after 'goterm: profile list n=' \
    --snapshot-after 'rx-goterm-03-ok' \
    --script3 '$RUN_DIR/script3-03.txt' \
    --script3-after 'gotabwm: snapshot saved bytes=' \
    --script-expect 'rx-goterm-03-ok' --timeout 300

vgate_assert 03 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 03 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 03 serial-contains 'gotabwm: present'
vgate_assert 03 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 03 serial-contains 'goterm: declare accepted'
vgate_assert 03 serial-contains 'goterm: attached'
vgate_assert 03 serial-contains 'goterm: prompt'
# The named apply, then next cycled dusk -> day (file order): both merges
# landed crash-safe, each marked only after its write returned.
vgate_assert 03 serial-contains 'goterm: profile dusk'
vgate_assert 03 serial-contains 'goterm: profile day'
# The bare list ran too: two names, the active one starred (serial copy
# carries the active= field; the tty notice carries the '*').
vgate_assert 03 serial-contains 'goterm: profile list n=2 active=day'
# The seat saw the theme publish and re-resolved it.
vgate_assert 03 serial-contains 'gotabwm: settings broadcast key=theme'
# The snapshot: the seat asked, the app's blob answered (profile inside),
# and the bundle landed on the share for leg 04.
vgate_assert 03 serial-contains 'gotabwm: state ask id='
vgate_assert 03 serial-contains 'gotabwm: state save id='
vgate_assert 03 serial-contains 'gotabwm: snapshot saved bytes='
vgate_assert 03 serial-contains 'rx-goterm-03-ok'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'
vgate_assert 03 share-contains SETTINGS.TXT 'term_profile=day'
vgate_assert 03 share-contains SETTINGS.TXT 'theme=light'
# The palette pixel probe: the rail band's modal pixel is the light theme's
# chrome — every dark default (bg 0x182026, chrome 0x11171c, surface
# 0x222d35) has all channels under 0x60; every light fill token is over
# 0xa0. The publish's live re-theme is the only way that flips mid-boot.
vgate_assert 03 snapshot 'snap-03-*.raw' <<'PY'
import sys
W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot %d bytes, want %d" % (len(raw), W * H * 4))
hist = {}
for y in range(0, 22):
    for x in range(0, W, 2):
        k = (y * W + x) * 4
        px = (raw[k + 2], raw[k + 1], raw[k])
        hist[px] = hist.get(px, 0) + 1
mode = max(hist, key=hist.get)
print("rail modal pixel: #%02x%02x%02x over %d samples" %
      (mode + (hist[mode],)))
if max(mode) <= 0xa0:
    sys.exit("rail still paints the dark default (#%02x%02x%02x) — the "
             "theme=light publish never reached the seat" % mode)
print("palette probe: rail band is light — term-profile next re-themed the seat")
PY

# Leg 04: the restore boot. No rm's — SESSION.TABS + SNAPSHOT.BUNDLE are
# inputs. The kernel loads the merged SETTINGS.TXT at arming (theme=light
# paints the terminal grid itself), the seat re-execs GOTERM under
# mode=restore, and the v2 blob hands back the profile name: applyEnv's
# applySavedProfile rewrites it and marks it before the restored summary.
vgate_file script-04.txt <<'EOF'
exec -u0 GOTABWM.ELF
EOF

vgate_file script2-04.txt <<'EOF'
echo rx-goterm-04-ok
EOF

vgate_run 04 -- --display --input \
    --screen '$RUN_DIR/screen-04' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-04' \
    --script '$RUN_DIR/script-04.txt' \
    --script2 '$RUN_DIR/script2-04.txt' \
    --script2-after 'goterm: prompt' \
    --snapshot-after 'rx-goterm-04-ok' \
    --script-expect 'rx-goterm-04-ok' --timeout 300

vgate_assert 04 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 04 serial-contains 'gotabwm: mode live'
vgate_assert 04 serial-contains 'gotabwm: session load n=1 mode=restore'
vgate_assert 04 serial-contains 'gotabwm: session reexec n=1'
vgate_assert 04 serial-contains 'gotabwm: session exec GOTERM.ELF'
vgate_assert 04 serial-contains 'gotabwm: state restore id='
# The seat decoded theme=light out of the merged file at its own boot —
# serial proof the restore boot IS in the applied profile, kernel-side.
vgate_assert 04 serial-contains 'gotabwm: tokens theme=light'
vgate_assert 04 serial-contains 'goterm: open id='
vgate_assert 04 serial-contains 'goterm: attached'
# The blob's name re-applied by name: the marker can only print after the
# merge's crash-safe write landed, and 'state restored' summarizes after.
vgate_assert 04 serial-contains 'goterm: profile day'
vgate_assert 04 serial-contains 'goterm: state restored'
vgate_assert 04 serial-absent 'goterm: state refused'
vgate_assert 04 serial-absent 'goterm: profile fallback'
vgate_assert 04 serial-contains 'goterm: prompt'
vgate_assert 04 serial-contains 'rx-goterm-04-ok'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'
# The pixel probe: GOTERM's declared 640x400 rect lands at the content
# origin under the rail — the terminal client region's modal pixel is the
# kernel's light theme bg (0xf5f6f8); the dark default (0x101418) is what
# a boot that ignored the merged SETTINGS.TXT would paint instead.
vgate_assert 04 snapshot 'snap-04-*.raw' <<'PY'
import sys
W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot %d bytes, want %d" % (len(raw), W * H * 4))
hist = {}
for y in range(48, 384, 2):
    for x in range(8, 600, 2):
        k = (y * W + x) * 4
        px = (raw[k + 2], raw[k + 1], raw[k])
        hist[px] = hist.get(px, 0) + 1
mode = max(hist, key=hist.get)
print("client modal pixel: #%02x%02x%02x over %d samples" %
      (mode + (hist[mode],)))
dark = (0x10, 0x14, 0x18)
if max(abs(mode[i] - dark[i]) for i in range(3)) <= 8 or max(mode) <= 0xa0:
    sys.exit("terminal still paints the dark default (#%02x%02x%02x) — the "
             "restored profile's theme=light never reached the kernel" % mode)
print("palette probe: terminal grid is light — the restored boot came back in the saved profile")
PY

# --- M154d (#2928): the daily loop, K=3 --------------------------------------
# Three identical tagged boots, d1/d2/d3 — the terminal's daily loop end to
# end with M154a's bracketed paste at its default (on). Each boot seats
# GOTABWM (leg 03's recipe — the phase-3 rail probe needs a live seat) and
# execs GOTERM, then walks the same three phases:
#
#   phase 1  `source DCLIP.SH` emits OSC 52 `c;<b64>` — the "remote" copy.
#            The script's payload is three RUNNABLE lines (49 B), so the
#            clipboard never touches a selection or a drag. script3 rides
#            the source line's submit marker with a 1 s settle (the pump
#            bridges Screen.clip_data into the shared clipboard off the
#            parser path), and the monitor `clip` prints the decoded bytes
#            back on serial — the readback the chord burst keys off, so the
#            paste can never run ahead of the copy's landing.
#   phase 2  ctrl-shift-v pushes the clipboard through the bound tty
#            wrapped in DECSET 2004 — `tty: paste 61 bytes` = 49 + the 12 B
#            bracket, the M154a default proving itself with no opt-out
#            anywhere. ONE pending edit, ONE `goterm: line` submit on the
#            Enter chord carrying all three rows, one `goterm: done`.
#   phase 3  ctrl-shift-f opens the kernel search bar — read-only use: the
#            pattern chars feed the unified history+grid space, Esc closes
#            the bar (its keypress is captured, never queued). Each fed
#            char klogs its live count, so the last `tty: search:` line is
#            the full-pattern 'seek154d' count over the pasted block's
#            painted rows. Then `term-profile dusk` / `term-profile next` —
#            typed as chords so the cycle lands after the search — publish
#            dusk then wrap back to day; the settings broadcast re-themes
#            the seat's rail and leg 03's modal-pixel probe proves the
#            repaint on the scanout.
#
# The entering share state is always term_profile=day/theme=light (legs
# 03/04 leave it and every d-run ends having restored it), so the three
# boots are identical in choreography and result — K=3 repetition
# evidence, not three variants. The two trailing echoes are choreography:
# `echo dfin` is the snapshot trigger (~2.5 s of chord pacing after the
# day publish, long past the seat's repaint), `echo ddun` is the run's
# script-expect, giving the kind-4 frame its landing window.
vgate_file script-seatd.txt <<'EOF'
vf rm SESSION.TABS
vf rm SESSION.PANES
vf rm SNAPSHOT.BUNDLE
vf rm SNAPSHOT.RESTORE
set GOMAXPROCS=1
wm
exec -u0 GOTABWM.ELF
EOF

vgate_file script2-d.txt <<'EOF'
exec -u0 GOTERM.ELF
EOF

vgate_file script3-d.txt <<'EOF'
clip
echo rx-d-clip-seen
EOF

vgate_setup_python <<'PY'
import base64, os
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
# The phase-1 payload: three runnable lines, no trailing newline — the
# bracketed submit below is exactly these rows. `seek154d` is the phase-3
# search token: lowercase+digits, all chord-mappable, and it appears only
# inside this payload (never in a typed line), so a search hit can only
# come from the paste.
payload = b"echo row-alpha\necho seek154d-token\necho row-omega"
assert len(payload) == 49, len(payload)
b64 = base64.b64encode(payload).decode()
with open(os.path.join(share, "DCLIP.SH"), "w") as fh:
    fh.write("printf '\\e]52;c;%s\\x07'\n" % b64)
print("seeded DCLIP.SH: OSC 52 c; payload %d B (%d b64 chars)" %
      (len(payload), len(b64)))
PY

vgate_run d1 -- --display --input \
    --screen '$RUN_DIR/screen-d1' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-d1' \
    --script '$RUN_DIR/script-seatd.txt' \
    --script2 '$RUN_DIR/script2-d.txt' \
    --script2-after 'gotabwm: present' \
    --input-string 'source DCLIP.SH'$'\n' \
    --input-string-after 'goterm: prompt' \
    --script3 '$RUN_DIR/script3-d.txt' \
    --script3-after 'goterm: line source DCLIP.SH' --script3-delay 1 \
    --input-chords 'ctrl-shift-v,return,ctrl-shift-f,s,e,e,k,1,5,4,d,escape,t,e,r,m,-,p,r,o,f,i,l,e,space,d,u,s,k,return,t,e,r,m,-,p,r,o,f,i,l,e,space,n,e,x,t,return,e,c,h,o,space,d,f,i,n,return,e,c,h,o,space,d,d,u,n,return' \
    --input-chords-after 'clip: echo row-alpha' \
    --snapshot-after 'goterm: line echo dfin' \
    --script-expect 'goterm: line echo ddun' --timeout 300

vgate_assert d1 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert d1 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert d1 serial-contains 'gotabwm: mode live'
vgate_assert d1 serial-contains 'gotabwm: present'
vgate_assert d1 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert d1 serial-contains 'goterm: attached'
vgate_assert d1 serial-contains 'goterm: prompt'
# Phase 1: the sourced OSC 52 landed in the shared clipboard and the
# monitor read it back (`clip: ` + the payload's first line).
vgate_assert d1 serial-contains 'goterm: line source DCLIP.SH'
vgate_assert d1 serial-contains 'clip: echo row-alpha'
# Phase 2: the bracketed paste — payload + 12 B wrap in one push, one
# submit marker leading with the pasted block's first line.
vgate_assert d1 serial-contains 'tty: paste 61 bytes'
vgate_assert d1 serial-contains 'goterm: line echo row-alpha'
# Phase 3: the search fed its pattern (counts pinned in python below),
# then the profile cycle dusk -> next -> day with the seat's re-theme
# broadcast in between.
vgate_assert d1 serial-contains 'tty: search: '
vgate_assert d1 serial-contains 'goterm: profile dusk'
vgate_assert d1 serial-contains 'goterm: profile day'
vgate_assert d1 serial-contains 'gotabwm: settings broadcast key=theme'
vgate_assert d1 serial-contains 'goterm: line echo dfin'
vgate_assert d1 serial-contains 'goterm: line echo ddun'
vgate_assert d1 serial-absent '[EXC] parking:'
vgate_assert d1 serial-absent 'exited status=139'
vgate_assert d1 share-contains SETTINGS.TXT 'term_profile=day'
vgate_assert d1 share-contains SETTINGS.TXT 'theme=light'
vgate_assert d1 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()

# Phase order: clip readback -> paste push -> ONE submit -> search -> the
# dusk/day cycle -> the two choreography echoes.
i_clip = ser.find("clip: echo row-alpha")
assert i_clip >= 0, "monitor clip never showed the OSC 52 payload"
clip_seg = ser[i_clip:i_clip + 120]
for row in ("echo row-alpha", "echo seek154d-token", "echo row-omega"):
    assert row in clip_seg, "clip readback dropped %r: %r" % (row, clip_seg)

mp = re.search(r"tty: paste (\d+) bytes", ser)
assert mp, "paste marker missing"
n_paste = int(mp.group(1))
assert n_paste == 49 + 12, (
    "paste must be the 49 B payload + the 12 B DECSET wrap (got %d) — "
    "the wrap's presence is bracketed paste being ON at its default" % n_paste)
i_paste = ser.find(mp.group(0))
assert i_paste > i_clip, "paste fired before the clip readback"

i_line = ser.find("goterm: line ", i_paste)
i_done = ser.find("goterm: done status=0", i_line)
assert i_line > i_paste and i_done > i_line, "no submit after the paste"
n_sub = ser.count("goterm: line ", i_paste, i_done)
assert n_sub == 1, "one edit, one submit on Enter (got %d submits)" % n_sub
seg = ser[i_line:i_done]
for row in ("echo row-alpha", "echo seek154d-token", "echo row-omega"):
    assert row in seg, "%r missing from the one submit" % row

# Every fed char klogs its live count; the last one carries the full
# 'seek154d' pattern's match count over the painted block.
i_search = ser.find("tty: search:", i_done)
assert i_search > i_done, "the search ran before the paste submitted"
counts = [int(x) for x in re.findall(r"tty: search: (\d+) matches", ser[i_search:])]
assert counts, "the search bar fed no pattern"
assert counts[-1] >= 1, "full pattern 'seek154d' found %d matches" % counts[-1]

i_dusk = ser.find("goterm: profile dusk", i_search)
assert i_dusk > i_search, "term-profile dusk missing after the search"
i_day = ser.find("goterm: profile day", i_dusk)
assert i_day > i_dusk, "term-profile next did not cycle dusk -> day"
i_dfin = ser.find("goterm: line echo dfin", i_day)
i_ddun = ser.find("goterm: line echo ddun", i_dfin)
assert i_dfin > i_day and i_ddun > i_dfin, "tail echoes out of order"
print("daily loop OK: clip -> paste 61B one submit -> search %d hit(s) -> dusk -> day"
      % counts[-1])
PY

# The rail band's modal pixel is the light theme's chrome — leg 03's probe
# verbatim. The publish's live re-theme is the only thing that lands it
# there after the dusk detour.
vgate_assert d1 snapshot 'snap-d1-*.raw' <<'PY'
import sys
W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot %d bytes, want %d" % (len(raw), W * H * 4))
hist = {}
for y in range(0, 22):
    for x in range(0, W, 2):
        k = (y * W + x) * 4
        px = (raw[k + 2], raw[k + 1], raw[k])
        hist[px] = hist.get(px, 0) + 1
mode = max(hist, key=hist.get)
print("rail modal pixel: #%02x%02x%02x over %d samples" %
      (mode + (hist[mode],)))
if max(mode) <= 0xa0:
    sys.exit("rail band is not the light theme (#%02x%02x%02x) — the "
             "term-profile next publish never reached the seat" % mode)
print("palette probe: rail band is light — the profile cycle re-themed the seat")
PY

vgate_run d2 -- --display --input \
    --screen '$RUN_DIR/screen-d2' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-d2' \
    --script '$RUN_DIR/script-seatd.txt' \
    --script2 '$RUN_DIR/script2-d.txt' \
    --script2-after 'gotabwm: present' \
    --input-string 'source DCLIP.SH'$'\n' \
    --input-string-after 'goterm: prompt' \
    --script3 '$RUN_DIR/script3-d.txt' \
    --script3-after 'goterm: line source DCLIP.SH' --script3-delay 1 \
    --input-chords 'ctrl-shift-v,return,ctrl-shift-f,s,e,e,k,1,5,4,d,escape,t,e,r,m,-,p,r,o,f,i,l,e,space,d,u,s,k,return,t,e,r,m,-,p,r,o,f,i,l,e,space,n,e,x,t,return,e,c,h,o,space,d,f,i,n,return,e,c,h,o,space,d,d,u,n,return' \
    --input-chords-after 'clip: echo row-alpha' \
    --snapshot-after 'goterm: line echo dfin' \
    --script-expect 'goterm: line echo ddun' --timeout 300

vgate_assert d2 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert d2 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert d2 serial-contains 'gotabwm: mode live'
vgate_assert d2 serial-contains 'gotabwm: present'
vgate_assert d2 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert d2 serial-contains 'goterm: attached'
vgate_assert d2 serial-contains 'goterm: prompt'
vgate_assert d2 serial-contains 'goterm: line source DCLIP.SH'
vgate_assert d2 serial-contains 'clip: echo row-alpha'
vgate_assert d2 serial-contains 'tty: paste 61 bytes'
vgate_assert d2 serial-contains 'goterm: line echo row-alpha'
vgate_assert d2 serial-contains 'tty: search: '
vgate_assert d2 serial-contains 'goterm: profile dusk'
vgate_assert d2 serial-contains 'goterm: profile day'
vgate_assert d2 serial-contains 'gotabwm: settings broadcast key=theme'
vgate_assert d2 serial-contains 'goterm: line echo dfin'
vgate_assert d2 serial-contains 'goterm: line echo ddun'
vgate_assert d2 serial-absent '[EXC] parking:'
vgate_assert d2 serial-absent 'exited status=139'
vgate_assert d2 share-contains SETTINGS.TXT 'term_profile=day'
vgate_assert d2 share-contains SETTINGS.TXT 'theme=light'
vgate_assert d2 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()

i_clip = ser.find("clip: echo row-alpha")
assert i_clip >= 0, "monitor clip never showed the OSC 52 payload"
clip_seg = ser[i_clip:i_clip + 120]
for row in ("echo row-alpha", "echo seek154d-token", "echo row-omega"):
    assert row in clip_seg, "clip readback dropped %r: %r" % (row, clip_seg)

mp = re.search(r"tty: paste (\d+) bytes", ser)
assert mp, "paste marker missing"
n_paste = int(mp.group(1))
assert n_paste == 49 + 12, (
    "paste must be the 49 B payload + the 12 B DECSET wrap (got %d) — "
    "the wrap's presence is bracketed paste being ON at its default" % n_paste)
i_paste = ser.find(mp.group(0))
assert i_paste > i_clip, "paste fired before the clip readback"

i_line = ser.find("goterm: line ", i_paste)
i_done = ser.find("goterm: done status=0", i_line)
assert i_line > i_paste and i_done > i_line, "no submit after the paste"
n_sub = ser.count("goterm: line ", i_paste, i_done)
assert n_sub == 1, "one edit, one submit on Enter (got %d submits)" % n_sub
seg = ser[i_line:i_done]
for row in ("echo row-alpha", "echo seek154d-token", "echo row-omega"):
    assert row in seg, "%r missing from the one submit" % row

i_search = ser.find("tty: search:", i_done)
assert i_search > i_done, "the search ran before the paste submitted"
counts = [int(x) for x in re.findall(r"tty: search: (\d+) matches", ser[i_search:])]
assert counts, "the search bar fed no pattern"
assert counts[-1] >= 1, "full pattern 'seek154d' found %d matches" % counts[-1]

i_dusk = ser.find("goterm: profile dusk", i_search)
assert i_dusk > i_search, "term-profile dusk missing after the search"
i_day = ser.find("goterm: profile day", i_dusk)
assert i_day > i_dusk, "term-profile next did not cycle dusk -> day"
i_dfin = ser.find("goterm: line echo dfin", i_day)
i_ddun = ser.find("goterm: line echo ddun", i_dfin)
assert i_dfin > i_day and i_ddun > i_dfin, "tail echoes out of order"
print("daily loop OK: clip -> paste 61B one submit -> search %d hit(s) -> dusk -> day"
      % counts[-1])
PY

vgate_assert d2 snapshot 'snap-d2-*.raw' <<'PY'
import sys
W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot %d bytes, want %d" % (len(raw), W * H * 4))
hist = {}
for y in range(0, 22):
    for x in range(0, W, 2):
        k = (y * W + x) * 4
        px = (raw[k + 2], raw[k + 1], raw[k])
        hist[px] = hist.get(px, 0) + 1
mode = max(hist, key=hist.get)
print("rail modal pixel: #%02x%02x%02x over %d samples" %
      (mode + (hist[mode],)))
if max(mode) <= 0xa0:
    sys.exit("rail band is not the light theme (#%02x%02x%02x) — the "
             "term-profile next publish never reached the seat" % mode)
print("palette probe: rail band is light — the profile cycle re-themed the seat")
PY

vgate_run d3 -- --display --input \
    --screen '$RUN_DIR/screen-d3' \
    --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-d3' \
    --script '$RUN_DIR/script-seatd.txt' \
    --script2 '$RUN_DIR/script2-d.txt' \
    --script2-after 'gotabwm: present' \
    --input-string 'source DCLIP.SH'$'\n' \
    --input-string-after 'goterm: prompt' \
    --script3 '$RUN_DIR/script3-d.txt' \
    --script3-after 'goterm: line source DCLIP.SH' --script3-delay 1 \
    --input-chords 'ctrl-shift-v,return,ctrl-shift-f,s,e,e,k,1,5,4,d,escape,t,e,r,m,-,p,r,o,f,i,l,e,space,d,u,s,k,return,t,e,r,m,-,p,r,o,f,i,l,e,space,n,e,x,t,return,e,c,h,o,space,d,f,i,n,return,e,c,h,o,space,d,d,u,n,return' \
    --input-chords-after 'clip: echo row-alpha' \
    --snapshot-after 'goterm: line echo dfin' \
    --script-expect 'goterm: line echo ddun' --timeout 300

vgate_assert d3 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert d3 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert d3 serial-contains 'gotabwm: mode live'
vgate_assert d3 serial-contains 'gotabwm: present'
vgate_assert d3 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert d3 serial-contains 'goterm: attached'
vgate_assert d3 serial-contains 'goterm: prompt'
vgate_assert d3 serial-contains 'goterm: line source DCLIP.SH'
vgate_assert d3 serial-contains 'clip: echo row-alpha'
vgate_assert d3 serial-contains 'tty: paste 61 bytes'
vgate_assert d3 serial-contains 'goterm: line echo row-alpha'
vgate_assert d3 serial-contains 'tty: search: '
vgate_assert d3 serial-contains 'goterm: profile dusk'
vgate_assert d3 serial-contains 'goterm: profile day'
vgate_assert d3 serial-contains 'gotabwm: settings broadcast key=theme'
vgate_assert d3 serial-contains 'goterm: line echo dfin'
vgate_assert d3 serial-contains 'goterm: line echo ddun'
vgate_assert d3 serial-absent '[EXC] parking:'
vgate_assert d3 serial-absent 'exited status=139'
vgate_assert d3 share-contains SETTINGS.TXT 'term_profile=day'
vgate_assert d3 share-contains SETTINGS.TXT 'theme=light'
vgate_assert d3 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], errors="replace").read()

i_clip = ser.find("clip: echo row-alpha")
assert i_clip >= 0, "monitor clip never showed the OSC 52 payload"
clip_seg = ser[i_clip:i_clip + 120]
for row in ("echo row-alpha", "echo seek154d-token", "echo row-omega"):
    assert row in clip_seg, "clip readback dropped %r: %r" % (row, clip_seg)

mp = re.search(r"tty: paste (\d+) bytes", ser)
assert mp, "paste marker missing"
n_paste = int(mp.group(1))
assert n_paste == 49 + 12, (
    "paste must be the 49 B payload + the 12 B DECSET wrap (got %d) — "
    "the wrap's presence is bracketed paste being ON at its default" % n_paste)
i_paste = ser.find(mp.group(0))
assert i_paste > i_clip, "paste fired before the clip readback"

i_line = ser.find("goterm: line ", i_paste)
i_done = ser.find("goterm: done status=0", i_line)
assert i_line > i_paste and i_done > i_line, "no submit after the paste"
n_sub = ser.count("goterm: line ", i_paste, i_done)
assert n_sub == 1, "one edit, one submit on Enter (got %d submits)" % n_sub
seg = ser[i_line:i_done]
for row in ("echo row-alpha", "echo seek154d-token", "echo row-omega"):
    assert row in seg, "%r missing from the one submit" % row

i_search = ser.find("tty: search:", i_done)
assert i_search > i_done, "the search ran before the paste submitted"
counts = [int(x) for x in re.findall(r"tty: search: (\d+) matches", ser[i_search:])]
assert counts, "the search bar fed no pattern"
assert counts[-1] >= 1, "full pattern 'seek154d' found %d matches" % counts[-1]

i_dusk = ser.find("goterm: profile dusk", i_search)
assert i_dusk > i_search, "term-profile dusk missing after the search"
i_day = ser.find("goterm: profile day", i_dusk)
assert i_day > i_dusk, "term-profile next did not cycle dusk -> day"
i_dfin = ser.find("goterm: line echo dfin", i_day)
i_ddun = ser.find("goterm: line echo ddun", i_dfin)
assert i_dfin > i_day and i_ddun > i_dfin, "tail echoes out of order"
print("daily loop OK: clip -> paste 61B one submit -> search %d hit(s) -> dusk -> day"
      % counts[-1])
PY

vgate_assert d3 snapshot 'snap-d3-*.raw' <<'PY'
import sys
W, H = 1280, 720
raw = open(sys.argv[1], "rb").read()
if len(raw) < W * H * 4:
    sys.exit("snapshot %d bytes, want %d" % (len(raw), W * H * 4))
hist = {}
for y in range(0, 22):
    for x in range(0, W, 2):
        k = (y * W + x) * 4
        px = (raw[k + 2], raw[k + 1], raw[k])
        hist[px] = hist.get(px, 0) + 1
mode = max(hist, key=hist.get)
print("rail modal pixel: #%02x%02x%02x over %d samples" %
      (mode + (hist[mode],)))
if max(mode) <= 0xa0:
    sys.exit("rail band is not the light theme (#%02x%02x%02x) — the "
             "term-profile next publish never reached the seat" % mode)
print("palette probe: rail band is light — the profile cycle re-themed the seat")
PY

# --- issue #3251: notify-on-finish -----------------------------------------
# One input burst types three commands; the M98f interrupter's type-ahead
# stash parks the later lines while a foreground child runs, so they
# submit in order as each finishes — all three halves of the bet in one
# boot:
#
#   sleep 6   runs while the tab is FOCUSED -> silence (watching earns it)
#   sleep 7   runs while blurred -> the toast
#   cd /data  runs blurred but fast -> silence (under the 5 s threshold)
#
# `dui cycle` rides script3 off the `sleep 7` submit marker, so the blur
# lands inside its 7-second window — the kernel's focus id is what the
# app's WinQuery reads when the engine answers. The toast click is
# go-clock run 02's recipe: slot-0's centre (112,702) on the painted
# toast dismisses it and click-through refocuses the sender. The boot
# recipe is leg 03's — SESSION.TABS/PANES are removed so the seat comes
# up live, never restore.

vgate_file script-seat5.txt <<'EOF'
vf rm SESSION.TABS
vf rm SESSION.PANES
set GOMAXPROCS=1
wm
exec -u0 GOTABWM.ELF
EOF

vgate_file script2-05.txt <<'EOF'
exec -u0 GOTERM.ELF
EOF

vgate_file script3-05.txt <<'EOF'
dui cycle
EOF

vgate_run 05 -- --display --input \
    --screen '$RUN_DIR/screen-05' \
    --via-virtio \
    --script '$RUN_DIR/script-seat5.txt' \
    --script2 '$RUN_DIR/script2-05.txt' \
    --script2-after 'gotabwm: present' \
    --input-chords 's,l,e,e,p,space,6,return,s,l,e,e,p,space,7,return,c,d,space,/,d,a,t,a,return' \
    --input-chords-after 'goterm: prompt' \
    --script3 '$RUN_DIR/script3-05.txt' \
    --script3-after 'goterm: line sleep 7' \
    --pointer-virtio '112,702,d;112,702,u' \
    --pointer-virtio-after 'gotabwm: notify paint id=' \
    --script-expect 'gotabwm: notify dismiss id=' --timeout 300

vgate_assert 05 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 05 serial-contains 'gotabwm: mode live'
vgate_assert 05 serial-contains 'gotabwm: present'
vgate_assert 05 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 05 serial-contains 'goterm: attached'
vgate_assert 05 serial-contains 'goterm: prompt'
vgate_assert 05 serial-contains 'goterm: line sleep 6'
vgate_assert 05 serial-contains 'goterm: line sleep 7'
vgate_assert 05 serial-contains 'goterm: line cd /data'
# The blur landed while sleep 7 still owned the foreground.
vgate_assert 05 serial-contains 'dui: cycle focused='
# The app's own receipt, printed AFTER the seat acked the request — the
# gofiles two-sided contract; its absence next to a refused marker would
# mean the toast died on the wire.
vgate_assert 05 serial-contains 'goterm: notify sent sleep exited st=0 in '
vgate_assert 05 serial-absent 'goterm: notify refused'
vgate_assert 05 serial-contains 'gotabwm: notify paint id='
vgate_assert 05 serial-contains 'gotabwm: notify dismiss id='
vgate_assert 05 serial-contains 'gotabwm: tab focus id='
vgate_assert 05 serial-contains 'gotabwm: host focus id='
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'

# The ordering + silence + identity proof in one pass: sleep 6 finished
# focused and posted nothing; the blur sat inside sleep 7's run; the toast
# that posted is sleep 7's — same window id queued, painted, dismissed and
# refocused — and cd /data's blurred-but-fast exit earned nothing either.
# The focus legs are the FIRST occurrences AFTER the dismiss (adoption
# prints both at exec time, the go-clock run-02 trap).
vgate_assert 05 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

def at(pat, what, start=0):
    m = re.compile(pat).search(ser, start)
    if not m:
        sys.exit("no %s in the serial log" % what)
    return m

sub6   = at(r"(?m)^goterm: line sleep 6$", "sleep 6 submit")
done6  = at(r"(?m)^goterm: done status=0$", "sleep 6 done", sub6.end())
sub7   = at(r"(?m)^goterm: line sleep 7$", "sleep 7 submit", done6.end())
blur   = at(r"(?m)^dui: cycle focused=(\d+)$", "blur marker", sub7.end())
done7  = at(r"(?m)^goterm: done status=0$", "sleep 7 done", blur.end())
sent   = at(r"(?m)^goterm: notify sent sleep exited st=0 in (\d+)s$",
            "app notify marker", done7.end())
subcd  = at(r"(?m)^goterm: line cd /data$", "cd submit", sent.end())
donecd = at(r"(?m)^goterm: done status=0$", "cd done", subcd.end())
queued = at(r"(?m)^gotabwm: notify id=(\d+) sleep exited st=0 in (\d+)s$",
            "seat queue line")
painted  = at(r"(?m)^gotabwm: notify paint id=(\d+)$", "toast paint", queued.end())
dismiss  = at(r"(?m)^gotabwm: notify dismiss id=(\d+)$", "toast dismiss", painted.end())
tabfoc   = at(r"(?m)^gotabwm: tab focus id=(\d+)$", "tab focus", dismiss.end())
hostfoc  = at(r"(?m)^gotabwm: host focus id=(\d+)$", "host focus", dismiss.end())

# The toast's dur is the app's own measure of sleep 7 — a 7 s park at
# 1 Hz ticks can only land inside [6, 9] — and the seat's queue line
# carries the identical text (the 24-byte title fits it whole).
dur = int(sent.group(1))
if not (6 <= dur <= 9):
    sys.exit("toast dur = %ds — not a plausible sleep-7 measure" % dur)
if queued.group(2) != sent.group(1):
    sys.exit("the seat's toast text disagrees with the app's marker")

wid = queued.group(1)
for name, m in (("paint", painted), ("dismiss", dismiss),
                ("tab focus", tabfoc), ("host focus", hostfoc)):
    if m.group(1) != wid:
        sys.exit("the %s marker names id=%s, want the sender id=%s"
                 % (name, m.group(1), wid))

# Earnable silence: exactly one notify marker in the whole run — sleep 6
# (focused) and cd /data (under threshold) both earned nothing.
n_sent = len(re.findall(r"(?m)^goterm: notify sent ", ser))
if n_sent != 1:
    sys.exit("%d 'notify sent' markers — focused or fast commands posted"
             % n_sent)
print("notify chain OK: sleep6 focused -> silence; sleep7 blurred -> "
      "toast %ds id=%s -> click -> focused; cd blurred fast -> silence"
      % (dur, wid))
PY

# --- M190d (#3239) run 09: the menubar over the bound tty — F10 reaches
# the app as ESC[21~, engages the alternate-screen bar, right right lands
# on View, down opens it, return fires Chord hints: the identical '?' face
# and its registry receipts the bare-'?' path prints.
vgate_file script2-09.txt <<'EOFS'
exec GOTERM.ELF
EOFS

vgate_file script3-09.txt <<'EOFS'
dui close 2
echo rx-goterm-menu-ok
EOFS

vgate_run 09 -- \
    --screen '$RUN_DIR/screen-09' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2-09.txt' --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'f10,right,right,down,return' \
    --input-chords-after 'goterm: prompt' \
    --script3 '$RUN_DIR/script3-09.txt' --script3-after 'goterm: hints n=' \
    --script-expect 'rx-goterm-menu-ok' --timeout 240

vgate_assert 09 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 09 serial-contains 'goterm: menubar open'
vgate_assert 09 serial-contains 'goterm: hints n=53'
vgate_assert 09 serial-contains 'goterm: close'
vgate_assert 09 serial-contains 'rx-goterm-menu-ok'
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 serial-absent 'exited status=139'

# --- M191a (#3242): GOTERM scrollback find ----------------------------------
# One seated boot drives the whole bet against the app's own serial
# markers — the alt-screen overlay paints grid cells, which serial never
# sees (ADR 0020 selector 2), so the receipts are the app's, printed
# after the fact they name:
#
#   phase 1  a sourced script seeds 60 KNOWN rows into the scrollback
#            (seed191a-N), well past the visible fold.
#   phase 2  ctrl-shift-g opens the bar — the kernel's tty encoder folds
#            shift out of ctrl-letters, so the chord rides the wire as
#            BEL and the app opens its find session (marker: find open).
#   phase 3  the pattern chars type in (s,e,e,d,1,9,1,a), each edit
#            klogging the live count (`find n=`), the last one the full
#            pattern's 60 hits.
#   phase 4  return steps to a hit (`find hit` cur=1/60, the row below
#            the fold — scrollback); n steps forward (cur=2), and N —
#            shift+n, the runner's chord vocabulary maps it — steps back
#            (cur=1 again): the n/N cycle.
#   phase 5  escape closes the bar (`find close`), the editor repaints,
#            and one more submitted echo proves the prompt came back.
#
# The hit marker's row/top are corpus coordinates relative to the fold
# (negative = scrollback above the visible grid), so the python assert
# proves the hit sits BELOW the fold and INSIDE the window the bar
# scrolled to it — the card's scroll-to-hit, in the app's own copy of
# the surface. The kernel grid's view offset is not reachable from a
# bound app (no scroll seam exists); the PR says so plainly.

vgate_file script2-06.txt <<'EOF'
exec -u0 GOTERM.ELF
EOF

vgate_file script3-06.txt <<'EOF'
echo rx-goterm-find-ok
EOF

vgate_setup_python <<'PY'
import os
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
# 60 seed rows: unique, chord-typable when needed, and a token that only
# exists in the SEEDED scrollback (never in a typed line), so a hit can
# only come from the ring.
with open(os.path.join(share, "SEED191A.SH"), "w") as fh:
    for i in range(60):
        fh.write("echo seed191a-%02d\n" % i)
print("seeded SEED191A.SH (60 rows)")
PY

vgate_run 06 -- --display --input \
    --screen '$RUN_DIR/screen-06' \
    --via-virtio \
    --script '$RUN_DIR/script-seat5.txt' \
    --script2 '$RUN_DIR/script2-06.txt' \
    --script2-after 'gotabwm: present' \
    --input-string $'source SEED191A.SH\n' \
    --input-string-after 'goterm: prompt' \
    --input-chords 'ctrl-shift-g,s,e,e,d,1,9,1,a,return,n,shift-n,escape,e,c,h,o,space,f,i,n,d,o,n,e,return' \
    --input-chords-after 'goterm: line source SEED191A.SH' \
    --script3 '$RUN_DIR/script3-06.txt' \
    --script3-after 'goterm: find close' \
    --script-expect 'rx-goterm-find-ok' --timeout 300

vgate_assert 06 serial-contains 'exec: loaded GOTABWM.ELF'
vgate_assert 06 serial-contains 'gotabwm: present'
vgate_assert 06 serial-contains 'exec: loaded GOTERM.ELF'
vgate_assert 06 serial-contains 'goterm: attached'
vgate_assert 06 serial-contains 'goterm: prompt'
vgate_assert 06 serial-contains 'goterm: line source SEED191A.SH'
# The bar opened, narrowed live, and closed after the prompt returned.
vgate_assert 06 serial-contains 'goterm: find open'
vgate_assert 06 serial-contains 'goterm: find n='
vgate_assert 06 serial-contains 'goterm: find hit '
vgate_assert 06 serial-contains 'goterm: find close'
# The post-close echo submitted through the restored prompt.
vgate_assert 06 serial-contains 'goterm: line echo findone'
vgate_assert 06 serial-contains 'rx-goterm-find-ok'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'
# The whole chain in order, with the counts and geometry proven:
#   open after the seed's done marker, the live count climbing to 60
#   (seeded rows only — the typed lines never contain the token), the
#   first Step landing on a hit BELOW the fold (row<0: scrollback), the
#   n/N cycle (cur 1 -> 2 -> 1), close, then the restored prompt's echo.
vgate_assert 06 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()

def at(pat, what, start=0):
    m = re.compile(pat).search(ser, start)
    if not m:
        sys.exit("no %s in the serial log" % what)
    return m

seed_done = at(r"(?m)^goterm: done status=0$", "seed source done")
opened    = at(r"(?m)^goterm: find open$", "find open", seed_done.end())
counts    = [int(x) for x in re.findall(r"(?m)^goterm: find n=(\d+)$", ser[opened.end():])]
if not counts:
    sys.exit("the bar typed no pattern")
if counts[-1] != 60:
    sys.exit("full-pattern count = %d, want 60 (the seeded rows alone)" % counts[-1])

hit1  = at(r"(?m)^goterm: find hit cur=(\d+)/(\d+) row=(-?\d+) top=(-?\d+)$",
           "first hit", opened.end())
cur1, tot1, row1, top1 = (int(hit1.group(i)) for i in (1, 2, 3, 4))
if tot1 != 60 or cur1 != 1:
    sys.exit("first hit cur=%d/%d, want 1/60" % (cur1, tot1))
if row1 >= 0:
    sys.exit("first hit row=%d is at/above the fold — the seeded rows "
             "must sit in scrollback" % row1)
if not (top1 <= row1 < top1 + 20):
    sys.exit("hit row=%d outside its window (top=%d) — no scroll-to-hit"
             % (row1, top1))

hit2 = at(r"(?m)^goterm: find hit cur=(\d+)/(\d+) row=(-?\d+) top=(-?\d+)$",
          "n step hit", hit1.end())
if int(hit2.group(1)) != 2:
    sys.exit("after n: cur=%s, want 2 (forward cycle)" % hit2.group(1))
hit3 = at(r"(?m)^goterm: find hit cur=(\d+)/(\d+) row=(-?\d+) top=(-?\d+)$",
          "N step hit", hit2.end())
if int(hit3.group(1)) != 1:
    sys.exit("after N: cur=%s, want 1 (backward cycle)" % hit3.group(1))

closed = at(r"(?m)^goterm: find close$", "find close", hit3.end())
echo   = at(r"(?m)^goterm: line echo findone$", "post-close echo", closed.end())
rx     = at(r"(?m)^rx-goterm-find-ok$", "run receipt", echo.end())
print("find chain OK: open -> n=%d live -> hit 1/60 row=%d (below fold, "
      "in window top=%d) -> n 2/60 -> N 1/60 -> close -> prompt back"
      % (counts[-1], row1, top1))
PY
