# live-fs.spec -- host-share storage (M34 HF6): run A writes
# hello.txt, lists it [host], cats it, lists the seeded subdir, and
# hits the honest 2 KiB direct-read cap; run B fresh-boots the SAME
# share and still lists + prints the file; the host-disk bytes are
# the ground truth. The ANSI-tailed script-expects ride $'...'
# (the merged wave-1a n8 pattern).
# Mirrors tools/verify-live-fs.sh (issue #740). Two harness notes:
# per-TAG efi-vars rm (legacy reuses A's store in B -- neutral for
# file paths) and no inter-run sleep (local APFS needs none).
# M134d (#2762) adds the K=3 acceptance journey: `absent` boots with no
# --data-disk (the pinned host mtime at EL0, the mount-table rows
# enumerated, /disk named not_mounted), `mounted` opts /disk in
# (journaled write, read-back, FLUSH), `corrupt` boots the
# inode-checksum fixture (the M134c mount-time check refuses it by
# name). REPEAT SEMANTICS: vgate_repeat 3 re-runs EVERY leg; the armed
# share and vlfs.img persist across iterations, so each write is an
# idempotent whole-file replace and each refusal deterministic. Legs
# end on `m134d-done`, a marker only the probe ELF prints -- exec
# ordering is proven, never assumed.

vgate_name live-fs "write/ls/cat persist through reboot on the host share on VZ + M134d storage acceptance journey K=3"
vgate_share arm
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_repeat 3 PAIRS

vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
os.makedirs(os.path.join(share, "sub"), exist_ok=True)
os.makedirs(os.path.join(share, "sub", "deeper"), exist_ok=True)
open(os.path.join(share, "sub", "hello.txt"), "w").write("hello from the seeded share")
open(os.path.join(share, "sub", "big.txt"), "wb").write(bytes((i * 7 + 3) & 0xff for i in range(4000)))
open(os.path.join(share, "sub", "deeper", "nested.txt"), "w").write("nested level 2\n")
print("fs fixtures ok")
PY

vgate_file script-A.txt <<'EOF'
write hello.txt hello world
ls
cat hello.txt
ls sub
cat sub/big.txt
version
EOF

vgate_file script-B.txt <<'EOF'
ls
cat hello.txt
version
EOF

vgate_run A -- --script '$RUN_DIR/script-A.txt' --script-expect $'direct read caps at 0x0000000000000800 bytes\n\x1b[31mvirelai> ' --timeout 40
vgate_run B -- --script '$RUN_DIR/script-B.txt' --script-expect $'hello world\n\x1b[32mvirelai> ' --timeout 40

vgate_assert A serial-contains 'write: ok (persisted'
vgate_assert A serial-contains 'ls: host=0x'
vgate_assert A serial-contains '  hello.txt'
vgate_assert A serial-contains 'ls: sub entries=0x'
vgate_assert A serial-contains 'direct read caps at 0x0000000000000800'
vgate_assert A serial-contains 'hello world'
vgate_assert A serial-contains 'vf: probe 32k ok'
vgate_assert B serial-contains 'ls: host=0x'
vgate_assert B serial-contains '  hello.txt'
vgate_assert B serial-contains 'hello world'
vgate_assert B serial-contains 'vf: probe 32k ok'
vgate_assert B python <<'PY'
import os, sys
# HF6-DISK: hello.txt on the host share still carries the exact bytes
# (legacy compares $(cat) ==, which strips trailing newlines).
p = os.path.join(os.environ["VG_SHARE"], "hello.txt")
try:
    data = open(p, "rb").read()
except OSError:
    sys.exit("FAIL: hello.txt missing from the host share")
if data.rstrip(b"\n") != b"hello world":
    sys.exit("FAIL: hello.txt content off: %r" % data[:40])
print("fs host-disk ok")
PY

