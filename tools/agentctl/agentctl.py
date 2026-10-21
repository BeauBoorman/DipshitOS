#!/usr/bin/env python3
"""tools/agentctl/agentctl.py -- M109b agent control channel client (ADR 0052).

Two uses of one stdlib-only file:

  * Library: ``Session`` speaks the v2 JSON-Lines protocol over any pair of
    binary file-like objects (one read side, one write side).
  * Harness: ``agentctl.py harness --journey=<J> --key-file=<K>`` is the
    runner's ``--net-tcp-connect-stream`` child. Stdin carries guest->host
    bytes, stdout carries host->guest bytes, and stderr carries the
    ``AGENTCTL: ok|FAIL|PASS`` evidence lines the gate asserts on.

The credential is an Ed25519 seed held host-side only: the key file is
``<agent-id> <64 lowercase hex seed>``. The guest sees the public half in
AGENTS.TXT; the private half never enters the VM (ADR 0052 D1).

Nothing sensitive is ever printed (ADR 0044 D6): the seed, challenge,
signature, request paths, file bytes, ``cmd`` text and command output
never reach stderr.
"""

import argparse
import base64
import hashlib
import json
import select
import sys
import time

# ---------------------------------------------------------------------------
# RFC 8032 Ed25519, minimal sign-only implementation (stdlib has none).
# Pinned to TEST 1-3 by ed_selftest() and, end to end, by every gate run.
# ---------------------------------------------------------------------------

