# go-hello.spec -- issue #1163, GOOS=virelai phase 0a: the gc Go runtime
# runs on VirelaiOS. Runs 01-03 (M70c-K, #1504): svc #0 console + sbrk heap +
# GC; a >9 MiB image STREAMED into its mapped pages; the two refusals by name.
# Run 04 (M70c, #1455): the guest reads that same 9.5 MiB from the share
# end to end at the ABI's 32 KiB read cap (2048 B before card #3035) —
# bytes, call count and FNV hash asserted against the file on macOS, the
# rate reported (ADR 0035 measures it).
# Run 05 (M70c-S1L, #1540): the std fixture — a Go program whose file I/O goes
# through `os`/`fmt` (the #1525 port) instead of the guest SDK — RUNS. Its own
# output is held to the file on macOS: the whole 9.5 MiB image read through
# os.File and hashed, os.Mkdir/WriteFile/ReadDir/Stat/Remove exercised in a
# directory the fixture creates (so the entry counts are exact), and the
# removes checked from the host's copy of the share afterwards. The aperture
# that used to refuse this image is fixed in the runtime's break base, and the
# run also pins the two port bugs it caught (ADR 0035 amendment 4).
# Runs 06-08 (M70c-S1T, #1543): the guest's OWN cmd/compile and cmd/link build
# tools/go/hello.go in the guest (object -> ELF), and the ELF the guest linked
# runs and prints the pinned lines. The in-guest memory samples (run 06/07) are
# the ADR 0035 D6 figure: reported, not asserted, because a footprint is a
# property of the machine.
# Runs 11-12 (M72a, #1579; redefined M171a, card #3032): the loader's TWO
# bounds, on one real Go image — a `gobig.go`-shaped file plus 40 MiB of
# `.noptrbss` (the shape `crypto/internal/fips140/drbg`'s 32 MiB
# `entropy.ScratchBuffer` gives every Charm-sized binary). That image once
# refused as `segment_too_large`, because the single acceptance bound
# charged MAPPED bytes: zero-initialized bytes cost no file bytes, so an
# image the file could not even hold was refused for being big on disk.
# Run 11 pins the fix — the 9.1 MiB file maps 48 MiB and EXECS, reading
# both ends of its 40 MiB tail back — and, since M171a, holds the guest's
# `mappedpages=` (VIRTUAL span) to the image's own headers while
# `datapages=` (RESIDENT at exec) stays within the file-backed count plus
# the argv headroom page: the tail is demand-zero, not eagerly resident.
# Run 12 pins that the bound MOVED rather than disappeared: the same bytes
# with `p_memsz` rewritten to 1 GiB are still refused, by a message that
# names the mapped-memory bound and never says "staging buffer" (the lie
# the old fall-through told about this exact shape).
# HOST PREREQUISITE, in addition to the list below:
# `.build/go/GOLOADBSS.ELF` (`just go-toolchain` builds it).
# Runs 09-10 (M69e, #1532): the DAILY LOOP, and the only boots here where a
# compiler runs because of the guest's own action. Run 09 has the guest author
# a Go source on /host with the monitor's `write` verb; the Mac compiles THAT
# file between the two boots (a python hook on run 09, so the compile sits
# after the edit and before the run); run 10 executes the image the Mac built
# from the guest's own bytes. The guest never sees a compiler - both runs
# assert the host's own receipt line absent from their serial.
# Run 13 (#2354): GOBIGREAD.ELF reads GOBIG.ELF through os.ReadFile — the
# growing-buffer shape that lands a read chunk ACROSS the armed
# region boundary where the Go runtime's sbrk chain grows the heap
# (observed live: `read /host/GPKG_runtime.a: bad address` ~4.4 MiB into a
# 12 MiB archive on the pure cv channel, live-godiff-loop run 06). Every
# other big-read fixture uses a fixed 2-4 KiB buffer that never straddles.
# The bytes are held to the file on macOS (FNV-1a-64), and a deep+mid
# ReadAt pair proves the port's shadow pull after the sequential pass.
# HOST PREREQUISITE: `.build/go/{GOHELLO,GOBIG,GOREAD,GOSYSCALL,GOBIGREAD}.ELF`
# must exist first via `bash tools/go/build-go.sh tools/go/hello.go
# tools/go/gobig.go tools/go/goread.go tools/go/gosyscall.go
# tools/go/gobigread.go` (fork prerequisites in
# tools/go/README.md); runs 06-08 additionally need `bash tools/go/build-gotool.sh`
# (the GOOS=virelai toolchain images) and `bash tools/go/stage-selfhost.sh`
# (the import config + package archives the guest's linker resolves against).
# Runs 09-10 need only that same fork toolchain: the harness compiles in the
# gate, and refuses (before any boot) when `$GO_FORK_DIR/bin/go` is missing.
# exec-order: assert-proven — a run cannot go green without the program's own output. See tools/gate/SPEC.md.

vgate_name go-hello "issue #1163 GOOS=virelai phase 0a: gc Go runtime first target on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

# Issue #1163 A2 review follow-up: the run waits on the PROGRAM's own
# final line (below) — the old `echo go-hello-done` raced the VM shutdown
# against the exec'd process's first scheduling (observed live once on
# go-args), a flaky FAIL by construction.
vgate_file script.txt <<'EOF'
exec GOHELLO.ELF
EOF

vgate_file script2.txt <<'EOF'
exec GOBIG.ELF
EOF

vgate_file script3.txt <<'EOF'
exec XL.ELF
exec TRUNC.ELF
EOF

# M70c (#1455) run 04: GOREAD.ELF reads GOBIG.ELF back out of the share, end
# to end, at the guest SDK's own chunk size (vsys.MaxFileIOBytes = the kernel's
# 32 KiB per-call read cap since card #3035, 2048 B before). It hashes every
# byte as it arrives and prints
# what that cost; the host recomputes the hash and the call arithmetic over the
# file it staged. Nothing here is timing-dependent — the rate is reported, not
# asserted.
vgate_file script4.txt <<'EOF'
exec GOREAD.ELF /host/GOBIG.ELF
EOF

# M70c-S1L (issue #1540) run 05: the same image, read through the STANDARD
# LIBRARY instead of the guest SDK — os.File/os.ReadDir/os.WriteFile/os.Remove
# over the #1525 syscall+os port, printed with fmt into os.Stdout.
vgate_file script5.txt <<'EOF'
exec GOSYSCALL.ELF
EOF

# #2354 run 13: the straddle reproducer — os.ReadFile's growing destination
# plus a deep ReadAt pull, against the same 9.5 MiB image run 04 hashes.
vgate_file script17.txt <<'EOF'
exec GOBIGREAD.ELF /host/GOBIG.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
srcs = [".build/go/GOHELLO.ELF", ".build/go/GOBIG.ELF", ".build/go/GOREAD.ELF",
        ".build/go/GOSYSCALL.ELF", ".build/go/GOLOADBSS.ELF",
        ".build/go/GOBIGREAD.ELF"]
