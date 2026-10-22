//! VirelaiOS AArch64 ELF loader (M22 D1, issue #324, claim 9815).
//!
//! Pure parse + validate for statically linked AArch64 ELF32/ELF64
//! executables. The consumer is `exec.exec_file` (magic sniff: a file whose
//! first four bytes are `\x7fELF` takes this path instead of the DSK1/DSK3
//! flat paths) — no new syscall slot; `sys_exec` (28) and the monitor's
//! `exec` command both reach it through the same loader.
//!
//! Loader contract (documented, host-tested):
//!   * Only PT_LOAD program headers matter; every other type is skipped.
//!   * At most 3 PT_LOAD segments: segment 0 is TEXT (must NOT be
//!     writable — W^X); a middle segment (gap layout) is read-only
//!     non-executable; the last segment is DATA (must be writable).
//!   * Segment 0's p_vaddr MUST equal `text_base` (0x0040_0000), the fixed
//!     EL0 text aperture (`userspace.text_va`). The kernel maps it there,
//!     so absolute addresses in a normally linked image stay valid — no
//!     relocation is performed.
//!   * Two placement shapes:
//!       - CONTIGUOUS (the original contract): every later segment starts
//!         EXACTLY at the previous segment's memory end; the kernel stages
//!         [text][data] contiguously at text_va (claim-3805 DSK3 shape).
//!       - GAP (issue #1163, the GOOS=virelai gc-toolchain shape): a later
//!         segment sits at its own page-aligned p_vaddr ABOVE the previous
//!         segment's end (the Go linker's 64K-aligned R+X / R / RW
//!         segments). The kernel maps each gap segment at its DECLARED
//!         vaddr (`Image.gap_layout` tells the exec path which shape).
//!   * e_entry must land inside segment 0's INITIALIZED bytes (file range);
//!     it is reported relative to segment 0's p_vaddr because the staging
//!     strip re-bases the content at the aperture base.
//!   * Bounded: p_memsz >= p_filesz per segment, non-overlapping ordered
//!     file ranges, total INITIALIZED bytes <= `load_max`, and total MAPPED
//!     bytes <= `map_max` (matching `exec.exec_image_max` on the file and
//!     the loader's virtual-span bound on the mapping — M72a, issue #1579;
//!     a VIRTUAL bound since M171a/card #3032).
//!     The FILE ranges are validated against the caller-supplied file size
//!     — the read buffer on the staged path, the STAT size on the streamed
//!     one (`parse_head`, M70c-K / issue #1504).
//!
//! No dynamic linking, no sections, no relocations, no libc/POSIX.

const std = @import("std");
/// The `\x7fELF` magic.
pub const magic = [4]u8{ 0x7f, 'E', 'L', 'F' };
/// EM_AARCH64.
pub const em_aarch64: u16 = 0xB7;

// Program header types (PT_*)
pub const pt_null: u32 = 0;
pub const pt_load: u32 = 1;
pub const pt_dynamic: u32 = 2;
pub const pt_interp: u32 = 3;
pub const pt_note: u32 = 4;
pub const pt_shlib: u32 = 5;
pub const pt_phdr: u32 = 6;
pub const pt_tls: u32 = 7;

// Program header flags (PF_*)
pub const pf_x: u32 = 1;
pub const pf_w: u32 = 2;
pub const pf_r: u32 = 4;

// Dynamic section tags (DT_*)
pub const dt_null: u64 = 0;
pub const dt_needed: u64 = 1;
pub const dt_pltrelsz: u64 = 2;
pub const dt_pltgot: u64 = 3;
pub const dt_hash: u64 = 4;
pub const dt_strtab: u64 = 5;
pub const dt_symtab: u64 = 6;
pub const dt_rela: u64 = 7;
pub const dt_relasz: u64 = 8;
pub const dt_relaent: u64 = 9;
pub const dt_strsz: u64 = 10;
pub const dt_syment: u64 = 11;
pub const dt_init: u64 = 12;
pub const dt_fini: u64 = 13;
pub const dt_soname: u64 = 14;
pub const dt_rpath: u64 = 15;
pub const dt_symbolic: u64 = 16;
pub const dt_rel: u64 = 17;
pub const dt_relsz: u64 = 18;
pub const dt_relent: u64 = 19;
pub const dt_pltrel: u64 = 20;
pub const dt_debug: u64 = 21;
pub const dt_textrel: u64 = 22;
pub const dt_jmprel: u64 = 23;
pub const dt_bind_now: u64 = 24;
pub const dt_init_array: u64 = 25;
pub const dt_fini_array: u64 = 26;
pub const dt_init_arraysz: u64 = 27;
pub const dt_fini_arraysz: u64 = 28;
pub const dt_runpath: u64 = 29;
pub const dt_flags: u64 = 30;

// AArch64 dynamic relocations
pub const r_aarch64_none: u32 = 0;
pub const r_aarch64_abs64: u32 = 257;
pub const r_aarch64_copy: u32 = 1024;
pub const r_aarch64_glob_dat: u32 = 1025;
pub const r_aarch64_jump_slot: u32 = 1026;
pub const r_aarch64_relative: u32 = 1027;

// Auxiliary vector types (AT_*)
pub const at_null: u64 = 0;
pub const at_ignore: u64 = 1;
pub const at_execfd: u64 = 2;
pub const at_phdr: u64 = 3;
pub const at_phent: u64 = 4;
pub const at_phnum: u64 = 5;
pub const at_pagesz: u64 = 6;
pub const at_base: u64 = 7;
pub const at_flags: u64 = 8;
pub const at_entry: u64 = 9;

pub const AuxvEntry = struct {
    a_type: u64,
    a_val: u64,
};

pub const Elf64Dyn = struct {
    d_tag: u64,
    d_val: u64,
};

pub const Elf64Rela = struct {
    r_offset: u64,
    r_info: u64,
    r_addend: i64,

    pub inline fn sym(self: Elf64Rela) u32 {
        return @intCast(self.r_info >> 32);
    }

    pub inline fn r_type(self: Elf64Rela) u32 {
        return @intCast(self.r_info & 0xffffffff);
    }
};

pub const Elf64Sym = struct {
    st_name: u32,
    st_info: u8,
    st_other: u8,
    st_shndx: u16,
    st_value: u64,
    st_size: u64,
};

/// The required p_vaddr of the first PT_LOAD segment — the kernel's fixed
/// EL0 text aperture (`userspace.text_va`). Kept as a local constant so
/// this module stays dependency-free for host tests; exec.zig asserts the
/// two agree.
pub const text_base: u64 = 0x0040_0000;
/// Page granularity for gap-layout segment vaddrs (the kernel maps whole
/// pages at declared vaddrs — mmu/alloc page size, 4 KiB).
pub const page_alignment: u64 = 4096;
/// Upper sanity bound for EVERY gap-layout segment's placement: a loaded
/// image must end below the user mmap bump window (0x1000_0000) so it can
/// never collide with `sys_mmap` allocations or the reserved windows
/// above them. The user stack is not a fixed address (ASLR'd per exec via
/// the CSPRNG) — the bound exists to keep images below the bump region,
/// not below any fixed stack VA.
pub const gap_base_max: u64 = 0x1000_0000;
/// Acceptance bound on an image's INITIALIZED bytes: the sum of every
/// PT_LOAD `p_filesz`, i.e. exactly the bytes the loader reads off the
/// volume. Issue #1163: raised from 512 KiB — the gc Go runtime's first
/// images exceed the old bound even `-s -w`-stripped (GOHELLO.ELF is
/// 1.06 MiB of file / 1.21 MiB of PT_LOAD memory). M70c-K (issue #1504):
/// raised from 2 MiB to match the streamed loader, which no longer stages
/// the whole file, so the load bound is no longer a buffer size.
///
/// M72a (issue #1579): this constant used to be charged on the sum of every
/// PT_LOAD `p_memsz`, which made it a bound on MAPPED memory wearing the
/// name of a bound on file bytes — and that refused every Go image carrying
/// a large `.noptrbss`, because a zero-initialized global adds no file bytes
/// at all (`crypto/internal/fips140/drbg`'s `var memory
/// entropy.ScratchBuffer` is 32 MiB of it — `crypto/internal/entropy/v1.0.0`,
/// `type ScratchBuffer [1 << 25]byte`). The mapped bound is now `map_max`;
/// this one charges what it says.
///
/// What that leaves: the segment FILE ranges are disjoint and inside the file
/// (both enforced below), so `Σ filesz ≤ file size ≤ exec.exec_image_max`
/// (32 MiB) — for a caller that bounds the file too, this check is a
/// parser-level invariant. It stays because `parse`/`parse_head` are public
/// entry points that do not.
pub const load_max: usize = 32 * 1024 * 1024;
/// Bound on the address space an image may MAP — the sum of every PT_LOAD
/// `p_memsz` (each segment's initialized bytes plus its zero-filled
/// `.bss`/`.noptrbss` tail). Charged by `parse_impl` before any placement
/// check, so an oversized BSS is refused by a bound that names MEMORY rather
/// than by `gap_too_high`.
///
/// Since M171a (card #3032) this IS a notional reservation: the loader
/// allocates and fills only the file-backed pages of each segment and
/// registers the zero-fill tail (`memsz − align_up(filesz)`, page-rounded)
/// as a demand region faulted in on first touch, so `Σ memsz` is a bound
/// on VIRTUAL span, not a RAM budget. The resident side is bounded by
/// the allocator: at exec the file-backed part keeps the
/// `alloc_pages` → `out_of_memory` (ENOMEM) refusal, and at fault time a
/// dry pool makes `populate_user_page` deliver the fault rather than
/// map it — never a silent overcommit.
/// 64 MiB stays the virtual bound: it admits the largest known Go images
/// (a Charm-sized binary is ~37 MB of `memsz`, and `go-hello` run 11's
/// fixture is ~48 MB) without letting one image claim an arbitrary share
/// of the user address space — `sysinfo` on VZ reports `free=0xde0b`
/// (56,843 pages, 222.0 MiB) on a fresh boot and `free=0xb68c` (46,732
/// pages, 182.5 MiB) with the boot apps up.
pub const map_max: usize = 64 * 1024 * 1024;
/// At most three PT_LOAD segments: text + optional RO rodata + data
/// (issue #1163 — the Go linker's R+X / R / RW layout).
pub const max_segments: usize = 3;

