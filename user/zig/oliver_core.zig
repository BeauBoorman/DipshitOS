//! C1's bounded, filesystem-free adapter. Engines and CLI option semantics
//! remain pinned upstream; only the native I/O and resource policy live here.
const std = @import("std");
const oliver = @import("oliver");
const cli = @import("oliver_cli");
const meta = cli.meta;
const rewrite = cli.rewrite;

pub const input_limit = 128 * 1024;
pub const output_limit = 512 * 1024;
pub const arena_limit = 8 * 1024 * 1024;
pub const diagnostic_limit = 16 * 1024;
pub const depth_limit = 32;

pub fn config(args: []const []const u8) !cli.RunConfig {
    // Refuse excluded commands even if their hosted options are incomplete.
    for (args) |arg| {
        for ([_][]const u8{ "wrap", "plan", "manifest", "serialize", "scale", "menu" }) |excluded| {
            if (std.mem.eql(u8, arg, excluded)) return error.UnsupportedCommand;
        }
    }
    const cfg = try cli.parseArgs(args);
    if (cfg.command != .render and cfg.command != .meta) return error.UnsupportedCommand;
    return cfg;
}

pub const Output = struct { normal: []const u8, diagnostics: []const u8 = "" };

/// TOML's public-model conversion is recursive. Conservatively bound its
/// structural tokens before parsing, including dotted-table nesting. This
/// may refuse flat metadata with many fields; it never rewrites that input.
pub fn preflight(input: []const u8, cfg: cli.RunConfig) !void {
    if (input.len > input_limit) return error.InputLimit;
    // matchInlines recursively analyzes nested link/image children. Counting
    // every '[' is conservative (including literal/code brackets), but bounds
    // that recursion before the parser, not after it has consumed the stack.
    if (cfg.dialect == .markdown) {
        if (std.mem.count(u8, input, "[") > depth_limit) return error.DepthLimit;
    }
    if (cfg.frontmatter == .yaml) {
        var lines = std.mem.splitScalar(u8, input, '\n');
        while (lines.next()) |line| {
            var indentation: usize = 0;
            for (line) |byte| {
                if (byte != ' ' and byte != '\t') break;
                indentation += 1;
            }
            if (indentation > depth_limit) return error.DepthLimit;
        }
    }
    if (cfg.frontmatter == .toml) {
        var tokens: usize = 0;
        for (input) |byte| {
            if (byte == '[' or byte == '{' or byte == '.') tokens += 1;
            if (tokens > depth_limit) return error.DepthLimit;
        }
    }
}

/// Iterative check before heading-text recursion in the upstream renderer.
pub fn checkTree(a: std.mem.Allocator, root: *const oliver.document.Node) !void {
    const Visit = struct { node: *const oliver.document.Node, depth: usize };
    var pending = std.ArrayList(Visit).empty;
    defer pending.deinit(a);
    try pending.append(a, .{ .node = root, .depth = 0 });
    while (pending.pop()) |visit| {
        if (visit.depth > depth_limit) return error.DepthLimit;
        for (visit.node.children.items) |child|
            try pending.append(a, .{ .node = child, .depth = visit.depth + 1 });
    }
}

fn checkRecipe(a: std.mem.Allocator, blocks: []const oliver.cooklang.Block) !void {
    const Visit = struct { blocks: []const oliver.cooklang.Block, depth: usize };
    var pending = std.ArrayList(Visit).empty;
    defer pending.deinit(a);
    try pending.append(a, .{ .blocks = blocks, .depth = 0 });
    while (pending.pop()) |visit| {
        if (visit.depth > depth_limit) return error.DepthLimit;
        for (visit.blocks) |block| switch (block) {
            .section => |section| try pending.append(a, .{ .blocks = section.blocks, .depth = visit.depth + 1 }),
            else => {},
        };
    }
}

pub fn limits(normal: []const u8, diagnostics: []const u8) !Output {
    if (normal.len > output_limit) return error.OutputLimit;
    // Leave space for the allocation-free refusal diagnostic.
    if (diagnostics.len > diagnostic_limit - 256) return error.DiagnosticLimit;
    return .{ .normal = normal, .diagnostics = diagnostics };
}

