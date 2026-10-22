# live-user-fs.spec — userland storage ABI & utilities on VZ.
# Proves round-trip persistence across two boots sharing the host share:
# Boot A: headless GOSH redirection writes /host/hello.txt through the file ABI.
# Boot B: headless GOSH cat reads the payload back and GOFILES lists /host.
# B1's kernel-owned native probe independently checks redirected EOF,
# separate HTML/JSON destinations, inheritance, close/panic and short writes.
# exec-order: assert-proven -- stream boot waits for the probe's exit.
# B2 runs one raw native fixture on both backends, with independent
# share-byte validation, real continuation/EOF and post-death page recovery.
# B4: one raw native-ABI probe runs against each backend. The host compares
# both publications, retained stages, failure receipts and trust metadata.
# Shared SDK: rich pages, native containment, honest refusals, publication
# and mixed-resource limits through the real Zig 0.16 EL0 adapter.
# B5 (#1895): pinned create/mkdir/remove/rename and handle metadata run a
# Boris-style stage/swap/park publication raw and through the SDK; the host
# checks the resulting tree, untouched refusals and reclaimed pins.

vgate_name live-user-fs "userland storage ABI & utilities on VZ"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 PAIRS

vgate_setup_python <<'PY'
import os, pathlib, shutil, subprocess, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name, script in (("GOSH.ELF", "build-gosh.sh"),
                      ("GOFILES.ELF", "build-files.sh")):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit("%s missing (expected %s) - build it first: bash tools/go/%s"
                 % (name, src, script))
    shutil.copy(src, os.path.join(share, name))
    print("staged %s into share (%d bytes)"
          % (name, os.path.getsize(os.path.join(share, name))))
linker = pathlib.Path(rd) / "streams.ld"
linker.write_text("""ENTRY(_start)
PHDRS { text PT_LOAD FLAGS(5); data PT_LOAD FLAGS(6); }
SECTIONS {
 . = 0x00400000;
 .text : { *(.text .text.*) *(.rodata .rodata.*) } :text
 . = ALIGN(4096) + 4096;
 .data : { *(.data .data.*) *(.bss .bss.*) } :data
 /DISCARD/ : { *(.eh_frame*) *(.note*) }
}
""")
subprocess.run([
    "zig", "build-exe", "kernel/tests/streams_guest.zig",
    "-target", "aarch64-freestanding-none", "-O", "ReleaseSafe",
    "-fsingle-threaded", "-fno-PIE", "-fno-stack-check", "-fno-stack-protector",
    "-fno-unwind-tables", "--script", str(linker), "-fentry=_start",
    "-femit-bin=" + os.path.join(share, "STREAMS.BIN"),
], check=True)
for tag, n in (("A", 5003), ("B", 7001)):
    data = bytes(65 + ((i * 7 + ord(tag)) % 26) for i in range(n))
    pathlib.Path(share, "B1.IN." + tag).write_bytes(data)
    pathlib.Path(rd, "expected-" + tag + ".html").write_bytes(b"<html>\n" + data + b"</html>\n")
pathlib.Path(rd, "expected-diagnostic.json").write_bytes(b'{"kind":"b1","eof":true}\n')
pathlib.Path(rd, "expected-panic.txt").write_bytes(b"b1: panic\n")
pathlib.Path(rd, "expected-empty.txt").write_bytes(b"")
PY

vgate_file script-A.txt <<'EOF'
set GOMAXPROCS=1
exec GOSH.ELF -c "echo Hello from VirelaiOS EL0 Storage! > /host/hello.txt"
EOF

vgate_file script-A2.txt <<'EOF'
procs
echo done-user-fs-write
EOF

vgate_file script-B.txt <<'EOF'
set GOMAXPROCS=1
exec GOSH.ELF -c "cat /host/hello.txt"
EOF

vgate_file script-B2.txt <<'EOF'
exec GOFILES.ELF /host
EOF

vgate_file script-B3.txt <<'EOF'
procs
echo done-user-fs-read
EOF

vgate_run A -- --script '$RUN_DIR/script-A.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script-A2.txt' --script2-after 'tasks user-exec exited status=0' --script-expect 'done-user-fs-write' --timeout 60
vgate_run B -- --display --screen '$RUN_DIR/screen' --via-virtio --script '$RUN_DIR/script-B.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script-B2.txt' --script2-after 'tasks user-exec exited status=0' --input-chords 'q' --input-chords-after 'gofiles: ready' --script3 '$RUN_DIR/script-B3.txt' --script3-after 'gofiles OK' --script-expect 'done-user-fs-read' --timeout 120

vgate_file script-streams.txt <<'EOF'
pages
exec STREAMS.BIN
EOF
vgate_file script-streams-after.txt <<'EOF'
pages
procs
syscalls
echo done-user-fs-streams
EOF
vgate_run streams -- --script '$RUN_DIR/script-streams.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/script-streams-after.txt' --script2-after 'b1: streams done' --script2-delay 1 --script-expect 'done-user-fs-streams' --timeout 90
vgate_assert streams serial-contains 'b1: streams done'
vgate_assert streams serial-absent 'b1: FAIL'
vgate_assert streams serial-absent '[EXC] parking'
vgate_assert streams serial-absent '{"kind":"b1","eof":true}'
vgate_assert streams serial-absent 'b1: panic'
vgate_assert streams share-equals B1.OUT.A expected-A.html
vgate_assert streams share-equals B1.OUT.B expected-B.html
vgate_assert streams share-equals B1.ERR.A expected-diagnostic.json
vgate_assert streams share-equals B1.ERR.B expected-diagnostic.json
vgate_assert streams share-equals B1.PANIC.OUT expected-empty.txt
vgate_assert streams share-equals B1.PANIC.ERR expected-panic.txt
vgate_assert streams python <<'PY'
import os, pathlib, re
rd = pathlib.Path(os.environ["RUN_DIR"])
share = pathlib.Path(os.environ["VG_SHARE"])
serial = pathlib.Path(os.environ["VG_SER"]).read_bytes()
assert b"b1-console:" + b"C" * 1103 + b"\n" in serial
assert serial.count(b"b1: streams done\n") == 1
statuses = re.findall(rb"procs STREAMS\.BIN exited status=(\d+)", serial)
assert statuses.count(b"0") == 4 and statuses.count(b"71") == 1, statuses
for tag, n in (("A", 5003), ("B", 7001)):
    source = share.joinpath("B1.IN." + tag).read_bytes()
    assert source == bytes(65 + ((i * 7 + ord(tag)) % 26) for i in range(n))
    assert share.joinpath("B1.OUT." + tag).read_bytes() == b"<html>\n" + source + b"</html>\n"
    assert share.joinpath("B1.ERR." + tag).read_bytes() == b'{"kind":"b1","eof":true}\n'
