//! census (M188e, #3190): WASM.BIN — gate-referenced: live-wasm, live-wasm-abi, live-wasm-trap; also a build.zig host-test root.
//! The in-guest WASM core interpreter (M35 W1b, issue #762).
//!
//! Parses + validates + executes a bounded wasm-core subset:
//! i32/i64/f32/f64 (W4), block/loop/if/br/br_if/br_table/return/call/
//! call_indirect, one linear memory (2 MiB / 32 pages max — trap on
//! `memory.grow` beyond, NO unbounded mmap), one function table. Traps
//! are named with module + byte offset. Threads, atomics, SIMD, the 0xFC
//! 12+ table ops, and multi-memory stay OUT of subset (the 0xFC 0..11
//! trunc_sat + bulk-memory forms landed in W4).
//!
//! Import dispatch to ADR 0007 syscalls is W3 (`docs/wasm-import-
//! contract.md`); imported functions parse + validate, but calling one
//! traps `imported_unwired`. Imported tables/memories/globals are
//! rejected at validation (W3).
//!
//! Bounded like zc: one source file, fixed buffers, zero heap. Machine
//! state is a file-scope `Machine` (segmented DSK3 writable .data/.bss)
//! so the EL0 stack never carries it.

const std = @import("std");
// Contract v2 delivery admission (§9.2) verifies the manifest row's SHA-256
// against the module bytes. The in-tree hash is the same one lib/ssh uses.
const sha256 = @import("lib/crypto/sha256.zig");

// ---------------------------------------------------------------------------
// Bounds (the zc discipline: fixed arrays, no heap)
// ---------------------------------------------------------------------------
pub const max_types = 64; // func type section entries
pub const max_funcs = 64; // imported + defined functions
pub const max_params = 16;
pub const max_results = 2;
pub const max_globals = 64;
pub const max_imports = 32; // the frozen env.* surface (29) + headroom
pub const max_exports = 64;
pub const max_table = 256; // the single funcref table
pub const max_mem_pages = 32; // hard cap = 2 MiB (wasm-import-contract.md)
pub const max_locals = 64; // params + declared locals per function
pub const max_stack = 1024; // operand stack depth
pub const max_ctl = 64; // control stack depth
pub const max_frames = 32; // call depth
pub const max_datas = 64;
pub const max_elems = 64;

const page_size: usize = 64 * 1024;

// ---------------------------------------------------------------------------
// Value model
// ---------------------------------------------------------------------------
pub const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,

    pub fn fromByte(b: u8) ParseError!ValType {
        return switch (b) {
            0x7F => .i32,
            0x7E => .i64,
            0x7D => .f32,
            0x7C => .f64,
            else => error.UnknownValueType,
        };
    }
};

/// Machine value. The opcode selects which lane to read (validation
/// guarantees the type discipline; the exec arms pop/push by opcode).
pub const Value = extern union {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
};

pub const FuncType = struct {
    params: [max_params]ValType = undefined,
    results: [max_results]ValType = undefined,
    param_count: u8 = 0,
    result_count: u8 = 0,

    fn eql(a: FuncType, b: FuncType) bool {
        if (a.param_count != b.param_count or a.result_count != b.result_count) return false;
        for (0..a.param_count) |i| if (a.params[i] != b.params[i]) return false;
        for (0..a.result_count) |i| if (a.results[i] != b.results[i]) return false;
        return true;
    }
};

pub const ImportKind = enum(u8) { func = 0, table = 1, memory = 2, global = 3 };
pub const ExportKind = enum(u8) { func = 0, table = 1, memory = 2, global = 3 };

pub const Import = struct {
    module: []const u8,
    name: []const u8,
    kind: ImportKind,
    type_index: u32 = 0, // func only
};

pub const Global = struct {
    val_type: ValType,
    mutable: bool,
    init: Value, // i32/i64/f32/f64.const (subset init exprs)
};

pub const Export = struct {
    name: []const u8,
    kind: ExportKind,
    index: u32,
};

/// The frozen env.* surface — docs/wasm-import-contract.md §5 plus the W2
/// debug pair (write/exit, contract §7). Validation rejects anything else:
/// unknown name, foreign module, or a known name with a non-contract
/// signature all fail BEFORE start (contract §1 "Unknown imports →
/// validation failure"). This table is the single source of truth shared by
/// the validator and the dispatch arms' shape checks.
const Frozen = struct {
    name: []const u8,
    pc: u8,
    params: [6]ValType,
    rc: u8,
    cap: Cap,
};

// ---------------------------------------------------------------------------
// Contract v2 — declared capabilities (docs/wasm-import-contract.md §9)
// ---------------------------------------------------------------------------
/// The capability a frozen import belongs to. A module carrying a
/// `virelai.abi` custom section (contract v2) must declare every capability
/// whose imports it uses; validation fails closed with `UndeclaredCapability`
/// otherwise. A module with NO such section is contract v1: the gate does not
/// apply, which is what keeps v2 strictly additive — every M35 fixture and
/// every already-authored module loads exactly as before.
pub const Cap = enum(u8) {
    debug,
    file,
    window,
    audio,
    timer,
    memory,
    process,

    /// The wire spelling in the `capabilities=` / `caps=` directives.
    pub fn name(c: Cap) []const u8 {
        return switch (c) {
            .debug => "debug",
            .file => "file",
            .window => "window",
            .audio => "audio",
            .timer => "timer",
            .memory => "memory",
            .process => "process",
        };
    }

    pub fn parse(s: []const u8) ?Cap {
        inline for (std.meta.tags(Cap)) |cap| {
            if (std.mem.eql(u8, s, @tagName(cap))) return cap;
        }
        return null;
    }
};

/// A declared capability set: one bit per capability, fixed width, no heap.
pub const Caps = packed struct(u8) {
    debug: bool = false,
    file: bool = false,
    window: bool = false,
    audio: bool = false,
    timer: bool = false,
    memory: bool = false,
    process: bool = false,
    _reserved: u1 = 0,

    pub fn has(c: Caps, cap: Cap) bool {
        return switch (cap) {
            .debug => c.debug,
            .file => c.file,
            .window => c.window,
            .audio => c.audio,
            .timer => c.timer,
            .memory => c.memory,
            .process => c.process,
        };
    }

    pub fn set(c: *Caps, cap: Cap) void {
        switch (cap) {
            .debug => c.debug = true,
            .file => c.file = true,
            .window => c.window = true,
            .audio => c.audio = true,
            .timer => c.timer = true,
            .memory => c.memory = true,
            .process => c.process = true,
        }
    }
};
const frozen_imports = [_]Frozen{
    // W2 debug pair (contract §7: env.write / env.exit shim)
    .{ .name = "write", .pc = 3, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .debug },
    .{ .name = "exit", .pc = 1, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 0, .cap = .debug },
    // §5.1 file — slots 23–27 + 34–37
    .{ .name = "file_open", .pc = 3, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .file },
    .{ .name = "file_read", .pc = 3, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .file },
    .{ .name = "file_write", .pc = 3, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .file },
    .{ .name = "file_close", .pc = 1, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .file },
    .{ .name = "dir_list", .pc = 4, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .file },
    .{ .name = "file_delete", .pc = 2, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .file },
    .{ .name = "file_rename", .pc = 4, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .file },
    .{ .name = "file_truncate", .pc = 2, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .file },
    .{ .name = "file_free", .pc = 1, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .file },
    // §5.2 window — slots 12–20
    .{ .name = "win_open", .pc = 4, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .window },
    .{ .name = "win_fill", .pc = 6, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .window },
    .{ .name = "win_present", .pc = 1, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .window },
    .{ .name = "win_close", .pc = 1, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .window },
    .{ .name = "win_move", .pc = 3, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .window },
    .{ .name = "win_raise", .pc = 1, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .window },
    .{ .name = "win_get", .pc = 2, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .window },
    .{ .name = "win_query", .pc = 2, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .window },
    .{ .name = "win_set_visible", .pc = 2, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .window },
    // §5.3 audio — slots 42–45
    .{ .name = "audio_info", .pc = 1, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .audio },
    .{ .name = "audio_play", .pc = 2, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .audio },
    .{ .name = "audio_volume", .pc = 1, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .audio },
    .{ .name = "audio_mute", .pc = 1, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .audio },
    // §5.4 timers — slots 40/41
    .{ .name = "timer_set", .pc = 1, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .timer },
    .{ .name = "timer_cancel", .pc = 0, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .timer },
    // §5.5 mmap — slot 63 over the wasm arena (munmap 64, same row)
    .{ .name = "mmap", .pc = 4, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .memory },
    .{ .name = "munmap", .pc = 2, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .memory },
    // §5.6/5.7 processes + wait
    .{ .name = "procs", .pc = 2, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .process },
    .{ .name = "wait", .pc = 1, .params = .{ .i32, .i32, .i32, .i32, .i32, .i32 }, .rc = 1, .cap = .process },
};

fn checkFrozenImport(m: *const Module, imp: *const Import) ValidationError!void {
    if (!std.mem.eql(u8, imp.module, "env")) return error.UnknownImportModule;
    for (frozen_imports) |f| {
        if (std.mem.eql(u8, imp.name, f.name)) {
            const ft = &m.types[imp.type_index];
            if (ft.param_count != f.pc or ft.result_count != f.rc) return error.ImportSignature;
            for (0..f.pc) |i| {
                if (ft.params[i] != f.params[i]) return error.ImportSignature;
            }
            // Review fix (claim 3456): the result TYPE is part of the frozen
            // signature too. Without this, a module declaring e.g.
            // `env.win_open -> i64` validates, but the dispatch arm pushes an
            // i32-lane Value the body reads through the i64 lane (stale
            // stack in the high bits) — contract §5 signatures are exact.
            if (f.rc == 1 and ft.results[0] != .i32) return error.ImportSignature;
            // Contract v2 (§9): a module that declares its ABI revision must
            // also declare the capability this import belongs to. A v1 module
            // (no `virelai.abi` section) is exempt — that is the additive rule.
            if (m.abi_declared and !m.caps.has(f.cap)) return error.UndeclaredCapability;
            return;
        }
    }
    return error.UnknownImport;
}

/// Contract v2 custom-section name and the revision this loader implements.
pub const abi_section_name = "virelai.abi";
pub const abi_current_revision: u8 = 2;

/// Contract v2 `virelai.abi` custom section (§9): ASCII, one directive per
/// line, `#` comments and blank lines ignored.
///
///     virelai.abi=2
///     capabilities=file,window,timer
///
/// `virelai.abi=<n>` is required and must be 1 or 2 — a higher revision is
/// `UnsupportedAbiRevision` (fail closed: an unknown revision may mean
/// imports this loader would mis-dispatch). `capabilities=` is optional, and
/// OMITTING it is how a module declares "no capabilities"; each listed name
/// must be a §9 capability spelling. Anything else in the payload, a
/// duplicate directive, or a second `virelai.abi` section is `BadAbiSection`.
fn parseAbiSection(m: *Module, r: *Reader) ParseError!void {
    if (m.abi_declared) return error.BadAbiSection; // duplicate section
    var declared: Caps = .{};
    var revision: ?u8 = null;
    var lines = std.mem.splitScalar(u8, r.bytes[r.pos..], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "virelai.abi=")) {
            if (revision != null) return error.BadAbiSection; // duplicate directive
            const v = line["virelai.abi=".len..];
            if (v.len == 0 or v.len > 3) return error.BadAbiSection;
            revision = std.fmt.parseUnsigned(u8, v, 10) catch return error.BadAbiSection;
            continue;
        }
        if (std.mem.startsWith(u8, line, "capabilities=")) {
            const list = line["capabilities=".len..];
            if (list.len == 0) return error.BadAbiSection; // omit the line instead
            var names = std.mem.splitScalar(u8, list, ',');
            while (names.next()) |n| {
                const cap = Cap.parse(n) orelse return error.BadAbiSection;
                declared.set(cap);
            }
            continue;
        }
        return error.BadAbiSection; // unknown directive
    }
    const rev = revision orelse return error.BadAbiSection; // revision is required
    if (rev < 1) return error.BadAbiSection;
    if (rev > abi_current_revision) return error.UnsupportedAbiRevision;
    m.abi_declared = true;
    m.abi_revision = rev;
    m.caps = declared;
}

/// The capabilities a module's imports actually exercise: the union of the
/// `cap` field of every frozen import it declares. The manifest admission
/// check (and its host tests) compare this against the row's granted set.
pub fn usedCaps(m: *const Module) Caps {
    var used: Caps = .{};
    for (m.imports[0..m.import_count]) |imp| {
        if (imp.kind != .func) continue;
        for (frozen_imports) |f| {
            if (std.mem.eql(u8, imp.name, f.name)) used.set(f.cap);
        }
    }
    return used;
}

// ---------------------------------------------------------------------------
// Contract v2 — host-share delivery manifest (§9.2)
// ---------------------------------------------------------------------------
/// The manifest the guest reads. Its FORMAT is normative in
/// docs/wasm-import-contract.md §9.2, not here; the tool in tools/ writes it.
pub const manifest_path = "/host/WASM.TXT";

/// One row: `NAME.WASM | <bytes> | <64 hex chars> | abi=<n> | caps=<a,b,c>`
/// (`caps=none` for the empty set). Blank lines and `#` comments are ignored.
pub const ManifestRow = struct {
    name: []const u8,
    bytes: u64,
    digest: [32]u8,
    abi: u8,
    caps: Caps,

    /// Strict, and deliberately so: a row that does not parse returns null,
    /// and the caller refuses the module. A malformed row is
    /// indistinguishable from a missing one — nothing about a delivery is
    /// guessed at.
    pub fn parse(line: []const u8) ?ManifestRow {
        var fields = std.mem.splitScalar(u8, line, '|');
        const name = std.mem.trim(u8, fields.next() orelse return null, " \t");
        const size_s = std.mem.trim(u8, fields.next() orelse return null, " \t");
        const digest_s = std.mem.trim(u8, fields.next() orelse return null, " \t");
        const abi_s = std.mem.trim(u8, fields.next() orelse return null, " \t");
        const caps_s = std.mem.trim(u8, fields.next() orelse return null, " \t");
        if (fields.next() != null) return null; // exactly five fields
        if (name.len == 0 or name.len > 64) return null;
        const size = std.fmt.parseUnsigned(u64, size_s, 10) catch return null;
        if (digest_s.len != 64) return null;
        var digest: [32]u8 = undefined;
        for (0..32) |i| {
            digest[i] = std.fmt.parseUnsigned(u8, digest_s[i * 2 .. i * 2 + 2], 16) catch return null;
        }
        if (!std.mem.startsWith(u8, abi_s, "abi=")) return null;
        const abi = std.fmt.parseUnsigned(u8, abi_s["abi=".len..], 10) catch return null;
        if (abi == 0 or abi > abi_current_revision) return null;
        if (!std.mem.startsWith(u8, caps_s, "caps=")) return null;
        const list = caps_s["caps=".len..];
        var caps: Caps = .{};
        if (!std.mem.eql(u8, list, "none")) {
            if (list.len == 0) return null;
            var names = std.mem.splitScalar(u8, list, ',');
            while (names.next()) |nm| {
                const cap = Cap.parse(nm) orelse return null;
                caps.set(cap);
            }
        }
        return .{ .name = name, .bytes = size, .digest = digest, .abi = abi, .caps = caps };
    }
};

pub const AdmitFailure = enum {
    ok,
    no_row, // the module is v2 but the share does not vouch for it
    size, // byte length differs from the row
    digest, // SHA-256 differs from the row
    revision, // declared ABI revision differs from the row
    capability, // the module uses a capability the row does not grant
};

/// The §9.2 admission decision — pure, so the host tests and the guest run
/// the identical rule. `used` is `usedCaps(module)`; `digest` is SHA-256 over
/// the module bytes. A row may grant MORE than the module uses (an operator
/// may pre-provision a module's next revision); it may never grant less.
pub fn admit(row: ?ManifestRow, size: u64, digest: [32]u8, abi: u8, used: Caps) AdmitFailure {
    const r = row orelse return .no_row;
    if (r.bytes != size) return .size;
    if (!std.mem.eql(u8, &r.digest, &digest)) return .digest;
    if (r.abi != abi) return .revision;
    inline for (std.meta.tags(Cap)) |cap| {
        if (used.has(cap) and !r.caps.has(cap)) return .capability;
    }
    return .ok;
}

/// ASCII case-insensitive row-name match: the share is 8.3-uppercase by
/// convention while the exec name is whatever the user typed.
fn manifestNameMatches(row_name: []const u8, name: []const u8) bool {
    if (row_name.len != name.len) return false;
    for (row_name, name) |a, b| {
        if (std.ascii.toUpper(a) != std.ascii.toUpper(b)) return false;
    }
    return true;
}

var g_manifest_buf: [4096]u8 = undefined;

/// Read `manifest_path` and return the row for `name`, or null — a missing
/// file, no matching row, and an unparseable row are the same refusal.
fn findManifestRow(name: []const u8) ?ManifestRow {
    const fd = file_open(manifest_path, MODE_READ);
    if (fd < 0) return null;
    var len: usize = 0;
    while (len < g_manifest_buf.len) {
        const r = file_read(@intCast(fd), g_manifest_buf[len..]);
        if (r <= 0) break;
        len += @intCast(r);
    }
    _ = file_close(@intCast(fd));
    var lines = std.mem.splitScalar(u8, g_manifest_buf[0..len], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const row = ManifestRow.parse(line) orelse continue;
        if (manifestNameMatches(row.name, name)) return row;
    }
    return null;
}

/// Active element segment (flag 0x00 form only; table 0).
pub const Element = struct {
    offset: u32,
    funcs: [max_table]u32 = undefined,
    count: u32 = 0,
    abs_off: usize = 0,
};

/// Data segment: active (flags 0/2 — applied at instantiate) or passive
/// (flag 1 — consumed at runtime by `memory.init` until `data.drop`).
pub const Data = struct {
    offset: u32,
    bytes: []const u8 = &.{},
    abs_off: usize = 0,
    passive: bool = false,
};

pub const Func = struct {
    type_index: u32,
    body: []const u8 = &.{}, // code bytes after the locals declaration
    local_types: [max_locals]ValType = undefined,
    local_count: u8 = 0,
    abs_off: usize = 0, // module byte offset of the body's first instruction
};

pub const Module = struct {
    types: [max_types]FuncType = undefined,
    type_count: u16 = 0,
    funcs: [max_funcs]Func = undefined,
    func_count: u16 = 0,
    imported_funcs: u16 = 0, // front of funcs[] are imports
    globals: [max_globals]Global = undefined,
    global_count: u16 = 0,
    imports: [max_imports]Import = undefined,
    import_count: u16 = 0,
    exports: [max_exports]Export = undefined,
    export_count: u16 = 0,
    tables: [1]struct { min: u32, max: ?u32 } = undefined,
    table_count: u8 = 0,
    has_memory: bool = false,
    mem_min_pages: u32 = 0,
    mem_max_pages: ?u32 = null,
    start: ?u32 = null,
    elements: [max_elems]Element = undefined,
    element_count: u16 = 0,
    datas: [max_datas]Data = undefined,
    data_count: u16 = 0,
    has_datacount: bool = false, // DataCount section (id 12) present
    data_count_decl: u16 = 0, // value from that section (memory.init index cap)
    /// Contract v2 state from the optional `virelai.abi` custom section (§9).
    /// `abi_declared == false` is a v1 module: the capability gate is skipped.
    abi_declared: bool = false,
    abi_revision: u8 = 1, // 1 = undeclared (legacy), else the declared revision
    caps: Caps = .{},
};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------
pub const ParseError = error{
    BadMagic,
    BadVersion,
    Truncated,
    MalformedLeb,
    UnknownSection,
    DuplicateSection,
    SectionOutOfOrder,
    DataCountMismatch, // DataCount section count != actual data-section count
    UnknownValueType,
    UnknownImportKind,
    UnknownExportKind,
    BadElementKind,
    TooManyEntries,
    TooManyParams,
    TooManyResults,
    TooManyLocals,
    CodeCountMismatch,
    TrailingBytes, // non-empty bytes after a section payload
    BadAbiSection, // `virelai.abi` payload malformed, duplicate, or unknown directive
    UnsupportedAbiRevision, // `virelai.abi=<n>` names a revision past contract v2
};

pub const ValidationError = ParseError || error{
    BulkMemoryOutOfSubset, // 0xFC subopcodes 12+ (table.* + future: not in subset)
    DataCountMissing, // memory.init/data.drop without a DataCount section
    UnknownType,
    UnknownFunc,
    UnknownGlobal,
    UnknownLocal,
    UnknownLabel,
    UnknownExport,
    TypeMismatch,
    MemoryRequired,
    TableRequired,
    BadAlign,
    UnbalancedControl,
    UnterminatedBody,
    StartNotVoid,
    DuplicateExport,
    IndexOutOfRange,
    LimitsInvalid,
    MemoryTooBig, // declared max pages > 32
    TableTooBig, // declared max > 256 entries
    UnsupportedImport, // imported table/memory/global (W3)
    UnknownImportModule, // import module != "env" (W3: WASI etc. always rejected)
    UnknownImport, // import name not in the frozen env.* surface (W3)
    ImportSignature, // frozen name with a non-contract param/result shape (W3)
    UndeclaredCapability, // v2 module used an import whose capability it did not declare (§9)
    MultiValueBlock, // blocktype with a type index (multi-value)
    StackOverflow,
};

pub const TrapKind = enum {
    @"unreachable", // the wasm `unreachable` instruction (keyword-escaped)
    bounds, // memory/table/index out of bounds
    call_indirect_type,
    div_by_zero, // integer div/rem only — wasm float div yields +/-inf, never traps
    invalid_conv, // 0xAA..0xB1 plain trunc*: NaN or out-of-range (W4)
    grow_limit,
    call_depth,
    stack_overflow,
    imported_unwired, // calling an imported func before W3 dispatch
    guest_exit, // host-test only: env.exit captured (the guest path is a real sys_exit)
};

pub const Trap = struct {
    kind: TrapKind,
    module: []const u8,
    offset: usize, // module byte offset of the faulting instruction
};

// ---------------------------------------------------------------------------
// Reader (wasm is little-endian LEB128)
// ---------------------------------------------------------------------------
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    base: usize = 0, // absolute module offset of bytes[0]

    fn take(r: *Reader, n: usize) ParseError![]const u8 {
        if (r.pos + n > r.bytes.len) return error.Truncated;
        const s = r.bytes[r.pos .. r.pos + n];
        r.pos += n;
        return s;
    }

    fn u8_(r: *Reader) ParseError!u8 {
        return (try r.take(1))[0];
    }

    fn absPos(r: *const Reader) usize {
        return r.base + r.pos;
    }

    /// Unsigned LEB128 u32 (max 5 bytes; >32 bits rejected).
    fn uleb(r: *Reader) ParseError!u32 {
        var result: u32 = 0;
        var shift: u5 = 0; // u32 shift counts must fit 5 bits (zig 0.17)
        var count: u8 = 0;
        while (true) : (count += 1) {
            if (count >= 5) return error.MalformedLeb;
            const b = try r.u8_();
            if (count == 4 and (b & 0x80) != 0) return error.MalformedLeb;
            const low: u32 = b & 0x7F;
            if (count == 4 and (low & 0xF0) != 0) return error.MalformedLeb;
            result |= low << shift;
            if (b & 0x80 == 0) return result;
            shift += 7;
        }
    }

    /// Signed LEB128 i64 (i32.const reads this then truncates). At most 10
    /// bytes: the 10th byte carries bit 63, so a continuation bit there is
    /// malformed. (`shift` must be wider than u6: 63 + 7 wraps, which
    /// panicked safe builds, decoded canonical 10-byte negative constants
    /// as -64 in release builds, and made the old guard unreachable —
    /// issue #1519.)
    fn sleb(r: *Reader) ParseError!i64 {
        var result: i64 = 0;
        var shift: usize = 0;
        var b: u8 = 0;
        var count: u8 = 0;
        while (true) {
            b = try r.u8_();
            result |= @as(i64, @intCast(b & 0x7F)) << @intCast(shift);
            count += 1;
            shift += 7;
            if (b & 0x80 == 0) break;
            if (count >= 10) return error.MalformedLeb;
        }
        if (shift < 64 and (b & 0x40) != 0) {
            // -%: at shift 63 the operand is i64 min, whose unary minus
            // overflows in safe builds (the OR mask is identical).
            result |= -%(@as(i64, 1) << @intCast(shift));
        }
        return result;
    }

    fn name(r: *Reader) ParseError![]const u8 {
        const len = try r.uleb();
        return r.take(len);
    }
};

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------
/// Parse into a caller-provided Module (W2: the guest `_start` parses into
/// the file-scope global — the EL0 stack is only 32 KiB and a by-value
/// 77 KiB Module would smash it). `parse` stays as the by-value host API.
pub fn parseInto(m: *Module, bytes: []const u8) ParseError!void {
    m.* = Module{};
    var r = Reader{ .bytes = bytes };

    const magic = try r.take(4);
    if (!std.mem.eql(u8, magic, "\x00asm")) return error.BadMagic;
    const ver = try r.take(4);
    if (!std.mem.eql(u8, ver, "\x01\x00\x00\x00")) return error.BadVersion;

    var seen = @as([13]bool, @splat(@as(bool, false))); // ids 0..12 (DataCount is legal, id 12)
    var prev_id: u8 = 0;
    while (r.pos < r.bytes.len) {
        const id = try r.u8_();
        if (id == 0) { // custom section: parse `virelai.abi` (§9), skip the rest
            const csize = try r.uleb();
            const payload_pos = r.pos;
            const payload = try r.take(csize);
            var cr = Reader{ .bytes = payload, .base = payload_pos };
            // A custom section whose NAME is unreadable is still skipped, as
            // before — only the section we own fails the module.
            const cname = cr.name() catch continue;
            if (std.mem.eql(u8, cname, abi_section_name)) try parseAbiSection(m, &cr);
            continue;
        }
        if (id > 12) return error.UnknownSection;
        if (seen[id]) return error.DuplicateSection;
        if (id == 12) {
            // DataCount (bulk-memory proposal) sits BETWEEN the element
            // section (9) and the code section (10) positionally — its id
            // is numerically largest, so the monotonic check cannot rank
            // it. Spec order: element, datacount, code, data.
            if (seen[10] or seen[11]) return error.SectionOutOfOrder;
            seen[id] = true;
            prev_id = 9; // rank it just past element; code (10) follows
        } else {
            if (id < prev_id) return error.SectionOutOfOrder;
            seen[id] = true;
            prev_id = id;
        }
        const size = try r.uleb();
        const payload_pos = r.pos;
        const payload = try r.take(size);
        var pr = Reader{ .bytes = payload, .base = payload_pos };
        try parseSection(m, &pr, id);
        if (pr.pos != pr.bytes.len) return error.TrailingBytes;
    }
    if (m.has_datacount and m.data_count_decl != m.data_count) return error.DataCountMismatch;
}

pub fn parse(bytes: []const u8) ParseError!Module {
    var m = Module{};
    try parseInto(&m, bytes);
    return m;
}

