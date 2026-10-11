//! VirelaiOS userland shell scripting (M45 card SH5 — ADR 0021 D4/D6,
//! issue #1081).
//!
//! The pure parsing/evaluation behind M19 scripting: `;`/`&&`/`||` chains,
//! `$(( ))` arithmetic, whole-word keyword parsing for `if`/`for`/`while`,
//! `;`-split command bodies, and a bounded function table. No syscalls and no
//! allocation, so every construct is host-testable; the execution glue lives
//! in `user/src/sh.zig`.

const std = @import("std");
const pipe = @import("pipe.zig");

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

pub fn trimStart(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and isSpace(s[i])) i += 1;
    return s[i..];
}

pub fn trimEnd(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and isSpace(s[end - 1])) end -= 1;
    return s[0..end];
}

pub fn trim(s: []const u8) []const u8 {
    return trimStart(trimEnd(s));
}

/// Trim surrounding whitespace and any trailing `;` separators (construct
/// bodies sit before `; fi` / `; done`, so the boundary keeps a stray `;`).
fn trimSemi(s: []const u8) []const u8 {
    var v = trim(s);
    while (v.len > 0 and v[v.len - 1] == ';') v = trim(v[0 .. v.len - 1]);
    return v;
}

// ---------------------------------------------------------------------------
// Chains: `;`, `&&`, `||` (equal precedence, left to right).
// ---------------------------------------------------------------------------

pub const ChainOp = enum { seq, run_and, run_or };
pub const chain_max = 4;

pub const Chain = struct {
    segs: [chain_max][]const u8 = undefined,
    ops: [chain_max - 1]ChainOp = undefined,
    seg_count: usize = 0,
    op_count: usize = 0,
};

pub const ChainSplit = union(enum) {
    none,
    too_many,
    chain: Chain,
};

pub fn chainSplit(line: []const u8) ChainSplit {
    var in_quote = false;
    var in_single = false;
    var esc = false;
    var result = Chain{};
    var start: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (esc) {
            esc = false;
            continue;
        }
        if (line[i] == '\\') {
            esc = true;
            continue;
        }
        if (line[i] == '\'') {
            in_single = !in_single;
            continue;
        }
        if (line[i] == '"') {
            in_quote = !in_quote;
            continue;
        }
        if (in_quote or in_single) continue;
        var op: ?ChainOp = null;
        var op_width: usize = 1;
        if (line[i] == '&' and i + 1 < line.len and line[i + 1] == '&') {
            op = .run_and;
            op_width = 2;
        } else if (line[i] == '|' and i + 1 < line.len and line[i + 1] == '|') {
            op = .run_or;
            op_width = 2;
        } else if (line[i] == ';') {
            op = .seq;
        }
        if (op) |o| {
            if (result.seg_count >= chain_max - 1) return .too_many;
            result.segs[result.seg_count] = trim(line[start..i]);
            result.ops[result.op_count] = o;
            result.seg_count += 1;
            result.op_count += 1;
            start = i + op_width;
            i += op_width - 1;
        }
    }
    result.segs[result.seg_count] = trim(line[start..]);
    result.seg_count += 1;
    if (result.op_count == 0) return .none;
    return .{ .chain = result };
}

// ---------------------------------------------------------------------------
// `$(( ))` arithmetic: recursive-descent over + - * / % and parentheses.
// ---------------------------------------------------------------------------

const ArithToken = enum { num, plus, minus, star, slash, percent, lparen, rparen, eof };

