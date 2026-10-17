#!/usr/bin/env python3
"""agentloop.py -- the M109d (card #2400) host-side agent for the
live-agent-loop gate: the ONLY in-guest actor is this driver, and it
acts exclusively through AGENTD v2 verbs.

It is the runner's ``--net-tcp-connect-stream`` child, shaped exactly
like tools/agentctl/agentctl.py's harness: stdin carries guest->host
bytes, stdout carries host->guest bytes, and stderr carries the
``ALOOP: ok|FAIL|PASS`` evidence lines the spec asserts on. The wire
protocol (Session, Ed25519 auth, stream reassembly) is imported from
tools/agentctl/agentctl.py — no second implementation of the channel.

The journey (each hop is one verb, one serial marker, one MAC'd
AGENT/AUDIT receipt):

    fs.write APP/main.go          the agent authors the app source
    gosh.run FLINT.ELF init/add/commit   the workspace + source commit
    'flint: commit ok id='        the source commit's serial marker IS
                                  the build dispatch — the monitor
                                  execs GOBUILD on it at the proven
                                  shallow depth (a literal gosh.run
                                  GOBUILD would seat FOUR Go runtimes:
                                  agentd+gosh+gobuild+compile = 16
                                  tasks vs the 13-slot user pool — the
                                  wall live-dev-loop's header pins; and
                                  a builtin echo never reaches serial
                                  anyway — the daemon's own redirect
                                  captures it)
    fs.read APP.ELF -> too_large  the done probe (fs verbs spawn no
                                  tasks, so polling the product cannot
                                  starve the build's task slots)
    fs.write APP/release.go x2    the release manifest, authored in two
                                  halves so every pushed Change stays
                                  well under the relay's ~1460 B bound
    gosh.run FLINT.ELF add/commit the two release commits

Phase publish (third session, the push boot):

    wc -l the stream (precondition: all 3 commits landed)
    gosh.run FLINT.ELF push       the stream goes to the hermetic flintd
    fs.read release.go            round-trip: authored bytes read back

The sha256 in ReleaseELFSHA256 is computed here over --share: no
in-guest hasher exists today (crypto/sha256 is outside the staged
package surface, and fs.read stops at 4 KiB — the built ELF is
~1.5 MiB). The guest-built bytes are what gets hashed; the agent still
authors the manifest through fs.write.

Session resilience: the known open flake (#2436) can starve the channel
mid-journey — the stream child's stdin/stdout IS the single TCP
session, so there is no re-dial to fall back on. What the driver CAN do
is wait much longer than agentctl's 30 s reply bound: the observed
stalls are the smp serial flood starving the guest's TCP TX while the
socket stays open, so a 120 s window rides delays a dead socket would
never produce. A call that still times out (or EOFs) is a real drop —
the driver names #2436 and fails, never silently retrying.
"""

import argparse
import base64
import hashlib
import json
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", "..", "..", ".."))
sys.path.insert(0, os.path.join(_REPO, "tools", "agentctl"))
import agentctl  # noqa: E402

# The 30 s per-reply bound assumes a healthy link; under the smp serial
# flood the guest's TCP TX can legitimately stall far longer while the
# socket stays alive. Everything that reads a reply inside this process
# goes through this module constant (call/auth/refused_raw look it up at
# call time). The greeting's bound is a def-time default, so connect()
# passes an explicit value below.
agentctl.RESP_TIMEOUT = 120.0

Session = agentctl.Session
Refused = agentctl.Refused
ProtoError = agentctl.ProtoError
PeerGone = agentctl.PeerGone
Fail = agentctl.Fail
b64e = agentctl.b64e
b64d = agentctl.b64d
stream_bytes = agentctl.stream_bytes

# Guest paths (the sandbox prefix /host/AGENT/ is the verb's own).
APP_SRC = "APP/main.go"      # fs.* path
APP_ELF = "APP.ELF"          # fs.* path — the build product probe
APP_REL = "APP/release.go"   # fs.* path
WS_SRC = "/host/AGENT/APP"   # the flint workspace src
WS_CFG = "/host/FLINT/ws/agentapp/WORKSPACE.json"
STAGE = "/host/FLINT/ws/agentapp/STAGE.jsonl"
STREAM_GLOB = "/host/FLINT/streams/*.jsonl"
REMOTE = "10.0.0.2:4750"
PROBE_TIMEOUT_MS = 15000

FIXTURE = os.path.join(_HERE, "main.go")

REL_NAME = "AGENTAPP"
REL_VERSION = "1.0.0"
REL_ROW = "AGENTAPP.ELF | Agent App | a | dock=false"


