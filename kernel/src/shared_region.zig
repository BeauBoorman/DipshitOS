//! M33 SB1 (claim 7418, ADR 0016 D2): shared-region CAPABILITY POLICY, frozen
//! before the capability is built.
//!
//! This module is PURE POLICY — it makes the D2 security/capability DECISIONS
//! (who may read whose surface, read-only-vs-writable grant, who gets revoked
//! on teardown, and when a region is freed) as deterministic, host-testable
//! functions with NO effect on the MMU or any page table. It is the frozen,
//! runnable spec that SB2 (claim 8878) implements into `sys_mmap`: SB2 wires
//! these decisions to actual `mmu.map_user_cow_page` leaves under two EL0
//! roots (owner writable, WM read-only) and to `unmap_user_page` on teardown.
//! The physical mapping set (owner va, page count, contiguous pa base) and
//! the single peer seat are carried here as SB2 data fields; the DECISION
//! functions below stay pure (no MMU effect).
//!
//! The capability model (ADR 0016 D2):
//!   - Requestor-vs-owner. A shared surface is created and OWNED by the app
//!     that renders into it; only that app's root ever holds a WRITABLE leaf.
//!   - Read-only for compositors. The registered WM server (`wm_peer`) maps
//!     the surface EL0-RO (`sw_cow`, M29). A COW fault there is a kernel
//!     error, never a silent copy (D4).
//!   - Revocation on close/teardown. When the owner's window closes or the
//!     owner exits, EVERY peer's RO leaf is revoked (unmapped) and the region
//!     descriptor is dropped when the refcount reaches zero. No peer retains
//!     access past that point.
//!   - Trust boundary. The WM is the only peer trusted with another app's
//!     surface read today; every other requestor is re-authorized per call
//!     and gets read-only at most — never the owner's writable view.
//!
//! No libc, no POSIX, no allocation — a fixed BSS descriptor table sized by
//! `max_shared_regions`, in keeping with the ADR 0005/0013 bounded-BSS rule.

const std = @import("std");

/// Bound on concurrently-live shared regions (the fixed `SharedRegion` BSS
/// array). Deliberately small — seam-B migrates apps one at a time (the WMS7
/// mailbox re-point lever), so a handful of live surfaces covers the first
/// stretching pass. SB2 sizes the actual array from this constant.
pub const max_shared_regions: usize = 8;

/// The grant outcome the D2 rule computes before any leaf is touched. SB2 maps
/// real pages only for `.grant` results.
pub const Grant = union(enum) {
    /// Grant the requestor a READ-ONLY (`sw_cow`) leaf for this region. For the
    /// OWNER this means "permission to keep your surface" — SB2 does NOT map a
    /// redundant sw_cow leaf for the owner (its writable leaf is the region's
    /// creation side, mapped at create). Only NON-owner granted peers get an
    /// RO/sw_cow leaf from a `.grant` result.
    grant,
    /// Refuse the request: beat the region table (region already at max). This
    /// is the CREATE-side capacity signal — `create()` returns 0 for a full
    /// table. `authorize_read` NEVER returns `.capacity` (reads consume no
    /// descriptor slot); the variant documents the create path for SB2.
    capacity,
    /// Refuse the request: the requestor is not the owner and not an
    /// authorized reader (not the WM, or no WM registered).
    not_authorized,
    /// Refuse the request: the region/surface no longer exists.
    gone,
    /// Driver-only guard: a requestor may never ask for a WRITABLE peer view.
    /// The owner's own writable map is NOT a peer request — it is the region's
    /// creation-side map and lives outside this rule (SB2 keeps it at open).
    writable_refused,
};

