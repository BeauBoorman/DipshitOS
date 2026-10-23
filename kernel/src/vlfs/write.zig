//! write.zig — the VLFS journaled write path (M100d, issue #2309; ADR 0050
//! §D4 commit ordering, §D3 format, §D5 replay contract).
//!
//! **One operation, one transaction.** Every mutating op builds its full
//! dest→new-contents set, commits it, and checkpoints before returning — the
//! ADR's eager-checkpoint v1 shape: the journal is empty at every operation
//! boundary and reads never consult it.
//!
//! **The journal is the staging area.** `Txn.append` writes each payload
//! block into the journal region as it is composed (before DESC/COMMIT
//! exist). That is legal because nothing below a FLUSH is durable-ordered
//! and a half-written record never validates: D4 step 2 pins that "ordering
//! among them is not relied upon — the checksums make a half-durable record
//! read as torn, never as valid." Staging in the journal keeps the whole
//! write path at two 4 KiB buffers of BSS — no 256 KiB payload array — and
//! `readCurrent` gives ops a staged-or-home read view so a block mutated
//! twice in one txn (a bbitmap block feeding several allocations) still
//! reads back what this txn wrote.
//!
//! **The commit ordering (the wire contract).** `commit` emits DESC at the
//! journal cursor, then COMMIT, then FLUSH — the transaction is durable
//! exactly when that flush returns. Then the checkpoint: each payload to
//! its home block, FLUSH, the ping-pong superblock (journal_applied = seq,
//! next_txn_seq = seq+1 written into the LOWER-seq slot), FLUSH, and the
//! journal cursor resets to the region start (v1: it never moves).
//!
//! **Refusals before mutations.** Ops preflight the named refusals they can
//! (exists/dir_full/no_space/…) before the first append, so a refused op
//! leaves zero sectors touched; an op that fails mid-append leaves orphan
//! journal payload blocks — inert, since no valid DESC/COMMIT pairs them.
//!
//! No allocation, no recursion past the depth-8 directory bound.

const std = @import("std");
const vlfs = @import("vlfs.zig");

pub const Error = vlfs.Error;
const Block = [vlfs.block_len]u8;

/// directory.valid_name's same contract, kept local (write.zig cannot
/// import above kernel/src/vlfs/ — it must stay a standalone test root).
fn validName(name: []const u8) bool {
    return name.len > 0 and name.len <= vlfs.max_name and
        std.mem.indexOfScalar(u8, name, 0) == null and
        std.mem.indexOfScalar(u8, name, '/') == null and
        !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..");
}

fn wr16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}
fn wr32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}
fn wr64(b: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, b[off..][0..8], v, .little);
}

const rd16 = vlfs.rd16;
const rd32 = vlfs.rd32;
const rd64 = vlfs.rd64;

/// Bits of the block bitmap per bitmap block (32768).
const bits_per_map_block: u32 = 8 * vlfs.block_len;

// ---------------------------------------------------------------------------
// Txn — one journal transaction (DESC + ≤64 payload blocks + COMMIT)
// ---------------------------------------------------------------------------

pub const Txn = struct {
    src: vlfs.SectorSource,
    vol: *vlfs.Volume,
    /// This transaction's sequence number (vol.next_txn_seq at begin).
    seq: u64,
    /// Journal write cursor — always the region start under eager
    /// checkpointing (D4: the journal is empty at every op boundary).
    pos: u32,
    n: u32 = 0,
    dests: [vlfs.max_payload]u32 = undefined,
    psums: [vlfs.max_payload]u32 = undefined,
    /// Sticky refusal: once set, append/commit report it (an op that ran
    /// out of payload slots mid-flight still fails honestly).
    err: ?Error = null,
    /// Read window for internal reads (bitmap scans, chain walks); the
    /// caller owns the buffer.
    walk: *Block,
    /// The block currently being composed/mutated by the caller.
    compose: *Block,
    /// M172f (#3104, ADR 0061): the tag homes this txn's sealed dests
    /// dirtied — commit appends each as a payload so the updated tag
    /// block rides in the same transaction as the payloads it
    /// authenticates.
    thomes: [vlfs.max_payload]u32 = undefined,
    thomes_n: u32 = 0,

    pub fn begin(src: vlfs.SectorSource, vol: *vlfs.Volume, walk: *Block, compose: *Block) Txn {
        src.clearStaged(); // a stale stage from an aborted txn must not leak in
        return .{
            .src = src,
            .vol = vol,
            .seq = vol.next_txn_seq,
            .pos = vol.journal_first,
            .walk = walk,
            .compose = compose,
        };
    }

    fn slotOf(t: *const Txn, dest: u32) ?u32 {
        for (t.dests[0..t.n], 0..) |d, i| {
            if (d == dest) return @intCast(i);
        }
        return null;
    }

    /// Read dest's current contents: the staged journal slot when the txn
    /// already appended it, else the home block.
    pub fn readCurrent(t: *Txn, dest: u32, out: *Block) Error!void {
        if (t.err) |e| return e;
        const blk = if (t.slotOf(dest)) |i| t.pos + 1 + i else dest;
        if (!t.src.readBlock(blk, out)) {
            t.err = error.Io;
            return error.Io;
        }
    }

    /// Append dest→contents as a payload (the complete new block image), or
    /// rewrite the slot when dest was already appended this txn. Bounds the
    /// dest to the journaled regions ([2+J, volume_blocks)) per D3 — a dest
    /// inside the journal or superblocks is a writer bug, refused
    /// `bad_journal` rather than emitted.
    pub fn append(t: *Txn, dest: u32, contents: *const Block) Error!void {
        if (t.err) |e| return e;
        if (dest < t.vol.ibitmap_first or dest >= t.vol.volume_blocks) {
            t.err = error.BadJournal;
            return error.BadJournal;
        }
        const i = t.slotOf(dest) orelse blk: {
            if (t.n == vlfs.max_payload) {
                t.err = error.TxnTooLarge;
                return error.TxnTooLarge;
            }
            const i = t.n;
            t.dests[i] = dest;
            t.n += 1;
            break :blk i;
        };
        if (!t.src.writeBlock(t.pos + 1 + i, contents)) {
            t.err = error.Io;
            return error.Io;
        }
        t.psums[i] = vlfs.fnv32(contents);
        // ADR 0061 (#3104): a sealed dest's home ciphertext lands at
        // checkpoint under the {nonce, tag} staged here; the tag home
        // covering it joins this txn as a payload so pair and journal
        // commit atomically. Unsealed dests and sources stage nothing.
        const th = t.src.stageBlock(dest, contents);
        if (th != 0) {
            for (t.thomes[0..t.thomes_n]) |h| {
                if (h == th) return;
            }
            if (t.thomes_n < t.thomes.len) {
                t.thomes[t.thomes_n] = th;
                t.thomes_n += 1;
            }
        }
    }

    /// D4's ordering, in one shot: DESC, COMMIT, FLUSH (the commit point),
    /// checkpoint each payload home, FLUSH, ping-pong the superblock,
    /// FLUSH. n == 0 is a legal no-op commit (an op that mutated nothing).
    pub fn commit(t: *Txn) Error!void {
        if (t.err) |e| return e;
        if (t.n == 0) return;
        const walk = t.walk;
        // ADR 0061 (#3104): the tag homes covering this txn's sealed
        // dests join the commit as payloads — a mid-checkpoint kill
        // replays payload and tag as one transaction instead of leaving
        // a bad_block_auth home the replay has to guess at.
        for (t.thomes[0..t.thomes_n]) |home| {
            try t.readCurrent(home, walk);
            _ = t.src.applyStaged(home, walk);
            try t.append(home, walk);
        }
        // DESC at the cursor.
        @memset(walk, 0);
        wr32(walk, vlfs.jd_magic, vlfs.magic_desc);
        wr64(walk, vlfs.jd_seq, t.seq);
        wr16(walk, vlfs.jd_count, @intCast(t.n));
        for (0..t.n) |i| {
            wr32(walk, vlfs.jd_entries + i * 8, t.dests[i]);
            wr32(walk, vlfs.jd_entries + i * 8 + 4, t.psums[i]);
        }
        wr32(walk, vlfs.jd_cksum, vlfs.fnv32(walk[0..vlfs.jd_cksum]));
        if (!t.src.writeBlock(t.pos, walk)) return error.Io;
        // txn_cksum covers DESC[+0..16+8n] + every payload block, in order;
        // the payloads are re-read from the journal slots they were
        // appended to (they are on-device already).
        var h = vlfs.fnv32(walk[0 .. vlfs.jd_entries + 8 * t.n]);
        for (0..t.n) |i| {
            if (!t.src.readBlock(t.pos + 1 + @as(u32, @intCast(i)), walk)) return error.Io;
            h = vlfs.fnv32Continue(h, walk);
        }
        // COMMIT.
        @memset(walk, 0);
        wr32(walk, vlfs.jc_magic, vlfs.magic_commit);
        wr64(walk, vlfs.jc_seq, t.seq);
        wr32(walk, vlfs.jc_txn, h);
        wr32(walk, vlfs.jc_cksum, vlfs.fnv32(walk[0..vlfs.jc_cksum]));
        if (!t.src.writeBlock(t.pos + 1 + t.n, walk)) return error.Io;
        if (!t.src.flush()) return error.Io; // == the commit point ==
        // Checkpoint: payloads to their home blocks, then the ping-pong
        // superblock update, each bracketed by its own FLUSH (D4 step 4).
        for (0..t.n) |i| {
            if (!t.src.readBlock(t.pos + 1 + @as(u32, @intCast(i)), walk)) return error.Io;
            if (!t.src.writeBlock(t.dests[i], walk)) return error.Io;
        }
        if (!t.src.flush()) return error.Io;
        t.vol.journal_applied = t.seq;
        t.vol.next_txn_seq = t.seq + 1;
        t.vol.seq += 1;
        const target: u32 = 1 - t.vol.sb_slot;
        @memset(walk, 0);
        vlfs.writeSuperblockSector(walk[0..vlfs.sector_len], vlfs.volumeSuperblock(t.vol.*, @intCast(target)));
        if (!t.src.writeBlock(target, walk)) return error.Io;
        if (!t.src.flush()) return error.Io;
        t.vol.sb_slot = @intCast(target);
    }
};

