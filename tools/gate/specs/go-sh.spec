# go-sh.spec -- M68a (issue #1449) class-B gate: GOSH, the Go shell, hosts
# the M49 daily-use bar as a tabapp window in Zig TABWM. The seeded
# STARTUP.SH drives the scripting subset through the same engine a typed
# line uses: env/variables, one pipe, and > redirects (each read back ON
# THE HOST, byte-equal), a foreground exec whose status arrives through $?,
# and a background job cycled through jobs/fg. Then the harness types at
# the prompt: a fresh line, a Backspace edit, and a reverse-i-search recall
# edited by one character -- each visible as its own `gosh: line ` marker.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gosh.sh   ->  .build/go/GOSH.ELF
#
# exec-order: assert-proven -- the run ends on `rx-gosh-ok`, which only the
# stage script prints, and the stage gate waits on `gosh: line echo ay`,
# which only the typed recall can produce; a shell that never ran cannot pass.

vgate_name go-sh "issue #1449 M68a: GOSH runs the M49 bar as a tab (exec, pipe, redirect, jobs/fg, editing) on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec GOSH.ELF
EOF

# The close is driven from the harness after the typed-history marker, so
# every interactive line reached the shell before the window closes.
vgate_file script3.txt <<'EOF'
dui close 2
echo rx-gosh-ok
EOF

# M81c (#1763): GOSH's headless `-c` runs the same shell engine without its
# startup children. Each boot opens exactly one app; the stage gate waits for
# that app's own first-frame marker before the monitor closes its window.
vgate_file open-file.txt <<'EOF'
exec GOSH.ELF -c "open README.TXT"
EOF

vgate_file close-opened-file.txt <<'EOF'
dui close 2
echo rx-gosh-open-file-ok
EOF

vgate_file open-https.txt <<'EOF'
exec GOSH.ELF -c "open https://example.com/"
EOF

vgate_file close-opened-web.txt <<'EOF'
dui close 2
echo rx-gosh-open-https-ok
EOF

vgate_file log-help.expected <<'EOF'
log — read one app's bounded log ring, or all app rings
usage: log [APP]
EOF

vgate_file open-unknown.txt <<'EOF'
exec GOSH.ELF -c "open SAVE.ZIP"
EOF

vgate_file finish-open-unknown.txt <<'EOF'
echo rx-gosh-open-unknown-ok
EOF

# M81e2 (#1787) added two lines to the startup script below, and they are
# the redirect decision pinned on the share. `>` is now a crash-safe
# publish, so `echo shrunk-body > /host/GOOSHSHRINK.TXT` runs against a body
# the setup hook seeded LONG (800 B) and must leave EXACTLY the 13 B new body
# -- the share-equals assert is byte-equal, so a surviving tail fails rather
# than passes. `echo first-appended >> /host/GOSHVARS.TXT` then appends to
# the redirect above, so GOSHVARS.TXT reads back as body-plus-one-line; an
# append that replaced would show only the appended line. Neither may leave
# a `~` temp beside it (the last python assert).
#
# NOTE for the next editor: do NOT put comments inside this heredoc. The
# startup block is a GUEST script run by shlib, where a leading `#` is a
# parse-level no-op but is still submitted as a line -- so it lands in the
# history ring and shifts the Up-arrow recall the typed-chord choreography
# so it lands in the history ring and changes the session history. Comments
# belong in this prose, above the heredoc.

# Seed one known history entry before GOSH opens its editor. The first live
# Up/Return is a transport probe: if the key path works, a non-empty history
# MUST submit this line. This separates a lost Up chord from an empty live
# history ring before the following typed-line history regression.
vgate_file GOSH-HISTORY.TXT <<'EOF'
echo history-seed
EOF
# The startup contract: STARTUP.SH (then PROFILE.SH, absent here) runs
# before the first prompt. `exec` inside GOSH is the monitor vocabulary --
# it runs the named ELF; the -c child form is GOSH's own headless mode
# (no window, no tty, exits with the line's status). Two children, in this
# order: the foreground `exit 7` pins exec+wait status propagation through
# $?; the background `echo nested-child-ok` cycles the job table
# (jobs -> fg) AND proves a child's own console output reaches the serial
# log -- the old `sleep 2` there printed nothing, which is why the
# `nested-child-ok` assert below could never fire. A THIRD
# sequential exec from one EL0 parent currently dies in the Go runtime's
# own schedinit (observed twice: "refill of span with reusable pointers"
# -> fatal exit 2) -- surfaced by this card, documented on #1449, follow-up
# owed to the runtime/kernel owners; this scenario stays at two children
# until that lands.
vgate_file STARTUP.SH <<'EOF'
echo gosh-startup-ran
help log > /host/GOSHHELP.TXT
date > /host/GOSHDATE.TXT
set GREET=hello-vars
echo V=$GREET > /host/GOSHVARS.TXT
echo shrunk-body > /host/GOOSHSHRINK.TXT
echo first-appended >> /host/GOSHVARS.TXT
cat <<HDOC > /host/GOSHHDOC.TXT
expanded $GREET
HDOC
cat <<'QT' >> /host/GOSHHDOC.TXT
literal $GREET
QT
echo alpha-beta | grep alpha > /host/GOSHPIPE.TXT
exec GOSH.ELF -c "exit 7"
echo rc=$? > /host/GOSHRC.TXT
log > /host/GOSHLOG.TXT
exec GOSH.ELF -c "echo nested-child-ok" &
jobs
fg 1
echo jobrc=$? > /host/GOSHJOB.TXT
EOF