/// A fixed descriptor row (the ADR 0016 D1 "small fixed SharedRegion table"
/// shape, keyed by a kernel-issued integer handle). The policy rows own the
/// capability identity — owner, refcount, and the WM peer grant — and, since
/// SB2 (claim 8878), the region's physical mapping set + peer seat so one
/// descriptor is the whole capability (D1.2: "refcount + owner + the va/pa
/// set"). The DECISION functions are pure (no MMU effect); the wiring fields
/// are data, written by SB2.
pub const SharedRegion = struct {
    in_use: bool,
    handle: u32,
    owner_pid: u64,
    /// Read references (the WM and any re-authorized readers). The OWNER is
    /// NOT counted here — the owner's writable map is the region's creation
    /// side and is torn down with the owner's own teardown, not this refcount.
    refcount: u16,
    /// Whether the peer WM server holds the current read grant for this region.
    wm_granted: bool,

    /// SB2 wiring (claim 8878): the va the OWNER mapped the region at in its
    /// own root — the owner-side identity key (owner sys_munmap / re-map
    /// lookup). 0 until SB2 fills it at create.
    owner_va: u64,
    /// SB2 wiring: number of 4 KiB pages (the region is `alloc.alloc_pages(n)`
    /// contiguous, so one base + count describes the whole physical set).
    page_count: u32,
    /// SB2 wiring: physical base of the region's contiguous pages.
    pa_base: u64,
    /// SB2 wiring: the single live PEER seat (the registered WM's RO mapping),
    /// its pid, or 0 when no peer holds a view. The D2 trust boundary admits
    /// one peer seat per region today — the WM; a second seat is refused.
    peer_pid: u64,
    /// SB2 wiring: the va the peer mapped the region at IN THE PEER'S OWN ROOT
    /// (each root's leaves are independent; the peer's va is its own).
    peer_va: u64,
};

/// The module-level fixed table (BSS). Reset explicitly; no hidden global
/// initialization order dependency.
var regions: [max_shared_regions]SharedRegion = undefined;
var next_handle: u32 = 1;

/// Reinitialize the table (host tests + a fresh boot), zeroed and empty.
pub fn reset() void {
    for (&regions) |*r| {
        r.in_use = false;
        r.handle = 0;
        r.owner_pid = 0;
        r.refcount = 0;
        r.wm_granted = false;
        r.owner_va = 0;
        r.page_count = 0;
        r.pa_base = 0;
        r.peer_pid = 0;
        r.peer_va = 0;
    }
    next_handle = 1;
}

/// Create a shared surface owned by `owner_pid`, returning its handle (the D2
/// requestor-vs-owner start: the surface only exists once an app claims it).
/// Returns 0 when the table is full (capacity). WB owner mapping is SB2's job
/// at open — this only reserves the capability identity.
pub fn create(owner_pid: u64) u32 {
    for (&regions) |*r| {
        if (!r.in_use) {
            r.in_use = true;
            r.handle = next_handle;
            // Skip wrap-to-0: 0 is the `create()` capacity/error sentinel and
            // must never be issued to a live region (review fix, claim 7418).
            next_handle +%= 1;
            if (next_handle == 0) next_handle = 1;
            r.owner_pid = owner_pid;
            r.refcount = 0;
            r.wm_granted = false;
            // SB2 wiring (claim 8878): a reused slot must start CLEAN — a
            // stale peer seat or va/pa set from a previously dropped region
            // would make a later revoke unmap the wrong leaves.
            r.owner_va = 0;
            r.page_count = 0;
            r.pa_base = 0;
            r.peer_pid = 0;
            r.peer_va = 0;
            return r.handle;
        }
    }
    return 0; // capacity — the region table is full
}

/// The D2 grant rule for reading a shared surface. Pure decision — no MMU
/// effect. `wm_peer` is the registered WM's pid (0 = none registered).
///
/// Returns:
///   - `.grant`          → the requestor may hold a READ-ONLY leaf.
///   - `.writable_refused` → a peer asked for a WRITABLE view (never allowed).
///   - `.not_authorized` → the requestor is not the owner and not an
///                         authorized reader (not `wm_peer`).
///   - `.gone`           → `handle` names no live region.
pub fn authorize_read(
    requestor_pid: u64,
    handle: u32,
    want_writable: bool,
    wm_peer: u64,
) Grant {
    const r = find(handle) orelse return .gone;
    // The owner is checked FIRST (not gated by want_writable): the owner is
    // always the creator and may keep its surface — its WRITABLE view is the
    // region's creation-side leaf (SB2 maps it at create, outside this rule),
    // and its READ of its own surface is trivially granted. A writable request
    // from the OWNER must NOT be turned into `.writable_refused` — the ADR D2
    // decision table grants the owner read/write of its own surface; only PEERS
    // are read-only (fix, claim-7418 review).
    if (requestor_pid == r.owner_pid) return .grant;
    // A PEER may never hold a writable view (D2 read-only-for-compositors).
    if (want_writable) return .writable_refused;
    // Only the registered WM may read another app's surface, and only when a
    // WM is registered (seat exists). Every other requestor is refused.
    if (wm_peer != 0 and requestor_pid == wm_peer) return .grant;
    return .not_authorized;
}

