//! tool.zig — wasm-channel spike slice: a real Zig HTML tool (oliver's
//! Markdown -> HTML pipeline) running on VirelaiOS through the frozen
//! `env.*` contract (docs/wasm-import-contract.md, W1a #778).
//!
//! This is *oliver's own source* (the real `oliver.parse` + `oliver.html.render`
//! entry points, vendored at tests/wasm-spike/oliver-src/ from oliver commit
//! 3f05bacb188ab28ad797430c82d9ee20080c5ed6) — not a rewrite — with only the
//! host-side edges replaced:
//!
//!   * input  : /host/MD.TXT read through env.file_open/file_read/file_close (§5.1)
//!   * output : rendered HTML emitted through env.write (W2 debug pair), in
//!              <=256-byte chunks (the kernel write_cap; a larger len is EINVAL)
//!   * memory : one FixedBufferAllocator over a static .bss arena — oliver's
//!              "the caller supplies the allocator" contract, no libc, no WASI,
//!              no env.mmap
//!   * exit   : env.exit(bytes written), mirroring the wc capstone's discipline
//!
//! Build (Zig 0.17 — note `-femit-bin=`, not the contract §7 `-o`, which
//! 0.17's `zig build-exe` rejects):
//!
//!     zig build-exe -target wasm32-freestanding -O ReleaseSmall -fstrip \
//!         --dep virelai --dep oliver \
//!         -Mroot=tests/wasm-spike/tool.zig \
//!         -Mvirelai=tests/virelai.zig -Moliver=tests/wasm-spike/oliver-src/oliver.zig \
//!         -femit-bin=tool.wasm
//!
//! Exit statuses (mirroring fileapp/wc's discipline of distinct codes):
//!   31 open failed   32 read failed   33 read-capped-out
//!   41 parse failed  42 render failed 43 write failed
//!   >=0 = bytes of HTML written to fd 1 (never 0 for a non-empty document)

const std = @import("std");
const v = @import("virelai");
const oliver = @import("oliver");

/// Input cap. Bounded by linear memory (D2: 2 MiB total); the document is
/// borrowed by oliver's IR, so this buffer must live for the whole run.
const max_in: usize = 64 * 1024;
/// oliver needs an allocator (arena + IR lists) — the caller supplies it.
/// Sized for the spike fixture, not for arbitrary documents.
const heap_cap: usize = 256 * 1024;
/// Rendered HTML buffer. Fixed (std.Io.Writer.fixed) so the whole output is
/// bounded and the run is deterministic; overflow is error.WriteFailed.
const out_cap: usize = 32 * 1024;
/// The kernel write_cap the interpreter mirrors (user/src/wasm.zig
/// stage_write_len = 256; a larger env.write len returns EINVAL).
const write_chunk: usize = 256;
/// The kernel file staging cap (stage_io_len = 2048) — file_read truncates above it.
const read_chunk: usize = 2048;

var g_in: [max_in]u8 = undefined;
var g_heap: [heap_cap]u8 = undefined;
var g_out: [out_cap]u8 = undefined;

/// Emit `bytes` to fd 1 through env.write, chunked under the kernel write_cap.
/// Returns bytes written, or a negative errno from the import.
fn emit(bytes: []const u8) i32 {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = @min(write_chunk, bytes.len - off);
        const r = v.write(1, bytes[off..].ptr, @intCast(n));
        if (r < 0) return r;
        if (r == 0) break;
        off += @intCast(r);
    }
    return @intCast(off);
}

export fn _start() noreturn {
    // -- input: the M34 file channel, §5.1 -----------------------------------
    const path = "/host/MD.TXT";
    const fd = v.file_open(path, path.len, v.V_MODE_READ);
    if (fd < 0) v.exit(31);

    var n: usize = 0;
    while (true) {
        if (n >= g_in.len) v.exit(33);
        const cap: u32 = @intCast(@min(read_chunk, g_in.len - n));
        const r = v.file_read(fd, g_in[n..].ptr, cap);
        if (r < 0) v.exit(32);
        if (r == 0) break;
        n += @intCast(r);
    }
    _ = v.file_close(fd);

    // -- parse + render: oliver's real entry points --------------------------
    var fba = std.heap.FixedBufferAllocator.init(&g_heap);
    const alloc = fba.allocator();

    var result = oliver.parse(alloc, g_in[0..n], .markdown, .{}) catch v.exit(41);
    defer result.deinit();

    var w = std.Io.Writer.fixed(&g_out);
    oliver.html.render(alloc, &w, &result.document, .{}) catch v.exit(42);

    // -- output: env.write, then env.exit(bytes) -----------------------------
    const html = w.buffered();
    const written = emit(html);
    if (written < 0) v.exit(43);
    v.exit(written);
}