/// Caller owns a per-invocation arena, so all intermediate allocations are
/// charged and released together. Nothing is published on a render failure.
pub fn run(a: std.mem.Allocator, cfg: cli.RunConfig, input: []const u8, buffer: []u8) !Output {
    try preflight(input, cfg);
    if (cfg.command == .meta) return limits(try meta.extractJson(a, input), "");
    var writer = std.Io.Writer.fixed(buffer);
    var diagnostics: []const u8 = "";
    if (cfg.cooklang) {
        var result = try oliver.cooklang.parse(a, input, cli.cooklangParseOptions(cfg));
        defer result.deinit();
        try checkRecipe(a, result.recipe.blocks);
        if (cfg.diagnostics) diagnostics = try cli.diagnosticsJson(a, result.diagnostics);
        oliver.cooklang_html.render(a, &writer, &result.recipe, .{ .profile = cfg.profile }) catch |err|
            return if (err == error.WriteFailed) error.OutputLimit else err;
    } else {
        var result = try oliver.parse(a, input, cfg.dialect.?, cli.markdownParseOptions(cfg));
        defer result.deinit();
        try checkTree(a, result.document.root);
        try rewrite.rewriteDocument(&result.document);
        if (cfg.diagnostics) diagnostics = try cli.diagnosticsJson(a, result.diagnostics);
        oliver.html.render(a, &writer, &result.document, cli.renderOptionsFor(cfg)) catch |err|
            return if (err == error.WriteFailed) error.OutputLimit else err;
    }
    return limits(writer.buffered(), diagnostics);
}

test "C1 config uses upstream semantics and refuses deferred commands" {
    try std.testing.expectEqual(.render, (try config(&.{ "render", "--from", "markdown" })).command);
    try std.testing.expectEqual(.meta, (try config(&.{ "meta", "--from", "cooklang", "--format", "json" })).command);
    for ([_][]const u8{ "wrap", "plan", "manifest", "serialize", "scale", "menu" }) |cmd|
        try std.testing.expectError(error.UnsupportedCommand, config(&.{cmd}));
    try std.testing.expectError(error.Usage, config(&.{ "meta", "--from", "markdown" }));
    try std.testing.expectError(error.Usage, config(&.{ "render", "--from", "textile", "--footnotes" }));
}

test "C1 exact input, output and diagnostic boundaries" {
    const cfg = try config(&.{ "render", "--from", "markdown" });
    const input = try std.testing.allocator.alloc(u8, input_limit + 1);
    defer std.testing.allocator.free(input);
    @memset(input, 'a');
    try preflight(input[0..input_limit], cfg);
    try std.testing.expectError(error.InputLimit, preflight(input, cfg));
    const output = try std.testing.allocator.alloc(u8, output_limit + 1);
    defer std.testing.allocator.free(output);
    _ = try limits(output[0..output_limit], "");
    try std.testing.expectError(error.OutputLimit, limits(output, ""));
    const diagnostic = try std.testing.allocator.alloc(u8, diagnostic_limit);
    defer std.testing.allocator.free(diagnostic);
    _ = try limits("", diagnostic[0 .. diagnostic_limit - 256]);
    try std.testing.expectError(error.DiagnosticLimit, limits("", diagnostic[0 .. diagnostic_limit - 255]));
}

test "C1 depth is refused before recursive rendering or TOML conversion" {
    var doc = try oliver.document.Document.init(std.testing.allocator, .{ .bytes = "" });
    defer doc.deinit();
    var node = doc.root;
    for (0..depth_limit) |_| {
        const child = try doc.createNode(.emphasis, .{ .start = 0, .end = 0 }, .none);
        try doc.appendChild(node, child);
        node = child;
    }
    try checkTree(std.testing.allocator, doc.root);
    const child = try doc.createNode(.emphasis, .{ .start = 0, .end = 0 }, .none);
    try doc.appendChild(node, child);
    try std.testing.expectError(error.DepthLimit, checkTree(std.testing.allocator, doc.root));
    const cfg = try config(&.{ "render", "--from", "markdown", "--frontmatter", "toml" });
    try preflight(&@as([depth_limit:0]u8, @splat("."[0])), cfg);
    try std.testing.expectError(error.DepthLimit, preflight(&@as([(depth_limit + 1):0]u8, @splat("."[0])), cfg));
}
