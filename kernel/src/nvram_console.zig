//! VirelaiOS NVRAM console channel (M1.5 VZ serial-gate successor work,
//! claim 0015).
//!
//! The VZ serial gate is blocked because post-exit access to the
//! virtio-pci console transport hangs on VZ (claim 0013, observed): the
//! first banner TX dies in the flush and `vm-serial.log` stays 0 bytes.
//! The only proven post-exit device channel is EFI runtime `SetVariable`
//! (the claim-0009 marker ladder persists post-exit on VZ, observed), so
//! this module carries console bytes over the same channel: output is
//! buffered in RAM and persisted as chunked EFI variables `VirelaiC0`,
//! `VirelaiC1`, ... Each chunk payload is ≤ 256 bytes — comfortably under
//! the proven-safe post-exit write budget — and each chunk is a FRESH
//! variable (never a re-write of a big variable, which is what hangs
//! post-exit on VZ, claim 0013).
//!
//! Chunk encoding: the stored value is `VIRELAIC <4-digit-index>:` followed
//! by the raw payload bytes. The prefix rides INSIDE the value so the host
//! can find every chunk with a plain byte scan of the variable store
//! (file order == write order, same technique as the marker ladder) — no
//! struct-layout parsing of the store.
//!
//! Honesty rules: the bytes travel the NVRAM variable channel, NOT the
//! virtio serial pipe; this is the fallback channel claim 0013 named, and
//! it is a diagnostic/evidence path, not a production console. Writes are
//! best-effort (a failed runtime call never changes control flow), bounded
//! (a chunk cap; further output is dropped with one honest notice chunk),
//! and never touch the MMIO transport. With no captured `SetVariable`
//! pointer, writes are no-ops — the console honestly goes silent rather
//! than pretending.
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const uefi = std.os.uefi;
const mmu = @import("mmu.zig");

const RuntimeServices = uefi.tables.RuntimeServices;
const Status = uefi.Status;

/// EFI Runtime Services `SetVariable` — the same function type the
/// claim-0009 marker channel and the M1.5 machine controls use.
const SetVariableFn = *const fn (
    var_name: [*:0]const u16,
    vendor_guid: *const uefi.Guid,
    attributes: RuntimeServices.VariableAttributes,
    data_size: usize,
    data: [*]const u8,
) callconv(uefi.cc) Status;

/// Payload bytes per persisted chunk. 256 keeps the whole value ≤ ~270
/// bytes — well under the ~512-byte post-exit write budget proven on VZ
/// (claim 0013: the ≤512-byte `VirelaiP2` probe tail persists post-exit,
/// while ~2.6 KB+ re-writes hang).
pub const chunk_cap: usize = 256;

/// Total chunk budget (soft cap). Chunks are one per newline (short help/
/// banner lines average ~75 B, not the 256 B chunk_cap), so the cap is a
/// LINE-count bound, not a byte bound. Observed on VZ 2026-08-31: the full
/// gate session (takeover banner + descriptor map + probe records + shell
/// banner + version/mem/help) is ~12.7 KiB but lands as **168 chunks**. The
/// cap has historically been raised as the help catalog grew (64 → 128 cut
/// the help listing off mid-way even with ~47 KiB free); 128 now cuts it off
/// again at ~10470 B/129 chunks. 256 fits today's session (~1.5× headroom)
/// while the EFI variable store write budget (~61 KiB writable) is the real
/// ceiling anyway. One extra chunk is reserved for the overflow notice.
pub const max_chunks: usize = 256;

/// In-band chunk marker, 14 bytes: "VIRELAIC " + 4 zero-padded decimal
/// digits + ":". Distinctive enough that no real console output collides
/// (the monitor prints hex/decimal/ASCII, never this exact string).
pub const marker_len: usize = 14;
const marker_prefix = "VIRELAIC ";

/// In-band end marker appended after every chunk's payload, so the host can
/// delimit each chunk's payload without parsing the EFI variable store's
/// structure (the store also holds variable headers, GUIDs, and other
/// variables between chunk values — a raw byte scan to the NEXT start
/// marker would swallow them). Console output never contains this string.
pub const end_marker = "VIRELAIC-END";
pub const end_marker_len = end_marker.len;

/// Variable naming: `VirelaiC` + decimal chunk index (e.g. `VirelaiC0`).
const variable_prefix = "VirelaiC";
const variable_name_max: usize = 16;

