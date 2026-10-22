//! VirelaiOS milestone-two kernel proper.
//!
//! The boot stub passes the v2 contract in x3. The kernel validates it, moves
//! to the stub-allocated stack, captures the EFI map, calls ExitBootServices,
//! installs an identity-map TTBR0_EL1, probes a bounded set of MMIO serial
//! candidates, prints the takeover evidence, and never returns after a
//! successful exit. No libc, POSIX, allocator, interrupts, timers, RX, DMA,
//! filesystem, or firmware service is used after the exit boundary.

const std = @import("std");
const uefi = std.os.uefi;
const SystemTable = uefi.tables.SystemTable;
const BootServices = uefi.tables.BootServices;
const MemoryMapSlice = uefi.tables.MemoryMapSlice;

// M1.5 console & shell core (agent B): the interactive `virelai>` monitor
// runs on the polled TX console through these modules. The takeover path
// below is untouched; this is the seam's import surface.
const console = @import("console.zig");
const machine = @import("machine.zig");
const alloc = @import("alloc.zig");
const memmap = @import("memmap.zig");
const monitor = @import("monitor.zig");
const shell = @import("shell.zig");
const terminal = @import("terminal.zig"); // #1072 (ADR 0020): the terminal seam
// Claim 3475: ESP file window. Claim 6420: now FAT-backed (live ESP via
// the virtio-blk transport), replacing the NVRAM persistence medium.

const settings = @import("settings.zig"); // milestone eight card U8 (claim 2649): persistent settings on DATA partition
const file_table = @import("file_table.zig"); // M50 TS2 (#1136): OWNERS.TXT load at boot
const secret = @import("secret.zig"); // M50 TS5 (#1139): SECRETS.TXT store load at the queue-5 arming point
const grant = @import("grant.zig"); // M113c (#2419): GRANTS.TXT grant table load at the same arming point
// Milestone four (claim 2665): virtio entropy driver + ChaCha20 CSPRNG.
// The entropy device (DID 0x1044) seeds the CSPRNG post-MMU; `random` and
// the exec-path ASLR consumer live off that seed.
const virtio_entropy = @import("virtio_entropy.zig");
const csprng = @import("csprng.zig");
// Milestone five (claim 1373): virtio-net transport (the runner's
// VZVirtioNetworkDeviceConfiguration under `--net`) — the network keystone.
// Pre-exit discovery, post-MMU re-arm, MAC via VIRTIO_NET_F_MAC, TX on
// queue 1 with a polled used-ring drain; RX is card N2.
const virtio_net = @import("virtio_net.zig");
// M100b (issue #2307, ADR 0050): the virtio-blk transport returns as the
// VLFS data-disk path — clean-slate, not the deleted FAT-era driver. The
// runner's `--data-disk` attach adds a second DID-0x1042 function named
// `virelai-vlfs` via blockDeviceIdentifier; VIRTIO_BLK_T_GET_ID is the
// identity wire. Pre-exit scan/cap-resolution, post-MMU re-arm + GET_ID.
const virtio_blk = @import("virtio_blk.zig");
const vlfs = @import("vlfs/vlfs.zig"); // issue #2381: the boot probe reads the superblock's journal geometry
const vlfs_disk = @import("vlfs/disk.zig"); // M100d (#2309): mount the data disk
const seal = @import("seal.zig"); // M172d (#3037): sealed-v2 mount prompt + AEAD layer
// Milestone six card G1 (claim 6053): virtio-gpu transport + framebuffer
// (the runner's VZVirtioGraphicsDeviceConfiguration under `--display` /
// `--screenshot`) — the graphics keystone. Pre-exit discovery, post-MMU
// re-arm, the control-queue 2D command path to a fixed BSS framebuffer.
const virtio_gpu = @import("virtio_gpu.zig");
// Issue #990 (claim #997): the kernel's serial-log seam — leaf hook module
// armed HERE so modules below main.zig (driving_award) can emit one
// greppable line without an import cycle.
const klog = @import("klog.zig");
// Milestone fifteen card A1 (claim 6140): virtio-snd transport (the
// runner's VZVirtioSoundDeviceConfiguration under `--sound`) — the audio
// keystone. Pre-exit discovery, post-MMU re-arm; DID 0x1059 expected
// (0x1040 + virtio device type 25, the same scheme as net/entropy/gpu),
// whatever is observed is recorded in `snd_did`.
const virtio_snd = @import("virtio_snd.zig");
const fbtext = @import("text.zig"); // milestone six card G2 (claim 3194): framebuffer text
const road_pops = @import("road_pops.zig"); // milestone six card G3 (claim 1574): the Road Pops tee — the boot terminal on the screen
const xhci = @import("xhci.zig"); // milestone seven card I1 (claim 4272): the XHCI host-controller transport (keyboard/pointer live behind it)
const input = @import("input.zig"); // milestone seven card I3 (claim 6050): the keyboard/pointer event FIFO + keycode decode feeding Road Pops
const driving_award = @import("driving_award.zig"); // milestone six card G5 (claim 1543): Driving Award, the window manager (Road Pops is window 0; a clock overlay is window 1)
const smp = @import("smp.zig"); // milestone twenty-eight (claim 6438): SMP secondary core bringup and IPI

// Road Pops (claim 1574) framebuffer-text target: G2's text layer through
// the tee's injectable Target. The text layer is a fixed BSS singleton, so
// the wrappers ignore ctx (a file-scope dummy keeps the pointer well-typed).
// Card G5 (claim 1543): the present is now the Driving Award compositor —
// the tee's write path marks the terminal window dirty, and the compositor
// repaints the terminal (window 0) and blits the clock (window 1) over it,
// then pushes one transfer + flush per dirty batch.
var rp_target_dummy: u8 = 0;
fn rp_text_put_bytes(_: *anyopaque, bytes: []const u8) void {
    fbtext.puts(bytes);
    driving_award.mark_terminal_dirty();
}
fn rp_text_present(_: *anyopaque) void {
    // #1592: do not skip this present once a seat is registered. M71c
    // already refuses the terminal/taskbar/dock blit inside paint_scene
    // while the seat owns the layer, and this composite's transfer+flush
    // is what publishes the seat's pixels. Skipping the present leaves the
    // pre-seat console frame on the uncovered scanout (measured: 1789
    // console-green pixels, go-wm-console-ink FAIL).
    _ = driving_award.composite();
}
fn rp_text_clear(_: *anyopaque) void {
    fbtext.clear();
    driving_award.mark_terminal_dirty();
}

// Card G5 (claim 1543): the keyboard read source is gated on window focus —
// keyboard bytes reach the Road Pops line editor only while the terminal
// window is focused; otherwise they stay queued in the input FIFO. Serial
// (the scripted evidence channel) remains the always-wired fallback.
// Claim 9588: without a window manager (headless boot — no gpu device, the
// WM never armed) there are no windows to focus and the terminal IS the only
// interactive surface, so keyboard bytes flow unconditionally there. With
// the WM armed the focus discipline applies unchanged (every existing
// --input gate also passes --display, so their behavior is identical).
fn rp_read_source() ?u8 {
    if (!driving_award.armed()) return input.pop_byte();
    return if (driving_award.terminal_focused()) input.pop_byte() else null;
}

// Claim 0023: the handoff-v2 contract, the identity-map MMU, and the
// evidence channel (takeover markers + probe dumps) live in their own
// modules. This file keeps local aliases so the orchestration below reads
// like the original; the marker names and values are evidence.zig's.
const handoff = @import("handoff.zig");
const measure = @import("measure.zig"); // M113b (ADR 0054 Part I): the measurement primitive + D4 chain receipt
const mmu = @import("mmu.zig");
const mmio = @import("mmio.zig");
const pci = @import("pci.zig");
const evidence = @import("evidence.zig");
const virtio_console = @import("virtio_console.zig");
const walkprobe = @import("walkprobe.zig"); // claim 7896 diagnostic (linker-eliminated from default builds)
const exceptions = @import("exceptions.zig"); // claim 9746: VBAR_EL1 vector table + basic sync/IRQ handlers
const forensics = @import("forensics.zig"); // #1278: the last-words recorder (off by default)
const gic = @import("gic.zig"); // claim 7948: GIC distributor + CPU interface
const timer = @import("timer.zig"); // claim 7948: ARM generic timer (CNTP)
const scheduler = @import("scheduler.zig"); // claim 5275: tick-driven round-robin tasks
const userspace = @import("userspace.zig"); // claim 8215: first EL0t task + SVC boundary
const syscall = @import("syscall.zig"); // claim 3594: fixed syscall ABI + runtime dispatch table
const exec = @import("exec.zig"); // milestone-three card 6: ESP exec — owns the shared rebuild_user_root (claims 2665/3693)
const process = @import("process.zig"); // M173c (#3044): the receipt uid vocabulary (uid_system on the boot chain)
const virtio_custom = @import("virtio_custom.zig"); // claim 0828: custom-virtio spike driver (DID 0x1082)
const gpu3d_device = @import("gpu3d_device.zig"); // M102b1 (issue #2162): experimental GPU3D channel (DID 0x1083)
const virtio_file = @import("virtio_file.zig"); // M34 HF1+HF2 (issues #735/#736): host file channel client (queue 5)
const virtio_fs = @import("virtio_fs.zig"); // M83g: standard VirtioFS/FUSE backend for /host
const virtio_vsock = @import("virtio_vsock.zig"); // M115a (issue #2460): VZVirtioSocketDevice save/restore probe (DID 0x1053)
// M34 HF5 (issue #739): one-time /data → /host migration at boot.

const HandoffV2 = handoff.HandoffV2;

// Claim 0020 phase selectors live with the transport (the exact-one-phase
// comptime check is virtio_console.zig's); the orchestration reads them.
const tx_transition_a = virtio_console.tx_transition_a; // pre-ExitBootServices
const tx_transition_b = virtio_console.tx_transition_b; // post-EBS, firmware translation still active
const tx_transition_c = virtio_console.tx_transition_c; // post identity-map install, before unrelated work
const tx_transition_d = virtio_console.tx_transition_d; // normal final location (banner site)

// Only the markers the orchestration itself writes are aliased here; the
// virtio/transition markers are internal to virtio_console.zig.
const marker_entry = evidence.marker_entry;
const marker_cmap = evidence.marker_cmap;
const marker_prex = evidence.marker_prex;
const marker_exit = evidence.marker_exit;
const marker_table = evidence.marker_table;
const marker_mapd = evidence.marker_mapd;
const marker_mmu = evidence.marker_mmu;
const marker_seria = evidence.marker_seria;
const marker_ready = evidence.marker_ready;
const marker_raw = evidence.marker_raw;
const marker_txok = evidence.marker_txok;
const marker_seam = evidence.marker_seam;

// Claim 0015: NVRAM console channel (build-gated by `-Dnvram-console`).
// Post-exit access to the virtio-pci transport hangs on VZ (claim 0013), so
// in nvram-console builds console bytes ride the proven post-exit-safe
// runtime-SetVariable channel instead of the MMIO transport. The option
// comes from build.zig (kernel module options); a default build has it
// false and the virtio TX path is byte-identical.
const build_options = @import("build_options");
const nvram_console = @import("nvram_console.zig");
const osver = @import("osver.zig"); // M115f (#2465): the -Dos-version label `sysinfo` reports

// Claim 0021: firmware MMU-state capture (default off; the default build is
// byte-identical). Records the firmware's live MMU registers and a bounded
// walk of its TTBR0 tables for the virtio BAR0 window + a RAM control
// address, plus the kernel's planned values, persisted pre-exit.
const fw_mmu_capture = build_options.fw_mmu_capture;

const bad_handoff: u64 = 2;
const map_failure: u64 = 3;
const exit_failure: u64 = 4;
const table_failure: u64 = 5;
const serial_failure: u64 = 6;

const ProbeRecord = extern struct {
    base: u64,
    magic: u32,
    version: u32,
    device: u32,
    layout: u32,
};
var probe_records: [96]ProbeRecord = undefined;
var probe_count: usize = 0;

const Candidate = struct {
    base: u64,
    kind: Kind,
};
const Kind = evidence.Kind;
var console_kind: Kind = .none;
var console_base: u64 = 0;

// Candidate addresses are not hard-coded into the probe. The EFI map's
// declared MMIO descriptors are the only windows it may inspect.

/// The naked shim is the only code that runs on the loader stack. It copies
/// the four ABI arguments into caller-saved temporaries, installs the exact
/// 16 KiB stack from HandoffV2, restores x0..x3, and calls the normal Zig
/// takeover function. It returns only for a pre-exit failure.
///
/// The `bl` below overwrites the link register with this shim's own return
/// address, so the loader's x30 is stashed in x20 first. x20 is callee-saved
/// under AAPCS64: kernel_main (callconv(.c)) must preserve x19..x28, so the
/// value survives the call. Restoring x30 before the final `ret` is what
/// lets a pre-exit failure actually reach the loader (which then writes
/// RC.TXT); without it the `ret` loops forever on the `bl`'s return address
/// and the kernel never gets back (the observed bad-handoff gate failure).
export fn _start(
    _: u64,
    _: u64,
    _: *const SystemTable,
    _: *HandoffV2,
) callconv(.naked) u64 {
    asm volatile ("mov x9, x0\n" ++
            "mov x10, x1\n" ++
            "mov x11, x2\n" ++
            "mov x12, x3\n" ++
            "mov x19, sp\n" ++
            "mov x20, x30\n" ++
            "ldr x4, [x12, #40]\n" ++
            "ldr x5, [x12, #48]\n" ++
            "add sp, x4, x5\n" ++
            "mov x0, x9\n" ++
            "mov x1, x10\n" ++
            "mov x2, x11\n" ++
            "mov x3, x12\n" ++
            "bl %[takeover]\n" ++
            "mov sp, x19\n" ++
            "mov x30, x20\n" ++
            "ret"
        :
        : [takeover] "X" (&kernel_main),
    );
}

