//! AArch64 instruction encoder and ELF32 generator library.
//! Shared by ASM.BIN and zc.

const std = @import("std");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
pub const image_base: u32 = 0x0040_0000;
pub const elf_header_size: usize = 52;
pub const elf_phdr_size: usize = 32;
pub const elf_code_offset: usize = elf_header_size + elf_phdr_size;

pub const ElfError = error{too_large};

// ---------------------------------------------------------------------------
// Raw Encoders
// ---------------------------------------------------------------------------
pub fn enc_movz(rd: u5, imm16: u16, hw: u2) u32 {
    return 0xD2800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | rd;
}

pub fn enc_movk(rd: u5, imm16: u16, hw: u2) u32 {
    return 0xF2800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | rd;
}

/// MOV (register) alias == ORR rd, xzr, rm.
pub fn enc_mov_reg(rd: u5, rm: u5) u32 {
    return 0xAA0003E0 | (@as(u32, rm) << 16) | rd;
}

pub fn enc_add_imm(rn: u5, rd: u5, imm12: u12) u32 {
    return 0x91000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd;
}

pub fn enc_add_reg(rn: u5, rm: u5, rd: u5) u32 {
    return 0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}

pub fn enc_sub_imm(rn: u5, rd: u5, imm12: u12) u32 {
    return 0xD1000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd;
}

pub fn enc_sub_reg(rn: u5, rm: u5, rd: u5) u32 {
    return 0xCB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}

/// CMP immediate == SUBS xzr, rn, #imm12.
pub fn enc_cmp_imm(rn: u5, imm12: u12) u32 {
    return 0xF1000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | 31;
}

/// CMP register == SUBS xzr, rn, rm.
pub fn enc_cmp_reg(rn: u5, rm: u5) u32 {
    return 0xEB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | 31;
}

pub fn enc_and_reg(rn: u5, rm: u5, rd: u5) u32 {
    return 0x8A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}

pub fn enc_orr_reg(rn: u5, rm: u5, rd: u5) u32 {
    return 0xAA000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}

pub fn enc_eor_reg(rn: u5, rm: u5, rd: u5) u32 {
    return 0xCA000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}

/// B with a ±128 MiB pc-relative BYTE offset.
pub fn enc_b(rel_bytes: i32) u32 {
    const off: u32 = @bitCast(rel_bytes >> 2);
    return 0x14000000 | (off & 0x03FF_FFFF);
}

/// BL with a ±128 MiB pc-relative BYTE offset.
pub fn enc_bl(rel_bytes: i32) u32 {
    const off: u32 = @bitCast(rel_bytes >> 2);
    return 0x94000000 | (off & 0x03FF_FFFF);
}

pub const Cond = enum(u4) {
    eq = 0,
    ne = 1,
    cs = 2,
    cc = 3,
    mi = 4,
    pl = 5,
    vs = 6,
    vc = 7,
    hi = 8,
    ls = 9,
    ge = 10,
    lt = 11,
    gt = 12,
    le = 13,
    al = 14,
};

/// B.cond with a ±1 MiB pc-relative BYTE offset.
pub fn enc_b_cond(cond: Cond, rel_bytes: i32) u32 {
    const off: u32 = @bitCast(rel_bytes >> 2);
    return 0x54000000 | ((off & 0x7FFFF) << 5) | @intFromEnum(cond);
}

