# live-selfhost-go.spec -- M70c-S2 (issue #1544) class-B gate: the in-guest
# build loop. GOSELFHOST.ELF (tools/go/selfhost.go) compiles the pinned fixture
# with the guest's own cmd/compile and links it with the guest's own cmd/link,
# sequencing the two steps by spawn-and-wait (ADR 0007 slot 28 + the wait
# slots) instead of by two boots' worth of monitor `exec` — the shape the #1544
# spike chose and recorded (ADR 0035 amendment 6). Nothing fetches a toolchain:
# GOTOOLCHAIN=local is literal for a guest with no `go` command, and every byte
# the loop reads is staged in the share.
#
# TWO boots, and the shape is conservative rather than forced. The product as a
# third child died ONCE (run 01: `fault: HELLO2.ELF far=0x47c29000 ec=0x24
# esr=0x9200004f`, status 139) — the wall go-sh.spec documents for Go children
# ("A THIRD sequential exec from one EL0 parent currently dies in the Go
# runtime's own schedinit ... follow-up owed to the runtime/kernel owners",
# issue #1449) with a different symptom. It does NOT reproduce at this head:
# the driver's argv-gated measurement (tools/go/selfhost.go `--spawn`, off by
# default) ran three children of EITHER kind 3/3, and the exact failing
# configuration — loop, then the product as the third child — came back
# status=0 (four boots; the matrix is ADR 0035 amendment 8). So the BUILD stays
# the guest's own two-child loop and the RUN stays one monitor `exec` of what it
# produced (the same execution go-hello run 08 performs) because this shape is
# PROVEN green, not because a third child is known to fail. A one-boot
# three-child loop is feasible and is the first thing to try once #1449 is
# characterised.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-go.sh tools/go/selfhost.go   -> .build/go/GOSELFHOST.ELF
#   bash tools/go/build-gotool.sh                    -> .build/go/GOCMD*.ELF
#   bash tools/go/stage-selfhost.sh                  -> .build/go/selfhost/
#   bash tools/go/build-gobuild.sh                   -> .build/go/GOBUILD.ELF
#   bash tools/go/build-<app>.sh per fleet ELF       -> .build/go/<NAME>.ELF
#     (gocalc note goedit files goterm web pulse gosh help gotop goset
#      godiff goview gosound flint store agentd — REF/ names them)
# exec-order: assert-proven -- run 01 ends on a marker only the driver prints,
# and its asserts read the driver's own steps; run 02 ends on the executed
# program's own pinned line. A loop that never ran cannot go green. See
# tools/gate/SPEC.md.
#
# M112a (#2413) run 03 — the fleet leg. GOBUILD.ELF's `fleet` verb builds
# every row of the pinned list (user/go/gobuild/fleet.txt, staged as
# /host/FLEET.TXT) from the staged source tree (/host/SRC) with the real
# M107b policy table, writes the source->ELF manifest to /host/FLEET.MF, and
# smoke-execs each product once. GOSTALGIA's `external:` row earns the named
# refusal by design — its source is a pinned host-side checkout plus overlay
# trees, not share-stageable source.

vgate_name live-selfhost-go "issue #1544 M70c-S2: the guest's own toolchain builds the pinned hello in one loop, and the product runs"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec GOSELFHOST.ELF
EOF

vgate_file script2.txt <<'EOF'
exec HELLO2.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
fixtures = [".build/go/GOSELFHOST.ELF", ".build/go/GOCMDCOMPILE.ELF", ".build/go/GOCMDLINK.ELF"]
for src in fixtures:
    if not os.path.exists(src):
        sys.exit("%s missing — build it first (see this spec's header): "
                 "bash tools/go/build-go.sh tools/go/selfhost.go, "
                 "bash tools/go/build-gotool.sh" % src)
    shutil.copy(src, os.path.join(share, os.path.basename(src)))
    print("staged %s (%d bytes)" % (os.path.basename(src), os.path.getsize(src)))
# What the guest's linker reads: the import config naming export data for the
# pinned hello's closure, those archives, and the pinned source.
stage = ".build/go/selfhost"
if not os.path.isdir(stage):
    sys.exit("missing %s — run: bash tools/go/stage-selfhost.sh" % stage)
