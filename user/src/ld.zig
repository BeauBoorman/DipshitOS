//! census (M188e, #3190): LD.SO — gate-referenced: gate-exercised as the PT_INTERP interpreter exec loads for DYNAPP.ELF (live-dynamic-linking, live-dynamic-ecosystem).
//! VirelaiOS Freestanding Runtime Linker (LD.SO, Milestone 30 Dynamic Linking).
//!
//! Zero libc/POSIX, zero external runtime. Maps and relocates ELF dynamic
//! executables and shared libraries (LIBUI.SO, LIBFONT.SO) on Apple Silicon AArch64.

const std = @import("std");
const builtin = @import("builtin");

// Syscall numbers (ADR 0007 / ADR 0010)
const sys_write_num: u64 = 1;
const sys_exit_num: u64 = 3;
const sys_file_open_num: u64 = 23;
const sys_file_read_num: u64 = 24;
const sys_file_close_num: u64 = 26;
const mode_read: u32 = 1;

// Program header types (PT_*)
pub const pt_null: u32 = 0;
pub const pt_load: u32 = 1;
pub const pt_dynamic: u32 = 2;
pub const pt_interp: u32 = 3;
pub const pt_note: u32 = 4;
pub const pt_shlib: u32 = 5;
pub const pt_phdr: u32 = 6;
pub const pt_tls: u32 = 7;

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
pub const dt_jmprel: u64 = 23;

// AArch64 relocations
pub const r_aarch64_none: u32 = 0;
pub const r_aarch64_abs64: u32 = 257;
pub const r_aarch64_glob_dat: u32 = 1025;
pub const r_aarch64_jump_slot: u32 = 1026;
pub const r_aarch64_relative: u32 = 1027;

// Auxiliary vector types (AT_*)
pub const at_null: u64 = 0;
pub const at_phdr: u64 = 3;
pub const at_phent: u64 = 4;
pub const at_phnum: u64 = 5;
pub const at_pagesz: u64 = 6;
pub const at_base: u64 = 7;
pub const at_entry: u64 = 9;

pub const Auxv = struct {
    phdr: u64 = 0,
    phent: u64 = 56,
    phnum: u64 = 0,
    entry: u64 = 0,
    base: u64 = 0,
    pagesz: u64 = 4096,
};

pub const Elf64Dyn = extern struct {
    d_tag: u64,
    d_val: u64,
};

pub const Elf64Rela = extern struct {
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

pub const Elf64Sym = extern struct {
    st_name: u32,
    st_info: u8,
    st_other: u8,
    st_shndx: u16,
    st_value: u64,
    st_size: u64,
};

pub const Elf64Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

pub const LoadedLib = struct {
    name: [32]u8 = @as([32]u8, @splat(@as(u8, 0))),
    name_len: usize = 0,
    base_va: u64 = 0,
    strtab: ?[*]const u8 = null,
    strsz: usize = 0,
    symtab: ?[*]const Elf64Sym = null,
    sym_count: usize = 0,
};

pub const max_loaded_libs = 8;
var loaded_libs: [max_loaded_libs]LoadedLib = @as([max_loaded_libs]LoadedLib, @splat(@as(LoadedLib, .{})));
var loaded_lib_count: usize = 0;

// M97c #2099: the shared-library window contract, mirrored from the
// kernel side (`exec.zig`'s lib_slot_bytes/lib_slot_count). The kernel
// maps exactly this pool at lib_heap_base; the bump pointer and the
// table bound share the count so a library's bytes can never run past
// the mapped aperture.
pub const lib_heap_base: u64 = 0x0100_0000;
pub const lib_slot_bytes: u64 = 0x10000;
pub const lib_slot_count: usize = max_loaded_libs;
pub const lib_heap_end: u64 = lib_heap_base + lib_slot_bytes * lib_slot_count;

// Shared library placement heap — one slot per loaded library.
var next_lib_va: u64 = lib_heap_base;

// ELF64 fixed fields (all image reads go through bounds-checked helpers).
const elf_class_64: u8 = 2;
const elf_data_lsb: u8 = 1;
const elf_version_current: u8 = 1;
const elf_machine_aarch64: u16 = 183;
const elf_et_dyn: u16 = 3;
const elf_phentsize: usize = @sizeOf(Elf64Phdr);
const max_phnum: usize = 32;

/// M97c #2099: a PT_LOAD window of an image under relocation — every
/// dynamic-table pointer and every relocation WRITE target must resolve
/// inside one of these. Writable windows are the only legal relocation
/// destinations.
const LoadWindow = struct {
    start: u64,
    end: u64,
    writable: bool,
};
const max_load_windows: usize = 4;

fn lib_u16(buf: [*]const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .little);
}

fn lib_u32(buf: [*]const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

fn lib_u64(buf: [*]const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off..][0..8], .little);
}

/// #2099: a counted-string fetch against a BOUNDED string table — the
/// untrusted `st_name`/DT_* offsets are never allowed to produce an
/// unbounded `sliceTo` scan past the table.
fn dyn_str(strtab: [*]const u8, strsz: usize, off: u64) ?[]const u8 {
    if (off >= strsz or off > std.math.maxInt(usize)) return null;
    const start: usize = @intCast(off);
    const window = strtab[start..strsz];
    const nul = std.mem.indexOfScalar(u8, window, 0) orelse return null;
    return window[0..nul];
}

