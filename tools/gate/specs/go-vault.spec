# go-vault.spec -- M148a (issue #2804): GOVAULT.ELF class-B gate. A
# PBKDF2+AES-256-GCM vault file under the Go seat: create the vault through
# the masked pair, add an entry, reveal it, copy the secret onto the seat's
# primary selection, watch the 30 s lease expire, lock, unlock, quit. Two
# tamper legs and a wrong-pass leg pin the named refusals.
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

vgate_name go-vault "M148a #2804: PBKDF2/AES-GCM vault — masked unlock, entry store, per-entry reveal, copy-with-expiry on the seat selection, idle lock, named refusals"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-01.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
wm
exec GOTABWM.ELF
EOF

vgate_file script2-01.txt <<'EOF'
dui focus 0
exec GOVAULT.ELF
EOF

# Create the vault (two masked fields), add wifi/s3cr3t/home, reveal, copy,
# ctrl-l lock, unlock, esc lock, esc quit.
vgate_file script-02.txt <<'EOF'
set GOMAXPROCS=1
vf rm GOTABWM.DEMO
vf rm SESSION.TABS
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

# Tamper legs need no seat: the refusals live in the load/unlock path.
vgate_file script-04.txt <<'EOF'
vf open GOVAULT/VAULT.BIN
vf truncate 0 61
vf close 0
exec GOVAULT.ELF
EOF

vgate_file script-05.txt <<'EOF'
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