n = total = 0
for name in sorted(os.listdir(stage)):
    if name.startswith("."):
        continue
    src = os.path.join(stage, name)
    shutil.copy(src, os.path.join(share, name))
    n += 1
    total += os.path.getsize(src)
print("staged %d selfhost inputs (%.2f MiB): import config + archives + HELLO.GO"
      % (n, total / 1048576.0))
# The loop's products must not be leftovers: this spec and go-hello run 08 both
# write HELLO.o / HELLO2.ELF into a share, and a stale one would let a broken
# loop go green. Run 02 executes what run 01 writes, so a stale product would
# also fake the second boot.
for stale in ("HELLO.o", "HELLO2.ELF"):
    p = os.path.join(share, stale)
    if os.path.exists(p):
        os.remove(p)
        print("removed stale %s from a previous run" % stale)
PY

# Run 01: the build loop. One program, two children, sequenced by the guest's
# own waits. A linker that reads ~15 MiB of archives off the share at the
# 2048-byte EL0 read cap is the slow step, hence the wide timeout.
vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'selfhost: build loop OK' --timeout 900

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOSELFHOST.ELF'
vgate_assert 01 serial-contains 'selfhost: compile GOCMDCOMPILE.ELF status=0'
vgate_assert 01 serial-contains 'selfhost: link GOCMDLINK.ELF status=0'
vgate_assert 01 serial-contains 'selfhost: build loop OK'
vgate_assert 01 serial-absent 'selfhost: FAIL'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'cannot allocate memory'
vgate_assert 01 serial-absent 'exited status=139'

# The loop's products, checked from macOS: the object really is a virelai
# object (its ar header names the target it was compiled for) and the ELF
# really is loadable — every rule the kernel enforces, plus the argv+envp slack
# the second boot's exec depends on. The step times are extracted and reported
# (a build time is a property of the machine, so it is not asserted, the same
# way go-hello run 04 reports its transfer rate).
vgate_assert 01 python <<'PY'
import os, re, sys
sys.path.insert(0, os.path.join("tools", "lib"))
import elf_rules
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")

obj = os.path.join(share, "HELLO.o")
if not os.path.exists(obj):
    sys.exit("FAIL: the loop produced no object at " + obj)
raw = open(obj, "rb").read()
if not raw.startswith(b"!<arch>") or b"go object virelai arm64 " not in raw:
    sys.exit("FAIL: HELLO.o is not a virelai Go object (first bytes %r)" % raw[:16])
for want in (b"__.PKGDEF", b"_go_.o", b"main.main"):
    if want not in raw:
        sys.exit("FAIL: HELLO.o has no %r" % want)

elf = os.path.join(share, "HELLO2.ELF")
if not os.path.exists(elf):
    sys.exit("FAIL: the loop produced no ELF at " + elf)
# ONE copy of the kernel's loader rules, shared with go-hello.spec run 07
# (tools/lib/elf_rules.py). A rule that drifted in one spec would pass an
# image the kernel then refuses, far from the check that lied.
receipt, fails = elf_rules.check_file(elf, "HELLO2.ELF")
print("loop products: HELLO.o %d bytes (virelai object), %s"
      % (len(raw), receipt))
ser = open(os.environ["VG_SER"], errors="replace").read()
for label in ("compile", "link"):
    m = re.search(r"selfhost: %s \S+ status=(\d+) ms=(\d+)" % label, ser)
    if not m:
        sys.exit("FAIL: no `selfhost: %s ... ms=` line" % label)
    print("step %s: status=%s elapsed=%s ms" % (label, m.group(1), m.group(2)))
if fails:
    for f in fails:
        print("FAIL: " + f)
    sys.exit(1)
print("the loop's ELF satisfies every loader rule the kernel enforces")
PY

