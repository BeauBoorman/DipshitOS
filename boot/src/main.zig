//! VirelaiOS boot application (the loader).
//!
//! A minimal AArch64 UEFI application. It prints a fixed two-line message to
//! the UEFI Simple Text Output protocol (ConOut), writes the same two lines
//! to `\BOOTED.TXT` on the ESP (execution evidence -- Apple's VZ firmware
//! routes no console text anywhere visible), then -- milestone one -- loads
//! the separate kernel image `\KERNEL.BIN` from the ESP via the UEFI Simple
//! File System protocol, allocates memory with Boot Services
//! (AllocatePages, EfiLoaderCode so the pages are executable), copies the
//! image CONTENT there -- the format header is parsed but NOT loaded into
//! RAM, so the kernel's content sits at base+0 where its PC-relative
//! addressing (ADR and ADRP) resolves correctly; see ADR 0002. A KRN2 image
//! (issue #1042) also carries an absolute-relocation table that is applied
//! before the jump. Then it flushes
//! the data cache and invalidates the instruction cache (the same
//! maintenance the firmware's LoadImage performs), and jumps to the
//! kernel's entry point. The kernel writes its own evidence
//! (`\KERNEL.TXT`) and returns; the loader then returns to the firmware
//! (EFI_SUCCESS). The loader also writes `\LOADER.TXT` (loader-observed
//! placement of the kernel) and `\MEMMAP.TXT` (the EFI memory map) as
//! host-observable evidence.
//!
//! Kernel image format v1 and the handoff ABI are documented in
//! docs/decisions/0002-kernel-handoff.md and ADR 0004. The stub remains
//! pure UEFI services throughout: no libc, no POSIX, no filesystem driver
//! of our own. It allocates the v2 kernel stack and handoff record but never
//! calls ExitBootServices itself.
//!
//! Zig 0.17.0 adjustment: older Zig examples exported `efi_main` with
//! `callconv(.win64)`. Zig 0.17's `std.start` for the `uefi` OS target
//! instead exports `EfiMain` (callconv(.c), which on AArch64 is AAPCS64) and
//! calls our `pub fn main() void`. It installs the firmware-provided EFI
//! System Table into `std.os.uefi.system_table` before main runs; that is
//! where we read ConOut and Boot Services from.

const std = @import("std");
const uefi = std.os.uefi;
const build_options = @import("build_options");
const efi_time = @import("efi_time.zig"); // #1058: pure EFI_TIME -> Unix epoch
// M113b (ADR 0054 Part I): the measured-boot primitive — the same
// kernel-local SHA-256 the kernel's `measure.zig` carries (one
// implementation, imported here as a named build import), and the
// generated `kernel_digest` module holding the expected raw SHA-256 of
// KERNEL.BIN that build.zig computes after elf2bin.
const measure = @import("measure");
const kernel_digest = @import("kernel_digest");

/// Convert a comptime ASCII string into a null-terminated UTF-16LE array as
/// required by the EFI APIs. (All of our strings are pure ASCII.)
fn utf16z(comptime s: []const u8) [s.len + 1:0]u16 {
    var buf: [s.len + 1:0]u16 = undefined;
    for (s, 0..) |c, i| buf[i] = c;
    buf[s.len] = 0;
    return buf;
}

const line_banner = utf16z("VIRELAIOS BOOTLOADER\r\n");
const line_confirm = utf16z("firmware has agreed to cooperate\r\n");
const line_loading = utf16z("loading kernel from \\KERNEL.BIN\r\n");
const line_jumping = utf16z("jumping to kernel entry point\r\n");
const line_rc_ok = utf16z("kernel handoff complete (rc=0)\r\n");
const line_rc_bad = utf16z("kernel returned nonzero rc\r\n");
const marker_path = utf16z("\\BOOTED.TXT");
const marker_text = "VIRELAIOS BOOTLOADER\nfirmware has agreed to cooperate\n";
// Loader trace: where the kernel image landed, written before the jump. The
// kernel writes its own observed base into KERNEL.TXT; the two must match
// (cross-check of the handoff ABI).
const loader_trace_path = utf16z("\\LOADER.TXT");
// EFI memory map evidence (types and attributes of every region).
const memmap_path = utf16z("\\MEMMAP.TXT");
const rc_path = utf16z("\\RC.TXT");