/// #2099: bounded string compare — `name` must equal the table entry at
/// `st_name` AND terminate inside the table.
fn dyn_name_eq(strtab: [*]const u8, strsz: usize, st_name: u32, name: []const u8) bool {
    if (st_name >= strsz) return false;
    const start: usize = st_name;
    const avail = strsz - start;
    if (name.len + 1 > avail) return false;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (strtab[start + i] != name[i]) return false;
    }
    return strtab[start + name.len] == 0;
}

/// #2099: does `[va, va+size)` sit inside one of the image's PT_LOAD
/// windows (writable when `need_write`)? Wrap-safe.
fn window_contains(windows: []const LoadWindow, va: u64, size: u64, need_write: bool) bool {
    if (size > std.math.maxInt(u64) - va) return false;
    const end = va + size;
    for (windows) |w| {
        if (va >= w.start and end <= w.end and (!need_write or w.writable)) return true;
    }
    return false;
}

/// Collect the image's PT_LOAD windows from its (mapped) phdr table.
fn collect_load_windows(phdr_base: u64, phent: usize, phnum: usize, out: *[max_load_windows]LoadWindow) usize {
    var n: usize = 0;
    if (phent != elf_phentsize or (phdr_base & 7) != 0 or phnum > max_phnum) return 0;
    var i: usize = 0;
    while (i < phnum and n < max_load_windows) : (i += 1) {
        const ph: *const Elf64Phdr = @ptrFromInt(phdr_base + i * phent);
        if (ph.p_type != pt_load) continue;
        // Refuse degenerate or wrapping windows outright.
        if (ph.p_memsz == 0 or ph.p_memsz > std.math.maxInt(u64) - ph.p_vaddr) continue;
        out[n] = .{ .start = ph.p_vaddr, .end = ph.p_vaddr + ph.p_memsz, .writable = (ph.p_flags & 2) != 0 };
        n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Syscall helpers
// ---------------------------------------------------------------------------

fn sys_write(fd: u64, msg: []const u8) void {
    if (builtin.is_test) return; // host tests have no kernel to call
    if (msg.len == 0) return;
    _ = asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 1)),
          [arg0] "{x0}" (fd),
          [arg1] "{x1}" (@as(u64, @intFromPtr(msg.ptr))),
          [arg2] "{x2}" (@as(u64, msg.len)),
    );
}

fn sys_file_open(path: []const u8, mode: u32) i64 {
    if (builtin.is_test) return -1;
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 23)),
          [arg0] "{x0}" (@as(u64, @intFromPtr(path.ptr))),
          [arg1] "{x1}" (@as(u64, path.len)),
          [arg2] "{x2}" (@as(u64, mode)),
    );
}

fn sys_file_read(fd: u64, buf: [*]u8, len: usize) i64 {
    if (builtin.is_test) return -1;
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 24)),
          [arg0] "{x0}" (fd),
          [arg1] "{x1}" (@as(u64, @intFromPtr(buf))),
          [arg2] "{x2}" (@as(u64, len)),
    );
}

fn sys_file_close(fd: u64) void {
    if (builtin.is_test) return;
    _ = asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 26)),
          [arg0] "{x0}" (fd),
    );
}

fn sys_exit(code: u64) noreturn {
    if (builtin.is_test) unreachable;
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 3)),
          [arg0] "{x0}" (code),
    );
    unreachable;
}

// ---------------------------------------------------------------------------
// Linker Logic
// ---------------------------------------------------------------------------

pub fn parse_auxv(auxv_ptr: [*]const u64) Auxv {
    var av = Auxv{};
    var i: usize = 0;
    // #2099: bound the scan — an auxv with no AT_NULL must not walk off
    // the stack.
    while (i < 128) : (i += 2) {
        const a_type = auxv_ptr[i];
        const a_val = auxv_ptr[i + 1];
        if (a_type == at_null) break;
        switch (a_type) {
            at_phdr => av.phdr = a_val,
            at_phent => av.phent = a_val,
            at_phnum => av.phnum = a_val,
            at_entry => av.entry = a_val,
            at_base => av.base = a_val,
            at_pagesz => av.pagesz = a_val,
            else => {},
        }
    }
    return av;
}

pub fn find_phdr_dynamic(phdr_base: u64, phent: usize, phnum: usize) ?*const Elf64Phdr {
    // #2099: the phdr table must be the real, aligned layout — a hostile
    // phent/phnum pair must not turn the walk into unaligned or runaway
    // pointer arithmetic.
    if (phent != elf_phentsize or (phdr_base & 7) != 0 or phnum == 0 or phnum > max_phnum) return null;
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const phdr: *const Elf64Phdr = @ptrFromInt(phdr_base + i * phent);
        if (phdr.p_type == pt_dynamic) return phdr;
    }
    return null;
}

pub fn lookup_symbol_in_libs(sym_name: []const u8) ?u64 {
    for (loaded_libs[0..loaded_lib_count]) |lib| {
        if (lib.strtab == null or lib.symtab == null) continue;
        var i: usize = 0;
        while (i < lib.sym_count) : (i += 1) {
            const sym = lib.symtab.?[i];
            if (!dyn_name_eq(lib.strtab.?, lib.strsz, sym.st_name, sym_name)) continue;
            // #2099: a resolved address must name a VA inside the
            // library's own slot — a crafted st_value must not escape it.
            if (sym.st_value >= lib_slot_bytes) continue;
            return lib.base_va + sym.st_value;
        }
    }
    return null;
}