missing = [p for p in srcs if not os.path.exists(p)]
if missing:
    sys.exit("%s missing — build the fork binaries first: "
             "bash tools/go/build-go.sh tools/go/hello.go tools/go/gobig.go "
             "tools/go/goloadbss.go tools/go/goread.go tools/go/gosyscall.go "
             "tools/go/gobigread.go "
             "(or `just go-toolchain`; fork prerequisites in tools/go/README.md)"
             % ", ".join(missing))
for src in srcs:
    dst = os.path.join(share, os.path.basename(src))
    shutil.copy(src, dst)
    print("staged %s into share (%d bytes)" % (os.path.basename(src), os.path.getsize(dst)))
# The M70c-K (#1504) fixture's whole point is its size: fail here rather
# than let run 02 pass on an image the staging buffer could have held.
if os.path.getsize(os.path.join(share, "GOBIG.ELF")) <= 8 << 20:
    sys.exit("GOBIG.ELF is not over 8 MiB — the streamed bound is untested")
# Run 03's two refusal fixtures, made from that same real image so that
# neither is refused for a reason other than the one under test:
#   XL.ELF    — the whole image plus padding past the 32 MiB acceptance
#               bound. Every byte of the image itself is valid and its
#               segments are all present, so ONLY the file's size can
#               refuse it (a file of zeros would prove much less).
#   TRUNC.ELF — the first 4 MiB of a 9.5 MiB image: big enough to take the
#               STREAMED path (>2 MiB, so it is not the staged shape), laid
#               out so its text and rodata are complete and its 8 MiB data
#               segment is cut off, i.e. exactly what an interrupted copy
#               looks like.
go = os.path.join(share, "GOBIG.ELF")
xl = os.path.join(share, "XL.ELF")
with open(go, "rb") as src, open(xl, "wb") as out:
    shutil.copyfileobj(src, out)
    out.truncate(34 << 20)
trunc = os.path.join(share, "TRUNC.ELF")
with open(go, "rb") as src, open(trunc, "wb") as out:
    out.write(src.read(4 << 20))
    out.flush()
if os.path.getsize(xl) <= 32 << 20:
    sys.exit("XL.ELF is not over the 32 MiB acceptance bound — its refusal is untested")
if not 2 << 20 < os.path.getsize(trunc) < os.path.getsize(go):
    sys.exit("TRUNC.ELF must be too big to stage but smaller than the image it copies")
print("staged refusal fixtures: XL.ELF %d B, TRUNC.ELF %d B" % (os.path.getsize(xl), os.path.getsize(trunc)))
PY

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'virelai-go OK' --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOHELLO.ELF'
vgate_assert 01 serial-contains 'hello from virelai'
vgate_assert 01 serial-contains 'heap: wrote 1048576 bytes'
vgate_assert 01 serial-contains 'gc: cycle completed'
vgate_assert 01 serial-contains 'virelai-go OK'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-absent 'exited status=139'

# M70c-K (issue #1504) run 02: GOBIG.ELF is a real GOOS=virelai Go image of
# 9.5 MiB whose LAST segment carries 8.0 MiB of initialized data, so the old
# loader refused it outright (`image too large`) — a staged load would have had
# to hold the whole file in a 2 MiB array. The banner the program prints is
# read back at runtime from 1, 4 and 8 MiB into that payload: it is 'A B C E D'
# only if every streamed page arrived, and zeros or a fault otherwise.
vgate_run 02 -- --script '$RUN_DIR/script2.txt' --script-expect 'virelai-go big OK' --timeout 180

vgate_assert 02 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 02 serial-contains 'exec: loaded GOBIG.ELF'
vgate_assert 02 serial-contains 'big: blob bytes 8388608'
vgate_assert 02 serial-contains 'big: banner A B C E D'
vgate_assert 02 serial-contains 'big: sum 335'
vgate_assert 02 serial-contains 'virelai-go big OK'
vgate_assert 02 serial-absent ': image too large'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 serial-absent 'exited status=139'

# M70c-K (issue #1504) run 03: the bound MOVED, it did not disappear. Both
# refusals are asserted by their own message, and the run ends on the
# second one — so a loader that silently accepted either fixture, or that
# stopped after the first refusal instead of returning to the prompt, cannot
# go green. The truncated case here is the parse-time detection (a payload
# range past the volume's STAT size); the mid-read detection (a file that
# shrinks between that parse and the streamed read) needs a host-side seam
# and is pinned by `kernel/tests/monitor_test.zig` instead.
vgate_run 03 -- --script '$RUN_DIR/script3.txt' --script-expect 'TRUNC.ELF: truncated image' --timeout 180

vgate_assert 03 serial-contains 'XL.ELF: image too large (acceptance bound'
vgate_assert 03 serial-contains 'TRUNC.ELF: truncated image'
vgate_assert 03 serial-absent 'XL.ELF: truncated image'
vgate_assert 03 serial-absent 'TRUNC.ELF: image too large'
vgate_assert 03 serial-absent 'exec: loaded XL.ELF'
vgate_assert 03 serial-absent 'exec: loaded TRUNC.ELF'
vgate_assert 03 serial-absent 'staging buffer'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
xl = ser.find("XL.ELF: image too large")
tr = ser.find("TRUNC.ELF: truncated image")
if xl == -1 or tr == -1:
    sys.exit("FAIL: a refusal is missing (xl=%d tr=%d)" % (xl, tr))
if xl > tr:
    sys.exit("FAIL: TRUNC.ELF was refused BEFORE XL.ELF — the script's second line was dropped")
# The monitor must still be reading input after each refusal (it is the
# second line that proves the first did not kill it) — and no loader may
# have reached the success marker for either file.
if "exec: loaded XL.ELF" in ser or "exec: loaded TRUNC.ELF" in ser:
    sys.exit("FAIL: a refused image reported a successful load")
print("both refusals in order: XL at %d, TRUNC at %d" % (xl, tr))
PY
# M171a (card #3032): the streamed 8 MiB data segment is RESIDENT, its
# zero-fill tail is NOT. `datapages=` is held to the writable segment's
# own headers on the host: at least the file-backed pages (the streamed
# data) and never more than that plus the argv/envp run (two pages bound).
# `mappedpages=` reports the VIRTUAL span — the page-rounded p_memsz plus
# any headroom the argv block needs past it.
vgate_assert 02 python <<'PY'
import os, re, struct, sys