fn kernel_main(base: u64, size: u64, st: *const SystemTable, handoff_rec: *HandoffV2) callconv(.c) u64 {
    if (!valid_handoff(base, size, st, handoff_rec)) {
        print_pre_exit_error(st, "VirelaiOS: invalid handoff\r\n");
        return bad_handoff;
    }

    // M1.5 machine controls: capture the EFI Runtime Services table
    // pre-exit. Runtime services (unlike boot services) survive
    // ExitBootServices, so `ResetSystem` remains callable after the
    // takeover — the same table whose SetVariable drives the marker
    // ladder below (observed working post-exit on VZ, claims 0009/0010).
    machine.init(st.runtime_services);

    // Claim 0015: capture the same table for the NVRAM console channel.
    // Active only in `-Dnvram-console` builds; otherwise the module's
    // writes are never called.
    nvram_console.init(st.runtime_services);

    // #1058: adopt the boot loader's EFI GetTime epoch (Unix wall-clock
    // seconds) so userspace has a real system clock with or without a host
    // share. `no_boot_epoch` keeps the honest uptime fallback.
    timer.set_boot_epoch_secs(handoff_rec.boot_epoch_secs);

    // M115f (#2465): publish the build-stamped OS version (-Dos-version)
    // for `sysinfo` — an applied update carries a new label, so the
    // version line is the in-guest proof the base image changed.
    osver.label = build_options.os_version;

    print_pre_exit_error(st, "VirelaiOS: kernel entered\r\n");
    evidence.set_marker(marker_entry);
    evidence.write_marker_var(st, marker_entry);
    // Second pre-exit write immediately after the first: if the persisted
    // variable still reads M2_ENTRY, a *repeated* SetVariable failed (the
    // marker ladder would be stuck); if it reads M2_CMAP!, the kernel died
    // inside capture_map below.
    evidence.write_marker_var(st, marker_cmap);

    const bs = st.boot_services orelse {
        print_pre_exit_error(st, "VirelaiOS: no Boot Services\r\n");
        return map_failure;
    };

    var map_buffer = capture_map(bs) catch {
        print_pre_exit_error(st, "VirelaiOS: GetMemoryMap failed\r\n");
        return map_failure;
    };

    // Claim 0013 diagnostic (PRE-EXIT, all firmware memory still readable):
    // record the declared MMIO windows, the EFI configuration table
    // (sniffing for the flattened device tree, magic 0xd00dfeed), and the
    // ACPI tables (SPCR names the console UART) into the probe-dump buffer.
    // Persist ONCE, immediately: big SetVariable writes are proven to work
    // pre-exit but hang post-exit on VZ (observed: the ladder stopped at
    // M2_RAW! with a 2.6 KB re-write pending), and a post-switch fault must
    // not lose this evidence. The post-exit probe appends only a small tail
    // (write_probe_tail).
    evidence.dump_mmio_descriptors(map_buffer.map);
    evidence.dump_config_table(st);
    pci.dump_acpi(st);
    // Claim 3475: the probe dump is persisted ONCE, after the serial
    // selection is known, and only in `-Dprobe-var` diagnostic builds. The
    // serial log carries the probe records (base/layout/records below), and
    // VZ's append-per-write variable store fills up fast: the ~32 KiB
    // persist per boot (16 chunks × 2 KiB) left ~64 B free by the time the
    // shell ran, so the ESP file window's `write` always failed with
    // EFI_OUT_OF_RESOURCES (observed, claim 3475). Claim 0015 already
    // gated the persist off in nvram-console builds for the same
    // starvation; `-Dprobe-var` restores it for diagnostics.
    const pre = probe_serial_pre(map_buffer.map, st);
    console_kind = pre.kind;
    console_base = pre.base;
    evidence.dump_sel(pre.kind, pre.base);
    if (comptime build_options.probe_var) evidence.write_probe_var(st);

    // Claim 0017 diagnostic (build-gated `-Dpreexit-tx`): transmit a fixed
    // line through the SAME virtio-pci transport the post-exit path uses
    // while Boot Services and the firmware address space are still active.
    // Runs after the probe evidence is persisted (a hang must not lose it)
    // and immediately before the pre-exit marker / ExitBootServices. The
    // marker ladder brackets the flush (M2_PEXT! ... M2_TXST!/M2_TXNT!/
    // M2_TXPL! ... M2_PEXD!); vm-serial.log is the "bytes reached the host"
    // gate (tools/verify-preexit-tx.sh). Diagnostic only — the post-exit
    // banner TX is untouched.
    if (comptime build_options.preexit_tx) virtio_console.preexit_tx_experiment(st);
    // Claim 0020 phase A: the same fixed line through the same transport,
    // still pre-ExitBootServices. Runs immediately before the pre-exit
    // marker so a hang cannot lose the persisted probe evidence.
    if (comptime tx_transition_a) virtio_console.transition_tx_experiment(st, .a);
    // Claim 0021 diagnostic (build-gated `-Dfw-mmu-capture`): while the
    // firmware translation is still live, record the firmware's MMU
    // registers + a bounded walk of its TTBR0 tables for the virtio BAR0
    // window (the claim-0020 post-switch hang target) and a RAM control
    // address, plus the kernel's planned values. Persisted as its own small
    // ASCII variable, immediately before the pre-exit marker/exit so a hang
    // cannot lose it.
    if (comptime fw_mmu_capture) evidence.fw_mmu_capture_diag(st, handoff_rec, virtio_console.vp_ready, virtio_console.vp_bar0);

    // Pre-exit stage: proves the kernel passed valid_handoff + capture_map
    // and reached the exit call. The persisted NVRAM marker being M2_ENTRY
    // instead means the kernel died in that window.
    evidence.write_marker_var(st, marker_prex);

    // M34 HF6 (issue #740): the ESP/DATA FAT partitions are GONE — zero
    // guest code speaks FAT after boot. (The boot volume is parsed by
    // Apple's firmware pre-exit only.) M100b (issue #2307, ADR 0050)
    // restores a virtio-blk transport for the VLFS data disk alone:
    // the bus-0 scan collects EVERY DID-0x1042 function (the boot image
    // is always one; the runner's `--data-disk` adds a second named
    // `virelai-vlfs`), resolves each one's common/notify/device-config
    // capability addresses + BAR windows PRE-EXIT (config-space reads
    // hang post-exit, claim 0013), and arms each queue. Post-MMU the
    // functions are re-armed and GET_ID names the disk — identity is
    // wired, never positional.
    _ = virtio_blk.virtio_blk_init();

    // Milestone four (claim 2665): the virtio-pci entropy transport
    // (DID 0x1044 — the runner's VZVirtioEntropyDeviceConfiguration, seen
    // on the bus since the claim-5844-era `pci` listing). Armed PRE-EXIT
    // like the console/blk devices (config-space + BAR reads must stay
    // pre-exit, claim 0013); its BAR0 window is handed to the identity map
    // below, and the transport is RE-ARMED post-MMU (the claim-6420 lesson:
    // VZ resets virtio devices at ExitBootServices) right before the seed.
    const entropy_ready = virtio_entropy.virtio_entropy_init();

    // Milestone five card N1 (claim 1373): the virtio-pci network transport
    // (the runner's `--net` attachment — modern virtio-net, DID 0x1041 per
    // the 2026-08-11 DID correction; confirm-at-claim-time, whatever is
    // observed is recorded). Armed PRE-EXIT like the console/blk/entropy
    // devices (config-space + BAR reads must stay pre-exit, claim 0013);
    // its BAR0 window is handed to the identity map below, and the
    // transport is RE-ARMED post-MMU (the claim-6420 lesson: VZ resets
    // virtio devices at ExitBootServices) right after the MMU switch. The
    // default runner attaches no network device, so `net_ready` is false
    // on every existing gate — the default VM is unchanged.
    const net_ready = virtio_net.virtio_net_init();

    // Milestone six card G1 (claim 6053): the virtio-pci graphics transport
    // (the runner's `--display` / `--screenshot` attachment — modern
    // virtio-gpu, DID 0x1050 expected per the 0x1040 + device-id scheme;
    // confirm-at-claim-time, whatever is observed is recorded). Armed
    // PRE-EXIT like the console/blk/entropy/net devices (config-space +
    // BAR reads must stay pre-exit, claim 0013); its BAR0 window is handed
    // to the identity map below, and the transport is RE-ARMED post-MMU
    // (the claim-6420 lesson: VZ resets some virtio devices at
    // ExitBootServices — blk/entropy do, the net device does NOT; the gpu
    // answer is observed, not assumed) right after the MMU switch. The
    // default runner attaches no graphics device, so `gpu_ready` is false
    // on every existing gate — the default VM is unchanged.
    const gpu_ready = virtio_gpu.virtio_gpu_init();

    // Milestone fifteen card A1 (claim 6140): the virtio-pci sound
    // transport (the runner's `--sound` attachment — modern virtio-snd,
    // DID 0x1059 expected per the 0x1040 + device-id scheme; confirm-at-
    // claim-time, whatever is observed is recorded). Armed PRE-EXIT like
    // the console/blk/entropy/net/gpu devices (config-space + BAR reads
    // must stay pre-exit, claim 0013); its BAR0 window is handed to the
    // identity map below, and the transport is RE-ARMED post-MMU (the
    // claim-6420 lesson: VZ resets virtio devices at ExitBootServices)
    // right after the MMU switch. The default runner attaches no sound
    // device, so `snd_ready` is false on every existing gate — the
    // default VM is unchanged.
    const snd_ready = virtio_snd.virtio_snd_init();

    // Milestone seven card I1 (claim 4272): the XHCI host-controller
    // transport — the device VZ's `--input` attaches
    // (VZUSBKeyboardConfiguration + VZUSBScreenCoordinatePointingDeviceConfiguration,
    // observed as an Apple XHCI USB controller DID 0x1a06, claim 3868).
    // Discovery runs PRE-EXIT like every other device (config-space reads
    // must stay pre-exit, claim 0013); the MMIO init (register map + rings +
    // NO-OP + port status) runs post-MMU below. The default runner attaches
    // no input devices, so `xhci_probed` is false on every existing gate —
    // the default VM is unchanged.
    const xhci_probed = xhci.xhci_probe();

    // Claim 0828: the custom-virtio spike device (DID 0x1082) — PRE-EXIT
    // discovery only (config-space reads, the claim-0013 discipline). VZ's
    // firmware BAR assignment moves between boots (0x50001000 in the claim-
    // 5844 run; ABOVE the 4 GiB blanket on a later boot), so the transport
    // BAR is handed to the identity map below like the console/blk windows.
    const cv_probed = virtio_custom.probe();
    // M83g: discover Apple's standard virtio-fs device before
    // ExitBootServices; configure queues and FUSE after the MMU switch.
    const fs_probed = virtio_fs.probe();

    // M102 card b1 (issue #2162): the experimental GPU3D render channel —
    // the owner-approved second custom-virtio device (DID 0x1083, the
    // sibling of the 0x1082 host channel). PRE-EXIT discovery only
    // (config-space reads, the claim-0013 discipline); its transport BAR
    // is handed to the identity map below and the queue is armed post-MMU.
    // Absent means UNSUPPORTED, not a boot failure — the default runner
    // attaches no such device, so `g3_probed` is false on every existing
    // gate and the boot output stays byte-identical.
    const g3_probed = gpu3d_device.probe();
    // M115a (issue #2460): the standard virtio-vsock device (DID 0x1053,
    // the runner's `--vsock` attachment) — PRE-EXIT discovery only, the
    // claim-0013 discipline. The default runner attaches no socket device,
    // so `vsock_probed` is false on every existing gate and the boot
    // output stays byte-identical.
    const vsock_probed = virtio_vsock.probe();

    var exited = false;
    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        // The map buffer is already allocated. Re-reading it is the only
        // permitted operation between an INVALID_PARAMETER retry.
        if (bs.exitBootServices(@ptrFromInt(handoff_rec.image_handle), map_buffer.map.info.key)) |_| {
            exited = true;
            break;
        } else |err| switch (err) {
            error.InvalidParameter => {
                const refreshed = bs.getMemoryMap(map_buffer.buffer) catch {
                    print_pre_exit_error(st, "VirelaiOS: map refresh failed\r\n");
                    return map_failure;
                };
                map_buffer.map = refreshed;
            },
            else => {
                print_pre_exit_error(st, "VirelaiOS: ExitBootServices failed\r\n");
                return exit_failure;
            },
        }
    }
    if (!exited) {
        print_pre_exit_error(st, "VirelaiOS: ExitBootServices failed after 8 attempts\r\n");
        halt_forever();
    }
    evidence.set_marker(marker_exit);
    evidence.write_marker_var(st, marker_exit); // first post-exit runtime-services call
    // Claim 0020 phase B: the FIRST post-exit TX attempt, immediately after
    // a successful ExitBootServices while the firmware's translation regime
    // is still active (VirelaiOS page tables are not yet built). This is
    // the controlled test of whether ExitBootServices itself destroys
    // access to the transport window.
    if (comptime tx_transition_b) virtio_console.transition_tx_experiment(st, .b);

    // After successful exit, no longer allowed: AllocatePool/AllocatePages,
    // GetMemoryMap, SimpleTextOutput, Simple File System,
    // LoadImage/StartImage, SetTimer, any event services, any other Boot
    // Services call. The map buffer is now owned by this kernel and all
    // subsequent work is direct memory/register access only.
    const map_after_exit = map_buffer.map;
    // Claim 0023 (+ 6420): the virtio console + block BAR windows
    // (discovered pre-exit) are handed to mmu.build_identity_map as the
    // extra Device windows above the blanket; mmu.zig stays
    // transport-agnostic.
    var extra_windows: [16]mmu.DeviceWindow = undefined;
    var extra_count: usize = 0;
    if (virtio_console.vp_ready and virtio_console.vp_bar0 != 0) {
        extra_windows[extra_count] = .{ .base = virtio_console.vp_bar0, .len = 0x10000 };
        extra_count += 1;
    }
    // M34 HF6 (issue #740): the virtio-blk BAR window is gone with the
    // transport; M100b (issue #2307, ADR 0050) restores it — every
    // discovered blk function's BAR base(s) get a Device window so the
    // post-MMU common-config reads + queue notify reach the devices.
    if (virtio_blk.function_count > 0) {
        extra_count += virtio_blk.add_device_windows(extra_windows[extra_count..]);
    }
    // Claim 0828: the custom-virtio transport BAR (pre-exit resolved).
    // mmu.zig maps windows above the blanket; below it the 4 GiB blanket
    // already covers the BAR, so the entry is a harmless no-op there.
    if (cv_probed and virtio_custom.cv_bar != 0) {
        extra_windows[extra_count] = virtio_custom.device_window();
        extra_count += 1;
    }
    // M102b1 (issue #2162): the GPU3D transport BAR — the same Device-
    // window treatment so post-MMU common-config reads + control-queue
    // notify reach the device. Absent device: no window, no change.
    if (g3_probed and gpu3d_device.g3_bar != 0) {
        extra_windows[extra_count] = gpu3d_device.device_window();
        extra_count += 1;
    }
    if (fs_probed) extra_count += virtio_fs.add_device_windows(extra_windows[extra_count..]);
    // M115a (issue #2460): the vsock transport BARs — the same Device-
    // window treatment as fs so post-MMU common-config reads + queue
    // notify reach the device. Absent device: no window, no change.
    if (vsock_probed) extra_count += virtio_vsock.add_device_windows(extra_windows[extra_count..]);
    // Milestone four (claim 2665): the entropy transport BAR (pre-exit
    // resolved) — same Device-window treatment as the console/blk/custom
    // transports so post-MMU common-config reads reach the device.
    if (entropy_ready and virtio_entropy.ent_bar0 != 0) {
        extra_windows[extra_count] = .{ .base = virtio_entropy.ent_bar0, .len = 0x10000 };
        extra_count += 1;
    }
    // Milestone five card N1 (claim 1373): the net transport BAR (pre-exit
    // resolved) — same Device-window treatment as the console/blk/custom/
    // entropy transports so post-MMU common-config reads + TX notify reach
    // the device. Only present under the runner's `--net` flag (default VM:
    // no net device, no window).
    if (net_ready and virtio_net.net_bar0 != 0) {
        extra_windows[extra_count] = .{ .base = virtio_net.net_bar0, .len = 0x10000 };
        extra_count += 1;
    }
    // Milestone six card G1 (claim 6053): the gpu transport BAR (pre-exit
    // resolved) — same Device-window treatment as the console/blk/custom/
    // entropy/net transports so post-MMU common-config reads + control-
    // queue notify reach the device. Only present under the runner's
    // `--display`/`--screenshot` flags (default VM: no gpu device, no
    // window).
    if (gpu_ready and virtio_gpu.gpu_bar0 != 0) {
        extra_windows[extra_count] = .{ .base = virtio_gpu.gpu_bar0, .len = 0x10000 };
        extra_count += 1;
    }
    // Milestone fifteen card A1 (claim 6140): the sound transport BAR
    // (pre-exit resolved) — same Device-window treatment as the other
    // transports so post-MMU common-config reads reach the device. Only
    // present under the runner's `--sound` flag (default VM: no sound
    // device, no window).
    if (snd_ready and virtio_snd.snd_bar0 != 0) {
        extra_windows[extra_count] = .{ .base = virtio_snd.snd_bar0, .len = 0x10000 };
        extra_count += 1;
    }
    const user_text = userspace.text_region(base);
    const user_stack = userspace.stack_region(base);
    const user_regions = [_]mmu.UserRegion{
        .{ .base = user_text.base, .len = user_text.len, .writable = false, .executable = true },
        .{ .base = user_stack.base, .len = user_stack.len, .writable = true, .executable = false },
    };
    if (!mmu.build_identity_map(map_after_exit, map_buffer.buffer, base, size, handoff_rec, extra_windows[0..extra_count], &user_regions)) {
        evidence.set_marker(marker_table);
        evidence.write_marker_var(st, marker_table);
        halt_forever();
    }
    // Pre-install write (still on the firmware identity map, reliable): if the
    // persisted ladder stops here, the kernel died between this write and the
    // post-install M2_MMUP! write — i.e. inside install_identity_map() or at
    // the first post-switch call (claim 0009: observed — every VZ run stops
    // at M2_MAPD!, so the MMU takeover window is the death site; the kernel
    // never reaches the serial probe).
    evidence.write_marker_var(st, marker_mapd);
    exceptions.init(exception_report_writer);
    exceptions.install();
    mmu.install_identity_map();
    if (fs_probed) {
        const pre_rearm_status = mmio.mmio_read8(virtio_fs.fs_common + 0x14);
        if (virtio_fs.init()) {
            uart_puts("virtio-fs: ready did=0x105a dev=");
            uart_hex(virtio_fs.fs_dev);
            uart_puts(" tag=virelaios queues=");
            uart_hex(virtio_fs.fs_request_queues + 1);
            uart_puts(" qsize=");
            uart_hex(virtio_fs.fs_request_queue_size);
            uart_puts(" pre-rearm-st=");
            uart_hex8(pre_rearm_status);
            uart_puts(" fuse=7.");
            uart_hex(virtio_fs.fs_minor);
            uart_puts(" max-write=");
            uart_hex(virtio_fs.fs_max_write);
            uart_puts("\n");
        } else {
            uart_puts("virtio-fs: init failed did=0x105a dev=");
            uart_hex(virtio_fs.fs_dev);
            uart_puts(" pre-rearm-st=");
            uart_hex8(pre_rearm_status);
            uart_puts(" stage=");
            uart_hex(virtio_fs.fs_init_stage);
            uart_puts(" fuse-errno=");
            uart_hex(@as(u64, @intCast(@as(u32, @bitCast(virtio_fs.fs_error)))));
            uart_puts(" feature-lo=");
            uart_hex(virtio_fs.fs_feature_lo);
            uart_puts(" feature-hi=");
            uart_hex(virtio_fs.fs_feature_hi);
            uart_puts(" request-queues=");
            uart_hex(virtio_fs.fs_request_queues);
            uart_puts("\n");
        }
    }
    // M115a (issue #2460): arm the vsock transport post-MMU (the claim-6420
    // discipline — the whole device state machine is re-programmed on the
    // pre-exit-resolved addresses; the pre-rearm status is printed so the
    // host sees whether VZ reset the device at ExitBootServices). Absent
    // device: `vsock_probed` is false, nothing is printed, and the boot
    // output stays byte-identical.
    if (vsock_probed) {
        uart_puts("vsock: pre-rearm st=");
        uart_hex8(virtio_vsock.vs_status());
        uart_puts("\n");
        if (virtio_vsock.init()) {
            // The bare "vsock: ready did=0x1053" line is the spec's witness
            // (whole-line match): identical at arm and at every `vsock`
            // monitor command, so a post-restore serial query reproduces
            // the pre-save line byte-for-byte.
            uart_puts("vsock: ready did=0x1053\n");
            uart_puts("vsock: dev=");
            uart_hex(virtio_vsock.vs_dev);
            uart_puts(" cid=");
            uart_hex(virtio_vsock.vs_guest_cid);
            uart_puts("\n");
        } else {
            uart_puts("vsock: arm failed did=0x1053 dev=");
            uart_hex(virtio_vsock.vs_dev);
            uart_puts(" stage=");
            uart_hex(virtio_vsock.vs_fail_stage);
            uart_puts("\n");
        }
    }
    // Claim 9746 (roadmap item 5, first half): install the VBAR_EL1
    // exception vectors + basic synchronous/IRQ handlers NOW — after
    // ExitBootServices and the identity-map switch, when the kernel owns
    // EL1 and no pre-exit firmware Boot Services are still active. Writing
    // VBAR_EL1 earlier (pre-ExitBootServices) is catastrophic on VZ
    // (observed: the pre-exit firmware calls hang ~7/8 boots — firmware
    // exceptions would land in the kernel's vectors, claim 9746). From
    // here on any fault produces an `[EXC]` report instead of a silent
    // hang. The report writer degrades to a no-op until the serial console
    // is probed below (console_kind == .none); the GIC is NOT programmed
    // here — that is the next card.
    userspace.init();
    syscall.init(process_stdout);
    // Claim 5804: the EL0 task runs in its own address space, so the
    // uaccess regions are USER VAs (what the user root maps and what the
    // task's syscall pointers refer to) — not the physical image ranges
    // `build_identity_map` consumed above.
    syscall.set_user_regions(userspace.text_va_region(), userspace.stack_va_region());
    exceptions.set_svc_dispatcher(syscall.handle_svc);
    // Milestone sixteen C2 (claim 8403): an EL0 synchronous fault (a guard-
    // page step, an unmapped access, a non-executable fetch) is process
    // termination, not a machine hang — the scheduler reaps the faulting
    // process (status 139) and stages the next task.
    exceptions.set_fault_dispatcher(scheduler.fault_current);
    // Claim 7948 (roadmap item 5, second half): GIC + generic timer. The
    // MADT/GTDT discovery ran PRE-EXIT inside pci.dump_acpi (post-exit ACPI
    // reads hang on VZ, claim 0013); program the controller + timer NOW —
    // post-MMU, when the kernel owns EL1 and device MMIO is reachable
    // (claim 1517), with the claim-9746 vectors already installed so any
    // misstep reports instead of hanging. Only then register the IRQ chain
    // and unmask IRQs, so no interrupt can arrive before the whole path
    // (GIC -> vector -> dispatcher -> timer) is armed.
    gic.init(timer.ppi, timer.interrupt_edge);
    timer.init();
    exceptions.set_irq_dispatcher(irq_dispatch);
    // #1278: arm the recorder's drain seam. Installed unconditionally but inert
    // until `forensics on` sets `enabled`, so this wiring costs one null check
    // plus one bool test per console write and leaves a default boot
    // byte-identical. It is installed HERE, next to the IRQ chain, because the
    // recorder exists to narrate the window in which interrupts are live.
    console.set_drain_hook(&forensics.drain);
    exceptions.irq_unmask();
    evidence.set_marker(marker_mmu);
    evidence.write_marker_var(st, marker_mmu);
    // Claim 1517: the TLBI is now executed inside install_identity_map()
    // (corrected start level T0SZ=16 + full invalidation at the switch —
    // the ADR-0006 no-TLBI debt is paid). With -Dwalk-probe (class D,
    // default off), run the cold-address probe battery so the ladder names
    // the first address that does not resolve.
    if (comptime build_options.walk_probe) walkprobe.run(st);
    // Claim 0020 phase C: the FIRST MMIO access to the transport after the
    // identity-map switch, before the post-switch probe (M2_RAW!) or any
    // other runtime-service/diagnostic work. Tests whether installing the
    // VirelaiOS page tables destroys access (the claim-0013/0018
    // hypothesis), with the marker write above being the only prior
    // post-switch call.
    if (comptime tx_transition_c) virtio_console.transition_tx_experiment(st, .c);

    const selected = probe_serial(map_after_exit, st);
    console_kind = selected.kind;
    console_base = selected.base;
    if (selected.kind == .none) {
        evidence.set_marker(marker_seria);
        evidence.write_marker_var(st, marker_seria);
        evidence.write_marker_fallback(&virtio_console.virtio_tx, base, size, map_after_exit);
        halt_forever();
    }
    evidence.set_marker(marker_ready);
    evidence.write_marker_var(st, marker_ready);

    virtio_console.st_tx = st; // for flush stage markers
    // Claim 0020 phase D: TX at the normal final location — the same site
    // where the production banner transmits. Same payload as phases A/B/C.
    if (comptime tx_transition_d) virtio_console.transition_tx_experiment(st, .d);
    klog.line_hook = uart_puts; // #990: arm the klog seam (first banner line goes direct)
    uart_puts("VirelaiOS kernel has seized control.\n");
    // M113b (ADR 0054 Part I): publish the verified-boot chain receipt.
    // The loader measured both stages (its own Authenticode digest, the
    // raw KERNEL.BIN digest it verified before jumping) and carried them
    // in the v4 handoff — the kernel never re-reads the boot volume, so
    // these lines ARE the measurement record. The serial copy goes out
    // here; the share copy lands at the file-channel arming point below.
    var rcpt: [2 * measure.receipt_max]u8 = undefined;
    var rcpt_len: usize = 0;
    rcpt_len += measure.receipt_line(rcpt[rcpt_len..], .loader, &handoff_rec.measured_loader, if (handoff_rec.measured_ok & 1 != 0) "measured" else "unmeasured", null, null, process.uid_system);
    rcpt_len += measure.receipt_line(rcpt[rcpt_len..], .kernel, &handoff_rec.measured_kernel, if (handoff_rec.measured_ok & 2 != 0) "measured" else "unmeasured", null, null, process.uid_system);
    uart_puts(rcpt[0..rcpt_len]);
    // Claim 0013: after the first TX, record whether the TX path returned
    // (bytes may still be dropped by the device; the serial log is the gate,
    // but M2_TXOK! separates "TX hung" from "TX returned silently").
    evidence.write_marker_var(st, marker_txok);
    uart_puts("memory-map descriptors=");
    uart_hex(@intCast(map_after_exit.info.len));
    uart_puts(" descriptor_size=");
    uart_hex(@intCast(map_after_exit.info.descriptor_size));
    uart_puts(" version=");
    uart_hex(@intCast(map_after_exit.info.descriptor_version));
    uart_puts(" key=");
    uart_hex(@backingInt(map_after_exit.info.key));
    uart_puts("\n");

    var it = map_after_exit.iterator();
    while (it.next()) |desc| {
        uart_puts("map type=");
        uart_hex(@backingInt(desc.type));
        uart_puts(" base=");
        uart_hex(desc.physical_start);
        uart_puts(" pages=");
        uart_hex(desc.number_of_pages);
        uart_puts(" attr=");
        uart_hex(@bitCast(desc.attribute));
        uart_puts("\n");
    }

    uart_puts("probe base=");
    uart_hex(console_base);
    uart_puts(" layout=");
    uart_puts(layout_name(console_kind));
    uart_puts(" records=");
    uart_hex(@intCast(probe_count));
    uart_puts("\n");
    for (probe_records[0..probe_count]) |record| {
        uart_puts("probe candidate=");
        uart_hex(record.base);
        uart_puts(" magic=");
        uart_hex(record.magic);
        uart_puts(" version=");
        uart_hex(record.version);
        uart_puts(" device=");
        uart_hex(record.device);
        uart_puts(" layout=");
        uart_hex(record.layout);
        uart_puts("\n");
    }

    // Claim 9187: the interrupt-controller/timer state lands in the serial
    // log at every boot — the live gate's first assertion (before the
    // scripted `timer` command runs).
    uart_puts("interrupts: gic=");
    uart_puts(gic.kind_name());
    uart_puts(" armed=");
    uart_puts(if (gic.armed() and timer.armed()) "1" else "0");
    uart_puts(" dist=");
    uart_hex(gic.dist_base);
    uart_puts(" redist=");
    uart_hex(gic.redist_base);
    uart_puts(" active=");
    uart_hex(gic.active_redist_base);
    uart_puts(" fallback=");
    uart_puts(if (gic.used_fallback) "1" else "0");
    uart_puts(" ppi=");
    uart_hex(timer.ppi);
    uart_puts(" edge=");
    uart_puts(if (timer.interrupt_edge) "1" else "0");
    uart_puts(" freq=");
    uart_hex(timer.freq);
    uart_puts("\n");

    // M34 HF6 (issue #740): the ESP window and FAT volumes are gone — the
    // boot line reports the host file channel state instead (the queue-5
    // share is the only file store).
    uart_puts("host share: ");
    uart_puts(if (virtio_file.available()) "armed" else "absent");
    uart_puts("\n");

    // M34 HF6 (issue #740): the DATA partition and the post-exit
    // virtio-blk path are gone — settings load from the host share (a
    // no-op without a channel; defaults stay in force).
    settings.init_from_share();
    // M115d (#2463): the secret + grant stores take the same early load.
    // They still re-load at the queue-5 arming point below (the cvc
    // channel's file wins on a both-armed boot, unchanged); a boot whose
    // ONLY host channel is virtio-fs otherwise never read SECRETS.TXT —
    // the ctl credential's guest half would refuse `no_credential` even
    // with the row provisioned (observed live-suspend-resume sv1).
    _ = secret.init_from_share();
    _ = grant.init_from_share();
    // M50 TS2 (issue #1136, ADR 0024 D3): the ownership/mode metadata
    // (`OWNERS.TXT`) is loaded at the queue-5 arming point below, after the
    // host channel becomes available (the pre-probe "absent" state is not
    // a failure; an empty table is today's behavior).

    uart_puts("kernel terminal state\n");

    // macOS 27 custom-virtio spike (claim 0828): the smallest guest driver
    // for the spike device (`zig build spike-virtio`, DID 0x1082, claim
    // 5844). Probing, negotiation, DRIVER_OK, the queue-0 kick, and the
    // used-ring IRQ experiment all run POST-exit — post-MMU ECAM reads
    // work (claims 1517/6684) and the device's BAR2 window (0x50001000)
    // sits below the 4 GiB blanket. Silent no-op when the device is absent
    // (default builds are unchanged). Evidence: host runner stdout
    // (DRIVER_OK / notification / dequeued payload / returnToQueue) + this
    // serial report. The SPI window is disarmed after the report so the
    // shell runs without interrupt noise; the claim-9187 timer PPI stays
    // armed and the polled console paths are untouched.
    custom_virtio_spike();
    // M113b (#2418, ADR 0054 D5): the chain receipt's second publication
    // surface is the share file `RCPT.TXT` — the surface every
    // file-channel gate already reads — written after the spike because
    // the queue-5 arming lives inside it. Best effort; an absent channel
    // leaves the serial copy as the record.
    if (virtio_file.available()) {
        _ = virtio_file.write_whole("RCPT.TXT", rcpt[0..rcpt_len]);
    }

    // M102 card b1 (issue #2162): arm the GPU3D render channel post-MMU
    // (the claim-6420 discipline — the whole device state machine is
    // re-programmed on the pre-exit-resolved addresses). Absent device:
    // `g3_probed` is false, nothing is printed, and the boot output stays
    // byte-identical. A malformed device is unsupported, not fatal.
    if (g3_probed) {
        if (gpu3d_device.init()) {
            uart_puts("gpu3d: armed did=0x1083\n");
        } else {
            uart_puts("gpu3d: unsupported (");
            uart_puts(gpu3d_device.g3_fail);
            uart_puts(")\n");
        }
    }

    // ------------------------------------------------------------------
    // M1.5 console & shell core seam (agent B). The takeover path above
    // (exit, map, MMU, probe, uart_*) is byte-identical; this section only
    // wires the mock-proven shell loop onto the polled TX console. RX
    // reads are [inferred] and gated on the VZ serial gate (claim 0002,
    // unpassed): no device register is read, rx_wired() is false, so the
    // banner + prompt print and the kernel parks below — it never spins
    // hot. The loop's correctness is proven in kernel/src/shell.zig
    // against a scripted MockConsole (artifacts/m15-shell-core-loop.txt).
    // ------------------------------------------------------------------
    var m15 = M15Console{};
    const map_view = memmap.MapView.init(map_buffer.buffer, map_after_exit.info.descriptor_size, map_after_exit.info.len);
    // Physical page allocator (claims 3972 + 5162): arm the pool from the
    // captured map's conventional + loader + boot-services regions,
    // excluding the live kernel image, stack, handoff page, and captured
    // map buffer. Fixed BSS bitmap, no allocation; the `pages` monitor
    // command reports the pool. Not armed (silently) when the map declares
    // no poolable memory in span.
    const exclusions = [_]alloc.Exclusion{
        alloc.exclusion_from_bytes(handoff_rec.kernel_base, handoff_rec.kernel_size),
        alloc.exclusion_from_bytes(handoff_rec.stack_base, handoff_rec.stack_size),
        alloc.exclusion_from_bytes(@intFromPtr(handoff_rec), memmap.page_size),
        alloc.exclusion_from_bytes(@intFromPtr(map_buffer.buffer.ptr), map_buffer.buffer.len),
    };
    _ = alloc.init(map_view, &exclusions);
    // Milestone four (claim 2665): boot-time seed — post-MMU (after the
    // allocator arms), pull a fixed 64-byte seed from the REAL virtio
    // entropy device and key the CSPRNG. VZ resets virtio devices at
    // ExitBootServices (claim 6420), so the transport is re-armed here
    // first (the claim-6420 lesson applied to the entropy device; the live
    // gate's `entropy: seeded n=64` line is the proof the re-armed path
    // works). A failed read falls back to a deterministic key and reports
    // honestly — the live gate requires the real path.
    var seed_buf: [csprng.seed_len]u8 align(16) = undefined;
    // Claim 6420's lesson, verified live: VZ resets virtio devices at
    // ExitBootServices — the pre-re-arm status is printed so the host sees
    // the reset (0) before the re-arm restores DRIVER_OK and the seed read
    // delivers 64 real bytes.
    uart_puts("entropy: pre-rearm st=");
    uart_hex8(virtio_entropy.ent_status());
    uart_puts("\n");
    if (virtio_entropy.entropy_rearm() and virtio_entropy.entropy_read(&seed_buf)) {
        csprng.seed(&seed_buf);
        uart_puts("entropy: seeded n=64\n");
    } else {
        csprng.seed_fallback();
        uart_puts("entropy: seed failed n=0 (deterministic fallback)\n");
    }
    // M100b (issue #2307, ADR 0050): the virtio-blk data-disk path. One
    // DID-0x1042 function is the firmware's boot ESP — the kernel issues
    // it no requests at all, and the default boot stays byte-identical.
    // A SECOND function means the runner attached `--data-disk`: every
    // candidate is re-armed (claim 6420 — VZ resets virtio devices at
    // ExitBootServices), named with VIRTIO_BLK_T_GET_ID, and the one
    // answering `virelai-vlfs` is the data disk. A failed/absent match is
    // `no_disk` — the boot continues share-only, never wedged.
    if (virtio_blk.function_count > 1) {
        const armed = virtio_blk.blk_rearm();
        virtio_blk.blk_identify();
        var bi: usize = 0;
        while (bi < virtio_blk.function_count) : (bi += 1) {
            const f = &virtio_blk.functions[bi];
            uart_puts("blk: dev=");
            uart_hex(f.dev);
            uart_puts(" armed=");
            uart_puts(if (f.armed) "1" else "0");
            uart_puts(" flush=");
            uart_puts(if (f.flush_ok) "1" else "0");
            uart_puts(" id='");
            uart_puts(virtio_blk.function_id(bi));
            uart_puts("'");
            if (virtio_blk.vlfs_disk != null and virtio_blk.vlfs_disk.? == bi) {
                uart_puts(" vlfs");
            } else {
                uart_puts(" not_vlfs_disk");
            }
            uart_puts("\n");
        }
        if (virtio_blk.vlfs_disk) |_| {
            const sectors = virtio_blk.capacity_sectors() catch 0;
            uart_puts("disk: ");
            uart_hex(sectors);
            uart_puts(" sectors id=");
            uart_puts(virtio_blk.vlfs_disk_id);
            uart_puts("\n");
            blk_boot_probe(sectors);
            // M100d (issue #2309, ADR 0050 D1/D6): mount the data disk at
            // /disk. A refusal is named on the serial line and the boot
            // continues share-only — the mount is an enhancement, never a
            // requirement. M172d (#3037, ADR 0061): a sealed v2 volume
            // prompts for its passphrase on the console first — the
            // prompt's reads are echo-suppressed and the passphrase buffer
            // is zeroed (seal.zig owns the budget/timeout policy).
            const seal_ops = seal.PromptOps{
                .writeFn = sealPromptWrite,
                .readByteFn = sealPromptRead,
                .armedFn = sealPromptArmed,
                .nowFn = sealPromptNow,
                .hz = timer.freq,
                .nonceFn = sealPromptNonce,
                .rngReadyFn = sealPromptReady,
            };
            if (vlfs_disk.attachBlk(&seal_ops)) {
                uart_puts("vlfs: mounted /disk\n");
                // M100e (#2310): D5 replay evidence — a killed boot left
                // committed transactions in the journal and mount landed
                // them. 0 replays prints nothing (the common case).
                if (vlfs_disk.last_replayed > 0) {
                    uart_puts("vlfs: replayed ");
                    uart_hex(vlfs_disk.last_replayed);
                    uart_puts(" txn(s) from the journal\n");
                }
            } else {
                uart_puts("vlfs: mount refused ");
                uart_puts(vlfs_disk.last_refusal orelse "io_error");
                uart_puts("\n");
            }
        } else {
            uart_puts("blk: ");
            uart_hex(armed);
            uart_puts(" armed, no_disk (no 'virelai-vlfs' GET_ID match)\n");
        }
    }
    // Milestone five card N1 (claim 1373): re-arm the virtio-net transport
    // post-MMU (the claim-6420/2665 lesson — VZ resets virtio devices at
    // ExitBootServices, so the net device's status reads 0 and its queues
    // are dead until the re-arm). The pre-re-arm status is printed so the
    // host sees the reset (0) before the re-arm restores DRIVER_OK and TX
    // arms; the `net` monitor command then reports the observed DID/MAC/
    // queues/features. The default runner attaches NO network device, so
    // on every existing gate this whole block is skipped and the boot
    // output stays byte-identical.
    if (net_ready) {
        uart_puts("net: pre-rearm st=");
        uart_hex8(virtio_net.net_status());
        uart_puts("\n");
        _ = virtio_net.net_rearm();
        // Card N2 (claim 6076): supply the queue-0 RX buffer and kick so
        // the device can deliver host-injected frames. The `net: rx-armed`
        // serial line is the runner's `--net-inject` trigger (deterministic
        // — the host injects only once the buffer is guaranteed supplied,
        // not after a sleep).
        _ = virtio_net.net_rx_arm();
        uart_puts("net: rx-armed\n");
    }
    // Milestone six card G1 (claim 6053): re-arm the virtio-gpu transport
    // post-MMU (the claim-6420/2665 lesson — VZ resets some virtio devices
    // at ExitBootServices; blk/entropy reset to st=00, the net device does
    // NOT (st=0f observed) — the gpu answer is observed, not assumed: the
    // pre-rearm status is printed so the host sees it either way), then run
    // the spec 2D path to a flushed scanout (display info → resource →
    // backing → scanout → boot fill → transfer → flush). The `screen`
    // monitor command then re-fills. The default runner attaches NO
    // graphics device, so on every existing gate this whole block is
    // skipped and the boot output stays byte-identical.
    if (gpu_ready) {
        uart_puts("gpu: pre-rearm st=");
        uart_hex8(virtio_gpu.gpu_status());
        uart_puts("\n");
        if (virtio_gpu.gpu_rearm()) {
            if (virtio_gpu.gpu_setup()) {
                uart_puts("gpu: setup ok scanout=");
                uart_hex(virtio_gpu.gpu_scanout_w);
                uart_puts("x");
                uart_hex(virtio_gpu.gpu_scanout_h);
                uart_puts(" fmt=");
                uart_hex(virtio_gpu.format_b8g8r8x8);
                uart_puts("\n");
                // Milestone six card G3 (claim 1574): Road Pops — the
                // boot terminal goes graphical. The G2 one-shot boot
                // paint is replaced by a TEE console: the shell's OWN
                // banner + prompt + every reply now render on the
                // framebuffer through G2's text layer (the shell idle
                // loop drains one present per output batch; the tee's
                // FIRST present emits the G2 `text: boot banner
                // presented` evidence on serial, honestly — the boot
                // banner IS presented at that moment).
                fbtext.init();
                // M20-U11 (claim 5127): missing-glyph diagnostics log to
                // serial when the debug_font dev setting is on.
                fbtext.missing_glyph_log = &log_missing_glyph;
                // Card G5 (claim 1543): arm Driving Award — the window
                // manager. Road Pops (the terminal) registers as window 0
                // and a 1 Hz clock overlay as window 1; the compositor
                // repaints from the lowest dirty window up and pushes one
                // transfer + flush per batch. The Road Pops tee's present
                // target (rp_text_present) routes through the compositor.
                driving_award.arm();
                // Step 13 (Issue #213): boot splash — render once before Road Pops
                // takes over the terminal. Shows the system name + version
                // (busy-wait, no timer at this boot stage). M76a (#1674):
                // the splash then HOLDS — render_splash leaves
                // driving_award.splash_hold standing, so no kernel present
                // reaches the scanout until the seat binds it (silent
                // one-frame handoff) or the spec-stated bound expires (one
                // honest klog line), and Road Pops takes the screen back.
                driving_award.render_splash(3);
                // Claim 0015, Road Pops edition: a Target struct literal
                // with all-constant fields (ctx + &fn entries) is folded
                // into .rodata, whose &fn entries hold LINK-TIME absolute
                // addresses — wrong at the kernel's runtime load base
                // (observed live: the tee's first write jumped to the
                // link-time address of rp_text_put_bytes and faulted).
                // Build the Target in RAM, like ensure_vtable, so every
                // &fn resolves PC-relatively (ADRP) at any load base.
                var rp_target_storage: road_pops.Target = undefined;
                rp_target_storage.ctx = &rp_target_dummy;
                rp_target_storage.put_bytes = rp_text_put_bytes;
                rp_target_storage.present = rp_text_present;
                rp_target_storage.clear = rp_text_clear;
                road_pops.arm(m15.to_console(), rp_target_storage);
                uart_puts("roadpops: armed target=fbtext\n");
            } else {
                uart_puts("gpu: setup failed (");
                uart_puts(virtio_gpu.gpu_fail);
                uart_puts(")\n");
            }
        }
    }
    // Milestone fifteen card A1 (claim 6140): re-arm the virtio-snd
    // transport post-MMU (the claim-6420/2665 lesson — VZ resets SOME
    // virtio devices at ExitBootServices; blk/entropy reset to st=00, net
    // does NOT — the sound answer is observed, not assumed: st=0f
    // pre-rearm on the live runs, so the sound device is NOT reset, like
    // net/gpu; the pre-rearm status is printed so the host sees it either
    // way). The re-arm itself is unconditional and idempotent. A1 arms
    // the CONTROL queue (queue 0) and reaches DRIVER_OK; the PCM
    // playback path is card A2. The default runner attaches NO sound
    // device, so on every existing gate this whole block is skipped and
    // the boot output stays byte-identical.
    if (snd_ready) {
        uart_puts("snd: pre-rearm st=");
        uart_hex8(virtio_snd.snd_status());
        uart_puts("\n");
        if (virtio_snd.snd_rearm()) {
            uart_puts("snd: rearm ok st=");
            uart_hex8(virtio_snd.snd_status());
            uart_puts(" qoff=");
            uart_hex(virtio_snd.snd_queue_notify_off);
            uart_puts("\n");
            // Milestone fifteen card A4 (claim 3206): the BOOT CHIME — the
            // composition capstone's hearable welcome. The kernel plays a
            // short two-tone "ding-dong" through the proven A2 beep path
            // (snd_chime = snd_beep 660/150 + 880/220) the moment the
            // transport is live, so the device + playback are proven at the
            // earliest possible boot moment. Flag-gated the same way as the
            // transport: no `--sound` device → no chime → the default boot
            // stays byte-identical. A failure is reported honestly (never a
            // hang — every step's status is the record, the same fields the
            // monitor `beep` command reports).
            const chime_st = virtio_snd.snd_chime();
            if (chime_st == virtio_snd.S_OK) {
                uart_puts("chime: boot chime played (660+880)\n");
            } else {
                uart_puts("chime: boot chime failed (");
                uart_puts(virtio_snd.snd_fail);
                uart_puts(")\n");
            }
        } else {
            uart_puts("snd: rearm failed (");
            uart_puts(virtio_snd.snd_fail);
            uart_puts(")\n");
        }
    }
    // Milestone seven card I1 (claim 4272): initialize the XHCI host
    // controller post-MMU (register map + command/event rings + NO-OP + port
    // status). The pre-reset USBSTS is printed so the host sees whether VZ
    // reset the controller at ExitBootServices (observed, not assumed — the
    // gpu/blk/entropy `st=00` vs net `st=0f` question's XHCI answer). The
    // default runner attaches no input devices, so on every existing gate
    // this block is skipped and the boot output stays byte-identical.
    if (xhci_probed) {
        xhci.debug = uart_puts;
        xhci.debug_hex = uart_hex;
        if (xhci.xhci_init()) {
            xhci.debug = null;
            uart_puts("xhci: init ok base=");
            uart_hex(xhci.xhci_base);
            uart_puts(" caplen=");
            uart_hex(xhci.xhci_caplen);
            uart_puts(" ports=");
            uart_hex(xhci.hcsparams1_max_ports(xhci.xhci_hcsparams1));
            uart_puts(" pre-reset sts=");
            uart_hex(xhci.xhci_pre_reset_usbsts);
            uart_puts(" cmd=");
            uart_hex(xhci.xhci_pre_reset_usbcmd);
            uart_puts(" noop=");
            uart_puts(if (xhci.xhci_noop_done) "ok" else "fail");
            uart_puts("\n");
            // I2: the enumeration result (the gate's key-on marker + the
            // honest failure record).
            uart_puts("usb: enumerated=");
            uart_hex(xhci.enum_count);
            uart_puts(if (xhci.enum_done) " ok" else " fail");
            if (!xhci.enum_done and xhci.enum_fail.len > 0) {
                uart_puts(" (");
                uart_puts(xhci.enum_fail);
                uart_puts(")");
            }
            uart_puts("\n");
            // Card I3 (claim 6050): arm the keyboard/pointer event FIFO
            // once the interrupt-IN endpoints are up (the enumeration just
            // armed them). The `input: armed` line is the runner's
            // key-injection marker; until it prints the FIFO drain is a
            // no-op, so no key event can be lost.
            // U1 (M43): only when a HID device is present — a bulk-only
            // boot (the `--usb-msd` probe without `--input`) must not arm
            // an empty interrupt path (byte-identical HID boots otherwise).
            if (xhci.enum_done and xhci.enum_has_hid()) {
                input.arm();
                input.debug = uart_puts;
                input.debug_hex = uart_hex;
                uart_puts("input: armed\n");
            }
        } else {
            xhci.debug = null;
            uart_puts("xhci: init failed (");
            uart_puts(xhci.xhci_fail);
            uart_puts(")\n");
        }
    }
    // Claim 3693 (milestone-four follow-on): ASLR for the BOOT-time static
    // EL0 payload too. The pre-install user root (built inside
    // build_identity_map) maps the stack at the fixed userspace.stack_va;
    // now that the CSPRNG is seeded with REAL entropy, rebuild the root
    // with a randomized stack placement so the static payload — not just
    // exec'd programs (claim 2665) — runs with per-boot stack ASLR.
    // exec.rebuild_user_root is the single shared sequence (randomize →
    // map → clean → re-arm; see claims 6783/2665 for why it works
    // post-install). stack_len is the FULL .userbss section length (the
    // timer-preemption witness sits just past the 8 KiB stack, and its VA
    // is base-relative, so the rebuilt root must map it too). An unseeded
    // (fallback) boot skips the rebuild and keeps the fixed stack —
    // behavior unchanged there.
    if (csprng.seeded()) {
        // Issue #1214 review (boot-payload hang): map the WHOLE .userbss
        // SECTION, not the `user_stack` array — the linker may place
        // `user_timer_preemptions` (or padding) before the array, and both
        // the user-root mapping and `bss_user_va`'s arithmetic are
        // section-relative. Passing the array's physical address shifted
        // the mapping by one page: the payload's witness VA resolved to
        // the zeroed stack page and it never observed a preemption.
        if (exec.rebuild_user_root(user_text.base, user_text.len, user_stack.base, user_stack.len)) |aslr| {
            uart_puts("aslr: boot user stack=");
            uart_hex(aslr.stack_va);
            uart_puts("\n");
        } else {
            // Honest fallback: keep the fixed stack (the initial root still
            // maps it) and report the failed rebuild.
            userspace.set_stack_va(userspace.stack_va);
            uart_puts("aslr: boot user root rebuild failed (fixed stack)\n");
        }
    }
    const console_name = layout_name(console_kind);
    // Milestone six card G3 (claim 1574): the shell + monitor always run
    // on the Road Pops tee console. With the gpu transport ready (armed
    // above), output renders to serial AND the framebuffer; without it
    // (the default VM) the tee degrades to serial-only — byte-identical.
    if (!road_pops.is_armed()) road_pops.arm(m15.to_console(), null);
    // Card I3 (claim 6050) + G5 (claim 1543): feed the Road Pops tee's
    // read path from the keyboard event FIFO, gated on window focus (the
    // terminal must be focused for keyboard bytes to reach the line
    // editor). Serial stays the fallback. No-op without `--input` (the
    // default VM's read path is serial-only). Claim 9588: the custom-virtio
    // input channel feeds the SAME FIFO, so its pool being armed wires the
    // read source too — injected keys then reach the line editor exactly
    // like USB keys do.
    if (input.armed() or virtio_custom.input_armed) road_pops.set_read_source(rp_read_source);
    var mon = monitor.Monitor.init(
        road_pops.tee_console(),
        .{
            // Claim 0023: the shared handoff.zig type is used directly.
            .handoff = handoff_rec.*,
            .map = map_view,
            .console_name = console_name[0 .. console_name.len - 1],
        },
        machine.control(),
    );
    // #1072 (ADR 0020): give the terminal seam the kernel console as its
    // serial front-end. Nothing is attached by default, so the boot path is
    // unchanged until a process calls sys_tty_attach (D4).
    terminal.setRuntimeConsole(mon.console);
    // Claim 0015 diagnostic: mark the seam entry so a missing shell banner
    // is attributable to the seam setup vs. the shell write path.
    if (comptime build_options.nvram_console) {
        evidence.write_marker_var(st, marker_seam);
        // Stack + console-pointer probe: the banner write path crashed
        // without entering M15Console.writeFn, so record the state at the
        // seam (sp, vtable/ctx addresses, and a direct vtable dispatch).
        var sp: u64 = undefined;
        asm volatile ("mov %[sp], sp"
            : [sp] "=r" (sp),
        );
        uart_puts("[seam] sp=");
        uart_hex(sp);
        uart_puts(" base=");
        uart_hex(handoff_rec.stack_base);
        uart_puts(" ctx=");
        uart_hex(@intFromPtr(mon.console.ctx));
        uart_puts(" vt=");
        uart_hex(@intFromPtr(mon.console.vtable));
        uart_puts("\n");
        const probe_con = m15.to_console();
        probe_con.print_line("[seam] direct dispatch");
    }
    // Claim 5275: the first milestone-three tasks card — a tick-driven
    // round-robin scheduler. Task 0 is the EL1h shell/main task itself (its
    // context is captured on the first preemption); task 1 is the EL1h demo
    // worker on its own static stack; task 2 is the claim-8215 EL0t payload
    // with separate EL1 exception and EL0 execution stacks. Scheduling starts
    // only HERE, once the shell loop is the running context, so boot-time
    // printing (banner,
    // map, spike) is never preempted. The first tick then preempts the
    // shell, worker, and EL0 task run one quantum each — every timer PPI
    // (claim 9187) is a context switch.
    _ = scheduler.init();
    _ = scheduler.register_worker(@intFromPtr(&worker_entry));
    _ = scheduler.register_user(@intFromPtr(&userspace.entry), base);
    smp.init();
    smp.boot_secondary_cores();
    scheduler.start();
    shell.boot_and_park(&mon, m15.rx_wired());
    // No return after takeover. WFE is a terminal state, not a firmware call.
    // Note: with RX wired (nvram builds) boot_and_park loops forever, so
    // this flush is unreachable there — the trailing prompt is flushed by
    // readByteFn when the scripted session ends. Kept as a safety net for
    // the no-RX path, where boot_and_park returns after the prompt.
    if (comptime build_options.nvram_console) nvram_console.flush();
    halt_forever();
}

