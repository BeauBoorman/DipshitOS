# go-vault.spec -- M148a (issue #2804) + M148b (issue #2805): GOVAULT.ELF
# class-B gate, run K=3. A PBKDF2+AES-256-GCM vault file under the Go seat:
# create through the masked pair, add an entry, reveal it, copy the secret
# onto the seat's primary selection, watch the 30 s lease expire, lock,
# unlock, quit. Two tamper legs and a wrong-pass leg pin the named refusals.
# The M148b acceptance leg (run 06) stores, locks, unlocks, reveals, copies,
# expires, then opens the Receipts face and pins its rows in order — on the
# serial listing AND on the vault's own receipts file in the share.
#
# REPEAT SEMANTICS: vgate_repeat 3 re-runs EVERY leg, and the armed share
# persists across iterations — so each leg must be iteration-safe. Run 01
# deletes VAULT.BIN so the create face returns; run 02 re-clones it to
# VAULT.REF so the tamper legs (04/05) can restore a valid vault before
# mangling it; run 06 deletes VAULT.BIN and recreates it self-contained.
# RECEIPTS.TXT is never reset — the accumulating audit file IS the K=3
# evidence (the receipts view's n= grows 11, 22, 33).
#
# The clipboard story, for whoever audits the asserts: the KERNEL clipboard
# (slots 38/39) is seat/CAP_CLIPBOARD only, so the app's copy surface is the
# seat's primary selection (M124e kind-27 publish / kind-28 pull). The buffer
# contents are proven by the SEAT's own `gotabwm: sel pub` len markers — the
# buffer is seat memory, not a file a python assert can read — and the
# `clip: empty` read proves the secret never reached the kernel buffer.
# Clearing is an overwrite (`[cleared]`, 9 bytes) because kind-27 refuses an
# empty publish.
#
# exec-order: assert-proven -- every stage gate is anchored on output only
# the seat or the app produces (`gotabwm: registered`, `govault: *`); a
# program that never ran cannot pass.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-govault.sh  ->  .build/go/GOVAULT.ELF
#   bash tools/go/build-gotabwm.sh  ->  .build/go/GOTABWM.ELF

vgate_name go-vault "M148a #2804 + M148b #2805: PBKDF2/AES-GCM vault — masked unlock, entry store, per-entry reveal, copy-with-expiry on the seat selection, idle lock, named refusals, receipts file + Receipts view; K=3"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 3

# Every iteration must find no vault on the share, so the app boots into the
# create face again — 'govault: new vault' is the chords gate.
vgate_file script-01.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm GOVAULT/VAULT.BIN
wm
exec GOTABWM.ELF
EOF

vgate_file script2-01.txt <<'EOF'
dui focus 0
exec GOVAULT.ELF
EOF

# Create the vault (two masked fields), add wifi/s3cr3t/home, reveal, copy,
# ctrl-l lock, unlock, esc lock, esc quit. The pristine clone is seeded here
# (run 02's script is the earliest leg where VAULT.BIN exists on the share)
# so the tamper legs can restore it — `vf clone` refuses a live target, so
# REF is removed and re-taken every iteration.
vgate_file script-02.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm GOVAULT/VAULT.REF
vf clone GOVAULT/VAULT.BIN GOVAULT/VAULT.REF
wm
exec GOTABWM.ELF
EOF

vgate_file script2-02.txt <<'EOF'
dui focus 0
exec GOVAULT.ELF
EOF

vgate_file script3-02.txt <<'EOF'
clip
echo rx-vault-done
EOF

vgate_file script-03.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-03.txt <<'EOF'
dui focus 0
exec GOVAULT.ELF
EOF

# Tamper legs need no seat: the refusals live in the load/unlock path. Each
# first restores a VALID vault — iteration n's VAULT.BIN was left mangled by
# iteration n-1's run 05 — then mangles it the leg's own way.
vgate_file script-04.txt <<'EOF'
vf rm GOVAULT/VAULT.BIN
vf clone GOVAULT/VAULT.REF GOVAULT/VAULT.BIN
vf open GOVAULT/VAULT.BIN
vf truncate 0 61
vf close 0
exec GOVAULT.ELF
EOF

