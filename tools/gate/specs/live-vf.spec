# live-vf.spec -- M34 HF1+HF2+HF3+HF4+HF7 (issues #735-#738/#741)
#
# class-B gate: the HOST FILE CHANNEL over custom-virtio queue 5 on VZ.
#
#   Phase 1 (HF1): the guest's VF_PROBE spike proves the ONE unproven
#   transport fact -- a full 32,768-byte device-WRITE reply. Serial shows
#   `vf: probe 32k ok len=0x8000 cksum=0x0000 free=0020` (the XOR-symmetric
#   pattern genuinely folds to 0x0000; the guest Zig, Swift, and python
#   all agree); the runner prints `VF-PROBE: wrote 32768/32768 bytes`.
#
#   Phase 2 (HF2): the guest lists the share and streams a >32 KiB fixture
#   byte-exactly across >= 2 READ round trips -- `vf cat` prints the STAT
#   byte count FIRST, then `vf: cat ok bytes=N rts>=2 cksum=0x<...>` where
#   the checksum (RFC-1071 over the stream) must equal the gate's python
#   computation over the same fixture. LIST + STAT + READ all exercised; a
#   subdirectory proves /-paths.
#
#   Phase 3 (HF3 -- issue #737): MUTATION, one phase per boot:
#     mutate:   vf mkdir hf3 -> open hf3/new.bin -> write 100k pattern bytes
#               -> fsync -> mv -> open append -> write 4 bytes -> fsync -> close.
#     readback: vf cat hf3/renamed.bin -> verified byte-exact after reboot.
#     delete:   vf rm hf3/renamed.bin -> verified gone; hf3 dir survived.
#
#   Phase 4 (HF4 -- issue #738): APP DELIVERY, one boot: drop-and-exec
#   HF4APP.ELF with no image rebuild; headless GOSH reads the two-row
#   /host/APPS.TXT manifest over the same host file channel.
#
#   Phase 5/6 (HF7 -- issue #741): CLONE -> clonefile COW dedup:
#     clone: 3 worktrees cloned via `vf clone repo wtN`.
#     edit:  append 512 pattern bytes to wt1/README; verify wt2/wt3 stay
#            byte-identical to repo and wt1 differs ONLY in README.

vgate_name live-vf "host file channel over custom-virtio queue 5 on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1

vgate_file hf4app.zig <<'EOF'
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #20
        \\mov x8, #1
        \\svc #0
        \\mov x0, #43
        \\mov x8, #3
        \\svc #0
        \\1:
        \\.ascii "hf4: hello from host"
        \\.byte 10
    );
}
EOF

vgate_file script-mutate.txt <<'EOF'
vf ls
vf cat big.bin
vf ls sub
vf ls repo/lib
vf cat sub/hello.txt
vf mkdir hf3
vf open hf3/new.bin
vf write 0 100000
vf fsync 0
vf mv hf3/new.bin hf3/renamed.bin
vf open hf3/renamed.bin append
vf write 1 4
vf fsync 1
vf close 1
vf close 0
vf ls
echo rx-vf3-mutate
EOF

vgate_file script-readback.txt <<'EOF'
vf ls
vf cat big.bin
vf ls sub
vf cat sub/hello.txt
vf cat hf3/renamed.bin
echo rx-vf3-readback
EOF

vgate_file script-delete.txt <<'EOF'
vf ls
vf cat big.bin
vf ls sub
vf cat sub/hello.txt
vf rm hf3/renamed.bin
vf mkdir hf3
echo rx-vf3-delete
EOF

vgate_file script-app.txt <<'EOF'
vf ls
vf cat big.bin
vf ls sub
vf cat sub/hello.txt
vf ls
exec HF4APP.ELF
EOF

vgate_file script-app2.txt <<'EOF'
exec GOSH.ELF -c "cat /host/APPS.TXT"
EOF

vgate_file script-app3.txt <<'EOF'
echo rx-hf4-app
EOF

vgate_file script-clone.txt <<'EOF'
vf ls
vf cat big.bin
vf ls sub
vf cat sub/hello.txt
vf clone repo wt1
vf clone repo wt2
vf clone repo wt3
vf ls
echo rx-vf7-clone
EOF

vgate_file script-edit.txt <<'EOF'
vf ls
vf cat big.bin
vf ls sub
vf cat sub/hello.txt
vf open wt1/README append
vf write 0 512
vf fsync 0
vf close 0
vf cat wt1/README
echo rx-vf7-edit
EOF

