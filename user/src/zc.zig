//! census (M188e, #3190): ZC.BIN — gate-referenced: live-zc, live-snake; also a build.zig host-test root.
//! The in-guest compiler (zc): compiles a Zig subset to AArch64 ELF32.
//! Bounded: <=32 functions, <=512 lines, zero heap.
//!
//! Usage: exec ZC.BIN [<source.z>...] [<output.elf>] — since Z3a (issue
//! #758) the last argv word is the output and every word before it is a
//! source (multi-file, flat cross-file symbol table); no args compiles
//! /host/MAIN.Z to /host/MAIN.ELF.

const std = @import("std");
const asmenc = @import("lib/asmenc.zig");

// Encoders and constants from asmenc
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
const Cond = asmenc.Cond;
const enc_ldr = asmenc.enc_ldr;
const enc_str = asmenc.enc_str;
const enc_ldrb = asmenc.enc_ldrb;
const enc_strb = asmenc.enc_strb;
const enc_ret = asmenc.enc_ret;
const enc_blr = asmenc.enc_blr;
const enc_svc = asmenc.enc_svc;
const enc_mul = asmenc.enc_mul;
const enc_udiv = asmenc.enc_udiv;
const enc_lsl = asmenc.enc_lsl;
const enc_lsr = asmenc.enc_lsr;
const enc_lsl_reg = asmenc.enc_lsl_reg;
const enc_lsr_reg = asmenc.enc_lsr_reg;
const enc_adr = asmenc.enc_adr;
const build_elf32 = asmenc.build_elf32;
const build_elf32_with_data = asmenc.build_elf32_with_data;
const elf_code_offset = asmenc.elf_code_offset;

// ---------------------------------------------------------------------------
// EL0 syscall seam
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

fn print_err(msg: []const u8, line: usize, detail: []const u8) void {
    var buf: [128]u8 = undefined;
    var pos: usize = 0;
    pos = append_str(&buf, pos, "Compile error at line ");
    var num_buf: [20]u8 = undefined;
    pos = append_str(&buf, pos, fmt_u64(&num_buf, line));
    pos = append_str(&buf, pos, ": ");
    pos = append_str(&buf, pos, msg);
    if (detail.len > 0) {
        pos = append_str(&buf, pos, " '");
        pos = append_str(&buf, pos, detail);
        pos = append_str(&buf, pos, "'");
    }
    pos = append_str(&buf, pos, "\n");
    console_puts(buf[0..pos]);
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
// Lexer
// ---------------------------------------------------------------------------
const TokenKind = enum {
    eof,
    invalid,
    keyword_fn,
    keyword_pub,
    keyword_let,
    keyword_var,
    keyword_const,
    keyword_if,
    keyword_else,
    keyword_while,
    keyword_return,
    keyword_defer,
    keyword_struct,
    keyword_enum,
    keyword_for,
    keyword_switch,
    keyword_break,
    keyword_continue,
    ident,
    number,
    string_lit,
    char_lit,
    dot,
    double_dot,
    triple_dot,
    equal_greater,
    at,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_bracket,
    r_bracket,
    comma,
    semicolon,
    colon,
    equal,
    plus,
    minus,
    star,
    slash,
    percent,
    ampersand,
    pipe,
    caret,
    excl,
    double_equal,
    excl_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    less_less,
    greater_greater,
    double_ampersand,
    double_pipe,
};

const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: usize,
};

const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,

    fn next(self: *Tokenizer) Token {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\n') {
                self.pos += 1;
                self.line += 1;
                continue;
            }
            if (std.ascii.isWhitespace(c)) {
                self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            break;
        }
        if (self.pos >= self.src.len) return Token{ .kind = .eof, .text = "", .line = self.line };

        const start = self.pos;
        const c = self.src[self.pos];
        self.pos += 1;

        switch (c) {
            '.' => {
                if (self.pos + 1 < self.src.len and self.src[self.pos] == '.' and self.src[self.pos + 1] == '.') {
                    self.pos += 2;
                    return Token{ .kind = .triple_dot, .text = self.src[start..self.pos], .line = self.line };
                }
                if (self.pos < self.src.len and self.src[self.pos] == '.') {
                    self.pos += 1;
                    return Token{ .kind = .double_dot, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .dot, .text = self.src[start..self.pos], .line = self.line };
            },
            '@' => return Token{ .kind = .at, .text = self.src[start..self.pos], .line = self.line },
            '(' => return Token{ .kind = .l_paren, .text = self.src[start..self.pos], .line = self.line },
            ')' => return Token{ .kind = .r_paren, .text = self.src[start..self.pos], .line = self.line },
            '{' => return Token{ .kind = .l_brace, .text = self.src[start..self.pos], .line = self.line },
            '}' => return Token{ .kind = .r_brace, .text = self.src[start..self.pos], .line = self.line },
            '[' => return Token{ .kind = .l_bracket, .text = self.src[start..self.pos], .line = self.line },
            ']' => return Token{ .kind = .r_bracket, .text = self.src[start..self.pos], .line = self.line },
            ',' => return Token{ .kind = .comma, .text = self.src[start..self.pos], .line = self.line },
            ';' => return Token{ .kind = .semicolon, .text = self.src[start..self.pos], .line = self.line },
            ':' => return Token{ .kind = .colon, .text = self.src[start..self.pos], .line = self.line },
            '+' => return Token{ .kind = .plus, .text = self.src[start..self.pos], .line = self.line },
            '-' => return Token{ .kind = .minus, .text = self.src[start..self.pos], .line = self.line },
            '*' => return Token{ .kind = .star, .text = self.src[start..self.pos], .line = self.line },
            '/' => return Token{ .kind = .slash, .text = self.src[start..self.pos], .line = self.line },
            '%' => return Token{ .kind = .percent, .text = self.src[start..self.pos], .line = self.line },
            '^' => return Token{ .kind = .caret, .text = self.src[start..self.pos], .line = self.line },
            '&' => {
                if (self.pos < self.src.len and self.src[self.pos] == '&') {
                    self.pos += 1;
                    return Token{ .kind = .double_ampersand, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .ampersand, .text = self.src[start..self.pos], .line = self.line };
            },
            '|' => {
                if (self.pos < self.src.len and self.src[self.pos] == '|') {
                    self.pos += 1;
                    return Token{ .kind = .double_pipe, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .pipe, .text = self.src[start..self.pos], .line = self.line };
            },
            '!' => {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return Token{ .kind = .excl_equal, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .excl, .text = self.src[start..self.pos], .line = self.line };
            },
            '=' => {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return Token{ .kind = .double_equal, .text = self.src[start..self.pos], .line = self.line };
                }
                if (self.pos < self.src.len and self.src[self.pos] == '>') {
                    self.pos += 1;
                    return Token{ .kind = .equal_greater, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .equal, .text = self.src[start..self.pos], .line = self.line };
            },
            '<' => {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return Token{ .kind = .less_equal, .text = self.src[start..self.pos], .line = self.line };
                }
                if (self.pos < self.src.len and self.src[self.pos] == '<') {
                    self.pos += 1;
                    return Token{ .kind = .less_less, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .less, .text = self.src[start..self.pos], .line = self.line };
            },
            '>' => {
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return Token{ .kind = .greater_equal, .text = self.src[start..self.pos], .line = self.line };
                }
                if (self.pos < self.src.len and self.src[self.pos] == '>') {
                    self.pos += 1;
                    return Token{ .kind = .greater_greater, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .greater, .text = self.src[start..self.pos], .line = self.line };
            },
            '"' => {
                while (self.pos < self.src.len and self.src[self.pos] != '"') {
                    if (self.pos + 1 < self.src.len and self.src[self.pos] == '\\') self.pos += 1;
                    self.pos += 1;
                }
                if (self.pos < self.src.len and self.src[self.pos] == '"') {
                    self.pos += 1;
                    return Token{ .kind = .string_lit, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .invalid, .text = self.src[start..self.pos], .line = self.line };
            },
            '\'' => {
                if (self.pos < self.src.len and self.src[self.pos] != '\'') {
                    self.pos += 1;
                    if (self.pos < self.src.len and self.src[self.pos] == '\'') {
                        self.pos += 1;
                        return Token{ .kind = .char_lit, .text = self.src[start..self.pos], .line = self.line };
                    }
                }
                return Token{ .kind = .invalid, .text = self.src[start..self.pos], .line = self.line };
            },
            else => {
                if (std.ascii.isAlphabetic(c) or c == '_') {
                    while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) self.pos += 1;
                    const text = self.src[start..self.pos];
                    if (std.mem.eql(u8, text, "pub")) return Token{ .kind = .keyword_pub, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "fn")) return Token{ .kind = .keyword_fn, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "let")) return Token{ .kind = .keyword_let, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "var")) return Token{ .kind = .keyword_var, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "const")) return Token{ .kind = .keyword_const, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "if")) return Token{ .kind = .keyword_if, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "else")) return Token{ .kind = .keyword_else, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "while")) return Token{ .kind = .keyword_while, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "for")) return Token{ .kind = .keyword_for, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "switch")) return Token{ .kind = .keyword_switch, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "break")) return Token{ .kind = .keyword_break, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "continue")) return Token{ .kind = .keyword_continue, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "return")) return Token{ .kind = .keyword_return, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "defer")) return Token{ .kind = .keyword_defer, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "struct")) return Token{ .kind = .keyword_struct, .text = text, .line = self.line };
                    if (std.mem.eql(u8, text, "enum")) return Token{ .kind = .keyword_enum, .text = text, .line = self.line };
                    return Token{ .kind = .ident, .text = text, .line = self.line };
                }
                if (std.ascii.isDigit(c)) {
                    if (c == '0' and self.pos < self.src.len and (self.src[self.pos] == 'x' or self.src[self.pos] == 'X')) {
                        self.pos += 1;
                        while (self.pos < self.src.len and std.ascii.isHex(self.src[self.pos])) self.pos += 1;
                    } else {
                        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
                    }
                    return Token{ .kind = .number, .text = self.src[start..self.pos], .line = self.line };
                }
                return Token{ .kind = .invalid, .text = self.src[start..self.pos], .line = self.line };
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Compiler State & Symbols
// ---------------------------------------------------------------------------
const Function = struct {
    name: []const u8,
    address: u32,
    param_count: usize,
};

const LocalVar = struct {
    name: []const u8,
    offset: usize,
    is_array: bool = false,
    array_len: usize = 0,
    elem_size: usize = 8,
    is_struct: bool = false,
    struct_idx: usize = 0,
    is_ptr: bool = false,
    ptr_elem_size: usize = 8,
    ptr_is_struct: bool = false,
    ptr_struct_idx: usize = 0,
    is_slice: bool = false,
    is_fnptr: bool = false,
};

const Field = struct {
    name: []const u8,
    offset: usize,
    size: usize,
};

const StructDef = struct {
    name: []const u8,
    fields: [8]Field = undefined,
    field_count: usize = 0,
    size: usize = 0,
};

const EnumMember = struct {
    name: []const u8,
    value: u64,
};

const EnumDef = struct {
    name: []const u8,
    members: [16]EnumMember = undefined,
    member_count: usize = 0,
};

const CallPatch = struct {
    caller_pc: u32,
    target_func_idx: usize,
};

pub var code: [32768]u8 = undefined;
var code_len: usize = 0;

var data_buf: [32768]u8 = undefined;
var data_len: usize = 0;

const StringPatch = struct {
    code_pc: usize,
    data_off: usize,
    rd: u5,
};

var string_patches: [256]StringPatch = undefined;
var string_patches_count: usize = 0;

var tokens_buf: [2048]Token = undefined;
var tokens_count: usize = 0;

var functions: [32]Function = undefined;
var functions_count: usize = 0;

var locals: [64]LocalVar = undefined;
var locals_count: usize = 0;
var frame_size: usize = 0;

var structs: [8]StructDef = undefined;
var structs_count: usize = 0;

var enums: [8]EnumDef = undefined;
var enums_count: usize = 0;

var call_patches: [64]CallPatch = undefined;
var call_patches_count: usize = 0;

// ---------------------------------------------------------------------------
// Z2b (issue #757): scope-exit defers + function pointers.
//
// A `defer` statement is NOT compiled where it appears: its token position is
// recorded and the statement is skipped, then it is compiled again when its
// scope exits (reverse registration order), or inline on a `return` that
// unwinds the scope. Defer bodies are restricted to expression / simple-
// assignment statements (no declarations, no control flow, no nested defer).
// Entries survive their inline emission (return paths) so the same defers are
// also emitted at the scope's fallthrough end — exactly one path executes.
//
// Function pointers: *const fn(<params>) <ret> types parse to an 8-byte code
// address; `&fn` emits a PC-relative ADR patched once every function address
// is known; a call through a function-pointer local/param parks the callee
// address, pushes the arguments, pops the args into x0.., and dispatches with
// blr (the callee is popped into x16, the intra-call scratch register).
// ---------------------------------------------------------------------------
const DeferEntry = struct {
    stmt_start: usize,
};

const DeferScope = struct {
    defer_base: usize,
};

const FnAddrPatch = struct {
    code_pc: usize,
    func_idx: usize,
};

var defer_entries: [48]DeferEntry = undefined;
var defer_entries_count: usize = 0;
var defer_scopes: [16]DeferScope = undefined;
var defer_scope_depth: usize = 0;

var fn_addr_patches: [32]FnAddrPatch = undefined;
var fn_addr_patches_count: usize = 0;

fn emit(word: u32) void {
    std.mem.writeInt(u32, code[code_len..][0..4], word, .little);
    code_len += 4;
}

fn unescape_string(raw: []const u8, out: []u8) usize {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return 0;
    const content = raw[1 .. raw.len - 1];
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < content.len and out_idx < out.len) {
        if (content[i] == '\\' and i + 1 < content.len) {
            i += 1;
            switch (content[i]) {
                'n' => {
                    out[out_idx] = '\n';
                    out_idx += 1;
                },
                'r' => {
                    out[out_idx] = '\r';
                    out_idx += 1;
                },
                't' => {
                    out[out_idx] = '\t';
                    out_idx += 1;
                },
                '0' => {
                    out[out_idx] = 0;
                    out_idx += 1;
                },
                '\\' => {
                    out[out_idx] = '\\';
                    out_idx += 1;
                },
                '"' => {
                    out[out_idx] = '"';
                    out_idx += 1;
                },
                '\'' => {
                    out[out_idx] = '\'';
                    out_idx += 1;
                },
                else => {
                    out[out_idx] = content[i];
                    out_idx += 1;
                },
            }
        } else {
            out[out_idx] = content[i];
            out_idx += 1;
        }
        i += 1;
    }
    return out_idx;
}

fn addString(raw: []const u8) anyerror!struct { off: usize, len: usize } {
    var tmp: [4096]u8 = undefined;
    const unescaped_len = unescape_string(raw, &tmp);
    if (data_len + unescaped_len > data_buf.len) return error.CompileError;
    const off = data_len;
    @memcpy(data_buf[off .. off + unescaped_len], tmp[0..unescaped_len]);
    data_len += unescaped_len;
    return .{ .off = off, .len = unescaped_len };
}

fn emitStringAdr(rd: u5, data_off: usize) void {
    string_patches[string_patches_count] = StringPatch{
        .code_pc = code_len,
        .data_off = data_off,
        .rd = rd,
    };
    string_patches_count += 1;
    emit(0);
}

fn emitLoadImmediate(rd: u5, val: u64) void {
    const v0: u16 = @intCast(val & 0xFFFF);
    const v1: u16 = @intCast((val >> 16) & 0xFFFF);
    const v2: u16 = @intCast((val >> 32) & 0xFFFF);
    const v3: u16 = @intCast((val >> 48) & 0xFFFF);
    emit(enc_movz(rd, v0, 0));
    if (v1 != 0 or v2 != 0 or v3 != 0) emit(enc_movk(rd, v1, 1));
    if (v2 != 0 or v3 != 0) emit(enc_movk(rd, v2, 2));
    if (v3 != 0) emit(enc_movk(rd, v3, 3));
}

fn elemShift(elem_size: usize) u6 {
    return switch (elem_size) {
        1 => 0,
        2 => 1,
        4 => 2,
        8 => 3,
        else => 0,
    };
}

fn lookupFunc(name: []const u8) ?usize {
    var i: usize = 0;
    while (i < functions_count) : (i += 1) {
        if (std.mem.eql(u8, functions[i].name, name)) return i;
    }
    return null;
}

fn lookupLocal(name: []const u8) ?usize {
    var i: usize = locals_count;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, locals[i].name, name)) return locals[i].offset;
    }
    return null;
}

fn lookupLocalVar(name: []const u8) ?*LocalVar {
    var i: usize = locals_count;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, locals[i].name, name)) return &locals[i];
    }
    return null;
}

fn lookupStruct(name: []const u8) ?*StructDef {
    var i: usize = 0;
    while (i < structs_count) : (i += 1) {
        if (std.mem.eql(u8, structs[i].name, name)) return &structs[i];
    }
    return null;
}

fn lookupEnum(name: []const u8) ?*EnumDef {
    var i: usize = 0;
    while (i < enums_count) : (i += 1) {
        if (std.mem.eql(u8, enums[i].name, name)) return &enums[i];
    }
    return null;
}

fn typeSize(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "u8")) return 1;
    if (std.mem.eql(u8, name, "u16")) return 2;
    if (std.mem.eql(u8, name, "u32")) return 4;
    if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "i64")) return 8;
    if (lookupStruct(name)) |sd| return sd.size;
    if (lookupEnum(name)) |_| return 8;
    return null;
}