_T0 = time.monotonic()


def note(msg):
    print("ALOOP: t=%.1f %s" % (time.monotonic() - _T0, msg),
          file=sys.stderr, flush=True)


def call_wait(s, verb, read_s, **args):
    """agentctl.Session.call with a per-request read deadline: the stock
    call() reads at RESP_TIMEOUT (30 s), which a slow gosh child (the push
    is ~2 min at --cpus 1) sails past — the agentd-side timeout_ms bounds
    the child, this bounds the wait for its answer."""
    s._next += 1
    rid = s._next
    req = {"id": rid, "verb": verb}
    req.update(args)
    s.send_raw(json.dumps(req, separators=(",", ":")).encode("utf-8"))
    chunks = []
    while True:
        obj = s.read_json(timeout=read_s)
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


def gosh(s, cmd, timeout_ms=25000):
    """One gosh.run, returning the result dict. The read deadline rides
    above the child timeout so the answer lands before we give up."""
    try:
        return call_wait(s, "gosh.run", timeout_ms / 1000.0 + 60.0,
                         cmd=cmd, timeout_ms=timeout_ms)
    except Refused as e:
        raise Fail("gosh.run %r refused %s" % (cmd, e.code))


def fswrite(s, path, data):
    try:
        return call_wait(s, "fs.write", 60.0, path=path,
                         data_b64=b64e(data))
    except Refused as e:
        raise Fail("fs.write %s refused %s" % (path, e.code))


def fsread(s, path):
    """fs.read; Refused propagates so callers can name not_found/too_large."""
    return call_wait(s, "fs.read", 60.0, path=path)


def test_e(s, path):
    """`test -e` through a gosh builtin: True when the path exists."""
    res = gosh(s, "test -e " + path, PROBE_TIMEOUT_MS)
    return res.get("exit_status") == 0


def wc_l(s, path):
    """`wc -l` through a gosh builtin: line count, or None on a miss."""
    res = gosh(s, "wc -l " + path, PROBE_TIMEOUT_MS)
    if res.get("exit_status") != 0:
        return None
    first = stream_bytes(res).decode("ascii", "replace").split()
    if not first or not first[0].isdigit():
        return None
    return int(first[0])


def change_count(s):
    """Changes on the agent's stream log, via the glob'd wc -l.

    None when the glob did not expand (pre-init state or a host without
    the dir-list lane) — callers treat it as 'cannot tell'.
    """
    return wc_l(s, STREAM_GLOB)


def commit_or_done(s, msg):
    """`flint commit` with the torn-window answer: a nonzero exit plus an
    emptied STAGE means the Change landed before the channel dropped —
    accept it rather than double-committing."""
    res = gosh(s, 'FLINT.ELF commit -m "%s"' % msg)
    if res.get("exit_status") == 0:
        return
    if wc_l(s, STAGE) == 0:
        note("commit already landed before the drop (stage empty)")
        return
    raise Fail("flint commit exited %s" % res.get("exit_status"))


def make_release_v1(elf_sha):
    return (
        "package release\n"
        "\n"
        'const ReleaseName = "%s"\n' % REL_NAME
        + 'const ReleaseVersion = "%s"\n' % REL_VERSION
    ).encode("utf-8")


def make_release_v2(elf_sha):
    return make_release_v1(elf_sha) + (
        'const ReleaseELFSHA256 = "%s"\n' % elf_sha
    ).encode("utf-8")


def make_release_v3(elf_sha):
    return make_release_v2(elf_sha) + (
        'const ReleaseManifestRow = "%s"\n' % REL_ROW
    ).encode("utf-8")


