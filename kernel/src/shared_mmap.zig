//! M33 SB2 (claim 8878): the shared-anon MMU WIRING — the execution half of
//! the seam-B capability. `shared_region.zig` (SB1, claim 7418) DECIDES the
//! D2 grant/revoke rule as pure policy; this module EXECUTES it against real
//! page tables: writable leaves for the owner, EL0-RO `sw_cow` leaves for the
//! registered WM peer (mapped into the peer's OWN root at the peer's OWN va),
//! and unmap+unref on revoke — so the frozen policy stays pure and host-
//! testable while the physical side lives here.
//!
//! Model (ADR 0016 D1/D2, frozen by SB1):
//!   - The physical pages are allocated ONCE (contiguous, `alloc.alloc_pages`)
//!     and mapped into two roots via separate leaves: the owner's writable
//!     leaf (installed at create, tracked in the owner's `dynamic_pages` so
//!     exit frees them) and the peer's RO `sw_cow` leaf (ref'd 1->2, recorded
//!     as the region's single peer seat).
//!   - Teardown is D2 revocation: owner munmap/exit revokes the peer seat
//!     FIRST (unmap the peer's leaves, unref 2->1), then the owner's own
//!     teardown unrefs 1->0 and frees. A peer exit/munmap detaches only its
//!     seat (unref 2->1); the owner's writable leaf and the region survive
//!     (ADR 0016 D1: per-root teardown).
//!   - M52 card 3 (#1240): an owner-side revoke is COMPLETE — it also drops
//!     the peer's `mmap_region` row + armed read aperture (the mirror's
//!     kernel-side half, so no stale row can exhaust the peer's table) and
//!     ends any window bound to the dying surface (no zombie window blitting
//!     freed pages).
//!
//! No libc, no POSIX, no allocation — fixed BSS only.

const alloc = @import("alloc.zig");
const mmu = @import("mmu.zig");
const process = @import("process.zig");
const shared_region = @import("shared_region.zig");
const uaccess = @import("uaccess.zig"); // M52 card 3 (#1240): the peer's read aperture
const driving_award = @import("driving_award.zig"); // M52 card 3 (#1240): end the bound window

/// Map the owner's writable leaves for a freshly created region (SB2 create
/// path). `root_phys` is the owner's TTBR0 root. The pages were allocated by
/// the caller (and recorded in its `dynamic_pages` there so exit frees them);
/// this installs the leaves. Returns false on a partial failure — the caller
/// unwinds with the ordinary munmap path.
pub fn map_owner_leaves(root_phys: u64, va: u64, page_count: u32, pa_base: u64, prot: u64) bool {
    var i: u32 = 0;
    while (i < page_count) : (i += 1) {
        const pa = pa_base + @as(u64, i) * 4096;
        if (!mmu.map_user_page(root_phys, va + @as(u64, i) * 4096, pa, (prot & 2) != 0, (prot & 4) != 0)) return false;
    }
    return true;
}

/// Map a peer's EL0-RO `sw_cow` leaves (SB2 peer-attach path). Each page is
/// ref'd BEFORE its leaf is installed (so an owner teardown can never free a
/// page while the peer leaf maps it); a failed ref (M97b #2110: the ref is
/// now RECORDED or the call fails loudly) or a failed map unwinds everything
/// this call installed — the leaves [0, i) are unmapped and their refs
/// dropped, so a partial attach leaves no unrecorded mapping behind. #2114:
/// false means NOTHING survives, so the caller only drops its bookkeeping
/// (the mmap region row).
pub fn map_peer_leaves(peer_root: u64, peer_va: u64, page_count: u32, pa_base: u64) bool {
    var i: u32 = 0;
    while (i < page_count) : (i += 1) {
        const pa = pa_base + @as(u64, i) * 4096;
        if (!alloc.ref_page(pa)) { // owner ref 1 -> 2, or the attach fails
            unmap_peer_leaves(peer_root, peer_va, i, pa_base);
            return false;
        }
        if (!mmu.map_user_cow_page(peer_root, peer_va + @as(u64, i) * 4096, pa)) {
            _ = alloc.unref_page(pa); // back to 1; nothing was mapped
            // #2114: the call self-unwinds — a caller cannot know how far
            // the loop got. Unwind only [0, i): the full range would
            // double-unref THIS page (its ref was just backed out above),
            // freeing a page the owner still maps.
            unmap_peer_leaves(peer_root, peer_va, i, pa_base);
            return false;
        }
    }
    return true;
}

/// Unmap a peer's RO leaves and drop the peer refs (2 -> 1). The owner's
/// ref and the region survive (per-root teardown, ADR 0016 D1).
pub fn unmap_peer_leaves(peer_root: u64, peer_va: u64, page_count: u32, pa_base: u64) void {
    var i: u32 = 0;
    while (i < page_count) : (i += 1) {
        const va = peer_va + @as(u64, i) * 4096;
        if (mmu.unmap_user_page(peer_root, va)) |mapped_pa| {
            process.forget_dynamic_page_in_root(peer_root, mapped_pa);
            _ = alloc.unref_page(mapped_pa);
        } else {
            // Leaf already gone (defensive): unref the ref we hold anyway so
            // the count stays honest.
            _ = alloc.unref_page(pa_base + @as(u64, i) * 4096);
        }
    }
}

/// Owner-side teardown of ONE region (owner sys_munmap): revoke the peer seat
/// (unmap its leaves, unref 2->1) and drop the descriptor. Returns true if
/// `va` named a live region owned by `pid`. The caller then runs the ordinary
/// munmap loop, which unmaps the owner's own leaves and unrefs 1->0 (free) —
/// after this call the descriptor is gone, so the loop cannot re-enter the
/// shared path.
pub fn revoke_owner_va(pid: usize, va: u64) bool {
    const handle = shared_region.find_owner(pid, va) orelse return false;
    revoke_peer(handle);
    _ = shared_region.drop_owner(handle);
    return true;
}

