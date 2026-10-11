fn repeat_lit(comptime lit: []const u8, comptime n: usize) *const [n * lit.len:0]u8 {
    if (n == 0) return "";
    return lit ++ repeat_lit(lit, n - 1);
}
const std = @import("std");
const cli = @import("cli.zig");
const kt = @import("k4o");
const t = std.testing;

test "CLI defaults, formats, equals and short options, all seven argument slots" {
    const options = (try cli.parse(&.{ "render", "t", "--data", "d", "--format", "gfm", "-m=1M" })).render;
    try t.expectEqualStrings("t", options.template);
    try t.expectEqualStrings("d", options.data.?);
    try t.expectEqual(kt.Format.gfm, options.format);
    try t.expectEqual(cli.output_limit, options.max_output);
    for ([_][]const u8{ "--data=d", "-d=d" }) |arg| {
        const eq = (try cli.parse(&.{ "render", "t", arg, "--format=markdown", "--max-output=2k" })).render;
        try t.expectEqualStrings("d", eq.data.?);
        try t.expectEqual(kt.Format.markdown, eq.format);
        try t.expectEqual(@as(usize, 2048), eq.max_output);
    }
    const defaults = (try cli.parse(&.{ "render", "t" })).render;
    try t.expectEqual(cli.output_limit, defaults.max_output);
    try t.expectEqual(kt.Format.textile, defaults.format);
    try t.expect(defaults.data == null);
    try t.expectEqualStrings("t", (try cli.parse(&.{ "render", "t", "-m", "1" })).render.template);
    for ([_][]const u8{ "-h", "--help" }) |arg| {
        try t.expect((try cli.parse(&.{arg})) == .help);
        try t.expect((try cli.parse(&.{ "render", arg })) == .help);
    }
    for ([_][]const u8{ "-v", "--version" }) |arg| try t.expect((try cli.parse(&.{arg})) == .version);
}

test "CLI capacity and named usage refusals" {
    _ = try cli.parse(&.{ "render", &@as([255:0]u8, @splat("x"[0])) });
    try t.expectError(error.ArgumentLimit, cli.parse(&.{ "render", &@as([256:0]u8, @splat("x"[0])) }));
    try t.expectError(error.ArgumentLimit, cli.parse(&.{ "render", "a\x00b" }));
    try t.expectError(error.ArgumentLimit, cli.parse(&(@as([8][]const u8, @splat(@as([]const u8, "-h"))))));
    try t.expectError(error.MissingCommand, cli.parse(&.{}));
    try t.expectError(error.UnknownCommand, cli.parse(&.{"walk"}));
    try t.expectError(error.MissingTemplate, cli.parse(&.{"render"}));
    try t.expectError(error.MultipleTemplates, cli.parse(&.{ "render", "t", "u" }));
    try t.expectError(error.UnknownOption, cli.parse(&.{ "render", "t", "--network" }));
    try t.expectError(error.MissingDataValue, cli.parse(&.{ "render", "t", "-d" }));
    try t.expectError(error.MissingDataValue, cli.parse(&.{ "render", "t", "--data=" }));
    try t.expectError(error.DuplicateData, cli.parse(&.{ "render", "t", "-d=d", "--data=d" }));
    try t.expectError(error.MissingFormatValue, cli.parse(&.{ "render", "t", "--format" }));
    try t.expectError(error.InvalidFormat, cli.parse(&.{ "render", "t", "--format=html" }));
    try t.expectError(error.DuplicateFormat, cli.parse(&.{ "render", "t", "--format=gfm", "--format=gfm" }));
}

test "output limit exact and over, unlimited refusal, suffixes and numeric errors" {
    for ([_][]const u8{ "0", "1048577", "256m", "1g" }) |n| {
        var buffer: [64]u8 = undefined;
        const option = try std.fmt.bufPrint(&buffer, "--max-output={s}", .{n});
        try t.expectError(error.OutputLimit, cli.parse(&.{ "render", "t", option }));
    }
    try t.expectError(error.MissingOutputValue, cli.parse(&.{ "render", "t", "-m=" }));
    try t.expectError(error.MissingOutputValue, cli.parse(&.{ "render", "t", "-m" }));
    try t.expectError(error.NegativeOutputLimit, cli.parse(&.{ "render", "t", "-m=-1" }));
    for ([_][]const u8{ "-m=oops", "-m=18446744073709551616", "-m=18446744073709551615g" }) |arg|
        try t.expectError(error.InvalidOutputLimit, cli.parse(&.{ "render", "t", arg }));
}

test "input byte boundaries and quote-aware JSON depth" {
    const input = try t.allocator.alloc(u8, cli.input_limit + 1);
    defer t.allocator.free(input);
    @memset(input, ' ');
    try cli.templatePreflight(input[0..cli.input_limit]);
    try cli.jsonPreflight(input[0..cli.input_limit]);
    try t.expectError(error.InputLimit, cli.templatePreflight(input));
    try t.expectError(error.InputLimit, cli.jsonPreflight(input));
    try cli.jsonPreflight(&@as([8:0]u8, @splat("["[0])) ++ "0" ++ &@as([8:0]u8, @splat("]"[0])));
    try t.expectError(error.JsonDepthLimit, cli.jsonPreflight(&@as([9:0]u8, @splat("["[0])) ++ "0" ++ &@as([9:0]u8, @splat("]"[0]))));
    try cli.jsonPreflight("{\"quoted\":\"[[[[[[[[[[[\\\"}\"}");
}