assert share.joinpath("B1.PANIC.OUT").read_bytes() == b""
assert share.joinpath("B1.PANIC.ERR").read_bytes() == b"b1: panic\n"
pages = re.findall(rb"^pages: armed=1 total=(0x[0-9a-f]+) free=(0x[0-9a-f]+)", serial, re.M)
assert len(pages) >= 2 and pages[0] == pages[-1], ("stream/EL0 page leak", pages)
print("B1: 12004 input bytes, 12034 HTML bytes, 2 JSON destinations, "
      "1103 console bytes; inherited close and panic isolation verified")
PY

vgate_assert A serial-contains 'exec: loaded GOSH.ELF'
vgate_assert A serial-contains 'tasks user-exec exited status=0'
vgate_assert A serial-contains 'procs GOSH.ELF exited status=0'
vgate_assert A serial-contains 'done-user-fs-write'
vgate_assert A serial-absent '[EXC] parking'

vgate_assert B serial-contains 'Hello from VirelaiOS EL0 Storage!'
vgate_assert B serial-contains 'procs GOSH.ELF exited status=0'
vgate_assert B serial-contains 'exec: loaded GOFILES.ELF'
vgate_assert B serial-contains 'gofiles: list /host'
vgate_assert B serial-contains 'gofiles: entry hello.txt file'
vgate_assert B serial-contains 'gofiles: ready'
vgate_assert B serial-contains 'gofiles: close'
vgate_assert B serial-contains 'gofiles OK'
vgate_assert B serial-contains 'procs GOFILES.ELF exited status=0'
vgate_assert B serial-contains 'done-user-fs-read'
vgate_assert B serial-absent '[EXC] parking'

vgate_assert B python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], "rb").read().decode("latin1", errors="replace").lower()
if "hello.txt" not in ser:
    sys.exit("ERROR: hello.txt missing from GOFILES enumeration")
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
hpath = os.path.join(share, "hello.txt")
if not os.path.exists(hpath):
    sys.exit("ERROR: hello.txt missing from host share")
data = open(hpath, "r", errors="replace").read()
if "Hello from VirelaiOS EL0 Storage!" not in data:
    sys.exit("ERROR: hello.txt content mismatch on host share")
print("user-fs ok: GOSH round-trip and GOFILES enumeration verified")
PY

vgate_setup_python <<'PY'
import os, pathlib, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
# Keep the wide B2 tree out of GOFILES' intentionally clamped legacy listing.
share = rd / "b2-legacy-share"
share.mkdir()
# Raw ELF exec loads RX and RW PT_LOADs. Include constants in the RX segment;
# the DSK3 converter's separate read-only-segment coalescing is not used here.
linker = rd / "b2.ld"
linker.write_text("""ENTRY(_start)
SECTIONS {
  . = 0x00400000;
  .text : ALIGN(16) { *(.text .text.*) *(.rodata .rodata.*) }
  . = ALIGN(4096) + 4096;
  .data : ALIGN(16) { *(.data .data.*) }
  .bss : ALIGN(16) { *(.bss .bss.*) }
  /DISCARD/ : { *(.note.*) *(.eh_frame .eh_frame_hdr) *(.ARM.exidx*) }
}
""")
subprocess.run(["zig", "build-exe", "-target", "aarch64-freestanding-none",
    "-O", "ReleaseSafe", "-fentry=_start", "-fno-PIE",
    "-fsingle-threaded", "-T", str(linker),
    "--dep", "directory", "-Mroot=tests/dir-enum.zig",
    "-Mdirectory=kernel/src/directory.zig", "-femit-bin=" + str(share / "B2.ELF")], check=True)
names = [f"entry-{i:02d}" for i in range(35)] + [
    "p" * 31 + "-one", "p" * 31 + "-two", "x" * 255, ".hidden", "last"]
expected = "".join(n + "\n" for n in sorted(names)).encode()
(rd / "b2-expected.txt").write_bytes(expected)
# Each backend gets its own identically seeded tree and mutation fixture.
virtio = rd / "virtio-share"
virtio.mkdir()
for root in (share, virtio):
    if root != share:
        (root / "B2.ELF").write_bytes((share / "B2.ELF").read_bytes())
    (root / "B2").mkdir()
    for name in names:
        (root / "B2" / name).write_bytes(b"entry-data")
    for dirname, count in (("B2LIMIT", 256), ("B2OVER", 257)):
        (root / dirname).mkdir()
        for i in range(count):
            (root / dirname / f"f-{i:03d}").write_bytes(b"")
    (root / ("a" * 250) / ("b" * 255)).mkdir(parents=True)
    (root / ("a" * 250) / ("b" * 255) / "leaf").write_bytes(b"leaf")
    (root / "d/e/e/e/e/e/e/e").mkdir(parents=True)
    (root / "B2DENIED").mkdir()
    (root / "B2MUTATE").mkdir()
    (root / "B2MUTATE/old").write_bytes(b"old")
    (root / "OWNERS.TXT").write_text("#v1\nB2DENIED\t600\t0\t-\n")
PY

vgate_file b2-start.txt <<'EOF'
pages
exec B2.ELF
EOF

vgate_file b2-after.txt <<'EOF'
pages
procs
echo done-b2
EOF

