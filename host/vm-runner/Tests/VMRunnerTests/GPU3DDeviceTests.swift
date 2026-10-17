// GPU3DDeviceTests.swift — M102b2 (issue #2163): the host envelope for
// the custom-Virtio 3D render device (ID 0x43 / PCI 1af4:1083). Every
// byte vector below is pinned literally — the SAME fields the b1 guest
// transport emits per the shared contract in #2160 — and every refusal
// is named. Runs with `swift test`: no VM, no Virtualization, no GPU.
import XCTest
@testable import VMGPU3D

final class GPU3DDeviceTests: XCTestCase {
    // MARK: - Queue-element seam fakes

    /// One dequeued descriptor chain: fixed request bytes, a capped write
    /// buffer, and a returned flag. Mirrors VZVirtioQueueElement's
    /// read-once/write-once contract.
    final class FakeElement: GPU3DQueueElement {
        let request: [UInt8]
        let writeCapacity: Int
        private(set) var written: [UInt8] = []
        private(set) var returned = false
        /// Fires inside gpu3dReturn — the pump test observes retirement
        /// from whatever queue completed the fence.
        var onReturn: (() -> Void)?

        init(_ request: [UInt8], writeCapacity: Int = 4096) {
            self.request = request
            self.writeCapacity = writeCapacity
        }

        var gpu3dReadByteCount: Int { request.count }
        var gpu3dWriteByteCount: Int { writeCapacity }
        func gpu3dReadAll() -> [UInt8] { request }
        func gpu3dWrite(_ bytes: [UInt8]) -> Bool {
            guard bytes.count <= writeCapacity - written.count else { return false }
            written.append(contentsOf: bytes)
            return true
        }
        func gpu3dReturn() { returned = true; onReturn?() }
    }

    final class FakeQueue: GPU3DQueue {
        var elements: [FakeElement]
        init(_ elements: [FakeElement]) { self.elements = elements }
        var gpu3dQueueIndex: Int { 0 }
        func gpu3dNextElement() -> GPU3DQueueElement? {
            elements.isEmpty ? nil : elements.removeFirst()
        }
    }

    // MARK: - Pinned request/response vectors

    /// GET_CAPSET_INFO index 0: type 0x0108 then all-zero fields.
    private let capsetInfoReq: [UInt8] = [
        0x08, 0x01, 0x00, 0x00, // type = GET_CAPSET_INFO
        0x00, 0x00, 0x00, 0x00, // flags
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // fence_id
        0x00, 0x00, 0x00, 0x00, // ctx_id
        0x00, 0x00, 0x00, 0x00, // ring_idx + padding
        0x00, 0x00, 0x00, 0x00, // cap_set_index = 0
        0x00, 0x00, 0x00, 0x00, // padding
    ]

    /// OK_CAPSET_INFO: type 0x1102, then VIR1 / version 1 / size 32 / pad.
    private let capsetInfoResp: [UInt8] = [
        0x02, 0x11, 0x00, 0x00, // type = VIRTIO_GPU_RESP_OK_CAPSET_INFO
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x31, 0x52, 0x49, 0x56, // capset_id = 0x56495231 "VIR1" LE
        0x01, 0x00, 0x00, 0x00, // capset_max_version = 1
        0x20, 0x00, 0x00, 0x00, // capset_max_size = 32
        0x00, 0x00, 0x00, 0x00, // padding
    ]

    /// GET_CAPSET for VIR1 version 1.
    private let capsetReq: [UInt8] = [
        0x09, 0x01, 0x00, 0x00, // type = GET_CAPSET
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x31, 0x52, 0x49, 0x56, // cap_set_id = "VIR1"
        0x01, 0x00, 0x00, 0x00, // cap_set_version = 1
    ]

    /// OK_CAPSET with the eight pinned profile words, ready=0.
    private let capsetRespNotReady: [UInt8] = [
        0x03, 0x11, 0x00, 0x00, // type = VIRTIO_GPU_RESP_OK_CAPSET
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, // version = 1
        0x00, 0x01, 0x00, 0x00, // max_width = 256
        0xc0, 0x00, 0x00, 0x00, // max_height = 192
        0x02, 0x00, 0x00, 0x00, // contexts = 2
        0x02, 0x00, 0x00, 0x00, // resources_per_context = 2
        0x00, 0x10, 0x00, 0x00, // max_submit_bytes = 4096
        0x01, 0x00, 0x00, 0x00, // shader_pair = 1
        0x00, 0x00, 0x00, 0x00, // ready = 0 (no backend)
    ]

    /// CTX_CREATE, ctx_id 7, name "ctx7": 96 bytes.
    private func ctxCreateReq(_ ctxID: UInt32, name: String = "ctx7") -> [UInt8] {
        var req: [UInt8] = [
            0x00, 0x02, 0x00, 0x00, // type = CTX_CREATE
            0x00, 0x00, 0x00, 0x00, // flags
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // fence_id
            0x00, 0x00, 0x00, 0x00, // ctx_id (filled below)
            0x00, 0x00, 0x00, 0x00, // ring_idx + padding
        ]
        req[16] = UInt8(ctxID & 0xff)
        req[17] = UInt8((ctxID >> 8) & 0xff)
        req[18] = UInt8((ctxID >> 16) & 0xff)
        req[19] = UInt8((ctxID >> 24) & 0xff)
        let nb = Array(name.utf8)
        req += [UInt8(nb.count), 0, 0, 0] // nlen
        req += [0, 0, 0, 0]               // context_init = 0
        req += nb + [UInt8](repeating: 0, count: 64 - nb.count)
        return req
    }

    /// CTX_DESTROY, ctx_id 7: header only.
    private func ctxDestroyReq(_ ctxID: UInt32) -> [UInt8] {
        var req: [UInt8] = [
            0x01, 0x02, 0x00, 0x00, // type = CTX_DESTROY
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ]
        req[16] = UInt8(ctxID & 0xff)
        req[17] = UInt8((ctxID >> 8) & 0xff)
        req[18] = UInt8((ctxID >> 16) & 0xff)
        req[19] = UInt8((ctxID >> 24) & 0xff)
        return req
    }

    /// The pinned OK_NODATA response for ctx_id 7, no fence.
    private let okNoDataCtx7: [UInt8] = [
        0x00, 0x11, 0x00, 0x00, // type = VIRTIO_GPU_RESP_OK_NODATA
        0x00, 0x00, 0x00, 0x00, // flags (no fence)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x00, 0x00, 0x00, // ctx_id echoed
        0x00, 0x00, 0x00, 0x00,
    ]

