//! VirelaiOS ESP exec (milestone-three card 6, claim 6783; extended by the
//! milestone-four follow-on claim 0826 — concurrent processes).
//!
//! Loads a real user program from the ESP and enters it at EL0. The
//! claim-8215 static EL0 payload is boot-registered; this module loads
//! programs read through the claim-6420 FAT path (`fat.read_file` over
//! virtio-blk): the file is a flat AArch64 image in the same DSK1 format
//! as KERNEL.BIN (`tools/elf2bin.py`, 24-byte header, content at offset
//! 24), built by `zig build user` and embedded on the ESP by the image
//! builder.
//!
//! Exec is the monitor command `exec [<file>]` (default `USER.BIN`):
//!
//!   1. Read the file (bounded). Two shapes: DSK1/DSK3/contiguous-ELF and
//!      PT_INTERP files transit the whole-file 2 MiB staging buffer
//!      (`exec_program_max`); a gap-layout static ELF — every GOOS=virelai
//!      Go binary — is instead parsed from a 16 KiB header window and has
//!      each segment STREAMED straight from the share into the pages that
//!      get mapped, so it is bounded by `exec_image_max` (32 MiB) on the file
//!      and by `elf.map_max` (64 MiB) on what it maps, rather than by that
//!      array (M70c-K, issue #1504; the mapped bound split out of the file
//!      bound in M72a, issue #1579).
//!   2. Validate the header (magic, entry offset, image size).
//!   3. Gate on CAPACITY (claim 0826 — the old `user_root_in_use` gate is
//!      gone: a second program loads and runs while the first is alive):
//!      the pool's free slot (checked FIRST, so a full pool never leaks
//!      pages or tables), the page-table carve-out (`table_full`), the
//!      process registry (`process_full`), and the physical allocator
//!      (`out_of_memory`).
//!   4. Allocate the program's OWN pages — 1 text page + 2 user-stack
//!      pages + 2 EL1 exception-stack pages from the physical allocator
//!      (claims 3972/5162) — copy the stripped content into the text page,
//!      and build the process's OWN TTBR0 user root with
//!      `mmu.build_user_root` (claim 5804: identity-tree clone + EL1-only
//!      kernel overlay + the text page at `userspace.text_va` + the user
//!      stack at the randomized `stack_va`). Works POST-install because the
//!      kernel stays identity-mapped (the VZ TTBR1 fallback), so
//!      `@intFromPtr` is still physical; the fresh clone tables are
//!      D-cache-cleaned before the scheduler's next TTBR0 switch. The
//!      process owns every page (freed at reap/recycle), and the boot-time
//!      static payload keeps its linked `.usertext`/`.userbss` pages.
//!   5. Create + bind the process (`process.zig`, claim 3848) and spawn it
//!      as an EL0t task (`scheduler.register_exec_user`) under the fixed
//!      syscall ABI — with its own EL1 exception stack, because two live
//!      user tasks cannot share the static one (a second task's vector
//!      frame would clobber the first's saved context).
//!
//! Card 3e (claim 4636), lifted by M71m (#1572): `exec <file> [arg...]`
//! packs a bounded argv block (8 args × 256 B, NUL-terminated, 255 bytes
//! usable, an over-long arg refused) into the process image. The flat DSK1
//! path still packs it into the process's OWN text page right after the
//! content — the text leaf is already EL0 read-only (W^X), so that block
//! is a READ-ONLY leaf. The gap-layout ELF path sizes the writable
//! segment's pages to cover the block (ADR 0007). `_start` receives argc
//! in x0 + the block VA in x1 (an entry-contract extension, NOT a syscall;
//! ADR 0007). More than 8 args, or one arg longer than 255 bytes, is an
//! honest refusal; a no-args exec packs nothing.
//!
//! The syscall/uaccess apertures are per process (armed at SVC entry from
//! the task's TCB, claim 0826), so `sys_write` bounds follow whichever
//! program issued the call. No libc, no POSIX, no heap allocation.

const std = @import("std");
const console = @import("console.zig"); // card 3c (claim 7786): the shell-side report drain in host tests
const exceptions = @import("exceptions.zig"); // card 3e (claim 4636): the entry-contract frame slots (x0/x1) in host tests
const uaccess = @import("uaccess.zig"); // card 3e (claim 4636): the args range is read-only (copy_in ok, copy_out fault)
const mmu = @import("mmu.zig");
// M34 HF4 (issue #738): the HOST FILE CHANNEL is the exec source — `stat`
// + `read_into` stream a dropped `.ELF` into `program`.
const virtio_file = @import("virtio_file.zig");
const scheduler = @import("scheduler.zig");
const smp = @import("smp.zig");
const userspace = @import("userspace.zig");
// Milestone four (claim 2665): the seeded CSPRNG supplies the randomized
// user stack VA (the seed's real ASLR consumer).
const csprng = @import("csprng.zig");
const syscall = @import("syscall.zig");
// Milestone four (claim 3848): the loaded program is a PROCESS — the
// image + address space + lifecycle live in the bounded process registry,
// not in this module's globals.
const process = @import("process.zig");
// Card 3f (claim 5965): the per-process IPC mailbox — each exec'd
// process's ring is reset the moment its process id is created.
const mailbox = @import("mailbox.zig");
// Milestone 9 (claim 7670): per-process event queue
const events = @import("events.zig");
const app_timers = @import("app_timers.zig"); // claim 7323: the per-process app timer reset on exec
// Milestone 10 (claim 9948): per-process file handle table
const file_table = @import("file_table.zig");
const trust = @import("trust.zig"); // M50 TS2 (#1136, ADR 0024 D4/D8): the kernel-actor read gate
// Claim 0826: the per-process text/stack/kernel-stack pages come from the
// physical page allocator (claims 3972/5162).
const alloc = @import("alloc.zig");
const memmap = @import("memmap.zig"); // host-test fixture view (page_size + the arming view)
// M22 D1 (issue #324): the AArch64 ELF parse/validate module — exec_file
// sniffs the ELF magic and takes this path alongside DSK1/DSK3.
const elf_mod = @import("elf.zig");
// M22 D3 (issue #326): crash-report symbol names — populated from the
// loaded image's .symtab on every ELF exec, cleared on every other exec.
const symbol = @import("symbol.zig");
// M113c (#2419, ADR 0054 Part II): measured exec — the Part I primitive
// and receipt, the grant table, and the serial-log seam the `stage=exec`
// receipts ride on.
const measure = @import("measure.zig");
const grant = @import("grant.zig");
const klog = @import("klog.zig");

/// The STAGED load buffer: the DSK1/DSK3/contiguous-ELF paths still read
/// the whole file through this array, so an image of those shapes larger
/// than it is refused honestly (`staging_too_large`). Milestone sixteen C1 (claim
/// 3805) lifted it from the original 16 KiB bound; issue #1163
/// (GOOS=virelai phase 0a) took it 512 KiB → 1 MiB and then 2 MiB because
/// the gc Go runtime's first images exceed that even stripped (`-s -w`).
///
/// M70c-K (issue #1504) is what this bound is no longer: the gap-layout
/// ELF path (every GOOS=virelai Go binary) STREAMS its segments straight
/// from the file into their mapped pages and never stages the file at all,
/// so for those shapes this is not a bound. What bounds an image now is
/// `exec_image_max` below, plus the parser's own `elf.map_max` on what the
/// image MAPS (M72a, issue #1579).
pub const exec_program_max: usize = 2 * 1024 * 1024;

/// M97c #2097/#2099: the shared-library aperture contract, shared with
/// `user/src/ld.zig` — one 64 KiB slot per loaded library, `lib_slot_count`
/// slots total. The kernel sizes the aperture by these; ld.so advances its
/// bump pointer by the same slot and refuses at the same count, so the two
/// halves can never disagree about where a library's window ends.
pub const lib_slot_bytes: usize = 0x10000;
pub const lib_slot_count: usize = 8;
/// M70c-K (issue #1504): the acceptance bound — the largest image file the
/// loader will take, whatever its format. A file past it is refused
/// `image_too_large` up front, by name, so the caller sees "bigger than the
/// loader accepts" rather than a confusing allocator failure later. 32 MiB
/// admits the 27 MB `cmd/compile` with headroom while leaving the 512 MiB
/// guest room for the image's own heap; the true ceiling above this one is
/// the physical allocator (`out_of_memory` when the segments cannot be
/// backed), which is a memory-plan question, not a loader one.
///
/// M72a (issue #1579): this is a bound on the FILE, and it is not the whole
/// story — an image may be small on disk and map far more than it stores,
/// because `.bss`/`.noptrbss` costs no file bytes. That second quantity is
/// bounded by `elf.map_max` (64 MiB), which the parser enforces on both
/// paths and which this module reports as `map_too_large`.
pub const exec_image_max: usize = 32 * 1024 * 1024;
/// M72a (issue #1579): the parser's bound on what an image MAPS
/// (`elf.map_max`, 64 MiB), restated here so every caller that names a
/// loader bound — the monitor's refusals, the class-B fixtures — reads them
/// all from one module instead of reaching into the parser.
pub const map_max: usize = elf_mod.map_max;
/// The header window a streamed load reads first: an ELF header, its
/// program-header table (≤ 3 records), and a PT_INTERP path — or a
/// DSK1/DSK3 header. Segment PAYLOADS are never staged here; they are
/// streamed straight into the pages that get mapped.
pub const header_window: usize = 16 * 1024;
/// The one fixed buffer the streamed path needs (16 KiB of BSS, versus the
/// 2 MiB the staged path keeps for its own shapes).
var head_buf: [header_window]u8 align(4096) = undefined;
/// Card 3e (claim 4636), slot size lifted by M71m (#1572): at most 8 args,
/// each in a 256-byte slot (255 chars + NUL). An arg that does not fit is
/// refused (`arg_too_long`), never chopped. The gap-layout ELF loader
/// covers the resulting 2048-byte argv block plus the 2048-byte envp block
/// by sizing the writable segment's pages from the block end.
pub const max_exec_args: usize = 8;
pub const arg_slot_bytes: usize = 256;
pub const arg_block_bytes: usize = max_exec_args * arg_slot_bytes; // 2048
/// Issue #1226 (GOOS=virelai envp half): a bounded envp block packed
/// immediately after the gap-path argv block. 16 slots × 128 B holds the
/// kernel shell's whole `env_max` table as `KEY=VALUE` (name ≤ 32, val ≤
/// 64). The gap path sizes the writable segment to cover argv 2048 +
/// envp 2048 = 4096 (one page past the image). DSK1/contiguous ELF paths do not pack envp
/// — same scope as the B2 argv gap-only contract.
pub const max_exec_envs: usize = 16;
pub const env_slot_bytes: usize = 128;
pub const env_block_bytes: usize = max_exec_envs * env_slot_bytes; // 2048
/// Default file name for `exec` with no argument.
pub const default_name: []const u8 = "USER.BIN";
/// elf2bin.py's DSK1 header size (magic/flags/entry/image_size).
pub const dsk1_header_size: usize = 24;
const dsk1_magic: u32 = 0x314b5344; // "DSK1"
/// Milestone sixteen C1 (claim 3805): the segmented user-image header —
/// 48 bytes: magic/flags/entry/image_size + text_size/data_file_size/
/// data_mem_size, followed by [text+rodata][data] (the BSS tail is implicit
/// zero-fill). The loader maps text EL0-RO+PXN and data+bss EL0-RW+UXN+PXN.
pub const dsk3_header_size: usize = 48;
const dsk3_magic: u32 = 0x334b5344; // "DSK3" ("DSK2" 0x324b5344 is the handoff magic)
/// M22 D1 (issue #324): AArch64 ELF executables ("\x7fELF", little-endian).
const elf_magic: u32 = 0x464c457f;

pub const ExecResult = enum {
    ok,
    /// No host file channel (no `--cvc-file` share) — the only app source
    /// since M34 HF6 deleted the ESP app path.
    no_disk,
    /// The named file is absent from the volume (or is a directory).
    not_found,
    /// The FILE itself is larger than the loader accepts at all
    /// (`exec_image_max`, 32 MiB since M70c-K / #1504). Named separately
    /// from `staging_too_large` so the caller can tell "bigger than this
    /// loader takes" from "too big for the path this shape needs": the
    /// streamed gap-layout path is bounded by this one only.
    image_too_large,
    /// This image's shape must transit the 2 MiB staging buffer
    /// (`exec_program_max`) — DSK1, DSK3, the contiguous ELF layout, a
    /// PT_INTERP image, or a four-segment image — and does not fit it.
    /// Distinct from `image_too_large`: a gap-layout Go binary of the same
    /// size streams and is accepted (M70c-K, issue #1504).
    staging_too_large,
    /// The image's own headers promise more MAPPED memory than this loader
    /// will back (`elf.map_max`, 64 MiB since M72a / #1579: every mapped
    /// page is allocated and zero-filled before EL0 runs, so the bound is
    /// RAM). A name of its own because neither size refusal is what
    /// happened: the file is inside the acceptance bound and its shape would
    /// have streamed, and it is a large zero-filled `.bss`/`.noptrbss` (a
    /// 32 MiB FIPS scratch buffer, say) that crossed the line.
    map_too_large,
    /// Not a DSK1 flat program image.
    bad_magic,
    /// entry_offset outside the loaded content.
    bad_entry,
    /// No free scheduler pool slot — the capacity gate (claim 0826).
    pool_full,
    /// The physical page allocator could not supply the program's own
    /// text/stack/exception-stack pages (claim 0826).
    out_of_memory,
    /// More than `max_exec_args` arguments were given (card 3e) — an
    /// honest refusal, never silent truncation of the arg list.
    too_many_args,
    /// One argument is longer than `arg_slot_bytes - 1` (M71m #1572).
    /// Refused, never chopped.
    arg_too_long,
    /// The image leaves no room for the argv block in its text page
    /// (the flat DSK1 path: content + block would overflow the page).
    no_args_room,
    /// The fixed page-table carve-out cannot hold another user-root clone.
    table_full,
    /// The process registry holds only live (created/running) processes —
    /// no free slot and no exited descriptor to recycle.
    process_full,
    /// The `exec -c<core>` pin names a core that is not online (M70b
    /// review): a task pinned to an offline core's ring is unreachable —
    /// `steal_eligible` rejects it on every online core, and that core
    /// never comes up to claim it. Honest refusal beats a stranded task.
    bad_core,
    // M22 D1 (issue #324): honest ELF refusals, one per failure class.
    /// Structurally invalid ELF (bad header, truncated table, entry outside
    /// the initialized text).
    bad_elf,
    /// Not an AArch64 little-endian image.
    unsupported_arch,
    /// The file declares no PT_LOAD program headers.
    no_pt_load,
    /// More than two PT_LOAD segments (the loader maps text + data only).
    too_many_segments,
    /// A segment escapes the load bound/buffer, overlaps the other, or
    /// breaks the W^X / placement contract.
    segment_too_large,
    /// M70c-K (issue #1504): the file ends before the bytes its own header
    /// promises — a truncated copy. Detected twice, reported once: the
    /// header-window parse refuses a payload range past the volume's STAT
    /// size (`elf.file_too_short`), and, if the file shrinks between that
    /// check and the read, the streamed segment read hits EOF. Either way
    /// no half-filled segment is ever mapped. Distinct from the size
    /// refusals (this file is small enough — it is incomplete) and from
    /// `not_found` (the file is present).
    image_truncated,
    /// M113c (#2419, ADR 0054 D8): a grant row names this image but its
    /// measured raw-file SHA-256 does not match the row's — the swapped
    /// binary gets no grant and no baseline (never falls open). A
    /// poisoned (malformed) row and a failed measurement are refused by
    /// the same name.
    grant_stale,
};

/// The loaded program image (BSS, page-aligned so the user root can map the
/// whole page at `userspace.text_va`).
var program: [exec_program_max]u8 align(4096) = undefined;

pub const LoadedInfo = struct {
    name: []const u8,
    /// Content bytes (image minus the 24-byte DSK1 header).
    content_len: usize,
    /// User VA the task enters at.
    entry_va: u64,
    /// The process's OWN randomized user stack VA (claim 0826 — per-process
    /// stacks, so the reply prints this program's placement, not a global).
    stack_va: u64,
    /// Claim 3805 (milestone sixteen C1): the mapped DATA+bss region's byte
    /// length and page count (0 for a flat DSK1 image, which has no
    /// writable segment). The `exec` reply prints these only when non-zero.
    /// M171a (card #3032): `data_pages` is the RESIDENT count
    /// (`datapages=`); `data_map_pages` is the VIRTUAL mapped span
    /// (`mappedpages=`) — equal on the eager paths.
    data_len: u64 = 0,
    data_pages: u64 = 0,
    data_map_pages: u64 = 0,
};

/// Claim 6359 (ADR 0007 slot 28): the pid of the most recently exec'd
/// process, set at the loader's success point. `sys_exec` returns it so an
/// EL0 launcher can hand the new pid to `sys_wait`/a future `sys_kill`.
/// A later exec overwrites it (single-core, exec is synchronous — no
/// interleaving exec can race the read at return time); the EL1h monitor
/// ignores it.
var last_pid: ?usize = null;

/// Claim 6359: the pid the last successful `exec_file` spawned (null
/// before any exec succeeds).
pub fn last_exec_pid() ?usize {
    return last_pid;
}

// ---------------------------------------------------------------------------
// M113c (#2419, ADR 0054 D8): measured exec
// ---------------------------------------------------------------------------

/// The pending exec's measurement + grant outcome. Exec is a synchronous
/// loader (the syscall path holds the FILE|KERNEL domains, the monitor is
/// a single context), so one pending slot suffices — the same discipline
/// `program` and `envp_*` already keep.
var pending_words: u32 = grant.ambient;
var pending_digest: [measure.digest_len]u8 = @as([measure.digest_len]u8, @splat(@as(u8, 0)));
var pending_measured_ok: bool = false;
var pending_name: []const u8 = "";

/// Fixed BSS chunk for the measurement pass — the streamed gap path reads
/// segment payloads straight into mapped pages and never holds the whole
/// file, so the raw-file digest needs its own bounded read either way.
var measure_chunk: [16 * 1024]u8 = undefined;

/// SHA-256 the share file `name` (exactly `size` bytes, per the STAT the
/// caller already took) in bounded chunks through the same channel the
/// loader is about to read. False when a read fails mid-file — the
/// caller treats that as "no digest", which a named row's hash check
/// reads as fail-closed `grant_stale`.
fn measure_image(name: []const u8, size: u64, out: *[measure.digest_len]u8) bool {
    var h = measure.Sha256.init();
    var offset: u64 = 0;
    while (offset < size) {
        const take: usize = @intCast(@min(measure_chunk.len, size - offset));
        const n = virtio_file.read_at_into(name, offset, measure_chunk[0..take]) orelse return false;
        if (n == 0) return false;
        h.update(measure_chunk[0..n]);
        offset += n;
    }
    h.final(out);
    return true;
}

/// Emit one `stage=exec` receipt for the pending measurement (D4). The
/// digest is zeros when the measurement itself failed — readable as
/// "no measurement" in the record.
fn emit_exec_receipt(verdict: []const u8) void {
    var line: [measure.receipt_max]u8 = undefined;
    const n = measure.receipt_line(&line, .exec, &pending_digest, verdict, pending_name, null);
    klog.line(line[0..n]);
}

/// The loader's success point: stamp the process with the grant outcome
/// (word mask + measured digest — word-denial receipts quote it later)
/// and publish the `measured` receipt. A digest-less exec (measurement
/// failed but no row required one) emits `unmeasured` — a stage that was
/// not measured is never reported `measured`.
fn note_exec_grant(proc_id: usize) void {
    process.set_grant(proc_id, pending_words, pending_digest, pending_measured_ok);
    emit_exec_receipt(if (pending_measured_ok) "measured" else "unmeasured");
}