/// Record a granted RO read reference. Returns true on success; false if the
/// region is gone or the refcount is already at its u16 bound. The caller
/// (SB2) pre-gates through `authorize_read`; this only bookkeeps.
pub fn grant_read(handle: u32) bool {
    const r = find(handle) orelse return false;
    if (!r.in_use) return false;
    if (r.refcount == std.math.maxInt(u16)) return false;
    r.refcount +%= 1;
    r.wm_granted = true;
    return true;
}

/// Drop one RO read reference (the owner is NOT counted in `refcount`).
pub fn drop_read(handle: u32) void {
    const r = find(handle) orelse return;
    if (r.refcount > 0) {
        r.refcount -= 1;
        if (r.refcount == 0) r.wm_granted = false;
    }
}

/// Revoke the OWNER: clear the region entirely (the D2 revocation-on-teardown
/// rule). Every peer RO leaf goes away with the owner (SB2 unmaps them here),
/// and the descriptor is freed. Returns the number of read references that
/// were revoked, so a live gate can assert peers were dropped.
pub fn drop_owner(handle: u32) u32 {
    const r = find(handle) orelse return 0;
    if (!r.in_use) return 0;
    const revoked = @as(u32, r.refcount);
    r.in_use = false;
    r.refcount = 0;
    r.wm_granted = false;
    r.owner_pid = 0;
    r.handle = 0;
    // SB2 wiring (claim 8878): a dropped descriptor carries nothing stale.
    r.owner_va = 0;
    r.page_count = 0;
    r.pa_base = 0;
    r.peer_pid = 0;
    r.peer_va = 0;
    return revoked;
}

/// How many read references a live region currently holds (observability; SB2
/// reports it pre-revoke so a gate can assert the specified N peers were dropped).
pub fn read_count(handle: u32) u32 {
    const r = find(handle) orelse return 0;
    if (!r.in_use) return 0;
    return r.refcount;
}

/// SB2 wiring: record the region's physical mapping set (owner va, page
/// count, contiguous pa base) — the D1.2 va/pa set the descriptor carries.
/// Returns false when `handle` is not a live region.
pub fn set_mapping(handle: u32, owner_va: u64, page_count: u32, pa_base: u64) bool {
    const r = find(handle) orelse return false;
    if (!r.in_use) return false;
    r.owner_va = owner_va;
    r.page_count = page_count;
    r.pa_base = pa_base;
    return true;
}

/// SB2 wiring: record the peer's RO mapping (its pid + the va in ITS root).
/// One peer seat per region today (the D2 trust boundary); a second seat is
/// refused by the syscall caller. Returns false when not a live region.
pub fn set_peer(handle: u32, peer_pid: u64, peer_va: u64) bool {
    const r = find(handle) orelse return false;
    if (!r.in_use) return false;
    r.peer_pid = peer_pid;
    r.peer_va = peer_va;
    return true;
}

/// SB2 wiring: clear the peer seat (peer detach / owner teardown).
pub fn clear_peer(handle: u32) void {
    const r = find(handle) orelse return;
    r.peer_pid = 0;
    r.peer_va = 0;
}

/// Handle of the live region OWNED by `owner_pid` whose owner-side va is
/// `owner_va` (the owner's sys_munmap / owner re-map lookup), or null.
pub fn find_owner(owner_pid: u64, owner_va: u64) ?u32 {
    for (&regions) |*r| {
        if (r.in_use and r.owner_pid == owner_pid and r.owner_va == owner_va) return r.handle;
    }
    return null;
}

/// Handle of the live region whose PEER seat is `peer_pid` mapping at
/// `peer_va` (the peer's per-root sys_munmap lookup), or null.
pub fn find_peer(peer_pid: u64, peer_va: u64) ?u32 {
    for (&regions) |*r| {
        if (r.in_use and r.peer_pid == peer_pid and r.peer_va == peer_va) return r.handle;
    }
    return null;
}

