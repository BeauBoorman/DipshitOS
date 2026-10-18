# live-disas.spec -- M22 D4: disassemble assembler output on the machine.
# Staged source -> ASM.BIN -> DISAS.BIN decodes hex and instructions -> exec PROG.ELF exits 71.

vgate_name live-disas "M22 D4: disassemble assembler output on the machine"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

# exec DISAS.BIN /host/PROG.ELF 84 passes arguments: the flat-bin argv
# block (2 KiB) must fit inside the content's last page (exec.zig
# argv_va_for), so content sizes in the (2048, 4096) mod-4096 window
# refuse with 'no_args_room'. Pad the staged copy with load-inert zeros.
vgate_setup_python <<'PY'
import os, struct
p = os.path.join(os.environ["RUN_DIR"], "share", "DISAS.BIN")
# image_size (u64 at offset 16 of the DSK1 header) covers the 24-byte
# header + content — the loader reads the field, so the pad must write it
# AND extend the file, or the zeros are invisible.
size = os.path.getsize(p)
content = size - 24
if 2048 < content % 4096:
    want = (content // 4096 + 1) * 4096 + 8 + 24
    with open(p, "r+b") as f:
        f.seek(16)
        f.write(struct.pack("<Q", want))
        f.truncate(want)
    size = os.path.getsize(p)
print("live-disas: DISAS.BIN argv-pad check, size=%d" % size)
PY

vgate_file script.txt <<'EOF'
write PROG.S '_start:;mov x8, 3;mov x0, 71;svc 0'
exec ASM.BIN /host/PROG.S /host/PROG.ELF
exec DISAS.BIN /host/PROG.ELF 84
echo disas-mid
EOF

vgate_file script2.txt <<'EOF'
exec PROG.ELF
echo rx-disas-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after 'tasks user-el0 exited status=7' --script2 '$RUN_DIR/script2.txt' --script2-after 'asm: wrote 96 bytes to /host/PROG.ELF' --script-expect 'tasks user-exec exited status=71' --timeout 90

vgate_assert 01 serial-exact 'VirelaiOS kernel has seized control.' 1
vgate_assert 01 serial-count 'write: ok' 1
vgate_assert 01 serial-count 'asm: wrote 96 bytes to /host/PROG.ELF' 1
vgate_assert 01 serial-count '00000054: 680080d2' 1
vgate_assert 01 serial-count 'movz x8, #3' 1
vgate_assert 01 serial-count 'svc #0' 1
vgate_assert 01 serial-count 'tasks user-exec exited status=71' 1
vgate_assert 01 serial-exact 'rx-disas-ok' 1
vgate_assert 01 serial-absent '[EXC] parking:'
