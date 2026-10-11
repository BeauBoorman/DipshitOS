#!/usr/bin/env python3
"""A2 checker unit tests; --integration adds pinned clean builds and Zig probes."""
import argparse
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


checker = module("checker", ROOT / "tools/check-zc-host-contract.py")
sdk = module("sdk", ROOT / "tools/zig/sdk.py")


def elf():
    data = bytearray(0x3100)
    data[:16] = b"\x7fELF\x02\x01\x01" + bytes(9)
    struct.pack_into("<HHIQQQIHHHHHH", data, 16, 2, 183, 1, 0x400000, 64, 0x3000, 0, 64, 56, 2, 64, 2, 0)
    struct.pack_into("<II6Q", data, 64, 1, 5, 0x1000, 0x400000, 0x400000, 16, 16, 4096)
    struct.pack_into("<II6Q", data, 120, 1, 6, 0x2000, 0x402000, 0x402000, 16, 16, 4096)
    struct.pack_into("<II4QII2Q", data, 0x3040, 0, 1, 3, 0x402000, 0x2000, 16, 0, 0, 8, 0)
    return data


def field(data, offset, value, fmt="Q"):
    result = bytearray(data)
    struct.pack_into("<" + fmt, result, offset, value)
    return result


def corpus(data):
    phoff = struct.unpack_from("<Q", data, 32)[0]
    second = phoff + 56
    text_mem = struct.unpack_from("<Q", data, phoff + 40)[0]
    outside_window = bytearray(data)
    phbytes = struct.unpack_from("<H", data, 56)[0] * 56
    outside_window.extend(bytes(max(0, checker.HEADER_WINDOW + phbytes - len(outside_window))))
    outside_window[checker.HEADER_WINDOW:checker.HEADER_WINDOW + phbytes] = data[phoff:phoff + phbytes]
    struct.pack_into("<Q", outside_window, 32, checker.HEADER_WINDOW)
    # SDK-specific restrictions intentionally exceed what parse_head enforces.
    return [
        ("valid", data, True, True),
        ("headers-outside-window", outside_window, False, False),
        ("bad-machine", field(data, 18, 62, "H"), False, False),
        ("bad-entry", field(data, 24, 0), False, False),
        ("writable-text", field(data, phoff + 4, 7, "I"), False, False),
        ("executable-data", field(data, second + 4, 7, "I"), False, True),
        ("readonly-data", field(data, second + 4, 4, "I"), False, False),
        ("overlap-file", field(data, second + 8, 0), False, False),
        ("escaping-file", field(data, second + 8, len(data) + 1), False, False),
        ("filesz-gt-memsz", field(data, second + 40, 0), False, False),
        ("misaligned-data", field(data, second + 16, 0x400001), False, False),
        ("static-type", field(data, 16, 3, "H"), False, True),
        ("tls", field(data, second + 56, 7, "I"), False, True)
        if struct.unpack_from("<H", data, 56)[0] > 2 else
        ("bad-alignment", field(data, second + 48, 3), False, True),
        ("oversize-map", field(data, second + 40, checker.SDK_MAP_MAX), False, True),
        ("two-page-gap", field(data, second + 16, checker.aligned(0x400000 + text_mem) + 8192), False, True),
    ]