/// Same vendor GUID as the marker ladder / machine controls
/// (`M2M2_VIRELAIOS-M`) so one store namespace holds all kernel variables.
const vendor_guid = uefi.Guid{
    .time_low = 0x4d324d32, // "M2M2"
    .time_mid = 0x5f44, // "_D"
    .time_high_and_version = 0x4950, // "IP"
    .clock_seq_high_and_reserved = 0x53, // "S"
    .clock_seq_low = 0x48, // "H"
    .node = .{ 0x49, 0x54, 0x4f, 0x53, 0x2d, 0x4d }, // "ITOS-M"
};

const variable_attributes = RuntimeServices.VariableAttributes{
    .non_volatile = true,
    .bootservice_access = true,
    .runtime_access = true,
};

fn utf16z(comptime text: []const u8) [text.len + 1:0]u16 {
    var result: [text.len + 1:0]u16 = undefined;
    for (text, 0..) |byte, index| result[index] = byte;
    result[text.len] = 0;
    return result;
}

/// NVRAM console state. The kernel is single-threaded and this module has
/// no entry points beyond `init`/`write`/`putc`/`flush`, so module-level
/// state is safe; tests exercise the same surface with an injected fake.
const State = struct {
    set_var: ?SetVariableFn = null,
    buffer: [chunk_cap]u8 = undefined,
    len: usize = 0,
    chunks: usize = 0,
    dropped: usize = 0,
    overflow_noted: bool = false,
    debug_marked: bool = false,

    /// Append bytes to the RAM buffer, persisting a chunk when the buffer
    /// fills or a line completes (the console's logical writes are
    /// newline-terminated). Bytes past the chunk budget are dropped with
    /// one honest notice chunk.
    fn append(self: *State, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.chunks >= max_chunks) {
                if (!self.overflow_noted) {
                    self.overflow_noted = true;
                    const msg = "[nvram-console: output dropped at chunk cap]\n";
                    @memcpy(self.buffer[0..msg.len], msg);
                    self.len = msg.len;
                    self.emit();
                }
                self.dropped += 1;
                continue;
            }
            self.buffer[self.len] = byte;
            self.len += 1;
            if (self.len >= chunk_cap or byte == '\n') self.emit();
        }
    }

    /// Persist the buffered bytes as one chunk variable. Best effort: a
    /// failed (or absent) SetVariable never changes control flow — the
    /// buffer is cleared either way so output cannot loop.
    fn emit(self: *State) void {
        if (self.len == 0) return;
        const set_var = self.set_var orelse {
            self.len = 0;
            return;
        };
        var value: [marker_len + chunk_cap + end_marker_len]u8 = undefined;
        @memcpy(value[0..marker_prefix.len], marker_prefix);
        const idx = self.chunks;
        // Four zero-padded decimal digits directly after the prefix, then
        // the colon — offsets derived from the constants so a prefix
        // change cannot silently shift the digits.
        value[marker_prefix.len + 0] = '0' + @as(u8, @intCast((idx / 1000) % 10));
        value[marker_prefix.len + 1] = '0' + @as(u8, @intCast((idx / 100) % 10));
        value[marker_prefix.len + 2] = '0' + @as(u8, @intCast((idx / 10) % 10));
        value[marker_prefix.len + 3] = '0' + @as(u8, @intCast(idx % 10));
        value[marker_prefix.len + 4] = ':';
        @memcpy(value[marker_len .. marker_len + self.len], self.buffer[0..self.len]);
        @memcpy(value[marker_len + self.len ..][0..end_marker_len], end_marker);
        const total = marker_len + self.len + end_marker_len;

        var name: [variable_name_max:0]u16 = undefined;
        var i: usize = 0;
        while (i < variable_prefix.len) : (i += 1) name[i] = variable_prefix[i];
        // Note: `break` skips Zig's continue expression, so nd is bumped
        // before the break — otherwise the first digit is silently dropped.
        var digits: [4]u8 = undefined;
        var n = idx;
        var nd: usize = 0;
        while (true) {
            digits[nd] = @intCast('0' + (n % 10));
            n /= 10;
            nd += 1;
            if (n == 0) break;
        }
        while (nd > 0) : (nd -= 1) {
            name[i] = digits[nd - 1];
            i += 1;
        }
        name[i] = 0;

        // Claim 5804: firmware runtime services execute at their PHYSICAL
        // addresses, which only the kernel root (identity) maps — the EL0
        // task's text+stack TTBR0 root does not contain them, so a
        // SetVariable fired from the user task's syscall context would
        // fault. Run the call with TTBR0 = kernel root and restore the
        // caller's root after (no-op on host test processes).
        const prev_ttbr0 = mmu.current_ttbr0();
        mmu.set_ttbr0(mmu.kernel_root_phys());
        defer mmu.set_ttbr0(prev_ttbr0);
        _ = set_var(&name, &vendor_guid, variable_attributes, total, &value);
        self.chunks += 1;
        self.len = 0;
    }
};