/// #2113: how the unmap range [va, va+len) stands against every live shared
/// region `pid` seats. The old `covers` check tested only the range START,
/// so a range beginning before a surface and overlapping it fell through to
/// the generic unmap — stripping the owner's shared leaves while the
/// descriptor and the WM mirror stayed live.
pub const MunmapMatch = enum {
    /// No live seat of `pid` intersects the range.
    none,
    /// The range intersects a seat but does not equal it exactly — the
    /// full-region-only teardown rule (ADR 0016) refuses it EINVAL.
    partial,
    /// The range IS exactly a region `pid` owns (owner teardown path).
    owner,
    /// The range IS exactly a region `pid` peer-maps (peer detach path).
    peer,
};

pub fn munmap_match(pid: u64, va: u64, len: u64) MunmapMatch {
    const va_end = va +% len;
    for (&regions) |*r| {
        if (!r.in_use) continue;
        const rlen = @as(u64, r.page_count) * 4096;
        if (r.owner_pid == pid) {
            const lo = @max(va, r.owner_va);
            const hi = @min(va_end, r.owner_va + rlen);
            if (hi > lo) {
                if (va == r.owner_va and len == rlen) return .owner;
                return .partial;
            }
        }
        if (r.peer_pid == pid) {
            const lo = @max(va, r.peer_va);
            const hi = @min(va_end, r.peer_va + rlen);
            if (hi > lo) {
                if (va == r.peer_va and len == rlen) return .peer;
                return .partial;
            }
        }
    }
    return .none;
}

/// Collect the handles of every live region OWNED by `pid` (the owner-exit
/// revoke sweep). Returns the count written to `out`.
pub fn owned_handles(owner_pid: u64, out: []u32) usize {
    var n: usize = 0;
    for (&regions) |*r| {
        if (r.in_use and r.owner_pid == owner_pid) {
            if (n < out.len) out[n] = r.handle;
            n += 1;
        }
    }
    return n;
}

/// Collect the handles of every live region PEER-mapped by `pid` (the
/// peer-exit detach sweep). Returns the count written to `out`.
pub fn peer_handles(peer_pid: u64, out: []u32) usize {
    var n: usize = 0;
    for (&regions) |*r| {
        if (r.in_use and r.peer_pid == peer_pid) {
            if (n < out.len) out[n] = r.handle;
            n += 1;
        }
    }
    return n;
}

/// Read-only view of a live region's wiring (SB2's MMU module reads the
/// physical set + peer seat to map/unmap leaves). Null when gone.
pub fn info(handle: u32) ?*const SharedRegion {
    return find(handle);
}