// Kernel image format (docs/decisions/0002-kernel-handoff.md):
//   v1 "DSK1": u32 magic = 0x314B5344, u32 flags = 0,
//              u64 entry_offset (file-relative), u64 image_size, content.
//   v2 "KRN2" (issue #1042): the v1 fields, then
//              u64 reloc_offset, u64 reloc_count, content, then
//              reloc_count × { u64 offset, u64 value, u32 width, u32 pad }.
//              The loader writes (value + base) as `width` bytes at content
//              offset `offset` before the cache flush — the absolute
//              (base-0) references PC-relative codegen cannot fix.
const kernel_path = utf16z("\\KERNEL.BIN");
const kernel_magic: u32 = 0x314B5344;
const kernel_magic_reloc: u32 = 0x324E524B;
const kernel_header_size: usize = 24;
const kernel_header_size_reloc: usize = 40;
const kernel_reloc_entry_size: usize = 24;
// M129b (#2611): the sanity cap grew 16 → 32 MiB — the 64-slot process
// registry adds ~1.6 MiB of fixed BSS (each descriptor inlines a
// `dynamic_pages` record table) and pushed the image past 16 MiB.
// Still only a sanity cap: the loader allocates from any free UEFI
// Boot Services region, so no layout bound sits behind it.
const kernel_max_size: u64 = 32 * 1024 * 1024; // sanity cap for this milestone
// M113b (ADR 0054): the loader's own image path on the ESP — the
// self-measurement source for the `stage=loader` receipt digest.
const loader_image_path = utf16z("\\EFI\\BOOT\\BOOTAA64.EFI");
// The named KERNEL.BIN refusal (ADR 0054 D3): ESP receipt + ConOut line,
// then return-to-firmware halt. The NVRAM `VirelaiBoot` variable is the
// host-observable copy — under the gate harness the ESP writes land in a
// discarded ASIF overlay, while the per-run variable store persists.
const refused_path = utf16z("\\REFUSED.TXT");
const refused_text = "kernel_hash_mismatch\n";
const line_refused = utf16z("refused: kernel_hash_mismatch\r\n");
const boot_variable_name = utf16z("VirelaiBoot");
const boot_variable_refused = "refused=kernel_hash_mismatch";
// The project's variable vendor GUID (M2M2_VIRELAIOS-M — the same GUID the
// kernel's marker ladder writes under; mirrored from kernel/evidence.zig).
const virelai_vendor_guid = uefi.Guid{
    .time_low = 0x4d324d32,
    .time_mid = 0x5f44,
    .time_high_and_version = 0x4950,
    .clock_seq_high_and_reserved = 0x53,
    .clock_seq_low = 0x48,
    .node = .{ 0x49, 0x54, 0x4f, 0x53, 0x2d, 0x4d },
};

/// Handoff contract v2 (ADR 0004 D5). The stub allocates this record in a
/// dedicated EfiLoaderData page and passes its address in x3. Mirrored from
/// kernel/src/handoff.zig — the two move together on every version bump.
const HandoffV2 = extern struct {
    magic: u32,
    version: u32,
    kernel_base: u64,
    kernel_size: u64,
    system_table: u64,
    image_handle: u64,
    stack_base: u64,
    stack_size: u64,
    flags: u64,
    boot_epoch_secs: u64,
    /// v4 additive (#2418, ADR 0054 Part I): the loader's measured
    /// Authenticode SHA-256 of `\EFI\BOOT\BOOTAA64.EFI` (zeros when
    /// `measured_ok` bit0 is clear) and the raw-file SHA-256 of
    /// `\KERNEL.BIN` it verified before jumping (zeros when bit1 is
    /// clear). The kernel republishes both on the chain receipt — it never
    /// re-reads the boot volume.
    measured_loader: [32]u8,
    measured_kernel: [32]u8,
    measured_ok: u64,
};
const handoff_magic: u32 = 0x324B5344; // "DSK2"
const handoff_version: u32 = 4;
/// #1058: sentinel for "no wall-clock epoch from firmware".
const no_boot_epoch: u64 = efi_time.no_epoch;
const kernel_stack_size: usize = 16 * 1024;