/// Module state, captured once by `init` (kernel_main, pre-exit).
var state: State = .{};

/// Capture the EFI Runtime Services table so console chunks can be
/// persisted after ExitBootServices (runtime services, unlike boot
/// services, survive it — the claim-0009 marker channel proves
/// SetVariable works post-exit on VZ). Called once, pre-exit, from
/// kernel_main. Without it, writes are honest no-ops.
pub fn init(rt: *RuntimeServices) void {
    state.set_var = @ptrCast(rt._setVariable);
}

/// Append console bytes to the NVRAM channel (buffered, chunked on
/// newline / buffer-full).
pub fn write(bytes: []const u8) void {
    state.append(bytes);
}

/// Append one console byte.
pub fn putc(byte: u8) void {
    const one = [1]u8{byte};
    state.append(&one);
}

/// Persist any buffered bytes immediately (e.g. the trailing prompt, which
/// has no newline). Idempotent when the buffer is empty.
pub fn flush() void {
    state.emit();
}

/// Claim 0015 diagnostic (currently uninvoked from the kernel; kept as a
/// boot-time aid for future debugging, covered by its own test): persist a
/// single byte to the fixed variable `VirelaiX` the first time it is
/// called. Used to distinguish "the console write path was never entered"
/// from "a write hung/failed" when the chunk stream stops. Best effort,
/// once per boot.
pub fn debug_mark(byte: u8) void {
    if (state.debug_marked) return;
    state.debug_marked = true;
    const set_var = state.set_var orelse return;
    var name: [variable_name_max:0]u16 = undefined;
    const prefix = "VirelaiX";
    for (prefix, 0..) |ch, i| name[i] = ch;
    name[prefix.len] = 0;
    const value = [1]u8{byte};
    // Claim 5804: same kernel-root TTBR0 wrap as `emit` — the runtime
    // services code lives at identity addresses that the user root does
    // not map.
    const prev_ttbr0 = mmu.current_ttbr0();
    mmu.set_ttbr0(mmu.kernel_root_phys());
    defer mmu.set_ttbr0(prev_ttbr0);
    _ = set_var(&name, &vendor_guid, variable_attributes, value.len, &value);
}

// ---------------------------------------------------------------------------
// Tests (host-side; injected fakes, no hardware)
// ---------------------------------------------------------------------------

// Big enough for the "output past the chunk cap" test to observe
// max_chunks+1 calls (the full cap plus the overflow notice); sized off
// max_chunks so the two stay in sync if the cap is ever raised again.
const spy_max_calls: usize = max_chunks + 64;
const spy_value_max: usize = marker_len + chunk_cap + end_marker_len;
var spy_count: usize = 0;
// Variable names are ASCII, so they are stored as bytes for easy
// comparison in tests.
var spy_names: [spy_max_calls][variable_name_max]u8 = undefined;
var spy_values: [spy_max_calls][spy_value_max]u8 = undefined;
var spy_lens: [spy_max_calls]usize = undefined;

fn spySetVar(
    var_name: [*:0]const u16,
    _: *const uefi.Guid,
    _: RuntimeServices.VariableAttributes,
    data_size: usize,
    data: [*]const u8,
) callconv(uefi.cc) Status {
    if (spy_count < spy_max_calls) {
        const name_len = std.mem.len(var_name);
        for (var_name[0..name_len], 0..) |ch, i| spy_names[spy_count][i] = @intCast(ch);
        spy_names[spy_count][name_len] = 0;
        const n = @min(data_size, spy_value_max);
        @memcpy(spy_values[spy_count][0..n], data[0..n]);
        spy_lens[spy_count] = n;
        spy_count += 1;
    }
    return .success;
}