# Run 02: the product the guest built, executed by the kernel — the RUN half of
# the build loop, one monitor exec (see this spec's header for why it is not a
# third child in run 01). Its pinned lines are the fixture's own vocabulary
# (phase 0a's runtime surface: console, sbrk heap growth, a GC cycle).
#
# No `procs HELLO2.ELF exited status=0` assert: the run stops ON the program's
# last pinned line, which is printed before the process is reaped, so the exit
# line races the stop rather than reporting on the program. The
# absent-exception asserts are what rule out a crash.
vgate_run 02 -- --script '$RUN_DIR/script2.txt' --script-expect 'virelai-go OK' --timeout 300

vgate_assert 02 serial-contains 'exec: loaded HELLO2.ELF'
vgate_assert 02 serial-contains 'hello from virelai'
vgate_assert 02 serial-contains 'GOOS=virelai GOARCH=arm64 gc runtime alive'
vgate_assert 02 serial-contains 'heap: wrote 1048576 bytes'
vgate_assert 02 serial-contains 'gc: cycle completed'
vgate_assert 02 serial-contains 'virelai-go OK'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 serial-absent 'cannot allocate memory'

# ---------------------------------------------------------------------------
# M112a (#2413) run 03 — the fleet leg. One boot, one driver run: the pinned
# 19-row list, per-ELF named refusals (never a silently widened allowlist),
# the FLEET.MF manifest on the share, and a bounded smoke exec per product.
# wm=none keeps every EL0 task slot free for toolchain children.

vgate_file script3.txt <<'EOF'
exec GOBUILD.ELF fleet
EOF

vgate_setup_python <<'PY'
import os, re, shutil, subprocess, sys

share = os.path.join(os.environ["RUN_DIR"], "share")
repo = os.getcwd()

# Stale products must not fake a later run (same rule as the HELLO sweep):
# the manifest and the guest-built ELFs go BEFORE the driver itself is
# staged, because GOBUILD.ELF is both the staged driver and a fleet row.
mf = os.path.join(share, "FLEET.MF")
if os.path.exists(mf):
    os.remove(mf)
for line in open("user/go/gobuild/fleet.txt"):
    line = line.strip()
    if line and not line.startswith("#"):
        p = os.path.join(share, line.split()[0])
        if os.path.isfile(p):
            os.remove(p)

# The in-guest driver + the pinned list.
if not os.path.exists(".build/go/GOBUILD.ELF"):
    sys.exit(".build/go/GOBUILD.ELF missing — bash tools/go/build-gobuild.sh")
shutil.copy(".build/go/GOBUILD.ELF", os.path.join(share, "GOBUILD.ELF"))
shutil.copy("user/go/gobuild/fleet.txt", os.path.join(share, "FLEET.TXT"))

# wm=none: no seat ever starts, so the ~250 sequential toolchain children
# and the smoke execs never contend for EL0 task slots.
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")

# --- the pinned fleet rows --------------------------------------------------
rows = []
for line in open("user/go/gobuild/fleet.txt"):
    line = line.strip()
    if line and not line.startswith("#"):
        name, src = line.split()
        rows.append((name, src))
if len(rows) != 19:
    sys.exit("fleet.txt pins %d rows, expected 19" % len(rows))

# --- host-built reference ELFs -> REF/ (the manifest's host= column) --------
os.makedirs(os.path.join(share, "REF"), exist_ok=True)
n_ref = 0
for name, _ in rows:
    p = os.path.join(".build", "go", name)
    if os.path.exists(p):
        shutil.copy(p, os.path.join(share, "REF", name))
        n_ref += 1
print("staged %d host reference ELFs under REF/" % n_ref)

