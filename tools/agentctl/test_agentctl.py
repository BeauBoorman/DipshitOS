#!/usr/bin/env python3
"""tools/agentctl/test_agentctl.py -- class-A tests for agentctl.py (ADR 0044
AC3): the pinned HMAC vector, line framing and bounds, and the journeys run
end to end against a wire-level daemon simulation.

Run: python3 -m unittest tools/agentctl/test_agentctl.py
"""

import base64
import hashlib
import hmac
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agentctl  # noqa: E402

KEY = b"a5" * 32  # the pinned-vector key (ASCII a5 x 32 = 64 bytes)


def pinned_mac(challenge):
    return hmac.new(
        KEY, agentctl.DOMAIN + challenge, hashlib.sha256
    ).hexdigest()


def valid_name(path):
    if not path or len(path) > 31 or path in (".", ".."):
        return False
    if not path[0].isalnum() or ord(path[0]) > 0x7E:
        return False
    return all(c.isalnum() or c in "._-" for c in path) and all(
        ord(c) < 0x80 for c in path
    )


class FakeWire:
    """A scripted (rd, wr) pair. ``push`` queues daemon->client bytes; a
    client line triggers on_send, which may push replies or close."""

    def __init__(self):
        self.inq = bytearray()
        self.lines = []
        self.closed = False
        self.on_send = lambda line: None
        self._pend = bytearray()

    def push(self, obj_or_bytes):
        if isinstance(obj_or_bytes, (dict, list)):
            data = json.dumps(obj_or_bytes, separators=(",", ":")).encode()
        else:
            data = obj_or_bytes
        self.inq += data + b"\n"

    def read(self, n):
        if not self.inq:
            return b""
        # Bytes already queued still drain after close; EOF follows them.
        out = bytes(self.inq[:n])
        del self.inq[:n]
        return out

    def write(self, b):
        self._pend += b
        while True:
            i = self._pend.find(b"\n")
            if i < 0:
                break
            line = bytes(self._pend[:i])
            del self._pend[: i + 1]
            self.lines.append(line)
            self.on_send(line)
        return len(b)

    def flush(self):
        pass

    def close(self):
        self.closed = True