pub const Error = error{
    /// Not an ELF file (bad magic or absurdly short buffer).
    not_elf,
    /// EI_CLASS is neither 1 (ELF32) nor 2 (ELF64).
    unsupported_class,
    /// EI_DATA is not 1 (little-endian).
    unsupported_endian,
    /// e_machine is not EM_AARCH64.
    unsupported_machine,
    /// The header, program-header table, or a segment record extends past
    /// the buffer end.
    truncated,
    /// e_phentsize does not match the class's expected record size.
    bad_phdr,
    /// No PT_LOAD segments at all.
    no_load_segments,
    /// More than `max_segments` PT_LOAD segments.
    too_many_segments,
    /// A segment's FILE range escapes the file the caller described: the
    /// header promises initialized bytes the file does not hold. Detected
    /// identically on both paths — the staged one describes the bytes it
    /// read, the streamed one the volume's STAT size (M70c-K / #1504) — so
    /// the caller reports it as one named condition, a truncated image,
    /// rather than as a vague "bad segment".
    file_too_short,
    /// p_memsz < p_filesz, or the total INITIALIZED bytes exceed `load_max`.
    segment_too_large,
    /// The image's total MAPPED bytes (`Σ p_memsz`) exceed `map_max`. A name
    /// of its own, distinct from `segment_too_large`, because the bound it
    /// crosses is about memory the loader will allocate: a large zero-filled
    /// `.bss`/`.noptrbss` is admitted by the other bound and refused by this
    /// one (M72a, issue #1579).
    map_too_large,
    /// Two segments' FILE ranges overlap (the staging copy is forward-only
    /// and requires ordered, disjoint source ranges).
    overlapping_segments,
    /// The first PT_LOAD carries PF_W (the kernel maps text read-only).
    writable_text,
    /// A second PT_LOAD lacks PF_W (the kernel maps data read-write).
    readable_data,
    /// The first segment's p_vaddr is not `text_base`.
    bad_text_base,
    /// A later segment's p_vaddr is BELOW the previous segment's memory end.
    bad_data_base,
    /// A gap-layout segment's p_vaddr is not page-aligned (the kernel maps
    /// whole pages at declared vaddrs).
    unaligned_gap,
    /// A gap-layout segment ends at or above `gap_base_max` — inside the
    /// mmap bump window or a reserved window above it.
    gap_too_high,
    /// A gap-layout MIDDLE segment is writable (only the last segment may
    /// carry PF_W — W^X: [R+X][R][RW]).
    writable_rodata,
    /// e_entry falls outside segment 0's initialized bytes.
    bad_entry,
};

/// One collected PT_LOAD segment, re-based to staging coordinates by the
/// caller (the parser reports raw file offsets + sizes).
pub const Segment = struct {
    /// Byte offset of the segment's initialized bytes in the FILE buffer.
    file_offset: usize,
    /// Number of initialized bytes in the FILE buffer.
    file_size: usize,
    /// Number of bytes in the virtual MEMORY image.
    mem_size: usize,
    /// Virtual address of this segment in memory.
    vaddr: u64 = 0,
};

pub const Image = struct {
    /// Entry-point offset RELATIVE to segment 0's p_vaddr (== its offset
    /// within the staged text region after the strip).
    entry_rel: u64,
    segments: [max_segments]Segment,
    segment_count: usize,
    /// Absolute entry address in ELF header (e_entry).
    e_entry: u64 = 0,
    /// Base address of segment 0 (p_vaddr).
    base_vaddr: u64 = text_base,
    /// Program header offset, entry size, and count (for Aux Vector / AT_PHDR).
    phoff: u64 = 0,
    phentsize: usize = 0,
    phnum: usize = 0,
    /// Dynamic interpreter path (from PT_INTERP, e.g. "LD.SO").
    interp: ?[]const u8 = null,
    /// True when at least one later segment sits at its own page-aligned
    /// p_vaddr ABOVE the previous segment's end (issue #1163 gap layout —
    /// the exec path maps such segments at their declared vaddrs instead
    /// of staging [text][data] contiguously).
    gap_layout: bool = false,
    /// PT_DYNAMIC segment location if present.
    dynamic_vaddr: u64 = 0,
    dynamic_size: u64 = 0,
    has_dynamic: bool = false,
};

/// Quick magic sniff for the exec dispatch: true when the buffer starts
/// with the ELF magic (and is long enough to hold one).
pub fn is_elf(buf: []const u8) bool {
    return buf.len >= magic.len and std.mem.eql(u8, buf[0..magic.len], &magic);
}

// ---------------------------------------------------------------------------
// Symbol collection (M22 D3, issue #326): walk section headers, find the
// SHT_SYMTAB (+ its linked strtab), and emit function/object symbols with
// non-local binding. Names are slices INTO `buf` — the caller must copy
// them before dropping the buffer.
// ---------------------------------------------------------------------------

const sh_type_symtab: u32 = 2;
const stt_func: u8 = 2;
const stt_object: u8 = 1;
const stb_local: u8 = 0;

pub const SymInfo = struct {
    name: []const u8,
    addr: u64,
    size: u64,
};

/// Collect up to `out.len` symbols from `buf`. Returns how many were
/// written. Malformed/absent symbol tables yield 0 — never an error (a
/// stripped image simply has no names).
pub fn collect_symbols(buf: []const u8, out: []SymInfo) usize {
    if (!is_elf(buf)) return 0;
    const ei_class = buf[4];
    if (ei_class != 1 and ei_class != 2) return 0;

    var shoff: u64 = 0;
    var shentsize: usize = 0;
    var shnum: usize = 0;
    if (ei_class == 1) {
        if (buf.len < 52) return 0;
        shoff = read_u32(buf, 32);
        shentsize = read_u16(buf, 46);
        shnum = read_u16(buf, 48);
        if (shentsize != 40) return 0;
    } else {
        if (buf.len < 64) return 0;
        shoff = read_u64(buf, 40);
        shentsize = read_u16(buf, 58);
        shnum = read_u16(buf, 60);
        if (shentsize != 64) return 0;
    }
    if (shnum == 0 or shoff == 0) return 0;
    const table_bytes = @as(u64, shnum) * @as(u64, shentsize);
    if (shoff > buf.len or table_bytes > buf.len - shoff) return 0;

    // Locate SHT_SYMTAB; remember its linked strtab index.
    var symtab_off: u64 = 0;
    var symtab_size: u64 = 0;
    var symtab_entsize: u64 = 0;
    var strtab_idx: usize = 0;
    var found = false;
    var i: usize = 0;
    while (i < shnum) : (i += 1) {
        const rec = shoff + @as(u64, i) * @as(u64, shentsize);
        const sh_type = read_u32(buf, @intCast(rec + 4));
        if (sh_type != sh_type_symtab) continue;
        const sh_offset = if (ei_class == 1) read_u32(buf, @intCast(rec + 16)) else read_u64(buf, @intCast(rec + 24));
        const sh_size = if (ei_class == 1) read_u32(buf, @intCast(rec + 20)) else read_u64(buf, @intCast(rec + 32));
        strtab_idx = if (ei_class == 1) read_u32(buf, @intCast(rec + 24)) else read_u32(buf, @intCast(rec + 40));
        symtab_off = sh_offset;
        symtab_size = sh_size;
        symtab_entsize = if (ei_class == 1) read_u32(buf, @intCast(rec + 36)) else read_u64(buf, @intCast(rec + 56));
        found = true;
        break;
    }
    if (!found) return 0;

    // Resolve the strtab section record.
    if (strtab_idx >= shnum) return 0;
    const srec = shoff + @as(u64, strtab_idx) * @as(u64, shentsize);
    const str_off = if (ei_class == 1) read_u32(buf, @intCast(srec + 16)) else read_u64(buf, @intCast(srec + 24));
    const str_size = if (ei_class == 1) read_u32(buf, @intCast(srec + 20)) else read_u64(buf, @intCast(srec + 32));
    if (str_off > buf.len or str_size > buf.len - str_off) return 0;
    const strtab = buf[@intCast(str_off)..][0..@intCast(str_size)];

    // Expected entry sizes per class.
    const want_entsize: u64 = if (ei_class == 1) 16 else 24;
    if (symtab_entsize != want_entsize) return 0;
    if (symtab_off > buf.len or symtab_size > buf.len - symtab_off) return 0;

    var written: usize = 0;
    const entries = symtab_size / symtab_entsize;
    var e: usize = 0;
    while (e < entries) : (e += 1) {
        if (written == out.len) break;
        const rec = symtab_off + e * symtab_entsize;
        var st_name: u32 = 0;
        var st_info: u8 = 0;
        var st_value: u64 = 0;
        var st_size: u64 = 0;
        if (ei_class == 1) {
            st_name = read_u32(buf, @intCast(rec));
            st_info = buf[rec + 12];
            st_value = read_u32(buf, @intCast(rec + 4));
            st_size = read_u32(buf, @intCast(rec + 8));
        } else {
            st_name = read_u32(buf, @intCast(rec));
            st_info = buf[rec + 4];
            st_value = read_u64(buf, @intCast(rec + 8));
            st_size = read_u64(buf, @intCast(rec + 16));
        }
        // Keep GLOBAL(1)/WEAK(2) FUNC/OBJECT; skip locals and specials.
        const binding = st_info >> 4;
        const kind = st_info & 0xf;
        if (binding == stb_local) continue;
        if (kind != stt_func and kind != stt_object) continue;
        if (st_name >= strtab.len) continue;
        const name_slice = std.mem.sliceTo(strtab[st_name..], 0);
        if (name_slice.len == 0) continue;
        out[written] = .{ .name = name_slice, .addr = st_value, .size = st_size };
        written += 1;
    }
    return written;
}

