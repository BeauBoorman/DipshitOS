# go-selftest.spec -- M61b/M61c/M61d/M61e (issues #1382/#1383/#1384/#1385)
# class-B gate: the first guest-owned pass/fail in the fleet. GOSELF.ELF runs a
# built-in case list on the fixtures the host seeded under IN/, writes
# /host/SELFTEST/REPORT.txt + OUT/ receipts on the share, then prints the
# serial contract of ADR 0031 (`selftest: FAIL n=<N>`, `selftest OK`).
#
# Serial is the heartbeat; the files are the proof. The load-bearing asserts
# read $VG_SHARE on the HOST, so an app that printed `selftest: FAIL n=0`
# without writing the report cannot pass. The run ends on the program's own
# summary marker (SPEC.md idiom 1): a run whose summary never appears fails on
# the expect deadline.
#
# The intake cases (M61c) are the anti-embedding test. The host seeds two
# fixtures with DIFFERENT bodies (IN/fixture.txt = the canonical bytes,
# IN/altered.txt = the same bytes with one character changed) and the guest
# copies the bytes it actually READ into OUT/. An app that answered from a
# constant compiled into the binary cannot pass this: the copies would not
# match the files macOS holds in the share, and `intake-altered` — which must
# find the altered body, not the canonical one — would report the wrong bytes.
#
# The END-TO-END mutation form of ADR 0031 D2 (rewrite IN/fixture.txt itself,
# watch `intake` FAIL) was run once during M61c and is recorded on issue #1383:
# seed IN/fixture.txt with the altered bytes in the setup hook below and the run
# must end on `case intake fail fixture mismatch: got=25 want=25` +
# `selftest: FAIL n=1`. It is deliberately not a second boot in this spec — the
# mismatch path is regression-tested off-guest (`go test ./selftest`,
# TestIntakeFailsOnAMutatedSeed) and the anti-embedding property is what the
# asserts here cover continuously.
#
# M61d (#1384) adds the file-ABI pack, all of it on the share under per-case
# paths: create/write/close/reopen/read-back, truncate-then-read,
# delete-then-reopen-fails, and a directory listing that sees a file and then
# does not. Each case leaves TWO pieces of host-readable evidence — a one-line
# `case <id> …` receipt and, where bytes came back, a `.copy` of the bytes it
# READ (never the bytes it intended) — and the asserts below byte-compare all of
# it. A case that printed a verdict without landing the bytes cannot pass.
#
# The M61d cases are checked twice, on purpose. The receipts are the guest's
# claim about itself; the block below ALSO reads the share's own directory state
# on macOS (OUT/deleted.txt absent, OUT/LIST empty, roundtrip.txt 525 B,
# truncate.txt holding exactly the reconstructed 105-byte prefix). Those are
# facts about the filesystem the guest's syscalls left behind, which no receipt
# can fake — and the reconstructed bodies come from the same one-expression
# units the app writes (`b"goself file abi line\n" * n`), not from a fixture
# file. A `.copy` that does not equal the reconstruction fails the gate.
#
# M61e (#1385) adds the window receipt. Its evidence file is the only one whose
# bytes depend on a RUNTIME value (the id the kernel assigned), so it is matched
# rather than fixed — and then held to the two reporters of that same window
# that are NOT this process:
#
#   * the KERNEL's own open record, `open: id=<N> owner=<pid> rect=<x>,<y>
#     <W>x<H> ws=<k>` (driving_award.zig, the open-attribution marker of issue
#     #990), which also gives the rect as REQUESTED — 32,32 640x400, the app's
#     tabapp.Config;
#   * TABWM's `tabwm: tab-switch idx=<i> id=<N>` line, the WM naming the tab it
#     made active.
#
# The receipt's `win=` must equal both ids, and its `w=`/`h=` must be the
# tab-aware CONTENT VIEWPORT the WM proposed (1100x720 at x=180 — tabwm's
# compute_tab_viewport) rather than the 640x400 the kernel logged at open. That
# last point is what makes the window case worth a boot: a case that restated
# its own request would report 640x400, a number the kernel's open line
# contains, and fail here. The geometry in the receipt therefore comes from
# sys_win_query's read-back of the kernel's window record — a kernel->user copy
# into a fresh buffer, the same path issue #1391 broke and ADR 0032 fixed.
#
# This is NOT a framebuffer golden (the card's non-goal): no pixels are read
# anywhere, no PNG is compared, and nothing in the case knows what the window
# looks like.
#
# M81b (#1762) adds the `mime` case: the file-type table, proved on the share.
# The case WRITES seven fixtures under OUT/MIME/ and READS each one back
# through the file ABI before sniffing it, so the receipt describes bytes that
# came back over the share rather than a constant in the binary. The row that
# carries the card is README.TXT — PNG magic under a .TXT name, reported as
# `image`: magic decides before the extension ever does. The assert below
# byte-compares the receipt AND reads OUT/MIME/ from the host, so a case that
# printed a plausible table without landing the bytes cannot pass.
#
# REGRESSION TEST for #1391 (fixed in the kernel, ADR 0032): the first
# kernel->user copy into a user buffer whose pages EL0 has never written used to
# be silently lost on VZ — the syscall reported the right byte count and the app
# read zeros, because the destination page still resolved for EL1 into the
# kernel's EL1-only identity overlay. The guest's read helper does not touch its
# buffer first (that workaround is deleted), and `intake` reads a host-seeded
# fixture into a fresh buffer; the asserts below require the fixture bytes
# back — in the report, in the OUT/ copies and in the receipts. With the defect
# live, this run ended on `case intake fail read returned 25B of zeros (issue
# #1391)` + `selftest: FAIL n=1` (recorded on #1391). The host's file channel
# was never involved (its stdout shows the bytes served). The M61d read-backs
# and M61e's win_query land in fresh buffers on the same path.
#
# This spec is also the PILOT for the two share-assert kinds added by M61f
# (#1386), the only amendment to tools/gate/SPEC.md since M40 GF2: REPORT.txt
# and the host-seeded IN/fixture.txt are checked with `share-equals` (a
# byte-exact compare against a vgate_file fixture, with the compared share file
# lifted into evidence automatically) and the guest's own summary with
# `share-contains`. The two were proven both ways on VZ before landing — a
# deliberately truncated `report.expected` reddens the run naming share-equals,
# and an unarmed share FAILs rather than skipping (recorded on #1386).
#
# M66a (#1443) extends the file-ABI pack with the hardening semantics, each
# one the ADR 0031 way (guest writes receipts + the bytes it READ, the host
# byte-compares them here on macOS):
#
#   * file-append    — write a base body, REOPEN with MODE_APPEND (no
#                      create), write more: the append write must land at
#                      EOF, so append.txt is base+more (105 B). A dropped
#                      append flag replaces the file and the read-back is
#                      the delta alone.
#   * file-bigwrite  — a 73,500-byte body, far beyond the kernel's
#                      2048-byte sys_file_write stage cap: it only lands
#                      through the confirmed-count chunk loop, and
#                      bigwrite.txt + bigwrite.copy must be byte-exact.
#   * file-clamp     — write 840 B, shrink the SAME handle to 105 B, write
#                      63 B more through the still-open handle: the host's
#                      truncate clamps its cursor, so clamp.txt is kept+extra
#                      (168 B). Without the clamp the write resumes past EOF
#                      and the read-back is neither the length nor the bytes.
#   * file-fsync     — the durability verb (slot 77, ADR 0007 amendment):
#                      fsync=0 on the open handle, closed=-2 (the honest
#                      EBADF) on the closed one; fsync.txt is byte-compared.
#   * file-errors    — the honest error rows, each observed on the share:
#                      missing=-6 (ENOENT), exists=-9 (the file-domain
#                      EEXIST row), isdir=-1 (a WRITE open of a directory),
#                      ninth=-5 (the 8-handle table full).
#
#   * file-write-safe — the publish primitive the M81e (#1765) app
#                      conversions stand on: a long body replaced by a
#                      short one. The read-back is exactly the short
#                      body (a whole-file publish, no tail) and the
#                      sacrificial temp does not survive, so the share
#                      holds one file and no orphan.
#
#   * file-snapshot — the M81g (#1767) snapshot bundle, the DRILL the
#                      card is about. The host seeds four inputs under
#                      IN/ (a settings table, a BINARY session strip, two
#                      documents); the guest carries them into one bundle,
#                      publishes it through the safe write, reads it back,
#                      parses it and republishes every entry under
#                      OUT/RESTORED/. The host then rebuilds the bundle
#                      FROM ITS OWN SEEDED BODIES and byte-compares, so
#                      what is verified is a round trip through the
#                      container rather than the guest agreeing with
#                      itself — and it re-parses the published bundle with
#                      an INDEPENDENT reader, which is what makes the
#                      format self-describing instead of guest-private.
#                      The binary session body is the load-bearing part: a
#                      text-only container could not carry a real strip.
#                      The receipt's `corrupt=refused` is the refusal half,
#                      and a one-byte-short bundle must never parse.
#   * file-write-publish — the seam BOTH shell hooks now call (M81e2
#                      #1787): vi.WriteFilePublish's two contracts. The
#                      REPLACE half is the GOSH history ring save and `>
#                      file` (a long body replaced by a short one, no
#                      tail, no orphan temp). The APPEND half is the
#                      history one-line append and `>>`, and it must ADD
#                      to the file rather than rewrite it — so the
#                      read-back is the whole base-plus-lines body
#                      byte-compared, not a "the new line is present"
#                      contains, which a rewrite-per-line
#                      implementation would also pass.
#
#   * trash — the M81a (#1761) recoverable-delete flow. The guest reads the
#             trashed bytes, restores them to the original path, records both
#             actions in RECENT, and expires an old item at the retention
#             boundary. The host checks the bytes, receipt, trash directory
#             state and recent action order.
#
#   * file-lease — the M81d (#1764) advisory write lease drill: acquire,
#             the foreign refusal (-11), the read-only check agreeing, the
#             STALE takeover (a foreign record stamped past the expiry),
#             the DEAD-HOLDER takeover (a fresh stamp on a pid the procs
#             scan proves gone — the crash shape), the release rules (a
#             foreign record is never deleted; an absent one is a no-op),
#             and the free check. The foreign records are hand-rendered
#             VLEASE1 text (the on-share convention), and the stale one is
#             lifted to OUT/file-lease.copy as the takeover's evidence.
#             `clock=yes` in the receipt is the boot's EFI epoch present;
#             the same drill would prove the pid rules in a no-epoch boot.
#
#   * disk — the M100f (#2311) VLFS leg. This run attaches no --data-disk,
#             so the case records `mounted=no` on /host and passes (a data
#             disk is an enhancement, never a requirement — ADR 0050 D6).
#             The mounted write/fsync/readback drill and its receipts are
#             pinned by live-vlfs-dataroot.spec.
#
# The report fixture below is byte-exact on purpose — the report is
# deterministic (ADR 0031). Adding a case updates the fixture, the
# share-contains case count, and want_summary in the python block.
# M83a (#1774): clock-epoch is a dynamic OUT/ receipt, not a golden report
# value. The host bounds its numeric epoch against its OWN pre/post run
# samples with 60 seconds of slack; -ENOSYS has a named fallback in unit
# tests rather than a made-up calendar value.
# M83b (#1775): clock-set drives the slot-78 setter on the live kernel (the
# refusals, a +100 s step with read-back, the exact restore) and is the LAST
# case, so the clock-epoch bound above still sees the untouched boot clock.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-goself.sh   ->  .build/go/GOSELF.ELF