ser = open(os.environ["VG_SER"], errors="replace").read()
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
d = open(os.path.join(share, "GOBIG.ELF"), "rb").read()
phoff = struct.unpack_from("<Q", d, 32)[0]
phes = struct.unpack_from("<H", d, 54)[0]
phnum = struct.unpack_from("<H", d, 56)[0]
rw_fsz = rw_msz = None
for i in range(phnum):
    o = phoff + i * phes
    t, fl, off, va, pa, fsz, msz, al = struct.unpack_from("<IIQQQQQQ", d, o)
    if t == 1 and fl & 2:
        rw_fsz, rw_msz = fsz, msz
if rw_fsz is None:
    sys.exit("FAIL: the staged GOBIG.ELF has no writable PT_LOAD segment")
file_pages = (rw_fsz + 4095) // 4096
mem_pages = (rw_msz + 4095) // 4096
cover = (((rw_msz + 7) & ~7) + 4096 + 4095) // 4096
expected_map = max(mem_pages, cover)
m = re.search(r"exec: loaded GOBIG\.ELF .*datapages=(\d+) mappedpages=(\d+)", ser)
if not m:
    sys.exit("FAIL: no `exec: loaded GOBIG.ELF ... datapages= mappedpages=` line")
data_pages, map_pages = int(m.group(1)), int(m.group(2))
if map_pages != expected_map:
    sys.exit("FAIL: mappedpages=%d but the image's writable segment spans %d "
             "(memsz=%d, argv cover=%d)" % (map_pages, expected_map, rw_msz, cover))
if data_pages < file_pages:
    sys.exit("FAIL: datapages=%d under the file-backed count %d — the streamed "
             "8 MiB is not resident" % (data_pages, file_pages))
if data_pages > file_pages + 2:
    sys.exit("FAIL: datapages=%d beyond file pages %d + argv run — the zero-fill "
             "tail is resident at exec" % (data_pages, file_pages))
print("streamed 8 MiB data resident, tail demand-zero: datapages=%d "
      "(file %d + argv run) mappedpages=%d (memsz=%d, filesz=%d)"
      % (data_pages, file_pages, map_pages, rw_msz, rw_fsz))
PY

# M70c (#1455) run 04: the transfer half of the card's "measure the honest
# transfer and mmap story" — the guest reads a multi-MB file out of the host
# share with nothing staged in between.
#
# The assert is the guest's own byte stream, held to the file on macOS: the
# exact byte count, the call count the kernel's 32 KiB per-call read cap
# implies (ceil(bytes/32768) — reachable only if a call really moves 32 KiB),
# and the FNV-1a hash of the bytes READ. A short read, a dropped chunk, a
# read from the wrong offset or a page of zeros all produce a different hash,
# and none of them can be printed into place. The rate is extracted and
# reported (it lands in this run's log, which is what ADR 0035 quotes); it is
# deliberately NOT asserted, because a throughput is a property of the machine.
vgate_run 04 -- --script '$RUN_DIR/script4.txt' --script-expect 'goread: GOREAD OK' --timeout 300

vgate_assert 04 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 04 serial-contains 'exec: loaded GOREAD.ELF'
vgate_assert 04 serial-contains 'goread: GOREAD OK'
vgate_assert 04 serial-absent 'goread: FAIL'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'
vgate_assert 04 python <<'PY'
import os, re, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(share, "GOBIG.ELF")
if not os.path.exists(src):
    sys.exit("FAIL: the fixture run 04 reads is missing: " + src)
n = os.path.getsize(src)
calls = (n + 32767) // 32768  # one kernel read call moves at most 32 KiB (card #3035)
h = 0xcbf29ce484222325
with open(src, "rb") as fh:
    while True:
        b = fh.read(1 << 20)
        if not b:
            break
        for byte in b:
            h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
ser = open(os.environ["VG_SER"], errors="replace").read()
want = "goread: file /host/GOBIG.ELF bytes %d calls %d max 32768" % (n, calls)
if want not in ser:
    sys.exit("FAIL: the guest's exact read line is absent.\n  want: %r\n"
             "  (a shorter call count means the kernel moved more than 32 KiB per "
             "read, or the file the guest read is not the file on macOS)" % want)
if ("goread: fnv 0x%016x" % h) not in ser:
    sys.exit("FAIL: the guest hashed different bytes than the file on macOS "
             "(want 0x%016x)" % h)
m = re.search(r"goread: rate us (\d+) kib_s (\d+) ns_call (\d+)", ser)
if not m:
    sys.exit("FAIL: no `goread: rate` line — the measurement did not report")
us, kib, ns = (int(x) for x in m.groups())
if us <= 0 or kib <= 0 or ns <= 0:
    sys.exit("FAIL: the rate line is zero: " + m.group(0))
print("read %d B from the share in %d calls at the 32 KiB cap: %d us -> %d KiB/s (%d ns/call)"
      % (n, calls, us, kib, ns))
print("fnv 0x%016x matches the file on macOS" % h)
PY

# M70c-S1L (issue #1540) run 05: an `os`-importing image runs at all.
#
# The run is the assertion that the aperture story moved: before this card the
# same binary loaded and then died in `runtime.mallocinit` with "cannot allocate
# memory", because its break base landed inside the data aperture the kernel
# protects through the argv+envp block. Nothing about the guest's arithmetic is
# asserted here — the card's claim is that a std program executes, and the
# fixture's own output is what proves it. Where a number has to come from
# somewhere other than the guest, it comes from the file on macOS: the 9.5 MiB
# image is read through os.File and folded into FNV-1a by the host too, the
# second raw read is checked against the staged file's own byte at that offset,
# the directory it walks is one it created (so the exact entry counts are
# assertable), and the remove is checked from the host side of the share.
vgate_run 05 -- --script '$RUN_DIR/script5.txt' --script-expect 'gosyscall: GOSYSCALL OK' --timeout 300

vgate_assert 05 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 05 serial-contains 'exec: loaded GOSYSCALL.ELF'
vgate_assert 05 serial-contains 'gosyscall: os mkdir ok'
vgate_assert 05 serial-contains 'gosyscall: read 2048'
vgate_assert 05 serial-contains 'gosyscall: absent no such file or directory'
vgate_assert 05 serial-contains 'gosyscall: os remove ok 2'
vgate_assert 05 serial-contains 'gosyscall: GOSYSCALL OK'
vgate_assert 05 serial-absent 'gosyscall: MISMATCH'
vgate_assert 05 serial-absent 'gosyscall: FAIL'
vgate_assert 05 serial-absent 'cannot allocate memory'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 serial-absent 'exited status=139'
vgate_assert 05 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(share, "GOBIG.ELF")  # what the fixture read through os.File
if not os.path.exists(src):
    sys.exit("FAIL: the fixture's input is missing: " + src)
n = os.path.getsize(src)
# The fixture folds the bytes with 32-bit FNV-1a as it reads them through
# os.File; the host folds the file on macOS the same way and the two have to
# agree. Every byte of the file passes through os.File -> internal/poll ->
# the port's syscall.Read: a dropped or short chunk, a re-read or a wrong
# offset all change the hash, and the byte count alone would not.
h = 2166136261
with open(src, "rb") as fh:
    blob = fh.read()