vgate_run b2-legacy -- --cvc-file '$RUN_DIR/b2-legacy-share' --script '$RUN_DIR/b2-start.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/b2-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'done-b2' --timeout 120
# VirtioFS wins backend selection when both devices exist. Stage an
# independent identical share; the harness still owns the legacy device.
vgate_run b2-virtiofs -- --virtio-fs '$RUN_DIR/virtio-share' --script '$RUN_DIR/b2-start.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/b2-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'done-b2' --timeout 120

vgate_assert b2-legacy serial-exact 'b2: lossless count=40 pages=6 eof=1' 1
vgate_assert b2-legacy serial-exact 'b2: entries 256 accepted 257 refused' 1
vgate_assert b2-legacy serial-exact 'b2: path 512 accepted 513 refused depth 8 accepted 9 refused acl denied' 1
vgate_assert b2-legacy serial-exact 'b2: stable snapshot mutation ok' 1
vgate_assert b2-legacy serial-exact 'b2: capacity close ok death cursors=8' 1
vgate_assert b2-legacy serial-exact 'tasks user-exec exited status=0' 1
vgate_assert b2-legacy serial-absent 'b2: FAIL'
vgate_assert b2-legacy serial-absent '[EXC]'
vgate_assert b2-legacy python <<'PY'
import os, pathlib, re, shutil
rd = pathlib.Path(os.environ["RUN_DIR"])
actual = rd / "b2-legacy-share/B2.RECEIPT"
assert actual.read_bytes() == (rd / "b2-expected.txt").read_bytes()
shutil.copyfile(actual, pathlib.Path("artifacts/live-user-fs-b2-legacy-receipt.txt"))
lines = pathlib.Path(os.environ["VG_SER"]).read_text()
pages = re.findall(r"^pages: armed=1 total=(0x[0-9a-f]+) free=(0x[0-9a-f]+)", lines, re.M)
assert len(pages) >= 2 and pages[0] == pages[-1], ("cursor/EL0 page leak", pages)
PY

vgate_assert b2-virtiofs serial-exact 'b2: lossless count=40 pages=6 eof=1' 1
vgate_assert b2-virtiofs serial-exact 'b2: entries 256 accepted 257 refused' 1
vgate_assert b2-virtiofs serial-exact 'b2: path 512 accepted 513 refused depth 8 accepted 9 refused acl denied' 1
vgate_assert b2-virtiofs serial-exact 'b2: stable snapshot mutation ok' 1
vgate_assert b2-virtiofs serial-exact 'b2: capacity close ok death cursors=8' 1
vgate_assert b2-virtiofs serial-exact 'tasks user-exec exited status=0' 1
vgate_assert b2-virtiofs serial-absent 'b2: FAIL'
vgate_assert b2-virtiofs serial-absent '[EXC]'
vgate_assert b2-virtiofs python <<'PY'
import os, pathlib, re, shutil
rd = pathlib.Path(os.environ["RUN_DIR"])
actual = rd / "virtio-share/B2.RECEIPT"
assert actual.read_bytes() == (rd / "b2-expected.txt").read_bytes()
shutil.copyfile(actual, pathlib.Path("artifacts/live-user-fs-b2-virtiofs-receipt.txt"))
lines = pathlib.Path(os.environ["VG_SER"]).read_text()
pages = re.findall(r"^pages: armed=1 total=(0x[0-9a-f]+) free=(0x[0-9a-f]+)", lines, re.M)
assert len(pages) >= 2 and pages[0] == pages[-1], ("cursor/EL0 page leak", pages)
PY

# This is a gate-only ABI probe, not an additional Zig product/SDK adapter.
vgate_file publish.ld <<'EOF'
ENTRY(_start)
PHDRS {
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}
SECTIONS {
    . = 0x00400000;
    .text : { *(.text .text.*) } :text
    .rodata : { *(.rodata .rodata.*) } :text
    . = ALIGN(4096) + 4096;
    .data : { BYTE(0); *(.data .data.*) } :data
    .bss (NOLOAD) : { *(.bss .bss.*) } :data
    /DISCARD/ : { *(.note.*) *(.eh_frame .eh_frame_hdr) }
}
EOF

vgate_file publish.zig <<'EOF'
const replace_bit: u64 = @as(u64, 1) << 63;

fn svc(number: u64, a0: u64, a1: u64, a2: u64, a3: u64) i64 {
    var result: i64 = undefined;
    asm volatile ("svc #0"
        : [result] "={x0}" (result),
        : [number] "{x8}" (number),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
          [unused4] "{x4}" (@as(u64, 0x1234)),
          [unused5] "{x5}" (@as(u64, 0x5678)),
        : .{ .memory = true });
    return result;
}

fn say(message: []const u8) void {
    _ = svc(1, 1, @intFromPtr(message.ptr), message.len, 0);
}

fn expect(result: i64, wanted: i64) void {
    if (result != wanted) {
        say("b4: FAIL native result\n");
        _ = svc(3, 1, 0, 0, 0);
        while (true) {}
    }
}

fn write(path: []const u8, body: []const u8) void {
    const fd = svc(23, @intFromPtr(path.ptr), path.len, 6, 0);
    if (fd < 0) expect(fd, 0);
    expect(svc(25, @intCast(fd), @intFromPtr(body.ptr), body.len, 0), @intCast(body.len));
    expect(svc(77, @intCast(fd), 0, 0, 0), 0);
    expect(svc(26, @intCast(fd), 0, 0, 0), 0);
}

fn read(path: []const u8, body: []const u8) void {
    read_checked(path, body, null);
}

fn read_checked(path: []const u8, body: []const u8, copy: ?[]const u8) void {
    const fd = svc(23, @intFromPtr(path.ptr), path.len, 1, 0);
    if (fd < 0) expect(fd, 0);
    var bytes: [128]u8 = undefined;
    expect(svc(24, @intCast(fd), @intFromPtr(&bytes), bytes.len, 0), @intCast(body.len));
    for (body, 0..) |byte, i| expect(bytes[i], byte);
    expect(svc(26, @intCast(fd), 0, 0, 0), 0);
    if (copy) |copy_path| write(copy_path, bytes[0..body.len]);
}