// ---------------------------------------------------------------------------
// Block + inode allocation (bbitmap / ibitmap — metadata, journaled like
// everything else)
// ---------------------------------------------------------------------------

/// Allocate one data-region block: set its bbitmap bit (the bitmap block
/// becomes a txn payload) and append the block's zeroed contents — ADR D3:
/// allocated blocks are zeroed, and the journal must carry the durable
/// bytes. Scans from the volume's forward-only alloc hint, wrapping once.
fn allocBlock(t: *Txn) Error!u32 {
    const vol = t.vol;
    var probes: u64 = 0;
    var bit: u64 = vol.alloc_hint;
    while (probes < vol.data_blocks) {
        if (bit >= vol.volume_blocks) bit = vol.data_first;
        const map_idx: u32 = @intCast(bit / bits_per_map_block);
        const map_blk = vol.bbitmap_first + map_idx;
        try t.readCurrent(map_blk, t.walk);
        // Bits below data_first cover structural blocks — always set.
        const lo: u64 = @max(bit, vol.data_first);
        const hi: u64 = @min(@as(u64, map_idx + 1) * bits_per_map_block, vol.volume_blocks);
        var probe = lo;
        while (probe < hi) : (probe += 1) {
            const off: usize = @intCast(probe % bits_per_map_block);
            if (t.walk[off / 8] & (@as(u8, 1) << @intCast(off % 8)) == 0) {
                t.walk[off / 8] |= @as(u8, 1) << @intCast(off % 8);
                try t.append(map_blk, t.walk);
                @memset(t.walk, 0);
                try t.append(@intCast(probe), t.walk);
                vol.alloc_hint = @intCast(probe + 1);
                return @intCast(probe);
            }
        }
        probes += hi - lo;
        bit = hi;
    }
    return error.NoSpace;
}

/// Free data-region blocks [first, first+count): clear their bbitmap bits,
/// one read+append per covered bitmap block.
fn freeBlocks(t: *Txn, first: u32, count: u32) Error!void {
    var b = first;
    const end = first + count;
    while (b < end) {
        const map_idx = b / bits_per_map_block;
        const map_blk = t.vol.bbitmap_first + map_idx;
        try t.readCurrent(map_blk, t.walk);
        const hi = @min(@as(u64, map_idx + 1) * bits_per_map_block, end);
        while (b < hi) : (b += 1) {
            const off: usize = @intCast(b % bits_per_map_block);
            t.walk[off / 8] &= ~(@as(u8, 1) << @intCast(off % 8));
        }
        try t.append(map_blk, t.walk);
    }
    if (t.vol.alloc_hint > first) t.vol.alloc_hint = first;
}

/// Allocate an inode number: set its ibitmap bit. Bits 0 (never a file) and
/// 1 (root) are set at mkfs; the scan starts at 2.
fn allocInode(t: *Txn) Error!u32 {
    try t.readCurrent(t.vol.ibitmap_first, t.walk);
    var i: u32 = 2;
    while (i < t.vol.inode_count) : (i += 1) {
        if (t.walk[i / 8] & (@as(u8, 1) << @intCast(i % 8)) == 0) {
            t.walk[i / 8] |= @as(u8, 1) << @intCast(i % 8);
            try t.append(t.vol.ibitmap_first, t.walk);
            return i;
        }
    }
    return error.NoInodes;
}

/// Free an inode: clear its ibitmap bit and zero its itable record (a free
/// slot is zeros plus a valid checksum — the mkfs shape).
fn freeInode(t: *Txn, ino: u32) Error!void {
    try t.readCurrent(t.vol.ibitmap_first, t.walk);
    t.walk[ino / 8] &= ~(@as(u8, 1) << @intCast(ino % 8));
    try t.append(t.vol.ibitmap_first, t.walk);
    const blk = t.vol.itable_first + ino / vlfs.inodes_per_block;
    if (blk >= t.vol.itable_first + t.vol.itable_blocks) return error.BadInode;
    try t.readCurrent(blk, t.walk);
    const rec = t.walk[(ino % vlfs.inodes_per_block) * vlfs.inode_len ..][0..vlfs.inode_len];
    @memset(rec, 0);
    wr32(rec, vlfs.in_cksum, vlfs.fnv32(rec[0..vlfs.in_cksum]));
    try t.append(blk, t.walk);
}

/// Serialize `rec` into its 128-B itable slot (fields + trailing checksum).
fn writeInodeRec(out: *[vlfs.inode_len]u8, rec: vlfs.Inode) void {
    @memset(out, 0);
    out[vlfs.in_kind] = rec.kind;
    wr16(out, vlfs.in_nextents, rec.nextents);
    wr32(out, vlfs.in_size, rec.size);
    wr64(out, vlfs.in_mtime, rec.mtime);
    wr64(out, vlfs.in_ctime, rec.ctime);
    for (rec.extents, 0..) |e, i| {
        wr32(out, vlfs.in_extents + i * 8, e.first);
        wr32(out, vlfs.in_extents + i * 8 + 4, e.count);
    }
    wr32(out, vlfs.in_next_ext, rec.next_extent_block);
    wr32(out, vlfs.in_owner, rec.owner); // ADR 0061 D13 (M188b #3187)
    wr32(out, vlfs.in_cksum, vlfs.fnv32(out[0..vlfs.in_cksum]));
}

/// Stage the itable block holding `ino` with `rec` written into its slot.
fn stageInode(t: *Txn, ino: u32, rec: vlfs.Inode) Error!void {
    const blk = t.vol.itable_first + ino / vlfs.inodes_per_block;
    if (blk >= t.vol.itable_first + t.vol.itable_blocks) return error.BadInode;
    try t.readCurrent(blk, t.walk);
    const slot = t.walk[(ino % vlfs.inodes_per_block) * vlfs.inode_len ..][0..vlfs.inode_len];
    writeInodeRec(slot, rec);
    try t.append(blk, t.walk);
}

// ---------------------------------------------------------------------------
// Extent coverage
// ---------------------------------------------------------------------------

/// Read one chained extent block (txn overlay when inside a txn), validate
/// magic/count/checksum, and hand the raw block back in `walk`.
fn readExtentBlock(t: ?*Txn, src: vlfs.SectorSource, vol: *const vlfs.Volume, xb: u32, walk: *Block) Error!void {
    if (xb < vol.data_first or xb >= vol.volume_blocks) return error.ExtentChainCorrupt;
    if (t) |tx| {
        try tx.readCurrent(xb, walk);
    } else if (!src.readBlock(xb, walk)) {
        return error.Io;
    }
    if (rd32(walk, vlfs.xb_magic) != vlfs.magic_extent or
        rd16(walk, vlfs.xb_count) > vlfs.extents_per_block or
        rd32(walk, vlfs.xb_cksum) != vlfs.fnv32(walk[0..vlfs.xb_cksum]))
        return error.ExtentChainCorrupt;
}

/// Total blocks an inode's extent list covers (inline + chain). A chain
/// longer than the D7 bound is corrupt, never silently truncated.
fn coverBlocks(t: ?*Txn, src: vlfs.SectorSource, vol: *const vlfs.Volume, rec: vlfs.Inode, walk: *Block) Error!u64 {
    var total: u64 = 0;
    for (rec.extents[0..rec.nextents]) |e| total += e.count;
    var chain = rec.next_extent_block;
    for (0..vlfs.max_extent_blocks) |_| {
        if (chain == 0) return total;
        try readExtentBlock(t, src, vol, chain, walk);
        const count = rd16(walk, vlfs.xb_count);
        for (0..count) |i| total += rd32(walk, vlfs.xb_extents + i * 8 + 4);
        chain = rd32(walk, vlfs.xb_next);
    }
    return error.ExtentChainCorrupt;
}

/// The txn-aware twin of vlfs.fileBlock: chain reads see this txn's staged
/// extent blocks (a chain block allocated mid-txn has no home contents yet).
fn mapFileBlock(t: ?*Txn, src: vlfs.SectorSource, vol: *const vlfs.Volume, rec: vlfs.Inode, fblock: u32, walk: *Block) Error!?u32 {
    var base: u64 = 0;
    for (rec.extents[0..rec.nextents]) |e| {
        if (e.first < vol.data_first or e.count == 0 or
            @as(u64, e.first) + e.count > vol.volume_blocks) return error.BadExtent;
        if (fblock >= base and fblock < base + e.count) return e.first + @as(u32, @intCast(fblock - base));
        base += e.count;
    }
    var chain = rec.next_extent_block;
    for (0..vlfs.max_extent_blocks) |_| {
        if (chain == 0) return null;
        try readExtentBlock(t, src, vol, chain, walk);
        const count = rd16(walk, vlfs.xb_count);
        for (0..count) |i| {
            const first = rd32(walk, vlfs.xb_extents + i * 8);
            const n = rd32(walk, vlfs.xb_extents + i * 8 + 4);
            if (first < vol.data_first or n == 0 or
                @as(u64, first) + n > vol.volume_blocks) return error.BadExtent;
            if (fblock >= base and fblock < base + n) return first + @as(u32, @intCast(fblock - base));
            base += n;
        }
        chain = rd32(walk, vlfs.xb_next);
    }
    return error.ExtentChainCorrupt;
}

/// The last chain block of rec's extent chain, its staged contents in
/// `walk`, and the live chain depth — null when no chain exists.
fn lastChainBlock(t: *Txn, src: vlfs.SectorSource, vol: *const vlfs.Volume, rec: vlfs.Inode, walk: *Block) Error!?struct { blk: u32, depth: u32 } {
    var prev: u32 = 0;
    var depth: u32 = 0;
    var xb = rec.next_extent_block;
    for (0..vlfs.max_extent_blocks) |_| {
        if (xb == 0) break;
        try readExtentBlock(t, src, vol, xb, walk);
        prev = xb;
        depth += 1;
        xb = rd32(walk, vlfs.xb_next);
    }
    if (xb != 0) return error.ExtentChainCorrupt;
    if (prev == 0) return null;
    return .{ .blk = prev, .depth = depth };
}

