#!/usr/bin/env python3
"""tools/agentctl/test_agentctl.py -- class-A tests for agentctl.py (ADR 0052
AC3): the pinned Ed25519 vectors, line framing and bounds, and the journeys
run end to end against a wire-level daemon simulation.

Run: python3 -m unittest tools/agentctl/test_agentctl.py
"""

import base64
import json
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agentctl  # noqa: E402

# The fixture identities: the spec stages the same three agents in its
# AGENTS.TXT — devin full caps, viewer process-only, bobby listed-and-
# revoked. The sim holds the seeds (it computes the expected signature
# itself); a real wire holds only the seeds host-side.
DEVIN = ("devin", bytes.fromhex("0a" * 32))
VIEWER = ("viewer", bytes.fromhex("0b" * 32))
BOBBY = ("bobby", bytes.fromhex("0c" * 32))


def valid_path(path):
    """The daemon's D3 path grammar mirrored loosely for the sim."""
    if not path or len(path) > 48:
        return False
    segs = path.split("/")
    if len(segs) > 4:
        return False
    if segs[0].upper() == "AUDIT":
        return False
    for s in segs:
        if not s or len(s) > 31 or s in (".", ".."):
            return False
        if not s[0].isalnum() or ord(s[0]) > 0x7E:
            return False
        if not all(c.isalnum() or c in "._-" for c in s) or any(
                ord(c) > 0x7E for c in s):
            return False
    return True


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


# agent_id -> (seed, caps, revoked). The sim's AGENTS.TXT.
KEYRING = {
    "devin": (DEVIN[1], ["file", "process", "window", "term", "input"],
              False),
    "viewer": (VIEWER[1], ["process"], False),
    "bobby": (BOBBY[1], ["file"], True),
}

VERB_CAP = {
    "proc.list": "process", "proc.get": "process",
    "fs.read": "file", "fs.write": "file",
    "ui.windows": "window", "ui.screenshot": "window",
    "ui.input": "input",
    "gosh.run": "term",
}