fn parseSection(m: *Module, r: *Reader, id: u8) ParseError!void {
    switch (id) {
        1 => { // type
            const n = try r.uleb();
            for (0..n) |_| try parseFuncType(m, r);
        },
        2 => { // import
            const n = try r.uleb();
            for (0..n) |_| try parseImport(m, r);
        },
        3 => { // function
            const n = try r.uleb();
            if (m.func_count + n > max_funcs) return error.TooManyEntries;
            for (0..n) |_| {
                m.funcs[m.func_count] = .{ .type_index = try r.uleb() };
                m.func_count += 1;
            }
        },
        4 => { // table
            const n = try r.uleb();
            if (m.table_count + n > 1) return error.TooManyEntries;
            for (0..n) |_| {
                const elem = try r.u8_();
                if (elem != 0x70) return error.UnknownValueType; // funcref
                const lim = try parseLimit(r);
                m.tables[m.table_count] = .{ .min = lim.min, .max = lim.max };
                m.table_count += 1;
            }
        },
        5 => { // memory
            const n = try r.uleb();
            if (m.has_memory or n != 1) return error.TooManyEntries;
            m.has_memory = true;
            const lim = try parseLimit(r);
            m.mem_min_pages = lim.min;
            m.mem_max_pages = lim.max;
        },
        6 => { // global
            const n = try r.uleb();
            for (0..n) |_| try parseGlobal(m, r);
        },
        7 => { // export
            const n = try r.uleb();
            for (0..n) |_| {
                const name = try r.name();
                const kb = try r.u8_();
                const kind: ExportKind = switch (kb) {
                    0 => .func,
                    1 => .table,
                    2 => .memory,
                    3 => .global,
                    else => {
                        return error.UnknownExportKind;
                    },
                };
                if (m.export_count >= max_exports) return error.TooManyEntries;
                m.exports[m.export_count] = .{ .name = name, .kind = kind, .index = try r.uleb() };
                m.export_count += 1;
            }
        },
        8 => { // start
            m.start = try r.uleb();
        },
        9 => { // element
            const n = try r.uleb();
            for (0..n) |_| {
                const seg_abs = r.absPos();
                const flags = try r.u8_();
                if (flags == 0x02) {
                    // active segment with explicit table index
                    const tidx = try r.uleb();
                    if (tidx != 0) return error.BadElementKind; // single table only
                } else if (flags != 0x00) {
                    // 0x00 = active, table 0 implicit (no index byte).
                    // 1/3/4/5/6/7 = passive/declarative/expr: out of subset
                    return error.BadElementKind;
                }
                const init = try parseConstExpr(r);
                const cnt = try r.uleb();
                if (cnt > max_table) return error.TooManyEntries;
                if (m.element_count >= max_elems) return error.TooManyEntries;
                var el = Element{ .offset = @bitCast(init.i32), .count = cnt, .abs_off = seg_abs };
                for (0..cnt) |i| el.funcs[i] = try r.uleb();
                m.elements[m.element_count] = el;
                m.element_count += 1;
            }
        },
        10 => { // code
            const n = try r.uleb();
            // The code section counts DEFINED funcs only; imports live at
            // the front of funcs[] and have no bodies (the hello-env W2
            // fixture first tripped this).
            if (n != m.func_count - m.imported_funcs) return error.CodeCountMismatch;
            for (0..n) |i| try parseCode(m, r, i + m.imported_funcs); // imports hold funcs[0..imported_funcs)
        },
        11 => { // data (active flags 0/2 + passive flag 1; W4 bulk-memory)
            const n = try r.uleb();
            for (0..n) |_| {
                const seg_abs = r.absPos();
                const flags = try r.u8_();
                if (flags == 0x00) {
                    const init = try parseConstExpr(r);
                    const len = try r.uleb();
                    if (m.data_count >= max_datas) return error.TooManyEntries;
                    m.datas[m.data_count] = .{
                        .offset = @bitCast(init.i32),
                        .bytes = try r.take(len),
                        .abs_off = seg_abs,
                        .passive = false,
                    };
                    m.data_count += 1;
                } else if (flags == 0x01) { // passive: no offset expr
                    const len = try r.uleb();
                    if (m.data_count >= max_datas) return error.TooManyEntries;
                    m.datas[m.data_count] = .{
                        .offset = 0,
                        .bytes = try r.take(len),
                        .abs_off = seg_abs,
                        .passive = true,
                    };
                    m.data_count += 1;
                } else if (flags == 0x02) {
                    // active segment with explicit memory index
                    const midx = try r.uleb();
                    if (midx != 0) return error.BadElementKind; // single memory only
                    const init = try parseConstExpr(r);
                    const len = try r.uleb();
                    if (m.data_count >= max_datas) return error.TooManyEntries;
                    m.datas[m.data_count] = .{
                        .offset = @bitCast(init.i32),
                        .bytes = try r.take(len),
                        .abs_off = seg_abs,
                        .passive = false,
                    };
                    m.data_count += 1;
                } else {
                    // 3/4/5/6/7 = declarative/expr forms: out of subset
                    return error.BadElementKind;
                }
            }
        },
        12 => { // DataCount: u32 count, must match the data section (checked in parseInto)
            m.has_datacount = true;
            const c = try r.uleb();
            if (c > max_datas) return error.TooManyEntries;
            m.data_count_decl = @intCast(c);
        },
        else => unreachable,
    }
}

fn parseLimit(r: *Reader) ParseError!struct { min: u32, max: ?u32 } {
    const flag = try r.u8_();
    if (flag == 0) return .{ .min = try r.uleb(), .max = null };
    if (flag == 1) return .{ .min = try r.uleb(), .max = try r.uleb() };
    return error.UnknownValueType;
}

fn parseFuncType(m: *Module, r: *Reader) ParseError!void {
    if (m.type_count >= max_types) return error.TooManyEntries;
    const tag = try r.u8_();
    if (tag != 0x60) return error.UnknownValueType;
    var ft = FuncType{};
    const np = try r.uleb();
    if (np > max_params) return error.TooManyParams;
    ft.param_count = @intCast(np);
    for (0..np) |i| ft.params[i] = try ValType.fromByte(try r.u8_());
    const nr = try r.uleb();
    if (nr > max_results) return error.TooManyResults;
    ft.result_count = @intCast(nr);
    for (0..nr) |i| ft.results[i] = try ValType.fromByte(try r.u8_());
    m.types[m.type_count] = ft;
    m.type_count += 1;
}

fn parseImport(m: *Module, r: *Reader) ParseError!void {
    if (m.import_count >= max_imports) return error.TooManyEntries;
    const module = try r.name();
    const name = try r.name();
    const kb = try r.u8_();
    const kind: ImportKind = switch (kb) {
        0 => .func,
        1 => .table,
        2 => .memory,
        3 => .global,
        else => {
            return error.UnknownImportKind;
        },
    };
    var imp = Import{ .module = module, .name = name, .kind = kind };
    switch (kind) {
        .func => {
            const ti = try r.uleb();
            imp.type_index = ti;
            if (m.func_count >= max_funcs) return error.TooManyEntries;
            m.funcs[m.func_count] = .{ .type_index = ti };
            m.func_count += 1;
            m.imported_funcs += 1;
        },
        .table => {
            const elem = try r.u8_();
            if (elem != 0x70) return error.UnknownValueType;
            _ = try parseLimit(r);
        },
        .memory => {
            _ = try parseLimit(r);
        },
        .global => {
            _ = try ValType.fromByte(try r.u8_());
            _ = try r.u8_(); // mutability
        },
    }
    m.imports[m.import_count] = imp;
    m.import_count += 1;
}

fn parseGlobal(m: *Module, r: *Reader) ParseError!void {
    if (m.global_count >= max_globals) return error.TooManyEntries;
    const vt = try ValType.fromByte(try r.u8_());
    const mut = try r.u8_();
    if (mut > 1) return error.UnknownValueType;
    m.globals[m.global_count] = .{ .val_type = vt, .mutable = mut == 1, .init = try parseConstExpr(r) };
    m.global_count += 1;
}

/// Subset init expr: i32.const / i64.const followed by `end`.
fn parseConstExpr(r: *Reader) ParseError!Value {
    const op = try r.u8_();
    var v: Value = .{ .i64 = 0 };
    switch (op) {
        0x41 => v = .{ .i32 = @truncate(try r.sleb()) },
        0x42 => v = .{ .i64 = try r.sleb() },
        0x43 => v = .{ .f32 = @bitCast(readInt(u32, (try r.take(4))[0..4])) },
        0x44 => v = .{ .f64 = @bitCast(readInt(u64, (try r.take(8))[0..8])) },
        else => {
            return error.UnknownValueType;
        },
    }
    if ((try r.u8_()) != 0x0B) return error.UnknownValueType;
    return v;
}

/// Blocktype byte: 0x40 (empty) or one valtype (single result).
/// Multi-value block types (s33) are out of subset.
fn parseBlockType(r: *Reader) (ParseError || ValidationError)!?ValType {
    const b = try r.u8_();
    if (b == 0x40) return null;
    return ValType.fromByte(b) catch return error.MultiValueBlock;
}