/// Claim 5275: the demo worker task. Runs in its own task context (one
/// quantum per tick): increments its advance counter, asks the shell idle
/// loop to report it (main-context console discipline — the worker itself
/// never prints), and spins a bounded delay so a 1 s quantum holds several
/// advances. Preempted by the next timer tick; never returns.
const worker_report_every: u64 = 64;
fn worker_entry() void {
    var local: u64 = 0;
    while (true) {
        local += 1;
        scheduler.note_advance();
        if (local % worker_report_every == 0) scheduler.request_report();
        var spins: usize = 0;
        while (spins < 2_000_000) : (spins += 1) asm volatile ("nop");
    }
}

const CapturedMap = struct {
    buffer: []align(8) u8,
    map: MemoryMapSlice,
};

fn capture_map(bs: *BootServices) !CapturedMap {
    const info = try bs.getMemoryMapInfo();
    if (info.descriptor_size == 0 or info.len > std.math.maxInt(usize) / info.descriptor_size) return error.OutOfResources;
    const map_bytes = info.len * info.descriptor_size;
    if (info.descriptor_size > std.math.maxInt(usize) / 64 or map_bytes > std.math.maxInt(usize) - 64 * info.descriptor_size) return error.OutOfResources;
    const extra = 64 * info.descriptor_size;
    const bytes = map_bytes + extra;
    const buffer = try bs.allocatePool(.loader_data, bytes);
    const map = try bs.getMemoryMap(buffer);
    return .{ .buffer = buffer, .map = map };
}