vgate_file script-05.txt <<'EOF'
vf rm GOVAULT/VAULT.BIN
vf clone GOVAULT/VAULT.REF GOVAULT/VAULT.BIN
vf open GOVAULT/VAULT.BIN
vf write 0 4
vf close 0
exec GOVAULT.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
for elf, build in (("GOVAULT.ELF", "tools/go/build-govault.sh"),
                   ("GOTABWM.ELF", "tools/go/build-gotabwm.sh")):
    src = os.path.join(".build", "go", elf)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: bash %s"
                 % (elf, src, build))
    shutil.copy(src, os.path.join(share, elf))
    print("staged %s into share (%d bytes)" % (elf, os.path.getsize(src)))
# The compiled default is already the Go seat (M59); seed wm=none so the
# seat under test is the executed GOTABWM.ELF, not the autostart path.
with open(os.path.join(share, "SETTINGS.TXT"), "w") as f:
    f.write("#v2\nwm=none\n")
# The copy path is the seat's primary selection, which the seat admits only
# for apps whose manifest row carries `selection=primary` (M124e). GOVAULT's
# row ships it — assert it here so a manifest that dropped the opt-in fails
# the gate where it would silently refuse the copy.
apps = os.path.join(share, "APPS.TXT")
if not os.path.exists(apps):
    shutil.copy("image/apps.txt", apps)
row = [ln for ln in open(apps).read().splitlines()
       if ln.startswith("GOVAULT.ELF")]
if not row or "selection=primary" not in row[0]:
    sys.exit("GOVAULT's APPS.TXT row must carry selection=primary: %r"
             % (row,))
print("share APPS.TXT GOVAULT row carries selection=primary")
PY

# --- run 01: create, add, reveal, copy, lock, unlock, quit ------------------
vgate_run 01 -- \
    --screen '$RUN_DIR/vault-screen-01' \
    --via-virtio \
    --script '$RUN_DIR/script-01.txt' \
    --script2 '$RUN_DIR/script2-01.txt' \
    --script2-after 'gotabwm: registered' \
    --input-chords 'h,u,n,t,e,r,2,return,h,u,n,t,e,r,2,return,a,w,i,f,i,tab,s,3,c,r,3,t,tab,h,o,m,e,return,r,c,ctrl-l,h,u,n,t,e,r,2,return,escape,escape' \
    --input-chords-after 'govault: new vault' \
    --script-expect 'govault: exiting 0' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'exec: loaded GOVAULT.ELF'
vgate_assert 01 serial-contains 'govault: open id='
vgate_assert 01 serial-contains 'govault: declare accepted'
vgate_assert 01 serial-contains 'govault: new vault'
vgate_assert 01 serial-contains 'govault: iterations '
vgate_assert 01 serial-contains 'govault: saved'
vgate_assert 01 serial-contains 'govault: unlocked n=0'
vgate_assert 01 serial-contains 'govault: added'
vgate_assert 01 serial-contains 'govault: revealed'
vgate_assert 01 serial-contains 'govault: copied'
vgate_assert 01 serial-contains 'govault: locked'
vgate_assert 01 serial-contains 'govault: unlocked n=1'
vgate_assert 01 serial-contains 'govault: close'
vgate_assert 01 serial-contains 'govault OK'
vgate_assert 01 serial-contains 'govault: exiting 0'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
# The seat's own receipt that the copy landed in the buffer: a 6-byte
# publish ("s3cr3t") from GOVAULT's window.
vgate_assert 01 serial-contains 'gotabwm: sel pub id='
vgate_assert 01 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], "rb").read().decode("utf-8", "replace")
for m in re.finditer(r"gotabwm: sel pub id=\d+ len=(\d+)", ser):
    if int(m.group(1)) == 6:
        print("selection publish len=6 confirmed by the seat")
        break
else:
    raise SystemExit("no len=6 selection publish in serial")
