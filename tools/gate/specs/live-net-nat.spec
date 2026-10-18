# live-net-nat.spec -- outbound connectivity through the VZ NAT
# attachment: static address on the observed subnet, gateway ARP +
# ICMP round trip, guest-observed counters (capture bytes don't apply
# through NAT -- the host translates frames, the card's gate shape).
# Mirrors tools/verify-live-net-nat.sh (claim 4678, card N7). Two
# deliberate non-ports: the VIRELAI_NET_NAT_RUNS host-skip knob (the
# spec always runs; re-add if a host's NAT answers differently) and
# the documentation-only ifconfig bridge capture (unasserted).

vgate_name live-net-nat "NAT gateway round trip, guest-observed counters on VZ"
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig

vgate_file script-1.txt <<'EOF'
net ip 192.168.64.5
net arp 192.168.64.1
echo nat-phase1-ready
EOF

vgate_file script-2.txt <<'EOF'
net ping 192.168.64.1
net arp
net
echo nat-obs-done
EOF

vgate_run 01 -- --net-nat --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'net arp: 192.168.64.1 is at' --script-expect 'nat-obs-done' --timeout 40

vgate_assert 01 serial-contains 'net ip: ip=192.168.64.5'
vgate_assert 01 serial-contains 'net arp: request for 192.168.64.1 sent (42 bytes)'
vgate_assert 01 serial-contains 'net ping: echo request to 192.168.64.1 sent (46 bytes)'
vgate_assert 01 serial-contains ' icmp=req=1,repl=0,pong=1,drop=0,fail=0,seq=1'
vgate_assert 01 serial-contains 'net arp: 192.168.64.1 is at '
vgate_assert 01 serial-contains 'net: mac=02:00:00:00:00:01 source=feature'
vgate_assert 01 serial-contains 'net: ip=192.168.64.5 arp=req=1,repl=0,learn=1,drop=1,fail=0'
vgate_assert 01 serial-contains 'net: status=0x000000000000000f rearm=1'
vgate_assert 01 serial-contains 'nat-obs-done'
vgate_assert 01 output-contains 'net-nat: ENABLED (milestone five card N7, claim 4678)'