# --- M134d (#2762): the storage acceptance journey -------------------------
#
# One probe ELF answers both EL0 surfaces the card names: the pinned host
# mtime and ctime (the slot-79 op-0 stat record — mtime_sec rides wire
# offset 48, the M134a v2 STAT; ctime_sec offset 64, filled from the
# M160a v3 STAT) and the kernel mount table (the slot-27
# dir_list("/") rows — the reserved triple {state, kind, flags} decoded
# to the M134b names). It prints m134d-done last, so --script-expect on
# that marker is the graded run end: the VM stops only after every
# evidence line the asserts read.

vgate_file m134d.zig <<'EOF'
// M134d probe: stat /host/pinned-mtime.txt through the metadata syscall
// (slot 79 op 0; the record carries mtime at offset 48, ctime at 64) and
// enumerate the mount table through sys_dir_list("/") (slot 27; 40-byte
// rows whose reserved triple is {state, kind, flags}). Prints
// m134d-done last.
fn svc6(num: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) i64 {
    var res: i64 = undefined;
    asm volatile ("svc #0"
        : [res] "={x0}" (res),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
          [a4] "{x4}" (a4),
          [a5] "{x5}" (a5),
        : .{ .memory = true });
    return res;
}

fn puts(s: []const u8) void {
    _ = svc6(1, 1, @intFromPtr(s.ptr), s.len, 0, 0, 0);
}

fn pnum(v: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var x = v;
    while (true) {
        i -= 1;
        buf[i] = @intCast('0' + x % 10);
        x /= 10;
        if (x == 0) break;
    }
    puts(buf[i..]);
}

fn u64le(b: []const u8) u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) v |= @as(u64, b[i]) << @intCast(8 * i);
    return v;
}

fn stateWord(s: u8) []const u8 {
    return switch (s) {
        0 => "not_mounted",
        1 => "mounted",
        else => "?",
    };
}

fn kindWord(k: u8) []const u8 {
    return switch (k) {
        1 => "share",
        2 => "vlfs",
        3 => "block",
        4 => "fat32",
        else => "?",
    };
}

fn accWord(f: u8) []const u8 {
    return if (f & 1 != 0) "ro" else "rw";
}

var line: [96]u8 = undefined;
var line_len: usize = 0;

fn push(s: []const u8) void {
    @memcpy(line[line_len..][0..s.len], s);
    line_len += s.len;
}

fn emitLine() void {
    puts(line[0..line_len]);
    line_len = 0;
}

var wire: [96]u8 align(8) = @splat(0);
var mrows: [16 * 40]u8 align(8) = @splat(0);

export fn _start() void {
    const rc = svc6(79, 0, @intFromPtr("/host"), 5, @intFromPtr("pinned-mtime.txt"), 16, @intFromPtr(&wire));
    puts("m134d-stat rc=");
    if (rc < 0) {
        pnum(@bitCast(-rc));
        puts(" mtime_sec=? ctime_sec=?\n");
    } else {
        puts("0 mtime_sec=");
        pnum(u64le(wire[48..56]));
        puts(" ctime_sec=");
        pnum(u64le(wire[64..72]));
        puts("\n");
    }
    const n = svc6(27, @intFromPtr("/"), 1, @intFromPtr(&mrows), 16, 0, 0);
    if (n < 0) {
        puts("m134d-mounts rc=-");
        pnum(@bitCast(-n));
        puts("\n");
    } else {
        puts("m134d-mounts n=");
        pnum(@intCast(n));
        puts("\n");
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const row = mrows[i * 40 ..][0..40];
            var e: usize = 0;
            while (e < 32 and row[e] != 0) : (e += 1) {}
            // One write per row: the virtio-console TX posts every staged
            // chunk as its own descriptor, and mid-line bursts can lose a
            // unit on a contended device — a single post keeps the row
            // atomic on the wire.
            push("m134d-mount ");
            push(row[0..e]);
            push(" ");
            push(stateWord(row[37]));
            push(" ");
            push(kindWord(row[38]));
            push(" ");
            push(accWord(row[39]));
            push("\n");
            emitLine();
        }
    }
    puts("m134d-done\n");
    _ = svc6(3, 0, 0, 0, 0, 0, 0);
    unreachable;
}
EOF