const ArithLexer = struct {
    src: []const u8,
    pos: usize = 0,
    peek_token: ArithToken = .eof,
    peek_val: i64 = 0,

    fn init(src: []const u8) ArithLexer {
        var l = ArithLexer{ .src = src };
        l.advance();
        return l;
    }

    fn advance(self: *ArithLexer) void {
        while (self.pos < self.src.len and isSpace(self.src[self.pos])) self.pos += 1;
        if (self.pos >= self.src.len) {
            self.peek_token = .eof;
            return;
        }
        switch (self.src[self.pos]) {
            '+' => {
                self.peek_token = .plus;
                self.pos += 1;
            },
            '-' => {
                self.peek_token = .minus;
                self.pos += 1;
            },
            '*' => {
                self.peek_token = .star;
                self.pos += 1;
            },
            '/' => {
                self.peek_token = .slash;
                self.pos += 1;
            },
            '%' => {
                self.peek_token = .percent;
                self.pos += 1;
            },
            '(' => {
                self.peek_token = .lparen;
                self.pos += 1;
            },
            ')' => {
                self.peek_token = .rparen;
                self.pos += 1;
            },
            '0'...'9' => {
                var val: i64 = 0;
                while (self.pos < self.src.len and self.src[self.pos] >= '0' and self.src[self.pos] <= '9') {
                    val = val * 10 + @as(i64, self.src[self.pos] - '0');
                    self.pos += 1;
                }
                self.peek_token = .num;
                self.peek_val = val;
            },
            else => self.peek_token = .eof,
        }
    }

    fn next(self: *ArithLexer) ArithToken {
        const t = self.peek_token;
        self.advance();
        return t;
    }
};

fn arithExpr(lexer: *ArithLexer) i64 {
    var left = arithTerm(lexer);
    while (true) {
        switch (lexer.peek_token) {
            .plus => {
                _ = lexer.next();
                left += arithTerm(lexer);
            },
            .minus => {
                _ = lexer.next();
                left -= arithTerm(lexer);
            },
            else => break,
        }
    }
    return left;
}

fn arithTerm(lexer: *ArithLexer) i64 {
    var left = arithFactor(lexer);
    while (true) {
        switch (lexer.peek_token) {
            .star => {
                _ = lexer.next();
                left *= arithFactor(lexer);
            },
            .slash => {
                _ = lexer.next();
                const r = arithFactor(lexer);
                left = if (r != 0) @divTrunc(left, r) else 0;
            },
            .percent => {
                _ = lexer.next();
                const r = arithFactor(lexer);
                left = if (r != 0) @mod(left, r) else 0;
            },
            else => break,
        }
    }
    return left;
}

fn arithFactor(lexer: *ArithLexer) i64 {
    if (lexer.peek_token == .minus) {
        _ = lexer.next();
        return -arithFactor(lexer);
    }
    if (lexer.peek_token == .plus) {
        _ = lexer.next();
        return arithFactor(lexer);
    }
    if (lexer.peek_token == .num) {
        const val = lexer.peek_val;
        _ = lexer.next();
        return val;
    }
    if (lexer.peek_token == .lparen) {
        _ = lexer.next();
        const val = arithExpr(lexer);
        _ = lexer.next(); // consume ')'
        return val;
    }
    return 0;
}

/// Evaluate a bare arithmetic expression (no `$(( ))` wrapper).
pub fn evalArith(expr: []const u8) i64 {
    var lexer = ArithLexer.init(expr);
    return arithExpr(&lexer);
}

/// Splice the first `$((expr))` in `raw` into its decimal result, into
/// `out`. Returns `raw` unchanged when there is no expansion.
pub fn arithExpand(raw: []const u8, out: []u8) []const u8 {
    const at = std.mem.indexOf(u8, raw, "$((") orelse return raw;
    const expr_start = at + 3;

    var depth: usize = 0;
    var i: usize = expr_start;
    while (i + 1 < raw.len) : (i += 1) {
        if (raw[i] == '(') {
            depth += 1;
        } else if (raw[i] == ')') {
            if (depth == 0 and raw[i + 1] == ')') break;
            if (depth > 0) depth -= 1;
        }
    }
    if (i + 1 >= raw.len) return raw;
    const expr = raw[expr_start..i];
    if (expr.len == 0) return raw;

    var num_buf: [24]u8 = undefined;
    const str = std.fmt.bufPrint(&num_buf, "{d}", .{evalArith(expr)}) catch return raw;

    const prefix = raw[0..at];
    const suffix = raw[i + 2 ..];
    var op: usize = 0;
    const pn = @min(prefix.len, out.len);
    @memcpy(out[0..pn], prefix[0..pn]);
    op += pn;
    const sn = @min(str.len, out.len - op);
    @memcpy(out[op..][0..sn], str[0..sn]);
    op += sn;
    const xn = @min(suffix.len, out.len - op);
    @memcpy(out[op..][0..xn], suffix[0..xn]);
    op += xn;
    return out[0..op];
}

