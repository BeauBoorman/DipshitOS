const std = @import("std");
const qjs = @import("qjs");
const memory = @import("arena");
extern fn printf([*:0]const u8, ...) callconv(.c) c_int;
extern fn fprintf(*anyopaque, [*:0]const u8, ...) callconv(.c) c_int;
extern fn fputc(c_int, *anyopaque) callconv(.c) c_int;
extern fn fwrite(*const anyopaque, usize, usize, *anyopaque) callconv(.c) usize;
extern fn putchar(c_int) callconv(.c) c_int;

pub const Harness = struct {
    tick: u64 = 0,
    step: u64 = 0,
    frequency: u64 = 24_000_000,
    writes: usize = 0,
    short_write: usize = 256,
    fail_after: ?usize = null,
    cancel_after: ?usize = null,
    polls: usize = 0,
    output: [65_536]u8 = undefined,
    output_len: usize = 0,
    diagnostic: [256]u8 = undefined,
    diagnostic_len: usize = 0,
    largest_chunk: usize = 0,
    runtime: ?*qjs.Runtime = null,
    force_work_limit: bool = false,
    arm_on_output: bool = false,

    pub fn clock(self: *Harness) qjs.Clock {
        return .{ .context = self, .frequency = self.frequency, .counter = count };
    }
    fn count(context: *anyopaque) u64 {
        const self: *Harness = @ptrCast(@alignCast(context));
        self.tick += self.step;
        return self.tick;
    }
    pub fn sink(self: *Harness) qjs.Sink {
        return .{ .context = self, .write = write, .diagnostic = emitDiagnostic, .poll = poll };
    }
    fn write(context: *anyopaque, bytes: []const u8) !usize {
        const self: *Harness = @ptrCast(@alignCast(context));
        if (self.arm_on_output) {
            self.step = 100_000;
            self.arm_on_output = false;
        }
        if (self.fail_after) |limit| if (self.writes == limit) return 0;
        self.writes += 1;
        self.largest_chunk = @max(self.largest_chunk, bytes.len);
        const size = @min(bytes.len, self.short_write);
        if (size > self.output.len - self.output_len) return error.FixtureOutputOverflow;
        @memcpy(self.output[self.output_len .. self.output_len + size], bytes[0..size]);
        self.output_len += size;
        return size;
    }
    fn emitDiagnostic(context: *anyopaque, bytes: []const u8) !void {
        const self: *Harness = @ptrCast(@alignCast(context));
        if (bytes.len > self.diagnostic.len - self.diagnostic_len) return error.FixtureDiagnosticOverflow;
        @memcpy(self.diagnostic[self.diagnostic_len .. self.diagnostic_len + bytes.len], bytes);
        self.diagnostic_len += bytes.len;
    }
    fn poll(context: *anyopaque) bool {
        const self: *Harness = @ptrCast(@alignCast(context));
        self.polls += 1;
        if (self.force_work_limit) {
            self.runtime.?.control.work_sites = qjs.limits.work;
            self.force_work_limit = false;
        }
        return if (self.cancel_after) |limit| self.polls >= limit else false;
    }
    pub fn clear(self: *Harness) void {
        self.output_len = 0;
        self.diagnostic_len = 0;
        self.cancel_after = null;
        self.fail_after = null;
        self.step = 0;
        self.writes = 0;
        self.short_write = 256;
        self.arm_on_output = false;
    }
};

fn require(condition: bool) !void {
    if (!condition) return error.RuntimeContractMismatch;
}

fn success(runtime: *qjs.Runtime, harness: *Harness, source: []const u8, expected: []const u8) !void {
    harness.clear();
    const result = try runtime.eval(source, "contract.js", harness.sink(), true);
    if (result.failure) |failure| return failure;
    if (!std.mem.eql(u8, expected, harness.output[0..harness.output_len])) {
        if (@import("builtin").os.tag != .freestanding)
            std.debug.print("contract source={s}, expected={s}, observed={s}\n", .{ source, expected, harness.output[0..harness.output_len] });
        return error.RuntimeContractMismatch;
    }
    try require(harness.largest_chunk <= 256);
}