fn read_u16(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .little);
}

fn read_u32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

fn read_u64(buf: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off..][0..8], .little);
}

const RawSegment = struct {
    offset: u64,
    vaddr: u64,
    filesz: u64,
    memsz: u64,
    flags: u32,
};

/// The total PT_LOAD MEMORY the plan maps (initialized bytes plus the
/// zero-filled BSS tails of every segment) — the same quantity `parse_impl`
/// bounds by `map_max`. Callers use it for their own bounds: `exec_file`
/// still refuses a STAGED shape that would not fit the staging buffer even
/// though the parser admits it (M70c-K, issue #1504 — only the streamed gap
/// path is exempt from that buffer; M72a, #1579 — a GAP shape is exempt too,
/// because only its FILE bytes transit that buffer).
pub fn mem_total(image: Image) u64 {
    var total: u64 = 0;
    for (image.segments[0..image.segment_count]) |seg| total += seg.mem_size;
    return total;
}

/// Parse + validate an ELF executable image. `buf` holds the whole file as
/// read from the volume. On success returns the bounded load plan.
pub fn parse(buf: []const u8) Error!Image {
    return parse_impl(buf, buf.len, text_base);
}

/// Parse + validate an ELF image with an optional expected base address.
/// If `expected_base` is null, segment 0's declared vaddr is accepted.
/// Callers passing null — the interpreter load path — should prefer
/// `parse_declared`, which additionally confines every declared vaddr to
/// the user VA window (#2095).
pub fn parse_at(buf: []const u8, expected_base: ?u64) Error!Image {
    return parse_impl(buf, buf.len, expected_base);
}

/// M97c #2095: parse + validate an image that declares its OWN base — the
/// PT_INTERP interpreter (LD.SO). Same `parse_impl` contract, plus the
/// window confinement the fixed-base contract gets for free: segment 0's
/// declared base is page-aligned and clear of page zero, EVERY segment's
/// vaddr is page-aligned and ordered above the previous segment's end (the
/// exec path maps each segment at its declared vaddr), and every segment's
/// end sits strictly below `gap_base_max` — the mmap bump window and the
/// reserved windows above it stay kernel-side territory. Without this a
/// crafted interpreter could place a segment anywhere — including over the
/// identity map's pooled RAM — and the aperture builder would have been
/// handed an attacker-chosen EL0 window.
pub fn parse_declared(buf: []const u8) Error!Image {
    const image = try parse_impl(buf, buf.len, null);
    const segs = image.segments[0..image.segment_count];
    if (image.base_vaddr & (page_alignment - 1) != 0) return error.unaligned_gap;
    if (image.base_vaddr < page_alignment) return error.bad_text_base;
    var prev_end: u64 = 0;
    for (segs) |seg| {
        if (seg.vaddr & (page_alignment - 1) != 0) return error.unaligned_gap;
        if (seg.vaddr < prev_end) return error.bad_data_base;
        if (seg.vaddr >= gap_base_max) return error.gap_too_high;
        if (@as(u64, seg.mem_size) > gap_base_max - seg.vaddr) return error.gap_too_high;
        prev_end = seg.vaddr + seg.mem_size;
    }
    return image;
}

/// M70c-K (issue #1504): parse from a HEADER WINDOW.
///
/// `buf` must hold the ELF header, the program-header table, and — for a
/// dynamic image — the PT_INTERP path; the segment PAYLOAD ranges are
/// validated against `file_size` (the volume's STAT size) instead of the
/// window, because a streamed load never stages them. The returned plan's
/// `Segment.file_offset`s are FILE offsets, so the caller streams each
/// segment from there. Everything else (ordering, disjointness, W^X,
/// placement, the total-load bound, entry-in-text) is the same contract
/// `parse` enforces — this is a second entry point, not a weaker one.
pub fn parse_head(buf: []const u8, file_size: u64, expected_base: ?u64) Error!Image {
    // A window larger than the file would let a segment validate against
    // bytes that do not exist.
    if (file_size < buf.len) return error.truncated;
    return parse_impl(buf, file_size, expected_base);
}