vgate_name go-selftest "issues #1382-#1386 M61b-f: GOSELF.ELF runs the guest self-test cases over host-seeded intake fixtures, the file-ABI case pack and the window receipt; the host reads REPORT.txt and every OUT/ receipt on the share (share-assert pilot)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec GOSELF.ELF
EOF

# The expected bytes for the two share-equals asserts. vgate_file bodies are
# newline-terminated by contract, which is exactly REPORT.txt's shape (the
# report ends on the summary line + one newline, ADR 0031), so the fixture and
# the share file are byte-comparable without any trailing-newline games.
vgate_file report.expected <<'EOF'
case intake pass
case intake-altered pass
case clock-monotonic pass
case file-write pass
case file-roundtrip pass
case file-truncate pass
case file-delete pass
case file-list pass
case file-append pass
case file-bigwrite pass
case file-clamp pass
case file-fsync pass
case file-errors pass
case file-write-safe pass
case trash pass
case file-write-publish pass
case mime pass
case file-snapshot pass
case app-logs pass
case file-lease pass
case window pass
case disk pass
case clock-epoch pass
case clock-set pass
summary cases=24 failed=0
EOF
vgate_file clock-set.expected <<'EOF'
case clock-set refused=4 stepped=+100 restored=yes
EOF
vgate_file file-lease.expected <<'EOF'
case file-lease dir=LEASES clock=yes foreign-refused=-11 stale-takeover=ok dead-holder=ok foreign-release=-11 release=ok free=0
EOF
vgate_file app-log.expected <<'EOF'
line-04
line-05
line-06
line-07
line-08
line-09
line-10
line-11
line-12
line-13
line-14
line-15
line-16
line-17
line-18
line-19
line-20
line-21
line-22
line-23
line-24
line-25
line-26
line-27
line-28
line-29
line-30
line-31
line-32
line-33
line-34
line-35
EOF
vgate_file app-log-receipt.expected <<'EOF'
app=GOSELF.ELF
outcome=panic: fixture failure
last-log:
line-28
line-29
line-30
line-31
line-32
line-33
line-34
line-35
EOF
vgate_file trash.expected <<'EOF'
M81a trash fixture
EOF

# The canonical intake fixture as the spec seeds it (see the setup hook). The
# assert is that the GUEST left it alone: IN/ belongs to the host (ADR 0031 D2).
vgate_file intake-fixture.expected <<'EOF'
goself intake fixture v1
EOF

vgate_setup_python <<'PY'
import os, shutil, sys, time
rd = os.environ["RUN_DIR"]
with open(os.path.join(rd, "host-epoch-start.txt"), "w") as fh:
    fh.write(str(time.time()))
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOSELF.ELF")
if not os.path.exists(src):
    sys.exit("GOSELF.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-goself.sh")
shutil.copy(src, os.path.join(share, "GOSELF.ELF"))
st = os.path.join(share, "SELFTEST")
for d in ("IN", "OUT"):
    os.makedirs(os.path.join(st, d), exist_ok=True)
# The intake fixtures (ADR 0031 D2). The two bodies must differ, and the guest
# must report them differently: see the header.
fixture = b"goself intake fixture v1\n"
altered = b"goself intake fixture v2\n"
for name, body in (("fixture.txt", fixture), ("altered.txt", altered)):
    with open(os.path.join(st, "IN", name), "wb") as fh:
        fh.write(body)

# M81g (#1767): the four inputs the snapshot case carries. Seeded HERE, on the
# host, and READ by the guest — so the bundle it builds is made of bytes that
# came off the share, and a guest that answered from constants in its binary
# would produce a bundle the asserts below could not match. The session body
# is deliberately BINARY (NULs, a newline, high bytes) and exactly 12 bytes:
# the real SESSION.TABS is a binary strip, and a text-only container could not
# carry the state the card is about.
snap_settings = b"#v2\ntheme=amber\nwm=gotabwm\n"
snap_session = bytes([0x54, 0x41, 0x42, 0x53, 0x00, 0x02, 0x00, 0x0a,
                      0xff, 0xfe, 0x10, 0x20])
snap_note = b"goself snapshot note\n"
snap_second = b"goself snapshot second document\n"
docs = os.path.join(st, "IN", "snapshot-docs")
os.makedirs(docs, exist_ok=True)
for name, body in (("snapshot-settings.txt", snap_settings),
                   ("snapshot-session.tabs", snap_session),
                   (os.path.join("snapshot-docs", "NOTE.TXT"), snap_note),
                   (os.path.join("snapshot-docs", "SECOND.TXT"), snap_second)):
    with open(os.path.join(st, "IN", name), "wb") as fh:
        fh.write(body)