fn rename(from: []const u8, to: []const u8, replace: bool) i64 {
    const length = from.len | (if (replace) replace_bit else @as(u64, 0));
    return svc(35, @intFromPtr(from.ptr), length, @intFromPtr(to.ptr), to.len);
}

export fn b4_main() noreturn {
    write("/host/B4/stage", "first publication\n");
    expect(rename("/host/B4/stage", "/host/B4/output", true), 0);
    read_checked("/host/B4/output", "first publication\n", "/host/B4/first.copy");
    write("/host/B4/stage", "second publication\n");
    expect(rename("/host/B4/stage", "/host/B4/output", true), 0);
    read("/host/B4/output", "second publication\n");
    say("b4: two publications ok\n");

    write("/host/B4/stage", "retained stage\n");
    expect(rename("/host/B4/stage", "/host/B4/output", false), -9);
    read("/host/B4/output", "second publication\n");
    read("/host/B4/stage", "retained stage\n");
    expect(rename("/host/B4/stage", "/host/B4/fresh", false), 0);
    read("/host/B4/fresh", "retained stage\n");
    say("b4: no-overwrite EEXIST and fresh rename ok\n");

    // Inject a missing-stage failure, then an actual backend type conflict.
    expect(rename("/host/B4/missing", "/host/B4/output", true), -6);
    expect(rename("/host/B4/directory", "/host/B4/output", true), -1);
    read("/host/B4/output", "second publication\n");
    say("b4: replacement ENOENT and EINVAL preserve output\n");

    // Four both-end policy failures, through the actual native syscall.
    expect(rename("/host/B4/denied-src", "/host/B4/output", true), -7);
    write("/host/B4/stage", "retained stage\n");
    expect(rename("/host/B4/stage", "/host/B4/denied-dst", true), -7);
    expect(rename("/host/B4/secret-src", "/host/B4/output", true), -7);
    expect(rename("/host/B4/stage", "/host/B4/secret-dst", true), -7);
    // The preserve-existing operation has the same policy, not a bypass.
    expect(rename("/host/B4/denied-src", "/host/B4/output", false), -7);
    expect(rename("/host/B4/stage", "/host/B4/denied-dst", false), -7);
    read("/host/B4/stage", "retained stage\n");
    read("/host/B4/output", "second publication\n");
    say("b4: both-end permission and secret EACCES ok\n");

    const source = "/host/B4/stage";
    const destination = "/host/B4/output";
    expect(svc(35, @intFromPtr(source.ptr), source.len | replace_bit | (@as(u64, 1) << 62),
        @intFromPtr(destination.ptr), destination.len), -1);
    expect(svc(35, 0xfffffffffffff000, source.len | replace_bit,
        @intFromPtr(destination.ptr), destination.len), -3);
    expect(svc(35, @intFromPtr(source.ptr), source.len | replace_bit,
        0xfffffffffffff000, destination.len), -3);
    read("/host/B4/output", "second publication\n");
    write("/host/B4/receipt", "publications=2 refusals=12 failed=0\n");
    say("b4: PASS publications=2 refusals=12\n");
    _ = svc(3, 0, 0, 0, 0);
    while (true) {}
}

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\bl b4_main
    );
}
EOF

vgate_file script-publish.txt <<'EOF'
settings set hostname b4-first
settings set hostname b4-second
exec B4PUB.ELF
EOF

vgate_file script-publish-done.txt <<'EOF'
echo done-b4-publication
EOF

vgate_file b4-first.txt <<'EOF'
first publication
EOF
vgate_file b4-second.txt <<'EOF'
second publication
EOF
vgate_file b4-stage.txt <<'EOF'
retained stage
EOF
vgate_file b4-receipt.txt <<'EOF'
publications=2 refusals=12 failed=0
EOF

vgate_setup_python <<'PY'
import os, subprocess
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
subprocess.run([
    "zig", "build-exe", "-target", "aarch64-freestanding-none",
    "-O", "ReleaseSafe", "-fstrip", "-fno-stack-check", "-T", os.path.join(rd, "publish.ld"),
    os.path.join(rd, "publish.zig"), "-femit-bin=" + os.path.join(share, "B4PUB.ELF")
], check=True)
# Disjoint per-backend fixtures: the VirtioFS run also attaches the legacy
# share, so wrong backend dispatch cannot pass the independent host checks.
policy = ("#v1\n"
          "B4/denied-src\t400\t1000\t-\n"
          "B4/denied-dst\t400\t1000\t-\n"
          "B4/secret-src\t600\t0\tsecret\n"
          "B4/secret-dst\t600\t0\tsecret\n"
          "B4/stage\t600\t1000\t-\n"
          "B4/output\t606\t0\t-\n")
for root in (share, os.path.join(rd, "virtiofs")):
    os.makedirs(os.path.join(root, "B4", "directory"), exist_ok=True)
    if root != share:
        import shutil
        shutil.copy(os.path.join(share, "B4PUB.ELF"), os.path.join(root, "B4PUB.ELF"))
    for name, body in (("output", "original publication\n"),
                       ("denied-src", "denied source\n"),
                       ("denied-dst", "denied destination\n"),
                       ("secret-src", "secret source\n"),
                       ("secret-dst", "secret destination\n")):
        open(os.path.join(root, "B4", name), "w").write(body)
    open(os.path.join(root, "OWNERS.TXT"), "w").write(policy)
print("B4 native probe bytes=%d; no SDK dependencies or extra handles" %
      os.path.getsize(os.path.join(share, "B4PUB.ELF")))
PY

vgate_run publish-legacy -- --script '$RUN_DIR/script-publish.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/script-publish-done.txt' \
    --script2-after 'tasks user-exec exited status=0' \
    --script-expect 'done-b4-publication' --timeout 60
