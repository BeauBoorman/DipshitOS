//! census (M188e, #3190): DISAS.BIN — gate-referenced: live-disas.
//! VirelaiOS ESP user program — DISAS.BIN (M22 D4, issue #327, claim 9815).
//!
//! Reads up to 4 KiB of raw bytes from the mounted filesystems and prints
//! one line per AArch64 instruction: address, the four bytes, and the
//! decoded mnemonic — the inverse of ASM.BIN's encoder (M22 D2). Covers
//! everything the assembler emits plus common compiler shapes (CBZ/CBNZ,
//! ADRP); anything else prints `.word 0x????????` honestly instead of
//! guessing.
//!
//! Usage: exec DISAS.BIN <file> [<offset>]  (offset accepts decimal or
//! 0x-hex; default 0 — for assembler output pass 0x54 to skip the ELF
//! headers). No libc, no POSIX, no heap; workspace lives on the task stack
//! because DSK1 flat images map their text pages only.

const std = @import("std");

// ---------------------------------------------------------------------------
// EL0 seam (the claim-8215 ABI, direct SVCs)
// ---------------------------------------------------------------------------

fn sys_write(buf: []const u8) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 1)),
          [fd] "{x0}" (@as(u64, 1)),
          [ptr] "{x1}" (@as(u64, @intFromPtr(buf.ptr))),
          [len] "{x2}" (@as(u64, buf.len)),
    );
}

fn console_puts(text: []const u8) void {
    if (text.len == 0) return;
    _ = sys_write(text);
}

fn sys_exit(status: u64) noreturn {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 3)),
          [code] "{x0}" (status),
    );
    unreachable;
}

const MODE_READ: u32 = 0x1;

fn file_open(path: []const u8, flags: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 23)),
          [p] "{x0}" (@as(u64, @intFromPtr(path.ptr))),
          [l] "{x1}" (@as(u64, path.len)),
          [f] "{x2}" (@as(u64, flags)),
    );
}

fn file_read(fd: u32, buf: []u8) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 24)),
          [h] "{x0}" (@as(u64, fd)),
          [p] "{x1}" (@as(u64, @intFromPtr(buf.ptr))),
          [n] "{x2}" (@as(u64, buf.len)),
    );
}

fn file_close(fd: u32) void {
    asm volatile ("svc #0"
        :
        : [num] "{x8}" (@as(u64, 26)),
          [h] "{x0}" (@as(u64, fd)),
    );
}

// ---------------------------------------------------------------------------
// Bounds
// ---------------------------------------------------------------------------

pub const input_max: usize = 4096;
/// One formatted line stays under this.
pub const line_max: usize = 80;

// ---------------------------------------------------------------------------
// The decoder — inverse of asm.zig's encoders. Formats one instruction into
// `buf` (must be >= line_max) and returns the slice.
// ---------------------------------------------------------------------------

const names_x = [_][]const u8{ "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x29", "lr", "sp" };

fn reg(n: u5) []const u8 {
    return names_x[n];
}

fn reg_wide(n: u32) []const u8 {
    return names_x[@intCast(n)];
}

fn append_str(buf: []u8, pos: usize, src: []const u8) usize {
    const take = @min(src.len, buf.len - pos);
    @memcpy(buf[pos .. pos + take], src[0..take]);
    return pos + take;
}

fn append_u64_dec(buf: []u8, pos: usize, v_in: u64) usize {
    var v = v_in;
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    if (v == 0) {
        tmp[0] = '0';
        n = 1;
    }
    while (v > 0) : (v /= 10) {
        tmp[n] = @intCast('0' + v % 10);
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[pos + i] = tmp[n - 1 - i];
    }
    return pos + n;
}

fn append_hex(buf: []u8, pos: usize, v_in: u64) usize {
    const digits = "0123456789abcdef";
    var v = v_in;
    var tmp: [16]u8 = undefined;
    var n: usize = 0;
    if (v == 0) {
        tmp[0] = '0';
        n = 1;
    }
    while (v > 0) : (v /= 16) {
        tmp[n] = digits[@intCast(v % 16)];
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[pos + i] = tmp[n - 1 - i];
    }
    return pos + n;
}

/// Sign-extend the low `bits` of `val`.
fn signed_extend(comptime bits: u6, val: u32) i64 {
    const upper: u32 = val << @intCast(32 - bits);
    const as_i32: i32 = @bitCast(upper);
    return @as(i64, as_i32) >> @intCast(32 - bits);
}

