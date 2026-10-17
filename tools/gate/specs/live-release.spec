# live-release.spec -- M112c (issue #2415) class-B gate: a release is a
# guest command — the guest assembles what the host boots.
#
# Run 01 is the M112a fleet leg verbatim in shape: `GOBUILD.ELF fleet` at
# the monitor's own nesting depth over the staged SRC tree, its products
# landing in BUNDLE/ and its manifest at FLEET.MF.
#
# Run 02 execs `GORELEASE.ELF assemble`: it verifies the sha-pinned host
# boot inputs (BOOTIN.MF vs the staged BOOTAA64.EFI/KERNEL.BIN), checks
# every built FLEET.MF row is in BUNDLE/ at its guest= sha256, collects the
# rest of the bundle (APPS.TXT + SETTINGS.TXT + the driver + staged
# assets), streams a GPT+FAT32 boot image to RELEASE.IMG, and writes the
# RELEASE.MF manifest. The kernel's FAT support is read-only
# (kernel/src/fat32_ro.zig) and never touches the boot volume, so the
# writer is userspace Go — user/go/release is a byte-exact port of
# image/mkfat32.py, which the run-02 asserts prove by building the
# reference image from the same inputs and comparing bytes.
#
# (The one-shot `gorelease release` verb still drives the fleet as a
# spawned child for standalone use; the gate splits it so the fleet churn
# does not run under an extra resident process — kernel max_tasks=16.)
#
# Run 03 boots the guest-built image (--overlay-base RELEASE.IMG) with the
# guest-built bundle armed as the share (--cvc-file BUNDLE/) and execs the
# driver's own smoke verb: every kind=fleet manifest row is spawned and
# observed — the fleet smoke markers the card asks for.
#
# HOST PREREQUISITES (the setup fails honestly when any is missing):
#   bash tools/go/build-gorelease.sh   -> .build/go/GORELEASE.ELF
#   bash tools/go/build-gobuild.sh     -> .build/go/GOBUILD.ELF
#   bash tools/go/build-gotool.sh      -> .build/go/GOCMD*.ELF
#   bash tools/go/stage-selfhost.sh    -> .build/go/selfhost/
#   bash tools/go/build-*.sh           -> .build/go/<FLEET>.ELF (REF/ column)
#
# exec-order: assert-proven -- run 01 ends on `fleet: fleet ` (the driver's
# own summary line), runs 02/03 on the driver's `release: exit rc=` sentinel
# (printed on every path, so a failure ends promptly rather than riding the
# timeout). The green asserts require program-printed OK lines plus the
# guest-written artifacts on the share — a driver that never ran cannot go
# green (SPEC.md).

vgate_name live-release "M112c #2415: the guest assembles a bootable GPT/FAT32 image + share bundle; the host boots the result"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec GOBUILD.ELF fleet -nosmoke -outdir /host/BUNDLE -manifest /host/FLEET.MF
EOF

vgate_file script2.txt <<'EOF'
exec GORELEASE.ELF assemble
EOF

vgate_file script3.txt <<'EOF'
exec GORELEASE.ELF smoke
EOF

vgate_setup_python <<'PY'
import hashlib, os, re, shutil, subprocess, sys

share = os.path.join(os.environ["RUN_DIR"], "share")
repo = os.getcwd()

def sha256(b):
    return hashlib.sha256(b).hexdigest()

# --- stale products must not fake a later run -------------------------------
for stale in ("RELEASE.IMG", "RELEASE.MF", "FLEET.MF", "BOOTIN.MF"):
    p = os.path.join(share, stale)
    if os.path.exists(p):
        os.remove(p)
        print("removed stale %s" % stale)
bd = os.path.join(share, "BUNDLE")
if os.path.isdir(bd):
    shutil.rmtree(bd)
    print("removed stale BUNDLE/")
# The fleet child's link step writes -o /host/BUNDLE/<name>.ELF and the
# host file channel does not create missing parents (open -> EINVAL), so
# the directory exists before run 01.
os.makedirs(bd)

# --- the drivers + the pinned fleet list ------------------------------------
need = {
    ".build/go/GORELEASE.ELF": "bash tools/go/build-gorelease.sh",
    ".build/go/GOBUILD.ELF":   "bash tools/go/build-gobuild.sh",
    ".build/go/GOCMDCOMPILE.ELF": "bash tools/go/build-gotool.sh",
    ".build/go/GOCMDLINK.ELF":    "bash tools/go/build-gotool.sh",
}
for src, how in need.items():
    if not os.path.exists(src):
        sys.exit("%s missing — %s" % (src, how))
    shutil.copy(src, os.path.join(share, os.path.basename(src)))
    print("staged %s (%d bytes)" % (os.path.basename(src), os.path.getsize(src)))
