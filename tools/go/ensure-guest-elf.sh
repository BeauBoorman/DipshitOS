#!/usr/bin/env bash
#
# ensure-guest-elf.sh -- freshness guard for hand-built guest Go ELFs
# (issue #1503). Class-B GOSH/GOSSHD specs used to copy .build/go/*.ELF
# iff the file existed, so a binary left over from another branch could
# false-red (wrong behaviour) or false-green (foreign binary satisfies
# the gate). This tool records a source+elf hash in a stamp next to the
# ELF and either rebuilds (ensure) or refuses (check).
#
# Usage:
#   bash tools/go/ensure-guest-elf.sh check     <APP>
#   bash tools/go/ensure-guest-elf.sh ensure    <APP>
#   bash tools/go/ensure-guest-elf.sh stamp     <APP> [elf-path]
#   bash tools/go/ensure-guest-elf.sh plan      <APP>...
#   bash tools/go/ensure-guest-elf.sh builder   <APP>
#   bash tools/go/ensure-guest-elf.sh needed-by <spec>
#   bash tools/go/ensure-guest-elf.sh hash      <APP>
#
# <APP> is an upper-case ELF base name (GOSH, GOSSHD, GOSSH, GOTABWM, ...).
# The builder resolves to tools/go/build-<lower>.sh with the historical
# exceptions GOSSHD->sshd, GOSSH->ssh, GOFILES->files, GOHELP->help.
#
# check:   fail closed with a named ensure-guest-elf error if missing/stale
#          (no rebuild — that is what vgate.sh calls before zig build / boot).
# ensure:  rebuild via the app's tools/go/build-*.sh when the stamp does
#          not match, then stamp. Hash-cached: a matching stamp is a no-op.
#          fleet.sh calls this once per invocation.
# stamp:   write the stamp for an ELF that was just built (build-*.sh).
# plan:    one "APP status builder-path" line per app — the bulk query
#          session.sh uses so a warm `just session` costs ONE hash pass,
#          not one process spawn per app. status is fresh|stale|missing,
#          or nobuilder when no builder script (or override) exists.
# builder: print the resolved builder path (convention, no existence check).
#
# Environment:
#   ENSURE_GUEST_ELF_ROOT         repo root (default: discovered)
#   ENSURE_GUEST_ELF_OUTDIR       ELF directory (default: $ROOT/.build/go)
#   ENSURE_GUEST_ELF_TOOLCHAIN    override the toolchain id mixed into the hash
#   ENSURE_GUEST_ELF_BUILD_<APP>  override the app's builder (tests)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ENSURE_GUEST_ELF_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
OUTDIR="${ENSURE_GUEST_ELF_OUTDIR:-$ROOT/.build/go}"

usage() {
    sed -n 's/^#   bash tools\/go\/ensure-guest-elf.sh //p' "$0" | head -7 >&2
    echo "ensure-guest-elf: usage: $1" >&2
    exit 2
}