vgate_setup_python <<'PY'
import os, random, subprocess, sys

run_dir = os.environ["RUN_DIR"]
share = os.path.join(run_dir, "share")
os.makedirs(os.path.join(share, "sub"), exist_ok=True)

# 1. big.bin + sub/hello.txt
data = bytes((i * 37 + 11) & 0xff for i in range(100000))
with open(os.path.join(share, "big.bin"), "wb") as f:
    f.write(data)
with open(os.path.join(share, "sub", "hello.txt"), "wb") as f:
    f.write(b"hello vf!\n")

# 2. repo fixture
base = os.path.join(share, "repo")
os.makedirs(os.path.join(base, "lib"), exist_ok=True)
rng = random.Random(20260902)
for i in range(6):
    with open(os.path.join(base, f"big{i}.bin"), "wb") as f:
        f.write(rng.randbytes(1024 * 1024))
for i in range(2):
    with open(os.path.join(base, "lib", f"small{i}.bin"), "wb") as f:
        f.write(rng.randbytes(512 * 1024))
with open(os.path.join(base, "README"), "wb") as f:
    f.write(b"HF7 fixture repo\n")

# 3. build HF4APP.ELF on host and write manifest
import shutil
hf4_src = os.path.join(run_dir, "hf4app.zig")
hf4_dst = os.path.join(share, "HF4APP.ELF")
res = subprocess.run([
    "zig", "build-exe", "-target", "aarch64-freestanding", "-O", "ReleaseSmall",
    "-T", "user/linker.ld", hf4_src, f"-femit-bin={hf4_dst}"
], capture_output=True, text=True)
if res.returncode != 0:
    print(f"zig build-exe failed: {res.stderr}", file=sys.stderr)
    sys.exit(1)

with open(os.path.join(share, "APPS.TXT"), "w") as f:
    f.write("HF4APP.ELF | Host Hello | h\nGOCALC.ELF | 64-bit Calc | c\n")

gosh_src = os.path.join(".build", "go", "GOSH.ELF")
if not os.path.exists(gosh_src):
    sys.exit("GOSH.ELF missing (expected %s) - build it first: bash tools/go/build-gosh.sh" % gosh_src)
shutil.copy(gosh_src, os.path.join(share, "GOSH.ELF"))
PY

# --- Run 1: mutate ---
vgate_run mutate -- --script '$RUN_DIR/script-mutate.txt' --script-after "tasks user-el0 exited status=7" --timeout 90
vgate_allow_rc mutate 0 1
vgate_assert mutate serial-contains "VirelaiOS kernel has seized control."
vgate_assert mutate serial-contains "vf: probe 32k ok len=0x8000 cksum=0x0000 free=0020"
vgate_assert mutate serial-contains "big.bin"
vgate_assert mutate serial-contains "vf: cat big.bin size=100000"
vgate_assert mutate serial-contains "vf: cat ok bytes=100000 rts="
vgate_assert mutate serial-contains "cksum=0xd986"
vgate_assert mutate serial-contains "sub/"
# #2853: repeated dir_open/page/close sequences on one share — the second
# and later listings must serve THEIR directory's rows, not an error or a
# stale snapshot. The wedge signature is a non-ok reply surfaced as
# "host file-channel error"; row checks pin sub/ (second sequence, fewer
# rows than the root's multi-page listing) and repo/lib (depth 2, third
# sequence), and the final `vf ls` proves reuse after interleaved
# OPEN/WRITE/FSYNC/RENAME/CLOSE handle traffic.
vgate_assert mutate serial-contains "hello.txt  10"
vgate_assert mutate serial-contains "small0.bin"
vgate_assert mutate serial-exact "sub/ 0" 2
vgate_assert mutate serial-absent "host file-channel error"
vgate_assert mutate serial-contains "vf: cat ok bytes=10 rts=1 cksum=0x249d"
vgate_assert mutate serial-absent "vf: probe 32k FAILED"
vgate_assert mutate serial-exact "vf: open hf3/new.bin h=0" 1
vgate_assert mutate serial-exact "vf: write 0 n=100000 wrote=100000 chunks=4" 1
vgate_assert mutate serial-exact "vf: fsync 0 ok" 1
vgate_assert mutate serial-exact "vf: mv hf3/new.bin -> hf3/renamed.bin ok" 1
vgate_assert mutate serial-exact "vf: open hf3/renamed.bin append h=1" 1
vgate_assert mutate serial-exact "vf: write 1 n=4 wrote=4 chunks=1" 1
vgate_assert mutate serial-exact "vf: fsync 1 ok" 1
vgate_assert mutate serial-exact "vf: close 1 ok" 1
vgate_assert mutate serial-exact "vf: close 0 ok" 1
vgate_assert mutate serial-exact "rx-vf3-mutate" 1
vgate_assert mutate output-contains "VF-PROBE: wrote 32768/32768 bytes (write buffers 32768)"
vgate_assert mutate output-contains "VF-FILE: RENAME hf3/new.bin"
vgate_assert mutate output-contains "VF-FILE: OPEN hf3/"
vgate_assert mutate output-contains "VF-FILE: WRITE h="
vgate_assert mutate python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
def pattern(i): return (i & 0xff) ^ ((i >> 8) & 0xff)
expect = bytes(pattern(i) for i in range(100000)) + bytes(pattern(i) for i in range(4))
rp = os.path.join(share, "hf3", "renamed.bin")
nb = os.path.join(share, "hf3", "new.bin")
if not os.path.exists(rp):
    print("HF3-DISK: renamed.bin missing", file=sys.stderr); sys.exit(1)