vgate_setup_python <<'PY'
import os, shutil, sys, time
rd = os.environ["RUN_DIR"]
with open(os.path.join(rd, "host-epoch-start.txt"), "w") as fh:
    fh.write(str(time.time()))
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOSH.ELF")
if not os.path.exists(src):
    sys.exit("GOSH.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gosh.sh")
for name, build in (
    ("GOSH.ELF", "bash tools/go/build-gosh.sh"),
    ("GOEDIT.ELF", "bash tools/go/build-goedit.sh"),
    ("WEB.ELF", "bash tools/go/build-web.sh browser"),
):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: " + build)
    shutil.copy(src, os.path.join(share, name))
shutil.copy(os.path.join(rd, "STARTUP.SH"), os.path.join(share, "STARTUP.SH"))
# M138a (#2775): the unterminated-heredoc script the run-06 -c child sources.
shutil.copy(os.path.join(rd, "GOSHUNTERM.SH"), os.path.join(share, "GOSHUNTERM.SH"))
# M81e2 (#1787): seed the shrink target LONG, so STARTUP.SH's
# `echo shrunk-body > /host/GOOSHSHRINK.TXT` is a replace that SHRINKS. An
# in-place writer that opens without truncating leaves the tail of this body
# behind, and share-equals below is a byte-EQUAL check, so it would fail.
with open(os.path.join(share, "GOOSHSHRINK.TXT"), "w") as fh:
    fh.write("PREEXISTING-LONG-BODY\n" * 40)
with open(os.path.join(share, "README.TXT"), "w") as fh:
    fh.write("open-contract-text\n")
with open(os.path.join(share, "SAVE.ZIP"), "wb") as fh:
    fh.write(b"PK\x03\x04\x00\x02")
shutil.copy(os.path.join(rd, "GOSH-HISTORY.TXT"),
            os.path.join(share, "GOSH-HISTORY.TXT"))
print("staged GOSH.ELF, GOEDIT.ELF, WEB.ELF + STARTUP.SH and history fixture")
PY

# The first Up/Return submits the seeded history entry as a live transport
# probe. Then the typed-line sequence uses reverse-i-search to recall lines,
# exercising the current editor behavior while keeping the raw Up path pinned.
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'up,return,e,c,h,o,space,a,b,c,return,ctrl-r,e,c,h,o,return,backspace,backspace,z,return,ctrl-r,e,c,h,o,return,backspace,y,return' \
    --input-chords-after 'gosh: prompt' \
    --script3 '$RUN_DIR/script3.txt' \
    --script3-after 'gosh: line echo ay' \
    --script-expect 'rx-gosh-ok' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOSH.ELF'