shutil.copy("user/go/gobuild/fleet.txt", os.path.join(share, "FLEET.TXT"))

# The archive tier + import config the in-guest toolchain resolves against.
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
print("staged %d selfhost inputs (%.2f MiB): import config + archives"
      % (n, total / 1048576.0))

# wm=none: no seat ever starts, so the fleet's toolchain children and the
# smoke execs never contend for EL0 task slots (same reason M112a's run
# stages it).
open(os.path.join(share, "SETTINGS.TXT"), "w").write("#v2\nwm=none\n")

# --- the sha-pinned host boot inputs (the card's non-goal: the kernel stays
# host-built) ---------------------------------------------------------------
pins = []
for name in ("BOOTAA64.EFI", "KERNEL.BIN"):
    src = os.path.join("zig-out", "bin", name)
    if not os.path.exists(src):
        sys.exit("%s missing — zig build installs it" % src)
    b = open(src, "rb").read()
    shutil.copy(src, os.path.join(share, name))
    pins.append("%s\tsha256=%s\tbytes=%d" % (name, sha256(b), len(b)))
    print("pinned %s sha256=%s bytes=%d" % (name, sha256(b), len(b)))
open(os.path.join(share, "BOOTIN.MF"), "w").write(
    "#v1 boot-input pins — the sha256 the staged bytes must match\n" +
    "\n".join(pins) + "\n")

# --- host-built reference ELFs -> REF/ (the FLEET.MF host= column) -----------
rows = []
for line in open("user/go/gobuild/fleet.txt"):
    line = line.strip()
    if line and not line.startswith("#"):
        name, src = line.split()
        rows.append((name, src))
if len(rows) != 19:
    sys.exit("fleet.txt pins %d rows, expected 19" % len(rows))
os.makedirs(os.path.join(share, "REF"), exist_ok=True)
n_ref = 0
for name, _ in rows:
    p = os.path.join(".build", "go", name)
    if os.path.exists(p):
        shutil.copy(p, os.path.join(share, "REF", name))
        n_ref += 1
print("staged %d host reference ELFs under REF/" % n_ref)

# --- the fleet source tree -> SRC/ (the M112a walker, verbatim) --------------
# virelai/<pkg> maps to user/go/<pkg>. Third-party module imports map to the
# pinned module-cache copies — the same pins the Charm apps' host builds
# declare (THIRD-PARTY.txt) — under their import path, minus the @version.
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
# in Go's unix GOOS set, so "unix"-tagged code is out. The walker must only
# follow imports of files this toolchain would compile.
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
# pair; unrecognised tokens constrain nothing.
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
# help}.sh): two bubbletea files are REPLACED and termenv/go-isatty get an
# additive virelai shim file. Same rules, same files.
OVERLAY = os.path.join("tools", "go", "overlay", "charm")
BUBBLE = "charm.land/bubbletea/v2"

queue = []
for name, src in rows:
    if src.startswith("external:"):
        continue
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

# Run 01: the guest builds the fleet, at exactly M112a's nesting depth —
# monitor -> GOBUILD -> toolchain children. (The one-shot `gorelease release`
# verb still drives it as a spawned child for standalone use, but the gate
# does not hold an extra Go runtime resident through ~250 exec'd children:
# the kernel has 16 task slots and the M112a fleet build is already the
# shape that rides that ceiling — observed here as `newosproc: sys_thread
# create failed` inside compile children when a parent process adds slot
# pressure.)
vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'fleet: fleet ' --timeout 5400

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOBUILD.ELF'
vgate_assert 01 serial-contains 'fleet: GOCALC.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: NOTE.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: GOEDIT.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: GOTERM.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: WEB.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: GOSH.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: GOTOP.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: GOSET.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: GODIFF.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: GOVIEW.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: GOSOUND.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: FLINT.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: AGENTD.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: GOBUILD.ELF built sha256='
# Named refusals (M112a semantics): GOFILES/PULSE/GOHELP need image/color,
# which has no staged archive; GOSTALGIA is an external-tree row. STORE.ELF
# builds via virelai/store/main — the fleet.txt row was pointed at
# the package dir under this card (#2414); assert the built row, not a refusal.
vgate_assert 01 serial-contains 'fleet: GOFILES.ELF refused dep_unsupported'
vgate_assert 01 serial-contains 'fleet: PULSE.ELF refused dep_unsupported'
vgate_assert 01 serial-contains 'fleet: GOHELP.ELF refused dep_unsupported'
vgate_assert 01 serial-contains 'fleet: GOSTALGIA.ELF refused external_tree'
vgate_assert 01 serial-contains 'fleet: STORE.ELF built sha256='
vgate_assert 01 serial-contains 'fleet: fleet OK built=15 refused=4'
vgate_assert 01 serial-absent 'fleet: fleet INCOMPLETE'
vgate_assert 01 serial-absent 'release: FAIL'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'
vgate_assert 01 serial-absent 'cannot allocate memory'