/// Append one block to a file's coverage: extend the tail extent when the
/// block is contiguous, take the next inline slot while one is free, then
/// chain extent blocks (bounded at 4 — `extent_overflow`). Chain blocks are
/// allocated from the bbitmap and journaled like every mutation.
fn appendExtentBlock(t: *Txn, src: vlfs.SectorSource, vol: *vlfs.Volume, rec: *vlfs.Inode, b: u32) Error!void {
    // Merge with / extend the inline tail.
    if (rec.nextents == 0) {
        rec.extents[0] = .{ .first = b, .count = 1 };
        rec.nextents = 1;
        return;
    }
    const last = &rec.extents[rec.nextents - 1];
    if (last.first + last.count == b) {
        last.count += 1;
        return;
    }
    if (rec.nextents < vlfs.inline_extents) {
        rec.extents[rec.nextents] = .{ .first = b, .count = 1 };
        rec.nextents += 1;
        return;
    }
    // Inline array is full — the tail lives in the chain (if any).
    if (try lastChainBlock(t, src, vol, rec.*, t.walk)) |tail| {
        const xb = tail.blk;
        const count = rd16(t.walk, vlfs.xb_count);
        if (count > 0) {
            const lf = rd32(t.walk, vlfs.xb_extents + (count - 1) * 8);
            const lc = rd32(t.walk, vlfs.xb_extents + (count - 1) * 8 + 4);
            if (lf + lc == b) {
                wr32(t.walk, vlfs.xb_extents + (count - 1) * 8 + 4, lc + 1);
                wr32(t.walk, vlfs.xb_cksum, vlfs.fnv32(t.walk[0..vlfs.xb_cksum]));
                try t.append(xb, t.walk);
                return;
            }
        }
        if (count < vlfs.extents_per_block) {
            wr32(t.walk, vlfs.xb_extents + count * 8, b);
            wr32(t.walk, vlfs.xb_extents + count * 8 + 4, 1);
            wr16(t.walk, vlfs.xb_count, count + 1);
            wr32(t.walk, vlfs.xb_cksum, vlfs.fnv32(t.walk[0..vlfs.xb_cksum]));
            try t.append(xb, t.walk);
            return;
        }
        // The chain tail is full — one more block, if the bound allows.
        if (tail.depth >= vlfs.max_extent_blocks) return error.ExtentOverflow;
        const nb = try allocBlock(t);
        wr32(t.walk, vlfs.xb_next, nb);
        wr32(t.walk, vlfs.xb_cksum, vlfs.fnv32(t.walk[0..vlfs.xb_cksum]));
        try t.append(xb, t.walk);
        try writeExtentBlock(t, nb, b);
        return;
    }
    // No chain yet — allocate the first extent block.
    const nb = try allocBlock(t);
    rec.next_extent_block = nb;
    try writeExtentBlock(t, nb, b);
}

/// Write a fresh extent block holding one entry {b, 1}.
fn writeExtentBlock(t: *Txn, xb: u32, b: u32) Error!void {
    @memset(t.compose, 0);
    wr32(t.compose, vlfs.xb_magic, vlfs.magic_extent);
    wr16(t.compose, vlfs.xb_count, 1);
    wr32(t.compose, vlfs.xb_extents, b);
    wr32(t.compose, vlfs.xb_extents + 4, 1);
    wr32(t.compose, vlfs.xb_cksum, vlfs.fnv32(t.compose[0..vlfs.xb_cksum]));
    try t.append(xb, t.compose);
}

/// Free every extent-listed block and every chain block of `rec` — the
/// delete/truncate-shrink shared walk. `keep_blocks` bounds the shrink case
/// (the first keep_blocks file blocks stay); delete passes 0.
fn freeCoverage(t: *Txn, src: vlfs.SectorSource, vol: *vlfs.Volume, rec: *vlfs.Inode, keep_blocks: u64) Error!void {
    var base: u64 = 0;
    var new_nextents: u16 = rec.nextents;
    for (0..rec.nextents) |i| {
        const e = rec.extents[i];
        const keep = @min(@as(u64, e.count), if (keep_blocks > base) keep_blocks - base else 0);
        if (keep < e.count) try freeBlocks(t, e.first + @as(u32, @intCast(keep)), e.count - @as(u32, @intCast(keep)));
        if (keep == 0) {
            if (i < new_nextents) new_nextents = @intCast(i);
            rec.extents[i] = .{ .first = 0, .count = 0 };
        } else {
            rec.extents[i].count = @intCast(keep);
        }
        base += e.count;
    }
    rec.nextents = new_nextents;
    // The chain: entries before the cut survive (clipped), the rest drop,
    // and a fully-emptied chain block is freed and unlinked.
    var prev: u32 = 0; // 0 = the link lives in the inode record
    var xb = rec.next_extent_block;
    for (0..vlfs.max_extent_blocks) |_| {
        if (xb == 0) break;
        try readExtentBlock(t, src, vol, xb, t.walk);
        const next = rd32(t.walk, vlfs.xb_next);
        const count = rd16(t.walk, vlfs.xb_count);
        var kept: u16 = 0;
        var i: u16 = 0;
        while (i < count) : (i += 1) {
            const first = rd32(t.walk, vlfs.xb_extents + i * 8);
            const n = rd32(t.walk, vlfs.xb_extents + i * 8 + 4);
            const keep = @min(@as(u64, n), if (keep_blocks > base) keep_blocks - base else 0);
            if (keep < n) try freeBlocks(t, first + @as(u32, @intCast(keep)), n - @as(u32, @intCast(keep)));
            if (keep > 0) {
                // Compact survivor into slot `kept` (entries are dense; a
                // clip boundary makes all later entries droppable).
                if (kept != i) {
                    wr32(t.walk, vlfs.xb_extents + kept * 8, first);
                }
                wr32(t.walk, vlfs.xb_extents + kept * 8 + 4, @intCast(keep));
                kept += 1;
            }
            base += n;
        }
        if (kept == 0) {
            // Whole chain block dropped: unlink + free it.
            if (prev == 0) {
                rec.next_extent_block = next;
            } else {
                try t.readCurrent(prev, t.compose);
                wr32(t.compose, vlfs.xb_next, next);
                wr32(t.compose, vlfs.xb_cksum, vlfs.fnv32(t.compose[0..vlfs.xb_cksum]));
                try t.append(prev, t.compose);
            }
            try freeBlocks(t, xb, 1);
        } else {
            // Zero the dropped tail so a stale slot never reads as live.
            var j: u16 = kept;
            while (j < count) : (j += 1) {
                wr32(t.walk, vlfs.xb_extents + j * 8, 0);
                wr32(t.walk, vlfs.xb_extents + j * 8 + 4, 0);
            }
            if (kept != count) {
                wr16(t.walk, vlfs.xb_count, kept);
                wr32(t.walk, vlfs.xb_cksum, vlfs.fnv32(t.walk[0..vlfs.xb_cksum]));
                try t.append(xb, t.walk);
            }
            prev = xb;
        }
        xb = next;
    }
}

// ---------------------------------------------------------------------------
// Directory rows
// ---------------------------------------------------------------------------

const DirScan = struct {
    /// Absolute slot of the live row named `name` (null = absent).
    hit: ?u32 = null,
    hit_inode: u32 = 0,
    hit_kind: u8 = 0,
    /// First tombstone slot (reusable), or null.
    free: ?u32 = null,
    live: u32 = 0,
    /// Total slots = vlfs.dirSlotCount(dir.size).
    slots: u32,
};

/// Scan a directory's slots, txn-aware: the name match, first tombstone,
/// and live count in one pass. `name` may be empty (count-only scan).
fn dirScan(t: ?*Txn, src: vlfs.SectorSource, vol: *const vlfs.Volume, dir: vlfs.Inode, name: []const u8, walk: *Block) Error!DirScan {
    var scan = DirScan{ .slots = vlfs.dirSlotCount(dir.size) };
    var cur_blk: u32 = std.math.maxInt(u32);
    var abs: u32 = 0;
    while (abs < scan.slots) : (abs += 1) {
        const fblock = abs / vlfs.dirents_per_block;
        const slot = abs % vlfs.dirents_per_block;
        const blk = (try mapFileBlock(t, src, vol, dir, fblock, walk)) orelse return error.BadExtent;
        if (blk != cur_blk) {
            if (t) |tx| {
                try tx.readCurrent(blk, walk);
            } else if (!src.readBlock(blk, walk)) {
                return error.Io;
            }
            cur_blk = blk;
        }
        const row = walk[slot * vlfs.dirent_len ..][0..vlfs.dirent_len];
        const row_ino = rd32(row, vlfs.de_inode);
        if (row_ino == 0) {
            if (scan.free == null) scan.free = abs;
            continue;
        }
        const nl = rd16(row, vlfs.de_name_len);
        if (nl == 0 or nl > vlfs.max_name) return error.BadDirent;
        const row_kind = row[vlfs.de_kind];
        if (row_kind != vlfs.kind_file and row_kind != vlfs.kind_dir) return error.BadDirent;
        if (row[vlfs.de_flags] != 0 or rd64(row, vlfs.de_reserved) != 0) return error.BadDirent;
        const row_name = row[vlfs.de_name..][0..nl];
        if (std.mem.indexOfScalar(u8, row_name, 0) != null or
            std.mem.indexOfScalar(u8, row_name, '/') != null) return error.BadDirent;
        scan.live += 1;
        if (scan.hit == null and std.mem.eql(u8, row_name, name)) {
            scan.hit = abs;
            scan.hit_inode = row_ino;
            scan.hit_kind = row_kind;
        }
    }
    return scan;
}

/// Write one live dirent into a directory at absolute slot `abs`. The slot
/// must exist in the directory's current slot count (growth is
/// `dirGrow`'s job).
fn dirWriteRow(t: *Txn, src: vlfs.SectorSource, vol: *const vlfs.Volume, dir: vlfs.Inode, abs: u32, ino: u32, kind: u8, name: []const u8) Error!void {
    const fblock = abs / vlfs.dirents_per_block;
    const slot = abs % vlfs.dirents_per_block;
    const blk = (try mapFileBlock(t, src, vol, dir, fblock, t.walk)) orelse return error.BadExtent;
    try t.readCurrent(blk, t.compose);
    const row = t.compose[slot * vlfs.dirent_len ..][0..vlfs.dirent_len];
    @memset(row, 0);
    wr32(row, vlfs.de_inode, ino);
    wr16(row, vlfs.de_name_len, @intCast(name.len));
    row[vlfs.de_kind] = kind;
    @memcpy(row[vlfs.de_name..][0..name.len], name);
    try t.append(blk, t.compose);
}

