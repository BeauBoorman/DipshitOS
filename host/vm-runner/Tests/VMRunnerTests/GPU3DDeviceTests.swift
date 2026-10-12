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
}