// ---------------------------------------------------------------------------
// Command-substitution location scan: `$(...)` (non-nested).
// ---------------------------------------------------------------------------

pub const CmdSubst = struct {
    prefix: []const u8,
    inner: []const u8,
    suffix: []const u8,
};

/// Locate the first `$(...)` in `raw`. Returns null when absent, unmatched,
/// or empty. Nested `$(` is refused (null).
pub fn locateCommandSubst(raw: []const u8) ?CmdSubst {
    // `$((...))` is arithmetic, not command substitution — skip those.
    var search: usize = 0;
    var at: usize = 0;
    while (true) {
        at = std.mem.indexOfPos(u8, raw, search, "$(") orelse return null;
        if (at + 2 < raw.len and raw[at + 2] == '(') {
            search = at + 3;
            continue;
        }
        break;
    }
    const start = at + 2;
    var depth: usize = 1;
    var i: usize = start;
    while (i < raw.len and depth > 0) : (i += 1) {
        if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '(') return null;
        if (raw[i] == '(') {
            depth += 1;
        } else if (raw[i] == ')') {
            depth -= 1;
        }
    }
    if (depth != 0) return null;
    const end = i - 1;
    const inner = trim(raw[start..end]);
    if (inner.len == 0) return null;
    return .{ .prefix = raw[0..at], .inner = inner, .suffix = raw[end + 1 ..] };
}

// ---------------------------------------------------------------------------
// Whole-word keyword search + construct parsing.
// ---------------------------------------------------------------------------

/// Find a whole-word keyword (boundaries are start/whitespace/`;`).
pub fn findKeyword(text: []const u8, kw: []const u8) ?usize {
    var i: usize = 0;
    while (i + kw.len <= text.len) : (i += 1) {
        if (!std.mem.eql(u8, text[i..][0..kw.len], kw)) continue;
        if (i > 0 and text[i - 1] != ' ' and text[i - 1] != '\t' and text[i - 1] != ';') continue;
        const after = i + kw.len;
        if (after < text.len and text[after] != ' ' and text[after] != '\t' and text[after] != ';') continue;
        return i;
    }
    return null;
}

/// Split a `;`-separated command body into trimmed commands. Returns count.
pub fn splitCommands(body: []const u8, out: [][]const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        if (i == body.len or body[i] == ';') {
            const cmd = trim(body[start..i]);
            if (cmd.len > 0 and count < out.len) {
                out[count] = cmd;
                count += 1;
            }
            start = i + 1;
        }
    }
    return count;
}

fn stripPrefix(line: []const u8, kw: []const u8) []const u8 {
    if (line.len <= kw.len) return line[line.len..];
    if (!std.mem.startsWith(u8, line, kw)) return line;
    if (line[kw.len] == ' ' or line[kw.len] == '\t') return line[kw.len + 1 ..];
    return line[kw.len..];
}

pub const If = struct {
    cond: []const u8,
    then_body: []const u8,
    else_body: []const u8 = "",
    has_else: bool = false,
};