fn registerForwardFunc(name: []const u8) !usize {
    if (lookupFunc(name)) |idx| return idx;
    if (functions_count >= functions.len) return error.TooManyFunctions;
    functions[functions_count] = Function{ .name = name, .address = 0, .param_count = 0 };
    const idx = functions_count;
    functions_count += 1;
    return idx;
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------
const Parser = struct {
    tokens: []const Token,
    idx: usize = 0,

    fn peek(self: *Parser) TokenKind {
        if (self.idx >= self.tokens.len) return .eof;
        return self.tokens[self.idx].kind;
    }

    fn currentToken(self: *Parser) Token {
        if (self.idx >= self.tokens.len) return Token{ .kind = .eof, .text = "", .line = 0 };
        return self.tokens[self.idx];
    }

    fn advance(self: *Parser) Token {
        const t = self.currentToken();
        self.idx += 1;
        return t;
    }

    fn expect(self: *Parser, kind: TokenKind) anyerror!Token {
        const t = self.currentToken();
        if (t.kind != kind) {
            print_err("unexpected token", t.line, t.text);
            return error.CompileError;
        }
        self.idx += 1;
        return t;
    }

    fn accept(self: *Parser, kind: TokenKind) bool {
        if (self.peek() == kind) {
            self.idx += 1;
            return true;
        }
        return false;
    }
};

const ParsedType = struct {
    name: []const u8 = "",
    is_ptr: bool = false,
    ptr_elem_size: usize = 8,
    is_struct: bool = false,
    struct_idx: usize = 0,
    ptr_is_struct: bool = false,
    ptr_struct_idx: usize = 0,
    is_array: bool = false,
    array_len: usize = 0,
    elem_size: usize = 8,
    is_slice: bool = false,
    is_fnptr: bool = false,
};

fn parseType(p: *Parser) anyerror!ParsedType {
    var res = ParsedType{};
    if (p.accept(.star)) {
        res.is_ptr = true;
        _ = p.accept(.keyword_const);
        if (p.peek() == .keyword_fn) {
            // Z2b: function-pointer type, e.g. *const fn(u64, u64) u64.
            // The params and return type are consumed so the type parses
            // under host zig 0.17 and in-guest alike; the value itself is a
            // plain 8-byte code address.
            res.is_fnptr = true;
            _ = p.advance(); // 'fn'
            _ = try p.expect(.l_paren);
            while (p.peek() != .r_paren and p.peek() != .eof) _ = p.advance();
            _ = try p.expect(.r_paren);
            _ = try parseType(p); // return type (discarded)
            return res;
        }
        const id_tok = try p.expect(.ident);
        res.name = id_tok.text;
        if (lookupStruct(id_tok.text)) |sd| {
            res.ptr_is_struct = true;
            var i: usize = 0;
            while (i < structs_count) : (i += 1) {
                if (std.mem.eql(u8, structs[i].name, id_tok.text)) {
                    res.ptr_struct_idx = i;
                    break;
                }
            }
            res.ptr_elem_size = sd.size;
        } else {
            res.ptr_elem_size = typeSize(id_tok.text) orelse 8;
        }
    } else if (p.accept(.l_bracket)) {
        if (p.accept(.star)) {
            _ = try p.expect(.r_bracket);
            res.is_ptr = true;
            _ = p.accept(.keyword_const);
            const id_tok = try p.expect(.ident);
            res.name = id_tok.text;
            res.ptr_elem_size = typeSize(id_tok.text) orelse 1;
        } else if (p.peek() == .r_bracket) {
            _ = p.advance(); // ']'
            res.is_slice = true;
            _ = p.accept(.keyword_const);
            const id_tok = try p.expect(.ident);
            res.name = id_tok.text;
            res.elem_size = typeSize(id_tok.text) orelse 1;
            res.ptr_elem_size = res.elem_size;
        } else {
            const len_tok = try p.expect(.number);
            res.array_len = std.fmt.parseInt(usize, len_tok.text, 0) catch return error.CompileError;
            _ = try p.expect(.r_bracket);
            _ = p.accept(.keyword_const);
            const id_tok = try p.expect(.ident);
            res.name = id_tok.text;
            res.elem_size = typeSize(id_tok.text) orelse 1;
            res.is_array = true;
        }
    } else {
        const id_tok = try p.expect(.ident);
        res.name = id_tok.text;
        if (lookupStruct(id_tok.text)) |sd| {
            res.is_struct = true;
            var i: usize = 0;
            while (i < structs_count) : (i += 1) {
                if (std.mem.eql(u8, structs[i].name, id_tok.text)) {
                    res.struct_idx = i;
                    break;
                }
            }
            res.elem_size = sd.size;
        } else {
            res.elem_size = typeSize(id_tok.text) orelse 8;
        }
    }
    return res;
}

fn countParams(tokens: []const Token, start_idx: usize) usize {
    var idx = start_idx;
    if (tokens[idx].kind == .r_paren) return 0;
    // Nesting-aware: a function-pointer param type carries its own parens
    // and commas (e.g. f: *const fn(u64, u64) u64), which must not count.
    var depth: usize = 0;
    var commas: usize = 0;
    while (idx < tokens.len) : (idx += 1) {
        const k = tokens[idx].kind;
        switch (k) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_bracket, .r_brace => {
                if (depth > 0) depth -= 1;
            },
            .r_paren => {
                if (depth == 0) break;
                depth -= 1;
            },
            .comma => {
                if (depth == 0) commas += 1;
            },
            else => {},
        }
    }
    return commas + 1;
}

fn pushDeferScope() anyerror!void {
    if (defer_scope_depth >= defer_scopes.len) return error.CompileError;
    defer_scopes[defer_scope_depth] = DeferScope{ .defer_base = defer_entries_count };
    defer_scope_depth += 1;
}

fn popDeferScope() void {
    if (defer_scope_depth == 0) return;
    defer_scope_depth -= 1;
    defer_entries_count = defer_scopes[defer_scope_depth].defer_base;
}

/// Compile the defers registered in `scope_idx` (reverse order). Does NOT
/// pop the scope: return paths emit entries inline and the same entries are
/// emitted again at the scope's fallthrough end.
fn emitScopeDefers(p: *Parser, scope_idx: usize) anyerror!void {
    const base = defer_scopes[scope_idx].defer_base;
    const end = if (scope_idx + 1 < defer_scope_depth) defer_scopes[scope_idx + 1].defer_base else defer_entries_count;
    var i = end;
    while (i > base) {
        i -= 1;
        const saved_idx = p.idx;
        p.idx = defer_entries[i].stmt_start;
        try compileStatement(p);
        p.idx = saved_idx;
    }
}

/// Run every currently open scope's defers, innermost first — the unwind a
/// `return` performs (LIFO per scope, inner scopes before outer ones).
fn emitOpenScopeDefers(p: *Parser) anyerror!void {
    var d = defer_scope_depth;
    while (d > 0) {
        d -= 1;
        try emitScopeDefers(p, d);
    }
}

// ---------------------------------------------------------------------------
// M70c S3 (issue #1455): `break` / `continue` — the two loop-control
// statements the Z4a dialect boundary listed as non-goals.
//
// A compile-time loop stack. Each `while`/`for` pushes the defer scope it
// opened for its body plus two patch lists: where its `break` jumps land (the
// loop exit) and where its `continue` jumps land. The target pc is not known
// when the statement is compiled — for a `for` the target is the step BELOW
// the body — so both kinds park a placeholder `b` and are back-patched by
// `patchLoop` once the loop's shape is final.
//
// Two semantics ride on the loop stack rather than on a label:
//   * both jumps run every defer still open inside the body (innermost scope
//     first, the body's own scope included), so a `break` cannot skip a
//     cleanup — the same LIFO unwind a body fallthrough performs;
//   * `continue` targets the *condition* for `while` but the *step* for a
//     `for`, because a range/array loop's increment lives at the bottom of
//     the body. Jumping to the condition instead would skip the increment and
//     spin forever (the `s3` corpus fixture pins this behaviorally).
// ---------------------------------------------------------------------------
const LoopCtx = struct {
    /// Defer scope this loop opened for its body (`pushDeferScope`d before
    /// `pushLoop`). A `break`/`continue` unwinds every scope at or inside it.
    scope_idx: usize,
    break_patches: [16]usize,
    break_count: usize,
    continue_patches: [16]usize,
    continue_count: usize,
};

var loop_stack: [8]LoopCtx = undefined;
var loop_depth: usize = 0;

fn pushLoop(scope_idx: usize) anyerror!void {
    if (loop_depth >= loop_stack.len) return error.CompileError;
    loop_stack[loop_depth] = LoopCtx{
        .scope_idx = scope_idx,
        .break_patches = undefined,
        .break_count = 0,
        .continue_patches = undefined,
        .continue_count = 0,
    };
    loop_depth += 1;
}

fn recordLoopJump(is_break: bool, jump_idx: usize) anyerror!void {
    const ctx = &loop_stack[loop_depth - 1];
    const list = if (is_break) &ctx.break_patches else &ctx.continue_patches;
    const count = if (is_break) &ctx.break_count else &ctx.continue_count;
    if (count.* >= list.len) return error.CompileError;
    list[count.*] = jump_idx;
    count.* += 1;
}

fn patchBranch(idx: usize, target: usize) void {
    const offset = @as(i32, @intCast(target)) - @as(i32, @intCast(idx));
    std.mem.writeInt(u32, code[idx..][0..4], enc_b(offset), .little);
}

/// Back-patch this loop's parked jumps and pop it. `continue_pc` is the loop's
/// re-entry point (its condition for `while`, its step for a `for`).
fn patchLoop(continue_pc: usize, exit_pc: usize) void {
    loop_depth -= 1;
    const ctx = &loop_stack[loop_depth];
    var i: usize = 0;
    while (i < ctx.break_count) : (i += 1) patchBranch(ctx.break_patches[i], exit_pc);
    i = 0;
    while (i < ctx.continue_count) : (i += 1) patchBranch(ctx.continue_patches[i], continue_pc);
}

/// Compile `break` / `continue`: unwind this loop body's open defer scopes,
/// then park one unconditional branch for `patchLoop` to aim.
fn compileLoopJump(p: *Parser, is_break: bool) anyerror!void {
    const tok = p.advance();
    if (loop_depth == 0) {
        print_err(if (is_break) "break outside a loop" else "continue outside a loop", tok.line, tok.text);
        return error.CompileError;
    }
    const loop_scope = loop_stack[loop_depth - 1].scope_idx;
    var d = defer_scope_depth;
    while (d > loop_scope) {
        d -= 1;
        try emitScopeDefers(p, d);
    }
    _ = p.accept(.semicolon) or p.accept(.comma);
    const jump_idx = code_len;
    emit(0);
    try recordLoopJump(is_break, jump_idx);
}

/// Consume tokens up to and including the parameter list's closing paren,
/// honoring nested parens/brackets/braces (fn-pointer param types).
fn skipToDeclCloseParen(p: *Parser) void {
    var depth: usize = 0;
    while (p.peek() != .eof) {
        const k = p.peek();
        if (k == .r_paren and depth == 0) {
            _ = p.advance();
            return;
        }
        if (k == .l_paren or k == .l_bracket or k == .l_brace) {
            depth += 1;
        } else if (k == .r_paren or k == .r_bracket or k == .r_brace) {
            if (depth > 0) depth -= 1;
        }
        _ = p.advance();
    }
}

/// Skip a deferred statement's tokens (up to its `;`/`,` at nesting depth 0)
/// without compiling it — it is compiled later at scope exit.
fn skipDeferBody(p: *Parser) void {
    var depth: usize = 0;
    while (p.peek() != .eof) {
        const t = p.advance();
        switch (t.kind) {
            .l_paren, .l_bracket, .l_brace => depth += 1,
            .r_paren, .r_bracket, .r_brace => {
                if (depth > 0) depth -= 1;
            },
            .semicolon, .comma => {
                if (depth == 0) return;
            },
            else => {},
        }
    }
}

fn compileExpr(p: *Parser) anyerror!void {
    try parseLogicalOr(p);
}

fn parseLogicalOr(p: *Parser) anyerror!void {
    try parseLogicalAnd(p);
    while (p.accept(.double_pipe)) {
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseLogicalAnd(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_orr_reg(1, 0, 0));
    }
}

fn parseLogicalAnd(p: *Parser) anyerror!void {
    try parseBitwiseOr(p);
    while (p.accept(.double_ampersand)) {
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseBitwiseOr(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_and_reg(1, 0, 0));
    }
}

fn parseBitwiseOr(p: *Parser) anyerror!void {
    try parseBitwiseXor(p);
    while (p.accept(.pipe)) {
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseBitwiseXor(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_orr_reg(1, 0, 0));
    }
}

fn parseBitwiseXor(p: *Parser) anyerror!void {
    try parseBitwiseAnd(p);
    while (p.accept(.caret)) {
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseBitwiseAnd(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_eor_reg(1, 0, 0));
    }
}

fn parseBitwiseAnd(p: *Parser) anyerror!void {
    try parseEquality(p);
    while (p.accept(.ampersand)) {
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseEquality(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_and_reg(1, 0, 0));
    }
}

fn parseEquality(p: *Parser) anyerror!void {
    try parseRelational(p);
    while (true) {
        const is_eq = p.accept(.double_equal);
        const is_ne = !is_eq and p.accept(.excl_equal);
        if (!is_eq and !is_ne) break;
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseRelational(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_cmp_reg(1, 0));
        if (is_eq) {
            emit(enc_b_cond(.eq, 12));
        } else {
            emit(enc_b_cond(.ne, 12));
        }
        emit(enc_movz(0, 0, 0));
        emit(enc_b(8));
        emit(enc_movz(0, 1, 0));
    }
}