# --- the fleet source tree -> SRC/ ------------------------------------------
# virelai/<pkg> maps to user/go/<pkg>. Third-party module imports map to the
# pinned module-cache copies — the same pins the three Charm apps' host
# builds declare (THIRD-PARTY.txt) — under their import path, minus the
# @version. Resolution in-guest is local-source, so the archive allowlist is
# untouched and the manifest's src= column covers them.
MODVER = {
    "charm.land/bubbletea/v2": "v2.0.9",
    "github.com/aymanbagabas/go-osc52/v2": "v2.0.1",
    "github.com/charmbracelet/colorprofile": "v0.4.3",
    "github.com/charmbracelet/lipgloss": "v1.1.0",
    "github.com/charmbracelet/ultraviolet": "v0.0.0-20260703014108-f5a850f9c2b7",
    "github.com/charmbracelet/x/ansi": "v0.11.7",
    "github.com/charmbracelet/x/cellbuf": "v0.0.15",
    "github.com/charmbracelet/x/term": "v0.2.2",
    "github.com/charmbracelet/x/windows": "v0.2.2",
    "github.com/clipperhouse/displaywidth": "v0.11.0",
    "github.com/clipperhouse/uax29/v2": "v2.7.0",
    "github.com/lucasb-eyer/go-colorful": "v1.4.0",
    "github.com/mattn/go-isatty": "v0.0.20",
    "github.com/mattn/go-runewidth": "v0.0.23",
    "github.com/muesli/cancelreader": "v0.2.2",
    "github.com/muesli/termenv": "v0.16.0",
    "github.com/rivo/uniseg": "v0.4.7",
    "github.com/xo/terminfo": "v0.0.0-20220910002029-abceb7e1c41e",
    "golang.org/x/sync": "v0.21.0",
}
modcache = None

# virelai/vi and virelai/vsys are the archive tier, not source: their .s
# gateways need cmd/asm, which the in-guest toolchain does not ship. They
# resolve through GOIMPORT.CFG's staged GPKG_*.a archives.
ARCHIVE_TIER = {"virelai/vi", "virelai/vsys"}

IMP = re.compile(r'"([A-Za-z0-9_][A-Za-z0-9_./-]*)"')

# The driver's build tag set is exactly {virelai, arm64, gc} — virelai is NOT
# in Go's unix GOOS set, so "unix"-tagged code is out (that is why the Charm
# apps carry shims). The walker must only follow imports of files this
# toolchain would compile.
BUILD_TAGS = {"virelai", "arm64", "gc"}

def _eval_expr(tok, i):
    """tiny //go:build evaluator: !, &&, ||, parens over tag atoms."""
    if tok[i] == "!":
        v, i = _eval_expr(tok, i + 1)
        return (not v), i
    if tok[i] == "(":
        v, i = _eval_or(tok, i + 1)
        return v, i + 1  # consume ')'
    v = tok[i] in BUILD_TAGS
    return v, i + 1

def _eval_and(tok, i):
    v, i = _eval_expr(tok, i)
    while i < len(tok) and tok[i] == "&&":
        w, i = _eval_expr(tok, i + 1)
        v = v and w
    return v, i

def _eval_or(tok, i):
    v, i = _eval_and(tok, i)
    while i < len(tok) and tok[i] == "||":
        w, i = _eval_and(tok, i + 1)
        v = v or w
    return v, i

def _tok(expr):
    return re.findall(r'[A-Za-z0-9_.]+|&&|\|\||!|\(|\)', expr)

# go/build's filename platform rule (internal/syslist lists): a final
# _<GOOS>/_<GOARCH> component selects that platform, x_<GOOS>_<GOARCH> the
# pair; unrecognised tokens constrain nothing. The driver applies the same
# rule in-guest — the walker must agree or it will stage imports the in-guest
# selection never reads.
KNOWN_GOOS = {"aix", "android", "darwin", "dragonfly", "freebsd", "hurd",
              "illumos", "ios", "js", "linux", "nacl", "netbsd", "openbsd",
              "plan9", "solaris", "wasip1", "virelai", "windows", "zos"}
KNOWN_GOARCH = {"386", "amd64", "amd64p32", "arm", "armbe", "arm64",
                "arm64be", "loong64", "mips", "mipsle", "mips64",
                "mips64le", "mips64p32", "mips64p32le", "ppc", "ppc64",
                "ppc64le", "riscv", "riscv64", "s390x", "sparc",
                "sparc64", "wasm"}