/// #1058: read the firmware clock through EFI RuntimeServices.GetTime and
/// convert the broken-down face to Unix wall-clock seconds. Best effort — a
/// failed/absent/garbage clock records `no_boot_epoch` (the kernel's honest
/// uptime fallback) and never aborts the handoff.
fn read_boot_epoch(st: *const uefi.tables.SystemTable) u64 {
    const got = st.runtime_services.getTime() catch return no_boot_epoch;
    const t = got[0];
    return efi_time.toEpochSecs(t.year, t.month, t.day, t.hour, t.minute, t.second) orelse no_boot_epoch;
}

pub fn main() void {
    const st = uefi.system_table;

    // 1. Primary action: print via the UEFI Simple Text Output protocol.
    if (st.con_out) |con_out| {
        _ = con_out.outputString(&line_banner) catch {};
        _ = con_out.outputString(&line_confirm) catch {};
    }

    // 2. Evidence: write the same message to \BOOTED.TXT on the ESP using
    //    the firmware's Simple File System protocol. Best effort only.
    write_marker(st);

    // 3. Milestone one: load \KERNEL.BIN and transfer control to it.
    load_and_enter_kernel(st);

    // Wait safely for a short while (a pure, memory-free busy loop) so any
    // text stays visible, then fall through and return to the firmware.
    wait_a_moment();
}

/// Locate the volume the firmware loaded us from, open \BOOTED.TXT and write
/// the confirmation text. Uses only UEFI Boot Services + File protocols.
/// Any failure is silently ignored: the app must run even if the firmware
/// provides no writable filesystem.
fn write_marker(st: *const uefi.tables.SystemTable) void {
    const boot_services = st.boot_services orelse return;

    const loaded_image = (boot_services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch null) orelse return;
    const device_handle = loaded_image.device_handle orelse return;

    const fs = (boot_services.handleProtocol(uefi.protocol.SimpleFileSystem, device_handle) catch null) orelse return;
    const root = fs.openVolume() catch return;
    defer root.close() catch {};

    const marker = root.open(&marker_path, .read_write_create, .{}) catch return;
    defer marker.close() catch {};

    _ = marker.write(marker_text) catch {};
    marker.flush() catch {};
}

