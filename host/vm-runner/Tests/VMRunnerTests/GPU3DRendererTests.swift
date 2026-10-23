// GPU3DRendererTests.swift — M102c2 (issue #2165): contract tests for
// the fixed-subset VirGL decoder and the real Metal renderer.
//
//   * The decoder is checked against INDEPENDENT field tables derived
//     from c1's committed fixtures (triangle.words + the two TGSI
//     texts) — the same wire contract, written down twice.
//   * The renderer is checked against real Metal pixels at 256x192 —
//     a solid triangle interior, a distinct clear outside, pinned
//     orientation/stride and opaque alpha. The Metal device identity
//     is printed for the evidence comment; no device is the named
//     blocker, never a mock-green.
//   * Fences: a deferred submit's element is returned ONLY after the
//     Metal completion handler ran; delayed/wrong-fence/stall modes
//     are deterministic knobs on the injected backend.
//   * Revert-fails seams exercised by the owner: disabling draw
//     encoding turns the interior-pixel assertion red while the
//     clear-only control stays green; consumption-as-completion turns
//     the delayed-backend ordering assertion red.
import XCTest
import Metal
@testable import VMGPU3D

final class GPU3DRendererTests: XCTestCase {

    // MARK: - Fixture loading (repo-relative, discovered from #filePath)

    private func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let probe = dir.appendingPathComponent("test/fixtures/gpu3d/triangle.words")
            if FileManager.default.fileExists(atPath: probe.path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("could not locate repo root from #filePath")
        return dir
    }

    private func fixtureText(_ name: String) -> String {
        let url = repoRoot().appendingPathComponent("test/fixtures/gpu3d/\(name)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("missing fixture \(name)")
            return ""
        }
        return text
    }

    /// Parse triangle.words: one `0x%08x` word per line, serialized
    /// little-endian into the stream byte array.
    private func fixtureStream() -> [UInt8] {
        var bytes: [UInt8] = []
        for token in fixtureText("triangle.words").split(whereSeparator: \.isWhitespace) {
            guard token.hasPrefix("0x"), let w = UInt32(token.dropFirst(2), radix: 16) else {
                XCTFail("bad fixture token \(token)"); return []
            }
            bytes.append(UInt8(w & 0xff))
            bytes.append(UInt8((w >> 8) & 0xff))
            bytes.append(UInt8((w >> 16) & 0xff))
            bytes.append(UInt8((w >> 24) & 0xff))
        }
        return bytes
    }

    // MARK: - Queue-element seam fakes (mirrors GPU3DDeviceTests)

    final class FakeElement: GPU3DQueueElement {
        let request: [UInt8]
        let writeCapacity: Int
        private(set) var written: [UInt8] = []
        private(set) var returned = false
        init(_ request: [UInt8], writeCapacity: Int = 8192) {
            self.request = request; self.writeCapacity = writeCapacity
        }
        var gpu3dReadByteCount: Int { request.count }
        var gpu3dWriteByteCount: Int { writeCapacity }
        func gpu3dReadAll() -> [UInt8] { request }
        func gpu3dWrite(_ bytes: [UInt8]) -> Bool {
            guard bytes.count <= writeCapacity - written.count else { return false }
            written.append(contentsOf: bytes); return true
        }
        func gpu3dReturn() { returned = true }
    }

    final class FakeQueue: GPU3DQueue {
        var elements: [FakeElement]
        init(_ elements: [FakeElement]) { self.elements = elements }
        var gpu3dQueueIndex: Int { 0 }
        func gpu3dNextElement() -> GPU3DQueueElement? {
            elements.isEmpty ? nil : elements.removeFirst()
        }
    }

    /// Flat guest RAM: backing GPAs index directly into `mem`.
    final class FlatMemory: GPU3DMemory {
        var mem: [UInt8]
        init(bytes: Int) { mem = [UInt8](repeating: 0, count: bytes) }
        func gpu3dRead(_ address: UInt64, count: Int) -> [UInt8]? {
            let a = Int(address)
            guard a >= 0, a + count <= mem.count else { return nil }
            return Array(mem[a..<(a + count)])
        }
        func gpu3dWrite(_ address: UInt64, bytes: [UInt8]) -> Bool {
            let a = Int(address)
            guard a >= 0, a + bytes.count <= mem.count else { return false }
            mem.replaceSubrange(a..<(a + bytes.count), with: bytes)
            return true
        }
    }

    // MARK: - Request builders (b2 envelope numbering)

    private func header(_ type: UInt32, ctx: UInt32, fence: UInt64 = 0,
                        fenced: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        for i in 0..<4 { out.append(UInt8((type >> (8 * i)) & 0xff)) }
        let flags: UInt32 = fenced ? GPU3DWire.flagFence : 0
        for i in 0..<4 { out.append(UInt8((flags >> (8 * i)) & 0xff)) }
        for i in 0..<8 { out.append(UInt8((fence >> (8 * i)) & 0xff)) }
        for i in 0..<4 { out.append(UInt8((ctx >> (8 * i)) & 0xff)) }
        out += [0, 0, 0, 0]
        return out
    }

    private func push32(_ v: UInt32, into out: inout [UInt8]) {
        for i in 0..<4 { out.append(UInt8((v >> (8 * i)) & 0xff)) }
    }
    private func push64(_ v: UInt64, into out: inout [UInt8]) {
        for i in 0..<8 { out.append(UInt8((v >> (8 * i)) & 0xff)) }
    }

    private func ctxCreateReq(_ ctx: UInt32) -> [UInt8] {
        var r = header(GPU3DWire.cmdCtxCreate, ctx: ctx)
        let name = Array("ctx".utf8)
        push32(UInt32(name.count), into: &r)
        push32(0, into: &r)
        r += name + [UInt8](repeating: 0, count: 64 - name.count)
        return r
    }

    private func ctxDestroyReq(_ ctx: UInt32) -> [UInt8] {
        header(GPU3DWire.cmdCtxDestroy, ctx: ctx)
    }