for byte in blob:
    h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
ser = open(os.environ["VG_SER"], errors="replace").read()
if "gosyscall: os bytes %d hash 0x%08x" % (n, h) not in ser:
    sys.exit("FAIL: the fixture's os.File hash does not match the file on macOS "
             "(want bytes %d hash 0x%08x)" % (n, h))
# The raw layer's second read must continue at offset 2048, i.e. report that
# byte — a layer that re-read page one would report the ELF magic's second byte.
want_second = "gosyscall: second read 1 byte %d" % blob[2048]
if want_second not in ser:
    sys.exit("FAIL: the second raw read did not continue the file (want %r)" % want_second)
# Stat's parent-row route cannot reach an entry past the kernel's 16 rows, so a
# file in /host is sized by the reading fallback: the number has to be the real
# file size, and "isdir" must be false for a file.
for line in ("gosyscall: stat size %d isdir false" % n,
             "gosyscall: fstat size %d" % n,
             "gosyscall: os stat size %d isdir false" % n):
    if line not in ser:
        sys.exit("FAIL: missing %r (the file is %d B on macOS)" % (line, n))
# The owned directory: two files created by the fixture, each row 40 bytes.
for line in ("gosyscall: raw dirent bytes 80",
             "gosyscall: os dir entries 2 files 2 dirs 0",
             "gosyscall: os stat PAYLOAD.TXT size 32 isdir false",
             "gosyscall: os write PAYLOAD.TXT bytes 32",
             "gosyscall: os readback PAYLOAD.TXT ok bytes 32",
             "gosyscall: os dir entries 0 files 0 dirs 0"):
    if line not in ser:
        sys.exit("FAIL: missing %r" % line)
# The two host-side facts the guest cannot fake from inside: the removes
# really reached the share (the files are gone from the host's copy), and the
# directory the guest created is empty there too.
d = os.path.join(share, "GOSYSCALL.D")
if not os.path.isdir(d):
    sys.exit("FAIL: the fixture's os.Mkdir did not reach the share: " + d)
left = sorted(os.listdir(d))
if left:
    sys.exit("FAIL: the guest's os.Remove did not reach the share: %r remains" % left)
print("os layer: %d B hashed 0x%08x; os.Mkdir/WriteFile/ReadDir/Stat/Remove reached the share"
      % (n, h))
PY

# --- M70c-S1T (issue #1543): the guest builds, with its own toolchain --------
#
# The chain is three boots because the monitor's `exec` returns immediately
# (tools/gate/SPEC.md): the share carries the intermediate between runs, and
# each run ends on the guest's own exit-status line, which the scheduler prints
# (`procs <name> exited status=<n>`). The intermediate is a real artifact of
# the guest: run 07 links the object run 06 compiled, and run 08 executes the
# ELF run 07 produced.
#
# The argv is what the kernel's 8x256-byte block allows (kernel/src/exec.zig
# max_exec_args/arg_slot_bytes; 255 bytes usable per arg, M71m #1572), which is why the flags are terse and the
# import config is one flat file in the share; tools/go/stage-selfhost.sh
# checks those lines against the budget before a boot is spent on them.
vgate_file script6.txt <<'EOF'
exec GOCMDCOMPILE.ELF -o /host/HELLO.o -importcfg /host/GOIMPORT.CFG /host/HELLO.GO
EOF

vgate_file script7.txt <<'EOF'
sysinfo
EOF

vgate_file script8.txt <<'EOF'
sysinfo
syscalls
echo selfhost-compile-done
EOF

vgate_file script9.txt <<'EOF'
exec GOCMDLINK.ELF -importcfg /host/GOIMPORT.CFG -tmpdir /host -o /host/HELLO2.ELF /host/HELLO.o
EOF

vgate_file script10.txt <<'EOF'
sysinfo
EOF

vgate_file script11.txt <<'EOF'
sysinfo
syscalls
echo selfhost-link-done
EOF

vgate_file script12.txt <<'EOF'
exec HELLO2.ELF
EOF

# Runs 06-08's staging: the toolchain images, and the import config + package
# archives the guest's linker resolves symbols against. Both are host
# prerequisites with their own scripts, so this fails closed with the script
# to run rather than booting a guest that cannot find its inputs.
vgate_setup_python <<'PY'
import os, shutil, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
tools = [".build/go/GOCMDCOMPILE.ELF", ".build/go/GOCMDLINK.ELF"]
stage = ".build/go/selfhost"
if not os.path.isdir(stage):
    sys.exit("%s missing - run: bash tools/go/stage-selfhost.sh" % stage)
for src in tools:
    if not os.path.exists(src):
        sys.exit("%s missing - run: bash tools/go/build-gotool.sh" % src)
    shutil.copy(src, os.path.join(share, os.path.basename(src)))
    print("staged %s (%d bytes)" % (os.path.basename(src), os.path.getsize(src)))
n = total = 0
for name in sorted(os.listdir(stage)):
    if name.startswith("."):
        continue
    src = os.path.join(stage, name)
    shutil.copy(src, os.path.join(share, name))
    n += 1
    total += os.path.getsize(src)
print("staged %d selfhost files (%.2f MiB): import config + archives + HELLO.GO"
      % (n, total / 1048576.0))
# The chain assumes the share survives between runs and that run 07 links what
# run 06 wrote; both are checked by the asserts below, not assumed here.
for stale in ("HELLO.o", "HELLO2.ELF"):
    p = os.path.join(share, stale)
    if os.path.exists(p):
        os.remove(p)
        print("removed stale %s from a previous gate run" % stale)
PY

# Run 06: the guest's cmd/compile compiles the pinned hello. It prints nothing
# on success, so the evidence is the object it wrote (read back on macOS) and
# its own exit status. The object is an ar archive whose header line names the
# target it was compiled for: `go object virelai arm64 go1.27.1 ...` is not a
# line a copied binary or a no-op compile can produce.
vgate_run 06 -- --script '$RUN_DIR/script6.txt' --script2 '$RUN_DIR/script7.txt' --script2-after 'exec: loaded GOCMDCOMPILE.ELF' --script3 '$RUN_DIR/script8.txt' --script3-after 'procs GOCMDCOMPILE.ELF exited status=0' --script-expect 'selfhost-compile-done' --timeout 300

vgate_assert 06 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 06 serial-contains 'exec: loaded GOCMDCOMPILE.ELF'
vgate_assert 06 serial-contains 'procs GOCMDCOMPILE.ELF exited status=0'
vgate_assert 06 serial-absent '[EXC] parking:'
vgate_assert 06 serial-absent 'cannot allocate memory'
vgate_assert 06 serial-absent 'panic:'
vgate_assert 06 python <<'PY'
import os, re, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
obj = os.path.join(share, "HELLO.o")
if not os.path.exists(obj):
    sys.exit("FAIL: the in-guest compile produced no object at " + obj)