    /// A fenced SUBMIT_3D for ctx_id 7: 4 stream bytes, fence
    /// 0x8877665544332211.
    private func submitReq(ctxID: UInt32 = 7, fence: UInt64 = 0x8877_6655_4433_2211,
                           fenced: Bool = true, stream: [UInt8] = [0xaa, 0xbb, 0xcc, 0xdd]) -> [UInt8] {
        var req: [UInt8] = [
            0x07, 0x02, 0x00, 0x00, // type = SUBMIT_3D
            0x00, 0x00, 0x00, 0x00, // flags (filled below)
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // fence_id
            0x00, 0x00, 0x00, 0x00, // ctx_id
            0x00, 0x00, 0x00, 0x00, // ring_idx + padding
            0x00, 0x00, 0x00, 0x00, // size (filled below)
            0x00, 0x00, 0x00, 0x00, // padding
        ]
        if fenced { req[4] = 0x01 }
        for i in 0..<8 { req[8 + i] = UInt8((fence >> (8 * i)) & 0xff) }
        for i in 0..<4 { req[16 + i] = UInt8((ctxID >> (8 * i)) & 0xff) }
        for i in 0..<4 { req[24 + i] = UInt8((UInt32(stream.count) >> (8 * i)) & 0xff) }
        req += stream
        return req
    }

    /// RESOURCE_CREATE_3D: ctx 7, resource 5, a 256×192 BGRA8 target.
    private func resourceCreateReq(ctxID: UInt32 = 7, resourceID: UInt32 = 5) -> [UInt8] {
        var req: [UInt8] = [
            0x04, 0x02, 0x00, 0x00, // type = RESOURCE_CREATE_3D
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, // ctx_id (filled)
            0x00, 0x00, 0x00, 0x00,
        ]
        for i in 0..<4 { req[16 + i] = UInt8((ctxID >> (8 * i)) & 0xff) }
        let fields: [UInt32] = [
            resourceID, // resource_id
            2,          // target = 2D
            1,          // format = B8G8R8A8_UNORM
            0,          // bind
            256, 192,   // width, height — the profile's ceiling
            1,          // depth
            1,          // array_size
            1,          // last_level
            0,          // nr_samples = single sample
            0,          // flags
            0,          // padding
        ]
        for f in fields {
            req += [UInt8(f & 0xff), UInt8((f >> 8) & 0xff),
                    UInt8((f >> 16) & 0xff), UInt8((f >> 24) & 0xff)]
        }
        return req
    }

    /// RESOURCE_UNREF (0x0102) / RESOURCE_DETACH_BACKING (0x0107): the
    /// frozen VIR1 res-op envelope — 24-byte header + u32 resource_id,
    /// 28 bytes total with NO trailing pad word.
    private func resOpReq(_ type: UInt32, ctxID: UInt32 = 7,
                          resourceID: UInt32 = 5) -> [UInt8] {
        var req: [UInt8] = [
            UInt8(type & 0xff), UInt8((type >> 8) & 0xff), 0x00, 0x00, // type
            0x00, 0x00, 0x00, 0x00, // flags
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // fence_id
            0x00, 0x00, 0x00, 0x00, // ctx_id (filled below)
            0x00, 0x00, 0x00, 0x00, // ring_idx + padding
        ]
        for i in 0..<4 { req[16 + i] = UInt8((ctxID >> (8 * i)) & 0xff) }
        for i in 0..<4 { req.append(UInt8((resourceID >> (8 * i)) & 0xff)) }
        return req
    }

    // MARK: - Helpers

    private func drive(_ device: GPU3DDevice, _ elements: [FakeElement]) {
        device.handleQueueNotification(FakeQueue(elements))
    }

    private func responseType(_ element: FakeElement) -> UInt32 {
        guard element.written.count >= 4 else { return 0xffff_ffff }
        return UInt32(element.written[0])
            | UInt32(element.written[1]) << 8
            | UInt32(element.written[2]) << 16
            | UInt32(element.written[3]) << 24
    }

    @discardableResult
    private func create(_ device: GPU3DDevice, _ ctxID: UInt32) -> FakeElement {
        let el = FakeElement(ctxCreateReq(ctxID))
        drive(device, [el])
        return el
    }

    @discardableResult
    private func destroy(_ device: GPU3DDevice, _ ctxID: UInt32) -> FakeElement {
        let el = FakeElement(ctxDestroyReq(ctxID))
        drive(device, [el])
        return el
    }

    // MARK: - Pinned-byte capability/lifecycle round-trips

    /// GET_CAPSET_INFO parses and round-trips the exact pinned bytes.
    func testCapsetInfoPinnedBytes() {
        switch GPU3DWire.decode(capsetInfoReq) {
        case .success(let req):
            XCTAssertEqual(req.command, .getCapsetInfo(index: 0))
        case .failure(let r):
            XCTFail("pinned capset-info request refused: \(r)")
        }
        let device = GPU3DDevice()
        let el = FakeElement(capsetInfoReq)
        drive(device, [el])
        XCTAssertEqual(el.written, capsetInfoResp)
        XCTAssertTrue(el.returned)
        XCTAssertNil(device.lastRefusal)
    }

    /// GET_CAPSET pins all eight profile words; the ready bit tracks the
    /// injected backend and nothing else.
    func testCapsetPinnedBytes() {
        let device = GPU3DDevice() // no backend → ready=0
        let el = FakeElement(capsetReq)
        drive(device, [el])
        XCTAssertEqual(el.written, capsetRespNotReady)

        let backend = GPU3DTestBackend()
        let deviceReady = GPU3DDevice(backend: backend)
        let el2 = FakeElement(capsetReq)
        drive(deviceReady, [el2])
        var expected = capsetRespNotReady
        expected[52] = 1 // ready word, last payload word's low byte
        XCTAssertEqual(el2.written, expected)

        // Any other index/id/version refuses by name.
        var badIndex = capsetInfoReq
        badIndex[24] = 1
        let elBad = FakeElement(badIndex)
        drive(device, [elBad])
        XCTAssertEqual(device.lastRefusal, .invalidCapset)
        XCTAssertEqual(responseType(elBad), GPU3DWire.respErrInvalidParameter)

        var badVersion = capsetReq
        badVersion[28] = 2
        let elBadV = FakeElement(badVersion)
        drive(device, [elBadV])
        XCTAssertEqual(device.lastRefusal, .invalidCapset)

        var badID = capsetReq
        badID[24] = 0x32 // "VIR2" is not this profile
        let elBadID = FakeElement(badID)
        drive(device, [elBadID])
        XCTAssertEqual(device.lastRefusal, .invalidCapset)
    }

