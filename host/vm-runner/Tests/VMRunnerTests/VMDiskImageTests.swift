// VMDiskImageTests — M100b (issue #2307, ADR 0050 D2): the --data-disk
// image contract, pinned without a VM. Create-if-absent (zero-filled,
// sector-aligned), validate-if-present (positive multiple of 512),
// named refusals for the shapes VZ would only reject opaquely.
import XCTest
@testable import VMDiskImage

final class VMDiskImageTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmdisk-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func path(_ name: String) -> String {
        tmpDir.appendingPathComponent(name).path
    }

    /// An absent image is created: default 64 MiB, all zeros, sector count
    /// reported, `created` flagged.
    func testCreatesAbsentImage() throws {
        let p = path("fresh.img")
        let prepared = try DataDisk.prepare(path: p)
        XCTAssertTrue(prepared.created)
        XCTAssertEqual(prepared.sectors, DataDisk.defaultBytes / 512)
        let attrs = try FileManager.default.attributesOfItem(atPath: p)
        XCTAssertEqual((attrs[.size] as? UInt64) ?? 0, DataDisk.defaultBytes)
        // A spot-check that the image is zero-filled (head + tail sectors).
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: p))
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 512) ?? Data()
        XCTAssertEqual(head, Data(count: 512))
        try handle.seek(toOffset: DataDisk.defaultBytes - 512)
        let tail = try handle.read(upToCount: 512) ?? Data()
        XCTAssertEqual(tail, Data(count: 512))
    }

    /// An existing, well-formed image is opened read-only in spirit:
    /// contents untouched, `created` false, sectors derived from size.
    func testOpensExistingImage() throws {
        let p = path("existing.img")
        var sector = Data(count: 512)
        sector[0] = 0xAB
        try sector.write(to: URL(fileURLWithPath: p))
        let prepared = try DataDisk.prepare(path: p)
        XCTAssertFalse(prepared.created)
        XCTAssertEqual(prepared.sectors, 1)
        let back = try Data(contentsOf: URL(fileURLWithPath: p))
        XCTAssertEqual(back[0], 0xAB, "existing image contents must be untouched")
        XCTAssertEqual(back.count, 512)
    }

    /// A file whose size is not a multiple of 512 refuses by name — VZ's
    /// URL attachment would only fail it opaquely at attach time.
    func testRefusesUnalignedSize() throws {
        let p = path("odd.img")
        try Data(count: 513).write(to: URL(fileURLWithPath: p))
        XCTAssertThrowsError(try DataDisk.prepare(path: p)) { error in
            XCTAssertEqual(error as? DataDisk.PrepareError, .badImageSize(bytes: 513))
        }
    }

    /// A zero-length file is not a disk image (VZ requires size > 0 too).
    func testRefusesEmptyFile() throws {
        let p = path("empty.img")
        FileManager.default.createFile(atPath: p, contents: nil)
        XCTAssertThrowsError(try DataDisk.prepare(path: p)) { error in
            XCTAssertEqual(error as? DataDisk.PrepareError, .badImageSize(bytes: 0))
        }
    }

    /// A create whose truncate leg fails removes the just-made file — it
    /// must not leave a 0-byte poison the next launch would refuse as
    /// badImageSize(0). The failure is forced with RLIMIT_FSIZE: the
    /// ftruncate to 64 MiB crosses the 1 KiB cap and fails EFBIG, with
    /// SIGXFSZ ignored so the probe cannot kill the test host. The limit
    /// is process-wide, so it is restored before the retry assertion.
    func testFailedCreateLeavesNoFile() throws {
        signal(SIGXFSZ, SIG_IGN)
        var old = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_FSIZE, &old), 0)
        var cap = old
        cap.rlim_cur = 1024
        XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &cap), 0)
        let p = path("poisoned.img")
        XCTAssertThrowsError(try DataDisk.prepare(path: p)) { error in
            guard case .couldNotSize = error as? DataDisk.PrepareError else {
                return XCTFail("expected couldNotSize, got \(error)")
            }
        }
        XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &old), 0)
        signal(SIGXFSZ, SIG_DFL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p),
                       "a failed create must not leave a poisoned file")
        // The retry the fix exists for: the same path creates cleanly.
        let prepared = try DataDisk.prepare(path: p)
        XCTAssertTrue(prepared.created)
        XCTAssertEqual(prepared.sectors, DataDisk.defaultBytes / 512)
    }

    /// A directory is never an image and is never recreated.
    func testRefusesDirectory() throws {
        XCTAssertThrowsError(try DataDisk.prepare(path: tmpDir.path)) { error in
            XCTAssertEqual(error as? DataDisk.PrepareError, .notRegularFile)
        }
    }

    /// The identifier the guest's GET_ID matches: fixed, within VZ's
    /// 20-byte limit, exactly what ADR 0050 D1 pins.
    func testIdentifierIsTheAdrString() {
        XCTAssertEqual(DataDisk.vlfsIdentifier, "virelai-vlfs")
        XCTAssertLessThanOrEqual(DataDisk.vlfsIdentifier.utf8.count, 20)
    }

    /// The default size is a multiple of 512 and inside the ADR's
    /// 16 MiB…1 GiB volume window.
    func testDefaultSizeInsideVolumeWindow() {
        XCTAssertEqual(DataDisk.defaultBytes % 512, 0)
        XCTAssertGreaterThanOrEqual(DataDisk.defaultBytes, 16 * 1024 * 1024)
        XCTAssertLessThanOrEqual(DataDisk.defaultBytes, 1024 * 1024 * 1024)
    }
}
