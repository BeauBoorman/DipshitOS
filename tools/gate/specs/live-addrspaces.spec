# live-addrspaces.spec -- per-task user address spaces on VZ hardware:
# EL0 payload runs at fixed text VA + ASLR stack, `addrspaces` shows
# TTBR1=0/T0SZ=16, EL1h tasks share the kernel root, user-el0 owns its
# root with only text+stack EL0 leaves and zero EL0 Device leaves.
# Mirrors tools/verify-live-addrspaces.sh (claim 5804).

vgate_name live-addrspaces "per-task TTBR0 roots, EL1-only kernel overlay, MMIO excluded from EL0"
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig

vgate_file script.txt <<'EOF'
syscalls
uaccess
addrspaces
echo rx-addrspaces-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script-expect "rx-addrspaces-ok"$'\n' --timeout 45

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'syscall: write ok n=23' 1
vgate_assert 01 serial-exact 'uaccess: efault ok n=8' 1
vgate_assert 01 serial-exact '  1 sys_write calls=3' 1
vgate_assert 01 serial-exact 'uaccess: valid=0 fault=1 recovered=1 copies=3 validation_faults=1 unbacked=1' 1
vgate_assert 01 serial-exact 'userspace: el0=1 svc=2 roundtrips=1 arg=2 result=2 rejected=0' 1
vgate_assert 01 serial-exact 'rx-addrspaces-ok' 1
vgate_assert 01 serial-count 'addrspaces: user text=0x0000000000400000 stack=0x' 1
vgate_assert 01 serial-count ' el0_device=0' 1
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, re, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
# Legacy -Fc = 1 pair (both required): TTBR1 zero + T0SZ=16.
for n in ("addrspaces: ttbr1=0x0000000000000000", " t0sz=16"):
    if sum(1 for l in lines if n in l) != 1:
        sys.exit("FAIL: %r not exactly-once" % n)
def first(needle):
    for l in lines:
        if needle in l:
            return l
    return None
ul = first("addrspaces: user text=")
if ul is None:
    sys.exit("FAIL: no 'addrspaces: user text=' line")
m = re.search(r".*stack=0x([0-9a-f]{16}).*", ul)
if not m:
    sys.exit("FAIL: no stack=0x<16hex> on user line")
sv = m.group(1)
dec = int(sv, 16)
# issue #1214: the ASLR band moved above the GOOS=virelai sbrk heap ceiling.
if not (0x1_00000000 <= dec < 0x2_00000000 and dec % 65536 == 0 and sv != "0000000000400000"):
    sys.exit("FAIL: stack VA out of ASLR band/unaliased: %s" % sv)
m = re.search(r".*el0=([0-9]+).*", ul)
if not m or int(m.group(1)) < 3:
    sys.exit("FAIL: el0 leaves < 3")
m = re.search(r".*leaves=([0-9]+).*", ul)
if not m or int(m.group(1)) < 3:
    sys.exit("FAIL: leaves < 3")
rl = first("addrspaces: ttbr1=")
if rl is None:
    sys.exit("FAIL: no 'addrspaces: ttbr1=' line")
m = re.search(r".*root=0x([0-9a-f]{16}).*", rl)
if not m:
    sys.exit("FAIL: no root= on ttbr1 line")
root = m.group(1)
def ttbr0(needle):
    l = first(needle)
    if l is None:
        return None
    mm = re.search(r".*ttbr0=0x([0-9a-f]{16}).*", l)
    return mm.group(1) if mm else None
if ttbr0("addrspaces: task shell ") != root:
    sys.exit("FAIL: shell ttbr0 != kernel root")
if ttbr0("addrspaces: task worker ") != root:
    sys.exit("FAIL: worker ttbr0 != kernel root")
ul2 = first("addrspaces: user root=")
if ul2 is None:
    sys.exit("FAIL: no 'addrspaces: user root=' line")
m = re.search(r".*root=0x([0-9a-f]{16}).*", ul2)
if not m or m.group(1) == root:
    sys.exit("FAIL: user root missing or == kernel root")
print("addrspaces custom ok: stack=%s root=%s" % (sv, root))
PY