class CheckerTests(unittest.TestCase):
    def test_compiler_frame_ceiling_and_unknown_adjustments(self):
        prefix = ".type f,@function\n"
        self.assertEqual(sdk.stack_frames(prefix + "sub sp, sp, #32, lsl #12\n"), {"f": 128 * 1024})
        with self.assertRaisesRegex(ValueError, "StackBudget"):
            sdk.stack_frames(prefix + "sub sp, sp, #33, lsl #12\n")
        with self.assertRaisesRegex(ValueError, "unreviewed"):
            sdk.stack_frames(prefix + "sub sp, sp, x8\n")
        with self.assertRaisesRegex(ValueError, "missing"):
            sdk.stack_frames("")

    def test_materializer_archive_and_private_tree_drift(self):
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp)
            archive = cache / "test.tar.xz"
            with tarfile.open(archive, "w:xz") as output:
                for name, data in (("zig", b"not executed"), ("lib/std/std.zig", b"// pinned input\n")):
                    member = tarfile.TarInfo("test/" + name)
                    member.size = len(data)
                    member.mode = 0o755 if name == "zig" else 0o644
                    output.addfile(member, io.BytesIO(data))
            lock = dict(sdk.LOCK, patches=[], overlay_sha256=sdk.digest(b""), archives={"test": {"url": "https://example.invalid/test.tar.xz",
                                                   "sha256": sdk.digest(archive.read_bytes())}})
            with patch.object(sdk, "LOCK", lock), patch.object(sdk, "host", return_value="test"):
                installed, first = sdk.prepare(cache)
                self.assertEqual(sdk.prepare(cache)[1], first)
                std = installed / "lib/std/std.zig"
                original = std.read_bytes()
                std.write_bytes(b"// unreviewed edit")
                with self.assertRaisesRegex(ValueError, "drift"):
                    sdk.prepare(cache)
                std.write_bytes(original)
                extra = installed / "lib/std/extra.zig"
                extra.write_bytes(b"// unreviewed import")
                with self.assertRaisesRegex(ValueError, "additional"):
                    sdk.prepare(cache)
                extra.unlink()
                archive.write_bytes(b"corrupt archive")
                with self.assertRaisesRegex(ValueError, "checksum"):
                    sdk.prepare(cache)

    def test_overlay_is_pinned_and_only_selects_native_integration(self):
        overlay = sdk.load_overlay()
        self.assertEqual(len(overlay), 6)
        for name, row in overlay.items():
            self.assertTrue(name.startswith("lib/std/"))
            self.assertEqual(len(row["original_sha256"]), 64)
            for edit in row["edits"]:
                self.assertIn('@hasDecl(@import("root"), "virelai")', edit["after"])
                self.assertIn("freestanding", edit["after"])
        with patch.object(sdk, "LOCK", dict(sdk.LOCK, overlay_sha256="0" * 64)):
            with self.assertRaisesRegex(ValueError, "overlay checksum"):
                sdk.load_overlay()

    def test_overlay_checks_original_and_unique_anchor_offline(self):
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp)
            archive = cache / "test.tar.xz"
            original = b"// original\n"
            with tarfile.open(archive, "w:xz") as output:
                for name, data in (("zig", b"compiler"), ("lib/std/std.zig", original)):
                    member = tarfile.TarInfo("test/" + name)
                    member.size = len(data)
                    output.addfile(member, io.BytesIO(data))
            lock = dict(sdk.LOCK, archives={"test": {
                "url": "https://example.invalid/test.tar.xz", "sha256": sdk.digest(archive.read_bytes()),
            }})
            row = {"original_sha256": "0" * 64, "edits": [{"before": "original", "after": "native"}]}
            with patch.object(sdk, "LOCK", lock), patch.object(sdk, "host", return_value="test"), \
                    patch.object(sdk, "load_overlay", return_value={"lib/std/std.zig": row}), \
                    patch.object(sdk.urllib.request, "urlopen", side_effect=AssertionError("offline")):
                with self.assertRaisesRegex(ValueError, "original checksum"):
                    sdk.prepare(cache)
                row["original_sha256"] = sdk.digest(original)
                row["edits"][0]["before"] = "absent"
                with self.assertRaisesRegex(ValueError, "anchor not unique"):
                    sdk.prepare(cache)
                row["edits"][0]["before"] = "original"
                compiler, _ = sdk.prepare(cache)
                self.assertEqual((compiler / "lib/std/std.zig").read_bytes(), b"// native\n")
                sdk.prepare(cache)
                self.assertEqual(sdk.digest(archive.read_bytes()), lock["archives"]["test"]["sha256"])

    def test_corpus(self):
        for name, data, accepted, _kernel in corpus(elf()):
            with self.subTest(name=name):
                if accepted:
                    self.assertEqual(checker.check(data, "sdk")["mapped_bytes"], 12288)
                else:
                    with self.assertRaises(checker.ContractError):
                        checker.check(data, "sdk")

    def test_malformed_headers_fail_closed(self):
        for size in range(64):
            with self.subTest(size=size), self.assertRaises(checker.ContractError):
                checker.check(elf()[:size], "sdk")
        for offset, value, fmt in ((32, 2**64 - 1, "Q"), (56, 65535, "H"), (40, 2**64 - 1, "Q"),
                                   (58, 0, "H"), (60, 65535, "H"), (120 + 16, 2**64 - 1, "Q")):
            with self.subTest(offset=offset), self.assertRaises(checker.ContractError):
                checker.check(field(elf(), offset, value, fmt), "sdk")

    def test_file_budget_exact_and_one_over(self):
        data = elf()
        data.extend(bytes(checker.SDK_FILE_MAX - len(data)))
        self.assertEqual(checker.check(data, "sdk")["file_bytes"], checker.SDK_FILE_MAX)
        data.append(0)
        with self.assertRaisesRegex(checker.ContractError, "ImageBudget"):
            checker.check(data, "sdk")

    def test_map_budget_includes_rounded_argument_tail(self):
        data = field(elf(), 120 + 40, checker.SDK_MAP_MAX - 4096 - 4096)
        self.assertEqual(checker.check(data, "sdk")["mapped_bytes"], checker.SDK_MAP_MAX)
        with self.assertRaisesRegex(checker.ContractError, "ImageBudget"):
            checker.check(field(data, 120 + 40, checker.SDK_MAP_MAX - 8192 + 1), "sdk")

    def test_dynamic_tls_relocations_and_symbols(self):
        for kind in (2, 3, 7):
            data = field(elf(), 56, 3, "H")
            data = field(data, 176, kind, "I")
            with self.subTest(kind=kind), self.assertRaises(checker.ContractError):
                checker.check(data, "sdk")
        for kind in (4, 9, 19, 6, 11):
            with self.subTest(section_kind=kind), self.assertRaises(checker.ContractError):
                checker.check(field(elf(), 0x3040 + 4, kind, "I"), "sdk")
        with self.assertRaisesRegex(checker.ContractError, "TLS"):
            checker.check(field(elf(), 0x3040 + 8, 0x403), "sdk")
        data = elf()
        struct.pack_into("<II4QII2Q", data, 0x3040, 0, 2, 0, 0, 0x2100, 48, 0, 0, 8, 24)
        struct.pack_into("<IBBHQQ", data, 0x2118, 0, 0x10, 0, 0, 0, 0)
        with self.assertRaisesRegex(checker.ContractError, "unresolved"):
            checker.check(data, "sdk")

    def test_legacy_zc_stays_contiguous_and_small(self):
        data = field(elf(), 120 + 16, 0x400010)
        checker.check(data, "zc")
        with self.assertRaises(checker.ContractError):
            checker.check(elf(), "zc")
        with self.assertRaises(checker.ContractError):
            checker.check(field(data, 120 + 40, checker.LOAD_MAX), "zc")
        # ELF32 has a different PHDR field order; preserve actual legacy input.
        data = bytearray(256)
        data[:16] = b"\x7fELF\x01\x01\x01" + bytes(9)
        struct.pack_into("<HHIIIIIHHHHHH", data, 16, 2, 183, 1, 0x400000, 52, 0, 0, 52, 32, 1, 0, 0, 0)
        struct.pack_into("<8I", data, 52, 1, 128, 0x400000, 0, 16, 16, 5, 4096)
        checker.check(data, "zc")


