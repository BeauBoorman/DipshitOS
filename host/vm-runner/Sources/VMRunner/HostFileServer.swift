import Darwin
import Foundation
import VFWire
import Virtualization

// MARK: - HostFileServer — the M34 host file channel (VF-FILE), host half
//
// `--cvc-file <dir>` arms queue 5 of the custom-virtio device: the guest
// sends one framed request per element and the host serves it with
// FileManager calls rooted at the share dir — HF1+HF2 (#735/#736) the
// stateless PROBE/LIST/STAT/READ verbs, HF3 (#737) the mutation verbs on
// the 8-slot handle table, HF7 (#741) the APFS COW clone. M132c (#2754)
// moved this serving block out of main.swift verbatim — the wire replies
// and the VF-FILE/VF-PROBE log lines are byte-identical — so the M134
// wire work and the M139 host-app work hold disjoint Touches. The one
// call site left in main.swift is `handleFileNotification(queue:)` in
// the queue-5 notification branch.

// HF3 (issue #737): the mutation verbs ride an 8-slot host handle table
// (parity with the kernel's file_table.zig — cursors live HERE, not in
// the guest). VZ-free class lives in the VFWire module.
var fileHandleTable = FileHandleTable()
var directoryTable = DirectoryTable()

/// M134a (#2759) test-only switch: a `.vf-stat-v1` marker file at the
/// share root (or `VIRELAI_VF_STAT_V1` in the environment) pins STAT
/// replies to the pre-mtime 9-byte shape — the old-peer leg.
func vfStatLegacyShape(root: URL) -> Bool {
    if ProcessInfo.processInfo.environment["VIRELAI_VF_STAT_V1"] != nil { return true }
    return FileManager.default.fileExists(atPath: root.appendingPathComponent(".vf-stat-v1").path)
}

#if SPIKE

@available(macOS 27.0, *)
extension CustomVirtioSpikeDeviceDelegate {
    /// M34 HF1+HF2 (issues #735/#736): queue-5 notifications — serve one
    /// framed file-channel request per element with FileManager calls
    /// rooted at the share dir. Stateless by design: READ carries an
    /// explicit offset, so the host holds ZERO state between requests (an
    /// untrusted guest cannot leak host fds). VF_PROBE is transport-only.
    func handleFileNotification(queue: VZVirtioQueue) {
        while let element = queue.nextElement() {
            var bytes: [UInt8] = []
            for buffer in element.readBuffers() {
                bytes.append(contentsOf: [UInt8](buffer))
            }
            serveFileRequest(bytes, element: element)
            element.returnToQueue()
        }
    }