/// Parse `if COND; then BODY; [else BODY;] fi`. Returns null on a missing
/// or malformed keyword.
pub fn parseIf(line: []const u8) ?If {
    if (!std.mem.startsWith(u8, line, "if")) return null;
    const rest = stripPrefix(line, "if");
    const then_pos = findKeyword(rest, "then") orelse return null;

    var cond_end = then_pos;
    while (cond_end > 0 and (isSpace(rest[cond_end - 1]) or rest[cond_end - 1] == ';')) cond_end -= 1;
    const cond = trimSemi(rest[0..cond_end]);
    if (cond.len == 0) return null;

    const after_then = rest[then_pos + 4 ..];
    var body_start: usize = 0;
    while (body_start < after_then.len and after_then[body_start] != ' ' and after_then[body_start] != ';') body_start += 1;
    while (body_start < after_then.len and (isSpace(after_then[body_start]) or after_then[body_start] == ';')) body_start += 1;
    const then_rest = after_then[body_start..];

    const else_pos = findKeyword(then_rest, "else");
    const fi_pos = findKeyword(then_rest, "fi") orelse return null;

    if (else_pos) |ep| {
        if (ep > fi_pos) return null; // malformed ordering
        const else_start = blk: {
            var es = ep + 4;
            while (es < then_rest.len and then_rest[es] != ' ' and then_rest[es] != ';') es += 1;
            while (es < then_rest.len and (isSpace(then_rest[es]) or then_rest[es] == ';')) es += 1;
            break :blk es;
        };
        return .{
            .cond = cond,
            .then_body = trimSemi(then_rest[0..ep]),
            .else_body = trimSemi(then_rest[else_start..fi_pos]),
            .has_else = true,
        };
    }
    return .{ .cond = cond, .then_body = trimSemi(then_rest[0..fi_pos]) };
}

pub const For = struct {
    var_name: []const u8,
    words: [16][]const u8 = undefined,
    word_count: usize = 0,
    body: []const u8,
};

/// Parse `for VAR in W1 W2 ...; do BODY; done`.
pub fn parseFor(line: []const u8, out: *For) bool {
    if (!std.mem.startsWith(u8, line, "for")) return false;
    const rest = stripPrefix(line, "for");
    const in_pos = findKeyword(rest, "in") orelse return false;
    const var_name = trim(rest[0..in_pos]);
    if (var_name.len == 0) return false;

    const after_in = rest[in_pos + 2 ..];
    const do_pos = findKeyword(after_in, "do") orelse return false;
    const words_str = after_in[0..do_pos];

    const after_do = after_in[do_pos + 2 ..];
    var bd: usize = 0;
    while (bd < after_do.len and after_do[bd] != ' ' and after_do[bd] != ';') bd += 1;
    while (bd < after_do.len and (isSpace(after_do[bd]) or after_do[bd] == ';')) bd += 1;
    const body_and_done = after_do[bd..];
    const done_pos = findKeyword(body_and_done, "done") orelse return false;

    out.var_name = var_name;
    out.body = trimSemi(body_and_done[0..done_pos]);
    out.word_count = 0;
    var ws: usize = 0;
    while (ws < words_str.len and out.word_count < out.words.len) : (ws += 1) {
        while (ws < words_str.len and (isSpace(words_str[ws]) or words_str[ws] == ';')) ws += 1;
        if (ws >= words_str.len) break;
        var we = ws;
        while (we < words_str.len and !isSpace(words_str[we]) and words_str[we] != ';') we += 1;
        out.words[out.word_count] = words_str[ws..we];
        out.word_count += 1;
        ws = we;
    }
    return true;
}

pub const While = struct {
    cond: []const u8,
    body: []const u8,
};

/// Parse `while COND; do BODY; done`.
pub fn parseWhile(line: []const u8) ?While {
    if (!std.mem.startsWith(u8, line, "while")) return null;
    const rest = stripPrefix(line, "while");
    const do_pos = findKeyword(rest, "do") orelse return null;
    const cond = trimSemi(rest[0..do_pos]);
    if (cond.len == 0) return null;
    const after_do = rest[do_pos + 2 ..];
    var bd: usize = 0;
    while (bd < after_do.len and after_do[bd] != ' ' and after_do[bd] != ';') bd += 1;
    while (bd < after_do.len and (isSpace(after_do[bd]) or after_do[bd] == ';')) bd += 1;
    const body_and_done = after_do[bd..];
    const done_pos = findKeyword(body_and_done, "done") orelse return null;
    return .{ .cond = cond, .body = trimSemi(body_and_done[0..done_pos]) };
}