/// Milestone one: read \KERNEL.BIN from the ESP, allocate pages with Boot
/// Services, copy the image there, make the instruction stream see it, and
/// jump to its entry point (handoff ABI: x0 = image base, x1 = image size,
/// x2 = System Table, x3 = handoff-v2 page; only a pre-exit failure returns
/// a u64 status). Best effort: if anything is missing or malformed, the loader
/// quietly returns to the firmware.
fn load_and_enter_kernel(st: *const uefi.tables.SystemTable) void {
    const boot_services = st.boot_services orelse return;

    // Evidence: dump the EFI memory map (types + attributes) to \MEMMAP.TXT.
    dump_memory_map(st);

    const loaded_image = (boot_services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch null) orelse return;
    const device_handle = loaded_image.device_handle orelse return;

    const fs = (boot_services.handleProtocol(uefi.protocol.SimpleFileSystem, device_handle) catch null) orelse return;
    const root = fs.openVolume() catch return;
    defer root.close() catch {};

    // M113b (ADR 0054 D2): self-measurement for the `stage=loader` chain
    // receipt. The loader's own digest is the PE/COFF Authenticode hash —
    // the convention the firmware db pins under Secure Boot — so the same
    // file the firmware just verified is re-measured here and carried to
    // the kernel in the v4 handoff. Best effort: a failed read leaves the
    // digest zeroed and the receipt says `unmeasured`.
    var measured_loader_digest = @as([32]u8, @splat(0));
    var measured_ok: u64 = 0;
    if (measure_loader_image(root, boot_services)) |d| {
        measured_loader_digest = d;
        measured_ok |= 1;
    }

    const kernel_file = root.open(&kernel_path, .read, .{}) catch return;
    defer kernel_file.close() catch {};

    // M113b: the KERNEL.BIN measurement. Every byte of the file is hashed
    // as it is consumed — header, content, the KRN2 relocation table, and
    // any tail past image_size — so the pin covers the whole file, not
    // only the span the header declares.
    var kernel_hasher = measure.Sha256.init();

    // 1. Read the format header (a KRN2-sized buffer; only the fields the
    //    magic implies are used). See the constants block for the layout.
    var header: [kernel_header_size_reloc]u8 = undefined;
    if (kernel_file.read(&header) catch return < kernel_header_size) return;

    const magic = std.mem.readInt(u32, header[0..4], .little);
    const is_reloc = magic == kernel_magic_reloc;
    if (magic != kernel_magic and !is_reloc) return;
    const header_size: usize = if (is_reloc) kernel_header_size_reloc else kernel_header_size;
    const entry_offset = std.mem.readInt(u64, header[8..16], .little);
    const image_size = std.mem.readInt(u64, header[16..24], .little);
    const reloc_offset: u64 = if (is_reloc) std.mem.readInt(u64, header[24..32], .little) else 0;
    const reloc_count: u64 = if (is_reloc) std.mem.readInt(u64, header[32..40], .little) else 0;
    if (image_size < header_size or image_size > kernel_max_size) return;
    // The entry is file-relative (includes the header) and must land inside
    // the loadable content; anything else means a malformed image.
    if (entry_offset < header_size) return;
    if (entry_offset >= image_size) return;
    // Content runs from the end of the header to the relocation table (KRN2)
    // or the end of the file (DSK1).
    const content_end: u64 = if (is_reloc) reloc_offset else image_size;
    if (content_end <= header_size or content_end > image_size) return;
    const content_size: usize = @intCast(content_end - header_size);
    kernel_hasher.update(header[0..header_size]);

    // 2. Allocate exactly enough pages (Boot Services, any free region).
    //    AllocatePages returns 4K-aligned pages -- the base alignment that
    //    the kernel's PC-relative addressing relies on. We use
    //    EfiLoaderCode (not EfiLoaderData) because firmware may map
    //    non-code memory types as execute-never, and we are about to jump
    //    to this memory. Real UEFI bootloaders do the same.
    const pages_needed: usize = @intCast((image_size + 4095) / 4096);
    const pages = boot_services.allocatePages(.any, .loader_code, pages_needed) catch return;
    const dst: [*]u8 = @ptrCast(pages.ptr);
    const base: u64 = @intFromPtr(dst);

    // 3. Read the CONTENT into the allocation at offset 0. The header is
    //    parsed but NOT loaded into RAM: the kernel is linked with VMA 0 ==
    //    content start, so placing the content at base+0 makes every
    //    PC-relative reference (both ADR and ADRP+ADD) resolve to the right
    //    byte. Loading the file verbatim (content at base+header_size) is
    //    what caused the KERNEL.TXT scramble: ADR refs stayed correct
    //    because the header rides inside the PC, but ADRP+ADD refs compute
    //    (PC page) + VMA offset and silently drop the header, reading the
    //    kernel's own .rodata early (see ADR 0002, known issue [resolved]).
    kernel_file.setPosition(header_size) catch return;
    const dst_slice = dst[0..content_size];
    var filled: usize = 0;
    while (filled < content_size) {
        const got = kernel_file.read(dst_slice[filled..]) catch return;
        if (got == 0) return; // short read: image truncated
        filled += got;
    }
    // The content bytes as they sit in the FILE — hashed before the
    // relocation pass writes (value + base) into them.
    kernel_hasher.update(dst_slice);

    // 3a. KRN2: apply the absolute-relocation table. LLVM emits base-0
    //     pointer tables (jump tables, outlined-function pointer tables) that
    //     PC-relative addressing cannot fix; each entry writes
    //     (value + kernel_base) into the content. See issue #1042 and ADR
    //     0019. A malformed table aborts the handoff (the loader returns).
    //     The table bytes are file bytes too — hashed as they are read.
    if (is_reloc) {
        if (!apply_relocations(kernel_file, dst_slice, base, reloc_offset, reloc_count, &kernel_hasher)) return;
    }

    // 3a-ii. Tail: any bytes the file carries past `image_size` are part of
    //    the pinned image — a file that smuggles extra data must not hash
    //    equal to the canonical KERNEL.BIN.
    {
        var tail: [4096]u8 = undefined;
        while (true) {
            const got = kernel_file.read(&tail) catch break;
            if (got == 0) break;
            kernel_hasher.update(tail[0..got]);
        }
    }

    // 3a-iii. The pin (ADR 0054 D2): the measured digest must equal the
    //    raw SHA-256 of the KERNEL.BIN this loader was built against —
    //    baked into the image as the generated `kernel_digest` import. A
    //    mismatch is the named refusal `kernel_hash_mismatch`: an ESP
    //    receipt + ConOut line + the NVRAM copy, then return to firmware.
    var kernel_digest_actual: [measure.digest_len]u8 = undefined;
    kernel_hasher.final(&kernel_digest_actual);
    if (!std.mem.eql(u8, &kernel_digest_actual, &kernel_digest.kernel_sha256)) {
        refuse_kernel_hash_mismatch(st, root);
        return;
    }
    measured_ok |= 2;

    if (st.con_out) |con_out| {
        _ = con_out.outputString(&line_loading) catch {};
        _ = con_out.outputString(&line_jumping) catch {};
    }

    // 3b. Loader trace: record base/size/entry on the ESP before the jump.
    write_loader_trace(root, &header, dst, base, image_size, entry_offset, reloc_count);

    // 3c. The content bytes were written by data accesses; make the
    //     instruction stream see them (clean D-cache to PoU, invalidate
    //     I-cache, DSB, ISB -- the same maintenance the firmware's LoadImage
    //     performs before transferring control to a loaded image).
    //     Per-byte iteration so no cache-line-size assumption is made; the
    //     kernel image is tiny.
    flush_to_pou(dst, content_size);

    // 4. Allocate the kernel-owned stack and the v2 handoff page. Both are
    //    4K-aligned EfiLoaderData allocations adopted by the kernel after
    //    ExitBootServices. The stack is exactly 16 KiB as required by ADR 0004.
    const stack_pages = boot_services.allocatePages(.any, .loader_data, kernel_stack_size / 4096) catch return;
    const handoff_pages = boot_services.allocatePages(.any, .loader_data, 1) catch return;
    const stack_base: u64 = @intFromPtr(stack_pages.ptr);
    const handoff: *HandoffV2 = @ptrCast(@alignCast(handoff_pages.ptr));
    handoff.* = .{
        .magic = if (build_options.bad_handoff) 0 else handoff_magic,
        .version = handoff_version,
        .kernel_base = base,
        .kernel_size = image_size,
        .system_table = @intFromPtr(st),
        .image_handle = @intFromPtr(uefi.handle),
        .stack_base = stack_base,
        .stack_size = kernel_stack_size,
        .flags = 0,
        .boot_epoch_secs = read_boot_epoch(st),
        .measured_loader = measured_loader_digest,
        .measured_kernel = kernel_digest_actual,
        .measured_ok = measured_ok,
    };

    // 5. Jump. entry_offset is file-relative (includes the header); with
    //    content at base+0 the in-RAM entry is base + (entry_offset - header_size).
    const EntryFn = *const fn (
        base: u64,
        size: u64,
        st: *const uefi.tables.SystemTable,
        handoff_ptr: *HandoffV2,
    ) callconv(.c) u64;
    const entry: EntryFn = @ptrFromInt(base + (entry_offset - header_size));
    const rc = entry(base, image_size, st, handoff);
    write_rc(root, rc);

    if (st.con_out) |con_out| {
        _ = con_out.outputString(if (rc == 0) &line_rc_ok else &line_rc_bad) catch {};
    }
}

