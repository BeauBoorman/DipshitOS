// VMDiskImage — M100b (issue #2307, ADR 0050 D2): the host-side
// preparation of the `--data-disk <img>` raw image. Pure Foundation, zero
// Virtualization imports, so `swift test` pins the create/validate rules
// on any host — the runner itself only consumes `prepare`.
//
// The contract the ADR pins: a raw file whose size is a positive multiple
// of 512 bytes (the only format VZDiskImageStorageDeviceAttachment's URL
// init accepts); absent means create a zero-filled 64 MiB image by
// ftruncate — never formatted, never a filesystem (mkfs.vlfs is M100c's
// job). The guest finds the disk by VIRTIO_BLK_T_GET_ID ==
// `vlfsIdentifier`, so this module also owns that string.
import Foundation

public enum DataDisk {
    /// The `blockDeviceIdentifier` the runner sets on the second
    /// virtio-blk function (ADR 0050 D1; 12 ASCII bytes, inside VZ's
    /// 20-byte `validateBlockDeviceIdentifier` limit).
    public static let vlfsIdentifier = "virelai-vlfs"

    /// Default image size when the flagged file does not exist
    /// (ADR 0050 D2: 64 MiB, zero-filled via ftruncate).
    public static let defaultBytes: UInt64 = 64 * 1024 * 1024

    public struct Prepared: Equatable {
        public let url: URL
        /// File size in 512-byte sectors.
        public let sectors: UInt64
        /// True when `prepare` created the image this call.
        public let created: Bool
    }

    public enum PrepareError: Error, Equatable {
        /// The file exists but is zero-length or not a multiple of 512 B —
        /// VZ's URL attachment would refuse it anyway; we refuse first with
        /// a named reason.
        case badImageSize(bytes: UInt64)
        /// The path names a directory or another non-regular file.
        case notRegularFile
        /// Creation or truncation failed (the underlying reason is carried).
        case couldNotCreate(String)
        case couldNotSize(String)
    }

    /// Open or create the raw image at `path`. Existing files are only
    /// validated (size > 0, multiple of 512 B) — a VLFS image's contents are
    /// the guest's business. A missing file becomes `createBytes` of zeros.
    /// `createBytes` must itself be a positive multiple of 512.
    public static func prepare(path: String, createBytes: UInt64 = defaultBytes) throws -> Prepared {
        precondition(createBytes > 0 && createBytes % 512 == 0,
                     "data-disk image size must be a positive multiple of 512")
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard !isDir.boolValue else { throw PrepareError.notRegularFile }
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? UInt64) ?? UInt64((attrs[.size] as? Int) ?? 0)
            guard size > 0, size % 512 == 0 else {
                throw PrepareError.badImageSize(bytes: size)
            }
            return Prepared(url: url, sectors: size / 512, created: false)
        }
        // Absent: create a zero-filled raw image by truncation (the shape
        // VZ's own header documents).
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw PrepareError.couldNotCreate(url.path)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: createBytes)
            try handle.close()
        } catch {
            // A failed create must not leave the 0-byte file behind — the
            // next launch would refuse it by name as badImageSize(0)
            // where the intent was a fresh image.
            try? fm.removeItem(atPath: url.path)
            throw PrepareError.couldNotSize("\(error)")
        }
        return Prepared(url: url, sectors: createBytes / 512, created: true)
    }

    public enum AttachError: Error, Equatable {
        /// `diskutil image attach` exited nonzero — stderr carried.
        case attachFailed(String)
        /// Attach exited 0 but no `/dev/diskN` node was in its output.
        case noDeviceNode(String)
    }

    /// Issue #3112: attach `url` as a kernel block device
    /// (`/dev/diskN`) via `diskutil image attach --noMount`, returning
    /// the device node. Guest I/O then flows through the kernel's
    /// disk-image driver — synchronous and FIFO — rather than VZ's
    /// asynchronous image pipeline, so a request the guest completed is
    /// in the image file (or its page cache) before the power drops,
    /// and a VZDiskBlockDeviceStorageDeviceAttachment exposes a real
    /// flush barrier to the guest.
    public static func attachBlockDevice(url: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["image", "attach", "--noMount", url.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw AttachError.attachFailed(e.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let dev = stdout.split(separator: "\n").map(String.init)
                .first(where: { $0.hasPrefix("/dev/disk") }) else {
            throw AttachError.noDeviceNode(stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return dev
    }

    /// "/dev/diskN" -> "/dev/rdiskN" — the raw node for file-handle I/O.
    public static func rawDevice(_ dev: String) -> String {
        dev.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
    }

    /// Best-effort eject of a node from `attachBlockDevice`. The eject
    /// refuses while the device still has openers — VZ retains the
    /// attachment's file handle until process exit, so this is hygiene
    /// for the early-failure paths, not a contract. A node left behind
    /// is self-healing anyway: the next attach of the same image
    /// returns it.
    public static func detachBlockDevice(_ dev: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["eject", dev]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
