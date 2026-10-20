import Foundation
import XCTest
@testable import VFWire

final class DirectoryTests: XCTestCase {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("b2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func request(_ token: [UInt8], offset: Int, limit: Int = 16) -> [UInt8] {
        token + [UInt8(truncatingIfNeeded: offset), UInt8(truncatingIfNeeded: offset >> 8),
                 UInt8(truncatingIfNeeded: limit), UInt8(truncatingIfNeeded: limit >> 8)]
    }

    private func names(_ page: [UInt8]) -> [String] {
        let count = Int(page[8]) | (Int(page[9]) << 8)
        return (0..<count).map {
            let at = 16 + $0 * DirectoryTable.rowBytes
            let len = Int(page[at + 264]) | (Int(page[at + 265]) << 8)
            return String(decoding: page[at..<(at + len)], as: UTF8.self)
        }
    }

    func testCompleteLosslessPaginationAndEOF() throws {
        try withRoot { root in
            let prefix = String(repeating: "p", count: 31)
            let expected = (0..<35).map { "file-\($0)" } +
                [prefix + "-one", prefix + "-two", String(repeating: "x", count: 255), ".hidden", "utf8-é"]
            for name in expected { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
            let table = DirectoryTable()
            let (status, token) = table.open(root: root, path: "")
            XCTAssertEqual(status, VFWire.stOk)
            var found: [String] = []
            var offset = 0
            while true {
                let (st, page) = table.page(request(token, offset: offset, limit: 7))
                XCTAssertEqual(st, VFWire.stOk)
                let batch = names(page)
                found += batch
                offset = Int(page[0]) | (Int(page[1]) << 8)
                if page[12] == 1 { break }
                XCTAssertFalse(batch.isEmpty)
            }
            XCTAssertEqual(Set(found), Set(expected))
            XCTAssertEqual(found.count, expected.count)
            let (st, end) = table.page(request(token, offset: offset))
            XCTAssertEqual(st, VFWire.stOk)
            XCTAssertEqual(end, [40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0])
            XCTAssertEqual(table.close(token).0, VFWire.stOk)
            XCTAssertEqual(table.page(request(token, offset: 0)).0, VFWire.stHandle)
            XCTAssertEqual(table.close(token).0, VFWire.stHandle)
        }
    }

    func testExactAndOverEntryLimit() throws {
        try withRoot { root in
            for i in 0..<256 { try Data().write(to: root.appendingPathComponent("f-\(i)")) }
            let table = DirectoryTable()
            let (status, token) = table.open(root: root, path: "")
            XCTAssertEqual(status, VFWire.stOk)
            let last = table.page(request(token, offset: 240))
            XCTAssertEqual(last.0, VFWire.stOk)
            XCTAssertEqual(names(last.1).count, 16)
            XCTAssertEqual(last.1[12], 1)
            XCTAssertEqual(table.close(token).0, VFWire.stOk)
            try Data().write(to: root.appendingPathComponent("overflow"))
            XCTAssertEqual(table.open(root: root, path: "").0, VFWire.stLimit)
        }
    }

    func testPathNameAndDepthLimits() throws {
        let exact = String(repeating: "a", count: 255) + "/" + String(repeating: "b", count: 254) + "/c"
        XCTAssertEqual(exact.utf8.count, 512)
        XCTAssertTrue(DirectoryTable.validPath(exact))
        XCTAssertFalse(DirectoryTable.validPath(exact + "d"))
        XCTAssertTrue(DirectoryTable.validPath("a/b/c/d/e/f/g/h"))
        XCTAssertFalse(DirectoryTable.validPath("a/b/c/d/e/f/g/h/i"))
        XCTAssertFalse(DirectoryTable.validPath(String(repeating: "a", count: 256)))
        for bad in ["../escape", "a/../b", "a/./b", "a//b", "/a", "a\u{0}b"] {
            XCTAssertFalse(DirectoryTable.validPath(bad))
        }
        try withRoot { root in
            let nested = "a/b/c/d/e/f/g/h"
            try FileManager.default.createDirectory(at: root.appendingPathComponent(nested), withIntermediateDirectories: true)
            let table = DirectoryTable()
            let (status, token) = table.open(root: root, path: nested)
            XCTAssertEqual(status, VFWire.stOk)
            XCTAssertEqual(table.close(token).0, VFWire.stOk)
            XCTAssertEqual(table.open(root: root, path: nested + "/i").0, VFWire.stPathLimit)
        }
    }

    func testNameOverLimitRefusesInsteadOfTruncating() throws {
        XCTAssertNotNil(DirectoryTable.encodeRow(name: [UInt8](repeating: 120, count: 255), size: 7, isDirectory: false))
        XCTAssertNil(DirectoryTable.encodeRow(name: [UInt8](repeating: 120, count: 256), size: 7, isDirectory: false))
        XCTAssertNil(DirectoryTable.encodeRow(name: Array(String(repeating: "é", count: 128).utf8), size: 7, isDirectory: false))
        XCTAssertNil(DirectoryTable.encodeRow(name: [97, 0, 98], size: 0, isDirectory: false))
    }

    func testStableSnapshotAndDuringCaptureMutation() throws {
        try withRoot { root in
            try Data("old".utf8).write(to: root.appendingPathComponent("old"))
            let table = DirectoryTable()
            let (status, token) = table.open(root: root, path: "")
            XCTAssertEqual(status, VFWire.stOk)
            try FileManager.default.removeItem(at: root.appendingPathComponent("old"))
            try Data().write(to: root.appendingPathComponent("new"))
            XCTAssertEqual(names(table.page(request(token, offset: 0)).1), ["old"])
            XCTAssertEqual(table.close(token).0, VFWire.stOk)
            XCTAssertEqual(table.open(root: root, path: "", duringCapture: {
                try Data().write(to: root.appendingPathComponent("raced"))
            }).0, VFWire.stChanged)
            let fresh = table.open(root: root, path: "")
            XCTAssertEqual(fresh.0, VFWire.stOk)
            XCTAssertEqual(names(table.page(request(fresh.1, offset: 0)).1), ["new", "raced"])
        }
    }

    func testCapacityStaleTokensAndBadRequests() throws {
        try withRoot { root in
            let table = DirectoryTable()
            var tokens: [[UInt8]] = []
            for _ in 0..<8 {
                let result = table.open(root: root, path: "")
                XCTAssertEqual(result.0, VFWire.stOk)
                tokens.append(result.1)
            }
            XCTAssertEqual(table.open(root: root, path: "").0, VFWire.stHandle)
            XCTAssertEqual(table.close(tokens[0]).0, VFWire.stOk)
            let replacement = table.open(root: root, path: "")
            XCTAssertEqual(replacement.0, VFWire.stOk)
            XCTAssertNotEqual(replacement.1, tokens[0])
            XCTAssertEqual(table.page(request(tokens[0], offset: 0)).0, VFWire.stHandle)
            XCTAssertEqual(table.page([]).0, VFWire.stHostError)
            XCTAssertEqual(table.page(request(replacement.1, offset: 1)).0, VFWire.stHostError)
            XCTAssertEqual(table.page(request(replacement.1, offset: 0, limit: 0)).0, VFWire.stHostError)
            XCTAssertEqual(table.page(request(replacement.1, offset: 0, limit: 17)).0, VFWire.stHostError)
            XCTAssertEqual(table.close([]).0, VFWire.stHostError)
        }
    }

    /// #2853: repeated open/page/close sequences on one table must each
    /// serve their own directory — slot recycling across different paths
    /// (root -> child -> deeper -> root), never a stale or wedged session.
    func testSequentialReuseAcrossPaths() throws {
        try withRoot { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
            try Data("r".utf8).write(to: root.appendingPathComponent("r.txt"))
            try Data("c".utf8).write(to: root.appendingPathComponent("a/c.txt"))
            try Data("d".utf8).write(to: root.appendingPathComponent("a/b/d.txt"))
            let table = DirectoryTable()
            for (path, want) in [("", ["a", "r.txt"]), ("a", ["b", "c.txt"]), ("a/b", ["d.txt"]), ("", ["a", "r.txt"])] {
                let (status, token) = table.open(root: root, path: path)
                XCTAssertEqual(status, VFWire.stOk)
                let (pst, page) = table.page(request(token, offset: 0))
                XCTAssertEqual(pst, VFWire.stOk)
                XCTAssertEqual(names(page), want)
                XCTAssertEqual(page[12], 1) // single-page end
                XCTAssertEqual(table.close(token).0, VFWire.stOk)
            }
        }
    }

    func testMissingNonDirectoryAndSymlinkEscape() throws {
        try withRoot { root in
            let table = DirectoryTable()
            XCTAssertEqual(table.open(root: root, path: "missing").0, VFWire.stNotFound)
            try Data().write(to: root.appendingPathComponent("file"))
            XCTAssertEqual(table.open(root: root, path: "file").0, VFWire.stIsDir)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path,
                                                       withDestinationPath: root.deletingLastPathComponent().path)
            XCTAssertEqual(table.open(root: root, path: "escape").0, VFWire.stHostError)
        }
    }
}
