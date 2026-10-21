//! VirelaiOS root build system (milestone zero).
//!
//! Written against Zig 0.17.0 (pinned in .zigversion). Notable 0.17
//! differences from older tutorials that this file accounts for:
//!   * `b.addExecutable` takes `.root_module = b.createModule(...)`.
//!   * `build.zig.zon` uses `.name = .virelaios`, `.fingerprint`,
//!     `.minimum_zig_version` and a `.paths` allowlist.
//!   * `Step.Run` exposes settable `has_side_effects` and `stdio` fields
//!     (verified against the installed 0.17.0 std sources).
//! See docs/decisions/0001-arm64-uefi-zig.md and README.md.

const std = @import("std");

pub fn build(b: *std.Build) void {
    // ------------------------------------------------------------------
    // Guest: AArch64 UEFI application -- the loader (BOOTAA64.EFI).
    // ------------------------------------------------------------------
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .uefi,
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });
    const bad_handoff = b.option(bool, "bad-handoff", "Corrupt handoff v2 magic for the pre-exit failure-path test") orelse false;
    const boot_options = b.addOptions();
    boot_options.addOption(bool, "bad_handoff", bad_handoff);

    const efi = b.addExecutable(.{
        .name = "bootaa64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("boot/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    efi.root_module.addOptions("build_options", boot_options);
    // Canonical removable-media ARM64 UEFI filename (EFI/BOOT/BOOTAA64.EFI).
    // Set directly on the compile so the installed artifact is named exactly
    // BOOTAA64.EFI. (On case-insensitive APFS a separate install step would
    // collide with the default lowercase artifact name.)
    efi.out_filename = "BOOTAA64.EFI";
    b.installArtifact(efi);

    // ------------------------------------------------------------------
    // Guest: freestanding AArch64 kernel (linked ELF -> flat KERNEL.BIN).
    // ------------------------------------------------------------------
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
    });
    // The kernel is always built ReleaseSmall regardless of the loader's
    // mode: Debug's safety runtime (ubsan_rt etc.) bloats the flat blob and
    // emits absolute-address movk chains, which would break the kernel's
    // load-anywhere (PC-relative) contract. See ADR 0002.
    // Claim 0015: `-Dnvram-console` diverts console TX through the NVRAM
    // variable channel (post-exit access to the virtio transport hangs on
    // VZ — claim 0013), so the kernel can produce host-observable console
    // bytes after the MMU switch. Default off: the virtio TX path is
    // unchanged.
    const nvram_console = b.option(bool, "nvram-console", "Route kernel console TX through the NVRAM variable channel instead of the MMIO serial transport (claim 0015; for the VZ post-exit evidence gate)") orelse false;
    // Claim 0017: `-Dpreexit-tx` transmits a fixed diagnostic line
    // ("VIRELAIOS PREEXIT VIRTIO TX") through the virtio-pci console
    // transport BEFORE ExitBootServices, while Boot Services and the
    // firmware address space are still active — using the same device, BAR,
    // rings and notify mechanism as the post-exit path. Default off: the
    // post-exit TX path and every existing gate are byte-identical.
    const preexit_tx = b.option(bool, "preexit-tx", "Transmit 'VIRELAIOS PREEXIT VIRTIO TX' through the virtio-pci transport before ExitBootServices (claim 0017 diagnostic)") orelse false;
    // Claim 0018: `-Dtx-diag` replaces the flush's coarse TXST/TXNT/TXPL
    // markers with ten ordered per-stage NVRAM markers around each
    // potentially fatal operation of the first post-exit virtio TX, and
    // removes the large post-exit probe-tail SetVariable + logging-only
    // status dump from the flush. Default off: the default build's flush is
    // byte-identical.
    const tx_diag = b.option(bool, "tx-diag", "Bisect the post-exit virtio TX failure with per-stage NVRAM markers (claim 0018 diagnostic)") orelse false;
    // Claim 0020: TX-transition matrix phases. Each is default off; a
    // diagnostic build enables EXACTLY ONE phase, which runs a single
    // controlled TX attempt at its named location (A pre-ExitBootServices,
    // B immediately post-ExitBootServices on the firmware translation,
    // C immediately after the identity-map install, D at the normal final
    // location). Same payload + same transport + same flush in every phase.
    // Default builds stay byte-identical.
    const tx_transition_a = b.option(bool, "tx-transition-a", "Phase A: one virtio TX attempt before ExitBootServices (claim 0020 diagnostic)") orelse false;
    const tx_transition_b = b.option(bool, "tx-transition-b", "Phase B: one virtio TX attempt immediately after ExitBootServices, before VirelaiOS page tables (claim 0020 diagnostic)") orelse false;
    const tx_transition_c = b.option(bool, "tx-transition-c", "Phase C: one virtio TX attempt immediately after the identity-map install, before unrelated work (claim 0020 diagnostic)") orelse false;
    const tx_transition_d = b.option(bool, "tx-transition-d", "Phase D: one virtio TX attempt at the normal final location (claim 0020 diagnostic)") orelse false;
    // Claim 0021: firmware MMU-state capture. `-Dfw-mmu-capture` records the
    // firmware's live SCTLR/TCR/MAIR/TTBR0/TTBR1 + a bounded walk of the
    // firmware TTBR0 tables for the virtio BAR0 window and a RAM control
    // address, plus the kernel's planned values, persisted pre-exit as the
    // ASCII variable `VirelaiMmu` for a host-side firmware-vs-kernel diff.
    // Default off: the default build is byte-identical.
    const fw_mmu_capture = b.option(bool, "fw-mmu-capture", "Capture firmware MMU registers + a virtio BAR-window table walk pre-exit, persisted to NVRAM (claim 0021 diagnostic)") orelse false;
    // Claim 3475: `-Dprobe-var` persists the claim-0013 probe dump (the raw
    // declared-MMIO-window / config-table / ACPI evidence) as the chunked
    // `VirelaiP0..N` variables. Default OFF: the serial log carries the
    // probe records, and VZ's variable store is append-per-write, so the
    // ~32 KiB persist per boot starved the store and left no room for the
    // ESP file window's `write` (claim 3475; claim 0015 already gated the
    // persist off in nvram-console builds for the same starvation).
    const probe_var = b.option(bool, "probe-var", "Persist the claim-0013 probe dump as VirelaiP* NVRAM variables (diagnostic; default off — the serial log carries the probe records, and the persist starves the variable store)") orelse false;
    // Claim 1517: production T0SZ is 16 (correct start level for the built
    // L0-rooted hierarchy). `-Dt0sz25` selects the legacy 25 (W=39, walk
    // starts at level 1 — the claim-6460/7896 start-level mismatch that
    // made every fresh post-switch walk fault on VZ) for class-D A/B
    // regression. ONLY T0SZ changes: same tables, same TTBR0 root, same
    // MAIR/attributes/blanket/BAR window; the TLBI at the switch is
    // unconditional production behavior (claim 1517). Default off: default
    // builds are the production T0SZ=16 + TLBI kernel.
    const t0sz25 = b.option(bool, "t0sz25", "Diagnostic: install_identity_map programs T0SZ=25 (legacy start level, W=39 — the claim-6460/7896 start-level mismatch) instead of production 16 (claim 1517; default off)") orelse false;
    // Claim 7896: `-Dwalk-probe` runs a post-switch cold-address probe
    // battery, each probe bracketed by an NVRAM marker, to test whether the
    // installed tables resolve under the programmed T0SZ and to NAME the
    // first address whose walk (or MMIO read) does not return. Runs after
    // install_identity_map (which now always ends with the full TLBI,
    // claim 1517) before the claim-0020 phase-C experiment. Default off: the
    // module is linker-eliminated from default builds (byte-identical).
    const walk_probe = b.option(bool, "walk-probe", "Diagnostic: post-switch walk-validity probe battery with per-probe NVRAM markers (claim 7896; default off)") orelse false;
    const kernel_options = b.addOptions();
    // M115f (#2465): the OS version label the kernel stamps into `sysinfo`.
    // The self-update channel ships a KERNEL.BIN built with a different
    // -Dos-version, so an applied update is visible inside the guest.
    const os_version = b.option([]const u8, "os-version", "OS version label stamped into the kernel; `sysinfo` reports it as version= (default \"dev\")") orelse "dev";
    kernel_options.addOption([]const u8, "os_version", os_version);
    kernel_options.addOption(bool, "nvram_console", nvram_console);
    kernel_options.addOption(bool, "probe_var", probe_var);
    kernel_options.addOption(bool, "preexit_tx", preexit_tx);
    kernel_options.addOption(bool, "tx_diag", tx_diag);
    kernel_options.addOption(bool, "tx_transition_a", tx_transition_a);
    kernel_options.addOption(bool, "tx_transition_b", tx_transition_b);
    kernel_options.addOption(bool, "tx_transition_c", tx_transition_c);
    kernel_options.addOption(bool, "tx_transition_d", tx_transition_d);
    kernel_options.addOption(bool, "fw_mmu_capture", fw_mmu_capture);
    kernel_options.addOption(bool, "t0sz25", t0sz25);
    kernel_options.addOption(bool, "walk_probe", walk_probe);
    const kernel = b.addExecutable(.{
        .name = "virelai-kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/src/main.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    kernel.root_module.addOptions("build_options", kernel_options);
    // Dense layout from address 0 (kernel/linker.ld): without this, lld's
    // 64 KiB max-page-size padding would inflate the flat image ~100x.
    kernel.linker_script = b.path("kernel/linker.ld");
    // Issue #1042: keep lld's relocation records in the linked ELF so
    // elf2bin can emit the KRN2 absolute-relocation table the loader applies
    // at any base. lld forbids --emit-relocs together with --strip-all, so
    // the kernel ELF keeps its (non-PT_LOAD, image-irrelevant) symbols; every
    // absolute relocation in loadable content must be representable or
    // elf2bin fails the build — a pointer table can never silently ship.
    kernel.link_emit_relocs = true;
    kernel.root_module.strip = false;
    // tools/elf2bin.py converts the linked ELF into the flat kernel image
    // format (magic "KRN2", entry offset, size, absolute-reloc table; see
    // docs/decisions/0019-kernel-absolute-relocation-table.md). The loader on
    // the ESP reads KERNEL.BIN.
    const kernel_step = b.step("kernel", "Extract the flat kernel image (zig-out/bin/KERNEL.BIN) from the freestanding ELF (class A tooling, no VM)");
    // The kernel maps itself RW (its .data/.bss is live), so it is the one
    // flat image exempt from elf2bin's writable-segment guard
    // (--allow-writable); every exec'd user program must stay pure-code flat
    // or go DSK3 segmented (user/linker-segmented.ld + --segments).
    const elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--allow-writable", "--relocs" });
    elf2bin.addFileArg(kernel.getEmittedBin());
    const kernel_bin = elf2bin.addOutputFileArg("KERNEL.BIN");
    elf2bin.has_side_effects = true;
    elf2bin.stdio = .inherit;
    kernel_step.dependOn(&elf2bin.step);
    const install_kernel = b.addInstallFileWithDir(kernel_bin, .bin, "KERNEL.BIN");
    b.getInstallStep().dependOn(&install_kernel.step);

    // M113b (#2418, ADR 0054 D2): the loader pins KERNEL.BIN. The expected
    // raw-file SHA-256 is computed here — after elf2bin emits the image,
    // before the loader compile — and carried into boot/src/main.zig as
    // the generated `kernel_digest` import, so the pin can never drift
    // from the artifact it guards. The loader compile therefore depends
    // on the kernel image: a one-directional DAG (kernel ELF -> KERNEL.BIN
    // -> digest -> BOOTAA64.EFI). The `measure` import gives the loader
    // the same kernel-local SHA-256 the kernel publishes with — one
    // implementation in the guest.
    const kernel_digest_gen = b.addSystemCommand(&.{
        "python3", "-c",
        \\import hashlib, sys
        \\digest = hashlib.sha256(open(sys.argv[1], 'rb').read()).digest()
        \\body = 'pub const kernel_sha256: [32]u8 = .{ ' + ', '.join('0x%02x' % byte for byte in digest) + ' };\n'
        \\open(sys.argv[2], 'w').write(body)
    });
    kernel_digest_gen.addFileArg(kernel_bin);
    const kernel_digest_zig = kernel_digest_gen.addOutputFileArg("kernel_digest.zig");
    efi.root_module.addAnonymousImport("kernel_digest", .{ .root_source_file = kernel_digest_zig });
    efi.root_module.addAnonymousImport("measure", .{ .root_source_file = b.path("kernel/src/measure.zig") });

    // ------------------------------------------------------------------
    // Guest: ESP user program (milestone-three card 6, claim 6783) — a
    // small freestanding AArch64 flat image (USER.BIN, same DSK1 format as
    // KERNEL.BIN) that the kernel's `exec` monitor command loads from the
    // ESP and enters at EL0. Built into the same freestanding target and
    // embedded on the ESP by the image builder.
    // ------------------------------------------------------------------
    const user = b.addExecutable(.{
        .name = "user-hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/main.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    user.linker_script = b.path("user/linker.ld");
    const user_step = b.step("user", "Build the ESP user program (zig-out/bin/USER.BIN; class A tooling, no VM)");
    const user_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    user_elf2bin.addFileArg(user.getEmittedBin());
    const user_bin = user_elf2bin.addOutputFileArg("USER.BIN");
    user_elf2bin.has_side_effects = true;
    user_elf2bin.stdio = .inherit;
    user_step.dependOn(&user_elf2bin.step);
    const install_user = b.addInstallFileWithDir(user_bin, .bin, "USER.BIN");
    b.getInstallStep().dependOn(&install_user.step);

    // ------------------------------------------------------------------
    // Guest: second ESP user program (milestone-four follow-on 2, claim
    // 4613) — the never-exiting COUNTER.BIN. Same freestanding target,
    // linker script, elf2bin conversion, and ESP embedding as USER.BIN;
    // the kernel's `exec COUNTER.BIN` monitor command loads it by name.
    // It loops forever writing a DISTINCT marker (sys_write + sys_yield
    // only, no sys_exit), so the live long-lived gate can tell the two
    // programs apart in the serial log while one occupies its pool slot
    // permanently.
    // ------------------------------------------------------------------
    const counter = b.addExecutable(.{
        .name = "user-counter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/counter.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    counter.linker_script = b.path("user/linker.ld");
    const counter_step = b.step("counter", "Build the second ESP user program (zig-out/bin/COUNTER.BIN; class A tooling, no VM)");
    const counter_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    counter_elf2bin.addFileArg(counter.getEmittedBin());
    const counter_bin = counter_elf2bin.addOutputFileArg("COUNTER.BIN");
    counter_elf2bin.has_side_effects = true;
    counter_elf2bin.stdio = .inherit;
    counter_step.dependOn(&counter_elf2bin.step);
    const install_counter = b.addInstallFileWithDir(counter_bin, .bin, "COUNTER.BIN");
    b.getInstallStep().dependOn(&install_counter.step);

    // ------------------------------------------------------------------
    // Guest: third ESP user program (milestone-four follow-on 3, card
    // 3f — claim 5965) — the IPC peer PEER.BIN. Same freestanding target,
    // linker script, elf2bin conversion, and ESP embedding as USER.BIN /
    // COUNTER.BIN; the kernel's `exec PEER.BIN` monitor command loads it
    // by name. It never exits: it recv-loops through sys_ipc_recv (slot
    // 6) and echoes each received message verbatim ("peer: got N"), so
    // the live IPC gate can show COUNTER.BIN's sends and PEER.BIN's
    // echoes interleaving across the whole serial log — the strongest
    // proof of two live processes communicating.
    // ------------------------------------------------------------------
    const peer = b.addExecutable(.{
        .name = "user-peer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/peer.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    peer.linker_script = b.path("user/linker.ld");
    const peer_step = b.step("peer", "Build the third ESP user program (zig-out/bin/PEER.BIN; class A tooling, no VM)");
    const peer_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    peer_elf2bin.addFileArg(peer.getEmittedBin());
    const peer_bin = peer_elf2bin.addOutputFileArg("PEER.BIN");
    peer_elf2bin.has_side_effects = true;
    peer_elf2bin.stdio = .inherit;
    peer_step.dependOn(&peer_elf2bin.step);
    const install_peer = b.addInstallFileWithDir(peer_bin, .bin, "PEER.BIN");
    b.getInstallStep().dependOn(&install_peer.step);

    // ------------------------------------------------------------------
    // Guest: fourth ESP user program (milestone-four follow-on 4, card
    // 4c — claim 9946) — the short third program STATUS43.BIN. Same
    // freestanding target, linker script, elf2bin conversion, and ESP
    // embedding as USER.BIN / COUNTER.BIN / PEER.BIN; the kernel's
    // `exec STATUS43.BIN` monitor command loads it by name. It prints its
    // alive marker, sleeps `sleep_ticks` scheduler ticks (slot 4) so the
    // observer deterministically blocks on it, then exits with status 43
    // (slot 3) — the target in the exit-status-propagation live gate.
    // ------------------------------------------------------------------
    const status43 = b.addExecutable(.{
        .name = "user-status43",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/status43.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    status43.linker_script = b.path("user/linker.ld");
    const status43_step = b.step("status43", "Build the fourth ESP user program (zig-out/bin/STATUS43.BIN; class A tooling, no VM)");
    const status43_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    status43_elf2bin.addFileArg(status43.getEmittedBin());
    const status43_bin = status43_elf2bin.addOutputFileArg("STATUS43.BIN");
    status43_elf2bin.has_side_effects = true;
    status43_elf2bin.stdio = .inherit;
    status43_step.dependOn(&status43_elf2bin.step);
    const install_status43 = b.addInstallFileWithDir(status43_bin, .bin, "STATUS43.BIN");
    b.getInstallStep().dependOn(&install_status43.step);

    // ------------------------------------------------------------------
    // Guest: EL0EXEC.BIN (issue #1333) — class-B proof that EL0 sys_exec
    // returns to the caller. Segmented DSK3 (M133d #2758 fixup): the fuzz
    // (#1466) and oom (#2755) argv modes grew the flat image past the
    // text-page argv-block budget — `block_off + arg_block_bytes` no
    // longer fit the last content page, so every `exec EL0EXEC.BIN <arg>`
    // refused `no_args_room` before reaching _start. The DSK3 argv tail
    // lives in the writable data segment and has no such squeeze.
    // Not a GUI app (ADR 0030).
    // ------------------------------------------------------------------
    const el0exec_prog = b.addExecutable(.{
        .name = "user-el0exec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/el0exec.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    el0exec_prog.linker_script = b.path("user/linker-segmented.ld");
    const el0exec_step = b.step("el0exec", "Build the EL0 sys_exec caller-survival fixture (zig-out/bin/EL0EXEC.BIN; #1333)");
    const el0exec_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
    el0exec_elf2bin.addFileArg(el0exec_prog.getEmittedBin());
    const el0exec_bin = el0exec_elf2bin.addOutputFileArg("EL0EXEC.BIN");
    el0exec_elf2bin.has_side_effects = true;
    el0exec_elf2bin.stdio = .inherit;
    el0exec_step.dependOn(&el0exec_elf2bin.step);
    const install_el0exec = b.addInstallFileWithDir(el0exec_bin, .bin, "EL0EXEC.BIN");
    el0exec_step.dependOn(&install_el0exec.step);
    b.getInstallStep().dependOn(&install_el0exec.step);

    // ------------------------------------------------------------------
    // Guest: the SMP user program (claim 2369) — SMP1.BIN, the FIRST user
    // task that runs on a secondary core. Same freestanding target,
    // linker script, elf2bin conversion, and ESP embedding as the others;
    // the kernel's `exec -c1 SMP1.BIN` monitor command pins its task to
    // core 1 (locked console TX makes a pinned program's sys_writes safe
    // from there). It prints its hello marker, sleeps 2 ticks (the kernel
    // parks core 1 on its WFE loop and resumes it after the wake), prints
    // its exiting marker, and exits 0 — the live SMP gate's proof that a
    // USER program ran on core 1 end to end.
    // ------------------------------------------------------------------
    const smp1 = b.addExecutable(.{
        .name = "user-smp1",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/smp1.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    smp1.linker_script = b.path("user/linker.ld");
    const smp1_step = b.step("smp1", "Build the SMP user program (zig-out/bin/SMP1.BIN; class A tooling, no VM)");
    const smp1_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    smp1_elf2bin.addFileArg(smp1.getEmittedBin());
    const smp1_bin = smp1_elf2bin.addOutputFileArg("SMP1.BIN");
    smp1_elf2bin.has_side_effects = true;
    smp1_elf2bin.stdio = .inherit;
    smp1_step.dependOn(&smp1_elf2bin.step);
    const install_smp1 = b.addInstallFileWithDir(smp1_bin, .bin, "SMP1.BIN");
    b.getInstallStep().dependOn(&install_smp1.step);

    // ------------------------------------------------------------------
    // Guest: the sched-ring stress program (claim 881, #856 slice 4) —
    // SCHEDRING.BIN, the per-core ready-ring proof. The live gate runs
    // TWO copies: one pinned to core 1 (home ring 1) and one floating
    // (home ring 0, stolen onto core 1 by the idle-branch steal view).
    // Each runs 4 × sys_sleep(1) then 32 × sys_yield in a tight loop,
    // writes exact-count markers (`slept=4` / `yielded=32` / `done`),
    // and exits 0 — a lost wakeup, a duplicate staging, or a corrupt
    // save/restore breaks the exact-count greps and fails the gate.
    // ------------------------------------------------------------------
    const schedring = b.addExecutable(.{
        .name = "user-schedring",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/schedring.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    schedring.linker_script = b.path("user/linker.ld");
    const schedring_step = b.step("schedring", "Build the sched-ring stress user program (zig-out/bin/SCHEDRING.BIN; class A tooling, no VM)");
    const schedring_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    schedring_elf2bin.addFileArg(schedring.getEmittedBin());
    const schedring_bin = schedring_elf2bin.addOutputFileArg("SCHEDRING.BIN");
    schedring_elf2bin.has_side_effects = true;
    schedring_elf2bin.stdio = .inherit;
    schedring_step.dependOn(&schedring_elf2bin.step);
    const install_schedring = b.addInstallFileWithDir(schedring_bin, .bin, "SCHEDRING.BIN");
    b.getInstallStep().dependOn(&install_schedring.step);

    // ------------------------------------------------------------------
    // Guest: the four-core four-domain stress hammers (claim 907 / issue
    // #858) — SMPFILE.BIN / SMPNET.BIN / SMPWIN.BIN / SMPEV.BIN, each a
    // REAL Zig program (the calc/notepad shape, so they import the tiny
    // lib/smpst.zig syscall shim and keep counters in Zig). The live
    // gate boots 4 VCPUs and execs each pinned to its own core
    // (`exec -c1 SMPFILE.BIN` / `-c2 SMPNET.BIN` / `-c3 SMPWIN.BIN` /
    // `-c0 SMPEV.BIN`), each hammering a DIFFERENT service domain (FILE /
    // NET / WIN / EV) concurrently — the no-cross-domain-contention
    // payoff gate for the per-service-domain locks (claim 2792).
    // ------------------------------------------------------------------
    const smpst_hammers = [_]struct { src: []const u8, bin: []const u8, tag: []const u8 }{
        .{ .src = "user/src/smpst_file.zig", .bin = "SMPFILE.BIN", .tag = "file" },
        .{ .src = "user/src/smpst_net.zig", .bin = "SMPNET.BIN", .tag = "net" },
        .{ .src = "user/src/smpst_win.zig", .bin = "SMPWIN.BIN", .tag = "win" },
        .{ .src = "user/src/smpst_ev.zig", .bin = "SMPEV.BIN", .tag = "ev" },
    };
    for (smpst_hammers) |h| {
        const hammer = b.addExecutable(.{
            .name = b.fmt("user-smpst-{s}", .{h.tag}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(h.src),
                .target = kernel_target,
                .optimize = .ReleaseSmall,
            }),
        });
        hammer.linker_script = b.path("user/linker-segmented.ld");
        const hammer_step = b.step(b.fmt("smpst-{s}", .{h.tag}), b.fmt("Build the four-core stress {s} hammer (zig-out/bin/{s}; class A tooling, no VM)", .{ h.tag, h.bin }));
        const hammer_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
        hammer_elf2bin.addFileArg(hammer.getEmittedBin());
        const hammer_bin = hammer_elf2bin.addOutputFileArg(h.bin);
        hammer_elf2bin.has_side_effects = true;
        hammer_elf2bin.stdio = .inherit;
        hammer_step.dependOn(&hammer_elf2bin.step);
        const install_hammer = b.addInstallFileWithDir(hammer_bin, .bin, h.bin);
        b.getInstallStep().dependOn(&install_hammer.step);
    }

    // ------------------------------------------------------------------
    // Guest: the scheduler-aging pair (M133b, issue #2756) — SCHEDHOG.BIN
    // (a pure CPU spin that burns every slice and converges to the
    // age_max penalty) and SCHEDINT.BIN (a burn/sleep interactive whose
    // committed block resets its decay and whose `hb=` lines pace the
    // leg's measurement window). Both pinned to core 1 by the
    // live-sched-ring hog leg (`exec -c1`), so the measured shares are
    // contention on ONE core's ring.
    // ------------------------------------------------------------------
    const sched_aging = [_]struct { src: []const u8, bin: []const u8, tag: []const u8 }{
        .{ .src = "user/src/schedhog.zig", .bin = "SCHEDHOG.BIN", .tag = "hog" },
        .{ .src = "user/src/schedint.zig", .bin = "SCHEDINT.BIN", .tag = "int" },
    };
    for (sched_aging) |h| {
        const prog = b.addExecutable(.{
            .name = b.fmt("user-sched-{s}", .{h.tag}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(h.src),
                .target = kernel_target,
                .optimize = .ReleaseSmall,
            }),
        });
        prog.linker_script = b.path("user/linker-segmented.ld");
        const prog_step = b.step(b.fmt("sched-{s}", .{h.tag}), b.fmt("Build the scheduler-aging {s} program (zig-out/bin/{s}; class A tooling, no VM)", .{ h.tag, h.bin }));
        const prog_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
        prog_elf2bin.addFileArg(prog.getEmittedBin());
        const prog_bin = prog_elf2bin.addOutputFileArg(h.bin);
        prog_elf2bin.has_side_effects = true;
        prog_elf2bin.stdio = .inherit;
        prog_step.dependOn(&prog_elf2bin.step);
        const install_prog = b.addInstallFileWithDir(prog_bin, .bin, h.bin);
        b.getInstallStep().dependOn(&install_prog.step);
    }

    // ------------------------------------------------------------------
    // Guest: fifth ESP user program (milestone five, card N6 — claim
    // 1384) — the UDP syscall proof UDP.BIN. Same freestanding target,
    // linker script, elf2bin conversion, and ESP embedding as USER.BIN /
    // COUNTER.BIN / PEER.BIN / STATUS43.BIN; the kernel's `exec UDP.BIN`
    // monitor command loads it by name. It binds port 7000 through the
    // new sys_udp_listen (slot 9), loopback-sends and round-trips to the
    // host through sys_udp_send (slot 10) + sys_udp_recv (slot 11),
    // prints its markers, and exits with status 17 — the live gate's
    // first network-syscall proof from EL0.
    // ------------------------------------------------------------------
    const udp = b.addExecutable(.{
        .name = "user-udp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/udp.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    udp.linker_script = b.path("user/linker.ld");
    const udp_step = b.step("udp", "Build the fifth ESP user program (zig-out/bin/UDP.BIN; class A tooling, no VM)");
    const udp_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    udp_elf2bin.addFileArg(udp.getEmittedBin());
    const udp_bin = udp_elf2bin.addOutputFileArg("UDP.BIN");
    udp_elf2bin.has_side_effects = true;
    udp_elf2bin.stdio = .inherit;
    udp_step.dependOn(&udp_elf2bin.step);
    const install_udp = b.addInstallFileWithDir(udp_bin, .bin, "UDP.BIN");
    b.getInstallStep().dependOn(&install_udp.step);

    // ------------------------------------------------------------------
    // Guest: sixth ESP user program (milestone six, card G6 — claim 0487) —
    // the draw/window syscall proof WIN.BIN. Same freestanding target,
    // linker script, elf2bin conversion, and ESP embedding as the other
    // user programs; the kernel's `exec WIN.BIN` monitor command loads it
    // by name. It opens a user window through sys_win_open (slot 12),
    // fills it through sys_win_fill (slot 13), presents it through
    // sys_win_present (slot 14), and exits 87 — the first EL0 graphics
    // proof.
    // ------------------------------------------------------------------
    const win = b.addExecutable(.{
        .name = "user-win",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/win.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    win.linker_script = b.path("user/linker.ld");
    const win_step = b.step("win", "Build the sixth ESP user program (zig-out/bin/WIN.BIN; class A tooling, no VM)");
    const win_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    win_elf2bin.addFileArg(win.getEmittedBin());
    const win_bin = win_elf2bin.addOutputFileArg("WIN.BIN");
    win_elf2bin.has_side_effects = true;
    win_elf2bin.stdio = .inherit;
    win_step.dependOn(&win_elf2bin.step);
    const install_win = b.addInstallFileWithDir(win_bin, .bin, "WIN.BIN");
    b.getInstallStep().dependOn(&install_win.step);

    // ------------------------------------------------------------------
    // Guest: seventh ESP user program (milestone six, card G6 teardown
    // follow-on — claim 0487) — the draw/window RELEASE proof WINCLOSE.BIN.
    // Same freestanding target, linker script, elf2bin conversion, and ESP
    // embedding as the other user programs; the kernel's
    // `exec WINCLOSE.BIN` monitor command loads it by name. It opens a user
    // window through sys_win_open (slot 12), fills it (slot 13), presents
    // it (slot 14), then CLOSES it through sys_win_close (slot 15) and
    // exits 88 — the EL0 release proof (the window does not persist; the
    // freed id is re-openable).
    // ------------------------------------------------------------------
    const winclose = b.addExecutable(.{
        .name = "user-winclose",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/winclose.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    winclose.linker_script = b.path("user/linker.ld");
    const winclose_step = b.step("winclose", "Build the seventh ESP user program (zig-out/bin/WINCLOSE.BIN; class A tooling, no VM)");
    const winclose_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    winclose_elf2bin.addFileArg(winclose.getEmittedBin());
    const winclose_bin = winclose_elf2bin.addOutputFileArg("WINCLOSE.BIN");
    winclose_elf2bin.has_side_effects = true;
    winclose_elf2bin.stdio = .inherit;
    winclose_step.dependOn(&winclose_elf2bin.step);
    const install_winclose = b.addInstallFileWithDir(winclose_bin, .bin, "WINCLOSE.BIN");
    b.getInstallStep().dependOn(&install_winclose.step);

    // ------------------------------------------------------------------
    // Guest: eighth ESP user program (milestone six, card G6 per-process-
    // ownership follow-on — claim 0487) — the PERSISTENT window proof
    // WINLOOP.BIN. Same freestanding target, linker script, elf2bin
    // conversion, and ESP embedding as the other user programs; the kernel's
    // `exec WINLOOP.BIN` monitor command loads it by name. It opens a user
    // window (slot 12), fills it (slot 13), presents it (slot 14), then
    // yield-loops FOREVER (slot 2) so the window stays on the scanout for
    // the live gate's decoded-capture phase (WIN.BIN exits and its window
    // auto-closes before a capture can see it).
    // ------------------------------------------------------------------
    const winloop = b.addExecutable(.{
        .name = "user-winloop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/winloop.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    winloop.linker_script = b.path("user/linker.ld");
    const winloop_step = b.step("winloop", "Build the eighth ESP user program (zig-out/bin/WINLOOP.BIN; class A tooling, no VM)");
    const winloop_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    winloop_elf2bin.addFileArg(winloop.getEmittedBin());
    const winloop_bin = winloop_elf2bin.addOutputFileArg("WINLOOP.BIN");
    winloop_elf2bin.has_side_effects = true;
    winloop_elf2bin.stdio = .inherit;
    winloop_step.dependOn(&winloop_elf2bin.step);
    const install_winloop = b.addInstallFileWithDir(winloop_bin, .bin, "WINLOOP.BIN");
    b.getInstallStep().dependOn(&install_winloop.step);

    // ------------------------------------------------------------------
    // Guest: ninth ESP user program (milestone six, card G6 move/raise
    // follow-on — claim 0487) — the MOVE/RESTACK proof WINMOVE.BIN. Same
    // freestanding target, linker script, elf2bin conversion, and ESP
    // embedding as the other user programs; the kernel's
    // `exec WINMOVE.BIN` monitor command loads it by name. It opens a user
    // window (slot 12), fills it (slot 13), presents it (slot 14), moves it
    // twice (slot 16 — the second move clamps to the scanout corner) and
    // raises it (slot 17), then yield-loops FOREVER (slot 2) so the moved
    // window stays on the scanout for the live gate's decoded-capture
    // phase (the window's own colors at the NEW position).
    // ------------------------------------------------------------------
    const winmove = b.addExecutable(.{
        .name = "user-winmove",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/winmove.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    winmove.linker_script = b.path("user/linker.ld");
    const winmove_step = b.step("winmove", "Build the ninth ESP user program (zig-out/bin/WINMOVE.BIN; class A tooling, no VM)");
    const winmove_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    winmove_elf2bin.addFileArg(winmove.getEmittedBin());
    const winmove_bin = winmove_elf2bin.addOutputFileArg("WINMOVE.BIN");
    winmove_elf2bin.has_side_effects = true;
    winmove_elf2bin.stdio = .inherit;
    winmove_step.dependOn(&winmove_elf2bin.step);
    const install_winmove = b.addInstallFileWithDir(winmove_bin, .bin, "WINMOVE.BIN");
    b.getInstallStep().dependOn(&install_winmove.step);

    // ------------------------------------------------------------------
    // Guest: tenth ESP user program (milestone nine, card E6 capstone gate —
    // claim 9328) — the interactive event user application KEYTEST.BIN.
    // Opens a window, waits for application events via sys_wait_event
    // (slot 22), updates window contents in response to keyboard and pointer
    // events, and exits with status 99.
    // ------------------------------------------------------------------
    const keytest = b.addExecutable(.{
        .name = "user-keytest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/keytest.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    keytest.linker_script = b.path("user/linker.ld");
    const keytest_step = b.step("keytest", "Build the tenth ESP user program (zig-out/bin/KEYTEST.BIN; class A tooling, no VM)");
    const keytest_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    keytest_elf2bin.addFileArg(keytest.getEmittedBin());
    const keytest_bin = keytest_elf2bin.addOutputFileArg("KEYTEST.BIN");
    keytest_elf2bin.has_side_effects = true;
    keytest_elf2bin.stdio = .inherit;
    keytest_step.dependOn(&keytest_elf2bin.step);
    const install_keytest = b.addInstallFileWithDir(keytest_bin, .bin, "KEYTEST.BIN");
    b.getInstallStep().dependOn(&install_keytest.step);

    // ------------------------------------------------------------------
    // M78c: the three Zig storage demos are retired. The live storage proof
    // now uses GOSH.ELF redirection/cat and GOFILES.ELF directory listing;
    // no replacement Zig executable or install step remains here.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Guest: M43 U3 EL0 consumer (issue #1034 — claim #1048) BLKD.BIN.
    // Reads the raw USB mass-storage disk through the file-table `.usb`
    // volume (slots 23/24/26) and prints the host-staged marker bytes.
    // ------------------------------------------------------------------
    const blkd_prog = b.addExecutable(.{
        .name = "user-blkd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/blkd.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    blkd_prog.linker_script = b.path("user/linker.ld");
    const blkd_step = b.step("blkd", "Build the M43 U3 block-device consumer (zig-out/bin/BLKD.BIN)");
    const blkd_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    blkd_elf2bin.addFileArg(blkd_prog.getEmittedBin());
    const blkd_bin = blkd_elf2bin.addOutputFileArg("BLKD.BIN");
    blkd_elf2bin.has_side_effects = true;
    blkd_elf2bin.stdio = .inherit;
    blkd_step.dependOn(&blkd_elf2bin.step);
    const install_blkd = b.addInstallFileWithDir(blkd_bin, .bin, "BLKD.BIN");
    b.getInstallStep().dependOn(&install_blkd.step);

    // ------------------------------------------------------------------
    // M66c (#1485): NOTEPAD.BIN (the fifteenth ESP program, M11 A3 claim 3234)
    // is RETIRED with user/src/notepad.zig. Its Go successor is NOTE.ELF
    // (user/go/note, built by tools/go/build-note.sh) — a host-share ELF, not
    // an in-image Zig program, so there is no build step to replace this one.
    // The five specs that were its last exclusive coverage moved to NOTE.ELF
    // or retired in the same card.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // M71g (#1566): TOP.BIN (the sixteenth ESP program, claim 0680) is RETIRED
    // with user/src/top.zig. Its Go successor is GOTOP.ELF (user/go/top, built
    // by tools/go/build-gotop.sh) — a host-share ELF like GOFILES.ELF, not an
    // in-image Zig program, so there is no build step to replace this one. The
    // twelve specs that exec'd TOP.BIN stage GOTOP.ELF instead; GOTOP keeps the
    // `top:` marker vocabulary, so their assertions moved by binary name.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // M78c: the Zig desktop launcher is retired. GOTABWM.ELF is the shipping
    // Go seat and APPS.TXT launcher; GOSH.ELF -c covers headless exec.
    // The desktop live gates use those existing clients.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Guest: eighteenth ESP user program (milestone twelve, card N1 — claim 7483)
    // TCP.BIN. Userland TCP proof program.
    // ------------------------------------------------------------------
    const tcp_prog = b.addExecutable(.{
        .name = "user-tcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/tcp_client.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    tcp_prog.linker_script = b.path("user/linker.ld");
    const tcp_step = b.step("tcp", "Build the eighteenth ESP user program (zig-out/bin/TCP.BIN)");
    const tcp_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    tcp_elf2bin.addFileArg(tcp_prog.getEmittedBin());
    const tcp_bin = tcp_elf2bin.addOutputFileArg("TCP.BIN");
    tcp_elf2bin.has_side_effects = true;
    tcp_elf2bin.stdio = .inherit;
    tcp_step.dependOn(&tcp_elf2bin.step);
    const install_tcp = b.addInstallFileWithDir(tcp_bin, .bin, "TCP.BIN");
    b.getInstallStep().dependOn(&install_tcp.step);

    // ------------------------------------------------------------------
    // M78b (#1683): FETCH.BIN (milestone twelve, card N3) and DOWNLOAD.BIN
    // (M26 N11, #438) are RETIRED with user/src/fetch.zig and
    // user/src/download.zig. The HTTP client is Go: GOFETCH.ELF
    // (user/go/fetch, built by tools/go/build-web.sh) answers an explicit
    // http:// URL on the console with the old fetch: markers / 42 / 3 / 4
    // contract, and --download saves the body to the host share. The Zig TLS
    // consumer was already gone (M71k); there is no build step to replace
    // these two (the same shape as the FETCHS.BIN retirement below).
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Guest: M51 SSH1 (#1168) class-B proof program — SSHPACKET.BIN. The
    // guest half of the live-ssh-packet gate: it reassembles one SSH binary
    // packet the host sends split across many paced TCP segments. DSK3
    // segmented (the stream adapter's bounded buffer is a static .bss
    // global, ADR 0025 D6).
    // ------------------------------------------------------------------
    const sshpacket_ui_mod = b.createModule(.{
        .root_source_file = b.path("user/src/lib/ui.zig"),
        .target = kernel_target,
        .optimize = .ReleaseSmall,
    });
    const sshpacket_mod = b.createModule(.{
        .root_source_file = b.path("user/src/sshpacket.zig"),
        .target = kernel_target,
        .optimize = .ReleaseSmall,
    });
    sshpacket_mod.addImport("ui", sshpacket_ui_mod);
    const sshpacket_prog = b.addExecutable(.{
        .name = "user-sshpacket",
        .root_module = sshpacket_mod,
    });
    sshpacket_prog.linker_script = b.path("user/linker-segmented.ld");
    const sshpacket_step = b.step("sshpacket", "Build the M51 SSH1 class-B proof program (zig-out/bin/SSHPACKET.BIN) — DSK3 segmented");
    const sshpacket_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
    sshpacket_elf2bin.addFileArg(sshpacket_prog.getEmittedBin());
    const sshpacket_bin = sshpacket_elf2bin.addOutputFileArg("SSHPACKET.BIN");
    sshpacket_elf2bin.has_side_effects = true;
    sshpacket_elf2bin.stdio = .inherit;
    sshpacket_step.dependOn(&sshpacket_elf2bin.step);
    const install_sshpacket = b.addInstallFileWithDir(sshpacket_bin, .bin, "SSHPACKET.BIN");
    b.getInstallStep().dependOn(&install_sshpacket.step);

    // ------------------------------------------------------------------
    // M71j (#1569): SSH.BIN is RETIRED with user/src/ssh.zig. EL0 SSH-2
    // client is GOSSH.ELF (user/go/ssh, primitives in user/go/sshlib).
    // lib/ssh/wire.zig + packet.zig + stream.zig stay as the SSHPACKET.BIN
    // stream-adapter proof (live-ssh-packet). There is no Zig client build
    // step to replace this one.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // M71k (#1570): FETCHS.BIN (the HTTPS consumer, ADR 0029, cards
    // TLS13-C7/C8) is RETIRED with user/src/fetchs.zig. EL0 HTTPS is Go
    // in-process over user/go/tls (GOFETCH.ELF / WEB.ELF), and the Zig TLS
    // 1.3 client has no EL0 binary left. lib/tls stays as host-side
    // interop code: its vectors/ fixtures are consumed by the live-web and
    // go-fetch-https class-B gates. There is no build step to replace this
    // one (the same shape as the NOTEPAD.BIN retirement above).
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // M78c: the graphical Zig chat demo is retired. Its live-wm1 fixture role
    // is filled by the existing one-window SB4DAM.BIN resident; UDP itself
    // remains covered by the syscall and networking gates.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Guest: twenty-third ESP user program (milestone fourteen, card S2 — claim 7323)
    // TIMER.BIN. Headless per-process app-timer proof (arm/wait/fire/cancel).
    // ------------------------------------------------------------------
    const timertest_prog = b.addExecutable(.{
        .name = "user-timertest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/timertest.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    timertest_prog.linker_script = b.path("user/linker.ld");
    const timertest_step = b.step("timertest", "Build the twenty-third ESP user program (zig-out/bin/TIMER.BIN)");
    const timertest_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    timertest_elf2bin.addFileArg(timertest_prog.getEmittedBin());
    const timertest_bin = timertest_elf2bin.addOutputFileArg("TIMER.BIN");
    timertest_elf2bin.has_side_effects = true;
    timertest_elf2bin.stdio = .inherit;
    timertest_step.dependOn(&timertest_elf2bin.step);
    const install_timertest = b.addInstallFileWithDir(timertest_bin, .bin, "TIMER.BIN");
    b.getInstallStep().dependOn(&install_timertest.step);

    // ------------------------------------------------------------------
    // Guest: twenty-fourth ESP user program (milestone fourteen, card S4 — claim 4482)
    // VICTIM.BIN. The hostile-proof's VICTIM: owns a window, loops forever.
    // DSK3 segmented (writable .data/.bss — the ui toolkit's window-state
    // globals need the RW data+bss aperture; observed live: VICTIM
    // data-aborted at 0x400a50 on the flat DSK1 mapping the moment ui.win_*
    // wrote its first global — same failure class as NOTEPAD before its
    // segmented conversion).
    // ------------------------------------------------------------------
    const victim_prog = b.addExecutable(.{
        .name = "user-hardening-victim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/hardening_victim.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    victim_prog.linker_script = b.path("user/linker-segmented.ld");
    const victim_step = b.step("hardening-victim", "Build the twenty-fourth ESP user program (zig-out/bin/VICTIM.BIN) — DSK3 segmented (writable .data/.bss)");
    const victim_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
    victim_elf2bin.addFileArg(victim_prog.getEmittedBin());
    const victim_bin = victim_elf2bin.addOutputFileArg("VICTIM.BIN");
    victim_elf2bin.has_side_effects = true;
    victim_elf2bin.stdio = .inherit;
    victim_step.dependOn(&victim_elf2bin.step);
    const install_victim = b.addInstallFileWithDir(victim_bin, .bin, "VICTIM.BIN");
    b.getInstallStep().dependOn(&install_victim.step);

    // ------------------------------------------------------------------
    // Guest: twenty-fifth ESP user program (milestone fourteen, card S4 — claim 4482)
    // HARDEN.BIN. The hostile-consumer proof: cross-process window attacks refused.
    // ------------------------------------------------------------------
    const harden_prog = b.addExecutable(.{
        .name = "user-harden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/harden.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    harden_prog.linker_script = b.path("user/linker.ld");
    const harden_step = b.step("harden", "Build the twenty-fifth ESP user program (zig-out/bin/HARDEN.BIN)");
    const harden_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    harden_elf2bin.addFileArg(harden_prog.getEmittedBin());
    const harden_bin = harden_elf2bin.addOutputFileArg("HARDEN.BIN");
    harden_elf2bin.has_side_effects = true;
    harden_elf2bin.stdio = .inherit;
    harden_step.dependOn(&harden_elf2bin.step);
    const install_harden = b.addInstallFileWithDir(harden_bin, .bin, "HARDEN.BIN");
    b.getInstallStep().dependOn(&install_harden.step);

    // ------------------------------------------------------------------
    // Guest: twenty-sixth ESP user program (milestone fifteen, card A3 — claim 7636)
    // JINGLE.BIN. The EL0 audio seam proof: a melody played via sys_audio_play.
    // ------------------------------------------------------------------
    const jingle_prog = b.addExecutable(.{
        .name = "user-jingle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/jingle.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    jingle_prog.linker_script = b.path("user/linker.ld");
    const jingle_step = b.step("jingle", "Build the twenty-sixth ESP user program (zig-out/bin/JINGLE.BIN)");
    const jingle_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    jingle_elf2bin.addFileArg(jingle_prog.getEmittedBin());
    const jingle_bin = jingle_elf2bin.addOutputFileArg("JINGLE.BIN");
    jingle_elf2bin.has_side_effects = true;
    jingle_elf2bin.stdio = .inherit;
    jingle_step.dependOn(&jingle_elf2bin.step);
    const install_jingle = b.addInstallFileWithDir(jingle_bin, .bin, "JINGLE.BIN");
    b.getInstallStep().dependOn(&install_jingle.step);

    // ------------------------------------------------------------------
    // Guest: twenty-seventh ESP user program (milestone fifteen, card A4 — claim 3206)
    // CHIME.BIN. The composition capstone's event side: a blip played via
    // sys_audio_play on every M14 app-timer TIMER event.
    // ------------------------------------------------------------------
    const chime_prog = b.addExecutable(.{
        .name = "user-chime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/chime.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    chime_prog.linker_script = b.path("user/linker.ld");
    const chime_step = b.step("chime", "Build the twenty-seventh ESP user program (zig-out/bin/CHIME.BIN)");
    const chime_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    chime_elf2bin.addFileArg(chime_prog.getEmittedBin());
    const chime_bin = chime_elf2bin.addOutputFileArg("CHIME.BIN");
    chime_elf2bin.has_side_effects = true;
    chime_elf2bin.stdio = .inherit;
    chime_step.dependOn(&chime_elf2bin.step);
    const install_chime = b.addInstallFileWithDir(chime_bin, .bin, "CHIME.BIN");
    b.getInstallStep().dependOn(&install_chime.step);

    // ------------------------------------------------------------------
    // Guest: twenty-eighth ESP user program (milestone sixteen, card C1 — claim 3805)
    // GLOBALS.BIN. The FIRST SEGMENTED user image: built with elf2bin's
    // `--segments` mode so it carries a real writable .data + zero-filled
    // .bss region (the M15 JINGLE finding, claim 7636, is reversed) and a
    // 24 KiB .rodata blob that pushes it past the OLD 16 KiB load bound.
    // ------------------------------------------------------------------
    const globals_prog = b.addExecutable(.{
        .name = "user-globals",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/globals.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    globals_prog.linker_script = b.path("user/linker-segmented.ld");
    const globals_step = b.step("globals", "Build the twenty-eighth ESP user program (zig-out/bin/GLOBALS.BIN) — the first SEGMENTED DSK3 image");
    const globals_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
    globals_elf2bin.addFileArg(globals_prog.getEmittedBin());
    const globals_bin = globals_elf2bin.addOutputFileArg("GLOBALS.BIN");
    globals_elf2bin.has_side_effects = true;
    globals_elf2bin.stdio = .inherit;
    globals_step.dependOn(&globals_elf2bin.step);
    const install_globals = b.addInstallFileWithDir(globals_bin, .bin, "GLOBALS.BIN");
    b.getInstallStep().dependOn(&install_globals.step);

    // ------------------------------------------------------------------
    // Guest: twenty-ninth ESP user program (milestone sixteen, card C2 — claim 8403)
    // GUARD.BIN. The hostile-EL0-refused proof: steps off its stack into the
    // guard page below it, faults, and is REAPED (status 139) by the kernel's
    // fault dispatcher instead of parking the machine. Flat DSK1.
    // ------------------------------------------------------------------
    const guard_prog = b.addExecutable(.{
        .name = "user-guard",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/guard.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    guard_prog.linker_script = b.path("user/linker.ld");
    const guard_step = b.step("guard", "Build the twenty-ninth ESP user program (zig-out/bin/GUARD.BIN) — the hostile guard-page proof");
    const guard_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    guard_elf2bin.addFileArg(guard_prog.getEmittedBin());
    const guard_bin = guard_elf2bin.addOutputFileArg("GUARD.BIN");
    guard_elf2bin.has_side_effects = true;
    guard_elf2bin.stdio = .inherit;
    guard_step.dependOn(&guard_elf2bin.step);
    const install_guard = b.addInstallFileWithDir(guard_bin, .bin, "GUARD.BIN");
    b.getInstallStep().dependOn(&install_guard.step);

    // ------------------------------------------------------------------
    // M71f (#1565): the Zig settings panel SETTINGS.BIN is RETIRED here.
    // The panel is GOSET.ELF (user/go/settings), built by
    // tools/go/build-goset.sh like every other Go guest app. One binary per
    // card (ADR 0030): no `settings` step, no zig-out/bin/SETTINGS.BIN, so
    // the only way to launch Settings is the Go panel in image/apps.txt.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Guest: thirty-first ESP user program (M22 D2 — issue #325) ASM.BIN.
    // The on-machine two-pass AArch64 assembler: reads a bounded source
    // file, emits a minimal statically linked AArch64 ELF32 executable
    // (single R+X PT_LOAD at 0x400000) that the D1 loader runs via exec.
    // ------------------------------------------------------------------
    const asm_prog = b.addExecutable(.{
        .name = "user-asm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/asm.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    asm_prog.linker_script = b.path("user/linker.ld");
    const asm_step = b.step("asm", "Build the thirty-first ESP user program (zig-out/bin/ASM.BIN)");
    const asm_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    asm_elf2bin.addFileArg(asm_prog.getEmittedBin());
    const asm_bin = asm_elf2bin.addOutputFileArg("ASM.BIN");
    asm_elf2bin.has_side_effects = true;
    asm_elf2bin.stdio = .inherit;
    asm_step.dependOn(&asm_elf2bin.step);
    const install_asm = b.addInstallFileWithDir(asm_bin, .bin, "ASM.BIN");
    b.getInstallStep().dependOn(&install_asm.step);

    // ------------------------------------------------------------------
    // Guest: thirty-second ESP user program (M22 D4 — issue #327) DISAS.BIN.
    // The AArch64 disassembler: hex dump + mnemonic per instruction word,
    // inverse of ASM.BIN's encoders.
    // ------------------------------------------------------------------
    const disas_prog = b.addExecutable(.{
        .name = "user-disas",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/disas.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    disas_prog.linker_script = b.path("user/linker.ld");
    const disas_step = b.step("disas", "Build the thirty-second ESP user program (zig-out/bin/DISAS.BIN)");
    const disas_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    disas_elf2bin.addFileArg(disas_prog.getEmittedBin());
    const disas_bin = disas_elf2bin.addOutputFileArg("DISAS.BIN");
    disas_elf2bin.has_side_effects = true;
    disas_elf2bin.stdio = .inherit;
    disas_step.dependOn(&disas_elf2bin.step);
    const install_disas = b.addInstallFileWithDir(disas_bin, .bin, "DISAS.BIN");
    b.getInstallStep().dependOn(&install_disas.step);

    // ------------------------------------------------------------------
    // Guest: fifty-second ESP user program (M32 — issue #620) ZC.BIN.
    // The on-machine Zig subset compiler: compiles a small Zig dialect
    // to native AArch64 ELF32 in-guest.
    // ------------------------------------------------------------------
    const zc_prog = b.addExecutable(.{
        .name = "user-zc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/zc.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    zc_prog.linker_script = b.path("user/linker-segmented.ld");
    const zc_step = b.step("zc", "Build the fifty-second ESP user program (zig-out/bin/ZC.BIN)");
    const zc_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
    zc_elf2bin.addFileArg(zc_prog.getEmittedBin());
    const zc_bin = zc_elf2bin.addOutputFileArg("ZC.BIN");
    zc_elf2bin.has_side_effects = true;
    zc_elf2bin.stdio = .inherit;
    zc_step.dependOn(&zc_elf2bin.step);
    const install_zc = b.addInstallFileWithDir(zc_bin, .bin, "ZC.BIN");
    b.getInstallStep().dependOn(&install_zc.step);

    // ------------------------------------------------------------------
    // Guest: M35 W1b (#762) WASM.BIN — the wasm interpreter core.
    // Build-only marker for now: `wasm run` module delivery + command
    // wiring land with W2 (#763); the image is NOT touched here.
    // ------------------------------------------------------------------
    const wasm_prog = b.addExecutable(.{
        .name = "user-wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/wasm.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    // DSK3 segmented: the W2 `_start` keeps the interpreter state
    // (Module ~77 KiB, Machine ~30 KiB, module buffer 64 KiB) in .bss —
    // the 32 KiB EL0 stack can never carry it — and argv rides the
    // writable data tail (card 3e: ELF images cannot take args). The
    // linear-memory store is mmap'd at runtime, not .bss.
    wasm_prog.linker_script = b.path("user/linker-segmented.ld");
    const wasm_step = b.step("wasm", "Build the M35 wasm interpreter (zig-out/bin/WASM.BIN)");
    const wasm_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
    wasm_elf2bin.addFileArg(wasm_prog.getEmittedBin());
    const wasm_bin = wasm_elf2bin.addOutputFileArg("WASM.BIN");
    wasm_elf2bin.has_side_effects = true;
    wasm_elf2bin.stdio = .inherit;
    wasm_step.dependOn(&wasm_elf2bin.step);
    const install_wasm = b.addInstallFileWithDir(wasm_bin, .bin, "WASM.BIN");
    b.getInstallStep().dependOn(&install_wasm.step);

    // ------------------------------------------------------------------
    // Guest: M47 CP5 (#1119) CRYPTOD.BIN — the crypto KAT demo. Streams a
    // host-share file through SHA-256 + HMAC-SHA256 using the shared
    // `user/src/lib/crypto.zig` library and prints one line in one write;
    // the class-B live-crypto gate asserts guest bytes == host KAT.
    // ------------------------------------------------------------------
    const cryptod_prog = b.addExecutable(.{
        .name = "user-cryptod",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/cryptod.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    cryptod_prog.linker_script = b.path("user/linker.ld");
    const cryptod_step = b.step("cryptod", "Build the M47 crypto KAT demo (zig-out/bin/CRYPTOD.BIN) — DSK1 flat (no writable globals)");
    const cryptod_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    cryptod_elf2bin.addFileArg(cryptod_prog.getEmittedBin());
    const cryptod_bin = cryptod_elf2bin.addOutputFileArg("CRYPTOD.BIN");
    cryptod_elf2bin.has_side_effects = true;
    cryptod_elf2bin.stdio = .inherit;
    cryptod_step.dependOn(&cryptod_elf2bin.step);
    const install_cryptod = b.addInstallFileWithDir(cryptod_bin, .bin, "CRYPTOD.BIN");
    b.getInstallStep().dependOn(&install_cryptod.step);

    // M35 W3 (#764) + claim 4912: the virelai.h / virelai.zig host-author
    // shim probes. `zig build shim-check` compiles tests/virelai-probe.c
    // (zig cc) AND tests/virelai-probe.zig (zig build-exe) to wasm32
    // modules and asserts each import table is exactly the frozen
    // env.* surface (contract §5 + the W2 write/exit pair) — the W3
    // acceptance item "the shim compiles a host program against the
    // contract alone", class-A reproducible, for both languages.
    const shim_step = b.step("shim-check", "Compile the virelai.h/virelai.zig probes and assert the frozen env.* import table");
    const shim_cc = b.addSystemCommand(&.{ "zig", "cc", "-target", "wasm32-freestanding", "-nostdlib", "-fno-sanitize=undefined", "-g0", "-I", "tests" });
    shim_cc.addFileArg(b.path("tests/virelai-probe.c"));
    shim_cc.addArg("-o");
    const shim_wasm = shim_cc.addOutputFileArg("virelai-probe.wasm");
    shim_cc.stdio = .inherit;
    const shim_check = b.addSystemCommand(&.{ "python3", "tools/verify-virelai-probe.py" });
    shim_check.addFileArg(shim_wasm);
    shim_check.has_side_effects = true;
    shim_check.stdio = .inherit;
    shim_step.dependOn(&shim_check.step);

    // Zig shim probe: tests/virelai-probe.zig against tests/virelai.zig,
    // built with the Zig author recipe (zig build-exe, wasm32-freestanding,
    // ReleaseSmall) and run through the SAME import-table verifier.
    const wasm32_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const zig_probe = b.addExecutable(.{
        .name = "virelai-probe-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/virelai-probe.zig"),
            .target = wasm32_target,
            .optimize = .ReleaseSmall,
            .strip = true,
        }),
    });
    const zig_shim_check = b.addSystemCommand(&.{ "python3", "tools/verify-virelai-probe.py" });
    zig_shim_check.addFileArg(zig_probe.getEmittedBin());
    zig_shim_check.has_side_effects = true;
    zig_shim_check.stdio = .inherit;
    shim_step.dependOn(&zig_shim_check.step);

    // ------------------------------------------------------------------
    // Guest: thirty-third ESP user program (M22 D6 — issue #329) PS.BIN.
    // Windowed process viewer: 1 Hz sys_procs snapshot rendered as rows.
    // ------------------------------------------------------------------
    const ps_prog = b.addExecutable(.{
        .name = "user-ps",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/ps.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    ps_prog.linker_script = b.path("user/linker-segmented.ld");
    const ps_step = b.step("ps", "Build the thirty-third ESP user program (zig-out/bin/PS.BIN) — DSK3 segmented (writable .data/.bss)");
    const ps_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
    ps_elf2bin.addFileArg(ps_prog.getEmittedBin());
    const ps_bin = ps_elf2bin.addOutputFileArg("PS.BIN");
    ps_elf2bin.has_side_effects = true;
    ps_elf2bin.stdio = .inherit;
    ps_step.dependOn(&ps_elf2bin.step);
    const install_ps = b.addInstallFileWithDir(ps_bin, .bin, "PS.BIN");
    b.getInstallStep().dependOn(&install_ps.step);

    // ------------------------------------------------------------------
    // Guest: terminal-seam pilot (#1072, ADR 0020) — TTYECHO.BIN.
    // EL0 owns /dev/tty, attaches the serial console front-end, and echoes.
    // ------------------------------------------------------------------
    const ttyecho_prog = b.addExecutable(.{
        .name = "user-ttyecho",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/ttyecho.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    ttyecho_prog.linker_script = b.path("user/linker.ld");
    const ttyecho_step = b.step("ttyecho", "Build the terminal-seam pilot (zig-out/bin/TTYECHO.BIN; #1072)");
    const ttyecho_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    ttyecho_elf2bin.addFileArg(ttyecho_prog.getEmittedBin());
    const ttyecho_bin = ttyecho_elf2bin.addOutputFileArg("TTYECHO.BIN");
    ttyecho_elf2bin.has_side_effects = true;
    ttyecho_elf2bin.stdio = .inherit;
    ttyecho_step.dependOn(&ttyecho_elf2bin.step);
    const install_ttyecho = b.addInstallFileWithDir(ttyecho_bin, .bin, "TTYECHO.BIN");
    b.getInstallStep().dependOn(&install_ttyecho.step);

    // ------------------------------------------------------------------
    // Guest: TTYED.BIN (M45 SH1 — issue #1077, ADR 0021 D6). The live smoke
    // for `user/src/lib/tty.zig`: opens /dev/tty, attaches the serial
    // front-end, drives the line editor (insert/delete, Home/End, Up/Down
    // history) from the raw input queue, and prints `ttyed: line <text>` per
    // submitted line.
    // ------------------------------------------------------------------
    const ttyed_prog = b.addExecutable(.{
        .name = "user-ttyed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/ttyed.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    ttyed_prog.linker_script = b.path("user/linker.ld");
    const ttyed_step = b.step("ttyed", "Build the M45 SH1 terminal-library smoke (zig-out/bin/TTYED.BIN; #1077)");
    const ttyed_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    ttyed_elf2bin.addFileArg(ttyed_prog.getEmittedBin());
    const ttyed_bin = ttyed_elf2bin.addOutputFileArg("TTYED.BIN");
    ttyed_elf2bin.has_side_effects = true;
    ttyed_elf2bin.stdio = .inherit;
    ttyed_step.dependOn(&ttyed_elf2bin.step);
    const install_ttyed = b.addInstallFileWithDir(ttyed_bin, .bin, "TTYED.BIN");
    b.getInstallStep().dependOn(&install_ttyed.step);

    // ------------------------------------------------------------------
    // M68b (#1450): SH.BIN is RETIRED with user/src/sh.zig. Its Go successor
    // is GOSH.ELF (user/go/sh, built by tools/go/build-gosh.sh) — a host-share
    // ELF, not an in-image Zig program, so there is no build step to replace
    // this one. The last two SH.BIN-running specs (live-remote, live-remote-
    // auth2) retargeted onto `GOSH.ELF net` in the same card.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Guest: TOOL.BIN (M49 SD3 — issue #1130). The standalone busybox-style
    // multicall over lib/toolbox.zig: argv[0] selects head/tail/wc/grep/
    // sort/cut/test/[/printf, the rest are its arguments, stdin is the
    // kernel pipe, and file arguments come from the host share.
    // ------------------------------------------------------------------
    const tool_prog = b.addExecutable(.{
        .name = "user-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/tool.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    tool_prog.linker_script = b.path("user/linker-segmented.ld");
    const tool_step = b.step("tool", "Build the M49 SD3 tool multicall (zig-out/bin/TOOL.BIN) — DSK3 segmented");
    const tool_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
    tool_elf2bin.addFileArg(tool_prog.getEmittedBin());
    const tool_bin = tool_elf2bin.addOutputFileArg("TOOL.BIN");
    tool_elf2bin.has_side_effects = true;
    tool_elf2bin.stdio = .inherit;
    tool_step.dependOn(&tool_elf2bin.step);
    const install_tool = b.addInstallFileWithDir(tool_bin, .bin, "TOOL.BIN");
    b.getInstallStep().dependOn(&install_tool.step);

    // ------------------------------------------------------------------
    // M71n (#1573): PING.BIN (the thirty-fourth ESP program, M26 N1 — issue
    // #399) is RETIRED with user/src/ping.zig. Its Go successor is GOPING.ELF
    // (user/go/ping, built by tools/go/build-goping.sh) — a host-share ELF
    // like GOTOP.ELF, not an in-image Zig program, so there is no build step
    // to replace this one. live-n1-ping.spec and live-net-offline.spec stage
    // GOPING.ELF instead; it keeps PING.BIN's markers and its 0/1/2/3 exit
    // contract, so their assertions moved by binary name.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // M78a (#1682): the network diagnostics are guest Go applications
    // (GONETSTAT.ELF, GODNS.ELF, GOTRACEROUTE.ELF), built by
    // tools/go/build-netdiag.sh and staged by their existing live specs.
    // They are host-share ELFs, not in-image Zig programs.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Guest: thirty-fifth ESP user program (M22 D10 — issue #333) RESMON.BIN.
    // Lightweight resource monitor window: shows process count, scheduler
    // state, and uptime via sys_procs (slot 7). Auto-refreshes at 1 Hz.
    // Writable BSS snapshot state -> SEGMENTED DSK3 image (the GLOBALS.BIN
    // pattern; claim 5220 — the flat DSK1 mapping has no writable segment).
    // ------------------------------------------------------------------
    const resmon_prog = b.addExecutable(.{
        .name = "user-resmon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/resmon.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    resmon_prog.linker_script = b.path("user/linker-segmented.ld");
    const resmon_step = b.step("resmon", "Build the thirty-fifth ESP user program (zig-out/bin/RESMON.BIN) — segmented DSK3");
    const resmon_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
    resmon_elf2bin.addFileArg(resmon_prog.getEmittedBin());
    const resmon_bin = resmon_elf2bin.addOutputFileArg("RESMON.BIN");
    resmon_elf2bin.has_side_effects = true;
    resmon_elf2bin.stdio = .inherit;
    resmon_step.dependOn(&resmon_elf2bin.step);
    const install_resmon = b.addInstallFileWithDir(resmon_bin, .bin, "RESMON.BIN");
    b.getInstallStep().dependOn(&install_resmon.step);

    // ------------------------------------------------------------------
    // Guest: thirty-sixth ESP user program (M22 D14 — issue #337) DEVCONS.BIN.
    // Developer console: split-screen log viewer + command prompt window.
    // Auto-refreshes on key input; output on serial console.
    // Writable log-ring BSS -> SEGMENTED DSK3 image (the GLOBALS.BIN
    // pattern; claim 5220 — observed live: the flat image data-aborted on
    // the first log_append, far=0x400928, status 139 before `ready`).
    // ------------------------------------------------------------------
    const devcons_prog = b.addExecutable(.{
        .name = "user-devcons",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/devcons.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    devcons_prog.linker_script = b.path("user/linker-segmented.ld");
    const devcons_step = b.step("devcons", "Build the thirty-sixth ESP user program (zig-out/bin/DEVCONS.BIN) — segmented DSK3");
    const devcons_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
    devcons_elf2bin.addFileArg(devcons_prog.getEmittedBin());
    const devcons_bin = devcons_elf2bin.addOutputFileArg("DEVCONS.BIN");
    devcons_elf2bin.has_side_effects = true;
    devcons_elf2bin.stdio = .inherit;
    devcons_step.dependOn(&devcons_elf2bin.step);
    const install_devcons = b.addInstallFileWithDir(devcons_bin, .bin, "DEVCONS.BIN");
    b.getInstallStep().dependOn(&install_devcons.step);

    // ------------------------------------------------------------------
    // Guest: thirty-eighth ESP user program (milestone twenty-one W1/W2
    // gate payload — claim 8777) M21DEMO.BIN. Opens TWO distinctively-
    // colored user windows (A dark-blue + red block, B black + cyan block),
    // presents both, and yield-loops forever so the live tiling gate can
    // drive `dui tile <n>` / `dui master` against them and decode the
    // tiled-layout captures.
    // ------------------------------------------------------------------
    const m21demo = b.addExecutable(.{
        .name = "user-m21demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/m21demo.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    m21demo.linker_script = b.path("user/linker.ld");
    const m21demo_step = b.step("m21demo", "Build the thirty-eighth ESP user program (zig-out/bin/M21DEMO.BIN; class A tooling, no VM)");
    const m21demo_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    m21demo_elf2bin.addFileArg(m21demo.getEmittedBin());
    const m21demo_bin = m21demo_elf2bin.addOutputFileArg("M21DEMO.BIN");
    m21demo_elf2bin.has_side_effects = true;
    m21demo_elf2bin.stdio = .inherit;
    m21demo_step.dependOn(&m21demo_elf2bin.step);
    const install_m21demo = b.addInstallFileWithDir(m21demo_bin, .bin, "M21DEMO.BIN");
    b.getInstallStep().dependOn(&install_m21demo.step);

    // ------------------------------------------------------------------
    // Guest: forty-third ESP user program (M26 N12 — issue #439) NETPROF.BIN.
    // Persistent network configuration profile manager.
    // ------------------------------------------------------------------
    const netprof_prog = b.addExecutable(.{
        .name = "user-netprof",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/netprof.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    netprof_prog.linker_script = b.path("user/linker.ld");
    const netprof_step = b.step("netprof", "Build the forty-third ESP user program (zig-out/bin/NETPROF.BIN)");
    const netprof_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    netprof_elf2bin.addFileArg(netprof_prog.getEmittedBin());
    const netprof_bin = netprof_elf2bin.addOutputFileArg("NETPROF.BIN");
    netprof_elf2bin.has_side_effects = true;
    netprof_elf2bin.stdio = .inherit;
    netprof_step.dependOn(&netprof_elf2bin.step);
    const install_netprof = b.addInstallFileWithDir(netprof_bin, .bin, "NETPROF.BIN");
    b.getInstallStep().dependOn(&install_netprof.step);

    // ------------------------------------------------------------------
    // M71g (#1566): SYSMON.BIN (the forty-fourth ESP program, M27 G6 — issue
    // #449) is RETIRED with user/src/sysmon.zig. It and TOP.BIN were one piece
    // of product — "see what is running" — so one Go successor replaces both:
    // GOTOP.ELF (user/go/top, tools/go/build-gotop.sh), whose network tab
    // carries the slot-62 counters SYSMON reported. Two specs lost their Zig
    // font/theme host with it: live-typography moved to DEVCONS.BIN (the
    // remaining font-heavy Zig app) and live-tokens' SYSMON runs retired with a
    // named coverage note (DEVCONS' A5/B5 still pin the same kernel table).
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // M71l (#1571): HTTPD.BIN (the forty-fifth ESP program, Claim 0750) is
    // RETIRED with user/src/httpd.zig. Its Go successor is GOHTTPD.ELF
    // (user/go/httpd, built by tools/go/build-gohttpd.sh) — a host-share ELF,
    // not an in-image Zig program, so there is no build step to replace this
    // one. The live-httpd spec stages GOHTTPD.ELF and keeps the same passive
    // open probe (the monitor's tcp=listen).
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Guest: Dynamic Linker & Shared Libraries (Milestone 30, claim 7921)
    // ------------------------------------------------------------------
    const ld_prog = b.addExecutable(.{
        .name = "ld.so",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/ld.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    ld_prog.linker_script = b.path("user/ld.ld");
    const ld_step = b.step("ld", "Build the freestanding dynamic runtime linker (zig-out/bin/LD.SO)");
    const ld_bin = ld_prog.getEmittedBin();
    const install_ld = b.addInstallFileWithDir(ld_bin, .bin, "LD.SO");
    b.getInstallStep().dependOn(&install_ld.step);
    ld_step.dependOn(&install_ld.step);

    // ------------------------------------------------------------------
    // Guest: forty-sixth ESP user program (Milestone 29, Issue #598)
    // VMTEST.BIN. Headless VM depth proof (mmap, demand paging, COW, munmap).
    // ------------------------------------------------------------------
    const vmtest_prog = b.addExecutable(.{
        .name = "user-vmtest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/vmtest.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    vmtest_prog.linker_script = b.path("user/linker.ld");
    const vmtest_step = b.step("vmtest", "Build the forty-sixth ESP user program (zig-out/bin/VMTEST.BIN)");
    const vmtest_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    vmtest_elf2bin.addFileArg(vmtest_prog.getEmittedBin());
    const vmtest_bin = vmtest_elf2bin.addOutputFileArg("VMTEST.BIN");
    vmtest_elf2bin.has_side_effects = true;
    vmtest_elf2bin.stdio = .inherit;
    vmtest_step.dependOn(&vmtest_elf2bin.step);
    const install_vmtest = b.addInstallFileWithDir(vmtest_bin, .bin, "VMTEST.BIN");
    b.getInstallStep().dependOn(&install_vmtest.step);

    // ------------------------------------------------------------------
    // Guest: forty-seventh ESP user program (M32 WMS2, issue #622)
    // WNDSTUB.BIN — the minimal WM-server registrant behind the live
    // verify-live-wmctl-register.sh gate: registers through the render-
    // server register (slot 65 REGISTER), receives a COMPOSITE_TICK
    // (kind 18) via sys_wait_event, issues REQUEST_PRESENT (slot 65),
    // and exits — the kernel then reports the shim fallback. Same
    // freestanding target/linker/elf2bin/ESP-embedding as the others.
    // ------------------------------------------------------------------
    const wndstub_prog = b.addExecutable(.{
        .name = "user-wndstub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/wndstub.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    wndstub_prog.linker_script = b.path("user/linker.ld");
    const wndstub_step = b.step("wndstub", "Build the forty-seventh ESP user program (zig-out/bin/WNDSTUB.BIN)");
    const wndstub_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    wndstub_elf2bin.addFileArg(wndstub_prog.getEmittedBin());
    const wndstub_bin = wndstub_elf2bin.addOutputFileArg("WNDSTUB.BIN");
    wndstub_elf2bin.has_side_effects = true;
    wndstub_elf2bin.stdio = .inherit;
    wndstub_step.dependOn(&wndstub_elf2bin.step);
    const install_wndstub = b.addInstallFileWithDir(wndstub_bin, .bin, "WNDSTUB.BIN");
    b.getInstallStep().dependOn(&install_wndstub.step);

    // ------------------------------------------------------------------
    // Guest: ESP user program (M97g, issue #2084) ENTPROBE.BIN — the
    // minimal sys_getrandom (slot 72) caller behind the entropy-absent
    // fail-closed gate: one 16-byte fill, a serial marker, and an exit
    // status carrying the verdict (-errno when refused). Same freestanding
    // target/linker/elf2bin/ESP-embedding as the others.
    // ------------------------------------------------------------------
    const entprobe_prog = b.addExecutable(.{
        .name = "user-entprobe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/entprobe.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    entprobe_prog.linker_script = b.path("user/linker.ld");
    const entprobe_step = b.step("entprobe", "Build the slot-72 fail-closed probe (zig-out/bin/ENTPROBE.BIN)");
    const entprobe_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    entprobe_elf2bin.addFileArg(entprobe_prog.getEmittedBin());
    const entprobe_bin = entprobe_elf2bin.addOutputFileArg("ENTPROBE.BIN");
    entprobe_elf2bin.has_side_effects = true;
    entprobe_elf2bin.stdio = .inherit;
    entprobe_step.dependOn(&entprobe_elf2bin.step);
    const install_entprobe = b.addInstallFileWithDir(entprobe_bin, .bin, "ENTPROBE.BIN");
    b.getInstallStep().dependOn(&install_entprobe.step);

    // ------------------------------------------------------------------
    // Guest: forty-eighth ESP user program (M32 WMS3, issue #623)
    // WND.BIN — the long-lived EL0 WM server: REGISTERs (slot 65), then
    // loops on sys_wait_event servicing kind-18 COMPOSITE_TICK and
    // REQUEST_PRESENTs at its own cadence (pacing the desktop while the
    // shell idle drain is gated off by WMS2). Never exits. It is NOT in
    // APPS.TXT (infrastructure, launched via the `wnd start` bootstrap);
    // the default VM stays shim-only.
    // ------------------------------------------------------------------
    const wnd_mod = b.createModule(.{
        .root_source_file = b.path("user/src/wnd.zig"),
        .target = kernel_target,
        .optimize = .ReleaseSmall,
    });
    // M32 WMS3 drift guard: WND.BIN compiles the SAME pure rules source as
    // the kernel shim (kernel/src/wnd_core.zig). It lives in a different
    // module tree, so expose it as an anonymous import shared by both.
    wnd_mod.addAnonymousImport("wnd_core", .{ .root_source_file = b.path("kernel/src/wnd_core.zig") });
    // Gate 2 (claim 9850) turned WND.BIN from naked asm into a real Zig
    // program with EL0 policy state (mirror registry, tile/snap/ws tables,
    // counters) — module globals need a writable segment, so the build uses
    // the SEGMENTED DSK3 path (linker-segmented.ld + elf2bin --segments,
    // the GLOBALS.BIN precedent). The loader maps text EL0-RO+PXN and
    // data+bss EL0-RW+UXN; the WMS3-era flat naked-asm payload had no
    // globals and stayed on the flat path.
    const wnd_prog = b.addExecutable(.{
        .name = "user-wnd",
        .root_module = wnd_mod,
    });
    wnd_prog.linker_script = b.path("user/linker-segmented.ld");
    const wnd_step = b.step("wnd", "Build the forty-eighth ESP user program (zig-out/bin/WND.BIN)");
    const wnd_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
    wnd_elf2bin.addFileArg(wnd_prog.getEmittedBin());
    const wnd_bin = wnd_elf2bin.addOutputFileArg("WND.BIN");
    wnd_elf2bin.has_side_effects = true;
    wnd_elf2bin.stdio = .inherit;
    wnd_step.dependOn(&wnd_elf2bin.step);
    const install_wnd = b.addInstallFileWithDir(wnd_bin, .bin, "WND.BIN");
    b.getInstallStep().dependOn(&install_wnd.step);

    // ------------------------------------------------------------------
    // Guest: M39 TWM1 tabbed window manager (issue #928)
    // TABWM.BIN — the tabbed desktop EL0 WM server: registers (slot 65),
    // renders Left Sidebar with Sexiburger, tabs, and clock/tray.
    // ------------------------------------------------------------------
    const tabwm_mod = b.createModule(.{
        .root_source_file = b.path("user/src/tabwm.zig"),
        .target = kernel_target,
        .optimize = .ReleaseSmall,
    });
    tabwm_mod.addAnonymousImport("wnd_core", .{ .root_source_file = b.path("kernel/src/wnd_core.zig") });
    const tabwm_prog = b.addExecutable(.{
        .name = "user-tabwm",
        .root_module = tabwm_mod,
    });
    tabwm_prog.linker_script = b.path("user/linker-segmented.ld");
    const tabwm_step = b.step("tabwm", "Build the tabbed desktop WM server (zig-out/bin/TABWM.BIN)");
    const tabwm_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
    tabwm_elf2bin.addFileArg(tabwm_prog.getEmittedBin());
    const tabwm_bin = tabwm_elf2bin.addOutputFileArg("TABWM.BIN");
    tabwm_elf2bin.has_side_effects = true;
    tabwm_elf2bin.stdio = .inherit;
    tabwm_step.dependOn(&tabwm_elf2bin.step);
    const install_tabwm = b.addInstallFileWithDir(tabwm_bin, .bin, "TABWM.BIN");
    b.getInstallStep().dependOn(&install_tabwm.step);

    // ------------------------------------------------------------------
    // Guest: forty-ninth ESP user program (M32 WMS7 Gate A, issue #627)
    // WMRPC.BIN — the app↔WM mailbox-protocol test app behind the live
    // verify-live-wm-ipc.sh gate: reads sys_procs (slot 7) to find the WM,
    // opens a window, sends WIN_RAISE/WIN_CONFIG over the mailbox (slots
    // 5/6), polls for the ack. Real Zig (like NOTEPAD) with the SAME
    // wnd_core anon import as WND.BIN (the single-source WM_RPC wire
    // format). Flat DSK1 — it has no writable module globals (all scratch is
    // stack), unlike WND.BIN's segmented image.
    // ------------------------------------------------------------------
    const wmrpc_mod = b.createModule(.{
        .root_source_file = b.path("user/src/wmrpc.zig"),
        .target = kernel_target,
        .optimize = .ReleaseSmall,
    });
    wmrpc_mod.addAnonymousImport("wnd_core", .{ .root_source_file = b.path("kernel/src/wnd_core.zig") });
    const wmrpc_prog = b.addExecutable(.{
        .name = "user-wmrpc",
        .root_module = wmrpc_mod,
    });
    wmrpc_prog.linker_script = b.path("user/linker.ld");
    const wmrpc_step = b.step("wmrpc", "Build the forty-ninth ESP user program (zig-out/bin/WMRPC.BIN)");
    const wmrpc_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    wmrpc_elf2bin.addFileArg(wmrpc_prog.getEmittedBin());
    const wmrpc_bin = wmrpc_elf2bin.addOutputFileArg("WMRPC.BIN");
    wmrpc_elf2bin.has_side_effects = true;
    wmrpc_elf2bin.stdio = .inherit;
    wmrpc_step.dependOn(&wmrpc_elf2bin.step);
    const install_wmrpc = b.addInstallFileWithDir(wmrpc_bin, .bin, "WMRPC.BIN");
    b.getInstallStep().dependOn(&install_wmrpc.step);

    // ------------------------------------------------------------------
    // Guest: fiftieth + fifty-first ESP user programs (M33 SB2, claim 8878)
    // SB2WM.BIN + SB2OWN.BIN — the two-process shared-anon proof behind the
    // verify-live-sb2-shared-anon.sh gate: the owner creates a shared surface
    // (M33_MAP_SHARED), renders a magic byte; the registered WM attaches it
    // READ-ONLY by handle, reads the byte, and — after the owner exits —
    // re-attaches the stale handle to prove EFAULT revocation. Same
    // freestanding target/linker/elf2bin/ESP-embedding as the others.
    // ------------------------------------------------------------------
    const sb2_wm_prog = b.addExecutable(.{
        .name = "user-sb2-wm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/sb2_wm.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    sb2_wm_prog.linker_script = b.path("user/linker.ld");
    const sb2_wm_step = b.step("sb2wm", "Build the fiftieth ESP user program (zig-out/bin/SB2WM.BIN)");
    const sb2_wm_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    sb2_wm_elf2bin.addFileArg(sb2_wm_prog.getEmittedBin());
    const sb2_wm_bin = sb2_wm_elf2bin.addOutputFileArg("SB2WM.BIN");
    sb2_wm_elf2bin.has_side_effects = true;
    sb2_wm_elf2bin.stdio = .inherit;
    sb2_wm_step.dependOn(&sb2_wm_elf2bin.step);
    const install_sb2_wm = b.addInstallFileWithDir(sb2_wm_bin, .bin, "SB2WM.BIN");
    b.getInstallStep().dependOn(&install_sb2_wm.step);

    const sb2_own_prog = b.addExecutable(.{
        .name = "user-sb2-own",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/sb2_own.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    sb2_own_prog.linker_script = b.path("user/linker.ld");
    const sb2_own_step = b.step("sb2own", "Build the fifty-first ESP user program (zig-out/bin/SB2OWN.BIN)");
    const sb2_own_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    sb2_own_elf2bin.addFileArg(sb2_own_prog.getEmittedBin());
    const sb2_own_bin = sb2_own_elf2bin.addOutputFileArg("SB2OWN.BIN");
    sb2_own_elf2bin.has_side_effects = true;
    sb2_own_elf2bin.stdio = .inherit;
    sb2_own_step.dependOn(&sb2_own_elf2bin.step);
    const install_sb2_own = b.addInstallFileWithDir(sb2_own_bin, .bin, "SB2OWN.BIN");
    b.getInstallStep().dependOn(&install_sb2_own.step);

    // ------------------------------------------------------------------
    // Guest: fifty-second + fifty-third ESP user programs (M33 SB3, claim 3633)
    // SB3WM.BIN + SB3OWN.BIN — the two-process window surface handoff proof
    // behind the verify-live-sb3-surface-handoff.sh gate: the migrated app
    // opens a window, BINDS a shared-anonymous surface as its back-buffer via
    // sys_mmap(addr=M33_SURF_WIN_TAG|wid), renders with PLAIN STORES through
    // its writable leaf (no kernel fill), and the registered WM peers the
    // surface RO and reads the exact bytes — the surface-handoff parity gate.
    // Same freestanding target/linker/elf2bin/ESP-embedding as the others.
    // ------------------------------------------------------------------
    const sb3_wm_prog = b.addExecutable(.{
        .name = "user-sb3-wm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/sb3_wm.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    sb3_wm_prog.linker_script = b.path("user/linker.ld");
    const sb3_wm_step = b.step("sb3wm", "Build the fifty-second ESP user program (zig-out/bin/SB3WM.BIN)");
    const sb3_wm_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    sb3_wm_elf2bin.addFileArg(sb3_wm_prog.getEmittedBin());
    const sb3_wm_bin = sb3_wm_elf2bin.addOutputFileArg("SB3WM.BIN");
    sb3_wm_elf2bin.has_side_effects = true;
    sb3_wm_elf2bin.stdio = .inherit;
    sb3_wm_step.dependOn(&sb3_wm_elf2bin.step);
    const install_sb3_wm = b.addInstallFileWithDir(sb3_wm_bin, .bin, "SB3WM.BIN");
    b.getInstallStep().dependOn(&install_sb3_wm.step);

    const sb3_own_prog = b.addExecutable(.{
        .name = "user-sb3-own",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/sb3_own.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    sb3_own_prog.linker_script = b.path("user/linker.ld");
    const sb3_own_step = b.step("sb3own", "Build the fifty-third ESP user program (zig-out/bin/SB3OWN.BIN)");
    const sb3_own_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    sb3_own_elf2bin.addFileArg(sb3_own_prog.getEmittedBin());
    const sb3_own_bin = sb3_own_elf2bin.addOutputFileArg("SB3OWN.BIN");
    sb3_own_elf2bin.has_side_effects = true;
    sb3_own_elf2bin.stdio = .inherit;
    sb3_own_step.dependOn(&sb3_own_elf2bin.step);
    const install_sb3_own = b.addInstallFileWithDir(sb3_own_bin, .bin, "SB3OWN.BIN");
    b.getInstallStep().dependOn(&install_sb3_own.step);

    // ------------------------------------------------------------------
    // Guest: fifty-fourth ESP user program (M33 SB4, claim 2382)
    // SB4DAM.BIN — the rect-granular damage proof behind
    // verify-live-sb4-damage-tracking.sh: a migrated-free app fills two rects
    // into its window (the kernel-visible fill path, which KNOWS the rect), so
    // they coalesce into ONE union damage rect; the compositor repaints ONLY
    // that union (dui's `last=` column), proving one-fill -> one-rect repaint.
    // ------------------------------------------------------------------
    const sb4dam_prog = b.addExecutable(.{
        .name = "user-sb4dam",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/sb4dam.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    sb4dam_prog.linker_script = b.path("user/linker.ld");
    const sb4dam_step = b.step("sb4dam", "Build the fifty-fourth ESP user program (zig-out/bin/SB4DAM.BIN)");
    const sb4dam_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    sb4dam_elf2bin.addFileArg(sb4dam_prog.getEmittedBin());
    const sb4dam_bin = sb4dam_elf2bin.addOutputFileArg("SB4DAM.BIN");
    sb4dam_elf2bin.has_side_effects = true;
    sb4dam_elf2bin.stdio = .inherit;
    sb4dam_step.dependOn(&sb4dam_elf2bin.step);
    const install_sb4dam = b.addInstallFileWithDir(sb4dam_bin, .bin, "SB4DAM.BIN");
    b.getInstallStep().dependOn(&install_sb4dam.step);

    // ------------------------------------------------------------------
    // Guest: fifty-fifth ESP user program (M33 SB5, claim 7397)
    // SB5WM.BIN — the registered-WM half of the WM compose-N + one final
    // present proof: registers, binds the scanout writable (the SB5 grant),
    // peers the migrated surface RO, COMPOSES it into the scanout, reads
    // the byte back from the scanout, issues the FINAL present (flush only).
    // ------------------------------------------------------------------
    const sb5_wm_prog = b.addExecutable(.{
        .name = "user-sb5wm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/sb5_wm.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    sb5_wm_prog.linker_script = b.path("user/linker.ld");
    const sb5_wm_step = b.step("sb5wm", "Build the fifty-fifth ESP user program (zig-out/bin/SB5WM.BIN)");
    const sb5_wm_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    sb5_wm_elf2bin.addFileArg(sb5_wm_prog.getEmittedBin());
    const sb5_wm_bin = sb5_wm_elf2bin.addOutputFileArg("SB5WM.BIN");
    sb5_wm_elf2bin.has_side_effects = true;
    sb5_wm_elf2bin.stdio = .inherit;
    sb5_wm_step.dependOn(&sb5_wm_elf2bin.step);
    const install_sb5_wm = b.addInstallFileWithDir(sb5_wm_bin, .bin, "SB5WM.BIN");
    b.getInstallStep().dependOn(&install_sb5_wm.step);

    // ------------------------------------------------------------------
    // Guest: fifty-sixth ESP user program (M33 SB5, claim 7397)
    // SB5OWN.BIN — the migrated-app half: opens a window, binds a shared
    // surface, renders with PLAIN STORES ONLY (never sys_win_fill), and
    // hands the surface to the WM for compose-N. The gate observes ZERO
    // slot-13 fill SVCs via the `syscalls` monitor.
    // ------------------------------------------------------------------
    const sb5_own_prog = b.addExecutable(.{
        .name = "user-sb5own",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/sb5_own.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    sb5_own_prog.linker_script = b.path("user/linker.ld");
    const sb5_own_step = b.step("sb5own", "Build the fifty-sixth ESP user program (zig-out/bin/SB5OWN.BIN)");
    const sb5_own_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    sb5_own_elf2bin.addFileArg(sb5_own_prog.getEmittedBin());
    const sb5_own_bin = sb5_own_elf2bin.addOutputFileArg("SB5OWN.BIN");
    sb5_own_elf2bin.has_side_effects = true;
    sb5_own_elf2bin.stdio = .inherit;
    sb5_own_step.dependOn(&sb5_own_elf2bin.step);
    const install_sb5_own = b.addInstallFileWithDir(sb5_own_bin, .bin, "SB5OWN.BIN");
    b.getInstallStep().dependOn(&install_sb5_own.step);

    // ------------------------------------------------------------------
    // Guest: fifty-seventh ESP user program (M33 SB6, claim 6864)
    // SB6WM.BIN — the registered-WM half of the perf-payoff measurement:
    // registers, binds the scanout writable, peers the migrated surface
    // RO, COMPOSES it into the scanout COUNTING every copied byte (the
    // compose-N copy volume: 256*192*4 = 196,608), reads the byte back,
    // issues the FINAL present (flush only), acks the owner.
    // ------------------------------------------------------------------
    const sb6_wm_prog = b.addExecutable(.{
        .name = "user-sb6wm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/sb6_wm.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    sb6_wm_prog.linker_script = b.path("user/linker.ld");
    const sb6_wm_step = b.step("sb6wm", "Build the fifty-seventh ESP user program (zig-out/bin/SB6WM.BIN)");
    const sb6_wm_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    sb6_wm_elf2bin.addFileArg(sb6_wm_prog.getEmittedBin());
    const sb6_wm_bin = sb6_wm_elf2bin.addOutputFileArg("SB6WM.BIN");
    sb6_wm_elf2bin.has_side_effects = true;
    sb6_wm_elf2bin.stdio = .inherit;
    sb6_wm_step.dependOn(&sb6_wm_elf2bin.step);
    const install_sb6_wm = b.addInstallFileWithDir(sb6_wm_bin, .bin, "SB6WM.BIN");
    b.getInstallStep().dependOn(&install_sb6_wm.step);

    // ------------------------------------------------------------------
    // Guest: fifty-eighth ESP user program (M33 SB6, claim 6864)
    // SB6OLD.BIN — the PRE-seam-B control: opens a window and renders the
    // same 8x8 grid (static + 8 dynamic redraws) with sys_win_fill (slot
    // 13) = 576 fill SVCs + 9 presents (kernel blits). The "before"
    // number the gate compares against SB6NEW's zero-fill seam-B path.
    // ------------------------------------------------------------------
    const sb6_old_prog = b.addExecutable(.{
        .name = "user-sb6old",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/sb6_old.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    sb6_old_prog.linker_script = b.path("user/linker.ld");
    const sb6_old_step = b.step("sb6old", "Build the fifty-eighth ESP user program (zig-out/bin/SB6OLD.BIN)");
    const sb6_old_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    sb6_old_elf2bin.addFileArg(sb6_old_prog.getEmittedBin());
    const sb6_old_bin = sb6_old_elf2bin.addOutputFileArg("SB6OLD.BIN");
    sb6_old_elf2bin.has_side_effects = true;
    sb6_old_elf2bin.stdio = .inherit;
    sb6_old_step.dependOn(&sb6_old_elf2bin.step);
    const install_sb6_old = b.addInstallFileWithDir(sb6_old_bin, .bin, "SB6OLD.BIN");
    b.getInstallStep().dependOn(&install_sb6_old.step);

    // ------------------------------------------------------------------
    // Guest: fifty-ninth ESP user program (M33 SB6, claim 6864)
    // SB6NEW.BIN — the SEAM-B half: the SAME grid rendered with PLAIN
    // STORES into a bound shared surface (zero sys_win_fill), then hands
    // {owner_pid, handle, magic} to the registered WM which compose-N's
    // the surface into the scanout. The gate's syscalls diff proves
    // ZERO additional slot-13 fills after the control phase.
    // ------------------------------------------------------------------
    const sb6_new_prog = b.addExecutable(.{
        .name = "user-sb6new",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/sb6_new.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    sb6_new_prog.linker_script = b.path("user/linker.ld");
    const sb6_new_step = b.step("sb6new", "Build the fifty-ninth ESP user program (zig-out/bin/SB6NEW.BIN)");
    const sb6_new_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    sb6_new_elf2bin.addFileArg(sb6_new_prog.getEmittedBin());
    const sb6_new_bin = sb6_new_elf2bin.addOutputFileArg("SB6NEW.BIN");
    sb6_new_elf2bin.has_side_effects = true;
    sb6_new_elf2bin.stdio = .inherit;
    sb6_new_step.dependOn(&sb6_new_elf2bin.step);
    const install_sb6_new = b.addInstallFileWithDir(sb6_new_bin, .bin, "SB6NEW.BIN");
    b.getInstallStep().dependOn(&install_sb6_new.step);

    // ------------------------------------------------------------------
    // Guest: Sexiburger standalone component (Milestone 19 — issue #677)
    // SEXIBURG.BIN. The Sexiburger god menu standalone component & harness.
    // ------------------------------------------------------------------
    const sexiburg_prog = b.addExecutable(.{
        .name = "user-sexiburg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/sexiburger.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    sexiburg_prog.linker_script = b.path("user/linker-segmented.ld");
    const sexiburg_step = b.step("sexiburg", "Build the Sexiburger standalone program (zig-out/bin/SEXIBURG.BIN) — DSK3 segmented");
    const sexiburg_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py", "--segments" });
    sexiburg_elf2bin.addFileArg(sexiburg_prog.getEmittedBin());
    const sexiburg_bin = sexiburg_elf2bin.addOutputFileArg("SEXIBURG.BIN");
    sexiburg_elf2bin.has_side_effects = true;
    sexiburg_elf2bin.stdio = .inherit;
    sexiburg_step.dependOn(&sexiburg_elf2bin.step);
    const install_sexiburg = b.addInstallFileWithDir(sexiburg_bin, .bin, "SEXIBURG.BIN");
    sexiburg_step.dependOn(&install_sexiburg.step);
    b.getInstallStep().dependOn(&install_sexiburg.step);

    // ------------------------------------------------------------------
    // M71h (#1567): VIEW.BIN (the M36 IMG5 raster image viewer, issue #826,
    // claim 4574) is RETIRED with user/src/view.zig. Its Go successor is
    // GOVIEW.ELF (user/go/view, built by tools/go/build-goview.sh) — a
    // host-share ELF like GOFILES.ELF, not an in-image Zig program, so there is
    // no build step to replace this one. The live-image-viewer gate stages
    // GOVIEW.ELF instead and keeps both fixtures: QOI decodes on the guest
    // through webrender (reused, not re-vendored), PNG proves the honest error
    // surface because the fork has no in-guest PNG decoder yet
    // (user/go/webrender/image_png_guest.go).
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // M99c (#2181): GOSOUND.ELF (user/go/sound, built by
    // tools/go/build-gosound.sh) is the WAV player for the `audio` mime
    // type — another host-share ELF, so there is no Zig build step here
    // either. It parses RIFF/WAVE and streams through M99b's mixer client
    // (vi.AudioStream, slot 43); virelai/mime's init names it the Audio
    // handler so GOFILES' open path reaches it. The live-sound-playback
    // gate stages GOSOUND.ELF beside PCM.BIN and asserts its post-resample
    // stream counters against the fixture's declared frame count.
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // M71i (#1568): DOC.BIN (the M-web in-guest HTML viewer, issues
    // #1202–#1207, ADR 0028) is RETIRED with user/src/doc.zig. The EL0 HTML
    // consumer is WEB.ELF (`user/go/browser`, built by
    // tools/go/build-web.sh) — one renderer, per ADR 0030's dual-toolkit rule
    // and the M71i amendment to ADR 0028 (D1/D3). `user/src/lib/html/`
    // (parse/layout/url + their host tests) went with it: Go's
    // `user/go/webrender` owns parse/layout/paint now, and it is host-tested
    // harder than the Zig modules were (golden corpus, layout, text, url).
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Guest: Sexiburger Action & Tab test app (Milestone 19 — issues #701, #705, #782)
    // SEXITEST.BIN. Live end-to-end action registration and tab model test.
    // ------------------------------------------------------------------
    const sexitest_mod = b.createModule(.{
        .root_source_file = b.path("user/src/sexitest.zig"),
        .target = kernel_target,
        .optimize = .ReleaseSmall,
    });
    sexitest_mod.addAnonymousImport("wnd_core", .{ .root_source_file = b.path("kernel/src/wnd_core.zig") });
    const sexitest_prog = b.addExecutable(.{
        .name = "user-sexitest",
        .root_module = sexitest_mod,
    });
    sexitest_prog.linker_script = b.path("user/linker.ld");
    const sexitest_step = b.step("sexitest", "Build the Sexiburger Action & Tab test program (zig-out/bin/SEXITEST.BIN)");
    const sexitest_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    sexitest_elf2bin.addFileArg(sexitest_prog.getEmittedBin());
    const sexitest_bin = sexitest_elf2bin.addOutputFileArg("SEXITEST.BIN");
    sexitest_elf2bin.has_side_effects = true;
    sexitest_elf2bin.stdio = .inherit;
    sexitest_step.dependOn(&sexitest_elf2bin.step);
    const install_sexitest = b.addInstallFileWithDir(sexitest_bin, .bin, "SEXITEST.BIN");
    sexitest_step.dependOn(&install_sexitest.step);
    b.getInstallStep().dependOn(&install_sexitest.step);

    // TABHOLD.BIN. M37 DQ2 (issue #840) tab-strip live-gate holder: opens a
    // window, attaches it as a tab of window 2, and parks holding the
    // attachment so the gate can snapshot the painted strip (rides
    // zig-out/bin into the gate share; no image change).
    const tabhold_mod = b.createModule(.{
        .root_source_file = b.path("user/src/tabhold.zig"),
        .target = kernel_target,
        .optimize = .ReleaseSmall,
    });
    tabhold_mod.addAnonymousImport("wnd_core", .{ .root_source_file = b.path("kernel/src/wnd_core.zig") });
    const tabhold_prog = b.addExecutable(.{
        .name = "user-tabhold",
        .root_module = tabhold_mod,
    });
    tabhold_prog.linker_script = b.path("user/linker.ld");
    const tabhold_step = b.step("tabhold", "Build the DQ2 tab-strip holder program (zig-out/bin/TABHOLD.BIN)");
    const tabhold_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    tabhold_elf2bin.addFileArg(tabhold_prog.getEmittedBin());
    const tabhold_bin = tabhold_elf2bin.addOutputFileArg("TABHOLD.BIN");
    tabhold_elf2bin.has_side_effects = true;
    tabhold_elf2bin.stdio = .inherit;
    tabhold_step.dependOn(&tabhold_elf2bin.step);
    const install_tabhold = b.addInstallFileWithDir(tabhold_bin, .bin, "TABHOLD.BIN");
    tabhold_step.dependOn(&install_tabhold.step);
    b.getInstallStep().dependOn(&install_tabhold.step);

    // ------------------------------------------------------------------
    // Top-level steps. System-command steps are marked as having side
    // effects (and inherit stdio) so they always execute instead of being
    // skipped by the build cache. (No QEMU path: this project targets Apple
    // Virtualization.framework only.)
    // ------------------------------------------------------------------
    const image_step = b.step("image", "Create the FAT32+GPT boot disk image at artifacts/disk.img (class A gate)");
    const image = b.addSystemCommand(&.{ "bash", "image/make-image.sh" });
    image.addFileArg(efi.getEmittedBin());
    image.addArg("artifacts/disk.img");
    image.addFileArg(kernel_bin); // make-image.sh: [EFI_BIN] [IMAGE] [KERNEL_BIN]
    // M34 HF6 (issue #740): the image is a BOOT VOLUME ONLY — EFI +
    // KERNEL.BIN, no embedded apps (they live in the host share; see the
    // gate_seed_share helper in tools/lib/gate-run.sh). The user programs
    // above still BUILD into zig-out/bin for the share bundle; they are
    // simply not embedded anymore.
    image.has_side_effects = true;
    image.stdio = .inherit;
    image_step.dependOn(&image.step);

    const inspect_step = b.step("inspect", "Inspect the EFI binary and the disk image (class A gate)");
    const inspect = b.addSystemCommand(&.{ "bash", "tools/inspect.sh" });
    inspect.addFileArg(efi.getEmittedBin());
    inspect.addArg("artifacts/disk.img");
    inspect.has_side_effects = true;
    inspect.stdio = .inherit;
    inspect_step.dependOn(&inspect.step);

    const failure_step = b.step("bad-handoff", "Build a deliberately corrupted handoff image for the pre-exit failure-path test (class A tooling; feeds the class B bad-handoff gate)");
    const failure_image = b.addSystemCommand(&.{ "bash", "image/make-image.sh" });
    failure_image.addFileArg(efi.getEmittedBin());
    failure_image.addArg("artifacts/bad-handoff.img");
    failure_image.addFileArg(kernel_bin); // HF6: same two-file boot volume
    failure_image.has_side_effects = true;
    failure_image.stdio = .inherit;
    failure_step.dependOn(&failure_image.step);

    const run_step = b.step("run", "Boot the disk image with the Swift Virtualization.framework runner (class B — live serial takeover gate, claim 0002; Apple silicon only; PASSING since claim 1517)");
    const run = b.addSystemCommand(&.{ "bash", "-c", run_vm_command });
    run.step.dependOn(&image.step);
    run.has_side_effects = true;
    run.stdio = .inherit;
    run_step.dependOn(&run.step);

    // macOS 27 spike (capability-audit step 3): boot with one custom virtio
    // device attached (--custom-virtio) so the guest's PCI discovery can
    // observe it on a real VZ boot. The runner prints the host-side
    // CUSTOM-VIRTIO evidence to stdout; guest-side discovery evidence still
    // needs a kernel PCI dump (the audit's next slice).
    const spike_virtio_step = b.step("spike-virtio", "Boot the disk image with the custom virtio spike device attached (macOS 27 capability-audit step 3; class B; Apple silicon only)");
    const spike_virtio = b.addSystemCommand(&.{ "bash", "-c", spike_virtio_vm_command });
    spike_virtio.step.dependOn(&image.step);
    spike_virtio.has_side_effects = true;
    spike_virtio.stdio = .inherit;
    spike_virtio_step.dependOn(&spike_virtio.step);

    const console_step = b.step("console", "Boot the disk image and open an interactive host serial console (class C — interactive/manual hardware gate; Apple silicon only)");
    const console = b.addSystemCommand(&.{ "bash", "-c", console_vm_command });
    console.step.dependOn(&image.step);
    console.has_side_effects = true;
    console.stdio = .inherit;
    console_step.dependOn(&console.step);

    // Interactive desktop session (class C — a human at the keyboard): the
    // windowed GPU + USB-input front door. Seeds the persistent host share
    // (M34 HF6 removed the apps from the image), attaches GPU + keyboard +
    // pointer, stages the Go seat, and lets the M59 (issue #1298) boot
    // default seat it via /host/.virelairc. Apple silicon + macOS 27 only;
    // never run in CI (tools/session.sh owns the detail).
    const session_step = b.step("session", "Boot an interactive windowed VirelaiOS desktop (class C — human session; Apple silicon + macOS 27 only)");
    const session = b.addSystemCommand(&.{ "bash", "tools/session.sh" });
    session.step.dependOn(&image.step);
    session.has_side_effects = true;
    session.stdio = .inherit;
    session_step.dependOn(&session.step);

    const context_step = b.step("context", "Regenerate artifacts/context.md (deterministic project snapshot; class A gate)");
    const context = b.addSystemCommand(&.{ "bash", "tools/context/build-context.sh" });
    context.has_side_effects = true;
    context.stdio = .inherit;
    context_step.dependOn(&context.step);

    // ADR 0004 D4 fixed-memory-marker fallback (status.md gate work item 3):
    // boot the VM and save the host-side NVRAM marker ladder (the kernel
    // persists each takeover stage as the EFI variable `VirelaiM2`, which
    // runtime SetVariable keeps alive past ExitBootServices on VZ). The gate
    // here is the marker channel, not the serial channel: the runner exits 0
    // iff an M2_* marker was found. The hard gate lives in
    // tools/verify-marker.sh (`just verify-marker`).
    const marker_step = b.step("marker", "Boot the disk image and save the host-side kernel marker dump (ADR 0004 D4 fallback; class B mechanism behind tools/verify-marker.sh; Apple silicon only)");
    const marker = b.addSystemCommand(&.{ "bash", "-c", marker_vm_command });
    marker.step.dependOn(&image.step);
    marker.has_side_effects = true;
    marker.stdio = .inherit;
    marker_step.dependOn(&marker.step);

    // M1.5 march step 19: automated transcript test. No VM, no live RX —
    // the shell's mock-fed e2e test asserts the exact `virelai>` transcript
    // in-test and emits the captured bytes to artifacts/, which this gate
    // diffs byte-for-byte against the canonical fixture
    // tests/transcript-console.txt. The live vm-serial.log assertion stays
    // gated on the VZ serial gate (claim 0002).
    // ------------------------------------------------------------------
    // Host: Unified Unit Tests (M41 TS1, issue #952)
    // ------------------------------------------------------------------
    const test_step = b.step("test", "Run host-side unit tests in parallel (M41 TS1)");
    const elf2bin_checks = b.addSystemCommand(&.{ "python3", "tools/tests/test_elf2bin.py" });
    elf2bin_checks.has_side_effects = true;
    test_step.dependOn(&elf2bin_checks.step);
    const zig_guest_checks = b.addSystemCommand(&.{ "python3", "tools/tests/test_zig_guest.py" });
    test_step.dependOn(&zig_guest_checks.step);
    const thread_tls_checks = b.addSystemCommand(&.{ "python3", "-B", "tools/tests/test_zig_thread_tls.py" });
    thread_tls_checks.has_side_effects = true;
    test_step.dependOn(&thread_tls_checks.step);
    const zig_guest_step = b.step("zig-guest-check", "Rebuild the pinned SDK twice; check ELF, startup, allocator and native std boundary (fetch archive first)");
    const zig_guest_integration = b.addSystemCommand(&.{ "python3", "tools/tests/test_zig_guest.py", "--integration" });
    zig_guest_integration.has_side_effects = true;
    zig_guest_integration.stdio = .inherit;
    zig_guest_step.dependOn(&zig_guest_integration.step);
    const thread_tls_integration = b.addSystemCommand(&.{ "python3", "-B", "tools/tests/test_zig_thread_tls.py", "--integration" });
    thread_tls_integration.has_side_effects = true;
    thread_tls_integration.stdio = .inherit;
    // Share the checked compiler only after the existing SDK materializer finishes.
    thread_tls_integration.step.dependOn(&zig_guest_integration.step);
    zig_guest_step.dependOn(&thread_tls_integration.step);
    const native_network_integration = b.addSystemCommand(&.{ "python3", "-B", "tools/zig/network.py" });
    native_network_integration.has_side_effects = true;
    native_network_integration.stdio = .inherit;
    native_network_integration.step.dependOn(&thread_tls_integration.step);
    zig_guest_step.dependOn(&native_network_integration.step);

    // C3's closed, pinned no-libc build is opt-in; only its fetch command
    // accesses the network. Do not route it through Boris's hosted build.zig.
    const boris_tests = b.addSystemCommand(&.{ "python3", "-B", "-m", "unittest", "discover", "-s", "tools/zig/boris", "-p", "test_*.py" });
    boris_tests.has_side_effects = true;
    test_step.dependOn(&boris_tests.step);
    const boris_guest_step = b.step("boris-guest", "Build/install serial offline BORIS.BIN (fetch pinned inputs first)");
    const boris_guest = b.addSystemCommand(&.{ "python3", "-B", "tools/zig/boris/build.py", "guest", "--output" });
    const boris_bin = boris_guest.addOutputFileArg("BORIS.BIN");
    boris_guest.has_side_effects = true;
    boris_guest.stdio = .inherit;
    const boris_install = b.addInstallFileWithDir(boris_bin, .bin, "BORIS.BIN");
    boris_guest_step.dependOn(&boris_install.step);
    const boris_check_step = b.step("boris-check", "Check pinned compiler bytes, tests and two offline no-libc builds");
    const boris_check = b.addSystemCommand(&.{ "python3", "-B", "tools/zig/boris/check.py" });
    boris_check.has_side_effects = true;
    boris_check.stdio = .inherit;
    boris_check_step.dependOn(&boris_check.step);

    const core_test_sources = [_][]const u8{
        "user/zig/runtime.zig",
        "boot/src/efi_time.zig",
        "kernel/src/alloc.zig",
        "kernel/src/app_timers.zig",
        "kernel/src/arp.zig",
        "kernel/src/console.zig",
        "kernel/src/csprng.zig",
        "kernel/src/dhcp.zig",
        "kernel/src/dns.zig",
        "kernel/src/driving_award.zig",
        "kernel/src/events.zig",
        "kernel/src/exec.zig",
        "kernel/src/exceptions.zig",
        "kernel/src/fat32_ro.zig",
        "kernel/src/font8x8.zig",
        "kernel/src/gic.zig",
        // M102b1 (issue #2162): the GPU3D render channel — the pinned
        // wire contract plus the transport/context lifecycle against a
        // fake-device transcript (class A; the VZ render is a later card).
        "kernel/src/gpu3d_device.zig",
        // M111b (issue #2409): the compute broker behind slot 90 — its
        // fake-device transcripts pin the session/buffer/RUN lifecycle
        // and every named refusal (class A).
        "kernel/src/gpu3d_compute.zig",
        "kernel/src/gpu3d_wire.zig",
        // M113c (issue #2419, ADR 0054 Part II): the grant table — its
        // host tests pin the fail-closed parse, the stale-hash refusal,
        // the table bound, and the no-widening contract (class A).
        "kernel/src/grant.zig",
        "kernel/src/handoff.zig",
        "kernel/src/input.zig",
        "kernel/src/ipv4.zig",
        // M117b (issue #2474, ADR 0057): the v6 datapath — header
        // parse/build, the address set, the pseudo-header checksum; and
        // the NDP half — NS/NA/RS/RA builders, the bounded table,
        // solicited-only learning, the RA acceptance walk, the tick-seam
        // DAD/RS drive (class A).
        "kernel/src/ipv6.zig",
        "kernel/src/lineedit.zig",
        "kernel/src/machine.zig",
        "kernel/src/mailbox.zig",
        "kernel/src/measure.zig",
        "kernel/src/memmap.zig",
        "kernel/src/mmu.zig",
        "kernel/src/monitor.zig",
        "kernel/src/ndp.zig",
        "kernel/src/nvram_console.zig",
        "kernel/src/process.zig",
        "kernel/src/psci.zig",
        "kernel/src/redirect.zig",
        "kernel/src/road_pops.zig",
        "kernel/src/scheduler.zig",
        "kernel/src/scrollback.zig",
        "kernel/src/secret.zig",
        "kernel/src/settings.zig",
        "kernel/src/shared_region.zig",
        "kernel/src/shell.zig",
        "kernel/src/smp.zig",
        "kernel/src/spinlock.zig",
        "kernel/src/svclock.zig",
        "kernel/src/syscall.zig",
        "kernel/src/tcp.zig",
        "kernel/src/terminal.zig",
        "kernel/src/terminal_corpus.zig",
        "kernel/src/trust.zig",
        "kernel/src/text.zig",
        "kernel/src/thread_tls.zig",
        "kernel/src/timer.zig",
        "kernel/src/tokenizer.zig",
        "kernel/src/uaccess.zig",
        "kernel/src/udp.zig",
        "kernel/src/userspace.zig",
        // M100c (issue #2308, ADR 0050): the VLFS read half — golden-fixture
        // mount/lookup/read/readdir parity with tools/go/vlfs.
        "kernel/src/vlfs/vlfs.zig",
        "kernel/src/virtio_console.zig",
        "kernel/src/virtio_custom.zig",
        "kernel/src/virtio_entropy.zig",
        "kernel/src/virtio_file.zig",
        "kernel/src/virtio_fs.zig",
        "kernel/src/virtio_gpu.zig",
        "kernel/src/virtio_net.zig",
        "kernel/src/wm_server.zig",
        "kernel/src/wnd_core.zig",
        "kernel/src/xhci.zig",
        "user/src/lib/ui.zig",
        "user/src/lib/tty.zig",
        "user/src/lib/shell.zig",
        "user/src/lib/startup.zig",
        "user/src/lib/toolbox.zig",
        "user/src/lib/pipe.zig",
        "user/src/lib/script.zig",
        "user/src/lib/netauth.zig",
        "user/src/lib/crypto.zig",
        // M71i (#1568): user/src/lib/html/{parse,layout,url}.zig are deleted
        // with DOC.BIN — the modules' 21 host tests went with them, and the
        // surviving renderer's own suites (user/go/webrender: htmlparse,
        // layout, text, url, golden) carry the parse/layout claims.
        "user/src/lib/ssh/wire.zig",
        "user/src/lib/ssh/packet.zig",
        "user/src/lib/ssh/stream.zig",
        "user/src/el0exec.zig",
        // M70e (#1457): the wasm loader's own test blocks (41 before the
        // contract-v2 negatives) had no runner — the module was only built as
        // WASM.BIN, so nothing in the fleet executed them. Registering the
        // module as a host test root is what makes the §9 capability and
        // admission negatives evidence rather than prose.
        "user/src/wasm.zig",
        // M70c S3 (#1455): same gap in the in-guest compiler — zc.zig's own
        // test blocks (45 before the break/continue ones) were only ever
        // compiled into ZC.BIN, so nothing in the fleet ran them. The compiler
        // that the Z4 corpus gate trusts was the least-tested module in it.
        "user/src/zc.zig",
        // X.509 layer (card TLS13-C3): the strict DER reader, the certificate
        // parser, PEM decoding and hostname/identity matching. None of these
        "user/tests/ui/ui_test.zig",
        "kernel/tests/scheduler_test.zig",
        "kernel/tests/syscall_test.zig",
        "kernel/tests/service_lock_test.zig",
        "kernel/tests/lock_order_test.zig",
        "kernel/tests/trace_test.zig",
        "kernel/tests/sampler_test.zig",
        "kernel/tests/memstat_test.zig",
        "kernel/tests/monitor_test.zig",
        "kernel/tests/shell_test.zig",
        "kernel/tests/alloc_test.zig",
        "kernel/tests/pcm_stream_test.zig",
        // M70a (#1453): the seeded fuzz fleet — the syscall-seam sweep plus the
        // HF-wire mutation corpus. Class A only (no VM, no device).
        "kernel/tests/fuzz_test.zig",
        "kernel/tests/net/tcp_test.zig",
        "kernel/tests/net/socket_core_test.zig",
        "kernel/tests/net/dhcp_test.zig",
        "kernel/tests/driving_award_test.zig",
        "test/helpers/helpers.zig",
    };

    const ui_mod = b.createModule(.{
        .root_source_file = b.path("user/src/lib/ui.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    ui_mod.addOptions("build_options", kernel_options);

    // Module-mapped userland library roots (M51 SSH2): `ssh/` files are
    // unit-test module roots themselves, so their `../lib` deps arrive as
    // mapped modules exactly like `ui` does.
    const crypto_mod = b.createModule(.{
        .root_source_file = b.path("user/src/lib/crypto.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    crypto_mod.addOptions("build_options", kernel_options);

    const rng_mod = b.createModule(.{
        .root_source_file = b.path("user/src/lib/rng.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    // rng.zig imports the mapped `ui` module; without the mapping its
    // `@import("ui")` cannot resolve (the SSH.BIN graph loads rng.zig as its
    // own module alongside the real ui module).
    rng_mod.addImport("ui", ui_mod);
    rng_mod.addOptions("build_options", kernel_options);

    const helpers_mod = b.createModule(.{
        .root_source_file = b.path("test/helpers/helpers.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    helpers_mod.addOptions("build_options", kernel_options);

    // M70a (#1453): the HF-wire fixtures the fuzz root mutates, embedded as a
    // build option of THAT root only — the checked-in bytes cannot drift from
    // what the fuzz corpus feeds the decoders, and the kernel image never
    // carries fixture data.
    // M70c S3 (#1455): the zc corpus fixture, embedded as a build option of
    // the zc test root only, for the same reason — the source the class-B gate
    // stages must be the source the in-guest compiler is unit-tested against.
    const zc_corpus_options = b.addOptions();
    zc_corpus_options.addOption([]const u8, "s3_break", @embedFile("tests/zc-corpus/s3-break.z"));

    const fuzz_fixture_options = b.addOptions();
    fuzz_fixture_options.addOption([]const u8, "vf_pattern_32k", @embedFile("tests/vf-pattern-32k.bin"));
    fuzz_fixture_options.addOption([]const u8, "vf_req_read", @embedFile("tests/vf-req-read.bin"));
    fuzz_fixture_options.addOption([]const u8, "vf_reply_read", @embedFile("tests/vf-reply-read.bin"));
    fuzz_fixture_options.addOption([]const u8, "vf_reply_list", @embedFile("tests/vf-reply-list.bin"));

    const scheduler_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/scheduler.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    scheduler_mod.addOptions("build_options", kernel_options);

    const syscall_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/syscall.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    syscall_mod.addOptions("build_options", kernel_options);

    const monitor_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/monitor.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    monitor_mod.addOptions("build_options", kernel_options);

    const shell_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/shell.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    shell_mod.addOptions("build_options", kernel_options);

    const alloc_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/alloc.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    alloc_mod.addOptions("build_options", kernel_options);

    const tcp_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/tcp.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    tcp_mod.addOptions("build_options", kernel_options);

    const socket_core_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/socket_core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    const dhcp_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/dhcp.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    dhcp_mod.addOptions("build_options", kernel_options);

    const driving_award_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/driving_award.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    driving_award_mod.addOptions("build_options", kernel_options);

    // TLS 1.3 client (ADR 0029 D8). The library is not yet linked into any
    // guest binary, so this flag is the entire rollback surface: with
    // -Dtls_client=false the TLS roots are not built or tested and every other
    // gate is unaffected.
    const tls_client_enabled = b.option(bool, "tls_client", "Build and test the in-tree TLS 1.3 client") orelse true;
    const tls_test_sources = [_][]const u8{
        // The TCP seam adapter is host-testable (its Ops seam is injected), so
        // it runs here even though its guest entry point needs sys_tcp_*.
        "user/src/lib/tls/stream.zig",
        "user/src/lib/tls/keyschedule.zig",
        "user/src/lib/tls/record.zig",
        "user/src/lib/tls/der.zig",
        "user/src/lib/tls/pem.zig",
        "user/src/lib/tls/x509.zig",
        "user/src/lib/tls/identity.zig",
        "user/src/lib/tls/bigint.zig",
        "user/src/lib/tls/rsa.zig",
        "user/src/lib/tls/ecdsa.zig",
        "user/src/lib/tls/trust_store.zig",
        "user/src/lib/tls/vendored_roots.zig",
        "user/src/lib/tls/target.zig",
        "user/src/lib/tls/validate.zig",
    };
    var test_source_buf: [core_test_sources.len + tls_test_sources.len][]const u8 = undefined;
    var test_source_len: usize = 0;
    for (core_test_sources) |s| {
        test_source_buf[test_source_len] = s;
        test_source_len += 1;
    }
    if (tls_client_enabled) {
        for (tls_test_sources) |s| {
            test_source_buf[test_source_len] = s;
            test_source_len += 1;
        }
    }
    const unit_test_sources = test_source_buf[0..test_source_len];

    for (unit_test_sources) |src_path| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(src_path),
            .target = b.graph.host,
            .optimize = .Debug,
        });
        if (std.mem.eql(u8, src_path, "kernel/tests/pcm_stream_test.zig")) {
            test_mod.addImport("pcm_stream", b.createModule(.{
                .root_source_file = b.path("kernel/src/pcm_stream.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }));
        }
        test_mod.addOptions("build_options", kernel_options);
        // The fuzz root is the only one that reads the wire fixtures.
        if (std.mem.eql(u8, src_path, "kernel/tests/fuzz_test.zig")) {
            test_mod.addOptions("fuzz_fixtures", fuzz_fixture_options);
        }
        // Likewise the zc root is the only one that reads the corpus fixture.
        if (std.mem.eql(u8, src_path, "user/src/zc.zig")) {
            test_mod.addOptions("zc_corpus_fixtures", zc_corpus_options);
        }
        test_mod.addImport("ui", ui_mod);
        test_mod.addImport("crypto", crypto_mod);
        test_mod.addImport("rng", rng_mod);
        test_mod.addImport("helpers", helpers_mod);
        test_mod.addImport("scheduler", scheduler_mod);
        test_mod.addImport("syscall", syscall_mod);
        test_mod.addImport("monitor", monitor_mod);
        test_mod.addImport("shell", shell_mod);
        test_mod.addImport("alloc", alloc_mod);
        test_mod.addImport("tcp", tcp_mod);
        if (std.mem.eql(u8, src_path, "kernel/tests/net/socket_core_test.zig")) {
            test_mod.addImport("socket_core", socket_core_mod);
        }
        test_mod.addImport("dhcp", dhcp_mod);
        test_mod.addImport("driving_award", driving_award_mod);
        const t = b.addTest(.{
            .root_module = test_mod,
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
        if (std.mem.eql(u8, src_path, "user/zig/runtime.zig") or
            std.mem.eql(u8, src_path, "kernel/src/thread_tls.zig"))
        {
            zig_guest_step.dependOn(&run_t.step);
        }
    }

    const test_console_step = b.step("test-console", "Run the automated 'virelai>' transcript test (M1.5 march step 19; class A — mock console, no VM)");
    const test_console = b.addSystemCommand(&.{ "bash", "tools/verify-transcript.sh" });
    test_console.has_side_effects = true;
    test_console.stdio = .inherit;
    test_console_step.dependOn(&test_console.step);

    // Claim 0015: NVRAM console channel. `zig build nvram-console` rebuilds
    // the image with `-Dnvram-console=true` and boots it, reconstructing
    // the post-exit console stream from the EFI variable store. The hard
    // gate with substring assertions lives in tools/verify-nvram-console.sh
    // (`just verify-nvram-console`). Apple silicon only (VZ VM).
    const nvram_console_step = b.step("nvram-console", "Boot the -Dnvram-console=true image and reconstruct the post-exit NVRAM console stream (class B mechanism behind tools/verify-nvram-console.sh; claim 0015; Apple silicon only)");
    const nvram_console_run = b.addSystemCommand(&.{ "bash", "-c", nvram_console_vm_command });
    nvram_console_run.has_side_effects = true;
    nvram_console_run.stdio = .inherit;
    nvram_console_step.dependOn(&nvram_console_run.step);

    // Claim 0017: pre-exit virtio-pci TX diagnostic. `zig build preexit-tx`
    // rebuilds the image with -Dpreexit-tx=true and boots it, checking
    // whether the fixed line reaches vm-serial.log while the host saves the
    // NVRAM ladder bracket. The hard gate with the full assertions lives in
    // tools/verify-preexit-tx.sh (`just verify-preexit-tx`). Apple silicon
    // only (VZ VM).
    const preexit_tx_step = b.step("preexit-tx", "Boot the -Dpreexit-tx=true image and check whether the pre-exit virtio TX reaches vm-serial.log (class D diagnostic — claim 0017; Apple silicon only)");
    const preexit_tx_run = b.addSystemCommand(&.{ "bash", "-c", preexit_tx_vm_command });
    preexit_tx_run.has_side_effects = true;
    preexit_tx_run.stdio = .inherit;
    preexit_tx_step.dependOn(&preexit_tx_run.step);

    // Claim 0018: post-exit virtio TX bisect. `zig build tx-diag` boots the
    // -Dtx-diag=true image once and saves the per-stage marker ladder; the
    // determinism gate (N identical boots, per-boot ladders + serial logs +
    // revision) lives in tools/verify-tx-diag.sh (`just verify-tx-diag`).
    // Apple silicon only (VZ VM).
    const tx_diag_step = b.step("tx-diag", "Boot the -Dtx-diag=true image and save the per-stage post-exit TX marker ladder (class D diagnostic — claim 0018; Apple silicon only)");
    const tx_diag_run = b.addSystemCommand(&.{ "bash", "-c", tx_diag_vm_command });
    tx_diag_run.has_side_effects = true;
    tx_diag_run.stdio = .inherit;
    tx_diag_step.dependOn(&tx_diag_run.step);
}

const run_vm_command =
    \\set -e
    \\swift build --package-path host/vm-runner --configuration release
    \\# Recent macOS requires the com.apple.security.virtualization entitlement;
    \\# ad-hoc codesign the binary with it before running.
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\# Apple's EFI firmware does not route its console to the virtio serial
    \\# port or render it to the framebuffer, so the guest also writes its
    \\# message to \\BOOTED.TXT on the ESP (UEFI Simple File System).
    \\# The runner waits for the kernel's terminal marker. It accepts the
    \\# serial banner and marker as the milestone-two success signal.
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log --screen artifacts/vm-screen.png --expect "VirelaiOS kernel has seized control." --terminal-marker "kernel terminal state"
    \\echo
    \\echo "=== guest execution evidence: \\BOOTED.TXT on the ESP ==="
    \\EVIDENCE="$(python3 image/mkfat32.py --cat-file /BOOTED.TXT artifacts/disk.img)" || { echo "evidence missing: the guest did not write BOOTED.TXT"; exit 1; }
    \\printf '%s\n' "$EVIDENCE"
    \\printf '%s' "$EVIDENCE" | grep -q "firmware has agreed to cooperate" || { echo "evidence content mismatch"; exit 1; }
    \\echo
    \\echo "=== loader trace: \\LOADER.TXT on the ESP ==="
    \\python3 image/mkfat32.py --cat-file /LOADER.TXT artifacts/disk.img 2>/dev/null || echo "(no LOADER.TXT -- the loader did not reach the kernel jump)"
    \\echo
    \\echo "=== milestone-two serial evidence ==="
    \\SERIAL="$(cat artifacts/vm-serial.log)" || { echo "serial log missing"; exit 1; }
    \\printf '%s\n' "$SERIAL"
    \\printf '%s' "$SERIAL" | grep -q "VirelaiOS kernel has seized control." || { echo "kernel banner missing from vm-serial.log"; exit 1; }
    \\printf '%s' "$SERIAL" | grep -q "memory-map descriptors=0x" || { echo "kernel memory-map print missing from vm-serial.log"; exit 1; }
    \\printf '%s' "$SERIAL" | grep -q "kernel terminal state" || { echo "kernel terminal state missing from vm-serial.log"; exit 1; }
    \\echo "run: milestone-two takeover observed (serial banner, memory-map view, terminal state)"
;

const spike_virtio_vm_command =
    \\set -e
    \\# -DSPIKE compiles the custom-virtio section (macOS 27 SDK types); the
    \\# base class-A build omits it so the CI toolchain (macOS 26 SDK) parses.
    \\swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
    \\# Recent macOS requires the com.apple.security.virtualization entitlement;
    \\# ad-hoc codesign the binary with it before running.
    \\# Claims 0828/4374/9492/9737/4837: the guest's custom-virtio driver
    \\# (DID 0x1082) probes, negotiates features, arms both queues, runs the
    \\# transport experiment (concurrent in-flight exchanges + ring recycling,
    \\# the 12,340-byte multi-descriptor payload, the queue-1 log transport,
    \\# the negotiated kick/layout behavior), and reports the used-ring IRQ as
    \\# the "cvspike:" block in the serial log. Script mode forwards `pci` + an
    \\# echo once the terminal state appears and exits 0 iff the scripted echo
    \\# is observed. The host-side CUSTOM-VIRTIO lines (DRIVER_OK,
    \\# notifications, dequeued payloads, log lines, returnToQueue) print to
    \\# stdout.
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\echo 'pci' > artifacts/cvspike-script.txt
    \\echo 'echo cvspike-shell-ok' >> artifacts/cvspike-script.txt
    \\# --script-expect waits for the scripted echo output (which appears
    \\# only after the script is forwarded) — expecting the cvspike IRQ line
    \\# would exit the runner before pci/echo are sent (claim 0828).
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-spike.log --custom-virtio --script artifacts/cvspike-script.txt --script-expect "cvspike-shell-ok" --timeout 60
    \\    echo
    \\    echo "=== spike serial log ==="
    \\    cat artifacts/vm-spike.log 2>/dev/null || echo "(no serial output)"
    \\    echo
    \\    echo "=== spike guest evidence (vm-spike.log) ==="
    \\    grep -F -- "cvspike: irq=" artifacts/vm-spike.log || { echo "cvspike IRQ report missing from vm-spike.log"; exit 1; }
    \\    grep -F -- 'cvspike: init ok' artifacts/vm-spike.log || { echo "cvspike init did not arm the transport"; exit 1; }
    \\    grep -F -- 'cvspike: feat=0x' artifacts/vm-spike.log || { echo "cvspike feature report missing from vm-spike.log"; exit 1; }
    \\    grep -F -- 'cvspike: q0 heads=0x0000000000000000,0x0000000000000002,0x0000000000000004,0x0000000000000006 recycle=1' artifacts/vm-spike.log || { echo "cvspike ring-allocator recycle proof missing from vm-spike.log"; exit 1; }
    \\    grep -F -- 'cvspike: q0 big n=0x3034 echo=ok' artifacts/vm-spike.log || { echo "cvspike multi-descriptor payload echo missing from vm-spike.log"; exit 1; }
    \\    grep -F -- 'cvspike: q0 ok=1' artifacts/vm-spike.log || { echo "cvspike queue-0 exchanges did not all pass (q0 ok=1 missing from vm-spike.log)"; exit 1; }
    \\    grep -F -- 'cvspike: q1 ok=3' artifacts/vm-spike.log || { echo "cvspike log transport did not echo all lines (q1 ok=3 missing from vm-spike.log)"; exit 1; }
    \\    echo "spike-virtio: custom-virtio transport observed (queue transport + used-ring IRQ, ring allocator + multi-queue, multi-descriptor payloads, feature negotiation, guest log transport — host evidence in the runner stdout above)"
;

// M1.5 host plumbing: `zig build console` boots the image and opens an
// interactive host console. stdin is inherited so keystrokes reach the
// runner; the runner forwards them to the serial attachment (guest RX is a
// separate milestone slice). `zig build run` above keeps the deterministic
// evidence-gated behavior.
const console_vm_command =
    \\set -e
    \\swift build --package-path host/vm-runner --configuration release
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log --console
    \\echo
    \\echo "console session ended."
;

// ADR 0004 D4 fixed-memory-marker fallback (status.md gate work item 3):
// `zig build marker` boots the image, saves artifacts/marker-dump.txt (the
// host-side NVRAM marker ladder — the working form of the fallback; the
// memory-scan form is impossible on VZ because guest RAM is not host-mapped),
// and exits with the runner's code (0 iff an M2_* marker was found).
// `tools/verify-marker.sh` is the hard gate that also asserts the dump and
// saves the evidence.
const marker_vm_command =
    \\set -e
    \\swift build --package-path host/vm-runner --configuration release
    \\# Recent macOS requires the com.apple.security.virtualization entitlement;
    \\# ad-hoc codesign the binary with it before running.
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\# Fresh variable store so the dump is exactly this run's ladder (the
    \\# store is append-per-write and survives across runs otherwise).
    \\rm -f artifacts/efi-vars.bin
    \\set +e
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log --dump-marker artifacts/marker-dump.txt --timeout 25 --expect "VirelaiOS kernel has seized control." --terminal-marker "kernel terminal state"
    \\RUNNER_RC=$?
    \\set -e
    \\echo
    \\echo "=== marker dump (artifacts/marker-dump.txt) ==="
    \\cat artifacts/marker-dump.txt 2>/dev/null || true
    \\echo
    \\echo "=== loader trace: \\LOADER.TXT on the ESP ==="
    \\python3 image/mkfat32.py --cat-file /LOADER.TXT artifacts/disk.img 2>/dev/null || echo "(no LOADER.TXT -- the loader did not reach the kernel jump)"
    \\exit $RUNNER_RC
;

// Claim 0017: pre-exit virtio-pci TX diagnostic. Rebuilds the kernel +
// image with -Dpreexit-tx=true (a fixed line is TX'd through the virtio-pci
// transport BEFORE ExitBootServices), boots it, and reports whether the
// exact string reached vm-serial.log while saving the NVRAM ladder bracket
// (M2_PEXT!/M2_TXST!/M2_TXNT!/M2_TXPL!/M2_PEXD!). The hard gate lives in
// tools/verify-preexit-tx.sh.
// Claim 0018: post-exit virtio TX bisect. Rebuilds the kernel + image with
// -Dtx-diag=true (the flush writes ten ordered per-stage NVRAM markers;
// see the claim file for the interpretation table), boots it once, and
// saves the ladder. The determinism gate is tools/verify-tx-diag.sh.
const tx_diag_vm_command =
    \\set -e
    \\zig build -Dtx-diag=true image
    \\swift build --package-path host/vm-runner --configuration release
    \\# Recent macOS requires the com.apple.security.virtualization entitlement;
    \\# ad-hoc codesign the binary with it before running.
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\# Fresh variable store so the ladder is exactly this run's writes.
    \\rm -f artifacts/efi-vars.bin
    \\set +e
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log --dump-marker artifacts/tx-diag-marker-dump.txt --timeout 25
    \\RUNNER_RC=$?
    \\set -e
    \\echo
    \\echo "=== marker ladder (artifacts/tx-diag-marker-dump.txt) ==="
    \\cat artifacts/tx-diag-marker-dump.txt 2>/dev/null || true
    \\echo
    \\echo "=== vm-serial.log (artifacts/vm-serial.log) ==="
    \\cat artifacts/vm-serial.log 2>/dev/null || true
    \\exit $RUNNER_RC
;

const preexit_tx_vm_command =
    \\set -e
    \\zig build -Dpreexit-tx=true image
    \\swift build --package-path host/vm-runner --configuration release
    \\# Recent macOS requires the com.apple.security.virtualization entitlement;
    \\# ad-hoc codesign the binary with it before running.
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\# Fresh variable store so the ladder bracket is exactly this run's writes.
    \\rm -f artifacts/efi-vars.bin
    \\set +e
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log --dump-marker artifacts/preexit-marker-dump.txt --timeout 25 --expect "VIRELAIOS PREEXIT VIRTIO TX"
    \\RUNNER_RC=$?
    \\set -e
    \\echo
    \\echo "=== marker ladder (artifacts/preexit-marker-dump.txt) ==="
    \\cat artifacts/preexit-marker-dump.txt 2>/dev/null || true
    \\echo
    \\echo "=== vm-serial.log (artifacts/vm-serial.log) ==="
    \\cat artifacts/vm-serial.log 2>/dev/null || true
    \\echo
    \\if grep -qF -- "VIRELAIOS PREEXIT VIRTIO TX" artifacts/vm-serial.log; then
    \\  echo "PREEXIT-TX: OBSERVED in vm-serial.log (interpretation A — pre-exit TX works; the residual failure is across ExitBootServices/MMU/post-exit)"
    \\  exit 0
    \\else
    \\  echo "PREEXIT-TX: NOT OBSERVED in vm-serial.log (interpretation B / indeterminate — see the marker bracket in artifacts/preexit-marker-dump.txt)"
    \\  exit 1
    \\fi
;

// Claim 0015: NVRAM console channel. The kernel is rebuilt with
// -Dnvram-console=true (its console TX then rides the NVRAM variable
// channel instead of the hanging virtio transport), the image is rebuilt,
// and the runner reconstructs the console stream from efi-vars.bin. The
// hard gate (substring assertions + saved evidence) lives in
// tools/verify-nvram-console.sh.
const nvram_console_vm_command =
    \\set -e
    \\# Claim 0015: rebuild the kernel + image with console TX routed through
    \\# the NVRAM variable channel (post-exit virtio transport access hangs
    \\# on VZ — claim 0013).
    \\zig build -Dnvram-console=true image
    \\swift build --package-path host/vm-runner --configuration release
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\rm -f artifacts/efi-vars.bin
    \\set +e
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log --nvram-console artifacts/nvram-console.log --timeout 25
    \\RUNNER_RC=$?
    \\set -e
    \\echo
    \\echo "=== nvram console stream (artifacts/nvram-console.log) ==="
    \\cat artifacts/nvram-console.log 2>/dev/null || true
    \\echo
    \\echo "=== loader trace: \\LOADER.TXT on the ESP ==="
    \\python3 image/mkfat32.py --cat-file /LOADER.TXT artifacts/disk.img 2>/dev/null || echo "(no LOADER.TXT -- the loader did not reach the kernel jump)"
    \\exit $RUNNER_RC
;