class SimDaemon:
    """A minimal agentd for journey tests: greeting, MAC check, ready,
    then a D3/D4-faithful dispatch over the canned fixture set."""

    def __init__(self, w, key=KEY, allow_exec=True, seat=True,
                 mute=False, challenge=bytes(range(32))):
        self.w = w
        self.key = key
        self.allow_exec = allow_exec
        self.seat = seat
        self.challenge = challenge
        self.authed = False
        self.hello_written = False
        w.push({
            "proto": "virelai-agent/1",
            "auth": "hmac-sha256",
            "challenge": challenge.hex(),
        })
        if mute:
            # The real daemon waits 10 s; the sim answers at once and the
            # journey still reads exactly the line the gate expects.
            w.push({"id": None, "ok": False,
                    "error": {"code": "auth_timeout", "message": "m"}})
            w.close()
        else:
            w.on_send = self.on_send

    def err(self, rid, code):
        self.w.push({"id": rid, "ok": False,
                     "error": {"code": code, "message": "m"}})

    def ok(self, rid, result):
        self.w.push({"id": rid, "ok": True, "result": result})

    def on_send(self, line):
        if len(line) + 1 > agentctl.MAX_LINE:
            self.err(None, "line_too_long")
            self.w.close()
            return
        code, obj = parse_flat(line)
        if code:
            self.err(None, code)
            return
        if not self.authed:
            if "verb" in obj:
                self.err(None, "auth_required")
                self.w.close()
                return
            if set(obj) != {"auth"} or not isinstance(obj["auth"], str):
                self.err(None, "auth_failed")
                self.w.close()
                return
            if obj["auth"] != pinned_mac(self.challenge):
                self.err(None, "auth_failed")
                self.w.close()
                return
            self.authed = True
            verbs = ["proc.list", "proc.get", "fs.read", "fs.write",
                     "ui.windows"]
            if self.allow_exec:
                verbs.append("gosh.run")
            self.w.push({"ok": True, "session": "ready", "verbs": verbs})
            return
        self.dispatch(obj)

    PROC_ROW = {"pid": 7, "name": "AGENTD.ELF", "state": "running",
                "exit_status": None}

    def dispatch(self, obj):
        rid = obj.get("id")
        verb = obj.get("verb")
        if (not isinstance(rid, int) or isinstance(rid, bool) or rid < 1
                or not isinstance(verb, str)):
            self.err(rid if isinstance(rid, int) else None, "bad_request")
            return
        if verb not in ("proc.list", "proc.get", "fs.read", "fs.write",
                        "ui.windows", "gosh.run"):
            self.err(rid, "unknown_verb")
            return
        extra = [k for k in obj if k not in ("id", "verb")]
        allowed = {"proc.list": (), "proc.get": ("pid",),
                   "fs.read": ("path",), "fs.write": ("path", "data_b64"),
                   "ui.windows": (), "gosh.run": ("cmd", "timeout_ms")}[verb]
        if any(k not in allowed for k in extra):
            self.err(rid, "bad_request")
            return
        getattr(self, "v_" + verb.replace(".", "_"))(rid, obj)

    def v_proc_list(self, rid, obj):
        self.ok(rid, {"procs": [dict(self.PROC_ROW)]})

    def v_proc_get(self, rid, obj):
        pid = obj.get("pid")
        if not isinstance(pid, int) or pid < 1:
            self.err(rid, "bad_request")
        elif pid == 7:
            self.ok(rid, dict(self.PROC_ROW))
        else:
            self.err(rid, "not_found")

    def v_fs_read(self, rid, obj):
        path = obj.get("path")
        if not isinstance(path, str):
            self.err(rid, "bad_request")
            return
        if not valid_name(path):
            self.err(rid, "path_rejected")
            return
        if path == "SEED.TXT":
            self.ok(rid, {"path": path, "size": len(agentctl.SEED_BYTES),
                          "data_b64": agentctl.b64e(agentctl.SEED_BYTES)})
        elif path == "HELLO.TXT" and self.hello_written:
            self.ok(rid, {"path": path, "size": len(agentctl.PAYLOAD),
                          "data_b64": agentctl.b64e(agentctl.PAYLOAD)})
        elif path == "BIG.BIN":
            self.err(rid, "too_large")
        else:
            self.err(rid, "not_found")

    def v_fs_write(self, rid, obj):
        path, body = obj.get("path"), obj.get("data_b64")
        if not isinstance(path, str) or not isinstance(body, str):
            self.err(rid, "bad_request")
            return
        if not valid_name(path):
            self.err(rid, "path_rejected")
            return
        try:
            data = base64.b64decode(body, validate=True)
        except Exception:
            self.err(rid, "bad_request")
            return
        if len(data) > 4096:
            self.err(rid, "too_large")
            return
        if path == "HELLO.TXT":
            self.hello_written = True
        self.ok(rid, {"path": path, "size": len(data)})

    def v_ui_windows(self, rid, obj):
        if not self.seat:
            self.ok(rid, {"seat": "none", "focused": None, "windows": []})
            return
        self.ok(rid, {"seat": "gotabwm", "focused": 0, "windows": [
            {"index": 0, "id": 3, "title": "Calc", "focused": True,
             "pinned": False, "frozen": False}]})

    def v_gosh_run(self, rid, obj):
        if not self.allow_exec:
            self.err(rid, "verb_disabled")
            return
        cmd = obj.get("cmd")
        ms = obj.get("timeout_ms", 10000)
        if not isinstance(cmd, str):
            self.err(rid, "bad_request")
            return
        if len(cmd) == 0 or len(cmd) > 192:
            self.err(rid, "too_large")
            return
        if any(ord(c) < 0x20 or ord(c) > 0x7E for c in cmd):
            self.err(rid, "cmd_rejected")
            return
        if any(t in cmd for t in (">", "&", "#")) or cmd.count("'") % 2:
            self.err(rid, "cmd_rejected")
            return
        if not isinstance(ms, int) or ms < 1 or ms > 30000:
            self.err(rid, "bad_request")
            return
        if cmd == "sleep 5":
            self.err(rid, "timed_out")
            return
        out, status = b"", 0
        if cmd == "echo hello":
            out = b"hello\n"
        elif cmd == "echo " + agentctl.STDOUT_SENTINEL.decode():
            out = agentctl.STDOUT_SENTINEL + b"\n"
        elif cmd in ("cat NOPE.TXT", "cat /host/SECRETS.TXT"):
            status = 1
        self.ok(rid, {"exit_status": status,
                      "stdout_b64": agentctl.b64e(out), "truncated": False})