    private func create3DReq(ctx: UInt32, res: UInt32, target: UInt32,
                             format: UInt32, bind: UInt32,
                             w: UInt32, h: UInt32) -> [UInt8] {
        var r = header(GPU3DWire.cmdResourceCreate3D, ctx: ctx)
        for v in [res, target, format, bind, w, h, 1, 1, 0, 0, 0, 0] as [UInt32] {
            push32(v, into: &r)
        }
        return r
    }

    private func attachBackingReq(ctx: UInt32, res: UInt32, addr: UInt64,
                                  len: UInt32) -> [UInt8] {
        var r = header(GPU3DWire.cmdResourceAttachBacking, ctx: ctx)
        push32(res, into: &r)
        push32(1, into: &r)
        push64(addr, into: &r)
        push32(len, into: &r)
        push32(0, into: &r)
        return r
    }

    private func ctxResReq(_ cmd: UInt32, ctx: UInt32, res: UInt32) -> [UInt8] {
        var r = header(cmd, ctx: ctx)
        push32(res, into: &r)
        return r
    }

    private func transferReq(_ cmd: UInt32, ctx: UInt32, res: UInt32,
                             box: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
                             offset: UInt64 = 0, stride: UInt32 = 0,
                             layerStride: UInt32 = 0,
                             fence: UInt64 = 0x77) -> [UInt8] {
        var r = header(cmd, ctx: ctx, fence: fence, fenced: true)
        for v in [box.0, box.1, box.2, box.3, box.4, box.5] as [UInt32] {
            push32(v, into: &r)
        }
        push64(offset, into: &r)
        push32(res, into: &r)
        push32(0, into: &r) // level
        push32(stride, into: &r)
        push32(layerStride, into: &r)
        return r
    }

    private func submitReq(ctx: UInt32, stream: [UInt8],
                           fence: UInt64 = 0xF33D_0001) -> [UInt8] {
        var r = header(GPU3DWire.cmdSubmit3D, ctx: ctx, fence: fence, fenced: true)
        push32(UInt32(stream.count), into: &r)
        push32(0, into: &r)
        r += stream
        return r
    }

    private func drive(_ device: GPU3DDevice, _ elements: [FakeElement]) {
        device.handleQueueNotification(FakeQueue(elements))
    }

    private func responseType(_ el: FakeElement) -> UInt32 {
        guard el.written.count >= 4 else { return 0xffff_ffff }
        return UInt32(el.written[0]) | UInt32(el.written[1]) << 8
            | UInt32(el.written[2]) << 16 | UInt32(el.written[3]) << 24
    }

    // MARK: - Resource specs and bring-up

    private func colorSpec(res: UInt32 = 1, w: UInt32 = 256, h: UInt32 = 192)
        -> GPU3DWire.ResourceCreate {
        GPU3DWire.ResourceCreate(resourceID: res, target: 2, format: 1, bind: 2,
                                 width: w, height: h, depth: 1, arraySize: 1,
                                 lastLevel: 0, nrSamples: 0, flags: 0)
    }

    private func vboSpec(res: UInt32 = 2) -> GPU3DWire.ResourceCreate {
        GPU3DWire.ResourceCreate(resourceID: res, target: 0, format: 0, bind: 16,
                                 width: 96, height: 1, depth: 1, arraySize: 1,
                                 lastLevel: 0, nrSamples: 0, flags: 0)
    }

    private var specTable: [UInt32: GPU3DWire.ResourceCreate] {
        [1: colorSpec(), 2: vboSpec()]
    }

    /// Guest addresses for the color backing (256x192x4) and the vbo.
    private let colorGPA: UInt64 = 0x10_0000
    private let vboGPA: UInt64 = 0x20_0000

    /// ctx1 bring-up through the device: create, two resources,
    /// backings, attaches — the same order c1's open() drives.
    @discardableResult
    private func bringUp(_ device: GPU3DDevice, ctx: UInt32 = 1,
                         attachVBO: Bool = true) -> [FakeElement] {
        var els: [FakeElement] = [
            FakeElement(ctxCreateReq(ctx)),
            FakeElement(create3DReq(ctx: ctx, res: 1, target: 2, format: 1,
                                    bind: 2, w: 256, h: 192)),
            FakeElement(attachBackingReq(ctx: ctx, res: 1, addr: colorGPA,
                                         len: 256 * 192 * 4)),
            FakeElement(ctxResReq(GPU3DWire.cmdCtxAttachResource, ctx: ctx, res: 1)),
            FakeElement(create3DReq(ctx: ctx, res: 2, target: 0, format: 0,
                                    bind: 16, w: 96, h: 1)),
            FakeElement(attachBackingReq(ctx: ctx, res: 2, addr: vboGPA, len: 96)),
        ]
        if attachVBO {
            els.append(FakeElement(ctxResReq(GPU3DWire.cmdCtxAttachResource,
                                             ctx: ctx, res: 2)))
        }
        drive(device, els)
        for (i, el) in els.enumerated() {
            XCTAssertEqual(responseType(el), GPU3DWire.respOkNoData,
                           "bring-up step \(i) refused")
        }
        return els
    }

    /// The three 32-byte float4 vertices for the pixel proof:
    /// NDC (-1,-1),(1,-1),(-1,+1) -> pixels (0,0),(256,0),(0,192) —
    /// the half of the target above/left of the hypotenuse — all
    /// solid green (0,1,0,1).
    private func vertexUpload() -> [UInt8] {
        var out: [UInt8] = []
        func f(_ v: Float) { push32(v.bitPattern, into: &out) }
        for (x, y) in [(Float(-1), Float(-1)), (1, -1), (-1, 1)] {
            for v in [x, y, Float(0), Float(1)] { f(v) }          // position
            for v in [Float(0), Float(1), Float(0), Float(1)] { f(v) } // color
        }
        return out
    }

    /// Upload the vbo through the memory seam + transfer envelope.
    private func uploadVBO(_ device: GPU3DDevice, ctx: UInt32 = 1) {
        let el = FakeElement(transferReq(GPU3DWire.cmdTransferToHost3D, ctx: ctx,
                                         res: 2, box: (0, 0, 0, 96, 1, 1)))
        drive(device, [el])
        XCTAssertEqual(responseType(el), GPU3DWire.respOkNoData, "vbo upload refused")
    }

