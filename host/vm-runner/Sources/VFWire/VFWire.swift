// VFWire.swift — pure wire-format encode/decode for the M34 host file
// channel (issues #735/#736): the guest userland filesystem is a macOS
// folder served over custom-virtio queue 5.
//
// ZERO Virtualization imports — this module must build and test on any
// host, so `swift test` runs without a VM. Every byte layout here is
// pinned by the checked-in fixtures (tests/vf-*.bin) and mirrored by the
// guest kernel module kernel/src/virtio_file.zig.
//
// Wire:
//   request  [op u8][flags u8][len u16le][payload]
//   reply    [status u8][dlen u16le][data]
// Ops: VF_PROBE 0x00 (transport-only — the reply is the RAW 32,768-byte
// pattern, no frame), LIST 0x01, READ 0x02 ([path][u64le offset]), STAT
// 0x03. Status: 0 ok, 1 not found, 2 is a directory, 3 truncated, 4 host
// error.

import Foundation

public enum VFWire {
    // Ops
    public static let opProbe: UInt8 = 0x00
    public static let opList: UInt8 = 0x01
    public static let opRead: UInt8 = 0x02
    public static let opStat: UInt8 = 0x03
    // HF3 (issue #737): mutation ops — ADDITIVE (0x04...0x0b), so the
    // protocol stays non-breaking: an old host answers any new op with
    // status 4 host error and an old guest never sends them.
    public static let opOpen: UInt8 = 0x04
    public static let opClose: UInt8 = 0x05
    public static let opWrite: UInt8 = 0x06
    public static let opTruncate: UInt8 = 0x07
    public static let opFsync: UInt8 = 0x08
    public static let opRename: UInt8 = 0x09
    public static let opMkdir: UInt8 = 0x0a
    public static let opDelete: UInt8 = 0x0b
    // HF7 (issue #741): COW clone — additive (0x0c), same non-breaking
    // rule: an old host answers it with status 4 host error and an old
    // guest never sends it.
    public static let opClone: UInt8 = 0x0c
    public static let opDirOpen: UInt8 = 0x0d
    public static let opDirPage: UInt8 = 0x0e
    public static let opDirClose: UInt8 = 0x0f
    // B4: old hosts refuse this unknown opcode before touching either path.
    public static let opReplace: UInt8 = 0x10
    // M160a (#2981): STATFS — the share root's free-space truth, additive
    // under the same rule: an old host answers the unknown op with status
    // 4, which the guest reads as the named "unsupported".
    public static let opStatfs: UInt8 = 0x11

    // Reply statuses
    public static let stOk: UInt8 = 0
    public static let stNotFound: UInt8 = 1
    public static let stIsDir: UInt8 = 2
    public static let stTruncated: UInt8 = 3
    public static let stHostError: UInt8 = 4
    public static let stExists: UInt8 = 5
    public static let stHandle: UInt8 = 6
    public static let stLimit: UInt8 = 7
    public static let stPathLimit: UInt8 = 8
    public static let stChanged: UInt8 = 9
    public static let stAccess: UInt8 = 10
    public static let stUnsupported: UInt8 = 11

    // OPEN request flags byte (per-op modifiers in the reserved byte)
    public static let openFlagCreate: UInt8 = 0x01
    public static let openFlagAppend: UInt8 = 0x02

    // Frame constants (mirror kernel/src/virtio_file.zig)
    public static let requestHdrLen = 4 // [op][flags][len u16le]
    public static let replyHdrLen = 3 // [status][dlen u16le]
    public static let pathMax = 512
    public static let replyCap = 32768 // full-cap device-write reply (HF1)
    public static let listMaxEntries = 128
    public static let entryRowLen = 40 // [name 31][type u8][size u64le]
    public static let readOffsetLen = 8
    // M134a (#2759): STAT reply data — v1 is [size u64le][type u8] (9 B);
    // v2 appends [mtime_sec u64le][mtime_nsec u32le] (21 B total).
    // M160a (#2981): v3 appends [ctime_sec u64le][ctime_nsec u32le]
    // [birth_sec u64le][birth_nsec u32le][alloc_bytes u64le] (53 B total).
    // The per-group end offsets let a mid-v3 reply decode only the groups
    // that fully arrived — absent fields are nil, never zero-filled facts.
    public static let statBaseDataLen = 9
    public static let statV2DataLen = 21
    public static let statV3CtimeLen = 33
    public static let statV3BirthLen = 45
    public static let statDataLen = 53