fn valid_handoff(base: u64, size: u64, st: *const SystemTable, handoff_rec: *const HandoffV2) bool {
    // Entry-time mirror checks (the struct against the x0/x2 register
    // arguments) + the struct-internal validation from handoff.zig
    // (magic/version/flags/stack-size/alignment/bounds). Same semantics as
    // the previous inline checks; the canonical rules live in handoff.zig.
    if (@intFromPtr(st) != handoff_rec.system_table) return false;
    if (handoff_rec.kernel_base != base or handoff_rec.kernel_size != size) return false;
    return handoff.validate(handoff_rec) == .none;
}

fn record_probe(base: u64, magic: u32, version: u32, device: u32, layout: u32) void {
    if (probe_count < probe_records.len) {
        probe_records[probe_count] = .{ .base = base, .magic = magic, .version = version, .device = device, .layout = layout };
        probe_count += 1;
    }
}

fn probe_serial(_: MemoryMapSlice, st: *const SystemTable) Candidate {
    // Selection happened PRE-EXIT in probe_serial_pre (post-exit reads of
    // the declared MMIO windows hang on VZ — claim 0013). This records the
    // stage marker and returns the pre-exit result so the banner/TX path
    // proceeds without any post-exit window read beyond TX itself.
    evidence.write_marker_var(st, marker_raw);
    return .{ .base = console_base, .kind = console_kind };
}