fn parse_impl(buf: []const u8, file_size: u64, expected_base: ?u64) Error!Image {
    // e_ident needs 16 bytes; the shortest header table (ELF32) ends at
    // byte 44 with phentsize/phnum at 42/44 — checked below per class.
    if (!is_elf(buf)) return error.not_elf;
    const ei_class = buf[4];
    const ei_data = buf[5];
    if (ei_class != 1 and ei_class != 2) return error.unsupported_class;
    if (ei_data != 1) return error.unsupported_endian;

    var entry: u64 = 0;
    var phoff: u64 = 0;
    var phnum: usize = 0;
    var phentsize_expected: usize = 0;
    var header_min: usize = 0;
    if (ei_class == 1) {
        header_min = 52; // through e_phnum @44..46 (+ slack)
        if (buf.len < header_min) return error.truncated;
        entry = read_u32(buf, 24);
        phoff = read_u32(buf, 28);
        phnum = read_u16(buf, 44);
        phentsize_expected = 32;
    } else {
        header_min = 64; // through e_shstrndx @62..64
        if (buf.len < header_min) return error.truncated;
        entry = read_u64(buf, 24);
        phoff = read_u64(buf, 32);
        phnum = read_u16(buf, 56);
        phentsize_expected = 56;
    }
    const machine = read_u16(buf, 18);
    if (machine != em_aarch64) return error.unsupported_machine;

    // Program-header table bounds.
    if (phnum == 0) return error.no_load_segments;
    const phentsize = if (ei_class == 1) read_u16(buf, 42) else read_u16(buf, 54);
    if (phentsize != phentsize_expected) return error.bad_phdr;
    const table_bytes = @as(u64, phnum) * @as(u64, phentsize);
    if (phoff > buf.len or table_bytes > buf.len - phoff) return error.truncated;

    // Walk program headers, collecting PT_LOAD, PT_INTERP, PT_DYNAMIC.
    var raws: [max_segments]RawSegment = undefined;
    var count: usize = 0;
    var interp_slice: ?[]const u8 = null;
    var dyn_vaddr: u64 = 0;
    var dyn_size: u64 = 0;
    var has_dyn = false;

    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const rec = phoff + @as(u64, i) * @as(u64, phentsize);
        const p_type = read_u32(buf, @intCast(rec));
        if (p_type == pt_interp) {
            const p_offset = if (ei_class == 1) read_u32(buf, @intCast(rec + 4)) else read_u64(buf, @intCast(rec + 8));
            const p_filesz = if (ei_class == 1) read_u32(buf, @intCast(rec + 16)) else read_u64(buf, @intCast(rec + 32));
            if (p_offset <= buf.len and p_filesz <= buf.len - p_offset and p_filesz > 0) {
                const raw_interp = buf[@intCast(p_offset)..][0..@intCast(p_filesz)];
                interp_slice = std.mem.sliceTo(raw_interp, 0);
            }
            continue;
        }
        if (p_type == pt_dynamic) {
            dyn_vaddr = if (ei_class == 1) read_u32(buf, @intCast(rec + 8)) else read_u64(buf, @intCast(rec + 16));
            dyn_size = if (ei_class == 1) read_u32(buf, @intCast(rec + 20)) else read_u64(buf, @intCast(rec + 40));
            has_dyn = true;
            continue;
        }
        if (p_type != pt_load) continue;

        const r: RawSegment = switch (ei_class) {
            1 => .{
                .offset = read_u32(buf, @intCast(rec + 4)),
                .vaddr = read_u32(buf, @intCast(rec + 8)),
                .filesz = read_u32(buf, @intCast(rec + 16)),
                .memsz = read_u32(buf, @intCast(rec + 20)),
                .flags = read_u32(buf, @intCast(rec + 24)),
            },
            else => .{
                .flags = read_u32(buf, @intCast(rec + 4)),
                .offset = read_u64(buf, @intCast(rec + 8)),
                .vaddr = read_u64(buf, @intCast(rec + 16)),
                .filesz = read_u64(buf, @intCast(rec + 32)),
                .memsz = read_u64(buf, @intCast(rec + 40)),
            },
        };
        if (count == max_segments) return error.too_many_segments;
        raws[count] = r;
        count += 1;
    }
    if (count == 0) return error.no_load_segments;

    // Per-segment bounds + flags. Two totals, because they answer two
    // different questions: the INITIALIZED bytes the loader reads off the
    // volume (`load_max`) and the bytes the loader will MAP (`map_max`).
    // Both are checked here, before placement, so a 1 GiB `.bss` is refused
    // by the bound that names memory and not by `gap_too_high` (M72a,
    // issue #1579).
    var total_file: u64 = 0;
    var total_map: u64 = 0;
    for (raws[0..count]) |r| {
        if (r.memsz < r.filesz) return error.segment_too_large;
        // The payload range is validated against the FILE, not `buf`: the
        // staged path passes the whole file (file_size == buf.len, so this
        // is the old check exactly), while a streamed load passes only a
        // header window and streams the payload straight from the file.
        if (r.offset > file_size or r.filesz > file_size - r.offset) return error.file_too_short;
        total_file += r.filesz;
        if (total_file > load_max) return error.segment_too_large;
        total_map += r.memsz;
        if (total_map > map_max) return error.map_too_large;
    }
    if (raws[0].flags & pf_w != 0) return error.writable_text;
    // Contiguous shape: segment 1 (the last) must be writable. In the gap
    // shape (checked below) only the LAST segment may be writable; middle
    // segments are read-only rodata (W^X: [R+X][R][RW]).
    if (count == 2 and raws[1].flags & pf_w == 0) return error.readable_data;

    // File ranges must be disjoint AND ordered (the staging copy is
    // forward-only and every per-segment copy reads forward).
    var prev_end: u64 = 0;
    for (raws[0..count]) |r| {
        if (r.offset < prev_end) return error.overlapping_segments;
        prev_end = r.offset + r.filesz;
    }

    // Placement contract: segment 0 at the expected base aperture for the
    // CONTIGUOUS shape; the GAP shape maps every segment (including 0) at
    // its own declared vaddr, so it only needs a page-aligned, sane base
    // (the Go linker places the ELF headers one page below `-T`, so seg0
    // lands at e.g. 0x3f0000 for a 0x400000 text start). Later segments
    // are either contiguous or page-aligned gaps, checked below.
    var gap_layout = false;
    if (expected_base) |exp| {
        if (raws[0].vaddr != exp) gap_layout = true;
    }
    var seg_i: usize = 1;
    while (seg_i < count) : (seg_i += 1) {
        const prev_mem_end = raws[seg_i - 1].vaddr + raws[seg_i - 1].memsz;
        if (raws[seg_i].vaddr == prev_mem_end) continue; // contiguous
        if (raws[seg_i].vaddr < prev_mem_end) return error.bad_data_base;
        // Gap segment: page-aligned (the kernel maps whole pages at
        // declared vaddrs).
        if (raws[seg_i].vaddr & (page_alignment - 1) != 0) return error.unaligned_gap;
        gap_layout = true;
    }
    if (gap_layout) {
        // Declared-base sanity: page-aligned, clear of page 0 (the
        // compiler's nil checks rely on faulting at low addresses), and
        // every segment's END inside the user VA region — issue #1163 I2:
        // this bound applies to ALL segments, not just segment 0, so a
        // crafted image cannot place rodata/data in the mmap bump window
        // or any reserved window above it.
        if (raws[0].vaddr & (page_alignment - 1) != 0) return error.unaligned_gap;
        if (raws[0].vaddr < page_alignment) return error.bad_text_base;
        var k: usize = 0;
        while (k < count) : (k += 1) {
            if (raws[k].vaddr >= gap_base_max or
                raws[k].vaddr + raws[k].memsz > gap_base_max)
            {
                return error.gap_too_high;
            }
        }
        // Middle segments must be read-only; the LAST must be writable.
        var j: usize = 1;
        while (j < count) : (j += 1) {
            const writable = raws[j].flags & pf_w != 0;
            if (j == count - 1) {
                if (!writable) return error.readable_data;
            } else if (writable) {
                return error.writable_rodata;
            }
        }
    }

    // Entry must land in segment 0's INITIALIZED bytes (executing the
    // zero-filled tail would fault immediately anyway — reject it here
    // with an honest message instead of a tombstone).
    if (entry < raws[0].vaddr or entry >= raws[0].vaddr + raws[0].filesz) return error.bad_entry;

    var segments: [max_segments]Segment = undefined;
    var si: usize = 0;
    while (si < count) : (si += 1) {
        segments[si] = .{
            .file_offset = @intCast(raws[si].offset),
            .file_size = @intCast(raws[si].filesz),
            .mem_size = @intCast(raws[si].memsz),
            .vaddr = raws[si].vaddr,
        };
    }
    return .{
        .entry_rel = entry - raws[0].vaddr,
        .segments = segments,
        .segment_count = count,
        .e_entry = entry,
        .base_vaddr = raws[0].vaddr,
        .phoff = phoff,
        .phentsize = phentsize,
        .phnum = phnum,
        .interp = interp_slice,
        .dynamic_vaddr = dyn_vaddr,
        .dynamic_size = dyn_size,
        .has_dynamic = has_dyn,
        .gap_layout = gap_layout,
    };
}

/// Parse dynamic tags from a raw dynamic section buffer.
pub fn parse_dynamic_tags(dyn_bytes: []const u8, out: []Elf64Dyn) usize {
    const entry_size = @sizeOf(Elf64Dyn); // 16 bytes
    const count = dyn_bytes.len / entry_size;
    const n = @min(count, out.len);
    for (0..n) |i| {
        const off = i * entry_size;
        const tag = std.mem.readInt(u64, dyn_bytes[off..][0..8], .little);
        const val = std.mem.readInt(u64, dyn_bytes[off + 8 ..][0..8], .little);
        out[i] = .{ .d_tag = tag, .d_val = val };
        if (tag == dt_null) return i + 1;
    }
    return n;
}

/// Find a specific dynamic tag value in a list of parsed Elf64Dyn tags.
pub fn find_dynamic_tag(tags: []const Elf64Dyn, tag: u64) ?u64 {
    for (tags) |entry| {
        if (entry.d_tag == tag) return entry.d_val;
        if (entry.d_tag == dt_null) break;
    }
    return null;
}

/// Encode auxiliary vector entries into a byte slice.
pub fn encode_auxv(buf: []u8, entries: []const AuxvEntry) usize {
    var off: usize = 0;
    for (entries) |entry| {
        if (off + 16 > buf.len) break;
        std.mem.writeInt(u64, buf[off..][0..8], entry.a_type, .little);
        std.mem.writeInt(u64, buf[off + 8 ..][0..8], entry.a_val, .little);
        off += 16;
        if (entry.a_type == at_null) break;
    }
    return off;
}