pub fn parse_cond(name: []const u8) ?Cond {
    const map = .{
        .{ "eq", Cond.eq }, .{ "ne", Cond.ne }, .{ "cs", Cond.cs }, .{ "hs", Cond.cs },
        .{ "cc", Cond.cc }, .{ "lo", Cond.cc }, .{ "mi", Cond.mi }, .{ "pl", Cond.pl },
        .{ "vs", Cond.vs }, .{ "vc", Cond.vc }, .{ "hi", Cond.hi }, .{ "ls", Cond.ls },
        .{ "ge", Cond.ge }, .{ "lt", Cond.lt }, .{ "gt", Cond.gt }, .{ "le", Cond.le },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
}

/// CBZ with a ±1 MiB pc-relative BYTE offset.
pub fn enc_cbz(rt: u5, rel_bytes: i32) u32 {
    const off: u32 = @bitCast(rel_bytes >> 2);
    return 0xB4000000 | ((off & 0x7FFFF) << 5) | rt;
}

/// CBNZ with a ±1 MiB pc-relative BYTE offset.
pub fn enc_cbnz(rt: u5, rel_bytes: i32) u32 {
    const off: u32 = @bitCast(rel_bytes >> 2);
    return 0xB5000000 | ((off & 0x7FFFF) << 5) | rt;
}

/// ADR with a ±1 MiB pc-relative BYTE offset.
pub fn enc_adr(rd: u5, rel_bytes: i32) u32 {
    const off: u32 = @bitCast(rel_bytes);
    const immlo: u32 = off & 0x3;
    const immhi: u32 = (off >> 2) & 0x7FFFF;
    return 0x10000000 | (immlo << 29) | (immhi << 5) | rd;
}

/// ADRP with a ±4 GiB PAGE offset (target_page - pc_page).
pub fn enc_adrp(rd: u5, page_delta: i32) u32 {
    const off: u32 = @bitCast(page_delta);
    const immlo: u32 = off & 0x3;
    const immhi: u32 = (off >> 2) & 0x7FFFF;
    return 0x90000000 | (immlo << 29) | (immhi << 5) | rd;
}

/// LDR literal (64-bit) with a ±1 MiB pc-relative BYTE offset.
pub fn enc_ldr_literal(rt: u5, rel_bytes: i32) u32 {
    const off: u32 = @bitCast(rel_bytes >> 2);
    return 0x58000000 | ((off & 0x7FFFF) << 5) | rt;
}

/// LDR unsigned offset: base register + scaled imm12 ([xn] or [xn, #imm]).
pub fn enc_ldr(rn: u5, rt: u5, imm12: u12) u32 {
    return 0xF9400000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rt;
}

/// STR unsigned offset: base register + scaled imm12.
pub fn enc_str(rn: u5, rt: u5, imm12: u12) u32 {
    return 0xF9000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rt;
}

pub fn enc_blr(rn: u5) u32 {
    return 0xD63F0000 | (@as(u32, rn) << 5);
}

pub fn enc_ret(rn: u5) u32 {
    if (rn == 30) return 0xD65F03C0; // canonical RET encoding
    return 0xD65F0000 | (@as(u32, rn) << 5);
}

pub const nop_enc: u32 = 0xD503201F;

pub fn enc_svc(imm16: u16) u32 {
    return 0xD4000001 | (@as(u32, imm16) << 5);
}

pub fn enc_brk(imm16: u16) u32 {
    return 0xD4200000 | (@as(u32, imm16) << 5);
}

pub fn enc_mul(rn: u5, rm: u5, rd: u5) u32 {
    return 0x9B007C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}

pub fn enc_udiv(rn: u5, rm: u5, rd: u5) u32 {
    return 0x9AC00800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}

pub fn enc_lsl(rn: u5, rd: u5, imm: u6) u32 {
    const immr: u6 = @intCast((64 - @as(u32, imm)) & 63);
    const imms: u6 = 63 - imm;
    return 0xD3400000 | (@as(u32, immr) << 16) | (@as(u32, imms) << 10) | (@as(u32, rn) << 5) | rd;
}

pub fn enc_lsr(rn: u5, rd: u5, imm: u6) u32 {
    return 0xD340FC00 | (@as(u32, imm) << 16) | (@as(u32, rn) << 5) | rd;
}

pub fn enc_lsl_reg(rn: u5, rm: u5, rd: u5) u32 {
    return 0x9AC02000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}

pub fn enc_lsr_reg(rn: u5, rm: u5, rd: u5) u32 {
    return 0x9AC02400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}

pub fn enc_ldrb(rn: u5, rt: u5, imm12: u12) u32 {
    return 0x39400000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rt;
}

pub fn enc_strb(rn: u5, rt: u5, imm12: u12) u32 {
    return 0x39000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rt;
}

// ---------------------------------------------------------------------------
// Lexical / Parsing Helpers
// ---------------------------------------------------------------------------
pub fn parse_register(token: []const u8) ?u5 {
    if (token.len == 0) return null;
    var lower: [8]u8 = undefined;
    if (token.len > lower.len) return null;
    for (token, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const t = lower[0..token.len];
    if (std.mem.eql(u8, t, "xzr") or std.mem.eql(u8, t, "wzr") or std.mem.eql(u8, t, "sp")) return 31;
    if (std.mem.eql(u8, t, "lr")) return 30;
    if (t[0] != 'x' and t[0] != 'w') return null;
    const num = std.fmt.parseInt(u8, t[1..], 10) catch return null;
    if (num > 30) return null;
    return @intCast(num);
}

pub fn parse_immediate(token: []const u8) ?u64 {
    var t = token;
    if (t.len > 0 and t[0] == '#') t = t[1..];
    if (t.len == 0) return null;
    if (t.len >= 3 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
        return std.fmt.parseInt(u64, t[2..], 16) catch null;
    }
    return std.fmt.parseInt(u64, t, 10) catch null;
}

pub const Operands = struct {
    items: [4][]const u8 = @as([4][]const u8, @splat(@as([]const u8, ""))),
    count: usize = 0,
    pub fn get(self: @This(), i: usize) []const u8 {
        return self.items[i];
    }
};

pub fn split_operands(field: []const u8) Operands {
    var ops = Operands{};
    var start: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;
    while (i <= field.len) : (i += 1) {
        const at_end = i == field.len;
        if (!at_end and field[i] == '[') depth += 1;
        if (!at_end and field[i] == ']') depth -|= 1;
        if ((at_end or field[i] == ',') and depth == 0) {
            const raw = field[start..i];
            var s: usize = 0;
            var e: usize = raw.len;
            while (s < e and std.ascii.isWhitespace(raw[s])) s += 1;
            while (e > s and std.ascii.isWhitespace(raw[e - 1])) e -= 1;
            if (e > s and ops.count < ops.items.len) {
                ops.items[ops.count] = raw[s..e];
                ops.count += 1;
            }
            start = i + 1;
        }
        if (at_end) break;
    }
    return ops;
}

pub fn strip_comment(raw: []const u8) []const u8 {
    var line = raw;
    if (std.mem.indexOf(u8, line, "//")) |idx| line = line[0..idx];
    while (line.len > 0 and std.ascii.isWhitespace(line[0])) line = line[1..];
    while (line.len > 0 and std.ascii.isWhitespace(line[line.len - 1])) line = line[0 .. line.len - 1];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return line;
}

// ---------------------------------------------------------------------------
// ELF32 Generator
pub fn build_elf32_with_data(code: []const u8, data: []const u8, entry_off: u32, out: []u8) ElfError!usize {
    const total = elf_code_offset + code.len + data.len;
    if (total > out.len) return error.too_large;

    @memset(out[0..total], 0);
    // e_ident
    out[0] = 0x7f;
    out[1] = 'E';
    out[2] = 'L';
    out[3] = 'F';
    out[4] = 1; // ELF32
    out[5] = 1; // little-endian
    out[6] = 1; // EV_CURRENT
    std.mem.writeInt(u16, out[16..18], 2, .little); // e_type = ET_EXEC
    std.mem.writeInt(u16, out[18..20], 0xB7, .little); // e_machine = EM_AARCH64
    std.mem.writeInt(u32, out[20..24], 1, .little); // e_version
    std.mem.writeInt(u32, out[24..28], image_base + entry_off, .little); // e_entry
    std.mem.writeInt(u32, out[28..32], @intCast(elf_header_size), .little); // e_phoff
    std.mem.writeInt(u16, out[40..42], @intCast(elf_header_size), .little); // e_ehsize
    std.mem.writeInt(u16, out[42..44], @intCast(elf_phdr_size), .little); // e_phentsize
    std.mem.writeInt(u16, out[44..46], 1, .little); // e_phnum

    const p = elf_header_size;
    const seg_len: u32 = @intCast(code.len + data.len);
    std.mem.writeInt(u32, out[p..][0..4], 1, .little); // PT_LOAD
    std.mem.writeInt(u32, out[p + 4 ..][0..4], @intCast(elf_code_offset), .little); // p_offset
    std.mem.writeInt(u32, out[p + 8 ..][0..4], image_base, .little); // p_vaddr
    std.mem.writeInt(u32, out[p + 12 ..][0..4], image_base, .little); // p_paddr
    std.mem.writeInt(u32, out[p + 16 ..][0..4], seg_len, .little); // p_filesz
    std.mem.writeInt(u32, out[p + 20 ..][0..4], seg_len, .little); // p_memsz
    std.mem.writeInt(u32, out[p + 24 ..][0..4], 5, .little); // R+X
    std.mem.writeInt(u32, out[p + 28 ..][0..4], 0x1000, .little); // page aligned

    @memcpy(out[elf_code_offset..][0..code.len], code);
    if (data.len > 0) {
        @memcpy(out[elf_code_offset + code.len ..][0..data.len], data);
    }
    return total;
}

pub fn build_elf32(code: []const u8, entry_off: u32, out: []u8) ElfError!usize {
    return build_elf32_with_data(code, &.{}, entry_off, out);
}