/// Decode one instruction word relative to its own address `addr` (used to
/// render branch targets). Returns the slice inside `buf`.
pub fn format_instruction(w: u32, addr: u64, buf: []u8) []const u8 {
    var p: usize = 0;

    // System / fixed forms first.
    if (w == 0xD503201F) return buf[0..append_str(buf, 0, "nop")];
    if ((w & 0xFFE0001F) == 0xD4000001)
        return fmt_two(buf, "svc #", @as(u64, (w >> 5) & 0xFFFF));
    if ((w & 0xFFE0001F) == 0xD4200000)
        return fmt_two(buf, "brk #", @as(u64, (w >> 5) & 0xFFFF));
    if ((w & 0xFFFFFC1F) == 0xD65F0000) { // RET (Rn in bits 5-9)
        const rn: u5 = @intCast((w >> 5) & 31);
        if (rn == 30) return buf[0..append_str(buf, 0, "ret")];
        p = append_str(buf, 0, "ret ");
        return buf[0..append_str(buf, p, reg(rn))];
    }

    // Move-immediate (MOVZ/MOVK wide forms, 64-bit).
    switch (w >> 23) {
        0x1A5 => { // sf=1 opc=10 100101 — MOVZ
            const rd: u5 = @intCast(w & 31);
            p = append_str(buf, 0, "movz ");
            p = append_str(buf, p, reg(rd));
            p = append_str(buf, p, ", #");
            p = append_u64_dec(buf, p, (w >> 5) & 0xFFFF);
            return finish_shift(buf, p, @intCast((w >> 21) & 3));
        },
        0x1E5 => { // sf=1 opc=11 100101 — MOVK
            const rd: u5 = @intCast(w & 31);
            p = append_str(buf, 0, "movk ");
            p = append_str(buf, p, reg(rd));
            p = append_str(buf, p, ", #");
            p = append_u64_dec(buf, p, (w >> 5) & 0xFFFF);
            return finish_shift(buf, p, @intCast((w >> 21) & 3));
        },
        else => {},
    }

    // Immediate arithmetic (top byte selects the family).
    const hi: u8 = @intCast(w >> 24);
    switch (hi) {
        0x91 => { // ADD imm 64-bit
            const rd: u5 = @intCast(w & 31);
            const rn: u5 = @intCast((w >> 5) & 31);
            p = append_str(buf, 0, "add ");
            p = append_str(buf, p, reg(rd));
            p = append_str(buf, p, ", ");
            p = append_str(buf, p, reg(rn));
            p = append_str(buf, p, ", #");
            return buf[0..append_u64_dec(buf, p, (w >> 10) & 0xFFF)];
        },
        0xD1 => { // SUB imm
            const rd: u5 = @intCast(w & 31);
            const rn: u5 = @intCast((w >> 5) & 31);
            p = append_str(buf, 0, "sub ");
            p = append_str(buf, p, reg(rd));
            p = append_str(buf, p, ", ");
            p = append_str(buf, p, reg(rn));
            p = append_str(buf, p, ", #");
            return buf[0..append_u64_dec(buf, p, (w >> 10) & 0xFFF)];
        },
        0xF1 => { // CMP imm (SUBS xzr)
            if ((w & 31) == 31) {
                const rn: u5 = @intCast((w >> 5) & 31);
                p = append_str(buf, 0, "cmp ");
                p = append_str(buf, p, reg(rn));
                p = append_str(buf, p, ", #");
                return buf[0..append_u64_dec(buf, p, (w >> 10) & 0xFFF)];
            }
        },
        else => {},
    }

    // Register operations: match (w >> 21) & 0x7FF families.
    switch ((w >> 21) & 0x7FF) {
        0x458 => return reg_op(buf, "add", w),
        0x658 => return reg_op(buf, "sub", w),
        0x758 => { // CMP reg (SUBS xzr)
            if ((w & 31) == 31) {
                const rm: u5 = @intCast((w >> 16) & 31);
                const rn: u5 = @intCast((w >> 5) & 31);
                p = append_str(buf, 0, "cmp ");
                p = append_str(buf, p, reg(rn));
                p = append_str(buf, p, ", ");
                return buf[0..append_str(buf, p, reg(rm))];
            }
        },
        0x450 => return reg_op(buf, "and", w),
        0x550 => {
            // ORR — with Rn=xzr this is the MOV alias.
            const rn: u5 = @intCast((w >> 5) & 31);
            const rm: u5 = @intCast((w >> 16) & 31);
            const rd: u5 = @intCast(w & 31);
            if (rn == 31) {
                p = append_str(buf, 0, "mov ");
                p = append_str(buf, p, reg(rd));
                p = append_str(buf, p, ", ");
                return buf[0..append_str(buf, p, reg(rm))];
            }
            return reg_op(buf, "orr", w);
        },
        0x650 => return reg_op(buf, "eor", w),
        else => {},
    }

    // Branches.
    switch (w >> 26) {
        0x05 => { // B
            const rel = signed_extend(26, w & 0x03FFFFFF) * 4;
            return branch_to(buf, "b", addr, rel);
        },
        0x25 => { // BL
            const rel = signed_extend(26, w & 0x03FFFFFF) * 4;
            return branch_to(buf, "bl", addr, rel);
        },
        else => {},
    }
    if ((w & 0xFF000010) == 0x54000000) { // B.cond
        const conds = [_][]const u8{ "eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le", "al", "nv" };
        const cond: usize = @intCast(w & 0xF);
        const rel = signed_extend(19, (w >> 5) & 0x7FFFF) * 4;
        p = append_str(buf, 0, "b.");
        p = append_str(buf, p, conds[cond]);
        return branch_tail(buf, p, addr, rel);
    }
    if ((w & 0x7F000000) == 0x34000000 or (w & 0x7F000000) == 0x35000000) { // CBZ/CBNZ (64-bit)
        const rt: u5 = @intCast(w & 31);
        const rel = signed_extend(19, (w >> 5) & 0x7FFFF) * 4;
        p = append_str(buf, 0, if ((w & 0x7F000000) == 0x34000000) "cbz " else "cbnz ");
        p = append_str(buf, p, reg(rt));
        return branch_tail(buf, p, addr, rel);
    }

    // PC-relative address forms.
    if ((w & 0x9F000000) == 0x10000000) { // ADR
        const rd: u5 = @intCast(w & 31);
        const rel = adr_imm(w);
        p = append_str(buf, 0, "adr ");
        p = append_str(buf, p, reg(rd));
        p = append_str(buf, p, ", 0x");
        return buf[0..append_hex(buf, p, @bitCast(@as(i64, @intCast(addr)) + rel))];
    }
    if ((w & 0x9F000000) == 0x90000000) { // ADRP
        const rd: u5 = @intCast(w & 31);
        const rel = adr_imm(w) * 4096;
        p = append_str(buf, 0, "adrp ");
        p = append_str(buf, p, reg(rd));
        p = append_str(buf, p, ", 0x");
        return buf[0..append_hex(buf, p, @bitCast((@as(i64, @intCast(addr)) & ~@as(i64, 0xFFF)) + rel))];
    }
    if ((w & 0xFF000000) == 0x58000000) { // LDR literal
        const rt: u5 = @intCast(w & 31);
        const rel = signed_extend(19, (w >> 5) & 0x7FFFF) * 4;
        p = append_str(buf, 0, "ldr ");
        p = append_str(buf, p, reg(rt));
        p = append_str(buf, p, ", 0x");
        return buf[0..append_hex(buf, p, @bitCast(@as(i64, @intCast(addr)) + rel))];
    }

    // Load/store unsigned offset (64-bit scaled).
    if ((w & 0xFFC00000) == 0xF9400000) {
        const rt: u5 = @intCast(w & 31);
        const rn: u5 = @intCast((w >> 5) & 31);
        const imm: u64 = ((w >> 10) & 0xFFF) * 8;
        p = append_str(buf, 0, "ldr ");
        p = append_str(buf, p, reg(rt));
        p = append_str(buf, p, ", [");
        p = append_str(buf, p, reg(rn));
        if (imm != 0) {
            p = append_str(buf, p, ", #");
            p = append_u64_dec(buf, p, imm);
        }
        p = append_str(buf, p, "]");
        return buf[0..p];
    }
    if ((w & 0xFFC00000) == 0xF9000000) {
        const rt: u5 = @intCast(w & 31);
        const rn: u5 = @intCast((w >> 5) & 31);
        const imm: u64 = ((w >> 10) & 0xFFF) * 8;
        p = append_str(buf, 0, "str ");
        p = append_str(buf, p, reg(rt));
        p = append_str(buf, p, ", [");
        p = append_str(buf, p, reg(rn));
        if (imm != 0) {
            p = append_str(buf, p, ", #");
            p = append_u64_dec(buf, p, imm);
        }
        p = append_str(buf, p, "]");
        return buf[0..p];
    }

    // Honest fallback.
    p = append_str(buf, 0, ".word 0x");
    return buf[0..append_hex(buf, p, w)];
}