/// Tombstone the row at absolute slot `abs`.
fn dirClearRow(t: *Txn, src: vlfs.SectorSource, vol: *const vlfs.Volume, dir: vlfs.Inode, abs: u32) Error!void {
    const fblock = abs / vlfs.dirents_per_block;
    const slot = abs % vlfs.dirents_per_block;
    const blk = (try mapFileBlock(t, src, vol, dir, fblock, t.walk)) orelse return error.BadExtent;
    try t.readCurrent(blk, t.compose);
    @memset(t.compose[slot * vlfs.dirent_len ..][0..vlfs.dirent_len], 0);
    try t.append(blk, t.compose);
}

/// Grow a directory by one data block (the mkfs convention: dir size is
/// block-aligned, each block adds 15 slots).
fn dirGrow(t: *Txn, src: vlfs.SectorSource, vol: *vlfs.Volume, dir: *vlfs.Inode) Error!void {
    const b = try allocBlock(t); // appended zeroed — an all-tombstone block
    try appendExtentBlock(t, src, vol, dir, b);
    dir.size += vlfs.block_len;
}

// ---------------------------------------------------------------------------
// The mutating operations
// ---------------------------------------------------------------------------

/// Insert `name` → (ino, kind) into directory `dir` (its inode rec is
/// updated in memory — the caller stages it). `scan` is the pre-txn
/// dirScan; the row lands in the first tombstone or a fresh slot, growing
/// the directory by a block when full.
fn dirInsert(t: *Txn, src: vlfs.SectorSource, vol: *vlfs.Volume, dir: *vlfs.Inode, scan: DirScan, ino: u32, kind: u8, name: []const u8, now: u64) Error!void {
    var abs: u32 = undefined;
    if (scan.free) |f| {
        abs = f;
    } else {
        abs = scan.slots;
        // A fresh slot at a 15-row boundary needs a new dirent block.
        // (Slot s lives in block s/15 — the byte test abs*272 >= size
        // forgets the per-block pad and stops one growth short.)
        while (abs >= vlfs.dirSlotCount(dir.size)) try dirGrow(t, src, vol, dir);
    }
    try dirWriteRow(t, src, vol, dir.*, abs, ino, kind, name);
    dir.mtime = now;
    dir.ctime = now;
}

/// Create a file or directory named `name` inside directory `parent_ino`.
/// Returns the new inode number. One transaction: ibitmap bit, itable
/// record, parent dirent (+ parent dir growth and bbitmap bits as needed).
/// The un-owned entry point: mints an unowned (owner_uid 0) inode.
pub fn create(src: vlfs.SectorSource, vol: *vlfs.Volume, parent_ino: u32, name: []const u8, kind: u8, now: u64, walk: *Block, compose: *Block) Error!u32 {
    return createAs(src, vol, parent_ino, name, kind, 0, now, walk, compose);
}

/// M188b (#3187): the set-ownership seam ADR 0061 D13 reserved — the
/// owner_uid is claimed AT create, never changed after (there is no
/// chown: bounded on purpose). `owner` is the creator's uid, supplied by
/// the caller that resolved the acting principal; 0 mints an unowned,
/// world-accessible inode — the mkfs and kernel-actor default.
pub fn createAs(src: vlfs.SectorSource, vol: *vlfs.Volume, parent_ino: u32, name: []const u8, kind: u8, owner: u32, now: u64, walk: *Block, compose: *Block) Error!u32 {
    if (!src.writable()) return error.ReadOnly;
    if (!validName(name)) return error.NameTooLong;
    var parent = try vlfs.readInode(src, vol.*, parent_ino, walk);
    if (parent.kind != vlfs.kind_dir) return error.NotDir;
    // Preflight the named refusals before a single sector is appended.
    const scan = try dirScan(null, src, vol, parent, name, walk);
    if (scan.hit != null) return error.Exists;
    if (scan.free == null and scan.live >= vlfs.max_dirents) return error.DirFull;

    var t = Txn.begin(src, vol, walk, compose);
    const ino = try allocInode(&t);
    var rec = vlfs.Inode{
        .kind = kind,
        .nextents = 0,
        .size = 0,
        .mtime = now,
        .ctime = now,
        .extents = @splat(.{ .first = 0, .count = 0 }),
        .next_extent_block = 0,
        .owner = owner,
    };
    if (kind == vlfs.kind_dir) {
        // A directory is minted with one allocated, zeroed dirent block
        // (the mkfs shape — root got the same at format time).
        const b = try allocBlock(&t);
        rec.extents[0] = .{ .first = b, .count = 1 };
        rec.nextents = 1;
        rec.size = vlfs.block_len;
    }
    try stageInode(&t, ino, rec);
    try dirInsert(&t, src, vol, &parent, scan, ino, kind, name, now);
    try stageInode(&t, parent_ino, parent);
    try t.commit();
    return ino;
}

/// Write `data` at `offset` in file `ino` — one transaction. Extending
/// writes allocate zeroed blocks covering the gap (D3: no sparse files);
/// a write that would need more than the 64-block payload span refuses
/// `txn_too_large`, and past 4 GiB − 1 is `file_too_large`.
pub fn writeFile(src: vlfs.SectorSource, vol: *vlfs.Volume, ino: u32, offset: u64, data: []const u8, now: u64, walk: *Block, compose: *Block) Error!usize {
    return writeFileAs(src, vol, ino, 0, offset, data, now, walk, compose);
}

/// M188b (#3187): the owner-checked write — a nonzero owner_uid admits
/// only the owner or uid_system, else the named not_owner refusal lands
/// BEFORE the first payload is staged (the refused txn never exists).
pub fn writeFileAs(src: vlfs.SectorSource, vol: *vlfs.Volume, ino: u32, caller_uid: u32, offset: u64, data: []const u8, now: u64, walk: *Block, compose: *Block) Error!usize {
    if (!src.writable()) return error.ReadOnly;
    var rec = try vlfs.readInode(src, vol.*, ino, walk);
    if (rec.kind != vlfs.kind_file) return error.IsDir;
    if (!vlfs.ownerAllows(rec.owner, caller_uid)) return error.NotOwner;
    if (data.len == 0) return 0;
    const end = offset + data.len;
    if (end > std.math.maxInt(u32)) return error.FileTooLarge;
    const need_blocks: u64 = (end + vlfs.block_len - 1) / vlfs.block_len;
    var t = Txn.begin(src, vol, walk, compose);
    var covered = try coverBlocks(&t, src, vol, rec, t.walk);
    while (covered < need_blocks) : (covered += 1) {
        const b = try allocBlock(&t);
        try appendExtentBlock(&t, src, vol, &rec, b);
    }
    var f: u32 = @intCast(offset / vlfs.block_len);
    while (f < need_blocks) : (f += 1) {
        const dest = (try mapFileBlock(&t, src, vol, rec, f, t.walk)) orelse return error.BadExtent;
        try t.readCurrent(dest, t.compose);
        const blk_start = @as(u64, f) * vlfs.block_len;
        const lo = @max(offset, blk_start);
        const hi = @min(end, blk_start + vlfs.block_len);
        @memcpy(t.compose[@intCast(lo - blk_start)..][0..@intCast(hi - lo)], data[@intCast(lo - offset)..][0..@intCast(hi - lo)]);
        try t.append(dest, t.compose);
    }
    rec.size = @intCast(@max(@as(u64, rec.size), end));
    rec.mtime = now;
    rec.ctime = now;
    try stageInode(&t, ino, rec);
    try t.commit();
    return data.len;
}

/// Resize file `ino`. Shrinking frees the dropped blocks; growing
/// zero-fills (the partial tail of the old last block is re-zeroed — a
/// shrink can leave live bytes past the size field). A grow spanning more
/// than the payload cap refuses `txn_too_large`.
pub fn truncateFile(src: vlfs.SectorSource, vol: *vlfs.Volume, ino: u32, new_size: u32, now: u64, walk: *Block, compose: *Block) Error!void {
    return truncateFileAs(src, vol, ino, 0, new_size, now, walk, compose);
}

/// M188b (#3187): the owner-checked truncate — same not_owner refusal
/// placement as writeFileAs (a resize is a write).
pub fn truncateFileAs(src: vlfs.SectorSource, vol: *vlfs.Volume, ino: u32, caller_uid: u32, new_size: u32, now: u64, walk: *Block, compose: *Block) Error!void {
    if (!src.writable()) return error.ReadOnly;
    var rec = try vlfs.readInode(src, vol.*, ino, walk);
    if (rec.kind != vlfs.kind_file) return error.IsDir;
    if (!vlfs.ownerAllows(rec.owner, caller_uid)) return error.NotOwner;
    if (new_size == rec.size) return;
    var t = Txn.begin(src, vol, walk, compose);
    const need_blocks: u64 = (@as(u64, new_size) + vlfs.block_len - 1) / vlfs.block_len;
    if (new_size > rec.size) {
        // Re-zero the tail of the block holding the old EOF — a shrink may
        // have left real bytes there, and grown space must read as zeros.
        var covered = try coverBlocks(&t, src, vol, rec, t.walk);
        if (rec.size % vlfs.block_len != 0 and covered > 0) {
            const fb: u32 = @intCast(rec.size / vlfs.block_len);
            const dest = (try mapFileBlock(&t, src, vol, rec, fb, t.walk)) orelse return error.BadExtent;
            try t.readCurrent(dest, t.compose);
            @memset(t.compose[@intCast(rec.size % vlfs.block_len)..], 0);
            try t.append(dest, t.compose);
        }
        while (covered < need_blocks) : (covered += 1) {
            const b = try allocBlock(&t);
            try appendExtentBlock(&t, src, vol, &rec, b);
        }
    } else {
        try freeCoverage(&t, src, vol, &rec, need_blocks);
    }
    rec.size = new_size;
    rec.mtime = now;
    rec.ctime = now;
    try stageInode(&t, ino, rec);
    try t.commit();
}

