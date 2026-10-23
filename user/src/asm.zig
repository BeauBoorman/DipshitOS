//! census (M188e, #3190): ASM.BIN — gate-referenced: live-asm, live-disas, live-trust-grants.
//! VirelaiOS ESP user program — ASM.BIN (M22 D2, issue #325, claim 9815).
//!
//! A tiny two-pass AArch64 assembler running ON the machine: reads a
//! bounded source file from the mounted filesystems (sys_file_open/read,
//! slots 23/24), assembles ~20 common instructions, and writes a minimal
//! statically linked AArch64 ELF32 executable (single R+X PT_LOAD segment
//! at 0x00400000 — exactly the M22 D1 loader contract) back out through
//! sys_file_write (slot 25). `exec OUT.ELF` then loads and runs it.
//!
//! Source format (one instruction per line):
//!
//!     // comment
//! _start:
//!   mov x0, #42          // MOVZ alias (also movz/movk with lsl #hw)
//!   mov x1, x2           // register move (ORR rd, xzr, rm)
//!   add x0, x1, #8       // immediate forms: add/sub/cmp #
//!   cmp x0, #10          // SUBS xzr, xn, #imm
//!   ldr x0, msg          // LDR literal (pc-relative)
//!   str x0, [x1, #8]     // unsigned-offset register form
//!   b.eq done            // conditional branches eq/ne/lt/gt/hs/ls
//!   svc #0
//!   .word 0x12345678     // raw word directive
//!
//! Labels end with ':'. Bounded: 256 source lines, 96 chars per line,
//! 64 labels, 4096 output bytes. Every refusal names its line. No libc,
//! no POSIX, no heap.
//!
//! Usage: exec ASM.BIN <source> [<output>]  (paths route to the host
//! share; defaults: PROG.S -> OUT.ELF)

const std = @import("std");
const asmenc = @import("lib/asmenc.zig");
const Cond = asmenc.Cond;
const Operands = asmenc.Operands;
const split_operands = asmenc.split_operands;
const strip_comment = asmenc.strip_comment;
const parse_register = asmenc.parse_register;
const parse_immediate = asmenc.parse_immediate;
const parse_cond = asmenc.parse_cond;
const build_elf32 = asmenc.build_elf32;
const elf_header_size = asmenc.elf_header_size;
const elf_phdr_size = asmenc.elf_phdr_size;
const elf_code_offset = asmenc.elf_code_offset;

const enc_movz = asmenc.enc_movz;
const enc_movk = asmenc.enc_movk;
const enc_mov_reg = asmenc.enc_mov_reg;
const enc_add_imm = asmenc.enc_add_imm;
const enc_add_reg = asmenc.enc_add_reg;
const enc_sub_imm = asmenc.enc_sub_imm;
const enc_sub_reg = asmenc.enc_sub_reg;
const enc_cmp_imm = asmenc.enc_cmp_imm;
const enc_cmp_reg = asmenc.enc_cmp_reg;
const enc_and_reg = asmenc.enc_and_reg;
const enc_orr_reg = asmenc.enc_orr_reg;
const enc_eor_reg = asmenc.enc_eor_reg;
const enc_b = asmenc.enc_b;
const enc_bl = asmenc.enc_bl;
const enc_b_cond = asmenc.enc_b_cond;
const enc_cbz = asmenc.enc_cbz;
const enc_cbnz = asmenc.enc_cbnz;
const enc_adr = asmenc.enc_adr;
const enc_adrp = asmenc.enc_adrp;
const enc_ldr_literal = asmenc.enc_ldr_literal;
const enc_ldr = asmenc.enc_ldr;
const enc_str = asmenc.enc_str;
const enc_blr = asmenc.enc_blr;
const enc_ret = asmenc.enc_ret;
const enc_svc = asmenc.enc_svc;
const enc_brk = asmenc.enc_brk;
const nop_enc = asmenc.nop_enc;

const enc_mul = asmenc.enc_mul;
const enc_udiv = asmenc.enc_udiv;
const enc_lsl = asmenc.enc_lsl;
const enc_lsr = asmenc.enc_lsr;
const enc_lsl_reg = asmenc.enc_lsl_reg;
const enc_lsr_reg = asmenc.enc_lsr_reg;
const enc_ldrb = asmenc.enc_ldrb;
const enc_strb = asmenc.enc_strb;

// ---------------------------------------------------------------------------
// EL0 seam (the claim-8215 ABI, direct SVCs — same shape as ui.zig)
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
const MODE_WRITE: u32 = 0x2;
const MODE_CREATE: u32 = 0x4;

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

fn file_write(fd: u32, buf: []const u8) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [num] "{x8}" (@as(u64, 25)),
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
// Bounds (documented, enforced, host-tested)
// ---------------------------------------------------------------------------

pub const max_lines: usize = 256;
pub const max_line_len: usize = 96;
pub const max_labels: usize = 64;
pub const code_max: usize = 4096;
pub const image_base = asmenc.image_base;

pub const ErrorKind = enum {
    too_many_lines,
    line_too_long,
    too_many_labels,
    duplicate_label,
    unknown_label,
    bad_instruction,
    bad_register,
    bad_immediate,
    missing_operand,
    extra_operand,
    bad_operand_form,
    code_overflow,
    no_start_label,
};

/// One assembly failure, reported honestly with its 1-based source line.
pub const AsmError = struct {
    kind: ErrorKind,
    line: usize,
};

/// Success payload: emitted byte count + the `_start` byte offset (the
/// ELF entry point).
pub const Assembled = struct {
    bytes: usize,
    entry_off: u32,
};

pub const AsmResult = union(enum) {
    ok: Assembled,
    err: AsmError,
};