vgate_assert publish-legacy serial-contains 'b4: PASS publications=2 refusals=12'
vgate_assert publish-legacy serial-contains 'settings: hostname=b4-first (persisted)'
vgate_assert publish-legacy serial-contains 'settings: hostname=b4-second (persisted)'
vgate_assert publish-legacy serial-absent 'b4: FAIL'
vgate_assert publish-legacy serial-absent '[EXC] parking'
vgate_assert publish-legacy output-contains 'VF-FILE: REPLACE B4/stage'
vgate_assert publish-legacy share-equals B4/first.copy $'first publication\n'
vgate_assert publish-legacy share-equals B4/output $'second publication\n'
vgate_assert publish-legacy share-equals B4/stage $'retained stage\n'
vgate_assert publish-legacy share-equals B4/fresh $'retained stage\n'
vgate_assert publish-legacy share-equals B4/receipt b4-receipt.txt
vgate_assert publish-legacy share-equals B4/denied-src $'denied source\n'
vgate_assert publish-legacy share-equals B4/denied-dst $'denied destination\n'
vgate_assert publish-legacy share-equals B4/secret-src $'secret source\n'
vgate_assert publish-legacy share-equals B4/secret-dst $'secret destination\n'
vgate_assert publish-legacy share-contains OWNERS.TXT $'B4/secret-dst\t600\t0\tsecret'
vgate_assert publish-legacy share-contains SETTINGS.TXT 'hostname=b4-second'
vgate_assert publish-legacy python <<'PY'
import os
root = os.environ["VG_SHARE"]
assert os.path.isdir(os.path.join(root, "B4", "directory"))
assert open(os.path.join(os.environ["RUN_DIR"], "virtiofs", "B4", "output"), "rb").read() == b"original publication\n"
body = open(os.path.join(root, "OWNERS.TXT")).read()
for entry in ("B4/denied-src\t400\t1000\t-", "B4/denied-dst\t400\t1000\t-",
              "B4/secret-src\t600\t0\tsecret", "B4/secret-dst\t600\t0\tsecret"):
    assert entry in body, entry
assert "B4/stage\t" not in body
assert "B4/output\t" not in body  # Second stage had implicit/default metadata.
print("legacy: both publications, retained failure source, policies and backend dispatch verified")
PY

vgate_run publish-virtiofs -- --virtio-fs '$RUN_DIR/virtiofs' \
    --script '$RUN_DIR/script-publish.txt' \
    --script-after 'tasks user-el0 exited status=7' \
    --script2 '$RUN_DIR/script-publish-done.txt' \
    --script2-after 'tasks user-exec exited status=0' \
    --script-expect 'done-b4-publication' --timeout 60
vgate_assert publish-virtiofs serial-contains 'b4: PASS publications=2 refusals=12'
vgate_assert publish-virtiofs serial-contains 'settings: hostname=b4-first (persisted)'
vgate_assert publish-virtiofs serial-contains 'settings: hostname=b4-second (persisted)'
vgate_assert publish-virtiofs serial-absent 'b4: FAIL'
vgate_assert publish-virtiofs serial-absent '[EXC] parking'
vgate_assert publish-virtiofs serial-contains 'virtio-fs: ready did=0x105a'
vgate_assert publish-virtiofs python <<'PY'
import os, shutil
rd = os.environ["RUN_DIR"]
root = os.path.join(rd, "virtiofs")
expected = {
    "first.copy": b"first publication\n", "output": b"second publication\n",
    "stage": b"retained stage\n", "fresh": b"retained stage\n",
    "receipt": b"publications=2 refusals=12 failed=0\n",
    "denied-src": b"denied source\n", "denied-dst": b"denied destination\n",
    "secret-src": b"secret source\n", "secret-dst": b"secret destination\n",
}
for name, want in expected.items():
    path = os.path.join(root, "B4", name)
    assert open(path, "rb").read() == want, name
    shutil.copy(path, os.path.join(rd, "virtiofs-" + name))
assert os.path.isdir(os.path.join(root, "B4", "directory"))
body = open(os.path.join(root, "OWNERS.TXT")).read()
assert "B4/output\t" not in body
assert "B4/stage\t" not in body
for entry in ("B4/denied-src\t400\t1000\t-", "B4/denied-dst\t400\t1000\t-",
              "B4/secret-src\t600\t0\tsecret", "B4/secret-dst\t600\t0\tsecret"):
    assert entry in body, entry
shutil.copy(os.path.join(root, "OWNERS.TXT"), os.path.join(rd, "virtiofs-owners"))
assert "hostname=b4-second\n" in open(os.path.join(root, "SETTINGS.TXT")).read()
print("VirtioFS: 9 independent byte comparisons, directory/source preservation and both-end policy verified")
PY
vgate_assert publish-virtiofs capture-equals virtiofs-first.copy b4-first.txt
vgate_assert publish-virtiofs capture-equals virtiofs-output b4-second.txt
vgate_assert publish-virtiofs capture-equals virtiofs-stage b4-stage.txt
vgate_assert publish-virtiofs capture-equals virtiofs-fresh b4-stage.txt
vgate_assert publish-virtiofs capture-equals virtiofs-receipt b4-receipt.txt

# B3: raw EL0 metadata/containment, not a host-side scanner or C-card SDK.
vgate_setup_python <<'PY'
import os, pathlib, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
roots = [rd / "b3-legacy", rd / "b3-virtiofs"]
for root in roots:
    (root / "content/a/b").mkdir(parents=True)
    (root / "content/a/b/page.md").write_bytes(b"safe")
    for i in range(20):
        (root / "content" / f"entry-{i:02}").write_bytes(b"row")
    for name in ("p" * 31 + "-one", "x" * 255):
        (root / "content" / name).write_bytes(b"long")
    (root / "outside/b").mkdir(parents=True)
    (root / "outside/b/page.md").write_bytes(b"outside must stay untouched\n")
    (root / "B3LINKS").mkdir()
    (root / "B3LINKS/leaf").symlink_to("../outside/b/page.md")
    (root / "B3LINKS/dir").symlink_to("../outside/b")
    (root / "B3LINKS/dangling").symlink_to("../absent")
    (root / "ROOTLINK").symlink_to("content")
    (root / "SWAPDIR").symlink_to("outside")
    (root / "SWAPLEAF").symlink_to("../../../outside/b/page.md")
    (root / "DENIED").write_bytes(b"denied\n")
    (root / "SECRET").write_bytes(b"secret fixture\n")
    (root / "DENIEDDIR").mkdir()
    (root / "DENIEDDIR/leaf").write_bytes(b"denied\n")
    # B5: a live output tree for the pinned Boris-style publication.
    (root / "PUB/out/keep").mkdir(parents=True)
    (root / "PUB/out/old.html").write_bytes(b"old output\n")
    (root / "PUB/link").symlink_to("../outside")
    (root / "PUB/denied").write_bytes(b"denied pub\n")
    (root / "PUB/secret").write_bytes(b"secret pub\n")
    (root / "OWNERS.TXT").write_text(
        "#v1\nDENIED\t600\t0\t-\nSECRET\t600\t0\tsecret\nDENIEDDIR\t600\t0\t-\n"
        "PUB/denied\t600\t0\t-\nPUB/secret\t600\t0\tsecret\n")