    /// STAT reply data, all three shapes. A nil field names the absent
    /// case — a shorter reply shape or a deliberately old-shaped peer.
    public struct StatData {
        public let size: UInt64
        public let isDir: Bool
        public let mtimeSec: UInt64?
        public let mtimeNsec: UInt32?
        public let ctimeSec: UInt64?
        public let ctimeNsec: UInt32?
        public let birthSec: UInt64?
        public let birthNsec: UInt32?
        public let allocBytes: UInt64?
    }

    /// Encode STAT reply data. `includeMtime` false emits the pre-M134a
    /// 9-byte shape an old guest expects; true emits the full M160a v3
    /// shape (53 bytes — mtime, ctime, birth, allocated).
    public static func encodeStatData(size: UInt64, isDir: Bool,
                                      mtimeSec: UInt64, mtimeNsec: UInt32,
                                      ctimeSec: UInt64, ctimeNsec: UInt32,
                                      birthSec: UInt64, birthNsec: UInt32,
                                      allocBytes: UInt64, includeMtime: Bool) -> [UInt8] {
        var out: [UInt8] = []
        var s = size
        for _ in 0..<8 { out.append(UInt8(s & 0xff)); s >>= 8 }
        out.append(isDir ? dirTypeDir : dirTypeFile)
        if includeMtime {
            // v3 is v2's [mtime_sec u64le][mtime_nsec u32le] followed by
            // the same [sec u64le][nsec u32le] pair for ctime and birth,
            // then [alloc_bytes u64le] — 32 extension bytes, 53 total.
            for (sec, nsec) in [(mtimeSec, mtimeNsec), (ctimeSec, ctimeNsec), (birthSec, birthNsec)] {
                var s = sec
                for _ in 0..<8 { out.append(UInt8(s & 0xff)); s >>= 8 }
                var n = nsec
                for _ in 0..<4 { out.append(UInt8(n & 0xff)); n >>= 8 }
            }
            var a = allocBytes
            for _ in 0..<8 { out.append(UInt8(a & 0xff)); a >>= 8 }
        }
        return out
    }