PY
# The vault file itself on the host share: GVLT framing, sealed body.
vgate_assert 01 python <<'PY'
import os
share = os.environ["VG_SHARE"]
path = os.path.join(share, "GOVAULT", "VAULT.BIN")
b = open(path, "rb").read()
if b[:4] != b"GVLT":
    raise SystemExit("vault magic = %r, want GVLT" % b[:4])
if int.from_bytes(b[4:8], "little") != 1:
    raise SystemExit("vault version = %d, want 1"
                     % int.from_bytes(b[4:8], "little"))
iters = int.from_bytes(b[8:12], "little")
if not (100_000 <= iters <= 4_000_000):
    raise SystemExit("recorded iters = %d, outside calibration clamps" % iters)
if b"s3cr3t" in b or b"wifi" in b or b"hunter2" in b:
    raise SystemExit("PLAINTEXT secret material in the sealed file")
print("VAULT.BIN: GVLT v1, iters=%d recorded, body sealed (%d bytes)"
      % (iters, len(b)))
PY

# --- run 02: copy expiry — the 30 s lease overwrites the selection ---------
vgate_run 02 -- \
    --screen '$RUN_DIR/vault-screen-02' \
    --via-virtio \
    --script '$RUN_DIR/script-02.txt' \
    --script2 '$RUN_DIR/script2-02.txt' \
    --script2-after 'gotabwm: registered' \
    --input-chords 'h,u,n,t,e,r,2,return,c' \
    --input-chords-after 'govault: locked' \
    --script3 '$RUN_DIR/script3-02.txt' \
    --script3-after 'govault: clip expired' \
    --script-expect 'rx-vault-done' --timeout 240

vgate_assert 02 serial-contains 'gotabwm: registered'
vgate_assert 02 serial-contains 'exec: loaded GOVAULT.ELF'
vgate_assert 02 serial-contains 'govault: locked'
vgate_assert 02 serial-contains 'govault: unlocked n=1'
vgate_assert 02 serial-contains 'govault: copied'
vgate_assert 02 serial-contains 'govault: clip expired'
# The compare rule's pull is the seat's own `sel pull` receipt; the expiry
# publish is the 9-byte [cleared] sentinel, both ordered after the copy.
vgate_assert 02 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], "rb").read().decode("utf-8", "replace")
lens = [int(m.group(1))
        for m in re.finditer(r"gotabwm: sel pub id=\d+ len=(\d+)", ser)]
if len(lens) < 2 or lens[0] != 6 or 9 not in lens[1:]:
    raise SystemExit("selection publishes len=%s, want 6 then 9 (the "
                     "[cleared] overwrite)" % lens)
if "gotabwm: sel pull id=" not in ser:
    raise SystemExit("the expiry's compare pull is missing its seat receipt")
print("selection: copy len=6, expiry overwrite len=9, compare pull seen")
PY
# The KERNEL clipboard was never touched — our lane is the selection.
vgate_assert 02 serial-contains 'clip: empty'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# --- run 03: wrong passphrase is `unlock failed`, nothing more specific ----
vgate_run 03 -- \
    --screen '$RUN_DIR/vault-screen-03' \
    --via-virtio \
    --script '$RUN_DIR/script-03.txt' \
    --script2 '$RUN_DIR/script2-03.txt' \
    --script2-after 'gotabwm: registered' \
    --input-chords 'b,a,d,p,a,s,s,return,h,u,n,t,e,r,2,return,escape,escape' \
    --input-chords-after 'govault: locked' \
    --script-expect 'govault: exiting 0' --timeout 240

vgate_assert 03 serial-contains 'exec: loaded GOVAULT.ELF'
vgate_assert 03 serial-contains 'govault: locked'
vgate_assert 03 serial-contains 'govault: unlock failed'
vgate_assert 03 serial-contains 'govault: unlocked n=1'
vgate_assert 03 serial-contains 'govault OK'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'