got = open(rp, "rb").read()
if got != expect:
    print(f"HF3-DISK: renamed.bin mismatch {len(got)} != {len(expect)}", file=sys.stderr); sys.exit(1)
if os.path.exists(nb):
    print("HF3-DISK: new.bin still present", file=sys.stderr); sys.exit(1)
PY

# --- Run 2: readback ---
vgate_run readback -- --script '$RUN_DIR/script-readback.txt' --script-after "tasks user-el0 exited status=7" --timeout 90
vgate_allow_rc readback 0 1
vgate_assert readback serial-contains "VirelaiOS kernel has seized control."
vgate_assert readback serial-contains "vf: probe 32k ok len=0x8000 cksum=0x0000 free=0020"
vgate_assert readback serial-contains "big.bin"
vgate_assert readback serial-contains "vf: cat big.bin size=100000"
vgate_assert readback serial-contains "vf: cat ok bytes=100000 rts="
vgate_assert readback serial-contains "cksum=0xd986"
vgate_assert readback serial-contains "sub/"
vgate_assert readback serial-contains "vf: cat ok bytes=10 rts=1 cksum=0x249d"
vgate_assert readback serial-absent "vf: probe 32k FAILED"
vgate_assert readback serial-exact "vf: cat hf3/renamed.bin size=100004" 1
vgate_assert readback serial-contains "vf: cat ok bytes=100004 rts="
vgate_assert readback serial-contains "cksum=0x1ccb"
vgate_assert readback serial-exact "rx-vf3-readback" 1
vgate_assert readback python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
def pattern(i): return (i & 0xff) ^ ((i >> 8) & 0xff)
expect = bytes(pattern(i) for i in range(100000)) + bytes(pattern(i) for i in range(4))
rp = os.path.join(share, "hf3", "renamed.bin")
if not os.path.exists(rp):
    print("HF3-DISK: renamed.bin missing in readback", file=sys.stderr); sys.exit(1)
got = open(rp, "rb").read()
if got != expect:
    print(f"HF3-DISK: renamed.bin mismatch in readback {len(got)} != {len(expect)}", file=sys.stderr); sys.exit(1)
PY

# --- Run 3: delete ---
vgate_run delete -- --script '$RUN_DIR/script-delete.txt' --script-after "tasks user-el0 exited status=7" --timeout 90
vgate_allow_rc delete 0 1
vgate_assert delete serial-contains "VirelaiOS kernel has seized control."
vgate_assert delete serial-contains "vf: probe 32k ok len=0x8000 cksum=0x0000 free=0020"
vgate_assert delete serial-contains "big.bin"
vgate_assert delete serial-contains "vf: cat big.bin size=100000"
vgate_assert delete serial-contains "vf: cat ok bytes=100000 rts="
vgate_assert delete serial-contains "cksum=0xd986"
vgate_assert delete serial-contains "sub/"
vgate_assert delete serial-contains "vf: cat ok bytes=10 rts=1 cksum=0x249d"
vgate_assert delete serial-absent "vf: probe 32k FAILED"
vgate_assert delete serial-exact "vf: rm hf3/renamed.bin ok" 1
vgate_assert delete serial-contains "already exists on the host share"
vgate_assert delete serial-exact "rx-vf3-delete" 1
vgate_assert delete output-contains "VF-FILE: DELETE hf3/renamed.bin"
vgate_assert delete python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
rp = os.path.join(share, "hf3", "renamed.bin")
hd = os.path.join(share, "hf3")
if os.path.exists(rp):
    print("HF3-DISK: renamed.bin still present after delete", file=sys.stderr); sys.exit(1)