/// M97c #2099: validate a staged library image in its 64 KiB slot. Every
/// field comes from the share — untrusted bytes. All reads are bounded by
/// `lib_slot_bytes`; a malformed image is refused, never partially
/// trusted.
fn valid_lib_image(lib_buf: [*]const u8) bool {
    if (lib_buf[0] != 0x7f or lib_buf[1] != 'E' or lib_buf[2] != 'L' or lib_buf[3] != 'F') return false;
    if (lib_buf[4] != elf_class_64 or lib_buf[5] != elf_data_lsb or lib_buf[6] != elf_version_current) return false;
    if (lib_u16(lib_buf, 16) != elf_et_dyn) return false; // a library is ET_DYN
    if (lib_u16(lib_buf, 18) != elf_machine_aarch64) return false;
    if (lib_u32(lib_buf, 20) != 1) return false; // e_version == EV_CURRENT
    const e_phoff = lib_u64(lib_buf, 32);
    const e_phentsize = lib_u16(lib_buf, 54);
    const e_phnum = lib_u16(lib_buf, 56);
    if (e_phentsize != elf_phentsize or e_phnum == 0 or e_phnum > max_phnum) return false;
    if (e_phoff >= lib_slot_bytes or @as(u64, e_phnum) * elf_phentsize > lib_slot_bytes - e_phoff) return false;
    return true;
}

/// #2099: bounded phdr read inside the staged slot. `ph_off` is trusted
/// only so far — the caller validated `e_phoff + phnum*phentsize` against
/// the slot end before any field is touched.
fn lib_phdr(lib_buf: [*]const u8, ph_off: usize) Elf64Phdr {
    return .{
        .p_type = lib_u32(lib_buf, ph_off),
        .p_flags = lib_u32(lib_buf, ph_off + 4),
        .p_offset = lib_u64(lib_buf, ph_off + 8),
        .p_vaddr = lib_u64(lib_buf, ph_off + 16),
        .p_paddr = lib_u64(lib_buf, ph_off + 24),
        .p_filesz = lib_u64(lib_buf, ph_off + 32),
        .p_memsz = lib_u64(lib_buf, ph_off + 40),
        .p_align = lib_u64(lib_buf, ph_off + 48),
    };
}

/// #2099: `[off, off+len)` inside the staged slot, wrap-safe.
fn slot_contains(off: u64, len: u64) bool {
    return off <= lib_slot_bytes and len <= lib_slot_bytes - off;
}