# --- run 04: ciphertext tamper refuses as `unlock failed` -------------------
# `vf truncate 0 61` keeps the 44-byte header and cuts inside the sealed
# region: the frame still parses, the GCM tag still refuses — the named
# refusal, not a crash and not a partial unlock.
vgate_run 04 -- \
    --screen '$RUN_DIR/vault-screen-04' \
    --via-virtio \
    --script '$RUN_DIR/script-04.txt' \
    --input-chords 'h,u,n,t,e,r,2,return,escape' \
    --input-chords-after 'govault: locked' \
    --script-expect 'govault: exiting 0' --timeout 240

vgate_assert 04 serial-contains 'vf: open GOVAULT/VAULT.BIN'
vgate_assert 04 serial-contains 'vf: truncate 0 size=61 ok'
vgate_assert 04 serial-contains 'exec: loaded GOVAULT.ELF'
vgate_assert 04 serial-contains 'govault: locked'
vgate_assert 04 serial-contains 'govault: unlock failed'
vgate_assert 04 serial-absent 'govault: bad file'
vgate_assert 04 serial-absent 'govault: unlocked'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'

# --- run 05: magic tamper refuses as `bad file` -----------------------------
# `vf write 0 4` overwrites the GVLT magic through the host channel: the
# refusal is structural, named before a passphrase is spent.
vgate_run 05 -- \
    --screen '$RUN_DIR/vault-screen-05' \
    --via-virtio \
    --script '$RUN_DIR/script-05.txt' \
    --input-chords 'escape' \
    --input-chords-after 'govault: bad file' \
    --script-expect 'govault: exiting 0' --timeout 240

vgate_assert 05 serial-contains 'vf: write 0 n=4 wrote=4'
vgate_assert 05 serial-contains 'exec: loaded GOVAULT.ELF'
vgate_assert 05 serial-contains 'govault: bad file'
vgate_assert 05 serial-absent 'govault: unlock failed'
vgate_assert 05 serial-absent 'govault: unlocked'
vgate_assert 05 serial-contains 'govault OK'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'

# --- run 06: acceptance — the receipts face lists the journey in order ------
# Self-contained (M148b): the vault is deleted and recreated inside this leg,
# so it runs identically on every iteration. The journey is store, lock,
# unlock, reveal, copy, expire — then the Receipts face. The 'v' chord rides
# --input-string (printable-only) gated on 'govault: clip expired', so the
# receipts listing lands after the lease fire exactly as the card orders it;
# the run ends on 'govault: receipts end', which the app prints only after
# every row marker, so the assert sees the whole listing.
vgate_file script-06.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
vf rm GOVAULT/VAULT.BIN
wm
exec GOTABWM.ELF
EOF

vgate_file script2-06.txt <<'EOF'
dui focus 0
exec GOVAULT.ELF
EOF

vgate_run 06 -- \
    --screen '$RUN_DIR/vault-screen-06' \
    --via-virtio \
    --script '$RUN_DIR/script-06.txt' \
    --script2 '$RUN_DIR/script2-06.txt' \
    --script2-after 'gotabwm: registered' \
    --input-chords 'h,u,n,t,e,r,2,return,h,u,n,t,e,r,2,return,a,b,a,n,k,tab,h,u,n,t,e,r,3,tab,s,a,v,i,n,g,s,return,ctrl-l,h,u,n,t,e,r,2,return,r,c' \
    --input-chords-after 'govault: new vault' \
    --input-string 'v' \
    --input-string-after 'govault: clip expired' \
    --script-expect 'govault: receipts end' --timeout 240

