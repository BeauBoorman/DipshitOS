#!/usr/bin/env python3
"""tools/agentctl/agentctl.py -- M98 agent control channel client (ADR 0044).

Two uses of one stdlib-only file:

  * Library: ``Session`` speaks the v1 JSON-Lines protocol over any pair of
    binary file-like objects (one read side, one write side).
  * Harness: ``agentctl.py harness --journey=<J> --key-file=<K>`` is the
    runner's ``--net-tcp-connect-stream`` child. Stdin carries guest->host
    bytes, stdout carries host->guest bytes, and stderr carries the
    ``AGENTCTL: ok|FAIL|PASS`` evidence lines the gate asserts on.

Nothing sensitive is ever printed (ADR 0044 D6): the key, challenge, MAC,
request paths, file bytes, ``cmd`` text and command output never reach
stderr.
"""

import argparse
import base64
import hashlib
import hmac
import json
import select
import sys
import time

DOMAIN = b"VIRELAI-AGENT/1 hmac-sha256\x00"

# Fixed fixtures. tools/gate/specs/go-agentd.spec stages AGENT/SEED.TXT with
# SEED_BYTES exactly (it imports this file) and compares AGENT/HELLO.TXT
# against PAYLOAD. STDOUT_SENTINEL is produced by one gosh.run step so the
# gate can prove command output never reaches serial.
SEED_BYTES = b"virelai-agent-seed:the quick brown fox 0044\n"
PAYLOAD = b"agentctl-payload-sentinel-44\n"
STDOUT_SENTINEL = b"agentctl-stdout-sentinel-44"

MAX_LINE = 8192          # session line bound, LF included (D1)
GREET_TIMEOUT = 20.0     # the greeting is immediate; a wait is a hang
RESP_TIMEOUT = 20.0      # any single request's answer
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
    """The v1 protocol over a binary (rd, wr) pair."""

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
        if obj.get("proto") != "virelai-agent/1" or obj.get("auth") != "hmac-sha256":
            raise ProtoError("greeting is not the v1 shape")
        ch = obj.get("challenge")
        if (
            not isinstance(ch, str)
            or len(ch) != 64
            or any(c not in "0123456789abcdef" for c in ch)
        ):
            raise ProtoError("greeting challenge is not 64 lowercase hex")
        self.challenge = bytes.fromhex(ch)
        return self.challenge

    def auth(self, key):
        if self.challenge is None:
            self.greeting()
        mac = hmac.new(key, DOMAIN + self.challenge, hashlib.sha256).hexdigest()
        self.send_raw(('{"auth":"%s"}' % mac).encode("ascii"))
        obj = self.read_json(timeout=RESP_TIMEOUT)
        if obj.get("ok") is False:
            err = obj.get("error") or {}
            raise Refused(err.get("code", "?"), err.get("message", ""))
        if obj.get("ok") is not True or obj.get("session") != "ready":
            raise ProtoError("the ready line is not the v1 shape")
        verbs = obj.get("verbs")
        if not isinstance(verbs, list) or not all(isinstance(v, str) for v in verbs):
            raise ProtoError("the ready line's verbs is not a string list")
        self.verbs = verbs
        return verbs

    def connect(self, key):
        """greeting + auth; returns the advertised verb list."""
        self.greeting()
        return self.auth(key)

    # ---- requests -------------------------------------------------------------

    def call(self, verb, **args):
        self._next += 1
        rid = self._next
        req = {"id": rid, "verb": verb}
        req.update(args)
        self.send_raw(json.dumps(req, separators=(",", ":")).encode("utf-8"))
        obj = self.read_json(timeout=RESP_TIMEOUT)
        if obj.get("id") != rid:
            raise ProtoError("response id did not echo the request")
        if obj.get("ok") is True:
            res = obj.get("result")
            if not isinstance(res, dict):
                raise ProtoError("ok result is not an object")
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


# ---- the journeys ------------------------------------------------------------