    /// CTX_CREATE/CTX_DESTROY round-trip the pinned 96/24-byte envelopes;
    /// OK_NODATA echoes the context ID.
    func testCtxCreateDestroyPinnedBytes() {
        switch GPU3DWire.decode(ctxCreateReq(7)) {
        case .success(let req):
            XCTAssertEqual(req.command, .ctxCreate(GPU3DWire.CtxCreate(name: "ctx7", nlen: 4)))
            XCTAssertEqual(req.header.ctxID, 7)
        case .failure(let r):
            XCTFail("pinned ctx-create refused: \(r)")
        }
        let device = GPU3DDevice(backend: GPU3DTestBackend())
        let c = create(device, 7)
        XCTAssertEqual(c.written, okNoDataCtx7)
        XCTAssertEqual(device.liveContextIDs, [7])
        XCTAssertEqual(device.generation(of: 7), 1)

        let d = destroy(device, 7)
        XCTAssertEqual(d.written, okNoDataCtx7)
        XCTAssertEqual(device.liveContextIDs, [])
        XCTAssertNil(device.lastRefusal)
    }

    // MARK: - Frozen 28B res-op decode (#2222)

    /// The frozen res-op is 28 bytes: 24-byte header + u32 resource_id
    /// and NO trailing pad — the pad check that used to sit over bytes
    /// 24-27 made every nonzero resource_id die `.reservedBits`, so
    /// unref/detach could never succeed. Both commands now decode and
    /// dispatch against a live resource.
    func testResOpsAccepted28B() {
        switch GPU3DWire.decode(resOpReq(GPU3DWire.cmdResourceUnref)) {
        case .success(let req):
            XCTAssertEqual(req.command, .resourceUnref(resourceID: 5))
            XCTAssertEqual(req.header.ctxID, 7)
        case .failure(let r):
            XCTFail("28B unref refused: \(r)")
        }
        switch GPU3DWire.decode(resOpReq(GPU3DWire.cmdResourceDetachBacking)) {
        case .success(let req):
            XCTAssertEqual(req.command, .resourceDetachBacking(resourceID: 5))
        case .failure(let r):
            XCTFail("28B detach-backing refused: \(r)")
        }

        let backend = GPU3DTestBackend()
        backend.deferWork = false
        let device = GPU3DDevice(backend: backend)
        create(device, 7)
        XCTAssertEqual(responseType({ let e = FakeElement(resourceCreateReq(resourceID: 5)); drive(device, [e]); return e }()),
                       GPU3DWire.respOkNoData)
        XCTAssertEqual(responseType({ let e = FakeElement(resourceCreateReq(resourceID: 6)); drive(device, [e]); return e }()),
                       GPU3DWire.respOkNoData)

        let detach = FakeElement(resOpReq(GPU3DWire.cmdResourceDetachBacking, resourceID: 5))
        drive(device, [detach])
        XCTAssertEqual(backend.calls.last, "detachBacking:7:5")
        XCTAssertEqual(responseType(detach), GPU3DWire.respOkNoData)

        let unref = FakeElement(resOpReq(GPU3DWire.cmdResourceUnref, resourceID: 6))
        drive(device, [unref])
        XCTAssertEqual(backend.calls.last, "unref:7:6")
        XCTAssertEqual(responseType(unref), GPU3DWire.respOkNoData)

        // The unref dropped resource 6 — a second unref names the
        // dead id, and the envelope refusal still decodes.
        let again = FakeElement(resOpReq(GPU3DWire.cmdResourceUnref, resourceID: 6))
        drive(device, [again])
        XCTAssertEqual(device.lastRefusal, .invalidResource)
        XCTAssertEqual(responseType(again), GPU3DWire.respErrInvalidResourceID)
    }

    /// The 28B freeze is the whole envelope: a stock-virtio 32-byte
    /// res-op (trailing pad word) is trailing garbage, a header pad
    /// byte is still a named reserved-bits violation, and resource_id
    /// 0 is still invalid — none of the hygiene checks went away with
    /// the overlapping padWord.
    func testResOpEnvelopeViolationsRefused() {
        let device = GPU3DDevice(backend: GPU3DTestBackend())

        var stockShape = resOpReq(GPU3DWire.cmdResourceUnref)
        stockShape += [0, 0, 0, 0] // the stock-virtio pad word
        let e32 = FakeElement(stockShape)
        drive(device, [e32])
        XCTAssertEqual(device.lastRefusal, .trailingBytes)
        XCTAssertEqual(responseType(e32), GPU3DWire.respErrInvalidParameter)

        var hdrPad = resOpReq(GPU3DWire.cmdResourceUnref)
        hdrPad[21] = 0xff
        let ePad = FakeElement(hdrPad)
        drive(device, [ePad])
        XCTAssertEqual(device.lastRefusal, .reservedBits)

        var badFlag = resOpReq(GPU3DWire.cmdResourceDetachBacking)
        badFlag[4] = 0x02 // INFO_RING_IDX — refused header-wide
        let eFlag = FakeElement(badFlag)
        drive(device, [eFlag])
        XCTAssertEqual(device.lastRefusal, .reservedBits)

        let eZero = FakeElement(resOpReq(GPU3DWire.cmdResourceUnref, resourceID: 0))
        drive(device, [eZero])
        XCTAssertEqual(device.lastRefusal, .invalidResource)
        XCTAssertEqual(responseType(eZero), GPU3DWire.respErrInvalidResourceID)

        let short = FakeElement(Array(resOpReq(GPU3DWire.cmdResourceUnref).prefix(27)))
        drive(device, [short])
        XCTAssertEqual(device.lastRefusal, .truncatedRequest)
    }

    // MARK: - Lifecycle

    /// 100 create/destroy cycles leave zero residue and monotonically
    /// increasing generations.
    func testHundredCreateDestroyCycles() {
        let device = GPU3DDevice(backend: GPU3DTestBackend())
        var lastGen: [UInt32: UInt64] = [:]
        for i in 0..<100 {
            let id: UInt32 = i % 2 == 0 ? 1 : 7
            XCTAssertEqual(responseType(create(device, id)), GPU3DWire.respOkNoData,
                           "create \(i) refused")
            let gen = try? XCTUnwrap(device.generation(of: id))
            XCTAssertNotNil(gen)
            XCTAssertGreaterThan(gen ?? 0, lastGen[id] ?? 0,
                                 "generation must rise per ctx_id (cycle \(i))")
            lastGen[id] = gen ?? 0
            XCTAssertEqual(responseType(destroy(device, id)), GPU3DWire.respOkNoData,
                           "destroy \(i) refused")
            XCTAssertTrue(device.liveContextIDs.isEmpty)
        }
        XCTAssertNil(device.lastRefusal)
        XCTAssertEqual(device.refusalCount, 0)
    }

    /// The third live context is pool exhaustion: named refusal,
    /// ERR_OUT_OF_MEMORY, and zero partial state.
    func testThirdContextRefused() {
        let device = GPU3DDevice(backend: GPU3DTestBackend())
        create(device, 1)
        create(device, 2)
        let third = FakeElement(ctxCreateReq(3))
        drive(device, [third])
        XCTAssertEqual(device.lastRefusal, .contextSlotsFull)
        XCTAssertEqual(responseType(third), GPU3DWire.respErrOutOfMemory)
        XCTAssertTrue(third.returned)
        XCTAssertEqual(device.liveContextIDs, [1, 2])
    }

