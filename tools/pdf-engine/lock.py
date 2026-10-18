"""Provisioning is separate. Build checks, never acquires or repairs inputs."""
import hashlib
import json
import subprocess
import sys
from pathlib import Path


def tree(path, predicate=lambda p: True):
    h = hashlib.sha256()
    for p in sorted(path.rglob("*")):
        if p.is_file() and predicate(p):
            h.update(p.relative_to(path).as_posix().encode()+b"\0")
            h.update(hashlib.sha256(p.read_bytes()).digest())
    return h.hexdigest()


def snapshot(root, fork):
    if not (fork/"bin/go").is_file():
        raise ValueError("MissingToolchain")
    version = subprocess.check_output([str(fork/"bin/go"), "version"], text=True).strip()
    if version != "go version go1.27.2 darwin/arm64":
        raise ValueError("SourceDrift: compiler identity")
    for p in (root/"tools/go/overlay").rglob("*"):
        rel = p.relative_to(root/"tools/go/overlay")
        # gostalgia/ and gostalgia-mods/ are build-gostalgia stage overlays —
        # apply.sh deliberately does NOT copy them into the fork's src/.
        if rel.parts and rel.parts[0] in ("gostalgia", "gostalgia-mods"):
            continue
        if p.is_file() and p.read_bytes() != (fork/"src"/rel).read_bytes():
            raise ValueError("SourceDrift: overlay")
    return {
        "version": 1, "compiler": version,
        "fork_revision": subprocess.check_output(["git", "-C", str(fork), "rev-parse", "HEAD"], text=True).strip(),
        "compiler_sha256": hashlib.sha256((fork/"bin/go").read_bytes()).hexdigest(),
        "tool_sha256": {name: hashlib.sha256((fork/"pkg/tool/darwin_arm64"/name).read_bytes()).hexdigest()
                       for name in ("compile", "link", "asm")},
        "fork_source_sha256": tree(fork/"src"),
        "overlay_sha256": tree(root/"tools/go/overlay"),
        "guest_source_sha256": {name: tree(root/name, lambda p: p.suffix in (".go", ".s") and not p.name.endswith("_test.go"))
                                for name in ("user/go/pdf", "user/go/vector", "user/go/vi", "user/go/vsys")},
        "adapter_and_build_sha256": {
            name: hashlib.sha256((root/"tools/pdf-engine"/name).read_bytes()).hexdigest()
            for name in ("adapter.go", "full.go", "empty.go", "build.sh", "elf.py", "runtime_ledger.py")
        },
        "flags": ["GOOS=virelai", "GOARCH=arm64", "CGO_ENABLED=0", "GOTOOLCHAIN=local",
                  "GOPROXY=off", "GOSUMDB=off", "-trimpath", "-ldflags=-s -w"],
        "new_third_party_guest_dependencies": [],
    }


if __name__ == "__main__":
    root, fork, lock = map(Path, sys.argv[2:5])
    actual = snapshot(root, fork)
    if sys.argv[1] == "record":
        lock.write_text(json.dumps(actual, indent=2)+"\n")
    elif json.loads(lock.read_text()) != actual:
        raise ValueError("SourceDrift: engine lock")
    else:
        print("pdf-engine: lock verified")