if not os.path.isdir(hd):
    print("HF3-DISK: hf3 directory missing after delete", file=sys.stderr); sys.exit(1)
PY

# --- Run 4: app ---
vgate_run app -- --script '$RUN_DIR/script-app.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script-app2.txt' --script2-after 'tasks user-exec exited status=43' --script3 '$RUN_DIR/script-app3.txt' --script3-after 'tasks user-exec exited status=0' --script-expect 'rx-hf4-app' --timeout 180
vgate_allow_rc app 0 1
vgate_assert app serial-contains "VirelaiOS kernel has seized control."
vgate_assert app serial-contains "vf: probe 32k ok len=0x8000 cksum=0x0000 free=0020"
vgate_assert app serial-contains "big.bin"
vgate_assert app serial-contains "vf: cat big.bin size=100000"
vgate_assert app serial-contains "vf: cat ok bytes=100000 rts="
vgate_assert app serial-contains "cksum=0xd986"
vgate_assert app serial-contains "sub/"
vgate_assert app serial-contains "vf: cat ok bytes=10 rts=1 cksum=0x249d"
vgate_assert app serial-absent "vf: probe 32k FAILED"
vgate_assert app serial-contains "exec: loaded HF4APP.ELF size="
vgate_assert app serial-contains "hf4: hello from host"
vgate_assert app serial-exact "tasks user-exec exited status=43" 1
vgate_assert app serial-contains "exec: loaded GOSH.ELF"
# GOSH's headless exec/cat mode intentionally has no interactive ready marker.
vgate_assert app serial-contains "HF4APP.ELF | Host Hello | h"
vgate_assert app serial-contains "GOCALC.ELF | 64-bit Calc | c"
vgate_assert app serial-exact "tasks user-exec exited status=0" 1
vgate_assert app serial-exact "rx-hf4-app" 1
vgate_assert app output-contains "VF-FILE: READ HF4APP.ELF"
vgate_assert app output-contains "VF-FILE: READ APPS.TXT"
vgate_assert app output-contains "VF-FILE: STAT HF4APP.ELF"
vgate_assert app python <<'PY'
import os, sys
share = os.environ["VG_SHARE"]
rp = os.path.join(share, "hf3", "renamed.bin")
hd = os.path.join(share, "hf3")
if os.path.exists(rp):
    print("HF3-DISK: renamed.bin still present in app boot", file=sys.stderr); sys.exit(1)
if not os.path.isdir(hd):
    print("HF3-DISK: hf3 directory missing in app boot", file=sys.stderr); sys.exit(1)
PY

# --- Run 5: clone ---
vgate_run clone -- --script '$RUN_DIR/script-clone.txt' --script-after "tasks user-el0 exited status=7" --timeout 90
vgate_allow_rc clone 0 1
vgate_assert clone serial-contains "VirelaiOS kernel has seized control."
vgate_assert clone serial-contains "vf: probe 32k ok len=0x8000 cksum=0x0000 free=0020"
vgate_assert clone serial-contains "big.bin"
vgate_assert clone serial-contains "vf: cat big.bin size=100000"
vgate_assert clone serial-contains "vf: cat ok bytes=100000 rts="
vgate_assert clone serial-contains "cksum=0xd986"
vgate_assert clone serial-contains "sub/"
vgate_assert clone serial-contains "vf: cat ok bytes=10 rts=1 cksum=0x249d"
vgate_assert clone serial-absent "vf: probe 32k FAILED"
vgate_assert clone serial-exact "vf: clone repo -> wt1 ok" 1
vgate_assert clone serial-exact "vf: clone repo -> wt2 ok" 1
vgate_assert clone serial-exact "vf: clone repo -> wt3 ok" 1
vgate_assert clone serial-contains "wt1"
vgate_assert clone serial-contains "wt2"
vgate_assert clone serial-contains "wt3"
vgate_assert clone serial-exact "rx-vf7-clone" 1
vgate_assert clone output-contains "VF-FILE: CLONE repo"

