//! Fixed-arity tokenizer (Milestone 1.5, console & shell core; reworked by
//! M19 P5, issue #294, into a full quote/escape state machine).
//!
//! Splits one shell line into at most `max_tokens` argument slices. Tokens
//! are slices into the CALLER'S line when they are contiguous runs, or
//! into the caller-provided `scratch` buffer when quoting joined fragments
//! or escapes had to be materialized (`ab"c d"e` → one argument, `\x` →
//! `x`). The scratch must outlive every use of the returned argv; it never
//! needs to be larger than the line itself (escapes only ever shrink).
//! No allocation, no libc.
//!
//! Explicit rules (documented behavior, host-tested):
//!   * Whitespace is space or tab; leading/trailing runs and repeated
//!     separators collapse.
//!   * Single quotes: `'...'` is fully literal to the closing `'` — no
//!     escapes, no operator meaning, nothing. `'\''` embeds a quote via
//!     outside-quote escaping. Quotes may appear mid-token and JOIN:
//!     `ab"c d"e` is the single argument `abc de`.
//!   * Double quotes: `"..."` protects spaces; `$VAR` still expands later
//!     (expansion runs before tokenization). Backslash escapes inside
//!     double quotes: `\"`, `\\`, `\$` yield that byte; `\n`/`\t` yield
//!     newline/tab (issue #294 spec); any other `\c` keeps both bytes.
//!   * Outside quotes a backslash escapes the next byte: `\x` → `x`
//!     (defusing operators and expansions upstream of the tokenizer).
//!   * `''` / `""` yield an empty argument.
//!   * An unclosed quote makes the rest of the line part of the literal
//!     argument and sets `unbalanced_quote` — the shell prints a warning
//!     and still executes ("unclosed literal" choice).
//!   * More than `max_tokens` tokens sets `too_many` and the excess is
//!     dropped — the shell refuses to execute.
//!   * `arg_glob[i]` reports whether argument i contains an UNQUOTED,
//!     UNESCAPED `*`, `?`, or `[` — the M19 P6 glob hook expands exactly
//!     those arguments.

const std = @import("std");
const monitor = @import("monitor.zig");

/// Total token slots: the command name plus up to `monitor.max_args_limit`
/// arguments (16), mirroring the registry's argument bound.
pub const max_tokens: usize = monitor.max_args_limit + 1;

pub const TokenizeResult = struct {
    argv: [max_tokens][]const u8 = undefined,
    /// Per-argument wildcard marker for the P6 glob expansion stage.
    arg_glob: [max_tokens]bool = @as([max_tokens]bool, @splat(@as(bool, false))),
    count: usize = 0,
    /// More tokens than fit: the caller must refuse to execute.
    too_many: bool = false,
    /// A quote was left open; the rest of the line is part of the literal
    /// argument. The caller may warn and proceed.
    unbalanced_quote: bool = false,
};