def journey_full(s, key):
    agent_pid = []

    def handshake():
        verbs = s.connect(key)
        if "gosh.run" not in verbs:
            raise Fail("gosh.run is not advertised with --allow-exec")
        for v in ("proc.list", "proc.get", "fs.read", "fs.write", "ui.windows"):
            if v not in verbs:
                raise Fail("missing advertised verb " + v)

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
            ("SUB/X", "path_rejected"),
            (".", "path_rejected"),
            ("..", "path_rejected"),
            ("", "path_rejected"),
            ("A" * 32, "path_rejected"),
            ("X~", "path_rejected"),
            ("A\x00B", "path_rejected"),
            ("NOPE.TXT", "not_found"),
            ("BIG.BIN", "too_large"),
        ):
            expect_refused(lambda p=path: s.call("fs.read", path=p), code)

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

    def gosh_green():
        res = s.call("gosh.run", cmd="echo hello")
        if res.get("exit_status") != 0 or b64d(res.get("stdout_b64", "")) != b"hello\n":
            raise Fail("echo hello did not return hello\\n status 0")
        res = s.call("gosh.run", cmd="cat NOPE.TXT")
        if res.get("exit_status") == 0:
            raise Fail("cat NOPE.TXT unexpectedly exited 0")
        res = s.call("gosh.run", cmd="cat /host/SECRETS.TXT")
        if res.get("exit_status") == 0:
            raise Fail("cat SECRETS.TXT unexpectedly exited 0")
        if key in b64d(res.get("stdout_b64", "")):
            raise Fail("the secret value appeared in command stdout")
        res = s.call("gosh.run", cmd="echo " + STDOUT_SENTINEL.decode("ascii"))
        if STDOUT_SENTINEL not in b64d(res.get("stdout_b64", "")):
            raise Fail("the stdout sentinel was not captured")

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
        # The daemon waits for the peer before closing (see journey_badmac);
        # the harness exit closes this session from the client side.

    return [
        ("handshake", handshake),
        ("proc.list", proc_list),
        ("proc.get", proc_get),
        ("proc-reds", proc_reds),
        ("fs.read-seed", fs_read_seed),
        ("fs.read-reds", fs_read_reds),
        ("fs.write", fs_write),
        ("fs.read-hello", fs_read_hello),
        ("fs.write-reds", fs_write_reds),
        ("gosh-green", gosh_green),
        ("gosh-reds", gosh_reds),
        ("gosh-timeout", gosh_timeout),
        ("ui.windows", ui_windows),
        ("framing-reds", framing_reds),
        ("line-too-long", too_long),
    ]


def journey_badmac(s, key):
    def handshake():
        ch = s.greeting()
        good = hmac.new(key, DOMAIN + ch, hashlib.sha256).hexdigest()
        bad = ("0" if good[0] != "0" else "1") + good[1:]
        s.send_raw(('{"auth":"%s"}' % bad).encode("ascii"))

    def refused():
        obj = s.read_json(timeout=RESP_TIMEOUT)
        if (obj.get("error") or {}).get("code") != "auth_failed":
            raise Fail("a wrong MAC was not refused auth_failed")
        if "ok" in obj and obj.get("ok") is True:
            raise Fail("a wrong MAC was answered ready")
        # No expect_close: the daemon waits for the peer before it closes
        # (a guest-first FIN strands the kernel waiting on a FIN+ACK this
        # transport never sends). The harness's own exit IS the close —
        # the VANISH set makes it an abrupt one, which the runner turns
        # into the RST that releases the listener for relisten evidence.

    return [("greeting", handshake), ("badmac", refused)]


def journey_preauth(s, key):
    def handshake():
        s.greeting()
        s.send_raw(b'{"id":1,"verb":"proc.list"}')

    def refused():
        obj = s.read_json(timeout=RESP_TIMEOUT)
        if (obj.get("error") or {}).get("code") != "auth_required":
            raise Fail("a pre-auth request was not refused auth_required")
        # See journey_badmac: the harness exit is the close.

    return [("greeting", handshake), ("preauth", refused)]


def journey_mute(s, key):
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
        # See journey_badmac: the harness exit is the close.

    return [("greeting", handshake), ("auth-timeout", timeout)]


def journey_noexec(s, key):
    def handshake():
        verbs = s.connect(key)
        if "gosh.run" in verbs:
            raise Fail("gosh.run is advertised without --allow-exec")

    def disabled():
        expect_refused(lambda: s.call("gosh.run", cmd="echo x"), "verb_disabled")

    def no_seat():
        res = s.call("ui.windows")
        if res.get("seat") != "none" or res.get("windows") != []:
            raise Fail("ui.windows did not report seat none with no windows")

    return [("handshake", handshake), ("verb-disabled", disabled), ("no-seat", no_seat)]


JOURNEYS = {
    "full": journey_full,
    "badmac": journey_badmac,
    "preauth": journey_preauth,
    "mute": journey_mute,
    "noexec": journey_noexec,
}

# Journeys that must exit nonzero after PASS. The runner turns a nonzero
# stream-probe exit into RST while the guest still holds the session
# established — a refused client that vanished — which is what releases
# the kernel's one-socket machine back to .listen inside the run. A
# graceful exit sends FIN only, whose peer_fin path leaves the socket in
# fin_sent until the ~30 s retransmission abort.
VANISH = {"badmac", "preauth"}


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


def harness(args):
    try:
        with open(args.key_file, "rb") as f:
            key = f.read().strip()
    except OSError:
        note("FAIL keyfile unreadable")
        return 1
    if not key:
        note("FAIL keyfile empty")
        return 1
    rd = sys.stdin.buffer
    wr = sys.stdout.buffer
    s = Session(rd, wr)
    try:
        steps = JOURNEYS[args.journey](s, key)
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
        description="M98 agent control channel client and go-agentd harness (ADR 0044)",
    )
    sub = p.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("harness", help="run one class-B journey over stdin/stdout")
    h.add_argument("--journey", required=True, choices=sorted(JOURNEYS))
    h.add_argument("--key-file", required=True,
                   help="file holding the agent-hmac secret text (never argv)")
    args = p.parse_args(argv)
    if args.cmd == "harness":
        return harness(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