fn find(handle: u32) ?*SharedRegion {
    for (&regions) |*r| {
        if (r.in_use and r.handle == handle) return r;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Host tests — the D2 rule, pinned before the capability exists.
// ---------------------------------------------------------------------------

test "shared_region: capacity bound" {
    reset();
    var n: u32 = 0;
    while (n < max_shared_regions) : (n += 1) {
        const h = create(1000 + n);
        try std.testing.expect(h != 0);
    }
    try std.testing.expect(create(2000) == 0);
}

test "shared_region: owner always granted; a peer is WM-only" {
    reset();
    const owner: u64 = 42;
    const wm: u64 = 7;
    const stranger: u64 = 99;
    const h = create(owner);
    try std.testing.expect(h != 0);

    try std.testing.expect(authorize_read(owner, h, false, wm) == .grant);
    // The owner MAY WRITE its own surface: a writable request from the owner
    // is granted, NOT `.writable_refused` -- the ADR D2 table grants the owner
    // read/write of its own surface; only PEERS are read-only (review fix,
    // claim-7418: the writable guard must not gate the owner).
    try std.testing.expect(authorize_read(owner, h, true, wm) == .grant);
    try std.testing.expect(authorize_read(wm, h, true, wm) == .writable_refused);
    try std.testing.expect(authorize_read(wm, h, false, wm) == .grant);
    try std.testing.expect(authorize_read(stranger, h, false, wm) == .not_authorized);
}

test "shared_region: no WM registered means no peer reads at all" {
    reset();
    const owner: u64 = 42;
    const h = create(owner);
    try std.testing.expect(h != 0);
    const wouldbe_wm: u64 = 7;
    try std.testing.expect(authorize_read(wouldbe_wm, h, false, 0) == .not_authorized);
    try std.testing.expect(authorize_read(owner, h, false, 0) == .grant);
}

test "shared_region: grant_read / drop_read maintain the read refcount" {
    reset();
    const owner: u64 = 42;
    const wm: u64 = 7;
    const h = create(owner);
    try std.testing.expect(h != 0);
    try std.testing.expect(authorize_read(wm, h, false, wm) == .grant);
    try std.testing.expect(grant_read(h));
    try std.testing.expect(grant_read(h));
    try std.testing.expect(read_count(h) == 2);
    drop_read(h);
    try std.testing.expect(read_count(h) == 1);
    drop_read(h);
    try std.testing.expect(read_count(h) == 0);
}

test "shared_region: teardown revokes every peer and frees the descriptor" {
    reset();
    const owner: u64 = 42;
    const wm: u64 = 7;
    const h = create(owner);
    try std.testing.expect(h != 0);
    try std.testing.expect(authorize_read(wm, h, false, wm) == .grant);
    try std.testing.expect(grant_read(h));
    try std.testing.expect(read_count(h) == 1);

    const revoked = drop_owner(h);
    try std.testing.expect(revoked == 1);
    try std.testing.expect(authorize_read(wm, h, false, wm) == .gone);
    try std.testing.expect(read_count(h) == 0);
    drop_read(h); // no-op on a dead region
}

test "shared_region: stale handle after teardown cannot re-grant old peers" {
    reset();
    const owner: u64 = 42;
    const wm: u64 = 7;
    const h = create(owner);
    try std.testing.expect(h != 0);
    try std.testing.expect(authorize_read(wm, h, false, wm) == .grant);
    try std.testing.expect(grant_read(h));
    _ = drop_owner(h);
    try std.testing.expect(grant_read(h) == false);

    // A NEW region after reset is independent of any prior grant state.
    reset();
    const fresh = create(owner);
    try std.testing.expect(fresh != 0);
    try std.testing.expect(read_count(fresh) == 0);
    try std.testing.expect(authorize_read(wm, fresh, false, wm) == .grant);
}

test "shared_region: a reused slot starts clean — no stale SB2 wiring survives" {
    reset();
    const owner: u64 = 42;
    const wm: u64 = 7;
    const h = create(owner);
    try std.testing.expect(h != 0);
    // Fully wire the region (SB2 fields): mapping set + peer seat.
    try std.testing.expect(authorize_read(wm, h, false, wm) == .grant);
    try std.testing.expect(grant_read(h));
    try std.testing.expect(set_mapping(h, 0x1000_0000, 2, 0x200000));
    try std.testing.expect(set_peer(h, wm, 0x2000_0000));
    try std.testing.expect(find_owner(owner, 0x1000_0000) == h);
    try std.testing.expect(find_peer(wm, 0x2000_0000) == h);
    try std.testing.expect(munmap_match(owner, 0x1000_0000, 8192) == .owner);
    try std.testing.expect(munmap_match(wm, 0x2000_0000, 8192) == .peer);
    var out: [max_shared_regions]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 1), owned_handles(owner, &out));
    try std.testing.expectEqual(@as(usize, 1), peer_handles(wm, &out));
    // Owner teardown: descriptor freed, lookups go dark.
    _ = drop_owner(h);
    try std.testing.expect(info(h) == null);
    try std.testing.expect(find_owner(owner, 0x1000_0000) == null);
    try std.testing.expect(find_peer(wm, 0x2000_0000) == null);
    try std.testing.expect(munmap_match(owner, 0x1000_0000, 8192) == .none);
    // A NEW region reuses the (dropped) slot: no stale owner va, page set,
    // or peer seat survives — a later revoke can never unmap wrong leaves.
    const h2 = create(owner);
    try std.testing.expect(h2 != 0);
    const r = info(h2).?;
    try std.testing.expectEqual(@as(u64, 0), r.owner_va);
    try std.testing.expectEqual(@as(u32, 0), r.page_count);
    try std.testing.expectEqual(@as(u64, 0), r.pa_base);
    try std.testing.expectEqual(@as(u64, 0), r.peer_pid);
    try std.testing.expectEqual(@as(u64, 0), r.peer_va);
}