_Q = 2**255 - 19
_L = 2**252 + 27742317777372353535851937790883648493
_D = (-121665 * pow(121666, _Q - 2, _Q)) % _Q
_I = pow(2, (_Q - 1) // 4, _Q)


def _inv(x):
    return pow(x, _Q - 2, _Q)


def _xrecover(y):
    xx = (y * y - 1) * _inv(_D * y * y + 1)
    x = pow(xx, (_Q + 3) // 8, _Q)
    if (x * x - xx) % _Q != 0:
        x = (x * _I) % _Q
    if x & 1:
        x = _Q - x
    return x


_BY = (4 * _inv(5)) % _Q
_B = (_xrecover(_BY), _BY)


def _ed_add(p, q):
    x1, y1 = p
    x2, y2 = q
    t = _D * x1 * x2 * y1 * y2
    x3 = (x1 * y2 + x2 * y1) * _inv(1 + t) % _Q
    y3 = (y1 * y2 + x1 * x2) * _inv(1 - t) % _Q
    return (x3, y3)


def _ed_mul(p, e):
    q = (0, 1)
    while e:
        if e & 1:
            q = _ed_add(q, p)
        p = _ed_add(p, p)
        e >>= 1
    return q


def _enc_point(p):
    x, y = p
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _clamp(h):
    a = bytearray(h[:32])
    a[0] &= 248
    a[31] &= 63
    a[31] |= 64
    return int.from_bytes(a, "little")


def _hint(m):
    return int.from_bytes(hashlib.sha512(m).digest(), "little")


def ed_public_key(seed):
    """SEED (32 bytes) -> the Ed25519 public key (32 bytes)."""
    a = _clamp(hashlib.sha512(seed).digest())
    return _enc_point(_ed_mul(_B, a))


def ed_sign(msg, seed):
    """The RFC 8032 signature of MSG under SEED (64 bytes)."""
    h = hashlib.sha512(seed).digest()
    a = _clamp(h)
    pub = _enc_point(_ed_mul(_B, a))
    r = _hint(h[32:] + msg) % _L
    r_enc = _enc_point(_ed_mul(_B, r))
    k = _hint(r_enc + pub + msg) % _L
    return r_enc + ((r + k * a) % _L).to_bytes(32, "little")


def ed_selftest():
    """RFC 8032 TEST 1 known-answer check; returns True or raises."""
    seed = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
    want_pub = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    want_sig = ("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
                "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
    if ed_public_key(seed).hex() != want_pub:
        raise Fail("ed25519 public key derivation failed the RFC vector")
    if ed_sign(b"", seed).hex() != want_sig:
        raise Fail("ed25519 signing failed the RFC vector")
    return True


DOMAIN = b"VIRELAI-AGENT/1 ed25519\x00"

# Fixed fixtures. tools/gate/specs/go-agentd.spec stages AGENT/SEED.TXT
# with SEED_BYTES, AGENT/SUB/DEEP.TXT with DEEP_BYTES, and compares
# AGENT/HELLO.TXT / AGENT/SUB/NEW.TXT against the payloads. STDOUT_SENTINEL
# is produced by one gosh.run step so the gate can prove command output
# never reaches serial.
SEED_BYTES = b"virelai-agent-seed:the quick brown fox 0044\n"
DEEP_BYTES = b"virelai-agent-deep:sandbox subdirectory bytes 0052\n"
PAYLOAD = b"agentctl-payload-sentinel-44\n"
NESTED_PAYLOAD = b"agentctl-nested-payload-sentinel-52\n"
STDOUT_SENTINEL = b"agentctl-stdout-sentinel-44"
# The stream stressor: a 4096-byte staged file catted N times — gosh's
# read bound is per file, so `cat W W W` is the in-grammar way to make a
# single redirect emit more than one stream chunk (ADRT: bounded under
# the 192-byte cmd limit).
WIDE_COPIES = 3


def wide_bytes():
    """Exactly 4096 deterministic bytes for AGENT/WIDE.TXT (16B rows)."""
    out = bytearray()
    for i in range(256):
        out += b"AGENTWIDE-%05d\n" % i  # 10 + 5 + 1 = 16 bytes
    assert len(out) == 4096
    return bytes(out)

MAX_LINE = 8192          # session line bound, LF included (D1)
GREET_TIMEOUT = 20.0     # the greeting is immediate; a wait is a hang
RESP_TIMEOUT = 30.0      # any single request's answer (streams may span lines)
UI_WAIT = 60.0           # run 01 stages GOCALC after the first ui.windows
MUTE_TIMEOUT = 15.0      # run 04: auth_timeout must land inside 15 s


class Fail(Exception):
    """One harness step failed."""


class PeerGone(Exception):
    """The daemon closed the stream."""


class ProtoError(Exception):
    """The daemon sent something the protocol forbids."""


class Refused(Exception):
    """A well-formed ``{"ok":false,...}`` answer."""

    def __init__(self, code, message=""):
        super().__init__(code)
        self.code = code
        self.message = message


def b64e(b):
    return base64.b64encode(b).decode("ascii")


def b64d(s):
    return base64.b64decode(s)


class Session:
    """The v2 protocol over a binary (rd, wr) pair."""

    def __init__(self, rd, wr):
        self.rd = rd
        self.wr = wr
        # A BufferedReader's read(n) waits for the FULL n or EOF — over a
        # pipe that means session bytes sit unread until close. read1
        # returns after one raw read; plain file-like fakes fall back.
        self._read = getattr(rd, "read1", None) or rd.read
        self._buf = bytearray()
        self._next = 0
        self.challenge = None
        self.agent = None
        self.caps = None
        self.verbs = None

    # ---- transport ----------------------------------------------------------

    def _fill(self, timeout=None):
        if timeout is not None:
            try:
                ready, _, _ = select.select([self.rd], [], [], timeout)
            except (OSError, ValueError, TypeError):
                ready = [self.rd]  # a non-fd test transport is always ready
            if not ready:
                raise TimeoutError("no bytes before the deadline")
        chunk = self._read(4096)
        if not chunk:
            raise PeerGone("peer closed")
        self._buf += chunk

    def readline(self, timeout=None):
        """One line without its LF (a CR before the LF is stripped)."""
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            i = self._buf.find(b"\n")
            if i >= 0:
                line = bytes(self._buf[:i])
                if line.endswith(b"\r"):
                    line = line[:-1]
                del self._buf[: i + 1]
                return line
            if len(self._buf) > MAX_LINE:
                raise ProtoError("an inbound line exceeded the byte limit")
            remain = None
            if deadline is not None:
                remain = deadline - time.monotonic()
                if remain <= 0:
                    raise TimeoutError("no line before the deadline")
            self._fill(remain)

    def send_raw(self, line):
        """Send LINE plus its LF. LINE is bytes with no embedded newline."""
        self.wr.write(line + b"\n")
        self.wr.flush()

    def read_json(self, timeout=None):
        line = self.readline(timeout)
        try:
            obj = json.loads(line)
        except ValueError:
            raise ProtoError("a response line was not JSON")
        if not isinstance(obj, dict):
            raise ProtoError("a response line was not a JSON object")
        return obj

    # ---- handshake ------------------------------------------------------------

    def greeting(self, timeout=GREET_TIMEOUT):
        obj = self.read_json(timeout)
        if obj.get("proto") != "virelai-agent/2" or obj.get("auth") != "ed25519":
            raise ProtoError("greeting is not the v2 shape")
        ch = obj.get("challenge")
        if (
            not isinstance(ch, str)
            or len(ch) != 64
            or any(c not in "0123456789abcdef" for c in ch)
        ):
            raise ProtoError("greeting challenge is not 64 lowercase hex")
        self.challenge = bytes.fromhex(ch)
        return self.challenge

    def sign_message(self, agent_id):
        """The D2 transcript: domain || 0x00 || challenge || 0x00 || id."""
        return DOMAIN + self.challenge + b"\x00" + agent_id.encode("utf-8")

    def auth(self, agent_id, seed):
        if self.challenge is None:
            self.greeting()
        sig = ed_sign(self.sign_message(agent_id), seed)
        self.send_raw(
            ('{"agent":"%s","auth":"%s"}' % (agent_id, sig.hex())).encode("ascii")
        )
        obj = self.read_json(timeout=RESP_TIMEOUT)
        if obj.get("ok") is False:
            err = obj.get("error") or {}
            raise Refused(err.get("code", "?"), err.get("message", ""))
        if obj.get("ok") is not True or obj.get("session") != "ready":
            raise ProtoError("the ready line is not the v2 shape")
        if obj.get("agent") != agent_id:
            raise ProtoError("the ready line named a different agent")
        caps = obj.get("caps")
        verbs = obj.get("verbs")
        for name, val in (("caps", caps), ("verbs", verbs)):
            if not isinstance(val, list) or not all(isinstance(v, str) for v in val):
                raise ProtoError("the ready line's %s is not a string list" % name)
        self.agent = agent_id
        self.caps = caps
        self.verbs = verbs
        return verbs

    def connect(self, agent_id, seed):
        """greeting + auth; returns the advertised verb list."""
        self.greeting()
        return self.auth(agent_id, seed)

    # ---- requests -------------------------------------------------------------

    def call(self, verb, **args):
        self._next += 1
        rid = self._next
        req = {"id": rid, "verb": verb}
        req.update(args)
        self.send_raw(json.dumps(req, separators=(",", ":")).encode("utf-8"))
        chunks = []
        while True:
            obj = self.read_json(timeout=RESP_TIMEOUT)
            if obj.get("id") != rid:
                raise ProtoError("response id did not echo the request")
            if "stream" in obj:
                if obj.get("ok") is not True or obj.get("stream") != len(chunks):
                    raise ProtoError("a stream chunk was out of order")
                data = obj.get("data_b64")
                if not isinstance(data, str):
                    raise ProtoError("a stream chunk carried no data_b64")
                chunks.append(b64d(data))
                continue
            if obj.get("ok") is True:
                res = obj.get("result")
                if not isinstance(res, dict):
                    raise ProtoError("ok result is not an object")
                res["stream"] = chunks
                return res
            if obj.get("ok") is False:
                err = obj.get("error") or {}
                raise Refused(err.get("code", "?"), err.get("message", ""))
            raise ProtoError("response carries neither ok:true nor ok:false")

    def refused_raw(self, raw, timeout=RESP_TIMEOUT):
        """Send RAW (bytes, no LF) and return the parsed response object."""
        self.send_raw(raw)
        return self.read_json(timeout)


def expect_refused(fn, code):
    """fn must raise Refused(code); anything else fails the step."""
    try:
        fn()
    except Refused as r:
        if r.code != code:
            raise Fail("expected %s, got %s" % (code, r.code))
        return
    raise Fail("expected %s, request succeeded" % code)


def raw_code(s, raw):
    """Send a raw line; return its error code (Fail on ok:true or bad shape)."""
    obj = s.refused_raw(raw)
    if obj.get("ok") is not False:
        raise Fail("a malformed line was answered ok")
    return (obj.get("error") or {}).get("code")


def expect_raw_code(s, raw, code):
    got = raw_code(s, raw)
    if got != code:
        raise Fail("expected %s, got %s" % (code, got))


def stream_bytes(res):
    """The reassembled stream payload of a call() result."""
    return b"".join(res.get("stream") or [])


# ---- the journeys ------------------------------------------------------------


def journey_full(s, cred):
    agent_pid = []

    def handshake():
        verbs = s.connect(cred[0], cred[1])
        if "gosh.run" not in verbs:
            raise Fail("gosh.run is not advertised with --allow-exec")
        for v in (
            "proc.list", "proc.get", "fs.read", "fs.write",
            "ui.windows", "ui.screenshot",
        ):
            if v not in verbs:
                raise Fail("missing advertised verb " + v)
        for c in ("file", "process", "window", "term"):
            if c not in s.caps:
                raise Fail("missing declared cap " + c)

    def proc_list():
        res = s.call("proc.list")
        rows = res.get("procs")
        if not isinstance(rows, list):
            raise Fail("procs is not a list")
        me = [r for r in rows if r.get("name") == "AGENTD.ELF" and r.get("state") == "running"]
        if not me:
            raise Fail("AGENTD.ELF running is absent from proc.list")
        agent_pid.append(me[0]["pid"])

    def proc_get():
        res = s.call("proc.get", pid=agent_pid[0])
        if res.get("name") != "AGENTD.ELF" or res.get("pid") != agent_pid[0]:
            raise Fail("proc.get did not return the AGENTD.ELF row")

    def proc_reds():
        expect_refused(lambda: s.call("proc.list", x=1), "bad_request")
        expect_refused(lambda: s.call("proc.get", pid=0), "bad_request")
        expect_refused(lambda: s.call("proc.get", pid=4000), "not_found")
        expect_refused(lambda: s.call("proc.get", pid="1"), "bad_request")

    def fs_read_seed():
        res = s.call("fs.read", path="SEED.TXT")
        if res.get("size") != len(SEED_BYTES) or b64d(res.get("data_b64", "")) != SEED_BYTES:
            raise Fail("SEED.TXT did not round-trip its fixed bytes")

    def fs_read_reds():
        for path, code in (
            ("../SECRETS.TXT", "path_rejected"),
            ("/host/SECRETS.TXT", "path_rejected"),
            ("SUB/../X", "path_rejected"),
            (".", "path_rejected"),
            ("..", "path_rejected"),
            ("", "path_rejected"),
            ("A" * 49, "path_rejected"),
            ("X~", "path_rejected"),
            ("A\x00B", "path_rejected"),
            ("SUB//X", "path_rejected"),
            ("A/B/C/D/E", "path_rejected"),
            ("AUDIT/R1", "path_rejected"),
            ("audit/x", "path_rejected"),
            ("NOPE.TXT", "not_found"),
            ("SUB/NOPE.TXT", "not_found"),
            ("BIG.BIN", "too_large"),
        ):
            expect_refused(lambda p=path: s.call("fs.read", path=p), code)

    def fs_depth():
        # Bounded depth: a staged subdirectory file reads back, and a
        # write lands through the parent directory.
        res = s.call("fs.read", path="SUB/DEEP.TXT")
        if b64d(res.get("data_b64", "")) != DEEP_BYTES:
            raise Fail("SUB/DEEP.TXT did not round-trip its fixed bytes")
        res = s.call("fs.write", path="SUB/NEW.TXT", data_b64=b64e(NESTED_PAYLOAD))
        if res.get("size") != len(NESTED_PAYLOAD):
            raise Fail("SUB/NEW.TXT size did not echo the payload length")
        res = s.call("fs.read", path="SUB/NEW.TXT")
        if b64d(res.get("data_b64", "")) != NESTED_PAYLOAD:
            raise Fail("SUB/NEW.TXT did not round-trip the payload")

    def fs_write():
        res = s.call("fs.write", path="HELLO.TXT", data_b64=b64e(PAYLOAD))
        if res.get("size") != len(PAYLOAD):
            raise Fail("HELLO.TXT size did not echo the payload length")

    def fs_read_hello():
        res = s.call("fs.read", path="HELLO.TXT")
        if b64d(res.get("data_b64", "")) != PAYLOAD:
            raise Fail("HELLO.TXT did not round-trip the payload")

    def fs_write_reds():
        expect_refused(
            lambda: s.call("fs.write", path="TOOBIG.BIN", data_b64=b64e(b"\x00" * 4097)),
            "too_large",
        )
        expect_refused(
            lambda: s.call("fs.write", path="BAD.BIN", data_b64="@@"), "bad_request"
        )
        expect_refused(
            lambda: s.call("fs.write", path="../X", data_b64=b64e(b"x")), "path_rejected"
        )
        expect_refused(
            lambda: s.call("fs.write", path="AUDIT/F.TXT", data_b64=b64e(b"x")),
            "path_rejected",
        )

    def gosh_green():
        res = s.call("gosh.run", cmd="echo hello")
        if res.get("exit_status") != 0 or stream_bytes(res) != b"hello\n":
            raise Fail("echo hello did not stream hello\\n status 0")
        if res.get("stdout_bytes") != 6 or res.get("truncated") is not False:
            raise Fail("echo hello result shape drifted")
        res = s.call("gosh.run", cmd="cat NOPE.TXT")
        if res.get("exit_status") == 0:
            raise Fail("cat NOPE.TXT unexpectedly exited 0")
        res = s.call("gosh.run", cmd="cat /host/SECRETS.TXT")
        if res.get("exit_status") == 0:
            raise Fail("cat SECRETS.TXT unexpectedly exited 0")
        if cred[1] in stream_bytes(res):
            raise Fail("the secret value appeared in command stdout")
        res = s.call("gosh.run", cmd="echo " + STDOUT_SENTINEL.decode("ascii"))
        if STDOUT_SENTINEL not in stream_bytes(res):
            raise Fail("the stdout sentinel was not captured")

    def gosh_stream():
        # Bounded streaming: the staged 4096-byte WIDE.TXT catted three
        # times is 12288 bytes — several ordered chunk lines bounded per
        # line, reassembling to exactly the fixture thrice.
        path = "/host/AGENT/WIDE.TXT"
        res = s.call("gosh.run", cmd="cat %s %s %s" % (path, path, path))
        out = stream_bytes(res)
        if res.get("exit_status") != 0 or res.get("truncated") is not False:
            raise Fail("the wide cat did not complete cleanly")
        if len(res.get("stream") or []) < 2:
            raise Fail("the wide cat did not arrive in multiple chunks")
        if out != wide_bytes() * WIDE_COPIES:
            raise Fail("the wide stream reassembly drifted")
        if res.get("stdout_bytes") != len(out):
            raise Fail("stdout_bytes did not count the streamed payload")
        res = s.call("gosh.run", cmd="cat %s %s %s %s %s" % ((path,) * 5))
        if res.get("truncated") is not True:
            raise Fail("an over-bound capture was not marked truncated")
        if res.get("stdout_bytes") != 16384 or len(stream_bytes(res)) != 16384:
            raise Fail("the truncated stream did not stop at the bound")

    def gosh_reds():
        for cmd in ("echo a > X", "echo a #c", "echo a &", "echo 'a", "echo a\nls"):
            expect_refused(lambda c=cmd: s.call("gosh.run", cmd=c), "cmd_rejected")
        expect_refused(lambda: s.call("gosh.run", cmd="a" * 193), "too_large")
        expect_refused(lambda: s.call("gosh.run", cmd="echo a", timeout_ms=0), "bad_request")
        expect_refused(
            lambda: s.call("gosh.run", cmd="echo a", timeout_ms=30001), "bad_request"
        )

    def gosh_timeout():
        expect_refused(
            lambda: s.call("gosh.run", cmd="sleep 5", timeout_ms=1000), "timed_out"
        )

    def ui_windows():
        # The gate stages GOCALC.ELF only after the first ui.windows
        # request (the task pool cannot seat four Go runtimes at once —
        # see go-agentd.spec run 01). Poll until the Calc row and the
        # single-focus invariant land.
        deadline = time.monotonic() + UI_WAIT
        last = "empty window list"
        while True:
            try:
                res = s.call("ui.windows")
            except Refused as r:
                res = None
                last = "refused " + r.code
            if res is not None:
                if res.get("seat") != "gotabwm":
                    raise Fail("seat is not gotabwm")
                rows = res.get("windows")
                if isinstance(rows, list) and any(
                    r.get("title") == "Calc" for r in rows
                ):
                    focused = [r for r in rows if r.get("focused") is True]
                    if len(focused) == 1 and res.get("focused") == focused[
                        0
                    ].get("index"):
                        break
                last = "no focused Calc row"
            if time.monotonic() >= deadline:
                raise Fail("ui.windows never showed a focused Calc row: " + last)
            time.sleep(1)
        expect_refused(lambda: s.call("ui.windows", x=1), "bad_request")

    def ui_screenshot():
        # A freshly-tiled client's shared surface is all-zero until its first
        # paint lands — the seat composites those zero bytes over the whole
        # viewport and the scanout honestly holds them. Poll past that
        # transient rather than racing it: the seat is alive either way, and
        # the verb's contract is the real frame.
        deadline = time.monotonic() + 30
        while True:
            res = s.call("ui.screenshot")
            if res.get("w") != 160 or res.get("h") != 90:
                raise Fail("screenshot shape is not 160x90")
            if res.get("format") != "rgb565le" or res.get("bytes") != 160 * 90 * 2:
                raise Fail("screenshot format/byte count drifted")
            pix = stream_bytes(res)
            if len(pix) != 160 * 90 * 2:
                raise Fail("screenshot stream reassembled %d bytes" % len(pix))
            if any(pix):
                break
            if time.monotonic() >= deadline:
                raise Fail("screenshot stayed all-zero on a live seat")
            time.sleep(1)

    def framing_reds():
        expect_raw_code(s, b"{", "bad_json")
        expect_raw_code(s, b'{"verb":"proc.list"}', "bad_request")
        expect_raw_code(s, b'{"id":1,"verb":"nope"}', "unknown_verb")
        expect_raw_code(s, b'{"id":1,"id":2,"verb":"proc.list"}', "bad_request")
        expect_raw_code(s, b'{"id":1,"verb":"proc.list","a":{}}', "bad_request")
        expect_raw_code(s, b"null", "bad_request")

    def too_long():
        s.send_raw(b"x" * 8192)  # 8192 content bytes + LF = over the bound
        obj = s.read_json(timeout=RESP_TIMEOUT)
        if (obj.get("error") or {}).get("code") != "line_too_long":
            raise Fail("an 8193-byte line was not refused line_too_long")
        # The daemon waits for the peer before closing (see journey_badsig);
        # the harness exit closes this session from the client side.

    return [
        ("handshake", handshake),
        ("proc.list", proc_list),
        ("proc.get", proc_get),
        ("proc-reds", proc_reds),
        ("fs.read-seed", fs_read_seed),
        ("fs.read-reds", fs_read_reds),
        ("fs-depth", fs_depth),
        ("fs.write", fs_write),
        ("fs.read-hello", fs_read_hello),
        ("fs.write-reds", fs_write_reds),
        ("gosh-green", gosh_green),
        ("gosh-stream", gosh_stream),
        ("gosh-reds", gosh_reds),
        ("gosh-timeout", gosh_timeout),
        ("ui.windows", ui_windows),
        ("ui.screenshot", ui_screenshot),
        ("framing-reds", framing_reds),
        ("line-too-long", too_long),
    ]


def journey_badsig(s, cred):
    def handshake():
        ch = s.greeting()
        good = ed_sign(s.sign_message(cred[0]), cred[1]).hex()
        bad = ("0" if good[0] != "0" else "1") + good[1:]
        s.send_raw(('{"agent":"%s","auth":"%s"}' % (cred[0], bad)).encode("ascii"))

    def refused():
        obj = s.read_json(timeout=RESP_TIMEOUT)
        if (obj.get("error") or {}).get("code") != "auth_failed":
            raise Fail("a wrong signature was not refused auth_failed")
        if "ok" in obj and obj.get("ok") is True:
            raise Fail("a wrong signature was answered ready")
        # No expect_close: the daemon waits for the peer before it closes
        # (a guest-first FIN strands the kernel waiting on a FIN+ACK this
        # transport never sends). The harness's own exit IS the close —
        # the VANISH set makes it an abrupt one, which the runner turns
        # into the RST that releases the listener for relisten evidence.

    return [("greeting", handshake), ("badsig", refused)]


def journey_preauth(s, cred):
    def handshake():
        s.greeting()
        s.send_raw(b'{"id":1,"verb":"proc.list"}')

    def refused():
        obj = s.read_json(timeout=RESP_TIMEOUT)
        if (obj.get("error") or {}).get("code") != "auth_required":
            raise Fail("a pre-auth request was not refused auth_required")
        # See journey_badsig: the harness exit is the close.

    return [("greeting", handshake), ("preauth", refused)]


def journey_mute(s, cred):
    def handshake():
        s.greeting()

    def timeout():
        t0 = time.monotonic()
        obj = s.read_json(timeout=MUTE_TIMEOUT)
        elapsed = time.monotonic() - t0
        if (obj.get("error") or {}).get("code") != "auth_timeout":
            raise Fail("a silent client was not refused auth_timeout")
        if elapsed > MUTE_TIMEOUT:
            raise Fail("auth_timeout arrived late")
        # See journey_badsig: the harness exit is the close.

    return [("greeting", handshake), ("auth-timeout", timeout)]


def journey_noexec(s, cred):
    def handshake():
        verbs = s.connect(cred[0], cred[1])
        if "gosh.run" in verbs:
            raise Fail("gosh.run is advertised without --allow-exec")
        if s.agent != cred[0] or "term" not in s.caps:
            raise Fail("the session did not resolve the agent's caps")

    def disabled():
        expect_refused(lambda: s.call("gosh.run", cmd="echo x"), "verb_disabled")

    def no_seat():
        res = s.call("ui.windows")
        if res.get("seat") != "none" or res.get("windows") != []:
            raise Fail("ui.windows did not report seat none with no windows")

    def no_seat_shot():
        expect_refused(lambda: s.call("ui.screenshot"), "seat_absent")

    return [
        ("handshake", handshake),
        ("verb-disabled", disabled),
        ("no-seat", no_seat),
        ("no-seat-shot", no_seat_shot),
    ]


def journey_input(s, cred):
    """M139b (#2780): ui.input types into the focused GOEDIT pane and a
    following ui.screenshot observes the repaint; then the named
    refusals. The gate execs GOEDIT only after the first ui.windows
    request (go-agentd.spec run 15), exactly like journey_full's Calc.
    """
    edit_index = []
    pixels_a = []

    def handshake():
        verbs = s.connect(cred[0], cred[1])
        for v in ("ui.windows", "ui.screenshot", "ui.input"):
            if v not in verbs:
                raise Fail("missing advertised verb " + v)
        if "input" not in s.caps:
            raise Fail("missing declared cap input")

    def ui_windows():
        deadline = time.monotonic() + UI_WAIT
        last = "empty window list"
        while True:
            try:
                res = s.call("ui.windows")
            except Refused as r:
                res = None
                last = "refused " + r.code
            if res is not None:
                if res.get("seat") != "gotabwm":
                    raise Fail("seat is not gotabwm")
                rows = res.get("windows")
                if isinstance(rows, list):
                    # #2865: the strip may carry SESSION.TABS-restored
                    # Edits ahead of this boot's fresh one — the predicate
                    # is "the focused row is an Edit" (the pane ui.input
                    # types into), never "the first Edit row is focused".
                    focused = [r for r in rows if r.get("focused") is True]
                    if (len(focused) == 1
                            and focused[0].get("title") == "Edit"):
                        edit_index.append(focused[0]["index"])
                        break
                last = "no focused Edit row"
            if time.monotonic() >= deadline:
                raise Fail("ui.windows never showed a focused Edit row: " + last)
            time.sleep(1)

    def screenshot(tag):
        deadline = time.monotonic() + 30
        while True:
            res = s.call("ui.screenshot")
            pix = stream_bytes(res)
            if len(pix) != 160 * 90 * 2:
                raise Fail("screenshot stream reassembled %d bytes" % len(pix))
            if not any(pix):
                if time.monotonic() >= deadline:
                    raise Fail(tag + ": screenshot stayed all-zero")
                time.sleep(1)
                continue
            return pix

    def shot_a():
        pixels_a.append(screenshot("a"))

    def ui_input_type():
        # 'h','i' (HID usages 0x0B/0x0C) plus a click press+release at
        # (300,200) — one bounded batch, one kind-29 frame per event.
        res = s.call("ui.input", win=edit_index[0], events=[
            {"type": "key", "usage": 0x0B},
            {"type": "key", "usage": 0x0C},
            {"type": "ptr", "x": 300, "y": 200, "buttons": 1},
            {"type": "ptr", "x": 300, "y": 200, "buttons": 0},
        ])
        if res.get("sent") != 4:
            raise Fail("ui.input sent %r of 4 events" % res.get("sent"))

    def shot_b():
        # GOEDIT repaints on the first insert (status `*` + glyphs): the
        # next screenshot must differ from shot a. Poll past the seat's
        # paint latency.
        deadline = time.monotonic() + 30
        while True:
            pix = screenshot("b")
            if pix != pixels_a[0]:
                return
            if time.monotonic() >= deadline:
                raise Fail("typed input never repainted the screenshot")
            time.sleep(1)

    def ui_input_reds():
        # The seat's refusal name for a non-focused target, verbatim.
        expect_refused(
            lambda: s.call("ui.input", win=99, events=[
                {"type": "key", "usage": 4}]),
            "agent_input_no_focus")
        expect_refused(
            lambda: s.call("ui.input", win=edit_index[0], events=[
                {"type": "key", "usage": 4}] * 65),
            "too_large")
        for events in (
            [{"type": "key"}],                    # usage missing
            [5],                                  # element not an object
            [{"type": "wheel"}],                  # unknown event class
            [{"type": "ptr", "x": 1}],            # y missing
            [{"type": "key", "usage": 4, "x": 1}],  # key-only extra
        ):
            expect_refused(
                lambda e=events: s.call(
                    "ui.input", win=edit_index[0], events=e),
                "bad_request")
        expect_refused(lambda: s.call("ui.input", events=[]), "bad_request")

    return [
        ("handshake", handshake),
        ("ui.windows", ui_windows),
        ("ui.screenshot-a", shot_a),
        ("ui.input", ui_input_type),
        ("ui.screenshot-b", shot_b),
        ("ui.input-reds", ui_input_reds),
    ]


def journey_capsneg(s, cred):
    """An agent whose row declares only `process` gets cap_required for
    every other verb — the per-verb cap-absent negative."""
    def handshake():
        verbs = s.connect(cred[0], cred[1])
        if sorted(verbs) != ["proc.get", "proc.list"]:
            raise Fail("cap-limited session advertised verbs %r" % verbs)
        if s.caps != ["process"]:
            raise Fail("caps did not resolve to [process]: %r" % s.caps)

    def proc_ok():
        res = s.call("proc.list")
        if not isinstance(res.get("procs"), list):
            raise Fail("proc.list refused under the process cap")

    def refused():
        for verb, args, cap in (
            ("fs.read", {"path": "SEED.TXT"}, "file"),
            ("fs.write", {"path": "X", "data_b64": b64e(b"x")}, "file"),
            ("ui.windows", {}, "window"),
            ("ui.screenshot", {}, "window"),
            ("ui.input", {"win": 0, "events": [{"type": "key", "usage": 4}]},
             "input"),
            ("gosh.run", {"cmd": "echo hi"}, "term"),
        ):
            expect_refused(
                lambda v=verb, a=args: s.call(v, **a), "cap_required"
            )
        # The refusal message names the missing cap.
        try:
            s.call("fs.read", path="SEED.TXT")
            raise Fail("fs.read ran without the file cap")
        except Refused as r:
            if "file" not in r.message:
                raise Fail("cap_required did not name the cap: %s" % r.message)

    return [("handshake", handshake), ("proc-ok", proc_ok), ("cap-negatives", refused)]


def journey_revoked(s, cred):
    """A listed-but-revoked key: the signature is valid, the credential is
    refused by name."""
    def handshake():
        ch = s.greeting()
        sig = ed_sign(s.sign_message(cred[0]), cred[1])
        s.send_raw(
            ('{"agent":"%s","auth":"%s"}' % (cred[0], sig.hex())).encode("ascii")
        )

    def refused():
        obj = s.read_json(timeout=RESP_TIMEOUT)
        if (obj.get("error") or {}).get("code") != "agent_revoked":
            raise Fail("a revoked credential was not refused agent_revoked")
        # See journey_badsig: the harness exit is the close.

    return [("greeting", handshake), ("revoked", refused)]


def journey_unknown(s, cred):
    """A good signature under no listed id: agent_unknown by name."""
    def handshake():
        s.greeting()
        sig = ed_sign(s.sign_message("mallory"), cred[1])
        s.send_raw(b'{"agent":"mallory","auth":"%s"}' % sig.hex().encode("ascii"))

    def refused():
        obj = s.read_json(timeout=RESP_TIMEOUT)
        if (obj.get("error") or {}).get("code") != "agent_unknown":
            raise Fail("an unlisted agent was not refused agent_unknown")

    return [("greeting", handshake), ("unknown", refused)]


JOURNEYS = {
    "full": journey_full,
    "badsig": journey_badsig,
    "preauth": journey_preauth,
    "mute": journey_mute,
    "noexec": journey_noexec,
    "capsneg": journey_capsneg,
    "input": journey_input,
    "revoked": journey_revoked,
    "unknown": journey_unknown,
}

# Journeys that must exit nonzero after PASS. The runner turns a nonzero
# stream-probe exit into RST while the guest still holds the session
# established — a refused client that vanished — which is what releases
# the kernel's socket back to .listen inside the run. A graceful exit
# sends FIN only, whose peer_fin path leaves the socket in fin_sent until
# the ~30 s retransmission abort.
VANISH = {"badsig", "preauth", "revoked", "unknown"}


def note(msg):
    print("AGENTCTL: " + msg, file=sys.stderr, flush=True)


def run_steps(journey, steps):
    for name, fn in steps:
        try:
            fn()
        except Fail as e:
            note("FAIL %s %s" % (name, e))
            return 1
        except (Refused, ProtoError, PeerGone, TimeoutError) as e:
            why = e.code if isinstance(e, Refused) else str(e)
            note("FAIL %s %s" % (name, why))
            return 1
        note("ok " + name)
    note("PASS " + journey)
    return 0


def read_cred(path):
    """The key file is '<agent-id> <64 lowercase hex seed>' — the private
    half stays host-side, never on argv."""
    try:
        with open(path, "rb") as f:
            text = f.read().decode("ascii").strip()
    except OSError:
        raise Fail("keyfile unreadable")
    parts = text.split()
    if len(parts) != 2 or len(parts[1]) != 64:
        raise Fail("keyfile is not '<agent> <64 hex seed>'")
    try:
        seed = bytes.fromhex(parts[1])
    except ValueError:
        raise Fail("keyfile seed is not hex")
    if len(seed) != 32 or not parts[0]:
        raise Fail("keyfile seed is not 32 bytes")
    return parts[0], seed


def harness(args):
    try:
        cred = read_cred(args.key_file)
    except Fail as e:
        note("FAIL %s" % e)
        return 1
    rd = sys.stdin.buffer
    wr = sys.stdout.buffer
    s = Session(rd, wr)
    try:
        steps = JOURNEYS[args.journey](s, cred)
        rc = run_steps(args.journey, steps)
        if rc == 0 and args.journey in VANISH:
            return 1  # refused client vanishes abruptly -> runner RST
        return rc
    except KeyboardInterrupt:
        return 1
    except Exception as e:  # a harness bug is a failure, never a pass
        note("FAIL harness %s" % type(e).__name__)
        return 1


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="agentctl.py",
        description="v2 agent-channel client/harness (ADR 0052)",
    )
    p.add_argument("--selftest", action="store_true",
                   help="check the in-file Ed25519 against RFC 8032 TEST 1 and exit")
    p.add_argument("--pubkey", metavar="KEYFILE",
                   help="print the public key hex for a '<agent> <seed>' key file and exit")
    sub = p.add_subparsers(dest="cmd")
    h = sub.add_parser("harness")
    h.add_argument("--journey", required=True, choices=sorted(JOURNEYS))
    h.add_argument("--key-file", required=True)
    args = p.parse_args(argv)
    if args.selftest:
        ed_selftest()
        note("ed25519 selftest ok")
        return 0
    if args.pubkey:
        try:
            cred = read_cred(args.pubkey)
        except Fail as e:
            note("FAIL %s" % e)
            return 1
        print(ed_public_key(cred[1]).hex())
        return 0
    if args.cmd == "harness":
        return harness(args)
    p.error("a command is required")


if __name__ == "__main__":
    sys.exit(main())