raw = open(obj, "rb").read()
if len(raw) < 1024:
    sys.exit("FAIL: HELLO.o is only %d bytes" % len(raw))
if not raw.startswith(b"!<arch>"):
    sys.exit("FAIL: HELLO.o is not an ar archive; first bytes %r" % raw[:16])
for want in (b"go object virelai arm64 ", b"__.PKGDEF", b"_go_.o", b"main.main"):
    if want not in raw:
        sys.exit("FAIL: HELLO.o has no %r" % want)
hdr = re.search(rb"go object [^\n]{0,64}", raw)
print("in-guest compile: HELLO.o %d bytes (ar archive); header %r"
      % (len(raw), hdr.group(0).decode()))
ser = open(os.environ["VG_SER"], errors="replace").read()
samples = re.findall(r"allocator:\s+armed=(\d) total=(0x[0-9a-f]+) free=(0x[0-9a-f]+) "
                     r"excluded=(0x[0-9a-f]+) regions=(0x[0-9a-f]+)", ser)
for i, (armed, total, free, excl, regions) in enumerate(samples):
    t, f = int(total, 16), int(free, 16)
    if f > t:
        sys.exit("FAIL: allocator sample %d has free > total" % i)
    print("guest frames at sample %d: used=%d of %d (%d KiB of %d KiB) on a %d-page guest"
          % (i, t - f, t, (t - f) * 4, t * 4, 65215))
m = re.search(r"\s63 sys_mmap calls=(\d+)", ser)
print("in-guest compile sys_mmap calls: %s" % (m.group(1) if m else "not reported"))
PY

# Run 07: the guest's cmd/link links that object into an ELF, resolving
# symbols out of the package archives staged in the share. The host then holds
# the result to the SAME loader rules the kernel enforces before run 08 is
# allowed to execute it — segment count, sum of memsz, gap ceiling, W^X order,
# entry-inside-segment-0 and the argv+envp page slack.
vgate_run 07 -- --script '$RUN_DIR/script9.txt' --script2 '$RUN_DIR/script10.txt' --script2-after 'exec: loaded GOCMDLINK.ELF' --script3 '$RUN_DIR/script11.txt' --script3-after 'procs GOCMDLINK.ELF exited status=0' --script-expect 'selfhost-link-done' --timeout 900

vgate_assert 07 serial-contains 'exec: loaded GOCMDLINK.ELF'
vgate_assert 07 serial-contains 'procs GOCMDLINK.ELF exited status=0'
vgate_assert 07 serial-absent '[EXC] parking:'
vgate_assert 07 serial-absent 'cannot allocate memory'
vgate_assert 07 serial-absent 'panic:'
vgate_assert 07 python <<'PY'
import os, re, sys
sys.path.insert(0, os.path.join("tools", "lib"))
import elf_rules
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
elf = os.path.join(share, "HELLO2.ELF")
if not os.path.exists(elf):
    sys.exit("FAIL: the in-guest link produced nothing at " + elf)
# ONE copy of the kernel's loader rules, shared with live-selfhost-go.spec run 01
# (tools/lib/elf_rules.py): a rule that drifted in one spec would pass an image
# the kernel then refuses, far from the check that lied.
receipt, fails = elf_rules.check_file(elf, "HELLO2.ELF")
print("in-guest link: " + receipt)
ser = open(os.environ["VG_SER"], errors="replace").read()
for i, (armed, t, f, excl, regions) in enumerate(re.findall(
        r"allocator:\s+armed=(\d) total=(0x[0-9a-f]+) free=(0x[0-9a-f]+) "
        r"excluded=(0x[0-9a-f]+) regions=(0x[0-9a-f]+)", ser)):
    t, f = int(t, 16), int(f, 16)
    print("guest frames at sample %d: used=%d of %d (%d KiB of %d KiB)"
          % (i, t - f, t, (t - f) * 4, t * 4))
if fails:
    for f in fails:
        print("FAIL: " + f)
    sys.exit(1)
print("HELLO2.ELF satisfies every loader rule the kernel enforces")
PY

# Run 08: the binary the GUEST produced runs on the kernel. This is the
# end-to-end claim of the card: compile in-guest, link in-guest, execute the
# result. The pinned lines are the fixture's own vocabulary (phase 0a's
# runtime surface: console, sbrk heap growth, a GC cycle).
#
# No `procs HELLO2.ELF exited status=0` assert here: the run stops ON the
# program's last pinned line, which is printed before the process is reaped,
# so the exit line races the stop rather than reporting on the program. The
# absent-exception asserts are what rule out a crash.
vgate_run 08 -- --script '$RUN_DIR/script12.txt' --script-expect 'virelai-go OK' --timeout 300

vgate_assert 08 serial-contains 'exec: loaded HELLO2.ELF'
vgate_assert 08 serial-contains 'hello from virelai'
vgate_assert 08 serial-contains 'GOOS=virelai GOARCH=arm64 gc runtime alive'
vgate_assert 08 serial-contains 'heap: wrote 1048576 bytes'
vgate_assert 08 serial-contains 'gc: cycle completed'
vgate_assert 08 serial-contains 'virelai-go OK'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 serial-absent 'exited status=139'
vgate_assert 08 serial-absent 'cannot allocate memory'

# --- M69e (issue #1532): the daily loop, one boot per step --------------------
#
# The card's loop is edit -> compile -> run, and unlike the selfhost chain above
# the STEPS ARE SEQUENCED: the harness evaluates a run's asserts between runs,
# so run 09's hook compiles the file the guest just wrote and run 10 runs the
# result. What the guest authored is a ONE-LINE program (it has to be: the
# monitor's `write` joins its arguments and appends no newline), so the loop
# fixture lives on the share instead of in `tools/go/` - there is nothing to
# keep in sync, and no new demo app.
#
# D1 (the compiler is the Mac) is pinned rather than promised: the compile's
# receipt line `loop: host-built ...` is printed by the HOST into the gate log,
# and both runs assert that line absent from their own serial, so a future
# version that types a compiler banner into the guest console fails here.
#
# Run 09 writes, and stops on the monitor's own persistence report. That report
# carries the byte count, which the hook holds to the file it reads on macOS -
# the guest's claim about its edit and the host's copy of it have to agree.
vgate_file script13.txt <<'EOF'
write LOOP.GO 'package main; func main() { println("loop-m69e: guest-authored source") }'
EOF

# Run 10 is the run half: the image exists only because the hook on run 09 built
# it from that same file, and the hook deletes any earlier LOOP.ELF first, so a
# share left over from a previous gate run cannot satisfy this boot. The run
# stops on the SCHEDULER's exit line for the program (printed after its last
# write, unlike the program's own line, which only marks the print).
vgate_file script14.txt <<'EOF'
exec LOOP.ELF
EOF