/// PRE-EXIT serial probe (claim 0013): scan the declared MMIO windows for a
/// PrimeCell UART. Run 5's raw dumps showed the 0x20050000 window carries
/// the standard PrimeCell CID block (0x0d/0xf0/0x05/0xb1 at +0xff0..0xffc)
/// with PL011-family PIDs (PID1=0x10, PID3=0x00, PID2 JEDEC nibble 0x4) but
/// PID0=0x31 instead of the textbook 0x11 — a VZ PL011-variant the old
/// probe's rigid `pid0 == 0x11` check rejected. Accept the CID+PID family
/// fingerprint instead. Pre-exit reads are deterministic (the pre-exit raw
/// dumps already read both windows safely); post-exit they hang.
fn probe_serial_pre(map: MemoryMapSlice, st: *const SystemTable) Candidate {
    probe_count = 0;
    // Claim 0013: the authoritative console is the virtio-pci device the
    // runner attaches (VZVirtioConsoleDeviceSerialPortConfiguration), found
    // via the MCFG ECAM base — not the EFI MMIO windows. It is preferred
    // whenever it initializes; the MMIO heuristics below remain as fallback
    // (the 0x20050000 PrimeCell UART is Apple's internal debug console, not
    // the serial attachment).
    if (virtio_console.virtio_pci_init(st)) {
        return .{ .base = virtio_console.vp_bar0, .kind = .virtio };
    }
    var it = map.iterator();
    while (it.next()) |desc| {
        if (desc.type != .memory_mapped_io and desc.type != .memory_mapped_io_port_space) continue;
        if (desc.number_of_pages == 0 or desc.number_of_pages > std.math.maxInt(u64) / 4096) continue;
        const bytes = desc.number_of_pages * 4096;
        if (desc.physical_start > std.math.maxInt(u64) - bytes) continue;
        const base = desc.physical_start;
        if (bytes < 0x1000) continue;

        const magic = mmio.mmio_read32(base);
        const version = mmio.mmio_read32(base + 4);
        const device = mmio.mmio_read32(base + 8);
        const vendor = mmio.mmio_read32(base + 12);
        if (magic == 0x74726976) { // "virt"
            record_probe(base, magic, version, device, vendor);
            evidence.dump_probe_line(0, base, magic, version, device, vendor);
            if ((version == 1 or version == 2) and device == 3 and vendor != 0) {
                evidence.dump_str("PRE: virtio-console candidate @");
                evidence.dump_hex(base);
                evidence.dump_str("\n");
                return .{ .base = base, .kind = .virtio };
            }
        }

        const cid0 = mmio.mmio_read32(base + 0xff0) & 0xff;
        const cid1 = mmio.mmio_read32(base + 0xff4) & 0xff;
        const cid2 = mmio.mmio_read32(base + 0xff8) & 0xff;
        const cid3 = mmio.mmio_read32(base + 0xffc) & 0xff;
        const pid0 = mmio.mmio_read32(base + 0xfe0) & 0xff;
        const pid1 = mmio.mmio_read32(base + 0xfe4) & 0xff;
        const pid2 = mmio.mmio_read32(base + 0xfe8) & 0xff;
        const pid3 = mmio.mmio_read32(base + 0xfec) & 0xff;
        const fr = mmio.mmio_read32(base + 0x18);
        if (cid0 != 0 or cid1 != 0 or cid2 != 0 or cid3 != 0 or pid0 != 0 or pid1 != 0 or pid2 != 0 or pid3 != 0 or fr != 0) {
            record_probe(base, pid0 | (pid1 << 8) | (pid2 << 16) | (pid3 << 24), fr, cid0 | (cid1 << 8) | (cid2 << 16) | (cid3 << 24), 0x504c3031); // PL01
            evidence.dump_pl011_line(0, base, pid0, pid1, pid2, fr);
        }
        if (cid0 == 0x0d and cid1 == 0xf0 and cid2 == 0x05 and cid3 == 0xb1 and pid1 == 0x10 and pid3 == 0x00 and (pid2 & 0x0f) == 0x04) {
            evidence.dump_str("PRE: PL011-family UART @");
            evidence.dump_hex(base);
            evidence.dump_str(" PID0=");
            evidence.dump_hex(pid0);
            evidence.dump_str("\n");
            return .{ .base = base, .kind = .pl011 };
        }
    }
    return .{ .base = 0, .kind = .none };
}

var pl011_initialized: bool = false;
fn pl011_init() void {
    const base = console_base;
    mmio.mmio_write32(base + 0x30, 0); // CR = 0 (disable UART)
    mmio.mmio_write32(base + 0x24, 13); // IBRD: 115200 baud @ 24 MHz reference
    mmio.mmio_write32(base + 0x28, 1); // FBRD
    mmio.mmio_write32(base + 0x2c, 0x70); // LCR_H: 8 data, 1 stop, no parity, FIFO enable
    mmio.mmio_write32(base + 0x30, 0x301); // CR: UARTEN | TXE | RXE
}

const serial_ring = @import("serial_ring.zig"); // Arc5 #243: capture last 512B for tombstones
const spinlock = @import("spinlock.zig"); // SMP user tasks (claim 2369): cross-core serial TX

/// Serial TX lock (SMP user tasks on secondary cores). Every byte reaches
/// the host through `uart_putc`; with the PE-0 tick gate lifted and user
/// tasks allowed on cores 1-3, two cores can print concurrently. The lock
/// is an IrqSaveSpinlock — IRQs stay MASKED for the whole write — because
/// SVC-context prints run with IRQs unmasked: without the mask, a timer
/// tick can preempt a print mid-line and the resumed shell (SAME core,
/// "holder") would write INSIDE the critical section (observed live:
/// `heap-oworker advances=18816` — the worker report merged into
/// MAIN.ELF's heap-ok line in verify-live-zc). Polled TX holds are short,
/// so a few microseconds of tick latency per line is nothing. The lock is
/// holder-tracked so same-core reentry (a fault dump inside a print, or a
/// nested uart_puts/uart_putc chain) proceeds instead of self-deadlocking
/// — the claim-9408 `sched_lock_holder` pattern. IRQ context never prints
/// (claim 9187 invariant), so a cross-core spinner always finds the holder
/// running and releasing promptly. `smp.max_cores` = nobody.
var serial_lock = spinlock.IrqSaveSpinlock{};
var serial_lock_holder: usize = smp.max_cores;
var serial_lock_daif: [smp.max_cores]u64 = [_]u64{ 0, 0, 0, 0 };

fn serial_lock_held() bool {
    return serial_lock_holder == smp.core_id();
}

fn serial_lock_acquire() void {
    // Mask IRQs + take the spinlock; remember the pre-mask DAIF so the
    // matching release restores it (reentrant calls never acquire, so the
    // per-core slot holds exactly one outstanding save per core).
    serial_lock_daif[smp.core_id()] = serial_lock.lock();
    serial_lock_holder = smp.core_id();
}

fn serial_lock_release() void {
    serial_lock_holder = smp.max_cores;
    serial_lock.unlock(serial_lock_daif[smp.core_id()]);
}

/// Whether the serial cursor sits at the start of a line right now. Every
/// byte reaches the TX through `uart_putc`, so tracking the delimiter here
/// captures all output (the kernel banner, the shell's prompt, process
/// stdout, tracer lines) from one choke point. A process launched by an
/// async exec can write while the shell is idle at a live prompt (`virelai> `
/// drawn, cursor mid-line); `uart_write_as` consults this flag so foreign
/// output starts on its own line instead of merging onto the prompt (which
/// swallowed the `elf: hello from HELLO.ELF` marker in the strace gate).
var serial_at_bol: bool = true;

/// WHOSE content the open (mid-line) serial line belongs to — `.kernel`
/// for shell/monitor/kernel output written through `uart_puts`, `.proc(pid)`
/// for a user program's sys_write through `process_stdout`. #2649 (the
/// M119f K-pass console/marker defects): a write arriving while a
/// DIFFERENT writer's line is mid-composition must close that line with a
/// newline first — bytes injected into a foreign open line fuse
/// irreversibly (no boundary to rejoin on; observed as `smp:` drain tails
/// fused onto an app's open line and marker halves fused when two writers
/// shared one physical line), while closing it keeps every physical line
/// a clean, recoverable unit.
///
/// This generalizes the claim-1714 fresh-line prepend, which only guarded
/// process-vs-prompt writes (and only through `process_stdout`): kernel
/// report lines used to land mid-composition on an app's open line
/// because nothing checked ownership on the kernel side. Owner identity
/// keeps the earlier pid rule's subtleties: a program composing one line
/// across several sys_write calls keeps its line open (the USER.BIN argv
/// preamble; the un-gated prepend split it, breaking verify-live-args), a
/// DIFFERENT pid must fresh-line (the HF4APP.ELF marker → DESKTOP.BIN
/// merge), a newline always clears ownership (a terminated line never
/// continues), and a kernel-side partial write (the prompt) owns the line
/// so the next process write fresh-lines.
const SerialLineOwner = union(enum) {
    kernel,
    proc: usize,
};
var serial_line_owner: ?SerialLineOwner = null;

fn serial_owner_is(a: ?SerialLineOwner, b: SerialLineOwner) bool {
    const o = a orelse return false;
    if (std.meta.activeTag(o) != std.meta.activeTag(b)) return false;
    return switch (o) {
        .kernel => true,
        .proc => |p| p == b.proc,
    };
}