# --- Run 6: edit ---
vgate_run edit -- --script '$RUN_DIR/script-edit.txt' --script-after "tasks user-el0 exited status=7" --timeout 90
vgate_allow_rc edit 0 1
vgate_assert edit serial-contains "VirelaiOS kernel has seized control."
vgate_assert edit serial-contains "vf: probe 32k ok len=0x8000 cksum=0x0000 free=0020"
vgate_assert edit serial-contains "big.bin"
vgate_assert edit serial-contains "vf: cat big.bin size=100000"
vgate_assert edit serial-contains "vf: cat ok bytes=100000 rts="
vgate_assert edit serial-contains "cksum=0xd986"
vgate_assert edit serial-contains "sub/"
vgate_assert edit serial-contains "vf: cat ok bytes=10 rts=1 cksum=0x249d"
vgate_assert edit serial-absent "vf: probe 32k FAILED"
vgate_assert edit serial-exact "vf: open wt1/README append h=0" 1
vgate_assert edit serial-exact "vf: write 0 n=512 wrote=512 chunks=1" 1
vgate_assert edit serial-exact "vf: fsync 0 ok" 1
vgate_assert edit serial-exact "vf: close 0 ok" 1
vgate_assert edit serial-exact "vf: cat wt1/README size=529" 1
vgate_assert edit serial-contains "bytes=529 rts="
vgate_assert edit serial-contains "cksum=0xda53"
vgate_assert edit serial-exact "rx-vf7-edit" 1
vgate_assert edit python <<'PY'
import hashlib, os, sys

share = os.environ["VG_SHARE"]
want_size = 529
want_cksum = 0xda53

def walk(d):
    out = {}
    for root, _, files in os.walk(d):
        for fn in sorted(files):
            p = os.path.join(root, fn)
            out[os.path.relpath(p, d)] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    return out

def cksum(data):
    s = 0; i = 0
    while i + 1 < len(data):
        s += (data[i] << 8) | data[i + 1]
        i += 2
    if i < len(data): s += data[i] << 8
    while s >> 16: s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff

ref = walk(os.path.join(share, "repo"))
for wt in ("wt2", "wt3"):
    got = walk(os.path.join(share, wt))
    if set(got) != set(ref):
        print(f"HF7-TREE: {wt} file set differs from repo", file=sys.stderr); sys.exit(1)
    diff = [k for k in ref if got[k] != ref[k]]
    if diff:
        print(f"HF7-TREE: {wt} differs from repo in {diff}", file=sys.stderr); sys.exit(1)

wt1 = walk(os.path.join(share, "wt1"))
diff1 = [k for k in ref if wt1.get(k) != ref[k]]
if diff1 != ["README"]:
    print(f"HF7-TREE: wt1 must differ ONLY in README, got {diff1}", file=sys.stderr); sys.exit(1)

rw = open(os.path.join(share, "wt1", "README"), "rb").read()
if len(rw) != want_size or cksum(rw) != want_cksum:
    print(f"HF7-TREE: wt1/README {len(rw)} bytes cksum=0x{cksum(rw):04x} (want {want_size}/0x{want_cksum:04x})", file=sys.stderr)
    sys.exit(1)
print("HF7-TREE: PASS -- edit duplicated nothing; untouched siblings intact")
PY

# --- M134a (#2759): STAT carries mtime; the legacy 31-byte LIST loses
#     its last kernel consumers -------------------------------------------

vgate_file m134stat.zig <<'EOF'
// M134a probe: reads /host/pinned-mtime.txt through the metadata syscall
// (slot 79 op 0 — the stat record's mtime sits at offset 48) and lists
// /host/long through the v2 directory ABI (slot 27) so a 40-byte host
// name's survival is observed at EL0, not host-side.
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

var wire: [96]u8 align(8) = @splat(0);
var page: [16 + 16 * 272]u8 align(8) = @splat(0);

export fn _start() void {
    const rc = svc6(79, 0, @intFromPtr("/host"), 5, @intFromPtr("pinned-mtime.txt"), 16, @intFromPtr(&wire));
    puts("m134-stat rc=");
    if (rc < 0) {
        pnum(@bitCast(-rc));
        puts(" mtime_sec=?\n");
    } else {
        puts("0 mtime_sec=");
        pnum(u64le(wire[48..56]));
        puts("\n");
    }
    const tok = svc6(27, @intFromPtr("/host/long"), 10, 0, (@as(u64, 1) << 63) | 1, 0, 0);
    if (tok > 0) {
        var off: u64 = 0;
        while (true) {
            const n = svc6(27, @as(u64, @bitCast(tok)), off, @intFromPtr(&page), (@as(u64, 1) << 63) | 2, 16, 0);
            if (n <= 0) break;
            const next = u64le(page[0..8]);
            const last = page[12] == 1;
            const count: usize = page[8];
            var at: usize = 16;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const nlen = @as(usize, page[at + 264]) | (@as(usize, page[at + 265]) << 8);
                puts("m134-name ");
                if (nlen <= 256) puts(page[at .. at + nlen]);
                puts("\n");
                at += 272;
            }
            if (last) break;
            off = next;
        }
        _ = svc6(27, @as(u64, @bitCast(tok)), 0, 0, (@as(u64, 1) << 63) | 3, 0, 0);
    } else {
        puts("m134-dirv2-open-failed\n");
    }
    _ = svc6(3, 0, 0, 0, 0, 0, 0);
    unreachable;
}
EOF