/// The exec-time grant decision, taken once per `exec_file_impl` after
/// the size checks and before any parse or mapping: a matching row
/// applies its words, `grant_stale` refuses by name, and no row leaves
/// the ambient set (M116b — the narrowed floor, not the vocabulary).
/// The `measured` receipt is published at the success
/// point (`note_exec_grant`) — the receipt records a measurement that
/// ran, not one that merely parsed.
fn apply_exec_grant(name: []const u8, size: u64) ExecResult {
    pending_name = name;
    pending_words = grant.ambient;
    pending_digest = @as([measure.digest_len]u8, @splat(@as(u8, 0)));
    pending_measured_ok = measure_image(name, size, &pending_digest);
    switch (grant.decide(name, if (pending_measured_ok) &pending_digest else null)) {
        .ambient => {},
        .apply => |words| pending_words = words,
        .stale => {
            emit_exec_receipt("refused:grant_stale");
            return .grant_stale;
        },
    }
    return .ok;
}

/// What the current process's image is (claim 3848): the descriptor lives
/// in the process registry, so this reads the most recently created
/// process instead of a module-global copy — a later exec never leaves
/// stale "last program" state behind.
pub fn loaded() ?LoadedInfo {
    const id = process.current() orelse return null;
    const info = process.info(id) orelse return null;
    if (info.state == .free) return null;
    return .{
        .name = info.name,
        .content_len = info.content_len,
        .entry_va = info.entry_va,
        .stack_va = info.stack_va,
        .data_len = info.data_len,
        .data_pages = info.data_pages,
        .data_map_pages = info.data_map_pages,
    };
}

/// The first 8 bytes of the LOADED CONTENT for a STREAMED image (M70c-K,
/// issue #1504). That path never touches `program`, so recording them here
/// is what keeps `head()` from reporting another image's staging bytes.
var streamed_head: [8]u8 = @as([8]u8, @splat(@as(u8, 0)));
var streamed_head_valid: bool = false;

/// The first 8 bytes of the LOADED CONTENT (the stripped image's first
/// instruction). Diagnostic: the `exec` reply prints them so a live run can
/// confirm the exact bytes that will execute at EL0. For the staged shapes
/// those bytes are the staging buffer's; a streamed image answers from the
/// page its segment 0 was read into.
pub fn head() [8]u8 {
    if (streamed_head_valid) return streamed_head;
    var out: [8]u8 = undefined;
    @memcpy(out[0..8], program[0..8]);
    return out;
}

/// Pack `args` into a fixed argv block (card 3e, M71m #1572): every slot
/// is 256 bytes, NUL-terminated (the block is zeroed first). A string
/// longer than 255 bytes is refused (`error.ArgTooLong`), never chopped.
/// The caller has already bounded `args.len` to `max_exec_args`. Returns
/// the packed arg count.
pub fn pack_args(args: []const []const u8, block: []u8) error{ArgTooLong}!usize {
    @memset(block, 0);
    for (args, 0..) |arg, i| {
        if (arg.len >= arg_slot_bytes) return error.ArgTooLong;
        const slot = block[i * arg_slot_bytes ..][0..arg_slot_bytes];
        @memcpy(slot[0..arg.len], arg);
    }
    return args.len;
}

/// Pack `entries` (`KEY=VALUE` strings) into a fixed envp block (issue
/// #1226): every slot is 128 bytes, NUL-terminated; a string longer than
/// 127 bytes is truncated. Caller has already bounded `entries.len` to
/// `max_exec_envs`. Returns the packed count.
pub fn pack_env(entries: []const []const u8, block: []u8) usize {
    @memset(block, 0);
    const n = @min(entries.len, max_exec_envs);
    for (entries[0..n], 0..) |e, i| {
        const slot = block[i * env_slot_bytes ..][0..env_slot_bytes];
        const take = @min(e.len, env_slot_bytes - 1);
        @memcpy(slot[0..take], e[0..take]);
    }
    return n;
}

/// Pending envp for the next `exec_file` (kernel shell `set`/`export`
/// snapshot). `set_envp` copies into BSS; `exec_file_impl` consumes it.
var envp_storage: [max_exec_envs][env_slot_bytes]u8 = undefined;
var envp_slices: [max_exec_envs][]const u8 = undefined;
var envp_count: usize = 0;

pub fn set_envp(entries: []const []const u8) void {
    envp_count = 0;
    for (entries) |e| {
        if (envp_count >= max_exec_envs) break;
        const take = @min(e.len, env_slot_bytes - 1);
        @memset(&envp_storage[envp_count], 0);
        @memcpy(envp_storage[envp_count][0..take], e[0..take]);
        envp_slices[envp_count] = envp_storage[envp_count][0..take];
        envp_count += 1;
    }
}

pub fn clear_envp() void {
    envp_count = 0;
}

/// The user VA of the argv block for a loaded program with `content_len`
/// content bytes (the block sits right after the content, 8-aligned, in
/// the program's OWN text page). 0 when the block does not fit.
pub fn argv_va_for(content_len: usize) u64 {
    const block_off = (content_len + 7) & ~@as(usize, 7);
    const page_limit = if (content_len == 0) alloc.page_size else ((content_len + alloc.page_size - 1) / alloc.page_size) * alloc.page_size;
    if (block_off + arg_block_bytes > page_limit or block_off + arg_block_bytes > exec_program_max) return 0;
    return userspace.text_va + block_off;
}

/// Load `name` from the host share OR the ESP, rebuild the user root
/// around it, and spawn it as an EL0t task. `args` (bounded to
/// `max_exec_args`) are packed into the program's text page and passed at
/// entry: `_start` receives argc in x0 and the argv block VA in x1 (card
/// 3e — an entry-contract extension, NOT a syscall; ADR 0007 frozen). See
/// the module doc for the ordered steps.
///
/// M34 HF4 (issue #738): when the host file channel is present the SHARE
/// is the primary app source — a `.ELF` compiled on the host and dropped
/// into the share runs with NO image rebuild (the card's live proof). The
/// ESP stays the fallback (dual path until HF6 deletes the FAT app path),
/// so every default boot is byte-identical.
pub fn exec_file(name: []const u8, args: []const []const u8) ExecResult {
    return exec_file_impl(name, args, null, process.default_principal, null);
}

/// M173b (#3041, ADR 0052 amendment / index D15): the recorded image name
/// the kernel binds the agent principal to — the same name grant rows and
/// the M97g label binding key on, compared case-insensitively (APFS).
pub const agent_image_name = "AGENTD.ELF";

/// The principal an EL0 `sys_exec` spawns. `AGENTD.ELF` by recorded name
/// binds `{uid_agent, 0}` no matter who asks — the binding only narrows,
/// and the EL0 caller can never name a principal anyway. Every other
/// image preserves the caller's principal, so a `uid_agent` parent's
/// children inherit `uid_agent` (index D15) and caps stay 0.
pub fn el0_spawn_principal(name: []const u8, caller: process.Principal) process.Principal {
    if (std.ascii.eqlIgnoreCase(name, agent_image_name)) return process.agent_principal;
    return caller;
}

/// `exec_file` with an explicit spawn principal (M50 TS1, issue #1135,
/// ADR 0024 D2/D5). `exec` preserves the caller's uid/caps by passing them
/// here; the EL1h monitor uses it for an administrative spawn. No EL0 path
/// raises privilege — only the kernel can name a principal.
pub fn exec_file_as(name: []const u8, args: []const []const u8, principal: process.Principal) ExecResult {
    return exec_file_impl(name, args, null, principal, null);
}

/// B1: the syscall has reserved stream references under the file lock.
/// Publish them with the child, never after another core can execute it.
pub fn exec_file_streams_as(name: []const u8, args: []const []const u8, principal: process.Principal, plan: *file_table.StreamPlan) ExecResult {
    return exec_file_impl(name, args, null, principal, plan);
}

/// `exec_file` plus an SMP pin (claim 2369): the spawned task may run ONLY
/// on `pin` (cores 0-3; the `exec -c<core>` monitor flag). Claim 907
/// (#858): `pin = 0` is a LEGAL explicit pin to CORE 0 (secondary_ok off)
/// — the `null` vs `0` distinction is what keeps a plain exec unpinned.
/// Pinned user tasks are safe on a secondary core because console TX is
/// now locked; they stay on their pinned core for their whole lifetime.
pub fn exec_file_pinned(name: []const u8, args: []const []const u8, pin: usize) ExecResult {
    return exec_file_impl(name, args, pin, process.default_principal, null);
}

/// `exec_file_pinned` with an explicit spawn principal (M50 TS1).
pub fn exec_file_pinned_as(name: []const u8, args: []const []const u8, pin: usize, principal: process.Principal) ExecResult {
    return exec_file_impl(name, args, pin, principal, null);
}

fn exec_file_impl(name: []const u8, args: []const []const u8, pin: ?usize, principal: process.Principal, streams: ?*file_table.StreamPlan) ExecResult {
    defer clear_envp();
    // `head()` reports the newest load; a staged exec answers from the
    // staging buffer, so clear the streamed snapshot until one takes one.
    streamed_head_valid = false;
    if (args.len > max_exec_args) return .too_many_args;
    for (args) |arg| {
        if (arg.len >= arg_slot_bytes) return .arg_too_long;
    }
    // M70b review: an offline pin would strand the task forever — pinned
    // tasks bypass every offline gate on the dequeue side (steal_eligible
    // rejects them on every other core). The choke point covers every
    // caller, not just the monitor's own -c parse.
    if (pin) |p| {
        if (p >= smp.max_cores or !smp.core_online[p]) return .bad_core;
    }
    if (name.len == 0) return .not_found;

    // M34 HF6 (issue #740): the host share is the ONLY app source — the
    // ESP app path is gone (fat.zig deleted). STAT for the size, then
    // stream the whole file into the shared staging buffer across READ
    // round trips; a name may exceed FAT's old 8.3 window — the wire
    // allows `virtio_file.path_max`; the process registry truncates long
    // names.
    if (name.len > virtio_file.path_max) return .not_found;
    // M50 TS2 (ADR 0024 D4/D8): the explicit kernel-actor gate — a
    // secret-class path is never loadable (exec must not read SECRETS.TXT).
    if (trust.check(trust.kernel_actor(), .host, name, .read) != .allow) return .not_found;
    if (!virtio_file.available()) return .no_disk;
    var st = virtio_file.StatResult{};
    if (virtio_file.stat(name, &st) != virtio_file.st_ok or st.is_dir) return .not_found;
    if (st.size > exec_image_max) return .image_too_large;
    if (st.size < dsk1_header_size) return .bad_magic;

    // M113c (#2419, ADR 0054 D8): measure BEFORE the first byte is
    // parsed or mapped — the digest is the raw-file SHA-256 the row
    // pins, over the same channel bytes the loader is about to read. A
    // named row whose hash is wrong refuses by name (`grant_stale`) and
    // never falls open; no row means the ambient set (M116b).
    if (apply_exec_grant(name, st.size) == .grant_stale) return .grant_stale;

    // M70c-K (issue #1504): a file too big for the staging buffer is no
    // longer refused outright. `exec_program_max` is a bound of the STAGED
    // shapes below, where the whole file transits `program`; a gap-layout
    // static ELF — every GOOS=virelai Go binary — can instead be loaded by
    // streaming each segment straight from the file into the pages that
    // will be mapped, so its size is bounded by the guest's memory rather
    // than by that array. Read the header window and ask whether this file
    // is that shape; every other oversized file keeps the old refusal, and
    // every file that FITS the staging buffer keeps the old path exactly
    // (byte-identical, one channel read, no extra probe).
    if (st.size > program.len) {
        const head_len = read_head(name, @intCast(@min(st.size, header_window))) orelse return .not_found;
        if (head_len >= 4 and std.mem.readInt(u32, head_buf[0..4], .little) == elf_magic) {
            if (elf_mod.parse_head(head_buf[0..head_len], st.size, elf_mod.text_base)) |image| {
                if (image.gap_layout and image.interp == null) {
                    // M22 D3: crash-trace names follow the program — the
                    // streamed path cannot harvest them from a file it
                    // never stages (the .symtab sits behind a file offset
                    // the header window does not hold), so a streamed image
                    // has no kernel symbol names. A Go binary's own
                    // traceback is unaffected; stated in the M70c-K PR and
                    // in the docs.
                    symbol.reset();
                    return exec_static_elf_gap(name, args, .streamed, image, pin, principal, streams);
                }
                // The shape parses and is under `load_max`, but it is a
                // STAGED shape: DSK1/DSK3 are not ELF at all, a contiguous
                // ELF is copied through `program`, and a PT_INTERP image
                // needs `interp_program` too. Say which bound it missed.
                return .staging_too_large;
            } else |err| {
                // A file whose own header promises bytes the file does not
                // hold is an incomplete copy, not an oversized image.
                if (err == error.file_too_short) return .image_truncated;
                // M72a (issue #1579): an image whose headers promise more
                // mapped memory than `elf.map_max` is refused by THAT
                // bound's name. The fall-through below would have told this
                // file it was "too large for the 0x200000-byte staging
                // buffer (only a gap-layout static ELF streams past it)" —
                // about a gap-layout static ELF that would have streamed.
                if (err == error.map_too_large) return .map_too_large;
                // Any other parse failure falls through to the size refusal:
                // the file was already past `exec_image_max`? no — past the
                // staging buffer, which is all an oversized file of an
                // unusable shape ever got told before this change (the old
                // code refused on size alone, before any parse). Naming a
                // parse error here would be new information; leaving it out
                // keeps the refusal as informative as it was.
            }
        }
        return .staging_too_large;
    }
    const got = virtio_file.read_into(name, st.size, &program) orelse return .not_found;

    if (got < dsk1_header_size) return .bad_magic;
    const magic = std.mem.readInt(u32, program[0..4], .little);
    // Milestone sixteen C1 (claim 3805): two load paths. DSK1 (the flat
    // single-segment shape, kept for the boot-payload-era images and the
    // argv consumers) maps one read-only W^X text page. DSK3 (the segmented
    // shape from `elf2bin.py --segments`) adds a writable data region with a
    // zero-filled BSS tail — the loader maps text EL0-RO+PXN and data+bss
    // EL0-RW+UXN+PXN, so EL0 globals are real writable memory.
    var header_size: usize = dsk1_header_size;
    var entry_off: u64 = 0;
    var image_size: u64 = 0;
    var text_size: usize = 0;
    var data_file_size: usize = 0;
    var data_mem_size: usize = 0;
    // M22 D1: the ELF branch stages the image into the contiguous
    // [text][data] layout itself, so the shared strip below is skipped.
    var pre_staged = false;
    switch (magic) {
        dsk1_magic => {
            entry_off = std.mem.readInt(u64, program[8..16], .little);
            image_size = std.mem.readInt(u64, program[16..24], .little);
            if (image_size > program.len) return .staging_too_large;
            if (image_size > got) return .staging_too_large; // truncated read — file bigger than the buffer
            if (entry_off < dsk1_header_size or entry_off >= image_size) return .bad_entry;
            text_size = @intCast(image_size - dsk1_header_size);
        },
        dsk3_magic => {
            header_size = dsk3_header_size;
            switch (parse_dsk3(&program, got)) {
                .err => |err| return err,
                .ok => |s| {
                    entry_off = s.entry_off;
                    text_size = s.text_size;
                    data_file_size = s.data_file_size;
                    data_mem_size = s.data_mem_size;
                },
            }
        },
        elf_magic => {
            const image = elf_mod.parse(program[0..got]) catch |err| return elf_exec_error(err);
            // M70c-K (issue #1504): the acceptance bound is the PARSER's
            // (`elf.load_max` on the initialized bytes, `elf.map_max` on the
            // mapping), but the CONTIGUOUS shapes below still copy
            // [text][data] through the 2 MiB staging buffer, so a shape it
            // cannot hold is refused by name here instead of tripping a
            // slice past the end of the array.
            //
            // M72a (issue #1579): the GAP shape is not one of those shapes.
            // `exec_static_elf_gap` takes its pages from the physical
            // allocator and copies only each segment's FILE bytes out of
            // `program`, so what a gap image loads through this buffer is
            // `got`, already proven ≤ `program.len`. Charging `mem_total`
            // here (which adds every segment's BSS) refused a ≤2 MiB Go
            // binary that maps 50 MiB, with the same false "staging buffer"
            // message; a gap image's mapping is bounded by `elf.map_max`
            // instead.
            if (!image.gap_layout and elf_mod.mem_total(image) > exec_program_max) return .staging_too_large;
            // M22 D3 (issue #326): crash-report symbol names follow the
            // program — every exec starts from an empty table, then this
            // image's .symtab repopulates it. Harvest BEFORE staging
            // rearranges the buffer (names point into it and the table
            // copies them out immediately).
            symbol.reset();
            var syms: [symbol.max_symbols]elf_mod.SymInfo = undefined;
            const sym_n = elf_mod.collect_symbols(program[0..got], &syms);
            for (syms[0..sym_n]) |si| {
                _ = symbol.add(si.name, si.addr, si.size);
            }

            if (image.interp) |interp_name| {
                // Dynamic ELF executable (claim 7921): load runtime interpreter (LD.SO), setup auxv and shared library aperture.
                return exec_dynamic_elf(name, args, program[0..got], image, interp_name, pin, principal, streams);
            }

            if (image.gap_layout) {
                // Issue #1163 (GOOS=virelai phase 0a): the gc Go linker's
                // [R+X][R][RW] segments sit at 64K-aligned declared vaddrs
                // with gaps — the contiguous staging contract cannot
                // represent them. The gap path maps every segment at its
                // DECLARED vaddr (aperture machinery from the dynamic
                // path); symbols were already collected above.
                return exec_static_elf_gap(name, args, .{ .staged = program[0..got] }, image, pin, principal, streams);
            }

            // The CONTIGUOUS staging contract below represents exactly
            // [text][data]: a third segment has nowhere to go in the buffer
            // and would simply be left out, so such an image is refused by
            // name instead of running with its rodata or data missing.
            // (Gap-layout images — every GOOS=virelai Go binary — never
            // reach here: the branch above maps all three of their
            // segments, streamed or staged.)
            if (image.segment_count > 2) return .staging_too_large;

            const seg0 = image.segments[0];
            // The loader contract (elf.zig): segment 0 sits at
            // userspace.text_va, an optional writable segment 1 directly
            // after its memory image. Stage [text][data] contiguously —
            // exactly the stripped DSK3 shape downstream expects. The copy
            // is forward-safe because parse() rejects overlapping file
            // ranges and every destination offset is below its source.
            text_size = @intCast(seg0.mem_size);
            std.mem.copyForwards(u8, program[0..seg0.file_size], program[seg0.file_offset..][0..seg0.file_size]);
            if (image.segment_count == 2) {
                const seg1 = image.segments[1];
                data_file_size = seg1.file_size;
                data_mem_size = seg1.mem_size;
                std.mem.copyForwards(u8, program[text_size..][0..seg1.file_size], program[seg1.file_offset..][0..seg1.file_size]);
            }
            header_size = seg0.file_offset;
            entry_off = header_size + image.entry_rel;
            pre_staged = true;
        },
        else => return .bad_magic,
    }
    // Claim 0826: the exec gate is GONE — a second program loads and runs
    // while the first is alive (every process owns its own root + pages, so
    // nothing shared is rebuilt under a live task). The gates are capacity:
    // the pool slot FIRST (a full pool fails cheaply and never leaks pages
    // or tables), then the allocator, the table carve-out, the registry.
    if (!scheduler.has_free_slot()) return .pool_full;

    const content_len: usize = text_size;
    // Strip the header IN PLACE (staging): the user root maps whole pages
    // at `text_va` (the clone masks the phys to page granularity), so the
    // loadable content must start at a page boundary. The entry offset is
    // file-relative, so the entry VA is `text_va + (entry_offset - header)`.
    // The stripped buffer layout is [text+rodata][data] for both formats
    // (the data portion is empty for DSK1 — `data_file_size` is 0 there).
    // M22 D1: the ELF branch already staged its contiguous layout, so only
    // the DSK header paths strip here.
    if (!pre_staged) {
        std.mem.copyForwards(u8, program[0 .. text_size + data_file_size], program[header_size..][0 .. text_size + data_file_size]);
    }
    @memset(program[text_size + data_file_size ..], 0); // the rest of the staging page is padding
    // Card 3e (claim 4636): pack the argv block into the staging buffer
    // right after the content (it is copied into the process's OWN text
    // page below — the text leaf is already EL0 read-only, so the block is
    // a read-only leaf with no extra page). The text aperture extends over
    // the block, so uaccess reads it (copy_in ok) and writes to it fault
    // (copy_out → EFAULT). A no-args exec packs nothing and keeps the
    // byte-identical text aperture of earlier cards.
    const argc = args.len;
    var argv_va: u64 = 0;
    var text_len: usize = content_len;
    // DSK3 (and ELF): the offset of the argv block inside the WRITABLE data
    // region (0 = no argv / DSK1 — the flat path packs into the text page).
    var argv_data_off: usize = 0;
    if (argc > 0) {
        if (magic == dsk1_magic) {
            // Card 3e (claim 4636): the flat path packs the block into the
            // process's OWN text page right after the content — the text leaf
            // is already EL0 read-only, so the block is a read-only leaf with
            // no extra page.
            const block_off = (content_len + 7) & ~@as(usize, 7);
            const page_limit = if (content_len == 0) alloc.page_size else ((content_len + alloc.page_size - 1) / alloc.page_size) * alloc.page_size;
            if (block_off + arg_block_bytes > page_limit or block_off + arg_block_bytes > exec_program_max) return .no_args_room;
            _ = pack_args(args, program[block_off..][0..arg_block_bytes]) catch return .arg_too_long;
            text_len = block_off + arg_block_bytes;
            argv_va = userspace.text_va + block_off;
        } else if (magic == dsk3_magic) {
            // Claim 3805's "later card": a segmented image's text region is
            // page-aligned and its data starts right after, so there is no
            // room in the RX leaf — pack the block into a RESERVED DATA TAIL
            // (after the app's own bss, so no global overlaps it). The data
            // aperture + task uaccess regions grow by arg_block_bytes to
            // cover it; unlike the DSK1 read-only text-leaf block, this one
            // lives in the writable data region (documented — the claim-4636
            // read-only-argv property is DSK1-specific).
            argv_data_off = data_mem_size;
            if (text_size + data_mem_size + arg_block_bytes > exec_program_max) return .no_args_room;
            _ = pack_args(args, program[text_size + argv_data_off ..][0..arg_block_bytes]) catch return .arg_too_long;
            data_mem_size += arg_block_bytes;
            argv_va = userspace.text_va + text_size + argv_data_off;
        } else {
            // ELF images: their text region is fixed by the loader contract.
            return .no_args_room;
        }
    }
    // Claim 0826: per-process pages from the physical allocator — the
    // program's OWN text (1 page), user stack (8 KiB = 2 pages) and EL1
    // exception stack (8 KiB = 2 pages). The process owns them and frees
    // them at reap/recycle; the staging `program` buffer is only a read
    // buffer now, so a later exec of a DIFFERENT file can never overwrite
    // a live program's text. The boot-time static payload keeps its linked
    // `.usertext`/`.userbss` pages instead.
    const text_pages: u64 = (text_len + alloc.page_size - 1) / alloc.page_size;
    const text_phys = alloc.alloc_pages(text_pages) orelse return .out_of_memory;
    // Claim 3805: the segmented image's data+bss pages (0 for a flat DSK1
    // image, which has no writable segment).
    const data_pages: u64 = (data_mem_size + alloc.page_size - 1) / alloc.page_size;
    const data_phys: u64 = if (data_pages > 0) (alloc.alloc_pages(data_pages) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        return .out_of_memory;
    }) else 0;
    const stack_pages: u64 = (scheduler.task_stack_size + alloc.page_size - 1) / alloc.page_size;
    const stack_phys = alloc.alloc_pages(stack_pages) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        return .out_of_memory;
    };
    const kstack_pages: u64 = stack_pages;
    const kstack_phys = alloc.alloc_pages(kstack_pages) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        _ = alloc.free_pages(stack_phys, stack_pages);
        return .out_of_memory;
    };
    // Copy the stripped content (plus the argv block, card 3e) into the
    // process's OWN text page (the identity map keeps the physical address
    // a valid kernel pointer).
    const text_dst: [*]u8 = @ptrFromInt(text_phys);
    @memcpy(text_dst[0..text_len], program[0..text_len]);
    // Claim 3805: copy the initialized data, then zero-fill the BSS tail
    // (the data aperture maps `data_mem_size` bytes; the file only carried
    // `data_file_size` of them).
    if (data_pages > 0) {
        const data_dst: [*]u8 = @ptrFromInt(data_phys);
        if (data_file_size > 0) @memcpy(data_dst[0..data_file_size], program[text_size .. text_size + data_file_size]);
        // Zero the app's own bss (data_file_size .. data_mem_size); a DSK3
        // argv tail (packed at argv_data_off, after the app's bss) is copied
        // AFTER the zeroing so the memset cannot wipe it.
        const bss_end = if (argv_data_off > 0) argv_data_off else data_mem_size;
        if (bss_end > data_file_size) @memset(data_dst[data_file_size..bss_end], 0);
        if (argv_data_off > 0) {
            @memcpy(data_dst[argv_data_off..][0..arg_block_bytes], program[text_size + argv_data_off ..][0..arg_block_bytes]);
        }
    }
    const kstack: []u8 = @as(*[scheduler.task_stack_size]u8, @ptrFromInt(kstack_phys))[0..];
    // Milestone four (claim 2665): ASLR — the loaded program's EL0 stack
    // lands at a per-boot random VA from the seeded CSPRNG (page-aligned,
    // 64 KiB placement granularity, clear of text_va); the per-process
    // uaccess stack region follows via set_stack_va so the program may
    // write from its stack through sys_write. Unseeded (host test /
    // fallback) returns the fixed default, so nothing below ever sees an
    // out-of-band VA. rebuild_user_root runs the whole sequence (randomize
    // → map → clean → re-arm) — shared with the boot-time static payload
    // (claim 3693), which passes the static stack phys instead.
    // Claim 3805: the data aperture maps right after the (page-aligned)
    // text region, matching the linker's `.data` placement at base + text_size.
    const data_va = userspace.text_va + text_size;
    const rebuild = rebuild_user_root_full(text_phys, @intCast(text_len), data_va, data_phys, @intCast(data_mem_size), stack_phys, scheduler.task_stack_size) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        _ = alloc.free_pages(stack_phys, stack_pages);
        _ = alloc.free_pages(kstack_phys, kstack_pages);
        return .table_full;
    };

    const entry_va = userspace.text_va + (entry_off - header_size);
    // Milestone four (claim 3848): the loaded program is a PROCESS. The
    // descriptor owns the image + the rebuilt address space + the owned
    // pages; a later exec creates a NEW process (per-process identity)
    // instead of overwriting module globals. The process registry is
    // exhausted only when every slot holds a live process (no exited
    // descriptor to recycle) — an honest, distinct failure from the pool
    // being full.
    const proc_id = process.create_as(
        name,
        .{ .entry_va = entry_va, .content_len = content_len },
        .{
            .root_phys = rebuild.root_phys,
            .text_va = userspace.text_va,
            .text_len = @intCast(text_len),
            .text_phys = text_phys,
            .text_pages = text_pages,
            .data_va = data_va,
            .data_len = @intCast(data_mem_size),
            .data_phys = data_phys,
            .data_pages = data_pages,
            // M171a: this path still backs the whole span eagerly —
            // resident and virtual are the same count here.
            .data_map_pages = data_pages,
            .stack_va = rebuild.stack_va,
            .stack_len = scheduler.task_stack_size,
            .stack_phys = stack_phys,
            .stack_pages = stack_pages,
        },
        .{ .phys = kstack_phys, .pages = kstack_pages },
        principal,
    ) orelse {
        // #2430: the built root's whole table subtree returns to the
        // carve-out too — it owns no descriptor, so nothing else can.
        _ = mmu.free_table_tree(rebuild.root_phys);
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        _ = alloc.free_pages(stack_phys, stack_pages);
        _ = alloc.free_pages(kstack_phys, kstack_pages);
        return .process_full;
    };
    // Card 3f (claim 5965): the new process's IPC ring starts clean — a
    // recycled process id must never inherit an earlier occupant's queued
    // messages (cross-process isolation at the mailbox level). Card E1: same
    // for event queue.
    mailbox.reset(proc_id);
    events.reset(proc_id);
    file_table.reset_process(proc_id);
    app_timers.reset(proc_id); // claim 7323: a recycled pid inherits no stale app timer
    if (scheduler.register_exec_user_pinned(entry_va, rebuild.root_phys, @intCast(text_len), rebuild.stack_va, scheduler.task_stack_size, kstack, @intCast(argc), argv_va, 0, pin)) |task_id| {
        // M32 WMS5 Gate 2 (claim 4278): a segmented (DSK3) image's writable
        // data+bss segment must be in the task's per-process uaccess
        // regions, like the dynamic-ELF path does below (the module-global
        // `uaccess.add_*_region` in `rebuild_user_root_full` is re-armed
        // away at every SVC entry by `handle_svc`, so the TCB copy is the
        // one that survives). Without it, `sys_wait_event`'s copy_out to a
        // buffer inside the data segment EFAULTs forever and a segmented
        // program with globals spins instead of blocking.
        if (data_mem_size > 0) {
            // Fresh task: extras are empty, these cannot overflow (24 slots).
            if (!scheduler.add_task_read_region(task_id, .{ .base = data_va, .len = data_mem_size })) return .pool_full;
            if (!scheduler.add_task_write_region(task_id, .{ .base = data_va, .len = data_mem_size })) return .pool_full;
        }
        _ = process.bind(proc_id, task_id);
        process.set_spawner(proc_id, scheduler.spawn_provenance(task_id).parent);
        // M70b (#1454): the pin is part of the registration (set while the
        // task is still `.blocked`) and the task only becomes visible to
        // the cores at publish — a parked remote core can claim it the
        // instant it lands on a ring, so a post-publish `pin_task` would
        // lose that race (observed: an `exec -c0` hammer running on a
        // secondary forever).
        if (streams) |plan| file_table.commit_streams(proc_id, plan);
        scheduler.publish_task(task_id);
    } else {
        // Defensive rollback (the upfront slot check makes this
        // unreachable): the process reap frees its owned pages.
        _ = process.reap(proc_id);
        return .pool_full;
    }
    // Claim 6359 (slot 28 `sys_exec`): record the spawned pid at the true
    // success point so the EL0 caller can read it back.
    last_pid = proc_id;
    note_exec_grant(proc_id);
    return .ok;
}