    /// A duplicate ctx_id refuses without touching the live context.
    func testDuplicateContextRefused() {
        let device = GPU3DDevice(backend: GPU3DTestBackend())
        create(device, 7)
        let gen = device.generation(of: 7)
        let dup = FakeElement(ctxCreateReq(7, name: "ctx7"))
        drive(device, [dup])
        XCTAssertEqual(device.lastRefusal, .duplicateContext)
        XCTAssertEqual(responseType(dup), GPU3DWire.respErrInvalidContextID)
        XCTAssertEqual(device.generation(of: 7), gen)

        let zero = FakeElement(ctxCreateReq(0, name: "zero"))
        drive(device, [zero])
        XCTAssertEqual(device.lastRefusal, .invalidContext)
    }

    /// A sub-header element is a named truncation; the device still
    /// returns the element with an error response.
    func testTruncatedRequestRefused() {
        let device = GPU3DDevice()
        let el = FakeElement([0x00, 0x02, 0x00])
        drive(device, [el])
        XCTAssertEqual(device.lastRefusal, .truncatedRequest)
        XCTAssertEqual(responseType(el), GPU3DWire.respErrUnspec)
        XCTAssertTrue(el.returned)
        XCTAssertTrue(device.liveContextIDs.isEmpty)

        // Header-sized but body-short: CTX_CREATE claims 96 bytes.
        let short = FakeElement(Array(ctxCreateReq(7).prefix(60)))
        drive(device, [short])
        XCTAssertEqual(device.lastRefusal, .truncatedRequest)
        XCTAssertEqual(responseType(short), GPU3DWire.respErrInvalidParameter)
    }

    /// Reserved/padding bytes and unknown flag bits all refuse by name,
    /// across several different envelopes.
    func testReservedBitsRefused() {
        let device = GPU3DDevice(backend: GPU3DTestBackend())

        var hdrPad = ctxCreateReq(7)
        hdrPad[21] = 0xff // header padding byte
        let e1 = FakeElement(hdrPad)
        drive(device, [e1])
        XCTAssertEqual(device.lastRefusal, .reservedBits)
        XCTAssertEqual(responseType(e1), GPU3DWire.respErrInvalidParameter)

        var badFlag = ctxCreateReq(7)
        badFlag[4] = 0x02 // INFO_RING_IDX — not carried by this profile
        let e2 = FakeElement(badFlag)
        drive(device, [e2])
        XCTAssertEqual(device.lastRefusal, .reservedBits)

        var badInit = ctxCreateReq(7)
        badInit[28] = 1 // context_init is Venus machinery; must be 0
        let e3 = FakeElement(badInit)
        drive(device, [e3])
        XCTAssertEqual(device.lastRefusal, .reservedBits)

        var badTail = ctxCreateReq(7)
        badTail[40] = 0xaa // inside debug_name, past the 4-byte name
        let e4 = FakeElement(badTail)
        drive(device, [e4])
        XCTAssertEqual(device.lastRefusal, .reservedBits)

        var badSubmitPad = submitReq()
        badSubmitPad[29] = 1 // SUBMIT_3D padding word
        let e5 = FakeElement(badSubmitPad)
        drive(device, [e5])
        XCTAssertEqual(device.lastRefusal, .reservedBits)

        XCTAssertTrue(device.liveContextIDs.isEmpty, "a refused create must not register")
    }

    /// A write buffer too short for the success response is itself a
    /// named refusal; the guest still sees a bare error header when it
    /// fits, and nothing at all when it doesn't.
    func testShortResponseSpaceRefused() {
        let device = GPU3DDevice()
        // GET_CAPSET wants 56 bytes; 40 fits the error header only.
        let tight = FakeElement(capsetReq, writeCapacity: 40)
        drive(device, [tight])
        XCTAssertEqual(device.lastRefusal, .responseSpaceShort)
        XCTAssertEqual(tight.written.count, GPU3DWire.hdrLen)
        XCTAssertEqual(responseType(tight), GPU3DWire.respErrUnspec)
        XCTAssertTrue(tight.returned)

        // 8 bytes can't even hold an error header — the element is
        // returned empty, the refusal still named.
        let tiny = FakeElement(capsetReq, writeCapacity: 8)
        drive(device, [tiny])
        XCTAssertEqual(device.lastRefusal, .responseSpaceShort)
        XCTAssertEqual(tiny.written.count, 0)
        XCTAssertTrue(tiny.returned)
    }

    /// Commands outside the private profile name their refusal: a real
    /// virtio-gpu 2D command is unsupported; a non-gpu type is unknown.
    func testOutOfProfileCommandsRefused() {
        let device = GPU3DDevice(backend: GPU3DTestBackend())
        var displayInfo = capsetInfoReq
        displayInfo[0] = 0x00 // GET_DISPLAY_INFO 0x0100
        let e1 = FakeElement(displayInfo)
        drive(device, [e1])
        XCTAssertEqual(device.lastRefusal, .unsupportedCommand(0x0100))
        XCTAssertEqual(responseType(e1), GPU3DWire.respErrUnspec)

        var garbage = capsetInfoReq
        garbage[0] = 0x99
        garbage[1] = 0x99
        let e2 = FakeElement(garbage)
        drive(device, [e2])
        XCTAssertEqual(device.lastRefusal, .unknownCommand(0x9999))
    }

    // MARK: - Deferred completion, generation safety, reset