fn uart_putc(byte: u8) void {
    // Cross-core serial TX (SMP user tasks): a standalone putc (uart_hex
    // and friends) is a kernel-class one-byte write and takes the lock +
    // open-line rule through uart_write_as; calls already under a held
    // lock (the uart_write_as byte loop) go straight to the sink. The
    // standalone form does NOT tail-flush — per-byte writers rely on the
    // leaf's own newline/buffer-full flush (16 flushed descriptors per
    // hex digit would be the regression).
    if (!serial_lock_held()) {
        uart_write_as_mode(.kernel, &[_]u8{byte}, false);
        return;
    }
    // Arc5 #243: capture every serial byte into the ring buffer so
    // crash tombstones can include the last 512 bytes of serial output.
    serial_ring.append(&[_]u8{byte});
    if (byte == '\n' or byte == '\r') {
        serial_at_bol = true;
    } else {
        serial_at_bol = false;
    }
    // Claim 0680 (issue #523 item 3): when the host armed the structured
    // console, every console byte is DUPLICATED onto custom-virtio queue 1
    // (line-buffered; partial lines flush from the idle seam). One cheap
    // branch while disarmed; serial output is untouched.
    virtio_custom.console_tee_putc(byte);
    // Claim 0015: in nvram-console builds every console byte rides the
    // NVRAM channel instead of the MMIO transport (which hangs post-exit
    // on VZ). Comptime-gated, so a default build is byte-identical.
    if (comptime build_options.nvram_console) {
        nvram_console.putc(byte);
        return;
    }
    switch (console_kind) {
        .pl011 => {
            if (!pl011_initialized) {
                pl011_init();
                pl011_initialized = true;
            }
            var timeout: usize = 0;
            while ((mmio.mmio_read32(console_base + 0x18) & (1 << 5)) != 0 and timeout < 1_000_000) : (timeout += 1) {}
            if (timeout < 1_000_000) mmio.mmio_write32(console_base, byte);
        },
        .ns16550 => {
            var timeout: usize = 0;
            while ((mmio.mmio_read8(console_base + 5) & (1 << 5)) == 0 and timeout < 1_000_000) : (timeout += 1) {}
            if (timeout < 1_000_000) mmio.mmio_write8(console_base, byte);
        },
        .virtio => {
            // Claim 0013: the VZ serial attachment is a modern virtio-pci
            // console (BAR0 transport, queue 1 TX). Bytes are line-buffered
            // and flushed as one descriptor — one kick per line instead of
            // one per byte.
            virtio_console.virtio_tx[virtio_console.vp_tx_len] = byte;
            virtio_console.vp_tx_len += 1;
            if (byte == '\n' or virtio_console.vp_tx_len >= virtio_console.virtio_tx.len) virtio_console.virtio_pci_flush();
        },
        .none => {},
    }
}

/// M100b (issue #2307, ADR 0050): the smallest honest proof of the RW
/// data-disk path — save the scratch sector, write the marker pattern,
/// FLUSH (a real barrier: submitted only after the write's completion and
/// waited out itself), read it back and verify, then restore the original
/// contents + FLUSH so the probe leaves the image untouched. The serial
/// line records every step's named refusal instead of hiding it.
// M172d (#3037, ADR 0061): the console/entropy/clock surface for the
// sealed-volume unseal prompt. Input comes from the virtio console RX
// queue — the same polled byte path the shell uses — and is never echoed.
fn sealPromptWrite(_: ?*anyopaque, bytes: []const u8) void {
    uart_puts(bytes);
}

fn sealPromptRead(_: ?*anyopaque) ?u8 {
    if (console_kind != .virtio) return null;
    return virtio_console.virtio_read_byte();
}

fn sealPromptArmed(_: ?*anyopaque) bool {
    return console_kind == .virtio and virtio_console.rx_armed();
}

fn sealPromptNow(_: ?*anyopaque) u64 {
    return timer.cntpct();
}

fn sealPromptNonce(_: ?*anyopaque, out: *[12]u8) void {
    csprng.random_bytes(out);
}

fn sealPromptReady(_: ?*anyopaque) bool {
    return csprng.seeded();
}

fn blk_boot_probe(capacity: u64) void {
    if (capacity == 0) {
        uart_puts("vlfs-probe: refused no_capacity\n");
        return;
    }
    const lba = blk_probe_lba(capacity);
    var saved: [virtio_blk.sector_len]u8 = undefined;
    var probe: [virtio_blk.sector_len]u8 = undefined;
    var back: [virtio_blk.sector_len]u8 = undefined;
    virtio_blk.read_sector(lba, &saved) catch |e| {
        blk_probe_fail("read", e);
        return;
    };
    const sig = "VIRELAI-VLFS-PROBE";
    @memcpy(probe[0..sig.len], sig);
    var i: usize = sig.len;
    while (i < probe.len) : (i += 1) probe[i] = @truncate(i *% 31 +% 7);
    virtio_blk.write_sector(lba, &probe) catch |e| {
        blk_probe_fail("write", e);
        return;
    };
    const flushed = blk: {
        virtio_blk.flush() catch |e| {
            // no_flush = the feature was never negotiated: recorded
            // honestly as flush=0, not dressed up as a barrier.
            if (e == error.no_flush) break :blk false;
            blk_probe_fail("flush", e);
            return;
        };
        break :blk true;
    };
    virtio_blk.read_sector(lba, &back) catch |e| {
        blk_probe_fail("readback", e);
        return;
    };
    const ok = std.mem.eql(u8, &back, &probe);
    virtio_blk.write_sector(lba, &saved) catch |e| {
        blk_probe_fail("restore", e);
        return;
    };
    if (flushed) virtio_blk.flush() catch |e| {
        blk_probe_fail("restore-flush", e);
        return;
    };
    uart_puts("vlfs-probe: write+readback ");
    uart_puts(if (ok) "ok" else "MISMATCH");
    uart_puts(" lba=");
    uart_hex(lba);
    uart_puts(" flush=");
    uart_puts(if (flushed) "1" else "0");
    uart_puts(" restored\n");
}

/// Issue #2381: the probe's target sector. A disk carrying a valid VLFS
/// superblock (magic + version + checksum — the field offsets pinned here
/// are ADR 0050's frozen v1 layout; vlfs.zig's own copies stay private to
/// the format reader) probes the LAST sector of the journal region's tail
/// block. The journal's live records span at most max_payload+2 blocks
/// from journal_first — one outstanding transaction, checkpointed at every
/// commit boundary — so the tail block is never replay-read and never
/// transaction-written: a crash mid-probe strands the marker where nothing
/// reads it, instead of in the volume's last data block (the old
/// capacity-1 target — live data when the volume spans the disk). A disk
/// without a valid superblock is a raw scratch disk and keeps the
/// last-sector probe; nothing lives there either.
fn blk_probe_lba(capacity: u64) u64 {
    const sb_magic: usize = 0;
    const sb_version: usize = 4;
    const sb_journal_first: usize = 40;
    const sb_journal_blocks: usize = 44;
    const sb_cksum: usize = 508;
    var sector: [virtio_blk.sector_len]u8 = undefined;
    var slot: u64 = 0;
    while (slot < 2) : (slot += 1) {
        const valid = blk: {
            virtio_blk.read_sector(slot * @as(u64, vlfs.sectors_per_block), &sector) catch break :blk false;
            if (vlfs.rd32(&sector, sb_magic) != vlfs.magic_super) break :blk false;
            const v = vlfs.rd32(&sector, sb_version);
            if (v != vlfs.format_version and v != vlfs.format_version_2) break :blk false;
            if (vlfs.rd32(&sector, sb_cksum) != vlfs.fnv32(sector[0..sb_cksum])) break :blk false;
            break :blk true;
        };
        if (!valid) continue;
        const journal_first = vlfs.rd32(&sector, sb_journal_first);
        const journal_blocks = vlfs.rd32(&sector, sb_journal_blocks);
        if (journal_first < 2 or journal_blocks == 0) continue;
        const tail = (@as(u64, journal_first) + journal_blocks) * vlfs.sectors_per_block - 1;
        if (tail < capacity) return tail;
    }
    return capacity - 1;
}

fn blk_probe_fail(stage: []const u8, e: virtio_blk.BlkError) void {
    uart_puts("vlfs-probe: ");
    uart_puts(stage);
    uart_puts(" ");
    uart_puts(@errorName(e));
    uart_puts("\n");
}

pub fn uart_puts(text: []const u8) void {
    uart_write_as_mode(.kernel, text, true);
}

fn uart_write_as(owner: SerialLineOwner, text: []const u8) void {
    uart_write_as_mode(owner, text, true);
}

/// One serial write under the TX lock, carrying the writer's identity so
/// the open-line ownership rule applies uniformly: a write that arrives
/// while a DIFFERENT writer's line is mid-composition closes that line
/// with a newline first — foreign bytes can then never fuse into it
/// (see `serial_line_owner`). The check, the close, the bytes, and the
/// ownership update all run inside one critical section, so writers on
/// different cores interleave only at line boundaries. A write that ends
/// mid-line leaves ownership to its writer; one that ends a line frees it.
/// Reentrant calls (a nested puts under a held lock) append in place —
/// the outer write owns the line state, and closing it mid-composition
/// would split the very write being interrupted. `tail_flush` carries the
/// claim-0013 prompt rule (a newline-less write must still reach the
/// host); standalone `uart_putc` passes false so per-byte callers stay on
/// the leaf's own newline/buffer-full flush cadence.
fn uart_write_as_mode(owner: SerialLineOwner, text: []const u8, tail_flush: bool) void {
    // The whole write is one critical section so a secondary core's
    // output never interleaves byte-wise with core 0's (holder-tracked:
    // a fault dump or nested puts on the same core proceeds).
    const reentrant = serial_lock_held();
    if (!reentrant) serial_lock_acquire();
    defer if (!reentrant) serial_lock_release();
    if (!reentrant and text.len > 0 and !serial_at_bol and !serial_owner_is(serial_line_owner, owner)) uart_putc('\n');
    for (text) |byte| uart_putc(byte);
    if (!reentrant and text.len > 0) {
        serial_line_owner = switch (text[text.len - 1]) {
            '\n', '\r' => null,
            else => owner,
        };
    }
    // Claim 0013: a virtio-console line without a trailing newline (e.g. the
    // shell's prompt) must still reach the host — flush any buffered bytes.
    // In nvram-console builds the virtio transport is never touched; the
    // NVRAM sink does its own newline/buffer-flush batching.
    if (comptime !build_options.nvram_console) {
        if (tail_flush and console_kind == .virtio and virtio_console.vp_tx_len > 0) virtio_console.virtio_pci_flush();
    }
}

/// M20-U11: serial side of the missing-glyph debug log (the framebuffer
/// text layer calls this only with debug_font on; writing through fbtext
/// itself would recurse).
fn log_missing_glyph(cp: u21) void {
    uart_puts("text: no glyph for U+");
    var shift: u4 = 12;
    while (true) : (shift -= 4) {
        const nibble: u8 = @intCast((cp >> shift) & 0xf);
        uart_putc(if (nibble < 10) '0' + nibble else 'a' + nibble - 10);
        if (shift == 0) break;
    }
    uart_puts("\n");
}

fn uart_hex(value: u64) void {
    uart_puts("0x");
    var shift: u6 = 60;
    while (true) : (shift -= 4) {
        const digit: u8 = @intCast((value >> shift) & 0xf);
        uart_putc(if (digit < 10) '0' + digit else 'a' + digit - 10);
        if (shift == 0) break;
    }
}

/// Two lowercase hex digits for one byte (no "0x", no separator) — the
/// claim-0828 reply readback prints each byte this way so arbitrary reply
/// contents (including non-printables) are represented faithfully.
fn uart_hex8(value: u8) void {
    uart_putc(hex_digit(value >> 4));
    uart_putc(hex_digit(value & 0xf));
}

/// Compact lowercase 4-digit hex (the vf probe line's needle style).
fn hex16(value: u16) [4]u8 {
    var out: [4]u8 = undefined;
    out[0] = hex_digit(@intCast((value >> 12) & 0xf));
    out[1] = hex_digit(@intCast((value >> 8) & 0xf));
    out[2] = hex_digit(@intCast((value >> 4) & 0xf));
    out[3] = hex_digit(@intCast(value & 0xf));
    return out;
}

fn hex_digit(v: u8) u8 {
    return if (v < 10) '0' + v else 'a' + v - 10;
}

fn layout_name(kind: Kind) []const u8 {
    return switch (kind) {
        .pl011 => "PL011\n",
        .ns16550 => "16550\n",
        .virtio => "virtio-console\n",
        .none => "none\n",
    };
}

fn halt_forever() noreturn {
    while (true) asm volatile ("wfe");
}

/// Walk the installed TTBR0 tables for `va` (4 K pages, L0-rooted) and
/// print the descriptor chain — diagnostic for the claim-0828 BAR window.
fn walk_print(tag: []const u8, va: u64) void {
    var ttbr0: u64 = undefined;
    asm volatile ("mrs %[v], ttbr0_el1"
        : [v] "=r" (ttbr0),
    );
    var addr = ttbr0 & ~@as(u64, 0xfff);
    var level: u8 = 0;
    var desc: u64 = 0;
    var ok = true;
    while (level <= 3) {
        const shift: u6 = switch (level) {
            0 => 39,
            1 => 30,
            2 => 21,
            else => 12,
        };
        const index = (va >> shift) & 0x1ff;
        desc = @as(*const volatile u64, @ptrFromInt(addr + index * 8)).*;
        if ((desc & 3) == 0) {
            ok = false;
            break;
        }
        if ((desc & 3) == 1 or level == 3) break; // block or page
        addr = desc & ~@as(u64, 0xfff);
        level += 1;
    }
    uart_puts("cvspike: walk ");
    uart_puts(tag);
    uart_puts(" va=");
    uart_hex(va);
    uart_puts(" l");
    uart_puts(&.{'0' + level});
    uart_puts("=");
    uart_hex(desc);
    uart_puts(" ");
    uart_puts(if (ok) "ok" else "INVALID");
    uart_puts("\n");
}

// ---------------------------------------------------------------------------
// Claims 0828/4374/9492/9737/4837: custom-virtio transport experiment
// ---------------------------------------------------------------------------

/// SPI window armed for the spike device's used-ring notification (INTID
/// unknown in advance — 32..191 covers VZ's virtio SPIs; the report names
/// whatever actually fires).
const cv_spi_first: u32 = 32;
const cv_spi_count: u32 = 160;
/// Bounded wait budget per exchange: kick -> host notification -> dequeue
/// -> reply write -> returnToQueue -> used ring + SPI assert -> vector,
/// all sub-millisecond on the host.
const cv_wait_budget: usize = 16_000_000;
/// The small-exchange reply buffer (the write descriptor; the host echoes
/// the 16-byte payload back into it — claims 0828/4374).
var cv_reply_buf: [virtio_custom.reply_cap]u8 align(16) = undefined;
/// The claim-9492 big payload + reply buffers: 12,340 bytes across three
/// device-read descriptors; the host reassembles the spans and echoes the
/// full payload back, which this guest verifies byte-for-byte.
var cv_big_payload: [virtio_custom.big_payload_len]u8 align(16) = undefined;
var cv_big_reply: [virtio_custom.big_payload_len]u8 align(16) = undefined;
/// Guest log lines sent over queue 1 (claim 4837). Stored as raw BYTE
/// arrays (no slice pointers): the kernel is a flat image loaded at a
/// runtime-chosen base, so any .rodata table of baked slice pointers (as
/// an array of string literals would be) holds unrelocated image-relative
/// addresses and faults when dereferenced (observed: q1 data abort at the
/// "cvlog-1" string address). Raw [N:0]u8 arrays contain only bytes —
/// every reference goes through a runtime-computed PC-relative address.
const cv_log_lines = [_][7:0]u8{ "cvlog-1".*, "cvlog-2".*, "cvlog-3".* };

// ---------------------------------------------------------------------------
// Claim 3141 (--cvc-echo): the HOST-initiated push echo over queue 2.
// Byte-exact protocol constants. Raw BYTE arrays again (no baked slice
// pointers — see cv_log_lines).
// ---------------------------------------------------------------------------

/// The host's request, written into the pre-armed receive buffer.
const cv_push_req = [13]u8{ 'C', 'V', 'C', '-', 'P', 'I', 'N', 'G', '-', '0', 'x', '4', '2' };
/// The guest's reply staging (the request echoed verbatim) + its ack buffer
/// (the host writes "OK:13").
var cv_push_reply: [virtio_custom.push_buf_len]u8 align(16) = undefined;
var cv_push_ack_buf: [16]u8 align(16) = @as([16]u8, @splat(@as(u8, 0)));