# Run 02: a fresh boot runs the assemble leg — pin-verify the host boot
# payload, check every built fleet row is bundled at its guest= sha256,
# stream the GPT+FAT32 image to the share through the publish-safe sink,
# and write RELEASE.MF (share root + inside the bundle).
vgate_run 02 -- --script '$RUN_DIR/script2.txt' --script-expect 'release: exit rc=' --timeout 1800

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'exec: loaded GORELEASE.ELF'
vgate_assert 02 serial-contains 'release: inputs BOOTAA64.EFI sha256='
vgate_assert 02 serial-contains 'release: inputs KERNEL.BIN sha256='
vgate_assert 02 serial-contains 'release: fleet built=15 refused=4'
vgate_assert 02 serial-contains 'release: bundle '
vgate_assert 02 serial-contains 'release: image RELEASE.IMG bytes='
vgate_assert 02 serial-contains 'release: manifest RELEASE.MF rows='
vgate_assert 02 serial-contains 'release: release OK'
vgate_assert 02 serial-absent 'release: FAIL'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 serial-absent 'cannot allocate memory'

# The image is a real GPT+FAT32 volume: the reference tool lists it, its
# members carry the pinned hashes, AND — because both builders are
# deterministic — the guest image is byte-identical to a reference built
# from the same inputs.
vgate_assert 02 python <<'PY'
import hashlib, os, subprocess, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
img = os.path.join(share, "RELEASE.IMG")
if not os.path.exists(img):
    sys.exit("FAIL: no RELEASE.IMG on the share")

def sha256(b):
    return hashlib.sha256(b).hexdigest()

listing = subprocess.run(["python3", "image/mkfat32.py", "--list", img],
                         capture_output=True, text=True)
print(listing.stdout)
if listing.returncode != 0:
    sys.exit("FAIL: mkfat32.py --list refused the guest-built image")
for want in ("KERNEL.BIN", "BOOTAA64.EFI"):
    if want not in listing.stdout:
        sys.exit("FAIL: image listing lacks " + want)

# The embedded members carry the pinned input hashes.
pins = {}
for line in open(os.path.join(share, "BOOTIN.MF")):
    line = line.strip()
    if line and not line.startswith("#"):
        f = line.split("\t")
        pins[f[0]] = f[1].split("=", 1)[1]
for member, pin_name in (("/EFI/BOOT/BOOTAA64.EFI", "BOOTAA64.EFI"),
                         ("/KERNEL.BIN", "KERNEL.BIN")):
    got = subprocess.run(["python3", "image/mkfat32.py", "--cat-file",
                          member, img], capture_output=True)
    if got.returncode != 0:
        sys.exit("FAIL: --cat-file %s refused" % member)
    if sha256(got.stdout) != pins[pin_name]:
        sys.exit("FAIL: image member %s sha256 != the pin" % member)
    print("image member %s sha256 matches the pin" % member)