/// Write \MEMMAP.TXT: one line per EFI memory map descriptor with its type,
/// physical start, page count, and key attributes (xp/wb/ro). Host-visible
/// evidence of the memory layout the kernel handoff runs in. Best effort.
fn dump_memory_map(st: *const uefi.tables.SystemTable) void {
    const boot_services = st.boot_services orelse return;
    const info = boot_services.getMemoryMapInfo() catch return;
    // info.len is the descriptor COUNT; the pool must hold len*desc_size
    // bytes. Allocate with margin: the allocatePool call itself can grow the
    // map (a pool allocation may split a descriptor), so an exact-size
    // buffer risks EFI_BUFFER_TOO_SMALL on the second call.
    const bytes_needed = info.len * info.descriptor_size + 64 * info.descriptor_size;
    const buf = boot_services.allocatePool(.loader_data, bytes_needed) catch return;
    defer boot_services.freePool(buf.ptr) catch {};
    const mm = boot_services.getMemoryMap(buf) catch return;

    const loaded_image = (boot_services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch null) orelse return;
    const device_handle = loaded_image.device_handle orelse return;
    const fs = (boot_services.handleProtocol(uefi.protocol.SimpleFileSystem, device_handle) catch null) orelse return;
    const vol = fs.openVolume() catch return;
    defer vol.close() catch {};
    const f = vol.open(&memmap_path, .read_write_create, .{}) catch return;
    defer f.close() catch {};

    // Header with map metadata, then one line per descriptor. The std
    // iterator walks with the firmware-reported descriptor_size stride.
    var header: [96]u8 = undefined;
    var hn: usize = 0;
    hn += copy_into(header[hn..], "VIRELAIOS MEMORY MAP\n");
    hn += copy_into(header[hn..], "descriptors=");
    hn += append_hex(header[hn..], mm.info.len);
    hn += copy_into(header[hn..], " descriptor_size=");
    hn += append_hex(header[hn..], mm.info.descriptor_size);
    hn += copy_into(header[hn..], "\n");
    _ = f.write(header[0..hn]) catch {};

    var it = mm.iterator();
    while (it.next()) |desc| {
        // One line per descriptor; the buffer is sized for the longest line.
        var line: [160]u8 = undefined;
        var n: usize = 0;
        n += copy_into(line[n..], "  ");
        n += copy_into(line[n..], @tagName(desc.type));
        n += copy_into(line[n..], " phys=");
        n += append_hex(line[n..], desc.physical_start);
        n += copy_into(line[n..], " pages=");
        n += append_hex(line[n..], desc.number_of_pages);
        n += copy_into(line[n..], " xp=");
        line[n] = if (desc.attribute.xp) '1' else '0';
        n += 1;
        n += copy_into(line[n..], " wb=");
        line[n] = if (desc.attribute.wb) '1' else '0';
        n += 1;
        n += copy_into(line[n..], " ro=");
        line[n] = if (desc.attribute.ro) '1' else '0';
        n += 1;
        n += copy_into(line[n..], "\n");
        _ = f.write(line[0..n]) catch {};
    }
    f.flush() catch {};
}