class SimDaemon:
    """A minimal agentd for journey tests: v2 greeting, signature check
    against the session keyring row, caps resolved onto the ready line,
    then a D3/D4-faithful dispatch with stream chunks for the two
    bounded-output verbs."""

    def __init__(self, w, allow_exec=True, seat=True, mute=False,
                 challenge=bytes(range(32)), keyring=None):
        self.w = w
        self.allow_exec = allow_exec
        self.seat = seat
        self.challenge = challenge
        self.keyring = KEYRING if keyring is None else keyring
        self.row = None
        self.caps = []
        self.hello_written = False
        self.edited = 0  # events injected: perturbs the screenshot bytes
        self.next_full = 0.0  # the session's scale=1 rate bound (mono)
        w.push({
            "proto": "virelai-agent/2",
            "auth": "ed25519",
            "challenge": challenge.hex(),
        })
        if mute:
            w.push({"id": None, "ok": False,
                    "error": {"code": "auth_timeout", "message": "m"}})
            w.close()
        else:
            w.on_send = self.on_send

    def err(self, rid, code, msg=None):
        self.w.push({"id": rid, "ok": False,
                     "error": {"code": code,
                               "message": msg or (code + " detail")}})

    def ok(self, rid, result):
        self.w.push({"id": rid, "ok": True, "result": result})

    def stream(self, rid, payload):
        for i in range(0, len(payload), 4608):
            self.w.push({"id": rid, "ok": True, "stream": i // 4608,
                         "data_b64": agentctl.b64e(payload[i:i + 4608])})

    def on_send(self, line):
        if len(line) + 1 > agentctl.MAX_LINE:
            self.err(None, "line_too_long")
            self.w.close()
            return
        code, obj = parse_flat(line)
        if code:
            self.err(None, code)
            return
        if self.row is None:
            if "verb" in obj:
                self.err(None, "auth_required")
                self.w.close()
                return
            if set(obj) != {"agent", "auth"} or not all(
                    isinstance(obj[k], str) for k in ("agent", "auth")):
                self.err(None, "auth_failed")
                self.w.close()
                return
            ent = self.keyring.get(obj["agent"])
            if ent is None:
                self.err(None, "agent_unknown")
                self.w.close()
                return
            if ent[2]:
                self.err(None, "agent_revoked")
                self.w.close()
                return
            want = agentctl.ed_sign(
                agentctl.DOMAIN + self.challenge + b"\x00"
                + obj["agent"].encode("utf-8"), ent[0])
            if obj["auth"] != want.hex():
                self.err(None, "auth_failed")
                self.w.close()
                return
            self.row = obj["agent"]
            self.caps = ent[1]
            verbs = [v for v, c in VERB_CAP.items() if c in self.caps]
            if not self.allow_exec and "gosh.run" in verbs:
                verbs.remove("gosh.run")
            self.w.push({"ok": True, "session": "ready",
                         "agent": self.row, "caps": self.caps,
                         "verbs": verbs})
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
        cap = VERB_CAP.get(verb)
        if cap is None:
            self.err(rid, "unknown_verb")
            return
        if cap not in self.caps:
            self.err(rid, "cap_required", "cap missing: " + cap)
            return
        extra = [k for k in obj if k not in ("id", "verb")]
        allowed = {"proc.list": (), "proc.get": ("pid",),
                   "fs.read": ("path",), "fs.write": ("path", "data_b64"),
                   "ui.windows": (), "ui.screenshot": ("scale",),
                   "ui.input": ("win", "events"),
                   "gosh.run": ("cmd", "timeout_ms")}[verb]
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
        if not valid_path(path):
            self.err(rid, "path_rejected")
            return
        if path == "SEED.TXT":
            self.ok(rid, {"path": path, "size": len(agentctl.SEED_BYTES),
                          "data_b64": agentctl.b64e(agentctl.SEED_BYTES)})
        elif path == "SUB/DEEP.TXT":
            self.ok(rid, {"path": path, "size": len(agentctl.DEEP_BYTES),
                          "data_b64": agentctl.b64e(agentctl.DEEP_BYTES)})
        elif path == "HELLO.TXT" and self.hello_written:
            self.ok(rid, {"path": path, "size": len(agentctl.PAYLOAD),
                          "data_b64": agentctl.b64e(agentctl.PAYLOAD)})
        elif path == "SUB/NEW.TXT" and self.new_written:
            self.ok(rid, {"path": path,
                          "size": len(agentctl.NESTED_PAYLOAD),
                          "data_b64": agentctl.b64e(agentctl.NESTED_PAYLOAD)})
        elif path == "BIG.BIN":
            self.err(rid, "too_large")
        else:
            self.err(rid, "not_found")

    def v_fs_write(self, rid, obj):
        path, body = obj.get("path"), obj.get("data_b64")
        if not isinstance(path, str) or not isinstance(body, str):
            self.err(rid, "bad_request")
            return
        if not valid_path(path):
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
        if path == "SUB/NEW.TXT":
            self.new_written = True
        self.ok(rid, {"path": path, "size": len(data)})

    def v_ui_windows(self, rid, obj):
        if not self.seat:
            self.ok(rid, {"seat": "none", "focused": None, "windows": []})
            return
        # The Calc row journey_full waits for, plus a focused Edit row
        # journey_input drives.
        self.ok(rid, {"seat": "gotabwm", "focused": 1, "windows": [
            {"index": 0, "id": 3, "title": "Calc", "focused": False,
             "pinned": False, "frozen": False},
            {"index": 1, "id": 4, "title": "Edit", "focused": True,
             "pinned": False, "frozen": False}]})

    def v_ui_screenshot(self, rid, obj):
        # #2977 mirror: `scale` is 1|8 (default 8); a second scale=1
        # inside 2 s is rate_limited — refused before the seat check.
        scale = obj.get("scale", 8)
        if not isinstance(scale, int) or isinstance(scale, bool) \
                or scale not in (1, 8):
            self.err(rid, "bad_request")
            return
        if scale == 1 and time.monotonic() < self.next_full:
            self.err(rid, "rate_limited")
            return
        if not self.seat:
            self.err(rid, "seat_absent")
            return
        if scale == 1:
            self.next_full = time.monotonic() + 2.0
            self.stream(rid, bytes(((i + self.edited) % 251 + 1)
                                   for i in range(1280 * 720 * 2)))
            self.ok(rid, {"w": 1280, "h": 720, "format": "rgb565le",
                          "bytes": 1280 * 720 * 2})
            return
        self.stream(rid, bytes(((i + self.edited) % 251 + 1)
                               for i in range(160 * 90 * 2)))
        self.ok(rid, {"w": 160, "h": 90, "format": "rgb565le",
                      "bytes": 160 * 90 * 2})

    def v_ui_input(self, rid, obj):
        # D3/D4 mirror of the real verb: flat int win, events a bounded
        # list of typed flat objects; the focused strip index answers win.
        win, events = obj.get("win"), obj.get("events")
        if (not isinstance(win, int) or isinstance(win, bool) or win < 0
                or not isinstance(events, list)):
            self.err(rid, "bad_request")
            return
        if len(events) > 64:
            self.err(rid, "too_large")
            return
        ok = True
        for e in events:
            if not isinstance(e, dict) or len(set(e)) != len(e):
                ok = False
                break
            t = e.get("type")
            fields = {k for k in e if k != "type"}
            if t == "key":
                ok = fields <= {"usage", "mods"} and "usage" in fields
            elif t == "ptr":
                ok = fields <= {"x", "y", "buttons"} and \
                    {"x", "y"} <= fields
            else:
                ok = False
            if not ok:
                break
            for k, v in e.items():
                if k == "type":
                    continue
                hi = 0xFFFF if k in ("x", "y") else 0xFF
                if (not isinstance(v, int) or isinstance(v, bool)
                        or v < 0 or v > hi):
                    ok = False
                    break
            if not ok:
                break
        if not ok:
            self.err(rid, "bad_request")
            return
        if win != 1:  # the focused row's index (v_ui_windows above)
            self.err(rid, "agent_input_no_focus")
            return
        self.edited += len(events)
        self.ok(rid, {"sent": len(events)})

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
        out, status, truncated = b"", 0, False
        path = "/host/AGENT/WIDE.TXT"
        if cmd == "echo hello":
            out = b"hello\n"
        elif cmd == "echo " + agentctl.STDOUT_SENTINEL.decode():
            out = agentctl.STDOUT_SENTINEL + b"\n"
        elif cmd == "cat %s %s %s" % (path, path, path):
            out = agentctl.wide_bytes() * 3
        elif cmd == "cat %s %s %s %s %s" % ((path,) * 5):
            out = agentctl.wide_bytes() * 4  # capture stops at the bound
            truncated = True
        elif cmd in ("cat NOPE.TXT", "cat /host/SECRETS.TXT"):
            status = 1
        self.stream(rid, out)
        self.ok(rid, {"exit_status": status,
                      "stdout_bytes": len(out), "truncated": truncated})