fn fmt_two(buf: []u8, prefix: []const u8, v: u64) []const u8 {
    const p = append_str(buf, 0, prefix);
    return buf[0..append_u64_dec(buf, p, v)];
}

fn finish_shift(buf: []u8, p_in: usize, hw: u2) []const u8 {
    if (hw == 0) return buf[0..p_in];
    const p = append_str(buf, p_in, ", lsl #");
    return buf[0..append_u64_dec(buf, p, @as(u64, hw) * 16)];
}

fn reg_op(buf: []u8, name: []const u8, w: u32) []const u8 {
    const rm: u5 = @intCast((w >> 16) & 31);
    const rn: u5 = @intCast((w >> 5) & 31);
    const rd: u5 = @intCast(w & 31);
    var p = append_str(buf, 0, name);
    p = append_str(buf, p, " ");
    p = append_str(buf, p, reg(rd));
    p = append_str(buf, p, ", ");
    p = append_str(buf, p, reg(rn));
    p = append_str(buf, p, ", ");
    return buf[0..append_str(buf, p, reg(rm))];
}

fn branch_to(buf: []u8, name: []const u8, addr: u64, rel: i64) []const u8 {
    const p = append_str(buf, 0, name);
    return branch_tail(buf, p, addr, rel);
}

fn branch_tail(buf: []u8, p_in: usize, addr: u64, rel: i64) []const u8 {
    const p = append_str(buf, p_in, " 0x");
    const target: u64 = @bitCast(@as(i64, @intCast(addr)) + rel);
    return buf[0..append_hex(buf, p, target)];
}