    /// Decode STAT reply data, accepting the v1 (>=9), v2 (>=21) and v3
    /// (>=53, with per-group mid-length tolerance) lengths — the same
    /// tolerance the guest's decode_stat_reply has. nil when the data is
    /// shorter than the base record.
    public static func decodeStatData(_ data: [UInt8]) -> StatData? {
        guard data.count >= statBaseDataLen else { return nil }
        var size: UInt64 = 0
        for i in 0..<8 { size |= UInt64(data[i]) << (8 * i) }
        func u64le(_ off: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[off + i]) << (8 * i) }
            return v
        }
        func u32le(_ off: Int) -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(data[off + i]) << (8 * i) }
            return v
        }
        var mtime: (UInt64, UInt32)? = nil
        if data.count >= statV2DataLen { mtime = (u64le(9), u32le(17)) }
        var ctime: (UInt64, UInt32)? = nil
        if data.count >= statV3CtimeLen { ctime = (u64le(21), u32le(29)) }
        var birth: (UInt64, UInt32)? = nil
        if data.count >= statV3BirthLen { birth = (u64le(33), u32le(41)) }
        var alloc: UInt64? = nil
        if data.count >= statDataLen { alloc = u64le(45) }
        return StatData(size: size, isDir: data[8] == dirTypeDir,
                        mtimeSec: mtime?.0, mtimeNsec: mtime?.1,
                        ctimeSec: ctime?.0, ctimeNsec: ctime?.1,
                        birthSec: birth?.0, birthNsec: birth?.1,
                        allocBytes: alloc)
    }

    /// M160a (#2981): STATFS reply data — [total u64le][free u64le]
    /// [avail u64le][block_size u32le], 28 bytes; the counts are in
    /// `blockSize` units (statvfs semantics: blocks × bsize = bytes).
    public static let statfsDataLen = 28

    public struct StatfsData {
        public let total: UInt64
        public let free: UInt64
        public let avail: UInt64
        public let blockSize: UInt32
    }

    public static func encodeStatfsData(total: UInt64, free: UInt64, avail: UInt64, blockSize: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        for v in [total, free, avail] {
            var x = v
            for _ in 0..<8 { out.append(UInt8(x & 0xff)); x >>= 8 }
        }
        var b = blockSize
        for _ in 0..<4 { out.append(UInt8(b & 0xff)); b >>= 8 }
        return out
    }

    /// nil when the data is shorter than the 28-byte record — the fields
    /// stay absent, never half-filled (mirrors the guest's
    /// decode_statfs_data).
    public static func decodeStatfsData(_ data: [UInt8]) -> StatfsData? {
        guard data.count >= statfsDataLen else { return nil }
        func u64le(_ off: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[off + i]) << (8 * i) }
            return v
        }
        var bsize: UInt32 = 0
        for i in 0..<4 { bsize |= UInt32(data[24 + i]) << (8 * i) }
        return StatfsData(total: u64le(0), free: u64le(8), avail: u64le(16), blockSize: bsize)
    }
    // HF3 scalar field lengths + the handle-table cap (parity with the
    // kernel's file_table.zig — max_handles_per_process = 8).
    public static let handleLen = 2
    public static let writtenLen = 8
    public static let truncateSizeLen = 8
    public static let maxFileHandles = 8
    public static let writeChunkMax = replyCap - replyHdrLen - handleLen

    public static let dirTypeFile: UInt8 = 0
    public static let dirTypeDir: UInt8 = 1

    // The VF_PROBE reply pattern (both sides compute it without storing
    // 32 KiB): pattern[i] = (i & 0xff) ^ ((i >> 8) & 0xff). The full
    // 32,768 bytes are the checked-in fixture tests/vf-pattern-32k.bin
    // (sha256-pinned by the class-A gate).
    public static func pattern(_ i: Int) -> UInt8 {
        UInt8((i & 0xff) ^ ((i >> 8) & 0xff))
    }

    /// Encode a request: [op][flags][len u16le][payload]. nil when the
    /// payload exceeds the u16 length field.
    public static func encodeRequest(op: UInt8, flags: UInt8, payload: [UInt8]) -> [UInt8]? {
        guard payload.count <= 0xffff else { return nil }
        var out = [UInt8](repeating: 0, count: requestHdrLen + payload.count)
        out[0] = op
        out[1] = flags
        out[2] = UInt8(payload.count & 0xff)
        out[3] = UInt8((payload.count >> 8) & 0xff)
        out.replaceSubrange(requestHdrLen..., with: payload)
        return out
    }

    /// A decoded reply: status, declared data length, and the data —
    /// CLAMPED to the buffer (never OOB); `clamped` reports truncation.
    public struct Reply {
        public let status: UInt8
        public let dlen: UInt16
        public let data: [UInt8]
        public let clamped: Bool
    }

    /// Decode a reply buffer: [status u8][dlen u16le][data]. A buffer
    /// shorter than the header decodes as host_error with empty data.
    public static func decodeReply(_ buf: [UInt8]) -> Reply {
        guard buf.count >= replyHdrLen else {
            return Reply(status: stHostError, dlen: 0, data: [], clamped: true)
        }
        let status = buf[0]
        let dlen = UInt16(buf[1]) | (UInt16(buf[2]) << 8)
        let avail = buf.count - replyHdrLen
        let take = min(Int(dlen), avail)
        return Reply(
            status: status,
            dlen: dlen,
            data: Array(buf[replyHdrLen..<(replyHdrLen + take)]),
            clamped: take < Int(dlen)
        )
    }

    /// Encode a reply: [status u8][dlen u16le][data] (dlen = data count).
    public static func encodeReply(status: UInt8, data: [UInt8]) -> [UInt8] {
        precondition(data.count <= 0xffff)
        var out = [UInt8](repeating: 0, count: replyHdrLen + data.count)
        out[0] = status
        out[1] = UInt8(data.count & 0xff)
        out[2] = UInt8((data.count >> 8) & 0xff)
        out.replaceSubrange(replyHdrLen..., with: data)
        return out
    }

    /// One LIST row: [name 31 B NUL-padded][type u8][size u64le].
    public struct DirEntry {
        public let name: String
        public let type: UInt8
        public let size: UInt64

        public init(name: String, type: UInt8, size: UInt64) {
            self.name = name
            self.type = type
            self.size = size
        }
    }

    public static func encodeEntryRow(_ e: DirEntry) -> [UInt8] {
        var row = [UInt8](repeating: 0, count: entryRowLen)
        let nameBytes = Array(e.name.utf8.prefix(31))
        row.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        row[31] = e.type
        var size = e.size
        for i in 0..<8 {
            row[32 + i] = UInt8(size & 0xff)
            size >>= 8
        }
        return row
    }

    /// Build a READ payload: [path][u64le offset]. nil for over-long paths.
    public static func buildReadPayload(path: String, offset: UInt64) -> [UInt8]? {
        let p = Array(path.utf8)
        guard p.count <= pathMax else { return nil }
        var out = p
        var off = offset
        for _ in 0..<8 {
            out.append(UInt8(off & 0xff))
            off >>= 8
        }
        return out
    }

    /// RFC-1071 one's-complement checksum (big-endian word semantics,
    /// mirroring the guest's checksum1071 and the gate's python cross-
    /// check). u64 accumulator: 32 KiB of pattern sums ~33M before the
    /// fold — safe, but kept u64 for parity with the guest.
    public static func checksum1071(_ data: [UInt8]) -> UInt16 {
        var sum: UInt64 = 0
        var i = 0
        while i + 1 < data.count {
            sum += (UInt64(data[i]) << 8) | UInt64(data[i + 1])
            i += 2
        }
        if i < data.count { sum += UInt64(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(~sum & 0xffff)
    }

    // ------------------------------------------------------------------
    // Path defense (HF1 scope): resolve a guest path INSIDE the share
    // root. The protocol is stateless and the share is a plain macOS
    // folder, so the attack surface is the path: reject absolute paths,
    // `..` traversal, and symlink escapes.
    // ------------------------------------------------------------------

    /// Resolve `path` (relative, '/' separated; "" = the root) under
    /// `root`. Returns nil when the path is absolute, contains `..`, or
    /// would escape the share root via a symlink after standardization.
    public static func resolveSubpath(root: URL, path: String) -> URL? {
        // An absolute path is refused outright (the protocol is
        // root-relative; a leading '/' is never valid).
        if path.hasPrefix("/") { return nil }
        let rootURL = root.resolvingSymlinksInPath()
        let rootPath = rootURL.path
        var url = rootURL
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        for c in comps {
            if c == ".." { return nil }
            if c == "." { continue }
            guard !c.isEmpty else { continue }
            // A single component must not smuggle separators or escapes.
            if c.contains("\\") { return nil }
            url = url.appendingPathComponent(String(c))
        }
        // Symlink-escape check: the fully symlink-RESOLVED path must still
        // live under the share root (standardizedFileURL is syntactic
        // only — it does not chase symlinks).
        let resolved = url.resolvingSymlinksInPath().path
        guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else { return nil }
        return URL(fileURLWithPath: resolved)
    }

    // ------------------------------------------------------------------
    // HF3 mutation wire (issue #737): payload builders + parsers.
    // All little-endian, mirroring kernel/src/virtio_file.zig byte for
    // byte (locked by the class-A unit tests on both sides).
    // ------------------------------------------------------------------

    /// WRITE payload: [handle u16le][data]. nil when data exceeds the
    /// per-round-trip chunk cap.
    public static func buildWritePayload(handle: Int, data: [UInt8]) -> [UInt8]? {
        guard data.count <= writeChunkMax else { return nil }
        var out = [UInt8(handle & 0xff), UInt8((handle >> 8) & 0xff)]
        out.append(contentsOf: data)
        return out
    }

    /// TRUNCATE payload: [handle u16le][size u64le].
    public static func buildTruncatePayload(handle: Int, size: UInt64) -> [UInt8] {
        var out = [UInt8(handle & 0xff), UInt8((handle >> 8) & 0xff)]
        var s = size
        for _ in 0..<8 { out.append(UInt8(s & 0xff)); s >>= 8 }
        return out
    }

    /// RENAME payload: [from][0x00][to]. nil for over-long or empty paths,
    /// or a path smuggling a NUL — the frame separator must be unambiguous
    /// (`serveRename` splits on the FIRST NUL, so an embedded one would move
    /// the boundary). CLONE always checked this; the M70a fuzz sweep caught
    /// RENAME not checking it (2026-09-18), and the two now agree.
    public static func buildRenamePayload(from: String, to: String) -> [UInt8]? {
        let f = Array(from.utf8)
        let t = Array(to.utf8)
        guard !f.isEmpty, !t.isEmpty, f.count <= pathMax, t.count <= pathMax,
              !f.contains(0), !t.contains(0) else { return nil }
        var out = f
        out.append(0)
        out.append(contentsOf: t)
        return out
    }

    /// CLONE payload: the same NUL-framed shape as RENAME —
    /// [from][0x00][to]. nil for over-long or empty paths (or a path
    /// smuggling a NUL — the frame separator must be unambiguous).
    public static func buildClonePayload(from: String, to: String) -> [UInt8]? {
        let f = Array(from.utf8)
        let t = Array(to.utf8)
        guard !f.isEmpty, !t.isEmpty, f.count <= pathMax, t.count <= pathMax,
              !f.contains(0), !t.contains(0) else { return nil }
        var out = f
        out.append(0)
        out.append(contentsOf: t)
        return out
    }

    /// Parse a u16le handle from the head of a request payload or reply
    /// data. nil on a short buffer.
    public static func handle(fromPayload bytes: [UInt8], at offset: Int = 0) -> Int? {
        guard bytes.count >= offset + handleLen else { return nil }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }

    /// OPEN reply data: [handle u16le].
    public static func encodeOpenReply(handle: Int) -> [UInt8] {
        [UInt8(handle & 0xff), UInt8((handle >> 8) & 0xff)]
    }

    /// WRITE reply data: [written u64le].
    public static func encodeWrittenReply(written: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var w = written
        for _ in 0..<8 { out.append(UInt8(w & 0xff)); w >>= 8 }
        return out
    }
}

// --------------------------------------------------------------------------
// HF3: the host's 8-slot OPEN-handle table (issue #737).
//
// VZ-FREE — a plain FileManager/FileHandle service, unit-testable on any
// host (no Virtualization imports). This is exactly where cursors earn
// their keep: OPEN allocates a slot, WRITE advances the cursor (append
// handles write at EOF), TRUNCATE clamps it, FSYNC pushes real durability
// (synchronize() on the live fd), CLOSE flushes and frees. The 8-slot cap
// is parity with the kernel's file_table.zig ABI (max_handles_per_process).
// --------------------------------------------------------------------------
public final class FileHandleTable {
    public struct Slot {
        public var path: String = ""
        public var fh: FileHandle? = nil
        public var cursor: UInt64 = 0
        public var append: Bool = false
        public var inUse: Bool = false
    }

    public private(set) var slots: [Slot]

    public init() {
        slots = Array(repeating: Slot(), count: VFWire.maxFileHandles)
    }

    /// Allocate a slot for a live FileHandle. Returns the handle index,
    /// or VFWire.stHandle when the table is full.
    public func open(path: String, fh: FileHandle, append: Bool) -> (Int, UInt8) {
        for i in slots.indices where !slots[i].inUse {
            slots[i] = Slot(path: path, fh: fh, cursor: 0, append: append, inUse: true)
            return (i, VFWire.stOk)
        }
        return (-1, VFWire.stHandle)
    }

    /// Look up a live slot; nil when the handle is not open.
    public func slot(_ handle: Int) -> Slot? {
        guard handle >= 0, handle < slots.count, slots[handle].inUse else { return nil }
        return slots[handle]
    }

    /// WRITE data at the cursor (append → EOF first). Returns (written,
    /// status) — nil written on failure.
    public func write(_ handle: Int, data: [UInt8]) -> (UInt64?, UInt8) {
        guard handle >= 0, handle < slots.count, slots[handle].inUse,
              let fh = slots[handle].fh else { return (nil, VFWire.stHandle) }
        do {
            if slots[handle].append {
                try fh.seekToEnd()
                slots[handle].cursor = try fh.offset()
            } else {
                try fh.seek(toOffset: slots[handle].cursor)
            }
            try fh.write(contentsOf: data)
            let count = UInt64(data.count)
            slots[handle].cursor += count
            return (count, VFWire.stOk)
        } catch {
            return (nil, VFWire.stHostError)
        }
    }

    /// TRUNCATE an open file to `size`; clamp the cursor below it.
    public func truncate(_ handle: Int, size: UInt64) -> UInt8 {
        guard handle >= 0, handle < slots.count, slots[handle].inUse,
              let fh = slots[handle].fh else { return VFWire.stHandle }
        do {
            try fh.truncate(atOffset: size)
            slots[handle].cursor = min(slots[handle].cursor, size)
            return VFWire.stOk
        } catch {
            return VFWire.stHostError
        }
    }

    /// FSYNC: synchronize() on the live fd — real durability.
    public func fsync(_ handle: Int) -> UInt8 {
        guard handle >= 0, handle < slots.count, slots[handle].inUse,
              let fh = slots[handle].fh else { return VFWire.stHandle }
        do {
            try fh.synchronize()
            return VFWire.stOk
        } catch {
            return VFWire.stHostError
        }
    }

    /// CLOSE: flush + close the fd, free the slot.
    public func close(_ handle: Int) -> UInt8 {
        guard handle >= 0, handle < slots.count, slots[handle].inUse else { return VFWire.stHandle }
        if let fh = slots[handle].fh {
            try? fh.close()
        }
        slots[handle] = Slot()
        return VFWire.stOk
    }
}

