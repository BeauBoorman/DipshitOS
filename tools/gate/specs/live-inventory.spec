# live-inventory.spec -- M22 D16: which + inventory on VZ.
# Resolves all three command classes (builtin, monitor, app) + not-found,
# and inventory lists APPS.TXT applications.
#
# M66c (#1445): the dock's editor entry is NOTE.ELF now, so `image/apps.txt`
# (which gate-run copies in as the share's APPS.TXT) names it and the app query
# follows. NOTE.ELF is a staged Go ELF, not a seeded .BIN, hence the setup that
# copies it into the share.
#
# HOST PREREQUISITE: bash tools/go/build-note.sh -> .build/go/NOTE.ELF

vgate_name live-inventory "M22 D16: which + inventory on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
which type
which stat
which NOTE.ELF
which nope.bin
inventory
echo rx-inv-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(".build", "go", "NOTE.ELF")
if not os.path.exists(src):
    sys.exit("NOTE.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-note.sh")
shutil.copy(src, os.path.join(share, "NOTE.ELF"))
print("staged NOTE.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "NOTE.ELF")))
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'rx-inv-ok' --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'type: shell builtin'
vgate_assert 01 serial-contains 'stat: monitor command'
vgate_assert 01 serial-contains 'NOTE.ELF: host-share application'
vgate_assert 01 serial-contains 'nope.bin: not found'
vgate_assert 01 serial-contains 'rx-inv-ok'
vgate_assert 01 serial-absent '[EXC] parking:'

vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ['VG_SER']).read()
if not re.search(r'inventory: \d+ application\(s\):', ser):
    sys.exit("missing inventory header in serial log")
if "NOTE.ELF" not in ser:
    sys.exit("NOTE.ELF not listed in inventory")

# M82a (#1768): the manifest and the share are the same catalog, and the
# kernel's `inventory` is the guest's own view of it. The check runs over the
# INVENTORY BLOCK of the log (header to the run's own `rx-inv-ok`), not the
# whole serial, so a name cannot be satisfied by an unrelated boot message.
# A manifest row that exists in this share must be a file the guest listed:
# a row naming a file the guest cannot see is a row the launcher would offer
# and then fail to exec, which is the class of lie this card exists to stop.
# Rows NOT staged in this gate are counted and reported, never silently
# skipped — this spec stages one Go ELF, so most of the catalog is absent by
# design.
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
rows = [ln for ln in open(os.path.join(share, "APPS.TXT"), encoding="utf-8").read().splitlines()
        if ln.strip() and not ln.startswith("#")]
if len(rows) != 29:
    sys.exit("manifest has %d rows, want 29 (M132b #2753 appended the nine "
             "M140-M148 reservation rows)" % len(rows))
m = re.search(r'inventory: \d+ application\(s\):\n(.*?)rx-inv-ok', ser, re.S)
if not m:
    sys.exit("cannot isolate the inventory block in the serial log")
block = m.group(1)
present = unstaged = 0
for ln in rows:
    f = [x.strip() for x in ln.split("|")]
    if len(f) < 2 or not f[0] or not f[1]:
        sys.exit("malformed manifest row: %r" % ln)
    if f[4:] and (len(f) < 5 or f[3] not in ("dock=true", "dock=false") or
                  f[4].split("=", 1)[0] != "v"):
        sys.exit("row has a v2 tail but not four positional fields plus a "
                 "leading v=: %r" % ln)
    for tail in f[4:]:
        if not tail or "=" not in tail:
            sys.exit("trailing field is not key=value: %r" % ln)
    if os.path.exists(os.path.join(share, f[0])):
        present += 1
        if f[0] not in block:
            sys.exit("manifest row %s is in the share but not in the guest's "
                     "inventory listing" % f[0])
    else:
        unstaged += 1
print("manifest: %d rows, %d staged in this share and all listed by the "
      "guest, %d not staged here" % (len(rows), present, unstaged))
PY
