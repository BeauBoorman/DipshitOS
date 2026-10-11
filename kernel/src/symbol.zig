//! VirelaiOS kernel symbol table (M22 D3, issue #326, claim 9815).
//!
//! A fixed BSS table populated when the M22 D1 ELF loader loads an image:
//! function/object symbols from the file's `.symtab` are copied here so
//! crash tombstones can name the closest preceding symbol for a faulting
//! PC (`(in name+0xoffset)`), and so the monitor's `sym` command can list
//! what is loaded. The table holds ONE program's worth of symbols — it is
//! cleared at every exec so stale names never outlive their code.
//!
//! Pure BSS, no allocation, no libc/POSIX. Safe to read from exception
//! context (tombstone recording runs on the task's kernel stack).

const std = @import("std");

/// At most 32 symbols per loaded program (the issue's bound).
pub const max_symbols: usize = 32;
/// Symbol names are truncated to 63 chars + terminator.
pub const name_max: usize = 63;

pub const Symbol = struct {
    name: [name_max + 1]u8 = @as([(name_max + 1)]u8, @splat(@as(u8, 0))),
    name_len: u8 = 0,
    /// Link-time virtual address (ELF st_value — images link at the EL0
    /// text aperture, so these are directly comparable with fault PCs).
    addr: u64 = 0,
    size: u64 = 0,

    pub fn name_slice(self: *const Symbol) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// A successful lookup: the symbol plus how far INTO it the address sits.
pub const Match = struct {
    name: []const u8,
    offset: u64,
};

var table: [max_symbols]Symbol = @as([max_symbols]Symbol, @splat(@as(Symbol, .{})));
var count_val: usize = 0;

/// Clear the table (called at every exec).
pub fn reset() void {
    count_val = 0;
}

/// Add one symbol; the name is truncated to `name_max`. Returns false when
/// the table is full or the name is empty.
pub fn add(name: []const u8, addr: u64, size: u64) bool {
    if (name.len == 0) return false;
    if (count_val == max_symbols) return false;
    const slot = &table[count_val];
    const take = @min(name.len, name_max);
    @memcpy(slot.name[0..take], name[0..take]);
    slot.name_len = @intCast(take);
    slot.addr = addr;
    slot.size = size;
    count_val += 1;
    return true;
}

pub fn count() usize {
    return count_val;
}

pub fn get(index: usize) ?*const Symbol {
    if (index >= count_val) return null;
    return &table[index];
}

/// Find the closest preceding symbol covering `addr`
/// (`addr` in `[sym.addr, sym.addr + size)`). Zero-sized symbols match
/// exactly at their address. Ties (nested ranges) resolve to the LAST
/// added — the innermost/most specific definition wins.
pub fn lookup(addr: u64) ?Match {
    var best: ?*const Symbol = null;
    for (table[0..count_val]) |*sym| {
        const covers = if (sym.size == 0)
            addr == sym.addr
        else
            addr >= sym.addr and addr < sym.addr +% sym.size;
        if (!covers) continue;
        if (best == null or sym.addr >= best.?.addr) best = sym;
    }
    const sym = best orelse return null;
    return .{ .name = sym.name_slice(), .offset = addr - sym.addr };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "symbol: add, count, get, and truncation" {
    reset();
    try testing.expectEqual(@as(usize, 0), count());
    try testing.expect(add("crasher", 0x400000, 16));
    try testing.expect(!add("", 0x400010, 4)); // empty name refused
    try testing.expectEqual(@as(usize, 1), count());
    const s = get(0).?;
    try testing.expectEqualStrings("crasher", s.name_slice());
    try testing.expectEqual(@as(u64, 0x400000), s.addr);

    // Truncation to 63 chars.
    const long = &@as([80:0]u8, @splat("a"[0]));
    try testing.expect(add(long, 0x400100, 4));
    try testing.expectEqual(@as(usize, name_max), get(1).?.name_len);
}

test "symbol: lookup resolves the covering range and offset" {
    reset();
    _ = add("_start", 0x400000, 12);
    _ = add("crasher", 0x40000c, 20);
    _ = add("after", 0x400030, 8);

    const m = lookup(0x400010).?; // inside crasher
    try testing.expectEqualStrings("crasher", m.name);
    try testing.expectEqual(@as(u64, 4), m.offset);

    // Exact start and last byte of a range.
    try testing.expectEqualStrings("crasher", lookup(0x40000c).?.name);
    try testing.expectEqualStrings("crasher", lookup(0x40001f).?.name);

    // One PAST the end belongs to nothing here.
    try testing.expect(lookup(0x400020) == null);

    // Outside everything.
    try testing.expect(lookup(0x500000) == null);

    // Zero-size symbol matches exactly.
    _ = add("point", 0x400100, 0);
    try testing.expectEqualStrings("point", lookup(0x400100).?.name);
    try testing.expect(lookup(0x400101) == null);
}

test "symbol: reset clears between programs" {
    reset();
    _ = add("old_prog_fn", 0x400000, 8);
    try testing.expectEqual(@as(usize, 1), count());
    reset();
    try testing.expectEqual(@as(usize, 0), count());
    try testing.expect(lookup(0x400000) == null);
}

test "symbol: full table refuses adds" {
    reset();
    var i: usize = 0;
    while (i < max_symbols) : (i += 1) {
        try testing.expect(add("f", @intCast(0x400000 + i * 4), 4));
    }
    try testing.expect(!add("overflow", 0x500000, 4));
    try testing.expectEqual(@as(usize, max_symbols), count());
}