pub fn tokenize(line: []const u8, scratch: []u8) TokenizeResult {
    var result: TokenizeResult = .{};
    var index: usize = 0;
    var spos: usize = 0;
    while (index < line.len) {
        if (is_space(line[index])) {
            index += 1;
            continue;
        }
        if (result.count >= max_tokens) {
            result.too_many = true;
            break;
        }
        const arg_i = result.count;
        const buf_start = spos;
        var in_single = false;
        var in_double = false;
        while (index < line.len) {
            const c = line[index];
            if (in_single) {
                if (c == '\'') {
                    in_single = false;
                } else {
                    if (spos < scratch.len) scratch[spos] = c;
                    spos += 1;
                }
                index += 1;
                continue;
            }
            if (in_double) {
                if (c == '"') {
                    in_double = false;
                    index += 1;
                    continue;
                }
                if (c == '\\' and index + 1 < line.len) {
                    const n = line[index + 1];
                    switch (n) {
                        '"', '\\', '$' => {
                            if (spos < scratch.len) scratch[spos] = n;
                            spos += 1;
                        },
                        'n' => {
                            if (spos < scratch.len) scratch[spos] = '\n';
                            spos += 1;
                        },
                        't' => {
                            if (spos < scratch.len) scratch[spos] = '\t';
                            spos += 1;
                        },
                        else => {
                            if (spos + 1 < scratch.len) {
                                scratch[spos] = '\\';
                                scratch[spos + 1] = n;
                            }
                            spos += 2;
                        },
                    }
                    index += 2;
                    continue;
                }
                if (spos < scratch.len) scratch[spos] = c;
                spos += 1;
                index += 1;
                continue;
            }
            // Unquoted region.
            if (is_space(c)) break;
            if (c == '\'') {
                in_single = true;
                index += 1;
                continue;
            }
            if (c == '"') {
                in_double = true;
                index += 1;
                continue;
            }
            if (c == '\\') {
                if (index + 1 < line.len) {
                    if (spos < scratch.len) scratch[spos] = line[index + 1];
                    spos += 1;
                    index += 2;
                } else {
                    if (spos < scratch.len) scratch[spos] = '\\';
                    spos += 1;
                    index += 1;
                }
                continue;
            }
            if (c == '*' or c == '?' or c == '[') {
                result.arg_glob[arg_i] = true;
            }
            if (spos < scratch.len) scratch[spos] = c;
            spos += 1;
            index += 1;
        }
        if (in_single or in_double) result.unbalanced_quote = true;
        // Clamp: a caller-provided scratch smaller than needed truncates
        // honestly instead of panicking (the shell always passes a
        // max_line-sized scratch; the fuzzer does not).
        result.argv[arg_i] = scratch[buf_start..@min(spos, scratch.len)];
        result.count += 1;
    }
    return result;
}