// ---------------------------------------------------------------------------
// Functions: `fn NAME(a, b) { cmd1; cmd2 }`.
// ---------------------------------------------------------------------------

pub const func_max = 8;
pub const func_cmds_max = 8;
pub const func_cmd_max = 128;
pub const func_arg_max = 4;
pub const func_name_max = 32;
pub const func_arg_name_max = 16;

pub const FuncDef = struct {
    name: []const u8,
    arg_names: [func_arg_max][]const u8 = undefined,
    arg_count: usize = 0,
    body: []const u8,
};

pub fn parseFuncDef(text: []const u8) ?FuncDef {
    var i: usize = 0;
    while (i < text.len and text[i] != ' ' and text[i] != '(' and text[i] != '{') i += 1;
    const name = text[0..i];
    if (name.len == 0 or name.len > func_name_max) return null;

    var def = FuncDef{ .name = name, .body = "" };
    if (i < text.len and text[i] == '(') {
        i += 1;
        while (i < text.len and text[i] != ')' and def.arg_count < func_arg_max) {
            while (i < text.len and (text[i] == ' ' or text[i] == ',')) i += 1;
            const a_start = i;
            while (i < text.len and text[i] != ' ' and text[i] != ',' and text[i] != ')') i += 1;
            const aname = text[a_start..i];
            if (aname.len > 0) {
                def.arg_names[def.arg_count] = aname;
                def.arg_count += 1;
            }
        }
        if (i < text.len and text[i] == ')') i += 1;
    }
    while (i < text.len and text[i] != '{') i += 1;
    if (i >= text.len) return null;
    var start = i + 1;
    while (start < text.len and isSpace(text[start])) start += 1;
    var end: ?usize = null;
    i = text.len;
    while (i > start) {
        i -= 1;
        if (text[i] == '}') {
            end = i;
            break;
        }
    }
    def.body = trim(if (end) |e| text[start..e] else text[start..]);
    if (def.body.len == 0) return null;
    return def;
}

pub const Func = struct {
    name: [func_name_max]u8 = @as([func_name_max]u8, @splat(@as(u8, 0))),
    name_len: usize = 0,
    arg_names: [func_arg_max][func_arg_name_max]u8 = @as([func_arg_max][func_arg_name_max]u8, @splat(@as([func_arg_name_max]u8, @as([func_arg_name_max]u8, @splat(@as(u8, 0)))))),
    arg_name_lens: [func_arg_max]usize = @as([func_arg_max]usize, @splat(@as(usize, 0))),
    arg_count: usize = 0,
    body: [func_cmds_max][func_cmd_max]u8 = @as([func_cmds_max][func_cmd_max]u8, @splat(@as([func_cmd_max]u8, @as([func_cmd_max]u8, @splat(@as(u8, 0)))))),
    body_lens: [func_cmds_max]usize = @as([func_cmds_max]usize, @splat(@as(usize, 0))),
    body_count: usize = 0,

    pub fn argName(self: *const Func, i: usize) []const u8 {
        return self.arg_names[i][0..self.arg_name_lens[i]];
    }

    pub fn command(self: *const Func, i: usize) []const u8 {
        return self.body[i][0..self.body_lens[i]];
    }
};