/// Claim 9588: the input channel's decode hook. Kind-1 payloads are raw
/// 8-byte HID keyboard boot reports; feeding them through the SAME decode
/// function an XHCI report takes makes injected keys ordinary keys
/// downstream — per-process event FIFO (sys_poll_event / sys_wait_event)
/// when an app window owns focus, console bytes + `input` counters at the
/// terminal.
/// Claim 1747: the queue-3 drain, moved OFF the console reader and onto
/// the scheduler's idle pass. poll_input() used to be reachable only
/// through M15Console.readByteFn, so the drain ran only when the SHELL
/// idle loop happened to poll for a byte. That made input liveness
/// depend on the shell making progress: with the serial-attached
/// terminal and a shell-side synchronous GPU wait the loop is not
/// guaranteed to run, completions are never scanned, and injected chords
/// never reach the guest. OBSERVED on go-dogfood boot 04: the host
/// enqueued every chord message and reported `sequence complete`, yet no
/// `gotabwm: key` / `charmhello: key` / resize followed, while scheduler
/// and WM output continued. Bounded and non-blocking: safe in main
/// context on core 0 between the reap and the idle spin.
///
/// #1757: service the kind-4 snapshot request in the SAME pass that armed
/// it — this is where claim 0680's "after the input pump" order moved when
/// the drain moved here. Two observed failures shaped the placement: a
/// request serviced only from the console reader could sit pending past
/// the run's end (the shell loop's servicing lagged the burst by seconds
/// on live-term-depth run 03), and a request serviced WITHOUT the chord
/// path's synchronous present shipped pre-composite frames. Both are
/// closed: the hygiene chords composite before their markers print, so
/// the pixels are on the scanout before the request can even exist, and
/// this pass streams them the moment the request lands. Bounded: one
/// stream of ~113 queue-4 exchanges with per-submit timeouts — the same
/// inline cost the console reader always paid; serialized against the
/// shell-loop caller by service_snapshot's own lock.
fn cv_idle_input_pump() void {
    if (virtio_custom.cv_ready and virtio_custom.input_armed) virtio_custom.poll_input();
    if (virtio_custom.snap_pending) virtio_custom.service_snapshot();
}

fn cv_input_dispatch(rep: []const u8) void {
    input.decode_keyboard_report(rep);
}

/// Claim 9367: the input channel's POINTER decode hook. Kind-2 payloads are
/// raw 5-byte absolute-pointer reports; feeding them through the SAME
/// decode function an XHCI pointer report takes makes injected pointers
/// ordinary pointers downstream — cursor moves, `dui` click-to-focus, and
/// the `input` ptr-* counters — with no USB device attached at all.
fn cv_pointer_dispatch(rep: []const u8) void {
    input.decode_pointer_report(rep);
    // M124f follow-up (boot-08 drag flake): fan the JUST-DECODED report to
    // a registered WM per report, not per idle pass. poll_input drains the
    // whole used ring in one pass, so the pointer_tick state sample could
    // only ever see the last write of a batch — a press batched with its
    // first held-move fanned the move's coordinates as the down edge and
    // the gesture died unarmed. wm_fan_pointer dedups (mapped-pixel state
    // unchanged = no fan), so a repeat report costs nothing and the tick's
    // own sampling fan below it stays a harmless no-op. Keyboard parity:
    // decode_keyboard_report has fanned per report (wm_key_hook) all along.
    // The decoded state — not the raw rep — is what fans, so the report can
    // never drift from what decode consumed.
    if (driving_award.wm_owns_input) {
        const st = input.pointer_state();
        if (st.valid) driving_award.wm_fan_pointer(st.x, st.y, st.buttons);
    }
}

/// Drive the spike device: init (probe + negotiate + DRIVER_OK + both
/// queues armed), arm the SPI window, then run the transport experiment:
/// (1) claim 4374 — two batches of four CONCURRENT in-flight exchanges on
/// queue 0 with descriptor recycling (the second batch must reallocate the
/// same head indices); (2) claim 9492 — a 12,340-byte payload across
/// three read descriptors with host reassembly + full byte-for-byte reply
/// verification; (3) claim 4837 — guest log lines over queue 1 with host
/// echo; (4) claim 9737's feature report (what VZ offers, what was
/// accepted, the negotiated kick width) with the negotiated
/// notification/layout behavior exercised. Then report the accumulated
/// used-ring IRQ observation and disarm the window.
fn custom_virtio_spike() void {
    // Cap decode FIRST, one short line per cap (a line longer than the
    // 128-byte TX buffer flushes mid-line and the follow-up flush can drop
    // on a still-full ring, claim 0016).
    for (virtio_custom.cv_caps[0..virtio_custom.cv_cap_count]) |cap| {
        uart_puts("cvspike: cap @");
        uart_hex(cap.base);
        uart_puts(" head=");
        uart_hex(cap.head);
        uart_puts(" t=");
        uart_hex(cap.cfg_type);
        uart_puts(" bar=");
        uart_hex(cap.bar);
        uart_puts(" off=");
        uart_hex(cap.off);
        uart_puts("\n");
    }
    uart_puts("cvspike: probe dev=");
    uart_hex(virtio_custom.cv_dev);
    uart_puts(" common=");
    uart_hex(virtio_custom.cv_common);
    uart_puts(" notify=");
    uart_hex(virtio_custom.cv_notify);
    uart_puts(" bar=");
    uart_hex(virtio_custom.cv_bar);
    uart_puts(" b0=");
    uart_hex(virtio_custom.cv_bars[0]);
    uart_puts(" b2=");
    uart_hex(virtio_custom.cv_bars[2]);
    uart_puts(" cp=");
    uart_hex(virtio_custom.cv_cap_ptr);
    uart_puts(" nc=");
    uart_hex(virtio_custom.cv_cap_count);
    uart_puts("\n");
    // Verify the identity map actually resolves the transport BARs (the
    // console's 0x100010000 vs the custom's 0x100020000): walk TTBR0.
    walk_print("console-bar", virtio_console.vp_common & ~@as(u64, 0xfff));
    walk_print("cv-bar", virtio_custom.cv_common & ~@as(u64, 0xfff));
    if (!virtio_custom.init()) {
        uart_puts("cvspike: init failed (transport not armed)\n");
        return;
    }
    uart_puts("cvspike: init ok\n");
    gic.arm_spi_window(cv_spi_first, cv_spi_count);
    virtio_custom.reset_irq_observation();

    uart_puts("cvspike: dev=");
    uart_hex(virtio_custom.cv_dev);
    uart_puts(" did=0x1082 common=");
    uart_hex(virtio_custom.cv_common);
    uart_puts(" notify=");
    uart_hex(virtio_custom.cv_notify);
    uart_puts(" qoff=");
    uart_hex(virtio_custom.cv_rings[0].notify_off);
    uart_puts(" qoff1=");
    uart_hex(virtio_custom.cv_rings[1].notify_off);
    uart_puts(" ready=1\n");

    // Claim 9737: the feature report — what VZ offers (64-bit device
    // features), what the driver accepted, and the kick format the
    // negotiation produced (honest either way).
    uart_puts("cvspike: feat="); // uart_hex emits the 0x prefix itself
    uart_hex(virtio_custom.device_features);
    uart_puts(" acc=");
    uart_hex(virtio_custom.guest_features);
    uart_puts(" nd=");
    uart_puts(if (virtio_custom.has_notification_data) "1" else "0");
    uart_puts(" al=");
    uart_puts(if (virtio_custom.has_any_layout) "1" else "0");
    uart_puts(" notify=");
    uart_puts(if (virtio_custom.has_notification_data) "32bit" else "16bit");
    uart_puts("\n");

    virtio_custom.init_payload(); // BSS copy — .rodata pointers are image-relative
    uart_puts("cvspike: payload=\"");
    uart_puts(virtio_custom.payload[0..virtio_custom.payload_len]);
    uart_puts("\" len=");
    uart_hex(virtio_custom.payload_len);
    uart_puts("\n");

    // ---- Claim 4374: concurrent in-flight exchanges + recycling --------
    // Batch 1: four elements submitted back-to-back WITHOUT waiting — the
    // ring allocator hands out four 2-descriptor chains (heads 0,2,4,6 on
    // the reversed-LIFO free list; low indices, the claim-0828-proven
    // pattern). The host drains them per notification and echoes each
    // payload. Batch 2 runs after batch 1 is freed and MUST reallocate the
    // exact same head indices (the recycle proof).
    var ok_q0 = true;
    var batch1: [4]u16 = undefined;
    var batch2: [4]u16 = undefined;
    // Scatter via the BSS staging array (an anonymous `&.{...}` slice
    // array folds into .rodata with baked image-relative pointers).
    virtio_custom.cv_scatter[0] = virtio_custom.payload[0..virtio_custom.payload_len];
    for (0..4) |i| {
        const h = virtio_custom.submit_ex(0, virtio_custom.cv_scatter[0..1], cv_reply_buf[0..virtio_custom.payload_len], false) orelse {
            ok_q0 = false;
            break;
        };
        batch1[i] = h;
    }
    for (0..4) |i| {
        const n = virtio_custom.wait(0, batch1[i], cv_wait_budget, cv_reply_buf[0..virtio_custom.payload_len]) orelse {
            ok_q0 = false;
            continue;
        };
        const echo_ok = @as(usize, n) == virtio_custom.payload_len and std.mem.eql(u8, cv_reply_buf[0..virtio_custom.payload_len], virtio_custom.payload[0..virtio_custom.payload_len]);
        if (!echo_ok) ok_q0 = false;
        uart_puts("cvspike: q0 xchg=");
        uart_putc('0' + @as(u8, @intCast(i + 1)));
        uart_puts(" n=0x10 echo=");
        uart_puts(if (echo_ok) "ok" else "bad");
        uart_puts("\n");
    }
    // Free in REVERSE order: the LIFO free list returns the last-freed
    // chain's head first, so reversing the frees makes batch 2's heads
    // come back in the same order as batch 1's (the recycle comparison).
    var fi: usize = 4;
    while (fi > 0) {
        fi -= 1;
        virtio_custom.free_chain_q(0, batch1[fi]);
    }
    for (0..4) |i| {
        const h = virtio_custom.submit_ex(0, virtio_custom.cv_scatter[0..1], cv_reply_buf[0..virtio_custom.payload_len], false) orelse {
            ok_q0 = false;
            break;
        };
        batch2[i] = h;
    }
    var recycle = true;
    for (0..4) |i| {
        const n = virtio_custom.wait(0, batch2[i], cv_wait_budget, cv_reply_buf[0..virtio_custom.payload_len]) orelse {
            ok_q0 = false;
            recycle = false;
            continue;
        };
        if (!(@as(usize, n) == virtio_custom.payload_len and std.mem.eql(u8, cv_reply_buf[0..virtio_custom.payload_len], virtio_custom.payload[0..virtio_custom.payload_len]))) ok_q0 = false;
        if (batch2[i] != batch1[i]) recycle = false;
    }
    for (batch2) |h| virtio_custom.free_chain_q(0, h);
    uart_puts("cvspike: q0 heads=");
    uart_hex(batch1[0]);
    uart_puts(",");
    uart_hex(batch1[1]);
    uart_puts(",");
    uart_hex(batch1[2]);
    uart_puts(",");
    uart_hex(batch1[3]);
    uart_puts(" recycle=");
    uart_puts(if (recycle) "1" else "0");
    uart_puts("\n");

    // ---- Claim 9492: multi-descriptor >4 KiB payload --------------------
    // 12,340 bytes (0x3034) of a deterministic non-printable pattern across
    // three device-read descriptors (4 KiB + 4 KiB + 4148 B) + one
    // device-write reply descriptor of the same size. With ANY_LAYOUT
    // negotiated (claim 9737) the reply descriptor is posted FIRST in the
    // chain (any layout, Virtio 1.3 §2.7.6); otherwise classic order. The
    // host reassembles the three read spans and echoes the full payload;
    // this guest compares it byte-for-byte.
    for (&cv_big_payload, 0..) |*b, i| b.* = @truncate((i % 251) + 1);
    // Build the 3-part scatter in BSS (anonymous slice arrays are
    // .rodata-folded with baked pointers — see cv_scatter).
    virtio_custom.cv_scatter[0] = cv_big_payload[0..4096];
    virtio_custom.cv_scatter[1] = cv_big_payload[4096..8192];
    virtio_custom.cv_scatter[2] = cv_big_payload[8192..virtio_custom.big_payload_len];
    var big_ok = false;
    if (virtio_custom.submit_ex(0, virtio_custom.cv_scatter[0..3], cv_big_reply[0..], virtio_custom.has_any_layout)) |big_head| {
        if (virtio_custom.wait(0, big_head, cv_wait_budget, cv_big_reply[0..])) |n| {
            big_ok = @as(usize, n) == virtio_custom.big_payload_len and std.mem.eql(u8, cv_big_reply[0..], cv_big_payload[0..]);
        } else {
            ok_q0 = false;
        }
        virtio_custom.free_chain_q(0, big_head);
    } else {
        ok_q0 = false;
    }
    if (!big_ok) ok_q0 = false;
    uart_puts("cvspike: q0 big n=0x3034 echo=");
    uart_puts(if (big_ok) "ok" else "bad");
    uart_puts("\n");
    uart_puts("cvspike: q0 ok=");
    uart_puts(if (ok_q0) "1" else "0");
    uart_puts("\n");

    // ---- Claim 4837: guest log transport over queue 1 -------------------
    // Each line rides one queue-1 element; the host prints it verbatim to
    // its stdout and replies ACK:<len>, which cvlog_puts verifies. The
    // transport is polled (no IRQ dependency), so it is robust against
    // VZ's per-burst used-buffer IRQ coalescing (claim 0828).
    var log_count: usize = 0;
    for (cv_log_lines) |line| {
        // `line` is a stack copy of the raw bytes; its slice is valid for
        // the synchronous cvlog_puts call (which copies it into BSS).
        if (!virtio_custom.cvlog_puts(line[0..])) continue;
        log_count += 1;
        uart_puts("cvspike: q1 log=\"");
        uart_puts(virtio_custom.cv_log_line[0..virtio_custom.cv_log_line_len]);
        uart_puts("\" ack=\"");
        uart_puts(virtio_custom.cv_log_ack_buf[0..virtio_custom.cv_log_ack_len]);
        uart_puts("\" n=");
        uart_hex(virtio_custom.used_len);
        uart_puts("\n");
    }
    uart_puts("cvspike: q1 ok=");
    uart_putc('0' + @as(u8, @intCast(log_count)));
    uart_puts("\n");

    // ---- Claim 3141: HOST-initiated push echo over queue 2 --------------
    // Only when the device exposed the third queue (the runner's --cvc-echo
    // attaches it; the classic --custom-virtio world stays two-queue and
    // skips this block with one honest line). Sequence: pre-arm ONE
    // device-write receive buffer + kick, signal readiness over queue 1
    // ("cvc-push-armed"), and the HOST delegate — when it processes that
    // line — enqueues the 13-byte request into the buffer at a time of its
    // choosing. This guest then reads the request back verbatim, replies on
    // queue 2, and verifies the host's OK:<len> ack.
    var push_ok = false;
    if (virtio_custom.has_push_queue) {
        if (!virtio_custom.arm_push()) {
            uart_puts("cvspike: q2 arm failed\n");
        } else {
            uart_puts("cvspike: q2 armed rx=1 handle=");
            uart_hex(virtio_custom.push_rx_handle);
            uart_puts("\n");
            if (!virtio_custom.cvlog_puts("cvc-push-armed")) {
                uart_puts("cvspike: q2 armed-signal failed\n");
            } else if (virtio_custom.wait_any_push(cv_wait_budget)) |rx| {
                const n: usize = @min(@as(usize, rx.len), virtio_custom.push_req_len);
                const handle_ok = rx.handle == virtio_custom.push_rx_handle;
                const req_ok = @as(usize, rx.len) == cv_push_req.len and std.mem.eql(u8, virtio_custom.push_rx_buf[0..n], &cv_push_req);
                uart_puts("cvspike: q2 req=\"CVC-PING-0x42\" n=");
                uart_hex(rx.len);
                uart_puts(if (req_ok) " req=ok" else " req=bad");
                uart_puts(if (handle_ok) " handle=ok\n" else " handle=bad\n");
                if (req_ok and handle_ok) {
                    // Reply: echo the request verbatim (BSS staging slice)
                    // plus a write buffer for the host's ack.
                    @memcpy(cv_push_reply[0..n], virtio_custom.push_rx_buf[0..n]);
                    virtio_custom.cv_scatter[0] = cv_push_reply[0..n];
                    if (virtio_custom.submit_ex(virtio_custom.push_qidx, virtio_custom.cv_scatter[0..1], cv_push_ack_buf[0..], false)) |rh| {
                        var ack_ok = false;
                        if (virtio_custom.wait(virtio_custom.push_qidx, rh, cv_wait_budget, cv_push_ack_buf[0..])) |an| {
                            ack_ok = an == 5 and std.mem.eql(u8, cv_push_ack_buf[0..5], "OK:13");
                        }
                        virtio_custom.free_chain_q(virtio_custom.push_qidx, rh);
                        uart_puts("cvspike: q2 rsp=\"CVC-PING-0x42\" ack=\"");
                        const al: usize = @min(@as(usize, virtio_custom.used_len), cv_push_ack_buf.len);
                        uart_puts(cv_push_ack_buf[0..al]);
                        uart_puts("\" ok=");
                        uart_puts(if (ack_ok) "1" else "0");
                        uart_puts("\n");
                        push_ok = ack_ok;
                    } else {
                        uart_puts("cvspike: q2 reply submit failed\n");
                    }
                }
            } else {
                uart_puts("cvspike: q2 timeout (no host push observed)\n");
            }
        }
    } else {
        uart_puts("cvspike: q2 absent (two-queue device)\n");
    }
    uart_puts("cvspike: q2 ok=");
    uart_puts(if (push_ok) "1" else "0");
    uart_puts("\n");

    // ---- Claim 9588: the INPUT channel over queue 3 ---------------------
    // Only when the device exposed the fourth queue (the runner's
    // --via-virtio attaches it; smaller shapes skip this block with one
    // honest line). Wire the decode hook FIRST (injected keys must decode
    // from the first completion on), then pre-arm the receive pool; the
    // host injects only after a shell marker, so the pool is guaranteed
    // live long before the first message. Claim 1747: completions are
    // pumped by poll_input() from the scheduler's idle pass
    // (scheduler.on_idle_pass), NOT the shell idle loop's RX seam.
    virtio_custom.on_input_report = &cv_input_dispatch;
    virtio_custom.on_pointer_report = &cv_pointer_dispatch;
    // Claim 1747: the drain rides the scheduler's idle pass, not the
    // console reader — one owner for the ring, and input liveness no
    // longer depends on the shell idle loop running.
    scheduler.on_idle_pass = cv_idle_input_pump;
    if (virtio_custom.has_input_queue) {
        if (!virtio_custom.arm_input_pool()) {
            uart_puts("cvspike: q3 arm failed\n");
        } else {
            uart_puts("cvspike: q3 armed bufs=");
            uart_hex(virtio_custom.input_pool_count);
            uart_puts("\n");
            // Claim 0680: the pool is live — tell the host, which answers
            // by enqueueing the kind-3 console-control message (arming the
            // structured-console tee) when --cvc-console-file was passed.
            // Event-driven like the claim-3141 "cvc-push-armed" trigger:
            // no timing dance.
            _ = virtio_custom.cvlog_puts("cvconsole-ready");
        }
    } else {
        uart_puts("cvspike: q3 absent\n");
    }

    // ---- M34 HF1 (issues #735/#736): the HOST FILE CHANNEL over queue 5.
    // Only when the runner's --cvc-file attached the sixth queue; default
    // boots keep one honest line. VF_PROBE proves the ONE unproven
    // transport fact — a full 32 KiB device-WRITE reply (claim 0680
    // proved 32 KiB device-reads; the claim-9492 echo is 12,340 bytes) —
    // with two exchanges so chain reuse + the ring free count are proven
    // at full scale (the claim-0680 leak class).
    if (virtio_custom.has_file_queue) {
        const pr = virtio_file.probe_spike();
        uart_puts("vf: probe 32k ");
        uart_puts(if (pr.ok) "ok" else "FAILED");
        uart_puts(" len=0x");
        uart_puts(hex16(virtio_file.probe_dlen)[0..]);
        if (pr.ok) {
            uart_puts(" cksum=0x");
            uart_puts(hex16(pr.cksum)[0..]);
        }
        uart_puts(" free=");
        uart_puts(hex16(pr.free)[0..]);
        uart_puts("\n");
        // M34 HF5 (issue #739): re-load settings from the share — the
        // share IS the settings home. M34 HF6 (issue #740): the /data
        // migration is gone (its job finished in HF5; the share is the
        // only store). No-op on default boots. M66b (#1444): a file that
        // is present but corrupt (no valid schema header — the partial
        // in-place write shape) is REFUSED: one honest boot line, and the
        // compiled defaults stay in force.
        _ = settings.load_from_share();
        if (settings.last_load_refused) {
            uart_puts("settings: SETTINGS.TXT refused (defaults in force)\n");
        }
        // M50 TS2 (issue #1136, ADR 0024 D3): the ownership/mode table
        // shares this arming point — the queue-5 probe above arms it. A
        // boot with no `OWNERS.TXT` stays byte-identical (no line).
        if (file_table.load_trust_from_share()) uart_puts("owners: OWNERS.TXT loaded\n");
        // M50 TS5 (issue #1139, ADR 0024 D8): the secret store loads at the
        // SAME arming point. `init_from_share` registers `SECRETS.TXT` as a
        // secret-class path BY CONSTRUCTION before reading a byte (fail
        // closed when the bounded metadata table cannot hold the class) and
        // is a silent no-op without a host channel or file — no secret is
        // read at boot on a default share, and no boot line is emitted
        // (boot-default-unchanged).
        _ = secret.init_from_share();
        // M113c (#2419, ADR 0054 Part II): the grant table loads at the
        // SAME arming point, after OWNERS.TXT. `init_from_share`
        // registers `GRANTS.TXT` as secret-class BY CONSTRUCTION before
        // reading a byte — a file ABI call can never read or modify it —
        // then parses `#v1` fail-closed (a malformed row poisons its
        // name; a non-`#v1` schema poisons every name it lists). An
        // absent file leaves an empty table and the audit posture —
        // no boot line, boot-default unchanged.
        _ = grant.init_from_share();
    } else {
        uart_puts("vf: queue 5 absent (no host file channel)\n");
    }

    // The used-ring advances are observed by poll (fast); the device IRQs
    // travel through the GIC + vector and can trail them. Give the
    // notifications a bounded window to assert, so the report names how
    // many IRQs the whole experiment actually delivered (VZ coalesces per
    // burst — claim 0828 — so expect a small count, honest either way).
    var drain: usize = 0;
    while (drain < cv_wait_budget and virtio_custom.irq_count[0] < 1) : (drain += 1) {} // claim 7339: per-core; SPIs land on PE 0

    uart_puts("cvspike: irq=");
    uart_hex(virtio_custom.irq_count[0]);
    if (virtio_custom.irq_count[0] > 0) {
        uart_puts(" first="); // uart_hex emits the 0x prefix itself
        uart_hex(virtio_custom.irq_first[0]);
        uart_puts(" spi=");
        uart_hex(virtio_custom.irq_first[0]);
    } else {
        uart_puts(" first=none");
    }
    uart_puts(" armed=");
    uart_hex(cv_spi_first);
    uart_puts("..");
    uart_hex(cv_spi_first + cv_spi_count - 1);
    uart_puts("\n");

    gic.disarm_spi_window(cv_spi_first, cv_spi_count);
}