/// Remove the name `name` from directory `dir_ino` — the file's or empty
/// directory's blocks, chain blocks, inode and dirent all drop in one
/// transaction. Returns the freed inode number (callers invalidate
/// handles/pins that referenced it).
pub fn removeAt(src: vlfs.SectorSource, vol: *vlfs.Volume, dir_ino: u32, name: []const u8, now: u64, walk: *Block, compose: *Block) Error!u32 {
    return removeAtAs(src, vol, dir_ino, name, 0, now, walk, compose);
}

/// M188b (#3187): the owner-checked unlink — the victim inode's owner_uid
/// gates the removal, not the parent directory's. A nonzero owner admits
/// only the owner or uid_system; the named not_owner refusal lands before
/// the first payload (the refused txn never exists).
pub fn removeAtAs(src: vlfs.SectorSource, vol: *vlfs.Volume, dir_ino: u32, name: []const u8, caller_uid: u32, now: u64, walk: *Block, compose: *Block) Error!u32 {
    if (!src.writable()) return error.ReadOnly;
    var parent = try vlfs.readInode(src, vol.*, dir_ino, walk);
    if (parent.kind != vlfs.kind_dir) return error.NotDir;
    const scan = try dirScan(null, src, vol, parent, name, walk);
    const abs = scan.hit orelse return error.NotFound;
    var rec = try vlfs.readInode(src, vol.*, scan.hit_inode, walk);
    if (rec.kind != scan.hit_kind) return error.BadDirent;
    if (!vlfs.ownerAllows(rec.owner, caller_uid)) return error.NotOwner;
    if (rec.kind == vlfs.kind_dir) {
        const inner = try dirScan(null, src, vol, rec, "", walk);
        if (inner.live != 0) return error.NotEmpty;
    }
    var t = Txn.begin(src, vol, walk, compose);
    try dirClearRow(&t, src, vol, parent, abs);
    try freeCoverage(&t, src, vol, &rec, 0);
    try freeInode(&t, scan.hit_inode);
    parent.mtime = now;
    parent.ctime = now;
    try stageInode(&t, dir_ino, parent);
    try t.commit();
    return scan.hit_inode;
}

/// Move `from_name` inside `from_dir` to `to_name` inside `to_dir`. A live
/// target refuses `exists` unless `replace`; a replaced file's blocks free
/// in the same transaction, a replaced directory must be empty
/// (`not_empty`), and kind mismatches are `is_directory`/`not_directory`.
/// Moving a directory into its own subtree refuses `not_directory` — the
/// cycle guard lives here, not in the caller, because the .disk ABI entry
/// (slot-79 pin_rename) reaches renameAt without renamePath's checks.
pub fn renameAt(src: vlfs.SectorSource, vol: *vlfs.Volume, from_dir: u32, from_name: []const u8, to_dir: u32, to_name: []const u8, replace: bool, now: u64, walk: *Block, compose: *Block) Error!void {
    if (!src.writable()) return error.ReadOnly;
    if (!validName(to_name)) return error.NameTooLong;
    var src_parent = try vlfs.readInode(src, vol.*, from_dir, walk);
    if (src_parent.kind != vlfs.kind_dir) return error.NotDir;
    var dst_parent = try vlfs.readInode(src, vol.*, to_dir, walk);
    if (dst_parent.kind != vlfs.kind_dir) return error.NotDir;
    const from_scan = try dirScan(null, src, vol, src_parent, from_name, walk);
    const from_abs = from_scan.hit orelse return error.NotFound;
    // Cycle guard: a directory may not move beneath itself. If the
    // destination directory is inside the moving subtree — or is the
    // moving inode itself — the rename would orphan the subtree; refuse
    // before any mutation.
    if (from_scan.hit_kind == vlfs.kind_dir and
        try dirContains(src, vol, from_scan.hit_inode, to_dir, 0, walk))
        return error.NotDir;
    var victim: ?vlfs.Inode = null;
    var victim_ino: u32 = 0;
    const to_scan = try dirScan(null, src, vol, dst_parent, to_name, walk);
    if (to_scan.hit) |victim_abs| {
        _ = victim_abs;
        if (!replace) return error.Exists;
        // Same slot, same object: renaming a name onto itself is a no-op.
        if (from_dir == to_dir and from_scan.hit.? == to_scan.hit.?) return;
        const rec = try vlfs.readInode(src, vol.*, to_scan.hit_inode, walk);
        if (rec.kind != to_scan.hit_kind) return error.BadDirent;
        if (rec.kind == vlfs.kind_dir and from_scan.hit_kind == vlfs.kind_file) return error.NotDir;
        if (rec.kind == vlfs.kind_file and from_scan.hit_kind == vlfs.kind_dir) return error.IsDir;
        if (rec.kind == vlfs.kind_dir) {
            const inner = try dirScan(null, src, vol, rec, "", walk);
            if (inner.live != 0) return error.NotEmpty;
        }
        victim = rec;
        victim_ino = to_scan.hit_inode;
    } else if (to_scan.free == null and to_scan.live >= vlfs.max_dirents) {
        return error.DirFull;
    }
    var t = Txn.begin(src, vol, walk, compose);
    try dirClearRow(&t, src, vol, src_parent, from_abs);
    if (victim) |*v| {
        try dirClearRow(&t, src, vol, dst_parent, to_scan.hit.?);
        try freeCoverage(&t, src, vol, v, 0);
        try freeInode(&t, victim_ino);
    }
    const scan = try dirScan(&t, src, vol, dst_parent, to_name, walk);
    try dirInsert(&t, src, vol, &dst_parent, scan, from_scan.hit_inode, from_scan.hit_kind, to_name, now);
    // The moved inode's ctime bumps (a name is metadata); parents' mtimes.
    var moved = try vlfs.readInode(src, vol.*, from_scan.hit_inode, walk);
    moved.ctime = now;
    try stageInode(&t, from_scan.hit_inode, moved);
    src_parent.mtime = now;
    src_parent.ctime = now;
    dst_parent.mtime = now;
    dst_parent.ctime = now;
    try stageInode(&t, from_dir, src_parent);
    if (to_dir != from_dir) try stageInode(&t, to_dir, dst_parent);
    try t.commit();
}

// ---------------------------------------------------------------------------
// Path-level wrappers — resolve parents by /-separated canonical path
// ---------------------------------------------------------------------------

/// Split a canonical path into (parent path, leaf name); null when the
/// path names the volume root (no parent, no leaf).
fn splitPath(path: []const u8) ?struct { parent: []const u8, leaf: []const u8 } {
    if (path.len == 0) return null;
    const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse
        return .{ .parent = "", .leaf = path };
    return .{ .parent = path[0..cut], .leaf = path[cut + 1 ..] };
}

/// Create a file at `path` (all but the last component must resolve to
/// directories). Returns the new inode.
pub fn createPath(src: vlfs.SectorSource, vol: *vlfs.Volume, path: []const u8, kind: u8, now: u64, walk: *Block, compose: *Block) Error!u32 {
    return createPathAs(src, vol, path, kind, 0, now, walk, compose);
}

/// M188b (#3187): create at `path` minting the inode's owner_uid — the
/// claim is the create itself, the only set-ownership verb (see createAs).
pub fn createPathAs(src: vlfs.SectorSource, vol: *vlfs.Volume, path: []const u8, kind: u8, owner: u32, now: u64, walk: *Block, compose: *Block) Error!u32 {
    const parts = splitPath(path) orelse return error.Exists; // root exists
    const parent = try vlfs.lookup(src, vol.*, parts.parent, walk);
    if (parent.kind != vlfs.kind_dir) return error.NotDir;
    return createAs(src, vol, parent.inode, parts.leaf, kind, owner, now, walk, compose);
}

/// Remove `path` (file or empty directory).
pub fn removePath(src: vlfs.SectorSource, vol: *vlfs.Volume, path: []const u8, now: u64, walk: *Block, compose: *Block) Error!u32 {
    return removePathAs(src, vol, path, 0, now, walk, compose);
}

/// M188b (#3187): remove `path` as `caller_uid` — the victim's owner_uid
/// gates the unlink inside removeAtAs.
pub fn removePathAs(src: vlfs.SectorSource, vol: *vlfs.Volume, path: []const u8, caller_uid: u32, now: u64, walk: *Block, compose: *Block) Error!u32 {
    const parts = splitPath(path) orelse return error.IsDir; // the root is not a name
    const parent = try vlfs.lookup(src, vol.*, parts.parent, walk);
    if (parent.kind != vlfs.kind_dir) return error.NotDir;
    return removeAtAs(src, vol, parent.inode, parts.leaf, caller_uid, now, walk, compose);
}

/// Rename `old` to `new`. Both may name different directories; moving a
/// directory into its own subtree refuses `not_directory` (the cycle has
/// no ADR refusal name — the EINVAL row covers it).
pub fn renamePath(src: vlfs.SectorSource, vol: *vlfs.Volume, old: []const u8, new: []const u8, replace: bool, now: u64, walk: *Block, compose: *Block) Error!void {
    const op = splitPath(old) orelse return error.IsDir; // the root cannot move
    const np = splitPath(new) orelse return error.IsDir; // nor be a rename target
    const src_parent = try vlfs.lookup(src, vol.*, op.parent, walk);
    if (src_parent.kind != vlfs.kind_dir) return error.NotDir;
    const dst_parent = try vlfs.lookup(src, vol.*, np.parent, walk);
    if (dst_parent.kind != vlfs.kind_dir) return error.NotDir;
    return renameAt(src, vol, src_parent.inode, op.leaf, dst_parent.inode, np.leaf, replace, now, walk, compose);
}