    /// A fenced deferred submit holds the element; only the matching
    /// fence completes it, and the response echoes the full u64 fence.
    func testDeferredCompletionMatchesFence() {
        let backend = GPU3DTestBackend() // defers all work
        let device = GPU3DDevice(backend: backend)
        create(device, 7)

        let el = FakeElement(submitReq())
        drive(device, [el])
        XCTAssertEqual(backend.calls.last, "submit:7:4")
        XCTAssertFalse(el.returned, "deferred work holds the element")
        XCTAssertEqual(el.written.count, 0)
        XCTAssertEqual(device.pendingFenceID, 0x8877_6655_4433_2211)

        // A wrong fence completes nothing.
        device.noteFenceCompleted(0x1111)
        XCTAssertFalse(el.returned)
        XCTAssertEqual(device.staleCompletions, 1)

        device.noteFenceCompleted(0x8877_6655_4433_2211)
        XCTAssertTrue(el.returned)
        XCTAssertEqual(responseType(el), GPU3DWire.respOkNoData)
        // Response echoes FENCE flag + the full fence ID + ctx_id.
        XCTAssertEqual(el.written[4], 0x01)
        XCTAssertEqual(Array(el.written[8..<16]),
                       [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
        XCTAssertEqual(Array(el.written[16..<20]), [0x07, 0x00, 0x00, 0x00])
    }

    /// Deferred completion requires the guest's fence — an unfenced
    /// submit to a deferring backend is a named refusal, not silent
    /// acceptance.
    func testDeferredWorkRequiresFence() {
        let device = GPU3DDevice(backend: GPU3DTestBackend())
        create(device, 7)
        let el = FakeElement(submitReq(fenced: false))
        drive(device, [el])
        XCTAssertEqual(device.lastRefusal, .fenceRequired)
        XCTAssertEqual(responseType(el), GPU3DWire.respErrUnspec)
        XCTAssertTrue(el.returned)
        XCTAssertNil(device.pendingFenceID)
    }

    /// At most one device request is outstanding: a second deferrable
    /// submit — even on the other live context — is refused busy.
    func testSingleOutstandingRequest() {
        let device = GPU3DDevice(backend: GPU3DTestBackend())
        create(device, 7)
        create(device, 9)
        let first = FakeElement(submitReq(ctxID: 7, fence: 0xaa))
        drive(device, [first])
        XCTAssertEqual(device.pendingFenceID, 0xaa)

        let second = FakeElement(submitReq(ctxID: 9, fence: 0xbb))
        drive(device, [second])
        XCTAssertEqual(device.lastRefusal, .deviceBusy)
        XCTAssertTrue(second.returned)
        XCTAssertEqual(device.pendingFenceID, 0xaa)

        device.noteFenceCompleted(0xaa)
        XCTAssertTrue(first.returned)
    }

    /// Reset retires the held element with an honest error, drops the
    /// contexts, and keeps generations rising — the delayed completion
    /// for the pre-reset fence lands nowhere.
    func testResetRetiresContextsAndPendingSafely() {
        let backend = GPU3DTestBackend()
        let device = GPU3DDevice(backend: backend)
        create(device, 7)
        create(device, 9)
        XCTAssertEqual(device.generation(of: 7), 1)

        let held = FakeElement(submitReq(ctxID: 7, fence: 0xfeed_0001))
        drive(device, [held])
        XCTAssertEqual(device.pendingFenceID, 0xfeed_0001)

        device.reset()
        XCTAssertTrue(held.returned, "reset must return the held element")
        XCTAssertEqual(responseType(held), GPU3DWire.respErrUnspec)
        XCTAssertEqual(device.retiredPending, 1)
        XCTAssertEqual(device.liveContextIDs, [])
        XCTAssertEqual(backend.resets, 1)

        // The recycled ctx_id gets generation 2 — never generation 1.
        create(device, 7)
        XCTAssertEqual(device.generation(of: 7), 2)

        // The delayed pre-reset completion cannot target generation 2:
        // it is dropped as stale and the live context is untouched.
        device.noteFenceCompleted(0xfeed_0001)
        XCTAssertEqual(device.staleCompletions, 1)
        XCTAssertEqual(device.generation(of: 7), 2)

        // And the device still serves new fenced work on the new
        // generation.
        let next = FakeElement(submitReq(ctxID: 7, fence: 0xfeed_0002))
        drive(device, [next])
        XCTAssertEqual(device.pendingFenceID, 0xfeed_0002)
        device.noteFenceCompleted(0xfeed_0002)
        XCTAssertEqual(responseType(next), GPU3DWire.respOkNoData)
    }

    /// Destroying a context that has a fence in flight retires the held
    /// element honestly; the late fence completes nothing.
    func testDestroyRetiresPending() {
        let device = GPU3DDevice(backend: GPU3DTestBackend())
        create(device, 7)
        let held = FakeElement(submitReq(ctxID: 7, fence: 0x5a))
        drive(device, [held])

        let d = destroy(device, 7)
        XCTAssertEqual(d.written, okNoDataCtx7)
        XCTAssertTrue(held.returned)
        XCTAssertEqual(responseType(held), GPU3DWire.respErrUnspec)
        XCTAssertEqual(device.retiredPending, 1)

        device.noteFenceCompleted(0x5a)
        XCTAssertEqual(device.staleCompletions, 1)
    }

    /// The backend's poll channel retires deferred work too — the polled
    /// model, with no callback, completes the same matched fence.
    func testPollCompletesPending() {
        let backend = GPU3DTestBackend()
        let device = GPU3DDevice(backend: backend)
        create(device, 7)
        let el = FakeElement(submitReq(ctxID: 7, fence: 0x42))
        drive(device, [el])
        XCTAssertFalse(el.returned)

        backend.polledFences = [0x42]
        // The next queue drain observes the poll — even an empty batch.
        drive(device, [])
        XCTAssertTrue(el.returned)
        XCTAssertEqual(responseType(el), GPU3DWire.respOkNoData)
    }

    /// pumpFences() is the drain the serial-queue pump invokes between
    /// doorbells: an unfinished fence keeps the element held, a finished
    /// one retires it with the matched OK — no queue notification needed.
    func testPumpFencesRetiresPending() {
        let backend = GPU3DTestBackend()
        let device = GPU3DDevice(backend: backend)
        create(device, 7)
        let el = FakeElement(submitReq(ctxID: 7, fence: 0x42))
        drive(device, [el])
        XCTAssertFalse(el.returned)

        device.pumpFences() // Metal has not completed — still held.
        XCTAssertFalse(el.returned)
        XCTAssertEqual(device.pendingFenceID, 0x42)

        backend.polledFences = [0x42]
        device.pumpFences()
        XCTAssertTrue(el.returned)
        XCTAssertEqual(responseType(el), GPU3DWire.respOkNoData)
        XCTAssertNil(device.pendingFenceID)
    }

    /// #2223: while a deferred element holds its fence the device
    /// re-polls the backend on completionQueue — the guest's next
    /// doorbell is NOT required for the fence to retire. The Metal
    /// completion is armed from inside the poll itself (on the pump's
    /// serial queue) so the test races nothing.
    func testFencePumpCompletesWithoutDoorbell() {
        let backend = GPU3DTestBackend()
        let device = GPU3DDevice(backend: backend)
        device.completionQueue = DispatchQueue(label: "test.gpu3d.fencepump")
        // The completion lands between guest notifications: arm it
        // inside the poll, which every pump tick runs on the serial
        // queue — the first notification-time poll sees no pending
        // fence and stays empty.
        backend.onPoll = {
            if device.pendingFenceID == 0x42 { backend.polledFences = [0x42] }
        }
        create(device, 7)

        let returned = expectation(description: "held element returned")
        let el = FakeElement(submitReq(ctxID: 7, fence: 0x42))
        el.onReturn = { returned.fulfill() }
        drive(device, [el])
        XCTAssertEqual(device.pendingFenceID, 0x42)
        XCTAssertFalse(el.returned)

        wait(for: [returned], timeout: 2)
        XCTAssertEqual(responseType(el), GPU3DWire.respOkNoData)
        XCTAssertNil(device.pendingFenceID)
        XCTAssertEqual(device.staleCompletions, 0)
    }

    /// The pump stops itself: once the fence retires, `pending` clears
    /// and no further poll is armed — a late backend report lands as
    /// stale, never as a second retirement of the same element.
    func testFencePumpStopsAfterRetirement() {
        let backend = GPU3DTestBackend()
        let device = GPU3DDevice(backend: backend)
        device.completionQueue = DispatchQueue(label: "test.gpu3d.fencepump.stop")
        create(device, 7)

        let returned = expectation(description: "held element returned")
        let el = FakeElement(submitReq(ctxID: 7, fence: 0x42))
        el.onReturn = { returned.fulfill() }
        drive(device, [el])

        backend.polledFences = [0x42]
        device.pumpFences() // retire synchronously before any pump tick
        wait(for: [returned], timeout: 2)
        XCTAssertNil(device.pendingFenceID)

        // Let any stray tick fire, then a late fence report is stale.
        backend.polledFences = [0x42]
        let drained = expectation(description: "pump drained")
        device.completionQueue?.asyncAfter(deadline: .now() + 0.02) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        device.pumpFences()
        XCTAssertEqual(device.staleCompletions, 1)
    }

    // MARK: - Null backend

    /// With no backend the device still answers the capability envelope
    /// (ready=0) and context lifecycle, but every render-path command is
    /// a named refusal — and no successful-render receipt is ever
    /// manufactured.
    func testNullBackendRefusesRendering() {
        let device = GPU3DDevice()

        let info = FakeElement(capsetInfoReq)
        let caps = FakeElement(capsetReq)
        drive(device, [info, caps])
        XCTAssertEqual(info.written, capsetInfoResp)
        XCTAssertEqual(caps.written, capsetRespNotReady) // ready word = 0

        let c = create(device, 7) // envelope lifecycle still works
        XCTAssertEqual(c.written, okNoDataCtx7)

        let res = FakeElement(resourceCreateReq())
        let sub = FakeElement(submitReq())
        drive(device, [res, sub])
        XCTAssertEqual(device.lastRefusal, .backendUnavailable)
        XCTAssertEqual(responseType(res), GPU3DWire.respErrUnspec)
        XCTAssertEqual(responseType(sub), GPU3DWire.respErrUnspec)
        // Neither element carried a fake "success" — both are errors.
        for el in [res, sub] {
            XCTAssertNotEqual(responseType(el), GPU3DWire.respOkNoData)
        }
    }

    /// A backend that declines CTX_CREATE fails the guest's create with
    /// no context recorded — the clean partial-failure unwind.
    func testBackendCreateRefusalLeavesNoState() {
        let backend = GPU3DTestBackend()
        backend.nextFailure = .refused
        let device = GPU3DDevice(backend: backend)
        let el = FakeElement(ctxCreateReq(7))
        drive(device, [el])
        XCTAssertEqual(device.lastRefusal, .backendRefused)
        XCTAssertEqual(responseType(el), GPU3DWire.respErrUnspec)
        XCTAssertTrue(device.liveContextIDs.isEmpty)

        // The slot is free: the next create succeeds.
        create(device, 7)
        XCTAssertEqual(device.liveContextIDs, [7])
    }

    /// Render-path bookkeeping is enforced before the backend is asked:
    /// resource bound per context, resource existence for transfers, and
    /// in-extent boxes.
    func testResourceBoundsEnforced() {
        let backend = GPU3DTestBackend()
        backend.deferWork = false
        let device = GPU3DDevice(backend: backend)
        create(device, 7)

        // Two resources land; the third hits the per-context bound.
        XCTAssertEqual(responseType({ let e = FakeElement(resourceCreateReq(resourceID: 5)); drive(device, [e]); return e }()),
                       GPU3DWire.respOkNoData)
        XCTAssertEqual(responseType({ let e = FakeElement(resourceCreateReq(resourceID: 6)); drive(device, [e]); return e }()),
                       GPU3DWire.respOkNoData)
        let over = FakeElement(resourceCreateReq(resourceID: 9))
        drive(device, [over])
        XCTAssertEqual(device.lastRefusal, .resourceLimit)
        XCTAssertEqual(responseType(over), GPU3DWire.respErrOutOfMemory)

        let dup = FakeElement(resourceCreateReq(resourceID: 5))
        drive(device, [dup])
        XCTAssertEqual(device.lastRefusal, .duplicateResource)

        // A transfer naming no live resource refuses.
        var xfer: [UInt8] = [
            0x05, 0x02, 0x00, 0x00, // TRANSFER_TO_HOST_3D
            0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            7, 0, 0, 0,             // ctx_id
            0, 0, 0, 0,
            0, 0, 0, 0,             // box x
            0, 0, 0, 0,             // box y
            0, 0, 0, 0,             // box z
            4, 0, 0, 0, 4, 0, 0, 0, 1, 0, 0, 0, // w=4,h=4,d=1
            0, 0, 0, 0, 0, 0, 0, 0, // offset
            77, 0, 0, 0,            // resource_id = 77 (not live)
            0, 0, 0, 0,             // level
            16, 0, 0, 0,            // stride
            0, 0, 0, 0,             // layer_stride
        ]
        let e = FakeElement(xfer)
        drive(device, [e])
        XCTAssertEqual(device.lastRefusal, .invalidResource)

        // Same transfer at live resource 5 succeeds through the backend.
        xfer[56] = 5
        let ok = FakeElement(xfer)
        drive(device, [ok])
        XCTAssertEqual(responseType(ok), GPU3DWire.respOkNoData)
        XCTAssertEqual(backend.calls.last, "transfer:to:7:5")

        // An out-of-extent box refuses before the backend is asked.
        xfer[24] = 255 // box.x = 255; 255+4 > 256
        let oob = FakeElement(xfer)
        drive(device, [oob])
        XCTAssertEqual(device.lastRefusal, .invalidParameter)
    }

    // MARK: - M111b compute (#2409, ADR 0053)

    /// GET_CAPSET_INFO for index 1 (VIC1 discovery).
    private func capsetInfoReqAt(_ index: UInt32) -> [UInt8] {
        var req = capsetInfoReq
        for i in 0..<4 { req[24 + i] = UInt8((index >> (8 * i)) & 0xff) }
        return req
    }

    /// GET_CAPSET for a named capset id + version.
    private func getCapsetReq(id: UInt32, version: UInt32 = 1) -> [UInt8] {
        var req = capsetReq
        for i in 0..<4 { req[24 + i] = UInt8((id >> (8 * i)) & 0xff) }
        for i in 0..<4 { req[28 + i] = UInt8((version >> (8 * i)) & 0xff) }
        return req
    }

    /// RESOURCE_CREATE_3D for a target_buffer byte window (target 0):
    /// flat 1-D shape, no format/bind — the compute path's create.
    private func bufferCreateReq(ctxID: UInt32 = 7, resourceID: UInt32,
                                 size: UInt32 = 4096) -> [UInt8] {
        var req = resourceCreateReq(ctxID: ctxID, resourceID: resourceID)
        req[28] = 0 // target = 0 (buffer)
        req[32] = 0 // format = 0 (no format semantics on a byte range)
        req[36] = 0 // bind = 0 (not a vertex buffer)
        for i in 0..<4 { req[40 + i] = UInt8((size >> (8 * i)) & 0xff) } // width = bytes
        req[44] = 1 // height = 1
        req[56] = 0 // last_level = 0 (the builder's texture value is 1)
        return req
    }

    /// CTX_ATTACH_RESOURCE (0x0202) for a resource of ctx 7.
    private func attachReq(ctxID: UInt32 = 7, resourceID: UInt32) -> [UInt8] {
        resOpReq(GPU3DWire.cmdCtxAttachResource, ctxID: ctxID, resourceID: resourceID)
    }

    /// A fenced COMPUTE_SUBMIT for ctx_id 7 carrying the 64-byte kernel
    /// descriptor verbatim (the wire is the guest's encode — the decoder
    /// must round-trip the same layout the kernel emits).
    private func computeSubmitReq(_ kd: GPU3DWire.KernelDesc,
                                  ctxID: UInt32 = 7,
                                  fence: UInt64 = 0x5a5a_0101_0202_0303,
                                  fenced: Bool = true) -> [UInt8] {
        var req: [UInt8] = [
            0x00, 0x04, 0x00, 0x00, // type = COMPUTE_SUBMIT (0x0400)
            0x00, 0x00, 0x00, 0x00, // flags (filled below)
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // fence_id
            0x00, 0x00, 0x00, 0x00, // ctx_id
            0x00, 0x00, 0x00, 0x00, // ring_idx + padding
        ]
        if fenced { req[4] = 0x01 }
        for i in 0..<8 { req[8 + i] = UInt8((fence >> (8 * i)) & 0xff) }
        for i in 0..<4 { req[16 + i] = UInt8((ctxID >> (8 * i)) & 0xff) }
        func u32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
             UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        }
        req += u32(kd.kernelID) + u32(kd.flags)
        req += u32(kd.d0) + u32(kd.d1) + u32(kd.d2) + u32(kd.aux)
        for b in kd.bufs { req += u32(b.buf) + u32(b.byteOff) }
        req += [0, 0, 0, 0, 0, 0, 0, 0] // reserved
        return req
    }

    /// A small GEMM descriptor: A[2×2]·B[2×2]→C[2×2], resources 5,6,7.
    private func gemmDesc(res: (UInt32, UInt32, UInt32) = (5, 6, 7)) -> GPU3DWire.KernelDesc {
        var kd = GPU3DWire.KernelDesc()
        kd.kernelID = GPU3DWire.kernelGEMM
        kd.d0 = 2; kd.d1 = 2; kd.d2 = 2
        kd.bufs = [.init(buf: res.0), .init(buf: res.1), .init(buf: res.2), .init()]
        return kd
    }

    /// Create a ctx and three attached 4 KiB buffers on it.
    private func bufferSet(_ device: GPU3DDevice, _ ctxID: UInt32,
                           _ backend: GPU3DTestBackend) {
        create(device, ctxID)
        for res: UInt32 in [5, 6, 7] {
            drive(device, [FakeElement(bufferCreateReq(ctxID: ctxID, resourceID: res))])
            drive(device, [FakeElement(attachReq(ctxID: ctxID, resourceID: res))])
        }
    }

    /// VIC1 discovery: index 1 answers the pinned VIC1 payload only when
    /// a backend is attached; ready tracks gpu3dComputeReady.
    func testVic1CapsetDiscovery() {
        // Backend-less device: index 1 is the honest refusal, and the
        // config advertises one capset.
        let solo = GPU3DDevice()
        let miss = FakeElement(capsetInfoReqAt(1))
        drive(solo, [miss])
        XCTAssertEqual(solo.lastRefusal, .invalidCapset)
        XCTAssertEqual(responseType(miss), GPU3DWire.respErrInvalidParameter)

        // With a backend, index 1 answers "VIC1"/v1/32 and the capset
        // payload carries the eight frozen words.
        let backend = GPU3DTestBackend()
        let device = GPU3DDevice(backend: backend)
        let info = FakeElement(capsetInfoReqAt(1))
        drive(device, [info])
        XCTAssertEqual(info.written.count, 40)
        XCTAssertEqual(responseType(info), GPU3DWire.respOkCapsetInfo)
        XCTAssertEqual(Array(info.written[24..<28]), [0x31, 0x43, 0x49, 0x56]) // "VIC1" LE
        XCTAssertEqual(Array(info.written[28..<32]), [0x01, 0x00, 0x00, 0x00])
        XCTAssertEqual(Array(info.written[32..<36]), [0x20, 0x00, 0x00, 0x00])

        let gc = FakeElement(getCapsetReq(id: GPU3DWire.capsetVIC1))
        drive(device, [gc])
        XCTAssertEqual(gc.written.count, 56)
        XCTAssertEqual(responseType(gc), GPU3DWire.respOkCapset)
        func word(_ i: Int) -> UInt32 {
            UInt32(gc.written[24 + i * 4])
                | UInt32(gc.written[24 + i * 4 + 1]) << 8
                | UInt32(gc.written[24 + i * 4 + 2]) << 16
                | UInt32(gc.written[24 + i * 4 + 3]) << 24
        }
        XCTAssertEqual(word(0), 1)                  // version
        XCTAssertEqual(word(1), 16)                 // max buffers/context
        XCTAssertEqual(word(2), 16 * 1024 * 1024)   // max buffer bytes
        XCTAssertEqual(word(3), 7)                  // kernels_mask
        XCTAssertEqual(word(4), 4096)               // max dim
        XCTAssertEqual(word(5), 1 << 24)            // max elems
        XCTAssertEqual(word(6), 0)                  // reserved
        XCTAssertEqual(word(7), 0)                  // ready (backend off)

        backend.computeReady = true
        let gc2 = FakeElement(getCapsetReq(id: GPU3DWire.capsetVIC1))
        drive(device, [gc2])
        XCTAssertEqual(Array(gc2.written[52..<56]), [0x01, 0x00, 0x00, 0x00])

        // Wrong version / index-2 probes refuse.
        let badV = FakeElement(getCapsetReq(id: GPU3DWire.capsetVIC1, version: 2))
        drive(device, [badV])
        XCTAssertEqual(device.lastRefusal, .invalidCapset)
        let badI = FakeElement(capsetInfoReqAt(2))
        drive(device, [badI])
        XCTAssertEqual(device.lastRefusal, .invalidCapset)
    }

    /// The happy path: three buffers + a fenced GEMM submit defers until
    /// the backend reports the fence; the held element returns OK_NODATA.
    func testComputeSubmitDefersAndFences() {
        let backend = GPU3DTestBackend()
        backend.computeReady = true
        let device = GPU3DDevice(backend: backend)
        bufferSet(device, 7, backend)

        let el = FakeElement(computeSubmitReq(gemmDesc()))
        drive(device, [el])
        XCTAssertFalse(el.returned, "a deferred submit must hold the element")
        XCTAssertEqual(device.pendingFenceID, 0x5a5a_0101_0202_0303)
        XCTAssertEqual(backend.calls.last, "compute:7:1")

        // An unknown fence reports nothing; the real one releases it —
        // any new element drains the backend's poll at the batch top.
        device.noteFenceCompleted(0xdead)
        XCTAssertFalse(el.returned)
        backend.polledFences = [0x5a5a_0101_0202_0303]
        drive(device, [FakeElement(capsetInfoReqAt(0))])
        XCTAssertTrue(el.returned)
        XCTAssertEqual(responseType(el), GPU3DWire.respOkNoData)
        XCTAssertNil(device.pendingFenceID)
    }

    /// The D2/D3 named refusals refuse before the backend is asked.
    func testComputeSubmitRefusalTable() {
        let backend = GPU3DTestBackend()
        backend.computeReady = true
        let device = GPU3DDevice(backend: backend)
        bufferSet(device, 7, backend)

        // kernel_id outside the mask → unknownKernel → EINVAL class.
        var kd = gemmDesc()
        kd.kernelID = 9
        let unknown = FakeElement(computeSubmitReq(kd))
        drive(device, [unknown])
        XCTAssertEqual(device.lastRefusal, .unknownKernel)
        XCTAssertEqual(responseType(unknown), GPU3DWire.respErrInvalidParameter)

        // Zero dim → badKernelShape.
        kd = gemmDesc()
        kd.d0 = 0
        let dimZero = FakeElement(computeSubmitReq(kd))
        drive(device, [dimZero])
        XCTAssertEqual(device.lastRefusal, .badKernelShape)

        // A buf slot naming no resource of this ctx → badKernelBinding.
        kd = gemmDesc(res: (5, 6, 77))
        let missing = FakeElement(computeSubmitReq(kd))
        drive(device, [missing])
        XCTAssertEqual(device.lastRefusal, .badKernelBinding)
        XCTAssertEqual(responseType(missing), GPU3DWire.respErrInvalidResourceID)

        // A buf slot naming the ctx's TEXTURE (not a buffer) refuses too.
        drive(device, [FakeElement(resourceCreateReq(ctxID: 7, resourceID: 9))])
        drive(device, [FakeElement(attachReq(ctxID: 7, resourceID: 9))])
        kd = gemmDesc(res: (5, 6, 9))
        let texBind = FakeElement(computeSubmitReq(kd))
        drive(device, [texBind])
        XCTAssertEqual(device.lastRefusal, .badKernelBinding)

        // The backend call log proves validation happened device-side:
        // nothing reached gpu3dComputeSubmit.
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("compute:") })