/// Console writer for the claim-9746 exception report. Wraps the polled
/// uart; a no-op until the console is probed (console_kind == .none).
fn exception_report_writer(text: []const u8) void {
    uart_puts(text);
}

/// `write_fn` (process stdout) seam. `exception_report_writer` forwards to
/// uart verbatim; this wrapper starts the output on a fresh serial line
/// when the cursor is mid-line on FOREIGN content — the case where an
/// async-exec'd program writes while the shell is idle at a drawn prompt.
/// Without it the program's first line merges onto the `virelai> ` prompt
/// and the exact-line marker grep misses it (the strace gate). The
/// prefixed newline flushes the buffered virtio prompt line first, then
/// the program's output lands at column 0. When the shell already sits at
/// a fresh line (the common foreground case) nothing is prepended.
fn process_stdout(text: []const u8) void {
    // Claim 1714 + #2649: the whole thing — fresh-line check, the closing
    // newline when the open line belongs to a different writer (the shell's
    // prompt, kernel prints, ANOTHER process's partial line), this write's
    // bytes, and the ownership update — is ONE critical section. The old
    // shape made the prepend decision outside the lock and issued the
    // close + the body as two separate uart_puts calls, so a foreign write
    // could still land between them and fuse (the M119f K-pass signature).
    // Owner identity also keeps the claim-1714/merge subtleties: a program
    // composing one line across several sys_write calls (USER.BIN's argv
    // preamble) stays contiguous, while a DIFFERENT process's partial line
    // is never continued.
    uart_write_as(.{ .proc = scheduler.current_id() }, text);
}

/// Claim 9187 IRQ chain, registered as the exception module's dispatcher:
/// ack from the GIC, handle the timer tick if the INTID is the timer's
/// PPI (re-arming the comparator), then EOI. Runs in IRQ context with a
/// register frame on the stack — NO console access (the heartbeat prints
/// from the shell idle loop, where a print cannot re-enter the polled
/// virtio TX path mid-flush). Claim 5275: on a timer PPI the scheduler
/// tick runs before the EOI; it stages the next task's restore frame
/// (exceptions.resume_frame) and programs ELR/SPSR, but the actual SP
/// switch happens in the vector stub (`mov sp, x0`) only after this
/// function returns — so the EOI is still issued on the interrupted
/// task's stack, which is harmless (the CPU interface is task-agnostic).
/// Claim 0828: every non-timer INTID is recorded into the custom-virtio
/// spike's observation window (an increment + first-INTID store,
/// console-free); in default builds no SPI is armed so the branch never
/// fires.
fn irq_dispatch() void {
    const intid = gic.ack();
    if (gic.is_spurious(intid)) {
        // #1261: a spurious ack means the interrupt was SIGNALED but not
        // delivered as a real one (or was raced to zero by another core).
        // Invisible after this point — without this record a storm of
        // spurious acks is indistinguishable from silence.
        forensics.note(.spur, intid);
        return;
    }
    gic.note_irq(intid);
    // #1278: record the delivery itself. This runs in IRQ context, which is
    // exactly why `note` may not print — the record is emitted by whatever
    // console line the guest prints next, so the tail of a dying boot's serial
    // log shows the interrupts it was servicing when it stopped.
    forensics.note(.irq, intid);
    if (intid < 16) {
        smp.handle_sgi(intid);
        // M70b (#1454): the RESCHEDULE SGI is the wake-target nudge — a
        // parked secondary exits WFE and claims the woken task NOW (the
        // same seam tick's parked branch runs) instead of waiting for its
        // next 1 Hz PPI. Kept here rather than inside smp.handle_sgi so
        // the SMP module stays free of a scheduler dependency.
        if (intid == smp.SGI_IPI_RESCHEDULE) scheduler.ipi_reschedule();
    } else if (timer.is_ppi(intid)) {
        if (smp.core_id() == 0) {
            timer.handle(); // core-0 timekeeping authority (tick record + re-arm)
        } else {
            timer.arm(); // secondary core: re-arm only — no tick record
        }
        // SMP lift (claim 8477 follow-up): every core runs the tick; on
        // secondary cores it runs ONLY the switch machinery on its own
        // per-core staging (global timekeeping/registries stay core-0).
        scheduler.tick();
    } else {
        virtio_custom.note_irq(intid);
    }
    gic.eoi(intid);
    // #1965: a device wake on the worker's own core uses this IRQ's frame
    // immediately. Other tasks and the timer cadence are unchanged.
    _ = scheduler.irq_exit_reschedule();
}

fn print_pre_exit_error(st: *const SystemTable, msg: []const u8) void {
    if (st.con_out) |out| {
        var wide: [128:0]u16 = undefined;
        for (msg, 0..) |byte, index| wide[index] = byte;
        wide[msg.len] = 0;
        _ = out.outputString(&wide) catch {};
    }
}

// ===========================================================================
// M1.5 console & shell core (agent B) — prompt-loop seam support.
// Additive section; the takeover path above is byte-identical.
// ===========================================================================

/// Console adapter over the polled TX uart. `readByte`/`rx_wired` dispatch
/// to the live virtio receive queue when the console is the virtio device
/// (claim 6684; the shell loop's correctness is also proven against a
/// scripted MockConsole in `kernel/src/shell.zig`). For the PL011/16550
/// fallback consoles RX stays an unimplemented null stub — no device
/// register is read on that path.
const M15Console = struct {
    const Self = @This();

    // Claim 0015 root cause: the vtable is built at runtime into BSS, NOT
    // as a const in .rodata. The kernel ELF is linked at address 0 with no
    // relocation sections and the flat loader copies the image to a
    // runtime-chosen base (observed 0x7e4d1000), so a const vtable would
    // hold link-time absolute function addresses (observed: write=0x44c4,
    // should be base+0x44c4) and the first dispatch would jump into the
    // weeds — the claim-0015 seam crash (chunk 30 persisted, the first
    // vtable write never did; writeFn was never entered). Building the
    // table in RAM makes every `&fn` resolve PC-relatively (ADRP), which is
    // correct at any load base. Host tests never caught this because macOS
    // relocates test binaries; the flat kernel loader does not.
    var vtable_storage: console.Console.VTable = undefined;
    var vtable_ready = false;

    fn ensure_vtable() *const console.Console.VTable {
        if (!vtable_ready) {
            vtable_storage = .{
                .write = writeFn,
                .flush = flushFn,
                .readByte = readByteFn,
                .pushByte = pushByteFn,
            };
            vtable_ready = true;
        }
        return &vtable_storage;
    }

    // Claim 0015: in nvram-console builds the shell loop runs a scripted
    // session. The input is a STATIC kernel-side byte buffer (the same
    // technique the mock transcript uses), NOT host keystrokes — host RX
    // stays unclaimed. It proves the real command loop executes post-exit
    // on VZ and its output is observable through the NVRAM channel. The
    // script is compile-time elided in default builds.
    script_pos: usize = 0,

    fn writeFn(_: *anyopaque, bytes: []const u8) void {
        uart_puts(bytes);
    }

    fn flushFn(_: *anyopaque) void {
        if (comptime build_options.nvram_console) nvram_console.flush();
    }

    fn readByteFn(ctx: *anyopaque) ?u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (comptime build_options.nvram_console) {
            if (self.script_pos < nvram_script.len) {
                const byte = nvram_script[self.script_pos];
                self.script_pos += 1;
                return byte;
            }
            // Script exhausted: persist any buffered output (the trailing
            // prompt has no newline) on the first idle poll, then stay idle.
            nvram_console.flush();
            return null;
        }
        // Claim 6684: live RX through the polled virtio receive queue
        // (queue 0). Runs whenever the console is the virtio device — post-MMU
        // the transport is reachable (claim 1517). Never blocks.
        // Claim 1747: the custom-virtio input channel is NO LONGER pumped
        // here. It used to be, which tied the queue-3 drain to the shell
        // idle loop calling readByte — and that loop is not guaranteed to
        // run (serial-attached terminal + a shell-side synchronous GPU
        // wait), so completions could sit unscanned and injected chords
        // never arrive. The drain moved to the scheduler's idle pass
        // (cv_idle_input_pump), which also leaves this reader with no
        // dependency on the device being armed.
        // Claim 0680: service a pending framebuffer snapshot request (set
        // by a kind-4 control message) and flush any partial console-tee
        // line (the prompt case) — both once per idle tick, after the
        // input pump so the freshest composite is what ships.
        if (virtio_custom.snap_pending) virtio_custom.service_snapshot();
        virtio_custom.console_tee_flush_partial();
        if (console_kind == .virtio) return virtio_console.virtio_read_byte();
        return null;
    }

    /// Input pushback for the serial front-end's detach handover: requeue a
    /// byte the dead session pumped but never read. virtio only — the
    /// UART fallback has no RX path to requeue onto.
    fn pushByteFn(_: *anyopaque, b: u8) bool {
        if (console_kind != .virtio) return false;
        return virtio_console.rx_pushback(b);
    }

    fn to_console(self: *Self) console.Console {
        return .{ .ctx = self, .vtable = ensure_vtable() };
    }

    /// True when an input source is wired so the shell loop runs instead
    /// of parking. Nvram-console builds run the scripted session; default
    /// builds run the live loop when the virtio receive queue is armed
    /// (claim 6684). Otherwise the shell prints banner + prompt and the
    /// kernel parks.
    fn rx_wired(self: *Self) bool {
        _ = self;
        if (comptime build_options.nvram_console) return true;
        return console_kind == .virtio and virtio_console.rx_armed();
    }
};

/// Claim 0015: the scripted session served by `M15Console.readByte` in
/// nvram-console builds — the same shape of input the mock transcript test
/// feeds (help/version/mem/echo), proving real command execution post-exit.
const nvram_script = if (build_options.nvram_console)
    "version\nmem\necho nvram-console-ok\nhelp\n"
else
    "";