subprocess.run(["zig", "build-exe", "-target", "aarch64-freestanding-none",
    "-O", "ReleaseSafe", "-fentry=_start", "-fno-PIE", "-fsingle-threaded",
    "-T", str(rd / "streams.ld"), "--dep", "metadata",
    "-Mroot=tests/fs-metadata.zig", "-Mmetadata=kernel/src/fs_metadata.zig",
    "-femit-bin=" + str(roots[0] / "B3.ELF")], check=True)
(roots[1] / "B3.ELF").write_bytes((roots[0] / "B3.ELF").read_bytes())
print("B3 raw ELF bytes=%d; nested 3-directory/25-entry discovery corpus" %
      (roots[0] / "B3.ELF").stat().st_size)
PY

vgate_file b3-start.txt <<'EOF'
pages
exec B3.ELF
EOF
vgate_file b3-after.txt <<'EOF'
pages
procs
echo done-b3
EOF
vgate_run b3-legacy -- --cvc-file '$RUN_DIR/b3-legacy' --script '$RUN_DIR/b3-start.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/b3-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'done-b3' --timeout 120
vgate_run b3-virtiofs -- --virtio-fs '$RUN_DIR/b3-virtiofs' --script '$RUN_DIR/b3-start.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/b3-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'done-b3' --timeout 120
vgate_assert b3-legacy serial-exact 'b3: legacy explicitly unsupported operations=5' 1
vgate_assert b3-legacy serial-exact 'b5: legacy explicitly unsupported pin=1 path-fd=1 unbound=1' 1
vgate_assert b3-legacy serial-absent 'b3: FAIL'
vgate_assert b3-legacy serial-absent '[EXC]'
vgate_assert b3-legacy python <<'PY'
import os, pathlib
root = pathlib.Path(os.environ["RUN_DIR"]) / "b3-legacy"
assert (root / "content/a/b/page.md").read_bytes() == b"safe"
assert (root / "outside/b/page.md").read_bytes() == b"outside must stay untouched\n"
assert sorted(p.name for p in (root / "PUB").iterdir()) == ["denied", "link", "out", "secret"]
assert (root / "PUB/out/old.html").read_bytes() == b"old output\n"
PY
vgate_assert b3-virtiofs serial-exact 'b3: nested discovery directories=3 stable distinct' 1
vgate_assert b3-virtiofs serial-exact 'b3: directory rows=23 pages=4 long-names=2 fresh metadata' 1
vgate_assert b3-virtiofs serial-exact 'b3: Boris-style discovery directories=3 entries=25 cycles=0' 1
vgate_assert b3-virtiofs serial-exact 'b3: no-follow refusals=17 root intermediate leaf dangling' 1
vgate_assert b3-virtiofs serial-exact 'b3: watch independent mtime and size changes detected' 1
vgate_assert b3-virtiofs serial-exact 'b3: replacement races pinned reads survive and rebound mutation refused' 1
vgate_assert b3-virtiofs serial-exact 'b3: ownership and secret refusals=7' 1
vgate_assert b3-virtiofs serial-exact 'b5: pin metadata own-object path-fd unsupported symlink refused' 1
vgate_assert b3-virtiofs serial-exact 'b5: staged directories=2 files=2 exclusive EEXIST=2' 1
vgate_assert b3-virtiofs serial-exact 'b5: Boris publish EEXIST=2 park swap remove stale-refusals=2' 1
vgate_assert b3-virtiofs serial-exact 'b5: atomic replace preserve EEXIST replace ok slot-35 stales pins' 1
vgate_assert b3-virtiofs serial-exact 'b5: stale-inode write truncate sync refuse a rebound name' 1
vgate_assert b3-virtiofs serial-exact 'b5: refusals names=6 registers=7 policy=7 tokens=4' 1
vgate_assert b3-virtiofs serial-contains 'b3: PASS checks='
vgate_assert b3-virtiofs serial-absent 'b3: FAIL'
vgate_assert b3-virtiofs serial-absent '[EXC]'
vgate_assert b3-virtiofs python <<'PY'
import os, pathlib, re
root = pathlib.Path(os.environ["RUN_DIR"]) / "b3-virtiofs"
assert (root / "content/a/b/page.md").read_bytes() == b"safe!"
assert (root / "outside/b/page.md").read_bytes() == b"outside must stay untouched\n"
assert (root / "SWAPDIR").is_symlink() and (root / "SWAPLEAF").is_symlink()
assert (root / "DENIED").read_bytes() == b"denied\n"
assert (root / "SECRET").read_bytes() == b"secret fixture\n"
serial = pathlib.Path(os.environ["VG_SER"]).read_text()
assert "secret fixture" not in serial and "outside must stay untouched" not in serial
pages = re.findall(r"^pages: armed=1 total=(0x[0-9a-f]+) free=(0x[0-9a-f]+)", serial, re.M)
assert len(pages) >= 2 and pages[0][0] == pages[-1][0], pages
assert pages[0] == pages[-1], ("B3 pages not reclaimed after reap", pages)
checks = re.search(r"b3: PASS checks=(\d+) death-cursors=4 death-pins=4", serial)
assert checks and int(checks[1]) >= 400, checks
# B5: only the published tree remains; refused names and policy entries are untouched.
pub = root / "PUB"
assert sorted(p.name for p in pub.iterdir()) == ["denied", "link", "out", "secret"], list(pub.iterdir())
assert sorted(p.name for p in (pub / "out").iterdir()) == ["assets", "index.html"]
assert sorted(p.name for p in (pub / "out/assets").iterdir()) == ["site.css"]
assert (pub / "out/index.html").read_bytes() == b"<p>v2</p>\n"
assert (pub / "out/assets/site.css").read_bytes() == b"p{}\n"
assert (pub / "link").is_symlink() and os.readlink(pub / "link") == "../outside"
assert (pub / "denied").read_bytes() == b"denied pub\n"
assert (pub / "secret").read_bytes() == b"secret pub\n"
for created in (pub / "out", pub / "out/assets", pub / "out/index.html", pub / "out/assets/site.css"):
    assert created.lstat().st_mode & 0o022 == 0, (created, oct(created.lstat().st_mode))