def parse_flat(line):
    """The daemon's flat-grammar read: (code, fields)."""
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
        if isinstance(val, tuple) or val is None:
            return "bad_request", None
        if isinstance(val, list):
            # ui.input's events[]: elements decode as ("__obj__", pairs)
            # tuples — normalize to plain dicts for the verb mirror.
            val = [dict(e[1]) if (isinstance(e, tuple)
                                 and e[0] == "__obj__") else e
                   for e in val]
        if isinstance(val, float):
            return "bad_request", None
        if isinstance(val, int) and not isinstance(val, bool) and (
                val < 0 or val > 2147483647):
            return "bad_request", None
        fields[k] = val
    return "", fields


def connect_sim(allow_exec=True, seat=True, mute=False):
    w = FakeWire()
    SimDaemon(w, allow_exec, seat, mute)
    return agentctl.Session(w, w), w


class TestPinnedVectors(unittest.TestCase):
    def test_ed25519_rfc(self):
        agentctl.ed_selftest()

    def test_sign_message_shape(self):
        w = FakeWire()
        s = agentctl.Session(w, w)
        s.challenge = bytes(range(32))
        msg = s.sign_message("devin")
        want = agentctl.DOMAIN + bytes(range(32)) + b"\x00" + b"devin"
        self.assertEqual(msg, want)


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
        w.inq += b"x" * (agentctl.MAX_LINE + 1)
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
        verbs = s.connect(*DEVIN)
        self.assertIn("gosh.run", verbs)
        res = s.call("proc.list")
        self.assertEqual(res["procs"][0]["name"], "AGENTD.ELF")
        self.assertEqual(w.lines[-1], b'{"id":1,"verb":"proc.list"}')

    def test_wrong_key_is_auth_failed(self):
        s, w = connect_sim()
        s.greeting()
        with self.assertRaises(agentctl.Refused) as cm:
            s.auth("devin", b"\x00" * 32)
        self.assertEqual(cm.exception.code, "auth_failed")

    def test_revoked_and_unknown(self):
        s, w = connect_sim()
        s.greeting()
        with self.assertRaises(agentctl.Refused) as cm:
            s.auth(*BOBBY)
        self.assertEqual(cm.exception.code, "agent_revoked")
        s, w = connect_sim()
        s.greeting()
        with self.assertRaises(agentctl.Refused) as cm:
            s.auth("mallory", DEVIN[1])
        self.assertEqual(cm.exception.code, "agent_unknown")

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
        s.connect(*DEVIN)
        w.on_send = lambda line: w.push(
            {"id": 999, "ok": True, "result": {}})
        with self.assertRaises(agentctl.ProtoError):
            s.call("proc.list")