const Label = struct {
    name: [24]u8 = @as([24]u8, @splat(@as(u8, 0))),
    name_len: u8 = 0,
    offset: u32 = 0,

    fn matches(self: *const Label, ident: []const u8) bool {
        return std.mem.eql(u8, self.name[0..self.name_len], ident);
    }

    fn set(self: *Label, ident: []const u8, off: u32) void {
        self.name_len = @intCast(ident.len);
        @memcpy(self.name[0..ident.len], ident);
        self.offset = off;
    }
};

// ---------------------------------------------------------------------------
// Lexical helpers
// ---------------------------------------------------------------------------

fn is_ident_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

/// Split "mnemonic operands" — mnemonic up to first whitespace.
fn split_mnemonic(line: []const u8) struct { mnem: []const u8, rest: []const u8 } {
    var i: usize = 0;
    while (i < line.len and !std.ascii.isWhitespace(line[i])) i += 1;
    const rest_raw = line[@min(i + 1, line.len)..];
    var rest = rest_raw;
    while (rest.len > 0 and std.ascii.isWhitespace(rest[0])) rest = rest[1..];
    return .{ .mnem = line[0..i], .rest = rest };
}

/// Resolve one label name to its byte offset.
fn label_offset(labels: []const Label, ident: []const u8) ?u32 {
    for (labels) |*l| {
        if (l.name_len != 0 and l.matches(ident)) return l.offset;
    }
    return null;
}

pub const ParsedLine = struct {
    /// Null when the whole line was a comment / blank / pure label def.
    mnemonic: ?[]const u8,
    ops: Operands,
};

/// Classify one source line into (optional label, optional instruction).
pub fn classify(line_in: []const u8) ?ParsedLine {
    const line = strip_comment(line_in);
    if (line.len == 0) return null;
    var body = line;
    // A leading "name:" label definition may share the line with code.
    if (body.len > 0 and is_ident_char(body[0]) and !std.ascii.isDigit(body[0])) {
        var i: usize = 0;
        while (i < body.len and is_ident_char(body[i])) i += 1;
        if (i < body.len and body[i] == ':') {
            // The caller handles labels during the pass walks; here we only
            // strip it so classification sees the remainder.
            var rest = body[i + 1 ..];
            while (rest.len > 0 and std.ascii.isWhitespace(rest[0])) rest = rest[1..];
            body = rest;
            if (body.len == 0) {
                return ParsedLine{ .mnemonic = null, .ops = .{} };
            }
        }
    }
    const parts = split_mnemonic(body);
    if (parts.mnem.len == 0) return null;
    return ParsedLine{ .mnemonic = parts.mnem, .ops = split_operands(parts.rest) };
}

/// Extract the label definition ("foo" from "foo:") on this line, if any.
fn label_def(striped: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < striped.len and is_ident_char(striped[i])) i += 1;
    if (i > 0 and i < striped.len and striped[i] == ':') return striped[0..i];
    return null;
}

// ---------------------------------------------------------------------------
// Instruction encoding — one branch per supported form. `pc` is the byte
// offset of THIS instruction inside the assembled image; labels resolve to
// byte offsets in the same space. Returns the emitted word.
// ---------------------------------------------------------------------------

/// Per-instruction encode outcome: one emitted word or one honest failure.
pub const EncodeResult = union(enum) {
    word: u32,
    err: AsmError,
};

const EncodeCtx = struct {
    pc: u32,
    labels: []const Label,
    line: usize,
};