/// Is `target` inside the directory tree rooted at `root`? Bounded by the
/// D7 depth limit — a deeper tree is refused `depth_overflow`-adjacent
/// (the read path would fail it first; here the bound just cuts).
fn dirContains(src: vlfs.SectorSource, vol: *const vlfs.Volume, root: u32, target: u32, depth: u32, walk: *Block) Error!bool {
    if (root == target) return true;
    if (depth >= 8) return false; // beyond the D7 bound nothing valid lives
    const rec = try vlfs.readInode(src, vol.*, root, walk);
    if (rec.kind != vlfs.kind_dir) return false;
    var iter = vlfs.DirIter.init(src, vol.*, rec, walk);
    while (try iter.next()) |d| {
        if (d.inode == target) return true;
        if (d.kind == vlfs.kind_dir) {
            if (try dirContains(src, vol, d.inode, target, depth + 1, walk)) return true;
        }
    }
    return false;
}

/// fsync (slot 77) on the volume: one device FLUSH, waited out — the real
/// barrier ADR D4 measures durability against. Every successful mutation
/// is already committed; the flush makes the caller's line honest on the
/// wire the same way /host's fsync does.
pub fn sync(src: vlfs.SectorSource) Error!void {
    if (!src.flush()) return error.Io;
}

// ---------------------------------------------------------------------------
// Host tests — class A over a recording in-memory device.
//
// RecDisk is the fixture the review notes ask for: every sector write is
// applied AND logged, every FLUSH is logged, so a test can (a) prove the
// D4 ordering on the wire and (b) enumerate every legal crash state — all
// writes up to the last completed FLUSH plus any subset after it — and
// replay each through the real mount path.
// ---------------------------------------------------------------------------

const test_img_bytes: usize = 16 << 20;
const empty_regions = @embedFile("testdata/empty-16m.regions");

const Op = struct {
    flush: bool = false,
    lba: u64 = 0,
    data: [vlfs.sector_len]u8 = undefined,
};

/// The recorded op log — module-level BSS (too big for any stack).
var op_log: [32768]Op = undefined;
var op_log_n: usize = 0;

/// In-memory VLFS-sized device: writes apply to `img` AND append to the
/// shared op log when `record` is set; flushes log as markers.
const RecDisk = struct {
    img: []u8,
    record: bool = true,

    fn source(d: *RecDisk) vlfs.SectorSource {
        return .{
            .ctx = d,
            .total_sectors = @intCast(d.img.len / vlfs.sector_len),
            .readFn = readFn,
            .writeFn = writeFn,
            .flushFn = flushFn,
        };
    }

    fn readFn(ctx: ?*anyopaque, lba: u64, out: *[vlfs.sector_len]u8) bool {
        const d: *RecDisk = @ptrCast(@alignCast(ctx.?));
        const off = lba * vlfs.sector_len;
        if (off + vlfs.sector_len > d.img.len) return false;
        @memcpy(out, d.img[off..][0..vlfs.sector_len]);
        return true;
    }

    fn writeFn(ctx: ?*anyopaque, lba: u64, data: *const [vlfs.sector_len]u8) bool {
        const d: *RecDisk = @ptrCast(@alignCast(ctx.?));
        const off = lba * vlfs.sector_len;
        if (off + vlfs.sector_len > d.img.len) return false;
        @memcpy(d.img[off..][0..vlfs.sector_len], data);
        if (d.record and op_log_n < op_log.len) {
            op_log[op_log_n] = .{ .flush = false, .lba = lba, .data = data.* };
            op_log_n += 1;
        }
        return true;
    }

    fn flushFn(ctx: ?*anyopaque) bool {
        const d: *RecDisk = @ptrCast(@alignCast(ctx.?));
        if (d.record and op_log_n < op_log.len) {
            op_log[op_log_n] = .{ .flush = true };
            op_log_n += 1;
        }
        return true;
    }
};

fn buildImage(regions: []const u8, img: []u8) !void {
    @memset(img, 0);
    var it = std.mem.splitScalar(u8, regions, '\n');
    var lines: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (lines == 0) {
            if (!std.mem.eql(u8, line, "vlfs-regions 1")) return error.BadFixture;
            lines += 1;
            continue;
        }
        if (lines == 1) {
            const n = try std.fmt.parseInt(usize, line[6..], 10);
            if (n != img.len) return error.BadFixture;
            lines += 1;
            continue;
        }
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadFixture;
        const off = try std.fmt.parseInt(usize, line[0..sp], 10);
        _ = try std.fmt.hexToBytes(img[off..][0..hexs_len(line, sp)], line[sp + 1 ..]);
        lines += 1;
    }
}

fn hexs_len(line: []const u8, sp: usize) usize {
    return (line.len - sp - 1) / 2;
}

var img_a: [test_img_bytes]u8 align(64) = undefined;
var img_b: [test_img_bytes]u8 align(64) = undefined;
var img_crash: [test_img_bytes]u8 align(64) = undefined;
var disk_a: RecDisk = .{ .img = &img_a };
var disk_b: RecDisk = .{ .img = &img_b };
var t_walk: Block align(64) = undefined;
var t_compose: Block align(64) = undefined;

const test_now: u64 = 1_800_000_000;

/// A digest of the volume's whole logical state — name-sorted recursive
/// walk hashing each dirent's (kind, name, size) and each file's bytes.
/// Two states compare equal iff the guest would observe them identically.
fn treeDigest(src: vlfs.SectorSource, vol: *const vlfs.Volume, ino: u32, depth: u32, h: *u64, walk: *Block) Error!void {
    const rec = try vlfs.readInode(src, vol.*, ino, walk);
    var iter = vlfs.DirIter.init(src, vol.*, rec, walk);
    while (try iter.next()) |d| {
        for (d.nameSlice()) |c| {
            h.* ^= c;
            h.* *%= 0x100000001b3;
        }
        h.* ^= d.kind;
        h.* *%= 0x100000001b3;
        const child = try vlfs.readInode(src, vol.*, d.inode, walk);
        h.* ^= child.size;
        h.* *%= 0x100000001b3;
        if (d.kind == vlfs.kind_dir) {
            if (depth < 8) try treeDigest(src, vol, d.inode, depth + 1, h, walk);
        } else {
            // Hash the file's bytes.
            var off: u64 = 0;
            var buf: [1024]u8 = undefined;
            while (true) {
                const n = try vlfs.read(src, vol.*, d.inode, off, &buf, walk);
                if (n == 0) break;
                for (buf[0..n]) |c| {
                    h.* ^= c;
                    h.* *%= 0x100000001b3;
                }
                off += n;
            }
        }
    }
}

fn mountDigest(img: []u8, walk: *Block) Error!u64 {
    var disk = RecDisk{ .img = img, .record = false };
    const src = disk.source();
    const vol = try vlfs.mount(src, walk);
    var h: u64 = 1469598103934665603;
    try treeDigest(src, &vol, vlfs.root_inode, 0, &h, walk);
    return h;
}

// --- Operation coverage -----------------------------------------------------

test "vlfs write: create + write + truncate + rename + delete round-trips through the file ops" {
    try buildImage(empty_regions, &img_a);
    var disk = RecDisk{ .img = &img_a, .record = false };
    const src = disk.source();
    var vol = try vlfs.mount(src, &t_walk);

    // create a file, write two blocks, read back across the boundary.
    const ino = try create(src, &vol, vlfs.root_inode, "HELLO.TXT", vlfs.kind_file, test_now, &t_walk, &t_compose);
    try std.testing.expect(ino >= 2);
    var payload: [6000]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i % 251);
    try std.testing.expectEqual(@as(usize, 6000), try writeFile(src, &vol, ino, 0, &payload, test_now, &t_walk, &t_compose));
    var out: [6000]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6000), try vlfs.read(src, vol, ino, 0, &out, &t_walk));
    try std.testing.expectEqualSlices(u8, &payload, &out);

    // Extending write past EOF leaves a zeroed gap; the 4 tail bytes land
    // at file offsets 9000..9003, i.e. just past the gap window's end.
    _ = try writeFile(src, &vol, ino, 9000, "tail", test_now, &t_walk, &t_compose);
    var gap: [3004]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3004), try vlfs.read(src, vol, ino, 6000, &gap, &t_walk));
    try std.testing.expect(std.mem.allEqual(u8, gap[0..3000], 0));
    try std.testing.expectEqualSlices(u8, "tail", gap[3000..3004]);

    // Truncate shrink keeps the prefix; grow zero-fills.
    try truncateFile(src, &vol, ino, 3, test_now, &t_walk, &t_compose);
    try std.testing.expectEqual(@as(usize, 3), try vlfs.read(src, vol, ino, 0, &out, &t_walk));
    try std.testing.expectEqualSlices(u8, payload[0..3], out[0..3]);
    try truncateFile(src, &vol, ino, 4096 + 5, test_now, &t_walk, &t_compose);
    var grown: [4101]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4101), try vlfs.read(src, vol, ino, 0, &grown, &t_walk));
    try std.testing.expectEqualSlices(u8, payload[0..3], grown[0..3]);
    try std.testing.expect(std.mem.allEqual(u8, grown[3..], 0));

    // mkdir + nested create + rename + remove.
    const dir = try create(src, &vol, vlfs.root_inode, "SUB", vlfs.kind_dir, test_now, &t_walk, &t_compose);
    _ = try create(src, &vol, dir, "INNER.TXT", vlfs.kind_file, test_now, &t_walk, &t_compose);
    try renamePath(src, &vol, "HELLO.TXT", "SUB/MOVED.TXT", false, test_now, &t_walk, &t_compose);
    try std.testing.expectError(error.NotFound, vlfs.lookup(src, vol, "HELLO.TXT", &t_walk));
    const moved = try vlfs.lookup(src, vol, "SUB/MOVED.TXT", &t_walk);
    try std.testing.expectEqual(ino, moved.inode);
    _ = try removePath(src, &vol, "SUB/MOVED.TXT", test_now, &t_walk, &t_compose);
    _ = try removePath(src, &vol, "SUB/INNER.TXT", test_now, &t_walk, &t_compose);
    _ = try removePath(src, &vol, "SUB", test_now, &t_walk, &t_compose);
    try std.testing.expectError(error.NotFound, vlfs.lookup(src, vol, "SUB", &t_walk));

    // A fresh mount sees the same tree (eager checkpoint — reads never
    // consult the journal): the root is empty again.
    const h = try mountDigest(&img_a, &t_walk);
    try std.testing.expectEqual(@as(u64, 1469598103934665603), h);
}