class TestJourneys(unittest.TestCase):
    def run_journey(self, name, cred=DEVIN, **simkw):
        s, w = connect_sim(**simkw)
        if name == "shot":
            steps = agentctl.JOURNEYS[name](
                s, cred, tempfile.mkdtemp())
        else:
            steps = agentctl.JOURNEYS[name](s, cred)
        fails = []
        for step_name, fn in steps:
            try:
                fn()
            except Exception as e:
                fails.append("%s: %r" % (step_name, e))
        return fails

    def test_journey_names(self):
        self.assertEqual(sorted(agentctl.JOURNEYS),
                         ["badsig", "capsneg", "full", "input", "mute",
                          "noexec", "preauth", "revoked", "shot",
                          "unknown"])
        self.assertTrue(agentctl.VANISH.issubset(agentctl.JOURNEYS))
        for name in agentctl.JOURNEYS:
            s, _ = connect_sim()
            steps = agentctl.JOURNEYS[name](s, DEVIN)
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

    def test_capsneg(self):
        fails = self.run_journey("capsneg", cred=VIEWER)
        self.assertEqual(fails, [])

    def test_badsig(self):
        fails = self.run_journey("badsig")
        self.assertEqual(fails, [])

    def test_revoked(self):
        fails = self.run_journey("revoked", cred=BOBBY)
        self.assertEqual(fails, [])

    def test_unknown(self):
        fails = self.run_journey("unknown")
        self.assertEqual(fails, [])

    def test_preauth(self):
        fails = self.run_journey("preauth")
        self.assertEqual(fails, [])

    def test_mute(self):
        fails = self.run_journey("mute", mute=True)
        self.assertEqual(fails, [])

    def test_input(self):
        fails = self.run_journey("input")
        self.assertEqual(fails, [])

    def test_shot(self):
        # scale=1 streams the full frame, the scale/refusal matrix holds,
        # the 2 s bound bites and lapses, and both evidence files land.
        with tempfile.TemporaryDirectory() as d:
            s, w = connect_sim()
            fails = []
            for step_name, fn in agentctl.journey_shot(s, DEVIN, d):
                try:
                    fn()
                except Exception as e:
                    fails.append("%s: %r" % (step_name, e))
            self.assertEqual(fails, [])
            with open(os.path.join(d, "shot-full.rgb565"), "rb") as f:
                full = f.read()
            with open(os.path.join(d, "shot-thumb.rgb565"), "rb") as f:
                thumb = f.read()
            self.assertEqual(len(full), 1280 * 720 * 2)
            self.assertEqual(len(thumb), 160 * 90 * 2)

    def test_full_fails_when_calc_missing(self):
        s, w = connect_sim()
        sim_verbs = s.connect(*DEVIN)
        self.assertIn("gosh.run", sim_verbs)
        steps = dict(agentctl.JOURNEYS["full"](s, DEVIN))
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
        try:
            agentctl.main(["harness", "--journey", "bogus", "--key-file", "k"])
            self.fail("bad journey accepted")
        except SystemExit as e:
            self.assertEqual(e.code, 2)

    def test_keyfile_required(self):
        import io
        import contextlib
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                agentctl.main(["harness", "--journey", "full"])
        except SystemExit as e:
            self.assertEqual(e.code, 2)
        self.assertIn("--key-file", err.getvalue())

    def test_read_cred(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write("devin " + "0a" * 32 + "\n")
            path = f.name
        try:
            agent, seed = agentctl.read_cred(path)
            self.assertEqual(agent, "devin")
            self.assertEqual(seed, DEVIN[1])
        finally:
            os.unlink(path)

    def test_selftest_flag(self):
        self.assertEqual(agentctl.main(["--selftest"]), 0)


if __name__ == "__main__":
    unittest.main()