fn encode(ctx: *const EncodeCtx, mnem_in: []const u8, ops: Operands) EncodeResult {
    var lower_buf: [12]u8 = undefined;
    if (mnem_in.len == 0 or mnem_in.len > lower_buf.len) return fail(ctx.line, .bad_instruction);
    for (mnem_in, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
    const mnem = lower_buf[0..mnem_in.len];

    // Conditional branches: "b.eq" etc.
    if (mnem[0] == 'b' and mnem.len > 2 and mnem[1] == '.') {
        const cond = parse_cond(mnem[2..]) orelse return fail(ctx.line, .bad_instruction);
        if (ops.count != 1) return fail(ctx.line, .missing_operand);
        const target = resolve_branch_label(ctx, ops.items[0]) orelse return fail(ctx.line, .unknown_label);
        return .{ .word = enc_b_cond(cond, target) };
    }

    if (eq(mnem, "nop")) {
        if (ops.count != 0) return fail(ctx.line, .extra_operand);
        return .{ .word = nop_enc };
    }
    if (eq(mnem, "ret")) {
        if (ops.count == 0) return .{ .word = enc_ret(30) };
        if (ops.count != 1) return fail(ctx.line, .extra_operand);
        const rn = parse_register(ops.items[0]) orelse return fail(ctx.line, .bad_register);
        return .{ .word = enc_ret(rn) };
    }
    if (eq(mnem, "svc") or eq(mnem, "brk")) {
        if (ops.count != 1) return fail(ctx.line, .missing_operand);
        const imm = parse_immediate(ops.items[0]) orelse return fail(ctx.line, .bad_immediate);
        if (imm > 0xFFFF) return fail(ctx.line, .bad_immediate);
        const word = if (eq(mnem, "svc")) enc_svc(@intCast(imm)) else enc_brk(@intCast(imm));
        return .{ .word = word };
    }
    if (eq(mnem, "b")) {
        if (ops.count != 1) return fail(ctx.line, .missing_operand);
        const target = resolve_branch_label(ctx, ops.items[0]) orelse return fail(ctx.line, .unknown_label);
        return .{ .word = enc_b(target - @as(i32, @intCast(ctx.pc))) };
    }
    if (eq(mnem, "bl")) {
        if (ops.count != 1) return fail(ctx.line, .missing_operand);
        const target = resolve_branch_label(ctx, ops.items[0]) orelse return fail(ctx.line, .unknown_label);
        return .{ .word = enc_bl(target - @as(i32, @intCast(ctx.pc))) };
    }
    if (eq(mnem, "blr")) {
        if (ops.count != 1) return fail(ctx.line, .missing_operand);
        const rn = parse_register(ops.items[0]) orelse return fail(ctx.line, .bad_register);
        return .{ .word = enc_blr(rn) };
    }
    if (eq(mnem, "cbz") or eq(mnem, "cbnz")) {
        if (ops.count != 2) return fail(ctx.line, .missing_operand);
        const rt = parse_register(ops.items[0]) orelse return fail(ctx.line, .bad_register);
        const target = resolve_branch_label(ctx, ops.items[1]) orelse return fail(ctx.line, .unknown_label);
        const rel = target - @as(i32, @intCast(ctx.pc));
        return .{ .word = if (eq(mnem, "cbz")) enc_cbz(rt, rel) else enc_cbnz(rt, rel) };
    }
    if (eq(mnem, "adr") or eq(mnem, "adrp")) {
        if (ops.count != 2) return fail(ctx.line, .missing_operand);
        const rd = parse_register(ops.items[0]) orelse return fail(ctx.line, .bad_register);
        const target = resolve_branch_label(ctx, ops.items[1]) orelse return fail(ctx.line, .unknown_label);
        if (eq(mnem, "adr")) {
            return .{ .word = enc_adr(rd, target - @as(i32, @intCast(ctx.pc))) };
        }
        const page_of = struct {
            fn f(v: i32) i32 {
                return v & ~@as(i32, 0xFFF);
            }
        }.f;
        const page_delta = page_of(target) -% page_of(@intCast(ctx.pc));
        return .{ .word = enc_adrp(rd, page_delta >> 12) };
    }
    if (eq(mnem, "ldr")) {
        return encode_ldr_str(ctx, ops, true);
    }
    if (eq(mnem, "str")) {
        return encode_ldr_str(ctx, ops, false);
    }
    if (eq(mnem, "ldrb")) {
        return encode_ldrb_strb(ctx, ops, true);
    }
    if (eq(mnem, "strb")) {
        return encode_ldrb_strb(ctx, ops, false);
    }
    if (eq(mnem, "movz") or eq(mnem, "movk")) {
        if (ops.count < 2) return fail(ctx.line, .missing_operand);
        const rd = parse_register(ops.items[0]) orelse return fail(ctx.line, .bad_register);
        const imm = parse_immediate(ops.items[1]) orelse return fail(ctx.line, .bad_immediate);
        if (imm > 0xFFFF) return fail(ctx.line, .bad_immediate);
        var hw: u2 = 0;
        if (ops.count >= 3) {
            // Accept ", lsl #16" / ", lsl #48".
            var buf: [16]u8 = undefined;
            const tok = ops.items[2];
            if (tok.len == 0 or tok.len > buf.len) return fail(ctx.line, .bad_immediate);
            for (tok, 0..) |c, i| buf[i] = std.ascii.toLower(c);
            const t = buf[0..tok.len];
            const shift: u64 = blk: {
                if (std.mem.startsWith(u8, t, "lsl #")) break :blk parse_immediate(t[5..]) orelse return fail(ctx.line, .bad_immediate);
                if (std.mem.eql(u8, t, "lsl")) break :blk 0;
                return fail(ctx.line, .bad_immediate);
            };
            if (shift != 0 and shift != 16 and shift != 32 and shift != 48) return fail(ctx.line, .bad_immediate);
            hw = @intCast(shift >> 4);
        }
        return .{ .word = if (eq(mnem, "movz")) enc_movz(rd, @intCast(imm), hw) else enc_movk(rd, @intCast(imm), hw) };
    }
    if (eq(mnem, "mov")) {
        if (ops.count != 2) return fail(ctx.line, .missing_operand);
        const rd = parse_register(ops.items[0]) orelse return fail(ctx.line, .bad_register);
        // Immediate ("#imm" or bare imm) → MOVZ alias; register →
        // ORR rd, xzr, rm.
        if (parse_immediate(ops.items[1])) |imm| {
            if (imm > 0xFFFF) return fail(ctx.line, .bad_immediate);
            return .{ .word = enc_movz(rd, @intCast(imm), 0) };
        }
        const rm = parse_register(ops.items[1]) orelse return fail(ctx.line, .bad_register);
        return .{ .word = enc_mov_reg(rd, rm) };
    }
    if (eq(mnem, "add") or eq(mnem, "sub")) {
        if (ops.count != 3) return fail(ctx.line, .missing_operand);
        const rd = parse_register(ops.items[0]) orelse return fail(ctx.line, .bad_register);
        const rn = parse_register(ops.items[1]) orelse return fail(ctx.line, .bad_register);
        if (parse_immediate(ops.items[2])) |imm| {
            if (imm > 4095) return fail(ctx.line, .bad_immediate);
            return .{ .word = if (eq(mnem, "add")) enc_add_imm(rn, rd, @intCast(imm)) else enc_sub_imm(rn, rd, @intCast(imm)) };
        }
        const rm = parse_register(ops.items[2]) orelse return fail(ctx.line, .bad_register);
        return .{ .word = if (eq(mnem, "add")) enc_add_reg(rn, rm, rd) else enc_sub_reg(rn, rm, rd) };
    }
    if (eq(mnem, "cmp")) {
        if (ops.count != 2) return fail(ctx.line, .missing_operand);
        const rn = parse_register(ops.items[0]) orelse return fail(ctx.line, .bad_register);
        if (parse_immediate(ops.items[1])) |imm| {
            if (imm > 4095) return fail(ctx.line, .bad_immediate);
            return .{ .word = enc_cmp_imm(rn, @intCast(imm)) };
        }
        const rm = parse_register(ops.items[1]) orelse return fail(ctx.line, .bad_register);
        return .{ .word = enc_cmp_reg(rn, rm) };
    }
    if (eq(mnem, "and") or eq(mnem, "orr") or eq(mnem, "eor")) {
        if (ops.count != 3) return fail(ctx.line, .missing_operand);
        const rd = parse_register(ops.items[0]) orelse return fail(ctx.line, .bad_register);
        const rn = parse_register(ops.items[1]) orelse return fail(ctx.line, .bad_register);
        const rm = parse_register(ops.items[2]) orelse return fail(ctx.line, .bad_register);
        if (eq(mnem, "and")) return .{ .word = enc_and_reg(rn, rm, rd) };
        if (eq(mnem, "orr")) return .{ .word = enc_orr_reg(rn, rm, rd) };
        return .{ .word = enc_eor_reg(rn, rm, rd) };
    }
    if (eq(mnem, "mul") or eq(mnem, "udiv")) {
        if (ops.count != 3) return fail(ctx.line, .missing_operand);
        const rd = parse_register(ops.items[0]) orelse return fail(ctx.line, .bad_register);
        const rn = parse_register(ops.items[1]) orelse return fail(ctx.line, .bad_register);
        const rm = parse_register(ops.items[2]) orelse return fail(ctx.line, .bad_register);
        return .{ .word = if (eq(mnem, "mul")) enc_mul(rn, rm, rd) else enc_udiv(rn, rm, rd) };
    }
    if (eq(mnem, "lsl") or eq(mnem, "lsr")) {
        if (ops.count != 3) return fail(ctx.line, .missing_operand);
        const rd = parse_register(ops.items[0]) orelse return fail(ctx.line, .bad_register);
        const rn = parse_register(ops.items[1]) orelse return fail(ctx.line, .bad_register);
        if (parse_immediate(ops.items[2])) |imm| {
            if (imm > 63) return fail(ctx.line, .bad_immediate);
            return .{ .word = if (eq(mnem, "lsl")) enc_lsl(rn, rd, @intCast(imm)) else enc_lsr(rn, rd, @intCast(imm)) };
        }
        const rm = parse_register(ops.items[2]) orelse return fail(ctx.line, .bad_register);
        return .{ .word = if (eq(mnem, "lsl")) enc_lsl_reg(rn, rm, rd) else enc_lsr_reg(rn, rm, rd) };
    }
    return fail(ctx.line, .bad_instruction);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn fail(line: usize, kind: ErrorKind) EncodeResult {
    return .{ .err = .{ .kind = kind, .line = line } };
}

/// Resolve a label operand to an absolute byte offset (the emitted-image
/// address space: byte offsets from the start of the code).
fn resolve_branch_label(ctx: *const EncodeCtx, token: []const u8) ?i32 {
    const off = label_offset(ctx.labels, token) orelse return null;
    return @intCast(off);
}

fn encode_ldr_str(ctx: *const EncodeCtx, ops: Operands, is_load: bool) EncodeResult {
    if (ops.count != 2) return fail(ctx.line, .missing_operand);
    const rt = parse_register(ops.items[0]) orelse return fail(ctx.line, .bad_register);

    // Literal form: "ldr x0, label" (load-only).
    if (is_load and ops.items[1][0] != '[') {
        const target = resolve_branch_label(ctx, ops.items[1]) orelse return fail(ctx.line, .unknown_label);
        return .{ .word = enc_ldr_literal(rt, target - @as(i32, @intCast(ctx.pc))) };
    }

    // Memory form: [xn] or [xn, #imm].
    const mem = ops.items[1];
    if (mem.len < 3 or mem[0] != '[') return fail(ctx.line, .bad_operand_form);
    const close = std.mem.indexOfScalar(u8, mem, ']') orelse return fail(ctx.line, .bad_operand_form);
    if (close != mem.len - 1) return fail(ctx.line, .bad_operand_form);
    const inner = mem[1..close];
    var base_tok = inner;
    var imm12: u12 = 0;
    if (std.mem.indexOfScalar(u8, inner, ',')) |ci| {
        base_tok = std.mem.trim(u8, inner[0..ci], " \t");
        const imm_tok = std.mem.trim(u8, inner[ci + 1 ..], " \t");
        const imm = parse_immediate(imm_tok) orelse return fail(ctx.line, .bad_immediate);
        if (imm % 8 != 0 or imm / 8 > 4095) return fail(ctx.line, .bad_immediate); // scaled
        imm12 = @intCast(imm / 8);
    }
    const rn = parse_register(base_tok) orelse return fail(ctx.line, .bad_register);
    return .{ .word = if (is_load) enc_ldr(rn, rt, imm12) else enc_str(rn, rt, imm12) };
}

fn encode_ldrb_strb(ctx: *const EncodeCtx, ops: Operands, is_load: bool) EncodeResult {
    if (ops.count != 2) return fail(ctx.line, .missing_operand);
    const rt = parse_register(ops.items[0]) orelse return fail(ctx.line, .bad_register);
    const mem = ops.items[1];
    if (mem.len < 3 or mem[0] != '[') return fail(ctx.line, .bad_operand_form);
    const close = std.mem.indexOfScalar(u8, mem, ']') orelse return fail(ctx.line, .bad_operand_form);
    if (close != mem.len - 1) return fail(ctx.line, .bad_operand_form);
    const inner = mem[1..close];
    var base_tok = inner;
    var imm12: u12 = 0;
    if (std.mem.indexOfScalar(u8, inner, ',')) |ci| {
        base_tok = std.mem.trim(u8, inner[0..ci], " \t");
        const imm_tok = std.mem.trim(u8, inner[ci + 1 ..], " \t");
        const imm = parse_immediate(imm_tok) orelse return fail(ctx.line, .bad_immediate);
        if (imm > 4095) return fail(ctx.line, .bad_immediate);
        imm12 = @intCast(imm);
    }
    const rn = parse_register(base_tok) orelse return fail(ctx.line, .bad_register);
    return .{ .word = if (is_load) enc_ldrb(rn, rt, imm12) else enc_strb(rn, rt, imm12) };
}

// ---------------------------------------------------------------------------
// The two-pass driver: pass 1 collects labels and counts words (every
// instruction is exactly 4 bytes, so sizes are known without encoding);
// pass 2 emits. `_start` is remembered for the ELF entry.
//
// Statements are separated by newlines OR semicolons — the semicolon lets
// a one-line `write PROG.S a; b; c` stage a whole program through the
// serial console, where embedded newlines cannot travel.
// ---------------------------------------------------------------------------

const StmtIter = struct {
    rest: []const u8,
    /// 1-based index of the statement LAST returned.
    line: usize = 0,

    fn next(self: *StmtIter) ?[]const u8 {
        while (self.rest.len > 0) {
            const found = std.mem.indexOfAny(u8, self.rest, "\n;");
            if (found == null) {
                const stmt = self.rest;
                self.rest = self.rest[stmt.len..];
                self.line += 1;
                return stmt;
            }
            const idx = found.?;
            const stmt = self.rest[0..idx];
            self.rest = self.rest[idx + 1 ..];
            if (strip_comment(stmt).len == 0 and stmt.len == 0) continue; // empty separator
            self.line += 1;
            return stmt;
        }
        return null;
    }
};

/// Assemble `src` into `code` (must be >= code_max bytes). Every failure
/// names its 1-based statement line (semicolons start new lines).
pub fn assemble(src: []const u8, code: []u8) AsmResult {
    var labels: [max_labels]Label = @as([max_labels]Label, @splat(@as(Label, .{})));
    var label_count: usize = 0;
    var entry_off: ?u32 = null;
    var words: usize = 0; // 4-byte units emitted so far

    // ---- pass 1: labels -------------------------------------------------
    var lines: usize = 0;
    var it = StmtIter{ .rest = src };
    while (it.next()) |raw| {
        if (strip_comment(raw).len == 0) continue;
        lines = it.line;
        if (lines > max_lines) return .{ .err = .{ .kind = .too_many_lines, .line = lines } };
        if (raw.len > max_line_len) return .{ .err = .{ .kind = .line_too_long, .line = lines } };
        const parsed = classify(raw) orelse continue;
        // A leading label was stripped by classify(); recover its name.
        const striped = strip_comment(raw);
        if (label_def(striped)) |name| {
            if (label_count == max_labels) return .{ .err = .{ .kind = .too_many_labels, .line = lines } };
            for (labels[0..label_count]) |l| {
                if (l.matches(name)) return .{ .err = .{ .kind = .duplicate_label, .line = lines } };
            }
            labels[label_count].set(name, @intCast(words * 4));
            if (eq(name, "_start")) entry_off = @intCast(words * 4);
            label_count += 1;
        }
        if (parsed.mnemonic == null) continue;
        words += 1;
    }

    if (entry_off == null) return .{ .err = .{ .kind = .no_start_label, .line = lines } };

    // ---- pass 2: emit ----------------------------------------------------
    var out_words: usize = 0;
    var it2 = StmtIter{ .rest = src };
    while (it2.next()) |raw| {
        if (strip_comment(raw).len == 0) continue;
        const line_no = it2.line;
        const parsed = classify(raw) orelse continue;
        if (parsed.mnemonic == null) continue;
        const mnem = parsed.mnemonic.?;

        if (eq(mnem, ".word")) {
            if (parsed.ops.count != 1) return .{ .err = .{ .kind = .missing_operand, .line = line_no } };
            const v = parse_immediate(parsed.ops.items[0]) orelse return .{ .err = .{ .kind = .bad_immediate, .line = line_no } };
            if (out_words * 4 + 4 > code_max) return .{ .err = .{ .kind = .code_overflow, .line = line_no } };
            std.mem.writeInt(u32, code[out_words * 4 ..][0..4], @truncate(v), .little);
            out_words += 1;
            continue;
        }
        if (out_words * 4 + 4 > code_max) return .{ .err = .{ .kind = .code_overflow, .line = line_no } };

        const ctx = EncodeCtx{
            .pc = @intCast(out_words * 4),
            .labels = labels[0..label_count],
            .line = line_no,
        };
        switch (encode(&ctx, mnem, parsed.ops)) {
            .word => |word| {
                std.mem.writeInt(u32, code[out_words * 4 ..][0..4], word, .little);
                out_words += 1;
            },
            .err => |e| return .{ .err = e },
        }
    }

    return .{ .ok = .{ .bytes = out_words * 4, .entry_off = entry_off.? } };
}

pub fn error_name(kind: ErrorKind) []const u8 {
    return switch (kind) {
        .too_many_lines => "too many source lines",
        .line_too_long => "line too long",
        .too_many_labels => "too many labels",
        .duplicate_label => "duplicate label",
        .unknown_label => "unknown label",
        .bad_instruction => "unknown instruction",
        .bad_register => "bad register",
        .bad_immediate => "bad immediate",
        .missing_operand => "missing operand",
        .extra_operand => "extra operand",
        .bad_operand_form => "bad operand form",
        .code_overflow => "output exceeds 4096 bytes",
        .no_start_label => "no '_start' label defined",
    };
}

// ---------------------------------------------------------------------------
// Entry point: exec ASM.BIN <source> [<output>]
// ---------------------------------------------------------------------------

pub export fn _start(argc: usize, argv: ?[*]const [256]u8) callconv(.c) noreturn {
    // M34 HF6 (issue #740): bare names route to the host share (the ESP
    // is gone).
    var src_path_buf: [40]u8 = @as([40]u8, @splat(@as(u8, 0)));
    @memcpy(src_path_buf[0..6], "PROG.S");
    var out_path_buf: [40]u8 = @as([40]u8, @splat(@as(u8, 0)));
    @memcpy(out_path_buf[0..7], "OUT.ELF");
    var src_len: usize = 6;
    var out_len: usize = 7;

    if (argc >= 1) {
        if (argv) |slots| {
            copy_arg(&src_path_buf, &src_len, slots[0]);
        }
    }
    if (argc >= 2) {
        if (argv) |slots| {
            copy_arg(&out_path_buf, &out_len, slots[1]);
        }
    }

    run(src_path_buf[0..src_len], out_path_buf[0..out_len]);
}

fn copy_arg(dst: *[40]u8, len: *usize, slot: [256]u8) void {
    const n = std.mem.indexOfScalar(u8, &slot, 0) orelse slot.len;
    const take = @min(n, dst.len);
    @memcpy(dst[0..take], slot[0..take]);
    len.* = take;
}

/// Per-run work areas. A DSK1 flat image maps its TEXT pages only — there
/// is no writable .data/.bss aperture for this program — so ALL workspace
/// lives on the 16 KiB EL0 task stack: 4 KiB source + 4 KiB code +
/// 4180 B image = ~12.4 KiB, inside the budget with headroom.
const source_cap: usize = 4096;

fn run(src_path: []const u8, out_path: []const u8) noreturn {
    var source_buf: [source_cap]u8 = undefined;
    var code_buf: [code_max]u8 = undefined;
    var image_buf: [elf_code_offset + code_max]u8 = undefined;

    // Read the source.
    const fd = file_open(src_path, MODE_READ);
    if (fd < 0) {
        console_puts("asm: cannot open source\n");
        sys_exit(1);
    }
    const n = file_read(@intCast(fd), &source_buf);
    file_close(@intCast(fd));
    if (n <= 0) {
        console_puts("asm: empty or unreadable source\n");
        sys_exit(2);
    }

    switch (assemble(source_buf[0..@intCast(n)], &code_buf)) {
        .err => |e| {
            var msg: [80]u8 = undefined;
            var pos: usize = 0;
            pos = append_str(&msg, pos, "asm: line ");
            pos = append_str(&msg, pos, fmt_u64(msg[pos..], @intCast(e.line)));
            pos = append_str(&msg, pos, ": ");
            pos = append_str(&msg, pos, error_name(e.kind));
            msg[pos] = '\n';
            console_puts(msg[0 .. pos + 1]);
            sys_exit(3);
        },
        .ok => |res| {
            const total = build_elf32(code_buf[0..res.bytes], res.entry_off, &image_buf) catch {
                console_puts("asm: image too large\n");
                sys_exit(4);
            };
            const ofd = file_open(out_path, MODE_CREATE | MODE_WRITE);
            if (ofd < 0) {
                console_puts("asm: cannot create output\n");
                sys_exit(5);
            }
            const w = file_write(@intCast(ofd), image_buf[0..total]);
            file_close(@intCast(ofd));
            if (w != total) {
                console_puts("asm: short write\n");
                sys_exit(6);
            }
            var ok_msg: [64]u8 = undefined;
            var pos: usize = 0;
            pos = append_str(&ok_msg, pos, "asm: wrote ");
            pos = append_str(&ok_msg, pos, fmt_u64(ok_msg[pos..], @intCast(total)));
            pos = append_str(&ok_msg, pos, " bytes to ");
            pos = append_str(&ok_msg, pos, out_path);
            ok_msg[pos] = '\n';
            console_puts(ok_msg[0 .. pos + 1]);
            sys_exit(0);
        },
    }
}

fn append_str(buf: []u8, pos: usize, src: []const u8) usize {
    const take = @min(src.len, buf.len - pos);
    @memcpy(buf[pos .. pos + take], src[0..take]);
    return pos + take;
}

fn fmt_u64(buf: []u8, value: u64) []const u8 {
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
    }
    return buf[i..];
}

// ---------------------------------------------------------------------------
// Host tests — each encoding pinned against a known AArch64 word, plus the
// two-pass label resolution, bounds, and the ELF32 container.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn first_word(instr: []const u8) u32 {
    var src: [256]u8 = undefined;
    const prefix = "_start:\n";
    @memcpy(src[0..prefix.len], prefix);
    @memcpy(src[prefix.len..][0..instr.len], instr);
    var code: [code_max]u8 = undefined;
    _ = assemble(src[0 .. prefix.len + instr.len], &code).ok;
    return std.mem.readInt(u32, code[0..4], .little);
}