/// Owner exit sweep: revoke EVERY region owned by `pid` (the D2 close/
/// teardown rule). Returns the number of peer read-references revoked (a gate
/// can assert peers were dropped). Call BEFORE the owner's pages are unref'd
/// at reap, so a peer can never retain access into freed physical memory.
pub fn revoke_owner(pid: usize) usize {
    var handles: [shared_region.max_shared_regions]u32 = undefined;
    const n = shared_region.owned_handles(pid, &handles);
    var revoked: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        revoke_peer(handles[i]);
        revoked += shared_region.drop_owner(handles[i]);
    }
    return revoked;
}

/// Peer exit sweep: detach every region PEER-mapped by `pid` (the WM exits
/// while surfaces it read remain live). Unmaps its RO leaves (they die with
/// its root anyway), unrefs 2->1, clears the seat + read ref. The owner's
/// writable leaf and the region survive.
pub fn revoke_peer_role(pid: usize) usize {
    var handles: [shared_region.max_shared_regions]u32 = undefined;
    const n = shared_region.peer_handles(pid, &handles);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const info = shared_region.info(handles[i]) orelse continue;
        if (process.info(@intCast(info.peer_pid))) |self| {
            unmap_peer_leaves(self.root_phys, info.peer_va, info.page_count, info.pa_base);
        } else {
            unref_peer_pages(info.page_count, info.pa_base);
        }
        shared_region.clear_peer(handles[i]);
        shared_region.drop_read(handles[i]);
    }
    return n;
}

/// Peer-side detach of ONE region (peer sys_munmap): unmap the peer's RO
/// leaves, unref 2->1, clear the seat + read ref. The region and the owner's
/// writable leaf survive (ADR 0016 D1 per-root teardown). Returns true if
/// `va` named the caller's peer seat.
pub fn detach_peer(pid: usize, va: u64) bool {
    const handle = shared_region.find_peer(pid, va) orelse return false;
    const info = shared_region.info(handle).?;
    if (process.info(@intCast(info.peer_pid))) |self| {
        unmap_peer_leaves(self.root_phys, info.peer_va, info.page_count, info.pa_base);
    } else {
        unref_peer_pages(info.page_count, info.pa_base);
    }
    shared_region.clear_peer(handle);
    shared_region.drop_read(handle);
    return true;
}

fn revoke_peer(handle: u32) void {
    const info = shared_region.info(handle) orelse return;
    // NOTE (M52 card 3 review follow-up): the peer-seat work is conditional,
    // the ZOMBIE CLOSE below is NOT — it is about the SURFACE dying, not about
    // the peer seat. Do not fold the two guards back together.
    if (info.peer_pid != 0) {
        const peer_pid: usize = @intCast(info.peer_pid);
        const len = @as(u64, info.page_count) * 4096;
        if (process.info(peer_pid)) |peer| {
            unmap_peer_leaves(peer.root_phys, info.peer_va, info.page_count, info.pa_base);
            // M52 card 3 (#1240): an owner-side revoke must ALSO release what
            // the peer still owns on the KERNEL side of the mapping — the
            // leaves are not the whole mirror. The peer's own `mmap_region`
            // row (its va reservation, and with it the aperture
            // `arm_task_regions` rebuilds from that row at its next SVC) and
            // the currently-armed read aperture would otherwise outlive the
            // region: the peer's table is 16 rows, so 16 owner deaths exhaust
            // the WM's mirror capacity and every later attach fails ENOMEM,
            // and the stale aperture keeps admitting a range no leaf maps.
            // This mirrors the peer-side `detach_peer` call site in
            // handle_munmap, which always did both.
            _ = process.remove_mmap_region(peer_pid, info.peer_va, len);
            uaccess.remove_region(info.peer_va, len);
        } else {
            // Peer exited without detaching (defensive — the exit seam
            // detaches first, so this is unreachable in practice): the leaves
            // died with its root; account the refs so no leak.
            unref_peer_pages(info.page_count, info.pa_base);
        }
    }
    // M52 card 3 (#1240): the surface is gone, so a window still bound to it
    // has no source left to render or composite — `composite()` would blit
    // from freed physical pages and `sys_win_fill` would write into them.
    // End the window now (the same `remove_user_at` primitive every release
    // path uses) so the registry holds no zombie and the WM learns it is
    // released. A window closed BEFORE its surface is the ordinary order and
    // finds nothing here; a peer-side detach (the WM dying) never reaches
    // this function, so the owner's window survives its WM (ADR 0016 D1).
    //
    // UNCONDITIONAL (M52 card 3 review follow-up): the peer seat may ALREADY
    // be gone — a WM that died first cleared it (peer_pid == 0) — and this
    // owner-side revoke is then the only remaining moment that knows the
    // surface is dying. Behind the peer-seat guard it was skipped, and the
    // owner's later `sys_munmap` left the window surface_backed over freed
    // physical pages: the same use-after-free the guard-free case fixes,
    // reached by a different interleaving. Owner EXIT was safe only because
    // the seam runs close_owner before revoke_owner; the munmap order is not.
    _ = driving_award.surface_revoked(handle);
}

fn unref_peer_pages(page_count: u32, pa_base: u64) void {
    var j: u32 = 0;
    while (j < page_count) : (j += 1) {
        _ = alloc.unref_page(pa_base + @as(u64, j) * 4096);
    }
}