def parse_flat(line):
    """The daemon's flat-grammar read: (code, fields). Duplicate keys and
    nested/array/null values are preserved here that json.loads alone would
    lose, so the sim refuses the same lines the daemon does."""
    try:
        v = json.loads(line, object_pairs_hook=lambda p: ("__obj__", p))
    except ValueError:
        return "bad_json", None
    if v is None:
        return "bad_request", None
    if not (isinstance(v, tuple) and v[0] == "__obj__"):
        return "bad_json", None
    pairs = v[1]
    keys = [k for k, _ in pairs]
    if len(set(keys)) != len(keys):
        return "bad_request", None
    fields = {}
    for k, val in pairs:
        if isinstance(val, tuple) or isinstance(val, list) or val is None:
            return "bad_request", None  # nested object, array or null
        if isinstance(val, float):
            return "bad_request", None
        if isinstance(val, int) and not isinstance(val, bool) and (
                val < 0 or val > 2147483647):
            return "bad_request", None
        fields[k] = val
    return "", fields


def connect_sim(key=KEY, allow_exec=True, seat=True, mute=False):
    w = FakeWire()
    SimDaemon(w, key, allow_exec, seat, mute)
    return agentctl.Session(w, w), w


class TestPinnedVector(unittest.TestCase):
    def test_pinned(self):
        self.assertEqual(
            pinned_mac(bytes(range(32))),
            "e907b2015a16de6504cc2bc61da0d60156c3abe2b035601372840acb58feff04",
        )
        # The daemon's wire view: the same digest as one 64-hex member.
        ch = bytes(range(32))
        line = ('{"auth":"%s"}' % pinned_mac(ch)).encode()
        self.assertEqual(len(json.loads(line)["auth"]), 64)


class TestFraming(unittest.TestCase):
    def test_readline_splits_and_strips(self):
        w = FakeWire()
        w.push(b'{"a":1}\r')
        w.push(b'{"b":2}')
        s = agentctl.Session(w, w)
        self.assertEqual(s.readline(), b'{"a":1}\r'.rstrip(b"\r"))
        self.assertEqual(s.readline(), b'{"b":2}')

    def test_readline_pipelined(self):
        w = FakeWire()
        w.push(b'{"x":1}')
        w.push(b'{"y":2}')
        s = agentctl.Session(w, w)
        self.assertEqual(s.readline(), b'{"x":1}')
        self.assertEqual(s.readline(), b'{"y":2}')

    def test_eof_is_peer_gone(self):
        w = FakeWire()
        s = agentctl.Session(w, w)
        with self.assertRaises(agentctl.PeerGone):
            s.readline(timeout=0.01)

    def test_line_bound(self):
        w = FakeWire()
        w.inq += b"x" * (agentctl.MAX_LINE + 1)  # no LF ever arrives
        s = agentctl.Session(w, w)
        with self.assertRaises(agentctl.ProtoError):
            s.readline()

    def test_send_raw_appends_lf_once(self):
        w = FakeWire()
        s = agentctl.Session(w, w)
        s.send_raw(b'{"id":1}')
        self.assertEqual(w.lines, [b'{"id":1}'])

    def test_bad_response_shapes(self):
        w = FakeWire()
        s = agentctl.Session(w, w)
        w.push(b"[1,2,3]")
        with self.assertRaises(agentctl.ProtoError):
            s.read_json()
        w.push(b"not json")
        with self.assertRaises(agentctl.ProtoError):
            s.read_json()

    def test_buffered_pipe_reads_without_eof(self):
        # A BufferedReader's read(n) would hold session bytes until the
        # writer closed the pipe (observed class-B: the greeting only
        # reached the client at teardown). read1 must return partial
        # lines while the writer stays open.
        rfd, wfd = os.pipe()
        try:
            rd = os.fdopen(rfd, "rb")
            wr = os.fdopen(wfd, "wb", buffering=0)
            s = agentctl.Session(rd, wr)
            wr.write(b'{"proto":"x"}\n')
            self.assertEqual(s.readline(timeout=5), b'{"proto":"x"}')
            wr.write(b"partial")
            wr.write(b"-line\n")
            self.assertEqual(s.readline(timeout=5), b"partial-line")
            rd.close()
            wr.close()
        finally:
            for fd in (rfd, wfd):
                try:
                    os.close(fd)
                except OSError:
                    pass