vgate_assert 01 serial-contains 'gosh: ready'
vgate_assert 01 serial-contains 'gosh: open id='
vgate_assert 01 serial-contains 'gosh: declare accepted'
vgate_assert 01 serial-contains 'gosh: tty'
vgate_assert 01 serial-contains 'gosh: attached'
# The startup contract ran before the first prompt; its lines are visible
# as the same `gosh: line ` markers a typed line gets.
vgate_assert 01 serial-contains 'gosh: line echo gosh-startup-ran'
vgate_assert 01 serial-contains 'gosh: line date > /host/GOSHDATE.TXT'
vgate_assert 01 serial-contains 'gosh: prompt'
vgate_assert 01 serial-contains 'gosh: line echo history-seed'
vgate_assert 01 serial-contains 'gosh: job 1 pid='
vgate_assert 01 serial-contains 'gosh: job 1 done exit=0'
# The four markers neither existing kind can carry honestly -- the child's own
# console output and the three typed lines -- matched at LINE START by a
# python hook:
#  * `serial-exact` (whole line) is unusable for a guest CONSOLE line. The
#    guest's console write races the kernel's own log writes, which land on
#    the tail of the same serial line. Observed 1 run in 8:
#    `gosh: line echo azsmp: steal runs=50 task=GOSH.ELF from=0` -- the marker
#    was printed and grep -x counted 0.
#  * `serial-contains` cannot carry them either: the staged line
#    `gosh: line exec GOSH.ELF -c "echo nested-child-ok" &` contains the
#    child's marker, and `gosh: line echo az` is a substring of
#    `gosh: line echo azx` -- both would pass with no work done.
# Anchoring at ^ excludes every line that merely CONTAINS the text (the
# parent's staged line starts with `gosh: line exec`), and tolerating a tail
# keeps the interleaved case passing. The typed markers are prefix-free, so no
# marker can be satisfied by another marker's line.
vgate_assert 01 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], errors="replace").read()
wants = {
    "nested-child-ok": "the background child's own console output",
    "gosh: line echo abc": "typed line 1 (a fresh line, submitted)",
    "gosh: line echo az": "typed line 2 (reverse-i-search, two Backspaces, z)",
    "gosh: line echo ay": "typed line 3 (reverse-i-search of echo az, Backspace, y)",
}
missing = [w for w in wants if not re.search(r"(?m)^" + re.escape(w), ser)]
if missing:
    sys.exit("marker(s) never printed at line start: " + ", ".join(
        "%s (%s)" % (w, wants[w]) for w in missing))
PY
vgate_assert 01 serial-contains 'gosh: close'
vgate_assert 01 serial-contains 'gosh OK'
vgate_assert 01 serial-contains 'rx-gosh-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
# The scripting subset's byte proof ON THE HOST, byte-EQUAL rather than
# contains -- `rc=7` would also have matched `rc=70`. The share files carry
# the trailing newline the typed echo wrote, hence the $'...' literals.
# `>>` appended AFTER the `>` redirect above, so the file is the redirect's
# body plus one appended line -- an append that replaced instead would read
# back as just `first-appended`.
# M138a (#2775): the two heredoc bodies above land byte-equal — the first
# expands $GREET the way any unquoted <<WORD body does, the second keeps
# $GREET literal because 'QT' was a quoted delimiter. An expander that ran
# on the quoted body (or skipped the unquoted one) flips a byte and fails.
vgate_assert 01 serial-contains 'gosh: line cat <<HDOC > /host/GOSHHDOC.TXT'
vgate_assert 01 share-equals GOSHHDOC.TXT $'expanded hello-vars\nliteral $GREET\n'
vgate_assert 01 share-equals GOSHVARS.TXT $'V=hello-vars\nfirst-appended\n'
vgate_assert 01 share-equals GOSHPIPE.TXT $'alpha-beta\n'
vgate_assert 01 share-equals GOSHRC.TXT $'rc=7\n'
vgate_assert 01 share-contains GOSHLOG.TXT 'GOSH.ELF:'
vgate_assert 01 share-equals GOSHHELP.TXT log-help.expected
vgate_assert 01 share-equals GOSHJOB.TXT $'jobrc=0\n'
# The live date is dynamic. Pin its formatting against the epoch it printed
# and compare that epoch to the host's own pre/post run samples. The face is
# the `timezone` row's (M83c #1776): this boot carries no settings file, so
# the label must be the UTC default and the face the epoch itself. Run 05 is
# the second zone. No NTP conclusion follows from either.
vgate_assert 01 python <<'PY'
import datetime, os, re, shutil, time
rd = os.environ["RUN_DIR"]
with open(os.path.join(os.environ["VG_SHARE"], "GOSHDATE.TXT"), "rb") as fh:
    line = fh.read()
m = re.fullmatch(rb"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (UTC(?:[+-]\d\d:\d\d)?) \(epoch=([0-9]+)\)\n", line)
if not m:
    raise SystemExit("date did not print a calendar face + zone + epoch: %r" % line)
if m.group(2) != b"UTC":
    raise SystemExit("a boot with no timezone row must print UTC, got %r" % m.group(2))
epoch = int(m.group(3))
face = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
if m.group(1).decode() != face.strftime("%Y-%m-%d %H:%M:%S"):
    raise SystemExit("date face %r disagrees with epoch %d" % (m.group(1), epoch))
with open(os.path.join(rd, "host-epoch-start.txt")) as fh:
    host_start = float(fh.read())
