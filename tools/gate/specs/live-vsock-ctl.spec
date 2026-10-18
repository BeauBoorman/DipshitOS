# live-vsock-ctl.spec — M115b (#2461, ADR 0056): the virelai-ctl/1
# guest→host control channel on the M115a vsock device.
#
# Run `ok` is the full wire on a seeded share: the runner arms the ctl
# listener (`--vsock-ctl`, port 1209 — the M115a probe listener on 1208
# stays up beside it), and the guest's `vsock ctl` monitor client runs a
# session per command — connect, HMAC-challenge auth, one request line,
# reply, shutdown. Positives: `suspend` and `snapshot SNAP-1` round-trip
# to the named `unimplemented` refusal (the verbs are wired, not armed —
# M115d/e do the acting), `frobnicate` answers `unknown_verb`, and `dup`
# answers `replay` for the repeated request id. Auth negatives are driven
# entirely from the guest side: `badauth` corrupts the MAC, `replay`
# re-uses a captured auth line on a fresh connection (the new challenge
# makes it `auth_failed`).
#
# Run `nokey` is the fail-closed posture: a share without the `vsock-ctl`
# SECRETS.TXT row — the runner refuses to arm (no listener, an honest RST
# for any connect) and the guest refuses the command itself, each naming
# `no_credential`.
#
# The credential: `vsock-ctl<TAB>0<TAB><value>` — a uid_system row with no
# app binding, so no EL0 sys_secret_get reader can see it; the kernel's
# own ctl client is its only in-guest consumer (ADR 0056 D2).

vgate_name live-vsock-ctl "M115b #2461: virelai-ctl/1 over virtio-vsock — verb round trips + auth negatives"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import os
run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
# The pinned-vector credential (ASCII 'a5' x 32 — the ADR 0056 test key),
# uid_system and app-unbound.
key = "a5" * 32
open(os.path.join(share, "SECRETS.TXT"), "w").write(
    "#v1\nvsock-ctl\t0\t" + key + "\n"
)
# The no-credential leg's share: a valid #v1 file that simply lacks the
# vsock-ctl row (the row it carries is someone else's).
alt = os.path.join(run, "nokey-share")
os.makedirs(alt, exist_ok=True)
open(os.path.join(alt, "SECRETS.TXT"), "w").write(
    "#v1\nhost-int\t1000\t" + "00" * 32 + "\n"
)
print("staged vsock-ctl shares (keyed + nokey)")
PY

vgate_file script.txt <<'EOF'
vsock ctl suspend
vsock ctl snapshot SNAP-1
vsock ctl frobnicate
vsock ctl dup suspend
vsock ctl badauth suspend
vsock ctl replay suspend
vsock 1208
echo ctl-done
EOF

vgate_file script-nokey.txt <<'EOF'
vsock ctl suspend
echo ctl-nokey-done
EOF

# Full wire: both verbs round-trip to `unimplemented`, the unknown verb and
# the duplicated id are refused by name, and both auth negatives die at
# the challenge. The M115a probe listener still works alongside.
vgate_run ok -- --vsock --vsock-ctl --script '$RUN_DIR/script.txt' --script-expect 'ctl-done' --timeout 120
vgate_assert ok serial-contains 'vsock: ready did=0x1053'
vgate_assert ok output-contains 'VSOCK: ENABLED host-listen-port=1208'
vgate_assert ok output-contains 'VSOCK-CTL: host listener armed port=1209'
vgate_assert ok output-contains 'VSOCK-CTL: session opened'
vgate_assert ok serial-count 'vsock-ctl: authed' 5
vgate_assert ok serial-count 'vsock-ctl: reply id=1 ok=false code=unimplemented' 3
vgate_assert ok serial-contains 'vsock-ctl: reply id=1 ok=false code=unknown_verb'
vgate_assert ok serial-contains 'vsock-ctl: reply id=1 ok=false code=replay'
vgate_assert ok serial-contains 'vsock-ctl: auth refused code=auth_failed'
vgate_assert ok serial-contains 'vsock-ctl: replay refused code=auth_failed'
vgate_assert ok serial-contains 'vsock-ctl: closed'
vgate_assert ok serial-contains 'vsock: connected port=1208'
vgate_assert ok serial-absent '[EXC]'

# Fail-closed posture leg: no vsock-ctl row on the run's own share. The
# host never arms the listener; the guest refuses before connecting.
vgate_run nokey -- --vsock --vsock-ctl --cvc-file '$RUN_DIR/nokey-share' \
  --script '$RUN_DIR/script-nokey.txt' --script-expect 'ctl-nokey-done' --timeout 90
vgate_assert nokey output-contains 'VSOCK-CTL: refuse no_credential'
vgate_assert nokey serial-contains 'vsock-ctl: refuse no_credential'
vgate_assert nokey serial-absent 'vsock-ctl: authed'
vgate_assert nokey serial-absent '[EXC]'
