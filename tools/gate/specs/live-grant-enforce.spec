# live-grant-enforce.spec -- M116b (issue #2468, ADR 0054 D8/D9/D12):
# the audit -> enforce flip, live on VZ, on one share with a host-seeded
# `GRANTS.TXT` carrying `#v1 mode=enforce`:
#
#   * DENIED.ELF — a fixture binary carrying NO row: the M116b ambient
#     floor applies (file/audio/net are row-only words now; debug stays
#     because ping/write/exit are existence verbs). Its file open is
#     refused by name — `refused:file_denied name=DENIED.ELF word=file`
#     AND the syscall answers honest EACCES the app prints itself — and
#     its socket open is refused the same way. It still prints and exits
#     cleanly: confined, not stuck.
#   * GRANTED.ELF — the SAME bytes under a `*`-bound row carrying
#     file,memory,process,debug,net: under enforce both calls land — a
#     row overrides the ambient floor.
#   * GOHELLO.ELF / GOSH.ELF — the in-tree fleet: rowed apps measure in,
#     run, and the serial seat still attaches under enforce.
#
# The rows key the RECORDED image name, so same-bytes copies are the
# experiment's controlled variable (the live-trust-grants pattern).
vgate_name live-grant-enforce "#2468 M116b: mode=enforce — denied words answer named EACCES; fleet boots/seats green"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt kernel/src/*.zig user/src/*.zig build.zig

vgate_file enforce.go <<'EOF'
package main

import (
    "time"
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

func main() {
    // The `file` word: open a share file through the file ABI.
    if _, rc := vi.ReadFileAll("PROBE.TXT", 64); rc < 0 {
        vsys.Println("enforce: file refused " + errnoName(rc))
    } else {
        vsys.Println("enforce: file read")
    }
    // The `net` word: a socket open against the live responder.
    c, err := vi.DialTimeout("10.0.0.2", 8080, 5*time.Second)
    if err != nil {
        vsys.Println("enforce: dial refused " + err.Error())
    } else {
        vsys.Println("enforce: connected")
        _ = c.Close()
    }
    // The `debug` word (ambient): the confined app still prints and
    // exits — the refusal is named, not silent.
    vsys.Println("enforce: done")
    vsys.Exit(0)
}
EOF

vgate_setup_python <<'PY'
import os, pathlib, shutil, subprocess, sys
rd = pathlib.Path(os.environ["RUN_DIR"])
share = pathlib.Path(os.environ.get("VG_SHARE") or rd / "share")
tmp = rd / "enforce-build"
tmp.mkdir(exist_ok=True)
# One binary, two row names — same-bytes copies are the controlled
# variable (the live-trust-grants pattern).
env = dict(os.environ, TMPDIR=str(tmp), GO_BUILD_OUT=str(share),
           GO_BUILD_NAME="ENPROBE", GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh", str(rd / "enforce.go")],
               env=env, check=True)
for name in ("DENIED", "GRANTED"):
    shutil.copyfile(share / "ENPROBE.ELF", share / (name + ".ELF"))
os.remove(share / "ENPROBE.ELF")
# The fleet legs: GOHELLO (rowed, debug+memory+process+file) and GOSH
# (the serial seat — rowed file,memory,process,debug,term).
for name, script in (("GOHELLO.ELF", ["tools/go/build-go.sh", "tools/go/hello.go"]),
                      ("GOSH.ELF", ["tools/go/build-gosh.sh"])):
    src = pathlib.Path(".build/go") / name
    if not src.exists():
        subprocess.run(["bash"] + script, check=True)
    shutil.copy(src, share / name)
# The share file the `file` word leg opens.
(share / "PROBE.TXT").write_text("probe-payload\n")
# The user grant table: `mode=enforce` posture; GRANTED carries its
# words, DENIED carries no row -> the M116b ambient floor.
(share / "GRANTS.TXT").write_text(
    "#v1 mode=enforce\n"
    "GRANTED.ELF\t*\tfile,memory,process,debug,net\n"
)
print("enforce fixtures + GRANTS.TXT ok")
PY

vgate_file script-01.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp 10.0.0.2
exec DENIED.ELF
exec GRANTED.ELF
exec GOHELLO.ELF
exec GOSH.ELF serial
echo monitor-done
EOF

# The serial seat's typed input (CR submits on this seam, like
# live-trust-modes).
vgate_setup_python <<'PY'
import os
rd = os.environ["RUN_DIR"]
open(os.path.join(rd, "seat.bin"), "wb").write(
    b"echo seat-green\r"
)
print("seat input ok")
PY

vgate_run 01 -- --net '$RUN_DIR/cap.bin' \
    --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:8080 \
    --script '$RUN_DIR/script-01.txt' \
    --script2 '$RUN_DIR/seat.bin' --script2-after 'gosh: attached' \
    --script-expect 'seat-green' --timeout 90

# --- the denied app: refusals name the app AND the word, the syscall
# answers honest EACCES, and the app still reaches exit ---------------
vgate_assert 01 serial-contains 'verdict=measured name=DENIED.ELF'
vgate_assert 01 serial-contains 'refused:file_denied name=DENIED.ELF word=file'
vgate_assert 01 serial-contains 'refused:net_denied name=DENIED.ELF word=net'
vgate_assert 01 serial-contains 'enforce: file refused EACCES'
vgate_assert 01 serial-contains 'enforce: dial refused EACCES'
vgate_assert 01 serial-contains 'enforce: done'
vgate_assert 01 serial-contains 'DENIED.ELF exited status=0'

# --- the rowed control: same bytes, both calls land --------------------
vgate_assert 01 serial-contains 'verdict=measured name=GRANTED.ELF'
vgate_assert 01 serial-contains 'enforce: file read'
vgate_assert 01 serial-contains 'enforce: connected'
vgate_assert 01 serial-absent 'denied name=GRANTED.ELF'
# "Allowed" reached the wire — the responder saw the SYN, so the word
# gate let the open through, not just failed to receipt.
vgate_assert 01 output-contains 'NET-TCP: answered the guest'

# --- the fleet under enforce: a rowed app and the serial seat ----------
vgate_assert 01 serial-contains 'virelai-go OK'
vgate_assert 01 serial-absent 'denied name=GOHELLO.ELF'
vgate_assert 01 serial-contains 'gosh: attached'
vgate_assert 01 serial-contains 'seat-green'

# --- posture: nothing audit-receipted under enforce --------------------
vgate_assert 01 serial-absent 'verdict=audit:'
vgate_assert 01 serial-absent '[EXC] parking:'