print("staged GOSELF.ELF into share (%d bytes) and %s/{IN,OUT}; seeded "
      "IN/fixture.txt %r, IN/altered.txt %r and the four M81g snapshot inputs "
      "(session %d B binary)"
      % (os.path.getsize(os.path.join(share, "GOSELF.ELF")), st, fixture, altered,
         len(snap_session)))
PY

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'tabwm: sidebar-rendered' \
    --script-expect 'selftest: FAIL n=' --timeout 240

# M94f: preserve run 01 and its pinned receipts above. Later boots use isolated
# A/B rings; only after run 01's original asserts do we stage the new apps and
# select wm=none. The producer stage waits for the viewer's first completed
# poll, and the run ends on its own completion marker.
vgate_file log-tail.txt <<'EOF'
exec -u0 LOGVIEW.ELF -text -polls 10 -follow export
EOF
vgate_file log-level.txt <<'EOF'
exec -u0 LOGVIEW.ELF -text -level W -polls 6 -follow export
EOF
vgate_file log-tag.txt <<'EOF'
exec -u0 LOGVIEW.ELF -text -tag net -polls 6 -follow export
EOF
vgate_file log-app.txt <<'EOF'
exec -u0 LOGVIEW.ELF -text -app A -polls 6 -follow export
EOF
vgate_file log-grep.txt <<'EOF'
exec -u0 LOGVIEW.ELF -text -grep line=000003 -polls 6 -follow export
EOF
vgate_file log-producers.txt <<'EOF'
exec -u0 LOGFIX.ELF A 1 12
exec -u0 LOGFIX.ELF B 1 12
EOF
vgate_file log-filter-producers.txt <<'EOF'
exec -u0 LOGFIX.ELF A 4 4
exec -u0 LOGFIX.ELF B 4 4
EOF
vgate_file log-reset.py <<'PY'
import os, shutil
share = os.environ["VG_SHARE"]
for name in ("APPLOG", "LOGEXPORT"):
    shutil.rmtree(os.path.join(share, name), ignore_errors=True)
os.mkdir(os.path.join(share, "APPLOG"))
PY
vgate_file log-tasks.txt <<'EOF'
tasks
EOF

vgate_run tail -- --script '$RUN_DIR/log-tail.txt' \
    --script2 '$RUN_DIR/log-producers.txt' --script2-after 'logview: ready text' \
    --script3 '$RUN_DIR/log-tasks.txt' --script3-after 'logfix: active app=B' \
    --script-expect 'logview: done' --timeout 45
vgate_assert tail serial-contains 'exec: loaded LOGVIEW.ELF'
vgate_assert tail serial-count 'exec: loaded LOGFIX.ELF' 2
vgate_assert tail serial-contains 'logview: A 1 D net line=000001'
vgate_assert tail serial-contains 'logview: B 1 D net line=000001'
vgate_assert tail serial-absent 'gap app='
vgate_assert tail serial-absent 'logview: error'
vgate_assert tail serial-absent 'logfix: error'
vgate_assert tail serial-absent '[EXC] parking:'
vgate_assert tail python <<'PY'
import os, re, shutil
serial = open(os.environ["VG_SER"]).read()
rows = re.findall(r"^logview: ([AB]) ([0-9]+) ([DIWE]) (net|ui) line=([0-9]{6})$", serial, re.M)
assert {r[0] for r in rows} == {"A", "B"}, "both concurrent rings must arrive"
for app in ("A", "B"):
    seqs = [int(r[1]) for r in rows if r[0] == app]
    assert seqs == list(range(1, len(seqs)+1)) and len(seqs) >= 6, (app, seqs)
for app, seq, level, tag, msg in rows:
    i = int(seq)
    assert level == "DIWE"[(i-1)%4] and tag == ("net" if i%2 else "ui") and int(msg) == i
apps = "".join(r[0] for r in rows)
assert "ABA" in apps or "BAB" in apps, ("not a live interleave", apps)
tasks = re.findall(r"tasks: enabled=.*?pool=(\d+)/(\d+)", serial)
assert tasks and all(int(n) <= 16 and int(cap) == 16 for n, cap in tasks), tasks
# The boot's user-el0 probe may still await reaping at this marker. Its one
# transient slot does not change the three-runtime budget or the <=16 bar.
assert any(15 <= int(n) <= 16 for n, cap in tasks), ("three live Go runtimes expected", tasks)
print("concurrent arrival tail and tasks observed:", apps, tasks)
share = os.environ["VG_SHARE"]
for app in ("A", "B"):
    path = os.path.join(share, "LOGEXPORT", app + "-1.TXT")
    got = open(path).read()
    want = "".join("%s %s %s %s line=%s\n" % r for r in rows if r[0] == app)
    assert got == want, ("export differs from observed view", app, got, want)
    shutil.copy(path, "artifacts/go-selftest-log-tail-" + app + os.environ.get("VIRELAI_GATE_SUFFIX", "") + ".txt")
PY

vgate_run level -- --script '$RUN_DIR/log-level.txt' \
    --script2 '$RUN_DIR/log-filter-producers.txt' --script2-after 'logview: ready text' \
    --script-expect 'logview: done' --timeout 45
vgate_assert level serial-contains 'logview: A 3 W net line=000003'
vgate_assert level serial-contains 'logview: B 4 E ui line=000004'
vgate_assert level serial-absent 'gap app='
vgate_assert level python <<'PY'
import os, re, shutil
serial = open(os.environ["VG_SER"]).read()
rows = re.findall(r"^logview: ([AB]) ([0-9]+) ([DIWE]) (net|ui) line=([0-9]{6})$", serial, re.M)
assert {r[2] for r in rows} == {"W", "E"} and {r[0] for r in rows} == {"A", "B"}, rows
share = os.environ["VG_SHARE"]
for app in ("A", "B"):
    path = os.path.join(share, "LOGEXPORT", app + "-1.TXT")
    got = open(path).read()
    want = "".join("%s %s %s %s line=%s\n" % r for r in rows if r[0] == app)
    assert got == want, ("level export", got, want)
    shutil.copy(path, "artifacts/go-selftest-log-level-" + app + os.environ.get("VIRELAI_GATE_SUFFIX", "") + ".txt")
print("level >= W and exported bytes observed")
PY

vgate_run tag -- --script '$RUN_DIR/log-tag.txt' \
    --script2 '$RUN_DIR/log-filter-producers.txt' --script2-after 'logview: ready text' \
    --script-expect 'logview: done' --timeout 45
vgate_assert tag serial-contains 'logview: A 1 D net line=000001'
vgate_assert tag serial-contains 'logview: B 3 W net line=000003'
vgate_assert tag serial-absent 'gap app='
vgate_assert tag python <<'PY'
import os, re, shutil
rows = re.findall(r"^logview: ([AB]) ([0-9]+) ([DIWE]) (\w+) line=([0-9]{6})$", open(os.environ["VG_SER"]).read(), re.M)
assert {r[3] for r in rows} == {"net"} and {r[2] for r in rows} == {"D", "W"}, rows
share = os.environ["VG_SHARE"]
for app in ("A", "B"):
    path = os.path.join(share, "LOGEXPORT", app + "-1.TXT")
    got = open(path).read()
    want = "".join("%s %s %s %s line=%s\n" % r for r in rows if r[0] == app)
    assert got == want, ("tag export", got, want)
    shutil.copy(path, "artifacts/go-selftest-log-tag-" + app + os.environ.get("VIRELAI_GATE_SUFFIX", "") + ".txt")
print("tag=net and exported bytes observed")
PY

vgate_run app -- --script '$RUN_DIR/log-app.txt' \
    --script2 '$RUN_DIR/log-filter-producers.txt' --script2-after 'logview: ready text' \
    --script-expect 'logview: done' --timeout 45