def filename_target_ok(name):
    base = name.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    if base.endswith("_test"):
        base = base[:-5]
    parts = base.split("_")
    if len(parts) < 2:
        return True
    last = parts[-1]
    second = parts[-2] if len(parts) >= 3 else ""
    if last in KNOWN_GOARCH:
        if last != "arm64":
            return False
        return second not in KNOWN_GOOS or second == "virelai"
    if last in KNOWN_GOOS:
        return last == "virelai"
    return True

def buildable_go(path):
    """True when this file would compile under //go:build virelai."""
    if not filename_target_ok(path):
        return False
    gobuild, plusbuilds = None, []
    try:
        for line in open(path, errors="replace"):
            s = line.strip()
            if s.startswith("//go:build"):
                v, _ = _eval_or(_tok(s[len("//go:build"):]), 0)
                gobuild = v
            elif s.startswith("// +build"):
                # legacy: comma = AND, space = OR, lines AND together
                groups = s[len("// +build"):].split()
                line_ok = False
                for grp in groups:
                    atoms = grp.split(",")
                    line_ok = all(
                        (a[1:] not in BUILD_TAGS) if a.startswith("!")
                        else (a in BUILD_TAGS)
                        for a in atoms)
                    if line_ok:
                        break
                plusbuilds.append(line_ok)
            elif s.startswith("//") or s == "":
                continue
            else:
                break
    except OSError:
        return True  # unreadable stays the driver's problem
    if gobuild is not None:
        return gobuild
    if plusbuilds:
        return all(plusbuilds)
    return True

def go_imports(path):
    imps, inblock = [], False
    for line in open(path, errors="replace"):
        s = line.split("//", 1)[0].strip() if "import" not in line else line.strip()
        if s.startswith("//"):
            continue
        if not inblock and s.startswith("import"):
            rest = s[len("import"):].strip()
            if rest.startswith("("):
                inblock = True
                continue
            m = IMP.search(rest)
            if m:
                imps.append(m.group(1))
            continue
        if inblock:
            if s.startswith(")"):
                inblock = False
                continue
            m = IMP.search(s)
            if m:
                imps.append(m.group(1))
    return imps

def modsrc(imp):
    """map an import path to (module root in cache, subpath) or None."""
    global modcache
    best = None
    for m in MODVER:
        if imp == m or imp.startswith(m + "/"):
            if best is None or len(m) > len(best):
                best = m
    if best is None:
        return None
    if modcache is None:
        modcache = subprocess.run(["go", "env", "GOMODCACHE"],
                                  capture_output=True, text=True).stdout.strip()
        if not modcache:
            sys.exit("go env GOMODCACHE returned nothing")
    rel = imp[len(best):].lstrip("/")
    return os.path.join(modcache, best + "@" + MODVER[best], rel)

def stage_dir(src_abs, dst_rel, seen):
    """copy one package dir's .go surface; return True if newly staged."""
    dst = os.path.join(share, "SRC", dst_rel)
    if dst_rel in seen:
        return False
    if not os.path.isdir(src_abs):
        return False
    os.makedirs(dst, exist_ok=True)
    n = 0
    for name in sorted(os.listdir(src_abs)):
        sp = os.path.join(src_abs, name)
        if os.path.isfile(sp) and name.endswith(".go") and not name.endswith("_test.go"):
            shutil.copyfile(sp, os.path.join(dst, name))
            n += 1
    if n == 0:
        return False
    seen.add(dst_rel)
    return True

# The overlay facts the host builds apply (tools/go/build-{files,pulse,
# help}.sh): two bubbletea files are REPLACED (their upstream build tags
# would otherwise select wrong-GOOS implementations), and termenv/go-isatty
# get an additive virelai shim file. Same rules, same files.
OVERLAY = os.path.join("tools", "go", "overlay", "charm")
BUBBLE = "charm.land/bubbletea/v2"

queue = []
for name, src in rows:
    if src.startswith("external:"):
        continue
    # src is virelai/<app>: the program dir under the source root.
    queue.append((os.path.join(repo, "user", "go", src[len("virelai/"):]), src))