    /// Serve ONE file-channel request. Never hangs, never falls through to
    /// the filesystem for an unknown op (status 4 loudly).
    private func serveFileRequest(_ bytes: [UInt8], element: VZVirtioQueueElement) {
        guard bytes.count >= VFWire.requestHdrLen else {
            print("VF-FILE: short request (\(bytes.count) byte(s)) — replying host error")
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let op = bytes[0]
        let flags = bytes[1]
        let len = Int(bytes[2]) | (Int(bytes[3]) << 8)
        guard bytes.count == VFWire.requestHdrLen + len else {
            print("VF-FILE: request length mismatch (declared \(len), got \(bytes.count - VFWire.requestHdrLen)) — replying host error")
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let payload = Array(bytes[VFWire.requestHdrLen...])
        switch op {
        case VFWire.opProbe:
            serveProbe(element: element)
        case VFWire.opList:
            serveList(payload, element: element)
        case VFWire.opDirOpen:
            guard let root = shareRootURL(), let path = String(bytes: payload, encoding: .utf8) else {
                writeFileReply(element: element, status: VFWire.stHostError, data: [])
                return
            }
            let (status, data) = directoryTable.open(root: root, path: path)
            writeFileReply(element: element, status: status, data: data)
        case VFWire.opDirPage:
            let (status, data) = directoryTable.page(payload)
            writeFileReply(element: element, status: status, data: data)
        case VFWire.opDirClose:
            let (status, data) = directoryTable.close(payload)
            writeFileReply(element: element, status: status, data: data)
        case VFWire.opRead:
            serveRead(payload, element: element)
        case VFWire.opStat:
            serveStat(payload, element: element)
        case VFWire.opOpen:
            serveOpen(payload, flags: flags, element: element)
        case VFWire.opClose:
            serveClose(payload, element: element)
        case VFWire.opWrite:
            serveWrite(payload, element: element)
        case VFWire.opTruncate:
            serveTruncate(payload, element: element)
        case VFWire.opFsync:
            serveFsync(payload, element: element)
        case VFWire.opRename:
            serveRename(payload, mode: .preserveExisting, element: element)
        case VFWire.opReplace:
            serveRename(payload, mode: .replace, element: element)
        case VFWire.opMkdir:
            serveMkdir(payload, element: element)
        case VFWire.opDelete:
            serveDelete(payload, element: element)
        case VFWire.opClone:
            serveClone(payload, element: element)
        default:
            print("VF-FILE: unknown op 0x\(String(format: "%02x", op)) — replying host error")
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
        }
        _ = flags
    }

    /// VF_PROBE: prove a full 32,768-byte device-WRITE reply (HF1's
    /// acceptance case A). The reply is the RAW pattern (no frame). The
    /// descriptor MUST carry the full write buffer — a short buffer is a
    /// guest bug to surface loudly, never silent truncation.
    private func serveProbe(element: VZVirtioQueueElement) {
        guard element.writeBuffersByteCount >= VFWire.replyCap else {
            print("VF-PROBE: FAILED — write buffers \(element.writeBuffersByteCount) < \(VFWire.replyCap) (guest bug: short write buffer)")
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        var reply = [UInt8](repeating: 0, count: VFWire.replyCap)
        for i in 0..<reply.count { reply[i] = VFWire.pattern(i) }
        do {
            try element.write(Data(reply))
            let wrote = element.writtenByteCount
            print("VF-PROBE: wrote \(wrote)/\(VFWire.replyCap) bytes (write buffers \(element.writeBuffersByteCount))")
            if wrote != VFWire.replyCap {
                print("VF-PROBE: FAILED — writtenByteCount \(wrote) != \(VFWire.replyCap)")
            }
        } catch {
            print("VF-PROBE: FAILED — reply write error: \(error)")
        }
    }

    /// LIST: contentsOfDirectory at the resolved path, 40-byte rows,
    /// sorted by name for deterministic gate greps.
    private func serveList(_ payload: [UInt8], element: VZVirtioQueueElement) {
        guard let root = shareRootURL(), let path = String(bytes: payload, encoding: .utf8),
              let url = VFWire.resolveSubpath(root: root, path: path) else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            writeFileReply(element: element, status: VFWire.stNotFound, data: [])
            return
        }
        guard isDir.boolValue else {
            writeFileReply(element: element, status: VFWire.stIsDir, data: [])
            return
        }
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let sorted = items.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var rows: [UInt8] = []
        for item in sorted.prefix(VFWire.listMaxEntries) {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirItem = values?.isDirectory ?? false
            let size = UInt64(values?.fileSize ?? 0)
            rows.append(contentsOf: VFWire.encodeEntryRow(
                VFWire.DirEntry(name: item.lastPathComponent, type: isDirItem ? VFWire.dirTypeDir : VFWire.dirTypeFile, size: size)
            ))
        }
        writeFileReply(element: element, status: VFWire.stOk, data: rows)
        print("VF-FILE: LIST \(path.isEmpty ? "/" : path) → \(sorted.count) entr\(sorted.count == 1 ? "y" : "ies") (\(rows.count / VFWire.entryRowLen) rows)")
    }

    /// STAT: size + type for the resolved path.
    private func serveStat(_ payload: [UInt8], element: VZVirtioQueueElement) {
        guard let root = shareRootURL(), let path = String(bytes: payload, encoding: .utf8),
              let url = VFWire.resolveSubpath(root: root, path: path) else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            writeFileReply(element: element, status: VFWire.stNotFound, data: [])
            return
        }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let ti = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let sec = UInt64(max(0, ti))
        let nsec = UInt32(max(0, min(999_999_999, (ti - floor(ti)) * 1_000_000_000)))
        let includeMtime = !vfStatLegacyShape(root: root)
        let data = VFWire.encodeStatData(size: size, isDir: isDir.boolValue, mtimeSec: sec, mtimeNsec: nsec, includeMtime: includeMtime)
        writeFileReply(element: element, status: VFWire.stOk, data: data)
        print("VF-FILE: STAT \(path) → \(isDir.boolValue ? "dir" : "file") size=\(size)\(includeMtime ? " mtime=\(sec)" : " (v1 shape)")")
    }

    /// READ at an explicit offset (stateless): open, seek, read a chunk
    /// that fits the guest's reply buffer, close. EOF = an empty ok reply.
    private func serveRead(_ payload: [UInt8], element: VZVirtioQueueElement) {
        guard payload.count >= VFWire.readOffsetLen else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let pathBytes = Array(payload[0..<(payload.count - VFWire.readOffsetLen)])
        var offset: UInt64 = 0
        for i in 0..<VFWire.readOffsetLen {
            offset |= UInt64(payload[payload.count - VFWire.readOffsetLen + i]) << (8 * i)
        }
        guard let root = shareRootURL(), let path = String(bytes: pathBytes, encoding: .utf8),
              let url = VFWire.resolveSubpath(root: root, path: path) else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            writeFileReply(element: element, status: VFWire.stNotFound, data: [])
            return
        }
        if isDir.boolValue {
            writeFileReply(element: element, status: VFWire.stIsDir, data: [])
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        // The reply frame costs 3 bytes: one reply never exceeds the
        // guest's 32 KiB buffer (32765 data bytes per round trip).
        let maxData = max(0, Int(element.writeBuffersByteCount) - VFWire.replyHdrLen)
        let chunk = (try? handle.read(upToCount: maxData)) ?? Data()
        writeFileReply(element: element, status: VFWire.stOk, data: [UInt8](chunk))
        print("VF-FILE: READ \(path) off=\(offset) → \(chunk.count) byte(s)")
    }

    // ------------------------------------------------------------------
    // HF3 mutation serving (issue #737). OPEN/CLOSE/WRITE/TRUNCATE/FSYNC
    // ride the 8-slot handle table (cursors here); RENAME/MKDIR/DELETE
    // stay stateless path ops. All write kernel-resolved paths only.
    // ------------------------------------------------------------------

    /// OPEN [path]: flags byte bit0 = create-if-missing, bit1 = append.
    /// Reply: [handle u16le] or an honest status.
    private func serveOpen(_ payload: [UInt8], flags: UInt8, element: VZVirtioQueueElement) {
        guard let root = shareRootURL(), let path = String(bytes: payload, encoding: .utf8),
              let url = VFWire.resolveSubpath(root: root, path: path) else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let create = (flags & VFWire.openFlagCreate) != 0
        let append = (flags & VFWire.openFlagAppend) != 0
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists && isDir.boolValue {
            writeFileReply(element: element, status: VFWire.stIsDir, data: [])
            return
        }
        if !exists {
            guard create else {
                writeFileReply(element: element, status: VFWire.stNotFound, data: [])
                return
            }
            guard fm.createFile(atPath: url.path, contents: nil) else {
                writeFileReply(element: element, status: VFWire.stHostError, data: [])
                return
            }
        }
        guard let fh = try? FileHandle(forUpdating: url) else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let (handle, status) = fileHandleTable.open(path: path, fh: fh, append: append)
        if status != VFWire.stOk {
            try? fh.close()
            writeFileReply(element: element, status: status, data: [])
            return
        }
        writeFileReply(element: element, status: VFWire.stOk, data: VFWire.encodeOpenReply(handle: handle))
        print("VF-FILE: OPEN \(path) → h=\(handle) append=\(append) create=\(create)")
    }

    /// CLOSE [handle u16le]: flush + free the slot.
    private func serveClose(_ payload: [UInt8], element: VZVirtioQueueElement) {
        guard let handle = VFWire.handle(fromPayload: payload) else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let status = fileHandleTable.close(handle)
        writeFileReply(element: element, status: status, data: [])
        print("VF-FILE: CLOSE h=\(handle) → status \(status)")
    }

    /// WRITE [handle u16le][data]: cursor write (append → EOF). Reply:
    /// [written u64le].
    private func serveWrite(_ payload: [UInt8], element: VZVirtioQueueElement) {
        guard let handle = VFWire.handle(fromPayload: payload), payload.count >= VFWire.handleLen else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let data = Array(payload[VFWire.handleLen...])
        let (written, status) = fileHandleTable.write(handle, data: data)
        if status != VFWire.stOk || written == nil {
            writeFileReply(element: element, status: status, data: [])
            return
        }
        writeFileReply(element: element, status: VFWire.stOk, data: VFWire.encodeWrittenReply(written: written!))
        print("VF-FILE: WRITE h=\(handle) → \(written!) byte(s), cursor advanced")
    }

    /// TRUNCATE [handle u16le][size u64le].
    private func serveTruncate(_ payload: [UInt8], element: VZVirtioQueueElement) {
        guard let handle = VFWire.handle(fromPayload: payload),
              payload.count >= VFWire.handleLen + VFWire.truncateSizeLen else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        var size: UInt64 = 0
        for i in 0..<8 {
            size |= UInt64(payload[VFWire.handleLen + i]) << (8 * i)
        }
        let status = fileHandleTable.truncate(handle, size: size)
        writeFileReply(element: element, status: status, data: [])
        print("VF-FILE: TRUNCATE h=\(handle) size=\(size) → status \(status)")
    }

    /// FSYNC [handle u16le]: synchronize() on the live fd.
    private func serveFsync(_ payload: [UInt8], element: VZVirtioQueueElement) {
        guard let handle = VFWire.handle(fromPayload: payload) else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let status = fileHandleTable.fsync(handle)
        writeFileReply(element: element, status: status, data: [])
        print("VF-FILE: FSYNC h=\(handle) → status \(status)")
    }

    /// RENAME/REPLACE [from][0x00][to]: one atomic host primitive.
    private func serveRename(_ payload: [UInt8], mode: VFWire.RenameMode, element: VZVirtioQueueElement) {
        guard let root = shareRootURL() else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let status = VFWire.rename(root: root, payload: payload, mode: mode)
        writeFileReply(element: element, status: status, data: [])
        let operation = mode == .replace ? "REPLACE" : "RENAME"
        let paths = String(bytes: payload, encoding: .utf8)?.replacingOccurrences(of: "\0", with: " → ") ?? "<invalid>"
        print("VF-FILE: \(operation) \(paths) → status \(status)")
    }

    /// MKDIR [path]: one level (parents must exist). stExists when the
    /// target is already there.
    private func serveMkdir(_ payload: [UInt8], element: VZVirtioQueueElement) {
        guard let root = shareRootURL(), let path = String(bytes: payload, encoding: .utf8),
              let url = VFWire.resolveSubpath(root: root, path: path), !path.isEmpty else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            writeFileReply(element: element, status: VFWire.stExists, data: [])
            return
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            writeFileReply(element: element, status: VFWire.stOk, data: [])
            print("VF-FILE: MKDIR \(path)")
        } catch {
            // Missing parent reads as not-found; other failures host error.
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
        }
    }

