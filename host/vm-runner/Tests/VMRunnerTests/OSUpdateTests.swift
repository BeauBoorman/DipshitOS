// OSUpdateTests — M115f (#2465): the class-A pin for the --apply-update
// engine. Every test runs without a VM: a tempdir share/UPDATE set is
// composed, signed with the fleet's pinned RFC 8032 test seed, and the
// manifest grammar / refusal names / swap ordering are exercised against
// it directly.
import CryptoKit
import Foundation
import XCTest
@testable import VMProfile

final class OSUpdateTests: XCTestCase {

    /// The fleet's pinned test key — RFC 8032 §7.1 TEST 1, the same seed
    /// go-flint.spec stages as `agent-sign` and the os-update gate stages
    /// for GOUPD.ELF.
    private let testSeed = Data([
        0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60,
        0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c, 0xc4,
        0x44, 0x49, 0xc5, 0x69, 0x7b, 0x32, 0x69, 0x19,
        0x70, 0x3b, 0xac, 0x03, 0x1c, 0xae, 0x7f, 0x60,
    ])
    private var pub: Curve25519.Signing.PublicKey!
    private var pubData: Data!

    override func setUp() {
        pub = try! Curve25519.Signing.PrivateKey(rawRepresentation: testSeed).publicKey
        pubData = pub.rawRepresentation
    }

    // MARK: - fixture composition

    private func sha256Hex(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// Compose a staged UPDATE dir: the three payload files plus a
    /// manifest signed over its own bytes.
    @discardableResult
    private func stageSet(in dir: URL, version: String = "test-b",
                          kernel: Data? = nil, efi: Data? = nil,
                          image: Data? = nil) throws -> URL {
        let fm = FileManager.default
        let update = dir.appendingPathComponent("UPDATE")
        try fm.createDirectory(at: update, withIntermediateDirectories: true)
        let k = kernel ?? Data("KRN2-fake-kernel".utf8)
        let e = efi ?? Data("MZ-fake-loader".utf8)
        let img = image ?? Data("fake-image-bytes".utf8)
        try k.write(to: update.appendingPathComponent("KERNEL.BIN"))
        try e.write(to: update.appendingPathComponent("BOOTAA64.EFI"))
        try img.write(to: update.appendingPathComponent("OS.IMG"))
        let mf = """
        #v1 os-update
        OS.IMG\tkind=image\tsha256=\(sha256Hex(img))\tbytes=\(img.count)\tversion=\(version)
        KERNEL.BIN\tkind=member\tsha256=\(sha256Hex(k))\tbytes=\(k.count)\tesp=KERNEL.BIN
        BOOTAA64.EFI\tkind=member\tsha256=\(sha256Hex(e))\tbytes=\(e.count)\tesp=EFI/BOOT/BOOTAA64.EFI

        """
        let mfData = Data(mf.utf8)
        try mfData.write(to: update.appendingPathComponent("UPDATE.MF"))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: testSeed)
        let sig = try key.signature(for: mfData)
        try sig.write(to: update.appendingPathComponent("UPDATE.SIG"))
        return update
    }