host_end = time.time()
if not host_start - 60 <= epoch <= host_end + 60:
    raise SystemExit("date epoch %d outside host interval [%d, %d] with 60 s slack" %
                     (epoch, host_start, host_end))
shutil.copy(os.path.join(os.environ["VG_SHARE"], "GOSHDATE.TXT"),
            "artifacts/go-sh-share-date.txt")
print("date epoch %d agrees with the UTC face and lies within 60 s of host [%d, %d]" %
      (epoch, host_start, host_end))
PY
# M81e2 (#1787): the redirect decision, pinned on the share. `>` published
# crash-safe, so over a 800 B pre-existing body the file must read back as
# EXACTLY the 13 B new body -- byte-equal, so a surviving tail fails rather
# than passes. The sacrificial temp must not be there either: a share holding
# an orphan is a share a human has to clean by hand.
vgate_assert 01 share-equals GOOSHSHRINK.TXT $'shrunk-body\n'
vgate_assert 01 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
# Scoped to the paths THIS script redirects to, not a blanket scan of the
# share: the safe publish writes path+"~", so an orphan beside any of these
# is a publish that did not finish. A share-wide scan would also assert other
# components' publish hygiene, which is not what this run is here to prove.
stray = [n for n in sorted(os.listdir(share))
         if n.endswith("~") and n[:-1] in
         ("GOOSHSHRINK.TXT", "GOSHVARS.TXT", "GOSHPIPE.TXT", "GOSHRC.TXT",
          "GOSHJOB.TXT")]
if stray:
    sys.exit("orphan publish temp(s) beside a redirect target: " +
             ", ".join(stray) + " - the publish did not complete")
PY

# --- M81c (#1763): the shared GOSH `open` contract -------------------------
# File path -> the registered text handler. The handler's own frame marker
# is the close barrier, and the exit script closes its first user window.
vgate_run 02 -- \
    --screen '$RUN_DIR/screen-open-file' \
    --script '$RUN_DIR/open-file.txt' \
    --script2 '$RUN_DIR/close-opened-file.txt' \
    --script2-after 'goedit: present' \
    --script-expect 'rx-gosh-open-file-ok' --timeout 240

vgate_assert 02 serial-contains 'gosh: open launched scheme=file target=/host/README.TXT handler=GOEDIT.ELF pid='
vgate_assert 02 serial-contains 'goedit: read /host/README.TXT n=19'
vgate_assert 02 serial-contains 'goedit: present'
vgate_assert 02 serial-contains 'dui close: closed=2'
vgate_assert 02 serial-contains 'rx-gosh-open-file-ok'
vgate_assert 02 serial-absent 'gosh: open refused'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# HTTPS -> WEB.ELF. example.com deliberately reaches WEB's named DNS refusal:
# this proves routing without pretending this browser slice resolves names.
vgate_run 03 -- \
    --screen '$RUN_DIR/screen-open-https' \
    --script '$RUN_DIR/open-https.txt' \
    --script2 '$RUN_DIR/close-opened-web.txt' \
    --script2-after 'web: ready' \
    --script-expect 'rx-gosh-open-https-ok' --timeout 240

vgate_assert 03 serial-contains 'gosh: open launched scheme=https target=https://example.com/ handler=WEB.ELF pid='
vgate_assert 03 serial-contains 'web: url https://example.com/'
vgate_assert 03 serial-contains 'web: error dns'
vgate_assert 03 serial-contains 'web: ready'
vgate_assert 03 serial-contains 'dui close: closed=2'
vgate_assert 03 serial-contains 'rx-gosh-open-https-ok'
vgate_assert 03 serial-absent 'gosh: open refused'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# A type with no handler is a named refusal, and must not spawn an app.
vgate_run 04 -- \
    --screen '$RUN_DIR/screen-open-unknown' \
    --script '$RUN_DIR/open-unknown.txt' \
    --script2 '$RUN_DIR/finish-open-unknown.txt' \
    --script2-after 'gosh: open refused target=SAVE.ZIP reason=no handler for archive' \
    --script-expect 'rx-gosh-open-unknown-ok' --timeout 240

vgate_assert 04 serial-contains 'gosh: open refused target=SAVE.ZIP reason=no handler for archive'
vgate_assert 04 serial-contains 'gosh: open: SAVE.ZIP: no handler for archive'
vgate_assert 04 serial-contains 'rx-gosh-open-unknown-ok'
vgate_assert 04 serial-absent 'gosh: open launched'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'