    /// CLONE [from][0x00][to] (HF7, issue #741): APFS COW dedup — the
    /// worktree workload. Both subpaths go through the same traversal
    /// defense as every VF op; src must exist, dst must NOT exist
    /// (clonefile(2) demands a fresh dst — pre-checked, so the error
    /// never surfaces as a raw EEXIST). Regular files clone with
    /// Darwin.clonefile(2); DIRECTORY TREES clone with copyfile(3) +
    /// COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_RECURSIVE (the man page
    /// explicitly prefers copyfile(3) over clonefile(2) for directories).
    /// Clones share blocks until one side edits — measured live by the
    /// HF7 gate (artifact m34-hf7-measurement.txt).
    private func serveClone(_ payload: [UInt8], element: VZVirtioQueueElement) {
        guard let root = shareRootURL(), let nul = payload.firstIndex(of: 0),
              let from = String(bytes: payload[0..<nul], encoding: .utf8),
              let to = String(bytes: payload[(nul + 1)...], encoding: .utf8),
              let fromURL = VFWire.resolveSubpath(root: root, path: from),
              let toURL = VFWire.resolveSubpath(root: root, path: to),
              !from.isEmpty, !to.isEmpty else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let fm = FileManager.default
        var fromIsDir: ObjCBool = false
        guard fm.fileExists(atPath: fromURL.path, isDirectory: &fromIsDir) else {
            writeFileReply(element: element, status: VFWire.stNotFound, data: [])
            return
        }
        if fm.fileExists(atPath: toURL.path) {
            writeFileReply(element: element, status: VFWire.stExists, data: [])
            return
        }
        let rc: Int32
        if !fromIsDir.boolValue {
            // Regular file: the raw clonefile(2) — COW clone, new inode.
            rc = Darwin.clonefile(fromURL.path, toURL.path, 0)
        } else {
            // Directory tree: copyfile(3) with COPYFILE_CLONE does the
            // same per-item COW clone the man page recommends. (Root's
            // relative path strings are fine — the file names carry no
            // leading separator because resolveSubpath stripped it.)
            rc = copyfile(fromURL.path, toURL.path, nil,
                          UInt32(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_RECURSIVE))
        }
        if rc == 0 {
            writeFileReply(element: element, status: VFWire.stOk, data: [])
            print("VF-FILE: CLONE \(from) → \(to) (\(fromIsDir.boolValue ? "tree" : "file") COW clone)")
        } else {
            // The dst-exists race (checked above, but two guests could
            // clone concurrently): map EEXIST honestly, everything else
            // is a host error with the errno for the log.
            let e = errno
            if e == EEXIST {
                writeFileReply(element: element, status: VFWire.stExists, data: [])
            } else {
                writeFileReply(element: element, status: VFWire.stHostError, data: [])
            }
            print("VF-FILE: CLONE \(from) → \(to) FAILED errno=\(e) (\(String(cString: strerror(e))))")
        }
    }