pub fn load_shared_library(name: []const u8) ?*LoadedLib {
    // Check if already loaded
    for (loaded_libs[0..loaded_lib_count]) |*lib| {
        if (std.mem.eql(u8, lib.name[0..lib.name_len], name)) return lib;
    }
    // #2099: the count bound IS the aperture bound — `next_lib_va` starts
    // at lib_heap_base and advances exactly one lib_slot_bytes per
    // successful load, so `loaded_lib_count == lib_slot_count` means the
    // bump pointer sits at lib_heap_end and another library would land
    // outside the kernel-mapped pool.
    if (loaded_lib_count >= lib_slot_count) return null;
    // #2099: the name lands in a fixed 32-byte field — a longer name is
    // refused, not truncated-or-overflowed.
    if (name.len == 0 or name.len > 32) return null;

    sys_write(1, "ld.so: loading shared library: ");
    sys_write(1, name);
    sys_write(1, "\n");

    const lib_dest_va = next_lib_va;
    const lib_buf: [*]const u8 = @ptrFromInt(lib_dest_va);
    var present = false;

    if (lib_buf[0] == 0x7f and lib_buf[1] == 'E' and lib_buf[2] == 'L' and lib_buf[3] == 'F') {
        present = true;
    } else {
        const fd = sys_file_open(name, mode_read);
        if (fd >= 0) {
            defer sys_file_close(@intCast(fd));
            const mut_lib_buf: [*]u8 = @ptrFromInt(lib_dest_va);
            const read_bytes = sys_file_read(@intCast(fd), mut_lib_buf, lib_slot_bytes);
            if (read_bytes > 64) {
                present = true;
            }
        }
    }

    if (!present) {
        sys_write(1, "ld.so: file not found: ");
        sys_write(1, name);
        sys_write(1, "\n");
        return null;
    }

    // #2099: validate the staged bytes before a single field is trusted.
    if (!valid_lib_image(lib_buf)) {
        sys_write(1, "ld.so: malformed library image: ");
        sys_write(1, name);
        sys_write(1, "\n");
        return null;
    }

    const e_phoff: usize = @intCast(lib_u64(lib_buf, 32));
    const e_phnum: usize = lib_u16(lib_buf, 56);

    // Walk the phdrs: every PT_LOAD must map inside the slot; PT_DYNAMIC's
    // byte range must sit inside it too.
    var dyn_phdr: ?Elf64Phdr = null;
    var p: usize = 0;
    while (p < e_phnum) : (p += 1) {
        const ph = lib_phdr(lib_buf, e_phoff + p * elf_phentsize);
        switch (ph.p_type) {
            pt_load => {
                if (!slot_contains(ph.p_offset, ph.p_filesz)) return null;
                if (ph.p_memsz < ph.p_filesz) return null;
                // The library's declared vaddrs are slot-relative: its
                // mapped span must fit inside the slot.
                if (!slot_contains(ph.p_vaddr, ph.p_memsz)) return null;
            },
            pt_dynamic => {
                if (!slot_contains(ph.p_offset, ph.p_filesz)) return null;
                if (ph.p_filesz == 0 or ph.p_filesz % @sizeOf(Elf64Dyn) != 0) return null;
                if (!slot_contains(ph.p_vaddr, ph.p_filesz)) return null;
                dyn_phdr = ph;
            },
            else => {},
        }
    }

    // Scan PT_DYNAMIC into LOCALS first — nothing is committed to the
    // loaded-table or the bump pointer until every untrusted field has
    // been checked. A table without DT_NULL is refused, not truncated.
    var strtab_off: ?u64 = null;
    var symtab_off: ?u64 = null;
    var strsz: u64 = 0;
    if (dyn_phdr) |dph| {
        const dyn_off: usize = @intCast(dph.p_offset);
        const dyn_entries: usize = @intCast(dph.p_filesz / @sizeOf(Elf64Dyn));
        var terminated = false;
        var d: usize = 0;
        while (d < dyn_entries) : (d += 1) {
            const tag = lib_u64(lib_buf, dyn_off + d * 16);
            const val = lib_u64(lib_buf, dyn_off + d * 16 + 8);
            if (tag == dt_null) {
                terminated = true;
                break;
            }
            switch (tag) {
                dt_strtab => strtab_off = val,
                dt_symtab => symtab_off = val,
                dt_strsz => strsz = val,
                else => {},
            }
        }
        if (!terminated) return null;
        // Both tables must live inside the slot, and strsz must not run
        // past the slot end — a malformed table leaves the lib slot empty
        // but the load still refuses rather than half-trusting it.
        if (strtab_off != null and !slot_contains(strtab_off.?, strsz)) return null;
        if (strsz > 0 and strtab_off == null) return null;
        if (symtab_off != null and !slot_contains(symtab_off.?, @sizeOf(Elf64Sym))) return null;
    }

    // Advance heap for next library (one slot each)
    next_lib_va += lib_slot_bytes;

    const lib_slot = &loaded_libs[loaded_lib_count];
    lib_slot.* = .{};
    @memcpy(lib_slot.name[0..name.len], name);
    lib_slot.name_len = name.len;
    lib_slot.base_va = lib_dest_va;

    if (strtab_off != null and symtab_off != null and strsz > 0) {
        const so = strtab_off.?;
        const yo = symtab_off.?;
        lib_slot.strtab = @ptrFromInt(lib_dest_va + so);
        lib_slot.strsz = @intCast(strsz);
        lib_slot.symtab = @ptrFromInt(lib_dest_va + yo);
        // Symbol count is bounded by the slot bytes after symtab — never
        // by the untrusted table's own contents alone.
        const sym_cap: usize = @intCast((lib_slot_bytes - yo) / @sizeOf(Elf64Sym));
        var sc: usize = 1;
        while (sc < sym_cap) : (sc += 1) {
            const s = lib_slot.symtab.?[sc];
            if (s.st_name >= strsz) break;
            if (s.st_name == 0 and s.st_value == 0 and s.st_size == 0) break;
        }
        lib_slot.sym_count = sc;
    }

    loaded_lib_count += 1;
    return lib_slot;
}

