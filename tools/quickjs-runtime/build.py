#!/usr/bin/env python3
"""Offline native C objects for ADR 0039; no root build or SDK changes."""
import argparse
import importlib.util
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
from materialize import INPUT, LOCK, materialize, sha
from safety import instrument
import math_library

inspect_spec = importlib.util.spec_from_file_location("quickjs_inspection", HERE / "inspection.py")
inspection = importlib.util.module_from_spec(inspect_spec)
inspect_spec.loader.exec_module(inspection)

spec = importlib.util.spec_from_file_location("sdk", ROOT / "tools/zig/sdk.py")
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)

C_FLAGS = [
    "-target", "aarch64-freestanding-none", "-mcpu=generic+reserve_x18", "-std=c11", "-Os",
    "-ffreestanding", "-fno-builtin", "-fwrapv", "-funsigned-char",
    "-fno-stack-protector", "-fno-pic", "-fno-pie", "-fno-unwind-tables",
    "-ffixed-x18", "-ffunction-sections", "-fdata-sections", "-fno-lto",
    "-nostdinc", '-DCONFIG_VERSION="2026-06-04"',
]


def environment():
    return {k: v for k, v in os.environ.items()
            if not k.startswith(("ZIG_", "NIX_"))
            and k not in ("LIBRARY_PATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "CPATH", "SDKROOT")}


def prepare(cache):
    if sha((ROOT / "tools/zig/lock.json").read_bytes()) != LOCK["sdk"]["lock_sha256"]:
        raise ValueError("SourceDrift: SDK lock")
    if sdk.LOCK["archives"] != LOCK["sdk"]["compiler_archives"]:
        raise ValueError("SourceDrift: compiler archives")
    if sdk.LOCK["overlay_sha256"] != LOCK["sdk"]["overlay_sha256"]:
        raise ValueError("SourceDrift: SDK overlay")
    for name, digest in LOCK["sdk"]["sources"].items():
        if sha((ROOT / name).read_bytes()) != digest:
            raise ValueError("SourceDrift: SDK input " + name)
    return sdk.prepare(cache)


def prepare_runtime(cache, work):
    """Product builders must use this private --zig-lib-dir, not the SDK copy."""
    compiler, provenance = prepare(cache)
    library, math_receipt = math_library.prepare(compiler, work)
    provenance["math_poll_overlay"] = math_receipt
    return compiler, library, provenance


def objects(work, cache, hosted=False):
    compiler, receipt = prepare(cache)
    source = materialize(work)
    inputs = [
        INPUT / "lock.json", INPUT / "upstream.sha256",
        *(ROOT / name for name in sorted(LOCK["private_inputs"])),
        *(ROOT / name for name in sorted(LOCK["patches"])),
        *(ROOT / name for name in sorted(LOCK["sdk"]["sources"])),
    ]
    hashes = {p.relative_to(ROOT).as_posix(): sha(p.read_bytes()) for p in inputs}
    output = work / "objects"
    output.mkdir(parents=True, exist_ok=True)
    core_names = LOCK["translation_units"]
    if core_names != ["quickjs.c", "dtoa.c", "libregexp.c", "libunicode.c", "cutils.c"]:
        raise ValueError("UnexpectedTranslationUnit")
    if LOCK["bridge_units"] != ["bytes.c", "format.c", "guard.c", "binding.c", "guard.S"]:
        raise ValueError("UnexpectedBridgeUnit")
    units = [(name, source / name) for name in core_names]
    units += [(name, INPUT / name) for name in LOCK["bridge_units"]]
    env = environment()
    env["ZIG_LOCAL_CACHE_DIR"] = str(work / "cache/local")
    env["ZIG_GLOBAL_CACHE_DIR"] = str(work / "cache/global")
    flags = list(C_FLAGS)
    if hosted:
        flags[flags.index("aarch64-freestanding-none")] = "aarch64-macos"
        flags = [flag for flag in flags if flag not in ("-fno-pic", "-fno-pie")]
        flags += ["-D" + name + "=qjs_host_" + name for name in
                  ("malloc", "free", "realloc", "malloc_usable_size")]
    includes = ["-I", str(INPUT / "headers"), "-I", str(source),
                "-isystem", str(compiler / "lib/include")]
    coverage = []
    frames = {}
    assembly = work / "assembly"
    if not hosted:
        assembly.mkdir(exist_ok=True)
    for name in core_names:
        coverage.append(instrument(compiler, source / name, flags + includes, env, work / (name + ".ast.log")))
    for name, input_path in units:
        command = [
            str(compiler / "zig"), "cc", *flags, *includes,
            "-fdebug-prefix-map=" + str(ROOT) + "=.",
            "-fstack-usage",
            "-c", str(input_path), "-o", str(output / (name + ".o")),
        ]
        result = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
        (work / (name + ".compiler.log")).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise ValueError("NativeCompileFailed: " + name + "\n" + result.stderr)
        if not hosted and name != "guard.S":
            command[-4:] = ["-S", str(input_path), "-o", str(assembly / (name + ".s"))]
            result = subprocess.run(command, cwd=work, env=env, text=True, capture_output=True)
            if result.returncode:
                raise ValueError("CFrameCompileFailed: " + name + "\n" + result.stderr)
            frames[name] = inspection.c_frames((assembly / (name + ".s")).read_text())
    receipt.update({
        "c_flags": flags,
        "inputs_sha256": hashes,
        "patched_source_sha256": {name: sha(path.read_bytes()) for name, path in units},
        "objects_sha256": {name + ".o": sha((output / (name + ".o")).read_bytes()) for name, _ in units},
        "target": "aarch64-freestanding-none",
        "scope": "C object compilation, not a native linked runtime or guest execution",
        "safety_coverage": coverage,
        "c_frames": frames,
    })
    if not hosted:
        receipt["platform_inventory"] = inspection.imports(sorted(output.glob("*.o")))
    if hashes != {p.relative_to(ROOT).as_posix(): sha(p.read_bytes()) for p in inputs}:
        raise ValueError("BuildInputChanged")
    (work / "objects.receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return output


def linked(work, cache, hosted=False, baseline=False):
    work.mkdir(parents=True, exist_ok=True)
    inputs = [INPUT / "lock.json", INPUT / "upstream.sha256",
              *(ROOT / name for name in sorted(LOCK["private_inputs"])),
              *(ROOT / name for name in sorted(LOCK["sdk"]["sources"]))]
    hashes = {path.relative_to(ROOT).as_posix(): sha(path.read_bytes()) for path in inputs}
    output = None if baseline else objects(work / "c", cache, hosted)
    if baseline:
        materialize(work / "inputs")
    compiler, library, provenance = prepare_runtime(cache, work)
    env = environment()
    env["ZIG_LOCAL_CACHE_DIR"] = str(work / "cache/local")
    env["ZIG_GLOBAL_CACHE_DIR"] = str(work / "cache/global")
    flags = ["-target", "aarch64-macos" if hosted else sdk.LOCK["target"],
             "-mcpu", sdk.LOCK["cpu"] + "+reserve_x18",
             "-O", "ReleaseSafe", "-fsingle-threaded", "-fno-PIE",
             "-fno-unwind-tables", "-fno-stack-check", "-fno-stack-protector"]
    if hosted:
        flags.remove("-fno-PIE")
    command = [str(compiler / "zig"), "test" if hosted else "build-exe",
               "--zig-lib-dir", str(library)]
    if output:
        command += [str(path) for path in sorted(output.glob("*.o"))]
    if hosted:
        command += ["-lc", "--dep", "qjs", "--dep", "arena", *flags,
                    "-Mroot=" + str(INPUT / "host_fixture.zig"),
                    "--dep", "arena", "--dep", "hooks", *flags, "-Mqjs=" + str(INPUT / "runtime.zig"),
                    *flags, "-Marena=" + str(ROOT / "user/zig/arena.zig"),
                    *flags, "-Mhooks=" + str(INPUT / "host_hooks.zig")]
        artifact = None
    else:
        sdk_copy = work / "sdk"
        sdk_copy.mkdir(exist_ok=True)
        for path in (ROOT / "user/zig").glob("*.zig"):
            shutil.copyfile(path, sdk_copy / path.name)
        (sdk_copy / "module.zig").write_text('pub const runtime = @import("runtime.zig");\npub const entry = @import("entry.zig");\n')
        options = work / "options.zig"
        options.write_text("pub const engine = " + ("false" if baseline else "true") + ";\n")
        artifact = work / ("BASELINE.BIN" if baseline else "QJS-RUNTIME.BIN")
        command += ["-fstrip", "-fentry=_start", "-T", str(ROOT / "tools/zig/guest.ld"),
                    "-femit-bin=" + str(artifact), "-femit-asm=" + str(work / "fixture.s"),
                    "--dep", "qjs", "--dep", "sdk", "--dep", "arena", "--dep", "build_options", *flags,
                    "-Mroot=" + str(INPUT / "native_fixture.zig"),
                    "--dep", "arena", "--dep", "hooks", *flags, "-Mqjs=" + str(INPUT / "runtime.zig"),
                    "--dep", "sdk", *flags, "-Marena=" + str(INPUT / "arena_alias.zig"),
                    "--dep", "sdk", *flags, "-Mhooks=" + str(INPUT / "native_hooks.zig"),
                    *flags, "-Msdk=" + str(sdk_copy / "module.zig"),
                    *flags, "-Mbuild_options=" + str(options)]
    result = subprocess.run(command, cwd=work, env=env, text=True, capture_output=True)
    (work / "linked.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise ValueError("HostedContractFailed: " + result.stderr if hosted else "NativeLinkFailed: " + result.stderr)
    if hashes != {path.relative_to(ROOT).as_posix(): sha(path.read_bytes()) for path in inputs}:
        raise ValueError("BuildInputChanged")
    if artifact:
        frames = sdk.stack_frames((work / "fixture.s").read_text())
        if re.search(r"(?m)^\s*[A-Za-z][^\n]*\b[wx]18\b", (work / "fixture.s").read_text()):
            raise ValueError("ReservedX18")
        rt_objects = sorted((work / "cache/global").glob("o/*/*compiler_rt_zcu.o"))
        rt = [inspection.compiler_rt_object(path, (work / "fixture.s").read_text(),
                                           sorted(output.glob("*.o")) if output else []) for path in rt_objects]
        if not rt:
            raise ValueError("MissingCompilerRtInspection")
        (work / "compiler-rt.json").write_text(json.dumps(rt, sort_keys=True, indent=2) + "\n")
        (work / "stack-frames.json").write_text(json.dumps(frames, sort_keys=True, indent=2) + "\n")
        subprocess.run([sys.executable, str(ROOT / "tools/check-zc-host-contract.py"),
                        "--profile", "sdk", str(artifact)], check=True)
        provenance.update(artifact_sha256=sha(artifact.read_bytes()), maximum_compiler_frame_bytes=max(frames.values()),
                          artifact=inspection.elf(artifact),
                          inputs_sha256=hashes,
                          zig_flags=flags, linker_script="tools/zig/guest.ld",
                          strip=True, entry="_start",
                          evidence="adapter-free native linked contract, not guest execution")
        artifact.with_suffix(".BIN.json").write_text(json.dumps(provenance, sort_keys=True, indent=2) + "\n")
        return artifact
    print(result.stderr)
    return work / "linked.log"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("objects", "native", "host", "baseline"))
    parser.add_argument("--work", type=Path, default=ROOT / ".build/quickjs/native")
    parser.add_argument("--cache", type=Path, default=sdk.DEFAULT_CACHE)
    args = parser.parse_args()
    try:
        if args.command == "objects":
            result = objects(args.work.resolve(), args.cache.resolve())
        else:
            result = linked(args.work.resolve(), args.cache.resolve(), args.command == "host", args.command == "baseline")
        print(result)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"quickjs-runtime: {error}\n")


if __name__ == "__main__":
    main()