# The fork must be provisioned BEFORE a boot, not built inside one: no
# make.bash in a gate (the rule tools/go/README.md states). Two files of the
# previous gate run cannot leak into this one.
vgate_setup_python <<'PY'
import os, sys
share = os.path.join(os.environ["RUN_DIR"], "share")
repo = os.getcwd()
fork = os.environ.get("GO_FORK_DIR") or os.path.join(os.path.dirname(repo), "go-virelai")
for need in (os.path.join(fork, "bin", "go"), os.path.join(fork, "src", "runtime")):
    if not os.path.exists(need):
        sys.exit("the M69e loop runs (09/10) compile with the fork toolchain on the "
                 "host, and %s is missing - run: bash tools/go/build-go.sh "
                 "tools/go/hello.go (fork prerequisites in tools/go/README.md)" % need)
for stale in ("LOOP.GO", "LOOP.ELF"):
    p = os.path.join(share, stale)
    if os.path.exists(p):
        os.remove(p)
        print("removed stale %s: run 09 must author it and run 10 must run the Mac's build of it" % stale)
print("loop: runs 09/10 stage no guest compiler - the Mac builds between the two boots")
PY

vgate_run 09 -- --script '$RUN_DIR/script13.txt' --script-expect 'write: ok (persisted' --timeout 120

vgate_assert 09 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 09 serial-absent ': not persisted - '
vgate_assert 09 serial-absent 'unterminated quote'
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 serial-absent 'build-go:'
vgate_assert 09 serial-absent 'loop: host-built'
# The harness's own share reader (not the hook below) sees the guest's file,
# and lifts it into evidence: artifacts/go-hello-share-LOOP.GO is the bytes the
# Mac compiled in this very run.
vgate_assert 09 share-contains LOOP.GO 'func main()'
vgate_assert 09 python <<'PY'
import hashlib, os, re, subprocess, sys, time
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
ser = open(os.environ["VG_SER"], errors="replace").read()
src = os.path.join(share, "LOOP.GO")
if not os.path.exists(src):
    sys.exit("FAIL: the guest wrote no /host/LOOP.GO - there is nothing for the Mac to compile")
raw = open(src, "rb").read()
if not raw.startswith(b"package main"):
    sys.exit("FAIL: the guest's file is not a Go program; it starts %r" % raw[:24])
if b"func main()" not in raw:
    sys.exit("FAIL: the guest's file has no func main()")
# The tokenizer's job, checked rather than trusted: the guest's own persistence
# report carries a byte count, and it has to be the size of the file on macOS.
m = re.search(r"write: ok \(persisted (\d+) bytes", ser)
if not m:
    sys.exit("FAIL: no `write: ok (persisted N bytes to the host share)` line")
if int(m.group(1)) != len(raw):
    sys.exit("FAIL: the guest reported %s persisted bytes but the share holds %d "
             "- the write did not land as authored" % (m.group(1), len(raw)))
# `go build` wants a lowercase .go extension; the share's convention is
# uppercase, so the compile takes a byte-verified copy. The claim is about
# bytes, and the copy is compared, not assumed.
work = os.path.join(os.environ["RUN_DIR"], "loop-src")
os.makedirs(work, exist_ok=True)
comp = os.path.join(work, "loop.go")
open(comp, "wb").write(raw)
if open(comp, "rb").read() != raw:
    sys.exit("FAIL: the compile input is not byte-identical to the guest's file")
elf = os.path.join(share, "LOOP.ELF")
if os.path.exists(elf):
    os.remove(elf)
    print("loop: removed a pre-existing LOOP.ELF - run 10 must execute this build")
env = dict(os.environ)
env["GO_BUILD_OUT"] = share
env["GO_BUILD_NAME"] = "LOOP"
env["GO_STRICT_LAYOUT"] = "1"   # a shifted segment is a failure, not a warning
t0 = time.time()
try:
    p = subprocess.run(["bash", "tools/go/build-go.sh", comp], env=env,
                       capture_output=True, text=True, timeout=900)
except subprocess.TimeoutExpired:
    sys.exit("FAIL: the host build of the guest's own source did not finish in 900 s")
for line in ((p.stdout or "") + (p.stderr or "")).splitlines():
    print("  build-go| " + line)
if p.returncode != 0:
    sys.exit("FAIL: the Mac could not build the guest's own source (rc=%d); an "
             "in-guest build is NOT the loop this card claims" % p.returncode)
if not os.path.exists(elf):
    sys.exit("FAIL: build-go.sh reported success but wrote no " + elf)
eb = open(elf, "rb").read()
if eb[:4] != b"\x7fELF":
    sys.exit("FAIL: LOOP.ELF is not an ELF image; first bytes %r" % eb[:8])
if os.path.getmtime(elf) < t0 or len(eb) < 1 << 16:
    sys.exit("FAIL: LOOP.ELF predates this compile or is too small to be a Go image (%d bytes)" % len(eb))
# The image has to carry the literal the guest's source names: that is what
# makes run 10's own output a statement about the guest's bytes rather than
# about a binary that happened to be in the share.
mm = re.search(r'println\("([^"]*)"\)', raw.decode(errors="replace"))
if not mm:
    sys.exit("FAIL: the guest's program prints no string literal for run 10 to hold it to")
marker = mm.group(1)
if marker.encode() not in eb:
    sys.exit("FAIL: the image the Mac just built does not contain %r, the literal the "
             "guest's own source names" % marker)
open(os.path.join(os.environ["RUN_DIR"], "loop-marker.txt"), "w").write(marker)
print("loop: the guest's file is %r" % raw.decode())
print("loop: host-built GOOS=virelai LOOP.ELF %d bytes from the guest's own /host/LOOP.GO "
      "%d bytes sha256=%s (not from any staged fixture)"
      % (len(eb), len(raw), hashlib.sha256(raw).hexdigest()))
print("loop: the source names %r and that literal is in the image" % marker)
PY

vgate_run 10 -- --script '$RUN_DIR/script14.txt' --script-expect 'procs LOOP.ELF exited status=0' --timeout 180

vgate_assert 10 serial-contains 'exec: loaded LOOP.ELF'
vgate_assert 10 serial-contains 'procs LOOP.ELF exited status=0'
vgate_assert 10 serial-contains-file loop-marker.txt
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 serial-absent 'exited status=139'
vgate_assert 10 serial-absent 'build-go:'
vgate_assert 10 serial-absent 'loop: host-built'
vgate_assert 10 python <<'PY'
import os, re, sys
# The chain closes here, with no literal of its own: the expectation is read
# back off the file the GUEST wrote, so these two boots cannot drift into
# agreeing because a string was pasted twice in this spec.
ser = open(os.environ["VG_SER"], errors="replace").read()
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(share, "LOOP.GO")
if not os.path.exists(src):
    sys.exit("FAIL: the guest's own /host/LOOP.GO is gone from the share")