test "template blocks, comments, quoted delimiters and every condition recursion form" {
    try cli.templatePreflight(repeat_lit("{% if true %}", 8) ++ "ok" ++ repeat_lit("{% endif %}", 8));
    try t.expectError(error.TemplateDepthLimit, cli.templatePreflight(repeat_lit("{% if true %}", 9)));
    try cli.templatePreflight(repeat_lit("{%if(true)%}", 8) ++ "ok" ++ repeat_lit("{%endif%}", 8));
    try t.expectError(error.TemplateDepthLimit, cli.templatePreflight(repeat_lit("{%if(true)%}", 9)));
    try t.expectError(error.ConditionLimit, cli.templatePreflight("{%if" ++ &@as([9:0]u8, @splat("!"[0])) ++ "true%}"));
    try cli.templatePreflight(repeat_lit("{# {% if true %}", 9) ++ "#}");
    try cli.templatePreflight("{% if \"{% if not not not not not not not not not %}\" %}ok{% endif %}");
    try cli.templatePreflight(repeat_lit("{% if not ", 1) ++ repeat_lit("not ", 7) ++ "true %}ok{% endif %}");
    try t.expectError(error.ConditionLimit, cli.templatePreflight("{% if " ++ repeat_lit("not ", 9) ++ "true %}"));
    try t.expectError(error.ConditionLimit, cli.templatePreflight("{% if " ++ &@as([9:0]u8, @splat("!"[0])) ++ "true %}"));
    try t.expectError(error.ConditionLimit, cli.templatePreflight("{% if " ++ &@as([9:0]u8, @splat("("[0])) ++ "true" ++ &@as([9:0]u8, @splat(")"[0])) ++ " %}"));
    try t.expectError(error.ConditionLimit, cli.templatePreflight("{% if true " ++ repeat_lit("or true ", 9) ++ "%}"));
    try t.expectError(error.ConditionLimit, cli.templatePreflight("{% if true %}{% elseif " ++ repeat_lit("not ", 9) ++ "true %}"));
}

test "unchanged format rendering and optional JSON" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d: kt.Diagnostic = .{};
    for ([_]kt.Format{ .textile, .markdown, .gfm }, [_][]const u8{ "*hello*", "**hello**", "**hello**" }) |format, expected| {
        const output = try cli.render(arena.allocator(), "{{ title | bold }}", "{\"title\":\"hello\"}", .{ .template = "t", .format = format }, &d);
        try t.expectEqualStrings(expected, output);
    }
    try t.expectEqualStrings("ok", try cli.render(arena.allocator(), "ok{{missing}}", null, .{ .template = "t" }, &d));
}

test "invalid JSON and template diagnostics never produce a result" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d: kt.Diagnostic = .{};
    const a = arena.allocator();
    try t.expectError(error.InvalidJson, cli.render(a, "before", "{broken", .{ .template = "t" }, &d));
    try t.expectError(error.JsonObjectRequired, cli.render(a, "before", "[]", .{ .template = "t" }, &d));
    try t.expectError(error.Template, cli.render(a, "before{{missing | unknown}}", null, .{ .template = "t" }, &d));
    try t.expect(std.mem.indexOf(u8, d.message, "no filter named") != null);
}

test "engine output charge exact boundary and one byte beyond" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d: kt.Diagnostic = .{};
    const options: cli.Render = .{ .template = "t", .max_output = 4 };
    try t.expectEqualStrings("1234", try cli.render(arena.allocator(), "1234", null, options, &d));
    try t.expectError(error.OutputLimit, cli.render(arena.allocator(), "12345", null, options, &d));
    try t.expect(std.mem.startsWith(u8, d.detail, "output exceeded the 4 byte limit"));
}

test "8 MiB aggregate arena includes input, output, metadata and deterministic OOM" {
    const memory = @import("memory");
    const bytes = try t.allocator.alignedAlloc(u8, .fromByteUnits(4096), cli.arena_bytes);
    defer t.allocator.free(bytes);
    const backing = try memory.Arena.init(bytes);
    var arena = std.heap.ArenaAllocator.init(backing.allocator());
    defer arena.deinit();
    var d: kt.Diagnostic = .{};
    // An allowed 128 KiB input with many tiny AST nodes exhausts the arena.
    const template = repeat_lit("{{x}}", (cli.input_limit / 5));
    try t.expectError(error.OutOfMemory, cli.render(arena.allocator(), template, null, .{ .template = "t" }, &d));
    try t.expect(backing.peak() <= cli.arena_bytes);
}

test "owned argv packing refuses before mutation at both ABI boundaries" {
    const startup = @import("startup");
    var block: [startup.block_bytes]u8 = @splat(0xcc);
    try startup.pack(&.{ "K4O.BIN", &@as([255:0]u8, @splat("x"[0])) }, &.{}, &block);
    @memset(&block, 0xcc);
    try t.expectError(error.ArgumentLimit, startup.pack(&.{ "K4O.BIN", &@as([256:0]u8, @splat("x"[0])) }, &.{}, &block));
    try t.expect(std.mem.allEqual(u8, &block, 0xcc));
    try t.expectError(error.ArgumentLimit, startup.pack(&(@as([9][]const u8, @splat(@as([]const u8, "x")))), &.{}, &block));
}