    /// DELETE [path]: file or EMPTY directory (never recursive).
    private func serveDelete(_ payload: [UInt8], element: VZVirtioQueueElement) {
        guard let root = shareRootURL(), let path = String(bytes: payload, encoding: .utf8),
              let url = VFWire.resolveSubpath(root: root, path: path) else {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
            return
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            writeFileReply(element: element, status: VFWire.stNotFound, data: [])
            return
        }
        do {
            try fm.removeItem(at: url)
            writeFileReply(element: element, status: VFWire.stOk, data: [])
            print("VF-FILE: DELETE \(path)")
        } catch {
            writeFileReply(element: element, status: VFWire.stHostError, data: [])
        }
    }

    /// Write a framed reply, honoring the element's write-buffer capacity
    /// (an over-cap reply is reported status=3 honestly, never written
    /// past the buffer).
    private func writeFileReply(element: VZVirtioQueueElement, status: UInt8, data: [UInt8]) {
        var reply = VFWire.encodeReply(status: status, data: data)
        let cap = Int(element.writeBuffersByteCount)
        if reply.count > cap {
            reply = VFWire.encodeReply(status: VFWire.stTruncated, data: [])
            print("VF-FILE: reply \(data.count)-byte data exceeds \(cap)-byte write buffer — status=3 truncated")
        }
        do {
            try element.write(Data(reply))
        } catch {
            print("VF-FILE: reply write FAILED: \(error)")
        }
    }

    /// The share root (validated once per serve; an unreadable share
    /// dir is reported loudly, never silently served as empty).
    private func shareRootURL() -> URL? {
        guard let dir = cvcFileShareDir else { return nil }
        let url = URL(fileURLWithPath: dir)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            print("VF-FILE: share dir not found or not a directory: \(dir)")
            return nil
        }
        return url
    }
}

#endif
