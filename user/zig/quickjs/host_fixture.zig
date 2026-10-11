const qjs = @import("qjs");
const memory = @import("arena");
const contract = @import("contract.zig");
var backing: [qjs.limits.arena]u8 align(4096) = undefined;

test "complete adapter-free hosted runtime contract" {
    const arena = try memory.Arena.init(&backing);
    try @import("contract.zig").run(arena);
    try @import("std").testing.expectEqual(@as(usize, 32), arena.used());
}

test "source exact/over, invalid UTF8, handles, diagnostics and repeated reuse" {
    const std = @import("std");
    const arena = try memory.Arena.init(&backing);
    const harness = try arena.allocator().create(contract.Harness);
    defer arena.allocator().destroy(harness);
    harness.* = .{};
    const runtime = try qjs.Runtime.create(arena, harness.clock());
    defer runtime.destroy() catch @panic("fixture teardown failed");
    const source = try runtime.allocate(qjs.limits.source + 1);
    defer runtime.release(source);
    @memset(source, ' ');
    @memcpy(source[0..6], "1+2*3;");
    var result = try runtime.eval(source[0..qjs.limits.source], "source.js", harness.sink(), true);
    if (result.failure) |failure| return failure;
    try std.testing.expectEqualStrings("7\n", harness.output[0..harness.output_len]);
    try std.testing.expectError(error.InputLimit, runtime.eval(source, "source.js", harness.sink(), true));
    harness.clear();
    result = try runtime.eval("\xc0\x80", "source.js", harness.sink(), true);
    try std.testing.expectEqual(error.InvalidUtf8, result.failure.?);
    try std.testing.expect(result.context_reset);
    try runtime.checkResources(2, 7);
    try std.testing.expectError(error.HandleLimit, runtime.checkResources(3, 7));
    try std.testing.expectError(error.HandleLimit, runtime.checkResources(2, 8));
    try std.testing.expectError(error.InvalidFilename, runtime.eval("42", &@as([65:0]u8, @splat("x"[0])), harness.sink(), true));
    try std.testing.expectError(error.InvalidFilename, runtime.eval("42", "x\x00y", harness.sink(), true));
    for (0..16) |_| {
        try runtime.reset();
        harness.clear();
        result = try runtime.eval("let a=[]; a.push(a); new Map().set(a,a); 42", "source.js", harness.sink(), true);
        if (result.failure) |failure| return failure;
        try std.testing.expectEqualStrings("42\n", harness.output[0..harness.output_len]);
    }
    try runtime.control.chargeDiagnostic(qjs.limits.diagnostics - qjs.limits.terminal_diagnostic);
    try std.testing.expectError(error.DiagnosticLimit, runtime.control.chargeDiagnostic(1));
    try std.testing.expectError(error.ReceiptLimit, runtime.chargeReceipt(qjs.limits.receipt + 1));
}

test "repeated create/destroy proves ordinary cyclic GC and same-arena reuse" {
    const std = @import("std");
    const arena = try memory.Arena.init(&backing);
    const harness = try arena.allocator().create(contract.Harness);
    defer arena.allocator().destroy(harness);
    const baseline = arena.used();
    for (0..16) |_| {
        harness.* = .{};
        const runtime = try qjs.Runtime.create(arena, harness.clock());
        const result = try runtime.eval("let a=[]; a.push(a); new Map().set(a,a); 42", "cycles.js", harness.sink(), true);
        if (result.failure) |failure| return failure;
        try runtime.destroy();
        try std.testing.expectEqual(baseline, arena.used());
    }
}