/// Read UP TO `limit` bytes of `name` into `head_buf` and report how many
/// arrived: the loader's head probe. Unlike `virtio_file.read_at_into` a
/// short file is not a failure here — the header window only has to hold
/// the ELF header and the program-header table, and a file that vanished or
/// shrank mid-flight is diagnosed by the caller (a parse that cannot
/// complete, or a streamed segment read that hits EOF). Returns null only
/// when the channel itself refuses.
fn read_head(name: []const u8, limit: usize) ?usize {
    var done: usize = 0;
    while (done < limit) {
        const rc = virtio_file.read_chunk(name, done, head_buf[done..limit]);
        if (rc.status != virtio_file.st_ok) return null;
        if (rc.bytes == 0) break; // EOF: parse what actually arrived
        done += rc.bytes;
    }
    return done;
}

/// Where a gap-layout ELF's segment payloads come from. `staged` is the
/// classic path (the whole file is in `program`); `streamed` is M70c-K
/// (issue #1504): each segment is read straight from the file into the
/// pages that will be mapped, so image size is bounded by the guest's
/// memory rather than by a staging array.
const ImageSource = union(enum) {
    staged: []const u8,
    streamed,
};

/// Issue #1163 (GOOS=virelai phase 0a): static-ELF GAP layout — every
/// PT_LOAD is mapped at its DECLARED page-aligned vaddr (segment 0 at the
/// fixed text aperture, `elf.text_base`), with the parser-enforced W^X
/// shape [R+X][R]…[RW]. The gc Go linker emits exactly this (its segments
/// are 64K-aligned with gaps), which the contiguous staging contract
/// cannot represent. Mirrors the dynamic path's aperture machinery minus
/// interpreter/library staging. Issue #1163 B2: takes the card-3e argv
/// contract — the block (prepended program name + args) packs into the
/// writable segment's reserved tail page, and the GOOS rt0 stub converts
/// it to a SysV char* array for rt0_go.
///
/// M70c-K (issue #1504): `src` selects where each segment's payload comes
/// from. `streamed` is the whole point of the card — segment bytes go from
/// the file channel straight into the physical pages that are about to be
/// mapped, so there is no per-image staging buffer and the declared-vaddr
/// aperture machinery below is untouched by the change (the page count and
/// placement of a given image are identical either way).
fn exec_static_elf_gap(
    name: []const u8,
    args: []const []const u8,
    src: ImageSource,
    image: elf_mod.Image,
    pin: ?usize,
    principal: process.Principal,
    streams: ?*file_table.StreamPlan,
) ExecResult {
    // Issue #1163 B2 (phase 0b): ELF images take the card-3e argv contract.
    // Go's os.Args[0] is the program name, so the block is
    // [<name>, args...] (the DSK1 flat path keeps its own convention —
    // untouched). Bounded to max_exec_args slots like every other path.
    var argv_list: [max_exec_args][]const u8 = undefined;
    if (1 + args.len > max_exec_args) return .too_many_args;
    argv_list[0] = name;
    for (args, 1..) |a, i| argv_list[i] = a;
    const argc: usize = 1 + args.len;
    // The block lives in the LAST (writable) segment's mapped tail; a
    // single-segment (text-only) image has nowhere writable to host it.
    if (image.segment_count < 2 and argc > 1) return .no_args_room;
    if (!scheduler.has_free_slot()) return .pool_full;

    // Per-segment physical backing (issue #1163): segment i's pages are
    // owned by the process and freed at reap. Segment 0 is the text
    // aperture (vaddr == elf.text_base, parser-enforced); middle segments
    // are read-only rodata; the last is the writable data segment.
    var seg_phys: [elf_mod.max_segments]u64 = @splat(0);
    var seg_pages: [elf_mod.max_segments]u64 = @splat(0);
    // M171a (card #3032): per-segment page geometry. `seg_file` is the
    // file-backed run the loader reads into; `seg_pages` the RESIDENT
    // total (the file run plus the argv/envp run — the only pages
    // allocated and filled at exec); `seg_span` the VIRTUAL mapped span
    // (page-rounded p_memsz plus argv headroom); `seg_run` the VA-page
    // index where the second resident run begins (`== seg_span` when
    // there is none). The pages in [seg_file, min(memsz pages, seg_run))
    // are the demand-zero tail — `zero_*` records it for registration as
    // an image demand region once the descriptor exists.
    var seg_file: [elf_mod.max_segments]u64 = @splat(0);
    var seg_span: [elf_mod.max_segments]u64 = @splat(0);
    var seg_run: [elf_mod.max_segments]u64 = @splat(0);
    var zero_base: [elf_mod.max_segments]u64 = @splat(0);
    var zero_len: [elf_mod.max_segments]u64 = @splat(0);
    var zero_prot: [elf_mod.max_segments]u64 = @splat(0);
    var allocated: usize = 0;
    const last_seg_i = image.segment_count - 1;
    const streaming = switch (src) {
        .streamed => true,
        .staged => false,
    };
    while (allocated < image.segment_count) : (allocated += 1) {
        const seg = image.segments[allocated];
        const file_pages: u64 = (seg.file_size + alloc.page_size - 1) / alloc.page_size;
        const mem_pages: u64 = (seg.mem_size + alloc.page_size - 1) / alloc.page_size;
        var pages: u64 = mem_pages;
        // M71m (#1572): the argv+envp block is 8×256 + 16×128 = 4096 bytes,
        // placed at align8(mem_size). Size this segment to cover that end
        // instead of requiring the block to fit in the image's own tail
        // slack. For a 4096-byte block the cover is one page past the
        // image: exactly 4096 bytes when mem_size is page-aligned, and
        // 8192 − r bytes past align8(mem_size) otherwise
        // (r = mem_size mod 4096). M171a: `argv_first` is the VA page the
        // block starts in — the run [argv_first, cover) stays RESIDENT
        // even where it overlaps what would otherwise be the demand tail.
        var argv_first: u64 = mem_pages;
        if (allocated == last_seg_i and argc > 0) {
            const block_off: u64 = (seg.mem_size + 7) & ~@as(u64, 7);
            const need: u64 = block_off + arg_block_bytes + env_block_bytes;
            const cover: u64 = (need + alloc.page_size - 1) / alloc.page_size;
            argv_first = block_off / alloc.page_size;
            if (cover > pages) pages = cover;
        }
        if (pages == 0) continue;
        // The resident allocation is ONE contiguous run: the file pages,
        // then the pages the argv run contributes (the argv run's own
        // first page may already be inside the file run, hence @max).
        const run_page = @max(argv_first, file_pages);
        const eager: u64 = file_pages + (pages -| run_page);
        seg_file[allocated] = file_pages;
        seg_span[allocated] = pages;
        seg_run[allocated] = run_page;
        const tail_end = @min(mem_pages, run_page);
        if (tail_end > file_pages) {
            zero_base[allocated] = seg.vaddr + file_pages * alloc.page_size;
            zero_len[allocated] = (tail_end - file_pages) * alloc.page_size;
            // W^X, mirroring the aperture permissions: text R+X, a middle
            // rodata segment R, the last (writable) segment R+W.
            zero_prot[allocated] = if (allocated == 0) 5 else if (allocated == last_seg_i) 3 else 1;
        }
        if (eager == 0) continue;
        const phys = alloc.alloc_pages(eager) orelse {
            var j: usize = 0;
            while (j < allocated) : (j += 1) {
                if (seg_pages[j] > 0) _ = alloc.free_pages(seg_phys[j], seg_pages[j]);
            }
            return .out_of_memory;
        };
        seg_phys[allocated] = phys;
        seg_pages[allocated] = eager;
        const dst: [*]u8 = @ptrFromInt(phys);
        if (seg.file_size > 0) {
            const payload = dst[0..seg.file_size];
            if (streaming) {
                if (virtio_file.read_at_into(name, seg.file_offset, payload) == null) {
                    // The file is shorter than its own header promises (or
                    // the channel died): free everything this load took and
                    // refuse by name — never map a half-filled segment.
                    var j: usize = 0;
                    while (j <= allocated) : (j += 1) {
                        if (seg_pages[j] > 0) _ = alloc.free_pages(seg_phys[j], seg_pages[j]);
                    }
                    return .image_truncated;
                }
            } else {
                @memcpy(payload, src.staged[seg.file_offset..][0..seg.file_size]);
            }
        }
        // Zero only what is RESIDENT: the file run's tail past p_filesz
        // (BSS bytes that share the last file page), and — for the last
        // segment — the argv run's whole span (BSS bytes the block's page
        // carries below the block; the block itself is re-zeroed at pack
        // time). Everything between is the demand tail.
        if (seg.mem_size > seg.file_size)
            @memset(dst[seg.file_size..@min(seg.mem_size, file_pages * alloc.page_size)], 0);
        if (pages > run_page)
            @memset(dst[file_pages * alloc.page_size ..][0 .. (pages - run_page) * alloc.page_size], 0);
    }
    // `head()` is a diagnostic the `exec` reply prints: for a streamed image
    // take it from the page segment 0 was just read into, so the line reports
    // THIS image's first instruction rather than the staging buffer's
    // leftovers (M70c-K, issue #1504).
    if (streaming and image.segments[0].file_size >= 8) {
        const text_src: [*]const u8 = @ptrFromInt(seg_phys[0]);
        @memcpy(&streamed_head, text_src[0..8]);
        streamed_head_valid = true;
    }

    const stack_pages: u64 = (scheduler.task_stack_size + alloc.page_size - 1) / alloc.page_size;
    const stack_phys = alloc.alloc_pages(stack_pages) orelse {
        var j: usize = 0;
        while (j < image.segment_count) : (j += 1) {
            if (seg_pages[j] > 0) _ = alloc.free_pages(seg_phys[j], seg_pages[j]);
        }
        return .out_of_memory;
    };
    const kstack_pages: u64 = stack_pages;
    const kstack_phys = alloc.alloc_pages(kstack_pages) orelse {
        var j: usize = 0;
        while (j < image.segment_count) : (j += 1) {
            if (seg_pages[j] > 0) _ = alloc.free_pages(seg_phys[j], seg_pages[j]);
        }
        _ = alloc.free_pages(stack_phys, stack_pages);
        return .out_of_memory;
    };

    // B2: pack the argv block into the writable segment's reserved tail
    // (after the image's own bss; the page was allocated above and must be
    // zeroed before packing — fresh allocator pages are not zeroed).
    // Issue #1226: the envp block sits immediately after argv (same extra
    // page). rt0 converts both to the SysV argv/NULL/envp/NULL layout.
    var argv_va: u64 = 0;
    const last_seg = image.segments[image.segment_count - 1];
    if (argc > 0 and image.segment_count >= 2) {
        const last_phys = seg_phys[image.segment_count - 1];
        const last_span = seg_span[image.segment_count - 1];
        const block_off: u64 = (last_seg.mem_size + 7) & ~@as(u64, 7);
        if (block_off + arg_block_bytes + env_block_bytes > last_span * alloc.page_size) return .no_args_room;
        // M171a: the block lives in the argv run — inside the file run's
        // own pages when block_off precedes the run boundary, else in the
        // run's pages (which are physically contiguous right after the
        // file run). The demand tail in between is NOT resident.
        const run_bytes = seg_run[image.segment_count - 1] * alloc.page_size;
        const block_dst_off: u64 = if (block_off >= run_bytes)
            seg_file[image.segment_count - 1] * alloc.page_size + (block_off - run_bytes)
        else
            block_off;
        const block_dst: [*]u8 = @ptrFromInt(last_phys + block_dst_off);
        @memset(block_dst[0..arg_block_bytes], 0);
        _ = pack_args(argv_list[0..argc], block_dst[0..arg_block_bytes]) catch {
            var j: usize = 0;
            while (j < image.segment_count) : (j += 1) {
                if (seg_pages[j] > 0) _ = alloc.free_pages(seg_phys[j], seg_pages[j]);
            }
            _ = alloc.free_pages(stack_phys, stack_pages);
            _ = alloc.free_pages(kstack_phys, kstack_pages);
            return .arg_too_long;
        };
        argv_va = last_seg.vaddr + block_off;
        const env_dst: [*]u8 = @ptrFromInt(last_phys + block_dst_off + arg_block_bytes);
        @memset(env_dst[0..env_block_bytes], 0);
        _ = pack_env(envp_slices[0..envp_count], env_dst[0..env_block_bytes]);
    }

    // Initial stack placement (per-process ASLR, claim 2665) and the
    // TTBR0 multi-aperture root: one aperture per PT_LOAD at its declared
    // vaddr with the parser-validated permissions, plus the user stack.
    const stack_va = csprng.random_stack_va();
    userspace.set_stack_va(stack_va);
    var aps: [2 + elf_mod.max_segments]mmu.UserAperture = undefined;
    var ap_count: usize = 0;
    for (image.segments[0..image.segment_count], 0..) |seg, i| {
        if (seg_span[i] == 0) continue;
        // W^X (parser-enforced): only the LAST segment is writable,
        // and a single-segment image is text-only (never writable).
        const writable = image.segment_count > 1 and i == image.segment_count - 1;
        const executable = i == 0;
        // M171a: the RESIDENT runs only — the demand-zero tail is
        // deliberately absent from the apertures so its first touch
        // faults through populate_user_page.
        if (seg_file[i] > 0) {
            aps[ap_count] = .{
                .va_start = seg.vaddr,
                .va_end = seg.vaddr + seg_file[i] * alloc.page_size,
                .phys = seg_phys[i],
                .writable = writable,
                .executable = executable,
            };
            ap_count += 1;
        }
        if (seg_span[i] > seg_run[i]) {
            aps[ap_count] = .{
                .va_start = seg.vaddr + seg_run[i] * alloc.page_size,
                .va_end = seg.vaddr + seg_span[i] * alloc.page_size,
                .phys = seg_phys[i] + seg_file[i] * alloc.page_size,
                .writable = writable,
                .executable = executable,
            };
            ap_count += 1;
        }
    }
    aps[ap_count] = .{
        .va_start = stack_va,
        .va_end = stack_va + scheduler.task_stack_size,
        .phys = stack_phys,
        .writable = true,
        .executable = false,
    };
    ap_count += 1;

    const root_phys = mmu.build_user_root_apertures(aps[0..ap_count]) orelse {
        var j: usize = 0;
        while (j < image.segment_count) : (j += 1) {
            if (seg_pages[j] > 0) _ = alloc.free_pages(seg_phys[j], seg_pages[j]);
        }
        _ = alloc.free_pages(stack_phys, stack_pages);
        _ = alloc.free_pages(kstack_phys, kstack_pages);
        return .table_full;
    };
    mmu.clean_table_storage();
    for (image.segments[0..image.segment_count], 0..) |_, i| {
        if (seg_pages[i] > 0) mmu.clean_dcache_range(seg_phys[i], seg_pages[i] * alloc.page_size);
    }

    const seg0 = image.segments[0];
    const last = image.segments[image.segment_count - 1];
    const text_len_pages = seg_span[0] * alloc.page_size;
    // Issue #1163 I1 (review pass): a single-segment GAP image is legal
    // (the parser accepts any sane declared base), and there `last ==`
    // `seg0` — aliasing the text allocation into `.data_*` would free the
    // SAME pages twice at reap and register the R+X text as a copy-out
    // WRITE region. Data exists only when there is more than one segment.
    const has_data = image.segment_count > 1;
    // Re-arm the global uaccess view (replaced at every SVC entry by the
    // task TCB copy): text + stack baseline, then per-task extras below.
    syscall.set_user_regions(.{ .base = seg0.vaddr, .len = text_len_pages }, .{ .base = stack_va, .len = scheduler.task_stack_size });

    const entry_va = seg0.vaddr + image.entry_rel;
    const proc_id = process.create_as(
        name,
        .{ .entry_va = entry_va, .content_len = seg0.mem_size },
        .{
            .root_phys = root_phys,
            .text_va = seg0.vaddr,
            .text_len = seg0.mem_size,
            .text_phys = seg_phys[0],
            .text_pages = seg_pages[0],
            .data_va = if (has_data) last.vaddr else 0,
            .data_len = if (has_data) last.mem_size else 0,
            .data_phys = if (has_data) seg_phys[image.segment_count - 1] else 0,
            .data_pages = if (has_data) seg_pages[image.segment_count - 1] else 0,
            .data_map_pages = if (has_data) seg_span[image.segment_count - 1] else 0,
            .stack_va = stack_va,
            .stack_len = scheduler.task_stack_size,
            .stack_phys = stack_phys,
            .stack_pages = stack_pages,
            // Issue #1163: the gap layout's middle read-only segment
            // (rodata) — freed with the rest at reap. Issue #1214: the
            // segment's VA rides along so mmap_collides can protect it.
            .ro_phys = if (image.segment_count == 3) seg_phys[1] else 0,
            .ro_pages = if (image.segment_count == 3) seg_pages[1] else 0,
            .ro_va = if (image.segment_count == 3) image.segments[1].vaddr else 0,
            .ro_len = if (image.segment_count == 3) image.segments[1].mem_size else 0,
            // Issue #1214 review / #1226: the packed argv+envp region's
            // end — the data aperture collision bound extends through it,
            // so the sbrk heap cannot swallow a block that starts on the
            // headroom page (an exactly page-aligned `mem_size`).
            .argv_end_va = if (argv_va != 0) argv_va + arg_block_bytes + env_block_bytes else 0,
        },
        .{ .phys = kstack_phys, .pages = kstack_pages },
        principal,
    ) orelse {
        // #2430: free the built root's table subtree as well as the pages.
        _ = mmu.free_table_tree(root_phys);
        var j: usize = 0;
        while (j < image.segment_count) : (j += 1) {
            if (seg_pages[j] > 0) _ = alloc.free_pages(seg_phys[j], seg_pages[j]);
        }
        _ = alloc.free_pages(stack_phys, stack_pages);
        _ = alloc.free_pages(kstack_phys, kstack_pages);
        return .process_full;
    };

    // M171a (card #3032): publish the demand-zero tails BEFORE the task
    // can run — every PT_LOAD's unbacked span, one region per segment so
    // `max_zero_regions` suffices by construction. A refusal is a
    // registry-invariant break, unwound like the create failure.
    for (0..image.segment_count) |i| {
        if (zero_len[i] == 0) continue;
        if (!process.add_zero_region(proc_id, zero_base[i], zero_len[i], zero_prot[i])) {
            _ = process.reap(proc_id);
            return .process_full;
        }
    }

    mailbox.reset(proc_id);
    events.reset(proc_id);
    file_table.reset_process(proc_id);
    app_timers.reset(proc_id);

    const kstack: []u8 = @as(*[scheduler.task_stack_size]u8, @ptrFromInt(kstack_phys))[0..];
    // Review fix 2: the block only exists when the argv page was reserved
    // (a writable segment exists). A single-segment gap image would
    // otherwise enter EL0 with x0=1 / x1=0 and rt0 would dereference argv
    // at address 0. Consistent contract: argc==0 <=> argv_va==0.
    const entry_argc: u64 = if (argv_va != 0) @intCast(argc) else 0;
    if (scheduler.register_exec_user_pinned(entry_va, root_phys, @intCast(text_len_pages), stack_va, scheduler.task_stack_size, kstack, entry_argc, argv_va, 0, pin)) |task_id| {
        // Middle (rodata) segments are readable through syscalls; the
        // writable data segment is readable AND writable. The text and
        // stack regions were set by register_exec_user itself.
        if (image.segment_count == 3) {
            const ro = image.segments[1];
            // M171a: the VIRTUAL span — syscall copies into the demand
            // tail must reach populate_user_page, not EFAULT.
            if (!scheduler.add_task_read_region(task_id, .{ .base = ro.vaddr, .len = seg_span[1] * alloc.page_size })) return .pool_full;
        }
        // I1: data regions only for a REAL data segment — with one
        // segment the text is already covered by the task's text region,
        // and it must never appear as a copy-out write destination.
        if (has_data and last.mem_size > 0) {
            if (!scheduler.add_task_read_region(task_id, .{ .base = last.vaddr, .len = seg_span[image.segment_count - 1] * alloc.page_size })) return .pool_full;
            if (!scheduler.add_task_write_region(task_id, .{ .base = last.vaddr, .len = seg_span[image.segment_count - 1] * alloc.page_size })) return .pool_full;
        }
        // register_exec_user hardcodes the task text region at
        // userspace.text_va; the gap layout's declared base differs (the
        // Go linker places headers one page below -T), so re-point it.
        scheduler.set_task_text_region(task_id, seg0.vaddr, text_len_pages);
        _ = process.bind(proc_id, task_id);
        process.set_spawner(proc_id, scheduler.spawn_provenance(task_id).parent);
        // M70b (#1454): pin-before-publish — see the flat-image path above.
        if (streams) |plan| file_table.commit_streams(proc_id, plan);
        scheduler.publish_task(task_id);
    } else {
        _ = process.reap(proc_id);
        return .pool_full;
    }
    last_pid = proc_id;
    note_exec_grant(proc_id);
    return .ok;
}