def integration(cache, work):
    work.mkdir(parents=True, exist_ok=True)
    # New local AND global caches, different output paths; no prior compiler
    # objects can make a stale fixture masquerade as a reproducible rebuild.
    with tempfile.TemporaryDirectory(prefix="reproduce-", dir=work) as temp:
        temp = Path(temp)
        outputs = [temp / name / "ZGUEST.BIN" for name in ("first", "second")]
        with patch.object(sdk.urllib.request, "urlopen", side_effect=AssertionError("build must be offline")):
            for output in outputs:
                sdk.build(cache, output, output.parent / "cache")
        if outputs[0].read_bytes() != outputs[1].read_bytes():
            raise ValueError("clean fixture builds are not byte-identical")
        if outputs[0].with_suffix(".BIN.json").read_bytes() != outputs[1].with_suffix(".BIN.json").read_bytes():
            raise ValueError("build provenance is not reproducible")
        output = work / "ZGUEST.BIN"
        output.write_bytes(outputs[0].read_bytes())
        output.with_suffix(".BIN.json").write_bytes(outputs[0].with_suffix(".BIN.json").read_bytes())
    compiler, _ = sdk.prepare(cache)
    cases = corpus(output.read_bytes())
    for name, data, accepted, _kernel in cases:
        try:
            checker.check(data, "sdk")
        except checker.ContractError:
            if accepted:
                raise
        else:
            if not accepted:
                raise ValueError(f"SDK checker unexpectedly accepted {name}")
        (work / f"{name}.bin").write_bytes(data)
    (work / "cases.zig").write_text(
        "const Case = struct { name: []const u8, bytes: []const u8, accepted: bool };\n"
        "pub const fixtures = [_]Case{\n" +
        "".join(f'.{{ .name="{name}", .bytes=@embedFile("{name}.bin"), .accepted={str(kernel).lower()} }},\n'
                for name, _data, _accepted, kernel in cases) + "};\n")
    subprocess.run([
        str(compiler / "zig"), "test", "--dep", "elf", "--dep", "cases",
        f"-Mroot={ROOT / 'tools/zig/kernel_contract.zig'}",
        f"-Melf={ROOT / 'kernel/src/elf.zig'}", f"-Mcases={work / 'cases.zig'}",
    ], cwd=ROOT, check=True)
    # Independent shared-SDK declarations must match the merged native wire.
    wire_contract = work / "filesystem-wire.zig"
    wire_contract.write_text('''
const std = @import("std");
const sdk = @import("fs");
const native = @import("metadata");
test "SDK wire matches native B2/B3/B5 without importing kernel into the guest" {
    try std.testing.expectEqual(native.max_guest_path, sdk.path_max);
    try std.testing.expectEqual(native.max_component, sdk.name_max);
    try std.testing.expectEqual(native.max_depth, sdk.depth_max);
    try std.testing.expectEqual(native.max_pinned_depth, sdk.pinned_depth_max);
    inline for (.{"pin_open_op", "pin_child_op", "pin_close_op", "handle_metadata_op",
                  "create_op", "mkdir_op", "remove_op", "rename_op", "handle_file",
                  "handle_directory", "rename_replace"}) |name| {
        try std.testing.expectEqual(@field(native, name), @field(sdk, name));
    }
    try std.testing.expectEqual(native.remove_file, @backingInt(sdk.EntryKind.file));
    try std.testing.expectEqual(native.remove_directory, @backingInt(sdk.EntryKind.directory));
    inline for (.{.{sdk.Metadata, native.Wire}, .{sdk.Identity, native.Identity},
                  .{sdk.Entry, native.Entry}, .{sdk.Page, native.Page}}) |pair| {
        try std.testing.expectEqual(@sizeOf(pair[1]), @sizeOf(pair[0]));
        inline for (@typeInfo(pair[0]).@"struct".field_names) |name| {
            try std.testing.expectEqual(@offsetOf(pair[1], name), @offsetOf(pair[0], name));
        }
    }
    const fact = native.Wire.from(.{
        .kind = .file, .identity = .{.filesystem = 9, .inode = 7}, .size = 0x100000001,
        .atime = .{.seconds = -1, .nanoseconds = 3},
        .mtime = .{.seconds = 2, .nanoseconds = 4},
        .ctime = .{.seconds = 3, .nanoseconds = 5},
        .host_mode = 0o100640, .host_uid = 501, .host_gid = 20,
    });
    const decoded: sdk.Metadata = @bitCast(fact);
    try decoded.validate();
    try std.testing.expectEqual(fact.size, decoded.size);
    try std.testing.expectEqual(fact.atime.seconds, decoded.atime.seconds);
}
''')
    subprocess.run([
        str(compiler / "zig"), "test", "-O", "ReleaseSafe", "--dep", "fs", "--dep", "metadata",
        f"-Mroot={wire_contract}", f"-Mfs={ROOT / 'user/zig/fs.zig'}",
        f"-Mmetadata={ROOT / 'kernel/src/fs_metadata.zig'}",
    ], cwd=ROOT, check=True)
    # Native rich-page acceptance also depends on the kernel not overflowing
    # its exception stack. Block sort used a 512 * 360-byte automatic cache.
    sort_contract = work / "filesystem-sort.zig"
    sort_contract.write_text('''
const metadata = @import("metadata");
export fn sortSnapshot(snapshot: *metadata.Snapshot) void {
    snapshot.sort();
}
''')
    for mode in ("ReleaseSafe", "ReleaseSmall"):
        assembly = work / f"filesystem-sort-{mode}.s"
        subprocess.run([
            str(compiler / "zig"), "build-obj", "-target", sdk.LOCK["target"],
            "-mcpu", sdk.LOCK["cpu"], "-O", mode, "-fno-emit-bin",
            "--dep", "metadata", f"-Mroot={sort_contract}",
            f"-Mmetadata={ROOT / 'kernel/src/fs_metadata.zig'}",
            f"-femit-asm={assembly}",
        ], cwd=ROOT, check=True)
        maximum = max(sdk.stack_frames(assembly.read_text()).values())
        if maximum > 8192:
            raise ValueError(f"native snapshot sort frame exceeds 8 KiB: {mode} {maximum}")
        print(f"zig-guest: native snapshot sort {mode} maximum frame={maximum}")
    probes = {
        "allocator-format": (
            'const std = @import("std"); const sdk = @import("sdk");\n'
            "pub const os = sdk.os; pub const std_options = sdk.std_options;\n"
            "pub const panic = std.debug.FullPanic(sdk.panic);\n"
            'export fn probe() usize { const a = std.heap.page_allocator; const p = a.alloc(u8, 32) catch return 0; '
            'defer a.free(p); return (std.fmt.bufPrint(p, "{d}", .{@as(u32, 42)}) catch return 0).len; }\n', True, ""),
        "threads": ('const std=@import("std"); fn child() void {} export fn probe() void { '
                    '_ = std.Thread.spawn(.{}, child, .{}) catch return; }\n', False, "unsupported"),
        "stdout": ('const std=@import("std"); export fn probe() void { _ = std.Io.File.stdout(); }\n',
                   False, "STDOUT_FILENO"),
        "args": ('const std=@import("std"); export fn probe() void { var a: std.process.Args = .{.vector={}}; '
                 'var i=a.iterate(); _=i.next(); }\n', False, "void"),
    }
    recipe = (
        'const std = @import("std"); const sdk = @import("sdk");\n'
        'pub const virelai = sdk.platform;\n'
        'pub const os = sdk.os; pub const std_options = sdk.std_options;\n'
        'pub const std_options_debug_io = sdk.std_options_debug_io;\n'
        'pub const std_options_FilePermissions = sdk.std_options_FilePermissions;\n'
        'pub const std_options_cwd = sdk.std_options_cwd;\n'
        'pub const panic = std.debug.FullPanic(sdk.panic);\n'
    )
    native_probes = {
        "filesystem": (
            'export fn probe() void { const f=sdk.filesystem(); '
            '_=f.metadata("/host","content") catch return; '
            '_=f.identity("/host","content") catch return; '
            'const file=f.openContained("/host/content","a",.read) catch return; '
            '_=f.fileMetadata(file) catch {}; _=file.length(sdk.io) catch {}; file.close(sdk.io); '
            'const c=f.openSnapshot("/host/content","") catch return; '
            'var p:sdk.fs.Page=undefined; f.snapshotPage(c,0,16,&p) catch return; '
            'f.closeSnapshot(c) catch return; f.publish("stage","out",.replace) catch return; '
            'const d=f.openDirectory("/host","out") catch return; defer f.closeDirectory(d) catch {}; '
            '_=f.directoryMetadata(d) catch {}; const s=f.makeDirectory(d,"stage") catch return; '
            'const n=f.createExclusive(s,"page") catch return; n.close(sdk.io); f.closeDirectory(s) catch return; '
            'const k=f.openChildDirectory(d,"stage") catch return; f.closeDirectory(k) catch return; '
            'f.rename(d,"stage",d,"live",.preserve_existing) catch return; '
            'f.removeFile(d,"page") catch {}; f.removeDirectory(d,"live") catch {}; }\n',
            True, ""),
        "page-allocator": ('export fn probe() void { const a=std.heap.page_allocator; '
                           'const p=a.alloc(u8,4096) catch return; defer a.free(p); '
                           '_=a.resize(p,8192); }\n', True, ""),
        "streams": ('export fn probe() void { const a=std.Io.File.stdin(); const b=std.Io.File.stdout(); '
                    'const c=std.Io.File.stderr(); if(a.handle==b.handle or b.handle==c.handle) @panic("alias"); '
                    'b.writeStreamingAll(sdk.io,"hello") catch {}; }\n', True, ""),
        "debug": ('export fn probe() void { std.debug.print("native {d}\\n", .{@as(u32,42)}); }\n', True, ""),
        "args-env-init": ('export fn probe() void { var block:[sdk.startup.block_bytes]u8=undefined; '
                          'sdk.startup.pack(&.{"program","arg"},&.{"A=B"},&block) catch return; '
                          'const args=sdk.startup.Startup.parse(2,&block) catch return; '
                          'var state=sdk.InitState.init(&args) catch return; defer state.deinit(); '
                          'const init=state.get(args.argc,args.envc); var it=init.minimal.args.iterate(); _=it.next(); '
                          'var env=init.minimal.environ.createMap(init.gpa) catch return; defer env.deinit(); '
                          '_=init.preopens.get("/host"); }\n', True, ""),
        "cli-files": ('export fn probe() void { const cwd:std.Io.Dir=.cwd(); '
                      'const f=cwd.openFile(sdk.io,"input",.{}) catch return; defer f.close(sdk.io); '
                      'var bytes:[4097]u8=undefined; _=sdk.io_helpers.readBounded(f,sdk.io,&bytes) catch return; '
                      'const out=cwd.createFile(sdk.io,"output",.{}) catch return; defer out.close(sdk.io); '
                      'var w=out.writer(sdk.io,&bytes); w.interface.print("{d}",.{@as(u32,42)}) catch return; '
                      'w.interface.flush() catch return; out.sync(sdk.io) catch return; }\n', True, ""),
        "exit": ('export fn probe() noreturn { std.process.exit(7); }\n', True, ""),
        "abort": ('export fn probe() noreturn { std.process.abort(); }\n', True, ""),
        "threaded": ('export fn probe() void { var t:std.Io.Threaded=.init(std.heap.page_allocator,.{}); '
                     '_=t.io(); }\n', False, "VirelaiUnsupportedThreaded"),
        "threads": ('fn child() void {} export fn probe() void { _=std.Thread.spawn(.{},child,.{}) catch return; }\n',
                    False, "single-threaded"),
        "posix-mmap": ('export fn probe() usize { return std.posix.PROT.READ; }\n', False, "VirelaiUnsupportedPosix"),
        "posix-mremap": ('export fn probe() usize { return std.posix.MREMAP.MAYMOVE; }\n', False, "VirelaiUnsupportedPosix"),
        "posix-errno": ('export fn probe() usize { return @backingInt(std.posix.errno(@as(isize,-1))); }\n',
                        False, "VirelaiUnsupportedPosix"),
        "posix-getrandom": ('export fn probe() void { var b:[1]u8=undefined; _=std.posix.system.getrandom(&b,1,0); }\n',
                            False, "VirelaiUnsupportedPosix"),
    }
    probes.update({f"native-{name}": (recipe + source, accepted, diagnostic)
                   for name, (source, accepted, diagnostic) in native_probes.items()})
    for name, (source, accepted, diagnostic) in probes.items():
        path = work / f"probe-{name}.zig"
        path.write_text(source)
        result = subprocess.run([
            str(compiler / "zig"), "build-obj", "--zig-lib-dir", str(compiler / "lib"),
            "-target", sdk.LOCK["target"], "-O", "ReleaseSafe", "-fno-emit-bin",
            *(["-fsingle-threaded"] if name.startswith("native-") else []),
            "--dep", "sdk", f"-Mroot={path}", f"-Msdk={ROOT / 'user/zig/runtime.zig'}",
        ], cwd=ROOT, text=True, capture_output=True)
        (work / f"probe-{name}.log").write_text(result.stdout + result.stderr)
        if (result.returncode == 0) != accepted or (not accepted and diagnostic.lower() not in result.stderr.lower()):
            raise ValueError(f"unexpected {name} probe result:\n{result.stderr}")
    fatal_fixture = work / "refusal-fixture"
    subprocess.run([str(compiler / "zig"), "build-exe", str(ROOT / "user/zig/refusal_fixture.zig"),
                    f"-femit-bin={fatal_fixture}"], check=True)
    for name, diagnostic in {
        "now": "Unsupported:now", "futexWait": "Unsupported:futexWaitUncancelable",
        "close": "CloseFailed", "unlock": "Unsupported:fileUnlock",
        "tty": "Unsupported:fileIsTty", "netClose": "Unsupported:netClose",
        "random": "EntropyUnavailable",
    }.items():
        result = subprocess.run([str(fatal_fixture), name], text=True, capture_output=True)
        (work / f"fatal-{name}.log").write_text(result.stdout + result.stderr)
        if result.returncode != 70 or diagnostic not in result.stderr:
            raise ValueError(f"no-error API {name} did not refuse loudly: {result}")
    print(f"zig-guest: clean builds identical; {len(cases)} kernel cases; "
          f"{len(probes)} exported-body probes; 7 fatal refusals passed")
    sys.path.insert(0, str(ROOT / "tools/zig"))
    filesystem = module("filesystem", ROOT / "tools/zig/fs.py")
    with tempfile.TemporaryDirectory(prefix="fs-reproduce-", dir=work) as temp:
        with patch.object(filesystem.sdk.urllib.request, "urlopen", side_effect=AssertionError("offline")):
            outputs = [filesystem.build(cache, Path(temp) / name) for name in ("first", "second")]
        if outputs[0].read_bytes() != outputs[1].read_bytes():
            raise ValueError("filesystem clean builds differ")
        if outputs[0].with_suffix(".BIN.json").read_bytes() != outputs[1].with_suffix(".BIN.json").read_bytes():
            raise ValueError("filesystem provenance differs")
        (work / "ZFS.BIN").write_bytes(outputs[0].read_bytes())
        (work / "ZFS.BIN.json").write_bytes(outputs[0].with_suffix(".BIN.json").read_bytes())
    print("zig-guest: filesystem clean builds and provenance identical, offline")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--integration", action="store_true")
    parser.add_argument("--cache", type=Path, default=sdk.DEFAULT_CACHE)
    parser.add_argument("--work", type=Path, default=ROOT / "artifacts/zig-guest")
    args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CheckerTests))
    if not result.wasSuccessful():
        sys.exit(1)
    if args.integration:
        integration(args.cache.resolve(), args.work.resolve())