test "asm: single-instruction encodings match known words" {
    try testing.expectEqual(@as(u32, 0xD2800540), first_word("mov x0, #42")); // 42<<5|0
    try testing.expectEqual(@as(u32, 0xD2800028), first_word("movz x8, #1"));
    try testing.expectEqual(@as(u32, 0xF2A04001), first_word("movk x1, #0x200, lsl #16")); // hw=1, 0x200<<5
    try testing.expectEqual(@as(u32, 0xD4000001), first_word("svc #0"));
    try testing.expectEqual(@as(u32, 0xD503201F), first_word("nop"));
    try testing.expectEqual(@as(u32, 0xD65F03C0), first_word("ret"));
    try testing.expectEqual(@as(u32, 0xD65F0000 | (5 << 5)), first_word("ret x5"));
    // mov x1, x2 == orr x1, xzr, x2
    try testing.expectEqual(@as(u32, 0xAA0203E1), first_word("mov x1, x2")); // rm=2<<16 | xzr<<5 | 1
    try testing.expectEqual(@as(u32, 0x91002020), first_word("add x0, x1, #8")); // 8<<10 | x1<<5
    try testing.expectEqual(@as(u32, 0x8B010001), first_word("add x1, x0, x1")); // rm<<16 | rn<<5 | rd
    try testing.expectEqual(@as(u32, 0xD1004022), first_word("sub x2, x1, #16")); // 16<<10 | x1<<5 | 2
    try testing.expectEqual(@as(u32, 0xCB010002), first_word("sub x2, x0, x1"));
    try testing.expectEqual(@as(u32, 0xF100147F), first_word("cmp x3, #5")); // 5<<10 | x3<<5 | xzr
    try testing.expectEqual(@as(u32, 0xEB01007F), first_word("cmp x3, x1")); // rm | x3<<5 | xzr
    try testing.expectEqual(@as(u32, 0x8A010000), first_word("and x0, x0, x1"));
    try testing.expectEqual(@as(u32, 0xAA010000), first_word("orr x0, x0, x1"));
    try testing.expectEqual(@as(u32, 0xCA010000), first_word("eor x0, x0, x1"));
    try testing.expectEqual(@as(u32, 0xD63F0040), first_word("blr x2"));
    try testing.expectEqual(@as(u32, 0xD4200000), first_word("brk #0"));

    // Expanded instructions
    try testing.expectEqual(@as(u32, 0x9B027C20), first_word("mul x0, x1, x2"));
    try testing.expectEqual(@as(u32, 0x9AC20820), first_word("udiv x0, x1, x2"));
    try testing.expectEqual(@as(u32, 0xD37CEC20), first_word("lsl x0, x1, #4"));
    try testing.expectEqual(@as(u32, 0xD344FC20), first_word("lsr x0, x1, #4"));
    try testing.expectEqual(@as(u32, 0x9AC22020), first_word("lsl x0, x1, x2"));
    try testing.expectEqual(@as(u32, 0x9AC22420), first_word("lsr x0, x1, x2"));
}
test "asm: branch offsets resolve forward and backward through labels" {
    var code: [code_max]u8 = undefined;
    const r = assemble("_start:\n  b done\n  nop\n  nop\ndone:\n  ret\n", &code).ok;
    try testing.expectEqual(@as(usize, 16), r.bytes);
    try testing.expectEqual(@as(u32, 0x14000003), std.mem.readInt(u32, code[0..4], .little));
    _ = assemble("_start:\n  nop\n  nop\n  nop\n  bl _start\n", &code).ok;
    // bl backward at pc=12 to _start: offset -12 bytes → -3 words
    try testing.expectEqual(@as(u32, 0x97FFFFFD), std.mem.readInt(u32, code[12..16], .little)); // -3 words
}

