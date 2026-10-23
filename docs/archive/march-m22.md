> ARCHIVED 2026-10-23 — closed-milestone record; do not treat as an active plan.
> Canonical status: [`docs/status.md`](../status.md).

# Milestone twenty-two march — developer tools (living tracker)

> [`docs/status.md`](../status.md) is the canonical source for milestone-level
> facts. This file holds M22's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

VirelaiOS can run userland apps, but every app is built on the host and
loaded as a flat binary or DSK3 image. There's no way to write, assemble,
or inspect code *on the machine itself*. The tombstone system (M15 #243)
crashes with addresses but no symbol names. M22 gives the machine basic
developer tooling — enough to write a small program, assemble it, run it,
and debug a crash.

**Two new syscall slots** (59/60) for ELF loading and strace.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| D1 | **ELF loader.** `exec app.elf` loads an ELF32/ELF64 AArch64 executable from FAT. Parse ELF headers, validate architecture (AArch64 only), map PT_LOAD segments into the EL0 address space, jump to e_entry. Works alongside the existing flat-image `exec APP.BIN`. Rejects non-AArch64 ELF files with a clear error. | ✅ | `artifacts/live-elf-report.txt` — verify-live-elf PASS 1/1 on VZ: HELLO.ELF listed, `exec HELLO.ELF size=0x3a entry=0x400000`, marker line, exit 42 + reap, shell responsive | Kernel: NO new syscall slot — the issue's magic-sniff design won: `exec.exec_file` sniffs `\x7fELF` and routes to the new `kernel/src/elf.zig` parse/validate (ELF32+ELF64, ≤2 PT_LOAD segments, W^X text at `userspace.text_va`, optional data segment directly after text memory, entry inside initialized text, 256 KiB bound). Five new honest `ExecResult` refusals surfaced by `exec`. Host tests: elf.zig 7/7, exec.zig 374/374. |
| D2 | **Tiny assembler.** `asm source.txt output.bin` — a minimal AArch64 assembler for ~20 common instructions: MOV, MOVZ, MOVK, ADD, SUB, AND, ORR, LDR (literal), STR (register), BLR, RET, SVC, NOP, CMP, B, BEQ, BNE, BL, ADRP, ADD (immediate). Reads source from FAT, writes ELF32 to FAT. Enough to write "hello world" + syscall test programs on the machine. | ✅ | `artifacts/live-asm-report.txt` — verify-live-asm PASS 1/1 on VZ: `write PROG.S` stages source → `exec ASM.BIN /esp/PROG.S /esp/PROG.ELF` prints `asm: wrote 96 bytes` → `mount esp` → `exec PROG.ELF` loads via D1 and exits status 71 | New userland app `user/src/asm.zig` (ASM.BIN): two-pass assembler, statements separated by newline OR `;`, labels + `//` comments + `.word`; encodes MOV/MOVZ/MOVK/ADD/SUB/CMP/AND/ORR/EOR/LDR(literal+mem)/STR/BLR/RET/SVC/NOP/BRK/B/BL/B.cond/CBZ/CBNZ/ADR/ADRP with host tests pinning every word against known encodings (12/12). Emits minimal AArch64 ELF32 (single R+X PT_LOAD at 0x400000) matching the D1 loader contract. Bounds: 256 lines, 64 labels, 4096 output bytes, honest per-line errors. DSK1 flat images map text only (no .bss aperture), so all workspace lives on the task stack (~12.4 KiB of 16 KiB). |
| D3 | **Symbol table.** `sym` command shows loaded ELF symbols. Tombstone crash reports (M15 #243) include symbol names — the last symbol before the faulting address. `sym app.elf` reads the ELF symbol table and prints it. | ✅ | `artifacts/live-symbols-report.txt` — verify-live-symbols PASS 1/1 on VZ: CRASH.ELF's symtab populates the kernel table (`sym` lists crasher), its BRK yields a status-139 tombstone, and `crash` resolves the PC to `(in crasher+0x4)` | New `kernel/src/symbol.zig` — BSS table (32 × name/addr/size), cleared at every exec, populated by `elf.collect_symbols` (.symtab/.strtab walk, GLOBAL/WEAK FUNC+OBJECT only) in exec's ELF branch BEFORE staging rearranges the buffer. Fault path now carries PC: exceptions fault dispatcher signature gains elr, scheduler's FaultEntry stores it, and tombstone.record resolves `(in name+0xoff)` via lookup(pc), falling back to fault_addr. Monitor registry 53→54 (`sym`, list + file-inspect via 64 KiB staging). mkhello-elf.py --crash emits CRASH.ELF with a real symtab (correct ELF32 Sym layout). Tests: symbol.zig 4/4, elf.zig 8/8, tombstone.zig 27/27 incl. note resolution. |
| D4 | **Disassembler.** `disas binary.bin` — hex dump + AArch64 disassembly of raw bytes. 16 bytes per line with address, hex, and mnemonic. Useful for inspecting tombstone addresses and verifying assembler output. | ✅ | `artifacts/live-disas-report.txt` — verify-live-disas PASS 1/1 on VZ: DISAS.BIN decodes ASM.BIN's PROG.ELF byte-exactly (`00000054: 680080d2 movz x8, #3`, `svc #0`) and the same ELF then executes with exit 71 | New userland app `user/src/disas.zig` (DISAS.BIN): decoder inverse of D2 — system forms (nop/svc/brk/ret), MOVZ/MOVK with lsl, imm12 add/sub/cmp, register ops incl. the ORR-xzr MOV alias and CMP-SUBS-xzr, B/BL/B.cond/CBZ/CBNZ with absolute branch targets, ADR/ADRP/LDR-literal, LDR/STR unsigned-offset; unknown words print `.word 0x…` honestly. `disas <file> [offset]` (dec or 0x-hex); 4 KiB bound; stack-only workspace (DSK1 text-mapping constraint). Host tests 7/7 pin known words both directions; the D2↔D4 round-trip is proven live by feeding assembler output to the decoder. |
| D5 | **System call tracer.** `strace cmd` — wraps exec, logs every syscall invocation with name, args, and return value to the serial console. Each syscall prints: `[strace] sys_name(args) = retval`. | ✅ | `artifacts/live-strace-report.txt` — verify-live-strace PASS 1/1 on VZ: `[strace 1] sys_write(0x1, 0x400020, 0x1a) = 0x1a` and `sys_exit(0x2a) = —` for a HELLO.ELF run; `strace off` disarms | No new syscall slot (ABI budget unchanged): monitor command `strace exec <file> [args]` arms `syscall.strace_pid` around the exec — the loader records the pid at the success point so every subsequent syscall from that process traces. dispatch() prints synchronously (`[strace <pid>] <name>(x0, x1, x2) = res`, hex); sys_exit is special-cased pre-call with an em-dash result since its handler never returns. Registry 55. |

### Lane-D wave 2 — D8–D16 (issues #331–#339; implementation claim 0720, verification claim 5220)

All nine cards implemented on main (`3fce71b`, registry 59 → 65 commands, RESMON.BIN +
DEVCONS.BIN on the ESP) and now **live-verified on VZ** — each card's issue-named class-B
gate exists and passes on this machine (macOS 27, Apple silicon), evidence under
`artifacts/live-*` in the claiming worktree:

| # | Card | Status | Gate | Notes |
|---:|------|--------|------|-------|
| D8 | **Filesystem inspection** — `stat <file\|path>`, `find <dir> -name <pattern>` (glob *, ?, bounded 3 levels / 256 results) | ✅ | `verify-live-stat-find.sh` PASS 1/1 — stat file metadata (size/type/cluster via FAT path), stat directory entry, find walked / listing 40 *.BIN matches | Monitor commands; bare-name stat uses the ESP window (no cluster line — that's the path form). |
| D9 | **System information dashboard** — extended `sysinfo` (cpu/memory/allocator/storage free-total/network/graphics/input/uptime sections) | ✅ | `verify-live-sysinfo.sh` PASS 1/1 on a FRESH boot — all sections incl. storage `free=0x…/0x…` + uptime | The earlier "missing free=/total on fresh boot" report (#552) was resolved NOT-A-BUG: a one-shot boot debug line (`syscall: write ok n=23`) interleaves mid-print and splits the storage line across two serial lines; the data was always there (#552 closed with probe evidence). The gate's free=/total assertion is deliberately unanchored for this reason. |
| D10 | **Resource monitor** — RESMON.BIN window, sys_procs-driven, 1 Hz refresh | ✅ | `verify-live-resmon.sh` PASS 1/1 — loaded, window open, `resmon: ready`, no faults, screenshot | Honest scope: process/scheduler/uptime only (no mem/disk/net stats without new syscalls; ABI budget preserved). Now built as SEGMENTED DSK3 (claim 5220 — flat mapping has no writable segment). |
| D11 | **Crash report viewer** — `crash [<index>]` detail view: resolved symbol `(in name+0xoff)`, serial snapshot section | ✅ | `verify-live-crash-viewer.sh` PASS 1/1 — CRASH.ELF's status-139 tombstone renders `(in crasher+0x4)` + `--- Last Serial Output ---` | Tombstone 0 is the boot payload's exit-7 record; the BRK lands at index 1 deterministically. Viewer commands ride the runner's second script phase (exec is async). |
| D12 | **System log viewer** — `dmesg` dumps the serial ring (last 512 bytes of console output) | ✅ | `verify-live-dmesg.sh` PASS 1/1 — an echoed marker reappears inside the dmesg dump (marker-count ≥ 2) | Optional `sys_dmesg_read` slot NOT taken — ABI budget unchanged. |
| D13 | **Command timing** — `time <cmd>` wraps any monitor command, prints elapsed ticks + wall-clock | ✅ | `verify-live-time.sh` PASS 1/1 — `time sysinfo` reports `ticks   25` (~250 ms) | `exec` is asynchronous — `time exec X` measures only the load (ticks 0); there is no blocking builtin, so the gate pins the heaviest synchronous command. |
| D14 | **Developer console** — DEVCONS.BIN split-screen log pane + command prompt | ✅ | `verify-live-devcons.sh` PASS 2/2 — typed `dir.bin` at the in-window prompt over the claim 9588 virtio INPUT channel; echo + `exec: ok` render in the log pane (pixel proof), child's `dir: listing /data` / `dir: success` on serial, `input` events=8 | FIXED live bug (issue #553, claim 0590): the prompt compared `ev.arg0` (raw HID usage) against ASCII ranges, so every printable key was rejected — typing never reached the command buffer. Now consumes the ADR 0009 convention (arg1 ASCII, arg0 usage). Earlier live bug: flat DSK1 build data-aborted on its first BSS write (`far=0x400928`); now SEGMENTED DSK3 (claim 5220). |
| D15 | **File permissions viewer** — `ls -l` long format (type bits, root owner, size); viewer only, no permission model | ✅ | `verify-live-ls-l.sh` PASS 1/1 — `-rw- … root` file lines, `drwx … root` dir lines, sizes; plain `ls` unchanged | Each entry wraps over two lines (bits+owner line, then indented size+name). |
| D16 | **Package/tool inventory** — `which <name>` (shell builtin / monitor command / ESP app / not found) + `inventory` (APPS.TXT listing with sizes) | ✅ | `verify-live-inventory.sh` PASS 1/1 — all three locator classes + not-found + inventory header/listing | FIXED live bug (ADR 0005 class): `is_shell_builtin`'s const slice table held unrelocated link-time pointers — `which type` data-aborted on real hardware (`far=0x4129a`); host tests never caught it (host linker relocates). Replaced with a comptime `inline for` list + regression test in monitor.zig. |

Wave-2 gate evidence was produced by claim 5220's worktree; per-card artifacts live under
that tree's `artifacts/live-*` and should be cited from the PR description.

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Kernel ELF + strace** | `kernel/src/elf.zig` (new) + `kernel/src/syscall.zig` (slot 59) for D1. `kernel/src/syscall.zig` (slot 60) + `kernel/src/tombstone.zig` + `kernel/src/symbol.zig` (new) for D3 + D5. | M20 done (Unicode for error messages). |
| **B — Userland tools** | `user/src/asm.zig` (new) for D2. `user/src/disas.zig` (new) for D4. | D1 (ELF loader must work to run assembler output). |

## Notes

1. **ABI budget:** 2 new syscall slots (59/60) for ELF load + strace.
   Cumulative: 61/64 after M22. Three slots remain.
2. **BSS budget:** ELF scratch ~64 bytes. Symbol table ~2.3 KiB. Strace
   buffer ~1 KiB. Assembler (userland) ~10 KiB BSS. Disassembler (userland)
   ~8 KiB BSS. Total M22 kernel BSS delta: ~3.4 KiB. Userland BSS: ~18 KiB.
3. **Gate shape:** D1: `verify-live-elf.sh` — ELF load + execute (assembler
   output). D2: `verify-live-asm.sh` — assemble + run "hello world". D3:
   `verify-live-symbols.sh` — tombstone shows symbol name. D4:
   `verify-live-disas.sh` — disassembly output matches known bytes. D5:
   `verify-live-strace.sh` — strace output shows syscall names + args.
4. **ELF scope:** Only PT_LOAD segments. No dynamic linking, no sections,
   no relocations. The ELF loader is a *consumer* — it loads what the host
   toolchain already linked. The assembler (D2) produces ELF32 with a single
   PT_LOAD segment.
5. **Scope exclusions:** No compiler (too large for the OS). No linker
   (flat images suffice). No debugger (tombstones + strace cover basics).
   No ELF shared libraries. No ELF core dumps.