vgate_assert app serial-contains 'logview: A 1 D net line=000001'
vgate_assert app serial-absent 'logview: B '
vgate_assert app serial-absent 'gap app='
vgate_assert app python <<'PY'
import os, re, shutil
rows = re.findall(r"^logview: ([AB]) ([0-9]+) ([DIWE]) (\w+) line=([0-9]{6})$", open(os.environ["VG_SER"]).read(), re.M)
assert rows and {r[0] for r in rows} == {"A"} and {r[2] for r in rows} == set("DIWE"), rows
share = os.environ["VG_SHARE"]
path = os.path.join(share, "LOGEXPORT", "A-1.TXT")
assert open(path).read() == "".join("%s %s %s %s line=%s\n" % r for r in rows)
assert os.listdir(os.path.join(share, "LOGEXPORT")) == ["A-1.TXT"], "app filter exported B"
shutil.copy(path, "artifacts/go-selftest-log-app" + os.environ.get("VIRELAI_GATE_SUFFIX", "") + ".txt")
print("app=A only and exported bytes observed")
PY

vgate_run grep -- --script '$RUN_DIR/log-grep.txt' \
    --script2 '$RUN_DIR/log-filter-producers.txt' --script2-after 'logview: ready text' \
    --script-expect 'logview: done' --timeout 45
vgate_assert grep serial-contains 'logview: A 3 W net line=000003'
vgate_assert grep serial-contains 'logview: B 3 W net line=000003'
vgate_assert grep serial-absent 'gap app='
vgate_assert grep python <<'PY'
import os, re, shutil
rows = re.findall(r"^logview: ([AB]) ([0-9]+) ([DIWE]) (\w+) line=([0-9]{6})$", open(os.environ["VG_SER"]).read(), re.M)
assert rows == [("A", "3", "W", "net", "000003"), ("B", "3", "W", "net", "000003")], rows
share = os.environ["VG_SHARE"]
for app in ("A", "B"):
    path = os.path.join(share, "LOGEXPORT", app + "-1.TXT")
    assert open(path).read() == "%s 3 W net line=000003\n" % app
    shutil.copy(path, "artifacts/go-selftest-log-grep-" + app + os.environ.get("VIRELAI_GATE_SUFFIX", "") + ".txt")
print("substring filter and exported bytes observed")
PY

vgate_file log-gap.txt <<'EOF'
exec -u0 LOGVIEW.ELF -text -app A -polls 6 -follow export
EOF
vgate_file log-burst.txt <<'EOF'
exec -u0 LOGFIX.ELF A 64 64
EOF
vgate_run gap -- --script '$RUN_DIR/log-gap.txt' \
    --script2 '$RUN_DIR/log-burst.txt' --script2-after 'logview: ready text' \
    --script-expect 'logview: done' --timeout 45
vgate_assert gap serial-contains 'gap app=A lost=32'
vgate_assert gap serial-contains 'logview: A 100096 E ui line=000064'
vgate_assert gap serial-absent 'logview: error'
vgate_assert gap serial-absent 'logfix: error'
vgate_assert gap python <<'PY'
import os, re, shutil
share = os.environ["VG_SHARE"]
serial = open(os.environ["VG_SER"]).read()
gaps = re.findall(r"^gap app=A lost=(\d+)$", serial, re.M)
assert gaps == ["100000", "32"], ("exact gap", gaps)
rows = re.findall(r"^logview: A (\d+) [DIWE] (?:net|ui) line=\d{6}$", serial, re.M)
assert [int(n) for n in rows] == list(range(100001, 100033)) + list(range(100065, 100097)), rows
path = os.path.join(share, "LOGEXPORT", "A-1.TXT")
got = open(path).read()
want = "".join((l.removeprefix("logview: ") + "\n") for l in serial.splitlines()
               if l.startswith("logview: A ") or l.startswith("gap app=A "))
assert got == want, ("gap export", got, want)
shutil.copy(path, "artifacts/go-selftest-log-gap" + os.environ.get("VIRELAI_GATE_SUFFIX", "") + ".txt")
ring = open(os.path.join(share, "APPLOG", "A.LOG")).read()
initial_size = sum(len("%d %s %s line=%06d\n" % (100000+i, "DIWE"[(i-1)%4], "net" if i%2 else "ui", i))
                   for i in range(1, 33))
assert len(ring) == initial_size, ("must defeat size-only follow", len(ring), initial_size)
print("same-size content follow observed: exactly 32 new rows lost")
PY

vgate_file log-window.txt <<'EOF'
exec -u0 LOGVIEW.ELF -app A
EOF
vgate_file log-window-producer.txt <<'EOF'
exec -u0 LOGFIX.ELF A 1 12
EOF
vgate_file log-window-close.txt <<'EOF'
tasks
EOF
vgate_run window -- --screen '$RUN_DIR/log-screen' --via-virtio \
    --script '$RUN_DIR/log-window.txt' --script-after 'gotabwm: present' \
    --script2 '$RUN_DIR/log-window-producer.txt' --script2-after 'logview: present' \
    --script3 '$RUN_DIR/log-window-close.txt' --script3-after 'logview: A 3 W net line=000003' \
    --input-chords 'escape' --input-chords-after 'logview: A 3 W net line=000003' \
    --script-expect 'logview: close' --timeout 60
vgate_assert window serial-contains 'logview: declare accepted'
vgate_assert window serial-count 'logview: present' 2
vgate_assert window serial-contains 'logview: A 3 W net line=000003'
vgate_assert window serial-absent 'logview: error'
vgate_assert window serial-absent '[EXC] parking:'

# M97g (#2085): the diagnostic-label binding, proven live. A privileged
# producer mints ring C; the unprivileged legs then fail closed — a
# foreign-label append is EACCES (no FORGED ring appears) and a foreign
# ring read is EACCES. The viewer's own render is covered by every leg
# above running the same -u0 path.
# The legs are serialized (one run per exec): three concurrent Go apps
# plus the desktop would overrun the global task table (max_tasks=16) and
# the fixture would die in runtime startup before it could print.
vgate_file log-bound-seed.txt <<'EOF'
exec -u0 LOGFIX.ELF C 1 2
EOF
vgate_run bound-seed -- --script '$RUN_DIR/log-bound-seed.txt' \
    --script-expect 'logfix: done app=C' --timeout 45
vgate_file log-bound-forge.txt <<'EOF'
exec LOGFIX.ELF FORGED 1 1
EOF
vgate_run bound-forge -- --script '$RUN_DIR/log-bound-forge.txt' \
    --script-expect 'logfix: error app=FORGED rc=-7' --timeout 45
vgate_file log-bound-view.txt <<'EOF'
exec LOGVIEW.ELF -text -polls 2
EOF
vgate_run bound-view -- --script '$RUN_DIR/log-bound-view.txt' \
    --script-expect 'logview: error rc=-7' --timeout 45
vgate_assert bound-seed serial-contains 'logfix: done app=C'
vgate_assert bound-forge serial-contains 'logfix: error app=FORGED rc=-7'
vgate_assert bound-forge serial-absent 'logfix: done app=FORGED'
vgate_assert bound-view serial-contains 'logview: error rc=-7'
vgate_assert bound-view python <<'PY'
import os
share = os.environ["VG_SHARE"]
ring = open(os.path.join(share, "APPLOG", "C.LOG")).read()
assert ring == "1 D net line=000001\n2 I ui line=000002\n", ring
assert not os.path.exists(os.path.join(share, "APPLOG", "FORGED.LOG")), "forged ring published"
print("label binding observed: own/privileged C ring intact, FORGED refused")
PY

# Keep boot preparation independent of the preceding verdict. A red test must
# not turn all later boots into stale-ring failures.
vgate_assert tail python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "log-reset.py")).read())
PY
vgate_assert level python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "log-reset.py")).read())
PY
vgate_assert tag python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "log-reset.py")).read())
PY
vgate_assert app python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "log-reset.py")).read())
PY
vgate_assert grep python <<'PY'
import os
exec(open(os.path.join(os.environ["RUN_DIR"], "log-reset.py")).read())
# Both snapshots are full rings with six-digit sequences and equal-length
# messages. The last observed seq is 100032; a 64-row burst retains 100065
# through 100096 and loses exactly 32 NEW rows without changing file size.
with open(os.path.join(share, "APPLOG", "A.LOG"), "w") as f:
    f.write("".join("%d %s %s line=%06d\n" % (100000+i, "DIWE"[(i-1)%4], "net" if i%2 else "ui", i)
                    for i in range(1, 33)))