/// M113b (ADR 0054 D2): read `\EFI\BOOT\BOOTAA64.EFI` — the same bytes the
/// firmware just verified when Secure Boot is on — and return its PE/COFF
/// Authenticode SHA-256, the digest convention the db pins. The image is
/// small (~170 KiB), so it is read whole into an EfiLoaderData allocation.
/// Null on any failure: the caller records `unmeasured`, never guesses.
fn measure_loader_image(root: *uefi.protocol.File, boot_services: *uefi.tables.BootServices) ?[32]u8 {
    const image_file = root.open(&loader_image_path, .read, .{}) catch return null;
    defer image_file.close() catch {};

    var info_buf: [256]u8 align(8) = undefined;
    const info = image_file.getInfo(.file, &info_buf) catch return null;
    const size: usize = @intCast(info.file_size);
    // A PE image needs at least the DOS header + PE headers; 4 MiB is a
    // generous ceiling for a loader image (today's is ~170 KiB).
    if (size < 0x40 or size > 4 * 1024 * 1024) return null;

    const pages = boot_services.allocatePages(.any, .loader_data, (size + 4095) / 4096) catch return null;
    const buf: [*]u8 = @ptrCast(pages.ptr);
    var filled: usize = 0;
    while (filled < size) {
        const got = image_file.read(buf[filled..size]) catch return null;
        if (got == 0) return null;
        filled += got;
    }
    return authenticode_sha256(buf[0..size]);
}