owners = (root / "OWNERS.TXT").read_text()
assert "PUB/denied\t600\t0\t-" in owners and "PUB/secret\t600\t0\tsecret" in owners, owners
print("B3: native metadata checks=%s; 4 rich death cursors and 4 pins reclaimed, outside unchanged" % checks[1])
print("B5: pinned stage/swap/park/remove and atomic replace verified on the host share")
PY

vgate_setup_python <<'PY'
import json, os, pathlib, shutil, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
subprocess.run(["python3", "tools/zig/fs.py", "--work", str(rd / "sdk-build")], check=True)
names = sorted([f"entry-{i:02}" for i in range(20)] +
               ["p" * 31 + "-one", "p" * 31 + "-two", "x" * 255, "nested"])
(rd / "sdk-names").write_bytes(b"".join(n.encode() + b"\n" for n in names))
for backend in ("legacy", "virtiofs"):
    root = rd / ("sdk-" + backend)
    (root / "SDK/content/nested/deep").mkdir(parents=True)
    (root / "SDK/content/nested/deep/page").write_bytes(b"safe")
    for name in names:
        if name != "nested":
            (root / "SDK/content" / name).write_bytes(b"row")
    # Host mode is a factual attribute, not the Virelai guest ACL.
    (root / "SDK/content/entry-00").chmod(0o600)
    st = (root / "SDK/content/entry-00").stat()
    (rd / ("sdk-" + backend + "-facts.json")).write_text(json.dumps(
        dict(mode=st.st_mode, uid=st.st_uid, gid=st.st_gid, size=st.st_size, mtime=st.st_mtime_ns)))
    (root / "SDK/directory").mkdir()
    (root / "SDK/outside/deep").mkdir(parents=True)
    (root / "SDK/outside/deep/page").write_bytes(b"outside unchanged\n")
    (root / "SDK/LINKS").mkdir()
    (root / "SDK/LINKS/leaf").symlink_to("../outside/deep/page")
    (root / "SDK/LINKS/dir").symlink_to("../outside")
    (root / "SDK/LINKS/dangling").symlink_to("../missing")
    (root / "SDK/root-link").symlink_to("content")
    (root / "SDK/SWAP").symlink_to("../outside")
    (root / "SDK/denied").write_bytes(b"denied unchanged\n")
    (root / "SDK/secret").write_bytes(b"secret fixture unchanged\n")
    (root / "SDK/denied-dir").mkdir()
    (root / "SDK/denied-dir/leaf").write_bytes(b"denied\n")
    (root / "SDK/PUB/out/keep").mkdir(parents=True)
    (root / "SDK/PUB/out/old.html").write_bytes(b"old output\n")
    (root / "SDK/PUB/link").symlink_to("../outside")
    (root / "SDK/PUB/denied").write_bytes(b"denied pub\n")
    (root / "SDK/PUB/secret").write_bytes(b"secret pub\n")
    (root / "OWNERS.TXT").write_text(
        "#v1\nSDK/denied\t600\t0\t-\nSDK/secret\t600\t0\tsecret\nSDK/denied-dir\t600\t0\t-\n"
        "SDK/PUB/denied\t600\t0\t-\nSDK/PUB/secret\t600\t0\tsecret\n")
    (root / ("a" * 250) / ("b" * 255)).mkdir(parents=True)
    (root / "d/e/e/e/e/e/e/e").mkdir(parents=True)
    for directory, count in (("LIMIT", 256), ("OVER", 257)):
        (root / directory).mkdir()
        for i in range(count):
            (root / directory / f"f-{i:03}").write_bytes(b"")
    shutil.copyfile(rd / "sdk-build/ZFS.BIN", root / "ZFS.BIN")
PY