        // An unfenced submit to the deferring backend is fenceRequired —
        // the descriptor is valid so the backend IS asked; the wire-side
        // refusal is the missing fence, not the math.
        let unfenced = FakeElement(computeSubmitReq(gemmDesc(), fenced: false))
        drive(device, [unfenced])
        XCTAssertEqual(device.lastRefusal, .fenceRequired)
    }

    /// Compute shares the one-outstanding device slot with render: a
    /// deferred SUBMIT_3D holds the slot; a compute submit is busy.
    func testComputeSharesTheOneOutstandingSlot() {
        let backend = GPU3DTestBackend()
        backend.computeReady = true
        let device = GPU3DDevice(backend: backend)
        bufferSet(device, 7, backend)
        create(device, 9)

        let held = FakeElement(submitReq(ctxID: 7, fence: 0x42))
        drive(device, [held])
        XCTAssertEqual(device.pendingFenceID, 0x42)

        let cs = FakeElement(computeSubmitReq(gemmDesc(), ctxID: 9, fence: 0x77))
        drive(device, [cs])
        XCTAssertEqual(device.lastRefusal, .deviceBusy)
        XCTAssertTrue(cs.returned)
        XCTAssertFalse(backend.calls.contains { $0.hasPrefix("compute:") })
        device.noteFenceCompleted(0x42)
        XCTAssertTrue(held.returned)
    }

    /// target_buffer creates carry VIC1's bounds: over 16 MiB, a non-flat
    /// height, and a sixth live buffer? — the 16-buffer/context budget.
    func testBufferResourceBounds() {
        let backend = GPU3DTestBackend()
        backend.computeReady = true
        let device = GPU3DDevice(backend: backend)
        create(device, 7)

        // 16 MiB + 1 byte refuses.
        let tooBig = FakeElement(bufferCreateReq(resourceID: 5, size: 16 * 1024 * 1024 + 1))
        drive(device, [tooBig])
        XCTAssertEqual(device.lastRefusal, .invalidParameter)

        // height != 1 refuses (buffers are flat).
        var tall = bufferCreateReq(resourceID: 5)
        tall[44] = 2
        let tallEl = FakeElement(tall)
        drive(device, [tallEl])
        XCTAssertEqual(device.lastRefusal, .invalidParameter)

        // A nonzero format/bind refuses the flat shape.
        var f = bufferCreateReq(resourceID: 5)
        f[32] = 1
        drive(device, [FakeElement(f)])
        XCTAssertEqual(device.lastRefusal, .invalidParameter)

        // Sixteen buffers is the VIC1 budget; the 17th is resourceLimit.
        // (lastRefusal holds the earlier legs' named refusals — a success
        // does not clear it — so the response word is what is asserted.)
        for res: UInt32 in 1...16 {
            let el = FakeElement(bufferCreateReq(resourceID: res))
            drive(device, [el])
            XCTAssertEqual(responseType(el), GPU3DWire.respOkNoData,
                           "buffer \(res) refused: \(String(describing: device.lastRefusal))")
        }
        let seventeenth = FakeElement(bufferCreateReq(resourceID: 17))
        drive(device, [seventeenth])
        XCTAssertEqual(device.lastRefusal, .resourceLimit)

        // But the render budget stays 2 in the same context.
        let tex1 = FakeElement(resourceCreateReq(ctxID: 7, resourceID: 30))
        let tex2 = FakeElement(resourceCreateReq(ctxID: 7, resourceID: 31))
        let tex3 = FakeElement(resourceCreateReq(ctxID: 7, resourceID: 32))
        drive(device, [tex1, tex2, tex3])
        XCTAssertEqual(device.lastRefusal, .resourceLimit)
    }
}