/// M97c #2099: apply the main image's relocations. `phdr_base`/`phent`/
/// `phnum` come from the auxv so the image's PT_LOAD windows — the only
/// legal span for every dynamic-table pointer and every relocation write
/// — are known. A dynamic table or relocation outside the image's own
/// segments is ignored, never chased into another window.
pub fn relocate_main(dyn_phdr: *const Elf64Phdr, base_va: u64, phdr_base: u64, phent: usize, phnum: usize) void {
    var wins: [max_load_windows]LoadWindow = undefined;
    const win_count = collect_load_windows(phdr_base, phent, phnum, &wins);
    const windows = wins[0..win_count];
    if (win_count == 0) return;

    // PT_DYNAMIC must itself sit inside a PT_LOAD window.
    if (dyn_phdr.p_filesz == 0 or dyn_phdr.p_filesz % @sizeOf(Elf64Dyn) != 0) return;
    if (!window_contains(windows, dyn_phdr.p_vaddr, dyn_phdr.p_filesz, false)) return;

    const dyn_ptr: [*]const Elf64Dyn = @ptrFromInt(dyn_phdr.p_vaddr);
    const dyn_count: usize = @intCast(dyn_phdr.p_filesz / @sizeOf(Elf64Dyn));

    var strtab: ?[*]const u8 = null;
    var strsz: usize = 0;
    var symtab: ?[*]const Elf64Sym = null;
    var sym_cap: usize = 0;
    var rela_va: u64 = 0;
    var rela_sz: u64 = 0;
    var jmprel_va: u64 = 0;
    var jmprel_sz: u64 = 0;

    // Collect dynamic info — bounded scan, must find DT_NULL.
    var terminated = false;
    var d: usize = 0;
    while (d < dyn_count) : (d += 1) {
        const tag = dyn_ptr[d].d_tag;
        const val = dyn_ptr[d].d_val;
        if (tag == dt_null) {
            terminated = true;
            break;
        }
        switch (tag) {
            dt_strtab => {
                strtab = @ptrFromInt(val);
            },
            dt_strsz => strsz = @intCast(val),
            dt_symtab => symtab = @ptrFromInt(val),
            dt_rela => rela_va = val,
            dt_relasz => rela_sz = val,
            dt_jmprel => jmprel_va = val,
            dt_pltrelsz => jmprel_sz = val,
            else => {},
        }
    }
    if (!terminated) return;

    // Validate the collected tables against the image's windows. A table
    // outside them is dropped — a wrong pointer is worse than a missing
    // one.
    if (strtab != null and strsz > 0) {
        const st_va = @intFromPtr(strtab.?);
        if (!window_contains(windows, st_va, strsz, false)) {
            strtab = null;
            strsz = 0;
        }
    } else {
        strtab = null;
        strsz = 0;
    }
    if (symtab) |st| {
        const st_va = @intFromPtr(st);
        // symtab must sit inside a window; the symbol count cap is the
        // window's remaining bytes, so a crafted index can never read past it.
        var cap: usize = 0;
        for (windows) |w| {
            if (st_va >= w.start and st_va < w.end) {
                cap = @intCast((w.end - st_va) / @sizeOf(Elf64Sym));
                break;
            }
        }
        if (cap == 0) {
            symtab = null;
        } else {
            sym_cap = cap;
        }
    }

    // Now load all DT_NEEDED libraries — names are bounded string-table
    // fetches, never unbounded scans.
    if (strtab) |st| {
        d = 0;
        while (d < dyn_count) : (d += 1) {
            if (dyn_ptr[d].d_tag == dt_null) break;
            if (dyn_ptr[d].d_tag == dt_needed) {
                if (dyn_str(st, strsz, dyn_ptr[d].d_val)) |lib_name| {
                    _ = load_shared_library(lib_name);
                }
            }
        }
    }

    // Process DT_RELA / DT_JMPREL relocations — each table must sit inside
    // a PT_LOAD window and each entry is applied only when its WRITE
    // target lands in a WRITABLE one.
    if (rela_sz > 0 and window_contains(windows, rela_va, rela_sz, false)) {
        const relas: [*]const Elf64Rela = @ptrFromInt(rela_va);
        const count: usize = @intCast(rela_sz / @sizeOf(Elf64Rela));
        for (relas[0..count]) |rel| {
            apply_relocation(rel, base_va, strtab, strsz, symtab, sym_cap, windows);
        }
    }
    if (jmprel_sz > 0 and window_contains(windows, jmprel_va, jmprel_sz, false)) {
        const jmprels: [*]const Elf64Rela = @ptrFromInt(jmprel_va);
        const count: usize = @intCast(jmprel_sz / @sizeOf(Elf64Rela));
        for (jmprels[0..count]) |rel| {
            apply_relocation(rel, base_va, strtab, strsz, symtab, sym_cap, windows);
        }
    }
}