    /// Bounded spin until `cond` or ~5 s — the only place the suite
    /// waits on the GPU (deterministic modes never wait).
    private func waitUntil(_ cond: () -> Bool, _ what: String) {
        let deadline = Date().addingTimeInterval(5)
        while !cond() {
            XCTAssertLessThan(Date(), deadline, "timed out waiting for \(what)")
            if Date() > deadline { return }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private func makeRenderer(_ mem: FlatMemory,
                              file: StaticString = #filePath,
                              line: UInt = #line) -> GPU3DMetalRenderer? {
        guard let r = GPU3DMetalRenderer(memory: mem) else {
            XCTFail("no Metal device / pipeline on this host — the named c2 blocker",
                    file: file, line: line)
            return nil
        }
        return r
    }

    // MARK: - Independent fixture parse

    /// The decoder consumes c1's canonical stream against independent
    /// field tables: the (cmd,obj,len) sequence written down here, the
    /// embedded TGSI texts byte-compared to the on-disk fixtures, and
    /// the decoded frame plan (res ids, extent, clear, one draw).
    func testIndependentFixtureParse() {
        let stream = fixtureStream()
        XCTAssertEqual(stream.count, 660, "fixture must be 165 u32 words")

        // Independent command table: (opcode, object, payload words).
        let expected: [(UInt32, UInt32, Int)] = [
            (1, 8, 5),   // CREATE surface
            (1, 5, 9),   // CREATE vertex-elements
            (1, 1, 11),  // CREATE blend
            (1, 2, 9),   // CREATE rasterizer
            (1, 3, 5),   // CREATE dsa
            (1, 4, 32),  // CREATE vertex shader   (5 + 27 text dwords)
            (1, 4, 21),  // CREATE fragment shader (5 + 16 text dwords)
            (30, 0, 2),  // BIND_SHADER vertex
            (30, 0, 2),  // BIND_SHADER fragment
            (2, 1, 1),   // BIND blend
            (2, 2, 1),   // BIND rasterizer
            (2, 3, 1),   // BIND dsa
            (2, 5, 1),   // BIND vertex-elements
            (5, 0, 3),   // SET_FRAMEBUFFER_STATE (1 cbuf)
            (4, 0, 7),   // SET_VIEWPORT_STATE
            (6, 0, 3),   // SET_VERTEX_BUFFERS
            (7, 0, 8),   // CLEAR color0
            (8, 0, 12),  // DRAW_VBO triangles x3
            (3, 4, 1), (3, 4, 1), (3, 3, 1), (3, 2, 1),
            (3, 1, 1), (3, 5, 1), (3, 8, 1), // DESTROY, reverse order
        ]
        guard case .success(let commands) = VirglStreamDecoder.walk(stream) else {
            return XCTFail("fixture stream failed structural walk")
        }
        XCTAssertEqual(commands.count, expected.count)
        for (i, c) in commands.enumerated() where i < expected.count {
            XCTAssertEqual(c.cmd, expected[i].0, "cmd at index \(i)")
            XCTAssertEqual(c.obj, expected[i].1, "obj at index \(i)")
            XCTAssertEqual(c.payload.count / 4, expected[i].2, "len at index \(i)")
        }

        // The two embedded TGSI payloads must be byte-identical to the
        // on-disk .tgsi fixtures (complete text, NUL + pad on the wire).
        let vertexTGSI = Array(fixtureText("vertex.tgsi").utf8)
        let fragmentTGSI = Array(fixtureText("fragment.tgsi").utf8)
        XCTAssertEqual(vertexTGSI, Array(VirglStreamConst.vertexShaderText.utf8),
                       "decoder constant must match the committed fixture")
        XCTAssertEqual(fragmentTGSI, Array(VirglStreamConst.fragmentShaderText.utf8),
                       "decoder constant must match the committed fixture")
        for (cmdIndex, text) in [(5, vertexTGSI), (6, fragmentTGSI)] {
            let c = commands[cmdIndex]
            var carried: [UInt8] = []
            for off in stride(from: c.payload.lowerBound + 20,
                              to: c.payload.upperBound, by: 4) {
                for i in 0..<4 {
                    carried.append(stream[off + i])
                }
            }
            XCTAssertEqual(Array(carried[0..<text.count]), text,
                           "embedded TGSI text at command \(cmdIndex)")
            XCTAssertEqual(carried[text.count], 0, "NUL terminator")
            XCTAssertTrue(carried[(text.count + 1)...].allSatisfy { $0 == 0 })
        }

        switch VirglStreamDecoder.decode(stream, resources: specTable) {
        case .failure(let why):
            XCTFail("canonical fixture rejected: \(why)")
        case .success(let f):
            XCTAssertEqual(f.colorResourceID, 1)
            XCTAssertEqual(f.vertexResourceID, 2)
            XCTAssertEqual(f.width, 256)
            XCTAssertEqual(f.height, 192)
            XCTAssertEqual(f.clearColor, SIMD4<Float>(0, 0, 0, 1))
            XCTAssertTrue(f.drawsTriangle)
            XCTAssertEqual(f.commandCount, expected.count)
        }

        // NOP padding to exactly the 4,096-byte bound stays valid.
        var padded = stream
        padded += [UInt8](repeating: 0, count: 4096 - padded.count)
        guard case .success = VirglStreamDecoder.decode(padded, resources: specTable) else {
            return XCTFail("NOP-padded 4096-byte stream rejected")
        }
    }

    // MARK: - Malformed streams: zero draws, no prefix execution

    /// Mutations of the canonical stream must be rejected wholesale —
    /// decode yields no frame and the renderer encodes no Metal work.
    func testMutatedStreamsRejectWithZeroDraws() {
        let canonical = fixtureStream()

        func mutate(_ body: (inout [UInt8]) -> Void) -> [UInt8] {
            var s = canonical; body(&s); return s
        }
        // Independent checks on the decoder itself. Command offsets in
        // the canonical stream (words): draw at 138, first destroy at
        // 151, last destroy at 164; shader text begins at byte 200.
        let mutants: [(String, [UInt8])] = [
            ("payload-count", mutate { $0[2] = 6 }),        // surface len 5 -> 6
            ("handle", mutate { $0[4] = 9 }),               // surface handle 1 -> 9
            ("state-word", mutate { $0[128] ^= 0x40 }),     // rasterizer float word
            ("shader-text", mutate { $0[216] = UInt8(Character("X").asciiValue!) }),
            ("draw-opcode", mutate { $0[4 * 138] = 9 }),    // DRAW_VBO cmd -> 9
            ("object-kind", mutate { $0[25] = 7 }),         // velems create obj 5 -> 7
            ("obj-field-set", mutate { $0[4 * 138 + 1] = 1 }), // obj on DRAW_VBO
            ("midstream-NOP", {
                var s = canonical
                s.insert(contentsOf: [0, 0, 0, 0], at: 4 * 138)
                return s
            }()),
            ("leaked-object", {
                var s = canonical
                s.removeLast(8) // drop the last DESTROY entirely
                s += [0, 0, 0, 0, 0, 0, 0, 0]
                return s
            }()),
            ("second-draw", {
                var s = canonical
                s.insert(contentsOf: canonical[4 * 138..<(4 * 138 + 52)],
                         at: 4 * 151) // duplicate draw right after the first
                return s
            }()),
            ("truncated-tail", mutate { $0[4 * 164 + 2] = 2 }), // last len 1 -> 2
            ("malformed-tail", canonical + [0x77, 0x02, 0x00, 0x00]),
            ("misaligned", canonical + [0xaa]),
            ("over-cap", canonical + [UInt8](repeating: 0, count: 4096 - canonical.count + 4)),
        ]
        for (name, mutant) in mutants {
            switch VirglStreamDecoder.decode(mutant, resources: specTable) {
            case .success(let f):
                XCTFail("mutant \(name) decoded: \(f)")
            case .failure:
                break // every mutation is a named rejection
            }
        }

        // The same mutations through the renderer: no draws, no GPU
        // work, a named backend refusal.
        let mem = FlatMemory(bytes: 0x30_0000)
        guard let renderer = makeRenderer(mem) else { return }
        XCTAssertNil(renderer.gpu3dCreateContext(1, name: "t"))
        for (name, mutant) in mutants {
            let before = renderer.drawsEncoded
            let beforeGPU = renderer.gpuCompletions
            switch renderer.gpu3dSubmit(context: 1, stream: mutant) {
            case .failed:
                break
            default:
                XCTFail("mutant \(name) accepted by renderer")
            }
            XCTAssertEqual(renderer.drawsEncoded, before, "\(name) drew")
            XCTAssertEqual(renderer.gpuCompletions, beforeGPU, "\(name) hit the GPU")
        }
    }

    /// A stream that is a valid PREFIX plus one bad trailing command
    /// must execute nothing — the prefix never reaches the GPU.
    func testMalformedTailExecutesNoPrefix() {
        let mem = FlatMemory(bytes: 0x30_0000)
        guard let renderer = makeRenderer(mem) else { return }
        let device = GPU3DDevice(backend: renderer)
        renderer.device = device
        // Fill the vbo backing so the ONLY thing wrong is the tail.
        _ = bringUp(device)
        mem.mem.replaceSubrange(Int(vboGPA)..<(Int(vboGPA) + 96),
                                with: vertexUpload())
        uploadVBO(device)

        var s = fixtureStream()
        s += [0x77, 0x02, 0x00, 0x00] // bogus command appended
        let el = FakeElement(submitReq(ctx: 1, stream: s))
        drive(device, [el])
        XCTAssertTrue(el.returned)
        XCTAssertEqual(responseType(el), GPU3DWire.respErrUnspec)
        XCTAssertEqual(renderer.drawsEncoded, 0, "malformed tail ran the prefix")
        XCTAssertEqual(renderer.gpuCompletions, 0)
    }

    /// Skipping the vbo CTX_ATTACH makes the pinned stream refuse —
    /// no draw against an unattached buffer.
    func testUnattachedVertexBufferRefuses() {
        let mem = FlatMemory(bytes: 0x30_0000)
        guard let renderer = makeRenderer(mem) else { return }
        let device = GPU3DDevice(backend: renderer)
        renderer.device = device
        _ = bringUp(device, attachVBO: false)
        mem.mem.replaceSubrange(Int(vboGPA)..<(Int(vboGPA) + 96),
                                with: vertexUpload())
        uploadVBO(device)
        let el = FakeElement(submitReq(ctx: 1, stream: fixtureStream()))
        drive(device, [el])
        XCTAssertEqual(responseType(el), GPU3DWire.respErrUnspec)
        XCTAssertEqual(renderer.drawsEncoded, 0)
    }

    // MARK: - The coverage matrix (M185a, issue #3176)

    /// The battery's canonical builder must produce byte-identical
    /// output to c1's committed fixture — the matrix's accepted row is
    /// the SAME stream the guest emits, so this comparison keeps the
    /// in-module builder honest against the guest's real encoder.
    func testMatrixCanonicalIsTheFixture() {
        XCTAssertEqual(VirglCoverage.canonicalStream(), fixtureStream())
    }

    /// Every probe row's observed verdict IS the pinned one, and both
    /// field-space sweeps return exactly the profile's sets — the
    /// class-A half of the matrix pin (live-gpu3d's matrix leg asserts
    /// the same names on the runner's stdout class-B).
    func testMatrixProbesAllPinned() {
        var count = 0
        for r in VirglCoverage.run() {
            count += 1
            XCTAssertTrue(r.pinned,
                          "probe \(r.label) drifted: observed \(r.verdict)")
        }
        XCTAssertEqual(count, 24, "the battery covers every refusal row")
        XCTAssertEqual(VirglCoverage.cmdSweep(), [0, 1, 2, 3, 4, 5, 6, 7, 8, 30])
        XCTAssertEqual(VirglCoverage.objSweep(), [1, 2, 3, 4, 5, 8])
        // The report the runner prints at attach: no DRIFT line, the
        // pinned summary, and every row's named verdict present.
        let report = VirglCoverage.report()
        XCTAssertFalse(report.contains { $0.contains("DRIFT") },
                       "report shows drift: \(report.filter { $0.contains("DRIFT") })")
        XCTAssertTrue(report.contains("gpu3d-matrix: pinned 24/24 probes"))
        for name in ["canonical: accepted", "empty: refused:empty",
                     "unknown-cmd: refused:unknownCommand",
                     "unknown-obj: refused:unknownObject",
                     "bad-arity: refused:badArity",
                     "bad-field: refused:badField",
                     "bad-handle: refused:badHandle",
                     "dead-handle: refused:deadHandle",
                     "shader-handle-type: refused:shaderHandleType",
                     "shader-framing: refused:shaderFraming",
                     "shader-text: refused:shaderText",
                     "bad-reference: refused:badReference",
                     "object-field-set: refused:objectFieldSet",
                     "second-draw: refused:unmetPrecondition",
                     "leaked-object: refused:leakedObjects"] {
            XCTAssertTrue(report.contains("gpu3d-matrix: \(name)"),
                          "report missing row \(name)")
        }
    }

    // MARK: - Real Metal pixels

    /// The full happy path through the device + real Metal: upload,
    /// deferred submit, fence on GPU completion, BGRA8 readback.
    /// Asserts interior solid green, distinct clear outside,
    /// orientation/stride and opaque alpha — all on the host's actual
    /// Metal device (identity printed for the evidence comment).
    func testMetalTriangleReadback() throws {
        let mem = FlatMemory(bytes: 0x30_0000)
        guard let renderer = makeRenderer(mem) else { return }
        print("GPU3D Metal device: \(renderer.metalDeviceName)")
        let device = GPU3DDevice(backend: renderer)
        renderer.device = device
        _ = bringUp(device)
        mem.mem.replaceSubrange(Int(vboGPA)..<(Int(vboGPA) + 96),
                                with: vertexUpload())
        uploadVBO(device)

        let completions = renderer.gpuCompletions
        let sub = FakeElement(submitReq(ctx: 1, stream: fixtureStream()))
        drive(device, [sub])
        XCTAssertFalse(sub.returned, "deferred submit must hold the element")

        waitUntil({ renderer.gpuCompletions > completions }, "Metal completion")
        drive(device, []) // poll drains the completed fence
        XCTAssertTrue(sub.returned)
        XCTAssertEqual(responseType(sub), GPU3DWire.respOkNoData)
        XCTAssertEqual(renderer.drawsEncoded, 1)

        // BGRA8 readback ordered after the completed fence.
        let rb = FakeElement(transferReq(GPU3DWire.cmdTransferFromHost3D, ctx: 1,
                                         res: 1, box: (0, 0, 0, 256, 192, 1),
                                         stride: 256 * 4))
        drive(device, [rb])
        XCTAssertTrue(rb.returned)
        XCTAssertEqual(responseType(rb), GPU3DWire.respOkNoData)

        func px(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let i = Int(colorGPA) + (y * 256 + x) * 4
            return (mem.mem[i], mem.mem[i + 1], mem.mem[i + 2], mem.mem[i + 3])
        }
        // Interior (hypotenuse x + 4y/3 < 256): solid green, opaque.
        for (x, y) in [(4, 4), (8, 180), (64, 96), (200, 4)] {
            let p = px(x, y)
            XCTAssertEqual(p.g, 0xff, "interior (\(x),\(y)) green channel")
            XCTAssertEqual(p.r, 0x00); XCTAssertEqual(p.b, 0x00)
            XCTAssertEqual(p.a, 0xff, "interior (\(x),\(y)) alpha opaque")
        }
        // Exterior: the opaque-black clear.
        for (x, y) in [(240, 16), (192, 96), (250, 8), (8, 188)] {
            let p = px(x, y)
            XCTAssertEqual(p.r, 0x00, "exterior (\(x),\(y)) red")
            XCTAssertEqual(p.g, 0x00); XCTAssertEqual(p.b, 0x00)
            XCTAssertEqual(p.a, 0xff, "exterior (\(x),\(y)) alpha opaque")
        }
    }

    /// Clear-only control: a stream without the draw clears the whole
    /// target — the control that stays green when draw encoding is
    /// disabled in the revert-fails proof.
    func testClearOnlyFrame() throws {
        let mem = FlatMemory(bytes: 0x30_0000)
        guard let renderer = makeRenderer(mem) else { return }
        let device = GPU3DDevice(backend: renderer)
        renderer.device = device
        _ = bringUp(device)

        // Rebuild the canonical stream minus the DRAW_VBO command:
        // same sequence, just no geometry.
        var stream = fixtureStream()
        stream.removeSubrange(4 * 138..<(4 * 138 + 52))

        let completions = renderer.gpuCompletions
        let sub = FakeElement(submitReq(ctx: 1, stream: stream))
        drive(device, [sub])
        XCTAssertFalse(sub.returned)
        waitUntil({ renderer.gpuCompletions > completions }, "clear completion")
        drive(device, [])
        XCTAssertEqual(responseType(sub), GPU3DWire.respOkNoData)
        XCTAssertEqual(renderer.drawsEncoded, 0, "clear-only drew something")

        let rb = FakeElement(transferReq(GPU3DWire.cmdTransferFromHost3D, ctx: 1,
                                         res: 1, box: (0, 0, 0, 256, 192, 1),
                                         stride: 256 * 4))
        drive(device, [rb])
        XCTAssertEqual(responseType(rb), GPU3DWire.respOkNoData)
        for (x, y) in [(0, 0), (4, 4), (128, 96), (255, 191)] {
            let i = Int(colorGPA) + (y * 256 + x) * 4
            XCTAssertEqual(Array(mem.mem[i..<(i + 4)]), [0, 0, 0, 0xff],
                           "clear color at (\(x),\(y))")
        }
    }

    // MARK: - Fences, completion ordering, deterministic modes

    /// Delayed backend: the element is held until the fence is
    /// reported — and the fence is withheld until the Metal completion
    /// arrives AND is released. Under the revert (completion reported
    /// at queue consumption) the element returns instantly and the
    /// "still held" assertions go red.
    func testDelayedBackendFencesAfterCompletion() throws {
        let mem = FlatMemory(bytes: 0x30_0000)
        guard let renderer = makeRenderer(mem) else { return }
        renderer.withholdCompletion = true
        let device = GPU3DDevice(backend: renderer)
        renderer.device = device
        _ = bringUp(device)
        mem.mem.replaceSubrange(Int(vboGPA)..<(Int(vboGPA) + 96),
                                with: vertexUpload())
        uploadVBO(device)

        let sub = FakeElement(submitReq(ctx: 1, stream: fixtureStream()))
        drive(device, [sub])
        XCTAssertFalse(sub.returned,
                       "consumption-as-completion would return the element now")

        let completions = renderer.gpuCompletions
        waitUntil({ renderer.gpuCompletions > completions }, "Metal completion")
        drive(device, [])
        XCTAssertFalse(sub.returned,
                       "fence reported before the withheld completion released")

        renderer.releaseCompletion()
        drive(device, [])
        XCTAssertTrue(sub.returned)
        XCTAssertEqual(responseType(sub), GPU3DWire.respOkNoData)
    }

    /// Wrong-fence mode: a completed submission whose reported fence
    /// does not match stays held and is counted stale — the full u64
    /// match is what completes a request.
    func testWrongFenceNeverCompletes() throws {
        let mem = FlatMemory(bytes: 0x30_0000)
        guard let renderer = makeRenderer(mem) else { return }
        renderer.reportWrongFence = true
        let device = GPU3DDevice(backend: renderer)
        renderer.device = device
        _ = bringUp(device)
        mem.mem.replaceSubrange(Int(vboGPA)..<(Int(vboGPA) + 96),
                                with: vertexUpload())
        uploadVBO(device)

        let completions = renderer.gpuCompletions
        let sub = FakeElement(submitReq(ctx: 1, stream: fixtureStream(),
                                        fence: 0xABCD_1234))
        drive(device, [sub])
        waitUntil({ renderer.gpuCompletions > completions }, "Metal completion")
        drive(device, [])
        XCTAssertFalse(sub.returned, "a wrong fence must not complete the element")
        XCTAssertEqual(device.staleCompletions, 1)

        device.reset()
        XCTAssertTrue(sub.returned)
        XCTAssertEqual(responseType(sub), GPU3DWire.respErrUnspec)
    }

    /// Stall mode: completions never report; the held element waits
    /// until reset retires it with an honest error.
    func testStalledBackendNeverAcknowledges() throws {
        let mem = FlatMemory(bytes: 0x30_0000)
        guard let renderer = makeRenderer(mem) else { return }
        renderer.stallCompletion = true
        let device = GPU3DDevice(backend: renderer)
        renderer.device = device
        _ = bringUp(device)
        mem.mem.replaceSubrange(Int(vboGPA)..<(Int(vboGPA) + 96),
                                with: vertexUpload())
        uploadVBO(device)

        let sub = FakeElement(submitReq(ctx: 1, stream: fixtureStream()))
        drive(device, [sub])
        for _ in 0..<4 { drive(device, []) }
        XCTAssertFalse(sub.returned, "stalled completion must never ack")
        XCTAssertEqual(device.staleCompletions, 0)

        device.reset()
        XCTAssertTrue(sub.returned)
        XCTAssertEqual(responseType(sub), GPU3DWire.respErrUnspec)
        XCTAssertEqual(device.retiredPending, 1)
    }

    /// Reset while a submission is in flight: the held element gets an
    /// honest error, contexts drop, the late Metal completion lands
    /// nowhere and cannot acknowledge a recycled context generation.
    func testResetDuringInFlightIsSafe() throws {
        let mem = FlatMemory(bytes: 0x30_0000)
        guard let renderer = makeRenderer(mem) else { return }
        let device = GPU3DDevice(backend: renderer)
        renderer.device = device
        _ = bringUp(device)
        mem.mem.replaceSubrange(Int(vboGPA)..<(Int(vboGPA) + 96),
                                with: vertexUpload())
        uploadVBO(device)

        let completions = renderer.gpuCompletions
        let sub = FakeElement(submitReq(ctx: 1, stream: fixtureStream()))
        drive(device, [sub])
        XCTAssertFalse(sub.returned)

        device.reset()
        XCTAssertTrue(sub.returned)
        XCTAssertEqual(responseType(sub), GPU3DWire.respErrUnspec)
        XCTAssertTrue(device.liveContextIDs.isEmpty)

        // The late Metal completion must not touch freed state or a
        // recycled generation — it lands nowhere.
        waitUntil({ renderer.gpuCompletions > completions }, "late completion")
        drive(device, [])
        XCTAssertEqual(device.staleCompletions, 0,
                       "an orphaned fence must never be reported")

        // The recycled ctx gets a new generation; new work proceeds.
        let c = FakeElement(ctxCreateReq(1))
        drive(device, [c])
        XCTAssertEqual(responseType(c), GPU3DWire.respOkNoData)
        XCTAssertEqual(device.generation(of: 1), 2)
    }

    /// Destroy under an in-flight submission: the held element is
    /// retired with an error; the later completion is orphaned.
    func testDestroyDuringInFlightIsSafe() throws {
        let mem = FlatMemory(bytes: 0x30_0000)
        guard let renderer = makeRenderer(mem) else { return }
        let device = GPU3DDevice(backend: renderer)
        renderer.device = device
        _ = bringUp(device)
        mem.mem.replaceSubrange(Int(vboGPA)..<(Int(vboGPA) + 96),
                                with: vertexUpload())
        uploadVBO(device)

        let completions = renderer.gpuCompletions
        let sub = FakeElement(submitReq(ctx: 1, stream: fixtureStream()))
        drive(device, [sub])
        XCTAssertFalse(sub.returned)

        let d = FakeElement(ctxDestroyReq(1))
        drive(device, [d])
        XCTAssertEqual(responseType(d), GPU3DWire.respOkNoData)
        XCTAssertTrue(sub.returned)
        XCTAssertEqual(responseType(sub), GPU3DWire.respErrUnspec)

        // The late Metal completion arrives after the context died:
        // reported to nothing, counted orphaned, never acknowledged.
        waitUntil({ renderer.gpuCompletions > completions }, "late completion")
        drive(device, [])
        XCTAssertEqual(device.staleCompletions, 0)
        XCTAssertEqual(renderer.orphanedCompletions, 1)
    }

    /// Readback while a draw is still in flight refuses — pixels are
    /// only final after the matching fence.
    func testReadbackRefusedBeforeCompletion() throws {
        let mem = FlatMemory(bytes: 0x30_0000)
        guard let renderer = makeRenderer(mem) else { return }
        renderer.withholdCompletion = true
        let device = GPU3DDevice(backend: renderer)
        renderer.device = device
        _ = bringUp(device)
        mem.mem.replaceSubrange(Int(vboGPA)..<(Int(vboGPA) + 96),
                                with: vertexUpload())
        uploadVBO(device)

        let sub = FakeElement(submitReq(ctx: 1, stream: fixtureStream()))
        drive(device, [sub])

        // A readback arriving while the draw is pending refuses —
        // it may not sample unfinished pixels.
        let early = FakeElement(transferReq(GPU3DWire.cmdTransferFromHost3D, ctx: 1,
                                            res: 1, box: (0, 0, 0, 256, 192, 1),
                                            stride: 256 * 4))
        drive(device, [early])
        XCTAssertTrue(early.returned)
        XCTAssertEqual(responseType(early), GPU3DWire.respErrUnspec)
        XCTAssertEqual(device.lastRefusal, .backendRefused)

        let completions = renderer.gpuCompletions
        waitUntil({ renderer.gpuCompletions > completions }, "Metal completion")
        renderer.releaseCompletion()
        drive(device, [])
        XCTAssertTrue(sub.returned)

        let late = FakeElement(transferReq(GPU3DWire.cmdTransferFromHost3D, ctx: 1,
                                           res: 1, box: (0, 0, 0, 256, 192, 1),
                                           stride: 256 * 4))
        drive(device, [late])
        XCTAssertEqual(responseType(late), GPU3DWire.respOkNoData)
    }

    /// Without a Metal device the renderer is the honest null backend:
    /// failable init returns nil — the named blocker, not a mock.
    func testNoMetalDeviceIsBlockedNotFaked() {
        let mem = FlatMemory(bytes: 0x30_0000)
        XCTAssertNil(GPU3DMetalRenderer(memory: mem, device: nil))
    }

    // MARK: - M111b compute (#2409, ADR 0053)

    /// COMPUTE_SUBMIT: header + the frozen 64-byte kernel descriptor.
    private func computeReq(_ kd: GPU3DWire.KernelDesc, ctx: UInt32,
                            fence: UInt64 = 0xC0FF_EE00) -> [UInt8] {
        var r = header(GPU3DWire.cmdComputeSubmit, ctx: ctx, fence: fence, fenced: true)
        push32(kd.kernelID, into: &r)
        push32(kd.flags, into: &r)
        push32(kd.d0, into: &r)
        push32(kd.d1, into: &r)
        push32(kd.d2, into: &r)
        push32(kd.aux, into: &r)
        for b in kd.bufs {
            push32(b.buf, into: &r)
            push32(b.byteOff, into: &r)
        }
        push64(0, into: &r) // reserved
        return r
    }

    /// Bring up one ctx with `n` buffer resources (res 2..n+1) backed
    /// 4 KiB apart from `gpaBase`.
    private func computeBringUp(_ device: GPU3DDevice, ctx: UInt32,
                                buffers: Int, gpaBase: UInt64 = 0x10_0000) {
        var els: [FakeElement] = [FakeElement(ctxCreateReq(ctx))]
        for i in 0..<buffers {
            let res = UInt32(i + 2)
            els.append(FakeElement(create3DReq(ctx: ctx, res: res, target: 0,
                                               format: 0, bind: 0, w: 4096, h: 1)))
            els.append(FakeElement(attachBackingReq(ctx: ctx, res: res,
                                                    addr: gpaBase + UInt64(i) * 0x1000,
                                                    len: 4096)))
            els.append(FakeElement(ctxResReq(GPU3DWire.cmdCtxAttachResource,
                                             ctx: ctx, res: res)))
        }
        drive(device, els)
        for (i, el) in els.enumerated() {
            XCTAssertEqual(responseType(el), GPU3DWire.respOkNoData,
                           "compute bring-up step \(i) refused")
        }
    }

    private func f16bytes(_ vals: [Float16]) -> [UInt8] {
        var out: [UInt8] = []
        for v in vals {
            out.append(UInt8(v.bitPattern & 0xff))
            out.append(UInt8(v.bitPattern >> 8))
        }
        return out
    }

    /// The whole point of the card, at Metal level: upload A/B into
    /// target_buffer resources, fenced COMPUTE_SUBMIT(GEMM), poll→fence
    /// → element returned, and a TRANSFER_FROM_HOST readback holds the
    /// exact f16 product — submit → fence → readback.
    func testMetalComputeGemmRoundTrip() throws {
        let mem = FlatMemory(bytes: 0x40_0000)
        guard let renderer = makeRenderer(mem) else { return }
        XCTAssertTrue(renderer.gpu3dComputeReady, "compute pipelines must build")
        let device = GPU3DDevice(backend: renderer)
        renderer.device = device

        let ctx: UInt32 = 1
        computeBringUp(device, ctx: ctx, buffers: 3) // res 2,3,4 at 0x100000+

        // A = [[1,2],[3,4]], B = [[5,6],[7,8]] — f16 row-major.
        mem.mem.replaceSubrange(0x10_0000..<0x10_0008,
                                with: f16bytes([1, 2, 3, 4]))
        mem.mem.replaceSubrange(0x10_1000..<0x10_1008,
                                with: f16bytes([5, 6, 7, 8]))
        for res: UInt32 in [2, 3] {
            let up = FakeElement(transferReq(GPU3DWire.cmdTransferToHost3D,
                                             ctx: ctx, res: res,
                                             box: (0, 0, 0, 8, 1, 1)))
            drive(device, [up])
            XCTAssertEqual(responseType(up), GPU3DWire.respOkNoData,
                           "buffer upload res \(res)")
        }

        var kd = GPU3DWire.KernelDesc()
        kd.kernelID = GPU3DWire.kernelGEMM
        kd.d0 = 2; kd.d1 = 2; kd.d2 = 2
        kd.bufs = [.init(buf: 2), .init(buf: 3), .init(buf: 4), .init()]
        let sub = FakeElement(computeReq(kd, ctx: ctx, fence: 0xBEEF_0001))
        drive(device, [sub])
        XCTAssertFalse(sub.returned, "consumption is not completion")
        XCTAssertEqual(device.pendingFenceID, 0xBEEF_0001)

        let completions = renderer.gpuCompletions
        waitUntil({ renderer.gpuCompletions > completions }, "Metal compute completion")
        drive(device, [])
        XCTAssertTrue(sub.returned, "the real fence did not release the element")
        XCTAssertEqual(responseType(sub), GPU3DWire.respOkNoData)
        XCTAssertEqual(renderer.computeSubmits, 1)

        // Read C back through the buffer readback leg.
        let rb = FakeElement(transferReq(GPU3DWire.cmdTransferFromHost3D,
                                         ctx: ctx, res: 4,
                                         box: (0, 0, 0, 8, 1, 1)))
        drive(device, [rb])
        XCTAssertEqual(responseType(rb), GPU3DWire.respOkNoData)

        // C = A·B = [[19,22],[43,50]] — exact in f16.
        let want = f16bytes([19, 22, 43, 50])
        XCTAssertEqual(Array(mem.mem[0x10_2000..<0x10_2008]), want)
    }

    /// DEQUANT i8-symmetric at Metal level: out[i] = q[i] * s[i/G] in
    /// f16 — exercises a second pipeline and the absent-slot dummy.
    func testMetalComputeDequantI8() throws {
        let mem = FlatMemory(bytes: 0x40_0000)
        guard let renderer = makeRenderer(mem) else { return }
        let device = GPU3DDevice(backend: renderer)
        renderer.device = device
        let ctx: UInt32 = 1
        computeBringUp(device, ctx: ctx, buffers: 3) // res 2 packed, 3 scales, 4 out

        // q = [1,2,-1,-2,0,1,2,3] i8 in ONE group of 32 (the legal group
        // sizes are 32/64/128); scale s[0] = 2.0.
        let q: [UInt8] = [1, 2, 0xff, 0xfe, 0, 1, 2, 3]
        var scales: [UInt8] = []
        push32(Float(2.0).bitPattern, into: &scales)
        mem.mem.replaceSubrange(0x10_0000..<0x10_0008, with: q)
        mem.mem.replaceSubrange(0x10_1000..<0x10_1004, with: scales)
        for res: UInt32 in [2, 3] {
            let up = FakeElement(transferReq(GPU3DWire.cmdTransferToHost3D,
                                             ctx: ctx, res: res,
                                             box: (0, 0, 0, 8, 1, 1)))
            drive(device, [up])
            XCTAssertEqual(responseType(up), GPU3DWire.respOkNoData)
        }

        var kd = GPU3DWire.KernelDesc()
        kd.kernelID = GPU3DWire.kernelDequant
        kd.d0 = 8; kd.d1 = 32; kd.aux = GPU3DWire.dequantFmtI8Sym
        kd.bufs = [.init(buf: 2), .init(buf: 3), .init(), .init(buf: 4)]
        let sub = FakeElement(computeReq(kd, ctx: ctx, fence: 0xBEEF_0002))
        drive(device, [sub])
        let completions = renderer.gpuCompletions
        waitUntil({ renderer.gpuCompletions > completions }, "Metal compute completion")
        drive(device, [])
        XCTAssertTrue(sub.returned)
        XCTAssertEqual(responseType(sub), GPU3DWire.respOkNoData)

        let rb = FakeElement(transferReq(GPU3DWire.cmdTransferFromHost3D,
                                         ctx: ctx, res: 4,
                                         box: (0, 0, 0, 16, 1, 1)))
        drive(device, [rb])
        XCTAssertEqual(responseType(rb), GPU3DWire.respOkNoData)
        // out = q[i] * 2.0 = [2, 4, -2, -4, 0, 2, 4, 6] in f16.
        let want = f16bytes([2, 4, -2, -4, 0, 2, 4, 6])
        XCTAssertEqual(Array(mem.mem[0x10_2000..<0x10_2010]), want)
    }

    /// A buffer slot naming a resource of ANOTHER context is a named
    /// refusal — the context isolation the whole device contract rests
    /// on; Metal never sees it. res 5 exists ONLY on ctx 1: naming it
    /// from ctx 2 must refuse even though the resource id is real.
    func testComputeBindingCannotReachAcrossContexts() throws {
        let mem = FlatMemory(bytes: 0x40_0000)
        guard let renderer = makeRenderer(mem) else { return }
        let device = GPU3DDevice(backend: renderer)
        renderer.device = device
        computeBringUp(device, ctx: 1, buffers: 4, gpaBase: 0x10_0000) // ctx1 owns res 2..5
        computeBringUp(device, ctx: 2, buffers: 3, gpaBase: 0x20_0000) // ctx2 owns res 2..4

        var kd = GPU3DWire.KernelDesc()
        kd.kernelID = GPU3DWire.kernelGEMM
        kd.d0 = 2; kd.d1 = 2; kd.d2 = 2
        kd.bufs = [.init(buf: 2), .init(buf: 3), .init(buf: 4), .init()]
        // Same res ids, right ctx: ctx 2's own buffers complete the run.
        let fine = FakeElement(computeReq(kd, ctx: 2, fence: 0xBEEF_0003))
        drive(device, [fine])
        let completions = renderer.gpuCompletions
        waitUntil({ renderer.gpuCompletions > completions }, "Metal compute completion")
        drive(device, [])
        XCTAssertTrue(fine.returned)

        // res 5 is live under ctx 1 — naming it from ctx 2 is a named
        // binding refusal, not a resource the device would serve.
        var kdBad = GPU3DWire.KernelDesc()
        kdBad.kernelID = GPU3DWire.kernelSoftmax
        kdBad.d0 = 1; kdBad.d1 = 8
        kdBad.bufs = [.init(buf: 2), .init(buf: 5), .init(), .init()]
        let bad = FakeElement(computeReq(kdBad, ctx: 2, fence: 0xBEEF_0004))
        drive(device, [bad])
        XCTAssertEqual(device.lastRefusal, .badKernelBinding)
        XCTAssertEqual(responseType(bad), GPU3DWire.respErrInvalidResourceID)
    }
}
