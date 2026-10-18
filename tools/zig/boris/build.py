#!/usr/bin/env python3
"""Pinned C3 serial-offline guest artifact. Only `fetch` uses the network."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
LOCK = json.loads((HERE / "lock.json").read_text())
INPUTS = ROOT / ".build/boris-inputs"
# The native exception frame deliberately omits platform register x18.
# Reserve it for the entire image, including code between asynchronous IRQs.
GUEST_CPU = "baseline+reserve_x18"
spec = importlib.util.spec_from_file_location("sdk", ROOT / "tools/zig/sdk.py")
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)
from stack import frames, guard, proof


def verify(name, source):
    pin = LOCK[name]
    for path, sha in pin["files"].items():
        file = source / path
        if file.is_symlink() or not file.is_file() or sdk.digest(file.read_bytes()) != sha:
            raise ValueError(f"{name} checksum mismatch: {path}")
    actual = {p.relative_to(source).as_posix() for p in (source / "src").glob("*.zig")}
    if actual != {p for p in pin["files"] if p.startswith("src/")}:
        raise ValueError(f"{name} source inventory drift")


def fetch(cache=sdk.DEFAULT_CACHE):
    INPUTS.mkdir(parents=True, exist_ok=True)
    for name in ("boris", "oliver"):
        source = INPUTS / name
        if source.exists():
            verify(name, source)
            continue
        with tempfile.TemporaryDirectory(prefix=name + "-fetch-", dir=INPUTS) as tmp:
            stage = Path(tmp) / "source"
            pin = LOCK[name]
            subprocess.run(["git", "clone", "--no-checkout", pin["repository"], str(stage)], check=True)
            subprocess.run(["git", "-C", str(stage), "checkout", "--detach", pin["revision"]], check=True)
            revision = subprocess.check_output(["git", "-C", str(stage), "rev-parse", "HEAD"], text=True).strip()
            if revision != pin["revision"]:
                raise ValueError(name + " revision mismatch")
            verify(name, stage)
            stage.rename(source)
    sdk.fetch(cache)


def clean_env():
    return {k: v for k, v in os.environ.items()
            if not k.startswith(("ZIG_", "NIX_")) and
            k not in ("LIBRARY_PATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH")}


def run(command, log, cwd=ROOT):
    result = subprocess.run(command, cwd=cwd, env=clean_env(), capture_output=True, text=True)
    log.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise ValueError(result.stdout + result.stderr)
    return result.stdout + result.stderr


def _repeat17(text):
    """zig 0.17 removed the `x ** n` array-repeat operator (its lexer now
    reads `**` as the pointer-of-pointer type suffix). Every upstream site
    is a single-element repeat, which @splat covers exactly: `[_]T{e} ** n`
    -> `@as([n]T, @splat(e))`, the declared-form `name: [n]T = .{e} ** n`
    -> `@as([n]T, @splat(e))`, and uniform string repeats `"c" ** n` ->
    `&@as([n*len]u8, @splat('c'))`. Semantics are unchanged — this is a
    syntax port, not a patch."""
    import re
    def decl(m):
        return "%s: [%s]%s = @as([%s]%s, @splat(%s))" % (
            m.group(1), m.group(2), m.group(3), m.group(2), m.group(3),
            m.group(4))
    def arr(m):
        return "@as([%s]%s, @splat(%s))" % (m.group(3), m.group(1),
                                            m.group(2))
    def lit(m):
        body, n = m.group(1), int(m.group(2))
        assert len(set(body)) == 1, "non-uniform repeat literal: " + body
        return "&@as([%d:0]u8, @splat('%s'))" % (len(body) * n, body[0])
    n_expr = r"[^,;\n()]+(?:\([^)]*\)[^,;\n()]*)*"
    out = re.sub(r"(\w+): \[(\w+)\](.+) = \.\{([^}]*)\} \*\* \2\b",
                 decl, text)
    out = re.sub(r"\[_\]([^\s{]+)\{([^}]*)\} \*\* (" + n_expr + r")",
                 arr, out)
    out = re.sub(r'"([^"]+)" \*\* (\d+)\b', lit, out)
    # zig 0.17's Type reflection split `.fields` (EnumField records) into
    # parallel `field_names`/`field_values` lists, and `std.meta.fields`
    # is a compileError. The three rewrite shapes upstream uses follow.
    out = out.replace('@"enum".fields.len', '@"enum".field_names.len')
    had_enum_loop = ('@"enum".fields, 0..) |field' in out or
                     '@"enum".fields) |field|' in out)
    out = out.replace('@"enum".fields, 0..) |field, i|',
                      '@"enum".field_names, 0..) |field_name, i|')
    out = out.replace('@"enum".fields) |field|',
                      '@"enum".field_names) |field_name|')
    # The two enum-loop files use `field.name` only inside those loops.
    if had_enum_loop:
        out = out.replace("field.name", "field_name")
    out = out.replace("std.meta.fields(artifact_inventory.Kind).len",
                      '@typeInfo(artifact_inventory.Kind).@"enum".field_names.len')
    old_fn = """fn enumWireNames(comptime E: type) [std.meta.fields(E).len][]const u8 {
    comptime {
        const fields = std.meta.fields(E);
        var names: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, index| names[index] = @field(E, field.name).name();"""
    new_fn = """fn enumWireNames(comptime E: type) [@typeInfo(E).@"enum".field_names.len][]const u8 {
    comptime {
        const names = @typeInfo(E).@"enum".field_names;
        var wire: [names.len][]const u8 = undefined;
        for (names, 0..) |name, index| wire[index] = @field(E, name).name();"""
    if old_fn in out:
        out = out.replace(old_fn, new_fn)
        out = out.replace("        return names;\n    }\n}\n\ntest \"publication proof pack",
                          "        return wire;\n    }\n}\n\ntest \"publication proof pack")
    return out


def materialize17(work):
    """Upstream-verbatim tree with only the zig-0.17 repeat-syntax port —
    the unpatched modes still test upstream, just readable by the pinned
    compiler."""
    target = work / "source17"
    for path in LOCK["boris"]["files"]:
        data = (INPUTS / "boris" / path).read_bytes()
        out = target / path
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(_repeat17(data.decode()).encode())
    return target


def materialize(work):
    """Boris-only exclusions, never patch the SDK or the dependency cache."""
    target = work / "source"
    patches = json.loads((HERE / "patches.json").read_text())
    stack_patches = json.loads((HERE / "workspace-patches.json").read_text())
    for path in LOCK["boris"]["files"]:
        data = _repeat17((INPUTS / "boris" / path).read_bytes().decode()).encode()
        if path in patches or path in stack_patches:
            text = data.decode()
            for edit in patches.get(path, []):
                if text.count(edit["before"]) != 1:
                    raise ValueError("Boris guest exclusion anchor drift: " + path)
                text = text.replace(edit["before"], edit["after"], 1)
            rules = stack_patches.get(path, {})
            if rules.get("parse_into"):
                # Keep the public value-returning API and every diagnostic,
                # but let failure sites write the caller's result directly.
                old = "fn fail(category: Category, line: u32, column: u32, message: []const u8) ParseResult {\n    return .{"
                new = "fn fail(out: *ParseResult, category: Category, line: u32, column: u32, message: []const u8) void {\n    out.* = .{"
                if text.count(old) != 1:
                    raise ValueError("Boris parser failure anchor drift")
                text = text.replace(old, new, 1)
                old = "pub fn parse(source: []const u8) ParseResult {"
                begin = text.index(old)
                end = text.index("\n// ---------------------------------------------------------------------------\n// Unit tests", begin)
                body = text[begin:end]
                if body.count("fail(") != 47 or body.count("return .{ .doc = doc };") != 3:
                    raise ValueError("Boris parser result-site inventory drift")
                body = body.replace(old, "noinline fn parseInto(source: []const u8, out: *ParseResult) void {")
                body = body.replace("fail(", "fail(out, ")
                body = body.replace("return .{ .doc = doc };", "out.* = .{ .doc = doc };\n        return;")
                body = body.replace("return .{ .diagnostic = .{", "out.* = .{ .diagnostic = .{")
                body = body.replace("        } };\n    }\n    if (unicode.warning)", "        } };\n        return;\n    }\n    if (unicode.warning)")
                wrapper = "pub fn parse(source: []const u8) ParseResult {\n    var result: ParseResult = undefined;\n    parseInto(source, &result);\n    return result;\n}\n\n"
                text = text[:begin] + wrapper + body + text[end:]
            for token, count in rules.get("stable_sorts", {}).items():
                if text.count(token) != count:
                    raise ValueError("Boris stable-sort anchor drift: " + path)
                text = text.replace(token, '@import("guest_workspace.zig").sort(')
            data = text.encode()
        out = target / path
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(data)
    (target / "src/guest_workspace.zig").write_bytes((ROOT / "user/zig/boris/workspace.zig").read_bytes())
    return target


def build(mode, work, cache=sdk.DEFAULT_CACHE):
    work.mkdir(parents=True, exist_ok=True)
    compiler, receipt = sdk.prepare(cache)
    for name in ("boris", "oliver"):
        verify(name, INPUTS / name)
    inputs = [*sorted((ROOT / "user/zig").glob("*.zig")),
              *sorted((ROOT / "user/zig/boris").glob("*.zig")),
              *sorted(HERE.glob("*.py")), HERE / "lock.json", HERE / "patches.json",
              HERE / "workspace-patches.json",
              ROOT / "tools/zig/sdk.py", ROOT / "tools/zig/lock.json",
              ROOT / "tools/zig/overlay.json", ROOT / "tools/zig/guest.ld",
              ROOT / "tools/check-zc-host-contract.py"]
    hashes = {str(p.relative_to(ROOT)): sdk.digest(p.read_bytes()) for p in inputs}
    guest_modes = ("guest", "guest-oom", "guest-resources", "guest-no-entropy", "guest-short-entropy", "audit")
    guest = mode in guest_modes
    patched = guest or mode in ("patched-host", "patched-test", "patched-upstream-test")
    source = materialize(work) if patched else materialize17(work)
    tests = mode in ("test", "upstream-test", "patched-test", "patched-upstream-test")
    output = work / ({"guest-resources": "BORISFULL.BIN", "guest-oom": "BORISOOM.BIN",
                     "guest-no-entropy": "BORISNO.BIN", "guest-short-entropy": "BORISSHORT.BIN"}.get(mode, "BORIS.BIN") if guest else "boris-oracle")
    root = ROOT / ("user/zig/boris.zig" if guest else "user/zig/boris/tests.zig" if tests else "user/zig/boris/host.zig")
    if mode in ("upstream-test", "patched-upstream-test"):
        root = source / "src/embed.zig"
    command = [str(compiler / "zig"), "test" if tests else "build-exe",
               "--cache-dir", str(work / "local"), "--global-cache-dir", str(work / "global"),
               "--zig-lib-dir", str(compiler / "lib"), "-O", "ReleaseSafe", "-freference-trace=40"]
    if guest:
        command += ["-target", sdk.LOCK["target"], "-mcpu", GUEST_CPU,
                    "-fsingle-threaded", "-fstrip", "-fno-PIE", "-fno-unwind-tables",
                    "-fno-stack-check", "-fno-stack-protector", "-fentry=_start",
                    "-fno-compiler-rt",
                    "-T", str(ROOT / "tools/zig/guest.ld"),
                    "-femit-asm=" + str(work / "boris.s")]
    if not tests:
        command += ["-femit-bin=" + str(work / "unguarded.elf" if guest else output)]
    if mode in ("upstream-test", "patched-upstream-test"):
        command += ["--dep", "oliver", "-Mroot=" + str(root)]
    else:
        if guest:
            options = work / "options.zig"
            options.write_text(f"pub const arena_bytes: usize = {4096 if mode == 'guest-oom' else 12 * 1024 * 1024};\n"
                               f"pub const exhaust_resources = {'true' if mode == 'guest-resources' else 'false'};\n"
                               "pub const EntropyMode = enum { native, unavailable, short };\n"
                               f"pub const entropy_mode: EntropyMode = .{'unavailable' if mode == 'guest-no-entropy' else 'short' if mode == 'guest-short-entropy' else 'native'};\n")
            command += ["--dep", "boris_options"]
        command += ["--dep", "sdk"]
        command += ["--dep", "boris", "-Mroot=" + str(root),
                    "--dep", "oliver", "-Mboris=" + str(source / "src/embed.zig")]
    command += ["-Moliver=" + str(INPUTS / "oliver/src/oliver.zig")]
    if guest:
        command += ["-Mboris_options=" + str(options)]
    if mode not in ("upstream-test", "patched-upstream-test"):
        command += ["-Msdk=" + str(ROOT / "user/zig/runtime.zig")]
    log = run(command, work / "compiler.log", INPUTS / "boris" if mode in ("upstream-test", "patched-upstream-test") else ROOT)
    if guest:
        assembly = (work / "boris.s").read_text()
        check_registers(assembly)
        frame_sizes = frames(assembly)
        candidate = work / "unguarded.elf"
        run([sys.executable, str(ROOT / "tools/check-zc-host-contract.py"),
             "--profile", "sdk", str(candidate)], work / "candidate-check.log")
        # Linking from Zig alone, no build.zig/C/linkLibrary/-lc, then checking
        # the static ELF proves the dependency closure without hosted linkage.
        forbidden = ("secp256k1", "nostr_keys", "nostr_sign", "nostr_publish",
                     "preview_server", "Thread.spawn", "Io.Threaded", "atproto_transport")
        if any(token in name for name in frame_sizes for token in forbidden):
            raise ValueError("UnsupportedHostedClosure")
        receipt.update(
            flags=command[2:command.index("--dep")], sources=hashes, dependencies=LOCK,
            candidate_sha256=sdk.digest(candidate.read_bytes()), no_libc=True,
            maximum_frame_bytes=max(frame_sizes.values()),
            oversized_frames={name: n for name, n in frame_sizes.items() if n > 8192},
            stack_budget_bytes=128 * 1024, entry_floor_bytes=120 * 1024,
            arena_bytes=4096 if mode == "guest-oom" else 12 * 1024 * 1024,
            reserved_platform_register="x18",
            acceptance_instrumentation=mode not in ("guest", "audit"),
            release_ready=True,
            blockers=[],
            scope="serial offline compiler and pinned per-entry publication; quiescent inputs, no site transaction",
        )
        (work / "closure.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        (work / "frames.json").write_text(json.dumps(frame_sizes, indent=2, sort_keys=True) + "\n")
        print((work / "candidate-check.log").read_text(), end="")
        print(f"Compiler closure: {len(frame_sizes)} functions; largest frame {max(frame_sizes.values())} B")
        if mode == "audit":
            output = candidate
        else:
            release(compiler, work, assembly, frame_sizes, receipt)
    for name in ("boris", "oliver"):
        verify(name, INPUTS / name)
    if any(sdk.digest(p.read_bytes()) != hashes[str(p.relative_to(ROOT))] for p in inputs):
        raise ValueError("BuildInputChanged")
    if guest and mode != "audit":
        (work / "guarded.elf").replace(output)
        output.with_suffix(".BIN.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    if tests:
        print(log, end="")
    return None if tests else output


def gate(work, cache=sdk.DEFAULT_CACHE):
    work.mkdir(parents=True, exist_ok=True)
    compiler, _ = sdk.prepare(cache)
    output = work / "BORISGATE.BIN"
    run([str(compiler / "zig"), "build-exe", "--zig-lib-dir", str(compiler / "lib"),
         "--cache-dir", str(work / "local"), "--global-cache-dir", str(work / "global"),
         "-target", sdk.LOCK["target"], "-mcpu", GUEST_CPU,
         "-O", "ReleaseSafe", "-fsingle-threaded", "-fstrip", "-fno-PIE",
         "-fentry=_start", "-T", str(ROOT / "tools/zig/guest.ld"),
         "-femit-bin=" + str(output), "-femit-asm=" + str(work / "gate.s"),
         "--dep", "native", "--dep", "startup",
         "-Mroot=" + str(ROOT / "user/zig/boris/gate.zig"),
         "-Mnative=" + str(ROOT / "user/zig/native.zig"),
         "-Mstartup=" + str(ROOT / "user/zig/startup.zig")], work / "compiler.log")
    if max(frames((work / "gate.s").read_text()).values()) > 32768:
        raise ValueError("GateFrameBudget")
    check_registers((work / "gate.s").read_text())
    run([sys.executable, str(ROOT / "tools/check-zc-host-contract.py"), "--profile", "sdk",
         str(output)], work / "elf-check.log")
    return output


def check_registers(assembly):
    for line in assembly.splitlines():
        instruction = line.split("//", 1)[0].strip()
        if not instruction or instruction.startswith("."):
            continue
        if re.search(r"\b[wx]18\b", instruction):
            raise ValueError("UnpreservedPlatformRegister:x18")


def release(compiler, work, assembly, frame_sizes, receipt):
    stack_proof = proof(assembly, frame_sizes)
    guarded = guard(assembly, frame_sizes)
    (work / "guarded.s").write_text(guarded)
    run([str(compiler / "zig"), "cc", "-target", sdk.LOCK["target"], "-c",
         str(work / "guarded.s"), "-o", str(work / "guarded.o")], work / "assembler.log")
    run([str(compiler / "zig"), "build-exe", str(work / "guarded.o"),
         "--zig-lib-dir", str(compiler / "lib"), "-target", sdk.LOCK["target"],
         "-mcpu", GUEST_CPU, "-O", "ReleaseSafe", "-fstrip", "-fno-PIE",
         "-fno-compiler-rt", "-fentry=_start", "-T", str(ROOT / "tools/zig/guest.ld"),
         "-femit-bin=" + str(work / "guarded.elf")], work / "link.log")
    run([sys.executable, str(ROOT / "tools/check-zc-host-contract.py"),
         "--profile", "sdk", str(work / "guarded.elf")], work / "elf-check.log")
    receipt.update(
        artifact_sha256=sdk.digest((work / "guarded.elf").read_bytes()),
        guarded_functions=len(frame_sizes) - 2,
        guarded_assembly_sha256=sdk.digest(guarded.encode()),
        stack_proof={k: v for k, v in stack_proof.items() if k != "calls"},
        stack_budget_verified=True,
        scope="guarded serial offline compiler and pinned per-entry publisher",
    )
    (work / "stack-proof.json").write_text(json.dumps(stack_proof, indent=2, sort_keys=True) + "\n")
    print((work / "elf-check.log").read_text(), end="")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("fetch", "audit", "guest", "guest-oom", "guest-resources", "guest-no-entropy", "guest-short-entropy", "gate", "host", "test", "upstream-test",
                                          "patched-host", "patched-test", "patched-upstream-test"))
    parser.add_argument("--work", type=Path)
    parser.add_argument("--output", type=Path, help="copy the guarded guest artifact to this build output")
    parser.add_argument("--cache", type=Path, default=sdk.DEFAULT_CACHE)
    args = parser.parse_args()
    try:
        if args.command == "fetch":
            fetch(args.cache.resolve())
        elif args.command == "gate":
            print(gate((args.work or ROOT / ".build/boris/gate").resolve(), args.cache.resolve()))
        else:
            output = build(args.command, (args.work or ROOT / ".build/boris" / args.command).resolve(), args.cache.resolve())
            if args.output:
                if args.command != "guest":
                    raise ValueError("--output is supported only for the shipping guest artifact")
                destination = args.output.resolve()
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(output, destination)
                shutil.copyfile(output.with_suffix(".BIN.json"), destination.with_suffix(".BIN.json"))
            print(output or "tests passed")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"boris-build: {error}\n")


if __name__ == "__main__":
    main()