test "asm: conditional branches encode cond in the low bits" {
    var code: [code_max]u8 = undefined;
    const r = assemble("_start:\n  b.ne skip\n  nop\nskip:\n  ret\n", &code).ok;
    try testing.expectEqual(@as(usize, 12), r.bytes);
    // b.ne +8 bytes → imm19 = 2, cond ne = 1
    try testing.expectEqual(@as(u32, 0x54000041), std.mem.readInt(u32, code[0..4], .little));
}

test "asm: adr and ldr literal compute pc-relative offsets" {
    var code: [code_max]u8 = undefined;
    const src = "_start:\n  adr x1, msg\n  b done\nmsg:\n  .word 0x12345678\ndone:\n  ret\n";
    const r = assemble(src, &code).ok;
    try testing.expectEqual(@as(usize, 16), r.bytes); // 3 instrs + 1 word
    try testing.expectEqual(@as(u32, 0x10000041), std.mem.readInt(u32, code[0..4], .little)); // adr msg: +8
    try testing.expectEqual(@as(u32, 0x14000002), std.mem.readInt(u32, code[4..8], .little)); // b +8
    try testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, code[8..12], .little)); // .word LE
    _ = assemble("_start:\n  ldr x0, val\n  b done\nval:\n  .word 99\ndone:\n  ret\n", &code).ok;
    // ldr literal from val (+8 bytes) → imm19 = 2 << 5
    try testing.expectEqual(@as(u32, 0x58000040), std.mem.readInt(u32, code[0..4], .little));
}
test "asm: ldr/str memory forms scale their immediate" {
    try testing.expectEqual(@as(u32, 0xF9400020), first_word("ldr x0, [x1]"));
    try testing.expectEqual(@as(u32, 0xF9400420), first_word("ldr x0, [x1, #8]")); // (8/8)<<10
    try testing.expectEqual(@as(u32, 0xF9000420), first_word("str x0, [x1, #8]"));
    try testing.expectEqual(@as(u32, 0xF90003E0), first_word("str x0, [sp]"));

    // Byte forms (unscaled immediate)
    try testing.expectEqual(@as(u32, 0x39400820), first_word("ldrb w0, [x1, #2]"));
    try testing.expectEqual(@as(u32, 0x39000820), first_word("strb w0, [x1, #2]"));
}

