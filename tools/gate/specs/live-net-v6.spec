# live-net-v6.spec — M117b (issue #2474, ADR 0057): the IPv6 datapath
# under the card-N1 capture attachment with the three hermetic
# responders (--net-ra-respond / --net-ndp-respond / --net-icmp6-respond).
# p1: SLAAC from the hermetic RA (PIO 2001:db8:64::/64 A+L), on-link
# ndp+ping6 round-trip, off-link resolve of the router link-local —
# capture-equals on the whole guest TX stream. p2: an unlisted NS target
# goes unanswered (pending slot unmatched, no_peer named). p3: no
# responder flags — RS/DAD get silence (rx=frames=0), g6 never forms,
# bad_dst6/no_route6/no_peer named. Stage gates are the guest's own
# async transition lines (net: v6 ll/g6 valid, net: v6 rs=3), so every
# script-driven transmit lands after the bounded RS train — deterministic.

vgate_name live-net-v6 "M117b #2474 ADR 0057 — IPv6: hermetic SLAAC, NDP resolve, ICMPv6 echo, named refusals, flags-off silence"
vgate_note "p1: RA->g6 valid; on-link + off-link (router) resolves; echo round-trip; byte-exact TX"
vgate_note "p2: unlisted NS target unanswered -> entries=0 learn=0 no_peer"
vgate_note "p3: flags-off -> rx=frames=0, g6=-, bad_dst6/no_route6/no_peer named"

vgate_file p1.s1 <<'EOF'
net ip6
echo v6-p1-ready
EOF
vgate_file p1.s2 <<'EOF'
net ip6
echo v6-p1-wait
EOF
vgate_file p1.s3 <<'EOF'
net ndp 2001:db8:64::ff:fe00:2
net ip6
net ndp 2001:db8:64::ff:fe00:2
net ping6 2001:db8:64::ff:fe00:2
net ndp 2001:db8:99::1
net ip6
net ndp 2001:db8:99::1
net ping6 2001:db8:99::1
net ip6
net ndp
net
net recv
echo net-v6-ok
EOF
vgate_file p2.s1 <<'EOF'
echo v6-p2-ready
EOF
vgate_file p2.s2 <<'EOF'
echo v6-p2-wait
EOF
vgate_file p2.s3 <<'EOF'
net ndp 2001:db8:64::99
net ping6 2001:db8:64::99
net ndp
net
echo net-v6-unlisted-ok
EOF
vgate_file p3.s1 <<'EOF'
echo v6-p3-ready
EOF
vgate_file p3.s2 <<'EOF'
net ndp fe80::99
net ping6 fe80::99
net ping6 2001:db8:64::1
net ping6 ff02::1
echo v6-p3-sent
EOF
vgate_file p3.s3 <<'EOF'
net ip6
net ndp
net
echo net-v6-silent-ok
EOF

vgate_setup_python <<'PY'
import os, ipaddress

GUEST = bytes([0x02, 0, 0, 0, 0, 1])
HOST = bytes([0x02, 0, 0, 0, 0, 2])
LL = ipaddress.IPv6Address("fe80::ff:fe00:1").packed
G6 = ipaddress.IPv6Address("2001:db8:64::ff:fe00:1").packed
RT = ipaddress.IPv6Address("fe80::ff:fe00:2").packed
PEER = ipaddress.IPv6Address("2001:db8:64::ff:fe00:2").packed
OFF = ipaddress.IPv6Address("2001:db8:99::1").packed
ALLR = ipaddress.IPv6Address("ff02::2").packed
ALLR_MAC = bytes([0x33, 0x33, 0, 0, 0, 2])
UNSPEC = bytes(16)

def snm(a):
    return bytes([0xff, 0x02]) + bytes(9) + bytes([0x01, 0xff]) + a[13:16]

def snm_mac(a):
    return bytes([0x33, 0x33, 0xff]) + a[13:16]

def cksum6(src, dst, msg, nh):
    s = 0
    for i in range(0, 16, 2):
        s += (src[i] << 8) | src[i + 1]
        s += (dst[i] << 8) | dst[i + 1]
    s += (len(msg) >> 16) + (len(msg) & 0xffff) + nh
    i = 0
    while i + 1 < len(msg):
        s += (msg[i] << 8) | msg[i + 1]
        i += 2
    if i < len(msg):
        s += msg[i] << 8
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff

def v6hdr(dst_mac, src_mac, nh, hop, src, dst, msg):
    return (dst_mac + src_mac + b"\x86\xdd" + b"\x60\x00\x00\x00"
            + len(msg).to_bytes(2, "big") + bytes([nh, hop]) + src + dst + msg)