fn exec_dynamic_elf(
    name: []const u8,
    args: []const []const u8,
    prog_buf: []const u8,
    image: elf_mod.Image,
    interp_name: []const u8,
    pin: ?usize,
    principal: process.Principal,
    streams: ?*file_table.StreamPlan,
) ExecResult {
    if (!scheduler.has_free_slot()) return .pool_full;

    // Interpreter and library bytes are copied into process-owned pages
    // below; their scratch need not occupy 2 MiB of the flat kernel image.
    // Keep the staging bound unchanged and return the pages on EVERY exit.
    const scratch_pages = (exec_program_max + alloc.page_size - 1) / alloc.page_size;
    const scratch_phys = alloc.alloc_pages(scratch_pages) orelse return .out_of_memory;
    defer _ = alloc.free_pages(scratch_phys, scratch_pages);
    const interp_program: *align(4096) [exec_program_max]u8 = @ptrFromInt(scratch_phys);

    const interp_got = read_host_file(interp_name, interp_program) orelse return .not_found;
    // M97c #2095: the interpreter declares its own base — confine every
    // segment to the user VA window (aligned, below gap_base_max) before
    // its vaddrs become apertures. `parse_at(..., null)` alone would
    // accept a contiguous image at any address, including identity-mapped
    // kernel RAM.
    const interp_image = elf_mod.parse_declared(interp_program[0..interp_got]) catch |err| return elf_exec_error(err);

    // M97c #2097: the shared-library aperture is a fixed pool of
    // lib_slot_bytes slots (ld.so reads one slot per library). A library
    // that does not fit its slot is an honest refusal — never a partial
    // copy that overflows the pool into the neighbour pages.
    if (host_file_size("LIBUI.SO")) |sz| {
        if (sz > lib_slot_bytes) return .staging_too_large;
    }
    if (host_file_size("LIBFONT.SO")) |sz| {
        if (sz > lib_slot_bytes) return .staging_too_large;
    }

    const seg0 = image.segments[0];
    const text_len: usize = seg0.mem_size;
    const text_pages: u64 = (text_len + alloc.page_size - 1) / alloc.page_size;
    const text_phys = alloc.alloc_pages(text_pages) orelse return .out_of_memory;

    const data_file_size: usize = if (image.segment_count == 2) image.segments[1].file_size else 0;
    const data_mem_size: usize = if (image.segment_count == 2) image.segments[1].mem_size else 0;
    const data_pages: u64 = if (data_mem_size > 0) (data_mem_size + alloc.page_size - 1) / alloc.page_size else 0;
    const data_phys: u64 = if (data_pages > 0) (alloc.alloc_pages(data_pages) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        return .out_of_memory;
    }) else 0;

    const interp_seg0 = interp_image.segments[0];
    const interp_text_len: usize = interp_seg0.mem_size;
    const interp_text_pages: u64 = (interp_text_len + alloc.page_size - 1) / alloc.page_size;
    const interp_text_phys = alloc.alloc_pages(interp_text_pages) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        return .out_of_memory;
    };

    const interp_data_file_size: usize = if (interp_image.segment_count == 2) interp_image.segments[1].file_size else 0;
    const interp_data_mem_size: usize = if (interp_image.segment_count == 2) interp_image.segments[1].mem_size else 0;
    const interp_data_pages: u64 = if (interp_data_mem_size > 0) (interp_data_mem_size + alloc.page_size - 1) / alloc.page_size else 0;
    const interp_data_phys: u64 = if (interp_data_pages > 0) (alloc.alloc_pages(interp_data_pages) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        _ = alloc.free_pages(interp_text_phys, interp_text_pages);
        return .out_of_memory;
    }) else 0;

    // M97c/#2099: the shared-library pool is 8 × 64 KiB slots — one per
    // `ld.zig` max_loaded_libs entry — so the linker heap bound and the
    // kernel aperture describe the same window (was 256 KiB / 4 slots:
    // libraries 5-8 staged past the mapped end).
    const lib_pages: u64 = lib_slot_count * lib_slot_bytes / alloc.page_size; // 512 KiB
    const lib_phys = alloc.alloc_pages(lib_pages) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        _ = alloc.free_pages(interp_text_phys, interp_text_pages);
        if (interp_data_pages > 0) _ = alloc.free_pages(interp_data_phys, interp_data_pages);
        return .out_of_memory;
    };

    const stack_pages: u64 = (scheduler.task_stack_size + alloc.page_size - 1) / alloc.page_size;
    const stack_phys = alloc.alloc_pages(stack_pages) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        _ = alloc.free_pages(interp_text_phys, interp_text_pages);
        if (interp_data_pages > 0) _ = alloc.free_pages(interp_data_phys, interp_data_pages);
        _ = alloc.free_pages(lib_phys, lib_pages);
        return .out_of_memory;
    };

    const kstack_pages: u64 = stack_pages;
    const kstack_phys = alloc.alloc_pages(kstack_pages) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        _ = alloc.free_pages(interp_text_phys, interp_text_pages);
        if (interp_data_pages > 0) _ = alloc.free_pages(interp_data_phys, interp_data_pages);
        _ = alloc.free_pages(lib_phys, lib_pages);
        _ = alloc.free_pages(stack_phys, stack_pages);
        return .out_of_memory;
    };

    // Copy program text and data
    const text_dst: [*]u8 = @ptrFromInt(text_phys);
    @memcpy(text_dst[0..seg0.file_size], prog_buf[seg0.file_offset..][0..seg0.file_size]);
    if (seg0.mem_size > seg0.file_size) @memset(text_dst[seg0.file_size..seg0.mem_size], 0);

    if (data_pages > 0) {
        const data_dst: [*]u8 = @ptrFromInt(data_phys);
        if (data_file_size > 0) @memcpy(data_dst[0..data_file_size], prog_buf[image.segments[1].file_offset..][0..data_file_size]);
        @memset(data_dst[data_file_size..data_mem_size], 0);
    }

    // Copy interpreter text and data
    const interp_text_dst: [*]u8 = @ptrFromInt(interp_text_phys);
    @memcpy(interp_text_dst[0..interp_seg0.file_size], interp_program[interp_seg0.file_offset..][0..interp_seg0.file_size]);
    if (interp_seg0.mem_size > interp_seg0.file_size) @memset(interp_text_dst[interp_seg0.file_size..interp_seg0.mem_size], 0);

    if (interp_data_pages > 0) {
        const interp_data_dst: [*]u8 = @ptrFromInt(interp_data_phys);
        if (interp_data_file_size > 0) @memcpy(interp_data_dst[0..interp_data_file_size], interp_program[interp_image.segments[1].file_offset..][0..interp_data_file_size]);
        @memset(interp_data_dst[interp_data_file_size..interp_data_mem_size], 0);
    }

    // Pre-stage shared libraries into lib_phys (R-X shared library aperture
    // at 0x01000000). #2097: every copy is bounded by its 64 KiB slot and by
    // the pool end — the stat preflight above already refused oversized
    // files, this is the last-line check against a file that grew between
    // the stat and the read.
    const lib_dst: [*]u8 = @ptrFromInt(lib_phys);
    const lib_bytes: usize = @intCast(lib_pages * alloc.page_size);
    @memset(lib_dst[0..lib_bytes], 0);
    var lib_offset: usize = 0;
    var lib_overflow = false;
    if (read_host_file("LIBUI.SO", interp_program)) |got| {
        lib_overflow = got > lib_slot_bytes or lib_offset + lib_slot_bytes > lib_bytes;
        if (!lib_overflow) @memcpy(lib_dst[lib_offset..][0..got], interp_program[0..got]);
        lib_offset += lib_slot_bytes;
    }
    if (read_host_file("LIBFONT.SO", interp_program)) |got| {
        lib_overflow = lib_overflow or got > lib_slot_bytes or lib_offset + lib_slot_bytes > lib_bytes;
        if (!lib_overflow) @memcpy(lib_dst[lib_offset..][0..got], interp_program[0..got]);
        lib_offset += lib_slot_bytes;
    }
    if (lib_overflow) {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        _ = alloc.free_pages(interp_text_phys, interp_text_pages);
        if (interp_data_pages > 0) _ = alloc.free_pages(interp_data_phys, interp_data_pages);
        _ = alloc.free_pages(lib_phys, lib_pages);
        _ = alloc.free_pages(stack_phys, stack_pages);
        _ = alloc.free_pages(kstack_phys, kstack_pages);
        return .staging_too_large;
    }

    // Initial stack frame & Auxv setup
    const stack_va = csprng.random_stack_va();
    userspace.set_stack_va(stack_va);
    const stack_bytes: [*]u8 = @ptrFromInt(stack_phys);
    const frame_size: usize = 256;
    const frame_off: usize = scheduler.task_stack_size - frame_size;
    const frame_va: u64 = stack_va + frame_off;
    const frame = stack_bytes[frame_off..scheduler.task_stack_size];
    @memset(frame, 0);

    const argc = args.len;
    std.mem.writeInt(u64, frame[0..8], argc, .little);
    // frame[8..16] = 0 (argv NULL)
    // frame[16..24] = 0 (envp NULL)
    const auxv_entries = [_]elf_mod.AuxvEntry{
        .{ .a_type = elf_mod.at_phdr, .a_val = image.base_vaddr + image.phoff },
        .{ .a_type = elf_mod.at_phent, .a_val = image.phentsize },
        .{ .a_type = elf_mod.at_phnum, .a_val = image.phnum },
        .{ .a_type = elf_mod.at_entry, .a_val = image.base_vaddr + image.entry_rel },
        .{ .a_type = elf_mod.at_base, .a_val = interp_image.base_vaddr },
        .{ .a_type = elf_mod.at_pagesz, .a_val = 4096 },
        .{ .a_type = elf_mod.at_null, .a_val = 0 },
    };
    _ = elf_mod.encode_auxv(frame[24..], &auxv_entries);

    // Build TTBR0 multi-aperture root
    const data_va = userspace.text_va + text_len;
    const lib_va: u64 = 0x0100_0000;
    var aps: [6]mmu.UserAperture = undefined;
    var ap_count: usize = 0;

    // 0: Main text
    aps[ap_count] = .{
        .va_start = userspace.text_va,
        .va_end = userspace.text_va + text_len,
        .phys = text_phys,
        .writable = false,
        .executable = true,
    };
    ap_count += 1;

    // 1: Main data
    if (data_pages > 0) {
        aps[ap_count] = .{
            .va_start = data_va,
            .va_end = data_va + data_mem_size,
            .phys = data_phys,
            .writable = true,
            .executable = false,
        };
        ap_count += 1;
    }

    // 2: Interp text
    aps[ap_count] = .{
        .va_start = interp_image.base_vaddr,
        .va_end = interp_image.base_vaddr + interp_text_len,
        .phys = interp_text_phys,
        .writable = false,
        .executable = true,
    };
    ap_count += 1;

    // 3: Interp data
    if (interp_data_pages > 0) {
        const interp_data_va = interp_image.segments[1].vaddr;
        aps[ap_count] = .{
            .va_start = interp_data_va,
            .va_end = interp_data_va + interp_data_mem_size,
            .phys = interp_data_phys,
            .writable = true,
            .executable = false,
        };
        ap_count += 1;
    }

    // 4: Lib staging pool (R-X shared library text)
    aps[ap_count] = .{
        .va_start = lib_va,
        .va_end = lib_va + lib_pages * alloc.page_size,
        .phys = lib_phys,
        .writable = false,
        .executable = true,
    };
    ap_count += 1;

    // 5: User stack
    aps[ap_count] = .{
        .va_start = stack_va,
        .va_end = stack_va + scheduler.task_stack_size,
        .phys = stack_phys,
        .writable = true,
        .executable = false,
    };
    ap_count += 1;

    const root_phys = mmu.build_user_root_apertures(aps[0..ap_count]) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        _ = alloc.free_pages(interp_text_phys, interp_text_pages);
        if (interp_data_pages > 0) _ = alloc.free_pages(interp_data_phys, interp_data_pages);
        _ = alloc.free_pages(lib_phys, lib_pages);
        _ = alloc.free_pages(stack_phys, stack_pages);
        _ = alloc.free_pages(kstack_phys, kstack_pages);
        return .table_full;
    };

    mmu.clean_table_storage();
    mmu.clean_dcache_range(text_phys, text_len);
    if (data_pages > 0) mmu.clean_dcache_range(data_phys, data_mem_size);
    mmu.clean_dcache_range(interp_text_phys, interp_text_len);
    if (interp_data_pages > 0) mmu.clean_dcache_range(interp_data_phys, interp_data_mem_size);
    mmu.clean_dcache_range(lib_phys, lib_pages * alloc.page_size);
    syscall.set_user_regions(userspace.text_va_region(), userspace.stack_va_region());
    if (data_mem_size > 0) {
        // Fresh process: the module lists were just reset for this task —
        // cannot be full (26 slots vs <= 6 registrations).
        if (!uaccess.add_read_region(.{ .base = data_va, .len = data_mem_size })) return .pool_full;
        if (!uaccess.add_write_region(.{ .base = data_va, .len = data_mem_size })) return .pool_full;
    }
    if (!uaccess.add_read_region(.{ .base = interp_image.base_vaddr, .len = interp_text_pages * alloc.page_size })) return .pool_full;
    if (interp_data_pages > 0 and interp_image.segment_count == 2) {
        const interp_data_va = interp_image.segments[1].vaddr;
        if (!uaccess.add_read_region(.{ .base = interp_data_va, .len = interp_data_pages * alloc.page_size })) return .pool_full;
        if (!uaccess.add_write_region(.{ .base = interp_data_va, .len = interp_data_pages * alloc.page_size })) return .pool_full;
    }
    if (!uaccess.add_read_region(.{ .base = lib_va, .len = lib_pages * alloc.page_size })) return .pool_full;

    const interp_entry_va = interp_image.base_vaddr + interp_image.entry_rel;
    const proc_id = process.create_as(
        name,
        .{ .entry_va = interp_entry_va, .content_len = text_len },
        .{
            .root_phys = root_phys,
            .text_va = userspace.text_va,
            .text_len = @intCast(text_len),
            .text_phys = text_phys,
            .text_pages = text_pages,
            .data_va = data_va,
            .data_len = @intCast(data_mem_size),
            .data_phys = data_phys,
            .data_pages = data_pages,
            // M171a: this path still backs the whole span eagerly —
            // resident and virtual are the same count here.
            .data_map_pages = data_pages,
            .stack_va = stack_va,
            .stack_len = scheduler.task_stack_size,
            .stack_phys = stack_phys,
            .stack_pages = stack_pages,
            .interp_phys = interp_text_phys,
            .interp_pages = interp_text_pages + interp_data_pages,
            .lib_phys = lib_phys,
            .lib_pages = lib_pages,
        },
        .{ .phys = kstack_phys, .pages = kstack_pages },
        principal,
    ) orelse {
        // #2430: free the built root's table subtree as well as the pages.
        _ = mmu.free_table_tree(root_phys);
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        _ = alloc.free_pages(interp_text_phys, interp_text_pages);
        if (interp_data_pages > 0) _ = alloc.free_pages(interp_data_phys, interp_data_pages);
        _ = alloc.free_pages(lib_phys, lib_pages);
        _ = alloc.free_pages(stack_phys, stack_pages);
        _ = alloc.free_pages(kstack_phys, kstack_pages);
        return .process_full;
    };

    mailbox.reset(proc_id);
    events.reset(proc_id);
    file_table.reset_process(proc_id);
    app_timers.reset(proc_id);

    const kstack: []u8 = @as(*[scheduler.task_stack_size]u8, @ptrFromInt(kstack_phys))[0..];
    if (scheduler.register_exec_user_pinned(interp_entry_va, root_phys, @intCast(text_len), stack_va, frame_off, kstack, @intCast(argc), 0, frame_va + 24, pin)) |task_id| {
        if (data_mem_size > 0) {
            if (!scheduler.add_task_read_region(task_id, .{ .base = data_va, .len = data_mem_size })) return .pool_full;
            if (!scheduler.add_task_write_region(task_id, .{ .base = data_va, .len = data_mem_size })) return .pool_full;
        }
        if (!scheduler.add_task_read_region(task_id, .{ .base = interp_image.base_vaddr, .len = interp_text_pages * alloc.page_size })) return .pool_full;
        if (interp_data_pages > 0 and interp_image.segment_count == 2) {
            const interp_data_va = interp_image.segments[1].vaddr;
            if (!scheduler.add_task_read_region(task_id, .{ .base = interp_data_va, .len = interp_data_pages * alloc.page_size })) return .pool_full;
            if (!scheduler.add_task_write_region(task_id, .{ .base = interp_data_va, .len = interp_data_pages * alloc.page_size })) return .pool_full;
        }
        if (!scheduler.add_task_read_region(task_id, .{ .base = lib_va, .len = lib_pages * alloc.page_size })) return .pool_full;
        _ = process.bind(proc_id, task_id);
        process.set_spawner(proc_id, scheduler.spawn_provenance(task_id).parent);
        // M70b (#1454): pin-before-publish — see the flat-image path above.
        if (streams) |plan| file_table.commit_streams(proc_id, plan);
        scheduler.publish_task(task_id);
    } else {
        _ = process.reap(proc_id);
        return .pool_full;
    }
    last_pid = proc_id;
    note_exec_grant(proc_id);
    return .ok;
}