vgate_file sdk-legacy.txt <<'EOF'
pages
exec ZFS.BIN legacy
EOF
vgate_file sdk-virtiofs.txt <<'EOF'
pages
exec ZFS.BIN virtiofs
EOF
vgate_file sdk-bounds.txt <<'EOF'
pages
exec ZFS.BIN bounds
EOF
vgate_file sdk-over.txt <<'EOF'
pages
exec ZFS.BIN over
EOF
vgate_file sdk-after.txt <<'EOF'
pages
procs
echo done-zig-fs
EOF
vgate_run sdk-legacy -- --cvc-file '$RUN_DIR/sdk-legacy' --script '$RUN_DIR/sdk-legacy.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/sdk-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'done-zig-fs' --timeout 120
vgate_run sdk-virtiofs -- --virtio-fs '$RUN_DIR/sdk-virtiofs' --script '$RUN_DIR/sdk-virtiofs.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/sdk-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'done-zig-fs' --timeout 120
vgate_run sdk-bounds -- --virtio-fs '$RUN_DIR/sdk-virtiofs' --script '$RUN_DIR/sdk-bounds.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/sdk-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'done-zig-fs' --timeout 120
vgate_run sdk-over -- --virtio-fs '$RUN_DIR/sdk-virtiofs' --script '$RUN_DIR/sdk-over.txt' --script-after 'tasks user-el0 reaped' --script2 '$RUN_DIR/sdk-after.txt' --script2-after 'tasks user-exec reaped' --script-expect 'done-zig-fs' --timeout 120
vgate_assert sdk-legacy serial-contains 'zig-fs: legacy unsupported=8 no leaked records'
vgate_assert sdk-legacy serial-contains 'zig-fs: publications=2 failure-preservation refusals=8'
vgate_assert sdk-legacy serial-contains 'zig-fs: PASS'
vgate_assert sdk-legacy serial-absent 'zig-fs: FAIL'
vgate_assert sdk-legacy serial-absent '[EXC]'
vgate_assert sdk-legacy python <<'PY'
import os, pathlib, re
rd = pathlib.Path(os.environ["RUN_DIR"])
root = rd / "sdk-legacy/SDK"
assert (root / "output").read_bytes() == b"second publication\n"
assert (root / "stage").read_bytes() == b"retained stage\n"
assert (root / "denied").read_bytes() == b"denied unchanged\n"
assert (root / "secret").read_bytes() == b"secret fixture unchanged\n"
assert (root / "content/nested/deep/page").read_bytes() == b"safe"
assert sorted(p.name for p in (root / "PUB").iterdir()) == ["denied", "link", "out", "secret"]
assert (root / "PUB/out/old.html").read_bytes() == b"old output\n"
serial = pathlib.Path(os.environ["VG_SER"]).read_text()
assert "procs ZFS.BIN exited status=0" in serial
pages = re.findall(r"^pages: armed=1 total=(0x[0-9a-f]+) free=(0x[0-9a-f]+)", serial, re.M)
assert len(pages) >= 2 and pages[0] == pages[-1], pages
PY
vgate_assert sdk-virtiofs serial-contains 'zig-fs: rich rows=24 pages=4 long-names=3 identities=stable'
vgate_assert sdk-virtiofs serial-contains 'zig-fs: nofollow and guest permissions refused=15'
vgate_assert sdk-virtiofs serial-contains 'zig-fs: pinned reads/writes/fd-metadata survive replacement; File.stat refused'
vgate_assert sdk-virtiofs serial-contains 'zig-fs: pinned publication staged=4 swapped parked-removed stale-refusals=2'
vgate_assert sdk-virtiofs serial-contains 'zig-fs: pinned atomic replace; names symlinks and ACLs refused=11'
vgate_assert sdk-virtiofs serial-contains 'zig-fs: resources=8 overflow refused finish-cursors=4'
vgate_assert sdk-virtiofs serial-contains 'zig-fs: PASS'
vgate_assert sdk-virtiofs serial-absent 'zig-fs: FAIL'
vgate_assert sdk-virtiofs serial-absent '[EXC]'
vgate_assert sdk-virtiofs python <<'PY'
import json, os, pathlib, re, shutil
rd = pathlib.Path(os.environ["RUN_DIR"])
root = rd / "sdk-virtiofs/SDK"
assert (root / "names").read_bytes() == (rd / "sdk-names").read_bytes()
assert (root / "output").read_bytes() == b"second publication\n"
assert (root / "stage").read_bytes() == b"retained stage\n"
assert (root / "content/nested/deep/page").read_bytes() == b"pinned"
assert (root / "outside/deep/page").read_bytes() == b"outside unchanged\n"
assert (root / "denied").read_bytes() == b"denied unchanged\n"
assert (root / "secret").read_bytes() == b"secret fixture unchanged\n"
assert not (root / "overflow").exists()
pub = root / "PUB"
assert sorted(p.name for p in pub.iterdir()) == ["denied", "link", "out", "secret"], list(pub.iterdir())
assert sorted(p.name for p in (pub / "out").iterdir()) == ["assets", "index.html"]
assert (pub / "out/index.html").read_bytes() == b"<p>v2</p>\n"
assert (pub / "out/assets/site.css").read_bytes() == b"p{}\n"
assert (pub / "link").is_symlink()
assert (pub / "denied").read_bytes() == b"denied pub\n"
assert (pub / "secret").read_bytes() == b"secret pub\n"
serial = pathlib.Path(os.environ["VG_SER"]).read_text()
assert "procs ZFS.BIN exited status=0" in serial
facts = json.loads((rd / "sdk-virtiofs-facts.json").read_text())
observed = re.search(r"zig-fs: host-mode=(\d+) uid=(\d+) gid=(\d+) size=(\d+) mtime=(\d+)", serial)
assert observed, serial
values = [int(v) for v in observed.groups()]
assert [values[0], values[3], values[4]] == [facts["mode"], facts["size"], facts["mtime"]], (values, facts)
owners = re.search(r"zig-fs: native-owners uid=(\d+) gid=(\d+)", serial)
assert owners and values[1:3] == [int(v) for v in owners.groups()], (values, owners)
print("SDK: native uid/gid=%s; macOS uid/gid=%s (backend mapping, not guest ACL)" %
      (values[1:3], [facts["uid"], facts["gid"]]))
usage = re.search(r"zig-fs: PASS checks=(\d+) arena_peak=(\d+) stack_high_water=(\d+)", serial)
assert usage and int(usage[1]) >= 80 and int(usage[2]) <= 1024*1024 and int(usage[3]) <= 128*1024, usage
pages = re.findall(r"^pages: armed=1 total=(0x[0-9a-f]+) free=(0x[0-9a-f]+)", serial, re.M)
assert len(pages) >= 2 and pages[0] == pages[-1], pages
shutil.copyfile(root / "names", rd / "sdk-actual-names")
print("SDK: independent names, bytes, metadata and cleanup verified")
PY
vgate_assert sdk-virtiofs capture-equals sdk-actual-names sdk-names
vgate_assert sdk-bounds serial-contains 'zig-fs: path=512 name=255 depth=8 entries=256 path-over refused'
vgate_assert sdk-bounds serial-contains 'zig-fs: PASS'
vgate_assert sdk-bounds serial-absent 'zig-fs: FAIL'
vgate_assert sdk-bounds serial-absent '[EXC]'
vgate_assert sdk-over serial-contains 'zig-fs: entries=257 refused no leaked records'
vgate_assert sdk-over serial-contains 'zig-fs: PASS'
vgate_assert sdk-over serial-absent 'zig-fs: FAIL'
vgate_assert sdk-over serial-absent '[EXC]'