def dad_ns(target):
    m = bytes([135, 0, 0, 0]) + bytes(4) + target
    m = m[:2] + cksum6(UNSPEC, snm(target), m, 58).to_bytes(2, "big") + m[4:]
    return v6hdr(snm_mac(target), GUEST, 58, 255, UNSPEC, snm(target), m)

def rs():
    m = bytes([133, 0, 0, 0]) + bytes(4) + bytes([1, 1]) + GUEST
    m = m[:2] + cksum6(LL, ALLR, m, 58).to_bytes(2, "big") + m[4:]
    return v6hdr(ALLR_MAC, GUEST, 58, 255, LL, ALLR, m)

def ns(target):
    m = bytes([135, 0, 0, 0]) + bytes(4) + target + bytes([1, 1]) + GUEST
    m = m[:2] + cksum6(LL, snm(target), m, 58).to_bytes(2, "big") + m[4:]
    return v6hdr(snm_mac(target), GUEST, 58, 255, LL, snm(target), m)

def echo_req(dst_ip, dst_mac, seq):
    m = bytes([128, 0, 0, 0]) + bytes([0, 1]) + seq.to_bytes(2, "big") + bytes([1, 2, 3, 4])
    m = m[:2] + cksum6(G6, dst_ip, m, 58).to_bytes(2, "big") + m[4:]
    return v6hdr(dst_mac, GUEST, 58, 64, G6, dst_ip, m)

run_dir = os.environ["RUN_DIR"]
LL99 = ipaddress.IPv6Address("fe80::99").packed
UNS = ipaddress.IPv6Address("2001:db8:64::99").packed

# p1 TX stream — script-driven transmits wait for 'net: v6 rs=3', so the
# whole bounded train precedes the resolve/echo frames (deterministic).
p1 = (dad_ns(LL) + rs() + dad_ns(G6) + rs() + rs()
      + ns(PEER) + echo_req(PEER, HOST, 1)
      + ns(RT) + echo_req(OFF, HOST, 2))
open(os.path.join(run_dir, "p1.want"), "wb").write(p1)

# p2 — the unlisted-target leg: same SLAAC stream + one unanswered NS.
p2 = dad_ns(LL) + rs() + dad_ns(G6) + rs() + rs() + ns(UNS)
open(os.path.join(run_dir, "p2.want"), "wb").write(p2)

# p3 — flags-off: no RA, no global, one unanswered resolve-NS.
p3 = dad_ns(LL) + rs() + rs() + rs() + ns(LL99)
open(os.path.join(run_dir, "p3.want"), "wb").write(p3)
PY

vgate_run p1 -- --net '$RUN_DIR/p1.cap' --net-ra-respond '2001:db8:64::/64' --net-ndp-respond '2001:db8:64::ff:fe00:2' --net-icmp6-respond '2001:db8:64::ff:fe00:2' --script '$RUN_DIR/p1.s1' --script2 '$RUN_DIR/p1.s2' --script2-after 'net: v6 g6=2001:db8:64::ff:fe00:1 valid' --script3 '$RUN_DIR/p1.s3' --script3-after 'net: v6 rs=3' --script-expect 'net-v6-ok' --timeout 45
vgate_assert p1 output-contains 'net-ra-respond: ENABLED'
vgate_assert p1 output-contains 'net-ndp-respond: ENABLED'
vgate_assert p1 output-contains 'net-icmp6-respond: ENABLED'
vgate_assert p1 serial-contains 'net: v6 ll=fe80::ff:fe00:1 valid'
vgate_assert p1 serial-contains 'net: v6 g6=2001:db8:64::ff:fe00:1 valid'
vgate_assert p1 serial-contains 'net: v6 rs=3'
vgate_assert p1 output-contains 'NET-RA: answered'
vgate_assert p1 output-contains 'NET-NDP: answered'
vgate_assert p1 output-contains 'NET-ICMP6: answered'
vgate_assert p1 serial-contains 'net ip6: ll=fe80::ff:fe00:1 valid g6=2001:db8:64::ff:fe00:1 valid'
vgate_assert p1 serial-contains 'net ip6: rt=fe80::ff:fe00:2 lt=1800 onl=2001:db8:64::/64'
vgate_assert p1 serial-contains 'net ndp: request for 2001:db8:64::ff:fe00:2 sent (86 bytes)'
vgate_assert p1 serial-contains 'net ping6: echo request to 2001:db8:64::ff:fe00:2 sent (66 bytes)'
vgate_assert p1 serial-contains 'net ndp: request for 2001:db8:99::1 sent (86 bytes)'
vgate_assert p1 serial-contains 'net ping6: echo request to 2001:db8:99::1 sent (66 bytes)'
vgate_assert p1 serial-contains 'net ndp: 2001:db8:64::ff:fe00:2 is at 02:00:00:00:00:02'
vgate_assert p1 serial-contains 'net ndp: 2001:db8:99::1 is at 02:00:00:00:00:02'
vgate_assert p1 serial-contains 'net ndp: entries=2'
vgate_assert p1 serial-contains 'net ndp: 2001:db8:64::ff:fe00:2 -> 02:00:00:00:00:02'
vgate_assert p1 serial-contains 'net ndp: fe80::ff:fe00:2 -> 02:00:00:00:00:02'
vgate_assert p1 serial-contains 'net: rx=frames=6'
vgate_assert p1 serial-contains 'filtered=0,overflow=2'
vgate_assert p1 serial-contains 'net recv: frames=4'
vgate_assert p1 serial-contains ' v6=ll=fe80::ff:fe00:1,g6=2001:db8:64::ff:fe00:1,rt=fe80::ff:fe00:2,onl=2001:db8:64::/64'
vgate_assert p1 serial-contains ' ndp=rs=3,dad=2,dadc=0,ra=3,for=0,mal=0,opt=2,ns=2,na=0,learn=2,unsol=0,drop=0,redir=0,fail=0'
vgate_assert p1 serial-contains ' icmp6=req=2,repl=0,pong=1,err=0,drop=0,fail=0,seq=1'
vgate_assert p1 serial-contains 'net-v6-ok'
vgate_assert p1 capture-equals p1.cap p1.want