/// M22 D1 (issue #324): map an `elf.parse` refusal onto the exec result —
/// one honest class per failure, matching the issue's message list.
fn elf_exec_error(err: elf_mod.Error) ExecResult {
    return switch (err) {
        error.not_elf,
        error.truncated,
        error.bad_phdr,
        => .bad_elf,
        // M70c-K (issue #1504): the file ends before the bytes its own
        // header promises. One name for both detections (this parse-time
        // one and the streamed read hitting EOF).
        error.file_too_short => .image_truncated,
        error.unsupported_class,
        error.unsupported_endian,
        error.unsupported_machine,
        => .unsupported_arch,
        error.no_load_segments => .no_pt_load,
        error.too_many_segments => .too_many_segments,
        error.bad_entry => .bad_entry,
        // M72a (issue #1579): the mapped-memory bound has its own name on
        // this side too, so the refusal a caller sees matches the bound the
        // image crossed.
        error.map_too_large => .map_too_large,
        error.segment_too_large,
        error.overlapping_segments,
        error.writable_text,
        error.readable_data,
        error.writable_rodata,
        error.unaligned_gap,
        error.gap_too_high,
        error.bad_text_base,
        error.bad_data_base,
        => .segment_too_large,
    };
}

/// Rebuild the EL0 user root around a fresh randomized stack placement
/// (milestone-four ASLR, claims 2665 + 3693): draw a per-boot stack VA
/// from the seeded CSPRNG, map `text_len` bytes of `text_phys` at
/// `userspace.text_va` plus the user stack at the new base (`stack_phys`,
/// `stack_len` bytes), clean the fresh clone tables + mapped text (the
/// walker and EL0 instruction fetch must see the real bytes), and re-arm
/// the syscall/uaccess regions so `sys_write` bounds follow the new base.
/// The single shared sequence for the exec path (the loaded program's own
/// pages, claim 0826) and the boot-time rebuild of the static EL0 payload
/// (claim 3693, which passes the static `.userbss` stack phys).
///
/// `stack_len` must cover the FULL `.userbss` section for the static boot
/// payload: the scheduler's timer-preemption witness sits just past the
/// 8 KiB stack, and its VA is base-relative to the stack, so the rebuilt
/// root must map it too. Exec passes the task stack size (no witness).
///
/// Claim 0826: the rebuilt root is the process's OWN root — `build_user_root`
/// returns its phys, and the caller records it in the process descriptor
/// (and hands it to `register_exec_user`), so a second exec never touches
/// the first process's live root. Returns null when the fixed table
/// carve-out cannot hold another user-root clone (the caller's root is
/// then unchanged).
pub const RootInfo = struct {
    /// Physical root of the freshly built per-process TTBR0 user root.
    root_phys: u64,
    /// The randomized user stack VA mapped in that root.
    stack_va: u64,
};

pub fn rebuild_user_root(text_phys: u64, text_len: u64, stack_phys: u64, stack_len: u64) ?RootInfo {
    return rebuild_user_root_full(text_phys, text_len, 0, 0, 0, stack_phys, stack_len);
}

/// The full rebuild (milestone sixteen C1, claim 3805): like
/// `rebuild_user_root` but with a writable DATA aperture (`data_phys`,
/// `data_len` at `data_va`) mapped between text and stack — the segmented
/// image's `.data` + zeroed `.bss`. `data_len == 0` omits the aperture.
pub fn rebuild_user_root_full(
    text_phys: u64,
    text_len: u64,
    data_va: u64,
    data_phys: u64,
    data_len: u64,
    stack_phys: u64,
    stack_len: u64,
) ?RootInfo {
    const stack_va = csprng.random_stack_va();
    userspace.set_stack_va(stack_va);
    const root_phys = mmu.build_user_root_full(
        userspace.text_va,
        text_phys,
        text_len,
        data_va,
        data_phys,
        data_len,
        stack_va,
        stack_phys,
        stack_len,
    ) orelse return null;
    // The fresh clone tables and the mapped text/data are dirty in the
    // D-cache; clean both before the scheduler's next TTBR0 switch (the
    // walker + EL0 instruction/data fetch must see the real bytes).
    mmu.clean_table_storage();
    mmu.clean_dcache_range(text_phys, text_len);
    if (data_len > 0) mmu.clean_dcache_range(data_phys, data_len);
    // The user stack aperture moved: re-arm the syscall/uaccess regions so
    // sys_write bounds follow the randomized base (per-task re-arming at
    // SVC entry keeps every process's bounds correct, claim 0826).
    syscall.set_user_regions(userspace.text_va_region(), userspace.stack_va_region());
    return .{ .root_phys = root_phys, .stack_va = stack_va };
}

// ---------------------------------------------------------------------------
// Tests (host-side: in-memory FAT fixture; the MMU clone builds an empty
// root on the host, so the tests pin the load/validate/gate/spawn logic)
// ---------------------------------------------------------------------------

const test_allocator = std.testing.allocator;

/// The segmented DSK3 header fields (claim 3805), parsed + validated.
pub const Segments = struct {
    entry_off: u64,
    text_size: usize,
    data_file_size: usize,
    data_mem_size: usize,
};

/// Parse + validate a DSK3 segmented header at the start of `buf` (the
/// first `got` bytes are valid). Pure — no globals — so host tests pin the
/// boundary checks without a FAT fixture (a valid DSK3 image is always
/// ≥ 4 KiB of page-aligned text, above the 2 KiB test write cap).
pub fn parse_dsk3(buf: []const u8, got: usize) union(enum) { ok: Segments, err: ExecResult } {
    const entry_off = std.mem.readInt(u64, buf[8..16], .little);
    const image_size = std.mem.readInt(u64, buf[16..24], .little);
    const text_size: usize = @intCast(std.mem.readInt(u64, buf[24..32], .little));
    const data_file_size: usize = @intCast(std.mem.readInt(u64, buf[32..40], .little));
    const data_mem_size: usize = @intCast(std.mem.readInt(u64, buf[40..48], .little));
    // Order matters: a declared image that did not ARRIVE is a truncated
    // file (the same condition the ELF path names), while one that arrived
    // in full but does not fit the staging buffer is a staging-bound
    // refusal. "Incomplete" is the more specific truth of the two.
    if (image_size > got) return .{ .err = .image_truncated }; // truncated read
    if (image_size > buf.len) return .{ .err = .staging_too_large };
    if (image_size != dsk3_header_size + text_size + data_file_size) return .{ .err = .bad_magic };
    if (text_size == 0 or text_size > exec_program_max) return .{ .err = .staging_too_large };
    if (data_mem_size < data_file_size or data_mem_size > exec_program_max) return .{ .err = .staging_too_large };
    if (entry_off < dsk3_header_size or entry_off >= dsk3_header_size + text_size) return .{ .err = .bad_entry };
    return .{ .ok = .{
        .entry_off = entry_off,
        .text_size = text_size,
        .data_file_size = data_file_size,
        .data_mem_size = data_mem_size,
    } };
}

/// M34 HF6 (issue #740): read a whole file from the HOST SHARE (STAT +
/// chunked READ round trips into `buf`) — the share is the only app and
/// shared-library source. Returns the byte count, or null when absent / a
/// directory / too big for `buf` / the transport is down.
fn read_host_file(name: []const u8, buf: []u8) ?usize {
    if (!virtio_file.available()) return null;
    if (name.len == 0 or name.len > virtio_file.path_max) return null;
    // M50 TS2 (ADR 0024 D4/D8): shared-library reads use the same kernel gate.
    if (trust.check(trust.kernel_actor(), .host, name, .read) != .allow) return null;
    var st = virtio_file.StatResult{};
    if (virtio_file.stat(name, &st) != virtio_file.st_ok or st.is_dir) return null;
    if (st.size > buf.len) return null;
    return virtio_file.read_into(name, st.size, buf);
}

/// M97c #2097: a staged library's on-share size — the stat half of
/// `read_host_file`, so the exec path can refuse an oversized library
/// BEFORE the aperture pages are allocated. Null = absent/unreadable,
/// same as `read_host_file` (an absent library is fine; ld.so falls back
/// to a runtime `sys_file_open`).
fn host_file_size(name: []const u8) ?u64 {
    if (!virtio_file.available()) return null;
    if (name.len == 0 or name.len > virtio_file.path_max) return null;
    if (trust.check(trust.kernel_actor(), .host, name, .read) != .allow) return null;
    var st = virtio_file.StatResult{};
    if (virtio_file.stat(name, &st) != virtio_file.st_ok or st.is_dir) return null;
    return st.size;
}

/// Build a minimal DSK1 flat image: header (entry at offset 24 = content
/// start) + `content`.
fn dsk1(content: []const u8, entry_off: u64, image_size: u64) [dsk1_header_size + 64]u8 {
    var img = @as([(dsk1_header_size + 64)]u8, @splat(@as(u8, 0)));
    std.mem.writeInt(u32, img[0..4], dsk1_magic, .little);
    std.mem.writeInt(u32, img[4..8], 0, .little);
    std.mem.writeInt(u64, img[8..16], entry_off, .little);
    std.mem.writeInt(u64, img[16..24], image_size, .little);
    @memcpy(img[dsk1_header_size..][0..content.len], content);
    return img;
}

/// Test-only share seeding: M34 HF6 (issue #740) — with fat.zig gone the
/// exec host tests serve files through virtio_file's in-memory share
/// override (the ONLY host-testable read seam). The table holds multiple
/// files so the PEER/pool tests can seed COUNTER + PEER + USER together
/// (a single slot silently dropped the first seed); `test_seed` upserts
/// by name so re-seeding USER.BIN with a different image replaces it.
/// Every test that arms MUST restore with `defer virtio_file.set_test_share(null)`
/// — the exec batch imports syscall's tests into the SAME test process,
/// so a leaked armed share flips sys_exec's honest no-disk path into a
/// not_found (the cross-module leak the old end-of-body restore missed).
var test_share_files: [8]virtio_file.TestFile = undefined;
var test_share_n: usize = 0;
fn test_seed(name: []const u8, content: []const u8) void {
    for (test_share_files[0..test_share_n]) |*f| {
        if (std.mem.eql(u8, f.name, name)) {
            f.* = .{ .name = name, .data = content };
            virtio_file.set_test_share(test_share_files[0..test_share_n]);
            return;
        }
    }
    if (test_share_n < test_share_files.len) {
        test_share_files[test_share_n] = .{ .name = name, .data = content };
        test_share_n += 1;
        virtio_file.set_test_share(test_share_files[0..test_share_n]);
    }
}

/// Arm the module physical allocator with a small fixture map, the way the
/// kernel arms it post-boot (claim 0826: exec allocates the program's own
/// pages, so the successful-path tests need a real pool). The pool backs a
/// HOST buffer: exec dereferences the program's text page to load its
/// bytes (`@ptrFromInt(text_phys)` is valid on the identity-mapped kernel,
/// but a fake 0x100000 base would segfault the host tests).
// Milestone sixteen C3 (claim 0339): the pool grew to EIGHT live user
// programs. #1336 raised task_stack_size to 192 KiB (48 pages), so each
// exec owns text 1 + user stack 48 + EL1 kstack 48 = 97 pages. #1426
// filled ten user slots (970 pages) inside 1024. M65d / #1442 fills
// thirteen (1261 pages plus MMU tables) — 2048 pages (8 MiB) covers that.
// M129b (#2611): the pool grew to 64. Exec'd roots are bounded by the
// mmu table carve-out (~20 tables per live root), NOT the pool — the
// saturation tests exec a bounded set and fill the rest with sys_thread
// tasks (48-page kstack each, no new root). 8192 pages covers ten execs
// (~970) plus ~55 thread kstacks (~2640) with margin.
const fixture_pool_pages: usize = 8192;
var fixture_pool: [fixture_pool_pages * 4096]u8 align(4096) = undefined;