test "asm: register and immediate parsing covers aliases" {
    try testing.expectEqual(@as(?u5, 31), parse_register("xzr"));
    try testing.expectEqual(@as(?u5, 31), parse_register("wzr"));
    try testing.expectEqual(@as(?u5, 31), parse_register("sp"));
    try testing.expectEqual(@as(?u5, 30), parse_register("lr"));
    try testing.expectEqual(@as(?u5, 30), parse_register("x30"));
    try testing.expectEqual(@as(?u5, null), parse_register("x31"));
    try testing.expectEqual(@as(?u5, null), parse_register("q7"));
    try testing.expectEqual(@as(?u64, 42), parse_immediate("#42"));
    try testing.expectEqual(@as(?u64, 42), parse_immediate("#0x2a"));
    try testing.expectEqual(@as(?u64, null), parse_immediate("#"));
}

test "asm: full hello-style program assembles end-to-end" {
    var code: [code_max]u8 = undefined;
    const src =
        "// tiny syscall program\n" ++
        "_start:\n" ++
        "  mov x8, #1     // sys_write\n" ++
        "  mov x0, #1     // fd 1\n" ++
        "  adr x1, hello\n" ++
        "  mov x2, #4     // len\n" ++
        "  svc #0\n" ++
        "  mov x0, #7     // exit status\n" ++
        "  mov x8, #3     // sys_exit\n" ++
        "  svc #0\n" ++
        "hello:\n" ++
        "  .word 0x6c6c6568\n";
    const r = assemble(src, &code).ok;
    try testing.expectEqual(@as(usize, 36), r.bytes); // 8 instrs + 1 word
    try testing.expectEqual(@as(u32, 0), r.entry_off); // _start == image start
    // adr x1, hello at pc=8 targeting 32 → +24
    try testing.expectEqual(@as(u32, 0x100000C1), std.mem.readInt(u32, code[8..12], .little));
}
fn expect_err(src: []const u8, kind: ErrorKind) !void {
    var code: [code_max]u8 = undefined;
    switch (assemble(src, &code)) {
        .err => |e| try testing.expectEqual(kind, e.kind),
        .ok => return error.TestUnexpectedResult,
    }
}

