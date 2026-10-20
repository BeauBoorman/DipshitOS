// VFWireTests.swift — S1–S4 for M34 HF1 (issue #735): byte-parity of the
// wire-format encode/decode against the checked-in fixtures (the SAME
// bytes the guest Zig module pins), plus the path-defense policy. Runs
// with `swift test` — no VM, no Virtualization (VFWire is pure).
import XCTest
@testable import VFWire

final class VFWireTests: XCTestCase {
    /// The repo's checked-in fixture dir: tests/ (four levels up from this
    /// test file, which lives at host/vm-runner/Tests/VMRunnerTests/).
    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/VMRunnerTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // vm-runner
            .deletingLastPathComponent() // host
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("tests", isDirectory: true)
    }

    private func fixture(_ name: String) throws -> [UInt8] {
        let url = fixturesDir.appendingPathComponent(name)
        return [UInt8](try Data(contentsOf: url))
    }

    /// S1 — generator parity: the pattern generator reproduces the shared
    /// 32 KiB fixture byte-for-byte (the class-A gate sha256-pins the
    /// file; the guest Zig generator locks the same bytes).
    func testS1PatternGeneratorParity() throws {
        let fixture = try fixture("vf-pattern-32k.bin")
        XCTAssertEqual(fixture.count, VFWire.replyCap, "fixture must be the full 32 KiB")
        for i in 0..<fixture.count {
            XCTAssertEqual(fixture[i], VFWire.pattern(i), "pattern mismatch at index \(i)")
        }
    }

    /// S2 — request encode parity: encodeRequest + buildReadPayload
    /// reproduce vf-req-read.bin exactly (the guest's encoder locks the
    /// same bytes).
    func testS2RequestEncodeParity() throws {
        let expected = try fixture("vf-req-read.bin")
        let payload = try XCTUnwrap(VFWire.buildReadPayload(path: "fixture.bin", offset: 0))
        let encoded = try XCTUnwrap(VFWire.encodeRequest(op: VFWire.opRead, flags: 0, payload: payload))
        XCTAssertEqual(encoded, expected)
        XCTAssertEqual(expected.count, VFWire.requestHdrLen + "fixture.bin".utf8.count + VFWire.readOffsetLen)
    }

    /// S3 — reply decode parity: the checked-in replies decode to the
    /// pinned fields; hostile dlen clamps, never OOB.
    func testS3ReplyDecodeParity() throws {
        let read = try fixture("vf-reply-read.bin")
        let rep = VFWire.decodeReply(read)
        XCTAssertEqual(rep.status, VFWire.stOk)
        XCTAssertEqual(rep.dlen, 5)
        XCTAssertEqual(rep.data, Array("hello".utf8))
        XCTAssertFalse(rep.clamped)

        let list = try fixture("vf-reply-list.bin")
        let lrep = VFWire.decodeReply(list)
        XCTAssertEqual(lrep.status, VFWire.stOk)
        XCTAssertEqual(lrep.dlen, 80)
        XCTAssertEqual(lrep.data.count, 2 * VFWire.entryRowLen)

        // Hostile envelope: dlen 0xffff into a 64-byte buffer clamps.
        var hostile = [UInt8](repeating: 0x42, count: 64)
        hostile[0] = VFWire.stOk
        hostile[1] = 0xff
        hostile[2] = 0xff
        let hrep = VFWire.decodeReply(hostile)
        XCTAssertEqual(hrep.dlen, 0xffff)
        XCTAssertTrue(hrep.clamped)
        XCTAssertEqual(hrep.data.count, 64 - VFWire.replyHdrLen)
        // A sub-header buffer decodes honestly as host_error.
        let tiny = VFWire.decodeReply([0x00])
        XCTAssertEqual(tiny.status, VFWire.stHostError)
        XCTAssertEqual(tiny.data.count, 0)
    }

    /// S4 — path-defense policy: in-root paths resolve; `..`, absolute
    /// paths, and symlink escapes are refused.
    func testS4PathDefense() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // In-root paths resolve (root itself is the empty path).
        XCTAssertNotNil(VFWire.resolveSubpath(root: root, path: ""))
        let ok = try XCTUnwrap(VFWire.resolveSubpath(root: root, path: "a/b/c.txt"))
        XCTAssertEqual(ok.lastPathComponent, "c.txt")

        // Refused: absolute, .. traversal, backslash smuggling.
        XCTAssertNil(VFWire.resolveSubpath(root: root, path: "/etc/passwd"))
        XCTAssertNil(VFWire.resolveSubpath(root: root, path: "../escape"))
        XCTAssertNil(VFWire.resolveSubpath(root: root, path: "a/../../escape"))
        XCTAssertNil(VFWire.resolveSubpath(root: root, path: "a\\..\\escape"))

        // Symlink escape: a link inside the root pointing outside.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("evil")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(VFWire.resolveSubpath(root: root, path: "evil"))
    }

    /// Cross-check: the RFC-1071 checksum the guest prints for the probe
    /// reply is stable (the gate greps the guest's `cksum=0x…` against the
    /// same computation over the fixture).
    func testProbeChecksumStable() throws {
        let fixture = try fixture("vf-pattern-32k.bin")
        let cksum = VFWire.checksum1071(fixture)
        XCTAssertEqual(cksum, VFWire.checksum1071((0..<32768).map { VFWire.pattern($0) }))
        print("VF-CKSUM-32K: 0x\(String(format: "%04x", cksum))")
    }

    // ------------------------------------------------------------------
    // S5–S10 — HF3 (issue #737): mutation wire parity + the 8-slot
    // FileHandleTable cursor semantics (VZ-free, runs anywhere). Mirrors
    // the guest Zig tests G7–G12 byte-for-byte.
    // ------------------------------------------------------------------

    /// S5 — HF3 op/status constants, 8-handle parity, chunk math.
    func testS5Hf3ConstantsParity() {
        XCTAssertEqual(VFWire.opOpen, 0x04)
        XCTAssertEqual(VFWire.opClose, 0x05)
        XCTAssertEqual(VFWire.opWrite, 0x06)
        XCTAssertEqual(VFWire.opTruncate, 0x07)
        XCTAssertEqual(VFWire.opFsync, 0x08)
        XCTAssertEqual(VFWire.opRename, 0x09)
        XCTAssertEqual(VFWire.opMkdir, 0x0a)
        XCTAssertEqual(VFWire.opDelete, 0x0b)
        XCTAssertEqual(VFWire.stExists, 5)
        XCTAssertEqual(VFWire.stHandle, 6)
        // Parity with the kernel's file_table.zig (8 handles).
        XCTAssertEqual(VFWire.maxFileHandles, 8)
        // 32763 data bytes/WRITE round trip.
        XCTAssertEqual(VFWire.writeChunkMax, 32763)
    }

    /// S6 — write/truncate payload builders + handle parse + reply
    /// encoders (little-endian, mirroring the guest).
    func testS6PayloadBuildersAndReplyEncoders() {
        let wp = try! XCTUnwrap(VFWire.buildWritePayload(handle: 0x1122, data: Array("xyz".utf8)))
        XCTAssertEqual(wp, [0x22, 0x11, 0x78, 0x79, 0x7a])
        XCTAssertEqual(VFWire.handle(fromPayload: wp), 0x1122)
        // Over-chunk write refused honestly.
        XCTAssertNil(VFWire.buildWritePayload(handle: 0, data: [UInt8](repeating: 0, count: VFWire.writeChunkMax + 1)))

        let tp = VFWire.buildTruncatePayload(handle: 7, size: 1234)
        XCTAssertEqual(VFWire.handle(fromPayload: tp), 7)
        var size: UInt64 = 0
        for i in 0..<8 { size |= UInt64(tp[2 + i]) << (8 * i) }
        XCTAssertEqual(size, 1234)

        // OPEN reply [handle u16le] and WRITE reply [written u64le].
        XCTAssertEqual(VFWire.encodeOpenReply(handle: 4660), [0x34, 0x12])
        let wr = VFWire.encodeWrittenReply(written: 100000)
        var written: UInt64 = 0
        for i in 0..<8 { written |= UInt64(wr[i]) << (8 * i) }
        XCTAssertEqual(written, 100000)
    }

    /// S7 — rename NUL framing + bounds.
    func testS7RenameFraming() {
        let rp = try! XCTUnwrap(VFWire.buildRenamePayload(from: "sub/old.bin", to: "sub/new.bin"))
        let nul = rp.firstIndex(of: 0)!
        XCTAssertEqual(String(bytes: rp[0..<nul], encoding: .utf8), "sub/old.bin")
        XCTAssertEqual(String(bytes: rp[(nul + 1)...], encoding: .utf8), "sub/new.bin")
        XCTAssertNil(VFWire.buildRenamePayload(from: "", to: "x"))
    }

    /// S11 — HF7 (issue #741): CLONE op constant (additive 0x0c, past
    /// the HF3 delete) + the NUL-framed payload that mirrors RENAME.
    /// Mirrors the guest G13 byte-for-byte.
    func testS11CloneOpAndFraming() {
        XCTAssertEqual(VFWire.opClone, 0x0c)
        XCTAssertGreaterThan(VFWire.opClone, VFWire.opDelete)
        let cp = try! XCTUnwrap(VFWire.buildClonePayload(from: "repo", to: "repo-wt1"))
        let nul = cp.firstIndex(of: 0)!
        XCTAssertEqual(String(bytes: cp[0..<nul], encoding: .utf8), "repo")
        XCTAssertEqual(String(bytes: cp[(nul + 1)...], encoding: .utf8), "repo-wt1")
        // Refused honestly: empty, over-long, NUL-smuggling paths.
        XCTAssertNil(VFWire.buildClonePayload(from: "", to: "x"))
        XCTAssertNil(VFWire.buildClonePayload(from: "x", to: ""))
        XCTAssertNil(VFWire.buildClonePayload(from: String(repeating: "a", count: VFWire.pathMax + 1), to: "x"))
        XCTAssertNil(VFWire.buildClonePayload(from: "a\u{0}b", to: "x"))
    }

    /// S8 — the 8-slot table: cursor advance + truncate clamp.
    func testS8HandleTableCursorAndTruncate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vf-hf3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cur.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let table = FileHandleTable()
        let fh = try FileHandle(forUpdating: url)
        let (h, st) = table.open(path: "cur.bin", fh: fh, append: false)
        XCTAssertEqual(st, VFWire.stOk)
        XCTAssertEqual(h, 0)

        let (w1, ws1) = table.write(h, data: Array("hello".utf8))
        XCTAssertEqual(ws1, VFWire.stOk)
        XCTAssertEqual(w1, 5)
        // Second write lands AFTER the first (cursor advanced):
        let (w2, _) = table.write(h, data: Array("world".utf8))
        XCTAssertEqual(w2, 5)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "helloworld")

        // Read-modify-write truncate: shrink to 5 clamps the cursor.
        XCTAssertEqual(table.truncate(h, size: 5), VFWire.stOk)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello")
        XCTAssertEqual(table.close(h), VFWire.stOk)
    }

    /// S9 — append handles write at EOF regardless of cursor.
    func testS9HandleTableAppend() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vf-hf3a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app.bin")
        try Data("base".utf8).write(to: url)

        let table = FileHandleTable()
        let fh = try FileHandle(forUpdating: url)
        let (h, st) = table.open(path: "app.bin", fh: fh, append: true)
        XCTAssertEqual(st, VFWire.stOk)
        let (w, _) = table.write(h, data: Array("-more".utf8))
        XCTAssertEqual(w, 5)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "base-more")
        _ = table.close(h)
    }

    // ------------------------------------------------------------------
    // M70a (#1453) — the host half of the fuzz fleet. Seeded mutation over
    // the pinned fixtures plus property checks on the pure builders and the
    // path defense. Deterministic by construction (an explicit-seed
    // SplitMix64 — no Date, no SystemRandomNumberGenerator), so a failure
    // reproduces from "seed + iteration" alone, exactly like the guest-side
    // corpus in kernel/tests/fuzz_test.zig.
    // ------------------------------------------------------------------

    private struct Fuzz {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
        mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next() >> 33) }
    }

    private static let fuzzSeeds: [UInt64] = [
        0x5eed_0001, 0x1337_2026, 0xdead_beef_cafe, 0x0f0f_1234_5678,
    ]

    /// F1 — a reply frame may never decode out of bounds, over-report its
    /// length, or lie about clamping, whatever the mutation did to it.
    func testFuzz12ReplyDecodeFailsClosedOverFixtureMutations() throws {
        let corpus = [try fixture("vf-reply-read.bin"), try fixture("vf-reply-list.bin")]
        var decoded = 0
        for seed in Self.fuzzSeeds {
            var fuzz = Fuzz(seed: seed)
            for original in corpus {
                for iteration in 0..<64 {
                    var buf = original
                    var len = buf.count
                    switch iteration % 4 {
                    case 0: // byte flips
                        for _ in 0..<(1 + fuzz.below(3)) { buf[fuzz.below(buf.count)] = fuzz.byte() }
                    case 1: // truncation anywhere, including inside the header
                        len = fuzz.below(buf.count + 1)
                    case 2: // extension with bytes past the declared length
                        for _ in 0..<(1 + fuzz.below(8)) { buf.append(fuzz.byte()) }
                        len = buf.count
                    default: // a hostile declared length on an intact frame
                        if buf.count >= VFWire.replyHdrLen {
                            buf[1] = fuzz.byte()
                            buf[2] = fuzz.byte()
                        }
                    }
                    let input = Array(buf[0..<len])
                    let rep = VFWire.decodeReply(input)
                    decoded += 1
                    let where_ = "seed 0x\(String(seed, radix: 16)) iteration \(iteration)"
                    if input.count < VFWire.replyHdrLen {
                        XCTAssertEqual(rep.status, VFWire.stHostError, where_)
                        XCTAssertEqual(rep.dlen, 0, where_)
                        XCTAssertTrue(rep.data.isEmpty, where_)
                        XCTAssertTrue(rep.clamped, where_)
                        continue
                    }
                    let declared = UInt16(input[1]) | (UInt16(input[2]) << 8)
                    let avail = input.count - VFWire.replyHdrLen
                    let take = min(Int(declared), avail)
                    XCTAssertEqual(rep.status, input[0], where_)
                    XCTAssertEqual(rep.dlen, declared, where_)
                    XCTAssertEqual(rep.data.count, take, where_)
                    XCTAssertEqual(rep.clamped, take < Int(declared), where_)
                    XCTAssertEqual(rep.data, Array(input[VFWire.replyHdrLen..<(VFWire.replyHdrLen + take)]), where_)
                }
            }
        }
        XCTAssertEqual(decoded, Self.fuzzSeeds.count * corpus.count * 64)
    }

    /// F2 — the path defense is the host's only trust boundary for a guest
    /// path: every path it ACCEPTS must land inside the share root, and the
    /// shapes it refuses stay refused.
    func testFuzz13ResolveSubpathConfinesEveryAcceptedPathUnderRoot() throws {
        // Deterministic root on purpose: F2's failure messages quote the
        // resolved path, so a UUID root would make a red log unreplayable
        // verbatim. The name is per-suite-fixed, and XCTest runs these in one
        // process serially, so there is nothing to collide with; a stale copy
        // from an interrupted run is removed first.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf-fuzz-share-root", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = root.resolvingSymlinksInPath().path

        var accepted = 0
        var refused = 0
        for seed in Self.fuzzSeeds {
            var fuzz = Fuzz(seed: seed)
            for iteration in 0..<512 {
                var path = ""
                for _ in 0..<fuzz.below(48) {
                    switch fuzz.below(8) {
                    case 0: path += "/"
                    case 1: path += "."
                    case 2: path += ".."
                    case 3: path += "\\"
                    case 4: path += "a"
                    case 5: path += "b"
                    case 6: path += " "
                    default: path += "z"
                    }
                }
                guard let resolved = VFWire.resolveSubpath(root: root, path: path) else {
                    refused += 1
                    continue
                }
                accepted += 1
                let landed = resolved.resolvingSymlinksInPath().path
                let where_ = "seed 0x\(String(seed, radix: 16)) iteration \(iteration)"
                XCTAssertTrue(
                    landed == canonicalRoot || landed.hasPrefix(canonicalRoot + "/"),
                    "\(where_): accepted path escaped the share root: \"\(path)\" -> \(landed)"
                )
                XCTAssertFalse(path.hasPrefix("/"), "\(where_): absolute path accepted: \"\(path)\"")
            }
        }
        XCTAssertGreaterThan(accepted, 0, "the corpus must exercise accepted paths too")
        XCTAssertGreaterThan(refused, 0, "the corpus must exercise refused paths too")

        // The named refusals stay refused (the pre-existing S4 set, re-pinned
        // against the fuzz corpus's alphabet).
        for hostile in ["/etc/passwd", "../escape", "a/../../escape", "a\\..\\escape", "..", "./.."] {
            XCTAssertNil(VFWire.resolveSubpath(root: root, path: hostile), "accepted \"\(hostile)\"")
        }
    }

    /// F3 — the pure builders and decoders refuse ambiguous input: the NUL
    /// frame separator (found here: RENAME did not check it while CLONE did),
    /// the u16 request length field, short handles, and long entry names.
    func testFuzz14BuildersAndDecodersRefuseAmbiguousInput() throws {
        // NUL smuggling must be refused by BOTH NUL-framed builders.
        XCTAssertNil(VFWire.buildRenamePayload(from: "a\u{0}b", to: "x"))
        XCTAssertNil(VFWire.buildRenamePayload(from: "x", to: "a\u{0}b"))
        XCTAssertNil(VFWire.buildClonePayload(from: "a\u{0}b", to: "x"))
        XCTAssertNil(VFWire.buildClonePayload(from: "x", to: "a\u{0}b"))
        // Empty and over-long halves on both.
        let long = String(repeating: "a", count: VFWire.pathMax + 1)
        XCTAssertNil(VFWire.buildRenamePayload(from: "", to: "x"))
        XCTAssertNil(VFWire.buildRenamePayload(from: "x", to: ""))
        XCTAssertNil(VFWire.buildRenamePayload(from: long, to: "x"))
        XCTAssertNil(VFWire.buildRenamePayload(from: "x", to: long))
        XCTAssertNil(VFWire.buildClonePayload(from: long, to: "x"))
        XCTAssertNil(VFWire.buildClonePayload(from: "x", to: long))

        // encodeRequest: exact little-endian header, refusal only past u16.
        var fuzz = Fuzz(seed: Self.fuzzSeeds[3])
        for _ in 0..<256 {
            let n = fuzz.below(VFWire.replyCap)
            var payload = [UInt8]()
            payload.reserveCapacity(n)
            for _ in 0..<n { payload.append(fuzz.byte()) }
            let enc = try XCTUnwrap(VFWire.encodeRequest(op: VFWire.opRead, flags: 0, payload: payload))
            XCTAssertEqual(enc.count, VFWire.requestHdrLen + n)
            XCTAssertEqual(enc[0], VFWire.opRead)
            XCTAssertEqual(enc[1], 0)
            XCTAssertEqual(Int(enc[2]) | (Int(enc[3]) << 8), n)
            XCTAssertEqual(Array(enc[VFWire.requestHdrLen...]), payload)
        }
        XCTAssertNil(VFWire.encodeRequest(op: VFWire.opRead, flags: 0,
                                          payload: [UInt8](repeating: 0, count: 0x10000)))

        // Short-buffer parses must refuse, never trap: a u16 handle needs
        // `handleLen` bytes from the offset it is read at, no more no less.
        for n in 0..<VFWire.handleLen {
            XCTAssertNil(VFWire.handle(fromPayload: [UInt8](repeating: 0, count: n)),
                         "a \(n)-byte payload holds no handle")
        }
        let threeByte: [UInt8] = [0x01, 0x02, 0x03]
        XCTAssertEqual(VFWire.handle(fromPayload: threeByte), 0x0201)
        XCTAssertEqual(VFWire.handle(fromPayload: threeByte, at: 1), 0x0302)
        XCTAssertNil(VFWire.handle(fromPayload: threeByte, at: 2))
        XCTAssertNil(VFWire.handle(fromPayload: threeByte, at: 3))

        // decodeReply over EVERY prefix of a real reply: sub-header prefixes
        // are honest host errors, the rest clamp without over-reading.
        let read = try fixture("vf-reply-read.bin")
        for n in 0..<read.count {
            let rep = VFWire.decodeReply(Array(read[0..<n]))
            if n < VFWire.replyHdrLen {
                XCTAssertEqual(rep.status, VFWire.stHostError)
                XCTAssertTrue(rep.data.isEmpty)
                XCTAssertTrue(rep.clamped)
            } else {
                XCTAssertLessThanOrEqual(rep.data.count, n - VFWire.replyHdrLen)
            }
        }

        // encodeEntryRow truncates a long name to the 31-byte row field.
        let row = VFWire.encodeEntryRow(VFWire.DirEntry(
            name: String(repeating: "x", count: 64),
            type: VFWire.dirTypeFile,
            size: 9
        ))
        XCTAssertEqual(row.count, VFWire.entryRowLen)
        XCTAssertEqual(Array(row[0..<31]), Array(repeating: UInt8(ascii: "x"), count: 31))
        XCTAssertEqual(row[31], VFWire.dirTypeFile)
        XCTAssertEqual(Int(row[32]), 9)
    }

    /// S10 — 8-slot cap (parity with the kernel ABI): the ninth open is
    /// refused with stHandle; closing frees a slot.
    func testS10HandleTableCap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vf-hf3c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let table = FileHandleTable()
        var handles: [Int] = []
        for i in 0..<VFWire.maxFileHandles {
            let url = dir.appendingPathComponent("f\(i).bin")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let fh = try FileHandle(forUpdating: url)
            let (h, st) = table.open(path: "f\(i).bin", fh: fh, append: false)
            XCTAssertEqual(st, VFWire.stOk)
            handles.append(h)
        }
        // Ninth open → stHandle (table full).
        let extraURL = dir.appendingPathComponent("extra.bin")
        FileManager.default.createFile(atPath: extraURL.path, contents: nil)
        let extraFh = try FileHandle(forUpdating: extraURL)
        let (_, stFull) = table.open(path: "extra.bin", fh: extraFh, append: false)
        XCTAssertEqual(stFull, VFWire.stHandle)
        try? extraFh.close()

        // Close frees a slot: the retry succeeds.
        XCTAssertEqual(table.close(handles[0]), VFWire.stOk)
        let retryFh = try FileHandle(forUpdating: extraURL)
        let (h2, st2) = table.open(path: "extra.bin", fh: retryFh, append: false)
        XCTAssertEqual(st2, VFWire.stOk)
        XCTAssertEqual(h2, handles[0], "freed slot must be reused")
        _ = table.close(h2)
    }

    /// M134a — STAT encoding carries mtime_sec/mtime_nsec in the 21-byte
    /// shape and round-trips through the decoder.
    func testStatEncodeWithMtime() {
        let d = VFWire.encodeStatData(size: 7, isDir: false, mtimeSec: 1_700_000_123, mtimeNsec: 987_654_321, includeMtime: true)
        XCTAssertEqual(d.count, VFWire.statDataLen)
        let dec = VFWire.decodeStatData(d)
        XCTAssertEqual(dec?.size, 7)
        XCTAssertEqual(dec?.isDir, false)
        XCTAssertEqual(dec?.mtimeSec, 1_700_000_123)
        XCTAssertEqual(dec?.mtimeNsec, 987_654_321)
    }

    /// M134a — the old-shape encoding stays 9 bytes and an old peer's
    /// decoder sees mtime absent (named), not fabricated.
    func testStatEncodeWithoutMtimeOldPeerDecode() {
        let d = VFWire.encodeStatData(size: 4096, isDir: true, mtimeSec: 0, mtimeNsec: 0, includeMtime: false)
        XCTAssertEqual(d.count, VFWire.statBaseDataLen)
        let dec = VFWire.decodeStatData(d)
        XCTAssertEqual(dec?.size, 4096)
        XCTAssertEqual(dec?.isDir, true)
        XCTAssertNil(dec?.mtimeSec)
        XCTAssertNil(dec?.mtimeNsec)
        // A mid-length reply (neither shape) still yields size/type with
        // mtime absent — the same tolerance the guest decoder has.
        let mid = VFWire.decodeStatData(Array(d[0..<9]) + [1, 2, 3])
        XCTAssertEqual(mid?.size, 4096)
        XCTAssertNil(mid?.mtimeSec)
        // Shorter than the base record decodes to nil.
        XCTAssertNil(VFWire.decodeStatData([1, 2, 3]))
    }
}