fn arm_allocator() void {
    const descriptors = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = @intFromPtr(&fixture_pool), .virtual_start = 0, .number_of_pages = fixture_pool_pages, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&descriptors), @sizeOf(memmap.MemoryDescriptor), descriptors.len);
    _ = alloc.init(view, &.{});
}

/// DSK1 exec page budget (#1336): 1 text page + user stack + EL1 kstack.
fn dsk1_exec_pages() u64 {
    const stack_pages: u64 = (scheduler.task_stack_size + 4095) / 4096;
    return 1 + 2 * stack_pages;
}

/// M129b (#2611): at `max_tasks` = 64 an exec'd process owns ~97 pages
/// plus ~20 tables of the 512-page mmu carve-out, so the carve-out is
/// exec's first wall — the pool itself can only be saturated by
/// `sys_thread` tasks, each of which owns just its 48-page EL1 kstack
/// and shares its process's root (≤ `process.max_threads` extras per
/// process). Spawn one thread per pass across `owners` until the pool
/// is full or every proc is at its thread bound; returns the count.
fn fill_pool_with_threads(owners: []const usize) usize {
    var spawned: usize = 0;
    var pass: usize = 0;
    while (pass < process.max_threads and scheduler.has_free_slot()) : (pass += 1) {
        for (owners) |pid| {
            if (!scheduler.has_free_slot()) break;
            const owner = process.info(pid).?;
            if (scheduler.spawn_thread(owner.task_id.?, owner.text_va, 0x8000_0000, 0) != null) {
                spawned += 1;
            } else break;
        }
    }
    return spawned;
}

/// One RX segment, optionally naming LD.SO, for the dynamic-exec tests.
fn test_dynamic_image(base: u64, interpreter: bool) [512]u8 {
    var img = @as([512]u8, @splat(@as(u8, 0)));
    @memcpy(img[0..4], "\x7fELF");
    img[4] = 2; // ELF64
    img[5] = 1; // little endian
    img[6] = 1;
    std.mem.writeInt(u16, img[16..18], 2, .little); // ET_EXEC
    std.mem.writeInt(u16, img[18..20], 183, .little); // AArch64
    std.mem.writeInt(u32, img[20..24], 1, .little);
    std.mem.writeInt(u64, img[24..32], base + 256, .little);
    std.mem.writeInt(u64, img[32..40], 64, .little);
    std.mem.writeInt(u16, img[52..54], 64, .little);
    std.mem.writeInt(u16, img[54..56], 56, .little);
    std.mem.writeInt(u16, img[56..58], if (interpreter) 2 else 1, .little);
    std.mem.writeInt(u32, img[64..68], 1, .little); // PT_LOAD
    std.mem.writeInt(u32, img[68..72], 5, .little); // R+X
    std.mem.writeInt(u64, img[80..88], base, .little);
    std.mem.writeInt(u64, img[96..104], img.len, .little);
    std.mem.writeInt(u64, img[104..112], 4096, .little);
    std.mem.writeInt(u64, img[112..120], 4096, .little);
    if (interpreter) {
        std.mem.writeInt(u32, img[120..124], 3, .little); // PT_INTERP
        std.mem.writeInt(u64, img[128..136], 232, .little);
        std.mem.writeInt(u64, img[152..160], 6, .little);
        @memcpy(img[232..238], "LD.SO\x00");
    }
    return img;
}

test "exec: dynamic scratch is released on read, parse, and allocation failures" {
    defer virtio_file.set_test_share(null);
    defer test_share_n = 0;
    arm_allocator();
    _ = scheduler.init();
    test_share_n = 0;
    const image = test_dynamic_image(userspace.text_va, true);
    test_seed("DYNAMIC.ELF", &image);
    const free_before = alloc.stats().free_pages;
    try std.testing.expectEqual(ExecResult.not_found, exec_file("DYNAMIC.ELF", &.{}));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);

    test_seed("LD.SO", "not an ELF");
    try std.testing.expectEqual(ExecResult.bad_elf, exec_file("DYNAMIC.ELF", &.{}));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);

    const interpreter = test_dynamic_image(0x0080_0000, false);
    test_seed("LD.SO", &interpreter);
    const scratch_pages = exec_program_max / alloc.page_size;
    const held_pages = free_before - scratch_pages;
    const held = alloc.alloc_pages(held_pages).?;
    defer _ = alloc.free_pages(held, held_pages);
    // Scratch fits exactly, but no page remains for the process text.
    try std.testing.expectEqual(ExecResult.out_of_memory, exec_file("DYNAMIC.ELF", &.{}));
    try std.testing.expectEqual(scratch_pages, alloc.stats().free_pages);
    const extra = alloc.alloc_pages(1).?;
    defer _ = alloc.free_pages(extra, 1);
    // Scratch itself cannot fit; no partial allocation may be retained.
    try std.testing.expectEqual(ExecResult.out_of_memory, exec_file("DYNAMIC.ELF", &.{}));
    try std.testing.expectEqual(scratch_pages - 1, alloc.stats().free_pages);
}

test "exec: dynamic scratch is released after copying interpreter and libraries" {
    defer virtio_file.set_test_share(null);
    defer test_share_n = 0;
    defer mmu.reset();
    arm_allocator();
    _ = scheduler.init();
    test_share_n = 0;
    const image = test_dynamic_image(userspace.text_va, true);
    const interpreter = test_dynamic_image(0x0080_0000, false);
    test_seed("DYNAMIC.ELF", &image);
    test_seed("LD.SO", &interpreter);
    test_seed("LIBUI.SO", "ui library");
    test_seed("LIBFONT.SO", "font library");
    const free_before = alloc.stats().free_pages;
    try std.testing.expectEqual(ExecResult.ok, exec_file("DYNAMIC.ELF", &.{}));
    const info = process.info(last_exec_pid().?).?;
    // The fixture maps one interpreter page and the 128-page (8 × 64 KiB
    // slot) library aperture, in addition to the ordinary process pages.
    const owned_pages = info.text_pages + info.data_pages + 1 +
        lib_slot_count * lib_slot_bytes / alloc.page_size +
        info.stack_pages + info.kernel_stack_pages;
    try std.testing.expectEqual(free_before - owned_pages, alloc.stats().free_pages);
    // Reuse the released scratch and poison it: no process mapping owns it.
    const scratch_pages = exec_program_max / alloc.page_size;
    const scratch = alloc.alloc_pages(scratch_pages).?;
    defer _ = alloc.free_pages(scratch, scratch_pages);
    const scratch_bytes: [*]u8 = @ptrFromInt(scratch);
    @memset(scratch_bytes[0..exec_program_max], 0xa5);
    const interp_leaf = mmu.get_user_leaf(info.root_phys, 0x0080_0000).?.*;
    const interp_bytes: [*]const u8 = @ptrFromInt(interp_leaf & 0x0000_ffff_ffff_f000);
    try std.testing.expectEqualSlices(u8, &interpreter, interp_bytes[0..interpreter.len]);
    const lib_leaf = mmu.get_user_leaf(info.root_phys, 0x0100_0000).?.*;
    const lib_bytes: [*]const u8 = @ptrFromInt(lib_leaf & 0x0000_ffff_ffff_f000);
    try std.testing.expectEqualStrings("ui library", lib_bytes[0..10]);
    try std.testing.expectEqualStrings("font library", lib_bytes[0x10000..][0..12]);
}

test "exec: #2097 — a shared library past its 64 KiB slot is refused" {
    defer virtio_file.set_test_share(null);
    defer test_share_n = 0;
    defer mmu.reset();
    arm_allocator();
    _ = scheduler.init();
    test_share_n = 0;
    const image = test_dynamic_image(userspace.text_va, true);
    const interpreter = test_dynamic_image(0x0080_0000, false);
    test_seed("DYNAMIC.ELF", &image);
    test_seed("LD.SO", &interpreter);
    // One byte past the slot bound — the stat preflight refuses before a
    // single aperture page is allocated or copied.
    const fat = @as([(lib_slot_bytes + 1)]u8, @splat(@as(u8, 0)));
    test_seed("LIBUI.SO", &fat);
    const free_before = alloc.stats().free_pages;
    try std.testing.expectEqual(ExecResult.staging_too_large, exec_file("DYNAMIC.ELF", &.{}));
    try std.testing.expectEqual(free_before, alloc.stats().free_pages);
    // Exactly the bound still stages — the bound is a ceiling, not a fence.
    const exact = @as([lib_slot_bytes]u8, @splat(@as(u8, 0)));
    test_seed("LIBUI.SO", &exact);
    try std.testing.expectEqual(ExecResult.ok, exec_file("DYNAMIC.ELF", &.{}));
}

test "exec: DSK1 header parse rejects bad magic, entry, and oversize images" {
    // Arm the share with an unrelated file so an absent name is a real
    // not_found (no share at all reports no_disk — the next test).
    defer virtio_file.set_test_share(null); // no-disk state on every exit
    test_seed("BOOTED.TXT", "1\n");
    try std.testing.expectEqual(ExecResult.not_found, exec_file("NOPE.BIN", &.{}));

    // Bad magic.
    test_seed("USER.BIN", "NOT A DSK1 IMAGE!");
    try std.testing.expectEqual(ExecResult.bad_magic, exec_file("USER.BIN", &.{}));

    // entry_offset below the 24-byte header (and past the content).
    const bad_entry = dsk1("xx", 4, 24 + 2);
    test_seed("USER.BIN", bad_entry[0 .. 24 + 2]);
    try std.testing.expectEqual(ExecResult.bad_entry, exec_file("USER.BIN", &.{}));
    const bad_entry2 = dsk1("xx", 30, 24 + 2);
    test_seed("USER.BIN", bad_entry2[0 .. 24 + 2]);
    try std.testing.expectEqual(ExecResult.bad_entry, exec_file("USER.BIN", &.{}));

    // image_size beyond the fixed buffer.
    const oversize = dsk1("xx", 24, exec_program_max + 1);
    test_seed("USER.BIN", oversize[0 .. 24 + 2]);
    try std.testing.expectEqual(ExecResult.staging_too_large, exec_file("USER.BIN", &.{}));
}

test "exec: no disk is reported honestly" {
    virtio_file.set_test_share(null);
    try std.testing.expectEqual(ExecResult.no_disk, exec_file("USER.BIN", &.{}));
}

test "exec: DSK3 header validation pins the segment bounds (claim 3805)" {
    var buf: [dsk3_header_size + 4096 + 16]u8 = @as([(dsk3_header_size + 4096 + 16)]u8, @splat(@as(u8, 0)));
    // A valid segmented header: page-aligned 4 KiB text + 8 data + 8 BSS.
    std.mem.writeInt(u32, buf[0..4], dsk3_magic, .little);
    std.mem.writeInt(u64, buf[8..16], dsk3_header_size, .little); // entry at content start
    std.mem.writeInt(u64, buf[16..24], dsk3_header_size + 4096 + 8, .little);
    std.mem.writeInt(u64, buf[24..32], 4096, .little);
    std.mem.writeInt(u64, buf[32..40], 8, .little);
    std.mem.writeInt(u64, buf[40..48], 16, .little);
    const got = buf.len;
    const ok = parse_dsk3(&buf, got).ok;
    try std.testing.expectEqual(@as(u64, dsk3_header_size), ok.entry_off);
    try std.testing.expectEqual(@as(usize, 4096), ok.text_size);
    try std.testing.expectEqual(@as(usize, 8), ok.data_file_size);
    try std.testing.expectEqual(@as(usize, 16), ok.data_mem_size);

    // image_size must equal header + text + data_file (no phantom bytes).
    var bad_image = buf;
    std.mem.writeInt(u64, bad_image[16..24], dsk3_header_size + 4096 + 7, .little);
    try std.testing.expectEqual(ExecResult.bad_magic, parse_dsk3(&bad_image, got).err);

    // A zero text region is not a loadable program.
    var zero_text = buf;
    std.mem.writeInt(u64, zero_text[24..32], 0, .little);
    std.mem.writeInt(u64, zero_text[16..24], dsk3_header_size + 0 + 8, .little);
    try std.testing.expectEqual(ExecResult.staging_too_large, parse_dsk3(&zero_text, got).err);

    // BSS must not be smaller than the initialized data.
    var bad_bss = buf;
    std.mem.writeInt(u64, bad_bss[40..48], 4, .little);
    try std.testing.expectEqual(ExecResult.staging_too_large, parse_dsk3(&bad_bss, got).err);

    // The entry must land inside the RX region.
    var bad_entry = buf;
    std.mem.writeInt(u64, bad_entry[8..16], dsk3_header_size + 4096, .little); // == text end
    try std.testing.expectEqual(ExecResult.bad_entry, parse_dsk3(&bad_entry, got).err);

    // A truncated read (got < image_size) is an honest truncated-image
    // refusal, not a size one: the bytes the header promised never arrived.
    try std.testing.expectEqual(ExecResult.image_truncated, parse_dsk3(&buf, dsk3_header_size + 4096 + 4).err);
}

test "exec: ok path loads, validates, builds the root, and spawns the task" {
    virtio_file.set_test_share(null); // reset any prior test's armed share
    // Restore hardware mode on EVERY exit (success or failure): the exec
    // batch links syscall's tests into the SAME process, so a leaked
    // armed share flips sys_exec's honest no-disk into a not_found.
    defer virtio_file.set_test_share(null);
    arm_allocator();
    // Give the boot user root a real (non-zero) value so the payload's
    // task carries it: the EL1h tasks keep the kernel root (0).
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the static user task (a normal boot's payload exits early),
    // freeing its pool slot for the exec'd program.
    try std.testing.expect(scheduler.yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7)); // user -> idle
    try std.testing.expect(scheduler.reap(2));

    const img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    test_seed("USER.BIN", img[0 .. 24 + 25]);
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    const info = loaded().?;
    try std.testing.expectEqualStrings("USER.BIN", info.name);
    try std.testing.expectEqual(@as(usize, 25), info.content_len);
    try std.testing.expectEqual(userspace.text_va, info.entry_va); // entry at content start
    try std.testing.expect(info.stack_va != 0);
    // The 24-byte DSK1 header is stripped in the staging buffer: the
    // loaded content starts with the program bytes, not "DSK1".
    try std.testing.expectEqualStrings("user: hello from the ESP\n", program[0..25]);
    const h = head();
    try std.testing.expectEqualStrings("user: he", h[0..8]);
    const t = scheduler.task_info(2).?;
    try std.testing.expectEqualStrings("user-exec", t.name);
    try std.testing.expectEqual(@as(u64, 0), t.saves);
    try std.testing.expectEqual(@as(u64, 0), t.resumes);
    // Claim 3848: the exec'd program is a PROCESS — the boot payload's
    // process (exited, status 7) and the new USER.BIN process (bound to
    // the spawned task, carrying the rebuilt address space) both exist.
    try std.testing.expectEqual(@as(usize, 2), process.count());
    // Claim 6359 (slot 28 `sys_exec`): the loader records the spawned pid
    // so an EL0 caller can read it back.
    try std.testing.expectEqual(@as(?usize, 1), last_exec_pid());
    const boot_proc = process.info(0).?;
    try std.testing.expectEqualStrings("user-el0", boot_proc.name);
    try std.testing.expectEqual(process.State.exited, boot_proc.state);
    try std.testing.expectEqual(@as(u64, 7), boot_proc.exit_status);
    const exec_proc = process.info(1).?;
    try std.testing.expectEqualStrings("USER.BIN", exec_proc.name);
    // M50 TS1 (#1135): a plain exec spawns uid_user with no caps.
    try std.testing.expectEqual(process.uid_user, exec_proc.uid);
    try std.testing.expectEqual(@as(u32, 0), exec_proc.caps);
    try std.testing.expectEqual(process.State.running, exec_proc.state);
    try std.testing.expectEqual(@as(?usize, 2), exec_proc.task_id);
    try std.testing.expectEqual(@as(u64, 25), exec_proc.content_len);
    try std.testing.expectEqual(userspace.text_va, exec_proc.entry_va);
    try std.testing.expectEqual(mmu.user_root_phys(), exec_proc.root_phys);
    try std.testing.expectEqual(@as(u64, scheduler.task_stack_size), exec_proc.stack_len);
    // Claim 0826: the process owns its own text/stack/kernel-stack pages
    // from the physical allocator (the boot payload owns none of these).
    // #1336: pages = ceil(task_stack_size / 4 KiB); 192 KiB → 48.
    const stack_pages_expected: u64 = (scheduler.task_stack_size + 4095) / 4096;
    try std.testing.expect(exec_proc.text_phys != 0);
    try std.testing.expectEqual(@as(u64, 1), exec_proc.text_pages);
    try std.testing.expect(exec_proc.stack_phys != 0);
    try std.testing.expectEqual(stack_pages_expected, exec_proc.stack_pages);
    try std.testing.expect(exec_proc.kernel_stack_phys != 0);
    try std.testing.expectEqual(stack_pages_expected, exec_proc.kernel_stack_pages);
    // The loaded bytes landed in the process's OWN text page.
    const text_dst: [*]const u8 = @ptrFromInt(exec_proc.text_phys);
    try std.testing.expectEqualStrings("user: hello from the ESP\n", text_dst[0..25]);
}

test "exec: exec_file_as assigns an explicit principal (M50 TS1)" {
    // M50 TS1 (#1135, ADR 0024 D2/D5): only the kernel can name a spawn
    // principal. `exec_file_as` is the monitor's administrative path; the
    // EL0 sys_exec path preserves the caller instead (no elevation).
    virtio_file.set_test_share(null);
    defer virtio_file.set_test_share(null);
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    try std.testing.expect(scheduler.yield_current()); // shell -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7)); // user -> idle
    try std.testing.expect(scheduler.reap(2));

    const img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    test_seed("USER.BIN", img[0 .. 24 + 25]);
    const sys_principal = process.Principal{ .uid = process.uid_system, .caps = process.kernel_caps };
    try std.testing.expectEqual(ExecResult.ok, exec_file_as("USER.BIN", &.{}, sys_principal));
    const pid = last_exec_pid().?;
    const p = process.info(pid).?;
    try std.testing.expectEqual(process.uid_system, p.uid);
    try std.testing.expectEqual(process.kernel_caps, p.caps);
    // The default exec path stays uid_user/no caps.
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    const plain = process.info(last_exec_pid().?).?;
    try std.testing.expectEqual(process.uid_user, plain.uid);
    try std.testing.expectEqual(@as(u32, 0), plain.caps);
}