def run(s, ctx):
    """The hop sequence. Each entry: (name, probe-or-None, work)."""
    share = ctx["share"]
    src = open(FIXTURE, "rb").read()

    def author():
        res = fswrite(s, APP_SRC, src)
        if res.get("size") != len(src):
            raise Fail("APP/main.go size echo drifted")

    def authored():
        try:
            res = fsread(s, APP_SRC)
            return b64d(res.get("data_b64", "")) == src
        except Refused:
            return False

    def inited():
        return test_e(s, WS_CFG)

    def add_src():
        res = gosh(s, "FLINT.ELF add " + WS_SRC)
        if res.get("exit_status") != 0:
            raise Fail("flint add exited %s" % res.get("exit_status"))

    def committed_src():
        n = change_count(s)
        return n is not None and n >= 1

    def commit_src():
        commit_or_done(s, "agentapp: source")

    def check_built():
        """Publish-phase precondition: the build boot's product must be
        on the share (the ELF outgrows fs.read's 4 KiB, so too_large is
        the yes answer). Fails fast rather than polling — nothing is
        still building when this phase runs."""
        try:
            fsread(s, APP_ELF)
            return
        except Refused as e:
            if e.code == "too_large":
                return
            raise Fail("APP.ELF missing — the build boot did not publish")

    def build_request():
        """The dispatch artifact the build boot's `vf cat` consumes."""
        res = fswrite(
            s, "BUILD.REQ",
            b"ALOOP-BUILD-REQUEST src=/host/AGENT/APP out=/host/AGENT/APP.ELF\n")
        if res.get("size", 0) <= 0:
            raise Fail("BUILD.REQ write echoed no bytes")

    def elf_sha256():
        if "sha" not in ctx:
            p = os.path.join(share, "AGENT", "APP.ELF")
            try:
                ctx["sha"] = hashlib.sha256(open(p, "rb").read()).hexdigest()
            except OSError:
                raise Fail("the built ELF is not visible on the share at " + p)
        return ctx["sha"]

    def manifest_a():
        res = fswrite(s, APP_REL, make_release_v1(elf_sha256()))
        if res.get("size") <= 0:
            raise Fail("release.go write echoed no bytes")

    def manifested_a():
        try:
            res = fsread(s, APP_REL)
            return b"ReleaseVersion" in b64d(res.get("data_b64", ""))
        except Refused:
            return False

    def committed_rel_a():
        n = change_count(s)
        return n is not None and n >= 2

    def commit_rel_a():
        commit_or_done(s, "agentapp: release manifest")

    def manifest_b():
        res = fswrite(s, APP_REL, make_release_v2(elf_sha256()))
        if res.get("size") <= 0:
            raise Fail("release.go v2 write echoed no bytes")

    def manifested_b():
        try:
            res = fsread(s, APP_REL)
            return b"ReleaseELFSHA256" in b64d(res.get("data_b64", ""))
        except Refused:
            return False

    def committed_rel_b():
        n = change_count(s)
        return n is not None and n >= 3

    def commit_rel_b():
        commit_or_done(s, "agentapp: elf hash")

    def manifest_c():
        res = fswrite(s, APP_REL, make_release_v3(elf_sha256()))
        if res.get("size") <= 0:
            raise Fail("release.go v3 write echoed no bytes")

    def manifested_c():
        try:
            res = fsread(s, APP_REL)
            return b"ReleaseManifestRow" in b64d(res.get("data_b64", ""))
        except Refused:
            return False

    def committed_rel_c():
        n = change_count(s)
        return n is not None and n >= 4

    def commit_rel_c():
        commit_or_done(s, "agentapp: manifest row")

    def commits_ready():
        """Precondition for the push dispatch: all four commits (source
        + three release halves) must be on the stream before it goes out."""
        if change_count(s) < 4:
            raise Fail("stream has <4 Changes — the release boot did not "
                       "finish")

    def push_request():
        """The dispatch artifact the publish boot's `vf cat` consumes —
        like BUILD.REQ, the heavy work (a ~2-4 min wire round trip at
        --cpus 1) outlives any in-session verb's read window: the
        response always drops before it lands, so the push rides the
        monitor-dispatch seam too."""
        res = fswrite(
            s, "PUSH.REQ",
            b"ALOOP-PUSH-REQUEST stream=main remote=" + REMOTE.encode() + b"\n")
        if res.get("size", 0) <= 0:
            raise Fail("PUSH.REQ write echoed no bytes")

    def verify_roundtrip():
        res = fsread(s, APP_REL)
        if b64d(res.get("data_b64", "")) != make_release_v3(elf_sha256()):
            raise Fail("release.go did not round-trip the manifest")

    def handshake():
        # The greeting is one-per-session: connect() already authed; this
        # step only validates the advertised surface, no IO.
        for v in ("fs.write", "gosh.run"):
            if v not in (s.verbs or []):
                raise Fail("missing advertised verb " + v)
        for c in ("file", "term"):
            if c not in (s.caps or []):
                raise Fail("missing declared cap " + c)

    phases = {
        "author": [
            ("author", authored, author),
            ("init", inited, lambda: _gosh_ok(s, "FLINT.ELF init --name=agentapp --src=" + WS_SRC)),
            ("add-src", None, add_src),
            ("commit-src", committed_src, commit_src),
            ("build-request", None, build_request),
        ],
        "release-a": [
            ("built", None, check_built),
            ("manifest-a", manifested_a, manifest_a),
            ("add-rel-a", None, add_src),
            ("commit-rel-a", committed_rel_a, commit_rel_a),
            ("manifest-b", manifested_b, manifest_b),
            ("add-rel-b", None, add_src),
            ("commit-rel-b", committed_rel_b, commit_rel_b),
        ],
        "release-b": [
            ("manifest-c", manifested_c, manifest_c),
            ("add-rel-c", None, add_src),
            ("commit-rel-c", committed_rel_c, commit_rel_c),
            ("commits-ready", None, commits_ready),
            ("push-request", None, push_request),
            ("roundtrip", None, verify_roundtrip),
        ],
    }
    steps = phases[ctx["phase"]]

    handshake()
    note("ok handshake")
    i = 0
    while i < len(steps):
        name, probe, work = steps[i]
        try:
            if probe is not None and probe():
                note("ok " + name + " (resumed: already satisfied)")
                i += 1
                continue
            work()
            note("ok " + name)
            i += 1
        except Fail as e:
            # The file-channel/exec-lookup race can eat a spawn or return a
            # stale nonzero (observed `gosh: FLINT.ELF: not found` under
            # load): one settle + a state re-probe before the retry — the
            # recheck is what keeps a landed-but-unacked hop from running
            # twice, and the retry is named on stderr, never silent.
            note(name + " hit " + str(e) + " -> settle + recheck")
            time.sleep(3)
            if probe is not None and probe():
                note("ok " + name + " (resumed: already satisfied)")
                i += 1
                continue
            work()
            note("ok " + name + " (after settle retry)")
            i += 1
    note("PASS agentloop")