fn parseRelational(p: *Parser) anyerror!void {
    try parseShift(p);
    while (true) {
        const is_lt = p.accept(.less);
        const is_le = !is_lt and p.accept(.less_equal);
        const is_gt = !is_lt and !is_le and p.accept(.greater);
        const is_ge = !is_lt and !is_le and !is_gt and p.accept(.greater_equal);
        if (!is_lt and !is_le and !is_gt and !is_ge) break;
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseShift(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        emit(enc_cmp_reg(1, 0));
        if (is_lt) {
            emit(enc_b_cond(.lt, 12));
        } else if (is_le) {
            emit(enc_b_cond(.le, 12));
        } else if (is_gt) {
            emit(enc_b_cond(.gt, 12));
        } else {
            emit(enc_b_cond(.ge, 12));
        }
        emit(enc_movz(0, 0, 0));
        emit(enc_b(8));
        emit(enc_movz(0, 1, 0));
    }
}

fn parseShift(p: *Parser) anyerror!void {
    try parseAdditive(p);
    while (true) {
        const is_lsl = p.accept(.less_less);
        const is_lsr = !is_lsl and p.accept(.greater_greater);
        if (!is_lsl and !is_lsr) break;
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseAdditive(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        if (is_lsl) {
            emit(enc_lsl_reg(1, 0, 0));
        } else {
            emit(enc_lsr_reg(1, 0, 0));
        }
    }
}

fn parseAdditive(p: *Parser) anyerror!void {
    try parseMultiplicative(p);
    while (true) {
        const is_add = p.accept(.plus);
        const is_sub = !is_add and p.accept(.minus);
        if (!is_add and !is_sub) break;
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseMultiplicative(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        if (is_add) {
            emit(enc_add_reg(1, 0, 0));
        } else {
            emit(enc_sub_reg(1, 0, 0));
        }
    }
}

fn parseMultiplicative(p: *Parser) anyerror!void {
    try parseUnary(p);
    while (true) {
        const is_mul = p.accept(.star);
        const is_div = !is_mul and p.accept(.slash);
        if (!is_mul and !is_div) break;
        emit(enc_sub_imm(31, 31, 16));
        emit(enc_str(31, 0, 0));
        try parseUnary(p);
        emit(enc_ldr(31, 1, 0));
        emit(enc_add_imm(31, 31, 16));
        if (is_mul) {
            emit(enc_mul(1, 0, 0));
        } else {
            emit(enc_udiv(1, 0, 0));
        }
    }
}

fn parseUnary(p: *Parser) anyerror!void {
    if (p.accept(.minus)) {
        try parseUnary(p);
        emit(enc_sub_reg(31, 0, 0));
    } else if (p.accept(.excl)) {
        try parseUnary(p);
        emit(enc_cmp_imm(0, 0));
        emit(enc_b_cond(.eq, 12));
        emit(enc_movz(0, 0, 0));
        emit(enc_b(8));
        emit(enc_movz(0, 1, 0));
    } else {
        try parsePrimary(p);
    }
}

fn parsePrimary(p: *Parser) anyerror!void {
    const t = p.advance();
    switch (t.kind) {
        .number => {
            const val = std.fmt.parseInt(u64, t.text, 0) catch return error.CompileError;
            emitLoadImmediate(0, val);
        },
        .char_lit => {
            const val = t.text[1];
            emitLoadImmediate(0, val);
        },
        .string_lit => {
            const res = try addString(t.text);
            emitStringAdr(0, res.off);
            emit(enc_movz(1, @intCast(res.len), 0));
        },
        .at => {
            const builtin_tok = try p.expect(.ident);
            _ = try p.expect(.l_paren);
            try compileExpr(p);
            _ = try p.expect(.r_paren);
            // Z3b (issue #759): the stdz subset is dual-dialect (valid Zig
            // 0.17 AND the zc dialect) so the same sources host-parse; host
            // Zig type-checks u8 stores, which forces @intCast at byte
            // boundaries. In zc every value is a word, so intCast — like the
            // enum casts — is an identity op.
            if (!std.mem.eql(u8, builtin_tok.text, "backingInt") and
                !std.mem.eql(u8, builtin_tok.text, "fromBackingInt") and
                !std.mem.eql(u8, builtin_tok.text, "intCast"))
            {
                print_err("unknown zc builtin", builtin_tok.line, builtin_tok.text);
                return error.CompileError;
            }
            // All three casts are identity ops in zc.
        },
        .keyword_switch => {
            p.idx -= 1;
            try compileSwitch(p, true);
        },
        .ident => {
            if (p.accept(.dot)) {
                if (p.accept(.star)) {
                    const var_ptr = lookupLocalVar(t.text) orelse {
                        print_err("undefined identifier", t.line, t.text);
                        return error.CompileError;
                    };
                    emit(enc_ldr(19, 1, @intCast(var_ptr.offset / 8)));
                    if (var_ptr.ptr_elem_size == 1) {
                        emit(enc_ldrb(1, 0, 0));
                    } else {
                        emit(enc_ldr(1, 0, 0));
                    }
                } else {
                    const member_tok = try p.expect(.ident);
                    if (lookupEnum(t.text)) |ed| {
                        var mval: u64 = 0;
                        var mfound = false;
                        for (ed.members[0..ed.member_count]) |m| {
                            if (std.mem.eql(u8, m.name, member_tok.text)) {
                                mval = m.value;
                                mfound = true;
                                break;
                            }
                        }
                        if (!mfound) {
                            print_err("unknown enum member", member_tok.line, member_tok.text);
                            return error.CompileError;
                        }
                        emitLoadImmediate(0, mval);
                    } else if (std.mem.eql(u8, t.text, "zc")) {
                        if (std.mem.eql(u8, member_tok.text, "print")) {
                            _ = try p.expect(.l_paren);
                            if (p.peek() == .string_lit) {
                                const str_tok = p.advance();
                                const res = try addString(str_tok.text);
                                emit(enc_movz(0, 1, 0)); // stdout fd = 1
                                emitStringAdr(1, res.off); // x1 = ptr
                                emit(enc_movz(2, @intCast(res.len), 0)); // x2 = len
                                emit(enc_movz(8, 1, 0)); // sys_write
                                emit(enc_svc(0));
                            } else {
                                try compileExpr(p);
                                emit(enc_mov_reg(2, 1));
                                emit(enc_mov_reg(1, 0));
                                emit(enc_movz(0, 1, 0));
                                emit(enc_movz(8, 1, 0));
                                emit(enc_svc(0));
                            }
                            _ = try p.expect(.r_paren);
                        } else if (std.mem.eql(u8, member_tok.text, "exit")) {
                            _ = try p.expect(.l_paren);
                            try compileExpr(p);
                            _ = try p.expect(.r_paren);
                            emit(enc_movz(8, 3, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "write")) {
                            _ = try p.expect(.l_paren);
                            try compileExpr(p); // fd into x0
                            _ = try p.expect(.comma);
                            if (p.peek() == .string_lit) {
                                const str_tok = p.advance();
                                const res = try addString(str_tok.text);
                                emit(enc_sub_imm(31, 31, 16));
                                emit(enc_str(31, 0, 0)); // save fd
                                emitStringAdr(1, res.off); // ptr into x1
                                emit(enc_movz(2, @intCast(res.len), 0)); // len into x2
                                emit(enc_ldr(31, 0, 0)); // restore fd
                                emit(enc_add_imm(31, 31, 16));
                                emit(enc_movz(8, 1, 0)); // sys_write
                                emit(enc_svc(0));
                            } else {
                                emit(enc_sub_imm(31, 31, 16));
                                emit(enc_str(31, 0, 0)); // save fd on stack
                                try compileExpr(p); // evaluates 2nd arg into x0
                                if (p.accept(.comma)) {
                                    emit(enc_sub_imm(31, 31, 16));
                                    emit(enc_str(31, 0, 0)); // save 2nd arg on stack
                                    try compileExpr(p); // evaluates 3rd arg into x0
                                    emit(enc_mov_reg(2, 0)); // len -> x2
                                    emit(enc_ldr(31, 1, 0)); // restore 2nd arg (ptr) -> x1
                                    emit(enc_add_imm(31, 31, 16));
                                    emit(enc_ldr(31, 0, 0)); // restore 1st arg (fd) -> x0
                                    emit(enc_add_imm(31, 31, 16));
                                } else {
                                    emit(enc_mov_reg(2, 1));
                                    emit(enc_mov_reg(1, 0));
                                    emit(enc_ldr(31, 0, 0));
                                    emit(enc_add_imm(31, 31, 16));
                                }
                                emit(enc_movz(8, 1, 0));
                                emit(enc_svc(0));
                            }
                            _ = try p.expect(.r_paren);
                        } else if (std.mem.eql(u8, member_tok.text, "yield")) {
                            _ = try p.expect(.l_paren);
                            _ = try p.expect(.r_paren);
                            emit(enc_movz(8, 2, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "sleep")) {
                            _ = try p.expect(.l_paren);
                            try compileExpr(p);
                            _ = try p.expect(.r_paren);
                            emit(enc_movz(8, 4, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "mmap")) {
                            // Z2a: sys_mmap (slot 63) over the prelude seam.
                            // Anonymous RW private region, eager MAP_POPULATE so
                            // kernel-side file copy_in/out can touch the pages.
                            _ = try p.expect(.l_paren);
                            try compileExpr(p); // len -> x0
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 0, 0)); // save len
                            emit(enc_movz(0, 0, 0)); // x0 = addr hint 0
                            emit(enc_ldr(31, 1, 0)); // x1 = len
                            emit(enc_add_imm(31, 31, 16));
                            emit(enc_movz(2, 3, 0)); // x2 = prot RW
                            emit(enc_movz(3, 0x8022, 0)); // x3 = ANON|PRIVATE|POPULATE
                            _ = try p.expect(.r_paren);
                            emit(enc_movz(8, 63, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "file_open")) {
                            _ = try p.expect(.l_paren);
                            if (p.peek() != .string_lit) {
                                print_err("file_open path must be a string literal", p.currentToken().line, p.currentToken().text);
                                return error.CompileError;
                            }
                            const str_tok = p.advance();
                            const res = try addString(str_tok.text);
                            emitStringAdr(0, res.off); // x0 = path ptr
                            emit(enc_movz(1, @intCast(res.len), 0)); // x1 = path len
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 0, 0)); // save path ptr
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 1, 0)); // save path len
                            _ = try p.expect(.comma);
                            try compileExpr(p); // flags -> x0
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 0, 0)); // save flags
                            _ = try p.expect(.r_paren);
                            emit(enc_ldr(31, 2, 0)); // x2 = flags
                            emit(enc_add_imm(31, 31, 16));
                            emit(enc_ldr(31, 1, 0)); // x1 = path len
                            emit(enc_add_imm(31, 31, 16));
                            emit(enc_ldr(31, 0, 0)); // x0 = path ptr
                            emit(enc_add_imm(31, 31, 16));
                            emit(enc_movz(8, 23, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "file_read")) {
                            _ = try p.expect(.l_paren);
                            var arg_count: usize = 0;
                            if (p.peek() != .r_paren) {
                                try compileExpr(p);
                                emit(enc_sub_imm(31, 31, 16));
                                emit(enc_str(31, 0, 0));
                                arg_count += 1;
                                while (p.accept(.comma)) {
                                    try compileExpr(p);
                                    emit(enc_sub_imm(31, 31, 16));
                                    emit(enc_str(31, 0, 0));
                                    arg_count += 1;
                                }
                            }
                            _ = try p.expect(.r_paren);
                            var i = arg_count;
                            while (i > 0) {
                                i -= 1;
                                emit(enc_ldr(31, @intCast(i), 0));
                                emit(enc_add_imm(31, 31, 16));
                            }
                            emit(enc_movz(8, 24, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "file_write")) {
                            _ = try p.expect(.l_paren);
                            var arg_count: usize = 0;
                            if (p.peek() != .r_paren) {
                                try compileExpr(p);
                                emit(enc_sub_imm(31, 31, 16));
                                emit(enc_str(31, 0, 0));
                                arg_count += 1;
                                while (p.accept(.comma)) {
                                    try compileExpr(p);
                                    emit(enc_sub_imm(31, 31, 16));
                                    emit(enc_str(31, 0, 0));
                                    arg_count += 1;
                                }
                            }
                            _ = try p.expect(.r_paren);
                            var i = arg_count;
                            while (i > 0) {
                                i -= 1;
                                emit(enc_ldr(31, @intCast(i), 0));
                                emit(enc_add_imm(31, 31, 16));
                            }
                            emit(enc_movz(8, 25, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "file_close")) {
                            _ = try p.expect(.l_paren);
                            try compileExpr(p);
                            _ = try p.expect(.r_paren);
                            emit(enc_movz(8, 26, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "win_open")) {
                            _ = try p.expect(.l_paren);
                            var arg_count: usize = 0;
                            if (p.peek() != .r_paren) {
                                try compileExpr(p);
                                emit(enc_sub_imm(31, 31, 16));
                                emit(enc_str(31, 0, 0));
                                arg_count += 1;
                                while (p.accept(.comma)) {
                                    try compileExpr(p);
                                    emit(enc_sub_imm(31, 31, 16));
                                    emit(enc_str(31, 0, 0));
                                    arg_count += 1;
                                }
                            }
                            _ = try p.expect(.r_paren);
                            var i = arg_count;
                            while (i > 0) {
                                i -= 1;
                                emit(enc_ldr(31, @intCast(i), 0));
                                emit(enc_add_imm(31, 31, 16));
                            }
                            emit(enc_movz(8, 12, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "win_fill")) {
                            _ = try p.expect(.l_paren);
                            var arg_count: usize = 0;
                            if (p.peek() != .r_paren) {
                                try compileExpr(p);
                                emit(enc_sub_imm(31, 31, 16));
                                emit(enc_str(31, 0, 0));
                                arg_count += 1;
                                while (p.accept(.comma)) {
                                    try compileExpr(p);
                                    emit(enc_sub_imm(31, 31, 16));
                                    emit(enc_str(31, 0, 0));
                                    arg_count += 1;
                                }
                            }
                            _ = try p.expect(.r_paren);
                            var i = arg_count;
                            while (i > 0) {
                                i -= 1;
                                emit(enc_ldr(31, @intCast(i), 0));
                                emit(enc_add_imm(31, 31, 16));
                            }
                            emit(enc_movz(8, 13, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "win_present")) {
                            _ = try p.expect(.l_paren);
                            try compileExpr(p);
                            _ = try p.expect(.r_paren);
                            emit(enc_movz(8, 14, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "win_close")) {
                            _ = try p.expect(.l_paren);
                            try compileExpr(p);
                            _ = try p.expect(.r_paren);
                            emit(enc_movz(8, 15, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "svc")) {
                            _ = try p.expect(.l_paren);
                            const num_tok = try p.expect(.number);
                            const syscall_num = std.fmt.parseInt(u16, num_tok.text, 0) catch return error.CompileError;
                            var arg_count: usize = 0;
                            while (p.accept(.comma)) {
                                try compileExpr(p);
                                emit(enc_sub_imm(31, 31, 16));
                                emit(enc_str(31, 0, 0));
                                arg_count += 1;
                            }
                            _ = try p.expect(.r_paren);
                            var i = arg_count;
                            while (i > 0) {
                                i -= 1;
                                emit(enc_ldr(31, @intCast(i), 0));
                                emit(enc_add_imm(31, 31, 16));
                            }
                            emit(enc_movz(8, syscall_num, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "print_array")) {
                            _ = try p.expect(.l_paren);
                            const arr_tok = try p.expect(.ident);
                            _ = try p.expect(.r_paren);
                            const var_ptr = lookupLocalVar(arr_tok.text) orelse {
                                print_err("undefined identifier", arr_tok.line, arr_tok.text);
                                return error.CompileError;
                            };
                            if (!var_ptr.is_array) {
                                print_err("not an array", arr_tok.line, arr_tok.text);
                                return error.CompileError;
                            }
                            emit(enc_movz(0, 1, 0));
                            emit(enc_add_imm(19, 1, @intCast(var_ptr.offset)));
                            emit(enc_movz(2, @intCast(var_ptr.array_len * var_ptr.elem_size), 0));
                            emit(enc_movz(8, 1, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "print_struct")) {
                            _ = try p.expect(.l_paren);
                            const s_tok = try p.expect(.ident);
                            _ = try p.expect(.r_paren);
                            const var_ptr = lookupLocalVar(s_tok.text) orelse {
                                print_err("undefined identifier", s_tok.line, s_tok.text);
                                return error.CompileError;
                            };
                            if (!var_ptr.is_struct) {
                                print_err("not a struct", s_tok.line, s_tok.text);
                                return error.CompileError;
                            }
                            const sd = &structs[var_ptr.struct_idx];
                            emit(enc_movz(0, 1, 0));
                            emit(enc_add_imm(19, 1, @intCast(var_ptr.offset)));
                            emit(enc_movz(2, @intCast(sd.size), 0));
                            emit(enc_movz(8, 1, 0));
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "print_ptr")) {
                            _ = try p.expect(.l_paren);
                            try compileExpr(p); // ptr -> x0
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 0, 0)); // save ptr
                            _ = try p.expect(.comma);
                            try compileExpr(p); // len -> x0
                            emit(enc_mov_reg(2, 0)); // x2 = len
                            emit(enc_ldr(31, 1, 0)); // x1 = ptr
                            emit(enc_add_imm(31, 31, 16));
                            emit(enc_movz(0, 1, 0)); // x0 = 1 (stdout)
                            _ = try p.expect(.r_paren);
                            emit(enc_movz(8, 1, 0)); // sys_write
                            emit(enc_svc(0));
                        } else if (std.mem.eql(u8, member_tok.text, "write_ptr")) {
                            _ = try p.expect(.l_paren);
                            try compileExpr(p); // fd -> x0
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 0, 0)); // save fd
                            _ = try p.expect(.comma);
                            try compileExpr(p); // ptr -> x0
                            emit(enc_sub_imm(31, 31, 16));
                            emit(enc_str(31, 0, 0)); // save ptr
                            _ = try p.expect(.comma);
                            try compileExpr(p); // len -> x0
                            emit(enc_mov_reg(2, 0)); // x2 = len
                            emit(enc_ldr(31, 1, 0)); // x1 = ptr
                            emit(enc_add_imm(31, 31, 16));
                            emit(enc_ldr(31, 0, 0)); // x0 = fd
                            emit(enc_add_imm(31, 31, 16));
                            _ = try p.expect(.r_paren);
                            emit(enc_movz(8, 1, 0)); // sys_write
                            emit(enc_svc(0));
                        } else {
                            print_err("unknown zc function", member_tok.line, member_tok.text);
                            return error.CompileError;
                        }
                    } else {
                        const var_ptr = lookupLocalVar(t.text);
                        if (var_ptr) |vp| {
                            if (vp.is_struct) {
                                const sd = &structs[vp.struct_idx];
                                var foff: usize = 0;
                                var fsize: usize = 0;
                                var found = false;
                                for (sd.fields[0..sd.field_count]) |f| {
                                    if (std.mem.eql(u8, f.name, member_tok.text)) {
                                        foff = f.offset;
                                        fsize = f.size;
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    print_err("unknown field", member_tok.line, member_tok.text);
                                    return error.CompileError;
                                }
                                emit(enc_add_imm(19, 1, @intCast(vp.offset + foff)));
                                if (fsize == 1) {
                                    emit(enc_ldrb(1, 0, 0));
                                } else {
                                    emit(enc_ldr(1, 0, 0));
                                }
                            } else if (vp.is_ptr and vp.ptr_is_struct) {
                                const sd = &structs[vp.ptr_struct_idx];
                                var foff: usize = 0;
                                var fsize: usize = 0;
                                var found = false;
                                for (sd.fields[0..sd.field_count]) |f| {
                                    if (std.mem.eql(u8, f.name, member_tok.text)) {
                                        foff = f.offset;
                                        fsize = f.size;
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    print_err("unknown field", member_tok.line, member_tok.text);
                                    return error.CompileError;
                                }
                                emit(enc_ldr(19, 1, @intCast(vp.offset / 8)));
                                if (foff != 0) emit(enc_add_imm(1, 1, @intCast(foff)));
                                if (fsize == 1) {
                                    emit(enc_ldrb(1, 0, 0));
                                } else {
                                    emit(enc_ldr(1, 0, 0));
                                }
                            } else {
                                print_err("unknown module", t.line, t.text);
                                return error.CompileError;
                            }
                        } else {
                            print_err("unknown module", t.line, t.text);
                            return error.CompileError;
                        }
                    }
                }
            } else if (p.peek() == .l_bracket) {
                const var_ptr = lookupLocalVar(t.text) orelse {
                    print_err("undefined identifier", t.line, t.text);
                    return error.CompileError;
                };
                if (!var_ptr.is_array and !var_ptr.is_ptr and !var_ptr.is_slice) {
                    print_err("not an array, pointer, or slice", t.line, t.text);
                    return error.CompileError;
                }
                _ = p.advance(); // '['
                try compileExpr(p); // index -> x0
                _ = try p.expect(.r_bracket);
                const elem_sz = if (var_ptr.is_ptr or var_ptr.is_slice) var_ptr.ptr_elem_size else var_ptr.elem_size;
                const shift = elemShift(elem_sz);
                if (shift != 0) emit(enc_lsl(0, 0, shift));
                if (var_ptr.is_ptr or var_ptr.is_slice) {
                    emit(enc_ldr(19, 1, @intCast(var_ptr.offset / 8)));
                } else {
                    emit(enc_add_imm(19, 1, @intCast(var_ptr.offset)));
                }
                emit(enc_add_reg(1, 0, 1));
                if (elem_sz == 1) {
                    emit(enc_ldrb(1, 0, 0));
                } else {
                    emit(enc_ldr(1, 0, 0));
                }
            } else if (std.mem.eql(u8, t.text, "read8")) {
                _ = try p.expect(.l_paren);
                try compileExpr(p);
                _ = try p.expect(.r_paren);
                emit(enc_ldrb(0, 0, 0));
            } else if (std.mem.eql(u8, t.text, "write8")) {
                _ = try p.expect(.l_paren);
                try compileExpr(p);
                emit(enc_sub_imm(31, 31, 16));
                emit(enc_str(31, 0, 0));
                _ = try p.expect(.comma);
                try compileExpr(p);
                emit(enc_ldr(31, 1, 0));
                emit(enc_add_imm(31, 31, 16));
                emit(enc_strb(1, 0, 0));
                emit(enc_movz(0, 0, 0));
                _ = try p.expect(.r_paren);
            } else if (std.mem.eql(u8, t.text, "read64")) {
                _ = try p.expect(.l_paren);
                try compileExpr(p);
                _ = try p.expect(.r_paren);
                emit(enc_ldr(0, 0, 0));
            } else if (std.mem.eql(u8, t.text, "write64")) {
                _ = try p.expect(.l_paren);
                try compileExpr(p);
                emit(enc_sub_imm(31, 31, 16));
                emit(enc_str(31, 0, 0));
                _ = try p.expect(.comma);
                try compileExpr(p);
                emit(enc_ldr(31, 1, 0));
                emit(enc_add_imm(31, 31, 16));
                emit(enc_str(1, 0, 0));
                emit(enc_movz(0, 0, 0));
                _ = try p.expect(.r_paren);
            } else if (p.peek() == .l_paren) {
                // Direct call (function name) or, since Z2b (issue #757), an
                // indirect call through a function-pointer local or param.
                const direct_idx = lookupFunc(t.text);
                const fnptr_var = if (direct_idx == null) lookupLocalVar(t.text) else null;
                if (fnptr_var) |lv| {
                    if (!lv.is_fnptr) {
                        print_err("value is not a function pointer", t.line, t.text);
                        return error.CompileError;
                    }
                    // Park the callee address under the arguments: the args
                    // pop into x0.. first, then the callee pops into x16 and
                    // is dispatched with blr.
                    emit(enc_ldr(19, 0, @intCast(lv.offset / 8)));
                    emit(enc_sub_imm(31, 31, 16));
                    emit(enc_str(31, 0, 0));
                }
                _ = p.advance();
                var arg_count: usize = 0;
                if (p.peek() != .r_paren) {
                    try compileExpr(p);
                    emit(enc_sub_imm(31, 31, 16));
                    emit(enc_str(31, 0, 0));
                    arg_count += 1;
                    while (p.accept(.comma)) {
                        try compileExpr(p);
                        emit(enc_sub_imm(31, 31, 16));
                        emit(enc_str(31, 0, 0));
                        arg_count += 1;
                    }
                }
                _ = try p.expect(.r_paren);
                var i = arg_count;
                while (i > 0) {
                    i -= 1;
                    emit(enc_ldr(31, @intCast(i), 0));
                    emit(enc_add_imm(31, 31, 16));
                }
                if (fnptr_var != null) {
                    emit(enc_ldr(31, 16, 0));
                    emit(enc_add_imm(31, 31, 16));
                    emit(enc_blr(16));
                } else if (direct_idx) |idx| {
                    if (functions[idx].address != 0) {
                        // The callee's body already compiled: direct BL.
                        const target = functions[idx].address;
                        const rel = @as(i32, @intCast(target)) - @as(i32, @intCast(code_len));
                        emit(enc_bl(rel));
                    } else {
                        // Z3a: forward reference — the callee is registered
                        // (pass 1, possibly in a LATER source file) but its
                        // body has not compiled yet, so its address is still
                        // 0. A direct BL here would jump to offset 0; record
                        // a call patch resolved once every address is known.
                        // (Also fixes the same-file forward-call case.)
                        if (call_patches_count >= call_patches.len) return error.CompileError;
                        call_patches[call_patches_count] = CallPatch{ .caller_pc = @intCast(code_len), .target_func_idx = idx };
                        call_patches_count += 1;
                        emit(0);
                    }
                } else {
                    const f_idx = try registerForwardFunc(t.text);
                    if (call_patches_count >= call_patches.len) return error.CompileError;
                    call_patches[call_patches_count] = CallPatch{ .caller_pc = @intCast(code_len), .target_func_idx = f_idx };
                    call_patches_count += 1;
                    emit(0);
                }
            } else {
                const var_ptr = lookupLocalVar(t.text) orelse {
                    print_err("undefined identifier", t.line, t.text);
                    return error.CompileError;
                };
                emit(enc_ldr(19, 0, @intCast(var_ptr.offset / 8)));
                if (var_ptr.is_slice) {
                    emit(enc_ldr(19, 1, @intCast((var_ptr.offset + 8) / 8)));
                }
            }
        },
        .l_paren => {
            try compileExpr(p);
            _ = try p.expect(.r_paren);
        },
        .ampersand => {
            const target_tok = try p.expect(.ident);
            if (lookupFunc(target_tok.text)) |fidx| {
                // Z2b: &fn evaluates to the function's runtime address — a
                // PC-relative ADR patched at the end of compile() once every
                // function's address is known.
                if (fn_addr_patches_count >= fn_addr_patches.len) return error.CompileError;
                fn_addr_patches[fn_addr_patches_count] = FnAddrPatch{ .code_pc = code_len, .func_idx = fidx };
                fn_addr_patches_count += 1;
                emit(0);
            } else if (lookupLocalVar(target_tok.text)) |var_ptr| {
                if (p.accept(.dot)) {
                    const field_tok = try p.expect(.ident);
                    if (var_ptr.is_struct) {
                        const sd = &structs[var_ptr.struct_idx];
                        var foff: usize = 0;
                        var found = false;
                        for (sd.fields[0..sd.field_count]) |f| {
                            if (std.mem.eql(u8, f.name, field_tok.text)) {
                                foff = f.offset;
                                found = true;
                                break;
                            }
                        }
                        if (!found) return error.CompileError;
                        emit(enc_add_imm(19, 0, @intCast(var_ptr.offset + foff)));
                    } else if (var_ptr.is_ptr and var_ptr.ptr_is_struct) {
                        const sd = &structs[var_ptr.ptr_struct_idx];
                        var foff: usize = 0;
                        var found = false;
                        for (sd.fields[0..sd.field_count]) |f| {
                            if (std.mem.eql(u8, f.name, field_tok.text)) {
                                foff = f.offset;
                                found = true;
                                break;
                            }
                        }
                        if (!found) return error.CompileError;
                        emit(enc_ldr(19, 0, @intCast(var_ptr.offset / 8)));
                        if (foff != 0) emit(enc_add_imm(0, 0, @intCast(foff)));
                    } else {
                        return error.CompileError;
                    }
                } else if (p.peek() == .l_bracket) {
                    _ = p.advance(); // '['
                    try compileExpr(p); // index -> x0
                    _ = try p.expect(.r_bracket);
                    const elem_sz = if (var_ptr.is_ptr) var_ptr.ptr_elem_size else var_ptr.elem_size;
                    const shift = elemShift(elem_sz);
                    if (shift != 0) emit(enc_lsl(0, 0, shift));
                    if (var_ptr.is_ptr) {
                        emit(enc_ldr(19, 1, @intCast(var_ptr.offset / 8)));
                    } else {
                        emit(enc_add_imm(19, 1, @intCast(var_ptr.offset)));
                    }
                    emit(enc_add_reg(0, 0, 1));
                } else {
                    emit(enc_add_imm(19, 0, @intCast(var_ptr.offset)));
                }
            } else {
                print_err("undefined identifier", target_tok.line, target_tok.text);
                return error.CompileError;
            }
        },
        else => return error.CompileError,
    }
}

fn compileSwitch(p: *Parser, is_expr: bool) anyerror!void {
    _ = try p.expect(.keyword_switch);
    _ = try p.expect(.l_paren);
    try compileExpr(p);
    _ = try p.expect(.r_paren);

    if (frame_size + 8 > 512) return error.CompileError;
    const val_offset = frame_size;
    frame_size += 8;
    emit(enc_str(19, 0, @intCast(val_offset / 8)));

    _ = try p.expect(.l_brace);

    var end_patches: [64]usize = undefined;
    var end_patches_count: usize = 0;

    while (p.peek() != .r_brace and p.peek() != .eof) {
        if (p.peek() == .keyword_else) {
            _ = p.advance();
            _ = try p.expect(.equal_greater);
            if (is_expr) {
                try compileExpr(p);
                _ = p.accept(.comma);
            } else {
                if (p.peek() == .l_brace) {
                    _ = p.advance();
                    try pushDeferScope();
                    while (p.peek() != .r_brace and p.peek() != .eof) try compileStatement(p);
                    _ = try p.expect(.r_brace);
                    // Z2b: a braced switch prong is a scope — its defers run
                    // when the prong exits.
                    try emitScopeDefers(p, defer_scope_depth - 1);
                    popDeferScope();
                    _ = p.accept(.comma);
                } else {
                    try compileStatement(p);
                    _ = p.accept(.comma);
                }
            }
            break;
        }

        var match_branch_indices: [16]usize = undefined;
        var match_conds: [16]Cond = undefined;
        var match_branch_count: usize = 0;

        while (true) {
            try compileExpr(p);
            emit(enc_ldr(19, 1, @intCast(val_offset / 8)));

            if (p.peek() == .triple_dot or p.peek() == .double_dot) {
                _ = p.advance();
                emit(enc_cmp_reg(1, 0));
                const skip_idx = code_len;
                emit(0);

                try compileExpr(p);
                emit(enc_ldr(19, 1, @intCast(val_offset / 8)));
                emit(enc_cmp_reg(1, 0));
                match_branch_indices[match_branch_count] = code_len;
                match_conds[match_branch_count] = .le;
                match_branch_count += 1;
                emit(0);

                const skip_pc = code_len;
                const rel_skip = @as(i32, @intCast(skip_pc - skip_idx));
                std.mem.writeInt(u32, code[skip_idx..][0..4], enc_b_cond(.lt, rel_skip), .little);
            } else {
                emit(enc_cmp_reg(1, 0));
                match_branch_indices[match_branch_count] = code_len;
                match_conds[match_branch_count] = .eq;
                match_branch_count += 1;
                emit(0);
            }

            if (p.accept(.comma)) {
                if (p.peek() == .equal_greater) break;
                continue;
            }
            break;
        }

        _ = try p.expect(.equal_greater);

        const next_prong_idx = code_len;
        emit(0);

        const match_pc = code_len;
        var mi: usize = 0;
        while (mi < match_branch_count) : (mi += 1) {
            const m_idx = match_branch_indices[mi];
            const rel = @as(i32, @intCast(match_pc - m_idx));
            std.mem.writeInt(u32, code[m_idx..][0..4], enc_b_cond(match_conds[mi], rel), .little);
        }

        if (is_expr) {
            try compileExpr(p);
            _ = p.accept(.comma);
        } else {
            if (p.peek() == .l_brace) {
                _ = p.advance();
                try pushDeferScope();
                while (p.peek() != .r_brace and p.peek() != .eof) try compileStatement(p);
                _ = try p.expect(.r_brace);
                // Z2b: a braced switch prong is a scope — its defers run when
                // the prong exits.
                try emitScopeDefers(p, defer_scope_depth - 1);
                popDeferScope();
                _ = p.accept(.comma);
            } else {
                try compileStatement(p);
                _ = p.accept(.comma);
            }
        }

        if (end_patches_count < end_patches.len) {
            end_patches[end_patches_count] = code_len;
            end_patches_count += 1;
            emit(0);
        }

        const next_prong_pc = code_len;
        const rel_next = @as(i32, @intCast(next_prong_pc - next_prong_idx));
        std.mem.writeInt(u32, code[next_prong_idx..][0..4], enc_b(rel_next), .little);
    }

    _ = try p.expect(.r_brace);

    const end_pc = code_len;
    for (end_patches[0..end_patches_count]) |e_idx| {
        const rel_end = @as(i32, @intCast(end_pc - e_idx));
        std.mem.writeInt(u32, code[e_idx..][0..4], enc_b(rel_end), .little);
    }
}

// ---------------------------------------------------------------------------
// Statement Compiler
// ---------------------------------------------------------------------------
fn compileStatement(p: *Parser) anyerror!void {
    const k = p.peek();
    switch (k) {
        .keyword_let, .keyword_var, .keyword_const => {
            _ = p.advance();
            const name_tok = try p.expect(.ident);
            var is_array = false;
            var arr_len: usize = 0;
            var elem_size: usize = 8;
            var is_struct = false;
            var struct_idx: usize = 0;
            var struct_size: usize = 0;
            var is_ptr = false;
            var ptr_elem_size: usize = 8;
            var ptr_is_struct = false;
            var ptr_struct_idx: usize = 0;
            var is_fnptr = false;
            var is_slice = false;
            if (p.accept(.colon)) {
                const pt = try parseType(p);
                if (pt.is_ptr) {
                    is_ptr = true;
                    ptr_elem_size = pt.ptr_elem_size;
                    ptr_is_struct = pt.ptr_is_struct;
                    ptr_struct_idx = pt.ptr_struct_idx;
                    is_fnptr = pt.is_fnptr;
                } else if (pt.is_slice) {
                    is_slice = true;
                    elem_size = pt.elem_size;
                    ptr_elem_size = pt.ptr_elem_size;
                } else if (pt.is_array) {
                    is_array = true;
                    arr_len = pt.array_len;
                    elem_size = pt.elem_size;
                } else if (pt.is_struct) {
                    is_struct = true;
                    struct_idx = pt.struct_idx;
                    struct_size = pt.elem_size;
                } else {
                    elem_size = pt.elem_size;
                }
            }
            if (is_ptr) {
                if (frame_size + 8 > 512) return error.CompileError;
                const offset = frame_size;
                frame_size += 8;
                if (p.accept(.equal)) {
                    if (p.peek() == .ident and std.mem.eql(u8, p.currentToken().text, "undefined")) {
                        _ = p.advance();
                    } else {
                        try compileExpr(p);
                        emit(enc_str(19, 0, @intCast(offset / 8)));
                    }
                }
                _ = try p.expect(.semicolon);
                if (locals_count >= locals.len) return error.CompileError;
                locals[locals_count] = LocalVar{
                    .name = name_tok.text,
                    .offset = offset,
                    .is_ptr = true,
                    .ptr_elem_size = ptr_elem_size,
                    .ptr_is_struct = ptr_is_struct,
                    .ptr_struct_idx = ptr_struct_idx,
                    .is_fnptr = is_fnptr,
                };
                locals_count += 1;
            } else if (is_slice) {
                if (frame_size + 16 > 512) return error.CompileError;
                const offset = frame_size;
                frame_size += 16;
                if (p.accept(.equal)) {
                    if (p.peek() == .ident and std.mem.eql(u8, p.currentToken().text, "undefined")) {
                        _ = p.advance();
                    } else {
                        try compileExpr(p);
                        emit(enc_str(19, 0, @intCast(offset / 8)));
                        emit(enc_str(19, 1, @intCast((offset + 8) / 8)));
                    }
                }
                _ = try p.expect(.semicolon);
                if (locals_count >= locals.len) return error.CompileError;
                locals[locals_count] = LocalVar{
                    .name = name_tok.text,
                    .offset = offset,
                    .is_slice = true,
                    .elem_size = elem_size,
                    .ptr_elem_size = ptr_elem_size,
                };
                locals_count += 1;
            } else if (is_array) {
                const total = arr_len * elem_size;
                const aligned = (total + 7) & ~@as(usize, 7);
                if (frame_size + aligned > 512) return error.CompileError;
                const offset = frame_size;
                frame_size += aligned;
                if (p.accept(.equal)) {
                    if (p.peek() == .ident and std.mem.eql(u8, p.currentToken().text, "undefined")) {
                        _ = p.advance();
                    } else {
                        print_err("array init not supported", name_tok.line, name_tok.text);
                        return error.CompileError;
                    }
                }
                _ = try p.expect(.semicolon);
                if (locals_count >= locals.len) return error.CompileError;
                locals[locals_count] = LocalVar{ .name = name_tok.text, .offset = offset, .is_array = true, .array_len = arr_len, .elem_size = elem_size };
                locals_count += 1;
            } else if (is_struct) {
                const aligned = (struct_size + 7) & ~@as(usize, 7);
                if (frame_size + aligned > 512) return error.CompileError;
                const offset = frame_size;
                frame_size += aligned;
                if (p.accept(.equal)) {
                    if (p.peek() == .ident and std.mem.eql(u8, p.currentToken().text, "undefined")) {
                        _ = p.advance();
                    } else {
                        print_err("struct init not supported", name_tok.line, name_tok.text);
                        return error.CompileError;
                    }
                }
                _ = try p.expect(.semicolon);
                if (locals_count >= locals.len) return error.CompileError;
                locals[locals_count] = LocalVar{ .name = name_tok.text, .offset = offset, .is_struct = true, .struct_idx = struct_idx };
                locals_count += 1;
            } else {
                _ = try p.expect(.equal);
                if (p.peek() == .ident and std.mem.eql(u8, p.currentToken().text, "undefined")) {
                    _ = p.advance();
                    _ = try p.expect(.semicolon);
                    const offset = frame_size;
                    frame_size += 8;
                    if (locals_count >= locals.len) return error.CompileError;
                    locals[locals_count] = LocalVar{ .name = name_tok.text, .offset = offset };
                    locals_count += 1;
                } else {
                    const is_str = (p.peek() == .string_lit);
                    try compileExpr(p);
                    _ = try p.expect(.semicolon);
                    const offset = frame_size;
                    if (is_str) {
                        frame_size += 16;
                        emit(enc_str(19, 0, @intCast(offset / 8)));
                        emit(enc_str(19, 1, @intCast((offset + 8) / 8)));
                        if (locals_count >= locals.len) return error.CompileError;
                        locals[locals_count] = LocalVar{
                            .name = name_tok.text,
                            .offset = offset,
                            .is_slice = true,
                            .elem_size = 1,
                            .ptr_elem_size = 1,
                        };
                        locals_count += 1;
                    } else {
                        frame_size += 8;
                        emit(enc_str(19, 0, @intCast(offset / 8)));
                        if (locals_count >= locals.len) return error.CompileError;
                        locals[locals_count] = LocalVar{ .name = name_tok.text, .offset = offset };
                        locals_count += 1;
                    }
                }
            }
        },
        .keyword_if => {
            _ = p.advance();
            _ = try p.expect(.l_paren);
            try compileExpr(p);
            _ = try p.expect(.r_paren);
            emit(enc_cmp_imm(0, 0));
            const else_branch_idx = code_len;
            emit(0);
            _ = try p.expect(.l_brace);
            try pushDeferScope();
            while (p.peek() != .r_brace and p.peek() != .eof) try compileStatement(p);
            _ = try p.expect(.r_brace);
            // Z2b: the if-body's defers run when the body exits by fallthrough.
            try emitScopeDefers(p, defer_scope_depth - 1);
            popDeferScope();
            const end_branch_idx = code_len;
            emit(0);
            const else_pc = code_len;
            const else_offset_bytes = @as(i32, @intCast(else_pc - else_branch_idx));
            std.mem.writeInt(u32, code[else_branch_idx..][0..4], enc_b_cond(.eq, else_offset_bytes), .little);
            if (p.accept(.keyword_else)) {
                _ = try p.expect(.l_brace);
                try pushDeferScope();
                while (p.peek() != .r_brace and p.peek() != .eof) try compileStatement(p);
                _ = try p.expect(.r_brace);
                // Z2b: the else-body's defers run on its fallthrough exit.
                try emitScopeDefers(p, defer_scope_depth - 1);
                popDeferScope();
            }
            const end_pc = code_len;
            const end_offset_bytes = @as(i32, @intCast(end_pc - end_branch_idx));
            std.mem.writeInt(u32, code[end_branch_idx..][0..4], enc_b(end_offset_bytes), .little);
        },
        .keyword_while => {
            _ = p.advance();
            const start_pc = code_len;
            _ = try p.expect(.l_paren);
            try compileExpr(p);
            _ = try p.expect(.r_paren);
            emit(enc_cmp_imm(0, 0));
            const end_branch_idx = code_len;
            emit(0);
            _ = try p.expect(.l_brace);
            try pushDeferScope();
            try pushLoop(defer_scope_depth - 1);
            while (p.peek() != .r_brace and p.peek() != .eof) try compileStatement(p);
            _ = try p.expect(.r_brace);
            // Z2b: the while-body's defers run at the end of every iteration.
            try emitScopeDefers(p, defer_scope_depth - 1);
            const jump_back_offset = @as(i32, @intCast(start_pc)) - @as(i32, @intCast(code_len));
            emit(enc_b(jump_back_offset));
            const end_pc = code_len;
            // M70c S3: `continue` re-tests the condition (start_pc); `break`
            // lands past the back-branch (end_pc).
            patchLoop(start_pc, end_pc);
            popDeferScope();
            const end_offset_bytes = @as(i32, @intCast(end_pc - end_branch_idx));
            std.mem.writeInt(u32, code[end_branch_idx..][0..4], enc_b_cond(.eq, end_offset_bytes), .little);
        },
        .keyword_switch => try compileSwitch(p, false),
        .keyword_for => {
            _ = p.advance();
            _ = try p.expect(.l_paren);

            var has_dotdot = false;
            var j = p.idx;
            var depth: usize = 0;
            while (j < p.tokens.len) : (j += 1) {
                if (p.tokens[j].kind == .l_paren) depth += 1;
                if (p.tokens[j].kind == .r_paren) {
                    if (depth == 0) break;
                    depth -= 1;
                }
                if (depth == 0 and p.tokens[j].kind == .comma) break;
                if (depth == 0 and (p.tokens[j].kind == .double_dot or p.tokens[j].kind == .triple_dot)) {
                    has_dotdot = true;
                    break;
                }
            }

            const saved_locals_count = locals_count;

            if (has_dotdot) {
                // Range loop: for (start..end) |i| or for (0..n) |i|
                if (frame_size + 16 > 512) return error.CompileError;
                const idx_offset = frame_size;
                const limit_offset = frame_size + 8;
                frame_size += 16;

                if (p.peek() == .double_dot or p.peek() == .triple_dot) {
                    _ = p.advance();
                    emit(enc_movz(0, 0, 0));
                    emit(enc_str(19, 0, @intCast(idx_offset / 8)));
                    try compileExpr(p);
                    emit(enc_str(19, 0, @intCast(limit_offset / 8)));
                } else {
                    try compileExpr(p);
                    emit(enc_str(19, 0, @intCast(idx_offset / 8)));
                    _ = p.accept(.double_dot) or p.accept(.triple_dot);
                    try compileExpr(p);
                    emit(enc_str(19, 0, @intCast(limit_offset / 8)));
                }
                _ = try p.expect(.r_paren);

                if (p.accept(.pipe)) {
                    const cap_tok = try p.expect(.ident);
                    _ = try p.expect(.pipe);
                    if (locals_count >= locals.len) return error.CompileError;
                    locals[locals_count] = LocalVar{ .name = cap_tok.text, .offset = idx_offset };
                    locals_count += 1;
                }

                const start_pc = code_len;
                emit(enc_ldr(19, 0, @intCast(idx_offset / 8)));
                emit(enc_ldr(19, 1, @intCast(limit_offset / 8)));
                emit(enc_cmp_reg(0, 1));
                const exit_branch_idx = code_len;
                emit(0); // b.cs exit

                _ = try p.expect(.l_brace);
                try pushDeferScope();
                try pushLoop(defer_scope_depth - 1);
                while (p.peek() != .r_brace and p.peek() != .eof) try compileStatement(p);
                _ = try p.expect(.r_brace);
                // Z2b: the loop-body's defers run at the end of every iteration.
                try emitScopeDefers(p, defer_scope_depth - 1);
                popDeferScope();

                // Step: idx += 1. M70c S3: this is a `for` loop's `continue`
                // target — aiming at the condition instead would skip the
                // increment and spin forever.
                const step_pc = code_len;
                emit(enc_ldr(19, 0, @intCast(idx_offset / 8)));
                emit(enc_add_imm(0, 0, 1));
                emit(enc_str(19, 0, @intCast(idx_offset / 8)));

                const jump_back = @as(i32, @intCast(start_pc)) - @as(i32, @intCast(code_len));
                emit(enc_b(jump_back));

                const exit_pc = code_len;
                patchLoop(step_pc, exit_pc);
                const exit_offset_bytes = @as(i32, @intCast(exit_pc - exit_branch_idx));
                std.mem.writeInt(u32, code[exit_branch_idx..][0..4], enc_b_cond(.cs, exit_offset_bytes), .little);
            } else {
                // Array loop: for (arr) |elem| or for (arr, 0..) |elem, i|
                const arr_tok = try p.expect(.ident);
                const arr_var = lookupLocalVar(arr_tok.text) orelse {
                    print_err("undefined array", arr_tok.line, arr_tok.text);
                    return error.CompileError;
                };
                if (!arr_var.is_array and !arr_var.is_slice) {
                    print_err("not iterable", arr_tok.line, arr_tok.text);
                    return error.CompileError;
                }

                if (p.accept(.comma)) {
                    try compileExpr(p);
                    _ = p.accept(.double_dot) or p.accept(.triple_dot);
                }
                _ = try p.expect(.r_paren);

                if (frame_size + 24 > 512) return error.CompileError;
                const idx_offset = frame_size;
                const limit_offset = frame_size + 8;
                const elem_offset = frame_size + 16;
                frame_size += 24;

                emit(enc_movz(0, 0, 0));
                emit(enc_str(19, 0, @intCast(idx_offset / 8)));

                if (arr_var.is_array) {
                    emit(enc_movz(0, @intCast(arr_var.array_len), 0));
                    emit(enc_str(19, 0, @intCast(limit_offset / 8)));
                } else {
                    emit(enc_ldr(19, 0, @intCast((arr_var.offset + 8) / 8)));
                    emit(enc_str(19, 0, @intCast(limit_offset / 8)));
                }

                var cap_elem: ?[]const u8 = null;
                var cap_idx: ?[]const u8 = null;
                if (p.accept(.pipe)) {
                    cap_elem = (try p.expect(.ident)).text;
                    if (p.accept(.comma)) {
                        cap_idx = (try p.expect(.ident)).text;
                    }
                    _ = try p.expect(.pipe);
                }

                if (cap_elem) |name| {
                    if (locals_count >= locals.len) return error.CompileError;
                    locals[locals_count] = LocalVar{
                        .name = name,
                        .offset = elem_offset,
                        .elem_size = arr_var.elem_size,
                    };
                    locals_count += 1;
                }
                if (cap_idx) |name| {
                    if (locals_count >= locals.len) return error.CompileError;
                    locals[locals_count] = LocalVar{ .name = name, .offset = idx_offset };
                    locals_count += 1;
                }

                const start_pc = code_len;
                emit(enc_ldr(19, 0, @intCast(idx_offset / 8)));
                emit(enc_ldr(19, 1, @intCast(limit_offset / 8)));
                emit(enc_cmp_reg(0, 1));
                const exit_branch_idx = code_len;
                emit(0); // b.cs exit

                // Load arr[idx] -> elem_offset
                emit(enc_ldr(19, 1, @intCast(idx_offset / 8))); // x1 = idx
                if (arr_var.is_array) {
                    emit(enc_add_imm(19, 2, @intCast(arr_var.offset))); // x2 = &arr[0]
                } else {
                    emit(enc_ldr(19, 2, @intCast(arr_var.offset / 8))); // x2 = slice.ptr
                }
                if (arr_var.elem_size == 8) {
                    emit(enc_lsl(1, 1, 3));
                    emit(enc_add_reg(2, 1, 2));
                    emit(enc_ldr(2, 0, 0));
                } else {
                    emit(enc_add_reg(2, 1, 2));
                    emit(enc_ldrb(2, 0, 0));
                }
                emit(enc_str(19, 0, @intCast(elem_offset / 8)));

                _ = try p.expect(.l_brace);
                try pushDeferScope();
                try pushLoop(defer_scope_depth - 1);
                while (p.peek() != .r_brace and p.peek() != .eof) try compileStatement(p);
                _ = try p.expect(.r_brace);
                // Z2b: the loop-body's defers run at the end of every iteration.
                try emitScopeDefers(p, defer_scope_depth - 1);
                popDeferScope();

                // Step: idx += 1. M70c S3: this is a `for` loop's `continue`
                // target — aiming at the condition instead would skip the
                // increment and spin forever.
                const step_pc = code_len;
                emit(enc_ldr(19, 0, @intCast(idx_offset / 8)));
                emit(enc_add_imm(0, 0, 1));
                emit(enc_str(19, 0, @intCast(idx_offset / 8)));

                const jump_back = @as(i32, @intCast(start_pc)) - @as(i32, @intCast(code_len));
                emit(enc_b(jump_back));

                const exit_pc = code_len;
                patchLoop(step_pc, exit_pc);
                const exit_offset_bytes = @as(i32, @intCast(exit_pc - exit_branch_idx));
                std.mem.writeInt(u32, code[exit_branch_idx..][0..4], enc_b_cond(.cs, exit_offset_bytes), .little);
            }

            locals_count = saved_locals_count;
        },
        .keyword_break => try compileLoopJump(p, true),
        .keyword_continue => try compileLoopJump(p, false),
        .keyword_return => {
            _ = p.advance();
            const has_value = p.peek() != .semicolon and p.peek() != .comma;
            if (has_value) {
                try compileExpr(p);
                // Park the return value so scope-exit defers may clobber x0.
                emit(enc_sub_imm(31, 31, 16));
                emit(enc_str(31, 0, 0));
            }
            // Z2b: a return unwinds every scope that is still open — run
            // their defers (innermost first, each LIFO). Entries are left in
            // place so the same defers are emitted again at each scope's
            // fallthrough end; only one of the two code paths executes.
            try emitOpenScopeDefers(p);
            if (has_value) {
                emit(enc_ldr(31, 0, 0));
                emit(enc_add_imm(31, 31, 16));
            }
            _ = p.accept(.semicolon) or p.accept(.comma);
            emit(enc_add_imm(19, 31, 0));
            emit(enc_add_imm(31, 31, 512));
            emit(enc_ldr(31, 19, 0));
            emit(enc_add_imm(31, 31, 16));
            emit(enc_ldr(31, 30, 0));
            emit(enc_add_imm(31, 31, 16));
            emit(enc_ret(30));
        },
        .keyword_defer => {
            _ = p.advance();
            if (defer_scope_depth == 0) {
                print_err("defer outside a function body", p.currentToken().line, p.currentToken().text);
                return error.CompileError;
            }
            const t0 = p.currentToken();
            if (t0.kind != .ident and t0.kind != .at) {
                print_err("defer body must be an expression or simple assignment statement", t0.line, t0.text);
                return error.CompileError;
            }
            if (defer_entries_count >= defer_entries.len) return error.CompileError;
            defer_entries[defer_entries_count] = DeferEntry{ .stmt_start = p.idx };
            defer_entries_count += 1;
            // Do not compile the deferred statement now — it is compiled
            // again (emitted) when its scope exits or a return unwinds it.
            skipDeferBody(p);
        },
        else => {
            if (p.peek() == .ident and std.mem.eql(u8, p.currentToken().text, "_") and p.idx + 1 < p.tokens.len and p.tokens[p.idx + 1].kind == .equal) {
                _ = p.advance();
                _ = p.advance();
                try compileExpr(p);
                _ = p.accept(.semicolon) or p.accept(.comma);
            } else if (p.peek() == .ident and p.idx + 1 < p.tokens.len and p.tokens[p.idx + 1].kind == .equal) {
                const name_tok = p.advance();
                _ = p.advance();
                try compileExpr(p);
                _ = p.accept(.semicolon) or p.accept(.comma);
                const var_ptr = lookupLocalVar(name_tok.text) orelse return error.CompileError;
                if (var_ptr.is_slice) {
                    emit(enc_str(19, 0, @intCast(var_ptr.offset / 8)));
                    emit(enc_str(19, 1, @intCast((var_ptr.offset + 8) / 8)));
                } else {
                    emit(enc_str(19, 0, @intCast(var_ptr.offset / 8)));
                }
            } else if (p.peek() == .ident and p.idx + 1 < p.tokens.len and p.tokens[p.idx + 1].kind == .l_bracket) {
                // possible array/pointer store: look for ']' then '='
                var found = false;
                var j = p.idx + 2;
                while (j < p.tokens.len) : (j += 1) {
                    if (p.tokens[j].kind == .r_bracket) {
                        if (j + 1 < p.tokens.len and p.tokens[j + 1].kind == .equal) found = true;
                        break;
                    }
                    if (p.tokens[j].kind == .semicolon or p.tokens[j].kind == .eof) break;
                }
                if (found) {
                    const arr_name = p.advance().text;
                    const var_ptr = lookupLocalVar(arr_name) orelse return error.CompileError;
                    if (!var_ptr.is_array and !var_ptr.is_ptr) return error.CompileError;
                    _ = p.advance(); // '['
                    try compileExpr(p); // index -> x0
                    _ = try p.expect(.r_bracket);
                    _ = try p.expect(.equal);
                    emit(enc_sub_imm(31, 31, 16));
                    emit(enc_str(31, 0, 0)); // save idx
                    try compileExpr(p); // value -> x0
                    _ = try p.expect(.semicolon);
                    emit(enc_ldr(31, 1, 0));
                    emit(enc_add_imm(31, 31, 16));
                    const elem_sz = if (var_ptr.is_ptr) var_ptr.ptr_elem_size else var_ptr.elem_size;
                    const shift = elemShift(elem_sz);
                    if (shift != 0) emit(enc_lsl(1, 1, shift));
                    if (var_ptr.is_ptr) {
                        emit(enc_ldr(19, 2, @intCast(var_ptr.offset / 8)));
                    } else {
                        emit(enc_add_imm(19, 2, @intCast(var_ptr.offset)));
                    }
                    emit(enc_add_reg(2, 1, 2));
                    if (elem_sz == 1) {
                        emit(enc_strb(2, 0, 0));
                    } else {
                        emit(enc_str(2, 0, 0));
                    }
                } else {
                    try compileExpr(p);
                    _ = try p.expect(.semicolon);
                }
            } else if (p.peek() == .ident and p.idx + 3 < p.tokens.len and p.tokens[p.idx + 1].kind == .dot and p.tokens[p.idx + 2].kind == .star and p.tokens[p.idx + 3].kind == .equal) {
                const ptr_name = p.advance().text;
                _ = p.advance(); // dot
                _ = p.advance(); // star
                _ = p.advance(); // =
                const var_ptr = lookupLocalVar(ptr_name) orelse return error.CompileError;
                if (!var_ptr.is_ptr) return error.CompileError;
                try compileExpr(p); // value -> x0
                _ = try p.expect(.semicolon);
                emit(enc_ldr(19, 1, @intCast(var_ptr.offset / 8)));
                if (var_ptr.ptr_elem_size == 1) {
                    emit(enc_strb(1, 0, 0));
                } else {
                    emit(enc_str(1, 0, 0));
                }
            } else if (p.peek() == .ident and p.idx + 3 < p.tokens.len and p.tokens[p.idx + 1].kind == .dot and p.tokens[p.idx + 2].kind == .ident and p.tokens[p.idx + 3].kind == .equal) {
                const s_name = p.advance().text;
                _ = p.advance(); // dot
                const field_name = p.advance().text;
                _ = p.advance(); // =
                const var_ptr = lookupLocalVar(s_name) orelse return error.CompileError;
                if (var_ptr.is_struct) {
                    const sd = &structs[var_ptr.struct_idx];
                    var foff: usize = 0;
                    var fsize: usize = 0;
                    var found = false;
                    for (sd.fields[0..sd.field_count]) |f| {
                        if (std.mem.eql(u8, f.name, field_name)) {
                            foff = f.offset;
                            fsize = f.size;
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.CompileError;
                    try compileExpr(p); // value -> x0
                    _ = try p.expect(.semicolon);
                    emit(enc_add_imm(19, 1, @intCast(var_ptr.offset + foff)));
                    if (fsize == 1) {
                        emit(enc_strb(1, 0, 0));
                    } else {
                        emit(enc_str(1, 0, 0));
                    }
                } else if (var_ptr.is_ptr and var_ptr.ptr_is_struct) {
                    const sd = &structs[var_ptr.ptr_struct_idx];
                    var foff: usize = 0;
                    var fsize: usize = 0;
                    var found = false;
                    for (sd.fields[0..sd.field_count]) |f| {
                        if (std.mem.eql(u8, f.name, field_name)) {
                            foff = f.offset;
                            fsize = f.size;
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.CompileError;
                    try compileExpr(p); // value -> x0
                    _ = try p.expect(.semicolon);
                    emit(enc_ldr(19, 1, @intCast(var_ptr.offset / 8)));
                    if (foff != 0) emit(enc_add_imm(1, 1, @intCast(foff)));
                    if (fsize == 1) {
                        emit(enc_strb(1, 0, 0));
                    } else {
                        emit(enc_str(1, 0, 0));
                    }
                } else {
                    return error.CompileError;
                }
            } else {
                try compileExpr(p);
                _ = try p.expect(.semicolon);
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Compiler Main Driver
// ---------------------------------------------------------------------------
// Z3a (issue #758) / Z3b (issue #759): at most this many source files per
// compile. Z3b's stdz app is app + fmt + builder + ring = 4 sources; the
// headroom covers a growing stdz. Bounded by the argv block's 8-slot cap in
// practice; the per-file buffers below are sized to match.
const MAX_FILES: usize = 6;

pub fn compile(src: []const u8) !usize {
    return compileFiles(&.{src});
}

// Z3a (issue #758): multi-file compile. Every source is tokenized into one
// shared stream (each file's trailing eof is dropped except the last), and
// pass 1 / pass 2 walk the combined stream: the function table, struct/enum
// tables, and the call / &fn / string patch lists are all global, so a call
// in one file resolves to a definition in another through the same machinery
// as a same-file forward call. Files are a flat namespace: no @import
// semantics (scope-out per the ladder; Z3b's stdz rides this table).
pub fn compileFiles(sources: []const []const u8) !usize {
    tokens_count = 0;
    for (sources, 0..) |src, f| {
        var tokenizer = Tokenizer{ .src = src };
        while (true) {
            const t = tokenizer.next();
            if (tokens_count >= tokens_buf.len) return error.TooManyTokens;
            tokens_buf[tokens_count] = t;
            tokens_count += 1;
            if (t.kind == .eof) break;
        }
        // Drop this file's eof; the next file's tokens follow directly (a
        // file boundary sits between a top-level `;`/`}` and the next decl,
        // so no separator token is needed). The LAST file keeps its eof.
        if (f + 1 < sources.len) tokens_count -= 1;
    }
    const tokens = tokens_buf[0..tokens_count];

    code_len = 0;
    functions_count = 0;
    call_patches_count = 0;
    fn_addr_patches_count = 0;
    defer_entries_count = 0;
    defer_scope_depth = 0;
    locals_count = 0;
    frame_size = 0;
    structs_count = 0;
    enums_count = 0;
    data_len = 0;
    string_patches_count = 0;

    // Pass 1: Gather function declarations
    var p1 = Parser{ .tokens = tokens };
    while (p1.peek() != .eof) {
        _ = p1.accept(.keyword_pub);
        if (p1.peek() == .keyword_fn) {
            _ = p1.advance();
            const name_tok = try p1.expect(.ident);
            _ = try p1.expect(.l_paren);
            const param_count = countParams(tokens, p1.idx);
            skipToDeclCloseParen(&p1);
            _ = try parseType(&p1); // return type
            _ = try p1.expect(.l_brace);
            var brace_depth: usize = 1;
            while (brace_depth > 0 and p1.peek() != .eof) {
                const k = p1.advance().kind;
                if (k == .l_brace) brace_depth += 1;
                if (k == .r_brace) brace_depth -= 1;
            }
            if (functions_count >= functions.len) return error.TooManyFunctions;
            // Z3a: the cross-file symbol table is a flat namespace — a
            // duplicate function name (same file or across files) is a
            // diagnostic, not a silent first-wins.
            if (lookupFunc(name_tok.text) != null) {
                print_err("duplicate function", name_tok.line, name_tok.text);
                return error.CompileError;
            }
            functions[functions_count] = Function{ .name = name_tok.text, .address = 0, .param_count = param_count };
            functions_count += 1;
        } else if (p1.peek() == .keyword_const) {
            const save_idx = p1.idx;
            _ = p1.advance(); // const
            if (p1.peek() == .ident) {
                const name_tok = p1.advance();
                if (p1.accept(.equal)) {
                    if (p1.accept(.keyword_struct)) {
                        _ = try p1.expect(.l_brace);
                        var sd = StructDef{ .name = name_tok.text };
                        var off: usize = 0;
                        while (p1.peek() != .r_brace and p1.peek() != .eof) {
                            const fname = try p1.expect(.ident);
                            _ = try p1.expect(.colon);
                            // Z3b: struct fields may be [*]T pointers (the
                            // stdz Builder/Ring hold a [*]u8 buffer) — an
                            // 8-byte field.
                            var fsz: usize = 0;
                            if (p1.accept(.l_bracket)) {
                                _ = try p1.expect(.star);
                                _ = try p1.expect(.r_bracket);
                                _ = try p1.expect(.ident); // element type name
                                fsz = 8;
                            } else {
                                const tname = try p1.expect(.ident);
                                fsz = typeSize(tname.text) orelse return error.CompileError;
                            }
                            if (sd.field_count >= sd.fields.len) return error.CompileError;
                            sd.fields[sd.field_count] = Field{ .name = fname.text, .offset = off, .size = fsz };
                            sd.field_count += 1;
                            off += fsz;
                            _ = p1.accept(.comma);
                        }
                        _ = try p1.expect(.r_brace);
                        sd.size = off;
                        if (structs_count >= structs.len) return error.CompileError;
                        if (lookupStruct(name_tok.text) != null) {
                            print_err("duplicate struct", name_tok.line, name_tok.text);
                            return error.CompileError;
                        }
                        structs[structs_count] = sd;
                        structs_count += 1;
                        _ = p1.accept(.semicolon);
                        continue;
                    }
                    if (p1.accept(.keyword_enum)) {
                        // Optional explicit tag type: enum(u8)
                        if (p1.accept(.l_paren)) {
                            _ = try p1.expect(.ident); // tag type name (u8/u16/u32/u64/usize)
                            _ = try p1.expect(.r_paren);
                        }
                        _ = try p1.expect(.l_brace);
                        var ed = EnumDef{ .name = name_tok.text };
                        var next_value: u64 = 0;
                        while (p1.peek() != .r_brace and p1.peek() != .eof) {
                            const m_tok = try p1.expect(.ident);
                            if (p1.accept(.equal)) {
                                const num_tok = try p1.expect(.number);
                                next_value = std.fmt.parseInt(u64, num_tok.text, 0) catch return error.CompileError;
                            }
                            if (ed.member_count >= ed.members.len) return error.CompileError;
                            ed.members[ed.member_count] = EnumMember{ .name = m_tok.text, .value = next_value };
                            ed.member_count += 1;
                            next_value += 1;
                            _ = p1.accept(.comma);
                        }
                        _ = try p1.expect(.r_brace);
                        if (enums_count >= enums.len) return error.CompileError;
                        if (lookupEnum(name_tok.text) != null) {
                            print_err("duplicate enum", name_tok.line, name_tok.text);
                            return error.CompileError;
                        }
                        enums[enums_count] = ed;
                        enums_count += 1;
                        _ = p1.accept(.semicolon);
                        continue;
                    }
                }
            }
            p1.idx = save_idx;
            _ = p1.advance();
            while (p1.peek() != .semicolon and p1.peek() != .eof) _ = p1.advance();
            _ = p1.accept(.semicolon);
        } else if (p1.peek() == .keyword_var or p1.peek() == .keyword_let) {
            _ = p1.advance();
            while (p1.peek() != .semicolon and p1.peek() != .eof) _ = p1.advance();
            _ = p1.accept(.semicolon);
        } else {
            _ = p1.advance();
        }
    }

    // Emit startup entry: call main, then exit
    emit(0);
    emit(enc_movz(0, 0, 0));
    emit(enc_movz(8, 3, 0));
    emit(enc_svc(0));

    // Pass 2: Compile function bodies
    var p2 = Parser{ .tokens = tokens };
    while (p2.peek() != .eof) {
        _ = p2.accept(.keyword_pub);
        if (p2.peek() == .keyword_fn) {
            _ = p2.advance();
            const name_tok = try p2.expect(.ident);
            const f_idx = lookupFunc(name_tok.text).?;
            functions[f_idx].address = @intCast(code_len);

            _ = try p2.expect(.l_paren);
            locals_count = 0;
            frame_size = 0;

            // Load arguments
            if (p2.peek() != .r_paren) {
                const p_name = try p2.expect(.ident);
                _ = try p2.expect(.colon);
                const pt = try parseType(&p2);
                locals[locals_count] = LocalVar{
                    .name = p_name.text,
                    .offset = frame_size,
                    .is_ptr = pt.is_ptr,
                    .ptr_elem_size = pt.ptr_elem_size,
                    .ptr_is_struct = pt.ptr_is_struct,
                    .ptr_struct_idx = pt.ptr_struct_idx,
                    .is_fnptr = pt.is_fnptr,
                    .is_struct = pt.is_struct,
                    .struct_idx = pt.struct_idx,
                    .is_array = pt.is_array,
                    .array_len = pt.array_len,
                    .elem_size = pt.elem_size,
                };
                locals_count += 1;
                frame_size += 8;
                while (p2.accept(.comma)) {
                    const next_p_name = try p2.expect(.ident);
                    _ = try p2.expect(.colon);
                    const next_pt = try parseType(&p2);
                    locals[locals_count] = LocalVar{
                        .name = next_p_name.text,
                        .offset = frame_size,
                        .is_ptr = next_pt.is_ptr,
                        .ptr_elem_size = next_pt.ptr_elem_size,
                        .ptr_is_struct = next_pt.ptr_is_struct,
                        .ptr_struct_idx = next_pt.ptr_struct_idx,
                        .is_fnptr = next_pt.is_fnptr,
                        .is_struct = next_pt.is_struct,
                        .struct_idx = next_pt.struct_idx,
                        .is_array = next_pt.is_array,
                        .array_len = next_pt.array_len,
                        .elem_size = next_pt.elem_size,
                    };
                    locals_count += 1;
                    frame_size += 8;
                }
            }
            _ = try p2.expect(.r_paren);
            _ = try parseType(&p2); // return type
            _ = try p2.expect(.l_brace);

            // Function prologue
            emit(enc_sub_imm(31, 31, 16));
            emit(enc_str(31, 30, 0));
            emit(enc_sub_imm(31, 31, 16));
            emit(enc_str(31, 19, 0));
            emit(enc_sub_imm(31, 31, 512));
            emit(enc_add_imm(31, 19, 0));

            var i: usize = 0;
            while (i < functions[f_idx].param_count) : (i += 1) {
                emit(enc_str(19, @intCast(i), @intCast(i)));
            }

            try pushDeferScope();
            while (p2.peek() != .r_brace and p2.peek() != .eof) try compileStatement(&p2);
            _ = try p2.expect(.r_brace);

            // Z2b: function-scope defers run on the fallthrough exit (in
            // reverse registration order) before the epilogue. Return
            // statements already emitted them inline, so each exit path runs
            // them exactly once.
            try emitScopeDefers(&p2, defer_scope_depth - 1);
            popDeferScope();

            // Function epilogue
            emit(enc_add_imm(19, 31, 0));
            emit(enc_add_imm(31, 31, 512));
            emit(enc_ldr(31, 19, 0));
            emit(enc_add_imm(31, 31, 16));
            emit(enc_ldr(31, 30, 0));
            emit(enc_add_imm(31, 31, 16));
            emit(enc_ret(30));
        } else if (p2.peek() == .keyword_const or p2.peek() == .keyword_var or p2.peek() == .keyword_let) {
            _ = p2.advance();
            while (p2.peek() != .semicolon and p2.peek() != .eof) _ = p2.advance();
            _ = p2.accept(.semicolon);
        } else {
            _ = p2.advance();
        }
    }

    // Resolve patches
    for (call_patches[0..call_patches_count]) |patch| {
        const target_addr = functions[patch.target_func_idx].address;
        if (target_addr == 0) {
            // Z3a: a call whose target never got a body (never defined in any
            // source) is a missing-symbol diagnostic, not a bare error.
            print_err("undefined function", 0, functions[patch.target_func_idx].name);
            return error.CompileError;
        }
        const rel = @as(i32, @intCast(target_addr)) - @as(i32, @intCast(patch.caller_pc));
        std.mem.writeInt(u32, code[patch.caller_pc..][0..4], enc_bl(rel), .little);
    }

    // Resolve &fn address patches (Z2b): each is a PC-relative ADR whose
    // target function's buffer address is known now that every body compiled.
    for (fn_addr_patches[0..fn_addr_patches_count]) |patch| {
        const target_addr = functions[patch.func_idx].address;
        if (target_addr == 0) {
            print_err("undefined function", 0, functions[patch.func_idx].name);
            return error.CompileError;
        }
        const rel_bytes = @as(i32, @intCast(target_addr)) - @as(i32, @intCast(patch.code_pc));
        std.mem.writeInt(u32, code[patch.code_pc..][0..4], enc_adr(0, rel_bytes), .little);
    }

    // Resolve string ADR patches
    for (string_patches[0..string_patches_count]) |patch| {
        const target_pc = code_len + patch.data_off;
        const rel_bytes = @as(i32, @intCast(target_pc)) - @as(i32, @intCast(patch.code_pc));
        std.mem.writeInt(u32, code[patch.code_pc..][0..4], enc_adr(patch.rd, rel_bytes), .little);
    }

    const main_idx = lookupFunc("main") orelse {
        // Z3a: across N files there must be exactly one `main`.
        print_err("no main function", 0, "");
        return error.CompileError;
    };
    const main_addr = functions[main_idx].address;
    std.mem.writeInt(u32, code[0..4], enc_bl(@intCast(main_addr)), .little);

    return code_len;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
// Z3a (issue #758): multi-file CLI — `zc a.z b.z out.elf`. The LAST argv
// word is the output; every word before it is a source (up to MAX_FILES).
// Backward compatible: `zc a.z` compiles one source to the default output,
// and no args compiles /host/MAIN.Z -> /host/MAIN.ELF.
pub export fn _start(argc: usize, argv: ?[*]const [256]u8) callconv(.c) noreturn {
    var src_path_bufs: [MAX_FILES][40]u8 = @as([MAX_FILES][40]u8, @splat(@as([40]u8, @as([40]u8, @splat(@as(u8, 0))))));
    var src_lens: [MAX_FILES]usize = @as([MAX_FILES]usize, @splat(@as(usize, 0)));
    var src_paths: [MAX_FILES][]const u8 = undefined;
    var out_path_buf: [40]u8 = @as([40]u8, @splat(@as(u8, 0)));
    // M34 HF6 (issue #740): the host share is the only store — the
    // defaults route to /host/ (the old /esp prefix would resolve to a
    // literal "esp/" subdirectory on the share and fail to write).
    @memcpy(src_path_bufs[0][0..12], "/host/MAIN.Z");
    src_lens[0] = 12;
    @memcpy(out_path_buf[0..14], "/host/MAIN.ELF");
    var out_len: usize = 14;
    var src_count: usize = 1;

    if (argc >= 1) {
        if (argv) |slots| {
            if (argc == 1) {
                copy_arg(&src_path_bufs[0], &src_lens[0], slots[0]);
                src_count = 1;
            } else {
                src_count = @min(argc - 1, MAX_FILES);
                var i: usize = 0;
                while (i < src_count) : (i += 1) {
                    copy_arg(&src_path_bufs[i], &src_lens[i], slots[i]);
                }
                copy_arg(&out_path_buf, &out_len, slots[argc - 1]);
            }
        }
    }
    for (0..src_count) |i| src_paths[i] = src_path_bufs[i][0..src_lens[i]];

    run(src_paths[0..src_count], out_path_buf[0..out_len]);
}

fn copy_arg(dst: *[40]u8, len: *usize, slot: [256]u8) void {
    const n = std.mem.indexOfScalar(u8, &slot, 0) orelse slot.len;
    const take = @min(n, dst.len);
    @memcpy(dst[0..take], slot[0..take]);
    len.* = take;
}

// Shared source arena. The kernel caps a SINGLE file_read at 2048 B
// (syscall.zig take_count), so run() drains each source with a chunked
// read-until-EOF loop into this arena — a one-shot read would silently
// truncate any source above 2048 B in-guest (the old per-file staging
// buffer had exactly that bug for 2048..4096 B files). Sources are
// arena-bounded: the whole compile group must fit, and the load fails
// loudly instead of truncating when it does not. Keeping the arena small
// matters: ZC.BIN's text + bss + the 256-byte argv block must stay under
// the loader's 256 KiB exec_program_max (exec.zig). 24576 -> 32768 B
// (+8 KiB bss over the old [MAX_FILES][4096] staging).
const source_arena_cap: usize = 32768;
var source_arena: [source_arena_cap]u8 = undefined;
var image_buf: [elf_code_offset + 32768]u8 = undefined;

fn run(src_paths: []const []const u8, out_path: []const u8) noreturn {
    var sources: [MAX_FILES][]const u8 = undefined;
    var arena_off: usize = 0;
    for (src_paths, 0..) |src_path, i| {
        const fd = file_open(src_path, MODE_READ);
        if (fd < 0) {
            console_puts("zc: cannot open source\n");
            sys_exit(1);
        }
        var total: usize = 0;
        while (true) {
            const room = source_arena_cap - (arena_off + total);
            if (room == 0) {
                // Arena exactly full: probe one byte (into a stack var, not
                // the arena) to tell "the file ends exactly here" from "the
                // file continues past the arena" — never truncate silently.
                var probe: u8 = 0;
                if (file_read(@intCast(fd), (&probe)[0..1]) > 0) {
                    console_puts("zc: source group exceeds arena\n");
                    sys_exit(6);
                }
                break;
            }
            const n = file_read(@intCast(fd), source_arena[arena_off + total ..]);
            if (n < 0) {
                console_puts("zc: source read error\n");
                sys_exit(6);
            }
            if (n == 0) break;
            total += @intCast(n);
        }
        file_close(@intCast(fd));
        if (total == 0) {
            console_puts("zc: empty or unreadable source\n");
            sys_exit(2);
        }
        sources[i] = source_arena[arena_off .. arena_off + total];
        arena_off += total;
    }

    const bytes = compileFiles(sources[0..src_paths.len]) catch {
        console_puts("zc: compile failed\n");
        sys_exit(3);
    };

    const total = build_elf32_with_data(code[0..bytes], data_buf[0..data_len], 0, &image_buf) catch {
        console_puts("zc: image generation failed\n");
        sys_exit(4);
    };

    const ofd = file_open(out_path, MODE_CREATE | MODE_WRITE);
    if (ofd < 0) {
        console_puts("zc: cannot create output\n");
        sys_exit(5);
    }
    // The kernel refuses a single file_write > 2048 B (syscall.zig; the z2a
    // heap fixture learned this), and the generated ELF now exceeds that
    // (the stdz app + library compile to ~7 KiB), so drain it in chunks.
    var w: usize = 0;
    while (w < total) {
        const take = @min(total - w, 2048);
        _ = file_write(@intCast(ofd), image_buf[w .. w + take]);
        w += take;
    }
    file_close(@intCast(ofd));

    console_puts("zc: successfully compiled in-guest\n");
    sys_exit(0);
}

// ---------------------------------------------------------------------------
// Host Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "zc: tokenizer handles keywords, identifiers, numbers, and symbols" {
    const src = "fn main() void { let x: u64 = 42; return x; }";
    var t = Tokenizer{ .src = src };
    try testing.expectEqual(TokenKind.keyword_fn, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.l_paren, t.next().kind);
    try testing.expectEqual(TokenKind.r_paren, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.l_brace, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_let, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.colon, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.equal, t.next().kind);
    try testing.expectEqual(TokenKind.number, t.next().kind);
    try testing.expectEqual(TokenKind.semicolon, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_return, t.next().kind);
}

test "zc: compiles trivial program to AArch64 machine code" {
    const src = "fn main() void { return; }";
    const bytes = try compile(src);
    try testing.expect(bytes > 20);
    // startup shim + prologue + epilogue
    try testing.expectEqual(@as(u32, enc_bl(16)), std.mem.readInt(u32, code[0..4], .little));
}

test "zc: compiles simple expression arithmetic" {
    const src = "fn main() void { let x = (3 + 4) * 5; return; }";
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z0.5 dialect contract with @import(\"zc\") and zc.exit" {
    const src =
        \\const zc = @import("zc");
        \\
        \\pub fn main() void {
        \\    zc.exit(72);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
    // main is called from entry at byte 0
    try testing.expectEqual(@as(u32, enc_bl(16)), std.mem.readInt(u32, code[0..4], .little));
}

test "zc: Z0.5 zc builtins (write, yield, sleep, file ops)" {
    const src =
        \\const zc = @import("zc");
        \\
        \\pub fn main() void {
        \\    zc.yield();
        \\    zc.sleep(5);
        \\    _ = zc.write(1, 4096, 12);
        \\    let fd = zc.file_open("/f", 1);
        \\    _ = zc.file_read(fd, 200, 50);
        \\    _ = zc.file_write(fd, 200, 50);
        \\    zc.file_close(fd);
        \\    zc.exit(0);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: tokenizer handles dot, at, string literals, and pub keyword" {
    const src = "const zc = @import(\"zc\"); pub fn main() void {}";
    var t = Tokenizer{ .src = src };
    try testing.expectEqual(TokenKind.keyword_const, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.equal, t.next().kind);
    try testing.expectEqual(TokenKind.at, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.l_paren, t.next().kind);
    try testing.expectEqual(TokenKind.string_lit, t.next().kind);
    try testing.expectEqual(TokenKind.r_paren, t.next().kind);
    try testing.expectEqual(TokenKind.semicolon, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_pub, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_fn, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
}

test "zc: VL6 GUI consumer builtins (win_open, win_fill, win_present, win_close)" {
    const src =
        \\const zc = @import("zc");
        \\
        \\pub fn main() void {
        \\    const wid: u64 = zc.win_open(64, 64, 256, 192);
        \\    _ = zc.win_fill(wid, 0, 0, 256, 192, 0x1a2b3c);
        \\    _ = zc.win_fill(wid, 8, 8, 48, 48, 0xff0000);
        \\    _ = zc.win_present(wid);
        \\    zc.win_close(wid);
        \\    zc.exit(72);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
    // entry jumps to main
    try testing.expectEqual(@as(u32, enc_bl(16)), std.mem.readInt(u32, code[0..4], .little));
}

test "zc: Z1a string literal unescape and data segment emission" {
    const src =
        \\const zc = @import("zc");
        \\
        \\pub fn main() void {
        \\    zc.print("Hello, world!\n");
        \\    _ = zc.write(1, "Second line\n");
        \\    zc.exit(0);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
    try testing.expect(data_len > 0);
    try testing.expectEqualStrings("Hello, world!\nSecond line\n", data_buf[0..data_len]);

    const total = try build_elf32_with_data(code[0..bytes], data_buf[0..data_len], 0, &image_buf);
    try testing.expect(total == elf_code_offset + bytes + data_len);
}

test "zc: Z1b array allocation, indexed store/load, and print_array" {
    const src =
        \\const zc = @import("zc");
        \\
        \\pub fn main() void {
        \\    var buf: [8]u8 = undefined;
        \\    var i: u64 = 0;
        \\    while (i < 8) {
        \\        buf[i] = 65 + i;
        \\        i = i + 1;
        \\    }
        \\    zc.print_array(buf);
        \\    var sum: u64 = 0;
        \\    i = 0;
        \\    while (i < 8) {
        \\        sum = sum + buf[i];
        \\        i = i + 1;
        \\    }
        \\    if (sum == 548) {
        \\        zc.exit(0);
        \\    } else {
        \\        zc.exit(1);
        \\    }
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
    const total = try build_elf32_with_data(code[0..bytes], data_buf[0..data_len], 0, &image_buf);
    try testing.expect(total == elf_code_offset + bytes + data_len);
}

test "zc: Z1b u64 array with scaled index" {
    const src =
        \\const zc = @import("zc");
        \\
        \\pub fn main() void {
        \\    var arr: [4]u64 = undefined;
        \\    arr[0] = 10;
        \\    arr[1] = 20;
        \\    arr[2] = 30;
        \\    arr[3] = 40;
        \\    var s: u64 = arr[0] + arr[1] + arr[2] + arr[3];
        \\    if (s == 100) {
        \\        zc.exit(0);
        \\    } else {
        \\        zc.exit(1);
        \\    }
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1b tokenizer handles brackets" {
    const src = "var buf: [8]u8 = undefined; buf[0] = 65;";
    var t = Tokenizer{ .src = src };
    try testing.expectEqual(TokenKind.keyword_var, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.colon, t.next().kind);
    try testing.expectEqual(TokenKind.l_bracket, t.next().kind);
    try testing.expectEqual(TokenKind.number, t.next().kind);
    try testing.expectEqual(TokenKind.r_bracket, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
}

test "zc: Z1c struct definition, field offsets, member load/store, print_struct" {
    const src =
        \\const zc = @import("zc");
        \\const MyStruct = struct { a: u8, b: u8 };
        \\pub fn main() void {
        \\    var s: MyStruct = undefined;
        \\    s.a = 65;
        \\    s.b = 66;
        \\    zc.print_struct(s);
        \\    if (s.a == 65) {
        \\        if (s.b == 66) {
        \\            zc.exit(0);
        \\        }
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
    const total = try build_elf32_with_data(code[0..bytes], data_buf[0..data_len], 0, &image_buf);
    try testing.expect(total == elf_code_offset + bytes + data_len);
}

test "zc: Z1c struct with u64 fields and mixed types" {
    const src =
        \\const zc = @import("zc");
        \\const S = struct { x: u64, y: u64 };
        \\pub fn main() void {
        \\    var s: S = undefined;
        \\    s.x = 10;
        \\    s.y = 20;
        \\    var sum: u64 = s.x + s.y;
        \\    if (sum == 30) {
        \\        zc.exit(0);
        \\    } else {
        \\        zc.exit(1);
        \\    }
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1c tokenizer handles struct keyword" {
    const src = "const S = struct { a: u64, b: u8 };";
    var t = Tokenizer{ .src = src };
    try testing.expectEqual(TokenKind.keyword_const, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.equal, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_struct, t.next().kind);
    try testing.expectEqual(TokenKind.l_brace, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
}

test "zc: Z1d address-of and dereference load/store" {
    const src =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    var x: u64 = 42;
        \\    var p: *u64 = &x;
        \\    var y: u64 = p.*;
        \\    p.* = 84;
        \\    if (x == 84) {
        \\        if (y == 42) {
        \\            zc.exit(0);
        \\        }
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
    const total = try build_elf32_with_data(code[0..bytes], data_buf[0..data_len], 0, &image_buf);
    try testing.expect(total == elf_code_offset + bytes + data_len);
}

test "zc: Z1d pointer parameters swap" {
    const src =
        \\const zc = @import("zc");
        \\fn swap(a: *u64, b: *u64) void {
        \\    const tmp: u64 = a.*;
        \\    a.* = b.*;
        \\    b.* = tmp;
        \\}
        \\pub fn main() void {
        \\    var x: u64 = 10;
        \\    var y: u64 = 20;
        \\    swap(&x, &y);
        \\    if (x == 20) {
        \\        if (y == 10) {
        \\            zc.exit(0);
        \\        }
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1d pointer buffer indexing and print_ptr" {
    const src =
        \\const zc = @import("zc");
        \\fn fill_buf(buf: [*]u8, len: u64) void {
        \\    var i: u64 = 0;
        \\    while (i < len) {
        \\        buf[i] = 65 + i;
        \\        i = i + 1;
        \\    }
        \\}
        \\pub fn main() void {
        \\    var buf: [4]u8 = undefined;
        \\    fill_buf(&buf, 4);
        \\    zc.print_ptr(&buf, 4);
        \\    if (buf[0] == 65) {
        \\        if (buf[3] == 68) {
        \\            zc.exit(72);
        \\        }
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1d struct pointer parameter and member access" {
    const src =
        \\const zc = @import("zc");
        \\const Point = struct { x: u64, y: u64 };
        \\fn set_point(p: *Point, x: u64, y: u64) void {
        \\    p.x = x;
        \\    p.y = y;
        \\}
        \\pub fn main() void {
        \\    var pt: Point = undefined;
        \\    set_point(&pt, 100, 200);
        \\    if (pt.x == 100) {
        \\        if (pt.y == 200) {
        \\            zc.exit(0);
        \\        }
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1d tokenizer handles star and ampersand" {
    const src = "var p: *u64 = &x; p.* = 1;";
    var t = Tokenizer{ .src = src };
    try testing.expectEqual(TokenKind.keyword_var, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.colon, t.next().kind);
    try testing.expectEqual(TokenKind.star, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.equal, t.next().kind);
    try testing.expectEqual(TokenKind.ampersand, t.next().kind);
}

test "zc: Z1e for range iteration and sum" {
    const src =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    var sum: u64 = 0;
        \\    for (0..10) |i| {
        \\        sum = sum + i;
        \\    }
        \\    if (sum == 45) {
        \\        zc.exit(72);
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1e for array iteration with index capture" {
    const src =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    var arr: [4]u64 = undefined;
        \\    arr[0] = 10;
        \\    arr[1] = 20;
        \\    arr[2] = 30;
        \\    arr[3] = 40;
        \\    var total: u64 = 0;
        \\    var last_idx: u64 = 0;
        \\    for (arr, 0..) |v, i| {
        \\        total = total + v;
        \\        last_idx = i;
        \\    }
        \\    if (total == 100) {
        \\        if (last_idx == 3) {
        \\            zc.exit(72);
        \\        }
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1e switch statement with int, multi-value, and range prongs" {
    const src =
        \\const zc = @import("zc");
        \\fn classify(val: u64) u64 {
        \\    var res: u64 = 0;
        \\    switch (val) {
        \\        0 => { res = 10; },
        \\        1, 2 => { res = 20; },
        \\        3...5 => { res = 30; },
        \\        else => { res = 40; },
        \\    }
        \\    return res;
        \\}
        \\pub fn main() void {
        \\    if (classify(0) == 10) {
        \\        if (classify(2) == 20) {
        \\            if (classify(4) == 30) {
        \\                if (classify(9) == 40) {
        \\                    zc.exit(72);
        \\                }
        \\            }
        \\        }
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1e switch expression mapping int to string" {
    const src =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    var sum: u64 = 0;
        \\    for (0..10) |i| {
        \\        sum = sum + i;
        \\    }
        \\    const s: []const u8 = switch (sum) {
        \\        45 => "one",
        \\        else => "bad",
        \\    };
        \\    zc.print(s);
        \\    if (s[0] == 111) {
        \\        zc.exit(72);
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1e tokenizer handles for, switch, .., ..., =>" {
    const src = "for (0..10) |i| switch (x) { 0 => 1, 2...4 => 5, else => 6 }";
    var t = Tokenizer{ .src = src };
    try testing.expectEqual(TokenKind.keyword_for, t.next().kind);
    try testing.expectEqual(TokenKind.l_paren, t.next().kind);
    try testing.expectEqual(TokenKind.number, t.next().kind);
    try testing.expectEqual(TokenKind.double_dot, t.next().kind);
    try testing.expectEqual(TokenKind.number, t.next().kind);
    try testing.expectEqual(TokenKind.r_paren, t.next().kind);
    try testing.expectEqual(TokenKind.pipe, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.pipe, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_switch, t.next().kind);
    try testing.expectEqual(TokenKind.l_paren, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.r_paren, t.next().kind);
    try testing.expectEqual(TokenKind.l_brace, t.next().kind);
    try testing.expectEqual(TokenKind.number, t.next().kind);
    try testing.expectEqual(TokenKind.equal_greater, t.next().kind);
    try testing.expectEqual(TokenKind.number, t.next().kind);
    try testing.expectEqual(TokenKind.comma, t.next().kind);
    try testing.expectEqual(TokenKind.number, t.next().kind);
    try testing.expectEqual(TokenKind.triple_dot, t.next().kind);
    try testing.expectEqual(TokenKind.number, t.next().kind);
    try testing.expectEqual(TokenKind.equal_greater, t.next().kind);
    try testing.expectEqual(TokenKind.number, t.next().kind);
    try testing.expectEqual(TokenKind.comma, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_else, t.next().kind);
    try testing.expectEqual(TokenKind.equal_greater, t.next().kind);
    try testing.expectEqual(TokenKind.number, t.next().kind);
    try testing.expectEqual(TokenKind.r_brace, t.next().kind);
}

test "zc: Z2b tokenizer handles the defer keyword and fn-pointer type tokens" {
    const src = "defer *const fn(u64, u64) u64";
    var t = Tokenizer{ .src = src };
    try testing.expectEqual(TokenKind.keyword_defer, t.next().kind);
    try testing.expectEqual(TokenKind.star, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_const, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_fn, t.next().kind);
    try testing.expectEqual(TokenKind.l_paren, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.comma, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.r_paren, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
}

test "zc: Z2b function-scope defers compile and run on the return path" {
    const src =
        \\const zc = @import("zc");
        \\fn done() u64 {
        \\    defer zc.print("cleanup-a\n");
        \\    defer zc.print("cleanup-b\n");
        \\    return 7;
        \\}
        \\pub fn main() void {
        \\    const r: u64 = done();
        \\    if (r == 7) {
        \\        zc.exit(72);
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z2b if/while/for/switch scope defers compile" {
    const src =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    if (1 == 1) {
        \\        defer zc.print("if-body\n");
        \\    } else {
        \\        defer zc.print("else-body\n");
        \\    }
        \\    var i: u64 = 0;
        \\    while (i < 2) {
        \\        defer zc.print("iter\n");
        \\        i = i + 1;
        \\    }
        \\    for (0..2) |j| {
        \\        defer zc.print("for-iter\n");
        \\        _ = j;
        \\    }
        \\    switch (i) {
        \\        2 => {
        \\            defer zc.print("prong\n");
        \\        },
        \\        else => {
        \\            defer zc.print("other\n");
        \\        },
        \\    }
        \\    zc.exit(72);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z2b fn-pointer types, &fn, and indirect calls compile" {
    const src =
        \\const zc = @import("zc");
        \\fn add(a: u64, b: u64) u64 {
        \\    return a + b;
        \\}
        \\fn run_op(f: *const fn(u64, u64) u64, x: u64, y: u64) u64 {
        \\    return f(x, y);
        \\}
        \\pub fn main() void {
        \\    const fp: *const fn(u64, u64) u64 = &add;
        \\    if (run_op(fp, 40, 2) == 42) {
        \\        if (fp(6, 7) == 13) {
        \\            zc.exit(72);
        \\        }
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1f tokenizer handles enum keyword, tag type, and members" {
    const src = "const Color = enum(u8) { red, green = 2, blue }; var c: Color = Color.green;";
    var t = Tokenizer{ .src = src };
    try testing.expectEqual(TokenKind.keyword_const, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.equal, t.next().kind);
    try testing.expectEqual(TokenKind.keyword_enum, t.next().kind);
    try testing.expectEqual(TokenKind.l_paren, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.r_paren, t.next().kind);
    try testing.expectEqual(TokenKind.l_brace, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.comma, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.equal, t.next().kind);
    try testing.expectEqual(TokenKind.number, t.next().kind);
    try testing.expectEqual(TokenKind.comma, t.next().kind);
    try testing.expectEqual(TokenKind.ident, t.next().kind);
    try testing.expectEqual(TokenKind.r_brace, t.next().kind);
    try testing.expectEqual(TokenKind.semicolon, t.next().kind);
}

test "zc: Z1f enum declaration, member constants, and equality" {
    const src =
        \\const zc = @import("zc");
        \\const Color = enum(u8) { red, green, blue };
        \\pub fn main() void {
        \\    const c: Color = Color.green;
        \\    if (c == Color.green) {
        \\        zc.exit(72);
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1f enum-valued switch expression mapping tag to string" {
    const src =
        \\const zc = @import("zc");
        \\const Color = enum(u8) { red, green, blue };
        \\fn color_name(c: Color) []const u8 {
        \\    return switch (c) {
        \\        Color.red => "red",
        \\        Color.green => "green",
        \\        Color.blue => "blue",
        \\    };
        \\}
        \\pub fn main() void {
        \\    const c: Color = Color.green;
        \\    const s: []const u8 = color_name(c);
        \\    zc.print(s);
        \\    if (s[0] == 103) {
        \\        zc.exit(72);
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1f int-from-enum and enum-from-int casts" {
    const src =
        \\const zc = @import("zc");
        \\const Color = enum(u8) { red, green, blue };
        \\fn tag_of(c: Color) u8 {
        \\    return @backingInt(c);
        \\}
        \\pub fn main() void {
        \\    const c: Color = @fromBackingInt(1);
        \\    if (tag_of(c) == 1) {
        \\        zc.exit(72);
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z1f enum with explicit tag values and statement switch" {
    const src =
        \\const zc = @import("zc");
        \\const Mode = enum(u8) { idle = 3, busy, done };
        \\pub fn main() void {
        \\    const m: Mode = Mode.done;
        \\    var v: u64 = 0;
        \\    switch (m) {
        \\        Mode.idle => { v = 1; },
        \\        Mode.busy => { v = 2; },
        \\        Mode.done => { v = 3; },
        \\    }
        \\    if (v == 3) {
        \\        if (@backingInt(m) == 5) {
        \\            zc.exit(72);
        \\        }
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z2a mmap builtin returns a writable heap pointer" {
    const src =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    const heap: [*]u8 = zc.mmap(16384);
        \\    heap[0] = 65;
        \\    heap[4096] = 66;
        \\    if (heap[0] == 65) {
        \\        zc.exit(72);
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z2a file_open string path and pointer read/write compile" {
    const src =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    const buf: [*]u8 = zc.mmap(4096);
        \\    const fd: u64 = zc.file_open("/host/DATA.TXT", 1);
        \\    const n: u64 = zc.file_read(fd, buf, 1024);
        \\    const ofd: u64 = zc.file_open("/host/OUT.TXT", 6);
        \\    _ = zc.file_write(ofd, buf, n);
        \\    zc.file_close(fd);
        \\    zc.file_close(ofd);
        \\    if (n != 0) {
        \\        zc.exit(72);
        \\    }
        \\    zc.exit(1);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z2a chunked bump build and drain loops compile" {
    const src =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    const heap_cap: u64 = 16384;
        \\    const read_chunk: u64 = 1024;
        \\    const heap: [*]u8 = zc.mmap(heap_cap);
        \\    const in_fd: u64 = zc.file_open("/host/DATA.TXT", 1);
        \\    const out_fd: u64 = zc.file_open("/host/OUT.TXT", 6);
        \\    var used: u64 = 0;
        \\    var n: u64 = zc.file_read(in_fd, heap, read_chunk);
        \\    while (n != 0) {
        \\        if (used + n <= heap_cap - read_chunk) {
        \\            var i: u64 = 0;
        \\            while (i < n) {
        \\                heap[read_chunk + used + i] = heap[i];
        \\                i = i + 1;
        \\            }
        \\            used = used + n;
        \\        } else {
        \\            zc.exit(2); // bounded arena overflow
        \\        }
        \\        n = zc.file_read(in_fd, heap, read_chunk);
        \\    }
        \\    zc.file_close(in_fd);
        \\    if (used == 0) {
        \\        zc.exit(73);
        \\    }
        \\    var c: u64 = 0;
        \\    while (c < used) {
        \\        heap[c] = heap[read_chunk + c];
        \\        c = c + 1;
        \\    }
        \\    var left: u64 = used;
        \\    while (left > 0) {
        \\        var take: u64 = 2048;
        \\        if (left < take) {
        \\            take = left;
        \\        }
        \\        _ = zc.file_write(out_fd, heap, take);
        \\        var j: u64 = 0;
        \\        while (j < left - take) {
        \\            heap[j] = heap[j + take];
        \\            j = j + 1;
        \\        }
        \\        left = left - take;
        \\    }
        \\    zc.file_close(out_fd);
        \\    zc.print("heap-ok\n");
        \\    zc.exit(72);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z3a cross-file call — caller in file 2, callee in file 1" {
    const src_a = "fn greet(x: u64) u64 { return x + 5; }";
    const src_b =
        \\const zc = @import("zc");
        \\fn main() void {
        \\    let r = greet(3);
        \\    zc.print("z3a-lib-ok\n");
        \\    return;
        \\}
    ;
    const bytes = try compileFiles(&.{ src_a, src_b });
    try testing.expect(bytes > 0);
    // Both files' functions share one table, both got a real body address.
    try testing.expectEqual(@as(usize, 2), functions_count);
    const greet_idx = lookupFunc("greet").?;
    const main_idx = lookupFunc("main").?;
    try testing.expect(functions[greet_idx].address > 0);
    try testing.expect(functions[main_idx].address > 0);
    // The startup shim's BL to main patched in.
    try testing.expect(std.mem.readInt(u32, code[0..4], .little) != 0);
}

test "zc: Z3a forward cross-file call — caller in file 1, callee in file 2" {
    const src_a =
        \\const zc = @import("zc");
        \\fn main() void {
        \\    let r = later(10);
        \\    zc.print("z3a-fwd\n");
        \\    return;
        \\}
    ;
    const src_b = "fn later(x: u64) u64 { return x * 2; }";
    const bytes = try compileFiles(&.{ src_a, src_b });
    try testing.expect(bytes > 0);
    try testing.expectEqual(@as(usize, 2), functions_count);
    try testing.expect(functions[lookupFunc("later").?].address > 0);
    // The cross-file call went through a real patch, not a same-file BL.
    try testing.expect(call_patches_count >= 1);
}

test "zc: Z3a main may live in any file" {
    const src_a = "fn helper() u64 { return 7; }";
    const src_b =
        \\const zc = @import("zc");
        \\fn main() void {
        \\    let r = helper();
        \\    zc.print("z3a-main2\n");
        \\    return;
        \\}
    ;
    const bytes = try compileFiles(&.{ src_a, src_b });
    try testing.expect(bytes > 0);
    try testing.expectEqual(@as(usize, 2), functions_count);
}

test "zc: Z3a duplicate function across files is a diagnostic" {
    const src_a = "fn dup() u64 { return 1; }";
    const src_b = "fn dup() u64 { return 2; } fn main() void { return; }";
    try testing.expectError(error.CompileError, compileFiles(&.{ src_a, src_b }));
}

test "zc: Z3a duplicate main across files is a diagnostic" {
    const src_a = "fn main() void { return; }";
    const src_b = "fn main() void { return; }";
    try testing.expectError(error.CompileError, compileFiles(&.{ src_a, src_b }));
}

test "zc: Z3a missing function is a diagnostic, not a silent patch" {
    const src =
        \\const zc = @import("zc");
        \\fn main() void {
        \\    zc.exit(ghost());
        \\}
    ;
    try testing.expectError(error.CompileError, compileFiles(&.{src}));
}

test "zc: Z3a single-file compile still works through the wrapper" {
    const src =
        \\const zc = @import("zc");
        \\fn main() void {
        \\    zc.print("z3a-single\n");
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z3b intCast compiles as an identity cast" {
    const src =
        \\const zc = @import("zc");
        \\fn main() void {
        \\    var buf: [4]u8 = undefined;
        \\    buf[0] = @intCast(48 + 7);
        \\    if (buf[0] == 55) {
        \\        zc.exit(72);
        \\    }
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
}

test "zc: Z3b stdz-shaped multi-file compile — fmt + builder + ring + app" {
    // Abbreviated stand-ins for the real stdz modules (same dialect surface:
    // @intCast identity casts, explicit [*]u8 + u64 buffers, flat namespace).
    const fmt_src =
        \\fn fmt_dec(v: u64, out: [*]u8) u64 {
        \\    var buf: [20]u8 = undefined;
        \\    var i: u64 = 0;
        \\    var x: u64 = v;
        \\    while (x >= 10) {
        \\        buf[i] = @intCast(48 + (x - (x / 10) * 10));
        \\        i = i + 1;
        \\        x = x / 10;
        \\    }
        \\    buf[i] = @intCast(48 + x);
        \\    i = i + 1;
        \\    var n: u64 = 0;
        \\    while (n < i) {
        \\        out[n] = buf[i - 1 - n];
        \\        n = n + 1;
        \\    }
        \\    return i;
        \\}
    ;
    const builder_src =
        \\const Builder = struct {
        \\    buf: [*]u8,
        \\    cap: u64,
        \\    len: u64,
        \\};
        \\fn sb_append(b: *Builder, src: [*]u8, n: u64) u64 {
        \\    if (b.len + n > b.cap) {
        \\        return b.len;
        \\    }
        \\    var i: u64 = 0;
        \\    const bp: [*]u8 = b.buf;
        \\    while (i < n) {
        \\        bp[b.len + i] = src[i];
        \\        i = i + 1;
        \\    }
        \\    b.len = b.len + n;
        \\    return b.len;
        \\}
        \\fn sb_u64(b: *Builder, v: u64) u64 {
        \\    var tmp: [20]u8 = undefined;
        \\    const n: u64 = fmt_dec(v, &tmp);
        \\    return sb_append(b, &tmp, n);
        \\}
    ;
    const ring_src =
        \\const Ring = struct {
        \\    buf: [*]u8,
        \\    cap: u64,
        \\    head: u64,
        \\    tail: u64,
        \\    count: u64,
        \\};
        \\fn ring_put(r: *Ring, byte: u64) u64 {
        \\    if (r.count == r.cap) {
        \\        return 0;
        \\    }
        \\    const bp: [*]u8 = r.buf;
        \\    bp[r.head] = @intCast(byte);
        \\    r.head = r.head + 1;
        \\    if (r.head == r.cap) {
        \\        r.head = 0;
        \\    }
        \\    r.count = r.count + 1;
        \\    return 1;
        \\}
    ;
    const app_src =
        \\const zc = @import("zc");
        \\fn main() void {
        \\    const heap: [*]u8 = zc.mmap(32768);
        \\    var b: Builder = undefined;
        \\    b.len = 0;
        \\    var r: Ring = undefined;
        \\    r.cap = 64;
        \\    _ = sb_u64(&b, fmt_dec(12345, heap));
        \\    _ = ring_put(&r, @intCast(heap[0]));
        \\    zc.print("z3b-ok\n");
        \\}
    ;
    const bytes = try compileFiles(&.{ app_src, fmt_src, builder_src, ring_src });
    try testing.expect(bytes > 0);
    // app(1) + fmt(1) + builder(2) + ring(1) = 5 functions across 4 files.
    try testing.expectEqual(@as(usize, 5), functions_count);
    // Cross-file calls resolved through real patches (fmt_dec/sb_u64 into
    // the app, fmt_dec into builder, sb_append into sb_u64).
    try testing.expect(call_patches_count >= 3);
    try testing.expect(functions[lookupFunc("fmt_dec").?].address > 0);
    try testing.expect(functions[lookupFunc("sb_u64").?].address > 0);
    try testing.expect(functions[lookupFunc("ring_put").?].address > 0);
    try testing.expect(functions[lookupFunc("main").?].address > 0);
}

// ---------------------------------------------------------------------------
// M70c S3 (issue #1455): `break` / `continue`.
//
// The behavioral pins are the corpus gate's (tests/zc-corpus/s3-break.z runs
// in-guest AND as the Z4b host-built dual-run leg). What a host-side test can
// add on top of "it compiles" is where the parked jumps were actually aimed,
// so these decode the emitted `b` words rather than trusting the count.
// ---------------------------------------------------------------------------

const Branch = struct { idx: usize, target: usize };

/// Test-only: the absolute BYTE index a plain `b` at byte index `idx` targets,
/// or null when the word is not a `b`. zc's branch offsets are byte deltas from
/// the branch's own address, so decoding one shows the real jump target.
fn bTarget(idx: usize) ?usize {
    const word = std.mem.readInt(u32, code[idx..][0..4], .little);
    if ((word >> 26) != 0b000101) return null;
    var imm: i64 = @intCast(word & 0x03FF_FFFF);
    if ((imm & 0x0200_0000) != 0) imm -= 0x0400_0000; // sign-extend imm26
    const target = @as(i64, @intCast(idx)) + imm * 4;
    if (target < 0) return null;
    return @intCast(target);
}

/// Test-only: every plain `b` the last compile emitted, in emission order.
fn collectBranches(out: []Branch) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < code_len) : (i += 4) {
        if (bTarget(i)) |t| {
            out[n] = Branch{ .idx = i, .target = t };
            n += 1;
        }
    }
    return n;
}

/// Test-only: how many `svc` instructions the last compile emitted.
fn svcCount() usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < code_len) : (i += 4) {
        const w = std.mem.readInt(u32, code[i..][0..4], .little);
        if ((w & 0xFFE0_001F) == 0xD400_0001) n += 1;
    }
    return n;
}

test "zc: S3 break leaves the loop — the parked jump targets the loop exit" {
    const src =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    var i: u64 = 0;
        \\    while (i < 10) {
        \\        if (i == 3) {
        \\            break;
        \\        }
        \\        i = i + 1;
        \\    }
        \\    zc.exit(72);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
    var branches: [16]Branch = undefined;
    const n = collectBranches(&branches);
    // The loop's own back-edge is the only BACKWARD jump here.
    var back: ?Branch = null;
    var backward: usize = 0;
    for (branches[0..n]) |b| {
        if (b.target < b.idx) {
            backward += 1;
            back = b;
        }
    }
    try testing.expectEqual(@as(usize, 1), backward);
    // ...and exactly one forward jump aims at the instruction right after it:
    // the `break`, not the if's end-branch (which lands inside the body).
    var at_exit: usize = 0;
    for (branches[0..n]) |b| {
        if (b.target == back.?.idx + 4) at_exit += 1;
    }
    try testing.expectEqual(@as(usize, 1), at_exit);
}

test "zc: S3 continue in a while re-tests the condition (same target as the back-edge)" {
    const src =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    var i: u64 = 0;
        \\    while (i < 10) {
        \\        i = i + 1;
        \\        if (i == 4) {
        \\            continue;
        \\        }
        \\    }
        \\    zc.exit(72);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
    var branches: [16]Branch = undefined;
    const n = collectBranches(&branches);
    var backward: usize = 0;
    var target: usize = 0;
    for (branches[0..n]) |b| {
        if (b.target < b.idx) {
            backward += 1;
            target = b.target;
        }
    }
    // Two backward jumps — the loop back-edge and the `continue` — and BOTH
    // must land on the condition test, or the loop would skip its re-test.
    try testing.expectEqual(@as(usize, 2), backward);
    const cond_pc = branches[0..n][0].target;
    _ = cond_pc;
    var same_target: usize = 0;
    for (branches[0..n]) |b| {
        if (b.target == target) same_target += 1;
    }
    try testing.expectEqual(@as(usize, 2), same_target);
}

test "zc: S3 continue in a for lands on the step, not the loop top" {
    // A body of exactly `continue` keeps the emitted branch list unambiguous:
    // no `if`, and so none of the plain `b`s a comparison's 0/1
    // materialization emits — the two branches found below ARE the loop's own
    // control transfers.
    const src =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    for (0..6) |k| {
        \\        _ = k;
        \\        continue;
        \\    }
        \\    zc.exit(72);
        \\}
    ;
    const bytes = try compile(src);
    try testing.expect(bytes > 0);
    var branches: [16]Branch = undefined;
    const n = collectBranches(&branches);
    var back_idx: usize = 0;
    var back_target: usize = 0;
    var backward: usize = 0;
    var forward: usize = 0;
    var fwd_target: usize = 0;
    for (branches[0..n]) |b| {
        if (b.target < b.idx) {
            backward += 1;
            back_idx = b.idx;
            back_target = b.target;
        } else {
            forward += 1;
            fwd_target = b.target;
        }
    }
    // A `for` has no back-edge a `continue` can reuse: its increment sits at
    // the BOTTOM of the body, so `continue` is a FORWARD jump. (The `while`
    // case above is the mirror image — backward, onto the condition.) Exactly
    // one backward jump is therefore the loop's own back-edge; aiming
    // `continue` at the loop top instead would make this 2.
    try testing.expectEqual(@as(usize, 1), backward);
    try testing.expectEqual(@as(usize, 1), forward);
    // The step is the three-instruction (ldr/add/str) increment immediately
    // before the back-edge, so `continue` must land exactly there: strictly
    // past the loop top, strictly inside the loop, and on the step's own
    // address. The loop top is the bug that would spin forever; past the
    // back-edge is the bug that would exit the loop.
    try testing.expect(fwd_target > back_target);
    try testing.expect(fwd_target < back_idx);
    try testing.expectEqual(back_idx - 12, fwd_target);
}

test "zc: S3 break and continue outside a loop are diagnostics" {
    const brk =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    break;
        \\    zc.exit(72);
        \\}
    ;
    try testing.expectError(error.CompileError, compile(brk));
    const cont =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    if (1 == 1) {
        \\        continue;
        \\    }
        \\    zc.exit(72);
        \\}
    ;
    try testing.expectError(error.CompileError, compile(cont));
}

test "zc: S3 break emits the body's registered defers on the break path" {
    // Two programs that differ ONLY by one `defer` in the loop body. That
    // defer is emitted twice — once on the `break` path, once at the body's
    // (unreachable) fallthrough end — so the compile carries exactly two more
    // SVC words than the same loop without it. A `break` that skipped the
    // unwind would carry one, i.e. the delta would be 1 and this fails. The
    // subtraction rather than an absolute count keeps the assertion about the
    // break path and not about how many syscalls a builtin happens to lower to.
    const with_defer =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    while (1 == 1) {
        \\        defer zc.print("d\n");
        \\        break;
        \\    }
        \\    zc.exit(72);
        \\}
    ;
    _ = try compile(with_defer);
    const with_count = svcCount();
    const without_defer =
        \\const zc = @import("zc");
        \\pub fn main() void {
        \\    while (1 == 1) {
        \\        break;
        \\    }
        \\    zc.exit(72);
        \\}
    ;
    _ = try compile(without_defer);
    const without_count = svcCount();
    try testing.expect(without_count >= 1); // main still exits
    try testing.expectEqual(without_count + 2, with_count);
}

test "zc: S3 corpus fixture compiles in-guest (tests/zc-corpus/s3-break.z)" {
    // The fixture arrives through the `zc_corpus_fixtures` build option
    // (build.zig embeds tests/zc-corpus/s3-break.z), so a fixture edit that
    // stops compiling under zc fails HERE instead of costing a boot to
    // discover, and the file the gate stages cannot drift from the file this
    // test compiles.
    const fixtures = @import("zc_corpus_fixtures");
    const bytes = try compile(fixtures.s3_break);
    try testing.expect(bytes > 0);
}
