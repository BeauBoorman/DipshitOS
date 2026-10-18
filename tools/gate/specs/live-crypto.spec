# live-crypto.spec -- M47 CP5 (issue #1119): the guest-class-B proof that
# the freestanding crypto library produces the SAME bytes on the guest as
# the host. The EL0 app CRYPTOD.BIN streams a pinned share file through
# SHA-256 + HMAC-SHA256 (fixed demo key) and prints one line in ONE write;
# the harness recomputes both on the host and asserts the guest line is
# byte-exact. Fixed vectors first — no randomness, no protocol, no net.

vgate_name live-crypto "M47 CP5: guest CRYPTOD digest/HMAC == host KAT"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec CRYPTOD.BIN CRYPTO.TXT
echo rx-crypto-ok
EOF

vgate_setup_python <<'PY'
import os, hashlib, hmac

run_dir = os.environ["RUN_DIR"]
share = os.path.join(run_dir, "share")
os.makedirs(share, exist_ok=True)

# Pinned fixture: every byte value 0x00..0xff exactly once (256 bytes).
data = bytes(range(256))
with open(os.path.join(share, "CRYPTO.TXT"), "wb") as f:
    f.write(data)

# The demo HMAC key is the ASCII literal in user/src/cryptod.zig.
key = b"VIRELAIOS-M47-CRYPTO-DEMO-KEY"
line = "cryptod: sha256=%s hmac=%s" % (
    hashlib.sha256(data).hexdigest(),
    hmac.new(key, data, hashlib.sha256).hexdigest(),
)
with open(os.path.join(run_dir, "expected.txt"), "w") as f:
    f.write(line + "\n")

# exec CRYPTOD.BIN CRYPTO.TXT passes an argument: the flat-bin argv block
# (2 KiB) must fit inside the content's last page (exec.zig argv_va_for),
# so content sizes in the (2048, 4096) mod-4096 window refuse with
# 'no_args_room'. Pad the staged copy with load-inert zeros past it.
p = os.path.join(share, "CRYPTOD.BIN")
size = os.path.getsize(p)
if 2048 < size % 4096:
    with open(p, "ab") as f:
        f.write(b"\0" * ((size // 4096 + 1) * 4096 + 8 - size))
print("live-crypto: staged CRYPTOD.BIN argv-pad check, size=%d -> %d" %
      (size, os.path.getsize(p)))
print("live-crypto: host KAT = " + line)
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "virelai>" --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded CRYPTOD.BIN size='
# The proof: the host-recomputed line occurs verbatim in the guest serial.
vgate_assert 01 serial-contains-file expected.txt
vgate_assert 01 serial-contains 'rx-crypto-ok'
vgate_assert 01 serial-absent 'cryptod: cannot open file'
vgate_assert 01 serial-absent 'cryptod: read error'
vgate_assert 01 serial-absent 'cryptod: usage'
vgate_assert 01 serial-absent '[EXC] parking:'

# Independent host self-check: recompute the KAT from the pinned fixture and
# compare against the literals committed in this spec, and against the
# generated expected.txt. A stale literal or a drifted fixture fails here.
vgate_assert 01 python <<'PY'
import os, hashlib, hmac

RUN_DIR = os.environ["RUN_DIR"]
data = bytes(range(256))
key = b"VIRELAIOS-M47-CRYPTO-DEMO-KEY"
want_sha = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880"
want_mac = "706ad4b909d7311c88d736cf8dc6998a2b90b12b6d64f6eb676e227c6251a420"
got_sha = hashlib.sha256(data).hexdigest()
got_mac = hmac.new(key, data, hashlib.sha256).hexdigest()
assert got_sha == want_sha, "sha256 drifted: %s != %s" % (got_sha, want_sha)
assert got_mac == want_mac, "hmac drifted: %s != %s" % (got_mac, want_mac)
want_line = "cryptod: sha256=%s hmac=%s" % (want_sha, want_mac)
with open(os.path.join(RUN_DIR, "expected.txt")) as f:
    exp = f.read().strip()
assert exp == want_line, "expected.txt drifted: %r != %r" % (exp, want_line)
print("live-crypto: host KAT recomputation matches the pinned RFC/FIPS vectors")
PY