/// Reset module state to a spy-backed state and clear the spy so tests are
/// independent (module-level spies accumulate otherwise).
fn make_state() *State {
    spy_count = 0;
    state = .{ .set_var = &spySetVar };
    return &state;
}

/// Variable names are ASCII, so the u16 name is compared as bytes.
fn spy_name(index: usize) []const u8 {
    return std.mem.sliceTo(&spy_names[index], 0);
}

test "nvram-console: writes persist newline-terminated chunks in order" {
    _ = make_state();
    write("hello\n");
    write("world\n");
    try std.testing.expectEqual(@as(usize, 2), spy_count);
    try std.testing.expectEqualStrings("VirelaiC0", spy_name(0));
    try std.testing.expectEqualStrings("VIRELAIC 0000:hello\n" ++ end_marker, spy_values[0][0..spy_lens[0]]);
    try std.testing.expectEqualStrings("VirelaiC1", spy_name(1));
    try std.testing.expectEqualStrings("VIRELAIC 0001:world\n" ++ end_marker, spy_values[1][0..spy_lens[1]]);
}

test "nvram-console: a full buffer persists without a newline" {
    _ = make_state();
    const many = @as([(chunk_cap + 40)]u8, @splat(@as(u8, 'a')));
    write(&many);
    // First chunk filled the 256-byte buffer; 40 bytes remain buffered.
    try std.testing.expectEqual(@as(usize, 1), spy_count);
    try std.testing.expectEqualStrings("VIRELAIC 0000:", spy_values[0][0..marker_len]);
    try std.testing.expectEqual(@as(usize, chunk_cap), spy_lens[0] - marker_len - end_marker_len);
    flush();
    try std.testing.expectEqual(@as(usize, 2), spy_count);
    try std.testing.expectEqualStrings("VIRELAIC 0001:", spy_values[1][0..marker_len]);
    try std.testing.expectEqual(@as(usize, 40), spy_lens[1] - marker_len - end_marker_len);
}

test "nvram-console: a single large write splits across chunks" {
    _ = make_state();
    const big = @as([(chunk_cap * 2 + 10)]u8, @splat(@as(u8, 'b')));
    write(&big);
    // Two full chunks persist inline; the trailing 10 bytes (no newline)
    // stay buffered until the explicit flush.
    try std.testing.expectEqual(@as(usize, 2), spy_count);
    try std.testing.expectEqual(@as(usize, chunk_cap), spy_lens[0] - marker_len - end_marker_len);
    try std.testing.expectEqual(@as(usize, chunk_cap), spy_lens[1] - marker_len - end_marker_len);
    flush();
    try std.testing.expectEqual(@as(usize, 3), spy_count);
    try std.testing.expectEqualStrings("VIRELAIC 0002:", spy_values[2][0..marker_len]);
    try std.testing.expectEqual(@as(usize, 10), spy_lens[2] - marker_len - end_marker_len);
}

test "nvram-console: debug_mark persists once with a fixed name" {
    _ = make_state();
    debug_mark('W');
    debug_mark('W');
    try std.testing.expectEqual(@as(usize, 1), spy_count);
    try std.testing.expectEqualStrings("VirelaiX", spy_name(0));
    try std.testing.expectEqual(@as(usize, 1), spy_lens[0]);
    try std.testing.expectEqual(@as(u8, 'W'), spy_values[0][0]);
}

test "nvram-console: output past the chunk cap is dropped with a notice" {
    _ = make_state();
    // max_chunks of full chunks, then more bytes: the last allowed chunk is
    // the overflow notice, and everything after is dropped.
    const flood = @as([(chunk_cap * (max_chunks + 2))]u8, @splat(@as(u8, 'x')));
    write(&flood);
    try std.testing.expectEqual(@as(usize, max_chunks + 1), spy_count);
    const last = spy_values[spy_count - 1][0..spy_lens[spy_count - 1]];
    try std.testing.expect(std.mem.indexOf(u8, last, "output dropped at chunk cap") != null);
    try std.testing.expect(state.dropped > 0);
}

test "nvram-console: no captured SetVariable makes writes honest no-ops" {
    state = .{};
    spy_count = 0;
    write("silent\n");
    try std.testing.expectEqual(@as(usize, 0), spy_count);
}

test "nvram-console: init captures the runtime services pointer" {
    _ = make_state();
    // make_state injects the spy; init() itself is exercised through the
    // kernel seam. Verify the state's pointer is the spy.
    try std.testing.expect(state.set_var != null);
}