test "asm: honest bounded failures name their line" {
    var code: [code_max]u8 = undefined;
    // No _start.
    switch (assemble("nop\n", &code)) {
        .err => |e| {
            try testing.expectEqual(ErrorKind.no_start_label, e.kind);
            try testing.expectEqual(@as(usize, 1), e.line);
        },
        .ok => return error.TestUnexpectedResult,
    }
    // Unknown instruction at line 2.
    switch (assemble("_start:\n  frobnicate x0\n", &code)) {
        .err => |e| {
            try testing.expectEqual(ErrorKind.bad_instruction, e.kind);
            try testing.expectEqual(@as(usize, 2), e.line);
        },
        .ok => return error.TestUnexpectedResult,
    }
    try expect_err("_start:\nnop\nagain:\nnop\nagain:\nnop\n", .duplicate_label);
    try expect_err("_start:\n  b nowhere\n", .unknown_label);
    try expect_err("_start:\n  mov q9, #1\n", .bad_register);
    try expect_err("_start:\n  add x0, x1, #99999\n", .bad_immediate);
    try expect_err("_start:\n  svc\n", .missing_operand);
}

test "asm: source bounds enforced" {
    var code: [code_max]u8 = undefined;
    // Over-long single line.
    var long_line: [120]u8 = undefined;
    @memset(&long_line, 'x');
    long_line[0] = 'n';
    long_line[1] = 'o';
    long_line[2] = 'p';
    switch (assemble(&long_line, &code)) {
        .err => |e| try testing.expectEqual(ErrorKind.line_too_long, e.kind),
        .ok => {},
    }
}
test "asm: too many lines refused" {
    var code: [code_max]u8 = undefined;
    var src: [8192]u8 = undefined;
    var n: usize = 0;
    n += append_str(src[n..], 0, "_start:\n");
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        if (n + 5 > src.len) break;
        n += append_str(src[n..], 0, "nop\n");
    }
    switch (assemble(src[0..n], &code)) {
        .err => |e| try testing.expectEqual(ErrorKind.too_many_lines, e.kind),
        .ok => {},
    }
}