vgate_assert 06 serial-contains 'gotabwm: registered'
vgate_assert 06 serial-contains 'exec: loaded GOVAULT.ELF'
vgate_assert 06 serial-contains 'govault: new vault'
vgate_assert 06 serial-contains 'govault: iterations '
vgate_assert 06 serial-contains 'govault: saved'
vgate_assert 06 serial-contains 'govault: unlocked n=0'
vgate_assert 06 serial-contains 'govault: added'
vgate_assert 06 serial-contains 'govault: locked'
vgate_assert 06 serial-contains 'govault: unlocked n=1'
vgate_assert 06 serial-contains 'govault: revealed'
vgate_assert 06 serial-contains 'govault: copied'
vgate_assert 06 serial-contains 'govault: clip expired'
vgate_assert 06 serial-contains 'govault: receipts end'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'exited status=139'
# The Receipts face on serial: a contiguous i=0..n-1 listing matching the
# count line, ending on the journey's own rows — unlock, reveal, copy — in
# append order.
vgate_assert 06 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], "rb").read().decode("utf-8", "replace")
rows = re.findall(r"govault: rcpt i=(\d+) (\S+)", ser)
m = re.search(r"govault: receipts n=(\d+)", ser)
if not m or not rows:
    raise SystemExit("no receipts listing on serial")
n = int(m.group(1))
if len(rows) != n or [int(i) for i, _ in rows] != list(range(n)):
    raise SystemExit("receipt listing incomplete/disordered: %d rows "
                     "vs n=%d: %s" % (len(rows), n, rows))
tail = [a for _, a in rows[-3:]]
if tail != ["unlock", "reveal", "copy"]:
    raise SystemExit("receipt tail %s — want the journey's "
                     "unlock,reveal,copy in order" % tail)
print("Receipts face listed n=%d rows, contiguous, tail=unlock,reveal,copy" % n)
PY
# The vault's own receipts file on the share (share-contains also lifts the
# file into the evidence artifacts): the stored entry's name lands on its
# reveal and copy rows.
vgate_assert 06 share-contains GOVAULT/RECEIPTS.TXT 'reveal bank'
vgate_assert 06 share-contains GOVAULT/RECEIPTS.TXT 'copy bank'
# Every row is "<epoch> <action> <name>", the tail is the leg's journey in
# order, the names are the stored entry's — and no secret material ever
# lands in it.
vgate_assert 06 python <<'PY'
import os, re
share = os.environ["VG_SHARE"]
data = open(os.path.join(share, "GOVAULT", "RECEIPTS.TXT"), "rb").read().decode("utf-8", "replace")
rows = []
for ln in data.split("\n"):
    if not ln:
        continue
    m = re.match(r"(\d+) (\S+) (.*)$", ln)
    if not m:
        raise SystemExit("corrupt receipt row: %r" % ln)
    rows.append((int(m.group(1)), m.group(2), m.group(3)))
acts = [a for _, a, _ in rows]
if acts[-3:] != ["unlock", "reveal", "copy"]:
    raise SystemExit("RECEIPTS.TXT tail = %s, want unlock,reveal,copy" % acts[-3:])
for action in ("unlock", "reveal", "copy", "unlock-failed"):
    if action not in acts:
        raise SystemExit("no %s receipt in the file" % action)
if rows[-2][2] != "bank" or rows[-1][2] != "bank":
    raise SystemExit("tail names = %r/%r, want the stored entry 'bank'"
                     % (rows[-2][2], rows[-1][2]))
for secret in ("hunter2", "hunter3", "s3cr3t"):
    if secret in data:
        raise SystemExit("SECRET material in the receipts file: %r" % secret)
print("RECEIPTS.TXT: %d rows, ordered tail unlock,reveal,copy(bank), no secrets" % len(rows))
PY
# The copy landed on the seat's selection (7-byte "hunter3" publish), and the
# expiry overwrite wrote the 9-byte [cleared] sentinel after the compare pull.
vgate_assert 06 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"], "rb").read().decode("utf-8", "replace")
lens = [int(m.group(1))
        for m in re.finditer(r"gotabwm: sel pub id=\d+ len=(\d+)", ser)]
if len(lens) < 2 or lens[0] != 7 or 9 not in lens[1:]:
    raise SystemExit("selection publishes len=%s, want 7 then 9 "
                     "(the [cleared] overwrite)" % lens)
if "gotabwm: sel pull id=" not in ser:
    raise SystemExit("the expiry's compare pull is missing its seat receipt")
print("selection: copy len=7, expiry overwrite len=9, compare pull seen")
PY