pub const FuncTable = struct {
    funcs: [func_max]Func = @as([func_max]Func, @splat(@as(Func, .{}))),
    count: usize = 0,

    pub fn find(self: *const FuncTable, name: []const u8) ?usize {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (std.mem.eql(u8, self.funcs[i].name[0..self.funcs[i].name_len], name)) return i;
        }
        return null;
    }

    /// Define or redefine a function. Returns false on a bad definition or
    /// a full table (a redefinition always succeeds).
    pub fn define(self: *FuncTable, def: FuncDef) bool {
        var cmds: [func_cmds_max][]const u8 = undefined;
        const n = splitCommands(def.body, &cmds);
        if (n == 0) return false;

        const idx = self.find(def.name) orelse blk: {
            if (self.count >= func_max) return false;
            const fresh = self.count;
            self.count += 1;
            break :blk fresh;
        };
        const f = &self.funcs[idx];
        @memset(&f.name, 0);
        const nl = @min(def.name.len, func_name_max);
        @memcpy(f.name[0..nl], def.name[0..nl]);
        f.name_len = nl;
        f.arg_count = def.arg_count;
        var ai: usize = 0;
        while (ai < func_arg_max) : (ai += 1) {
            @memset(&f.arg_names[ai], 0);
            f.arg_name_lens[ai] = 0;
        }
        ai = 0;
        while (ai < def.arg_count) : (ai += 1) {
            const al = @min(def.arg_names[ai].len, func_arg_name_max);
            @memcpy(f.arg_names[ai][0..al], def.arg_names[ai][0..al]);
            f.arg_name_lens[ai] = al;
        }
        var ci: usize = 0;
        while (ci < func_cmds_max) : (ci += 1) {
            @memset(&f.body[ci], 0);
            f.body_lens[ci] = 0;
        }
        ci = 0;
        while (ci < n) : (ci += 1) {
            const cl = @min(cmds[ci].len, func_cmd_max);
            @memcpy(f.body[ci][0..cl], cmds[ci][0..cl]);
            f.body_lens[ci] = cl;
        }
        f.body_count = n;
        return true;
    }
};

// ---------------------------------------------------------------------------
// Tests (pure)
// ---------------------------------------------------------------------------

test "script: chainSplit handles ; && || and refuses too many" {
    const a = chainSplit("echo a && echo b");
    try std.testing.expectEqual(@as(usize, 2), a.chain.seg_count);
    try std.testing.expectEqual(ChainOp.run_and, a.chain.ops[0]);
    try std.testing.expectEqualStrings("echo a", a.chain.segs[0]);
    const b = chainSplit("false || echo ok; echo done");
    try std.testing.expectEqual(@as(usize, 3), b.chain.seg_count);
    try std.testing.expectEqual(ChainOp.run_or, b.chain.ops[0]);
    try std.testing.expectEqual(ChainOp.seq, b.chain.ops[1]);
    try std.testing.expectEqual(ChainSplit.none, chainSplit("echo plain"));
    // Quoted operators are literal.
    try std.testing.expectEqual(ChainSplit.none, chainSplit("echo 'a && b'"));
    try std.testing.expectEqual(ChainSplit.none, chainSplit("echo a \\; b"));
    try std.testing.expectEqual(ChainSplit.too_many, chainSplit("a;b;c;d;e"));
}

test "script: evalArith precedence and parentheses" {
    try std.testing.expectEqual(@as(i64, 7), evalArith("1+2*3"));
    try std.testing.expectEqual(@as(i64, 9), evalArith("(1+2)*3"));
    try std.testing.expectEqual(@as(i64, 20), evalArith("(2+3)*4"));
    try std.testing.expectEqual(@as(i64, 5), evalArith("10/2"));
    try std.testing.expectEqual(@as(i64, 1), evalArith("10%3"));
    try std.testing.expectEqual(@as(i64, -6), evalArith("-2*3"));
    try std.testing.expectEqual(@as(i64, 0), evalArith("5/0"));
}

test "script: arithExpand splices a computed result" {
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("X=20", arithExpand("X=$(( (2+3)*4 ))", &out));
    try std.testing.expectEqualStrings("a7b", arithExpand("a$((3+4))b", &out));
    try std.testing.expectEqualStrings("plain", arithExpand("plain", &out));
    try std.testing.expectEqualStrings("$((broken", arithExpand("$((broken", &out));
}

