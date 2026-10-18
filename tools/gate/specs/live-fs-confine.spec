# live-fs-confine.spec -- M116d (issue #2470, ADR 0054 D9/D12): the
# grant `file` word's `fs=` path scope, live on VZ under mode=enforce.
# A row's fourth field lists canonical `/vol[/sub]` prefixes with a
# `:ro|rw` suffix — every path-bearing file op (open/delete/rename/
# list/mode, the slot-79 root+relative ops, every pin use) must land
# under one. One FSPROBE binary copied to three names is the controlled
# variable (the live-trust-grants pattern):
#
#   * FSRO.ELF — `fs=/host/FSDATA:ro,fs=/disk/appdata:rw`: the card's
#     own shape. Its in-prefix read lands, a write under the ro prefix
#     is `fs_write_denied`, reads/writes outside every prefix are
#     `fs_path_denied`, and the rw disk scope takes both directions.
#   * FSOFF.ELF — `fs=/disk/elsewhere:rw`: every one of its six touches
#     is off-list and refused by name.
#   * FSOPEN.ELF — the SAME bytes under a scope-less row: every leg
#     lands — scope only narrows, and the fixture's own EACCES prints
#     prove the denial surfaced at the syscall, not just the receipt.
vgate_name live-fs-confine "M116d #2470 — grant fs= path scope: /host ro + /disk rw prefixes, off-list refused by name"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt kernel/src/*.zig user/src/*.zig build.zig

vgate_file fsconf.go <<'EOF'
package main

import (
    "virelai/vi"
    "virelai/vsys"
)

func errnoName(rc int64) string {
    switch -rc {
    case vi.ErrEACCES:
        return "EACCES"
    case vi.ErrENOENT:
        return "ENOENT"
    }
    return "errno" + vsys.Itoa64(-rc)
}

func writeSmall(path string, b []byte) int64 {
    h, rc := vi.FileOpen(path, vi.ModeWrite|vi.ModeCreate)
    if rc < 0 {
        return rc
    }
    _, wrc := vi.FileWrite(uint32(h), b)
    vi.FileClose(uint32(h))
    return wrc
}

func main() {
    me := "?"
    if args := vi.Args(); len(args) > 0 {
        me = args[0]
    }
    // In-scope host read.
    if _, rc := vi.ReadFileAll("/host/FSDATA/OK.TXT", 64); rc < 0 {
        vsys.Println(me + " read-in " + errnoName(rc))
    } else {
        vsys.Println(me + " read-in ok")
    }
    // In-prefix host write — the ro leg under FSRO.
    if rc := writeSmall("/host/FSDATA/NEW.TXT", []byte("n")); rc < 0 {
        vsys.Println(me + " write-in " + errnoName(rc))
    } else {
        vsys.Println(me + " write-in ok")
    }
    // Off-scope host read.
    if _, rc := vi.ReadFileAll("/host/OTHER.TXT", 64); rc < 0 {
        vsys.Println(me + " read-out " + errnoName(rc))
    } else {
        vsys.Println(me + " read-out ok")
    }
    // The rw disk prefix, both directions.
    if rc := writeSmall("/disk/appdata/Y.TXT", []byte("y")); rc < 0 {
        vsys.Println(me + " write-appdata " + errnoName(rc))
    } else {
        vsys.Println(me + " write-appdata ok")
    }
    if _, rc := vi.ReadFileAll("/disk/appdata/Y.TXT", 64); rc < 0 {
        vsys.Println(me + " read-appdata " + errnoName(rc))
    } else {
        vsys.Println(me + " read-appdata ok")
    }
    // Off-scope disk write.
    if rc := writeSmall("/disk/other/Z.TXT", []byte("z")); rc < 0 {
        vsys.Println(me + " write-offdisk " + errnoName(rc))
    } else {
        vsys.Println(me + " write-offdisk ok")
    }
    vsys.Println(me + " done")
    vsys.Exit(0)
}
EOF

vgate_setup_python <<'PY'
import os, pathlib, shutil, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
share = pathlib.Path(os.environ.get("VG_SHARE") or rd / "share")
tmp = rd / "fsconf-build"
tmp.mkdir(exist_ok=True)
env = dict(os.environ, TMPDIR=str(tmp), GO_BUILD_OUT=str(share),
           GO_BUILD_NAME="FSPROBE", GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh", str(rd / "fsconf.go")], env=env, check=True)
# One binary, three row names — same-bytes copies are the controlled
# variable (the live-trust-grants pattern).
for name in ("FSRO", "FSOFF", "FSOPEN"):
    shutil.copyfile(share / "FSPROBE.ELF", share / (name + ".ELF"))
os.remove(share / "FSPROBE.ELF")
# The share fixtures: the in-scope dir+file and the off-scope file.
(share / "FSDATA").mkdir(exist_ok=True)
(share / "FSDATA" / "OK.TXT").write_text("in-scope\n")
(share / "OTHER.TXT").write_text("off-scope\n")
# The golden empty 16 MiB VLFS image for --data-disk (the
# live-vlfs-write pattern — header + non-zero runs from .regions).
img = None
for line in pathlib.Path("kernel/src/vlfs/testdata/empty-16m.regions").read_text().splitlines():
    if not line or line.startswith("#") or line == "vlfs-regions 1":
        continue
    if line.startswith("bytes "):
        img = bytearray(int(line[6:]))
        continue
    off, hexs = line.split(" ", 1)
    img[int(off):int(off) + len(hexs) // 2] = bytes.fromhex(hexs)
assert img is not None and len(img) == 16 * 1024 * 1024
(rd / "vlfs.img").write_bytes(bytes(img))
# mode=enforce posture; the three rows are the controlled variable —
# the fs= scope differs, the word set (file, no net) does not.
open(share / "GRANTS.TXT", "w").write(
    "#v1 mode=enforce\n"
    "FSRO.ELF\t*\tfile,memory,process,debug\tfs=/host/FSDATA:ro,fs=/disk/appdata:rw\n"
    "FSOFF.ELF\t*\tfile,memory,process,debug\tfs=/disk/elsewhere:rw\n"
    "FSOPEN.ELF\t*\tfile,memory,process,debug\n"
)
print("fsconf fixtures + GRANTS.TXT ok")
PY

# The disk parents exist before the confined apps run (monitor vf ops
# are kernel-actor, never scope-checked); then the three same-bytes
# binaries run their fixed op sequence. script-02 is stage-gated on
# FSOFF's own completion marker — guest output, so the run cannot end
# while a launched program is still starting.
vgate_file script-01.txt <<'EOF'
vf mkdir /disk/appdata
vf mkdir /disk/other
exec FSRO.ELF
exec FSOFF.ELF
EOF

vgate_file script-02.txt <<'EOF'
exec FSOPEN.ELF
echo fsconf-done
EOF

vgate_run 01 -- --data-disk '$RUN_DIR/vlfs.img' \
    --script '$RUN_DIR/script-01.txt' \
    --script2 '$RUN_DIR/script-02.txt' --script2-after 'FSOFF.ELF done' \
    --script-expect 'fsconf-done' --timeout 90

vgate_assert 01 output-contains 'data-disk: ENABLED'

# --- FSRO: the card's own scope shape — in-prefix ops land, the ro
# write and both off-list touches are refused by name ---------------
vgate_assert 01 serial-contains 'FSRO.ELF read-in ok'
vgate_assert 01 serial-contains 'FSRO.ELF write-in EACCES'
vgate_assert 01 serial-contains 'FSRO.ELF read-out EACCES'
vgate_assert 01 serial-contains 'FSRO.ELF write-appdata ok'
vgate_assert 01 serial-contains 'FSRO.ELF read-appdata ok'
vgate_assert 01 serial-contains 'FSRO.ELF write-offdisk EACCES'
vgate_assert 01 serial-contains 'verdict=refused:fs_write_denied name=FSRO.ELF'
vgate_assert 01 serial-count 'verdict=refused:fs_path_denied name=FSRO.ELF' 2

# --- FSOFF: every touch is off its /disk/elsewhere scope -------------
vgate_assert 01 serial-count 'verdict=refused:fs_path_denied name=FSOFF.ELF' 6
vgate_assert 01 serial-contains 'FSOFF.ELF read-in EACCES'
vgate_assert 01 serial-contains 'FSOFF.ELF write-offdisk EACCES'

# --- FSOPEN: the scope-less control — every leg lands ----------------
vgate_assert 01 serial-contains 'FSOPEN.ELF read-in ok'
vgate_assert 01 serial-contains 'FSOPEN.ELF write-in ok'
vgate_assert 01 serial-contains 'FSOPEN.ELF read-out ok'
vgate_assert 01 serial-contains 'FSOPEN.ELF write-appdata ok'
vgate_assert 01 serial-contains 'FSOPEN.ELF read-appdata ok'
vgate_assert 01 serial-contains 'FSOPEN.ELF write-offdisk ok'
vgate_assert 01 serial-absent 'denied name=FSOPEN.ELF'

# --- posture: confined apps still exit clean; nothing audit-receipted
vgate_assert 01 serial-contains 'FSRO.ELF done'
vgate_assert 01 serial-contains 'FSOFF.ELF done'
vgate_assert 01 serial-contains 'FSOPEN.ELF done'
vgate_assert 01 serial-contains 'fsconf-done'
vgate_assert 01 serial-absent 'verdict=audit:'
vgate_assert 01 serial-absent '[EXC] parking:'