python_helper() {
    python3 - "$ROOT" "$OUTDIR" "$@" <<'PY'
import hashlib, os, sys

ROOT, OUTDIR = sys.argv[1], sys.argv[2]
cmd = sys.argv[3]
args = sys.argv[4:]

# The tools/go/build-<name>.sh convention. The historical exceptions are
# named explicitly; everything else is the lower-cased app name.
SPECIAL_BUILDERS = {
    "GOSSHD": "sshd",
    "GOSSH": "ssh",
    "GOFILES": "files",
    "GOHELP": "help",
}

APP_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")


def die(msg, rc=1):
    sys.stderr.write(msg if msg.endswith("\n") else msg + "\n")
    sys.exit(rc)


def elf_name(app):
    return app + ".ELF"


def elf_path(app):
    return os.path.join(OUTDIR, elf_name(app))


def stamp_path(app):
    return os.path.join(OUTDIR, elf_name(app) + ".stamp")


def norm_app(app):
    # Callers speak either form: the manifest/ELF name (GOTABWM.ELF) or the
    # base name (GOTABWM). Everything below uses the base.
    return app[:-4] if app.endswith(".ELF") else app


def builder_rel(app):
    app = norm_app(app)
    if not app or any(c not in APP_CHARS for c in app):
        die("ensure-guest-elf: bad app name %r (want an upper-case ELF "
            "base name, e.g. GOSH)" % app, 2)
    return "tools/go/build-%s.sh" % SPECIAL_BUILDERS.get(app, app.lower())


_TOOLCHAIN = {"done": False, "id": ""}


def toolchain_id():
    # One `go version` probe per helper invocation: `plan` hashes every
    # session app in a single pass and must not spawn the fork 19 times.
    if _TOOLCHAIN["done"]:
        return _TOOLCHAIN["id"]
    _TOOLCHAIN["done"] = True
    env = os.environ.get("ENSURE_GUEST_ELF_TOOLCHAIN")
    if env is not None:
        _TOOLCHAIN["id"] = env
        return env
    fork = os.environ.get("GO_FORK_DIR") or os.path.join(os.path.dirname(ROOT), "go-virelai")
    go = os.path.join(fork, "bin", "go")
    if os.path.isfile(go) and os.access(go, os.X_OK):
        import subprocess
        try:
            out = subprocess.check_output([go, "version"], stderr=subprocess.DEVNULL, timeout=8)
            _TOOLCHAIN["id"] = out.decode("utf-8", "replace").strip()
        except (subprocess.SubprocessError, OSError):
            pass
    return _TOOLCHAIN["id"]


def iter_source_rels(app):
    rels = []
    base = os.path.join(ROOT, "user", "go")
    if os.path.isdir(base):
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(d for d in dirnames if d not in (".git", "__pycache__"))
            for name in sorted(filenames):
                if name in (".DS_Store",):
                    continue
                path = os.path.join(dirpath, name)
                rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
                rels.append(rel)
    extra = builder_rel(app)
    extra_path = os.path.join(ROOT, extra)
    if os.path.isfile(extra_path):
        rels.append(extra.replace(os.sep, "/"))
    # Stable unique order (the builder may also live under a walk we
    # do not currently perform).
    seen = set()
    ordered = []
    for rel in sorted(rels):
        if rel in seen:
            continue
        seen.add(rel)
        ordered.append(rel)
    return ordered


_DIGESTS = {}


def file_digest(path):
    # Every app's source set is the same user/go walk plus its builder, so
    # a multi-app `plan` re-reads the same files without this cache.
    if path in _DIGESTS:
        return _DIGESTS[path]
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    _DIGESTS[path] = h.hexdigest()
    return _DIGESTS[path]


def source_hash(app):
    h = hashlib.sha256()
    h.update(b"ensure-guest-elf-v1\n")
    h.update(("app=" + app + "\n").encode("utf-8"))
    h.update(("toolchain=" + toolchain_id() + "\n").encode("utf-8"))
    for rel in iter_source_rels(app):
        path = os.path.join(ROOT, rel.replace("/", os.sep))
        h.update(rel.encode("utf-8"))
        h.update(b"\0")
        if not os.path.isfile(path):
            h.update(b"missing")
        else:
            h.update(file_digest(path).encode("ascii"))
        h.update(b"\n")
    return h.hexdigest()


def read_stamp(app):
    path = stamp_path(app)
    if not os.path.isfile(path):
        return None
    data = open(path, "r", encoding="utf-8", errors="replace").read().splitlines()
    if not data or data[0].strip() != "v1":
        return {"source": "", "elf": ""}
    out = {"source": "", "elf": ""}
    for line in data[1:]:
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k in out:
            out[k] = v.strip()
    return out


def write_stamp(app, path=None):
    elf = path or elf_path(app)
    if not os.path.isfile(elf):
        die("ensure-guest-elf: cannot stamp %s: %s is missing" % (elf_name(app), elf))
    os.makedirs(os.path.dirname(stamp_path(app)) or ".", exist_ok=True)
    body = "v1\nsource=%s\nelf=%s\n" % (source_hash(app), file_digest(elf))
    with open(stamp_path(app), "w", encoding="utf-8") as f:
        f.write(body)


def inspect(app):
    want_src = source_hash(app)
    elf = elf_path(app)
    have_elf = os.path.isfile(elf)
    stamp = read_stamp(app)
    want_elf = file_digest(elf) if have_elf else ""
    have_src = stamp["source"] if stamp else ""
    have_elf_hash = stamp["elf"] if stamp else ""
    if not have_elf:
        status = "missing"
    elif stamp is None or have_src != want_src or have_elf_hash != want_elf:
        status = "stale"
    else:
        status = "fresh"
    return {
        "status": status,
        "app": app,
        "elf": elf,
        "want_src": want_src,
        "have_src": have_src or "(none)",
        "want_elf": want_elf or "(none)",
        "have_elf": have_elf_hash or "(none)",
        "builder": builder_rel(app),
    }


def named_error(info):
    app = info["app"]
    name = elf_name(app)
    if info["status"] == "missing":
        head = "ensure-guest-elf: %s missing" % name
    else:
        head = "ensure-guest-elf: %s stale" % name
    return (
        "%s\n"
        "  path: %s\n"
        "  want source-hash: %s\n"
        "  have source-hash: %s\n"
        "  want elf-sha256:  %s\n"
        "  have elf-sha256:  %s\n"
        "  this gate refuses to boot a binary the current tree did not produce\n"
        "  rebuild: bash %s\n"
        % (head, info["elf"], info["want_src"], info["have_src"],
           info["want_elf"], info["have_elf"], info["builder"])
    )


def spec_needs(text, app):
    elf = elf_name(app)
    if elf not in text:
        return False
    slash = ".build/go/" + elf
    join_lit = '".build", "go", "' + elf + '"'
    join_base = 'os.path.join(".build", "go"'
    return slash in text or join_lit in text or (
        join_base in text and ('"' + elf + '"') in text
    )


if cmd == "hash":
    app = norm_app(args[0]) if args else ""
    builder_rel(app)
    sys.stdout.write(source_hash(app) + "\n")
    sys.exit(0)

if cmd == "needed-by":
    if not args:
        die("ensure-guest-elf: needed-by <spec>", 2)
    path = args[0]
    try:
        text = open(path, "r", encoding="utf-8", errors="replace").read()
    except OSError as e:
        die("ensure-guest-elf: cannot read spec %s: %s" % (path, e), 2)
    for app in ("GOSH", "GOSSHD", "GOSSH", "GOUPD"):
        if spec_needs(text, app):
            sys.stdout.write(app + "\n")
    sys.exit(0)

if cmd == "builder":
    app = norm_app(args[0]) if args else ""
    sys.stdout.write(builder_rel(app) + "\n")
    sys.exit(0)

if cmd == "plan":
    if not args:
        die("ensure-guest-elf: plan <APP>...", 2)
    for app in (norm_app(a) for a in args):
        rel = builder_rel(app)
        has_builder = os.path.isfile(os.path.join(ROOT, rel)) or \
            bool(os.environ.get("ENSURE_GUEST_ELF_BUILD_" + app))
        status = inspect(app)["status"] if has_builder else "nobuilder"
        sys.stdout.write("%s %s %s\n" % (app, status, rel))
    sys.exit(0)

if cmd in ("inspect", "check", "stamp"):
    app = norm_app(args[0]) if args else ""
    builder_rel(app)
    if cmd == "stamp":
        write_stamp(app, args[1] if len(args) > 1 else None)
        sys.exit(0)
    info = inspect(app)
    if cmd == "inspect":
        sys.stdout.write("%(status)s %(app)s %(want_src)s\n" % info)
        if info["status"] != "fresh":
            sys.stderr.write(named_error(info))
            sys.exit(1)
        sys.exit(0)
    # check
    if info["status"] == "fresh":
        sys.stdout.write("ensure-guest-elf: %s.ELF fresh (source-hash %s)\n"
                         % (info["app"], info["want_src"]))
        sys.exit(0)
    sys.stderr.write(named_error(info))
    sys.exit(1)

die("ensure-guest-elf: unknown helper command %s" % cmd, 2)
PY
}