staged = set()
files_total = 0
missing = []
while queue:
    src_abs, rel = queue.pop()
    if rel in staged:
        continue
    if not os.path.isdir(src_abs):
        missing.append(rel)
        continue
    if not stage_dir(src_abs, rel, staged):
        missing.append(rel)
        continue
    dst = os.path.join(share, "SRC", rel)
    files_total += len(os.listdir(dst))
    # apply the charm overlay rules to staged module copies
    if rel == BUBBLE:
        for old, new in (("termios_other.go", "termios_virelai.go"),
                         ("signals_unix.go", "signals_virelai.go")):
            ov = os.path.join(repo, OVERLAY, new)
            orig = os.path.join(dst, old)
            if os.path.exists(orig):
                os.remove(orig)
            shutil.copyfile(ov, os.path.join(dst, new))
    if rel == "github.com/muesli/termenv":
        shutil.copyfile(os.path.join(repo, OVERLAY, "termenv_virelai.go"),
                        os.path.join(dst, "termenv_virelai.go"))
    if rel == "github.com/mattn/go-isatty":
        shutil.copyfile(os.path.join(repo, OVERLAY, "isatty_virelai.go"),
                        os.path.join(dst, "isatty_virelai.go"))
    # walk this dir's imports — but only from files this toolchain selects
    # (a darwin- or windows-only file's imports are not ours to stage).
    for fn in sorted(os.listdir(dst)):
        fp = os.path.join(dst, fn)
        if not fn.endswith(".go") or not buildable_go(fp):
            continue
        for imp in go_imports(fp):
            if imp.startswith("virelai/"):
                if imp in ARCHIVE_TIER:
                    continue
                queue.append((os.path.join(repo, "user", "go",
                                           imp[len("virelai/"):]), imp))
            elif "." in imp.split("/")[0]:
                md = modsrc(imp)
                if md is None:
                    missing.append(imp + " (no pinned module)")
                else:
                    queue.append((md, imp))

if missing:
    sys.exit("fleet source staging incomplete — not stageable under SRC/: %s"
             % sorted(set(missing)))
print("fleet source tree: %d package dirs, %d .go files under SRC/"
      % (len(staged), files_total))
PY

# Run 03: one driver, ~250 sequential spawn-and-wait children, 18 smoke
# execs. The timeout is wide for the same reason run 01's is — a link child
# reading tens of MiB of archives off the 2048-byte share channel is slow,
# and there are eighteen of them. A premature kill would fake failure, not
# evidence.
vgate_run 03 -- --script '$RUN_DIR/script3.txt' --script-expect 'fleet: fleet ' --timeout 5400

vgate_assert 03 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 03 serial-contains 'exec: loaded GOBUILD.ELF'
vgate_assert 03 serial-contains 'fleet: GOCALC.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: NOTE.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: GOEDIT.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: GOTERM.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: WEB.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: GOSH.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: GOTOP.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: GOSET.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: GODIFF.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: GOVIEW.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: GOSOUND.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: FLINT.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: STORE.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: AGENTD.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: GOBUILD.ELF built sha256='
vgate_assert 03 serial-contains 'fleet: GOFILES.ELF refused dep_unsupported'
vgate_assert 03 serial-contains 'fleet: PULSE.ELF refused dep_unsupported'
vgate_assert 03 serial-contains 'fleet: GOHELP.ELF refused dep_unsupported'
vgate_assert 03 serial-contains 'fleet: GOSTALGIA.ELF refused external_tree'
vgate_assert 03 serial-contains 'fleet: smoke GOCALC.ELF'
vgate_assert 03 serial-contains 'fleet: smoke GOBUILD.ELF'
vgate_assert 03 serial-contains 'fleet: manifest -> /host/FLEET.MF'
vgate_assert 03 serial-contains 'fleet: fleet OK built=15 refused=4'
vgate_assert 03 serial-absent 'fleet: fleet INCOMPLETE'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'cannot allocate memory'
vgate_assert 03 serial-absent 'exited status=139'

# The manifest is the card's deliverable: every pinned row carries the
# source hash, the toolchain stamp, and both sha256 columns; every built
# ELF passes the kernel's own loader rules (the same elf_rules the other
# runs share). Refusals are named, never silent.
vgate_assert 03 python <<'PY'
import os, re, sys
sys.path.insert(0, os.path.join("tools", "lib"))
import elf_rules
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")