# exec-order: assert-proven -- `vf ls long`/`vf cat` precede the exec;
# every assert after it reads output only M134.ELF produces (m134-stat,
# m134-name), so a probe that never ran fails the leg, never passes it.
vgate_file script-m134.txt <<'EOF'
vf ls
vf cat pinned-mtime.txt
vf ls long
exec M134.ELF
echo rx-m134
EOF

vgate_setup_python <<'PY'
import os, subprocess, sys

run_dir = os.environ["RUN_DIR"]
share = os.path.join(run_dir, "share")

# A pinned mtime the guest-side stat can check byte-for-byte.
pinned = os.path.join(share, "pinned-mtime.txt")
with open(pinned, "w") as f:
    f.write("pinned\n")
os.utime(pinned, ns=(1_700_000_123_000_000_000, 1_700_000_123_000_000_000))

# A 40-byte host name the legacy 31-byte LIST row could never carry; it
# lives in its own directory so `vf ls` on the root still answers.
os.makedirs(os.path.join(share, "long"), exist_ok=True)
with open(os.path.join(share, "long", "a-very-long-host-file-name-123456789.txt"), "w") as f:
    f.write("long\n")

# Build the stat/dirV2 probe ELF onto the share. Raw-ELF exec requires the
# last PT_LOAD writable (kernel/src/elf.zig), so constants fold into the RX
# segment and .data/.bss take their own page (the live-user-fs b2.ld shape).
m134_src = os.path.join(run_dir, "m134stat.zig")
m134_dst = os.path.join(share, "M134.ELF")
linker = os.path.join(run_dir, "m134.ld")
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
    "-fsingle-threaded", "-T", linker, m134_src,
    f"-femit-bin={m134_dst}"
], capture_output=True, text=True)
if res.returncode != 0:
    print(f"zig build-exe failed: {res.stderr}", file=sys.stderr)
    sys.exit(1)
PY

# --- Run: mtime + long-name legs ---

vgate_run mtime -- --script '$RUN_DIR/script-m134.txt' --script-after "tasks user-el0 exited status=7" --timeout 90
vgate_allow_rc mtime 0 1
vgate_assert mtime serial-contains "m134-stat rc=0 mtime_sec=1700000123"
vgate_assert mtime serial-contains "m134-name a-very-long-host-file-name-123456789.txt"
vgate_assert mtime serial-contains "vf ls: long: host file-channel error"
vgate_assert mtime serial-contains "vf: cat ok"
vgate_assert mtime serial-contains "rx-m134"
vgate_assert mtime output-contains "VF-FILE: STAT pinned-mtime.txt → file size=7 mtime=1700000123"
# Arm the old-shape STAT switch for the next leg (test-only marker).
vgate_assert mtime python <<'PY'
import os
share = os.path.join(os.environ["RUN_DIR"], "share")
with open(os.path.join(share, ".vf-stat-v1"), "w") as f:
    f.write("pin STAT replies to the 9-byte pre-mtime shape\n")
PY

# --- Run: old-shape peer still lists/reads/stats, mtime absent ---

vgate_run oldshape -- --script '$RUN_DIR/script-m134.txt' --script-after "tasks user-el0 exited status=7" --timeout 90
vgate_allow_rc oldshape 0 1
vgate_assert oldshape serial-contains "m134-stat rc=0 mtime_sec=0"
vgate_assert oldshape serial-contains "m134-name a-very-long-host-file-name-123456789.txt"
vgate_assert oldshape serial-contains "vf: cat ok"
vgate_assert oldshape serial-contains "rx-m134"
vgate_assert oldshape output-contains "VF-FILE: STAT pinned-mtime.txt → file size=7 (v1 shape)"
vgate_assert oldshape python <<'PY'
import os
share = os.path.join(os.environ["RUN_DIR"], "share")
os.remove(os.path.join(share, ".vf-stat-v1"))
PY