PY
vgate_assert gap python <<'PY'
import os, shutil
exec(open(os.path.join(os.environ["RUN_DIR"], "log-reset.py")).read())
src = ".build/go/GOTABWM.ELF"
assert os.path.isfile(src), "build the seat fixture first: bash tools/go/build-gotabwm.sh"
shutil.copy(src, os.path.join(share, "GOTABWM.ELF"))
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=gotabwm\n")
PY

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'exec: loaded GOSELF.ELF'
vgate_assert 01 serial-contains 'goself: open id='
vgate_assert 01 serial-contains 'goself: declare accepted'
# Per-case heartbeat lines, printed only after the case's syscalls returned.
vgate_assert 01 serial-contains 'selftest: case intake pass'
vgate_assert 01 serial-contains 'selftest: case intake-altered pass'
vgate_assert 01 serial-contains 'selftest: case clock-monotonic pass'
vgate_assert 01 serial-contains 'selftest: case clock-epoch pass'
vgate_assert 01 serial-contains 'selftest: case clock-set pass'
vgate_assert 01 serial-contains 'selftest: case file-write pass'
vgate_assert 01 serial-contains 'selftest: case file-roundtrip pass'
vgate_assert 01 serial-contains 'selftest: case file-truncate pass'
vgate_assert 01 serial-contains 'selftest: case file-delete pass'
vgate_assert 01 serial-contains 'selftest: case file-list pass'
vgate_assert 01 serial-contains 'selftest: case file-append pass'
vgate_assert 01 serial-contains 'selftest: case file-bigwrite pass'
vgate_assert 01 serial-contains 'selftest: case file-clamp pass'
vgate_assert 01 serial-contains 'selftest: case file-fsync pass'
vgate_assert 01 serial-contains 'selftest: case file-errors pass'
vgate_assert 01 serial-contains 'selftest: case trash pass'
vgate_assert 01 serial-contains 'selftest: case file-snapshot pass'
vgate_assert 01 serial-contains 'selftest: case app-logs pass'
vgate_assert 01 serial-contains 'selftest: case file-lease pass'
vgate_assert 01 serial-contains 'selftest: case window pass'
# The files were written BEFORE the summary (ADR 0031 ordering).
vgate_assert 01 serial-contains 'selftest: report /host/SELFTEST/REPORT.txt n='
vgate_assert 01 serial-contains 'selftest: summary /host/SELFTEST/OUT/summary.txt n='
vgate_assert 01 serial-contains 'goself: present'
# The contract line: n=0 means every case passed (the spec stops on this line).
vgate_assert 01 serial-contains 'selftest: FAIL n=0'
vgate_assert 01 serial-contains 'selftest OK'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
# The window the kernel opened is named by the kernel and by the WM — the two
# reporters the receipt's `win=` is held to below. The id is a runtime value,
# so these are the fixed substrings; the python assert extracts and compares it.
vgate_assert 01 serial-contains 'owner='
vgate_assert 01 serial-contains 'rect=32,32 640x400 ws='
# --- the share asserts (the M61f #1386 pilot) --------------------------------
# REPORT.txt is byte-exact against a vgate_file fixture, and IN/fixture.txt must
# still hold the bytes the setup hook seeded (the guest writes only to OUT/).
# Both also lift the share file they compared into artifacts/ automatically,
# which is what the python block below still does by hand for its own files.
vgate_assert 01 share-equals SELFTEST/REPORT.txt report.expected
vgate_assert 01 share-equals SELFTEST/IN/fixture.txt intake-fixture.expected
# share-contains is the substring kind: the guest's own summary count. Weaker
# than the python's byte-exact summary.txt compare below, and kept deliberately
# as the kind's pilot in a real gate.
vgate_assert 01 share-equals SELFTEST/OUT/trash.copy trash.expected
vgate_assert 01 share-equals SELFTEST/OUT/app-log.copy app-log.expected
vgate_assert 01 share-equals SELFTEST/OUT/file-lease.ok file-lease.expected
# M83b (#1775): the setter drilled on the real kernel -- four out-of-range
# epochs refused, +100 s stepped and read back, then stepped exactly back.
vgate_assert 01 share-equals SELFTEST/OUT/clock-set.ok clock-set.expected
# The takeover evidence: the record as the FOREIGN writer left it (stamped
# past the expiry), not GOSELF's own — the copy is of the pre-takeover text.
vgate_assert 01 share-contains SELFTEST/OUT/file-lease.copy 'token=0123456789abcdef'
vgate_assert 01 share-contains SELFTEST/OUT/file-lease.copy 'path=/host/SELFTEST/LEASE/TARGET.TXT'
vgate_assert 01 share-equals CRASH/GOSELF.ELF.TXT app-log-receipt.expected
vgate_assert 01 share-contains SELFTEST/OUT/summary.txt 'summary cases=24 failed=0'

# The load-bearing assert: the copies and the receipts on the host's own
# filesystem must be byte-exact, the share's directory state must agree with
# what the cases claim they did, and the window receipt must agree with the
# kernel's and the WM's own record of that window. A marker that reported
# success without writing the bytes cannot pass this. The share is a per-run
# temp dir deleted at gate_end, so the files this spec relied on are copied
# into artifacts/ as evidence (ADR 0031 D4) — the two share-* asserts above do
# that for their own files, this block still does it by hand.
#
# NEVER copy a share file to `artifacts/NAME-report.txt`: the harness already
# owns that name (SPEC.md's per-gate report) and a copy there clobbers it.
# This block uses `go-selftest-share-*`, and the share kinds use
# `go-selftest-share-<RELPATH with / and space to _>`.
vgate_assert 01 python <<'PY'
import os, re, shutil, time
share = os.environ["VG_SHARE"]
rd = os.environ["RUN_DIR"]
serial_path = os.environ.get("VG_SER") or os.path.join(rd, "vm-serial-01.log")
suffix = os.environ.get("VIRELAI_GATE_SUFFIX", "")

# The names and bodies are the app's own constants (user/go/selftest). The
# payloads are reconstructed from ONE expression each, so a case that wrote or
# kept the wrong bytes cannot match them.
fixture = b"goself intake fixture v1\n"
altered = b"goself intake fixture v2\n"
unit = b"goself file abi line\n"
roundtrip_body = unit * 25          # 525 B, written then read back whole
truncate_full = unit * 40           # 840 B written, then shrunk
truncate_kept = unit * 5            # 105 B expected after the shrink
append_body = unit * 5              # 105 B: base 3 units + 2 appended at EOF
bigwrite_body = unit * 3500         # 73,500 B: 36 sys_file_write calls at the cap
clamp_body = unit * 8               # 168 B: kept 5 + extra 3 at the clamp point
fsync_body = unit * 7               # 147 B, fsync'd through slot 77 before close
write_safe_long = unit * 40         # 840 B published, then replaced by the short one
write_safe_short = unit * 5         # 105 B expected after the shorter publish

# The M81g (#1767) snapshot bodies, reconstructed from ONE expression each —
# the same bytes the setup hook seeded under IN/. The session one is BINARY:
# 12 bytes with NULs, a newline and high bytes, because the real SESSION.TABS
# is a binary strip and the container has to carry it as it is.
snap_settings = b"#v2\ntheme=amber\nwm=gotabwm\n"
snap_session = bytes([0x54, 0x41, 0x42, 0x53, 0x00, 0x02, 0x00, 0x0a,
                      0xff, 0xfe, 0x10, 0x20])
snap_note = b"goself snapshot note\n"
snap_second = b"goself snapshot second document\n"
# The bundle, built HERE from those bodies — the host does not take the
# guest's word for the container's shape, it recomputes it. An independent
# construction is the point: if this and virelai/snapshot disagreed about the
# format, the byte-compare below fails rather than both sides being wrong
# together.
snap_entries = [(b"settings", snap_settings),
                (b"session", snap_session),
                (b"docs/NOTE.TXT", snap_note),
                (b"docs/SECOND.TXT", snap_second)]