raw = open(src, "rb").read().decode(errors="replace")
mm = re.search(r'println\("([^"]*)"\)', raw)
if not mm:
    sys.exit("FAIL: the guest's source names no literal to hold the run to")
marker = mm.group(1)
if not re.search("^" + re.escape(marker) + "$", ser, re.M):
    sys.exit("FAIL: no whole line %r in run 10's serial - the guest ran an image that "
             "does not print the literal its own source names" % marker)
# D1: the compile is the Mac's, and its receipts are the host's. A version that
# typed a build banner into the guest console fails right here.
for leak in ("build-go:", "loop: host-built"):
    if leak in ser:
        sys.exit("FAIL: %r appears in run 10's serial - the compile is the Mac's, and "
                 "the guest's console must not say otherwise" % leak)
print("run 10 printed the guest's own literal %r as a whole line, with no compiler "
      "banner in its serial" % marker)
PY
# ---------------------------------------------------------------------------
# M72a (issue #1579) runs 11-12: the mapped-memory bound, on a real Go image.
# Two boots, because the two halves are different questions and one boot
# cannot order them: a program's output is asynchronous to the next monitor
# line, so the refusal (parse-time) would land before the fixture's banner.
# Each run therefore waits on its OWN causal marker.
# ---------------------------------------------------------------------------

# Run 11: the image the old bound refused EXECS. The wait is the program's
# own final line, so a loader that refused the file cannot go green here.
vgate_file script15.txt <<'EOF'
exec GOLOADBSS.ELF
EOF

# Run 12: ...and the bound MOVED, it did not disappear. The wait is the
# sysinfo header AFTER the refusal, so this run also proves the monitor kept
# reading input (a refusal that parked the monitor cannot pass), and its
# allocator line is where the log's free-page number comes from.
vgate_file script16.txt <<'EOF'
exec HUGEBSS.ELF
sysinfo
EOF

vgate_setup_python <<'PY'
import os, struct, sys

# Host-side self-checks before any boot, so these runs cannot go green on a
# fixture that lost the shape it exists to have: the file must be too big to
# stage (that is what makes the exec STREAM) and its writable segment must
# carry at least 40 MiB of `.bss` (that is what the old bound refused).
share = os.path.join(os.environ["RUN_DIR"], "share")
path = os.path.join(share, "GOLOADBSS.ELF")
if not os.path.exists(path):
    sys.exit("GOLOADBSS.ELF missing - bash tools/go/build-go.sh tools/go/goloadbss.go")
d = open(path, "rb").read()
if len(d) <= 2 << 20:
    sys.exit("GOLOADBSS.ELF is only %d B - under the 2 MiB staging buffer, so the exec would "
             "take the STAGED path and this run would prove nothing about the streamed one"
             % len(d))
phoff = struct.unpack_from("<Q", d, 32)[0]
phes = struct.unpack_from("<H", d, 54)[0]
phnum = struct.unpack_from("<H", d, 56)[0]
rw = None
tot_mem = 0
for i in range(phnum):
    o = phoff + i * phes
    t, fl, off, va, pa, fsz, msz, al = struct.unpack_from("<IIQQQQQQ", d, o)
    if t != 1:
        continue
    tot_mem += msz
    if fl & 2:
        rw = (o, va, fsz, msz)
if rw is None:
    sys.exit("GOLOADBSS.ELF has no writable PT_LOAD segment")
ro, rva, rfsz, rmsz = rw
if rmsz - rfsz < 40 << 20:
    sys.exit("GOLOADBSS.ELF's writable segment holds only %d bytes of .bss; this fixture needs "
             ">= 40 MiB for the mapped bound to be the one it crosses" % (rmsz - rfsz))
if tot_mem <= 32 << 20:
    sys.exit("GOLOADBSS.ELF maps %d B - the old memsz-charged bound would have admitted it, so "
             "it pins nothing" % tot_mem)
