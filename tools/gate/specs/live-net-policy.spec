# live-net-policy.spec -- M117e (issue #2477, ADR 0057 D12 + 0054 D9/D12):
# the grant `net` word's scope qualifiers, live on VZ under mode=enforce.
# GRANTS.TXT rows carry an optional fourth field: `v6=<prefix>/<len>`
# bounds a v6-family connect's literal, `if=<nat|bridged>` bounds the
# destination's path class (`nat` = router-mediated, the island's reach —
# the router itself is fabric; `bridged` = an L2-adjacent peer, the class
# the bridged/vmnet LAN adds). One DIALER binary copied to five names is
# the controlled variable: three v6 dials of the SAME resolvable on-link
# literal produce `v6_literal_denied` (off-prefix), `bridged_denied`
# (L2-adjacent class outside if=nat), and a landed handshake (V6OK) —
# while LANDENY's on-link v4 peer is refused and LANOK's scope-less row
# connects. The op's own resolution checks precede the scope check, so
# every denied dial still names a resolvable destination: the receipts
# are policy verdicts, not topology accidents.
vgate_name live-net-policy "M117e #2477 ADR 0057 D12 — grant net scope: v6 prefixes + bridged path class, named refusals"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_fmt kernel/src/*.zig user/src/*.zig build.zig

vgate_file dial.go <<'EOF'
package main

import (
    "strconv"
    "time"
    "virelai/vi"
    "virelai/vsys"
)

func main() {
    args := vi.Args()
    if len(args) < 3 {
        vsys.Println("netpolicy: usage")
        vsys.Exit(2)
    }
    port64, perr := strconv.ParseUint(args[2], 10, 16)
    if perr != nil {
        vsys.Println("netpolicy: bad port")
        vsys.Exit(2)
    }
    vsys.Println("netpolicy: dialing " + args[1])
    c, err := vi.DialTimeout(args[1], uint16(port64), 5*time.Second)
    if err != nil {
        vsys.Println("netpolicy: dial refused " + err.Error())
        vsys.Exit(1)
    }
    vsys.Println("netpolicy: connected")
    if err = c.Close(); err != nil {
        vsys.Println("netpolicy: close failed")
        vsys.Exit(1)
    }
    vsys.Println("netpolicy: done")
    vsys.Exit(0)
}
EOF

vgate_setup_python <<'PY'
import os, pathlib, shutil, subprocess
rd = pathlib.Path(os.environ["RUN_DIR"])
share = pathlib.Path(os.environ.get("VG_SHARE") or rd / "share")
tmp = rd / "dial-build"
tmp.mkdir(exist_ok=True)
env = dict(os.environ, TMPDIR=str(tmp), GO_BUILD_OUT=str(share),
           GO_BUILD_NAME="DIALER", GO_LDFLAGS_VALUE="-s -w")
subprocess.run(["bash", "tools/go/build-go.sh", str(rd / "dial.go")], env=env, check=True)
# One binary, five row names — same-bytes copies are the controlled
# variable (the live-trust-grants pattern).
for name in ("V6DENY", "V6OK", "V6LAN", "LANDENY", "LANOK"):
    shutil.copyfile(share / "DIALER.ELF", share / (name + ".ELF"))
open(share / "GRANTS.TXT", "w").write(
    "#v1 mode=enforce\n"
    "V6DENY.ELF\t*\tfile,memory,process,debug,net\tv6=fd00::/8\n"
    "V6OK.ELF\t*\tfile,memory,process,debug,net\tv6=2001:db8:64::/64\n"
    "V6LAN.ELF\t*\tfile,memory,process,debug,net\tif=nat\n"
    "LANDENY.ELF\t*\tfile,memory,process,debug,net\tif=nat\n"
    "LANOK.ELF\t*\tfile,memory,process,debug,net\n"
)
print("netpolicy fixtures + GRANTS.TXT ok")
PY

# s1: the v4 island legs. `net ip` + `net arp` configure the static /24;
# 10.0.0.2 is then L2-adjacent — the `bridged` class — so LANDENY's
# if=nat row refuses it by name while LANOK's scope-less row connects
# (the ARP pair lands the peer before either dials).
vgate_file s1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
net arp 10.0.0.2
exec LANDENY.ELF 10.0.0.2 8080
exec LANOK.ELF 10.0.0.2 8080
echo s1-done
EOF

# s2: the v6 legs, gated on the SLAAC global. `net ndp` resolves the
# peer once, then three rows dial the SAME literal: V6DENY is off its
# fd00::/8 prefix, V6LAN is on-link outside its if=nat set, V6OK is
# in-prefix and connects.
vgate_file s2.txt <<'EOF'
net ndp 2001:db8:64::ff:fe00:2
net ndp 2001:db8:64::ff:fe00:2
exec V6DENY.ELF 2001:db8:64::ff:fe00:2 8080
exec V6LAN.ELF 2001:db8:64::ff:fe00:2 8080
exec V6OK.ELF 2001:db8:64::ff:fe00:2 8080
echo s2-done
EOF

vgate_run p1 -- --net '$RUN_DIR/p1.cap' \
    --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:8080 \
    --net-ra-respond '2001:db8:64::/64' \
    --net-ndp-respond '2001:db8:64::ff:fe00:2' \
    --net-tcp6-respond '[2001:db8:64::ff:fe00:2]:8080' \
    --script '$RUN_DIR/s1.txt' \
    --script2 '$RUN_DIR/s2.txt' --script2-after 'net: v6 g6=2001:db8:64::ff:fe00:1 valid' \
    --script-expect 's2-done' --timeout 90

# The three refusals, each named: the qualifier in the verdict, the
# image in name= — "refused by name" on both axes.
vgate_assert p1 serial-contains 'verdict=refused:bridged_denied name=LANDENY.ELF'
vgate_assert p1 serial-contains 'verdict=refused:bridged_denied name=V6LAN.ELF'
vgate_assert p1 serial-contains 'verdict=refused:v6_literal_denied name=V6DENY.ELF'
# The two controls connect and close — and no row ever names them.
vgate_assert p1 serial-count 'netpolicy: connected' 2
vgate_assert p1 serial-count 'netpolicy: dial refused' 3
vgate_assert p1 serial-absent 'denied name=V6OK.ELF'
vgate_assert p1 serial-absent 'denied name=LANOK.ELF'
# "Allowed" reached the wire — the responders saw the SYNs, so the
# scope check let the opens through, not just failed to receipt.
vgate_assert p1 output-contains 'NET-TCP: answered the guest'
vgate_assert p1 output-contains 'NET-TCP6: answered the guest'
vgate_assert p1 serial-contains 's1-done'
vgate_assert p1 serial-contains 's2-done'
vgate_assert p1 serial-absent '[EXC] parking:'