fn adr_imm(w: u32) i64 {
    const immlo: u32 = (w >> 29) & 0x3;
    const immhi: u32 = (w >> 5) & 0x7FFFF;
    return signed_extend(21, (immhi << 2) | immlo);
}

// ---------------------------------------------------------------------------
// Host tests — decode known words + round-trip against the D2 assembler.
// ---------------------------------------------------------------------------

const testing = std.testing;

var line_out: [line_max]u8 = undefined;

fn fmt_of(w: u32) []const u8 {
    const t = format_instruction(w, 0, &line_out);
    return t;
}

test "disas: system instructions" {
    try testing.expectEqualStrings("nop", fmt_of(0xD503201F));
    try testing.expectEqualStrings("svc #0", fmt_of(0xD4000001));
    try testing.expectEqualStrings("svc #123", fmt_of(0xD4000F61));
    try testing.expectEqualStrings("brk #0", fmt_of(0xD4200000));
    try testing.expectEqualStrings("ret", fmt_of(0xD65F03C0));
    try testing.expectEqualStrings("ret x5", fmt_of(0xD65F00A0));
}

test "disas: move-immediate forms" {
    try testing.expectEqualStrings("movz x8, #1", fmt_of(0xD2800028));
    try testing.expectEqualStrings("movz x0, #42", fmt_of(0xD2800540));
    try testing.expectEqualStrings("movz x1, #200, lsl #16", fmt_of(0xD2A01901));
    try testing.expectEqualStrings("movk x1, #52, lsl #16", fmt_of(0xF2A00681));
}

test "disas: immediate arithmetic" {
    try testing.expectEqualStrings("add x0, x1, #8", fmt_of(0x91002020));
    try testing.expectEqualStrings("sub x2, x1, #16", fmt_of(0xD1004022));
    try testing.expectEqualStrings("cmp x3, #5", fmt_of(0xF100147F));
}

test "disas: register operations including the mov alias" {
    try testing.expectEqualStrings("add x1, x0, x1", fmt_of(0x8B010001));
    try testing.expectEqualStrings("sub x2, x0, x1", fmt_of(0xCB010002));
    try testing.expectEqualStrings("and x0, x0, x1", fmt_of(0x8A010000));
    try testing.expectEqualStrings("orr x0, x0, x1", fmt_of(0xAA010000));
    try testing.expectEqualStrings("eor x0, x0, x1", fmt_of(0xCA010000));
    try testing.expectEqualStrings("cmp x3, x1", fmt_of(0xEB01007F));
    try testing.expectEqualStrings("mov x1, x2", fmt_of(0xAA0203E1));
}

test "disas: branches render their absolute target" {
    // b .+12 from address 8 -> 0x14
    try testing.expectEqualStrings("b 0x14", fmt_at(0x14000003, 8));
    // bl backward to 0x0 from 12
    try testing.expectEqualStrings("bl 0x0", fmt_at(0x97FFFFFD, 12));
    // b.ne +8
    try testing.expectEqualStrings("b.ne 0x8", fmt_at(0x54000041, 0));
}

fn fmt_at(w: u32, addr: u64) []const u8 {
    const t = format_instruction(w, addr, &line_out);
    return t;
}