test "exec: pinned exec routes the spawned task to exactly one core" {
    // SMP user tasks (claim 2369): `exec -c<core>` (monitor flag) reaches
    // the loader as `exec_file_pinned`, which pins the spawned task so
    // core 0's pick skips it and only the pinned core can run it. This
    // test pins to core 1, checks the TCB, then unpins with a plain exec
    // (the spawned task must be free of the pin).
    virtio_file.set_test_share(null);
    defer virtio_file.set_test_share(null);
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    // M70b: a pin naming an OFFLINE core is refused (.bad_core) — a task
    // pinned to an offline core's ring is unreachable. Bring core 1
    // online so the routing below exercises the pin on a live core
    // (deferred restore: the rest of the suite boots single-core).
    scheduler.smp.core_online[1] = true;
    defer scheduler.smp.core_online[1] = false;
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));
    const img = dsk1("smp1: hello\n", dsk1_header_size, dsk1_header_size + 12);
    test_seed("SMP1.BIN", img[0 .. dsk1_header_size + 12]);
    // M70b review: an offline pin is honestly refused — core 2 is within
    // range but not online here (core 1 was brought online above).
    try std.testing.expectEqual(ExecResult.bad_core, exec_file_pinned("SMP1.BIN", &.{}, 2));
    try std.testing.expectEqual(ExecResult.ok, exec_file_pinned("SMP1.BIN", &.{}, 1));
    const pinned = scheduler.task_info(2).?;
    try std.testing.expectEqualStrings("user-exec", pinned.name);
    try std.testing.expectEqual(@as(usize, 1), pinned.pin_core);
    try std.testing.expect(pinned.secondary_ok); // pin 1: steal-eligible-only-for-core-1
    // Claim 907: `exec -c0` — an explicit pin to CORE 0 (secondary_ok
    // OFF, so no secondary core can steal it). pin_core is 0 for BOTH an
    // explicit core-0 pin and an unpinned task — secondary_ok is the
    // distinguishing field.
    try std.testing.expectEqual(ExecResult.ok, exec_file_pinned("SMP1.BIN", &.{}, 0));
    const pinned0 = scheduler.task_info(3).?;
    try std.testing.expectEqual(@as(usize, 0), pinned0.pin_core);
    try std.testing.expect(!pinned0.secondary_ok);
    // A plain exec after it spawns into the next free slot, unpinned
    // (secondary_ok ON — any core may run it).
    try std.testing.expectEqual(ExecResult.ok, exec_file("SMP1.BIN", &.{}));
    const unpinned = scheduler.task_info(4).?;
    try std.testing.expectEqual(@as(usize, 0), unpinned.pin_core);
    try std.testing.expect(unpinned.secondary_ok);
}

test "exec: a second program loads and runs while the first is alive" {
    virtio_file.set_test_share(null); // reset any prior test's armed share
    // Restore hardware mode on EVERY exit (success or failure): the exec
    // batch links syscall's tests into the SAME process, so a leaked
    // armed share flips sys_exec's honest no-disk into a not_found.
    defer virtio_file.set_test_share(null);
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the boot payload (exit + reap) so BOTH exec'd programs fit
    // the fixed pool (shell + worker + exec A + exec B + idle).
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));
    const img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    test_seed("USER.BIN", img[0 .. 24 + 25]);
    // Claim 0826: the exec gate is gone — the FIRST exec succeeds with the
    // pool slot free, and the rest succeed WITHOUT waiting for the earlier
    // programs to exit (the old `user_busy` refusal is gone). #1426/#1442:
    // user slots = max_tasks - 3 (shell + worker + idle). M129b (#2611):
    // the carve-out is exec's wall, so exec a bounded set, then fill the
    // remaining pool slots with sys_thread tasks sharing those roots.
    const procs_exec = 10;
    var n: usize = 0;
    while (n < procs_exec) : (n += 1) {
        try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    }
    // All exec'd slots are live: RUNNING USER.BIN processes with their
    // OWN roots, stacks, and executor tasks. Boot payload stayed exited.
    try std.testing.expectEqual(@as(usize, 1 + procs_exec), process.count());
    const proc_a = process.info(1).?;
    const proc_b = process.info(2).?;
    const proc_last = process.info(procs_exec).?;
    try std.testing.expectEqualStrings("USER.BIN", proc_a.name);
    try std.testing.expectEqualStrings("USER.BIN", proc_b.name);
    try std.testing.expectEqualStrings("USER.BIN", proc_last.name);
    n = 1;
    while (n <= procs_exec) : (n += 1) {
        const proc = process.info(n).?;
        try std.testing.expectEqual(process.State.running, proc.state);
        try std.testing.expectEqualStrings("USER.BIN", proc.name);
    }
    // Distinct executors, roots, and pages across the live processes.
    n = 1;
    while (n <= procs_exec) : (n += 1) {
        const left = process.info(n).?;
        var m: usize = n + 1;
        while (m <= procs_exec) : (m += 1) {
            const right = process.info(m).?;
            try std.testing.expect(left.task_id.? != right.task_id.?);
            try std.testing.expect(left.root_phys != right.root_phys);
        }
    }
    // Per-process ASLR (claim 0826): each process owns its stack PLACEMENT
    // (distinct when the CSPRNG is seeded, identical fixed VA when not) —
    // the ownership claim is the PHYSICAL pages + roots, which must differ.
    try std.testing.expect(proc_a.text_phys != proc_b.text_phys);
    try std.testing.expect(proc_a.stack_phys != proc_b.stack_phys);
    try std.testing.expectEqualStrings("user-exec", scheduler.task_info(proc_a.task_id.?).?.name);
    try std.testing.expectEqualStrings("user-exec", scheduler.task_info(proc_last.task_id.?).?.name);
    // Threads fill the pool: each of the ten procs seats ≤ max_threads
    // extras (16) — 10 × 16 = 160 requests vs 51 free user slots → the
    // pool saturates before the per-proc bound does.
    var owners: [procs_exec]usize = undefined;
    n = 1;
    while (n <= procs_exec) : (n += 1) owners[n - 1] = n;
    try std.testing.expect(fill_pool_with_threads(&owners) > 0);
    // The pool is the capacity gate: one more program cannot load.
    try std.testing.expect(!scheduler.has_free_slot());
    try std.testing.expectEqual(ExecResult.pool_full, exec_file("USER.BIN", &.{}));
    try std.testing.expectEqual(@as(usize, 1 + procs_exec), process.count()); // pool_full allocates nothing

}

test "exec: a live user task does not block a second exec (gate is gone)" {
    virtio_file.set_test_share(null); // reset any prior test's armed share
    // Restore hardware mode on EVERY exit (success or failure): the exec
    // batch links syscall's tests into the SAME process, so a leaked
    // armed share flips sys_exec's honest no-disk into a not_found.
    defer virtio_file.set_test_share(null);
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    const img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    test_seed("USER.BIN", img[0 .. 24 + 25]);
    // The boot payload's user task (slot 2) is STILL ALIVE — the old
    // `user_busy` gate is gone. The exec'd program gets its OWN root,
    // stack, and task, so it loads and runs alongside the payload.
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    // Slot 2 stays the boot payload's; the exec'd program takes the spare
    // slot 3 and runs alongside it.
    try std.testing.expectEqualStrings("user-el0", scheduler.task_info(2).?.name);
    try std.testing.expectEqualStrings("user-exec", scheduler.task_info(3).?.name);
    // Both live processes now exist: boot payload + exec'd program.
    try std.testing.expectEqual(@as(usize, 2), process.count());
    try std.testing.expectEqual(process.State.running, process.info(1).?.state);
    try std.testing.expect(process.info(1).?.root_phys != process.info(0).?.root_phys);
}

test "exec: COUNTER.BIN loads by name with its own marker and process" {
    virtio_file.set_test_share(null); // reset any prior test's armed share
    // Restore hardware mode on EVERY exit (success or failure): the exec
    // batch links syscall's tests into the SAME process, so a leaked
    // armed share flips sys_exec's honest no-disk into a not_found.
    defer virtio_file.set_test_share(null);
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the boot payload so its slot is free for the counter.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));

    // The counter's DSK1 image carries its DISTINCT marker (claim 4613 —
    // the `counter: alive` line the live gate greps for; deliberately
    // different from every USER.BIN marker so the serial log can tell the
    // two programs apart).
    const img = dsk1("counter: alive\n", 24, 24 + 15);
    test_seed("COUNTER.BIN", img[0 .. 24 + 15]);
    try std.testing.expectEqual(ExecResult.ok, exec_file("COUNTER.BIN", &.{}));
    const info = loaded().?;
    try std.testing.expectEqualStrings("COUNTER.BIN", info.name);
    try std.testing.expectEqual(@as(usize, 15), info.content_len);
    // The marker landed in the process's OWN text page (this program's
    // content, not USER.BIN's).
    const proc = process.info(1).?;
    try std.testing.expectEqualStrings("COUNTER.BIN", proc.name);
    try std.testing.expectEqual(process.State.running, proc.state);
    try std.testing.expect(proc.text_phys != 0);
    const text_dst: [*]const u8 = @ptrFromInt(proc.text_phys);
    try std.testing.expectEqualStrings("counter: alive\n", text_dst[0..15]);
    // USER.BIN is a DIFFERENT program: exec it too — the two live
    // processes are DISTINCT programs now (the claim-0826 gate ran two
    // copies of the same image).
    const img2 = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    test_seed("USER.BIN", img2[0 .. 24 + 25]);
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    try std.testing.expectEqualStrings("USER.BIN", loaded().?.name);
    try std.testing.expectEqual(@as(usize, 3), process.count()); // boot exited + COUNTER + USER
    try std.testing.expectEqual(process.State.running, process.info(1).?.state);
    try std.testing.expectEqual(process.State.running, process.info(2).?.state);
    try std.testing.expect(process.info(1).?.text_phys != process.info(2).?.text_phys);
}

/// M22 D1 (issue #324): build a minimal but fully valid AArch64 ELF32
/// executable — ELF header (52 B) + one PT_LOAD phdr (32 B) + code. The
/// single segment is R+X at `elf_mod.text_base` with entry at its start.
fn elf32_hello() [128]u8 {
    var img = @as([128]u8, @splat(@as(u8, 0)));
    @memcpy(img[0..4], &elf_mod.magic);
    img[4] = 1; // ELF32
    img[5] = 1; // little-endian
    img[6] = 1; // EV_CURRENT
    std.mem.writeInt(u16, img[16..18], 2, .little); // e_type = EXEC
    std.mem.writeInt(u16, img[18..20], elf_mod.em_aarch64, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little); // e_version
    std.mem.writeInt(u32, img[24..28], @intCast(elf_mod.text_base), .little); // e_entry
    std.mem.writeInt(u32, img[28..32], 52, .little); // e_phoff
    std.mem.writeInt(u16, img[40..42], 52, .little); // e_ehsize
    std.mem.writeInt(u16, img[42..44], 32, .little); // e_phentsize
    std.mem.writeInt(u16, img[44..46], 1, .little); // e_phnum
    std.mem.writeInt(u32, img[52..56], 1, .little); // PT_LOAD
    std.mem.writeInt(u32, img[56..60], 84, .little); // p_offset (after headers)
    std.mem.writeInt(u32, img[60..64], @intCast(elf_mod.text_base), .little); // p_vaddr
    std.mem.writeInt(u32, img[68..72], 44, .little); // p_filesz (128 - 84)
    std.mem.writeInt(u32, img[72..76], 44, .little); // p_memsz
    std.mem.writeInt(u32, img[76..80], 5, .little); // R+X
    const marker = "elf: loaded from the ESP\n";
    @memcpy(img[84..][0..marker.len], marker);
    return img;
}

test "exec: a valid AArch64 ELF32 loads through the magic-sniff path" {
    virtio_file.set_test_share(null); // reset any prior test's armed share
    // Restore hardware mode on EVERY exit (success or failure): the exec
    // batch links syscall's tests into the SAME process, so a leaked
    // armed share flips sys_exec's honest no-disk into a not_found.
    defer virtio_file.set_test_share(null);
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));

    const hello = elf32_hello();
    test_seed("HELLO.ELF", hello[0..]);
    try std.testing.expectEqual(ExecResult.ok, exec_file("HELLO.ELF", &.{}));
    const info = loaded().?;
    try std.testing.expectEqualStrings("HELLO.ELF", info.name);
    // content_len is the segment's memory size; the entry lands at the
    // aperture base (entry_rel == 0 for this fixture).
    try std.testing.expectEqual(@as(usize, 44), info.content_len);
    try std.testing.expectEqual(userspace.text_va, info.entry_va);
    // The staged text page carries the segment bytes, not the ELF header.
    const proc = process.info(1).?;
    try std.testing.expectEqualStrings("HELLO.ELF", proc.name);
    const text_dst: [*]const u8 = @ptrFromInt(proc.text_phys);
    try std.testing.expectEqualStrings("elf: loaded from the ESP\n", text_dst[0..25]);

    // Honest refusals: an x86_64-marked image and a truncated header.
    var x86 = elf32_hello();
    std.mem.writeInt(u16, x86[18..20], 0x3e, .little); // EM_X86_64
    test_seed("BAD.ELF", x86[0..]);
    try std.testing.expectEqual(ExecResult.unsupported_arch, exec_file("BAD.ELF", &.{}));
    // Truncated ELF (magic intact, header cut short) → honest refusal.
    test_seed("SHORT.ELF", hello[0..40]);
    try std.testing.expectEqual(ExecResult.bad_elf, exec_file("SHORT.ELF", &.{}));
}

test "exec: PEER.BIN loads by name — counter + peer fill the task pool" {
    // Card 3f (claim 5965): the THIRD ESP program loads by name exactly
    // like USER.BIN/COUNTER.BIN (same DSK1 pipeline). #1426/#1442: user
    // slots = max_tasks - 3; fillers occupy every slot so one more exec
    // is pool_full.
    virtio_file.set_test_share(null); // reset any prior test's armed share
    // Restore hardware mode on EVERY exit (success or failure): the exec
    // batch links syscall's tests into the SAME process, so a leaked
    // armed share flips sys_exec's honest no-disk into a not_found.
    defer virtio_file.set_test_share(null);
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the boot payload so BOTH exec'd programs fit the pool.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));

    const counter_img = dsk1("counter: alive\n", 24, 24 + 15);
    test_seed("COUNTER.BIN", counter_img[0 .. 24 + 15]);
    const peer_img = dsk1("peer: got \n", 24, 24 + 11);
    test_seed("PEER.BIN", peer_img[0 .. 24 + 11]);
    // Both load by name, each with its OWN process and executor slot.
    try std.testing.expectEqual(ExecResult.ok, exec_file("COUNTER.BIN", &.{})); // pid 1, slot 2
    try std.testing.expectEqual(ExecResult.ok, exec_file("PEER.BIN", &.{})); // pid 2, slot 3
    const counter = process.info(1).?;
    const peer = process.info(2).?;
    try std.testing.expectEqualStrings("COUNTER.BIN", counter.name);
    try std.testing.expectEqualStrings("PEER.BIN", peer.name);
    try std.testing.expectEqual(process.State.running, counter.state);
    try std.testing.expectEqual(process.State.running, peer.state);
    try std.testing.expect(counter.task_id != peer.task_id);
    try std.testing.expect(counter.text_phys != peer.text_phys);
    try std.testing.expect(counter.stack_phys != peer.stack_phys);
    // The peer's payload is in ITS OWN text page (its marker, not the
    // counter's — the serial log can tell the two programs apart).
    const peer_text: [*]const u8 = @ptrFromInt(peer.text_phys);
    try std.testing.expectEqualStrings("peer: got \n", peer_text[0..11]);
    // Fill the pool: counter + peer + eight more exec'd programs (the
    // mmu table carve-out is exec's wall — M129b), then sys_thread tasks
    // seat the rest. One more exec is pool_full, checked BEFORE any
    // allocation (nothing leaks).
    const user_img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    test_seed("USER.BIN", user_img[0 .. 24 + 25]);
    var n: usize = 0;
    while (n < 8) : (n += 1) {
        try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    }
    var owners: [10]usize = undefined;
    n = 1;
    while (n <= 10) : (n += 1) owners[n - 1] = n;
    try std.testing.expect(fill_pool_with_threads(&owners) > 0);
    try std.testing.expect(!scheduler.has_free_slot());
    try std.testing.expectEqual(ExecResult.pool_full, exec_file("USER.BIN", &.{}));
    try std.testing.expectEqual(@as(usize, 1 + 10), process.count()); // boot exited + ten live procs
}

test "exec: permanent occupant + recycle — one spare slot, pool_full, then the re-exec lands" {
    virtio_file.set_test_share(null); // reset any prior test's armed share
    // Restore hardware mode on EVERY exit (success or failure): the exec
    // batch links syscall's tests into the SAME process, so a leaked
    // armed share flips sys_exec's honest no-disk into a not_found.
    defer virtio_file.set_test_share(null);
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the boot payload: shell + idle + worker leave the user slots free.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));

    const counter_img = dsk1("counter: alive\n", 24, 24 + 15);
    test_seed("COUNTER.BIN", counter_img[0 .. 24 + 15]);
    const user_img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    test_seed("USER.BIN", user_img[0 .. 24 + 25]);

    // The counter is the permanent occupant: it takes one slot and never
    // exits (this test never drives it to exit). Nine more exec'd programs
    // join it — at max_tasks = 64 the mmu table carve-out is exec's wall
    // (~20 tables per live root; M129b), so sys_thread tasks seated on the
    // OTHER procs saturate the rest of the pool. pid 2 stays thread-free:
    // the task that exits below then has no siblings to reap.
    const fillers = 9;
    try std.testing.expectEqual(ExecResult.ok, exec_file("COUNTER.BIN", &.{})); // slot 2
    const free_after_counter = alloc.stats().free_pages;
    var n: usize = 0;
    while (n < fillers) : (n += 1) {
        try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    }
    const held_pages: u64 = (scheduler.task_stack_size + 4095) / 4096;
    var owners = [9]usize{ 1, 3, 4, 5, 6, 7, 8, 9, 10 };
    const thread_tasks = fill_pool_with_threads(&owners);
    try std.testing.expect(thread_tasks > 0);
    try std.testing.expect(!scheduler.has_free_slot());
    // The capacity gate: one more exec while every user slot is live is
    // pool_full, checked BEFORE any allocation — nothing leaks.
    try std.testing.expectEqual(ExecResult.pool_full, exec_file("USER.BIN", &.{}));
    const filler_pages = fillers * dsk1_exec_pages();
    const thread_pages = thread_tasks * held_pages;
    try std.testing.expectEqual(free_after_counter - filler_pages - thread_pages, alloc.stats().free_pages);

    // Drive the FIRST short program's exit + reap (the idle task's
    // lifecycle reap): its DSK1 pages (text 1 + stack + kstack) return
    // to the allocator and its
    // executor slot becomes spawnable again — while the counter stays
    // running.
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> counter
    try std.testing.expect(scheduler.yield_current()); // counter -> user (slot 3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(43)); // user -> idle
    try std.testing.expectEqual(process.State.exited, process.info(2).?.state);
    // #2430: the exited process's user pages return AT EXIT (text + user
    // stack); only the exiting task's kstack still waits for the reap...
    try std.testing.expectEqual(free_after_counter - filler_pages - thread_pages + (dsk1_exec_pages() - held_pages), alloc.stats().free_pages);
    // ...the scheduler reap returns the rest (claim 4613) while the exited
    // descriptor stays in the procs table with its status.
    try std.testing.expect(scheduler.reap(3));
    try std.testing.expectEqual(free_after_counter - (filler_pages - dsk1_exec_pages()) - thread_pages, alloc.stats().free_pages);
    try std.testing.expectEqual(process.State.exited, process.info(2).?.state);
    try std.testing.expectEqual(@as(u64, 43), process.info(2).?.exit_status);
    try std.testing.expectEqual(@as(u64, 0), process.info(2).?.text_pages);
    try std.testing.expect(scheduler.has_free_slot());
    try std.testing.expectEqual(process.State.running, process.info(1).?.state); // counter still live

    // The next exec lands in the freed slot (recycle under a permanent
    // occupant — the claim-0826 gate could never show this, because both
    // its programs exited)...
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    try std.testing.expectEqual(process.State.running, process.info(3).?.state);
    // ...and with the counter + filler live programs + thread tasks the
    // pool is full again: a subsequent exec is pool_full, still leak-free.
    try std.testing.expect(!scheduler.has_free_slot());
    try std.testing.expectEqual(ExecResult.pool_full, exec_file("USER.BIN", &.{}));
    try std.testing.expectEqual(free_after_counter - filler_pages - thread_pages, alloc.stats().free_pages);
    try std.testing.expectEqual(process.State.running, process.info(1).?.state);
}