/// Resolve a standard AArch64 dynamic relocation.
pub fn resolve_relocation(rel: Elf64Rela, base: u64, sym_addr: u64) ?u64 {
    return switch (rel.r_type()) {
        r_aarch64_none => null,
        r_aarch64_relative => @as(u64, @bitCast(@as(i64, @intCast(base)) +% rel.r_addend)),
        r_aarch64_glob_dat, r_aarch64_jump_slot, r_aarch64_abs64 => @as(u64, @bitCast(@as(i64, @intCast(sym_addr)) +% rel.r_addend)),
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests (host-side, pure): hand-crafted minimal images pin every contract.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a minimal ELF32 image: ELF header (52 B) + one phdr (32 B) +
/// `code`. Returns the image and its total size.
fn elf32_one(code: []const u8, vaddr: u32, filesz_extra: usize, memsz_extra: usize, flags: u32) [128]u8 {
    var img = @as([128]u8, @splat(@as(u8, 0)));
    // e_ident
    @memcpy(img[0..4], &magic);
    img[4] = 1; // ELF32
    img[5] = 1; // little-endian
    img[6] = 1; // EV_CURRENT
    // e_type=2 (EXEC) @16, e_machine @18
    std.mem.writeInt(u16, img[16..18], 2, .little);
    std.mem.writeInt(u16, img[18..20], em_aarch64, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little); // e_version
    std.mem.writeInt(u32, img[24..28], vaddr, .little); // e_entry (at code start)
    std.mem.writeInt(u32, img[28..32], 52, .little); // e_phoff
    std.mem.writeInt(u16, img[40..42], 52, .little); // e_ehsize
    std.mem.writeInt(u16, img[42..44], 32, .little); // e_phentsize
    std.mem.writeInt(u16, img[44..46], 1, .little); // e_phnum
    // phdr @52: PT_LOAD, R+X
    std.mem.writeInt(u32, img[52..56], pt_load, .little);
    std.mem.writeInt(u32, img[56..60], 84, .little); // p_offset
    std.mem.writeInt(u32, img[60..64], vaddr, .little); // p_vaddr
    std.mem.writeInt(u32, img[68..72], @intCast(code.len + filesz_extra), .little); // p_filesz
    std.mem.writeInt(u32, img[72..76], @intCast(code.len + filesz_extra + memsz_extra), .little); // p_memsz
    std.mem.writeInt(u32, img[76..80], flags, .little);
    @memcpy(img[84..][0..code.len], code);
    return img;
}

test "elf: minimal valid ELF32 parses with correct entry" {
    const code = [_]u8{ 0x01, 0x00, 0x80, 0xd2 }; // mov x0, #1
    const img = elf32_one(&code, 0x400000, 0, 0, 5); // R+X
    const image = try parse(&img);
    try testing.expectEqual(@as(usize, 1), image.segment_count);
    try testing.expectEqual(@as(u64, 0), image.entry_rel);
    try testing.expectEqual(@as(usize, 84), image.segments[0].file_offset);
    try testing.expectEqual(code.len, image.segments[0].file_size);
}

test "elf: rejects bad magic, classes, endianness, and machine" {
    var img = elf32_one(&@as([4]u8, @splat(@as(u8, 0))), 0x400000, 0, 0, 5);

    // Bad magic.
    var bad_magic = img;
    bad_magic[0] = 'D';
    try testing.expectError(error.not_elf, parse(&bad_magic));
    try testing.expectError(error.not_elf, parse(img[0..3]));

    // Bad class (3 is reserved).
    var bad_class = img;
    bad_class[4] = 3;
    try testing.expectError(error.unsupported_class, parse(&bad_class));

    // Big-endian.
    var bad_endian = img;
    bad_endian[5] = 2;
    try testing.expectError(error.unsupported_endian, parse(&bad_endian));

    // x86_64 machine (0x3E) — "unsupported architecture".
    var x86 = img;
    std.mem.writeInt(u16, x86[18..20], 0x3E, .little);
    try testing.expectError(error.unsupported_machine, parse(&x86));
}

test "elf: rejects truncated headers and tables" {
    const code = @as([4]u8, @splat(@as(u8, 0)));
    const img = elf32_one(&code, 0x400000, 0, 0, 5);
    // Header cut short of the ELF32 minimum.
    try testing.expectError(error.truncated, parse(img[0..48]));
    // Program-header table extends past the buffer (claim phnum=9 but ship 1).
    var bad_table = img;
    std.mem.writeInt(u16, bad_table[44..46], 9, .little);
    try testing.expectError(error.truncated, parse(&bad_table));
    // Wrong phentsize.
    var bad_entsize = img;
    std.mem.writeInt(u16, bad_entsize[42..44], 56, .little);
    try testing.expectError(error.bad_phdr, parse(&bad_entsize));
    // phnum == 0 → no PT_LOAD.
    var no_phdr = img;
    std.mem.writeInt(u16, no_phdr[44..46], 0, .little);
    try testing.expectError(error.no_load_segments, parse(&no_phdr));
}

test "elf: rejects out-of-range and oversized segments" {
    // p_filesz pointing past the buffer: the header promises bytes the
    // buffer (i.e. the file, on the staged path) does not hold, so the
    // refusal is the truncation one. M70c-K (#1504) split it out of
    // `segment_too_large` because a caller must be able to say "truncated"
    // rather than "bad segment".
    var oob = elf32_one(&@as([4]u8, @splat(@as(u8, 0))), 0x400000, 0, 0, 5);
    std.mem.writeInt(u32, oob[68..72], 9999, .little);
    std.mem.writeInt(u32, oob[72..76], 9999, .little);
    try testing.expectError(error.file_too_short, parse(&oob));

    // memsz < filesz (BSS smaller than the initialized part).
    var neg_bss = elf32_one(&@as([4]u8, @splat(@as(u8, 0))), 0x400000, 0, 0, 5);
    std.mem.writeInt(u32, neg_bss[72..76], 2, .little); // memsz < filesz (4)
    try testing.expectError(error.segment_too_large, parse(&neg_bss));

    // M72a (issue #1579): a large zero-filled BSS is ADMITTED. It costs no
    // file bytes (`memsz - filesz`), which is why the old rule — which
    // charged the mapped total against a bound named for the file — refused
    // every Go image carrying one:
    var bss_ok = elf32_one(&@as([4]u8, @splat(@as(u8, 0))), 0x400000, 0, 0, 5);
    const forty_mib: u32 = 40 * 1024 * 1024;
    std.mem.writeInt(u32, bss_ok[72..76], forty_mib, .little); // memsz ≫ filesz
    const bss_image = try parse(&bss_ok);
    try testing.expectEqual(@as(usize, forty_mib), bss_image.segments[0].mem_size);
    try testing.expect(mem_total(bss_image) > load_max); // past the old bound, still legal

    // ...but the mapped total is still bounded, and by its own name: the
    // bound now charges the VIRTUAL span (the zero-fill tail is
    // demand-paged, M171a), so a 1 GiB BSS cannot be a way to dodge the
    // acceptance bound.
    var too_much = elf32_one(&@as([4]u8, @splat(@as(u8, 0))), 0x400000, 0, 0, 5);
    std.mem.writeInt(u32, too_much[72..76], @intCast(map_max + 1), .little);
    try testing.expectError(error.map_too_large, parse(&too_much));
}

test "elf: enforces W^X segment flags and placement contract" {
    const code = @as([4]u8, @splat(@as(u8, 0)));
    // Writable first segment (RWX) → refused.
    const wtxt = elf32_one(&code, 0x400000, 0, 0, 7);
    try testing.expectError(error.writable_text, parse(&wtxt));

    // Wrong CONTIGUOUS text base: a 1-segment image at a declared base is
    // a legal GAP layout now, so refusal comes from the gap placement
    // bounds — a base at/above gap_base_max (the 0x1000_0000 mmap bump
    // region) is gap_too_high (issue #1163 I2), an unaligned base is
    // refused outright, and below-page-0 stays bad_text_base.
    const above_bound = elf32_one(&code, 0x1000_0000, 0, 0, 5);
    try testing.expectError(error.gap_too_high, parse(&above_bound));
    const unaligned_base = elf32_one(&code, 0x400800, 0, 0, 5);
    try testing.expectError(error.unaligned_gap, parse(&unaligned_base));
    const below_page0 = elf32_one(&code, 0, 0, 0, 5);
    try testing.expectError(error.bad_text_base, parse(&below_page0));

    // I2: a LATER gap segment ending at/above the bound → refused, even
    // though its base is below it (ends just past gap_base_max).
    var img2 = @as([512]u8, @splat(@as(u8, 0)));
    @memcpy(img2[0..4], &magic);
    img2[4] = 1;
    img2[5] = 1;
    img2[6] = 1;
    std.mem.writeInt(u16, img2[18..20], em_aarch64, .little);
    std.mem.writeInt(u32, img2[20..24], 1, .little);
    std.mem.writeInt(u32, img2[24..28], 0x400000, .little); // entry
    std.mem.writeInt(u32, img2[28..32], 52, .little);
    std.mem.writeInt(u16, img2[42..44], 32, .little);
    std.mem.writeInt(u16, img2[44..46], 3, .little);
    // seg0: R+X @0x400000, filesz 8, memsz 0x1000
    std.mem.writeInt(u32, img2[52..56], pt_load, .little);
    std.mem.writeInt(u32, img2[56..60], 124, .little);
    std.mem.writeInt(u32, img2[60..64], 0x400000, .little);
    std.mem.writeInt(u32, img2[68..72], 8, .little);
    std.mem.writeInt(u32, img2[72..76], 0x1000, .little);
    std.mem.writeInt(u32, img2[76..80], 5, .little);
    // seg1: rodata R @0x402000 (legal)
    std.mem.writeInt(u32, img2[84..88], pt_load, .little);
    std.mem.writeInt(u32, img2[88..92], 132, .little);
    std.mem.writeInt(u32, img2[92..96], 0x402000, .little);
    std.mem.writeInt(u32, img2[100..104], 4, .little);
    std.mem.writeInt(u32, img2[104..108], 4, .little);
    std.mem.writeInt(u32, img2[108..112], 4, .little);
    // seg2: data RW ending just PAST gap_base_max → refused (base is
    // page-aligned BELOW the bound; the END crosses it)
    const last_page: u32 = 0x1000_0000 - 0x1000; // 0x0FFF000, aligned
    std.mem.writeInt(u32, img2[116..120], pt_load, .little);
    std.mem.writeInt(u32, img2[120..124], 136, .little);
    std.mem.writeInt(u32, img2[124..128], last_page, .little);
    std.mem.writeInt(u32, img2[132..136], 4, .little);
    std.mem.writeInt(u32, img2[136..140], 0x1004, .little); // ends 4 over
    std.mem.writeInt(u32, img2[140..144], 6, .little);
    try testing.expectError(error.gap_too_high, parse(&img2));
    // Same image with the data segment INSIDE the bound → parses.
    std.mem.writeInt(u32, img2[136..140], 0x1000, .little);
    const image2 = try parse(&img2);
    try testing.expect(image2.gap_layout);
    try testing.expectEqual(@as(usize, 3), image2.segment_count);

    // Entry outside the initialized range → bad entry.
    var bad_entry_img = elf32_one(&code, 0x400000, 8, 0, 5); // filesz 12 > code 4? no: extra widens range
    _ = &bad_entry_img;
    // Simpler: point e_entry past the segment.
    var far_entry = elf32_one(&code, 0x400000, 0, 0, 5);
    std.mem.writeInt(u32, far_entry[24..28], 0x400000 + 4096, .little);
    try testing.expectError(error.bad_entry, parse(&far_entry));
}

test "elf: ELF64 parses and reports entry_rel correctly" {
    var img = @as([160]u8, @splat(@as(u8, 0)));
    @memcpy(img[0..4], &magic);
    img[4] = 2; // ELF64
    img[5] = 1;
    img[6] = 1;
    std.mem.writeInt(u16, img[16..18], 2, .little); // EXEC
    std.mem.writeInt(u16, img[18..20], em_aarch64, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little); // version
    std.mem.writeInt(u64, img[24..32], 0x400010, .little); // e_entry
    std.mem.writeInt(u64, img[32..40], 64, .little); // e_phoff
    std.mem.writeInt(u16, img[52..54], 64, .little); // e_ehsize
    std.mem.writeInt(u16, img[54..56], 56, .little); // e_phentsize
    std.mem.writeInt(u16, img[56..58], 1, .little); // e_phnum
    // phdr @64: PT_LOAD R+X, offset 120, vaddr 0x400000
    std.mem.writeInt(u32, img[64..68], pt_load, .little);
    std.mem.writeInt(u32, img[68..72], 5, .little); // R+X
    std.mem.writeInt(u64, img[72..80], 120, .little); // p_offset
    std.mem.writeInt(u64, img[80..88], 0x400000, .little); // p_vaddr
    std.mem.writeInt(u64, img[96..104], 32, .little); // p_filesz
    std.mem.writeInt(u64, img[104..112], 32, .little); // p_memsz
    const image = try parse(&img);
    try testing.expectEqual(@as(usize, 1), image.segment_count);
    try testing.expectEqual(@as(u64, 0x10), image.entry_rel);
    try testing.expectEqual(@as(usize, 120), image.segments[0].file_offset);
}

test "elf: two-segment layout validates the data-base contract" {
    // Text: vaddr 0x400000, memsz 0x1000 → data must sit at 0x401000.
    var img = @as([512]u8, @splat(@as(u8, 0)));
    @memcpy(img[0..4], &magic);
    img[4] = 1;
    img[5] = 1;
    img[6] = 1;
    std.mem.writeInt(u16, img[18..20], em_aarch64, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little);
    std.mem.writeInt(u32, img[24..28], 0x400000, .little); // entry
    std.mem.writeInt(u32, img[28..32], 52, .little); // e_phoff
    std.mem.writeInt(u16, img[42..44], 32, .little);
    std.mem.writeInt(u16, img[44..46], 2, .little); // two phdrs
    // phdr 0 @52: text, R+X, offset 116, filesz 8, memsz 0x1000
    std.mem.writeInt(u32, img[52..56], pt_load, .little);
    std.mem.writeInt(u32, img[56..60], 116, .little);
    std.mem.writeInt(u32, img[60..64], 0x400000, .little);
    std.mem.writeInt(u32, img[68..72], 8, .little);
    std.mem.writeInt(u32, img[72..76], 0x1000, .little);
    std.mem.writeInt(u32, img[76..80], 5, .little);
    // phdr 1 @84: data, RW, offset 124, vaddr 0x401000, filesz/memsz 4
    std.mem.writeInt(u32, img[84..88], pt_load, .little);
    std.mem.writeInt(u32, img[88..92], 124, .little);
    std.mem.writeInt(u32, img[92..96], 0x401000, .little);
    std.mem.writeInt(u32, img[100..104], 4, .little);
    std.mem.writeInt(u32, img[104..108], 4, .little);
    std.mem.writeInt(u32, img[108..112], 6, .little); // RW
    const image = try parse(&img);
    try testing.expectEqual(@as(usize, 2), image.segment_count);
    try testing.expectEqual(@as(usize, 124), image.segments[1].file_offset);
    try testing.expectEqual(@as(usize, 4), image.segments[1].mem_size);

    // Gap segment vaddr NOT page-aligned → refused (the kernel maps whole
    // pages at declared vaddrs).
    var misaligned = img;
    std.mem.writeInt(u32, misaligned[92..96], 0x401800, .little);
    try testing.expectError(error.unaligned_gap, parse(&misaligned));

    // Overlapping FILE ranges → refused (staging copy safety).
    var overlap = img;
    std.mem.writeInt(u32, overlap[88..92], 118, .little); // data file starts inside text file range
    try testing.expectError(error.overlapping_segments, parse(&overlap));
}

test "elf: three-segment gap layout (Go linker shape) parses with declared vaddrs" {
    // The GOOS=virelai shape (issue #1163): R+X at 0x400000, R-only rodata
    // at a page-aligned gap vaddr, RW data at another — each segment at
    // its DECLARED vaddr, flagged gap_layout.
    var img = @as([512]u8, @splat(@as(u8, 0)));
    @memcpy(img[0..4], &magic);
    img[4] = 1; // ELF32
    img[5] = 1;
    img[6] = 1;
    std.mem.writeInt(u16, img[18..20], em_aarch64, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little);
    std.mem.writeInt(u32, img[24..28], 0x400000, .little); // entry
    std.mem.writeInt(u32, img[28..32], 52, .little); // e_phoff
    std.mem.writeInt(u16, img[42..44], 32, .little);
    std.mem.writeInt(u16, img[44..46], 3, .little); // three phdrs
    // phdr 0 @52: text, R+X, offset 124, vaddr 0x400000, filesz 8, memsz 0x1000
    std.mem.writeInt(u32, img[52..56], pt_load, .little);
    std.mem.writeInt(u32, img[56..60], 124, .little);
    std.mem.writeInt(u32, img[60..64], 0x400000, .little);
    std.mem.writeInt(u32, img[68..72], 8, .little);
    std.mem.writeInt(u32, img[72..76], 0x1000, .little);
    std.mem.writeInt(u32, img[76..80], 5, .little); // R+X
    // phdr 1 @84: rodata, R, offset 132, vaddr 0x402000 (gap), filesz/memsz 4
    std.mem.writeInt(u32, img[84..88], pt_load, .little);
    std.mem.writeInt(u32, img[88..92], 132, .little);
    std.mem.writeInt(u32, img[92..96], 0x402000, .little);
    std.mem.writeInt(u32, img[100..104], 4, .little);
    std.mem.writeInt(u32, img[104..108], 4, .little);
    std.mem.writeInt(u32, img[108..112], 4, .little); // R
    // phdr 2 @116: data, RW, offset 136, vaddr 0x403000 (gap), filesz/memsz 4
    std.mem.writeInt(u32, img[116..120], pt_load, .little);
    std.mem.writeInt(u32, img[120..124], 136, .little);
    std.mem.writeInt(u32, img[124..128], 0x403000, .little);
    std.mem.writeInt(u32, img[132..136], 4, .little);
    std.mem.writeInt(u32, img[136..140], 8, .little); // memsz > filesz (bss)
    std.mem.writeInt(u32, img[140..144], 6, .little); // RW

    const image = try parse(&img);
    try testing.expectEqual(@as(usize, 3), image.segment_count);
    try testing.expect(image.gap_layout);
    try testing.expectEqual(@as(u64, 0x400000), image.segments[0].vaddr);
    try testing.expectEqual(@as(u64, 0x402000), image.segments[1].vaddr);
    try testing.expectEqual(@as(u64, 0x403000), image.segments[2].vaddr);
    try testing.expectEqual(@as(usize, 8), image.segments[2].mem_size);

    // A writable MIDDLE segment breaks the [R+X][R][RW] shape → refused.
    var wro = img;
    std.mem.writeInt(u32, wro[108..112], 6, .little); // rodata becomes RW
    try testing.expectError(error.writable_rodata, parse(&wro));

    // A read-only LAST segment → refused.
    var rdata = img;
    std.mem.writeInt(u32, rdata[140..144], 4, .little); // data becomes R
    try testing.expectError(error.readable_data, parse(&rdata));

    // A segment BELOW the previous segment's end → refused.
    var below = img;
    std.mem.writeInt(u32, below[124..128], 0x400800, .little);
    try testing.expectError(error.bad_data_base, parse(&below));

    // FOUR PT_LOAD segments → refused (max_segments is 3).
    var four = img;
    std.mem.writeInt(u16, four[44..46], 4, .little);
    // phdr 3 @148: PT_LOAD RW at 0x404000 (well-formed, just too many).
    std.mem.writeInt(u32, four[148..152], pt_load, .little);
    std.mem.writeInt(u32, four[152..156], 140, .little);
    std.mem.writeInt(u32, four[156..160], 0x404000, .little);
    std.mem.writeInt(u32, four[164..168], 4, .little);
    std.mem.writeInt(u32, four[168..172], 4, .little);
    std.mem.writeInt(u32, four[172..176], 6, .little);
    try testing.expectError(error.too_many_segments, parse(&four));
}

test "elf: parse_head validates a streamed image against its FILE size, not the window" {
    // M70c-K (issue #1504): the streamed loader reads only a header window
    // and streams each segment from the file. This image's rodata payload
    // is 3 MiB and lies entirely outside the 148-byte header window, so the
    // STAGED contract cannot validate it — while parse_head can, because it
    // is told the file's real size.
    var img = @as([256]u8, @splat(@as(u8, 0)));
    @memcpy(img[0..4], &magic);
    img[4] = 1; // ELF32
    img[5] = 1;
    img[6] = 1;
    std.mem.writeInt(u16, img[18..20], em_aarch64, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little);
    std.mem.writeInt(u32, img[24..28], 0x400000, .little); // entry
    std.mem.writeInt(u32, img[28..32], 52, .little); // e_phoff
    std.mem.writeInt(u16, img[42..44], 32, .little);
    std.mem.writeInt(u16, img[44..46], 3, .little);
    // phdr 0 @52: text R+X, file 0x100, vaddr 0x400000, filesz/memsz 0x1000
    std.mem.writeInt(u32, img[52..56], pt_load, .little);
    std.mem.writeInt(u32, img[56..60], 0x100, .little);
    std.mem.writeInt(u32, img[60..64], 0x400000, .little);
    std.mem.writeInt(u32, img[68..72], 0x1000, .little);
    std.mem.writeInt(u32, img[72..76], 0x1000, .little);
    std.mem.writeInt(u32, img[76..80], 5, .little); // R+X
    // phdr 1 @84: rodata R, file 0x2000, vaddr 0x402000, filesz 3 MiB
    std.mem.writeInt(u32, img[84..88], pt_load, .little);
    std.mem.writeInt(u32, img[88..92], 0x2000, .little);
    std.mem.writeInt(u32, img[92..96], 0x402000, .little);
    std.mem.writeInt(u32, img[100..104], 0x300000, .little);
    std.mem.writeInt(u32, img[104..108], 0x300000, .little);
    std.mem.writeInt(u32, img[108..112], 4, .little); // R
    // phdr 2 @116: data RW, file 0x302000, vaddr 0x702000, bss tail
    std.mem.writeInt(u32, img[116..120], pt_load, .little);
    std.mem.writeInt(u32, img[120..124], 0x302000, .little);
    std.mem.writeInt(u32, img[124..128], 0x702000, .little);
    std.mem.writeInt(u32, img[132..136], 0x1000, .little);
    std.mem.writeInt(u32, img[136..140], 0x2000, .little);
    std.mem.writeInt(u32, img[140..144], 6, .little); // RW

    const file_size: u64 = 0x303000; // 3 MiB + 12 KiB

    // The STAGED parse cannot validate this image: the payload is not in
    // the buffer, so the file-range check fires (`file_too_short` — from
    // a streamed caller's point of view the buffer simply is not the file).
    // That is the bound K1 removes, and pinning it here keeps the two
    // contracts distinct.
    try testing.expectError(error.file_too_short, parse(&img));

    // ...while the streamed parse accepts it and reports FILE offsets for
    // the caller to stream from.
    const image = try parse_head(&img, file_size, text_base);
    try testing.expect(image.gap_layout);
    try testing.expectEqual(@as(usize, 3), image.segment_count);
    try testing.expectEqual(@as(usize, 0x2000), image.segments[1].file_offset);
    try testing.expectEqual(@as(usize, 0x300000), image.segments[1].file_size);
    try testing.expectEqual(@as(u64, 0x702000), image.segments[2].vaddr);

    // A segment that escapes the FILE is still refused — the bound moved
    // from "fits the buffer" to "fits the file", it did not disappear.
    // This is the shape a half-copied image presents, so the refusal has
    // its own name (`file_too_short` → `image_truncated` at the exec seam).
    try testing.expectError(error.file_too_short, parse_head(&img, 0x302000, text_base));
    // A window larger than the file it claims to describe → refused.
    try testing.expectError(error.truncated, parse_head(&img, img.len - 1, text_base));

    // The acceptance bound is on INITIALIZED bytes (`load_max`, charged on
    // Σ filesz since M72a / #1579), and it is what refuses a payload the
    // file really does hold but the loader will not read: every FILE range
    // below stays valid, so the refusal can only come from that check.
    var huge = img;
    const big: u32 = load_max + 1;
    std.mem.writeInt(u32, huge[100..104], big, .little); // seg1 filesz
    std.mem.writeInt(u32, huge[104..108], big, .little); // seg1 memsz
    std.mem.writeInt(u32, huge[120..124], 0x2000 + big, .little); // seg2 offset (ordered, disjoint)
    std.mem.writeInt(u32, huge[124..128], 0x2403000, .little); // seg2 vaddr (page-aligned, above seg1)
    try testing.expectError(error.segment_too_large, parse_head(&huge, 0x2000 + big + 0x1000, text_base));

    // M72a (issue #1579): the card's shape — the Go linker's [R+X][R][RW]
    // layout whose LAST segment carries 40 MiB of `.noptrbss`. The file is
    // unchanged (zero-initialized bytes are not in it), so this is the image
    // the old `memsz`-charged bound refused as `segment_too_large` and this
    // tree admits. `mem_total` is what a staged caller still bounds against.
    var big_bss = img;
    const forty_mib: u32 = 40 * 1024 * 1024;
    std.mem.writeInt(u32, big_bss[136..140], 0x1000 + forty_mib, .little); // seg2 memsz
    const bss_image = try parse_head(&big_bss, file_size, text_base);
    try testing.expect(bss_image.gap_layout);
    try testing.expectEqual(@as(u64, 0x1000 + 0x300000 + 0x1000 + forty_mib), mem_total(bss_image));
    try testing.expect(mem_total(bss_image) > load_max);

    // The mapped bound speaks for itself, and BEFORE placement: this image's
    // declared end is far above `gap_base_max` (asserted), so a loader that
    // checked placement first would say `gap_too_high` — about address
    // space. The refusal must name MEMORY, because that is what the bound is
    // (every mapped page is allocated and zeroed).
    var giga_bss = img;
    const one_gib: u32 = 1 << 30;
    std.mem.writeInt(u32, giga_bss[136..140], one_gib, .little); // seg2 memsz
    try testing.expect(@as(u64, 0x702000) + one_gib > gap_base_max);
    try testing.expectError(error.map_too_large, parse_head(&giga_bss, file_size, text_base));

    // And a 3 MiB image is now accepted where the old 2 MiB bound refused
    // it — that raise is M70c-K's point, and it stays pinned:
    // `mem_total` is what a staged caller still bounds against.
    const big_img = try parse_head(&img, file_size, text_base);
    try testing.expectEqual(@as(u64, 0x1000 + 0x300000 + 0x2000), mem_total(big_img));
    try testing.expect(mem_total(big_img) > 2 * 1024 * 1024);
}

test "elf: collect_symbols reads a hand-built symtab" {
    // Build an ELF32 with two sections: symtab + strtab, three symbols
    // (global func "crasher", local skipped, global object "msg").
    var img = @as([512]u8, @splat(@as(u8, 0)));
    @memcpy(img[0..4], &magic);
    img[4] = 1;
    img[5] = 1;
    std.mem.writeInt(u16, img[18..20], em_aarch64, .little);
    const shoff: u32 = 52;
    std.mem.writeInt(u32, img[32..36], shoff, .little); // e_shoff
    std.mem.writeInt(u16, img[46..48], 40, .little); // e_shentsize
    std.mem.writeInt(u16, img[48..50], 2, .little); // e_shnum: symtab+strtab

    // Section 0 @52: SHT_SYMTAB, offset 132, size 48 (3 entries), link=1.
    std.mem.writeInt(u32, img[shoff..][0..4], 0, .little); // sh_name
    std.mem.writeInt(u32, img[shoff + 4 ..][0..4], 2, .little); // SHT_SYMTAB
    std.mem.writeInt(u32, img[shoff + 16 ..][0..4], 132, .little); // sh_offset
    std.mem.writeInt(u32, img[shoff + 20 ..][0..4], 48, .little); // sh_size
    std.mem.writeInt(u32, img[shoff + 24 ..][0..4], 1, .little); // sh_link -> strtab
    std.mem.writeInt(u32, img[shoff + 36 ..][0..4], 16, .little); // sh_entsize

    // Section 1 @92: SHT_STRTAB, offset 180, size 40.
    const s1 = shoff + 40;
    std.mem.writeInt(u32, img[s1 + 4 ..][0..4], 3, .little); // STRTAB
    std.mem.writeInt(u32, img[s1 + 16 ..][0..4], 180, .little);
    std.mem.writeInt(u32, img[s1 + 20 ..][0..4], 40, .little);

    // Strtab: [0]=NUL, "crasher\0", "msg\0"
    @memcpy(img[181..189], "crasher\x00");
    @memcpy(img[189..193], "msg\x00");

    // Symtab entries at 132: entry 0 is the reserved null symbol.
    // Entry 1: GLOBAL FUNC crasher @0x400010 size 20; st_name=1.
    var e1 = shoff;
    _ = &e1;
    const sym_base: u32 = 132;
    std.mem.writeInt(u32, img[sym_base + 16 ..][0..4], 1, .little); // st_name
    img[sym_base + 16 + 12] = (1 << 4) | 2; // GLOBAL FUNC
    std.mem.writeInt(u32, img[sym_base + 16 + 4 ..][0..4], 0x400010, .little); // st_value
    std.mem.writeInt(u32, img[sym_base + 16 + 8 ..][0..4], 20, .little); // st_size
    // Entry 2: LOCAL func (skipped).
    std.mem.writeInt(u32, img[sym_base + 32 ..][0..4], 9, .little);
    img[sym_base + 32 + 12] = (0 << 4) | 2;

    var out: [8]SymInfo = undefined;
    const n = collect_symbols(&img, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("crasher", out[0].name);
    try testing.expectEqual(@as(u64, 0x400010), out[0].addr);
    try testing.expectEqual(@as(u64, 20), out[0].size);

    // Stripped image (no sections) yields zero without error.
    var bare = elf32_one(&@as([4]u8, @splat(@as(u8, 0))), 0x400000, 0, 0, 5);
    _ = &bare;
    try testing.expectEqual(@as(usize, 0), collect_symbols(&bare, &out));
}

test "elf: PT_INTERP and PT_DYNAMIC program headers are parsed" {
    var img = @as([512]u8, @splat(@as(u8, 0)));
    @memcpy(img[0..4], &magic);
    img[4] = 2; // ELF64
    img[5] = 1; // little-endian
    img[6] = 1;
    std.mem.writeInt(u16, img[16..18], 2, .little); // EXEC
    std.mem.writeInt(u16, img[18..20], em_aarch64, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little);
    std.mem.writeInt(u64, img[24..32], 0x400000, .little); // e_entry
    std.mem.writeInt(u64, img[32..40], 64, .little); // e_phoff
    std.mem.writeInt(u16, img[52..54], 64, .little); // e_ehsize
    std.mem.writeInt(u16, img[54..56], 56, .little); // e_phentsize
    std.mem.writeInt(u16, img[56..58], 3, .little); // e_phnum (PT_PHDR, PT_INTERP, PT_LOAD, PT_DYNAMIC) -> 3 phdrs

    // phdr 0 @64: PT_INTERP
    std.mem.writeInt(u32, img[64..68], pt_interp, .little);
    std.mem.writeInt(u32, img[68..72], 4, .little); // R
    std.mem.writeInt(u64, img[72..80], 232, .little); // p_offset
    std.mem.writeInt(u64, img[80..88], 0x400000 + 232, .little); // p_vaddr
    std.mem.writeInt(u64, img[96..104], 6, .little); // p_filesz ("LD.SO\0")
    std.mem.writeInt(u64, img[104..112], 6, .little); // p_memsz

    // phdr 1 @120: PT_LOAD R+X
    std.mem.writeInt(u32, img[120..124], pt_load, .little);
    std.mem.writeInt(u32, img[124..128], 5, .little); // R+X
    std.mem.writeInt(u64, img[128..136], 232, .little); // p_offset
    std.mem.writeInt(u64, img[136..144], 0x400000, .little); // p_vaddr
    std.mem.writeInt(u64, img[152..160], 128, .little); // p_filesz
    std.mem.writeInt(u64, img[160..168], 128, .little); // p_memsz

    // phdr 2 @176: PT_DYNAMIC
    std.mem.writeInt(u32, img[176..180], pt_dynamic, .little);
    std.mem.writeInt(u32, img[176 + 4 ..][0..4], 6, .little); // RW
    std.mem.writeInt(u64, img[176 + 8 ..][0..8], 300, .little); // p_offset
    std.mem.writeInt(u64, img[176 + 16 ..][0..8], 0x400000 + 300, .little); // p_vaddr
    std.mem.writeInt(u64, img[176 + 32 ..][0..8], 32, .little); // p_filesz
    std.mem.writeInt(u64, img[176 + 40 ..][0..8], 32, .little); // p_memsz

    // Interp string at offset 232: "LD.SO\0"
    @memcpy(img[232..238], "LD.SO\x00");

    const image = try parse(&img);
    try testing.expect(image.interp != null);
    try testing.expectEqualStrings("LD.SO", image.interp.?);
    try testing.expect(image.has_dynamic);
    try testing.expectEqual(@as(u64, 0x400000 + 300), image.dynamic_vaddr);
    try testing.expectEqual(@as(u64, 32), image.dynamic_size);
    try testing.expectEqual(@as(u64, 0x400000), image.e_entry);
    try testing.expectEqual(@as(usize, 56), image.phentsize);
    try testing.expectEqual(@as(usize, 3), image.phnum);
}

test "elf: auxv encoding and decoding" {
    var buf: [128]u8 = @as([128]u8, @splat(@as(u8, 0)));
    const entries = [_]AuxvEntry{
        .{ .a_type = at_phdr, .a_val = 0x400040 },
        .{ .a_type = at_phent, .a_val = 56 },
        .{ .a_type = at_phnum, .a_val = 3 },
        .{ .a_type = at_entry, .a_val = 0x400080 },
        .{ .a_type = at_base, .a_val = 0x800000 },
        .{ .a_type = at_pagesz, .a_val = 4096 },
        .{ .a_type = at_null, .a_val = 0 },
    };
    const len = encode_auxv(&buf, &entries);
    try testing.expectEqual(@as(usize, 7 * 16), len);

    // Read back
    try testing.expectEqual(@as(u64, at_phdr), std.mem.readInt(u64, buf[0..8], .little));
    try testing.expectEqual(@as(u64, 0x400040), std.mem.readInt(u64, buf[8..16], .little));
    try testing.expectEqual(@as(u64, at_base), std.mem.readInt(u64, buf[64..72], .little));
    try testing.expectEqual(@as(u64, 0x800000), std.mem.readInt(u64, buf[72..80], .little));
}

test "elf: dynamic tags parsing and relocation resolution" {
    var dyn_sec: [48]u8 = @as([48]u8, @splat(@as(u8, 0)));
    // Entry 0: DT_NEEDED = 1
    std.mem.writeInt(u64, dyn_sec[0..8], dt_needed, .little);
    std.mem.writeInt(u64, dyn_sec[8..16], 1, .little); // strtab offset 1 ("LIBUI.SO")
    // Entry 1: DT_STRTAB = 0x401000
    std.mem.writeInt(u64, dyn_sec[16..24], dt_strtab, .little);
    std.mem.writeInt(u64, dyn_sec[24..32], 0x401000, .little);
    // Entry 2: DT_NULL
    std.mem.writeInt(u64, dyn_sec[32..40], dt_null, .little);
    std.mem.writeInt(u64, dyn_sec[40..48], 0, .little);

    var tags: [4]Elf64Dyn = undefined;
    const n = parse_dynamic_tags(&dyn_sec, &tags);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u64, 0x401000), find_dynamic_tag(&tags, dt_strtab).?);
    try testing.expectEqual(@as(?u64, null), find_dynamic_tag(&tags, dt_symtab));

    // Relocations
    const rel_rel = Elf64Rela{
        .r_offset = 0x402000,
        .r_info = r_aarch64_relative,
        .r_addend = 0x100,
    };
    try testing.expectEqual(@as(?u64, 0x500100), resolve_relocation(rel_rel, 0x500000, 0));

    const rel_glob = Elf64Rela{
        .r_offset = 0x402008,
        .r_info = (@as(u64, 5) << 32) | r_aarch64_glob_dat,
        .r_addend = 0,
    };
    try testing.expectEqual(@as(?u64, 0x700010), resolve_relocation(rel_glob, 0x500000, 0x700010));
}