// #2376: slot-79 pin_rename reaches renameAt without renamePath's checks,
// so the directory-cycle guard lives in renameAt itself.
test "vlfs write: renameAt refuses a directory into its own subtree" {
    try buildImage(empty_regions, &img_a);
    var disk = RecDisk{ .img = &img_a, .record = false };
    const src = disk.source();
    var vol = try vlfs.mount(src, &t_walk);

    const docs = try create(src, &vol, vlfs.root_inode, "DOCS", vlfs.kind_dir, test_now, &t_walk, &t_compose);
    const old = try create(src, &vol, docs, "OLD", vlfs.kind_dir, test_now, &t_walk, &t_compose);
    const deep = try create(src, &vol, old, "DEEP", vlfs.kind_dir, test_now, &t_walk, &t_compose);

    // DOCS into its child, its grandchild, and itself — all refuse.
    try std.testing.expectError(error.NotDir, renameAt(src, &vol, vlfs.root_inode, "DOCS", old, "ARCH", false, test_now, &t_walk, &t_compose));
    try std.testing.expectError(error.NotDir, renameAt(src, &vol, vlfs.root_inode, "DOCS", deep, "ARCH", false, test_now, &t_walk, &t_compose));
    try std.testing.expectError(error.NotDir, renameAt(src, &vol, vlfs.root_inode, "DOCS", docs, "ARCH", false, test_now, &t_walk, &t_compose));
    // The path entry gets the same refusal now that renameAt owns the guard.
    try std.testing.expectError(error.NotDir, renamePath(src, &vol, "DOCS", "DOCS/OLD/ARCH", false, test_now, &t_walk, &t_compose));

    // The refusals committed nothing: the tree is untouched.
    const untouched = try vlfs.lookup(src, vol, "DOCS/OLD/DEEP", &t_walk);
    try std.testing.expectEqual(deep, untouched.inode);

    // Legal moves still work: a file into a subdir, a directory renamed
    // at the same level.
    _ = try create(src, &vol, docs, "F.TXT", vlfs.kind_file, test_now, &t_walk, &t_compose);
    try renameAt(src, &vol, docs, "F.TXT", old, "G.TXT", false, test_now, &t_walk, &t_compose);
    try renameAt(src, &vol, vlfs.root_inode, "DOCS", vlfs.root_inode, "DOC2", false, test_now, &t_walk, &t_compose);
    const moved = try vlfs.lookup(src, vol, "DOC2/OLD/G.TXT", &t_walk);
    try std.testing.expectEqual(vlfs.kind_file, moved.kind);
}

test "vlfs write: named refusals — exists, not_empty, name_too_long, no_inodes" {
    try buildImage(empty_regions, &img_a);
    var disk = RecDisk{ .img = &img_a, .record = false };
    const src = disk.source();
    var vol = try vlfs.mount(src, &t_walk);

    _ = try create(src, &vol, vlfs.root_inode, "A.TXT", vlfs.kind_file, test_now, &t_walk, &t_compose);
    try std.testing.expectError(error.Exists, create(src, &vol, vlfs.root_inode, "A.TXT", vlfs.kind_file, test_now, &t_walk, &t_compose));
    // The volume root is not a removable name.
    try std.testing.expectError(error.IsDir, removePath(src, &vol, "", test_now, &t_walk, &t_compose));

    // A 256-char name refuses by name.
    var long_name: [256]u8 = @splat('x');
    try std.testing.expectError(error.NameTooLong, create(src, &vol, vlfs.root_inode, &long_name, vlfs.kind_file, test_now, &t_walk, &t_compose));

    // Exhaust the inode table: 16 MiB has 256 inodes — 0 is reserved, 1 is
    // root, A.TXT took one, so 253 more creates fill it exactly.
    var i: u32 = 0;
    var name_buf: [16]u8 = undefined;
    while (i < 253) : (i += 1) {
        const name = std.fmt.bufPrint(&name_buf, "f{x}", .{i}) catch unreachable;
        _ = try create(src, &vol, vlfs.root_inode, name, vlfs.kind_file, test_now, &t_walk, &t_compose);
    }
    try std.testing.expectError(error.NoInodes, create(src, &vol, vlfs.root_inode, "one-too-many", vlfs.kind_file, test_now, &t_walk, &t_compose));
}

test "vlfs write: read_only_partition on a source that cannot write" {
    try buildImage(empty_regions, &img_a);
    var ro = RecDisk{ .img = &img_a, .record = false };
    var src = ro.source();
    src.writeFn = null;
    src.flushFn = null;
    var vol = try vlfs.mount(src, &t_walk);
    try std.testing.expectError(error.ReadOnly, create(src, &vol, vlfs.root_inode, "X", vlfs.kind_file, test_now, &t_walk, &t_compose));
    try std.testing.expectError(error.Io, sync(src));
}

test "vlfs write: txn_too_large and file_too_large refuse by name" {
    try buildImage(empty_regions, &img_a);
    var disk = RecDisk{ .img = &img_a, .record = false };
    const src = disk.source();
    var vol = try vlfs.mount(src, &t_walk);
    const ino = try create(src, &vol, vlfs.root_inode, "BIG.BIN", vlfs.kind_file, test_now, &t_walk, &t_compose);
    // A grow past the 64-payload span is txn_too_large; past 4 GiB-1 is file_too_large.
    try std.testing.expectError(error.TxnTooLarge, truncateFile(src, &vol, ino, 80 * vlfs.block_len, test_now, &t_walk, &t_compose));
    var b: [1]u8 = .{0};
    try std.testing.expectError(error.FileTooLarge, writeFile(src, &vol, ino, std.math.maxInt(u32), &b, test_now, &t_walk, &t_compose));
    // The pre-write state survived: the file still reads empty.
    const st = try vlfs.stat(src, vol, ino, &t_walk);
    try std.testing.expectEqual(@as(u32, 0), st.size);
}

test "vlfs write: no_space fills the device honestly, earlier files intact" {
    try buildImage(empty_regions, &img_a);
    var disk = RecDisk{ .img = &img_a, .record = false };
    const src = disk.source();
    var vol = try vlfs.mount(src, &t_walk);
    const small = try create(src, &vol, vlfs.root_inode, "KEEP.TXT", vlfs.kind_file, test_now, &t_walk, &t_compose);
    _ = try writeFile(src, &vol, small, 0, "pre-write content", test_now, &t_walk, &t_compose);
    const big = try create(src, &vol, vlfs.root_inode, "FILL.BIN", vlfs.kind_file, test_now, &t_walk, &t_compose);
    var chunk: [32 * vlfs.block_len]u8 = undefined; // 32-block writes, under the span
    @memset(&chunk, 0xab);
    var wrote_ok = true;
    var i: u32 = 0;
    while (wrote_ok) : (i += 1) {
        _ = writeFile(src, &vol, big, @as(u64, i) * chunk.len, &chunk, test_now, &t_walk, &t_compose) catch |err| {
            try std.testing.expectEqual(error.NoSpace, err);
            wrote_ok = false;
        };
        if (i > 200) return error.LoopBoundExceeded;
    }
    // The surviving file is byte-identical — the refusal is honest.
    var out: [17]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 17), try vlfs.read(src, vol, small, 0, &out, &t_walk));
    try std.testing.expectEqualSlices(u8, "pre-write content", &out);
}

// --- The D4 ordering proof --------------------------------------------------

test "vlfs write: commit ordering — journal first, FLUSH, checkpoint, FLUSH, superblock, FLUSH" {
    try buildImage(empty_regions, &img_a);
    var disk = RecDisk{ .img = &img_a };
    const src = disk.source();
    var vol = try vlfs.mount(src, &t_walk);
    const ino = try create(src, &vol, vlfs.root_inode, "A.TXT", vlfs.kind_file, test_now, &t_walk, &t_compose);
    // Measure ONE transaction — the write's commit shape.
    op_log_n = 0;
    _ = try writeFile(src, &vol, ino, 0, "d4-order", test_now, &t_walk, &t_compose);

    // Collect the flush boundaries in the op log.
    var flush_idx: [8]usize = undefined;
    var nf: usize = 0;
    for (op_log[0..op_log_n], 0..) |op, i| {
        if (op.flush) {
            flush_idx[nf] = i;
            nf += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), nf); // commit, checkpoint, superblock

    const jlo: u64 = @as(u64, vol.journal_first) * vlfs.sectors_per_block;
    const jhi: u64 = @as(u64, vol.journal_first + vol.journal_blocks) * vlfs.sectors_per_block;
    // Phase 1 (before flush 1): only journal-region sector writes.
    for (op_log[0..flush_idx[0]]) |op| {
        try std.testing.expect(!op.flush);
        try std.testing.expect(op.lba >= jlo and op.lba < jhi);
    }
    // Phase 2 (flushes 1→2): home-block writes only — nothing in the
    // journal, nothing at a superblock slot.
    for (op_log[flush_idx[0] + 1 .. flush_idx[1]]) |op| {
        try std.testing.expect(!op.flush);
        try std.testing.expect(!(op.lba >= jlo and op.lba < jhi));
        try std.testing.expect(op.lba >= 2 * vlfs.sectors_per_block);
    }
    // Phase 3 (flushes 2→3): the ping-ponged superblock slot only.
    for (op_log[flush_idx[1] + 1 .. flush_idx[2]]) |op| {
        try std.testing.expect(!op.flush);
        try std.testing.expect(op.lba < 2 * vlfs.sectors_per_block);
    }
    // Nothing after the last flush.
    for (op_log[flush_idx[2] + 1 .. op_log_n]) |op| {
        try std.testing.expect(!op.flush);
    }
    // The COMMIT record landed before the commit flush: the last journal
    // write was at block pos+1+n.
    const last_journal = op_log[flush_idx[0] - vlfs.sectors_per_block];
    try std.testing.expect(!last_journal.flush);
}

// --- Crash-state enumeration (the ADR D5 contract) --------------------------