/// The PE/COFF Authenticode digest: the image hashed in file order,
/// skipping the CheckSum field (4 bytes), the security data-directory
/// entry (8 bytes), and the Attribute Certificate Table it points to (a
/// file offset, not an RVA). This is the convention the M113a probe
/// observed the firmware db enforcing (ADR 0054 Grounding 3): a raw-file
/// SHA-256 is REFUSED, this digest BOOTED. Null on a malformed image.
fn authenticode_sha256(bytes: []const u8) ?[32]u8 {
    if (bytes.len < 0x40) return null;
    const pe_off: usize = std.mem.readInt(u32, bytes[0x3c..][0..4], .little);
    if (pe_off + 24 > bytes.len) return null;
    if (!std.mem.eql(u8, bytes[pe_off..][0..4], "PE\x00\x00")) return null;
    const opt_off = pe_off + 4 + 20; // PE signature + COFF header
    const magic = std.mem.readInt(u16, bytes[opt_off..][0..2], .little);
    const dir_base: usize = switch (magic) {
        0x10b => opt_off + 96, // PE32 data directories
        0x20b => opt_off + 112, // PE32+ data directories
        else => return null,
    };
    const num_dirs_off: usize = switch (magic) {
        0x10b => opt_off + 92,
        0x20b => opt_off + 108,
        else => unreachable,
    };
    if (num_dirs_off + 4 > bytes.len) return null;
    const num_dirs = std.mem.readInt(u32, bytes[num_dirs_off..][0..4], .little);
    const checksum_off = opt_off + 64;
    const secdir_off = dir_base + 4 * 8; // IMAGE_DIRECTORY_ENTRY_SECURITY

    var h = measure.Sha256.init();
    if (num_dirs <= 4 or secdir_off + 8 > bytes.len) {
        // No security entry to skip: hash everything but the checksum.
        if (checksum_off + 4 > bytes.len) return null;
        h.update(bytes[0..checksum_off]);
        h.update(bytes[checksum_off + 4 ..]);
    } else {
        const cert_off: usize = std.mem.readInt(u32, bytes[secdir_off..][0..4], .little);
        const cert_size: usize = std.mem.readInt(u32, bytes[secdir_off + 4 ..][0..4], .little);
        if (checksum_off + 4 > secdir_off) return null;
        h.update(bytes[0..checksum_off]);
        h.update(bytes[checksum_off + 4 .. secdir_off]);
        const content_end: usize = if (cert_off == 0) bytes.len else @min(cert_off, bytes.len);
        if (secdir_off + 8 > content_end) return null;
        h.update(bytes[secdir_off + 8 .. content_end]);
        if (cert_off != 0) {
            if (cert_off + cert_size > bytes.len) return null;
            h.update(bytes[cert_off + cert_size ..]);
        }
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

/// The named KERNEL.BIN refusal (ADR 0054 D3): `kernel_hash_mismatch`
/// lands in three places — the ConOut line (invisible on VZ, kept for
/// non-VZ firmware), the ESP receipt `\REFUSED.TXT`, and the non-volatile
/// variable `VirelaiBoot` whose write survives in the host-visible
/// per-run variable store (the gate's observation channel — ESP writes
/// are trapped inside the discarded ASIF overlay). The caller then
/// returns to the firmware, which halts the VM as in the probe.
fn refuse_kernel_hash_mismatch(st: *const uefi.tables.SystemTable, root: *uefi.protocol.File) void {
    if (st.con_out) |con_out| {
        _ = con_out.outputString(&line_refused) catch {};
    }
    if (root.open(&refused_path, .read_write_create, .{})) |refused| {
        defer refused.close() catch {};
        _ = refused.write(refused_text) catch {};
        refused.flush() catch {};
    } else |_| {}
    _ = st.runtime_services.setVariable(
        &boot_variable_name,
        &virelai_vendor_guid,
        .{ .non_volatile = true, .bootservice_access = true, .runtime_access = true },
        boot_variable_refused,
    ) catch {};
}

/// Apply a KRN2 absolute-relocation table (issue #1042): for each 24-byte
/// entry { u64 offset, u64 value, u32 width, u32 _ }, write (value + base) as
/// `width` bytes at content offset `offset`. Returns false on a malformed or
/// out-of-bounds entry so the caller aborts the handoff rather than jumping
/// into a half-patched image.
fn apply_relocations(file: *uefi.protocol.File, content: []u8, base: u64, reloc_offset: u64, reloc_count: u64, hasher: *measure.Sha256) bool {
    file.setPosition(reloc_offset) catch return false;
    var i: u64 = 0;
    while (i < reloc_count) : (i += 1) {
        var entry: [kernel_reloc_entry_size]u8 = undefined;
        if ((file.read(&entry) catch return false) < kernel_reloc_entry_size) return false;
        hasher.update(&entry);
        const offset = std.mem.readInt(u64, entry[0..8], .little);
        const value = std.mem.readInt(u64, entry[8..16], .little);
        const width = std.mem.readInt(u32, entry[16..20], .little);
        const target = base +% value;
        switch (width) {
            8 => {
                if (offset + 8 > content.len) return false;
                std.mem.writeInt(u64, content[@intCast(offset)..][0..8], target, .little);
            },
            4 => {
                if (offset + 4 > content.len) return false;
                std.mem.writeInt(u32, content[@intCast(offset)..][0..4], @truncate(target), .little);
            },
            else => return false,
        }
    }
    return true;
}

/// Write \LOADER.TXT: loader-observed kernel placement (base, size, entry
/// offset), the header fields as read from the file (first8/second8), the
/// applied absolute-relocation count (KRN2), and the first 8 bytes that
/// landed at the image base in RAM (ram_first8; with the content at base+0
/// these are the kernel's first instructions). Best effort, like the other
/// marker writes.
fn write_loader_trace(root: *uefi.protocol.File, header: *const [kernel_header_size_reloc]u8, dst: [*]const u8, base: u64, size: u64, entry_offset: u64, reloc_count: u64) void {
    const trace = root.open(&loader_trace_path, .read_write_create, .{}) catch return;
    defer trace.close() catch {};

    var content: [320]u8 = undefined;
    var n: usize = 0;
    n += copy_into(content[n..], "VIRELAIOS LOADER\n");
    n += copy_into(content[n..], "kernel image loaded\n");
    n += copy_into(content[n..], "base=");
    n += append_hex(content[n..], base);
    n += copy_into(content[n..], " size=");
    n += append_hex(content[n..], size);
    n += copy_into(content[n..], " entry_offset=");
    n += append_hex(content[n..], entry_offset);
    n += copy_into(content[n..], " first8=");
    n += append_hex(content[n..], std.mem.readInt(u64, header[0..8], .little));
    n += copy_into(content[n..], " second8=");
    n += append_hex(content[n..], std.mem.readInt(u64, header[8..16], .little));
    n += copy_into(content[n..], " relocs=");
    n += append_hex(content[n..], reloc_count);
    n += copy_into(content[n..], " ram_first8=");
    n += append_hex(content[n..], std.mem.readInt(u64, dst[0..8], .little));
    n += copy_into(content[n..], "\n");

    _ = trace.write(content[0..n]) catch {};
    trace.flush() catch {};
}

/// Make code written by data accesses visible to instruction fetches over
/// [base, base+len): clean data cache to the point of unification, then
/// invalidate the instruction cache, synchronize (DSB ISH), and sync the
/// pipeline (ISB). Per-byte iteration so no cache-line-size is assumed; the
/// kernel image is tiny.
fn flush_to_pou(base: [*]const u8, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        asm volatile ("dc cvau, %[addr]"
            :
            : [addr] "r" (@intFromPtr(base + i)),
        );
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
    i = 0;
    while (i < len) : (i += 1) {
        asm volatile ("ic ivau, %[addr]"
            :
            : [addr] "r" (@intFromPtr(base + i)),
        );
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });
}

/// Record the kernel's return code in \RC.TXT (host-observable proof that
/// control returned from the kernel). Best effort.
fn write_rc(root: *uefi.protocol.File, rc: u64) void {
    const f = root.open(&rc_path, .read_write_create, .{}) catch return;
    defer f.close() catch {};
    var content: [48]u8 = undefined;
    var n: usize = 0;
    n += copy_into(content[n..], "kernel_rc=");
    n += append_hex(content[n..], rc);
    n += copy_into(content[n..], "\n");
    _ = f.write(content[0..n]) catch {};
    f.flush() catch {};
}

fn copy_into(dst: []u8, src: []const u8) usize {
    @memcpy(dst[0..src.len], src);
    return src.len;
}

/// Write "0x" + 16 lowercase hex digits of `value` into `buf` and return the
/// number of bytes written (18). Never aliases `buf` back onto itself.
fn append_hex(buf: []u8, value: u64) usize {
    buf[0] = '0';
    buf[1] = 'x';
    var v = value;
    var i: usize = 15;
    while (true) : (i -= 1) {
        const d: u8 = @intCast(v & 0xf);
        buf[2 + i] = if (d < 10) '0' + d else 'a' + (d - 10);
        v >>= 4;
        if (i == 0) break;
    }
    return 18;
}

fn wait_a_moment() void {
    var i: u64 = 0;
    while (i < 1_500_000_000) : (i += 1) {
        // The volatile asm prevents the optimizer from eliminating the loop.
        // (Zig 0.17 clobber syntax: a struct literal of clobber flags.)
        asm volatile ("" ::: .{ .memory = true });
    }
}
