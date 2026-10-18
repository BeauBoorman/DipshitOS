#!/usr/bin/env bash
# Existing Go 1.27.1 fork and stdlib only (BSD-3-Clause). Keep target .symtab:
# PROF symbolizes the exact guest compiler and fixture images, not host twins.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FORK_DIR="${GO_FORK_DIR:-$(dirname "$REPO")/go-virelai}"
[ -x "$FORK_DIR/bin/go" ] || {
    echo "build-prof: missing provisioned GOOS=virelai fork" >&2
    exit 1
}
GOPATH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virelai-prof-gopath.XXXXXX")"
trap 'rm -rf "$GOPATH_DIR"' EXIT
mkdir -p "$GOPATH_DIR/src" "$REPO/.build/go"
ln -s "$REPO/user/go" "$GOPATH_DIR/src/virelai"
export GOROOT="$FORK_DIR" PATH="$FORK_DIR/bin:$PATH" GOTOOLCHAIN=local
export GO111MODULE=off GOFLAGS= GOPATH="$GOPATH_DIR" CGO_ENABLED=0
for pair in prof/cmd:PROF proffixture:PROFFIX; do
    dir="${pair%:*}" name="${pair#*:}"
    GOOS=virelai GOARCH=arm64 go build -o "$REPO/.build/go/$name.ELF" \
        -ldflags "-w" "virelai/$dir"
done
python3 - "$FORK_DIR" "$GOPATH_DIR" <<'PY'
import json, pathlib, sys
fork, temp = map(pathlib.Path, sys.argv[1:])
checks_source = fork / "src/cmd/compile/internal/ssa/compile.go"
checks = checks_source.read_text()
assert checks.count("checkFunc(f)") == 2, "SourceDrift: SSA check call sites"
# A declared, separately named sampling fixture, not a normal compiler timing:
# repeat the existing read-only invariant check on the SAME pinned hello.
# No fake symbols, no inserted sleep/spin, no changed compiler output.
checks = checks.replace("checkFunc(f)",
    "for virelaiProfileCheck := 0; virelaiProfileCheck < 256; virelaiProfileCheck++ { checkFunc(f) }")
checks_overlay = temp / "ssa-checks.go"
checks_overlay.write_text(checks)
(temp / "overlay.json").write_text(json.dumps({"Replace": {
    str(checks_source): str(checks_overlay)}}))
PY
GOOS=virelai GOARCH=arm64 go build -tags virelaitoolchain \
    -overlay "$GOPATH_DIR/overlay.json" \
    -gcflags "cmd/compile/internal/ssa=-N -l" \
    -ldflags "-w" -o "$REPO/.build/go/GOCMDPROFILE.ELF" cmd/compile
python3 - "$REPO" <<'PY'
import os, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "tools/lib"))
import elf_rules
for name in ("PROF", "PROFFIX", "GOCMDPROFILE"):
    path = os.path.join(root, ".build/go", name + ".ELF")
    receipt, errors = elf_rules.check_file(path, name + ".ELF")
    print("build-prof: " + receipt)
    if errors:
        sys.exit("\n".join(errors))
PY