test "disas: pc-relative and memory forms" {
    try testing.expectEqualStrings("adr x1, 0x18", fmt_at(0x100000C1, 0));
    try testing.expectEqualStrings("ldr x0, 0x8", fmt_at(0x58000040, 0));
    try testing.expectEqualStrings("ldr x0, [x1]", fmt_of(0xF9400020));
    try testing.expectEqualStrings("ldr x0, [x1, #8]", fmt_of(0xF9400420));
    try testing.expectEqualStrings("str x0, [sp]", fmt_of(0xF90003E0));
}

test "disas: unknown words fall back honestly" {
    try testing.expectEqualStrings(".word 0x12345678", fmt_of(0x12345678));
    try testing.expectEqualStrings(".word 0xffffffff", fmt_of(0xFFFFFFFF));
}

// ---------------------------------------------------------------------------

pub export fn _start(argc: usize, argv: ?[*]const [256]u8) callconv(.c) noreturn {
    var path_buf: [40]u8 = @as([40]u8, @splat(@as(u8, 0)));
    // M34 HF6 (issue #740): bare name routes to the host share.
    @memcpy(path_buf[0..7], "OUT.ELF");
    var path_len: usize = 12;
    var offset: u64 = 0;

    if (argc >= 1) {
        if (argv) |slots| copy_arg(&path_buf, &path_len, slots[0]);
    }
    if (argc >= 2) {
        if (argv) |slots| {
            const n = std.mem.indexOfScalar(u8, &slots[1], 0) orelse slots[1].len;
            offset = parse_offset(slots[1][0..n]) orelse {
                console_puts("disas: bad offset\n");
                sys_exit(2);
            };
        }
    }
    run(path_buf[0..path_len], offset);
}

fn parse_offset(tok: []const u8) ?u64 {
    if (tok.len >= 3 and tok[0] == '0' and (tok[1] == 'x' or tok[1] == 'X')) {
        return std.fmt.parseInt(u64, tok[2..], 16) catch null;
    }
    return std.fmt.parseInt(u64, tok, 10) catch null;
}

fn copy_arg(dst: *[40]u8, len: *usize, slot: [256]u8) void {
    const n = std.mem.indexOfScalar(u8, &slot, 0) orelse slot.len;
    const take = @min(n, dst.len);
    @memcpy(dst[0..take], slot[0..take]);
    len.* = take;
}

fn run(path: []const u8, offset: u64) noreturn {
    // DSK1 flat images map text only — all workspace stays on the stack.
    var input: [input_max]u8 = undefined;
    var line: [line_max]u8 = undefined;

    const fd = file_open(path, MODE_READ);
    if (fd < 0) {
        console_puts("disas: cannot open file\n");
        sys_exit(1);
    }
    const total = file_read(@intCast(fd), &input);
    file_close(@intCast(fd));
    if (total <= 0) {
        console_puts("disas: empty or unreadable file\n");
        sys_exit(2);
    }
    if (offset >= @as(u64, @intCast(total))) {
        console_puts("disas: offset past end of file\n");
        sys_exit(3);
    }

    var pos: u64 = offset;
    while (pos + 4 <= @as(u64, @intCast(total))) : (pos += 4) {
        const w = std.mem.readInt(u32, input[@intCast(pos)..][0..4], .little);
        const b0 = w & 0xFF;
        const b1 = (w >> 8) & 0xFF;
        const b2 = (w >> 16) & 0xFF;
        const b3 = (w >> 24) & 0xFF;

        var p: usize = append_hex8(&line, 0, pos);
        p = append_str(&line, p, ": ");
        p = append_hex_byte(&line, p, @intCast(b0));
        p = append_hex_byte(&line, p, @intCast(b1));
        p = append_hex_byte(&line, p, @intCast(b2));
        p = append_hex_byte(&line, p, @intCast(b3));
        p = append_str(&line, p, "  ");
        const text = format_instruction(w, pos, line[p..]);
        p += text.len;
        if (p < line.len) {
            line[p] = '\n';
            console_puts(line[0 .. p + 1]);
        } else {
            console_puts(line[0..p]);
            console_puts("\n");
        }
    }
    sys_exit(0);
}

/// Fixed-width hex (8 digits) for the address column.
fn append_hex8(buf: []u8, pos: usize, v: u64) usize {
    const digits = "0123456789abcdef";
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        buf[pos + i] = digits[@intCast((v >> @intCast(28 - i * 4)) & 0xF)];
    }
    return pos + 8;
}

fn append_hex_byte(buf: []u8, pos: usize, v: u8) usize {
    const digits = "0123456789abcdef";
    buf[pos] = digits[v >> 4];
    buf[pos + 1] = digits[v & 0xF];
    return pos + 2;
}

// DISAS_TESTS_MARKER