def _gosh_ok(s, cmd):
    res = gosh(s, cmd)
    if res.get("exit_status") != 0:
        raise Fail("%s exited %s" % (cmd, res.get("exit_status")))


def connect(ctx):
    """The one session this child's stdin/stdout can carry."""
    s = Session(sys.stdin.buffer, sys.stdout.buffer)
    if os.environ.get("ALOOP_DEBUG"):
        s.greeting(timeout=90.0)
        note("dbg greeting done")
        ch = s.challenge
        import agentctl as _a
        sig = _a.ed_sign(s.sign_message(ctx["agent"]), ctx["seed"])
        s.send_raw((
            '{"agent":"%s","auth":"%s"}' % (ctx["agent"], sig.hex())
        ).encode("ascii"))
        note("dbg auth line sent, waiting on ready")
        obj = s.read_json(timeout=agentctl.RESP_TIMEOUT)
        note("dbg got reply " + str(obj))
        if not obj.get("ok"):
            raise Fail("auth refused")
        s.agent = ctx["agent"]
        s.caps = obj.get("caps")
        s.verbs = obj.get("verbs")
        return s
    s.greeting(timeout=90.0)
    s.auth(ctx["agent"], ctx["seed"])
    return s


def harness(args):
    try:
        cred = agentctl.read_cred(args.key_file)
    except Fail as e:
        note("FAIL %s" % e)
        return 1
    ctx = {"agent": cred[0], "seed": cred[1], "share": args.share,
           "phase": args.phase}
    try:
        s = connect(ctx)
        run(s, ctx)
        return 0
    except KeyboardInterrupt:
        return 1
    except Fail as e:
        note("FAIL %s" % e)
        return 1
    except (PeerGone, TimeoutError) as e:
        # The stream child's stdin/stdout is the whole TCP session — a
        # drop mid-journey cannot be retried from inside this process.
        # Name the known flake rather than quietly retrying.
        note("FAIL session lost mid-journey (flake #2436): %s" % e)
        return 1
    except Exception as e:  # a harness bug is a failure, never a pass
        import traceback
        traceback.print_exc(file=sys.stderr)
        note("FAIL harness %s" % type(e).__name__)
        return 1


def main(argv=None):
    p = argparse.ArgumentParser(
        prog="agentloop.py",
        description="M109d live-agent-loop driver (ADR 0052)",
    )
    h = p.add_subparsers(dest="cmd").add_parser("harness")
    h.add_argument("--key-file", required=True)
    h.add_argument("--share", required=True,
                   help="the armed share dir (for the ELF sha256 only)")
    h.add_argument("--phase", required=True,
                   choices=("author", "release-a", "release-b"),
                   help="which boot's leg this session drives")
    args = p.parse_args(argv)
    if args.cmd == "harness":
        return harness(args)
    p.error("a command is required")


if __name__ == "__main__":
    sys.exit(main())