want_bundle = (b"#vb1 %d\n" % len(snap_entries)
               + b"".join(b"%s %d\n%s" % (n, len(bd), bd) for n, bd in snap_entries))
want_snapshot_receipt = (b"case file-snapshot path=OUT/snapshot.bundle entries=4 docs=2 "
                         b"bytes=%d settings=%d session=%d match=yes orphan=none "
                         b"corrupt=refused\n"
                         % (len(want_bundle), len(snap_settings), len(snap_session)))
# M81e2 (#1787): the publish case's bodies. The base is the 105 B short body
# (so the replace is a SHRINK), and the two appended lines are the history
# appends — 17 B each including the LF.
publish_base = write_safe_short
publish_line1 = b"gosh-history-one\n"
publish_line2 = b"gosh-history-two\n"
publish_want = publish_base + publish_line1 + publish_line2

# The window, from the outside: the app's tabapp.Config at open, and the
# tab-aware content viewport TABWM proposes afterwards
# (user/src/tabwm.zig compute_tab_viewport: 180,0 1100x720).
win_open_rect = (32, 32, 640, 400)
win_viewport_w = 1100
win_viewport_h = 720

want_summary = b"summary cases=24 failed=0\n"
want_hello = b"goself smoke\n"
want_intake_receipt = b"case intake path=IN/fixture.txt bytes=25 match=yes\n"
want_altered_receipt = b"case intake-altered path=IN/altered.txt bytes=25 differs=yes\n"
want_write_receipt = b"case file-write path=OUT/hello.txt bytes=13\n"
want_roundtrip_receipt = b"case file-roundtrip path=OUT/roundtrip.txt bytes=525 match=yes\n"
want_truncate_receipt = (b"case file-truncate path=OUT/truncate.txt wrote=840 kept=105 "
                         b"bytes=105 match=yes\n")
want_delete_receipt = b"case file-delete path=OUT/deleted.txt delete=0 reopen=-6\n"
want_list_receipt = (b"case file-list dir=OUT/LIST file=listed.txt "
                     b"first=seen second=absent\n")
want_append_receipt = (b"case file-append path=OUT/append.txt base=63 more=42 "
                       b"bytes=105 match=yes\n")
want_bigwrite_receipt = (b"case file-bigwrite path=OUT/bigwrite.txt bytes=73500 "
                         b"calls=36 match=yes\n")
want_clamp_receipt = (b"case file-clamp path=OUT/clamp.txt wrote=840 kept=105 "
                      b"extra=63 bytes=168 match=yes\n")
want_fsync_receipt = b"case file-fsync path=OUT/fsync.txt bytes=147 fsync=0 closed=-2\n"
want_errors_receipt = b"case file-errors missing=-6 exists=-9 isdir=-1 ninth=-5\n"
want_write_safe_receipt = (b"case file-write-safe path=OUT/write-safe.txt long=840 "
                           b"short=105 bytes=105 tail=none orphan=none match=yes\n")
want_trash_receipt = (b"case trash path=OUT/trash-source.txt bytes=19 match=yes "
                      b"restored=yes expiry=1 recent=delete,restore,delete\n")
# M81e2 (#1787): the receipt's byte counts are RECONSTRUCTED from the bodies
# above, not copied from the guest, so the host is checking the share
# against its own reading of the contract.
want_publish_receipt = (
    b"case file-write-publish path=OUT/publish.txt base="
    + str(len(publish_base)).encode() + b" after=" + str(len(publish_want)).encode() +
    b" want=" + str(len(publish_want)).encode() + b" tail=none orphan=none"
    b" replaced=yes appended=yes\n")