test "exec: kill reaps a permanent occupant — pages return, the slot is re-exec'd" {
    // Card 3c (claim 7786): the OS, not the program, owns process
    // lifetime. The never-exiting COUNTER.BIN is force-terminated through
    // the EXISTING exit → zombie → idle-reap path with the reserved
    // status 137; its DSK1 allocator pages return at the reap (exact
    // +dsk1_exec_pages recovery), the slot frees, and a subsequent exec lands
    // in it.
    virtio_file.set_test_share(null); // reset any prior test's armed share
    // Restore hardware mode on EVERY exit (success or failure): the exec
    // batch links syscall's tests into the SAME process, so a leaked
    // armed share flips sys_exec's honest no-disk into a not_found.
    defer virtio_file.set_test_share(null);
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the boot payload: shell + idle + worker leave two free slots.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));
    // Drain the boot payload's exit/reap reports into a throwaway so the
    // kill's report below is the ONLY pending one (single-slot flags).
    var drain_mock = console.MockConsole(256){};
    var drain_con = drain_mock.console();
    scheduler.maybe_report(&drain_con);

    const counter_img = dsk1("counter: alive\n", 24, 24 + 15);
    test_seed("COUNTER.BIN", counter_img[0 .. 24 + 15]);
    const user_img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    test_seed("USER.BIN", user_img[0 .. 24 + 25]);

    // The permanent occupant takes a slot and dsk1_exec_pages() (1 text +
    // user stack + EL1 exception stack).
    try std.testing.expectEqual(ExecResult.ok, exec_file("COUNTER.BIN", &.{})); // slot 2
    const free_after_counter = alloc.stats().free_pages;
    const counter_proc = process.info(1).?;
    try std.testing.expectEqualStrings("COUNTER.BIN", counter_proc.name);
    try std.testing.expectEqual(process.State.running, counter_proc.state);
    // Kill by id (the `procs` id): the kernel arms the counter's executor.
    try std.testing.expectEqual(scheduler.KillResult.ok, scheduler.request_kill(counter_proc.task_id.?));
    // The ring's next selection of the counter converts it to the exit
    // path with the RESERVED status 137 (not a cooperative sys_exit).
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> counter -> killed -> idle
    try std.testing.expectEqual(@as(usize, scheduler.idle_id), scheduler.current_id());
    try std.testing.expect(scheduler.is_terminated(2));
    try std.testing.expectEqual(@as(?u64, scheduler.reserved_kill_status), scheduler.terminated_status(2));
    // The process exit report carries 137 (the killed-status report).
    var mock = console.MockConsole(128){};
    var con = mock.console();
    scheduler.maybe_report(&con);
    try std.testing.expectEqualStrings("tasks user-exec exited status=137\nprocs COUNTER.BIN exited status=137\n", mock.contents());
    const killed = process.info(1).?;
    try std.testing.expectEqual(process.State.exited, killed.state);
    try std.testing.expectEqual(@as(u64, 137), killed.exit_status);
    // The exited process's user pages return at the exit (#2430 — text +
    // user stack); only the kstack still waits for the reap...
    const held_pages: u64 = (scheduler.task_stack_size + 4095) / 4096;
    try std.testing.expectEqual(free_after_counter + dsk1_exec_pages() - held_pages, alloc.stats().free_pages);
    // ...then the scheduler reap returns the rest (exact +dsk1_exec_pages total).
    try std.testing.expect(scheduler.reap(2));
    try std.testing.expectEqual(free_after_counter + dsk1_exec_pages(), alloc.stats().free_pages);
    try std.testing.expect(scheduler.has_free_slot());
    // A subsequent exec lands in the freed slot.
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    try std.testing.expectEqual(process.State.running, process.info(2).?.state);
    try std.testing.expectEqual(@as(?usize, 2), process.info(2).?.task_id); // slot 2 reused
    // The counter's exited descriptor stays in the procs table.
    try std.testing.expectEqual(process.State.exited, process.info(1).?.state);
    try std.testing.expectEqual(@as(u64, 137), process.info(1).?.exit_status);
}

test "exec: argv packing shape, per-arg refusal, and block VA" {
    // Card 3e, M71m (#1572): the block is 8 slots × 256 bytes, zeroed,
    // NUL-terminated. pack_args is pure — the shape is pinned without a disk.
    var block: [arg_block_bytes]u8 = undefined;
    const n = try pack_args(&.{ "alpha", "beta", "gamma" }, &block);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("alpha", block[0..5]);
    try std.testing.expectEqual(@as(u8, 0), block[5]);
    try std.testing.expectEqualStrings("beta", block[arg_slot_bytes..][0..4]);
    try std.testing.expectEqualStrings("gamma", block[2 * arg_slot_bytes ..][0..5]);
    for (block[2 * arg_slot_bytes + 5 ..]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    // A 255-byte arg fills the slot and keeps its NUL. One more byte is
    // refused — the old 31-byte chop is gone.
    const exact = &@as([(arg_slot_bytes - 1):0]u8, @splat("y"[0]));
    const n2 = try pack_args(&.{exact}, &block);
    try std.testing.expectEqual(@as(usize, 1), n2);
    for (block[0 .. arg_slot_bytes - 1]) |b| try std.testing.expectEqual(@as(u8, 'y'), b);
    try std.testing.expectEqual(@as(u8, 0), block[arg_slot_bytes - 1]);

    const too = &@as([arg_slot_bytes:0]u8, @splat("x"[0]));
    try std.testing.expectError(error.ArgTooLong, pack_args(&.{too}, &block));

    // The block VA sits right after the content, 8-aligned, inside the
    // text page; an image that nearly fills the page leaves no room.
    try std.testing.expectEqual(userspace.text_va + 24, argv_va_for(24));
    try std.testing.expectEqual(userspace.text_va + 240, argv_va_for(234));
    try std.testing.expectEqual(@as(u64, 0), argv_va_for(4096 - 100));
}

test "exec: envp packing shape, per-entry truncation, and KEY=VALUE slots" {
    // Issue #1226: 16 slots × 128 bytes, zeroed, NUL-terminated. pack_env
    // is pure — the shape is pinned without a disk.
    var block: [env_block_bytes]u8 = undefined;
    const n = pack_env(&.{ "GOMAXPROCS=1", "HOME=/host" }, &block);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("GOMAXPROCS=1", block[0..12]);
    try std.testing.expectEqual(@as(u8, 0), block[12]);
    try std.testing.expectEqualStrings("HOME=/host", block[env_slot_bytes..][0..10]);
    for (block[env_slot_bytes + 10 .. env_slot_bytes * 2]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    const long = "K=" ++ (&@as([200:0]u8, @splat("v"[0])));
    const n2 = pack_env(&.{long}, &block);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqual(@as(u8, 'K'), block[0]);
    try std.testing.expectEqual(@as(u8, '='), block[1]);
    try std.testing.expectEqual(@as(u8, 0), block[env_slot_bytes - 1]);
    try std.testing.expectEqual(@as(usize, 127), std.mem.indexOfScalar(u8, block[0..env_slot_bytes], 0).?);
}

test "exec: more than 8 args is refused honestly (too_many_args)" {
    // Card 3e: the bounded block holds 8 args; a 9th is an honest refusal,
    // never silent truncation. Checked BEFORE any disk/file work (fails
    // even with no disk mounted).
    virtio_file.set_test_share(null);
    const args = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i" };
    try std.testing.expectEqual(ExecResult.too_many_args, exec_file("USER.BIN", &args));
}

test "exec: an argument longer than 255 bytes is refused (arg_too_long)" {
    // M71m (#1572): checked before any disk work, same as too_many_args.
    virtio_file.set_test_share(null);
    const long = &@as([arg_slot_bytes:0]u8, @splat("x"[0]));
    try std.testing.expectEqual(ExecResult.arg_too_long, exec_file("USER.BIN", &.{long}));
}

test "exec: the argv-block room guard is exact at the 4 KiB page boundary" {
    // The flat DSK1 path packs a 2048-byte argv block after the content
    // in the same 4 KiB page. content 2048 leaves the block exactly at
    // the page end (fits); content 2049 aligns up to 2056 and does not.
    try std.testing.expect(userspace.text_va + 2048 == argv_va_for(2048));
    try std.testing.expectEqual(@as(u64, 0), argv_va_for(2049));
    try std.testing.expectEqual(@as(u64, 0), argv_va_for(4095));
}

test "exec: argv block is a read-only leaf — uaccess reads it, writes fault, per-exec distinct" {
    // Card 3e: `exec USER.BIN alpha` + `exec USER.BIN beta` — the SAME
    // image, distinguished by its argv. Each exec packs its own block into
    // its OWN text page; the block sits inside the (read-only) text
    // aperture, so uaccess copy_in reads it and copy_out is a permission
    // fault — the args range is never in the EL0 write aperture.
    virtio_file.set_test_share(null); // reset any prior test's armed share
    // Restore hardware mode on EVERY exit (success or failure): the exec
    // batch links syscall's tests into the SAME process, so a leaked
    // armed share flips sys_exec's honest no-disk into a not_found.
    defer virtio_file.set_test_share(null);
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the boot payload so BOTH exec'd programs fit the pool.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));

    const img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    test_seed("USER.BIN", img[0 .. 24 + 25]);
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{"alpha"}));
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{"beta"}));
    // Both processes live, each with its OWN text page and its own block.
    try std.testing.expectEqual(@as(usize, 3), process.count());
    const proc_a = process.info(1).?;
    const proc_b = process.info(2).?;
    try std.testing.expectEqual(process.State.running, proc_a.state);
    try std.testing.expectEqual(process.State.running, proc_b.state);
    try std.testing.expect(proc_a.text_phys != proc_b.text_phys);
    const block_off: usize = (25 + 7) & ~@as(usize, 7); // 32 for content 25
    const text_a: [*]const u8 = @ptrFromInt(proc_a.text_phys);
    const text_b: [*]const u8 = @ptrFromInt(proc_b.text_phys);
    try std.testing.expectEqualStrings("alpha", text_a[block_off..][0..5]);
    try std.testing.expectEqualStrings("beta", text_b[block_off..][0..4]);
    try std.testing.expect(std.mem.indexOf(u8, text_a[0..256], "beta") == null);
    // The text aperture extends over the block (the region uaccess reads
    // from covers content + block) and the block VA is the one USER.BIN is
    // told about (x1 at entry).
    const text_region_len = block_off + arg_block_bytes; // 288 = 25 content + 256 block, 8-aligned
    try std.testing.expectEqual(userspace.text_va + block_off, argv_va_for(25));
    // uaccess both directions: copy_in from the args range reads the
    // packed bytes; copy_out to it is a permission fault.
    syscall.set_user_regions(
        .{ .base = proc_a.text_phys, .len = text_region_len },
        .{ .base = 0, .len = 0 },
    );
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(uaccess.Outcome.ok, uaccess.copy_in(&buf, proc_a.text_phys + block_off, 5));
    try std.testing.expectEqualStrings("alpha", buf[0..5]);
    try std.testing.expectEqual(uaccess.Outcome.fault, uaccess.copy_out(proc_a.text_phys + block_off, "12345678", 8));
    // The args range is absent from the EL0 write aperture: the real
    // per-task write aperture is the user STACK (a different page), so the
    // args range on the text page is never writable — while the stack
    // itself IS the EL0 write aperture.
    syscall.set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = proc_a.stack_phys, .len = proc_a.stack_len },
    );
    try std.testing.expectEqual(uaccess.Outcome.fault, uaccess.copy_out(proc_a.text_phys + block_off, "12345678", 8));
    try std.testing.expectEqual(uaccess.Outcome.ok, uaccess.copy_out(proc_a.stack_phys, "12345678", 8));
}

// ---------------------------------------------------------------------------
// M133a (#2755): named OOM — the physical-allocator injection hook fails the
// Nth `alloc.alloc_pages` call, and every loader path must answer
// `out_of_memory` with a leak-free unwind, never a wedge or a leak.
// ---------------------------------------------------------------------------

/// A minimal DSK3 segmented image: 16 bytes text + 16 bytes data file
/// (data_mem_size 32 — a real writable segment, so the flat path takes the
/// data allocation site).
fn dsk3_segments() [dsk3_header_size + 32]u8 {
    var img = @as([dsk3_header_size + 32]u8, @splat(@as(u8, 0)));
    std.mem.writeInt(u32, img[0..4], dsk3_magic, .little);
    std.mem.writeInt(u32, img[4..8], 0, .little);
    std.mem.writeInt(u64, img[8..16], dsk3_header_size, .little); // entry = text start
    std.mem.writeInt(u64, img[16..24], dsk3_header_size + 16 + 16, .little); // image_size
    std.mem.writeInt(u64, img[24..32], 16, .little); // text_size
    std.mem.writeInt(u64, img[32..40], 16, .little); // data_file_size
    std.mem.writeInt(u64, img[40..48], 32, .little); // data_mem_size
    return img;
}

/// Two-segment gap-layout static ELF: seg0 R+X at `base` (maps the whole
/// file), seg1 RW at `base + 0x100000` — the per-segment alloc loop's
/// mid-iteration failure fixture.
fn test_gap2_image(base: u64) [640]u8 {
    var img = @as([640]u8, @splat(@as(u8, 0)));
    @memcpy(img[0..4], "\x7fELF");
    img[4] = 2; // ELF64
    img[5] = 1; // little endian
    img[6] = 1;
    std.mem.writeInt(u16, img[16..18], 2, .little); // ET_EXEC
    std.mem.writeInt(u16, img[18..20], 183, .little); // AArch64
    std.mem.writeInt(u32, img[20..24], 1, .little);
    std.mem.writeInt(u64, img[24..32], base + 256, .little); // e_entry (seg0 file bytes)
    std.mem.writeInt(u64, img[32..40], 64, .little); // e_phoff
    std.mem.writeInt(u16, img[52..54], 64, .little); // e_ehsize
    std.mem.writeInt(u16, img[54..56], 56, .little); // e_phentsize
    std.mem.writeInt(u16, img[56..58], 2, .little); // e_phnum
    // phdr0: PT_LOAD R+X @ base — file bytes [0, 384) (past e_entry) over
    // a 4 KiB memsz. The file ranges must be disjoint AND ordered.
    std.mem.writeInt(u32, img[64..68], 1, .little); // PT_LOAD
    std.mem.writeInt(u32, img[68..72], 5, .little); // R+X
    std.mem.writeInt(u64, img[72..80], 0, .little); // p_offset
    std.mem.writeInt(u64, img[80..88], base, .little); // p_vaddr
    std.mem.writeInt(u64, img[96..104], 384, .little); // p_filesz
    std.mem.writeInt(u64, img[104..112], 4096, .little); // p_memsz
    std.mem.writeInt(u64, img[112..120], 4096, .little); // p_align
    // phdr1: PT_LOAD RW @ base + 0x100000 (a page-aligned gap — the
    // writable LAST segment the gap contract demands).
    std.mem.writeInt(u32, img[120..124], 1, .little); // PT_LOAD
    std.mem.writeInt(u32, img[124..128], 6, .little); // R+W
    std.mem.writeInt(u64, img[128..136], 384, .little); // p_offset
    std.mem.writeInt(u64, img[136..144], base + 0x100000, .little); // p_vaddr
    std.mem.writeInt(u64, img[152..160], 256, .little); // p_filesz
    std.mem.writeInt(u64, img[160..168], 4096, .little); // p_memsz
    std.mem.writeInt(u64, img[168..176], 4096, .little); // p_align
    return img;
}

/// Sweep the injection counter across an exec attempt: arming `n` must
/// refuse the load `out_of_memory` with every earlier allocation returned
/// — the free count is the leak detector. `sites` is the number of
/// `alloc.alloc_pages` calls a successful load makes on this path.
fn expect_injected_oom(name: []const u8, sites: u64) !void {
    var n: u64 = 1;
    while (n <= sites) : (n += 1) {
        const free_before = alloc.stats().free_pages;
        alloc.inject_fail_nth(n);
        try std.testing.expectEqual(ExecResult.out_of_memory, exec_file(name, &.{}));
        try std.testing.expectEqual(@as(u64, 0), alloc.inject_remaining_calls());
        try std.testing.expectEqual(free_before, alloc.stats().free_pages);
    }
}

test "exec: M133a — injected failure names out_of_memory at every flat-path site" {
    defer virtio_file.set_test_share(null);
    defer test_share_n = 0;
    defer alloc.inject_fail_nth(0);
    arm_allocator();
    _ = scheduler.init();
    test_share_n = 0;
    const img = dsk1("USER!", 24, 24 + 5);
    test_seed("USER.BIN", img[0 .. 24 + 5]);
    // DSK1 (no data segment): text, user stack, kernel stack — 3 sites.
    try expect_injected_oom("USER.BIN", 3);
}

test "exec: M133a — injected failure names out_of_memory at every DSK3 site" {
    defer virtio_file.set_test_share(null);
    defer test_share_n = 0;
    defer alloc.inject_fail_nth(0);
    arm_allocator();
    _ = scheduler.init();
    test_share_n = 0;
    const img = dsk3_segments();
    test_seed("SEG.BIN", img[0..]);
    // DSK3 with a writable segment: text, data, user stack, kernel stack.
    try expect_injected_oom("SEG.BIN", 4);
}

test "exec: M133a — injected failure names out_of_memory across the gap-ELF segment loop" {
    defer virtio_file.set_test_share(null);
    defer test_share_n = 0;
    defer mmu.reset();
    defer alloc.inject_fail_nth(0);
    arm_allocator();
    _ = scheduler.init();
    test_share_n = 0;
    const image = test_gap2_image(0x0080_0000);
    test_seed("GAP.ELF", image[0..]);
    // seg0, seg1 (the loop's second iteration — its unwind must return
    // seg0's pages), user stack, kernel stack — 4 sites.
    try expect_injected_oom("GAP.ELF", 4);
}

test "exec: M133a — injected failure names out_of_memory at every dynamic-ELF site" {
    defer virtio_file.set_test_share(null);
    defer test_share_n = 0;
    defer mmu.reset();
    defer alloc.inject_fail_nth(0);
    arm_allocator();
    _ = scheduler.init();
    test_share_n = 0;
    const image = test_dynamic_image(userspace.text_va, true);
    const interpreter = test_dynamic_image(0x0080_0000, false);
    test_seed("DYNAMIC.ELF", image[0..]);
    test_seed("LD.SO", interpreter[0..]);
    // scratch, text, interp text, library aperture, user stack, kernel
    // stack — 6 sites (single-segment program + interpreter).
    try expect_injected_oom("DYNAMIC.ELF", 6);
}

test "exec: el0_spawn_principal binds AGENTD.ELF to uid_agent, preserves all else (M173b #3041)" {
    const user = process.default_principal;
    const agent = process.agent_principal;
    const sys = process.Principal{ .uid = process.uid_system, .caps = process.kernel_caps };
    // The recorded image name binds {uid_agent,0} for any caller — narrowing only.
    try std.testing.expectEqual(process.uid_agent, el0_spawn_principal("AGENTD.ELF", user).uid);
    try std.testing.expectEqual(@as(u32, 0), el0_spawn_principal("AGENTD.ELF", user).caps);
    try std.testing.expectEqual(process.uid_agent, el0_spawn_principal("AGENTD.ELF", sys).uid);
    // Case-insensitive like the grant table's name keys (APFS share).
    try std.testing.expectEqual(process.uid_agent, el0_spawn_principal("agentd.elf", user).uid);
    // A uid_agent parent's child inherits uid_agent (preserve rule).
    const p = el0_spawn_principal("GOSH.ELF", agent);
    try std.testing.expectEqual(process.uid_agent, p.uid);
    try std.testing.expectEqual(@as(u32, 0), p.caps);
    // Everything else keeps the caller's principal unchanged.
    try std.testing.expectEqual(process.uid_user, el0_spawn_principal("GOSH.ELF", user).uid);
    try std.testing.expectEqual(process.uid_system, el0_spawn_principal("GOSH.ELF", sys).uid);
    // A same-named file in a subdirectory does NOT bind (verbatim recorded name).
    try std.testing.expectEqual(process.uid_user, el0_spawn_principal("SUB/AGENTD.ELF", user).uid);
}
