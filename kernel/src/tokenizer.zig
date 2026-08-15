//! Fixed-arity tokenizer (Milestone 1.5, console & shell core).
//!
//! Splits one shell line into at most `max_tokens` argument slices, with
//! optional double-quoted strings. No allocation, no libc: every token is
//! a slice into the caller's line buffer.
//!
//! Explicit rules (documented behavior, host-tested):
//!   * Whitespace is space or tab; leading/trailing runs and repeated
//!     separators collapse.
//!   * A `"` at the start of an argument opens a quoted region; the next
//!     `"` closes it and everything between (including spaces) is one
//!     argument. A `"` inside an unquoted token is a literal byte.
//!   * `""` yields an empty argument.
//!   * An unclosed `"` (open to end of line) makes the rest of the line a
//!     literal argument and sets `unbalanced_quote` — the shell prints a
//!     warning and still executes ("unclosed literal" choice).
//!   * More than `max_tokens` tokens sets `too_many` and the excess is
//!     dropped — the shell refuses to execute.

const std = @import("std");
const monitor = @import("monitor.zig");

/// Total token slots: the command name plus up to `monitor.max_args_limit`
/// arguments (16), mirroring the registry's argument bound.
pub const max_tokens: usize = monitor.max_args_limit + 1;

pub const TokenizeResult = struct {
    argv: [max_tokens][]const u8 = undefined,
    count: usize = 0,
    /// More tokens than fit: the caller must refuse to execute.
    too_many: bool = false,
    /// A double quote was left open; the rest of the line is the literal
    /// argument. The caller may warn and proceed.
    unbalanced_quote: bool = false,
};

pub fn tokenize(line: []const u8) TokenizeResult {
    var result: TokenizeResult = .{};
    var index: usize = 0;
    while (index < line.len) {
        if (is_space(line[index])) {
            index += 1;
            continue;
        }
        if (result.count >= max_tokens) {
            result.too_many = true;
            break;
        }
        if (line[index] == '"') {
            index += 1;
            const start = index;
            while (index < line.len and line[index] != '"') index += 1;
            if (index < line.len) {
                result.argv[result.count] = line[start..index];
                index += 1; // skip the closing quote
            } else {
                // Unclosed: the remainder of the line is the literal.
                result.argv[result.count] = line[start..];
                result.unbalanced_quote = true;
            }
            result.count += 1;
        } else {
            const start = index;
            while (index < line.len and !is_space(line[index])) index += 1;
            result.argv[result.count] = line[start..index];
            result.count += 1;
        }
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
    const result = tokenize(line);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("echo", result.argv[0]);
    try std.testing.expectEqualStrings("elephant business", result.argv[1]);
    try std.testing.expect(!result.too_many);
    try std.testing.expect(!result.unbalanced_quote);
}

test "tokenizer: leading, trailing and repeated spaces collapse" {
    const result = tokenize("  echo   a    b  ");
    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqualStrings("echo", result.argv[0]);
    try std.testing.expectEqualStrings("a", result.argv[1]);
    try std.testing.expectEqualStrings("b", result.argv[2]);
}

test "tokenizer: tabs separate tokens" {
    const result = tokenize("echo\ta\tb");
    try std.testing.expectEqual(@as(usize, 3), result.count);
    try std.testing.expectEqualStrings("b", result.argv[2]);
}

test "tokenizer: empty quotes yield an empty argument" {
    const result = tokenize("echo \"\"");
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqual(@as(usize, 0), result.argv[1].len);
}

test "tokenizer: quote inside an unquoted token is literal" {
    const result = tokenize("echo ab\"cd");
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("ab\"cd", result.argv[1]);
    try std.testing.expect(!result.unbalanced_quote);
}

test "tokenizer: unbalanced quote takes the rest of the line as literal" {
    const result = tokenize("echo \"elephant business");
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("elephant business", result.argv[1]);
    try std.testing.expect(result.unbalanced_quote);
}

test "tokenizer: empty line yields no tokens" {
    const result = tokenize("");
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
    const result = tokenize(line_buffer[0..n]);
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
    const result = tokenize(line_buffer[0..n]);
    try std.testing.expectEqual(max_tokens, result.count);
    try std.testing.expect(result.too_many);
}

test "tokenizer: card U3 — the garbage fuzz never panics and stays bounded" {
    // ADR 0008 D3 (card U3): no input may crash the shell. Deterministic
    // LCG — a seed change is a new fuzz, never a flaky one.
    var seed: u32 = 0xC0FFEE;
    var buf: [128]u8 = undefined;
    var iter: usize = 0;
    while (iter < 512) : (iter += 1) {
        const len = seed % buf.len;
        seed = seed *% 1664525 +% 1013904223;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            seed = seed *% 1664525 +% 1013904223;
            // Printable ASCII plus the interesting controls: quote,
            // backslash, space, tab.
            buf[i] = @intCast(0x20 + (seed % 0x5f));
            if (buf[i] == 0x7f) buf[i] = '"';
        }
        const r = tokenize(buf[0..len]);
        try std.testing.expect(r.count <= max_tokens);
        try std.testing.expect(r.argv.len == max_tokens);
    }
}
