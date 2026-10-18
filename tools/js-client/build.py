#!/usr/bin/env python3
"""Offline QJS.BIN product link using the unchanged SDK and M88b runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tools/quickjs-runtime"))
import build as runtime_build
import inspection

sdk = runtime_build.sdk


def sha(data):
    return hashlib.sha256(data).hexdigest()


def build(work, cache, baseline=False, fixture=None):
    work.mkdir(parents=True, exist_ok=True)
    inputs = [ROOT / "user/src/quickjs.zig", HERE / "policy.zig", HERE / "hooks.zig", Path(__file__),
              ROOT / "tools/zig/guest.ld", ROOT / "user/zig/quickjs/lock.json"]
    if fixture:
        inputs.append(HERE / (fixture + ".zig"))
    hashes = {p.relative_to(ROOT).as_posix(): sha(p.read_bytes()) for p in inputs}
    objects = None if baseline or fixture == "launcher" else runtime_build.objects(work / "c", cache)
    compiler, library, provenance = runtime_build.prepare_runtime(cache, work)
    copy = work / "sdk"
    copy.mkdir(exist_ok=True)
    for p in (ROOT / "user/zig").glob("*.zig"):
        shutil.copyfile(p, copy / p.name)
    (copy / "module.zig").write_text('pub const runtime = @import("runtime.zig");\npub const entry = @import("entry.zig");\n')
    (work / "options.zig").write_text("pub const engine = " + str(not baseline).lower() + ";\n")
    artifact = work / ("BASELINE.BIN" if baseline else {"launcher": "QLAUNCH.BIN", "bounds": "QBOUNDS.BIN"}.get(fixture, "QJS.BIN"))
    flags = ["-target", sdk.LOCK["target"], "-mcpu", sdk.LOCK["cpu"] + "+reserve_x18",
             "-O", "ReleaseSafe", "-fsingle-threaded", "-fno-PIE", "-fno-unwind-tables",
             "-fno-stack-check", "-fno-stack-protector"]
    root = HERE / (fixture + ".zig") if fixture else ROOT / "user/src/quickjs.zig"
    command = [str(compiler / "zig"), "build-exe", "--zig-lib-dir", str(library),
               *([str(p) for p in sorted(objects.glob("*.o"))] if objects else []),
               "-fstrip", "-fentry=_start", "-T", str(ROOT / "tools/zig/guest.ld"),
               "-femit-bin=" + str(artifact), "-femit-asm=" + str(work / "product.s"),
               "--dep", "sdk", "--dep", "qjs", "--dep", "product_policy", "--dep", "build_options", *flags,
               "-Mroot=" + str(root),
               "--dep", "arena", "--dep", "hooks", *flags, "-Mqjs=" + str(ROOT / "user/zig/quickjs/runtime.zig"),
               "--dep", "sdk", *flags, "-Marena=" + str(ROOT / "user/zig/quickjs/arena_alias.zig"),
               "--dep", "sdk", *flags, "-Mhooks=" + str(HERE / "hooks.zig"),
               *flags, "-Msdk=" + str(copy / "module.zig"),
               *flags, "-Mproduct_policy=" + str(HERE / "policy.zig"),
               *flags, "-Mbuild_options=" + str(work / "options.zig")]
    env = runtime_build.environment()
    env["ZIG_LOCAL_CACHE_DIR"] = str(work / "cache/local")
    env["ZIG_GLOBAL_CACHE_DIR"] = str(work / "cache/global")
    result = subprocess.run(command, cwd=work, env=env, capture_output=True, text=True)
    (work / "build.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise ValueError("ProductLinkFailed:\n" + result.stderr)
    assembly = (work / "product.s").read_text()
    if re.search(r"(?m)^\s*[A-Za-z][^\n]*\b[wx]18\b", assembly):
        raise ValueError("ReservedX18")
    frames = sdk.stack_frames(assembly)
    rt = [inspection.compiler_rt_object(p, assembly, sorted(objects.glob("*.o")) if objects else [])
          for p in sorted((work / "cache/global").glob("o/*/*compiler_rt_zcu.o"))]
    if not rt:
        raise ValueError("MissingCompilerRtInspection")
    (work / "compiler-rt.json").write_text(json.dumps(rt, sort_keys=True, indent=2) + "\n")
    (work / "stack-frames.json").write_text(json.dumps(frames, sort_keys=True, indent=2) + "\n")
    image = inspection.elf(artifact)
    subprocess.run([sys.executable, str(ROOT / "tools/check-zc-host-contract.py"),
                    "--profile", "sdk", str(artifact)], check=True)
    if hashes != {p.relative_to(ROOT).as_posix(): sha(p.read_bytes()) for p in inputs}:
        raise ValueError("BuildInputChanged")
    provenance.update(inputs_sha256=hashes, artifact_sha256=sha(artifact.read_bytes()), artifact=image,
                      flags=flags, strip=True, linker_script="tools/zig/guest.ld", entry="_start",
                      maximum_zig_frame_bytes=max(frames.values()), scope="offline product link, not guest acceptance")
    artifact.with_suffix(".BIN.json").write_text(json.dumps(provenance, sort_keys=True, indent=2) + "\n")
    return artifact


def verify(work, cache):
    if work.exists():
        raise ValueError("FreshWorkRequired")
    compiler, _ = runtime_build.prepare(cache)
    work.mkdir(parents=True)
    subprocess.run([str(compiler / "zig"), "test", str(HERE / "policy.zig"), "-O", "ReleaseSafe"], check=True)
    a = build(work / "a", cache)
    b = build(work / "b", cache)
    empty = build(work / "baseline", cache, baseline=True)
    if a.read_bytes() != b.read_bytes() or a.with_suffix(".BIN.json").read_bytes() != b.with_suffix(".BIN.json").read_bytes():
        raise ValueError("ProductReproducibility")
    full, base = inspection.elf(a), inspection.elf(empty)
    delta = full["file_bytes"] - base["file_bytes"]
    load_delta = sum(p["filesz"] for p in full["segments"]) - sum(p["filesz"] for p in base["segments"])
    if max(delta, load_delta) > 1_572_864:
        raise ValueError("EngineSizeLimit")
    # Current kernel parser, not only the narrower SDK checker.
    cases = work / "kernel"
    cases.mkdir()
    (cases / "product.elf").write_bytes(a.read_bytes())
    (cases / "cases.zig").write_text('pub const fixtures = [_]struct {name: []const u8, bytes: []const u8, accepted: bool}{\n'
                                   '.{.name="QJS.BIN",.bytes=@embedFile("product.elf"),.accepted=true},\n};\n')
    subprocess.run([str(compiler / "zig"), "test", "--dep", "elf", "--dep", "cases",
                    "-Mroot=" + str(ROOT / "tools/zig/kernel_contract.zig"),
                    "-Melf=" + str(ROOT / "kernel/src/elf.zig"), "-Mcases=" + str(cases / "cases.zig")], check=True)
    report = {"reproducible": True, "file_delta": delta, "initialized_delta": load_delta,
              "artifact_sha256": sha(a.read_bytes()), "baseline_sha256": sha(empty.read_bytes()),
              "image": full, "platform_inventory": inspection.imports(sorted((a.parent / "c/objects").glob("*.o")))}
    (work / "verification.json").write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
    return a


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "verify", "baseline", "launcher", "bounds"))
    parser.add_argument("--work", type=Path, default=ROOT / ".build/js-client/product")
    parser.add_argument("--cache", type=Path, default=sdk.DEFAULT_CACHE)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "verify":
            artifact = verify(args.work.resolve(), args.cache.resolve())
        else:
            artifact = build(args.work.resolve(), args.cache.resolve(), args.command == "baseline",
                             args.command if args.command in ("launcher", "bounds") else None)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(artifact, args.output)
            shutil.copyfile(artifact.with_suffix(".BIN.json"), args.output.with_suffix(".BIN.json"))
        print(artifact)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"js-client: {error}\n")


if __name__ == "__main__":
    main()