vgate_file script-absent.txt <<'EOF'
vf ls /disk
vf cat /disk/M134D.TXT
exec M134D.ELF
EOF

vgate_file script-mounted.txt <<'EOF'
vf ls /disk
write /disk/M134D.TXT m134d storage acceptance
vf cat /disk/M134D.TXT
vf fsync /disk
exec M134D.ELF
EOF

vgate_file script-corrupt.txt <<'EOF'
vf ls /disk
vf cat /disk/M134D.TXT
exec M134D.ELF
EOF

vgate_setup_python <<'PY'
import os, subprocess, sys
from pathlib import Path

run_dir = os.environ["RUN_DIR"]
share = os.path.join(run_dir, "share")

# A pinned mtime the guest-side stat can check byte-for-byte (the M134a
# pinned fixture, same epoch live-vf's m134 leg pins).
pinned = os.path.join(share, "pinned-mtime.txt")
with open(pinned, "w") as f:
    f.write("pinned\n")
os.utime(pinned, ns=(1_700_000_123_000_000_000, 1_700_000_123_000_000_000))

# The two data-disk images: the golden empty 16 MiB VLFS volume for leg
# `mounted`, the committed inode-checksum corrupt fixture for leg
# `corrupt` (the .regions format: "bytes N" then <offset> <hex> runs).
def regions_to_img(name):
    img = None
    src = Path("kernel/src/vlfs/testdata") / name
    for line in src.read_text().splitlines():
        if not line or line.startswith("#") or line == "vlfs-regions 1":
            continue
        if line.startswith("bytes "):
            img = bytearray(int(line[6:]))
            continue
        off, hexs = line.split(" ", 1)
        img[int(off):int(off) + len(hexs) // 2] = bytes.fromhex(hexs)
    assert img is not None and len(img) == 16 * 1024 * 1024
    return bytes(img)

Path(run_dir, "vlfs.img").write_bytes(regions_to_img("empty-16m.regions"))
print("vlfs.img rebuilt from golden regions")
Path(run_dir, "corrupt.img").write_bytes(regions_to_img("corrupt-inode-checksum.regions"))
print("corrupt.img rebuilt from the inode-checksum fixture")

# Build the stat/mount-table probe ELF onto the share. Raw-ELF exec
# requires the last PT_LOAD writable (kernel/src/elf.zig), so constants
# fold into the RX segment and .data/.bss take their own page (the
# live-vf m134 leg's linker shape).
m134d_src = os.path.join(run_dir, "m134d.zig")
m134d_dst = os.path.join(share, "M134D.ELF")
linker = os.path.join(run_dir, "m134d.ld")
with open(linker, "w") as f:
    f.write("""ENTRY(_start)
SECTIONS {
  . = 0x00400000;
  .text : ALIGN(16) { *(.text .text.*) *(.rodata .rodata.*) }
  . = ALIGN(4096) + 4096;
  .data : ALIGN(16) { *(.data .data.*) }
  .bss : ALIGN(16) { *(.bss .bss.*) }
  /DISCARD/ : { *(.note.*) *(.eh_frame .eh_frame_hdr) *(.ARM.exidx*) }
}
""")
res = subprocess.run([
    "zig", "build-exe", "-target", "aarch64-freestanding-none",
    "-O", "ReleaseSafe", "-fentry=_start", "-fno-PIE",
    "-fsingle-threaded", "-T", linker, m134d_src,
    f"-femit-bin={m134d_dst}"
], capture_output=True, text=True)
if res.returncode != 0:
    print(f"zig build-exe failed: {res.stderr}", file=sys.stderr)
    sys.exit(1)
PY

# --- leg absent: no --data-disk — mount rows enumerated, /disk not_mounted --
vgate_run absent -- --script '$RUN_DIR/script-absent.txt' --script-expect 'm134d-done' --timeout 60
vgate_assert absent serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert absent serial-contains 'vf ls: disk:/: not_mounted'
vgate_assert absent serial-contains 'vf cat: disk:M134D.TXT: not_mounted'
vgate_assert absent serial-contains 'exec: loaded M134D.ELF'
vgate_assert absent serial-contains 'm134d-stat rc=0 mtime_sec=1700000123'
vgate_assert absent serial-contains 'm134d-mounts n=7'
vgate_assert absent serial-contains 'm134d-mount host mounted share rw'
vgate_assert absent serial-contains 'm134d-mount disk not_mounted vlfs rw'
vgate_assert absent serial-contains 'm134d-mount usb not_mounted block ro'
vgate_assert absent serial-contains 'm134d-mount usb4 not_mounted fat32 ro'
vgate_assert absent serial-contains 'm134d-done'
vgate_assert absent serial-absent 'vlfs: mounted /disk'
vgate_assert absent serial-absent '[EXC] parking:'
vgate_assert absent output-contains 'VF-FILE: STAT pinned-mtime.txt → file size=7 mtime=1700000123'
# M160a (#2981): the stat record's ctime_sec equals the staged file's
# host st_ctime, read after the run — nothing mutates it between the
# setup python's stage and this check, so the equality is exact.
vgate_assert absent python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], "rb").read()
m = re.search(rb"m134d-stat rc=0 mtime_sec=\d+ ctime_sec=(\d+)", ser)
if not m:
    sys.exit("FAIL: no m134d-stat ctime_sec on serial")