# --- M138a (#2775): a heredoc with no body is a named refusal ------------
# The kernel monitor itself collects `<<` bodies (kernel/src/shell.zig), so
# an unterminated case typed as `exec GOSH.ELF -c "cat <<DONE"` would be
# eaten by the MONITOR's own heredoc reader and never reach GOSH. The
# refusal is therefore produced by a sourced script on the share — the
# file ends mid-body, which is exactly `gosh: heredoc: unterminated <DONE>`:
# never a silent empty stdin, never a mis-parsed `<` redirect.
vgate_file GOSHUNTERM.SH <<'EOF'
cat <<DONE
this body never ends
EOF

vgate_file heredoc-unterm.txt <<'EOF'
exec GOSH.ELF -c "source /host/GOSHUNTERM.SH"
EOF

vgate_file finish-heredoc-unterm.txt <<'EOF'
echo rx-gosh-heredoc-unterm-ok
EOF

vgate_run 06 -- \
    --screen '$RUN_DIR/screen-heredoc-unterm' \
    --via-virtio \
    --script '$RUN_DIR/heredoc-unterm.txt' \
    --script2 '$RUN_DIR/finish-heredoc-unterm.txt' \
    --script2-after 'gosh: heredoc: unterminated <DONE>' \
    --script-expect 'rx-gosh-heredoc-unterm-ok' --timeout 240

vgate_assert 06 serial-contains 'gosh: heredoc: unterminated <DONE>'
vgate_assert 06 serial-contains 'rx-gosh-heredoc-unterm-ok'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'

# --- M83c (#1776): date under a SECOND zone -------------------------------
# `date` formats the epoch in the `timezone` row's fixed offset and labels
# the face with it. Run 01 pinned the UTC default; this boot stores
# `timezone=UTC+05:30` through the kernel's own crash-safe `settings set`
# BEFORE the shell starts, so the same startup `date` line must come out
# shifted and labelled. The two zones' outputs are pinned against the epochs
# they print -- deterministic checks on a live clock. (Boots 02-04 need no
# zone: `date` runs only in STARTUP.SH, which run 01 and this run carry.)
vgate_file script-05.txt <<'EOF'
settings set timezone UTC+05:30
tabwm
tabwm start
EOF

vgate_file script2-05.txt <<'EOF'
exec GOSH.ELF
EOF

vgate_file script3-05.txt <<'EOF'
dui close 2
echo rx-m83c-tz-ok
EOF

vgate_run 05 -- \
    --screen '$RUN_DIR/screen-05' \
    --via-virtio \
    --script '$RUN_DIR/script-05.txt' \
    --script2 '$RUN_DIR/script2-05.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --script3 '$RUN_DIR/script3-05.txt' \
    --script3-after 'gosh: prompt' \
    --script-expect 'rx-m83c-tz-ok' --timeout 240

vgate_assert 05 serial-contains 'settings: timezone=UTC+05:30 (persisted)'
vgate_assert 05 serial-contains 'gosh: line date > /host/GOSHDATE.TXT'
vgate_assert 05 serial-contains 'rx-m83c-tz-ok'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'
vgate_assert 05 python <<'PY'
import datetime, os, re, shutil, time
rd = os.environ["RUN_DIR"]
with open(os.path.join(os.environ["VG_SHARE"], "GOSHDATE.TXT"), "rb") as fh:
    line = fh.read()
m = re.fullmatch(rb"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (UTC(?:[+-]\d\d:\d\d)?) \(epoch=([0-9]+)\)\n", line)
if not m:
    raise SystemExit("date did not print a calendar face + zone + epoch: %r" % line)
if m.group(2) != b"UTC+05:30":
    raise SystemExit("date labelled %r, want the configured UTC+05:30" % m.group(2))
epoch = int(m.group(3))
face = datetime.datetime.fromtimestamp(epoch + 5 * 3600 + 30 * 60, datetime.timezone.utc)
if m.group(1).decode() != face.strftime("%Y-%m-%d %H:%M:%S"):
    raise SystemExit("date face %r disagrees with epoch %d at +05:30" % (m.group(1), epoch))
with open(os.path.join(rd, "host-epoch-start.txt")) as fh:
    host_start = float(fh.read())
host_end = time.time()
if not host_start - 60 <= epoch <= host_end + 60:
    raise SystemExit("date epoch %d outside host interval [%d, %d] with 60 s slack" %
                     (epoch, host_start, host_end))
shutil.copy(os.path.join(os.environ["VG_SHARE"], "GOSHDATE.TXT"),
            "artifacts/go-sh-share-date-tz.txt")
print("date epoch %d agrees with the +05:30 face and lies within 60 s of host [%d, %d]" %
      (epoch, host_start, host_end))
PY