mf = os.path.join(share, "FLEET.MF")
if not os.path.exists(mf):
    sys.exit("FAIL: no FLEET.MF on the share")
lines = [l for l in open(mf).read().splitlines() if l and not l.startswith("#")]
if len(lines) != 19:
    sys.exit("FAIL: FLEET.MF has %d rows, want 19" % len(lines))

built, refused, failed = [], [], []
for line in lines:
    f = line.split("\t")
    row = {}
    name, state = f[0], f[1]
    for kv in f[2:]:
        if "=" in kv:
            k, v = kv.split("=", 1)
            row[k] = v
    for col in ("src", "tc", "guest", "host", "hash"):
        if col not in row:
            sys.exit("FAIL: %s row missing %s=" % (name, col))
    if row["tc"] == "-" or len(row["tc"]) != 64:
        sys.exit("FAIL: %s has no toolchain stamp" % name)
    if state == "built":
        for col in ("src", "guest"):
            if len(row[col]) != 64:
                sys.exit("FAIL: %s %s is not a sha256" % (name, col))
        if not row.get("smoke") or row["smoke"] == "-":
            sys.exit("FAIL: %s built but no smoke verdict" % name)
        if row["hash"] not in ("match", "host-missing") and \
           not row["hash"].startswith("mismatch:"):
            sys.exit("FAIL: %s unnamed hash verdict %r" % (name, row["hash"]))
        built.append(name)
    elif state == "refused":
        if row.get("code") in ("", None):
            sys.exit("FAIL: %s refused without naming the refusal" % name)
        refused.append(name)
    else:
        failed.append(name)

# The pinned list says exactly which of the 19 build; a drift either way is
# a spec-level finding, not a shrug. GOFILES/PULSE/GOHELP refuse
# dep_unsupported: their closure needs image/color, which M107b's table
# deliberately does not stage (the card's "never silently widen" means the
# refusal is the answer, not a wider allowlist). GOSTALGIA's sources are a
# host-side pin — external_tree.
want_built = {"GOCALC.ELF", "NOTE.ELF", "GOEDIT.ELF", "GOTERM.ELF",
              "WEB.ELF", "GOSH.ELF", "GOTOP.ELF", "GOSET.ELF", "GODIFF.ELF",
              "GOVIEW.ELF", "GOSOUND.ELF", "FLINT.ELF", "STORE.ELF",
              "AGENTD.ELF", "GOBUILD.ELF"}
want_refused = {"GOSTALGIA.ELF", "GOFILES.ELF", "PULSE.ELF", "GOHELP.ELF"}
if set(built) != want_built:
    sys.exit("FAIL: built set drifted: missing=%s extra=%s"
             % (sorted(want_built - set(built)), sorted(set(built) - want_built)))
if set(refused) != want_refused:
    sys.exit("FAIL: refused set = %s, want %s" % (sorted(refused), sorted(want_refused)))
if failed:
    sys.exit("FAIL: %d ELFs failed mid-build: %s" % (len(failed), failed))

for name in built:
    elf = os.path.join(share, name)
    if not os.path.exists(elf):
        sys.exit("FAIL: %s marked built but no product on the share" % name)
    receipt, fails = elf_rules.check_file(elf, name)
    if fails:
        for fl in fails:
            print("FAIL: " + fl)
        sys.exit(1)
print("fleet manifest: %d built + %d refused, all loader-clean, named "
      "verdicts per row" % (len(built), len(refused)))
PY

# Diagnostic, never-fail: child crashes write kernel tombstones to
# crash/<pid>-<name>.txt on the share — surface them in the report so a
# mid-fleet fault is legible evidence, not an invisible stack.
vgate_assert 03 python <<'PY'
import glob, os
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
tombs = sorted(glob.glob(os.path.join(share, "crash", "*.txt")))
if not tombs:
    print("no crash tombstones on the share")
for t in tombs[:8]:
    print("=== %s ===" % os.path.basename(t))
    print(open(t, errors="replace").read()[:4000])
PY