guest = int(m.group(1))
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
host = os.stat(os.path.join(share, "pinned-mtime.txt")).st_ctime_ns // 1_000_000_000
if guest != host:
    sys.exit("FAIL: guest ctime_sec=%d != host st_ctime=%d" % (guest, host))
print("m134d ctime_sec=%d == host st_ctime" % guest)
PY

# --- leg mounted: /disk opted in — journaled write, read-back, FLUSH -------
vgate_run mounted -- --data-disk '$RUN_DIR/vlfs.img' --script '$RUN_DIR/script-mounted.txt' --script-expect 'm134d-done' --timeout 90
vgate_assert mounted output-contains 'data-disk: ENABLED'
vgate_assert mounted serial-contains 'vlfs: mounted /disk'
vgate_assert mounted serial-contains 'write: ok (journaled 24 bytes to disk:M134D.TXT)'
vgate_assert mounted serial-contains 'vf: cat disk:M134D.TXT size=24'
vgate_assert mounted serial-contains 'vf: cat ok bytes=24 rts=1 cksum=0x57fa'
vgate_assert mounted serial-contains 'vf: fsync /disk ok (FLUSH completed)'
vgate_assert mounted serial-contains 'm134d-stat rc=0 mtime_sec=1700000123'
vgate_assert mounted serial-contains 'm134d-mount disk mounted vlfs rw'
vgate_assert mounted serial-contains 'm134d-mount host mounted share rw'
vgate_assert mounted serial-contains 'm134d-done'
vgate_assert mounted serial-absent '[EXC] parking:'

# --- leg corrupt: the M134c mount-time check refuses by name ---------------
vgate_run corrupt -- --data-disk '$RUN_DIR/corrupt.img' --script '$RUN_DIR/script-corrupt.txt' --script-expect 'm134d-done' --timeout 90
vgate_assert corrupt output-contains 'data-disk: ENABLED'
vgate_assert corrupt serial-contains 'vlfs: mount refused check=inode_checksum'
vgate_assert corrupt serial-absent 'vlfs: mounted /disk'
vgate_assert corrupt serial-contains 'vf ls: disk:/: not_mounted'
vgate_assert corrupt serial-contains 'vf cat: disk:M134D.TXT: not_mounted'
vgate_assert corrupt serial-contains 'm134d-mount disk not_mounted vlfs rw'
vgate_assert corrupt serial-contains 'm134d-done'
vgate_assert corrupt serial-absent '[EXC] parking:'