# Byte-parity with the reference builder on the same inputs.
ref = os.path.join(os.environ["RUN_DIR"], "ref.img")
r = subprocess.run(["python3", "image/mkfat32.py", ref,
                    os.path.join(share, "BOOTAA64.EFI"),
                    os.path.join(share, "KERNEL.BIN")],
                   capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("FAIL: reference image build failed: " + r.stdout + r.stderr)
a = open(img, "rb").read()
b = open(ref, "rb").read()
if a != b:
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            sys.exit("FAIL: guest image differs from reference at byte %d" % i)
    sys.exit("FAIL: image sizes differ: guest=%d ref=%d" % (len(a), len(b)))
print("image is byte-identical to the reference build (%d bytes)" % len(a))
PY

# The manifest + the bundle: every row verifies against the share, every
# built FLEET.MF row is in the bundle at its guest= sha256, and the bundle
# carries what run 03 needs (driver, settings, apps manifest).
vgate_assert 02 python <<'PY'
import hashlib, os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
bundle = os.path.join(share, "BUNDLE")

def sha256_file(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()

mf = os.path.join(share, "RELEASE.MF")
if not os.path.exists(mf):
    sys.exit("FAIL: no RELEASE.MF on the share")
rows = {}
for line in open(mf):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    f = line.split("\t")
    row = dict(kv.split("=", 1) for kv in f[1:] if "=" in kv)
    rows[f[0]] = row
if "RELEASE.IMG" not in rows:
    sys.exit("FAIL: manifest lacks the image row")
if sha256_file(os.path.join(share, "RELEASE.IMG")) != rows["RELEASE.IMG"]["sha256"]:
    sys.exit("FAIL: RELEASE.IMG sha256 does not match the manifest")
print("manifest image row verified")

# The bundle copy must be the same manifest (run 03 reads it at /host).
bcopy = os.path.join(bundle, "RELEASE.MF")
if not os.path.exists(bcopy) or open(bcopy).read() != open(mf).read():
    sys.exit("FAIL: bundle RELEASE.MF missing or differs")

fleet = 0
for path, row in rows.items():
    if row["kind"] not in ("fleet", "driver", "asset", "config"):
        continue
    p = os.path.join(bundle, path)
    if not os.path.exists(p):
        sys.exit("FAIL: bundle lacks " + path)
    if sha256_file(p) != row["sha256"]:
        sys.exit("FAIL: bundle file " + path + " sha256 != manifest")
    if int(row["bytes"]) != os.path.getsize(p):
        sys.exit("FAIL: bundle file " + path + " bytes != manifest")
    if row["kind"] == "fleet":
        fleet += 1
print("manifest verified: %d bundle files, %d fleet" % (len(rows) - 3, fleet))

# Every built FLEET.MF row is bundled at the recorded guest sha.
fleets = {}
for line in open(os.path.join(share, "FLEET.MF")):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    f = line.split("\t")
    row = dict(kv.split("=", 1) for kv in f[2:] if "=" in kv)
    fleets[f[0]] = (f[1], row)
built = [n for n, (st, _) in fleets.items() if st == "built"]
for name in built:
    if name not in rows or rows[name].get("kind") != "fleet":
        sys.exit("FAIL: built fleet ELF %s not in the release manifest" % name)
    if rows[name]["sha256"] != fleets[name][1]["guest"]:
        sys.exit("FAIL: %s manifest sha != FLEET.MF guest=" % name)
print("all %d built fleet rows are bundled at their guest= sha256" % len(built))

st = open(os.path.join(bundle, "SETTINGS.TXT")).read()
if "wm=none" not in st:
    sys.exit("FAIL: bundle SETTINGS.TXT lacks wm=none")
if "GORELEASE.ELF" not in rows or rows["GORELEASE.ELF"]["kind"] != "driver":
    sys.exit("FAIL: bundle lacks the GORELEASE.ELF driver row")
PY

# Run 03: the host boots what the guest built — the image as the overlay
# base and the bundle as the armed share. The driver runs its smoke verb
# against the bundle's fleet rows: spawn, bounded wait, verdict per ELF.
vgate_run 03 -- --overlay-base '$RUN_DIR/share/RELEASE.IMG' --cvc-file '$RUN_DIR/share/BUNDLE' --script '$RUN_DIR/script3.txt' --script-expect 'release: exit rc=' --timeout 900

vgate_assert 03 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 03 serial-contains 'exec: loaded GORELEASE.ELF'
vgate_assert 03 serial-contains 'release: smoke GOCALC.ELF'
vgate_assert 03 serial-contains 'release: smoke GOSH.ELF'
vgate_assert 03 serial-contains 'release: smoke GOBUILD.ELF'
vgate_assert 03 serial-contains 'release: smoke AGENTD.ELF'
vgate_assert 03 serial-contains 'release: smoke OK ran='
vgate_assert 03 serial-absent 'release: FAIL'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 serial-absent 'exited status=139'
vgate_assert 03 serial-absent 'cannot allocate memory'