fn is_space(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

// ---------------------------------------------------------------------------
// Tests (host-side; no hardware)
// ---------------------------------------------------------------------------

test "tokenizer: quoted and unquoted arguments" {
    const line = "echo \"elephant business\"";
    var scratch: [256]u8 = undefined;
    const result = tokenize(line, &scratch);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("echo", result.argv[0]);
    try std.testing.expectEqualStrings("elephant business", result.argv[1]);
    try std.testing.expect(!result.too_many);
    try std.testing.expect(!result.unbalanced_quote);
}

test "tokenizer: leading, trailing and repeated spaces collapse" {
    var scratch: [256]u8 = undefined;
    const result = tokenize("  echo   a    b  ", &scratch);
    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqualStrings("echo", result.argv[0]);
    try std.testing.expectEqualStrings("a", result.argv[1]);
    try std.testing.expectEqualStrings("b", result.argv[2]);
}

test "tokenizer: tabs separate tokens" {
    var scratch: [256]u8 = undefined;
    const result = tokenize("echo\ta\tb", &scratch);
    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqualStrings("b", result.argv[2]);
}

test "tokenizer: empty quotes yield an empty argument" {
    var scratch: [256]u8 = undefined;
    const result = tokenize("echo \"\"", &scratch);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual(@as(usize, 0), result.argv[1].len);
}

test "tokenizer: empty single quotes yield an empty argument" {
    var scratch: [256]u8 = undefined;
    const result = tokenize("echo ''", &scratch);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual(@as(usize, 0), result.argv[1].len);
}

// M19 P5 (issue #294): mid-token quotes now JOIN — superseding the M1.5
// "quote inside an unquoted token is literal" rule.
test "tokenizer: mid-token double quotes join fragments" {
    var scratch: [256]u8 = undefined;
    const result = tokenize("echo ab\"cd ef\"gh", &scratch);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    // One argument: the quoted space belongs to it, the outer fragments join.
    try std.testing.expectEqualStrings("abcd efgh", result.argv[1]);
    try std.testing.expect(!result.unbalanced_quote);
}

test "tokenizer: single quotes are fully literal" {
    var scratch: [256]u8 = undefined;
    const result = tokenize("echo 'hello world'", &scratch);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("hello world", result.argv[1]);

    const r2 = tokenize("echo 'a;b|c&&d'", &scratch);
    try std.testing.expectEqual(@as(usize, 2), r2.count);
    try std.testing.expectEqualStrings("a;b|c&&d", r2.argv[1]);
}

test "tokenizer: embedded single quote via outside-quote escape" {
    var scratch: [256]u8 = undefined;
    const result = tokenize("echo 'it'\\''s'", &scratch);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("it's", result.argv[1]);
}

test "tokenizer: quotes of the other kind are literal inside single/double" {
    var scratch: [256]u8 = undefined;
    const r1 = tokenize("echo 'say \"hi\"'", &scratch);
    try std.testing.expectEqualStrings("say \"hi\"", r1.argv[1]);
    const r2 = tokenize("echo \"it's\"", &scratch);
    try std.testing.expectEqualStrings("it's", r2.argv[1]);
}

test "tokenizer: outside-quote backslash escapes the next byte" {
    var scratch: [256]u8 = undefined;
    const r1 = tokenize("echo a\\ b", &scratch);
    try std.testing.expectEqual(@as(usize, 2), r1.count);
    try std.testing.expectEqualStrings("a b", r1.argv[1]);
    const r2 = tokenize("echo \\$HOME", &scratch);
    try std.testing.expectEqualStrings("$HOME", r2.argv[1]);
    const r3 = tokenize("echo x\\*y", &scratch);
    try std.testing.expectEqualStrings("x*y", r3.argv[1]);
    try std.testing.expect(!r3.arg_glob[1]); // escaped glob char is not wild
}

test "tokenizer: double-quote backslash escapes per the issue spec" {
    var scratch: [256]u8 = undefined;
    const r1 = tokenize("echo \"he said \\\"hi\\\"\"", &scratch);
    try std.testing.expectEqualStrings("he said \"hi\"", r1.argv[1]);
    const r2 = tokenize("echo \"back\\\\slash\"", &scratch);
    try std.testing.expectEqualStrings("back\\slash", r2.argv[1]);
    const r3 = tokenize("echo \"a\\$b\"", &scratch);
    try std.testing.expectEqualStrings("a$b", r3.argv[1]);
}

test "tokenizer: unbalanced single quote takes the rest as literal" {
    var scratch: [256]u8 = undefined;
    const result = tokenize("echo 'elephant business", &scratch);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("elephant business", result.argv[1]);
    try std.testing.expect(result.unbalanced_quote);
}

test "tokenizer: unbalanced quote takes the rest of the line as literal" {
    var scratch: [256]u8 = undefined;
    const result = tokenize("echo \"elephant business", &scratch);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("elephant business", result.argv[1]);
    try std.testing.expect(result.unbalanced_quote);
}

test "tokenizer: empty line yields no tokens" {
    var scratch: [256]u8 = undefined;
    const result = tokenize("", &scratch);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expect(!result.too_many);
}

test "tokenizer: exactly max_tokens tokens fit" {
    var line_buffer: [256]u8 = undefined;
    var n: usize = 0;
    var t: usize = 0;
    while (t < max_tokens) : (t += 1) {
        if (t > 0) {
            line_buffer[n] = ' ';
            n += 1;
        }
        line_buffer[n] = 'a';
        n += 1;
    }
    var scratch: [256]u8 = undefined;
    const result = tokenize(line_buffer[0..n], &scratch);
    try std.testing.expectEqual(max_tokens, result.count);
    try std.testing.expect(!result.too_many);
}

test "tokenizer: the max_tokens+1th token sets too_many" {
    var line_buffer: [256]u8 = undefined;
    var n: usize = 0;
    var t: usize = 0;
    while (t < max_tokens + 1) : (t += 1) {
        if (t > 0) {
            line_buffer[n] = ' ';
            n += 1;
        }
        line_buffer[n] = 'a';
        n += 1;
    }
    var scratch: [256]u8 = undefined;
    const result = tokenize(line_buffer[0..n], &scratch);
    try std.testing.expectEqual(max_tokens, result.count);
    try std.testing.expect(result.too_many);
}

test "tokenizer: arg_glob marks unquoted wildcards only" {
    var scratch: [256]u8 = undefined;
    const r1 = tokenize("ls *.BIN", &scratch);
    try std.testing.expect(r1.arg_glob[1]);
    const r2 = tokenize("ls '*.BIN'", &scratch);
    try std.testing.expect(!r2.arg_glob[1]); // quoted glob stays literal
    const r3 = tokenize("ls *.B?N", &scratch);
    try std.testing.expect(r3.arg_glob[1]);
    const r4 = tokenize("ls plain.txt", &scratch);
    try std.testing.expect(!r4.arg_glob[1]);
}