test "script: locateCommandSubst finds a simple substitution" {
    const c = locateCommandSubst("echo SUB=$(echo inner)").?;
    try std.testing.expectEqualStrings("echo SUB=", c.prefix);
    try std.testing.expectEqualStrings("echo inner", c.inner);
    try std.testing.expectEqualStrings("", c.suffix);
    try std.testing.expect(locateCommandSubst("no subst") == null);
    try std.testing.expect(locateCommandSubst("a$(b$(c))d") == null); // nested refused
    try std.testing.expect(locateCommandSubst("a$(unclosed") == null);
    // `$((...))` arithmetic is not command substitution.
    try std.testing.expect(locateCommandSubst("echo $((1+2))") == null);
    const mixed = locateCommandSubst("echo $((1)) $(pwd)").?;
    try std.testing.expectEqualStrings("echo $((1)) ", mixed.prefix);
    try std.testing.expectEqualStrings("pwd", mixed.inner);
}

test "script: parseIf reads then/else/fi" {
    const a = parseIf("if true; then echo yes; else echo no; fi").?;
    try std.testing.expectEqualStrings("true", a.cond);
    try std.testing.expectEqualStrings("echo yes", a.then_body);
    try std.testing.expect(a.has_else);
    try std.testing.expectEqualStrings("echo no", a.else_body);
    const b = parseIf("if false; then echo only; fi").?;
    try std.testing.expect(!b.has_else);
    try std.testing.expectEqualStrings("echo only", b.then_body);
    try std.testing.expect(parseIf("if true; echo missing fi") == null);
    try std.testing.expect(parseIf("if true; then x") == null); // missing fi
}

test "script: parseFor splits var, words and body" {
    var f: For = undefined;
    try std.testing.expect(parseFor("for n in a b c; do echo ITEM-$n; done", &f));
    try std.testing.expectEqualStrings("n", f.var_name);
    try std.testing.expectEqual(@as(usize, 3), f.word_count);
    try std.testing.expectEqualStrings("a", f.words[0]);
    try std.testing.expectEqualStrings("c", f.words[2]);
    try std.testing.expectEqualStrings("echo ITEM-$n", f.body);
    try std.testing.expect(!parseFor("for n in a b; echo bad; done", &f));
}

test "script: parseWhile reads cond and body" {
    const w = parseWhile("while true; do echo tick; done").?;
    try std.testing.expectEqualStrings("true", w.cond);
    try std.testing.expectEqualStrings("echo tick", w.body);
    try std.testing.expect(parseWhile("while true; echo bad; done") == null);
}