fn apply_relocation(rel: Elf64Rela, base_va: u64, strtab: ?[*]const u8, strsz: usize, symtab: ?[*]const Elf64Sym, sym_cap: usize, windows: []const LoadWindow) void {
    const rtype = rel.r_type();
    if (rtype == r_aarch64_none) return;
    // #2099: the relocation WRITE target must land inside a writable
    // PT_LOAD window — an untrusted r_offset otherwise picks any VA in the
    // address space (ld.so's own pages, the lib slots, unmapped ground).
    if (!window_contains(windows, rel.r_offset, @sizeOf(u64), true)) return;
    const target: *u64 = @ptrFromInt(rel.r_offset);

    switch (rtype) {
        r_aarch64_relative => {
            target.* = base_va +% @as(u64, @bitCast(rel.r_addend));
        },
        r_aarch64_glob_dat, r_aarch64_jump_slot, r_aarch64_abs64 => {
            if (strtab == null or symtab == null) return;
            // #2099: the symbol index is untrusted — bound it by the
            // window-derived cap, and fetch the name bounded by strsz.
            if (rel.sym() >= sym_cap) return;
            const sym = symtab.?[rel.sym()];
            const sym_name = dyn_str(strtab.?, strsz, sym.st_name) orelse return;
            if (lookup_symbol_in_libs(sym_name)) |sym_addr| {
                target.* = sym_addr +% @as(u64, @bitCast(rel.r_addend));
            } else {
                sys_write(1, "ld.so: warning unresolved symbol: ");
                sys_write(1, sym_name);
                sys_write(1, "\n");
            }
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Entry Point (_start)
// ---------------------------------------------------------------------------

comptime {
    if (@import("builtin").os.tag == .freestanding) {
        @export(&_start, .{ .name = "_start", .linkage = .strong });
    }
}

fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\// x0 = argc, x1 = argv_va, x2 = auxv_va
        \\mov x19, x0 // preserve argc
        \\mov x20, x1 // preserve argv_va
        \\mov x21, x2 // preserve auxv_va
        \\
        \\// If x2 (auxv_va) is not passed, find auxv on stack
        \\cbnz x21, 1f
        \\mov x21, sp
        \\add x21, x21, #24 // skip argc, argv NULL, envp NULL
        \\1:
        \\sub sp, sp, #32
        \\stp x29, x30, [sp, #16]
        \\mov x29, sp
        \\
        \\mov x0, x21
        \\bl ld_main
        \\
        \\mov x9, x0
        \\ldp x29, x30, [sp, #16]
        \\add sp, sp, #32
        \\
        \\mov x0, x19 // restore argc
        \\mov x1, x20 // restore argv_va
        \\br x9      // jump to executable entry point
    );
}

export fn ld_main(auxv_ptr: [*]const u64) u64 {
    sys_write(1, "ld.so: freestanding dynamic runtime linker active\n");

    const av = parse_auxv(auxv_ptr);
    if (av.phdr == 0 or av.entry == 0) {
        sys_write(1, "ld.so: error bad auxv\n");
        sys_exit(1);
    }

    if (find_phdr_dynamic(av.phdr, @intCast(av.phent), @intCast(av.phnum))) |dyn_phdr| {
        // #2099: the phdr table rides along so relocation targets and
        // dynamic-table pointers are confined to the image's PT_LOAD
        // windows.
        relocate_main(dyn_phdr, 0x0040_0000, av.phdr, @intCast(av.phent), @intCast(av.phnum));
    }

    sys_write(1, "ld.so: relocations resolved successfully, entering main application\n");
    return av.entry;
}

// ---------------------------------------------------------------------------
// Runtime Dynamic Plugin API (dlopen / dlsym / dlclose)
// ---------------------------------------------------------------------------

/// #2099: cap on a NUL-terminated caller-supplied name — the scan is
/// bounded even if the terminator never comes.
const max_sym_name: usize = 256;

fn bounded_cstr(ptr: [*:0]const u8) ?[]const u8 {
    const span = ptr[0..max_sym_name];
    const nul = std.mem.indexOfScalar(u8, span, 0) orelse return null;
    return span[0..nul];
}

pub export fn dlopen(filename: [*:0]const u8, flags: i32) ?*anyopaque {
    _ = flags;
    const name = bounded_cstr(filename) orelse return null;
    const lib = load_shared_library(name) orelse return null;
    return @ptrCast(lib);
}

pub export fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque {
    const sym_name = bounded_cstr(symbol) orelse return null;
    if (handle) |h| {
        const lib: *LoadedLib = @ptrCast(@alignCast(h));
        if (lib.strtab == null or lib.symtab == null) return null;
        var i: usize = 0;
        while (i < lib.sym_count) : (i += 1) {
            const sym = lib.symtab.?[i];
            if (!dyn_name_eq(lib.strtab.?, lib.strsz, sym.st_name, sym_name)) continue;
            // #2099: resolved addresses stay inside the library's slot.
            if (sym.st_value >= lib_slot_bytes) return null;
            return @ptrFromInt(lib.base_va + sym.st_value);
        }
        return null;
    } else {
        if (lookup_symbol_in_libs(sym_name)) |addr| {
            return @ptrFromInt(addr);
        }
        return null;
    }
}

pub export fn dlclose(handle: ?*anyopaque) i32 {
    _ = handle;
    return 0;
}

// ---------------------------------------------------------------------------
// Host Unit Tests
// ---------------------------------------------------------------------------

test "ld: parse_auxv extracts standard AT_* vectors" {
    const testing = std.testing;
    const raw_auxv = [_]u64{
        at_phdr,   0x400040,
        at_phent,  56,
        at_phnum,  4,
        at_entry,  0x401000,
        at_base,   0x800000,
        at_pagesz, 4096,
        at_null,   0,
    };
    const av = parse_auxv(&raw_auxv);
    try testing.expectEqual(@as(u64, 0x400040), av.phdr);
    try testing.expectEqual(@as(u64, 56), av.phent);
    try testing.expectEqual(@as(u64, 4), av.phnum);
    try testing.expectEqual(@as(u64, 0x401000), av.entry);
    try testing.expectEqual(@as(u64, 0x800000), av.base);
    try testing.expectEqual(@as(u64, 4096), av.pagesz);
}

test "ld: symbol lookup across loaded libraries" {
    const testing = std.testing;
    loaded_lib_count = 0;

    const sym_names = "\x00ui_win_open\x00ui_win_fill\x00";
    const syms = [_]Elf64Sym{
        .{ .st_name = 0, .st_info = 0, .st_other = 0, .st_shndx = 0, .st_value = 0, .st_size = 0 },
        .{ .st_name = 1, .st_info = 0x12, .st_other = 0, .st_shndx = 1, .st_value = 0x100, .st_size = 32 },
        .{ .st_name = 13, .st_info = 0x12, .st_other = 0, .st_shndx = 1, .st_value = 0x200, .st_size = 32 },
    };

    var lib = &loaded_libs[0];
    const name = "LIBUI.SO";
    @memcpy(lib.name[0..name.len], name);
    lib.name_len = name.len;
    lib.base_va = 0x0100_0000;
    lib.strtab = sym_names.ptr;
    lib.strsz = sym_names.len;
    lib.symtab = &syms;
    lib.sym_count = 3;
    loaded_lib_count = 1;

    try testing.expectEqual(@as(?u64, 0x0100_0100), lookup_symbol_in_libs("ui_win_open"));
    try testing.expectEqual(@as(?u64, 0x0100_0200), lookup_symbol_in_libs("ui_win_fill"));
    try testing.expectEqual(@as(?u64, null), lookup_symbol_in_libs("nonexistent"));

    const sym_ptr = dlsym(@ptrCast(lib), "ui_win_open");
    try testing.expect(sym_ptr != null);
    try testing.expectEqual(@as(usize, 0x0100_0100), @intFromPtr(sym_ptr.?));

    const sym_global = dlsym(null, "ui_win_fill");
    try testing.expect(sym_global != null);
    try testing.expectEqual(@as(usize, 0x0100_0200), @intFromPtr(sym_global.?));

    try testing.expect(dlsym(null, "missing") == null);
}

// ---------------------------------------------------------------------------
// M97c #2099: malformed-input suite. A fabricated slot buffer stands in for
// the kernel-mapped library window (`next_lib_va` is redirected at it), so
// the whole staged-load path runs without a kernel.
// ---------------------------------------------------------------------------

var test_lib_image: [lib_slot_bytes]u8 align(4096) = @as([lib_slot_bytes]u8, @splat(@as(u8, 0)));

fn seed_lib_image() void {
    @memset(&test_lib_image, 0);
    const img = &test_lib_image;
    img[0] = 0x7f;
    img[1] = 'E';
    img[2] = 'L';
    img[3] = 'F';
    img[4] = elf_class_64;
    img[5] = elf_data_lsb;
    img[6] = elf_version_current;
    std.mem.writeInt(u16, img[16..18], elf_et_dyn, .little);
    std.mem.writeInt(u16, img[18..20], elf_machine_aarch64, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little); // e_version = EV_CURRENT
    std.mem.writeInt(u64, img[32..40], 0x40, .little); // e_phoff
    std.mem.writeInt(u16, img[54..56], elf_phentsize, .little);
    std.mem.writeInt(u16, img[56..58], 2, .little); // e_phnum
    // phdr0: PT_LOAD covering the staged bytes.
    const ph0: *Elf64Phdr = @ptrCast(@alignCast(img[0x40..].ptr));
    ph0.* = .{ .p_type = pt_load, .p_flags = 5, .p_offset = 0, .p_vaddr = 0, .p_paddr = 0, .p_filesz = 0x800, .p_memsz = 0x800, .p_align = 0x1000 };
    // phdr1: PT_DYNAMIC at file offset 0x200, four entries.
    const ph1: *Elf64Phdr = @ptrCast(@alignCast(img[0x40 + 56 ..].ptr));
    ph1.* = .{ .p_type = pt_dynamic, .p_flags = 6, .p_offset = 0x200, .p_vaddr = 0x200, .p_paddr = 0, .p_filesz = 4 * @sizeOf(Elf64Dyn), .p_memsz = 4 * @sizeOf(Elf64Dyn), .p_align = 8 };
    // dynamic table: STRTAB/STRSZ/SYMTAB/NULL
    const dyn: [*]Elf64Dyn = @ptrCast(@alignCast(img[0x200..].ptr));
    dyn[0] = .{ .d_tag = dt_strtab, .d_val = 0x300 };
    dyn[1] = .{ .d_tag = dt_strsz, .d_val = 0x20 };
    dyn[2] = .{ .d_tag = dt_symtab, .d_val = 0x340 };
    dyn[3] = .{ .d_tag = dt_null, .d_val = 0 };
    // strtab + symtab
    @memcpy(img[0x300..][0..9], "\x00testfn\x00\x00");
    const syms: [*]Elf64Sym = @ptrCast(@alignCast(img[0x340..].ptr));
    syms[0] = .{ .st_name = 0, .st_info = 0, .st_other = 0, .st_shndx = 0, .st_value = 0, .st_size = 0 };
    syms[1] = .{ .st_name = 1, .st_info = 0x12, .st_other = 0, .st_shndx = 1, .st_value = 0x80, .st_size = 8 };
}

fn reset_lib_state() void {
    loaded_lib_count = 0;
    next_lib_va = lib_heap_base;
}

test "ld: #2099 — a well-formed staged library loads and resolves" {
    reset_lib_state();
    seed_lib_image();
    next_lib_va = @intFromPtr(&test_lib_image);
    const lib = load_shared_library("T.SO").?;
    try std.testing.expectEqual(@as(u64, @intFromPtr(&test_lib_image)), lib.base_va);
    try std.testing.expectEqual(@as(usize, 2), lib.sym_count);
    try std.testing.expectEqual(@as(?u64, @intFromPtr(&test_lib_image) + 0x80), lookup_symbol_in_libs("testfn"));
    try std.testing.expectEqual(@as(?u64, null), lookup_symbol_in_libs("absent"));
    reset_lib_state();
}

test "ld: #2099 — malformed staged images are refused" {
    reset_lib_state();
    const img = &test_lib_image;
    // Wrong machine.
    seed_lib_image();
    next_lib_va = @intFromPtr(img);
    std.mem.writeInt(u16, img[18..20], 62, .little); // x86-64
    try std.testing.expectEqual(@as(?*LoadedLib, null), load_shared_library("T.SO"));
    try std.testing.expectEqual(@as(usize, 0), loaded_lib_count);
    // phnum past the bound.
    seed_lib_image();
    next_lib_va = @intFromPtr(img);
    std.mem.writeInt(u16, img[56..58], 0xffff, .little);
    try std.testing.expectEqual(@as(?*LoadedLib, null), load_shared_library("T.SO"));
    // PT_LOAD whose mapped span escapes the slot.
    seed_lib_image();
    next_lib_va = @intFromPtr(img);
    const ph0: *Elf64Phdr = @ptrCast(@alignCast(img[0x40..].ptr));
    ph0.p_vaddr = lib_slot_bytes - 0x100;
    ph0.p_memsz = 0x200;
    try std.testing.expectEqual(@as(?*LoadedLib, null), load_shared_library("T.SO"));
    // PT_DYNAMIC without a DT_NULL terminator.
    seed_lib_image();
    next_lib_va = @intFromPtr(img);
    const dyn: [*]Elf64Dyn = @ptrCast(@alignCast(img[0x200..].ptr));
    dyn[3] = .{ .d_tag = dt_strtab, .d_val = 0x300 };
    try std.testing.expectEqual(@as(?*LoadedLib, null), load_shared_library("T.SO"));
    // strsz running past the slot end.
    seed_lib_image();
    next_lib_va = @intFromPtr(img);
    dyn[1] = .{ .d_tag = dt_strsz, .d_val = lib_slot_bytes };
    try std.testing.expectEqual(@as(?*LoadedLib, null), load_shared_library("T.SO"));
    // A name longer than the slot's 32-byte field is refused before any
    // copy — no partial-name truncation.
    seed_lib_image();
    next_lib_va = @intFromPtr(img);
    try std.testing.expectEqual(@as(?*LoadedLib, null), load_shared_library("THIS_LIBRARY_NAME_IS_FAR_TOO_LONG.SO"));
    reset_lib_state();
}

test "ld: #2099 — the library heap cannot run past the aperture" {
    reset_lib_state();
    // Slot count == aperture slot count: with all slots consumed the bump
    // pointer sits exactly at lib_heap_end and a further load refuses
    // before touching memory.
    loaded_lib_count = lib_slot_count;
    try std.testing.expectEqual(@as(?*LoadedLib, null), load_shared_library("X.SO"));
    try std.testing.expectEqual(lib_heap_base + lib_slot_bytes * lib_slot_count, lib_heap_end);
    reset_lib_state();
}

test "ld: #2099 — relocations only write inside writable image windows" {
    var target: u64 = 0;
    var outside: u64 = 0;
    const base_va: u64 = 0x0040_0000;

    // Fabricate the image's phdr table: an RX window holding the dynamic
    // table + RELA, and an RW window holding `target`.
    var phdrs = [3]Elf64Phdr{
        .{ .p_type = pt_load, .p_flags = 5, .p_offset = 0, .p_vaddr = @intFromPtr(&rela_fixture_buf), .p_paddr = 0, .p_filesz = 0x200, .p_memsz = 0x200, .p_align = 0x1000 },
        .{ .p_type = pt_load, .p_flags = 6, .p_offset = 0, .p_vaddr = @intFromPtr(&target), .p_paddr = 0, .p_filesz = 8, .p_memsz = 8, .p_align = 8 },
        .{ .p_type = pt_dynamic, .p_flags = 6, .p_offset = 0, .p_vaddr = @intFromPtr(&dyn_fixture_buf), .p_paddr = 0, .p_filesz = 3 * @sizeOf(Elf64Dyn), .p_memsz = 0, .p_align = 8 },
    };
    // RX window must cover BOTH the dyn table and the rela table.
    phdrs[0].p_vaddr = @min(@intFromPtr(&rela_fixture_buf), @intFromPtr(&dyn_fixture_buf));
    phdrs[0].p_memsz = @max(@intFromPtr(&rela_fixture_buf), @intFromPtr(&dyn_fixture_buf)) + 0x100 - phdrs[0].p_vaddr;

    const dyn: [*]Elf64Dyn = @ptrCast(&dyn_fixture_buf);
    dyn[0] = .{ .d_tag = dt_rela, .d_val = @intFromPtr(&rela_fixture_buf) };
    dyn[1] = .{ .d_tag = dt_relasz, .d_val = 2 * @sizeOf(Elf64Rela) };
    dyn[2] = .{ .d_tag = dt_null, .d_val = 0 };

    const rela: [*]Elf64Rela = @ptrCast(&rela_fixture_buf);
    // Legal: writable window.
    rela[0] = .{ .r_offset = @intFromPtr(&target), .r_info = @as(u64, r_aarch64_relative), .r_addend = 0x2000 };
    // Illegal: `outside` is inside no window — and `target`'s window is
    // the only writable one.
    rela[1] = .{ .r_offset = @intFromPtr(&outside), .r_info = @as(u64, r_aarch64_relative), .r_addend = 0x7fff };

    relocate_main(&phdrs[2], base_va, @intFromPtr(&phdrs), elf_phentsize, phdrs.len);

    try std.testing.expectEqual(base_va + 0x2000, target);
    try std.testing.expectEqual(@as(u64, 0), outside);
}

var rela_fixture_buf: [2 * @sizeOf(Elf64Rela)]u8 align(8) = @as([(2 * @sizeOf(Elf64Rela))]u8, @splat(@as(u8, 0)));
var dyn_fixture_buf: [4 * @sizeOf(Elf64Dyn)]u8 align(8) = @as([(4 * @sizeOf(Elf64Dyn))]u8, @splat(@as(u8, 0)));
