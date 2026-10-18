#!/usr/bin/env python3
"""Pinned, offline-by-default native SDK. Only `fetch` accesses the network."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = Path(__file__).with_name("lock.json")
LOCK = json.loads(LOCK_PATH.read_text())
DEFAULT_CACHE = ROOT / ".build/zig-guest"
STACK_BUDGET = 128 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def host():
    cpu = {"arm64": "aarch64", "AMD64": "x86_64"}.get(platform.machine(), platform.machine())
    system = {"Darwin": "macos", "Linux": "linux"}.get(platform.system(), platform.system())
    key = f"{cpu}-{system}"
    if key not in LOCK["archives"]:
        raise ValueError(f"no pinned compiler archive for host {key}")
    return key


def archive_path(cache):
    return cache / Path(LOCK["archives"][host()]["url"]).name


def fetch(cache):
    pin = LOCK["archives"][host()]
    archive = archive_path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    if archive.exists():
        if digest(archive.read_bytes()) != pin["sha256"]:
            raise ValueError(f"archive checksum mismatch: {archive}")
        return archive
    with urllib.request.urlopen(pin["url"], timeout=60) as response:
        data = response.read(100 * 1024 * 1024)
    if digest(data) != pin["sha256"]:
        raise ValueError("download checksum mismatch")
    # Refuse to overwrite a concurrently supplied archive.
    with archive.open("xb") as output:
        output.write(data)
    return archive


def prepare(cache):
    archive = archive_path(cache)
    pin = LOCK["archives"][host()]
    if not archive.is_file():
        raise ValueError(f"missing pinned archive; run: python3 tools/zig/sdk.py fetch --cache {cache}")
    if digest(archive.read_bytes()) != pin["sha256"]:
        raise ValueError(f"archive checksum mismatch: {archive}")
    overlay = load_overlay()
    destination = cache / (pin["sha256"] + "-" + LOCK["overlay_sha256"])
    exists = destination.exists()
    stage = destination if exists else Path(tempfile.mkdtemp(prefix="materialize-", dir=cache))
    manifest = {}
    try:
        with tarfile.open(archive, "r:xz") as source:
            for member in source:
                relative = Path(*Path(member.name).parts[1:])
                if not relative.parts:
                    continue
                if relative.is_absolute() or ".." in relative.parts or not (member.isdir() or member.isfile()):
                    raise ValueError(f"unsupported archive member: {member.name}")
                output = stage / relative
                if member.isdir():
                    if not exists:
                        output.mkdir(parents=True, exist_ok=True)
                    continue
                data = source.extractfile(member).read()
                if relative.as_posix() in overlay:
                    patch = overlay[relative.as_posix()]
                    if digest(data) != patch["original_sha256"]:
                        raise ValueError(f"overlay original checksum mismatch: {relative}")
                    text = data.decode()
                    for edit in patch["edits"]:
                        if text.count(edit["before"]) != 1:
                            raise ValueError(f"overlay anchor not unique: {relative}")
                        text = text.replace(edit["before"], edit["after"], 1)
                    data = text.encode()
                manifest[relative.as_posix()] = digest(data)
                if exists:
                    if output.is_symlink() or not output.is_file() or digest(output.read_bytes()) != digest(data):
                        raise ValueError(f"materialized compiler/library drift: {relative}")
                else:
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_bytes(data)
                    output.chmod(member.mode & 0o755)
        # Additional files in the std tree can alter imports, too. Finder
        # metadata (.DS_Store, ._AppleDouble) cannot, and on a shared
        # workstation it lands unbidden mid-build.
        actual = {p.relative_to(stage).as_posix() for p in stage.rglob("*")
                  if (p.is_file() or p.is_symlink()) and not p.name.startswith(".DS_Store")
                  and not p.name.startswith("._")}
        if actual != set(manifest):
            raise ValueError("materialized compiler/library has additional files")
        if not set(overlay) <= set(manifest):
            raise ValueError("overlay targets absent from compiler archive")
        if not exists:
            stage.rename(destination)
    finally:
        if not exists and stage.exists():
            shutil.rmtree(stage)  # Only the temporary tree created by this call.
    lib_hash = digest("".join(f"{p}\0{h}\n" for p, h in sorted(manifest.items()) if p.startswith("lib/")).encode())
    return destination, {
        "compiler_archive_sha256": pin["sha256"],
        "compiler_sha256": manifest["zig"],
        "stdlib_tree_sha256": lib_hash,
        "overlay_sha256": LOCK["overlay_sha256"],
    }


def load_overlay():
    if LOCK["dependencies"]:
        raise ValueError("the SDK has no external dependencies")
    patches = LOCK["patches"]
    if not patches:
        if LOCK["overlay_sha256"] != digest(b""):
            raise ValueError("empty overlay checksum mismatch")
        return {}
    if patches != ["tools/zig/overlay.json"]:
        raise ValueError("unreviewed overlay manifest")
    data = (ROOT / patches[0]).read_bytes()
    if digest(data) != LOCK["overlay_sha256"]:
        raise ValueError("overlay checksum mismatch")
    overlay = json.loads(data)
    if any(not name.startswith("lib/std/") or ".." in Path(name).parts for name in overlay):
        raise ValueError("overlay must remain inside the private stdlib")
    return overlay


def stack_frames(assembly):
    """Conservative per-function frame check, NOT a recursive call-depth proof."""
    frames = {}
    name = None
    for line in assembly.splitlines():
        line = line.strip()
        match = re.fullmatch(r"\.type\s+(.+),@function", line)
        if match:
            name = match[1]
            frames[name] = 0
        if line.startswith(".size"):
            name = None
        if name is None:
            continue
        match = re.fullmatch(r"sub\s+sp, sp, #(\d+)(?:, lsl #(\d+))?", line)
        if match:
            frames[name] += int(match[1]) << int(match[2] or 0)
        elif re.search(r"\[sp, #-(\d+)\]!", line):
            frames[name] += int(re.search(r"\[sp, #-(\d+)\]!", line)[1])
        elif re.match(r"\w+\s+sp,", line) and not re.fullmatch(r"add\s+sp, sp, #\d+(?:, lsl #\d+)?", line):
            raise ValueError(f"unreviewed stack adjustment in {name}: {line}")
    if not frames or max(frames.values()) > STACK_BUDGET:
        raise ValueError("StackBudget: missing frames or oversized compiler frame")
    return frames


def build(cache, output, work):
    compiler, provenance = prepare(cache)
    work.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for key in tuple(env):
        if key.startswith(("ZIG_", "NIX_")) or key in ("LIBRARY_PATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH"):
            del env[key]
    command = [
        str(compiler / "zig"), "build-exe", "user/zig/fixture.zig",
        "--zig-lib-dir", str(compiler / "lib"),
        "--cache-dir", str(work / "local"), "--global-cache-dir", str(work / "global"),
        "-target", LOCK["target"], "-mcpu", LOCK["cpu"], "-O", LOCK["optimize"],
        "-fsingle-threaded", "-fstrip", "-fno-PIE", "-fno-unwind-tables", "-fno-stack-check",
        "-fno-stack-protector", "-fentry=_start", f"-femit-asm={work / 'fixture.s'}",
        "-T", "tools/zig/guest.ld", f"-femit-bin={output}",
    ]
    result = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
    (work / "compiler.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise ValueError(f"guest compile failed:\n{result.stdout}{result.stderr}")
    frames = stack_frames((work / "fixture.s").read_text())
    (work / "stack-frames.json").write_text(json.dumps(frames, sort_keys=True, indent=2) + "\n")
    subprocess.run(["python3", str(ROOT / "tools/check-zc-host-contract.py"), "--profile", "sdk", str(output)], check=True)
    inputs = [LOCK_PATH, Path(__file__), *(ROOT / p for p in LOCK["patches"]), ROOT / "tools/zig/guest.ld",
              ROOT / "tools/check-zc-host-contract.py", *sorted((ROOT / "user/zig").glob("*.zig"))]
    provenance.update({
        "target": LOCK["target"], "cpu": LOCK["cpu"], "optimize": LOCK["optimize"],
        "source_sha256": {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in inputs},
        "artifact_sha256": digest(output.read_bytes()),
        "maximum_compiler_frame_bytes": max(frames.values()),
    })
    output.with_suffix(output.suffix + ".json").write_text(json.dumps(provenance, sort_keys=True, indent=2) + "\n")
    print(f"zig-guest: {output} sha256={provenance['artifact_sha256']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("fetch", "prepare", "build"))
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--output", type=Path, default=DEFAULT_CACHE / "ZGUEST.BIN")
    parser.add_argument("--work", type=Path, default=DEFAULT_CACHE / "compile")
    args = parser.parse_args()
    try:
        if args.command == "fetch":
            print(fetch(args.cache.resolve()))
        elif args.command == "prepare":
            print(prepare(args.cache.resolve())[0])
        else:
            build(args.cache.resolve(), args.output.resolve(), args.work.resolve())
    except (ValueError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        parser.exit(1, f"zig-guest: {error}\n")


if __name__ == "__main__":
    main()