# M81b (#1762): the MIME case. The fixture bodies are reconstructed here from
# ONE expression each, exactly as selftest.go builds them, so the host checks
# the share against its own reading of the table rather than against a copy of
# whatever the guest wrote. README.TXT is the load-bearing row: PNG magic under
# a .TXT name must report `image`.
mime_fixtures = [
    (b"README.TXT", b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR", b"image", 16),
    (b"PIC.QOI", b"qoif\x00\x00\x00\x10\x00\x00\x00\x10\x03\xff\xff\xff", b"image", 16),
    (b"NOTES.TXT", b"goself mime case: one line of text\n", b"text", 16),
    (b"SONG.OGG", b"OggS\x00\x02\x00\x00\x00\x00\x00\x00", b"audio", 12),
    (b"BUNDLE.ZIP", b"PK\x03\x04\x14\x00\x00\x00\x08\x00", b"archive", 10),
    (b"GUEST.ELF", b"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00", b"binary", 12),
    (b"MYSTERY.PS", bytes([0x00, 0x01, 0x50, 0x53, 0x1a, 0x00]), b"unknown", 6),
]
want_mime_receipt = b"".join(
    b"sniff " + name + b" " + kind + b" bytes=" + str(n).encode() + b"\n"
    for name, body, kind, n in mime_fixtures)
want_mime_ok = (b"case mime fixtures=7 default-image=GOVIEW.ELF "
                b"default-text=GOEDIT.ELF\n")

st = os.path.join(share, "SELFTEST")
out = os.path.join(st, "OUT")


def read(path):
    with open(path, "rb") as fh:
        return fh.read()


def require(path, want, what):
    got = read(path)
    if got != want:
        print("%s MISMATCH (%s):\n got %r\nwant %r" % (what, path, got, want))
        raise SystemExit(1)
    return got


# REPORT.txt is not compared here: the share-equals assert above owns it (and
# owns the evidence copy). This block is what share-* cannot express — the
# share's own directory state, the window cross-checks against the serial log.
require(os.path.join(out, "summary.txt"), want_summary, "SUMMARY")
clock_path = os.path.join(out, "clock-epoch.ok")
clock = read(clock_path)
match = re.fullmatch(rb"case clock-epoch epoch=([0-9]+) source=firmware\n", clock)
if not match:
    raise SystemExit("CLOCK RECEIPT has no live firmware epoch: %r" % clock)
epoch = int(match.group(1))
with open(os.path.join(rd, "host-epoch-start.txt")) as fh:
    host_start = float(fh.read())
host_end = time.time()
if not host_start - 60 <= epoch <= host_end + 60:
    raise SystemExit("guest epoch %d outside host wall-clock interval "
                     "[%d, %d] with 60 s slack" %
                     (epoch, host_start, host_end))
print("guest epoch %d lies within 60 s of host wall-clock interval [%d, %d]"
      % (epoch, host_start, host_end))
require(os.path.join(out, "hello.txt"), want_hello, "HELLO")
# The guest read the fixtures it says it read: these copies hold the bytes the
# share held, not the constant the binary carries.
require(os.path.join(out, "fixture.copy"), fixture, "FIXTURE COPY")
require(os.path.join(out, "altered.copy"), altered, "ALTERED COPY")
require(os.path.join(out, "intake.txt"), want_intake_receipt, "INTAKE RECEIPT")
require(os.path.join(out, "intake-altered.txt"), want_altered_receipt, "ALTERED RECEIPT")
# M61d: one receipt per file-ABI case, then the two read-back copies. The
# roundtrip copy is the bytes READ back out of the file the case had just
# written; the truncated copy is the prefix left after the shrink.
require(os.path.join(out, "file-write.ok"), want_write_receipt, "WRITE RECEIPT")
require(os.path.join(out, "file-roundtrip.ok"), want_roundtrip_receipt, "ROUNDTRIP RECEIPT")
require(os.path.join(out, "file-truncate.ok"), want_truncate_receipt, "TRUNCATE RECEIPT")
require(os.path.join(out, "file-delete.ok"), want_delete_receipt, "DELETE RECEIPT")
require(os.path.join(out, "file-list.ok"), want_list_receipt, "LIST RECEIPT")
require(os.path.join(out, "roundtrip.copy"), roundtrip_body, "ROUNDTRIP COPY")
require(os.path.join(out, "truncated.copy"), truncate_kept, "TRUNCATED COPY")
# M66a: one receipt per hardening case, the bytes each case READ beside it,
# and the share state the syscalls left behind.
require(os.path.join(out, "file-append.ok"), want_append_receipt, "APPEND RECEIPT")
require(os.path.join(out, "file-bigwrite.ok"), want_bigwrite_receipt, "BIGWRITE RECEIPT")
require(os.path.join(out, "file-clamp.ok"), want_clamp_receipt, "CLAMP RECEIPT")
require(os.path.join(out, "file-fsync.ok"), want_fsync_receipt, "FSYNC RECEIPT")
require(os.path.join(out, "file-errors.ok"), want_errors_receipt, "ERRORS RECEIPT")
# M100f (#2311): the disk leg's receipt lands on /host like every other
# case's. This boot attaches no --data-disk, so the case must record the
# mounted=no skip honestly — the mounted drill is the opt-in leg, pinned by
# live-vlfs-dataroot.spec.
require(os.path.join(out, "file-disk.ok"), b"case disk mounted=no skipped\n",
        "DISK RECEIPT (no data disk attached)")
require(os.path.join(out, "append.copy"), append_body, "APPEND COPY")
require(os.path.join(out, "bigwrite.copy"), bigwrite_body, "BIGWRITE COPY")
require(os.path.join(out, "clamp.copy"), clamp_body, "CLAMP COPY")
require(os.path.join(out, "append.txt"), append_body, "APPEND FILE")
require(os.path.join(out, "bigwrite.txt"), bigwrite_body, "BIGWRITE FILE")
require(os.path.join(out, "clamp.txt"), clamp_body, "CLAMP FILE")
require(os.path.join(out, "fsync.txt"), fsync_body, "FSYNC FILE")
require(os.path.join(out, "file-write-safe.ok"), want_write_safe_receipt,
        "WRITE-SAFE RECEIPT")
require(os.path.join(out, "write-safe.copy"), write_safe_short,
        "WRITE-SAFE COPY (no tail)")
require(os.path.join(out, "trash.ok"), want_trash_receipt, "TRASH RECEIPT")
require(os.path.join(out, "trash.copy"), b"M81a trash fixture\n", "TRASH COPY")
require(os.path.join(out, "trash-source.txt"), b"M81a trash fixture\n",
        "RESTORED TRASH FILE")
if os.path.exists(os.path.join(out, "expiry-source.txt")):
    print("OUT/expiry-source.txt still exists - the trash delete did not move it")
    raise SystemExit(1)
trash_dir = os.path.join(share, "TRASH")
if not os.path.isdir(trash_dir) or os.listdir(trash_dir):
    print("TRASH should be empty after restore and expiry, got %r" %
          (sorted(os.listdir(trash_dir)) if os.path.isdir(trash_dir) else None))
    raise SystemExit(1)
recent_path = os.path.join(share, "RECENT", "LOG.TXT")
recent = read(recent_path).decode("ascii").splitlines()
if len(recent) != 3:
    print("RECENT has %d rows, want 3: %r" % (len(recent), recent))
    raise SystemExit(1)
recent_re = re.compile(r"^-?[0-9]+\|(delete|restore)\|[0-9a-f]{16}\|[0-9a-f]+$")
if any(not recent_re.fullmatch(row) for row in recent):
    print("RECENT rows have an invalid shape: %r" % recent)
    raise SystemExit(1)
if [row.split("|", 2)[1] for row in recent] != ["delete", "restore", "delete"]:
    print("RECENT action order is wrong: %r" % recent)
    raise SystemExit(1)

# M81g (#1767): the snapshot drill, checked from outside. The bundle on the
# share is byte-equal to one the HOST rebuilt from the seeded bodies, and
# every entry the guest rehydrated is byte-equal to the input it came from —
# so what is being verified is a round trip THROUGH the container, not a copy.
# The container is then re-parsed below with an independent reader, which is
# what makes "byte-exact" mean something about the FORMAT and not just about
# the guest agreeing with itself.
require(os.path.join(out, "snapshot.bundle"), want_bundle, "SNAPSHOT BUNDLE")
require(os.path.join(out, "snapshot.copy"), want_bundle, "SNAPSHOT COPY (bytes read back)")
require(os.path.join(out, "file-snapshot.ok"), want_snapshot_receipt,
        "SNAPSHOT RECEIPT")
require(os.path.join(out, "RESTORED", "settings.txt"), snap_settings,
        "RESTORED SETTINGS")
require(os.path.join(out, "RESTORED", "session.tabs"), snap_session,
        "RESTORED SESSION (binary strip)")
require(os.path.join(out, "RESTORED", "docs", "NOTE.TXT"), snap_note,
        "RESTORED DOC NOTE.TXT")
require(os.path.join(out, "RESTORED", "docs", "SECOND.TXT"), snap_second,
        "RESTORED DOC SECOND.TXT")
if os.path.exists(os.path.join(out, "snapshot.bundle~")):
    print("OUT/snapshot.bundle~ survived the publish - the temp leaked")
    raise SystemExit(1)

# An independent parse of the bundle the guest published: header, declared
# entry count, then each entry's name and EXACT byte count. A guest that
# published something only it can read fails here.
raw = read(os.path.join(out, "snapshot.bundle"))
nl = raw.index(b"\n")
if raw[:nl] != b"#vb1 %d" % len(snap_entries):
    print("SNAPSHOT BUNDLE header is %r, want %r"
          % (raw[:nl], b"#vb1 %d" % len(snap_entries)))
    raise SystemExit(1)
rest = raw[nl + 1:]
parsed = {}
for _ in range(len(snap_entries)):
    eol = rest.index(b"\n")
    name, _, count = rest[:eol].partition(b" ")
    count = int(count)
    body = rest[eol + 1:eol + 1 + count]
    if len(body) != count:
        print("SNAPSHOT BUNDLE entry %r declared %d bytes and carried %d"
              % (name, count, len(body)))
        raise SystemExit(1)
    parsed[name] = body
    rest = rest[eol + 1 + count:]
if rest:
    print("SNAPSHOT BUNDLE has %d trailing bytes after its last entry" % len(rest))
    raise SystemExit(1)
if parsed != {n: bd for n, bd in snap_entries}:
    print("the independently parsed bundle does not match the seeded bodies: %r"
          % sorted(parsed))
    raise SystemExit(1)
# M81e2 (#1787): the publish receipt, the whole body the case read back
# (base + both appended lines, byte-equal -- an "contains the new line"
# check would also pass a rewrite-per-line append, which is the regression
# this case exists to catch), and the share's own directory state: the
# sacrificial temp must not be there.
require(os.path.join(out, "file-write-publish.ok"), want_publish_receipt,
        "PUBLISH RECEIPT")
require(os.path.join(out, "publish.copy"), publish_want,
        "PUBLISH COPY (replace + two appends)")
if os.path.exists(os.path.join(out, "publish.txt~")):
    print("OUT/publish.txt~ survived the publish - the temp leaked")
    raise SystemExit(1)

# M81b: the sniff receipt, the one-line summary of it, and the fixture bytes
# the share itself holds. The receipt alone could be a table printed from
# constants; OUT/MIME/ is what the guest actually wrote and read back.
require(os.path.join(out, "mime.txt"), want_mime_receipt, "MIME RECEIPT")
require(os.path.join(out, "mime.ok"), want_mime_ok, "MIME SUMMARY")
mime_dir = os.path.join(out, "MIME")
if not os.path.isdir(mime_dir):
    print("OUT/MIME is not a directory - the mime case did not create it")
    raise SystemExit(1)
for name, body, kind, n in mime_fixtures:
    got = read(os.path.join(mime_dir, name.decode()))
    if got != body:
        print("MIME FIXTURE %s MISMATCH:\n got %r\nwant %r" % (name, got, body))
        raise SystemExit(1)

# The guest's claims, cross-checked against the filesystem its syscalls left
# behind. These are independent of the receipts: the receipts say what the case
# believed, this says what the share holds.
require(os.path.join(out, "roundtrip.txt"), roundtrip_body, "ROUNDTRIP FILE")
require(os.path.join(out, "truncate.txt"), truncate_kept, "TRUNCATE FILE (kept prefix)")
# The publish's own state: the file is exactly the short body, and the
# sacrificial temp is gone — the case's claims, checked against the share.
require(os.path.join(out, "write-safe.txt"), write_safe_short,
        "WRITE-SAFE FILE (no tail)")
if os.path.exists(os.path.join(out, "write-safe.txt~")):
    print("OUT/write-safe.txt~ survived the publish - the temp leaked")
    raise SystemExit(1)
if os.path.exists(os.path.join(out, "deleted.txt")):
    print("OUT/deleted.txt still exists - the delete case did not remove it")
    raise SystemExit(1)
list_dir = os.path.join(out, "LIST")
if not os.path.isdir(list_dir):
    print("OUT/LIST is not a directory - the guest's MKDIR did not create it")
    raise SystemExit(1)
if os.listdir(list_dir):
    print("OUT/LIST is not empty after the delete: %r" % sorted(os.listdir(list_dir)))
    raise SystemExit(1)

# M61e: the window receipt is matched rather than fixed (its id is a runtime
# value), then held to the kernel's and the WM's own account of that window.
serial = read(serial_path)
win = read(os.path.join(out, "window.txt"))
m = re.fullmatch(rb"case window win=([0-9]+) w=([0-9]+) h=([0-9]+) present=ok\n", win)
if not m:
    print("WINDOW RECEIPT is not the card's shape %r\n"
          "want 'case window win=<id> w=<W> h=<H> present=ok'"
          % win)
    raise SystemExit(1)
win_id, win_w, win_h = int(m.group(1)), int(m.group(2)), int(m.group(3))

app = re.search(rb"goself: open id=([0-9]+)", serial)
if not app:
    print("the app's own `goself: open id=<N>` line is missing from the serial")
    raise SystemExit(1)
app_id = int(app.group(1))

kern = [x for x in re.finditer(
    rb"^open: id=([0-9]+) owner=[0-9]+ rect=([0-9]+),([0-9]+) ([0-9]+)x([0-9]+) ws=[0-9]+",
    serial, re.M) if int(x.group(1)) == win_id]
if not kern:
    print("the kernel logged no `open:` record for window %d - the receipt names a "
          "window the kernel does not have (app says %d)" % (win_id, app_id))
    raise SystemExit(1)
kern_rect = tuple(int(kern[-1].group(i)) for i in (2, 3, 4, 5))

wm = re.search(rb"tabwm: tab-switch idx=[0-9]+ id=([0-9]+)", serial)
if not wm:
    print("TABWM reported no `tab-switch` line - no independent WM report of the window")
    raise SystemExit(1)
wm_id = int(wm.group(1))

if not (win_id == app_id == wm_id):
    print("the window ids disagree: receipt win=%d, app goself: open id=%d, WM tab-switch id=%d"
          % (win_id, app_id, wm_id))
    raise SystemExit(1)
if kern_rect != win_open_rect:
    print("the kernel's open rect is %r, not the app's tabapp.Config %r"
          % (kern_rect, win_open_rect))
    raise SystemExit(1)
# The receipt must report the KERNEL's current geometry (the WM's full content
# viewport after the tab-aware declaration), NOT the 640x400 the kernel logged
# at open. A case that restated its own request fails right here.
if (win_w, win_h) == (kern_rect[2], kern_rect[3]):
    print("the window receipt repeats the OPEN rect %dx%d instead of the kernel's "
          "current geometry: the case is restating its request, not reading the "
          "window back (sys_win_query)" % (win_w, win_h))
    raise SystemExit(1)
if (win_w, win_h) != (win_viewport_w, win_viewport_h):
    print("the window receipt reports %dx%d, not the tab-aware content viewport "
          "%dx%d the WM proposes (tabwm compute_tab_viewport)"
          % (win_w, win_h, win_viewport_w, win_viewport_h))
    raise SystemExit(1)

# The host owns IN/: neither intake case may have written there (ADR 0031 D2).
# IN/fixture.txt is the share-equals assert's job; the altered twin has no
# fixture in this spec, so it is compared here.
require(os.path.join(st, "IN", "altered.txt"), altered, "IN/ALTERED (guest wrote it?)")

os.makedirs("artifacts", exist_ok=True)
for name, path in (("intake.txt", os.path.join(out, "intake.txt")),
                   ("clock-epoch.ok", clock_path),
                   ("intake-altered.txt", os.path.join(out, "intake-altered.txt")),
                   ("fixture.copy", os.path.join(out, "fixture.copy")),
                   ("altered.copy", os.path.join(out, "altered.copy")),
                   ("file-write.ok", os.path.join(out, "file-write.ok")),
                   ("file-roundtrip.ok", os.path.join(out, "file-roundtrip.ok")),
                   ("file-truncate.ok", os.path.join(out, "file-truncate.ok")),
                   ("file-delete.ok", os.path.join(out, "file-delete.ok")),
                   ("file-list.ok", os.path.join(out, "file-list.ok")),
                   ("roundtrip.copy", os.path.join(out, "roundtrip.copy")),
                   ("truncated.copy", os.path.join(out, "truncated.copy")),
                   ("file-append.ok", os.path.join(out, "file-append.ok")),
                   ("file-bigwrite.ok", os.path.join(out, "file-bigwrite.ok")),
                   ("file-clamp.ok", os.path.join(out, "file-clamp.ok")),
                   ("file-fsync.ok", os.path.join(out, "file-fsync.ok")),
                   ("file-errors.ok", os.path.join(out, "file-errors.ok")),
                   ("file-write-safe.ok", os.path.join(out, "file-write-safe.ok")),
                   ("write-safe.copy", os.path.join(out, "write-safe.copy")),
                   ("file-snapshot.ok", os.path.join(out, "file-snapshot.ok")),
                   ("snapshot.bundle", os.path.join(out, "snapshot.bundle")),
                   ("snapshot.copy", os.path.join(out, "snapshot.copy")),
                   ("restored-settings.txt",
                    os.path.join(out, "RESTORED", "settings.txt")),
                   ("restored-session.tabs",
                    os.path.join(out, "RESTORED", "session.tabs")),
                   ("restored-NOTE.TXT",
                    os.path.join(out, "RESTORED", "docs", "NOTE.TXT")),
                   ("restored-SECOND.TXT",
                    os.path.join(out, "RESTORED", "docs", "SECOND.TXT")),
                   ("append.copy", os.path.join(out, "append.copy")),
                   ("bigwrite.copy", os.path.join(out, "bigwrite.copy")),
                   ("clamp.copy", os.path.join(out, "clamp.copy")),
                   ("window.txt", os.path.join(out, "window.txt"))):
    shutil.copy(path, "artifacts/go-selftest-share-%s%s" % (name, suffix))
print("host read-back byte-exact: file-ABI evidence roundtrip.copy %d B, "
      "truncated.copy %d B; bigwrite.copy %d B across 36 confirmed-count "
      "chunks; OUT/deleted.txt absent, OUT/LIST empty, "
      "OUT/truncate.txt holds the %d-byte prefix, OUT/append.txt base+more, "
      "OUT/clamp.txt kept+extra at the clamp point, OUT/fsync.txt durable"
      % (len(roundtrip_body), len(truncate_kept), len(bigwrite_body),
         len(truncate_kept)))
print("window receipt agreed with the kernel and the WM: win=%d (kernel `open:`, "
      "app `goself: open`, WM `tab-switch`); kernel open rect %r; read-back "
      "geometry %dx%d (the tab-aware viewport, not the open rect)"
      % (win_id, kern_rect, win_w, win_h))
PY

vgate_assert 01 python <<'PY'
import os, shutil
share = os.environ["VG_SHARE"]
for name in ("LOGVIEW", "LOGFIX"):
    src = ".build/go/" + name + ".ELF"
    if os.path.isfile(src):
        shutil.copy(src, os.path.join(share, name + ".ELF"))
    else:
        # Fail-before on main: still boot and prove the filter/gap asserts red,
        # rather than replacing their missing-program failure with setup exit.
        print("M94f prerequisite absent: %s; exec and viewer asserts must fail" % src)
shutil.rmtree(os.path.join(share, "APPLOG"), ignore_errors=True)
os.mkdir(os.path.join(share, "APPLOG"))
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
PY