print("staged GOLOADBSS.ELF %d B: RW filesz=%d memsz=%d (.bss %.2f MiB), total mapped %.2f MiB, "
      "headers say %d pages"
      % (len(d), rfsz, rmsz, (rmsz - rfsz) / 1048576.0, tot_mem / 1048576.0,
         (rmsz + 4095) // 4096 + 1))

# The negative twin for run 12: the SAME bytes with the writable segment's
# p_memsz rewritten to 1 GiB. Nothing else moves, so the refusal can only
# come from the mapped-memory bound - the XL.ELF precedent, patching the
# field under test instead of padding the file.
huge = bytearray(d)
struct.pack_into("<Q", huge, ro + 40, 1 << 30)   # p_memsz
open(os.path.join(share, "HUGEBSS.ELF"), "wb").write(huge)
print("staged HUGEBSS.ELF: the same image with RW p_memsz = 1 GiB")
PY

vgate_run 11 -- --script '$RUN_DIR/script15.txt' --script-expect 'virelai-go loadbss OK' --timeout 300

# The 9.1 MiB file maps 48 MiB and RUNS: its own banner, and both ends of the
# 40 MiB tail read back (the program writes byte 0 and byte scratchBytes-1
# and prints them), so a short mapping faults or prints the wrong byte.
vgate_assert 11 serial-contains 'exec: loaded GOLOADBSS.ELF'
vgate_assert 11 serial-contains 'loadbss: blob bytes 8388608 scratch bytes 41943040'
vgate_assert 11 serial-contains 'loadbss: banner A B C E D'
vgate_assert 11 serial-contains 'loadbss: scratch ends 1 2'
vgate_assert 11 serial-contains 'virelai-go loadbss OK'
vgate_assert 11 serial-absent '[EXC] parking:'
vgate_assert 11 serial-absent 'exited status=139'

# M171a (card #3032): the mapping is still held to the image's own headers,
# but on TWO numbers now. `mappedpages=` is the VIRTUAL span — the
# page-rounded RW p_memsz plus any argv/envp headroom (for this fixture's
# page-aligned memsz, exactly ceil(memsz/4096) + 1). `datapages=` is the
# RESIDENT count at exec — the file-backed pages plus the argv run (two
# pages bound), never the 40 MiB tail: that memory now exists only once
# the program touches it. Both are asserted as numbers, not as "it ran".
vgate_assert 11 python <<'PY'
import os, re, struct, sys

ser = open(os.environ["VG_SER"], errors="replace").read()
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
d = open(os.path.join(share, "GOLOADBSS.ELF"), "rb").read()
phoff = struct.unpack_from("<Q", d, 32)[0]
phes = struct.unpack_from("<H", d, 54)[0]
phnum = struct.unpack_from("<H", d, 56)[0]
rw_fsz = rw_msz = None
for i in range(phnum):
    o = phoff + i * phes
    t, fl, off, va, pa, fsz, msz, al = struct.unpack_from("<IIQQQQQQ", d, o)
    if t == 1 and fl & 2:
        rw_fsz, rw_msz = fsz, msz
if rw_fsz is None:
    sys.exit("FAIL: the staged GOLOADBSS.ELF has no writable PT_LOAD segment")
file_pages = (rw_fsz + 4095) // 4096
mem_pages = (rw_msz + 4095) // 4096
cover = (((rw_msz + 7) & ~7) + 4096 + 4095) // 4096
expected_map = max(mem_pages, cover)
m = re.search(r"exec: loaded GOLOADBSS\.ELF .*datapages=(\d+) mappedpages=(\d+)", ser)
if not m:
    sys.exit("FAIL: no `exec: loaded GOLOADBSS.ELF ... datapages= mappedpages=` line")
data_pages, map_pages = int(m.group(1)), int(m.group(2))
if map_pages != expected_map:
    sys.exit("FAIL: the guest mapped %d pages but the image's writable segment spans %d "
             "(%d B of memsz) - the virtual bound did not follow the headers"
             % (map_pages, expected_map, rw_msz))
if map_pages < 10240:
    sys.exit("FAIL: %d mapped pages is under the 40 MiB the fixture's .bss needs" % map_pages)
if data_pages > file_pages + 2:
    sys.exit("FAIL: datapages=%d beyond file pages %d + argv run — the zero-fill "
             "tail is resident at exec (mapped %d)" % (data_pages, file_pages, map_pages))
if data_pages < file_pages:
    sys.exit("FAIL: datapages=%d under the file-backed count %d — the streamed "
             "image data is not resident" % (data_pages, file_pages))
print("mapped %d virtual pages of a %d B file (RW filesz=%d memsz=%d, %.2f MiB of "
      ".bss); resident at exec only %d — the tail faulted in on touch, and the "
      "program read both ends of it back"
      % (map_pages, len(d), rw_fsz, rw_msz, (rw_msz - rw_fsz) / 1048576.0, data_pages))
PY

vgate_run 12 -- --script '$RUN_DIR/script16.txt' --script-expect 'VirelaiOS AArch64 support snapshot' --timeout 300

# The refusal NAMES the bound it crossed, and `staging buffer` is absent on
# purpose: that sentence is what the old fall-through printed about this very
# shape, and it was false (the image is a gap-layout static ELF; it would
# have streamed). The 9.1 MiB file is under the acceptance bound either way,
# so only the mapped total can refuse it.
vgate_assert 12 serial-contains 'HUGEBSS.ELF: image maps too much memory (map bound'
vgate_assert 12 serial-absent 'exec: loaded HUGEBSS.ELF'
vgate_assert 12 serial-absent 'staging buffer'
vgate_assert 12 serial-absent 'HUGEBSS.ELF: image too large'
vgate_assert 12 serial-absent '[EXC] parking:'
vgate_assert 12 serial-absent 'exited status=139'
# Reported, not asserted: a free-page count is a property of the machine
# (ADR 0035 D6's footprint samples), and the point of printing it is that the
# number is in the log rather than in a sentence somewhere.
vgate_assert 12 serial-contains 'allocator:  armed=1'
vgate_assert 12 python <<'PY'
import os, re, sys

ser = open(os.environ["VG_SER"], errors="replace").read()
bad_at = ser.find("HUGEBSS.ELF: image maps too much memory")
info_at = ser.find("VirelaiOS AArch64 support snapshot")
if bad_at == -1:
    sys.exit("FAIL: no refusal naming the mapped-memory bound")
if info_at < bad_at:
    sys.exit("FAIL: sysinfo printed BEFORE the refusal - the script's order did not hold "
             "(refusal=%d sysinfo=%d)" % (bad_at, info_at))
if "staging buffer" in ser:
    sys.exit("FAIL: the refusal mentioned a staging buffer - the image is a gap-layout static "
             "ELF and no part of it was staged")
free = re.findall(r"allocator:  armed=1 total=0x[0-9a-f]+ free=0x([0-9a-f]+)", ser)
if not free:
    sys.exit("FAIL: no allocator line in the serial")
print("the 1 GiB twin was refused by the map bound, and the monitor kept reading "
      "(free=0x%s pages after the refusal)" % free[-1])
PY

# #2354 run 13: the large-read straddle regression leg, on the pure cv
# channel (the spec's `seed` share). GOREAD/GOSYSCALL hash their file
# through a fixed cap-sized buffer (2048 B, then 32 KiB since card #3035)
# that lands inside ONE armed region every call; os.ReadFile's destination
# grows across the whole file, so its chunks eventually straddle the
# boundary between two of the Go
# heap's adjacent sbrk regions — the exact copy_out range that used to
# EFAULT. The assert holds the guest's own byte count + FNV-1a-64 to the
# file on macOS, and the ReadAt pair proves the port's post-read shadow
# serves backward offsets too.
vgate_run 13 -- --script '$RUN_DIR/script17.txt' --script-expect 'gobigread: BIGREAD OK' --timeout 300

vgate_assert 13 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 13 serial-contains 'exec: loaded GOBIGREAD.ELF'
vgate_assert 13 serial-contains 'gobigread: readat deep+mid ok'
vgate_assert 13 serial-contains 'gobigread: BIGREAD OK'
vgate_assert 13 serial-absent 'gobigread: FAIL'
vgate_assert 13 serial-absent 'bad address'
vgate_assert 13 serial-absent '[EXC] parking:'
vgate_assert 13 serial-absent 'exited status=139'
vgate_assert 13 python <<'PY'
import os, sys
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
src = os.path.join(share, "GOBIG.ELF")  # what the fixture os.ReadFile'd
if not os.path.exists(src):
    sys.exit("FAIL: the fixture's input is missing: " + src)
n = os.path.getsize(src)
if n <= 4 * 1024 * 1024 + 400 * 1024:
    sys.exit("FAIL: GOBIG.ELF is %d B — under the ~4.4 MiB cliff, the "
             "straddle is untested" % n)
# FNV-1a-64, the same fold the fixture prints.
h = 0xcbf29ce484222325
with open(src, "rb") as fh:
    blob = fh.read()
for byte in blob:
    h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
ser = open(os.environ["VG_SER"], errors="replace").read()
want = "gobigread: readfile bytes %d fnv 0x%016x" % (n, h)
if want not in ser:
    sys.exit("FAIL: the guest's os.ReadFile hash does not match the file on "
             "macOS (want %r)" % want)
print("os.ReadFile over cv: %d B, fnv 0x%016x — byte-exact past the "
      "4.4 MiB straddle cliff" % (n, h))
PY