/// Replay a recorded op log onto a base image: `flush_k` flushes completed
/// (all writes before the k-th FLUSH are durable), plus each write in the
/// window after it whose bit is set in `tail_mask`.
fn crashImage(base: []const u8, flush_k: usize, tail_mask: u64, out: []u8) void {
    @memcpy(out, base);
    var seen: usize = 0;
    var boundary: usize = 0;
    for (op_log[0..op_log_n], 0..) |op, i| {
        if (op.flush) {
            seen += 1;
            if (seen == flush_k) {
                boundary = i + 1;
                break;
            }
        }
    }
    // Everything before the boundary is durable.
    for (op_log[0..boundary]) |op| {
        if (!op.flush) {
            const off = op.lba * vlfs.sector_len;
            @memcpy(out[off..][0..vlfs.sector_len], &op.data);
        }
    }
    // The window after it lands per tail_mask bits.
    var bit: usize = 0;
    for (op_log[boundary..op_log_n]) |op| {
        if (op.flush) break; // the next FLUSH completes the crash window
        if ((tail_mask >> @intCast(bit)) & 1 != 0) {
            const off = op.lba * vlfs.sector_len;
            @memcpy(out[off..][0..vlfs.sector_len], &op.data);
        }
        bit += 1;
    }
}

test "vlfs write: every legal crash state replays to pre- or post-txn, never a third state" {
    try buildImage(empty_regions, &img_a);
    var disk = RecDisk{ .img = &img_a };
    const src = disk.source();
    var vol = try vlfs.mount(src, &t_walk);

    // A representative multi-payload op: mkdir + create + write (3 txns).
    // The interesting transaction is the LAST one — snapshot pre-state
    // after the first two ops so the crash enumeration brackets exactly
    // the third commit.
    const dir = try create(src, &vol, vlfs.root_inode, "DIR", vlfs.kind_dir, test_now, &t_walk, &t_compose);
    const ino = try create(src, &vol, dir, "F.TXT", vlfs.kind_file, test_now, &t_walk, &t_compose);
    _ = try writeFile(src, &vol, ino, 0, "stable base\n", test_now, &t_walk, &t_compose);

    @memcpy(&img_b, &img_a); // pre-image of the measured transaction
    const pre_digest = try mountDigest(&img_b, &t_walk);

    op_log_n = 0;
    var payload: [5000]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i % 97);
    _ = try writeFile(src, &vol, ino, 3000, &payload, test_now, &t_walk, &t_compose);
    const post_digest = try mountDigest(&img_a, &t_walk);
    try std.testing.expect(pre_digest != post_digest);

    // Flush boundaries in the op log.
    var flush_idx: [16]usize = undefined;
    var nf: usize = 0;
    for (op_log[0..op_log_n], 0..) |op, i| {
        if (op.flush) {
            flush_idx[nf] = i;
            nf += 1;
        }
    }
    try std.testing.expect(nf >= 3);

    // Enumerate: for each completed-flush boundary k (0 = none), apply the
    // durable prefix plus each legal tail subset — empty, every singleton,
    // every leave-one-out, and full. Replay through the real mount path.
    var cases: usize = 0;
    for (0..nf + 1) |k| {
        const boundary: usize = if (k == 0) 0 else flush_idx[k - 1] + 1;
        const limit: usize = if (k < nf) flush_idx[k] else op_log_n;
        var window: usize = 0;
        for (op_log[boundary..limit]) |op| {
            if (!op.flush) window += 1;
        }
        try std.testing.expect(window <= 63);
        const full: u64 = (@as(u64, 1) << @intCast(window)) - 1;
        // The legal family is every subset of the post-flush window; 2^w is
        // unreachable, so the bounded sample covers its structurally
        // distinct edges: empty and full, every singleton (each write alone
        // is insufficient to forge a commit), every leave-one-out (each
        // write's loss), and every in-order prefix and suffix (the shapes
        // real devices actually retire writes in).
        var masks: [256]u64 = undefined;
        var nm: usize = 0;
        masks[nm] = 0;
        nm += 1;
        masks[nm] = full;
        nm += 1;
        for (0..window) |b| {
            masks[nm] = @as(u64, 1) << @intCast(b);
            nm += 1;
            masks[nm] = full & ~(@as(u64, 1) << @intCast(b));
            nm += 1;
        }
        var keep: usize = 1;
        while (keep < window) : (keep += 1) {
            const prefix = (@as(u64, 1) << @intCast(keep)) - 1;
            masks[nm] = prefix;
            nm += 1;
            masks[nm] = full & ~prefix;
            nm += 1;
        }
        for (masks[0..nm]) |mask| {
            crashImage(&img_b, k, mask, &img_crash);
            const d = try mountDigest(&img_crash, &t_walk);
            try std.testing.expect(d == pre_digest or d == post_digest);
            cases += 1;
        }
    }
    try std.testing.expect(cases > 200); // real enumeration breadth
}

test "vlfs write: identical operation sequences produce identical images" {
    try buildImage(empty_regions, &img_a);
    try buildImage(empty_regions, &img_b);
    var da = RecDisk{ .img = &img_a, .record = false };
    var db = RecDisk{ .img = &img_b, .record = false };
    var va = try vlfs.mount(da.source(), &t_walk);
    var vb = try vlfs.mount(db.source(), &t_walk);
    const ops = struct {
        fn run(src: vlfs.SectorSource, vol: *vlfs.Volume, w: *Block, c: *Block) Error!void {
            const d = try create(src, vol, vlfs.root_inode, "D", vlfs.kind_dir, test_now, w, c);
            const f = try create(src, vol, d, "X.TXT", vlfs.kind_file, test_now, w, c);
            _ = try writeFile(src, vol, f, 0, "deterministic", test_now, w, c);
            try renamePath(src, vol, "D/X.TXT", "D/Y.TXT", false, test_now, w, c);
            try truncateFile(src, vol, f, 5, test_now, w, c);
        }
    };
    try ops.run(da.source(), &va, &t_walk, &t_compose);
    try ops.run(db.source(), &vb, &t_walk, &t_compose);
    // Byte-identical images — journal tail included — is the determinism
    // receipt the issue asks for.
    try std.testing.expectEqualSlices(u8, &img_a, &img_b);
}

// --- M188b (#3187): owner_uid enforcement ------------------------------------

test "vlfs write: owner_uid — cross-uid refusals, owner proceeds, uid 0 stays world" {
    try buildImage(empty_regions, &img_a);
    var disk = RecDisk{ .img = &img_a, .record = false };
    const src = disk.source();
    var vol = try vlfs.mount(src, &t_walk);

    const uid_agent: u32 = 2000;
    const uid_user: u32 = 1000;

    // The create claims the owner (the only set-ownership verb): an inode
    // minted for uid_agent carries owner_uid 2000 in its record and stat.
    const agent_file = try createAs(src, &vol, vlfs.root_inode, "AGENT.TXT", vlfs.kind_file, uid_agent, test_now, &t_walk, &t_compose);
    const rec = try vlfs.readInode(src, vol, agent_file, &t_walk);
    try std.testing.expectEqual(uid_agent, rec.owner);
    const st = try vlfs.stat(src, vol, agent_file, &t_walk);
    try std.testing.expectEqual(uid_agent, st.owner);
    _ = try writeFileAs(src, &vol, agent_file, uid_agent, 0, "agent-only", test_now, &t_walk, &t_compose);

    // Cross-uid read/write/truncate/unlink all refuse not_owner.
    var buf: [32]u8 = undefined;
    try std.testing.expectError(error.NotOwner, vlfs.readAs(src, vol, agent_file, uid_user, 0, &buf, &t_walk));
    try std.testing.expectError(error.NotOwner, writeFileAs(src, &vol, agent_file, uid_user, 0, "x", test_now, &t_walk, &t_compose));
    try std.testing.expectError(error.NotOwner, truncateFileAs(src, &vol, agent_file, uid_user, 2, test_now, &t_walk, &t_compose));
    try std.testing.expectError(error.NotOwner, removeAtAs(src, &vol, vlfs.root_inode, "AGENT.TXT", uid_user, test_now, &t_walk, &t_compose));

    // The owner proceeds on every path; uid_system (0) proceeds too.
    try std.testing.expectEqual(@as(usize, 10), try vlfs.readAs(src, vol, agent_file, uid_agent, 0, &buf, &t_walk));
    try std.testing.expectEqualSlices(u8, "agent-only", buf[0..10]);
    try std.testing.expectEqual(@as(usize, 10), try vlfs.readAs(src, vol, agent_file, 0, 0, &buf, &t_walk));
    _ = try writeFileAs(src, &vol, agent_file, 0, 0, "sys", test_now, &t_walk, &t_compose);
    try truncateFileAs(src, &vol, agent_file, 0, 3, test_now, &t_walk, &t_compose);

    // An unowned file (owner_uid 0 — the mkfs/system default) is
    // world-accessible to every uid on every path.
    const world = try createAs(src, &vol, vlfs.root_inode, "WORLD.TXT", vlfs.kind_file, 0, test_now, &t_walk, &t_compose);
    _ = try writeFileAs(src, &vol, world, uid_user, 0, "everyone", test_now, &t_walk, &t_compose);
    _ = try writeFileAs(src, &vol, world, uid_agent, 8, "+agent", test_now, &t_walk, &t_compose);
    var wbuf: [64]u8 = undefined;
    const n = try vlfs.readAs(src, vol, world, uid_user, 0, &wbuf, &t_walk);
    try std.testing.expectEqualSlices(u8, "everyone+agent", wbuf[0..n]);

    // A third, unrelated uid is refused the same named way; a uid_user
    // file refuses uid_agent symmetrically.
    const user_file = try createAs(src, &vol, vlfs.root_inode, "USER.TXT", vlfs.kind_file, uid_user, test_now, &t_walk, &t_compose);
    _ = try writeFileAs(src, &vol, user_file, uid_user, 0, "mine", test_now, &t_walk, &t_compose);
    try std.testing.expectError(error.NotOwner, vlfs.readAs(src, vol, user_file, uid_agent, 0, &buf, &t_walk));
    try std.testing.expectError(error.NotOwner, vlfs.readAs(src, vol, user_file, 4242, 0, &buf, &t_walk));

    // Owner unlink proceeds; the name is gone.
    _ = try removeAtAs(src, &vol, vlfs.root_inode, "AGENT.TXT", uid_agent, test_now, &t_walk, &t_compose);
    try std.testing.expectError(error.NotFound, vlfs.lookup(src, vol, "AGENT.TXT", &t_walk));
}