require_app() {
    # The .ELF suffix is accepted and stripped — callers speak either form.
    case "${1%.ELF}" in
        ""|*[!A-Z0-9_]*|*.*) usage "check|ensure|stamp|builder <APP> — an upper-case ELF base name (GOSH, GOSSHD, GOTABWM, ...)" ;;
    esac
}

run_builder() {
    local app="$1" var="ENSURE_GUEST_ELF_BUILD_$1" script
    if [ -n "${!var:-}" ]; then
        bash -c "${!var}"
        return
    fi
    script="$(python_helper builder "$app")"
    if [ ! -f "$ROOT/$script" ]; then
        echo "ensure-guest-elf: no builder for $app — $script is missing" >&2
        return 1
    fi
    bash "$ROOT/$script"
}

[ $# -ge 1 ] || usage "check|ensure|stamp|plan|builder|needed-by|hash ..."
cmd="$1"; shift

case "$cmd" in
    needed-by)
        [ $# -eq 1 ] || usage "needed-by <spec>"
        python_helper needed-by "$1"
        ;;
    hash)
        require_app "${1:-}"
        python_helper hash "$1"
        ;;
    check)
        require_app "${1:-}"
        python_helper check "$1"
        ;;
    stamp)
        require_app "${1:-}"
        python_helper stamp "$1" "${2:-}"
        ;;
    plan)
        [ $# -ge 1 ] || usage "plan <APP>..."
        python_helper plan "$@"
        ;;
    builder)
        require_app "${1:-}"
        python_helper builder "$1"
        ;;
    ensure)
        require_app "${1:-}"
        # Fresh: check prints the cache-hit line and we are done. Stale or
        # missing: check prints the named ensure-guest-elf error, then we
        # rebuild, stamp, and re-check (a builder that writes the wrong
        # bytes still fails closed).
        if python_helper check "$1"; then
            exit 0
        fi
        echo "ensure-guest-elf: rebuilding $1.ELF"
        run_builder "$1"
        python_helper stamp "$1"
        python_helper check "$1"
        ;;
    *) usage "check|ensure|stamp|builder <APP> | plan <APP>... | needed-by <spec> | hash <APP>" ;;
esac
