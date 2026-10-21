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

vgate_name go-term "issue #1307 M58c: a Go terminal attaches /dev/tty selector 2 in Zig TABWM on VZ"
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