    private func baseImage(in dir: URL, contents: String = "old-base") throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = dir.appendingPathComponent("base.img")
        try Data(contents.utf8).write(to: base)
        return base
    }

    // MARK: - manifest grammar

    func testManifestParsesAndVerifies() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let update = try stageSet(in: dir, version: "v9")
        let mf = try OSUpdate.verify(updateDir: update, publicKey: pubData)
        XCTAssertEqual(mf.version, "v9")
        XCTAssertEqual(mf.members.count, 3)
        XCTAssertEqual(mf.image?.name, "OS.IMG")
    }

    func testManifestRefusals() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        // Missing manifest.
        let update = dir.appendingPathComponent("UPDATE")
        try FileManager.default.createDirectory(at: update, withIntermediateDirectories: true)
        XCTAssertThrowsError(try OSUpdate.verify(updateDir: update, publicKey: pubData)) {
            XCTAssertEqual($0 as? OSUpdate.UpdateError, .manifestMissing)
        }
        // Header absent.
        try Data("OS.IMG\tkind=image\tsha256=x\tbytes=1\n".utf8)
            .write(to: update.appendingPathComponent("UPDATE.MF"))
        XCTAssertThrowsError(try OSUpdate.verify(updateDir: update, publicKey: pubData)) {
            guard case .manifestMalformed = $0 as? OSUpdate.UpdateError else {
                return XCTFail("want manifest_malformed, got \($0)")
            }
        }
        // Name traversal refused.
        let bad = "#v1 os-update\n../escape\tkind=image\tsha256="
            + String(repeating: "a", count: 64) + "\tbytes=1\tversion=v\n"
        try Data(bad.utf8).write(to: update.appendingPathComponent("UPDATE.MF"))
        XCTAssertThrowsError(try OSUpdate.verify(updateDir: update, publicKey: pubData)) {
            guard case .manifestMalformed = $0 as? OSUpdate.UpdateError else {
                return XCTFail("want manifest_malformed, got \($0)")
            }
        }
    }

    func testMissingMemberRowRefuses() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let update = dir.appendingPathComponent("UPDATE")
        try FileManager.default.createDirectory(at: update, withIntermediateDirectories: true)
        let img = Data("img".utf8)
        try img.write(to: update.appendingPathComponent("OS.IMG"))
        let mf = "#v1 os-update\nOS.IMG\tkind=image\tsha256=\(sha256Hex(img))\tbytes=\(img.count)\tversion=v\n"
        let mfData = Data(mf.utf8)
        try mfData.write(to: update.appendingPathComponent("UPDATE.MF"))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: testSeed)
        try key.signature(for: mfData).write(to: update.appendingPathComponent("UPDATE.SIG"))
        XCTAssertThrowsError(try OSUpdate.verify(updateDir: update, publicKey: pubData)) {
            guard case .manifestMalformed = $0 as? OSUpdate.UpdateError else {
                return XCTFail("want manifest_malformed, got \($0)")
            }
        }
    }

    // MARK: - signature

    func testWrongKeyRefusesSigInvalid() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let update = try stageSet(in: dir)
        let wrong = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(try OSUpdate.verify(updateDir: update, publicKey: wrong)) {
            XCTAssertEqual($0 as? OSUpdate.UpdateError, .sigInvalid)
        }
    }

    func testTamperedMemberRefusesHashMismatch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let update = try stageSet(in: dir)
        try Data("tampered".utf8)
            .write(to: update.appendingPathComponent("OS.IMG"))
        XCTAssertThrowsError(try OSUpdate.verify(updateDir: update, publicKey: pubData)) {
            guard case .hashMismatch(let name) = $0 as? OSUpdate.UpdateError else {
                return XCTFail("want hash_mismatch, got \($0)")
            }
            XCTAssertEqual(name, "OS.IMG")
        }
    }

    func testMissingSigRefuses() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let update = try stageSet(in: dir)
        try FileManager.default.removeItem(
            at: update.appendingPathComponent("UPDATE.SIG"))
        XCTAssertThrowsError(try OSUpdate.verify(updateDir: update, publicKey: pubData)) {
            XCTAssertEqual($0 as? OSUpdate.UpdateError, .sigMissing)
        }
    }

    // MARK: - apply / rollback

    func testApplySwapsBaseAndRetainsPrev() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let update = try stageSet(in: dir, image: Data("new-base".utf8))
        let base = try baseImage(in: dir)
        let overlay = dir.appendingPathComponent("overlay.asif")
        try Data("stale-overlay".utf8).write(to: overlay)

        let mf = try OSUpdate.apply(updateDir: update, baseImage: base,
                                    publicKey: pubData, overlay: overlay)
        XCTAssertEqual(mf.version, "test-b")
        // New base in place, old base retained.
        XCTAssertEqual(try String(contentsOf: base), "new-base")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("base.img.prev")), "old-base")
        // The persistent overlay is discarded (stale sectors belong to the
        // old base), and the staged dir is consumed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlay.path))
        XCTAssertNil(OSUpdate.stagedDir(shareDir: dir))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("UPDATE.APPLIED").path))
    }

    func testApplyRefusedSetLeavesItAndBaseAlone() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let update = try stageSet(in: dir, image: Data("new".utf8))
        let base = try baseImage(in: dir)
        // Tamper after signing.
        try Data("evil".utf8).write(to: update.appendingPathComponent("OS.IMG"))
        XCTAssertThrowsError(try OSUpdate.apply(updateDir: update, baseImage: base,
                                              publicKey: pubData)) {
            XCTAssertEqual($0 as? OSUpdate.UpdateError, .hashMismatch("OS.IMG"))
        }
        XCTAssertEqual(try String(contentsOf: base), "old-base")
        XCTAssertNotNil(OSUpdate.stagedDir(shareDir: dir))
        // The refused private copy is cleaned up — no <base>.next litter.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("base.img.next").path))
    }

    /// The staged set sits in the guest-writable share, so a guest that
    /// rewrites UPDATE/OS.IMG while apply runs must never get its bytes
    /// installed: the private <base>.next copy is what the hash pins, so
    /// a racing rewrite ends in a refusal or installs the signed image —
    /// never the swapped-in bytes.
    func testApplyNeverInstallsGuestSwapIn() throws {
        let fm = FileManager.default
        let signed = Data(repeating: 0xA5, count: 8 << 20)
        let evil = Data(repeating: 0x5A, count: 8 << 20)
        let lock = NSLock()
        var racing = false
        for round in 0..<8 {
            let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let update = try stageSet(in: dir, image: signed)
            let base = try baseImage(in: dir)
            let imgURL = update.appendingPathComponent("OS.IMG")
            lock.lock(); racing = true; lock.unlock()
            let writer = Thread {
                var toggle = false
                while true {
                    lock.lock(); let go = racing; lock.unlock()
                    if !go { return }
                    try? (toggle ? evil : signed).write(to: imgURL)
                    toggle = !toggle
                }
            }
            writer.start()
            _ = try? OSUpdate.apply(updateDir: update, baseImage: base,
                                    publicKey: pubData)
            lock.lock(); racing = false; lock.unlock()
            while writer.isExecuting { Thread.sleep(forTimeInterval: 0.001) }
            let installed = try Data(contentsOf: base)
            XCTAssertTrue(installed == signed || installed == Data("old-base".utf8),
                "round \(round): base holds bytes that are neither the signed image nor the old base")
            try fm.removeItem(at: dir)
        }
    }

    func testRollbackRestoresAndSwapsForward() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let update = try stageSet(in: dir, image: Data("new-base".utf8))
        let base = try baseImage(in: dir)
        try OSUpdate.apply(updateDir: update, baseImage: base, publicKey: pubData)

        _ = try OSUpdate.rollback(baseImage: base)
        XCTAssertEqual(try String(contentsOf: base), "old-base")
        // One-step toggle: the just-replaced base is now the .prev, so a
        // second rollback walks back forward.
        _ = try OSUpdate.rollback(baseImage: base)
        XCTAssertEqual(try String(contentsOfFile: base.path, encoding: .utf8), "new-base")
    }

    func testRollbackWithoutPrevRefuses() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = try baseImage(in: dir)
        XCTAssertThrowsError(try OSUpdate.rollback(baseImage: base)) {
            XCTAssertEqual($0 as? OSUpdate.UpdateError, .noRollbackTarget)
        }
    }
}