pub fn run(arena: memory.Arena) !void {
    const harness = try arena.allocator().create(Harness);
    defer arena.allocator().destroy(harness);
    harness.* = .{};
    const runtime = try qjs.Runtime.create(arena, harness.clock());
    harness.runtime = runtime;
    defer runtime.destroy() catch @panic("fixture teardown failed");
    const second = qjs.Runtime.create(arena, harness.clock());
    if (second) |_| return error.ContextLimitMissing else |err| try require(err == error.ContextLimit);

    try success(runtime, harness, "1+2*3", "7\n");
    try success(runtime, harness, "print('a', 42, 'b\\u0000c'); console.log('done');", "a 42 b\x00c\ndone\n");
    try success(runtime, harness, "let n=40; n+2", "42\n");
    harness.clear();
    const exception = try runtime.eval("n++; throw new Error('ordinary')", "contract.js", harness.sink(), true);
    try require(exception.failure != null and exception.failure.? == error.JSException and !exception.context_reset);
    try success(runtime, harness, "n", "41\n");
    try success(runtime, harness, "'e\\u0301'.normalize('NFC') + ':' + /a+b/u.test('aaab')", "é:true\n");
    try success(runtime, harness, "JSON.stringify([2n**80n+'', [3,1,2].sort((a,b)=>a-b), Math.round(-0.5)])", "[\"1208925819614629174706176\",[1,2,3],0]\n");
    try success(runtime, harness, "Math.sin(Math.PI/2)+Math.cos(0)+Math.log(Math.E)+Math.log2(8)+Math.log10(100)+Math.exp(0)+Math.tan(0)", "9\n");
    try success(runtime, harness, "Math.random()", "0.28083505005035936\n");
    // Growth past malloc_usable_size slack: fast arrays, sort slots and
    // string buffers must keep every element across each realloc. Results
    // were checked independently with Node.js.
    try success(runtime, harness, "new Array(32768).fill(1).sort((a,b)=>a-b).length", "32768\n");
    try success(runtime, harness, "let a=new Array(1000).fill(7); a.every(x=>x===7)", "true\n");
    try success(runtime, harness, "let b=[]; for(let i=0;i<5000;i++) b.push((i*7919)%5000); b.sort((x,y)=>x-y); b.every((v,i)=>v===i)", "true\n");
    try success(runtime, harness, "let p=[]; for(let i=0;i<20000;i++) p.push(String.fromCharCode(97+i%26)); let s=p.join(''); let ok=s.length===20000; for(let i=0;i<s.length;i++) if(s.charCodeAt(i)!==97+i%26) ok=false; ok", "true\n");
    try success(runtime, harness, "let j=JSON.stringify(new Array(2000).fill([1,2,3])); j.length===16001 && j.split('[1,2,3]').length===2001", "true\n");
    try runtime.reset();
    try success(runtime, harness, "Math.random()", "0.28083505005035936\n");
    try success(runtime, harness, "typeof n", "undefined\n");

    harness.clear();
    harness.short_write = 7;
    var result = try runtime.eval("print('x'.repeat(1000))", "contract.js", harness.sink(), false);
    if (!(result.failure == null and harness.output_len == 1001 and harness.writes > 100))
        return error.ShortWriteContract;

    harness.clear();
    harness.fail_after = 0;
    result = try runtime.eval("print('x')", "contract.js", harness.sink(), false);
    if (!(result.failure != null and result.failure.? == error.WriteFailed and result.context_reset))
        return error.WriteFailureContract;
    try success(runtime, harness, "6*7", "42\n");

    // Invalid arguments prove that the five stubs never inspect FILE,
    // strings, counts or data. Their sticky latch crosses the next boundary.
    for (0..5) |index| {
        const pointer: *anyopaque = @ptrFromInt(1);
        const text: [*:0]const u8 = @ptrFromInt(1);
        const code: isize = switch (index) {
            0 => printf(text),
            1 => fprintf(pointer, text),
            2 => fputc(1, pointer),
            3 => @intCast(fwrite(pointer, std.math.maxInt(usize), std.math.maxInt(usize), pointer)),
            else => putchar(1),
        };
        try require(code == if (index == 3) @as(isize, 0) else @as(isize, -1));
        harness.clear();
        result = try runtime.eval("42", "contract.js", harness.sink(), true);
        if (!(result.failure != null and result.failure.? == error.UnsupportedHostedDiagnostic and result.context_reset))
            return error.StubLatchContract;
        try success(runtime, harness, "6*7", "42\n");
    }

    harness.clear();
    result = try runtime.eval("'x'.repeat(65535)", "contract.js", harness.sink(), true);
    if (!(result.failure == null and result.output_bytes == 65536))
        return error.OutputExactContract;
    harness.clear();
    result = try runtime.eval("try { print('x'.repeat(65536)); } catch(e) {} 42", "contract.js", harness.sink(), true);
    if (!(result.failure != null and result.failure.? == error.OutputLimit and result.context_reset))
        return error.OutputLimitContract;
    try success(runtime, harness, "6*7", "42\n");

    for ([_][]const u8{
        "async function f(){}",
        "eval('async function f(){}')",
        "Function('return async function(){}')()",
        "import('x')",
        "import x from 'x'",
    }) |source| {
        harness.clear();
        result = try runtime.eval(source, "contract.js", harness.sink(), true);
        if (!(result.failure != null and result.failure.? == error.UnsupportedFeature and result.context_reset)) {
            if (@import("builtin").os.tag != .freestanding)
                std.debug.print("feature source={s}, failure={any}, reset={}\n", .{ source, result.failure, result.context_reset });
            return error.FeatureRefusalContract;
        }
        try success(runtime, harness, "6*7", "42\n");
    }
    inline for (.{
        "Date",    "Atomics", "SharedArrayBuffer", "Worker",               "std",         "os",
        "require", "Promise", "WeakRef",           "FinalizationRegistry", "fs",          "read",
        "write",   "fetch",   "WebSocket",         "setTimeout",           "performance", "document",
        "window",
    }) |name| try success(runtime, harness, "typeof " ++ name, "undefined\n");

    harness.clear();
    harness.step = 100_000;
    result = try runtime.eval("try { for(;;){} } catch(e) {} 42", "contract.js", harness.sink(), true);
    if (!(result.failure != null and result.failure.? == error.EvaluationDeadline and result.context_reset))
        return error.DeadlineContract;
    try success(runtime, harness, "6*7", "42\n");

    harness.clear();
    runtime.cancel();
    result = try runtime.eval("42", "contract.js", harness.sink(), true);
    if (!(result.failure != null and result.failure.? == error.Cancelled and result.context_reset))
        return error.PrequeuedCancellationContract;
    try success(runtime, harness, "6*7", "42\n");

    harness.clear();
    harness.cancel_after = harness.polls + 200;
    result = try runtime.eval("for(;;){}", "contract.js", harness.sink(), true);
    if (!(result.failure != null and result.failure.? == error.Cancelled and result.context_reset))
        return error.ActiveCancellationContract;
    try success(runtime, harness, "6*7", "42\n");

    harness.clear();
    result = try runtime.eval("function f(){return f()} try {f()}catch(e){} 42", "contract.js", harness.sink(), true);
    if (!(result.failure != null and result.failure.? == error.StackLimit and result.context_reset))
        return error.StackResetContract;
    try success(runtime, harness, "6*7", "42\n");

    harness.clear();
    result = try runtime.eval("try { 'x'.repeat(4194304) }catch(e){} 42", "contract.js", harness.sink(), true);
    if (!(result.failure != null and result.failure.? == error.OutOfMemory and result.context_reset))
        return error.OutOfMemoryResetContract;
    try success(runtime, harness, "6*7", "42\n");

    const adapter_buffer = try runtime.allocate(4096);
    @memset(adapter_buffer, 0x5a);
    try runtime.reset();
    for (adapter_buffer) |byte| try require(byte == 0x5a);
    runtime.release(adapter_buffer);
    try success(runtime, harness, "6*7", "42\n");

    harness.clear();
    result = try runtime.eval("let a=0; for(let i=0;i<10;i++)a++;a", "contract.js", harness.sink(), true);
    try require(result.failure == null and result.work_sites >= 10 and result.work_sites < 100);
    harness.clear();
    harness.force_work_limit = true;
    result = try runtime.eval("try { for(;;){} }catch(e){} 42", "contract.js", harness.sink(), true);
    if (!(result.failure != null and result.failure.? == error.WorkLimit and result.context_reset))
        return error.WorkLimitContract;
    try success(runtime, harness, "6*7", "42\n");

    // Named native slow paths must propagate a poll refusal, not finish the
    // entire input before observing it. Deterministic counters test policy;
    // the product's real-counter guest timing remains M88c's responsibility.
    for ([_][]const u8{
        "let a='a'.repeat(10000), r=/^(a+)+b$/; print('ARM'); r.test(a)",
        "let a=2n**20000n; print('ARM'); a.toString()",
        "let a='e\\u0301'.repeat(2000); print('ARM'); a.normalize('NFC')",
        "let a=new Array(20000).fill([1,2,3]); print('ARM'); JSON.stringify(a)",
        "let a=new Array(2000).fill(1); print('ARM'); a.sort((a,b)=>a-b)",
        "let a='x'.repeat(100000); print('ARM'); a.split('')",
        "let a={toString(){for(;;){} }}; print('ARM'); print(a)",
    }) |source| {
        harness.clear();
        harness.arm_on_output = true;
        result = try runtime.eval(source, "contract.js", harness.sink(), true);
        if (!(result.failure != null and result.failure.? == error.EvaluationDeadline and result.context_reset))
            return error.SlowPathPollContract;
        try success(runtime, harness, "6*7", "42\n");
    }
    harness.clear();
    harness.step = 100_000;
    result = try runtime.eval(&@as([5000:0]u8, @splat(" "[0])) ++ "42", "contract.js", harness.sink(), true);
    if (!(result.failure != null and result.failure.? == error.EvaluationDeadline and result.context_reset))
        return error.ParserPollContract;
    try success(runtime, harness, "6*7", "42\n");
}