class TestHandshake(unittest.TestCase):
    def test_connect_and_call(self):
        s, w = connect_sim()
        verbs = s.connect(KEY)
        self.assertIn("gosh.run", verbs)
        res = s.call("proc.list")
        self.assertEqual(res["procs"][0]["name"], "AGENTD.ELF")
        self.assertEqual(w.lines[-1],
                         b'{"id":1,"verb":"proc.list"}')

    def test_wrong_key_is_auth_failed(self):
        s, w = connect_sim()
        s.greeting()
        with self.assertRaises(agentctl.Refused) as cm:
            s.auth(b"wrong")
        self.assertEqual(cm.exception.code, "auth_failed")

    def test_bad_greeting_shape(self):
        w = FakeWire()
        w.push({"proto": "other"})
        s = agentctl.Session(w, w)
        with self.assertRaises(agentctl.ProtoError):
            s.greeting()

    def test_id_mismatch(self):
        w = FakeWire()
        SimDaemon(w)
        s = agentctl.Session(w, w)
        s.connect(KEY)
        w.on_send = lambda line: w.push(
            {"id": 999, "ok": True, "result": {}})
        with self.assertRaises(agentctl.ProtoError):
            s.call("proc.list")


class TestJourneys(unittest.TestCase):
    def run_journey(self, name, key=KEY, **simkw):
        s, w = connect_sim(**simkw)
        steps = agentctl.JOURNEYS[name](s, key)
        fails = []
        for step_name, fn in steps:
            try:
                fn()
            except Exception as e:
                fails.append("%s: %r" % (step_name, e))
        return fails

    def test_journey_names(self):
        self.assertEqual(sorted(agentctl.JOURNEYS),
                         ["badmac", "full", "mute", "noexec", "preauth"])
        self.assertTrue(agentctl.VANISH.issubset(agentctl.JOURNEYS))
        for name in agentctl.JOURNEYS:
            s, _ = connect_sim()
            steps = agentctl.JOURNEYS[name](s, KEY)
            self.assertTrue(steps, name)
            for step_name, fn in steps:
                self.assertTrue(step_name)
                self.assertTrue(callable(fn))

    def test_full(self):
        fails = self.run_journey("full")
        self.assertEqual(fails, [])

    def test_noexec(self):
        fails = self.run_journey("noexec", allow_exec=False, seat=False)
        self.assertEqual(fails, [])

    def test_badmac(self):
        fails = self.run_journey("badmac")
        self.assertEqual(fails, [])

    def test_preauth(self):
        fails = self.run_journey("preauth")
        self.assertEqual(fails, [])

    def test_mute(self):
        fails = self.run_journey("mute", mute=True)
        self.assertEqual(fails, [])

    def test_full_fails_when_calc_missing(self):
        s, w = connect_sim()
        sim_verbs = s.connect(KEY)
        self.assertIn("gosh.run", sim_verbs)
        # A seat that reports no Calc row must fail the ui.windows step —
        # after the retry window (patched small) the staged GOCALC never
        # shows up.
        steps = dict(agentctl.JOURNEYS["full"](s, KEY))
        w.on_send = lambda line: w.push(
            {"id": json.loads(line)["id"], "ok": True,
             "result": {"seat": "gotabwm", "focused": None, "windows": []}})
        save = agentctl.UI_WAIT
        agentctl.UI_WAIT = 0.05
        try:
            with self.assertRaises(agentctl.Fail):
                steps["ui.windows"]()
        finally:
            agentctl.UI_WAIT = save


class TestHarnessCLI(unittest.TestCase):
    def test_journey_choices(self):
        for name in agentctl.JOURNEYS:
            args = agentctl.main.__wrapped__ if False else None  # parse only
        p = []
        # argparse exits 2 on a bad choice.
        import argparse as ap
        try:
            agentctl.main(["harness", "--journey", "bogus", "--key-file", "k"])
        except SystemExit as e:
            p.append(e.code)
        self.assertEqual(p, [2])

    def test_keyfile_required(self):
        import io, contextlib
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                agentctl.main(["harness", "--journey", "full"])
        except SystemExit as e:
            self.assertEqual(e.code, 2)


if __name__ == "__main__":
    unittest.main()