fn parseCode(m: *Module, r: *Reader, func_i: usize) ParseError!void {
    const body_size = try r.uleb();
    const size_pos = r.pos;
    const ft = &m.types[m.funcs[func_i].type_index];

    // locals declaration: vec of (count, valtype) groups
    var local_types: [max_locals]ValType = undefined;
    var local_count: u8 = 0;
    for (0..ft.param_count) |i| {
        local_types[local_count] = ft.params[i];
        local_count += 1;
    }
    const groups = try r.uleb();
    for (0..groups) |_| {
        const cnt = try r.uleb();
        const vt = try ValType.fromByte(try r.u8_());
        if (local_count + cnt > max_locals) return error.TooManyLocals;
        for (0..cnt) |_| {
            local_types[local_count] = vt;
            local_count += 1;
        }
    }
    // absPos, not pos: the trap offset printed on the serial is a MODULE
    // byte offset, and `r` reads a code-section payload slice (M70d #1518).
    const body_start = r.absPos();
    const remain = body_size - (r.pos - size_pos);
    m.funcs[func_i].body = try r.take(remain);
    m.funcs[func_i].local_types = local_types;
    m.funcs[func_i].local_count = local_count;
    m.funcs[func_i].abs_off = body_start;
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------
const VStack = struct {
    items: [max_stack]ValType = undefined,
    len: usize = 0,
    polymorphic: bool = false, // unreachable: pops at frame height are unknown
};

const VCtl = struct {
    kind: enum { block, loop, if_, func },
    height: usize,
    blocktype: ?ValType = null, // null = 0x40 empty; else single result
    else_seen: bool = false,
};

fn vpush(vs: *VStack, t: ValType) ValidationError!void {
    if (vs.len >= max_stack) return error.StackOverflow;
    vs.items[vs.len] = t;
    vs.len += 1;
}

fn vpop(vs: *VStack, ctl: []const VCtl, want: ValType) ValidationError!void {
    if (vs.polymorphic and vs.len <= ctl[ctl.len - 1].height) return;
    if (vs.len == 0) return error.TypeMismatch;
    const got = vs.items[vs.len - 1];
    vs.len -= 1;
    if (got != want) return error.TypeMismatch;
}

fn vpopAny(vs: *VStack, ctl: []const VCtl) ValType {
    if (vs.polymorphic and vs.len <= ctl[ctl.len - 1].height) return .i32;
    if (vs.len == 0) return .i32;
    vs.len -= 1;
    return vs.items[vs.len];
}

fn vpopAll(vs: *VStack, ctl: []const VCtl, types: []const ValType) ValidationError!void {
    var i: usize = types.len;
    while (i > 0) {
        i -= 1;
        try vpop(vs, ctl, types[i]);
    }
}

/// Check the top of the stack matches `types`, leaving it unchanged.
fn vpeekMatch(vs: *VStack, ctl: []const VCtl, types: []const ValType) ValidationError!void {
    var saved: [max_results]ValType = undefined;
    var saved_len: usize = 0;
    var i: usize = types.len;
    while (i > 0) : (i -= 1) {
        saved[saved_len] = vpopAny(vs, ctl);
        saved_len += 1;
    }
    while (saved_len > 0) {
        saved_len -= 1;
        try vpush(vs, saved[saved_len]);
    }
}

fn labelAt(ctl: []const VCtl, depth: u32) ValidationError!*const VCtl {
    if (depth >= ctl.len) return error.UnknownLabel;
    return &ctl[ctl.len - 1 - depth];
}

pub fn validate(m: *Module) ValidationError!void {
    if (m.table_count > 0) {
        const t = m.tables[0];
        if (t.max) |mx| {
            if (mx < t.min) return error.LimitsInvalid;
            if (mx > max_table) return error.TableTooBig;
        }
        if (t.min > max_table) return error.TableTooBig;
    }
    if (m.has_memory) {
        const mx = m.mem_max_pages orelse m.mem_min_pages;
        if (mx < m.mem_min_pages) return error.LimitsInvalid;
        if (mx > max_mem_pages) return error.MemoryTooBig;
    }
    for (m.imports[0..m.import_count]) |imp| {
        switch (imp.kind) {
            .func => {
                if (imp.type_index >= m.type_count) return error.UnknownType;
                // W3: the import surface is the frozen env.* set and nothing
                // else — unknown name / foreign module / bad signature all
                // fail BEFORE start (contract §1).
                try checkFrozenImport(m, &imp);
            },
            .table, .memory, .global => {
                return error.UnsupportedImport;
            },
        }
    }
    for (m.funcs[0..m.func_count]) |f| {
        if (f.type_index >= m.type_count) return error.UnknownType;
    }
    if (m.start) |si| {
        if (si >= m.func_count) return error.UnknownFunc;
        const st = &m.types[m.funcs[si].type_index];
        if (st.param_count != 0 or st.result_count != 0) return error.StartNotVoid;
    }
    for (m.exports[0..m.export_count]) |e| {
        switch (e.kind) {
            .func => if (e.index >= m.func_count) return error.UnknownExport,
            .table => if (e.index >= m.table_count) return error.UnknownExport,
            .memory => if (!m.has_memory) return error.UnknownExport,
            .global => if (e.index >= m.global_count) return error.UnknownExport,
        }
    }
    for (0..m.export_count) |i| {
        for (i + 1..m.export_count) |j| {
            if (std.mem.eql(u8, m.exports[i].name, m.exports[j].name)) return error.DuplicateExport;
        }
    }
    for (m.elements[0..m.element_count]) |el| {
        for (0..el.count) |i| {
            if (el.funcs[i] >= m.func_count) return error.UnknownFunc;
        }
        if (m.table_count == 0) return error.TableRequired;
    }
    if (m.data_count > 0 and !m.has_memory) return error.MemoryRequired;

    for (0..m.func_count) |fi| {
        if (fi < m.imported_funcs) continue; // imports have no body
        try validateBody(m, fi);
    }
}

fn validateBody(m: *Module, fi: usize) ValidationError!void {
    var vs = VStack{};
    var ctl: [max_ctl]VCtl = undefined;
    var ctl_len: usize = 1;
    const f = &m.funcs[fi];
    const ft = &m.types[f.type_index];
    if (ft.result_count > 1) return error.MultiValueBlock;
    ctl[0] = .{ .kind = .func, .height = 0, .blocktype = if (ft.result_count == 1) ft.results[0] else null };

    var pc: usize = 0;
    while (pc < f.body.len) {
        var body = Reader{ .bytes = f.body, .pos = pc };
        pc = try validateOp(m, f, ft, &vs, &ctl, &ctl_len, &body);
    }
    // the final `end` consumed the frame; a non-polymorphic stack must be
    // empty (results were checked by the vpop in the `end` handler)
    if (ctl_len != 0) return error.UnterminatedBody;
    if (!vs.polymorphic and vs.len != 0) return error.TypeMismatch;
}

fn validateOp(
    m: *Module,
    f: *const Func,
    ft: *const FuncType,
    vs: *VStack,
    ctl: []VCtl,
    ctl_len: *usize,
    body: *Reader,
) ValidationError!usize {
    const op = try body.u8_();
    switch (op) {
        0x00 => { // unreachable
            vs.len = ctl[ctl_len.* - 1].height;
            vs.polymorphic = true;
        },
        0x01 => {},
        0x02, 0x03, 0x04 => { // block / loop / if
            const bt = try parseBlockType(body);
            if (ctl_len.* >= max_ctl) return error.StackOverflow;
            if (op == 0x04) {
                try vpop(vs, ctl[0..ctl_len.*], .i32);
            }
            ctl[ctl_len.*] = .{ .kind = if (op == 0x02) .block else if (op == 0x03) .loop else .if_, .height = vs.len, .blocktype = bt };
            ctl_len.* += 1;
        },
        0x05 => { // else
            const frame = &ctl[ctl_len.* - 1];
            if (frame.kind != .if_ or frame.else_seen) return error.UnbalancedControl;
            frame.else_seen = true;
            if (frame.blocktype) |bt| try vpop(vs, ctl[0..ctl_len.*], bt);
            vs.len = frame.height;
            vs.polymorphic = false;
        },
        0x0B => { // end
            if (ctl_len.* == 0) return error.UnbalancedControl;
            const frame = &ctl[ctl_len.* - 1];
            if (frame.kind == .if_ and !frame.else_seen and frame.blocktype != null) {
                return error.TypeMismatch; // if without else must be void
            }
            if (frame.blocktype) |bt| try vpop(vs, ctl[0..ctl_len.*], bt);
            vs.len = frame.height;
            vs.polymorphic = false;
            ctl_len.* -= 1;
            if (frame.kind != .func) {
                if (frame.blocktype) |bt| try vpush(vs, bt);
            }
        },
        0x0C => { // br
            const depth = try body.uleb();
            const target = try labelAt(ctl[0..ctl_len.*], depth);
            if (target.blocktype) |bt| try vpopAll(vs, ctl[0..ctl_len.*], &[_]ValType{bt});
            vs.len = ctl[ctl_len.* - 1].height;
            vs.polymorphic = true;
        },
        0x0D => { // br_if
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            const depth = try body.uleb();
            const target = try labelAt(ctl[0..ctl_len.*], depth);
            if (target.blocktype) |bt| try vpeekMatch(vs, ctl[0..ctl_len.*], &[_]ValType{bt});
        },
        0x0E => { // br_table
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            const n = try body.uleb();
            if (n > max_ctl) return error.UnknownLabel;
            var target_bt: ?ValType = null;
            for (0..n) |_| {
                const d = try body.uleb();
                target_bt = (try labelAt(ctl[0..ctl_len.*], d)).blocktype;
            }
            const dd = try body.uleb();
            const def = try labelAt(ctl[0..ctl_len.*], dd);
            if (target_bt) |bt| {
                if (def.blocktype != null and def.blocktype.? != bt) return error.TypeMismatch;
            }
            if (def.blocktype) |bt| try vpeekMatch(vs, ctl[0..ctl_len.*], &[_]ValType{bt});
        },
        0x0F => { // return
            if (ft.result_count == 1) try vpop(vs, ctl[0..ctl_len.*], ft.results[0]);
            vs.len = ctl[ctl_len.* - 1].height;
            vs.polymorphic = true;
        },
        0x10 => { // call
            const fi = try body.uleb();
            if (fi >= m.func_count) return error.UnknownFunc;
            const callee = &m.types[m.funcs[fi].type_index];
            try vpopAll(vs, ctl[0..ctl_len.*], callee.params[0..callee.param_count]);
            for (callee.results[0..callee.result_count]) |t| try vpush(vs, t);
        },
        0x11 => { // call_indirect
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            if (m.table_count == 0) return error.TableRequired;
            const ti = try body.uleb();
            _ = try body.uleb(); // tableidx — U32 LEB (wasm 2.0; wasm-ld emits legal overlong encodings)
            if (ti >= m.type_count) return error.UnknownType;
            const callee = &m.types[ti];
            try vpopAll(vs, ctl[0..ctl_len.*], callee.params[0..callee.param_count]);
            for (callee.results[0..callee.result_count]) |t| try vpush(vs, t);
        },
        0x1A => {
            _ = vpopAny(vs, ctl[0..ctl_len.*]);
        },
        0x1B => { // select
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            const t2 = vpopAny(vs, ctl[0..ctl_len.*]);
            const t1 = vpopAny(vs, ctl[0..ctl_len.*]);
            if (t1 != t2) return error.TypeMismatch;
            try vpush(vs, t1);
        },
        0x20 => { // local.get
            const idx = try body.uleb();
            if (idx >= f.local_count) return error.UnknownLocal;
            try vpush(vs, f.local_types[idx]);
        },
        0x21 => { // local.set
            const idx = try body.uleb();
            if (idx >= f.local_count) return error.UnknownLocal;
            try vpop(vs, ctl[0..ctl_len.*], f.local_types[idx]);
        },
        0x22 => { // local.tee
            const idx = try body.uleb();
            if (idx >= f.local_count) return error.UnknownLocal;
            try vpop(vs, ctl[0..ctl_len.*], f.local_types[idx]);
            try vpush(vs, f.local_types[idx]);
        },
        0x23 => { // global.get
            const idx = try body.uleb();
            if (idx >= m.global_count) return error.UnknownGlobal;
            try vpush(vs, m.globals[idx].val_type);
        },
        0x24 => { // global.set
            const idx = try body.uleb();
            if (idx >= m.global_count) return error.UnknownGlobal;
            if (!m.globals[idx].mutable) return error.TypeMismatch;
            try vpop(vs, ctl[0..ctl_len.*], m.globals[idx].val_type);
        },
        0x28...0x35 => { // loads (i32/i64/f32/f64.load + the *_8/16/32 subloads)
            if (!m.has_memory) return error.MemoryRequired;
            const al = try body.uleb();
            _ = try body.uleb();
            if (al > natAlign(op)) return error.BadAlign;
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpush(vs, loadType(op));
        },
        0x36...0x3E => { // stores (i32/i64/f32/f64.store + the *_8/16/32 substores)
            if (!m.has_memory) return error.MemoryRequired;
            const al = try body.uleb();
            _ = try body.uleb();
            if (al > natAlign(op)) return error.BadAlign;
            try vpop(vs, ctl[0..ctl_len.*], storeType(op));
            try vpop(vs, ctl[0..ctl_len.*], .i32);
        },
        0x3F => { // memory.size: memidx U32 LEB (wasm 2.0)
            if (!m.has_memory) return error.MemoryRequired;
            _ = try body.uleb();
            try vpush(vs, .i32);
        },
        0x40 => { // memory.grow: memidx U32 LEB (wasm 2.0)
            if (!m.has_memory) return error.MemoryRequired;
            _ = try body.uleb();
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpush(vs, .i32);
        },
        0x41 => {
            _ = try body.sleb();
            try vpush(vs, .i32);
        },
        0x42 => {
            _ = try body.sleb();
            try vpush(vs, .i64);
        },
        0x43 => { // f32.const: 4-byte LE immediate
            _ = try body.take(4);
            try vpush(vs, .f32);
        },
        0x44 => { // f64.const: 8-byte LE immediate
            _ = try body.take(8);
            try vpush(vs, .f64);
        },
        0x45 => {
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpush(vs, .i32);
        },
        0x50 => {
            try vpop(vs, ctl[0..ctl_len.*], .i64);
            try vpush(vs, .i32);
        },
        0x46...0x4F => {
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpush(vs, .i32);
        },
        0x51...0x5A => {
            try vpop(vs, ctl[0..ctl_len.*], .i64);
            try vpop(vs, ctl[0..ctl_len.*], .i64);
            try vpush(vs, .i32);
        },
        0x5B...0x60 => { // f32 eq/ne/lt/gt/le/ge (no f32.eqz in wasm)
            try vpop(vs, ctl[0..ctl_len.*], .f32);
            try vpop(vs, ctl[0..ctl_len.*], .f32);
            try vpush(vs, .i32);
        },
        0x61...0x66 => { // f64 eq/ne/lt/gt/le/ge
            try vpop(vs, ctl[0..ctl_len.*], .f64);
            try vpop(vs, ctl[0..ctl_len.*], .f64);
            try vpush(vs, .i32);
        },
        0x8B...0x98 => { // f32 unary + binary (abs..copysign)
            const unary = op <= 0x91; // abs,neg,ceil,floor,trunc,nearest,sqrt
            try vpop(vs, ctl[0..ctl_len.*], .f32);
            if (!unary) try vpop(vs, ctl[0..ctl_len.*], .f32);
            try vpush(vs, .f32);
        },
        0x99...0xA6 => { // f64 unary + binary (abs..copysign)
            const unary = op <= 0x9F;
            try vpop(vs, ctl[0..ctl_len.*], .f64);
            if (!unary) try vpop(vs, ctl[0..ctl_len.*], .f64);
            try vpush(vs, .f64);
        },
        0xA8, 0xA9 => { // i32.trunc_f32_s/u — plain (trapping) trunc
            try vpop(vs, ctl[0..ctl_len.*], .f32);
            try vpush(vs, .i32);
        },
        0xAA, 0xAB => { // i32.trunc_f64_s/u
            try vpop(vs, ctl[0..ctl_len.*], .f64);
            try vpush(vs, .i32);
        },
        0xAC, 0xAD => { // i64.extend_i32_s / _u
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpush(vs, .i64);
        },
        0xAE, 0xAF => { // i64.trunc_f32_s/u
            try vpop(vs, ctl[0..ctl_len.*], .f32);
            try vpush(vs, .i64);
        },
        0xB0, 0xB1 => { // i64.trunc_f64_s/u
            try vpop(vs, ctl[0..ctl_len.*], .f64);
            try vpush(vs, .i64);
        },
        0xB2...0xBF => { // float<->int converts + reinterpret
            const t = convStack(op); // {pop, push} pair
            try vpop(vs, ctl[0..ctl_len.*], t.in);
            try vpush(vs, t.out);
        },
        0xFC => { // 0xFC prefix: trunc_sat 0..7 + bulk-memory 8..11 in subset
            const sub = try body.uleb();
            switch (sub) {
                0...7 => {
                    const t = truncStack(sub);
                    try vpop(vs, ctl[0..ctl_len.*], t.in);
                    try vpush(vs, t.out);
                },
                8 => { // memory.init: dataidx uleb + memidx byte; [dst src n] -> []
                    if (!m.has_datacount) return error.DataCountMissing;
                    const didx = try body.uleb();
                    if (didx >= m.data_count_decl) return error.IndexOutOfRange;
                    _ = try body.uleb(); // memidx U32 LEB
                    if (!m.has_memory) return error.MemoryRequired;
                    try vpop(vs, ctl[0..ctl_len.*], .i32);
                    try vpop(vs, ctl[0..ctl_len.*], .i32);
                    try vpop(vs, ctl[0..ctl_len.*], .i32);
                },
                9 => { // data.drop: dataidx uleb; no stack effect
                    if (!m.has_datacount) return error.DataCountMissing;
                    const didx = try body.uleb();
                    if (didx >= m.data_count_decl) return error.IndexOutOfRange;
                },
                10 => { // memory.copy: dst-memidx src-memidx (U32 LEBs); [dst src n] -> []
                    if (!m.has_memory) return error.MemoryRequired;
                    _ = try body.uleb();
                    _ = try body.uleb();
                    try vpop(vs, ctl[0..ctl_len.*], .i32);
                    try vpop(vs, ctl[0..ctl_len.*], .i32);
                    try vpop(vs, ctl[0..ctl_len.*], .i32);
                },
                11 => { // memory.fill: memidx U32 LEB; [dst val n] -> []
                    if (!m.has_memory) return error.MemoryRequired;
                    _ = try body.uleb();
                    try vpop(vs, ctl[0..ctl_len.*], .i32);
                    try vpop(vs, ctl[0..ctl_len.*], .i32);
                    try vpop(vs, ctl[0..ctl_len.*], .i32);
                },
                else => return error.BulkMemoryOutOfSubset, // table ops 12+ / future
            }
        },
        0x67...0x78 => {
            const unary = op <= 0x69;
            try vpop(vs, ctl[0..ctl_len.*], .i32);
            if (!unary) try vpop(vs, ctl[0..ctl_len.*], .i32);
            try vpush(vs, .i32);
        },
        0x79...0x8A => {
            const unary = op <= 0x7B;
            try vpop(vs, ctl[0..ctl_len.*], .i64);
            if (!unary) try vpop(vs, ctl[0..ctl_len.*], .i64);
            try vpush(vs, .i64);
        },
        0xA7 => {
            try vpop(vs, ctl[0..ctl_len.*], .i64);
            try vpush(vs, .i32);
        },
        0xC0...0xC4 => {
            const t: ValType = if (op <= 0xC1) .i32 else .i64;
            try vpop(vs, ctl[0..ctl_len.*], t);
            try vpush(vs, t);
        },
        else => {
            return error.UnknownValueType;
        },
    }
    return body.pos;
}

fn natAlign(op: u8) u32 {
    return switch (op) {
        0x2C, 0x2D, 0x30, 0x31 => 0, // 8-bit
        0x2E, 0x2F, 0x32, 0x33 => 1, // 16-bit
        0x28, 0x2A, 0x34, 0x35, 0x36, 0x38, 0x3A, 0x3B, 0x3E => 2, // 32-bit
        0x29, 0x2B, 0x37, 0x39, 0x3C, 0x3D => 3, // 64-bit
        else => 0,
    };
}

fn loadType(op: u8) ValType {
    return switch (op) {
        0x28, 0x2C...0x2F => .i32,
        0x2A => .f32,
        0x2B => .f64,
        else => .i64, // 0x29 + the i64 *_8/16/32 subloads
    };
}

fn storeType(op: u8) ValType {
    return switch (op) {
        0x36, 0x3A, 0x3B => .i32,
        0x38 => .f32,
        0x39 => .f64,
        else => .i64, // 0x37 + the i64 substores
    };
}

/// Stack effect of the 0xB2..0xBF conversion/reinterpret opcodes.
const ConvShape = struct { in: ValType, out: ValType };
fn convStack(op: u8) ConvShape {
    return switch (op) {
        0xB2, 0xB3 => .{ .in = .i32, .out = .f32 }, // f32.convert_i32_s/u
        0xB4, 0xB5 => .{ .in = .i64, .out = .f32 }, // f32.convert_i64_s/u
        0xB6 => .{ .in = .f64, .out = .f32 }, // f32.demote_f64
        0xB7, 0xB8 => .{ .in = .i32, .out = .f64 }, // f64.convert_i32_s/u
        0xB9, 0xBA => .{ .in = .i64, .out = .f64 }, // f64.convert_i64_s/u
        0xBB => .{ .in = .f32, .out = .f64 }, // f64.promote_f32
        0xBC => .{ .in = .f32, .out = .i32 }, // i32.reinterpret_f32
        0xBD => .{ .in = .f64, .out = .i64 }, // i64.reinterpret_f64
        0xBE => .{ .in = .i32, .out = .f32 }, // f32.reinterpret_i32
        else => .{ .in = .i64, .out = .f64 }, // 0xBF f64.reinterpret_i64
    };
}

/// Stack effect of the trunc subopcodes 0..7 shared by the 0xFC 0..7
/// trunc_sat forms and execTrunc's plain-trunc index mapping (the plain
/// family's bytes 0xA8..0xB1 map to this index by skips: 0,1=f32→i32,
/// 2,3=f64→i32, 4,5=f32→i64, 6,7=f64→i64 — 0xAC/0xAD are extends, not
/// truncs).
fn truncStack(sub: u32) ConvShape {
    return switch (sub) {
        0, 1 => .{ .in = .f32, .out = .i32 }, // i32.trunc_f32_s/u
        2, 3 => .{ .in = .f64, .out = .i32 }, // i32.trunc_f64_s/u
        4, 5 => .{ .in = .f32, .out = .i64 }, // i64.trunc_f32_s/u
        else => .{ .in = .f64, .out = .i64 }, // 6, 7: i64.trunc_f64_s/u
    };
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------
const Frame = struct {
    func_idx: u32 = 0,
    locals: [max_locals]Value = undefined,
    height: usize = 0, // operand-stack base for this call
    ctl_base: usize = 0,
    body: []const u8 = &.{},
    pc: usize = 0,
    abs_off: usize = 0,
};

const ECtl = struct {
    kind: enum { block, loop, if_, func },
    height: usize,
    blocktype: ?ValType = null,
    else_pc: ?usize = null, // if-only
    end_pc: usize = 0, // pc of the matching `end`
    arity: u8 = 0, // 0 or 1
};

pub const CallResult = union(enum) {
    ret: struct {
        vals: [max_results]Value = undefined,
        count: u8 = 0,
    },
    trap: Trap,
};

const TrapError = error{Trap};

fn mkTrap(kind: TrapKind, module: []const u8, offset: usize) CallResult {
    return .{ .trap = .{ .kind = kind, .module = module, .offset = offset } };
}

/// The machine: file-scope global (segmented DSK3 .data/.bss) so the
/// EL0 stack never carries it. One instance; the runner re-instantiates
/// per module.
pub var machine = Machine{};

pub const Machine = struct {
    stack: [max_stack]Value = undefined,
    sp: usize = 0,
    ctl: [max_ctl]ECtl = undefined,
    ctl_len: usize = 0,
    frames: [max_frames]Frame = undefined,
    frame_len: usize = 0,
    table: [max_table]u32 = undefined,
    table_len: u32 = 0,
    store: []u8 = &.{},
    mem_pages: u32 = 0,
    mem_max: u32 = 0,
    globals: [max_globals]Value = undefined,
    data_dropped: [max_datas]bool = undefined, // per-instance data.drop state
    module_name: []const u8 = "module",
    last_trap: ?Trap = null,
};

pub fn resetMachine(mm: *Machine) void {
    mm.sp = 0;
    mm.ctl_len = 0;
    mm.frame_len = 0;
    mm.table_len = 0;
    mm.store = &.{};
    mm.mem_pages = 0;
    mm.mem_max = 0;
    mm.data_dropped = @as([max_datas]bool, @splat(@as(bool, false)));
    mm.module_name = "module";
    mm.last_trap = null;
}

/// Bind the store, apply element + data segments, then run `start` (if any).
/// Returns null on success or the instantiation trap.
pub fn instantiate(mm: *Machine, m: *const Module, store: []u8, module_name: []const u8) ?CallResult {
    resetMachine(mm);
    mm.module_name = module_name;
    mm.store = store;
    mm.table_len = if (m.table_count > 0) m.tables[0].min else 0;
    if (m.has_memory) {
        const declared = m.mem_max_pages orelse max_mem_pages;
        const store_pages: u32 = @intCast(@min(@as(usize, std.math.maxInt(u32)), store.len / page_size));
        mm.mem_max = @min(declared, @min(max_mem_pages, store_pages));
        mm.mem_pages = @min(m.mem_min_pages, mm.mem_max);
    }
    for (0..m.global_count) |i| mm.globals[i] = m.globals[i].init;
    for (m.elements[0..m.element_count]) |el| {
        if (el.offset + el.count > mm.table_len) return mkTrap(.bounds, module_name, el.abs_off);
        for (0..el.count) |i| mm.table[el.offset + i] = el.funcs[i];
    }
    for (m.datas[0..m.data_count]) |d| {
        if (d.passive) continue; // passive segments land via memory.init at runtime
        const mem_len = @as(u64, mm.mem_pages) * page_size;
        if (@as(u64, d.offset) + d.bytes.len > mem_len) return mkTrap(.bounds, module_name, d.abs_off);
        @memcpy(mm.store[d.offset .. d.offset + d.bytes.len], d.bytes);
    }
    if (m.start) |si| {
        const r = callInternal(mm, m, si, &.{}); // si validated < func_count
        if (r == .trap) return r;
    }
    return null;
}

/// Invoke a defined function. `args` values are copied into the callee's
/// locals (param slots first). Trap results carry module + offset.
pub fn call(mm: *Machine, m: *const Module, func_idx: u32, args: []const Value) CallResult {
    if (func_idx >= m.func_count) return mkTrap(.bounds, mm.module_name, 0);
    if (func_idx < m.imported_funcs) return dispatchImport(mm, m, func_idx, args);
    return callInternal(mm, m, func_idx, args);
}

fn callInternal(mm: *Machine, m: *const Module, func_idx: u32, args: []const Value) CallResult {
    const f = &m.funcs[func_idx];
    const ft = &m.types[f.type_index];
    if (args.len != ft.param_count) return mkTrap(.bounds, mm.module_name, f.abs_off);
    if (mm.frame_len >= max_frames) return mkTrap(.call_depth, mm.module_name, f.abs_off);

    var frame = Frame{
        .func_idx = func_idx,
        .height = mm.sp,
        .ctl_base = mm.ctl_len,
        .body = f.body,
        .abs_off = f.abs_off,
    };
    for (0..f.local_count) |i| frame.locals[i] = .{ .i64 = 0 };
    for (0..args.len) |i| frame.locals[i] = args[i];
    mm.frames[mm.frame_len] = frame;
    mm.frame_len += 1;

    if (mm.ctl_len >= max_ctl) {
        mm.frame_len -= 1;
        return mkTrap(.stack_overflow, mm.module_name, f.abs_off);
    }
    mm.ctl[mm.ctl_len] = .{
        .kind = .func,
        .height = mm.sp,
        .blocktype = if (ft.result_count == 1) ft.results[0] else null,
        .arity = ft.result_count,
    };
    mm.ctl_len += 1;
    mm.sp = frame.height; // args copied into locals; stack starts empty

    const r = execBody(mm, m, ft);
    mm.ctl_len = frame.ctl_base;
    mm.frame_len -= 1;
    mm.sp = frame.height;
    return r;
}

fn tryPush(mm: *Machine, v: Value) error{StackOverflow}!void {
    if (mm.sp >= max_stack) return error.StackOverflow;
    mm.stack[mm.sp] = v;
    mm.sp += 1;
}

fn popVal(mm: *Machine) Value {
    mm.sp -= 1;
    return mm.stack[mm.sp];
}

/// Scan the body from `from` for the matching `end` (and `else` for an
/// if) at nesting depth 0. The scanner skips over immediates so bytes
/// inside i32.const etc. never confuse the depth counter.
fn findBlockEnd(body: []const u8, from: usize, want_else: bool) struct { end_pc: usize, else_pc: ?usize } {
    var depth: usize = 0;
    var pc = from;
    var else_pc: ?usize = null;
    while (pc < body.len) {
        const op = body[pc];
        switch (op) {
            0x02, 0x03, 0x04 => {
                depth += 1;
                pc += 2; // opcode + blocktype byte
            },
            0x05 => {
                if (depth == 0 and want_else and else_pc == null) else_pc = pc;
                pc += 1;
            },
            0x0B => {
                if (depth == 0) return .{ .end_pc = pc, .else_pc = else_pc };
                depth -= 1;
                pc += 1;
            },
            else => pc = skipInstr(body, pc),
        }
    }
    return .{ .end_pc = body.len, .else_pc = else_pc };
}

/// Advance past one instruction (incl. immediates) at `pc`.
fn skipInstr(body: []const u8, pc: usize) usize {
    const op = body[pc];
    return switch (op) {
        0x0C, 0x0D => pc + 1 + lebLen(body, pc + 1),
        0x0E => blk: {
            // count uleb; count ulebs; default uleb (the vec is the count)
            var p = pc + 1;
            const n = readUlebRaw(body, &p);
            var i: u32 = 0;
            while (i < n) : (i += 1) _ = readUlebRaw(body, &p);
            _ = readUlebRaw(body, &p);
            break :blk p;
        },
        0x10 => pc + 1 + lebLen(body, pc + 1),
        // call_indirect: typeidx U32 LEB + tableidx U32 LEB (wasm 2.0 —
        // wasm-ld emits legal overlong encodings, so both must be LEBs)
        0x11 => pc + 1 + lebLen(body, pc + 1) + lebLen(body, pc + 1 + lebLen(body, pc + 1)),
        0x20...0x24 => pc + 1 + lebLen(body, pc + 1),
        0x28...0x3E => pc + 1 + lebLen(body, pc + 1) + lebLen(body, pc + 1 + lebLen(body, pc + 1)),
        0x3F, 0x40 => pc + 1 + lebLen(body, pc + 1), // memory.size/grow: memidx U32 LEB
        0x41, 0x42 => blk: {
            var p = pc + 1;
            while (p < body.len and body[p] & 0x80 != 0) p += 1;
            break :blk p + 1;
        },
        0x43 => pc + 5, // f32.const: 4-byte immediate
        0x44 => pc + 9, // f64.const: 8-byte immediate
        0xFC => blk: {
            var p = pc + 1;
            const sub = readUlebRaw(body, &p);
            switch (sub) {
                8 => { // memory.init: dataidx U32 LEB + memidx U32 LEB
                    _ = readUlebRaw(body, &p);
                    _ = readUlebRaw(body, &p);
                },
                9 => { // data.drop: dataidx U32 LEB
                    _ = readUlebRaw(body, &p);
                },
                10 => { // memory.copy: dst memidx + src memidx (U32 LEBs)
                    _ = readUlebRaw(body, &p);
                    _ = readUlebRaw(body, &p);
                },
                11 => { // memory.fill: memidx U32 LEB
                    _ = readUlebRaw(body, &p);
                },
                else => {}, // trunc 0..7 and table ops carry no scanner-relevant extras
            }
            break :blk p;
        },
        else => pc + 1,
    };
}

/// Raw uleb read for the scanner (no error plumbing; bounded by max 5).
fn readUlebRaw(body: []const u8, p: *usize) u32 {
    var result: u32 = 0;
    var shift: u6 = 0;
    var count: u8 = 0;
    while (true) : ({
        count += 1;
        shift += 7;
    }) {
        const b = body[p.*];
        p.* += 1;
        if (count >= 5) return result; // malformed: scanner is best-effort
        result |= @as(u32, b & 0x7F) << @intCast(shift);
        if (b & 0x80 == 0) return result;
    }
}

fn lebLen(body: []const u8, from: usize) usize {
    var i: usize = 0;
    while (from + i < body.len and body[from + i] & 0x80 != 0) : (i += 1) {}
    return if (from + i >= body.len) body.len - from else i + 1;
}

fn blockArity(bt: ?ValType) u8 {
    return if (bt != null) 1 else 0;
}

fn branch(mm: *Machine, frame: *Frame, depth: u32, op_off: usize) CallResult {
    if (depth >= mm.ctl_len) return mkTrap(.bounds, mm.module_name, op_off);
    const target = mm.ctl[mm.ctl_len - 1 - depth];
    if (target.kind == .func) {
        // br to the function label == return
        const n_out: usize = mm.sp - frame.height;
        var res: [max_results]Value = undefined;
        for (0..n_out) |i| res[i] = mm.stack[frame.height + i];
        var out: [max_results]Value = undefined;
        for (0..n_out) |i| out[i] = res[n_out - 1 - i];
        mm.sp = frame.height;
        mm.ctl_len = frame.ctl_base;
        return .{ .ret = .{ .vals = out, .count = @intCast(n_out) } };
    }
    if (target.kind == .loop) {
        // loop: jump back to the body start with the loop label arity
        // values on the stack (the blocktype result is the loop param).
        frame.pc = target.end_pc; // stored: the loop's BODY start
        mm.sp = target.height + target.arity;
        mm.ctl_len -= depth; // keep the loop frame
        return .{ .ret = .{ .count = 0 } };
    } else {
        // block/if: jump past the matching end, popping the target frame
        const n_res: usize = if (target.blocktype != null) @as(usize, 1) else 0;
        frame.pc = target.end_pc + 1;
        mm.sp = target.height + n_res;
        mm.ctl_len -= depth + 1;
        return .{ .ret = .{ .count = 0 } };
    }
}

fn execBody(mm: *Machine, m: *const Module, ft0: *const FuncType) CallResult {
    _ = ft0;
    while (true) {
        const frame = &mm.frames[mm.frame_len - 1];
        if (frame.pc >= frame.body.len) return mkTrap(.bounds, mm.module_name, frame.abs_off + frame.pc);
        const op = frame.body[frame.pc];
        const op_off = frame.abs_off + frame.pc;
        frame.pc += 1;
        var body = Reader{ .bytes = frame.body, .pos = frame.pc };
        switch (op) {
            0x00 => {
                return mkTrap(.@"unreachable", mm.module_name, op_off);
            },
            0x01 => {},
            0x02, 0x03, 0x04 => { // block / loop / if
                const bt = parseBlockType(&body) catch return mkTrap(.bounds, mm.module_name, op_off);
                const ar = blockArity(bt);
                if (op == 0x04) { // if: pop condition
                    const cond = popVal(mm).i32;
                    if (cond == 0) {
                        // find the else/end and jump
                        const be = findBlockEnd(frame.body, body.pos, true);
                        if (be.else_pc) |ep| {
                            frame.pc = ep + 1;
                            // push a ctl frame for the else path so `end`
                            // pops it symmetrically
                            if (mm.ctl_len >= max_ctl) return mkTrap(.stack_overflow, mm.module_name, op_off);
                            mm.ctl[mm.ctl_len] = .{ .kind = .if_, .height = mm.sp, .blocktype = bt, .end_pc = be.end_pc, .arity = ar };
                            mm.ctl_len += 1;
                        } else {
                            frame.pc = be.end_pc; // run the `end` directly
                            if (mm.ctl_len >= max_ctl) return mkTrap(.stack_overflow, mm.module_name, op_off);
                            mm.ctl[mm.ctl_len] = .{ .kind = .if_, .height = mm.sp, .blocktype = bt, .end_pc = be.end_pc, .arity = ar };
                            mm.ctl_len += 1;
                        }
                        continue;
                    }
                }
                if (mm.ctl_len >= max_ctl) return mkTrap(.stack_overflow, mm.module_name, op_off);
                const be = findBlockEnd(frame.body, body.pos, false);
                mm.ctl[mm.ctl_len] = .{
                    .kind = if (op == 0x02) .block else if (op == 0x03) .loop else .if_,
                    .height = mm.sp,
                    .blocktype = bt,
                    .end_pc = if (op == 0x03) body.pos else be.end_pc,
                    .arity = ar,
                };
                mm.ctl_len += 1;
            },
            0x05 => { // else (true path fell through)
                const entry = &mm.ctl[mm.ctl_len - 1];
                if (entry.kind != .if_) return mkTrap(.@"unreachable", mm.module_name, op_off);
                // true-path values are dropped (the blocktype arity was
                // validated); jump to the matching end (if any)
                if (entry.blocktype) |_| {
                    // the true path SHOULD have left the result; verify the
                    // result slot count and drop everything above height
                    if (mm.sp >= entry.height + entry.arity) {
                        mm.sp = entry.height + entry.arity;
                    }
                } else {
                    mm.sp = entry.height;
                }
                frame.pc = entry.end_pc;
            },
            0x0B => { // end
                if (mm.ctl_len == 0) return mkTrap(.@"unreachable", mm.module_name, op_off);
                const entry = mm.ctl[mm.ctl_len - 1];
                mm.ctl_len -= 1;
                if (entry.kind == .func) {
                    var res: [max_results]Value = undefined;
                    var n: u8 = 0;
                    while (mm.sp > entry.height) {
                        res[n] = popVal(mm);
                        n += 1;
                    }
                    var out: [max_results]Value = undefined;
                    for (0..n) |i| out[i] = res[n - 1 - i];
                    mm.sp = entry.height;
                    return .{ .ret = .{ .vals = out, .count = n } };
                }
                // block/loop/if fall-through: keep the blocktype result
                mm.sp = entry.height + entry.arity;
                // (blocktype arity was validated: at most 1 value sits above)
            },
            0x0C => { // br
                const depth = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const r = branch(mm, frame, depth, op_off);
                if (r == .trap) return r;
                continue;
            },
            0x0D => { // br_if
                const depth = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const cond = popVal(mm).i32;
                if (cond != 0) {
                    const r = branch(mm, frame, depth, op_off);
                    if (r == .trap) return r;
                    continue;
                }
            },
            0x0E => { // br_table
                const n = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                var depths: [max_ctl]u32 = undefined;
                for (0..n) |i| depths[i] = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const def = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const idx = popVal(mm).i32;
                const d: u32 = if (idx < 0 or @as(u32, @intCast(idx)) >= n) def else depths[@intCast(idx)];
                const r = branch(mm, frame, d, op_off);
                if (r == .trap) return r;
                continue;
            },
            0x0F => { // return
                const func_frame = &mm.frames[mm.frame_len - 1];
                const height = func_frame.height;
                const n_out: usize = mm.sp - height;
                var res: [max_results]Value = undefined;
                for (0..n_out) |i| res[i] = mm.stack[height + i];
                var out: [max_results]Value = undefined;
                for (0..n_out) |i| out[i] = res[n_out - 1 - i];
                mm.sp = height;
                return .{ .ret = .{ .vals = out, .count = @intCast(n_out) } };
            },
            0x10 => { // call
                const fi = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (fi >= m.func_count) return mkTrap(.bounds, mm.module_name, op_off);
                const callee = if (fi < m.imported_funcs)
                    &m.types[m.imports[fi].type_index]
                else
                    &m.types[m.funcs[fi].type_index];
                // pop args into an array (last param topmost)
                var args: [max_params]Value = undefined;
                for (0..callee.param_count) |i| {
                    args[callee.param_count - 1 - i] = popVal(mm);
                }
                const r = if (fi < m.imported_funcs)
                    dispatchImport(mm, m, fi, args[0..callee.param_count])
                else
                    callInternal(mm, m, fi, args[0..callee.param_count]);
                if (r == .trap) return r;
                for (0..r.ret.count) |i| tryPush(mm, r.ret.vals[i]) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x11 => { // call_indirect
                const ti = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                _ = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (ti >= m.type_count) return mkTrap(.bounds, mm.module_name, op_off);
                const expected = &m.types[ti];
                const tbl_idx = popVal(mm).i32;
                if (tbl_idx < 0 or @as(u32, @intCast(tbl_idx)) >= mm.table_len) {
                    return mkTrap(.bounds, mm.module_name, op_off);
                }
                const fi = mm.table[@intCast(tbl_idx)];
                if (fi >= m.func_count) return mkTrap(.bounds, mm.module_name, op_off);
                const actual = if (fi < m.imported_funcs)
                    &m.types[m.imports[fi].type_index]
                else
                    &m.types[m.funcs[fi].type_index];
                if (!FuncType.eql(expected.*, actual.*)) return mkTrap(.call_indirect_type, mm.module_name, op_off);
                var args: [max_params]Value = undefined;
                for (0..actual.param_count) |i| {
                    args[actual.param_count - 1 - i] = popVal(mm);
                }
                const r = if (fi < m.imported_funcs)
                    dispatchImport(mm, m, fi, args[0..actual.param_count])
                else
                    callInternal(mm, m, fi, args[0..actual.param_count]);
                if (r == .trap) return r;
                for (0..r.ret.count) |i| tryPush(mm, r.ret.vals[i]) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x1A => {
                _ = popVal(mm);
            },
            0x1B => { // select
                const cond = popVal(mm).i32;
                const v2 = popVal(mm);
                const v1 = popVal(mm);
                tryPush(mm, if (cond != 0) v1 else v2) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x20 => { // local.get
                const idx = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (idx >= mm.frames[mm.frame_len - 1].locals.len) return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, mm.frames[mm.frame_len - 1].locals[idx]) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x21 => { // local.set
                const idx = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (idx >= mm.frames[mm.frame_len - 1].locals.len) return mkTrap(.bounds, mm.module_name, op_off);
                mm.frames[mm.frame_len - 1].locals[idx] = popVal(mm);
            },
            0x22 => { // local.tee
                const idx = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (idx >= mm.frames[mm.frame_len - 1].locals.len) return mkTrap(.bounds, mm.module_name, op_off);
                const v = popVal(mm);
                mm.frames[mm.frame_len - 1].locals[idx] = v;
                tryPush(mm, v) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x23 => { // global.get
                const idx = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (idx >= m.global_count) return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, mm.globals[idx]) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x24 => { // global.set
                const idx = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                if (idx >= m.global_count) return mkTrap(.bounds, mm.module_name, op_off);
                mm.globals[idx] = popVal(mm);
            },
            0x28...0x35 => { // loads
                _ = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const off = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const addr = @as(u32, @bitCast(popVal(mm).i32));
                const v = loadMem(mm, op, addr, off) catch return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, v) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x36...0x3E => { // stores
                _ = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const off = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const v = popVal(mm);
                const addr = @as(u32, @bitCast(popVal(mm).i32));
                storeMem(mm, op, addr, off, v) catch return mkTrap(.bounds, mm.module_name, op_off);
            },
            0x3F => { // memory.size
                _ = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, .{ .i32 = @intCast(mm.mem_pages) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x40 => { // memory.grow
                _ = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                const delta = @as(u32, @bitCast(popVal(mm).i32));
                const cur = mm.mem_pages;
                const new = cur +% delta;
                if (new > mm.mem_max or new > max_mem_pages) return mkTrap(.grow_limit, mm.module_name, op_off);
                if (@as(u64, new) * page_size > mm.store.len) return mkTrap(.grow_limit, mm.module_name, op_off);
                @memset(mm.store[@as(usize, cur) * page_size .. @as(usize, new) * page_size], 0);
                mm.mem_pages = new;
                tryPush(mm, .{ .i32 = @intCast(cur) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x41 => { // i32.const
                const v = body.sleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, .{ .i32 = @truncate(v) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x42 => { // i64.const
                const v = body.sleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, .{ .i64 = v }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x43 => { // f32.const (4-byte LE immediate)
                const raw = body.take(4) catch return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, .{ .f32 = @bitCast(readInt(u32, raw[0..4])) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x44 => { // f64.const (8-byte LE immediate)
                const raw = body.take(8) catch return mkTrap(.bounds, mm.module_name, op_off);
                tryPush(mm, .{ .f64 = @bitCast(readInt(u64, raw[0..8])) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x45 => { // i32.eqz
                tryPush(mm, .{ .i32 = @intFromBool(popVal(mm).i32 == 0) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x50 => { // i64.eqz
                tryPush(mm, .{ .i32 = @intFromBool(popVal(mm).i64 == 0) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x46...0x4F => {
                const b = popVal(mm).i32;
                const a = popVal(mm).i32;
                tryPush(mm, .{ .i32 = cmpI32(op, a, b) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x51...0x5A => {
                const b = popVal(mm).i64;
                const a = popVal(mm).i64;
                tryPush(mm, .{ .i32 = cmpI64(op, a, b) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x5B...0x60 => { // f32 eq/ne/lt/gt/le/ge
                const b = popVal(mm).f32;
                const a = popVal(mm).f32;
                tryPush(mm, .{ .i32 = cmpF32(op, a, b) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x61...0x66 => { // f64 eq/ne/lt/gt/le/ge
                const b = popVal(mm).f64;
                const a = popVal(mm).f64;
                tryPush(mm, .{ .i32 = cmpF64(op, a, b) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x67...0x78 => {
                const r = execI32(mm, op) catch return mkTrap(.div_by_zero, mm.module_name, op_off);
                tryPush(mm, .{ .i32 = r }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x79...0x8A => {
                const r = execI64(mm, op) catch return mkTrap(.div_by_zero, mm.module_name, op_off);
                tryPush(mm, .{ .i64 = r }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x8B...0x98 => { // f32 unary + binary (abs..copysign)
                tryPush(mm, .{ .f32 = execFloat(f32, op - 0x8B, mm) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0x99...0xA6 => { // f64 unary + binary (abs..copysign)
                tryPush(mm, .{ .f64 = execFloat(f64, op - 0x99, mm) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xA8, 0xA9 => { // i32.trunc_f32_s/u — plain, traps on NaN/overflow
                const r = execTrunc(mm, op - 0xA8) orelse return mkTrap(.invalid_conv, mm.module_name, op_off);
                tryPush(mm, r) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xAA, 0xAB => { // i32.trunc_f64_s/u
                const r = execTrunc(mm, op - 0xAA + 2) orelse return mkTrap(.invalid_conv, mm.module_name, op_off);
                tryPush(mm, r) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xAE...0xB1 => { // i64.trunc_f32/f64_s/u (AE→4 .. B1→7)
                const r = execTrunc(mm, op - 0xAE + 4) orelse return mkTrap(.invalid_conv, mm.module_name, op_off);
                tryPush(mm, r) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xB2...0xBF => { // float<->int converts + reinterpret
                tryPush(mm, execConv(mm, op)) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xFC => { // trunc_sat 0..7 + bulk-memory 8..11
                const sub = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                switch (sub) {
                    0...7 => { // trunc_sat: clamps, never traps
                        tryPush(mm, execTruncSat(mm, sub)) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
                    },
                    8 => { // memory.init didx memidx: (dst src n), src in segment didx
                        const didx = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                        _ = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                        const n = @as(u32, @bitCast(popVal(mm).i32));
                        const src = @as(u32, @bitCast(popVal(mm).i32));
                        const dst = @as(u32, @bitCast(popVal(mm).i32));
                        const mem_len = @as(u64, mm.mem_pages) * page_size;
                        if (didx >= m.data_count) return mkTrap(.bounds, mm.module_name, op_off);
                        const seg_len: u64 = if (mm.data_dropped[didx]) 0 else m.datas[didx].bytes.len;
                        if (@as(u64, dst) + n > mem_len) return mkTrap(.bounds, mm.module_name, op_off);
                        if (@as(u64, src) + n > seg_len) return mkTrap(.bounds, mm.module_name, op_off);
                        if (n > 0) {
                            const d: usize = @intCast(dst);
                            const s: usize = @intCast(src);
                            const c: usize = @intCast(n);
                            @memcpy(mm.store[d .. d + c], m.datas[didx].bytes[s .. s + c]);
                        }
                    },
                    9 => { // data.drop didx
                        const didx = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                        if (didx >= m.data_count) return mkTrap(.bounds, mm.module_name, op_off);
                        mm.data_dropped[didx] = true;
                    },
                    10 => { // memory.copy: (dst src n), memmove semantics
                        _ = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                        _ = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                        const n = @as(u32, @bitCast(popVal(mm).i32));
                        const src = @as(u32, @bitCast(popVal(mm).i32));
                        const dst = @as(u32, @bitCast(popVal(mm).i32));
                        const mem_len = @as(u64, mm.mem_pages) * page_size;
                        if (@as(u64, dst) + n > mem_len) return mkTrap(.bounds, mm.module_name, op_off);
                        if (@as(u64, src) + n > mem_len) return mkTrap(.bounds, mm.module_name, op_off);
                        if (n > 0) {
                            const d: usize = @intCast(dst);
                            const s: usize = @intCast(src);
                            const c: usize = @intCast(n);
                            @memmove(mm.store[d .. d + c], mm.store[s .. s + c]);
                        }
                    },
                    11 => { // memory.fill: (dst val n)
                        _ = body.uleb() catch return mkTrap(.bounds, mm.module_name, op_off);
                        const n = @as(u32, @bitCast(popVal(mm).i32));
                        const val = @as(u32, @bitCast(popVal(mm).i32));
                        const dst = @as(u32, @bitCast(popVal(mm).i32));
                        const mem_len = @as(u64, mm.mem_pages) * page_size;
                        if (@as(u64, dst) + n > mem_len) return mkTrap(.bounds, mm.module_name, op_off);
                        if (n > 0) {
                            const d: usize = @intCast(dst);
                            const c: usize = @intCast(n);
                            @memset(mm.store[d .. d + c], @as(u8, @truncate(val)));
                        }
                    },
                    else => return mkTrap(.bounds, mm.module_name, op_off), // unreachable post-validation
                }
            },
            0xA7 => { // i32.wrap_i64
                tryPush(mm, .{ .i32 = @truncate(popVal(mm).i64) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xAC => { // i64.extend_i32_s
                tryPush(mm, .{ .i64 = popVal(mm).i32 }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xAD => { // i64.extend_i32_u
                const v = popVal(mm).i32;
                tryPush(mm, .{ .i64 = @intCast(@as(u32, @bitCast(v))) }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xC0, 0xC1 => { // i32.extend8_s / extend16_s
                const v = popVal(mm).i32;
                const r: i32 = if (op == 0xC0) @as(i8, @truncate(v)) else @as(i16, @truncate(v));
                tryPush(mm, .{ .i32 = r }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            0xC2...0xC4 => { // i64.extend8/16/32_s
                const v = popVal(mm).i64;
                const r: i64 = switch (op) {
                    0xC2 => @as(i8, @truncate(v)),
                    0xC3 => @as(i16, @truncate(v)),
                    else => @as(i32, @truncate(v)),
                };
                tryPush(mm, .{ .i64 = r }) catch return mkTrap(.stack_overflow, mm.module_name, op_off);
            },
            else => {
                return mkTrap(.bounds, mm.module_name, op_off);
            },
        }
        frame.pc = body.pos;
    }
}

fn loadMem(mm: *Machine, op: u8, addr: u32, off: u32) error{Bounds}!Value {
    const ea = @as(u64, addr) + off;
    const mem_len = @as(u64, mm.mem_pages) * page_size;
    if (ea + loadSize(op) > mem_len) return error.Bounds;
    const p = mm.store[@intCast(ea)..][0..loadSize(op)];
    return switch (op) {
        0x28 => .{ .i32 = @bitCast(readInt(u32, p[0..4])) },
        0x29 => .{ .i64 = @bitCast(readInt(u64, p[0..8])) },
        0x2A => .{ .f32 = @bitCast(readInt(u32, p[0..4])) },
        0x2B => .{ .f64 = @bitCast(readInt(u64, p[0..8])) },
        0x2C => .{ .i32 = @as(i8, @bitCast(p[0])) },
        0x2D => .{ .i32 = p[0] },
        0x2E => .{ .i32 = @as(i16, @bitCast(readInt(u16, p[0..2]))) },
        0x2F => .{ .i32 = readInt(u16, p[0..2]) },
        0x30 => .{ .i64 = @as(i8, @bitCast(p[0])) },
        0x31 => .{ .i64 = p[0] },
        0x32 => .{ .i64 = @as(i16, @bitCast(readInt(u16, p[0..2]))) },
        0x33 => .{ .i64 = readInt(u16, p[0..2]) },
        0x34 => .{ .i64 = @as(i32, @bitCast(readInt(u32, p[0..4]))) },
        0x35 => .{ .i64 = readInt(u32, p[0..4]) },
        else => unreachable,
    };
}

fn storeMem(mm: *Machine, op: u8, addr: u32, off: u32, v: Value) error{Bounds}!void {
    const ea = @as(u64, addr) + off;
    const mem_len = @as(u64, mm.mem_pages) * page_size;
    if (ea + storeSize(op) > mem_len) return error.Bounds;
    const p = mm.store[@intCast(ea)..][0..storeSize(op)];
    switch (op) {
        0x36 => writeInt(u32, p[0..4], @bitCast(v.i32)),
        0x37 => writeInt(u64, p[0..8], @bitCast(v.i64)),
        0x38 => writeInt(u32, p[0..4], @bitCast(v.f32)),
        0x39 => writeInt(u64, p[0..8], @bitCast(v.f64)),
        0x3A => p[0] = @truncate(@as(u32, @bitCast(v.i32))),
        0x3B => writeInt(u16, p[0..2], @truncate(@as(u32, @bitCast(v.i32)))),
        0x3C => p[0] = @truncate(@as(u64, @bitCast(v.i64))),
        0x3D => writeInt(u16, p[0..2], @truncate(@as(u64, @bitCast(v.i64)))),
        0x3E => writeInt(u32, p[0..4], @truncate(@as(u64, @bitCast(v.i64)))),
        else => unreachable,
    }
}

fn loadSize(op: u8) usize {
    return switch (op) {
        0x2C, 0x2D, 0x30, 0x31 => 1,
        0x2E, 0x2F, 0x32, 0x33 => 2,
        0x2A, 0x34, 0x35, 0x28 => 4,
        else => 8, // 0x29 + 0x2B + the i64 subloads
    };
}

fn storeSize(op: u8) usize {
    return switch (op) {
        0x3A, 0x3C => 1,
        0x3B, 0x3D => 2,
        0x38, 0x3E, 0x36 => 4,
        else => 8, // 0x37 + 0x39 + the i64 substores
    };
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn writeInt(comptime T: type, bytes: []u8, v: T) void {
    std.mem.writeInt(T, bytes[0..@sizeOf(T)], v, .little);
}

fn cmpI32(op: u8, a: i32, b: i32) i32 {
    return switch (op) {
        0x46 => @intFromBool(a == b),
        0x47 => @intFromBool(a != b),
        0x48 => @intFromBool(a < b),
        0x49 => @intFromBool(@as(u32, @bitCast(a)) < @as(u32, @bitCast(b))),
        0x4A => @intFromBool(a > b),
        0x4B => @intFromBool(@as(u32, @bitCast(a)) > @as(u32, @bitCast(b))),
        0x4C => @intFromBool(a <= b),
        0x4D => @intFromBool(@as(u32, @bitCast(a)) <= @as(u32, @bitCast(b))),
        0x4E => @intFromBool(a >= b),
        0x4F => @intFromBool(@as(u32, @bitCast(a)) >= @as(u32, @bitCast(b))),
        else => unreachable,
    };
}

fn cmpI64(op: u8, a: i64, b: i64) i32 {
    return switch (op) {
        0x51 => @intFromBool(a == b),
        0x52 => @intFromBool(a != b),
        0x53 => @intFromBool(a < b),
        0x54 => @intFromBool(@as(u64, @bitCast(a)) < @as(u64, @bitCast(b))),
        0x55 => @intFromBool(a > b),
        0x56 => @intFromBool(@as(u64, @bitCast(a)) > @as(u64, @bitCast(b))),
        0x57 => @intFromBool(a <= b),
        0x58 => @intFromBool(@as(u64, @bitCast(a)) <= @as(u64, @bitCast(b))),
        0x59 => @intFromBool(a >= b),
        0x5A => @intFromBool(@as(u64, @bitCast(a)) >= @as(u64, @bitCast(b))),
        else => unreachable,
    };
}

const DivError = error{Div0};

fn execI32(mm: *Machine, op: u8) DivError!i32 {
    const b = popVal(mm).i32;
    if (op == 0x67) return @intCast(@clz(@as(u32, @bitCast(b))));
    if (op == 0x68) return @intCast(@ctz(@as(u32, @bitCast(b))));
    if (op == 0x69) return @intCast(@popCount(@as(u32, @bitCast(b))));
    const a = popVal(mm).i32;
    return switch (op) {
        0x6A => a +% b,
        0x6B => a -% b,
        0x6C => a *% b,
        0x6D => {
            if (b == 0) return error.Div0;
            if (a == std.math.minInt(i32) and b == -1) return error.Div0;
            return @divTrunc(a, b);
        },
        0x6E => {
            if (b == 0) return error.Div0;
            return @intCast(@divTrunc(@as(u32, @bitCast(a)), @as(u32, @bitCast(b))));
        },
        0x6F => {
            if (b == 0) return error.Div0;
            return @rem(a, b);
        },
        0x70 => {
            if (b == 0) return error.Div0;
            return @intCast(@rem(@as(u32, @bitCast(a)), @as(u32, @bitCast(b))));
        },
        0x71 => a & b,
        0x72 => a | b,
        0x73 => a ^ b,
        0x74 => @bitCast(@as(u32, @bitCast(a)) << @as(u5, @truncate(@as(u32, @bitCast(b))))),
        0x75 => @bitCast(@as(i32, a) >> @as(u5, @truncate(@as(u32, @bitCast(b))))),
        0x76 => @bitCast(@as(u32, @bitCast(a)) >> @as(u5, @truncate(@as(u32, @bitCast(b))))),
        0x77 => rotl32(a, b),
        0x78 => rotr32(a, b),
        else => unreachable,
    };
}

fn execI64(mm: *Machine, op: u8) DivError!i64 {
    const b = popVal(mm).i64;
    if (op == 0x79) return @intCast(@clz(@as(u64, @bitCast(b))));
    if (op == 0x7A) return @intCast(@ctz(@as(u64, @bitCast(b))));
    if (op == 0x7B) return @intCast(@popCount(@as(u64, @bitCast(b))));
    const a = popVal(mm).i64;
    return switch (op) {
        0x7C => a +% b,
        0x7D => a -% b,
        0x7E => a *% b,
        0x7F => {
            if (b == 0) return error.Div0;
            if (a == std.math.minInt(i64) and b == -1) return error.Div0;
            return @divTrunc(a, b);
        },
        0x80 => {
            if (b == 0) return error.Div0;
            return @intCast(@divTrunc(@as(u64, @bitCast(a)), @as(u64, @bitCast(b))));
        },
        0x81 => {
            if (b == 0) return error.Div0;
            return @rem(a, b);
        },
        0x82 => {
            if (b == 0) return error.Div0;
            return @intCast(@rem(@as(u64, @bitCast(a)), @as(u64, @bitCast(b))));
        },
        0x83 => a & b,
        0x84 => a | b,
        0x85 => a ^ b,
        0x86 => @bitCast(@as(u64, @bitCast(a)) << @as(u6, @truncate(@as(u64, @bitCast(b))))),
        0x87 => @bitCast(@as(i64, a) >> @as(u6, @truncate(@as(u64, @bitCast(b))))),
        0x88 => @bitCast(@as(u64, @bitCast(a)) >> @as(u6, @truncate(@as(u64, @bitCast(b))))),
        0x89 => rotl64(a, b),
        0x8A => rotr64(a, b),
        else => unreachable,
    };
}

fn rotl32(a: i32, b: i32) i32 {
    const n: u5 = @truncate(@as(u32, @bitCast(b)));
    const x = @as(u32, @bitCast(a));
    return @bitCast((x << n) | (x >> (~n +% 1)));
}

fn rotr32(a: i32, b: i32) i32 {
    const n: u5 = @truncate(@as(u32, @bitCast(b)));
    const x = @as(u32, @bitCast(a));
    return @bitCast((x >> n) | (x << (~n +% 1)));
}

fn rotl64(a: i64, b: i64) i64 {
    const n: u6 = @truncate(@as(u64, @bitCast(b)));
    const x = @as(u64, @bitCast(a));
    return @bitCast((x << n) | (x >> (~n +% 1)));
}

fn rotr64(a: i64, b: i64) i64 {
    const n: u6 = @truncate(@as(u64, @bitCast(b)));
    const x = @as(u64, @bitCast(a));
    return @bitCast((x >> n) | (x << (~n +% 1)));
}

// ---------------------------------------------------------------------------
// Float exec (M35 W4, issue #765). IEEE-754 semantics: round-to-nearest-
// even on the hardware default; div-by-zero yields +/-inf (NEVER a trap —
// only the 0xFC trunc conversions trap, on NaN / out-of-range); min/max
// are IEEE-754 minNum/maxNum; `nearest` is round-half-to-even.
// ---------------------------------------------------------------------------
fn cmpF32(op: u8, a: f32, b: f32) i32 {
    return switch (op) {
        0x5B => @intFromBool(a == b), // eq — NaN == x is false
        0x5C => @intFromBool(a != b), // ne — NaN != x is true
        0x5D => @intFromBool(a < b),
        0x5E => @intFromBool(a > b),
        0x5F => @intFromBool(a <= b),
        else => @intFromBool(a >= b),
    };
}

fn cmpF64(op: u8, a: f64, b: f64) i32 {
    return switch (op) {
        0x61 => @intFromBool(a == b),
        0x62 => @intFromBool(a != b),
        0x63 => @intFromBool(a < b),
        0x64 => @intFromBool(a > b),
        0x65 => @intFromBool(a <= b),
        else => @intFromBool(a >= b),
    };
}

fn negZero(comptime T: type, x: T) bool {
    if (x != 0) return false;
    return switch (T) {
        f32 => (@as(u32, @bitCast(x)) & 0x8000_0000) != 0,
        else => (@as(u64, @bitCast(x)) & 0x8000_0000_0000_0000) != 0,
    };
}

/// IEEE-754 minNum (wasm fmin): numeric operand wins over NaN; on equal
/// zeros the negative zero wins.
fn fMinNum(comptime T: type, a: T, b: T) T {
    if (a != a) return b; // a is NaN
    if (b != b) return a; // b is NaN
    if (a == b) {
        if (negZero(T, a) or negZero(T, b)) return -@as(T, 0.0);
        return a;
    }
    return if (a < b) a else b;
}

/// IEEE-754 maxNum (wasm fmax): numeric operand wins over NaN; on equal
/// zeros the positive zero wins.
fn fMaxNum(comptime T: type, a: T, b: T) T {
    if (a != a) return b;
    if (b != b) return a;
    if (a == b) {
        if (negZero(T, a) and negZero(T, b)) return -@as(T, 0.0);
        return @as(T, 0.0);
    }
    return if (a > b) a else b;
}

/// wasm `nearest`: round-half-to-even (NOT `@round`, which rounds half
/// away from zero). NaN/inf pass through.
fn roundEven(comptime T: type, x: T) T {
    if (x != x) return x;
    const fl = @floor(x);
    if (x == std.math.inf(T) or x == -std.math.inf(T)) return x;
    const diff = x - fl;
    if (diff < 0.5) return fl;
    if (diff > 0.5) return fl + 1;
    // exactly .5: pick the even neighbour
    const r = if (@rem(fl, 2.0) == 0) fl else fl + 1;
    if (r == 0 and x < 0) return -@as(T, 0.0);
    return r;
}

/// Shared unary/binary float executor. `rel` is the opcode's offset into
/// its 14-op block: 0..6 unary (abs, neg, ceil, floor, trunc, nearest,
/// sqrt), 7..13 binary (add, sub, mul, div, min, max, copysign).
fn execFloat(comptime T: type, rel: u8, mm: *Machine) T {
    const b: T = switch (T) {
        f32 => popVal(mm).f32,
        else => popVal(mm).f64,
    };
    const unary = rel <= 6;
    const a: T = if (unary) undefined else switch (T) {
        f32 => popVal(mm).f32,
        else => popVal(mm).f64,
    };
    return switch (rel) {
        0 => @abs(b),
        1 => -b,
        2 => @ceil(b),
        3 => @floor(b),
        4 => @trunc(b),
        5 => roundEven(T, b),
        6 => @sqrt(b),
        7 => a + b,
        8 => a - b,
        9 => a * b,
        10 => a / b, // +/-inf on div-by-zero; NaN on 0/0 — never a trap
        11 => fMinNum(T, a, b),
        12 => fMaxNum(T, a, b),
        else => std.math.copysign(a, b),
    };
}

/// 0xB2..0xBF conversions + reinterpret. Never traps (converts from ints
/// are exact-or-rounded; promote/demote/reinterpret are bit/rounding ops).
fn execConv(mm: *Machine, op: u8) Value {
    return switch (op) {
        0xB2 => .{ .f32 = @floatFromInt(popVal(mm).i32) }, // f32.convert_i32_s
        0xB3 => .{ .f32 = @floatFromInt(@as(u32, @bitCast(popVal(mm).i32))) },
        0xB4 => .{ .f32 = @floatFromInt(popVal(mm).i64) },
        0xB5 => .{ .f32 = @floatFromInt(@as(u64, @bitCast(popVal(mm).i64))) },
        0xB6 => .{ .f32 = @floatCast(popVal(mm).f64) }, // f32.demote_f64
        0xB7 => .{ .f64 = @floatFromInt(popVal(mm).i32) }, // f64.convert_i32_s
        0xB8 => .{ .f64 = @floatFromInt(@as(u32, @bitCast(popVal(mm).i32))) },
        0xB9 => .{ .f64 = @floatFromInt(popVal(mm).i64) }, // f64.convert_i64_s
        0xBA => .{ .f64 = @floatFromInt(@as(u64, @bitCast(popVal(mm).i64))) },
        0xBB => .{ .f64 = @floatCast(popVal(mm).f32) }, // f64.promote_f32
        0xBC => .{ .i32 = @bitCast(popVal(mm).f32) }, // i32.reinterpret_f32
        0xBD => .{ .i64 = @bitCast(popVal(mm).f64) }, // i64.reinterpret_f64
        0xBE => .{ .f32 = @bitCast(popVal(mm).i32) }, // f32.reinterpret_i32
        else => .{ .f64 = @bitCast(popVal(mm).i64) }, // 0xBF f64.reinterpret_i64
    };
}

/// Range-checked truncation toward zero (wasm trunc*: traps on NaN and on
/// results outside the target integer range — returns null to trap). The
/// float is widened to f64 for the bound test (exact for both f32 and f64
/// inputs), so one bound set serves both input widths.
fn truncToInt(comptime F: type, comptime I: type, unsigned: bool, x: F) ?I {
    const xd: f64 = x;
    if (xd != xd) return null; // NaN
    const in_range: bool = switch (I) {
        i32 => if (unsigned) (xd > -1.0 and xd < 4294967296.0) else (xd > -2147483649.0 and xd < 2147483648.0),
        else => if (unsigned) (xd > -1.0 and xd < 18446744073709551616.0) else (xd >= -9223372036854775808.0 and xd < 9223372036854775808.0),
    };
    if (!in_range) return null;
    if (unsigned) {
        if (comptime I == i32) return @bitCast(@as(u32, @intFromFloat(x)));
        return @bitCast(@as(u64, @intFromFloat(x)));
    }
    return @intFromFloat(x);
}

/// 0xAA..0xB1 plain trunc conversions (the trapping forms). Returns null
/// → invalid_conv trap. (The 0xFC 0..7 trunc_sat forms never trap — see
/// execTruncSat.)
fn execTrunc(mm: *Machine, sub: u32) ?Value {
    return switch (sub) {
        0 => blk: { // i32.trunc_f32_s
            const r = truncToInt(f32, i32, false, popVal(mm).f32) orelse break :blk null;
            break :blk .{ .i32 = r };
        },
        1 => blk: {
            const r = truncToInt(f32, i32, true, popVal(mm).f32) orelse break :blk null;
            break :blk .{ .i32 = r };
        },
        2 => blk: { // i32.trunc_f64_s
            const r = truncToInt(f64, i32, false, popVal(mm).f64) orelse break :blk null;
            break :blk .{ .i32 = r };
        },
        3 => blk: {
            const r = truncToInt(f64, i32, true, popVal(mm).f64) orelse break :blk null;
            break :blk .{ .i32 = r };
        },
        4 => blk: { // i64.trunc_f32_s
            const r = truncToInt(f32, i64, false, popVal(mm).f32) orelse break :blk null;
            break :blk .{ .i64 = r };
        },
        5 => blk: {
            const r = truncToInt(f32, i64, true, popVal(mm).f32) orelse break :blk null;
            break :blk .{ .i64 = r };
        },
        6 => blk: { // i64.trunc_f64_s
            const r = truncToInt(f64, i64, false, popVal(mm).f64) orelse break :blk null;
            break :blk .{ .i64 = r };
        },
        else => blk: {
            const r = truncToInt(f64, i64, true, popVal(mm).f64) orelse break :blk null;
            break :blk .{ .i64 = r };
        },
    };
}

/// Saturating truncation (0xFC 0..7 trunc_sat*, which clang lowers C
/// float->int casts to): NaN -> 0 and out-of-range clamps to the integer
/// min/max — NEVER traps. (The plain trunc* family at 0xAA..0xB1 keeps
/// the trapping discipline; truncToInt's range test doubles as the exact
/// clamp predicate.)
fn truncSat(comptime F: type, comptime I: type, unsigned: bool, x: F) I {
    const xd: f64 = x;
    if (xd != xd) return 0; // NaN -> 0
    const r = truncToInt(F, I, unsigned, x) orelse blk: {
        if (unsigned) {
            // Out of range upward -> max (stored as the signed container's
            // bit pattern); negative -> 0 (trunc toward zero).
            const mx: I = if (comptime I == i32)
                @as(i32, @bitCast(@as(u32, std.math.maxInt(u32))))
            else
                @as(i64, @bitCast(@as(u64, std.math.maxInt(u64))));
            break :blk if (xd > -1.0) mx else 0;
        }
        // Signed: xd >= 2^(W-1) -> max; xd <= -(2^(W-1))-1 -> min. (The
        // exact halves, e.g. -2147483648.5, are truncToInt-in-range and
        // never reach here.)
        break :blk if (xd >= 0)
            @as(I, @intCast(std.math.maxInt(I)))
        else
            @as(I, @intCast(std.math.minInt(I)));
    };
    return r;
}

/// 0xFC 0..7 trunc_sat conversions (saturating, never trap).
fn execTruncSat(mm: *Machine, sub: u32) Value {
    return switch (sub) {
        0 => .{ .i32 = truncSat(f32, i32, false, popVal(mm).f32) }, // i32.trunc_sat_f32_s
        1 => .{ .i32 = truncSat(f32, i32, true, popVal(mm).f32) },
        2 => .{ .i32 = truncSat(f64, i32, false, popVal(mm).f64) }, // i32.trunc_sat_f64_s
        3 => .{ .i32 = truncSat(f64, i32, true, popVal(mm).f64) },
        4 => .{ .i64 = truncSat(f32, i64, false, popVal(mm).f32) }, // i64.trunc_sat_f32_s
        5 => .{ .i64 = truncSat(f32, i64, true, popVal(mm).f32) },
        6 => .{ .i64 = truncSat(f64, i64, false, popVal(mm).f64) }, // i64.trunc_sat_f64_s
        else => .{ .i64 = truncSat(f64, i64, true, popVal(mm).f64) },
    };
}

// ---------------------------------------------------------------------------
// Guest entry (W2: `exec WASM.BIN <file>`). The argv block rides the DSK3
// writable data tail (card 3e; ELF images cannot take argv), the module
// rides the `/host/` share (M34 HF4), and the linear memory is mmap'd at
// runtime (M29 anonymous) — the loader's 256 KiB staging budget counts
// .bss, so the 2 MiB D2 reservation never lives there.
// ---------------------------------------------------------------------------
const MODE_READ: u32 = 0x1;
const MODE_WRITE: u32 = 0x2;
const MODE_CREATE: u32 = 0x4;
const MODE_APPEND: u32 = 0x8;
const MODE_DIR: u32 = 0x10;
const PROT_READ: u64 = 1;
const PROT_WRITE: u64 = 2;
const MAP_PRIVATE: u64 = 0x02;
const MAP_ANONYMOUS: u64 = 0x20;

/// Generic ADR 0007 svc seam (x8 = slot, x0..x5 = args, x0 = result).
/// Unused arg registers are harmless zeroes, so one helper covers every
/// slot in the frozen surface.
inline fn svcN(num: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (num),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
          [a4] "{x4}" (a4),
          [a5] "{x5}" (a5),
        : .{ .memory = true });
}

fn file_write(fd: u64, buf: []const u8) i64 {
    return svcN(25, fd, @intFromPtr(buf.ptr), buf.len, 0, 0, 0);
}

fn dir_list(path: []const u8, out: [*]u8, max_entries: u32) i64 {
    return svcN(27, @intFromPtr(path.ptr), path.len, @intFromPtr(out), max_entries, 0, 0);
}

fn file_delete(path: []const u8) i64 {
    return svcN(34, @intFromPtr(path.ptr), path.len, 0, 0, 0, 0);
}

fn file_rename(old_path: []const u8, new_path: []const u8) i64 {
    return svcN(35, @intFromPtr(old_path.ptr), old_path.len, @intFromPtr(new_path.ptr), new_path.len, 0, 0);
}

fn file_truncate(fd: u64, size: u64) i64 {
    return svcN(36, fd, size, 0, 0, 0, 0);
}

fn file_free(volume: u64) i64 {
    return svcN(37, volume, 0, 0, 0, 0, 0);
}

fn win_open(x: u64, y: u64, w: u64, h: u64) i64 {
    return svcN(12, x, y, w, h, 0, 0);
}

fn win_fill(id: u64, x: u64, y: u64, w: u64, h: u64, rgb: u64) i64 {
    return svcN(13, id, x, y, w, h, rgb);
}

fn win_present(id: u64) i64 {
    return svcN(14, id, 0, 0, 0, 0, 0);
}

fn win_close(id: u64) i64 {
    return svcN(15, id, 0, 0, 0, 0, 0);
}

fn win_move(id: u64, x: u64, y: u64) i64 {
    return svcN(16, id, x, y, 0, 0, 0);
}

fn win_raise(id: u64) i64 {
    return svcN(17, id, 0, 0, 0, 0, 0);
}

fn win_get(id: u64, out: [*]u8) i64 {
    return svcN(18, id, @intFromPtr(out), 0, 0, 0, 0);
}

fn win_query(id: u64, out: [*]u8) i64 {
    return svcN(19, id, @intFromPtr(out), 0, 0, 0, 0);
}

fn win_set_visible(id: u64, visible: u64) i64 {
    return svcN(20, id, visible, 0, 0, 0, 0);
}

fn audio_info(out: [*]u8) i64 {
    return svcN(42, @intFromPtr(out), 0, 0, 0, 0, 0);
}

fn audio_play(buf: []const u8) i64 {
    return svcN(43, @intFromPtr(buf.ptr), buf.len, 0, 0, 0, 0);
}

fn audio_volume(vol: u64) i64 {
    return svcN(44, vol, 0, 0, 0, 0, 0);
}

fn audio_mute(muted: u64) i64 {
    return svcN(45, muted, 0, 0, 0, 0, 0);
}

fn timer_set(delay_ticks: u64) i64 {
    return svcN(40, delay_ticks, 0, 0, 0, 0, 0);
}

fn timer_cancel() i64 {
    return svcN(41, 0, 0, 0, 0, 0, 0);
}

fn munmap(addr: u64, len: u64) i64 {
    return svcN(64, addr, len, 0, 0, 0, 0);
}

fn procs(buf: [*]u8, max: u64) i64 {
    return svcN(7, @intFromPtr(buf), max, 0, 0, 0, 0);
}

fn wait(pid: u64) i64 {
    return svcN(8, pid, 0, 0, 0, 0, 0);
}

fn sys_write(buf: []const u8) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 1)),
          [fd] "{x0}" (@as(u64, 1)),
          [ptr] "{x1}" (@as(u64, @intFromPtr(buf.ptr))),
          [len] "{x2}" (@as(u64, buf.len)),
        : .{ .memory = true });
}

fn file_open(path: []const u8, flags: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 23)),
          [arg0] "{x0}" (@as(u64, @intFromPtr(path.ptr))),
          [arg1] "{x1}" (@as(u64, path.len)),
          [arg2] "{x2}" (@as(u64, flags)),
        : .{ .memory = true });
}

fn file_read(handle: u32, buf: []u8) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 24)),
          [arg0] "{x0}" (@as(u64, handle)),
          [arg1] "{x1}" (@as(u64, @intFromPtr(buf.ptr))),
          [arg2] "{x2}" (@as(u64, buf.len)),
        : .{ .memory = true });
}

fn file_close(handle: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 26)),
          [arg0] "{x0}" (@as(u64, handle)),
        : .{ .memory = true });
}

fn mmap(addr: u64, len: u64, prot: u64, flags: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 63)),
          [arg0] "{x0}" (addr),
          [arg1] "{x1}" (len),
          [arg2] "{x2}" (prot),
          [arg3] "{x3}" (flags),
        : .{ .memory = true });
}

fn console_puts(text: []const u8) void {
    if (text.len == 0) return;
    _ = sys_write(text);
}

/// Uaccess staging (claim 3456 W3 lesson, zero kernel changes): the
/// kernel's claim-6120 uaccess region table is GLOBAL and reset by EVERY
/// exec, so an mmap'd wasm store can lose its read/write registration the
/// instant any interleaved command execs (observed live: env.write /
/// env.file_open on store pointers returning EFAULT -3). Every dispatch
/// arm therefore crosses the svc boundary through interpreter-owned .bss
/// staging buffers — registered by the loader at exec time and never
/// dropped. Fixed sizes mirror the kernel's own caps (write_cap 256,
/// file staging 2048, max_path_len 64, dir_list 16 rows, audio staging
/// 4 KiB — see the claim note on audio_play's staging window).
const stage_write_len = 256; // kernel write_cap (excess -> einval)
const stage_path_len = 64; // kernel max_path_len (excess -> einval / enametoolong)
const stage_io_len = 2048; // kernel file staging (read take_count, write enospc cap)
const stage_dir_len = 640; // 16 DirEntry rows (dir_list 16-entry cap, procs row budget)
const stage_audio_len = 4096; // beep_period_bytes (kernel periods the play itself)
const stage_info_len = 32; // win_get (16) / win_query (32) / audio_info (16) out
const audio_max_len = 64 * 1024; // kernel virtio_snd.audio_max_len
const audio_period_len = 4096; // kernel virtio_snd.beep_period_bytes
var g_stage_write: [stage_write_len]u8 = undefined;
var g_stage_path: [stage_path_len]u8 = undefined;
var g_stage_path2: [stage_path_len]u8 = undefined;
var g_stage_io: [stage_io_len]u8 = undefined;
var g_stage_io2: [stage_io_len]u8 = undefined;
var g_stage_dir: [stage_dir_len]u8 = undefined;
var g_stage_audio: [stage_audio_len]u8 = undefined;
var g_stage_info: [stage_info_len]u8 = undefined;

/// Copy store[ptr..ptr+len] into a .bss stage. Null when out of the wasm
/// store (bounds trap — contract §3) or larger than the stage (the arm
/// maps that to the kernel's cap error, never silent truncation).
fn stageIn(mm: *Machine, ptr: u32, len: u32, buf: []u8) ?[]u8 {
    if (len > buf.len) return null;
    const s = storeSlice(mm, ptr, len) orelse return null;
    @memcpy(buf[0..len], s);
    return buf[0..len];
}

/// Copy kernel output staged in .bss back into the wasm store.
fn stageOut(mm: *Machine, ptr: u32, src: []const u8) void {
    const mem_len = @as(u64, mm.mem_pages) * page_size;
    const n: u64 = src.len;
    if (n > mem_len - @min(@as(u64, ptr), mem_len)) return; // never OOB (validated already)
    @memcpy(mm.store[ptr .. ptr + src.len], src);
}

/// Capture-seam out-fill, clamped to the store. Test-only path, but a
/// canned return may exceed the buffer the caller declared — fill what
/// fits instead of slicing past the store.
fn captureFill(mm: *Machine, ptr: u32, bytes: u64, fill: u8) void {
    const mem_len = @as(u64, mm.mem_pages) * page_size;
    const n = @min(bytes, mem_len - @min(@as(u64, ptr), mem_len));
    if (n == 0) return;
    @memset(mm.store[ptr .. ptr + @as(usize, @intCast(n))], fill);
}

fn sys_exit(status: u64) noreturn {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 3)),
          [code] "{x0}" (status),
    );
    unreachable;
}

fn fail(msg: []const u8, status: u64) noreturn {
    console_puts(msg);
    sys_exit(status);
}

/// The exec-trap serial line (M70d #1518): the class, the module, and the
/// module byte offset of the faulting instruction, in the `key=value` marker
/// style. Before this, `exec WASM.BIN ELK.WASM` printed only
/// `wasm: trap during exec`, so #1456 could not tell `call_depth` from
/// `stack_overflow`. Null when `buf` cannot hold the line (the caller falls
/// back to the unnamed form).
const trap_line_len = 192;
fn formatExecTrapLine(buf: []u8, trap: Trap) ?[]const u8 {
    return std.fmt.bufPrint(
        buf,
        "wasm: trap during exec kind={s} module={s} offset=0x{x}\n",
        .{ @tagName(trap.kind), trap.module, trap.offset },
    ) catch null;
}

/// Host-test capture: when set, imports record their calls (id + args)
/// and return canned values instead of reaching svc #0 (which a host test
/// cannot execute). The W2 semantics carry: env.write copies into
/// write_buf (byte-exact console proof) and env.exit marks exited + the
/// guest_exit trap. Pointer imports that produce out-data fill their
/// out-buffers with `out_fill` so tests can prove the copy crossed the
/// wasm store.
const CapId = enum(u8) {
    write,
    exit,
    file_open,
    file_read,
    file_write,
    file_close,
    dir_list,
    file_delete,
    file_rename,
    file_truncate,
    file_free,
    win_open,
    win_fill,
    win_present,
    win_close,
    win_move,
    win_raise,
    win_get,
    win_query,
    win_set_visible,
    audio_info,
    audio_play,
    audio_volume,
    audio_mute,
    timer_set,
    timer_cancel,
    mmap,
    munmap,
    procs,
    wait,
    count,
};
const cap_count: usize = @backingInt(CapId.count);

const CapturedCall = struct {
    id: CapId,
    a: [6]i64,
    n: u8,
};

const HostCapture = struct {
    write_buf: []u8,
    wrote: usize = 0,
    exit_status: i32 = -1,
    exited: bool = false,
    log: [96]CapturedCall = undefined,
    log_count: usize = 0,
    returns: [cap_count]i64 = @as([cap_count]i64, @splat(@as(i64, 0))),
    out_fill: u8 = 0xA5,
    // W5 (wc): when set, captured file_read serves bytes from file_data
    // (0 at EOF, cap-clamped — contract §5 semantics) so a host test can
    // execute a file-channel app end-to-end. file_pos advances per read.
    file_data: []const u8 = &.{},
    file_pos: usize = 0,

    fn logCall(c: *HostCapture, id: CapId, args: []const Value) void {
        if (c.log_count >= c.log.len) return;
        var cl = CapturedCall{ .id = id, .a = undefined, .n = 0 };
        // The frozen surface is all-i32; log the i32 lanes sign-extended
        // (Value is an extern union — reading .i64 of an i32 lane would
        // see undefined high bits).
        for (args, 0..) |v, i| {
            if (i >= cl.a.len) break;
            cl.a[i] = @as(i64, v.i32);
            cl.n = @intCast(i + 1);
        }
        c.log[c.log_count] = cl;
        c.log_count += 1;
    }
};
var g_capture: ?*HostCapture = null;

/// Wrap a kernel i64 result as the import's single i32 return (§4: negative
/// errno values stay negative through the truncation).
fn importRet(v: i64) CallResult {
    var out: [max_results]Value = undefined;
    out[0] = .{ .i32 = @truncate(v) };
    return .{ .ret = .{ .vals = out, .count = 1 } };
}

fn argPtr(args: []const Value, i: usize) u32 {
    return @bitCast(args[i].i32);
}

fn argU64(args: []const Value, i: usize) u64 {
    const u: u32 = @bitCast(args[i].i32);
    return u;
}

fn checkRange(mm: *Machine, ptr: u32, len: u32) bool {
    return @as(u64, ptr) + len <= @as(u64, mm.mem_pages) * page_size;
}

/// Range-checked store slice. len==0 is valid for ANY ptr (contract §3:
/// zero-length means no access) — return an empty slice at the store base,
/// never index at a wild pointer.
fn storeSlice(mm: *Machine, ptr: u32, len: u32) ?[]const u8 {
    if (len == 0) return mm.store[0..0];
    if (!checkRange(mm, ptr, len)) return null;
    return mm.store[ptr .. ptr + len];
}

/// Dispatch a call to an imported function. The frozen env.* surface
/// (docs/wasm-import-contract.md §5 + the W2 write/exit pair) — validate()
/// has already proven module + name + signature, so each arm extracts args
/// and either records into the host capture or runs the ADR 0007 svc seam.
fn dispatchImport(mm: *Machine, m: *const Module, imp_idx: u32, args: []const Value) CallResult {
    const imp = &m.imports[imp_idx]; // all imports are funcs (parse rejects the rest)
    const name = imp.name;

    // -- W2 debug pair (contract §7) --------------------------------------
    if (std.mem.eql(u8, name, "write")) {
        const fd = args[0].i32;
        const ptr = argPtr(args, 1);
        const len: u32 = @bitCast(args[2].i32);
        const mem_len = @as(u64, mm.mem_pages) * page_size;
        // §3: zero-length is valid for ANY ptr (no access); a non-empty
        // buffer must lie in the store or trap here, before any copy.
        if (len != 0 and @as(u64, ptr) + len > mem_len) return mkTrap(.bounds, mm.module_name, 0);
        if (g_capture) |c| {
            c.logCall(.write, args);
            if (len == 0) return importRet(0);
            const n = @min(@as(usize, len), c.write_buf.len - c.wrote);
            @memcpy(c.write_buf[c.wrote .. c.wrote + n], mm.store[ptr .. ptr + n]);
            c.wrote += n;
            return importRet(@intCast(n));
        }
        // Mirror kernel slot 1: fd must be 1 (ebadf), len capped at write_cap (einval).
        if (fd != 1) return importRet(-2);
        if (len > stage_write_len) return importRet(-1);
        const staged = stageIn(mm, ptr, len, &g_stage_write) orelse return mkTrap(.bounds, mm.module_name, 0);
        const r = sys_write(staged);
        return importRet(@intCast(r));
    }
    if (std.mem.eql(u8, name, "exit")) {
        if (g_capture) |c| {
            c.logCall(.exit, args);
            c.exited = true;
            c.exit_status = args[0].i32;
            // A noreturn import terminates the call stack; the guest path
            // is a real sys_exit, this marker exists only for capture.
            return mkTrap(.guest_exit, mm.module_name, 0);
        }
        sys_exit(@bitCast(@as(i64, args[0].i32)));
    }

    // -- §5.1 file --------------------------------------------------------
    if (std.mem.eql(u8, name, "file_open")) {
        const path_ptr = argPtr(args, 0);
        const path_len: u32 = @bitCast(args[1].i32);
        const flags: u32 = @bitCast(args[2].i32);
        if (g_capture) |c| {
            c.logCall(.file_open, args);
            return importRet(c.returns[@backingInt(CapId.file_open)]);
        }
        // Kernel slot 23: empty or > max_path_len path -> einval.
        if (path_len == 0 or path_len > stage_path_len) return importRet(-1);
        const staged = stageIn(mm, path_ptr, path_len, &g_stage_path) orelse return mkTrap(.bounds, mm.module_name, 0);
        return importRet(file_open(staged, flags));
    }
    if (std.mem.eql(u8, name, "file_read")) {
        const fd: u32 = @bitCast(args[0].i32);
        const buf_ptr = argPtr(args, 1);
        const cap: u32 = @bitCast(args[2].i32);
        // §3: cap==0 reads nothing — valid for any buf_ptr.
        if (cap != 0 and !checkRange(mm, buf_ptr, cap)) return mkTrap(.bounds, mm.module_name, 0);
        if (g_capture) |c| {
            c.logCall(.file_read, args);
            if (c.file_data.len > 0) {
                if (c.file_pos < c.file_data.len) {
                    const n = @min(@as(usize, cap), c.file_data.len - c.file_pos);
                    stageOut(mm, buf_ptr, c.file_data[c.file_pos .. c.file_pos + n]);
                    c.file_pos += n;
                    return importRet(@intCast(n));
                }
                return importRet(0); // exhausted: EOF, exactly like the kernel
            }
            return importRet(c.returns[@backingInt(CapId.file_read)]);
        }
        // Kernel slot 24: take_count = min(count, 2048); result copied out.
        if (cap == 0) return importRet(0);
        const take: u32 = @min(cap, stage_io_len);
        const staged = stageIn(mm, buf_ptr, take, &g_stage_io) orelse return mkTrap(.bounds, mm.module_name, 0);
        const r = file_read(fd, staged);
        if (r > 0) stageOut(mm, buf_ptr, g_stage_io[0..@intCast(r)]);
        return importRet(@intCast(r));
    }
    if (std.mem.eql(u8, name, "file_write")) {
        const fd = argU64(args, 0);
        const buf_ptr = argPtr(args, 1);
        const len: u32 = @bitCast(args[2].i32);
        if (g_capture) |c| {
            c.logCall(.file_write, args);
            return importRet(c.returns[@backingInt(CapId.file_write)]);
        }
        // Kernel slot 25: count > 2048 -> enospc (no truncation).
        if (len > stage_io_len) return importRet(-5);
        const staged = stageIn(mm, buf_ptr, len, &g_stage_io) orelse return mkTrap(.bounds, mm.module_name, 0);
        return importRet(file_write(fd, staged));
    }
    if (std.mem.eql(u8, name, "file_close")) {
        if (g_capture) |c| {
            c.logCall(.file_close, args);
            return importRet(c.returns[@backingInt(CapId.file_close)]);
        }
        const fd: u32 = @bitCast(args[0].i32);
        // Kernel slot 26 result passes through: 0 on success, ebadf (−2)
        // on a bad/closed handle (contract §5.1 — review fix, the kernel
        // result was previously discarded).
        return importRet(file_close(fd));
    }
    if (std.mem.eql(u8, name, "dir_list")) {
        const path_ptr = argPtr(args, 0);
        const path_len: u32 = @bitCast(args[1].i32);
        const out_ptr = argPtr(args, 2);
        const max_entries: u32 = @bitCast(args[3].i32);
        // u64 math: max_entries*40 must not wrap u32 before the range
        // check (a ~2^26-entry request used to wrap to a passing value).
        const need = @as(u64, max_entries) * 40;
        const mem_len = @as(u64, mm.mem_pages) * page_size;
        if (max_entries != 0 and @as(u64, out_ptr) + need > mem_len) return mkTrap(.bounds, mm.module_name, 0);
        if (g_capture) |c| {
            c.logCall(.dir_list, args);
            const n = c.returns[@backingInt(CapId.dir_list)];
            if (n > 0) captureFill(mm, out_ptr, @as(u64, @intCast(n)) * 40, c.out_fill);
            return importRet(n);
        }
        // Kernel slot 27: path_len > max_path_len -> enametoolong (empty = root).
        if (path_len > stage_path_len) return importRet(-8);
        const path = stageIn(mm, path_ptr, path_len, &g_stage_path) orelse return mkTrap(.bounds, mm.module_name, 0);
        const take: u32 = @min(max_entries, 16); // kernel floors to 16 entries
        const r = dir_list(path, &g_stage_dir, take);
        if (r > 0) stageOut(mm, out_ptr, g_stage_dir[0 .. @as(usize, @intCast(r)) * 40]);
        return importRet(@intCast(r));
    }
    if (std.mem.eql(u8, name, "file_delete")) {
        const path_ptr = argPtr(args, 0);
        const path_len = @as(u32, @bitCast(args[1].i32));
        if (g_capture) |c| {
            c.logCall(.file_delete, args);
            return importRet(c.returns[@backingInt(CapId.file_delete)]);
        }
        // Kernel slot 34: empty or > max_path_len -> einval.
        if (path_len == 0 or path_len > stage_path_len) return importRet(-1);
        const path = stageIn(mm, path_ptr, path_len, &g_stage_path) orelse return mkTrap(.bounds, mm.module_name, 0);
        return importRet(file_delete(path));
    }
    if (std.mem.eql(u8, name, "file_rename")) {
        const old_ptr = argPtr(args, 0);
        const old_len = @as(u32, @bitCast(args[1].i32));
        const new_ptr = argPtr(args, 2);
        const new_len = @as(u32, @bitCast(args[3].i32));
        if (g_capture) |c| {
            c.logCall(.file_rename, args);
            return importRet(c.returns[@backingInt(CapId.file_rename)]);
        }
        // Kernel slot 35: any empty or > max_path_len side -> einval.
        if (old_len == 0 or old_len > stage_path_len or new_len == 0 or new_len > stage_path_len) return importRet(-1);
        const old_p = stageIn(mm, old_ptr, old_len, &g_stage_path) orelse return mkTrap(.bounds, mm.module_name, 0);
        const new_p = stageIn(mm, new_ptr, new_len, &g_stage_path2) orelse return mkTrap(.bounds, mm.module_name, 0);
        return importRet(file_rename(old_p, new_p));
    }
    if (std.mem.eql(u8, name, "file_truncate")) {
        if (g_capture) |c| {
            c.logCall(.file_truncate, args);
            return importRet(c.returns[@backingInt(CapId.file_truncate)]);
        }
        return importRet(file_truncate(argU64(args, 0), argU64(args, 1)));
    }
    if (std.mem.eql(u8, name, "file_free")) {
        if (g_capture) |c| {
            c.logCall(.file_free, args);
            return importRet(c.returns[@backingInt(CapId.file_free)]);
        }
        return importRet(file_free(argU64(args, 0)));
    }

    // -- §5.2 window ------------------------------------------------------
    if (std.mem.eql(u8, name, "win_open")) {
        if (g_capture) |c| {
            c.logCall(.win_open, args);
            return importRet(c.returns[@backingInt(CapId.win_open)]);
        }
        return importRet(win_open(
            argU64(args, 0),
            argU64(args, 1),
            argU64(args, 2),
            argU64(args, 3),
        ));
    }
    if (std.mem.eql(u8, name, "win_fill")) {
        if (g_capture) |c| {
            c.logCall(.win_fill, args);
            return importRet(c.returns[@backingInt(CapId.win_fill)]);
        }
        return importRet(win_fill(
            argU64(args, 0),
            argU64(args, 1),
            argU64(args, 2),
            argU64(args, 3),
            argU64(args, 4),
            argU64(args, 5),
        ));
    }
    if (std.mem.eql(u8, name, "win_present")) {
        if (g_capture) |c| {
            c.logCall(.win_present, args);
            return importRet(c.returns[@backingInt(CapId.win_present)]);
        }
        return importRet(win_present(argU64(args, 0)));
    }
    if (std.mem.eql(u8, name, "win_close")) {
        if (g_capture) |c| {
            c.logCall(.win_close, args);
            return importRet(c.returns[@backingInt(CapId.win_close)]);
        }
        return importRet(win_close(argU64(args, 0)));
    }
    if (std.mem.eql(u8, name, "win_move")) {
        if (g_capture) |c| {
            c.logCall(.win_move, args);
            return importRet(c.returns[@backingInt(CapId.win_move)]);
        }
        return importRet(win_move(
            argU64(args, 0),
            argU64(args, 1),
            argU64(args, 2),
        ));
    }
    if (std.mem.eql(u8, name, "win_raise")) {
        if (g_capture) |c| {
            c.logCall(.win_raise, args);
            return importRet(c.returns[@backingInt(CapId.win_raise)]);
        }
        return importRet(win_raise(argU64(args, 0)));
    }
    if (std.mem.eql(u8, name, "win_get")) {
        const out_ptr = argPtr(args, 1);
        if (!checkRange(mm, out_ptr, 16)) return mkTrap(.bounds, mm.module_name, 0);
        if (g_capture) |c| {
            c.logCall(.win_get, args);
            @memset(mm.store[out_ptr .. out_ptr + 16], c.out_fill);
            return importRet(c.returns[@backingInt(CapId.win_get)]);
        }
        const r = win_get(argU64(args, 0), &g_stage_info);
        if (r == 0) stageOut(mm, out_ptr, g_stage_info[0..16]);
        return importRet(@intCast(r));
    }
    if (std.mem.eql(u8, name, "win_query")) {
        const out_ptr = argPtr(args, 1);
        if (!checkRange(mm, out_ptr, 32)) return mkTrap(.bounds, mm.module_name, 0);
        if (g_capture) |c| {
            c.logCall(.win_query, args);
            @memset(mm.store[out_ptr .. out_ptr + 32], c.out_fill);
            return importRet(c.returns[@backingInt(CapId.win_query)]);
        }
        const r = win_query(argU64(args, 0), &g_stage_info);
        if (r == 0) stageOut(mm, out_ptr, g_stage_info[0..32]);
        return importRet(@intCast(r));
    }
    if (std.mem.eql(u8, name, "win_set_visible")) {
        if (g_capture) |c| {
            c.logCall(.win_set_visible, args);
            return importRet(c.returns[@backingInt(CapId.win_set_visible)]);
        }
        return importRet(win_set_visible(argU64(args, 0), argU64(args, 1)));
    }

    // -- §5.3 audio -------------------------------------------------------
    if (std.mem.eql(u8, name, "audio_info")) {
        const out_ptr = argPtr(args, 0);
        if (!checkRange(mm, out_ptr, 16)) return mkTrap(.bounds, mm.module_name, 0);
        if (g_capture) |c| {
            c.logCall(.audio_info, args);
            @memset(mm.store[out_ptr .. out_ptr + 16], c.out_fill);
            return importRet(c.returns[@backingInt(CapId.audio_info)]);
        }
        const r = audio_info(&g_stage_info);
        if (r == 0) stageOut(mm, out_ptr, g_stage_info[0..16]);
        return importRet(@intCast(r));
    }
    if (std.mem.eql(u8, name, "audio_play")) {
        const buf_ptr = argPtr(args, 0);
        const raw_len = @as(u32, @bitCast(args[1].i32));
        if (g_capture) |c| {
            c.logCall(.audio_play, args);
            return importRet(c.returns[@backingInt(CapId.audio_play)]);
        }
        // Kernel slot 43: zero -> einval, > audio_max_len -> enametoolong.
        if (raw_len == 0) return importRet(-1);
        if (raw_len > audio_max_len) return importRet(-8);
        var off: u32 = 0;
        while (off < raw_len) {
            const chunk: u32 = @min(raw_len - off, audio_period_len);
            const staged = stageIn(mm, buf_ptr + off, chunk, &g_stage_audio) orelse return mkTrap(.bounds, mm.module_name, 0);
            const r = audio_play(staged);
            if (r < 0) return importRet(@intCast(r));
            off += chunk;
        }
        return importRet(@intCast(raw_len));
    }
    if (std.mem.eql(u8, name, "audio_volume")) {
        if (g_capture) |c| {
            c.logCall(.audio_volume, args);
            return importRet(c.returns[@backingInt(CapId.audio_volume)]);
        }
        return importRet(audio_volume(argU64(args, 0)));
    }
    if (std.mem.eql(u8, name, "audio_mute")) {
        if (g_capture) |c| {
            c.logCall(.audio_mute, args);
            return importRet(c.returns[@backingInt(CapId.audio_mute)]);
        }
        return importRet(audio_mute(argU64(args, 0)));
    }

    // -- §5.4 timers ------------------------------------------------------
    if (std.mem.eql(u8, name, "timer_set")) {
        if (g_capture) |c| {
            c.logCall(.timer_set, args);
            return importRet(c.returns[@backingInt(CapId.timer_set)]);
        }
        return importRet(timer_set(argU64(args, 0)));
    }
    if (std.mem.eql(u8, name, "timer_cancel")) {
        if (g_capture) |c| {
            c.logCall(.timer_cancel, args);
            return importRet(c.returns[@backingInt(CapId.timer_cancel)]);
        }
        return importRet(timer_cancel());
    }

    // -- §5.5 mmap arena --------------------------------------------------
    if (std.mem.eql(u8, name, "mmap")) {
        if (g_capture) |c| {
            c.logCall(.mmap, args);
            return importRet(c.returns[@backingInt(CapId.mmap)]);
        }
        return importRet(mmap(
            argU64(args, 0),
            argU64(args, 1),
            argU64(args, 2),
            argU64(args, 3),
        ));
    }
    if (std.mem.eql(u8, name, "munmap")) {
        if (g_capture) |c| {
            c.logCall(.munmap, args);
            return importRet(c.returns[@backingInt(CapId.munmap)]);
        }
        return importRet(munmap(argU64(args, 0), argU64(args, 1)));
    }

    // -- §5.6/5.7 procs + wait -------------------------------------------
    if (std.mem.eql(u8, name, "procs")) {
        const buf_ptr = argPtr(args, 0);
        const max: u32 = @bitCast(args[1].i32);
        if (max != 0 and !checkRange(mm, buf_ptr, max)) return mkTrap(.bounds, mm.module_name, 0);
        if (g_capture) |c| {
            c.logCall(.procs, args);
            const n = c.returns[@backingInt(CapId.procs)];
            if (n > 0) captureFill(mm, buf_ptr, @as(u64, @intCast(n)) * 40, c.out_fill);
            return importRet(n);
        }
        // Kernel slot 7: byte-budget max, rows floored to whole 40-byte rows.
        if (max == 0) return importRet(0);
        const budget: u64 = @min(@as(u64, max), stage_dir_len);
        const r = procs(&g_stage_dir, budget);
        if (r > 0) stageOut(mm, buf_ptr, g_stage_dir[0 .. @as(usize, @intCast(r)) * 40]);
        return importRet(@intCast(r));
    }
    if (std.mem.eql(u8, name, "wait")) {
        if (g_capture) |c| {
            c.logCall(.wait, args);
            return importRet(c.returns[@backingInt(CapId.wait)]);
        }
        return importRet(wait(argU64(args, 0)));
    }

    return mkTrap(.imported_unwired, mm.module_name, 0);
}

/// The interpreter's fixed state lives in .bss (never the 32 KiB EL0
/// stack): the parsed module, the machine, and the module binary buffer.
/// The linear-memory store is the only large region and it is mmap'd.
const max_module_size: usize = 64 * 1024;
var g_module: Module = undefined;
var g_mod_buf: [max_module_size]u8 = undefined;
var g_path_buf: [64]u8 = undefined;

fn entryExport(m: *const Module) ?u32 {
    var main: ?u32 = null;
    var start: ?u32 = null;
    for (m.exports[0..m.export_count]) |e| {
        if (e.kind != .func) continue;
        if (std.mem.eql(u8, e.name, "main")) main = e.index;
        if (std.mem.eql(u8, e.name, "_start")) start = e.index;
    }
    return main orelse start;
}

pub export fn _start(argc: usize, argv: ?[*]const [256]u8) callconv(.c) noreturn {
    if (argc < 1 or argv == null) fail("wasm: usage: exec WASM.BIN <module.wasm>\n", 2);
    const slot = argv.?[0];
    const name_len = std.mem.indexOfScalar(u8, &slot, 0) orelse slot.len;
    const name = slot[0..name_len];
    const path = std.fmt.bufPrint(&g_path_buf, "/host/{s}", .{name}) catch fail("wasm: module name too long\n", 2);

    const fd = file_open(path, MODE_READ);
    if (fd < 0) fail("wasm: open failed\n", 3);
    var n: usize = 0;
    while (true) {
        if (n >= g_mod_buf.len) fail("wasm: module too large\n", 4);
        const r = file_read(@intCast(fd), g_mod_buf[n..]);
        if (r <= 0) break;
        n += @intCast(r);
    }
    _ = file_close(@intCast(fd));
    if (n == 0) fail("wasm: empty module\n", 4);

    // Contract v2 (§9) refusals are NAMED on the serial, with their own exit
    // status: a module rejected by the ABI gate is a named refusal, never a
    // trap inside the interpreter (M70e deliverable 4).
    parseInto(&g_module, g_mod_buf[0..n]) catch |e| switch (e) {
        error.UnsupportedAbiRevision => fail("wasm: abi: unsupported revision\n", 14),
        error.BadAbiSection => fail("wasm: abi: bad virelai.abi section\n", 15),
        else => fail("wasm: parse error\n", 10),
    };
    validate(&g_module) catch |e| switch (e) {
        error.UndeclaredCapability => fail("wasm: abi: undeclared capability\n", 16),
        else => fail("wasm: validate error\n", 11),
    };

    // §9.2 delivery admission: a v2 module runs only when the host share
    // vouches for it — same bytes, same revision, no capability escalation.
    // A v1 module (no `virelai.abi` section) keeps the legacy drop-and-exec
    // path: that is what makes v2 additive rather than a migration.
    if (g_module.abi_declared) {
        var digest: [32]u8 = undefined;
        sha256.sha256(&digest, g_mod_buf[0..n]);
        const row = findManifestRow(name);
        switch (admit(row, n, digest, g_module.abi_revision, usedCaps(&g_module))) {
            .ok => {},
            .no_row => fail("wasm: manifest: no row\n", 17),
            .size => fail("wasm: manifest: size mismatch\n", 18),
            .digest => fail("wasm: manifest: digest mismatch\n", 19),
            .revision => fail("wasm: manifest: abi revision mismatch\n", 20),
            .capability => fail("wasm: manifest: capability not granted\n", 21),
        }
    }

    // Linear memory: mmap'd (M29 anonymous, zero-filled COW), never .bss.
    const store_len: usize = max_mem_pages * page_size; // 2 MiB hard cap (D2)
    const mem = mmap(0, store_len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS);
    if (mem < 0) fail("wasm: mmap failed\n", 5);
    const store: []u8 = @as([*]u8, @ptrFromInt(@as(usize, @intCast(mem))))[0..store_len];

    if (instantiate(&machine, &g_module, store, name)) |trap| {
        _ = trap;
        fail("wasm: instantiate trap\n", 12);
    }
    const entry = entryExport(&g_module) orelse fail("wasm: no entry export\n", 13);
    switch (call(&machine, &g_module, entry, &.{})) {
        .ret => sys_exit(0),
        .trap => |tr| {
            var trap_line: [trap_line_len]u8 = undefined;
            fail(formatExecTrapLine(&trap_line, tr) orelse "wasm: trap during exec\n", 3);
        },
    }
}

// ---------------------------------------------------------------------------
// Host tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "parse: rejects bad magic/version" {
    try testing.expectError(error.BadMagic, parse("AAAA"));
    try testing.expectError(error.BadVersion, parse("\x00asm\x02\x00\x00\x00"));
}

test "parse: rejects truncated and unknown sections" {
    try testing.expectError(error.Truncated, parse("\x00asm\x01\x00\x00\x00\x01\x0A"));
    try testing.expectError(error.UnknownSection, parse("\x00asm\x01\x00\x00\x00\x63\x00"));
}

test "parse: sleb decodes 10-byte i64s and rejects an 11th byte (#1519)" {
    // Canonical i64 min: 9 continuation bytes + 0x7f. The old u6 `shift`
    // wrapped 63 + 7 — safe builds panicked, release builds decoded -64.
    var min = Reader{ .bytes = "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x7f" };
    try testing.expectEqual(std.math.minInt(i64), try min.sleb());
    // A 9-byte negative lands its sign at bit 63: `-(i64 1 << 63)` is unary
    // minus overflow; -% keeps the OR mask bit-exact.
    var neg9 = Reader{ .bytes = "\x80\x80\x80\x80\x80\x80\x80\x80\x40" };
    try testing.expectEqual(@as(i64, -4611686018427387904), try neg9.sleb());
    // The pinned Elk-style positive 10-byte constant.
    var big = Reader{ .bytes = "\x80\x80\x80\x80\x80\x80\xc0\xf9\xff\x00" };
    try testing.expectEqual(@as(i64, 0x7ff3000000000000), try big.sleb());
    // 11 bytes is over-long for i64; the old guard could never fire.
    var long = Reader{ .bytes = "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x00" };
    try testing.expectError(error.MalformedLeb, long.sleb());
}

test "w4: f64 type section parses + validates (W4 acceptance)" {
    // type section: one ( ) -> (f64) func type — the W1b reject now accepts
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7c";
    var m = try parse(bytes);
    try validate(&m);
}

test "w4: f64 scale — mul/add with consts (clang-probe shapes, byte-exact)" {
    // (func (export "scale") (param f64) (result f64)
    //   local.get 0  f64.const 0.5  f64.mul  f64.const 1.25  f64.add)
    // f64.mul = 0xA2, f64.add = 0xA0 (verified against zig cc output)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x06\x01\x60\x01\x7c\x01\x7c" ++
        "\x03\x02\x01\x00" ++
        "\x07\x09\x01\x05\x73\x63\x61\x6c\x65\x00\x00" ++
        "\x0a\x1a\x01\x18\x00" ++
        "\x20\x00\x44\x00\x00\x00\x00\x00\x00\xe0\x3f\xa2" ++
        "\x44\x00\x00\x00\x00\x00\x00\xf4\x3f\xa0\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "scale") == null);
    const r = call(&machine, &m, 0, &.{.{ .f64 = 2.0 }});
    try testing.expect(r == .ret);
    try testing.expectEqual(@as(f64, 2.25), r.ret.vals[0].f64);
}

test "w4: f32 div — f32.const + f32.div (0x95), IEEE result" {
    // (func (export "rec") (param f32) (result f32)
    //   f32.const 1.0f  local.get 0  f32.div)   -- 1/x, so x=0 hits div-by-zero
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x06\x01\x60\x01\x7d\x01\x7d" ++
        "\x03\x02\x01\x00" ++
        "\x07\x07\x01\x03\x72\x65\x63\x00\x00" ++
        "\x0a\x0c\x01\x0a\x00\x43\x00\x00\x80\x3f\x20\x00\x95\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "rec") == null);
    const r = call(&machine, &m, 0, &.{.{ .f32 = 2.0 }});
    try testing.expect(r == .ret);
    try testing.expectEqual(@as(f32, 0.5), r.ret.vals[0].f32);
    // div by zero is NOT a trap: +inf per IEEE
    const ri = call(&machine, &m, 0, &.{.{ .f32 = 0.0 }});
    try testing.expect(ri == .ret);
    try testing.expectEqual(std.math.inf(f32), ri.ret.vals[0].f32);
}

test "w4: trunc_sat (0xFC 2) saturates — NaN→0, overflow clamps, never traps" {
    // clang lowers C float->int casts to the 0xFC trunc_sat forms (the
    // nontrapping-float-to-int opcodes) — i32.trunc_sat_f64_s = 0xFC 2.
    // (func (export "tr") (param f64) (result i32)
    //   local.get 0  i32.trunc_sat_f64_s)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x06\x01\x60\x01\x7c\x01\x7f" ++
        "\x03\x02\x01\x00" ++
        "\x07\x06\x01\x02\x74\x72\x00\x00" ++
        "\x0a\x08\x01\x06\x00\x20\x00\xfc\x02\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "tr") == null);
    const r = call(&machine, &m, 0, &.{.{ .f64 = 3.9 }});
    try testing.expect(r == .ret);
    try testing.expectEqual(@as(i32, 3), r.ret.vals[0].i32);
    const rn = call(&machine, &m, 0, &.{.{ .f64 = -3.9 }});
    try testing.expectEqual(@as(i32, -3), rn.ret.vals[0].i32);
    const rnan = call(&machine, &m, 0, &.{.{ .f64 = std.math.nan(f64) }});
    try testing.expect(rnan == .ret); // saturates: NaN -> 0, no trap
    try testing.expectEqual(@as(i32, 0), rnan.ret.vals[0].i32);
    const rhi = call(&machine, &m, 0, &.{.{ .f64 = 1e300 }});
    try testing.expect(rhi == .ret); // clamps to i32 max, no trap
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), rhi.ret.vals[0].i32);
    const rlo = call(&machine, &m, 0, &.{.{ .f64 = -1e300 }});
    try testing.expect(rlo == .ret);
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), rlo.ret.vals[0].i32);
}

test "w4: plain trunc (0xA8 i32.trunc_f32_s) traps on NaN/overflow" {
    // The plain (trapping) trunc family lives at 0xA8/0xA9/0xAA/0xAB
    // (to i32) and 0xAE..0xB1 (to i64) — 0xAC/0xAD are the i64.extend
    // ops, NOT truncs (a misread of the opcode table the floatapp gate
    // flushed out). floatapp carries 0xA8-adjacent plain truncs where
    // clang can prove the value is in range.
    // (func (export "tr") (param f32) (result i32)
    //   local.get 0  i32.trunc_f32_s)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x06\x01\x60\x01\x7d\x01\x7f" ++
        "\x03\x02\x01\x00" ++
        "\x07\x06\x01\x02\x74\x72\x00\x00" ++
        "\x0a\x07\x01\x05\x00\x20\x00\xa8\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "trp") == null);
    const r = call(&machine, &m, 0, &.{.{ .f32 = 3.9 }});
    try testing.expect(r == .ret);
    try testing.expectEqual(@as(i32, 3), r.ret.vals[0].i32);
    const rt = call(&machine, &m, 0, &.{.{ .f32 = std.math.nan(f32) }});
    try testing.expect(rt == .trap and rt.trap.kind == .invalid_conv);
    const ro = call(&machine, &m, 0, &.{.{ .f32 = 1e30 }});
    try testing.expect(ro == .trap and ro.trap.kind == .invalid_conv);
}

test "w4: i64.extend_i32_s/u (0xAC/0xAD) widen with the right sign" {
    // (func (export "s") (param i32) (result i64)
    //   local.get 0  i64.extend_i32_s)
    const sb = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x06\x01\x60\x01\x7f\x01\x7e" ++
        "\x03\x02\x01\x00" ++
        "\x07\x05\x01\x01\x73\x00\x00" ++
        "\x0a\x07\x01\x05\x00\x20\x00\xac\x0b";
    var ms = try parse(sb);
    try validate(&ms);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &ms, &store, "exts") == null);
    const r1 = call(&machine, &ms, 0, &.{.{ .i32 = -1 }});
    try testing.expectEqual(@as(i64, -1), r1.ret.vals[0].i64);
    const r2 = call(&machine, &ms, 0, &.{.{ .i32 = std.math.minInt(i32) }});
    try testing.expectEqual(@as(i64, -2147483648), r2.ret.vals[0].i64);
    // (func (export "u") (param i32) (result i64)
    //   local.get 0  i64.extend_i32_u)
    const ub = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x06\x01\x60\x01\x7f\x01\x7e" ++
        "\x03\x02\x01\x00" ++
        "\x07\x05\x01\x01\x75\x00\x00" ++
        "\x0a\x07\x01\x05\x00\x20\x00\xad\x0b";
    var mu = try parse(ub);
    try validate(&mu);
    try testing.expect(instantiate(&machine, &mu, &store, "extu") == null);
    const r3 = call(&machine, &mu, 0, &.{.{ .i32 = -1 }});
    try testing.expectEqual(@as(i64, 4294967295), r3.ret.vals[0].i64);
}

test "w4: f64.convert_i64_s (0xB9) exact-via-rounding + f64.reinterpret_i64 (0xBF)" {
    // (func (export "i2d") (param i64) (result f64)
    //   local.get 0  f64.convert_i64_s)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x06\x01\x60\x01\x7e\x01\x7c" ++
        "\x03\x02\x01\x00" ++
        "\x07\x07\x01\x03\x69\x32\x64\x00\x00" ++
        "\x0a\x07\x01\x05\x00\x20\x00\xb9\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "i2d") == null);
    const r = call(&machine, &m, 0, &.{.{ .i64 = 42 }});
    try testing.expect(r == .ret);
    try testing.expectEqual(@as(f64, 42.0), r.ret.vals[0].f64);
    // maxInt(i64) rounds to 2^63 in f64
    const r2 = call(&machine, &m, 0, &.{.{ .i64 = std.math.maxInt(i64) }});
    try testing.expectEqual(@as(f64, 9223372036854775808.0), r2.ret.vals[0].f64);
}

test "w4: float comparisons — NaN semantics (ne true, ordered false)" {
    // (func (export "ne") (param f64 f64) (result i32)
    //   local.get 0  local.get 1  f64.ne)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x07\x01\x60\x02\x7c\x7c\x01\x7f" ++
        "\x03\x02\x01\x00" ++
        "\x07\x06\x01\x02\x6e\x65\x00\x00" ++
        "\x0a\x09\x01\x07\x00\x20\x00\x20\x01\x62\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "ne") == null);
    const nan = std.math.nan(f64);
    const r1 = call(&machine, &m, 0, &.{ .{ .f64 = nan }, .{ .f64 = 1.0 } });
    try testing.expectEqual(@as(i32, 1), r1.ret.vals[0].i32); // NaN != x
    const r2 = call(&machine, &m, 0, &.{ .{ .f64 = 1.0 }, .{ .f64 = 1.0 } });
    try testing.expectEqual(@as(i32, 0), r2.ret.vals[0].i32);
}

test "w4: f64.store/load round-trip (clang-probe memarg shape: align 3)" {
    // (func (export "rt") (result i32) (memory 1)
    //   i32.const 0  f64.const 1.5  f64.store align=3
    //   i32.const 0  f64.load align=3  f64.const 1.5  f64.eq)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++
        "\x03\x02\x01\x00" ++
        "\x05\x03\x01\x00\x01" ++
        "\x07\x06\x01\x02\x72\x74\x00\x00" ++
        "\x0a\x21\x01\x1f\x00" ++
        "\x41\x00\x44\x00\x00\x00\x00\x00\x00\xf8\x3f\x39\x03\x00" ++
        "\x41\x00\x2b\x03\x00\x44\x00\x00\x00\x00\x00\x00\xf8\x3f\x61\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "rt") == null);
    const r = call(&machine, &m, 0, &.{});
    try testing.expect(r == .ret);
    try testing.expectEqual(@as(i32, 1), r.ret.vals[0].i32);
}

test "w4: bulk-memory — memory.init/copy/fill with passive data + DataCount" {
    // (memory 1) (data passive "\x01\x02\x03\x04\x05\x06\x07\x08\x09")
    // (func (export "go")
    //   (memory.init 0 (i32.const 0) (i32.const 0) (i32.const 9))  ;; mem[0..9)=1..9
    //   (memory.copy  (i32.const 1) (i32.const 0) (i32.const 7))   ;; right-shift: memmove
    //   (memory.fill  (i32.const 32) (i32.const 0x37) (i32.const 5)))
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x04\x01\x60\x00\x00" ++
        "\x03\x02\x01\x00" ++
        "\x05\x03\x01\x00\x01" ++
        "\x07\x06\x01\x02\x67\x6f\x00\x00" ++
        "\x0c\x01\x01" ++
        "\x0a\x21\x01\x1f\x00" ++
        "\x41\x00\x41\x00\x41\x09\xfc\x08\x00\x00" ++
        "\x41\x01\x41\x00\x41\x07\xfc\x0a\x00\x00" ++
        "\x41\x20\x41\x37\x41\x05\xfc\x0b\x00\x0b" ++
        "\x0b\x0c\x01\x01\x09\x01\x02\x03\x04\x05\x06\x07\x08\x09";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    @memset(&store, 0xEE); // poison: passive data must NOT land at instantiate
    try testing.expect(instantiate(&machine, &m, &store, "bulk1") == null);
    try testing.expect(std.mem.eql(u8, store[0..8], &[_]u8{ 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE }));
    const r = call(&machine, &m, 0, &.{});
    try testing.expect(r == .ret);
    // init placed 1..9 at [0..9); the right-shift copy is memmove-correct:
    // [1..8) = [0..7) = 1,2,3,4,5,6,7, so index 8 keeps init's 9th byte (9):
    // 1,1,2,3,4,5,6,7,9 (a forward memcpy would smear 1s leftward). The 9
    // at index 8 also proves init wrote all 9 bytes and copy never touched
    // [8..). Fill wrote 0x37 x5 at [32..37).
    try testing.expect(std.mem.eql(u8, store[0..9], &[_]u8{ 1, 1, 2, 3, 4, 5, 6, 7, 9 }));
    try testing.expect(std.mem.eql(u8, store[32..37], &[_]u8{ 0x37, 0x37, 0x37, 0x37, 0x37 }));
}

test "w4: bulk-memory — data.drop makes later memory.init trap bounds" {
    // passive data "\x2a"; (func (export "boom")
    //   (memory.init 0 (i32.const 0) (i32.const 0) (i32.const 1))
    //   (data.drop 0)
    //   (memory.init 0 (i32.const 0) (i32.const 0) (i32.const 1)))  ;; dropped -> trap
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x04\x01\x60\x00\x00" ++
        "\x03\x02\x01\x00" ++
        "\x05\x03\x01\x00\x01" ++
        "\x07\x08\x01\x04\x62\x6f\x6f\x6d\x00\x00" ++
        "\x0c\x01\x01" ++
        "\x0a\x1b\x01\x19\x00" ++
        "\x41\x00\x41\x00\x41\x01\xfc\x08\x00\x00" ++
        "\xfc\x09\x00" ++
        "\x41\x00\x41\x00\x41\x01\xfc\x08\x00\x00\x0b" ++
        "\x0b\x04\x01\x01\x01\x2a";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "boom") == null);
    const r = call(&machine, &m, 0, &.{});
    try testing.expect(r == .trap and r.trap.kind == .bounds);
}

test "w4: bulk-memory — memory.init without DataCount fails validation" {
    // same body as bulk1's init but NO DataCount section: spec requires it
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x04\x01\x60\x00\x00" ++
        "\x03\x02\x01\x00" ++
        "\x05\x03\x01\x00\x01" ++
        "\x0a\x0e\x01\x0c\x00\x41\x00\x41\x00\x41\x08\xfc\x08\x00\x00\x0b" ++
        "\x0b\x0b\x01\x01\x08\x01\x02\x03\x04\x05\x06\x07\x08";
    var m = try parse(bytes);
    try testing.expectError(error.DataCountMissing, validate(&m));
}

test "w4: bulk-memory — DataCount count must match the data section" {
    // datacount declares 2 but the data section holds 1 passive segment
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x0c\x01\x02" ++
        "\x0b\x04\x01\x01\x01\x2a";
    try testing.expectError(error.DataCountMismatch, parse(bytes));
}

test "w4: bulk-memory — table ops (0xFC 12+) still out of subset" {
    // (func (result i32) i32.const 0 table.size 0)? -> table.size = 0xFC 16;
    // validation must reject any 0xFC sub >= 12 with BulkMemoryOutOfSubset
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x00\x01\x7f" ++
        "\x03\x02\x01\x00" ++
        "\x0a\x09\x01\x07\x00\x41\x00\xfc\x10\x00\x0b";
    var m = try parse(bytes);
    try testing.expectError(error.BulkMemoryOutOfSubset, validate(&m));
}

test "w4: sign-extension ops 0xC0-0xC4 execute (W3 left them fixture-less)" {
    // five exports over (i32->i32) type 0 / (i64->i64) type 1:
    // e8 = i32.extend8_s(0xC0), e16 = i32.extend16_s(0xC1),
    // x8 = i64.extend8_s(0xC2), x16 = i64.extend16_s(0xC3),
    // x32 = i64.extend32_s(0xC4)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x0b\x02\x60\x01\x7f\x01\x7f\x60\x01\x7e\x01\x7e" ++
        "\x03\x06\x05\x00\x00\x01\x01\x01" ++
        "\x07\x1d\x05" ++
        "\x02\x65\x38\x00\x00" ++
        "\x03\x65\x31\x36\x00\x01" ++
        "\x02\x78\x38\x00\x02" ++
        "\x03\x78\x31\x36\x00\x03" ++
        "\x03\x78\x33\x32\x00\x04" ++
        "\x0a\x1f\x05" ++
        "\x05\x00\x20\x00\xc0\x0b" ++
        "\x05\x00\x20\x00\xc1\x0b" ++
        "\x05\x00\x20\x00\xc2\x0b" ++
        "\x05\x00\x20\x00\xc3\x0b" ++
        "\x05\x00\x20\x00\xc4\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "sext") == null);
    const e8 = call(&machine, &m, 0, &.{.{ .i32 = 0x80 }});
    try testing.expectEqual(@as(i32, -128), e8.ret.vals[0].i32);
    const e16 = call(&machine, &m, 1, &.{.{ .i32 = 0x8000 }});
    try testing.expectEqual(@as(i32, -32768), e16.ret.vals[0].i32);
    const x8 = call(&machine, &m, 2, &.{.{ .i64 = 0x80 }});
    try testing.expectEqual(@as(i64, -128), x8.ret.vals[0].i64);
    const x16 = call(&machine, &m, 3, &.{.{ .i64 = 0x8000 }});
    try testing.expectEqual(@as(i64, -32768), x16.ret.vals[0].i64);
    const x32 = call(&machine, &m, 4, &.{.{ .i64 = 0x8000_0000 }});
    try testing.expectEqual(@as(i64, -2147483648), x32.ret.vals[0].i64);
}

test "exec: add module returns deterministic sums" {
    // (func (export "add3") (param i64 i64 i64) (result i64)
    //   local.get 0  local.get 1  i64.add  local.get 2  i64.add)
    // (module (type (;0;) (func (param i64 i64 i64) (result i64)))
    //   (func (;0;) (type 0) (param i64 i64 i64) (result i64)
    //     local.get 0  local.get 1  i64.add  local.get 2  i64.add)
    //   (export "add3" (func 0)))
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x08\x01\x60\x03\x7e\x7e\x7e\x01\x7e\x03\x02\x01\x00\x07\x08\x01\x04\x61\x64\x64\x33\x00\x00\x0a\x0c\x01\x0a\x00\x20\x00\x20\x01\x7c\x20\x02\x7c\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    const inst = instantiate(&machine, &m, &store, "add3");
    try testing.expect(inst == null);
    const r = call(&machine, &m, 0, &.{ .{ .i64 = 2 }, .{ .i64 = 3 }, .{ .i64 = 4 } });
    try testing.expect(r == .ret);
    try testing.expectEqual(@as(i64, 9), r.ret.vals[0].i64);
    // deterministic: second run yields the same
    const r2 = call(&machine, &m, 0, &.{ .{ .i64 = 2 }, .{ .i64 = 3 }, .{ .i64 = 4 } });
    try testing.expect(r2 == .ret);
    try testing.expectEqual(@as(i64, 9), r2.ret.vals[0].i64);
}

test "exec: loop + br_if computes factorial" {
    // (func (export "fact") (param $n i64) (result i64)
    //   (local $acc i64) (local $i i64)
    //   i64.const 1  local.set 1        ;; acc = 1
    //   i64.const 1  local.set 2        ;; i = 1
    //   block
    //     loop
    //       local.get 2  local.get 0  i64.ge_u   ;; i >= n?
    //       br_if 1
    //       local.get 1  local.get 2  i64.mul  local.set 1   ;; acc *= i
    //       local.get 2  i64.const 1  i64.add  local.set 2   ;; i++
    //       br 0
    //     end
    //   end
    //   local.get 1)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7e\x01\x7e\x03\x02\x01\x00\x07\x08\x01\x04\x66\x61\x63\x74\x00\x00\x0a\x2f\x01\x2d\x02\x01\x7e\x01\x7e\x42\x01\x21\x01\x42\x01\x21\x02\x02\x40\x03\x40\x20\x02\x20\x00\x56\x0d\x01\x20\x01\x20\x02\x7e\x21\x01\x20\x02\x42\x01\x7c\x21\x02\x0c\x00\x0b\x0b\x20\x01\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "fact") == null);
    const r = call(&machine, &m, 0, &.{.{ .i64 = 5 }});
    try testing.expect(r == .ret);
    try testing.expectEqual(@as(i64, 120), r.ret.vals[0].i64);
    const r0 = call(&machine, &m, 0, &.{.{ .i64 = 0 }});
    try testing.expectEqual(@as(i64, 1), r0.ret.vals[0].i64);
}

test "exec: unreachable traps with module + offset" {
    // (func (export "boom") (unreachable))
    // (module (type (;0;) (func))
    //   (func (;0;) (type 0) unreachable)
    //   (export "boom" (func 0)))
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00\x07\x08\x01\x04\x62\x6f\x6f\x6d\x00\x00\x0a\x05\x01\x03\x00\x00\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "boom") == null);
    const r = call(&machine, &m, 0, &.{});
    try testing.expect(r == .trap);
    try testing.expectEqual(TrapKind.@"unreachable", r.trap.kind);
    try testing.expectEqualStrings("boom", r.trap.module);
    // The `unreachable` opcode is at byte 33 of the module (8 magic/version +
    // type 6 + func 4 + export 10 + code id/size + count + body size +
    // locals count) — a MODULE offset, not an offset into the code-section
    // payload (M70d #1518).
    try testing.expectEqual(@as(usize, 33), r.trap.offset);
}

test "exec trap line names the class, module and offset (#1518)" {
    var buf: [trap_line_len]u8 = undefined;
    const line = formatExecTrapLine(&buf, .{
        .kind = .call_depth,
        .module = "ELK.WASM",
        .offset = 0x1a2b,
    }) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(
        "wasm: trap during exec kind=call_depth module=ELK.WASM offset=0x1a2b\n",
        line,
    );
    var tiny: [8]u8 = undefined;
    try testing.expect(formatExecTrapLine(&tiny, .{ .kind = .bounds, .module = "m", .offset = 0 }) == null);
}

test "exec: div by zero traps (i32.div_s)" {
    // (func (export "div") (param i32 i32) (result i32)
    //   local.get 0  local.get 1  i32.div_s)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x07\x01\x60\x02\x7f\x7f\x01\x7f" ++
        "\x03\x02\x01\x00" ++
        "\x07\x07\x01\x03" ++ "div" ++ "\x00\x00" ++
        "\x0a\x09\x01\x07\x00\x20\x00\x20\x01\x6d\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "div") == null);
    const r = call(&machine, &m, 0, &.{ .{ .i32 = 7 }, .{ .i32 = 0 } });
    try testing.expect(r == .trap);
    try testing.expectEqual(TrapKind.div_by_zero, r.trap.kind);
    const ok = call(&machine, &m, 0, &.{ .{ .i32 = 7 }, .{ .i32 = 2 } });
    try testing.expect(ok == .ret);
    try testing.expectEqual(@as(i32, 3), ok.ret.vals[0].i32);
}

test "exec: memory load/store round-trip and bounds trap" {
    // (func (export "store") (param i32 i64) local.get 0 local.get 1 i64.store)
    // (func (export "load") (param i32) (result i64) local.get 0 i64.load)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x0b\x02\x60\x02\x7f\x7e\x00\x60\x01\x7f\x01\x7e\x03\x03\x02\x00\x01\x05\x03\x01\x00\x01\x07\x10\x02\x05\x73\x74\x6f\x72\x65\x00\x00\x04\x6c\x6f\x61\x64\x00\x01\x0a\x13\x02\x09\x00\x20\x00\x20\x01\x37\x01\x00\x0b\x07\x00\x20\x00\x29\x03\x00\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [2 * page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "mem") == null);
    const s = call(&machine, &m, 0, &.{ .{ .i32 = 100 }, .{ .i64 = 0xDEAD_BEEF } });
    try testing.expect(s == .ret);
    const l = call(&machine, &m, 1, &.{.{ .i32 = 100 }});
    try testing.expect(l == .ret);
    try testing.expectEqual(@as(i64, 0xDEAD_BEEF), l.ret.vals[0].i64);
    // bounds trap: 8-byte load at 65530 straddles the 1-page (65536) end.
    // (65528 would be exactly in-bounds: 65528+8 == 65536.)
    const bo = call(&machine, &m, 1, &.{.{ .i32 = 65530 }});
    try testing.expect(bo == .trap);
    try testing.expectEqual(TrapKind.bounds, bo.trap.kind);
}

test "exec: memory.grow within cap, traps beyond (no unbounded mmap)" {
    // (func (export "grow") (param i32) (result i32) local.get 0 memory.grow)
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x03\x02\x01\x00\x05\x04\x01\x01\x01\x02\x07\x08\x01\x04\x67\x72\x6f\x77\x00\x00\x0a\x08\x01\x06\x00\x20\x00\x40\x00\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined; // only 1 page of backing
    try testing.expect(instantiate(&machine, &m, &store, "grow") == null);
    try testing.expectEqual(@as(u32, 1), machine.mem_pages);
    // grow(0) returns current pages (spec behavior)
    const g0 = call(&machine, &m, 0, &.{.{ .i32 = 0 }});
    try testing.expect(g0 == .ret);
    try testing.expectEqual(@as(i32, 1), g0.ret.vals[0].i32);
    // grow(1) exceeds max(2) pages of backing store => trap
    const g1 = call(&machine, &m, 0, &.{.{ .i32 = 1 }});
    try testing.expect(g1 == .trap);
    try testing.expectEqual(TrapKind.grow_limit, g1.trap.kind);
}

test "exec: call_indirect type-check traps on mismatch" {
    // types: 0 (i64)->i64, 1 ()->()
    // func 0: (export "f") (i64)->i64 { local.get 0 i64.const 1 i64.add }
    // func 1: (export "g") ()->() {}
    // table 1 funcref (min 2), element: [func 0, func 1]
    // (export "callit") (param i32 i64) (result i64) {
    //   local.get 1  local.get 0  call_indirect (type 0) }
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x0f\x03\x60\x01\x7e\x01\x7e\x60\x00\x00\x60\x02\x7f\x7e\x01\x7e\x03\x04\x03\x00\x01\x02\x04\x04\x01\x70\x00\x02\x07\x12\x03\x01\x66\x00\x00\x01\x67\x00\x01\x06\x63\x61\x6c\x6c\x69\x74\x00\x02\x09\x08\x01\x00\x41\x00\x0b\x02\x00\x01\x0a\x16\x03\x07\x00\x20\x00\x42\x01\x7c\x0b\x02\x00\x0b\x09\x00\x20\x01\x20\x00\x11\x00\x00\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "ci") == null);
    // table[0] = func 0 (i64)->(i64): call with type 0 succeeds
    const ok = call(&machine, &m, 2, &.{ .{ .i32 = 0 }, .{ .i64 = 41 } });
    try testing.expect(ok == .ret);
    try testing.expectEqual(@as(i64, 42), ok.ret.vals[0].i64);
    // table[1] = func 1 ()->(): type 0 expected -> mismatch trap
    const bad = call(&machine, &m, 2, &.{ .{ .i32 = 1 }, .{ .i64 = 0 } });
    try testing.expect(bad == .trap);
    try testing.expectEqual(TrapKind.call_indirect_type, bad.trap.kind);
    // table index OOB traps bounds
    const oob = call(&machine, &m, 2, &.{ .{ .i32 = 5 }, .{ .i64 = 0 } });
    try testing.expect(oob == .trap);
    try testing.expectEqual(TrapKind.bounds, oob.trap.kind);
}

test "exec: overlong-LEB call_indirect immediates stay in sync (claim 9746 find)" {
    // Same module as the type-check test above, but wasm-ld/LLVM encoded
    // call_indirect's TWO U32 immediates as legal overlong 5-byte LEBs
    // (`11 80 80 80 80 00 80 80 80 80 00`). The interpreter used to read
    // the tableidx as ONE byte, desynced into the middle of the LEB, and
    // misread 0x80 (i64.div_u) as the next opcode on an empty stack — a
    // false TypeMismatch at validate. rustc-built modules (claim 9746's
    // nl.wasm) carry exactly this encoding; clang/zig-cc emit minimal
    // LEBs so the W2-W5 C fixtures never exposed it. Validate must
    // consume BOTH LEBs and the dispatch must still work.
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x0f\x03\x60\x01\x7e\x01\x7e\x60\x00\x00\x60\x02\x7f\x7e\x01\x7e\x03\x04\x03\x00\x01\x02\x04\x04\x01\x70\x00\x02\x07\x12\x03\x01\x66\x00\x00\x01\x67\x00\x01\x06\x63\x61\x6c\x6c\x69\x74\x00\x02\x09\x08\x01\x00\x41\x00\x0b\x02\x00\x01\x0a\x1e\x03\x07\x00\x20\x00\x42\x01\x7c\x0b\x02\x00\x0b\x11\x00\x20\x01\x20\x00\x11\x80\x80\x80\x80\x00\x80\x80\x80\x80\x00\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "ciover") == null);
    const ok = call(&machine, &m, 2, &.{ .{ .i32 = 0 }, .{ .i64 = 41 } });
    try testing.expect(ok == .ret);
    try testing.expectEqual(@as(i64, 42), ok.ret.vals[0].i64);
    const bad = call(&machine, &m, 2, &.{ .{ .i32 = 1 }, .{ .i64 = 0 } });
    try testing.expect(bad == .trap);
    try testing.expectEqual(TrapKind.call_indirect_type, bad.trap.kind);
}

test "corpus: hand-built fixture executes deterministically (byte-identical output)" {
    // The committed corpus module: user/src/wasm-corpus/fib-loop.wasm — the
    // same loop+br_if structure as the factorial test, selected by the
    // fixture README. This test loads it through @embedFile and runs it
    // twice, asserting identical results.
    const fixture = @embedFile("wasm-corpus/fib-loop.wasm");
    var m = try parse(fixture);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "fib-loop") == null);
    const a = call(&machine, &m, 0, &.{.{ .i64 = 7 }});
    const b = call(&machine, &m, 0, &.{.{ .i64 = 7 }});
    try testing.expect(a == .ret and b == .ret);
    try testing.expectEqual(a.ret.vals[0].i64, b.ret.vals[0].i64);
    try testing.expectEqual(@as(i64, 5040), a.ret.vals[0].i64); // 7!
}

test "w2: hello-env runs — env.write byte-exact, env.exit status observed" {
    // The committed W2 fixture (user/src/wasm-corpus/hello-env.wasm): the
    // C hello-world built on the HOST with `zig cc -target
    // wasm32-freestanding -nostdlib`, importing env.write/env.exit and
    // exporting _start. The interpreter dispatches the two imports (W2)
    // and the capture seam proves byte-exact write + observed exit status
    // without touching the console.
    const fixture = @embedFile("wasm-corpus/hello-env.wasm");
    var m = try parse(fixture);
    try validate(&m);
    var store: [max_mem_pages * page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "hello-env") == null);
    var capture_buf: [128]u8 = undefined;
    var cap = HostCapture{ .write_buf = &capture_buf };
    g_capture = &cap;
    defer g_capture = null;
    const entry = entryExport(&m).?;
    const r = call(&machine, &m, entry, &.{});
    switch (r) {
        .ret => {},
        // clang emits `unreachable` after the noreturn exit(55) call; the
        // captured exit stops the interpreter first (guest_exit marker).
        .trap => try testing.expectEqual(TrapKind.guest_exit, r.trap.kind),
    }
    try testing.expectEqualStrings("hello, wasm!\n", cap.write_buf[0..cap.wrote]);
    try testing.expect(cap.exited);
    try testing.expectEqual(@as(i32, 55), cap.exit_status);
}

test "w2: env.write with out-of-bounds pointer traps bounds" {
    // (import "env" "write" (func (param i32 i32 i32) (result i32)))
    // (func (export "_start")
    //   i32.const 1  i32.const 0x7fffffff  i32.const 4  call 0  drop)
    // No memory section: mem_pages == 0, so any write pointer traps.
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x0b\x02\x60\x03\x7f\x7f\x7f\x01\x7f\x60\x00\x00\x02\x0d\x01\x03\x65\x6e\x76\x05\x77\x72\x69\x74\x65\x00\x00\x03\x02\x01\x01\x07\x0a\x01\x06\x5f\x73\x74\x61\x72\x74\x00\x01\x0a\x11\x01\x0f\x00\x41\x01\x41\xff\xff\xff\xff\x07\x41\x04\x10\x00\x1a\x0b";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "oob") == null);
    const r = call(&machine, &m, entryExport(&m).?, &.{});
    try testing.expect(r == .trap);
    try testing.expectEqual(TrapKind.bounds, r.trap.kind);
}

// ---------------------------------------------------------------------------
// W3 (#764) — the frozen env.* import surface (docs/wasm-import-contract.md
// §5 + the W2 write/exit pair). Fixture modules are import-only (no code
// section): parse + validate + instantiate, then each import is called
// DIRECTLY by func index through the capture seam, which proves dispatch
// shape, argument extraction, range checks, and canned returns without a
// real svc #0 (undefinable in a host test).
// ---------------------------------------------------------------------------
const w3_all = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x2d\x07\x60\x03\x7f\x7f\x7f\x01\x7f\x60\x01\x7f\x00\x60\x01\x7f\x01\x7f\x60\x04\x7f\x7f\x7f\x7f\x01\x7f\x60\x02\x7f\x7f\x01\x7f\x60\x06\x7f\x7f\x7f\x7f\x7f\x7f\x01\x7f\x60\x00\x01\x7f\x02\xdc\x03\x1e\x03\x65\x6e\x76\x05\x77\x72\x69\x74\x65\x00\x00\x03\x65\x6e\x76\x04\x65\x78\x69\x74\x00\x01\x03\x65\x6e\x76\x09\x66\x69\x6c\x65\x5f\x6f\x70\x65\x6e\x00\x00\x03\x65\x6e\x76\x09\x66\x69\x6c\x65\x5f\x72\x65\x61\x64\x00\x00\x03\x65\x6e\x76\x0a\x66\x69\x6c\x65\x5f\x77\x72\x69\x74\x65\x00\x00\x03\x65\x6e\x76\x0a\x66\x69\x6c\x65\x5f\x63\x6c\x6f\x73\x65\x00\x02\x03\x65\x6e\x76\x08\x64\x69\x72\x5f\x6c\x69\x73\x74\x00\x03\x03\x65\x6e\x76\x0b\x66\x69\x6c\x65\x5f\x64\x65\x6c\x65\x74\x65\x00\x04\x03\x65\x6e\x76\x0b\x66\x69\x6c\x65\x5f\x72\x65\x6e\x61\x6d\x65\x00\x03\x03\x65\x6e\x76\x0d\x66\x69\x6c\x65\x5f\x74\x72\x75\x6e\x63\x61\x74\x65\x00\x04\x03\x65\x6e\x76\x09\x66\x69\x6c\x65\x5f\x66\x72\x65\x65\x00\x02\x03\x65\x6e\x76\x08\x77\x69\x6e\x5f\x6f\x70\x65\x6e\x00\x03\x03\x65\x6e\x76\x08\x77\x69\x6e\x5f\x66\x69\x6c\x6c\x00\x05\x03\x65\x6e\x76\x0b\x77\x69\x6e\x5f\x70\x72\x65\x73\x65\x6e\x74\x00\x02\x03\x65\x6e\x76\x09\x77\x69\x6e\x5f\x63\x6c\x6f\x73\x65\x00\x02\x03\x65\x6e\x76\x08\x77\x69\x6e\x5f\x6d\x6f\x76\x65\x00\x00\x03\x65\x6e\x76\x09\x77\x69\x6e\x5f\x72\x61\x69\x73\x65\x00\x02\x03\x65\x6e\x76\x07\x77\x69\x6e\x5f\x67\x65\x74\x00\x04\x03\x65\x6e\x76\x09\x77\x69\x6e\x5f\x71\x75\x65\x72\x79\x00\x04\x03\x65\x6e\x76\x0f\x77\x69\x6e\x5f\x73\x65\x74\x5f\x76\x69\x73\x69\x62\x6c\x65\x00\x04\x03\x65\x6e\x76\x0a\x61\x75\x64\x69\x6f\x5f\x69\x6e\x66\x6f\x00\x02\x03\x65\x6e\x76\x0a\x61\x75\x64\x69\x6f\x5f\x70\x6c\x61\x79\x00\x04\x03\x65\x6e\x76\x0c\x61\x75\x64\x69\x6f\x5f\x76\x6f\x6c\x75\x6d\x65\x00\x02\x03\x65\x6e\x76\x0a\x61\x75\x64\x69\x6f\x5f\x6d\x75\x74\x65\x00\x02\x03\x65\x6e\x76\x09\x74\x69\x6d\x65\x72\x5f\x73\x65\x74\x00\x02\x03\x65\x6e\x76\x0c\x74\x69\x6d\x65\x72\x5f\x63\x61\x6e\x63\x65\x6c\x00\x06\x03\x65\x6e\x76\x04\x6d\x6d\x61\x70\x00\x03\x03\x65\x6e\x76\x06\x6d\x75\x6e\x6d\x61\x70\x00\x04\x03\x65\x6e\x76\x05\x70\x72\x6f\x63\x73\x00\x04\x03\x65\x6e\x76\x04\x77\x61\x69\x74\x00\x02\x05\x03\x01\x00\x01";
const w3_foreign = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x08\x01\x60\x03\x7f\x7f\x7f\x01\x7f\x02\x23\x01\x16\x77\x61\x73\x69\x5f\x73\x6e\x61\x70\x73\x68\x6f\x74\x5f\x70\x72\x65\x76\x69\x65\x77\x31\x08\x66\x64\x5f\x77\x72\x69\x74\x65\x00\x00";
const w3_unknown = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x02\x0c\x01\x03\x65\x6e\x76\x04\x6e\x6f\x70\x65\x00\x00\x05\x03\x01\x00\x01";
const w3_badsig = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x02\x10\x01\x03\x65\x6e\x76\x08\x77\x69\x6e\x5f\x6f\x70\x65\x6e\x00\x00\x05\x03\x01\x00\x01";
const w3_ptr = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x1b\x04\x60\x03\x7f\x7f\x7f\x01\x7f\x60\x04\x7f\x7f\x7f\x7f\x01\x7f\x60\x02\x7f\x7f\x01\x7f\x60\x01\x7f\x01\x7f\x02\x4b\x05\x03\x65\x6e\x76\x09\x66\x69\x6c\x65\x5f\x6f\x70\x65\x6e\x00\x00\x03\x65\x6e\x76\x08\x64\x69\x72\x5f\x6c\x69\x73\x74\x00\x01\x03\x65\x6e\x76\x07\x77\x69\x6e\x5f\x67\x65\x74\x00\x02\x03\x65\x6e\x76\x0a\x61\x75\x64\x69\x6f\x5f\x69\x6e\x66\x6f\x00\x03\x03\x65\x6e\x76\x05\x70\x72\x6f\x63\x73\x00\x02\x05\x03\x01\x00\x01";
const w3_file = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x10\x02\x60\x03\x7f\x7f\x7f\x01\x7f\x60\x04\x7f\x7f\x7f\x7f\x01\x7f\x02\x41\x04\x03\x65\x6e\x76\x09\x66\x69\x6c\x65\x5f\x6f\x70\x65\x6e\x00\x00\x03\x65\x6e\x76\x09\x66\x69\x6c\x65\x5f\x72\x65\x61\x64\x00\x00\x03\x65\x6e\x76\x0a\x66\x69\x6c\x65\x5f\x77\x72\x69\x74\x65\x00\x00\x03\x65\x6e\x76\x08\x64\x69\x72\x5f\x6c\x69\x73\x74\x00\x01\x05\x03\x01\x00\x01";
const w3_win = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x0f\x02\x60\x04\x7f\x7f\x7f\x7f\x01\x7f\x60\x02\x7f\x7f\x01\x7f\x02\x2e\x03\x03\x65\x6e\x76\x08\x77\x69\x6e\x5f\x6f\x70\x65\x6e\x00\x00\x03\x65\x6e\x76\x07\x77\x69\x6e\x5f\x67\x65\x74\x00\x01\x03\x65\x6e\x76\x09\x77\x69\x6e\x5f\x71\x75\x65\x72\x79\x00\x01\x05\x03\x01\x00\x01";
const w3_otr = "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x18\x04\x60\x01\x7f\x01\x7f\x60\x00\x01\x7f\x60\x04\x7f\x7f\x7f\x7f\x01\x7f\x60\x02\x7f\x7f\x01\x7f\x02\x64\x07\x03\x65\x6e\x76\x0a\x61\x75\x64\x69\x6f\x5f\x69\x6e\x66\x6f\x00\x00\x03\x65\x6e\x76\x09\x74\x69\x6d\x65\x72\x5f\x73\x65\x74\x00\x00\x03\x65\x6e\x76\x0c\x74\x69\x6d\x65\x72\x5f\x63\x61\x6e\x63\x65\x6c\x00\x01\x03\x65\x6e\x76\x04\x6d\x6d\x61\x70\x00\x02\x03\x65\x6e\x76\x06\x6d\x75\x6e\x6d\x61\x70\x00\x03\x03\x65\x6e\x76\x05\x70\x72\x6f\x63\x73\x00\x03\x03\x65\x6e\x76\x04\x77\x61\x69\x74\x00\x00\x05\x03\x01\x00\x01";
test "w3: validate rejects foreign module, unknown name, and bad signature" {
    var m0 = try parse(w3_foreign);
    try testing.expectError(error.UnknownImportModule, validate(&m0));
    var m1 = try parse(w3_unknown);
    try testing.expectError(error.UnknownImport, validate(&m1));
    var m2 = try parse(w3_badsig);
    try testing.expectError(error.ImportSignature, validate(&m2));
}

test "w3: all 30 frozen imports dispatch through the capture seam" {
    var m = try parse(w3_all);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "w3all") == null);
    var cap = HostCapture{ .write_buf = &store };
    g_capture = &cap;
    defer g_capture = null;
    cap.returns[@backingInt(CapId.file_open)] = 3;
    cap.returns[@backingInt(CapId.win_open)] = 4;
    cap.returns[@backingInt(CapId.mmap)] = 0x10000;
    cap.returns[@backingInt(CapId.procs)] = 2;
    const Z: [6]Value = .{ .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = 0 } };
    for (0..m.import_count) |fi| {
        const ft = &m.types[m.imports[fi].type_index];
        const r = call(&machine, &m, @intCast(fi), Z[0..ft.param_count]);
        const name = m.imports[fi].name;
        if (std.mem.eql(u8, name, "exit")) {
            // env.exit is noreturn: capture stops the interpreter.
            try testing.expect(r == .trap);
            try testing.expectEqual(TrapKind.guest_exit, r.trap.kind);
            continue;
        }
        try testing.expect(r == .ret);
        try testing.expectEqual(@as(usize, 1), r.ret.count);
    }
    try testing.expectEqual(@as(usize, 30), cap.log_count);
    // CapId variants were declared in the same order as the frozen table,
    // so the log ids line up with the import indices.
    for (0..30) |i| try testing.expectEqual(i, @as(usize, @backingInt(cap.log[i].id)));
    // Canned returns flowed back as the i32 result. The two direct re-calls
    // below log two more entries (30 + 2 = 32).
    const r11 = call(&machine, &m, 11, &.{ .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = 0 } });
    try testing.expectEqual(@as(i32, 4), r11.ret.vals[0].i32);
    const r26 = call(&machine, &m, 26, &.{ .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = 0 } });
    try testing.expectEqual(@as(i32, 0x10000), r26.ret.vals[0].i32);
    try testing.expectEqual(@as(usize, 32), cap.log_count);
    try testing.expectEqual(@as(usize, @backingInt(CapId.win_open)), @as(usize, @backingInt(cap.log[30].id)));
    try testing.expectEqual(@as(usize, @backingInt(CapId.mmap)), @as(usize, @backingInt(cap.log[31].id)));
}

test "w3: file imports carry paths and buffers across the store" {
    var m = try parse(w3_file);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "w3file") == null);
    const path = "/host/A.BIN";
    @memcpy(store[16 .. 16 + path.len], path);
    var cap = HostCapture{ .write_buf = &store };
    g_capture = &cap;
    defer g_capture = null;
    cap.returns[@backingInt(CapId.file_open)] = 3;
    cap.returns[@backingInt(CapId.file_read)] = 17;
    cap.returns[@backingInt(CapId.file_write)] = 8;
    cap.returns[@backingInt(CapId.dir_list)] = 2;
    const args1 = [_]Value{ .{ .i32 = 16 }, .{ .i32 = 13 }, .{ .i32 = 1 } };
    const r0 = call(&machine, &m, 0, &args1);
    try testing.expectEqual(@as(i32, 3), r0.ret.vals[0].i32);
    try testing.expectEqual(@as(i64, 16), cap.log[0].a[0]);
    try testing.expectEqual(@as(i64, 13), cap.log[0].a[1]);
    try testing.expectEqual(@as(i64, 1), cap.log[0].a[2]);
    const args2 = [_]Value{ .{ .i32 = 3 }, .{ .i32 = 64 }, .{ .i32 = 32 } };
    const r1 = call(&machine, &m, 1, &args2);
    try testing.expectEqual(@as(i32, 17), r1.ret.vals[0].i32);
    const args3 = [_]Value{ .{ .i32 = 3 }, .{ .i32 = 64 }, .{ .i32 = 8 } };
    try testing.expectEqual(@as(i32, 8), call(&machine, &m, 2, &args3).ret.vals[0].i32);
    const args4 = [_]Value{ .{ .i32 = 16 }, .{ .i32 = 13 }, .{ .i32 = 128 }, .{ .i32 = 2 } };
    const r3 = call(&machine, &m, 3, &args4);
    try testing.expectEqual(@as(i32, 2), r3.ret.vals[0].i32);
    try testing.expect(std.mem.allEqual(u8, store[128..208], 0xA5));
}

test "w3: window imports dispatch; win_get/win_query fill their out-buffers" {
    var m = try parse(w3_win);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "w3win") == null);
    var cap = HostCapture{ .write_buf = &store };
    g_capture = &cap;
    defer g_capture = null;
    cap.returns[@backingInt(CapId.win_open)] = 4;
    const args0 = [_]Value{ .{ .i32 = 100 }, .{ .i32 = 200 }, .{ .i32 = 96 }, .{ .i32 = 48 } };
    const r0 = call(&machine, &m, 0, &args0);
    try testing.expectEqual(@as(i32, 4), r0.ret.vals[0].i32);
    try testing.expectEqual(@as(i64, 100), cap.log[0].a[0]);
    try testing.expectEqual(@as(i64, 200), cap.log[0].a[1]);
    const args1 = [_]Value{ .{ .i32 = 4 }, .{ .i32 = 32 } };
    try testing.expect(call(&machine, &m, 1, &args1) == .ret);
    try testing.expect(std.mem.allEqual(u8, store[32..48], 0xA5));
    const args2 = [_]Value{ .{ .i32 = 4 }, .{ .i32 = 64 } };
    try testing.expect(call(&machine, &m, 2, &args2) == .ret);
    try testing.expect(std.mem.allEqual(u8, store[64..96], 0xA5));
}

test "w3: audio, timer, mmap, procs, wait dispatch" {
    var m = try parse(w3_otr);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "w3otr") == null);
    var cap = HostCapture{ .write_buf = &store };
    g_capture = &cap;
    defer g_capture = null;
    cap.returns[@backingInt(CapId.timer_cancel)] = 1;
    cap.returns[@backingInt(CapId.mmap)] = 0x10000;
    cap.returns[@backingInt(CapId.procs)] = 3;
    try testing.expect(call(&machine, &m, 0, &.{.{ .i32 = 16 }}) == .ret);
    try testing.expect(std.mem.allEqual(u8, store[16..32], 0xA5));
    try testing.expect(call(&machine, &m, 1, &.{.{ .i32 = 20 }}) == .ret);
    try testing.expectEqual(@as(i32, 1), call(&machine, &m, 2, &.{}).ret.vals[0].i32);
    const r3 = call(&machine, &m, 3, &.{ .{ .i32 = 0 }, .{ .i32 = 4096 }, .{ .i32 = 3 }, .{ .i32 = 0x22 } });
    try testing.expectEqual(@as(i32, 0x10000), r3.ret.vals[0].i32);
    try testing.expect(call(&machine, &m, 4, &.{ .{ .i32 = 0x10000 }, .{ .i32 = 4096 } }) == .ret);
    const r5 = call(&machine, &m, 5, &.{ .{ .i32 = 128 }, .{ .i32 = 80 } });
    try testing.expectEqual(@as(i32, 3), r5.ret.vals[0].i32);
    try testing.expect(std.mem.allEqual(u8, store[128..248], 0xA5));
    try testing.expect(call(&machine, &m, 6, &.{.{ .i32 = 2 }}) == .ret);
}

test "w3: pointer imports trap on out-of-bounds wasm pointers (never EFAULT at svc)" {
    var m = try parse(w3_ptr);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "w3ptr") == null);
    const trap = struct {
        fn expectBounds(r: CallResult) !void {
            try testing.expect(r == .trap);
            try testing.expectEqual(TrapKind.bounds, r.trap.kind);
        }
    };
    const big = @as(i32, @bitCast(@as(u32, 0x7FFFFFFF)));
    try trap.expectBounds(call(&machine, &m, 0, &.{ .{ .i32 = big }, .{ .i32 = 4 }, .{ .i32 = 1 } }));
    try trap.expectBounds(call(&machine, &m, 1, &.{ .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = big }, .{ .i32 = 2 } }));
    try trap.expectBounds(call(&machine, &m, 2, &.{ .{ .i32 = 2 }, .{ .i32 = big } }));
    try trap.expectBounds(call(&machine, &m, 3, &.{.{ .i32 = big }}));
    try trap.expectBounds(call(&machine, &m, 4, &.{ .{ .i32 = big }, .{ .i32 = 8 } }));
}

test "w3: frozen import with a non-i32 result type is rejected (ImportSignature)" {
    // env.win_open is (i32,i32,i32,i32) -> i32 (contract §5.2). A module
    // declaring -> i64 must fail validation: the dispatch arm pushes an
    // i32-lane Value, which the body would read through the i64 lane.
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x09\x01\x60\x04\x7f\x7f\x7f\x7f\x01\x7e" ++
        "\x02\x10\x01\x03\x65\x6e\x76\x08\x77\x69\x6e\x5f\x6f\x70\x65\x6e\x00\x00" ++
        "\x05\x03\x01\x00\x01";
    var m = try parse(bytes);
    try testing.expectError(error.ImportSignature, validate(&m));
}

test "w3: zero-length buffers are valid at any pointer (contract §3)" {
    // write(fd, 0x7fffffff, 0) and file_read(fd, 0x7fffffff, 0) touch no
    // memory — they return (0), not bounds-trap.
    const bytes = "\x00\x61\x73\x6d\x01\x00\x00\x00" ++
        "\x01\x0f\x02\x60\x03\x7f\x7f\x7f\x01\x7f\x60\x03\x7f\x7f\x7f\x01\x7f" ++
        "\x02\x1d\x02\x03\x65\x6e\x76\x05\x77\x72\x69\x74\x65\x00\x00\x03\x65\x6e\x76\x09\x66\x69\x6c\x65\x5f\x72\x65\x61\x64\x00\x00" ++
        "\x05\x03\x01\x00\x01";
    var m = try parse(bytes);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "w3zlen") == null);
    var cap = HostCapture{ .write_buf = &store };
    g_capture = &cap;
    defer g_capture = null;
    const rw = call(&machine, &m, 0, &.{ .{ .i32 = 1 }, .{ .i32 = 0x7FFFFFFF }, .{ .i32 = 0 } });
    try testing.expect(rw == .ret);
    try testing.expectEqual(@as(i32, 0), rw.ret.vals[0].i32);
    const rr = call(&machine, &m, 1, &.{ .{ .i32 = 0 }, .{ .i32 = 0x7FFFFFFF }, .{ .i32 = 0 } });
    try testing.expect(rr == .ret);
    try testing.expectEqual(@as(i32, 0), rr.ret.vals[0].i32);
}

test "w3: dir_list entry-count math is wrap-proof" {
    // max_entries * 40 wraps u32 for ~2^26 entries; the wrapped value used
    // to slip past the range check (here: 0x20000000 * 40 == 2^35, which
    // truncates to 0). Root path (len 0) with a huge entry cap must trap.
    var m = try parse(w3_file);
    try validate(&m);
    var store: [page_size]u8 = undefined;
    try testing.expect(instantiate(&machine, &m, &store, "w3wrap") == null);
    var cap = HostCapture{ .write_buf = &store };
    g_capture = &cap;
    defer g_capture = null;
    const r = call(&machine, &m, 3, &.{ .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = 0 }, .{ .i32 = 0x20000000 } });
    try testing.expect(r == .trap);
    try testing.expectEqual(TrapKind.bounds, r.trap.kind);
}

test "w3: live-gate app fixtures parse + validate against the frozen surface" {
    // The exact WINAPP.WASM / FILEAPP.WASM binaries the class-B gate
    // (tools/verify-live-wasm.sh W3 phases) drops into the share —
    // compiled from tests/virelai.h alone (the "contract alone" rule)
    // and pinned byte-identical (claim: fresh rebuild, fixed basenames).
    const win = @embedFile("wasm-corpus/winapp.wasm");
    const file = @embedFile("wasm-corpus/fileapp.wasm");
    var mw = try parse(win);
    try validate(&mw);
    var mf = try parse(file);
    try validate(&mf);
    var nwin: usize = 0;
    for (mw.imports[0..mw.import_count]) |imp| {
        if (std.mem.eql(u8, imp.name, "win_open")) nwin += 1;
    }
    var nfile: usize = 0;
    for (mf.imports[0..mf.import_count]) |imp| {
        if (std.mem.eql(u8, imp.name, "file_read")) nfile += 1;
    }
    try testing.expectEqual(@as(usize, 1), nwin);
    try testing.expectEqual(@as(usize, 1), nfile);
}

test "w4: floatapp fixture runs in-guest byte-exact (pinned output, exit = bytes)" {
    // The exact FLOATAPP.WASM binary the class-B gate (tools/verify-live-wasm.sh
    // W4 phase) drops into the share — the named C float utility from
    // tests/floatapp.c (compiled against tests/virelai.h alone with the W3
    // determinism recipe, volatile input tables so the float ops execute
    // at runtime). env.write captures the FULL 590-byte output through the
    // seam and env.exit's status is the byte count (fileapp's length
    // proof): byte-exact output + exit = 590 in one host test.
    const fixture = @embedFile("wasm-corpus/floatapp.wasm");
    var m = try parse(fixture);
    try validate(&m);
    // Fresh memory is zero-initialized per spec; the guest runner gets
    // zero pages from mmap, so the host test must zero too — floatapp is
    // the first fixture that READS .bss (the env.write cursor) before
    // writing it, and an undefined stack array poisons that read.
    var store: [max_mem_pages * page_size]u8 = @splat(0);
    try testing.expect(instantiate(&machine, &m, &store, "floatapp") == null);
    var capture_buf: [1024]u8 = undefined;
    var cap = HostCapture{ .write_buf = &capture_buf };
    g_capture = &cap;
    defer g_capture = null;
    const entry = entryExport(&m).?;
    const r = call(&machine, &m, entry, &.{});
    switch (r) {
        .ret => {},
        .trap => try testing.expectEqual(TrapKind.guest_exit, r.trap.kind),
    }
    const expected = "c2f 0.00 = 32.00\nc2f 10.00 = 50.00\nc2f 21.50 = 70.70\nc2f -40.00 = -40.00\nc2f 100.00 = 212.00\nf2c 32.00 = 0.00\nf2c 50.00 = 10.00\nf2c 98.60 = 37.00\nf2c 212.00 = 100.00\nf2c -40.00 = -40.00\nmC 0 = 32.00\nmC 10000 = 50.00\nmC 21500 = 70.70\nmC -40000 = -40.00\nmC 100000 = 212.00\nf32 c2f 21.50 = 70.70\nf32 c2f 100.00 = 212.00\nf32 c2f -40.00 = -40.00\nf32 f2c 212.00 = 100.00\nf32 f2c 70.70 = 21.50\nf32 f2c -4.00 = -20.00\nbits64 c2f 21.50 = 4051accccccccccd\nbits64 c2f -40.00 = c044000000000000\nbits64 f2c 98.60 = 4042800000000000\nbits32 c2f 21.50 = 428d6666\nbits32 f2c 70.70 = 41abffff\nsext chk = -66\n";
    try testing.expectEqual(@as(usize, expected.len), cap.wrote);
    try testing.expectEqualStrings(expected, cap.write_buf[0..cap.wrote]);
    try testing.expect(cap.exited);
    try testing.expectEqual(@as(i32, 590), cap.exit_status);
}

test "w5: wc capstone — byte/line/word counts run in-guest byte-exact (pinned)" {
    // WC.WASM = the exact binary the class-B gate (tools/verify-live-wasm.sh
    // W5 phase) drops into the share: tests/wc.c (written from the contract
    // doc + tests/virelai.h alone — the standalone-author provenance proof)
    // + tests/wc-fixture.txt (the gate's WC.TXT bytes, embedded verbatim
    // below — 8 lines / 32 words / 320 bytes, cross-validated against host
    // `wc`). The capture seam simulates the kernel file channel: file_open
    // -> fd 0, file_read serves min(cap, remaining) chunks with 0 at EOF
    // (contract §5.1), env.write captures the console byte-exact. Assert
    // the exact wc line (right-aligned classic three-column shape) and exit
    // status = 320 (the byte count — fileapp's length proof).
    const fixture = @embedFile("wasm-corpus/wc.wasm");
    const wc_txt =
        "w5 wc capstone fixture\n" ++
        "the quick brown fox\n" ++
        "long-token-0001-abcdefghijklmnopqrstuvwxyz-this-token-is-longer-than-the-64-byte-reader-buffer-so-the-word-state-must-survive-the-chunk-seam\n" ++
        "tab\tseparated\twords\n" ++
        "crlf pairs end each line here\r\n" ++
        "another line with trailing spaces   \n" ++
        "  leading spaces too\n" ++
        "last line ends with a word\n";
    try testing.expectEqual(@as(usize, 320), wc_txt.len);
    var m = try parse(fixture);
    try validate(&m);
    // Fresh memory is zero-initialized (the guest mmap provides it).
    var store: [max_mem_pages * page_size]u8 = @splat(0);
    try testing.expect(instantiate(&machine, &m, &store, "wc") == null);
    var capture_buf: [512]u8 = undefined;
    var cap = HostCapture{ .write_buf = &capture_buf, .file_data = wc_txt };
    g_capture = &cap;
    defer g_capture = null;
    const entry = entryExport(&m).?;
    const r = call(&machine, &m, entry, &.{});
    switch (r) {
        .ret => {},
        .trap => try testing.expectEqual(TrapKind.guest_exit, r.trap.kind),
    }
    const expected = "  8  32 320 /host/WC.TXT\n";
    try testing.expectEqual(@as(usize, expected.len), cap.wrote);
    try testing.expectEqualStrings(expected, cap.write_buf[0..cap.wrote]);
    try testing.expect(cap.exited);
    try testing.expectEqual(@as(i32, 320), cap.exit_status);
    // The file channel must be walked to EOF in chunks (320 / 64 = 5 data
    // reads + the EOF probe returning 0).
    var reads: usize = 0;
    for (cap.log[0..cap.log_count]) |cl| {
        if (cl.id == .file_read and cl.a[0] == 0) reads += 1;
    }
    try testing.expect(reads >= 5);
}

test "xl: rustc-authored nl fixture runs in-guest byte-exact (pinned)" {
    // NL.WASM = the exact binary the class-B gate (tools/verify-live-wasm.sh
    // cross-language phase, claim 9746) drops into the share:
    // tests/nl.rs — a numbered-lines tool AUTHORED IN RUST from
    // docs/wasm-import-contract.md alone (no virelai header, no WAT) and
    // compiled `rustc --crate-type=cdylib --target wasm32-unknown-unknown
    // -O -C strip=debuginfo`, rebuild-byte-identical (sha 34f02644). Its
    // imports are exactly env.write/exit/file_open/file_read/file_close.
    // Reads the SAME /host/WC.TXT the w5 test simulates, in 64-byte
    // chunks, prints each line right-aligned %6d + two spaces (CRLF
    // tolerant — the \r line of the fixture is terminator, not content),
    // exits with the total output byte count (383). Cross-validated
    // against an independent Python reimplementation of the fixture split
    // AND the native cross-run of the same source.
    const fixture = @embedFile("wasm-corpus/nl.wasm");
    const wc_txt =
        "w5 wc capstone fixture\n" ++
        "the quick brown fox\n" ++
        "long-token-0001-abcdefghijklmnopqrstuvwxyz-this-token-is-longer-than-the-64-byte-reader-buffer-so-the-word-state-must-survive-the-chunk-seam\n" ++
        "tab\tseparated\twords\n" ++
        "crlf pairs end each line here\r\n" ++
        "another line with trailing spaces   \n" ++
        "  leading spaces too\n" ++
        "last line ends with a word\n";
    try testing.expectEqual(@as(usize, 320), wc_txt.len);
    var m = try parse(fixture);
    try validate(&m);
    // Fresh memory is zero-initialized (the guest mmap provides it).
    var store: [max_mem_pages * page_size]u8 = @splat(0);
    try testing.expect(instantiate(&machine, &m, &store, "nl") == null);
    var capture_buf: [1024]u8 = undefined;
    var cap = HostCapture{ .write_buf = &capture_buf, .file_data = wc_txt };
    g_capture = &cap;
    defer g_capture = null;
    const entry = entryExport(&m).?;
    const r = call(&machine, &m, entry, &.{});
    switch (r) {
        .ret => {},
        .trap => try testing.expectEqual(TrapKind.guest_exit, r.trap.kind),
    }
    const expected =
        "     1  w5 wc capstone fixture\n" ++
        "     2  the quick brown fox\n" ++
        "     3  long-token-0001-abcdefghijklmnopqrstuvwxyz-this-token-is-longer-than-the-64-byte-reader-buffer-so-the-word-state-must-survive-the-chunk-seam\n" ++
        "     4  tab\tseparated\twords\n" ++
        "     5  crlf pairs end each line here\n" ++
        "     6  another line with trailing spaces   \n" ++
        "     7    leading spaces too\n" ++
        "     8  last line ends with a word\n";
    try testing.expectEqual(@as(usize, 383), expected.len);
    try testing.expectEqual(@as(usize, expected.len), cap.wrote);
    try testing.expectEqualStrings(expected, cap.write_buf[0..cap.wrote]);
    try testing.expect(cap.exited);
    try testing.expectEqual(@as(i32, 383), cap.exit_status);
    // The file channel must be walked to EOF in chunks (320 / 64 = 5 data
    // reads + the EOF probe returning 0).
    var reads: usize = 0;
    for (cap.log[0..cap.log_count]) |cl| {
        if (cl.id == .file_read and cl.a[0] == 0) reads += 1;
    }
    try testing.expect(reads >= 5);
}

// ---------------------------------------------------------------------------
// M70e (#1457) — contract v2: the `virelai.abi` custom section (§9).
// Host-decidable sandbox negatives in the same style as the W3 block above:
// hand-built module bytes through parse + validate. The delivery/manifest
// half (missing row, length/digest/revision mismatch, capability escalation)
// is host-testable too and lives with the admission code below.
// ---------------------------------------------------------------------------

/// Minimal module builder for the §9 fixtures — fixed buffers, no heap.
const ModBuilder = struct {
    buf: []u8,
    len: usize = 0,

    fn raw(bs: *ModBuilder, bytes: []const u8) void {
        @memcpy(bs.buf[bs.len..][0..bytes.len], bytes);
        bs.len += bytes.len;
    }
    fn byte(bs: *ModBuilder, v: u8) void {
        bs.buf[bs.len] = v;
        bs.len += 1;
    }
    fn uleb(bs: *ModBuilder, v: usize) void {
        var x = v;
        while (true) {
            var b: u8 = @intCast(x & 0x7f);
            x >>= 7;
            if (x != 0) b |= 0x80;
            bs.byte(b);
            if (x == 0) break;
        }
    }
    fn name(bs: *ModBuilder, s: []const u8) void {
        bs.uleb(s.len);
        bs.raw(s);
    }
    fn section(bs: *ModBuilder, id: u8, payload: []const u8) void {
        bs.byte(id);
        bs.uleb(payload.len);
        bs.raw(payload);
    }
};

var abi_scratch: [1024]u8 = undefined;

/// A module importing exactly `env.file_open` `(i32,i32,i32)->i32`, with one
/// memory, plus the optional `virelai.abi` custom section (emitted twice when
/// `dupe` — the duplicate-section refusal).
fn abiFixtureOpts(abi_text: ?[]const u8, dupe: bool) []const u8 {
    var sec: [512]u8 = undefined;
    var b = ModBuilder{ .buf = &abi_scratch };
    b.raw("\x00asm\x01\x00\x00\x00");
    if (abi_text) |t| {
        var sb = ModBuilder{ .buf = &sec };
        sb.name(abi_section_name);
        sb.raw(t);
        b.section(0, sec[0..sb.len]); // custom before type: legal anywhere
        if (dupe) b.section(0, sec[0..sb.len]);
    }
    {
        var sb = ModBuilder{ .buf = &sec };
        sb.uleb(1);
        sb.byte(0x60);
        sb.uleb(3);
        sb.raw(&[_]u8{ 0x7f, 0x7f, 0x7f });
        sb.uleb(1);
        sb.byte(0x7f);
        b.section(1, sec[0..sb.len]);
    }
    {
        var sb = ModBuilder{ .buf = &sec };
        sb.uleb(1);
        sb.name("env");
        sb.name("file_open");
        sb.byte(0x00); // func
        sb.uleb(0); // type index
        b.section(2, sec[0..sb.len]);
    }
    {
        var sb = ModBuilder{ .buf = &sec };
        sb.uleb(1);
        sb.byte(0x00);
        sb.uleb(1);
        b.section(5, sec[0..sb.len]);
    }
    return abi_scratch[0..b.len];
}

fn abiFixture(abi_text: ?[]const u8) []const u8 {
    return abiFixtureOpts(abi_text, false);
}

test "v2 (§9): a declared revision + capabilities gate the imports used" {
    var m = try parse(abiFixture("virelai.abi=2\ncapabilities=file\n"));
    try testing.expect(m.abi_declared);
    try testing.expectEqual(@as(u8, 2), m.abi_revision);
    try testing.expect(m.caps.has(.file));
    try testing.expect(!m.caps.has(.window));
    try validate(&m); // file_open is covered by the declared `file`

    // The SAME module with the capability it uses omitted fails closed.
    var m2 = try parse(abiFixture("virelai.abi=2\ncapabilities=debug\n"));
    try testing.expectError(error.UndeclaredCapability, validate(&m2));

    // ...and so does declaring v2 with no `capabilities=` line at all, which
    // is the empty set (omitting the line is how a module declares "none").
    var m3 = try parse(abiFixture("virelai.abi=2\n"));
    try testing.expectError(error.UndeclaredCapability, validate(&m3));
}

test "v2 (§9): a revision past the contract fails closed before start" {
    try testing.expectError(error.UnsupportedAbiRevision, parse(abiFixture("virelai.abi=3\ncapabilities=file\n")));
    try testing.expectError(error.UnsupportedAbiRevision, parse(abiFixture("virelai.abi=99\n")));
    // v1 is still accepted: additive, not breaking.
    var m = try parse(abiFixture("virelai.abi=1\ncapabilities=file\n"));
    try testing.expectEqual(@as(u8, 1), m.abi_revision);
    try validate(&m);
}

test "v2 (§9): a malformed section is a named refusal, never a guess" {
    // an unknown directive — an attempt to smuggle a new key past the loader
    try testing.expectError(error.BadAbiSection, parse(abiFixture("virelai.abi=2\ncapabilities=file\nvm_escape=yes\n")));
    // a capability spelling outside §9
    try testing.expectError(error.BadAbiSection, parse(abiFixture("virelai.abi=2\ncapabilities=net\n")));
    // an empty list (the way to declare none is to omit the line)
    try testing.expectError(error.BadAbiSection, parse(abiFixture("virelai.abi=2\ncapabilities=\n")));
    // a padded name is a DIFFERENT name, not a sloppy match
    try testing.expectError(error.BadAbiSection, parse(abiFixture("virelai.abi=2\ncapabilities= file\n")));
    // revision missing / unparseable / repeated, and a duplicate section
    try testing.expectError(error.BadAbiSection, parse(abiFixture("capabilities=file\n")));
    try testing.expectError(error.BadAbiSection, parse(abiFixture("virelai.abi=two\n")));
    try testing.expectError(error.BadAbiSection, parse(abiFixture("virelai.abi=2\nvirelai.abi=2\n")));
    try testing.expectError(error.BadAbiSection, parse(abiFixtureOpts("virelai.abi=2\ncapabilities=file\n", true)));
}

test "v2 (§9): a v1 module (no section) is untouched, and usedCaps still reports" {
    // The frozen M35 corpus carries no `virelai.abi` section: it must parse,
    // validate and report an empty DECLARED set — that is what makes v2
    // additive rather than a break of every authored module.
    var m = try parse(abiFixture(null));
    try testing.expect(!m.abi_declared);
    try testing.expectEqual(@as(u8, 1), m.abi_revision);
    try testing.expect(!m.caps.has(.file));
    try validate(&m);
    // usedCaps is derived from the imports, not from the declaration.
    try testing.expect(usedCaps(&m).has(.file));
    try testing.expect(!usedCaps(&m).has(.audio));
}

test "v2 (§9): a module past max_imports is refused (32 is the ceiling)" {
    var sec: [4096]u8 = undefined;
    var b = ModBuilder{ .buf = &abi_scratch };
    b.raw("\x00asm\x01\x00\x00\x00");
    {
        var sb = ModBuilder{ .buf = &sec };
        sb.uleb(1);
        sb.byte(0x60);
        sb.uleb(3);
        sb.raw(&[_]u8{ 0x7f, 0x7f, 0x7f });
        sb.uleb(1);
        sb.byte(0x7f);
        b.section(1, sec[0..sb.len]);
    }
    {
        var sb = ModBuilder{ .buf = &sec };
        sb.uleb(max_imports + 1);
        for (0..max_imports + 1) |_| {
            sb.name("env");
            sb.name("file_open");
            sb.byte(0x00);
            sb.uleb(0);
        }
        b.section(2, sec[0..sb.len]);
    }
    try testing.expectError(error.TooManyEntries, parse(abi_scratch[0..b.len]));
}

test "v2 (§9): the cap table covers every capability, and every frozen import maps once" {
    // A drift guard: a frozen import added without a capability would make the
    // v2 gate unenforceable for that name, and an unused Cap would mean §9
    // documents a capability nothing needs.
    var reachable: [std.meta.tags(Cap).len]bool = @splat(false);
    for (frozen_imports) |f| reachable[@backingInt(f.cap)] = true;
    for (reachable) |r| try testing.expect(r);
}

test "v2 (§9.2): manifest rows parse strictly, and a malformed row is not guessed" {
    const fixture = abiFixture("virelai.abi=2\ncapabilities=file\n");
    var digest: [32]u8 = undefined;
    sha256.sha256(&digest, fixture);
    var text_buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&text_buf, "abi.wasm | {d} | {x} | abi=2 | caps=file", .{ fixture.len, digest });
    const row = ManifestRow.parse(line).?;
    try testing.expectEqualStrings("abi.wasm", row.name);
    try testing.expectEqual(@as(u64, fixture.len), row.bytes);
    try testing.expectEqualSlices(u8, &digest, &row.digest);
    try testing.expectEqual(@as(u8, 2), row.abi);
    try testing.expect(row.caps.has(.file));
    try testing.expect(!row.caps.has(.debug));
    // The exec name is compared case-insensitively, and only in full.
    try testing.expect(manifestNameMatches(row.name, "ABI.WASM"));
    try testing.expect(!manifestNameMatches(row.name, "ABI.WAS"));

    // short digest / non-hex / missing field / six fields / unknown capability
    try testing.expect(ManifestRow.parse("ABI.WASM | 12 | ab | abi=2 | caps=file") == null);
    try testing.expect(ManifestRow.parse("ABI.WASM | 12 | 00112233445566778899aabbccddeeff00112233445566778899aabbccddeefg | abi=2 | caps=file") == null);
    try testing.expect(ManifestRow.parse("ABI.WASM | 12 | 00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff | abi=2") == null);
    try testing.expect(ManifestRow.parse("ABI.WASM | 12 | 00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff | abi=2 | caps=file | extra") == null);
    try testing.expect(ManifestRow.parse("ABI.WASM | 12 | 00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff | abi=2 | caps=net") == null);
    try testing.expect(ManifestRow.parse("ABI.WASM | 12 | 00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff | abi=2 | caps=") == null);
    // a revision row outside the contract is not a delivery we can honour
    try testing.expect(ManifestRow.parse("ABI.WASM | 12 | 00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff | abi=3 | caps=file") == null);
    // `caps=none` is the explicit empty set (and NOT the same as an empty list)
    const none = ManifestRow.parse("ABI.WASM | 12 | 00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff | abi=2 | caps=none").?;
    try testing.expect(!none.caps.has(.file));
}

test "v2 (§9.2): admission refuses an unvouched, altered, or escalated module" {
    const fixture = abiFixture("virelai.abi=2\ncapabilities=file\n");
    var m = try parse(fixture);
    const used = usedCaps(&m);
    var digest: [32]u8 = undefined;
    sha256.sha256(&digest, fixture);
    const row = ManifestRow{ .name = "ABI.WASM", .bytes = fixture.len, .digest = digest, .abi = 2, .caps = .{ .file = true } };
    try testing.expectEqual(AdmitFailure.ok, admit(row, fixture.len, digest, 2, used));

    // One flipped byte in the module is a different delivery.
    var altered = digest;
    altered[31] ^= 0x01;
    try testing.expectEqual(AdmitFailure.digest, admit(row, fixture.len, altered, 2, used));
    try testing.expectEqual(AdmitFailure.size, admit(row, fixture.len + 1, digest, 2, used));
    try testing.expectEqual(AdmitFailure.revision, admit(row, fixture.len, digest, 1, used));
    try testing.expectEqual(AdmitFailure.no_row, admit(null, fixture.len, digest, 2, used));

    // Capability escalation: a valid row that grants `debug` while the module's
    // imports need `file` is REFUSED, not silently widened.
    const narrow = ManifestRow{ .name = "ABI.WASM", .bytes = fixture.len, .digest = digest, .abi = 2, .caps = .{ .debug = true } };
    try testing.expectEqual(AdmitFailure.capability, admit(narrow, fixture.len, digest, 2, used));
    // Pre-provisioning (a row granting more than the module uses) is allowed.
    const wide = ManifestRow{ .name = "ABI.WASM", .bytes = fixture.len, .digest = digest, .abi = 2, .caps = .{ .file = true, .window = true } };
    try testing.expectEqual(AdmitFailure.ok, admit(wide, fixture.len, digest, 2, used));
}

test "v2 (§9): the author-proof corpus apps declare exactly what they use" {
    // trio.c (file + window + timers) and ticker.c (timer only) were written
    // from §5 + §9 alone — the §7 provenance rule made executable. Both carry
    // the section, so both are subject to §9.1 validation AND §9.2 admission.
    const trio = @embedFile("wasm-corpus/trio.wasm");
    var mt = try parse(trio);
    try validate(&mt);
    try testing.expect(mt.abi_declared);
    try testing.expectEqual(@as(u8, 2), mt.abi_revision);
    const used_trio = usedCaps(&mt);
    try testing.expect(used_trio.has(.file));
    try testing.expect(used_trio.has(.window));
    try testing.expect(used_trio.has(.timer));
    try testing.expect(used_trio.has(.debug));
    try testing.expect(!used_trio.has(.audio));
    // The declaration must cover what the imports need, or the app would
    // refuse itself at validation.
    inline for (std.meta.tags(Cap)) |cap| {
        try testing.expect(!used_trio.has(cap) or mt.caps.has(cap));
    }

    const ticker = @embedFile("wasm-corpus/ticker.wasm");
    var mk = try parse(ticker);
    try validate(&mk);
    try testing.expect(mk.abi_declared);
    const used_ticker = usedCaps(&mk);
    // The narrow-capability proof: ticker asks for nothing it does not use.
    try testing.expect(used_ticker.has(.timer));
    try testing.expect(used_ticker.has(.debug));
    try testing.expect(!used_ticker.has(.file));
    try testing.expect(!used_ticker.has(.window));

    // §9.2 on the REAL bytes: a row generated from the module admits it; the
    // same delivery with no row is refused, which is the live gate's `no_row`
    // case seen host-side.
    var digest: [32]u8 = undefined;
    sha256.sha256(&digest, trio);
    const row = ManifestRow{ .name = "TRIO.WASM", .bytes = trio.len, .digest = digest, .abi = 2, .caps = mt.caps };
    try testing.expectEqual(AdmitFailure.ok, admit(row, trio.len, digest, 2, used_trio));
    try testing.expectEqual(AdmitFailure.no_row, admit(null, trio.len, digest, 2, used_trio));
}