test "script: splitCommands trims and drops empties" {
    var out: [8][]const u8 = undefined;
    const n = splitCommands("  echo a ; echo b ;; echo c ", &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("echo a", out[0]);
    try std.testing.expectEqualStrings("echo c", out[2]);
}

test "script: FuncTable define/find/redefine and body split" {
    var table = FuncTable{};
    const def = parseFuncDef("greet(name) { echo HELLO-$name; echo BYE }").?;
    try std.testing.expectEqualStrings("greet", def.name);
    try std.testing.expectEqual(@as(usize, 1), def.arg_count);
    try std.testing.expectEqualStrings("name", def.arg_names[0]);
    try std.testing.expect(table.define(def));
    const idx = table.find("greet").?;
    try std.testing.expectEqualStrings("greet", table.funcs[idx].name[0..table.funcs[idx].name_len]);
    try std.testing.expectEqual(@as(usize, 2), table.funcs[idx].body_count);
    try std.testing.expectEqualStrings("echo BYE", table.funcs[idx].command(1));
    try std.testing.expectEqualStrings("name", table.funcs[idx].argName(0));
    // Redefinition replaces.
    const def2 = parseFuncDef("greet() { echo HI }").?;
    try std.testing.expect(table.define(def2));
    try std.testing.expectEqual(@as(usize, 1), table.count);
    try std.testing.expectEqual(@as(usize, 0), table.funcs[table.find("greet").?].arg_count);
    try std.testing.expect(parseFuncDef("bad") == null);
}

// ---------------------------------------------------------------------------
// M49 SD3 (#1130): a bounded single-line `case ... in ... esac`.
// ---------------------------------------------------------------------------

pub const case_arm_max: usize = 8;

pub const CaseArm = struct {
    pattern: []const u8,
    body: []const u8,
};

pub const Case = struct {
    subject: []const u8,
    arms: [case_arm_max]CaseArm = undefined,
    count: usize = 0,
};

/// Parse `case SUBJECT in PAT) BODY;; PAT2) BODY2;; esac`. Arms are split on
/// `;;`; the pattern may hold `|` alternatives. Bounded to `case_arm_max`
/// arms; a malformed line returns null (the caller reports it).
pub fn parseCase(line: []const u8) ?Case {
    if (!std.mem.startsWith(u8, line, "case")) return null;
    const rest = stripPrefix(line, "case");
    const in_pos = findKeyword(rest, "in") orelse return null;
    const subject = trim(rest[0..in_pos]);
    if (subject.len == 0) return null;
    const after_in = rest[in_pos + 2 ..];
    const esac_pos = findKeyword(after_in, "esac") orelse return null;
    const arms_text = trimSemi(after_in[0..esac_pos]);

    var c = Case{ .subject = subject };
    var i: usize = 0;
    while (i < arms_text.len and c.count < case_arm_max) {
        while (i < arms_text.len and (arms_text[i] == ';' or isSpace(arms_text[i]))) i += 1;
        if (i >= arms_text.len) break;
        const pat_end = std.mem.indexOfScalar(u8, arms_text[i..], ')') orelse break;
        const pattern = trim(arms_text[i .. i + pat_end]);
        const body_start = i + pat_end + 1;
        const sep = std.mem.indexOfPos(u8, arms_text, body_start, ";;");
        const body_end = sep orelse arms_text.len;
        c.arms[c.count] = .{
            .pattern = pattern,
            .body = trimSemi(arms_text[body_start..body_end]),
        };
        c.count += 1;
        i = if (sep) |s| s + 2 else arms_text.len;
    }
    if (c.count == 0) return null;
    return c;
}

/// True when `pattern` matches `subject`: `|` separates alternatives, and
/// each alternative is fnmatch-style (via `pipe.globMatch`). The single
/// pattern `*` matches everything.
pub fn caseMatch(pattern: []const u8, subject: []const u8) bool {
    var i: usize = 0;
    while (i <= pattern.len) {
        var j = i;
        while (j < pattern.len and pattern[j] != '|') j += 1;
        const alt = trim(pattern[i..j]);
        if (alt.len > 0 and pipe.globMatch(alt, subject)) return true;
        if (j >= pattern.len) break;
        i = j + 1;
    }
    return false;
}

test "script: parseCase splits subject and arms" {
    const c = parseCase("case $X in a) echo A;; b|c) echo BC;; *) echo OTHER;; esac").?;
    try std.testing.expectEqualStrings("$X", c.subject);
    try std.testing.expectEqual(@as(usize, 3), c.count);
    try std.testing.expectEqualStrings("a", c.arms[0].pattern);
    try std.testing.expectEqualStrings("echo A", c.arms[0].body);
    try std.testing.expectEqualStrings("b|c", c.arms[1].pattern);
    try std.testing.expectEqualStrings("echo BC", c.arms[1].body);
    try std.testing.expectEqualStrings("*", c.arms[2].pattern);
    try std.testing.expectEqualStrings("echo OTHER", c.arms[2].body);
}

test "script: parseCase rejects malformed lines" {
    try std.testing.expect(parseCase("case x") == null);
    try std.testing.expect(parseCase("case in esac") == null);
    try std.testing.expect(parseCase("if x; then y; fi") == null);
    try std.testing.expect(parseCase("case x in esac") == null);
}

test "script: caseMatch handles alternatives and globs" {
    try std.testing.expect(caseMatch("a", "a"));
    try std.testing.expect(!caseMatch("a", "b"));
    try std.testing.expect(caseMatch("b|c", "c"));
    try std.testing.expect(caseMatch("*", "anything"));
    try std.testing.expect(caseMatch("*.TXT", "NOTES.TXT"));
    try std.testing.expect(!caseMatch("*.TXT", "NOTES.BIN"));
}