test "asm: output stays well inside code_max under the line bound" {
    var code: [code_max]u8 = undefined;
    // 256 lines x 4 B = 1024 B: the per-line bound keeps every legal
    // source strictly inside the 4096-byte guard (defense-in-depth for
    // any future multi-word directive).
    var src: [8192]u8 = undefined;
    var n: usize = 0;
    n += append_str(src[n..], 0, "_start: nop\n");
    var i: usize = 0;
    while (i < 255) : (i += 1) n += append_str(src[n..], 0, "nop\n");
    switch (assemble(src[0..n], &code)) {
        .ok => |ok| try testing.expectEqual(@as(usize, 1024), ok.bytes),
        .err => return error.TestUnexpectedResult,
    }
}

test "asm: ELF32 container matches the D1 loader contract" {
    var code: [code_max]u8 = undefined;
    const r = assemble("_start:\n  mov x0, #42\n  ret\n", &code).ok;
    var image: [elf_code_offset + code_max]u8 = undefined;
    const total = try build_elf32(code[0..r.bytes], r.entry_off, &image);
    try testing.expectEqual(@as(usize, elf_code_offset + r.bytes), total);
    try testing.expectEqualSlices(u8, "\x7fELF", image[0..4]);
    try testing.expectEqual(@as(u8, 1), image[4]); // ELF32
    try testing.expectEqual(@as(u16, 0xB7), std.mem.readInt(u16, image[18..20], .little)); // AArch64
    try testing.expectEqual(image_base + r.entry_off, std.mem.readInt(u32, image[24..28], .little));
    try testing.expectEqual(@as(u32, elf_header_size), std.mem.readInt(u32, image[28..32], .little)); // e_phoff
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, image[44..46], .little)); // e_phnum
    const p = elf_header_size;
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, image[p..][0..4], .little)); // PT_LOAD
    try testing.expectEqual(@as(u32, image_base), std.mem.readInt(u32, image[p + 8 ..][0..4], .little));
    try testing.expectEqual(@as(u32, @intCast(r.bytes)), std.mem.readInt(u32, image[p + 20 ..][0..4], .little));
    try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, image[p + 24 ..][0..4], .little)); // R+X
    // The code lands at elf_code_offset with entry-relative placement.
    const word0 = std.mem.readInt(u32, image[elf_code_offset..][0..4], .little);
    try testing.expectEqual(first_word("mov x0, #42\n"), word0);
}