vgate_run p2 -- --net '$RUN_DIR/p2.cap' --net-ra-respond '2001:db8:64::/64' --net-ndp-respond '2001:db8:64::ff:fe00:2' --script '$RUN_DIR/p2.s1' --script2 '$RUN_DIR/p2.s2' --script2-after 'net: v6 g6=2001:db8:64::ff:fe00:1 valid' --script3 '$RUN_DIR/p2.s3' --script3-after 'net: v6 rs=3' --script-expect 'net-v6-unlisted-ok' --timeout 45
vgate_assert p2 serial-contains 'net: v6 g6=2001:db8:64::ff:fe00:1 valid'
vgate_assert p2 serial-contains 'net ndp: request for 2001:db8:64::99 sent (86 bytes)'
vgate_assert p2 serial-contains 'peer not in NDP table (net ndp <addr> first)'
vgate_assert p2 serial-contains 'net ndp: entries=0'
vgate_assert p2 serial-contains 'net: rx=frames=3'
vgate_assert p2 serial-contains ' ndp=rs=3,dad=2,dadc=0,ra=3,for=0,mal=0,opt=2,ns=1,na=0,learn=0,unsol=0,drop=0,redir=0,fail=0'
vgate_assert p2 serial-contains ' icmp6=req=0,repl=0,pong=0,err=0,drop=0,fail=0,seq=0'
vgate_assert p2 serial-contains 'net-v6-unlisted-ok'
vgate_assert p2 capture-equals p2.cap p2.want

vgate_run p3 -- --net '$RUN_DIR/p3.cap' --script '$RUN_DIR/p3.s1' --script2 '$RUN_DIR/p3.s2' --script2-after 'net: v6 rs=3' --script3 '$RUN_DIR/p3.s3' --script3-after 'v6-p3-sent' --script-expect 'net-v6-silent-ok' --timeout 45
vgate_assert p3 serial-contains 'net: v6 ll=fe80::ff:fe00:1 valid'
vgate_assert p3 serial-contains 'net: v6 rs=3'
vgate_assert p3 serial-contains 'net ip6: ll=fe80::ff:fe00:1 valid g6=- -'
vgate_assert p3 serial-contains 'net: rx=frames=0'
vgate_assert p3 serial-contains 'net ndp: request for fe80::99 sent (86 bytes)'
vgate_assert p3 serial-contains 'peer not in NDP table (net ndp <addr> first)'
vgate_assert p3 serial-contains 'no_route6 (off-link destination and no router)'
vgate_assert p3 serial-contains 'bad_dst6 (multicast/unspecified/loopback destination)'
vgate_assert p3 serial-contains 'net ndp: entries=0'
vgate_assert p3 serial-contains ' v6=ll=fe80::ff:fe00:1,g6=-,rt=-,onl=-'
vgate_assert p3 serial-contains ' ndp=rs=3,dad=1,dadc=0,ra=0,for=0,mal=0,opt=0,ns=1,na=0,learn=0,unsol=0,drop=0,redir=0,fail=0'
vgate_assert p3 serial-contains ' icmp6=req=0,repl=0,pong=0,err=0,drop=0,fail=0,seq=0'
vgate_assert p3 serial-contains 'net-v6-silent-ok'
vgate_assert p3 capture-equals p3.cap p3.want
