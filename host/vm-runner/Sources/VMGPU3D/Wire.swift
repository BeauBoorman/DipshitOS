// Wire.swift — M102b2 (issue #2163): the frozen wire format for the
// experimental custom-Virtio 3D render device, deviceID 0x43
// (PCI 1af4:1083), per the owner-approved private profile in the M102
// index (issue #2160). This is NOT standard capset 1, VIRGL2 or VENUS:
// the mandatory private capability set is 0x56495231 ("VIR1") version 1,
// a 32-byte payload of eight LE u32 words, and the device must reject
// every other profile, version and size.
//
// Pure Swift + Foundation — no Virtualization imports, so `swift test`
// pins every byte below on a host that never boots a VM. The guest-side
// mirror of this layout lives in b1's kernel files; both sides implement
// the shared contract in #2160, nothing else.
//
// Envelope: virtio_gpu_ctrl_hdr (24 bytes, all LE):
//   +0  u32 type
//   +4  u32 flags        (bit0 FENCE; bit1 INFO_RING_IDX and all others
//                         are refused — we use a single control ring)
//   +8  u64 fence_id     (meaningful iff FENCE was set by the guest)
//   +16 u32 ctx_id
//   +20 u8  ring_idx     (must be 0)
//   +21 u8  padding[3]   (must be 0)
//
// Request bodies (bytes after the header):
//   GET_CAPSET_INFO      u32 cap_set_index, u32 padding          (32 total)
//   GET_CAPSET           u32 cap_set_id, u32 cap_set_version     (32 total)
//   CTX_CREATE           u32 nlen, u32 context_init, name[64]    (96 total)
//   CTX_DESTROY          — header only                            (24 total)
//   CTX_ATTACH_RESOURCE  u32 resource_id                          (28 total)
//   CTX_DETACH_RESOURCE  u32 resource_id                          (28 total)
//   RESOURCE_CREATE_3D   12 × u32                                 (72 total)
//   TRANSFER_TO/FROM_3D  box[24], u64 offset, 4 × u32             (72 total)
//   SUBMIT_3D            u32 size, u32 padding + `size` stream bytes
//   RESOURCE_ATTACH_BACKING u32 resource_id, u32 nr_entries,
//                        entries[n]{u64 addr, u32 len, u32 pad}
//   RESOURCE_DETACH_BACKING / RESOURCE_UNREF
//                        u32 resource_id                          (28 total)

import Foundation

/// A named device refusal. The device logs the name and still answers the
/// guest with the mapped virtio-gpu error response when the descriptor's
/// write buffers can hold it — pool exhaustion, a bad reserved bit and an
/// out-of-envelope command are all refused, never silently ignored.
public enum GPU3DRefusal: Error, Equatable {
    /// Read buffers held fewer bytes than the fixed request length.
    case truncatedRequest
    /// A fixed-size request carried more bytes than the envelope allows.
    case trailingBytes
    /// A reserved/padding field, the ring index or an unknown flag bit
    /// was nonzero.
    case reservedBits
    /// The type word is not a virtio-gpu command at all.
    case unknownCommand(UInt32)
    /// A real virtio-gpu command that the private profile does not carry
    /// (2D scanout, cursor, blob, UUID, EDID, ...).
    case unsupportedCommand(UInt32)
    /// ctx_id was 0 or did not name a live context.
    case invalidContext
    /// CTX_CREATE for a ctx_id that is already live.
    case duplicateContext
    /// A third live context (the profile's bound is 2).
    case contextSlotsFull
    /// Wrong cap-set index, id or version.
    case invalidCapset
    /// A bounded field sat outside the profile's limits.
    case invalidParameter
    /// resource_id was 0 or did not name a live resource in the context.
    case invalidResource
    /// RESOURCE_CREATE_3D for a resource_id already live in the context.
    case duplicateResource
    /// A context already holds the profile's maximum of 2 resources.
    case resourceLimit
    /// A second deferred request arrived while one was outstanding
    /// (the profile allows at most one device request in flight).
    case deviceBusy
    /// The request needed a fence (deferred completion) but had none.
    case fenceRequired
    /// No renderer is attached — ready=0 was advertised and draw,
    /// transfer and submit refuse.
    case backendUnavailable
    /// The attached backend declined the operation.
    case backendRefused
    /// The element's write buffers could not hold the full response.
    case responseSpaceShort
    /// COMPUTE_SUBMIT's kernel_id is outside the advertised kernels_mask
    /// (M111, ADR 0053 D2/D3 — the library is GEMM/SOFTMAX/DEQUANT only).
    case unknownKernel
    /// A kernel descriptor's dims, flags or aux break the kernel's pinned
    /// shape (bounds, reserved bits, absent-slot discipline).
    case badKernelShape
    /// A kernel-descriptor buffer slot names no attached buffer of this
    /// context, or the declared tensor overruns the buffer's extent.
    case badKernelBinding
}

public enum GPU3DWire {
    // ---- Device identity (approved in #2160) ------------------------------
    /// Vendor-defined custom-Virtio device ID; PCI DID = 0x1040 + 0x43
    /// = 0x1083, so the guest sees 1af4:1083 beside the native 2D GPU
    /// (1af4:1050) and the existing custom channel (1af4:1082).
    public static let deviceID: UInt16 = 0x43
    public static let pciDID: UInt16 = 0x1040 + deviceID
    /// Display-controller class/subclass, matching virtio-gpu identity.
    public static let pciClass: UInt8 = 0x03
    public static let pciSubclass: UInt8 = 0x00
    /// Control queue + cursor queue, the virtio-gpu shape. Only queue 0
    /// carries the commands below.
    public static let queueCount: UInt16 = 2
    /// Offered as an OPTIONAL feature bit (the private capability match is
    /// what is mandatory — a stock device cannot bind this profile).
    public static let featureVirgl: UInt32 = 0x1

    // ---- Private capability profile ("VIR1") ------------------------------
    public static let capsetID: UInt32 = 0x5649_5231 // "VIR1" LE
    public static let capsetVersion: UInt32 = 1
    /// Eight LE u32 words.
    public static let capsetPayloadSize: UInt32 = 32
    /// GET_CAPSET_INFO answers exactly one index.
    public static let capsetIndex: UInt32 = 0

    // ---- Fixed profile bounds (#2160 item 3) ------------------------------
    public static let maxWidth: UInt32 = 256
    public static let maxHeight: UInt32 = 192
    public static let maxContexts = 2
    public static let maxResourcesPerContext = 2
    public static let maxSubmitBytes: UInt32 = 4096
    /// The fixed pair of original shaders the (future) Metal backend
    /// recognizes; no arbitrary shader input ever crosses this device.
    public static let shaderPair: UInt32 = 1
    /// A 256×192 BGRA frame may need many backing entries; this bounds the
    /// ATTACH_BACKING list so a guest cannot stream unbounded descriptor
    /// tables into the device.
    public static let maxBackingEntries = 256

    // ---- Envelope geometry -------------------------------------------------
    public static let hdrLen = 24
    public static let flagFence: UInt32 = 0x1
    public static let getCapsetInfoLen = 32
    public static let getCapsetLen = 32
    public static let ctxCreateLen = 96
    public static let ctxDestroyLen = hdrLen
    public static let ctxResourceLen = 28
    public static let resourceCreate3DLen = 72
    public static let transfer3DLen = 72
    public static let submit3DHdrLen = 32
    public static let attachBackingHdrLen = 32
    public static let backingEntryLen = 16
    public static let unrefLen = 28
    /// virtio-gpu device-specific config space: events_read, events_clear,
    /// num_scanouts, num_capsets — four LE u32. This device has no scanout
    /// (the 2D compositor owns pixels); num_capsets is 1 with no compute
    /// backend attached and 2 when the device carries one (M111, ADR 0053
    /// D1 — the guest probes index 1 for VIC1 and refuses compute on a
    /// single-capset device).
    public static let deviceConfigBytes: [UInt8] = deviceConfigBytes(numCapsets: 1)

    public static func deviceConfigBytes(numCapsets: UInt32) -> [UInt8] {
        [
            0, 0, 0, 0, // events_read
            0, 0, 0, 0, // events_clear
            0, 0, 0, 0, // num_scanouts = 0 (render-only device)
            UInt8(numCapsets & 0xff), 0, 0, 0, // num_capsets
        ]
    }

    // ---- The VIC1 compute capset (M111, ADR 0053 D1) -------------------------
    /// GET_CAPSET_INFO index 1 reports the compute profile; "VIC1" packed
    /// the VIR1 way (u32 0x56494331, wire bytes 31 43 49 56).
    public static let capsetVIC1: UInt32 = 0x5649_4331
    public static let vic1Index: UInt32 = 1
    public static let vic1Version: UInt32 = 1
    public static let vic1PayloadSize: UInt32 = 32
    // The pinned VIC1 bound words (ADR 0053 D1).
    public static let vic1MaxBuffersPerCtx: UInt32 = 16
    public static let vic1MaxBufferBytes: UInt32 = 16 * 1024 * 1024
    public static let vic1KernelsMask: UInt32 = 7 // bit0 GEMM, bit1 SOFTMAX, bit2 DEQUANT
    public static let vic1MaxDim: UInt32 = 4096
    public static let vic1MaxElems: UInt32 = 1 << 24
    /// SOFTMAX's wider column bound (the tiny-model vocab head, D3).
    public static let vic1SoftmaxMaxCols: UInt32 = 49152
    /// DEQUANT's group-count bound: groups = ceil(n / group_size) ≤ 2^19.
    public static let vic1MaxGroups: UInt32 = 1 << 19
    /// The pinned 2-D extent bound (D3): GEMM's M*N and SOFTMAX's
    /// rows*cols both stay ≤ 2^22 elements — 8 MiB of f16 / 16 MiB of
    /// f32, always inside one max-size buffer.
    public static let vic1Max2DElems: UInt32 = 1 << 22

    /// The VIC1 capset payload: eight LE u32 words; `ready` reports whether
    /// a compute-capable backend is attached.
    public static func vic1CapsetPayload(ready: Bool) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Int(vic1PayloadSize))
        for word in [vic1Version, vic1MaxBuffersPerCtx, vic1MaxBufferBytes,
                     vic1KernelsMask, vic1MaxDim, vic1MaxElems, 0,
                     ready ? 1 : 0] {
            pushU32(word, into: &out)
        }
        return out
    }

    /// GET_CAPSET_INFO payload for either capset index.
    public static func capsetInfoPayload(capsetID: UInt32, version: UInt32, size: UInt32) -> [UInt8] {
        var out = [UInt8]()
        pushU32(capsetID, into: &out)
        pushU32(version, into: &out)
        pushU32(size, into: &out)
        pushU32(0, into: &out)
        return out
    }

    // ---- Command types (virtio-gpu numbering) ------------------------------
    public static let cmdGetCapsetInfo: UInt32 = 0x0108
    public static let cmdGetCapset: UInt32 = 0x0109
    public static let cmdCtxCreate: UInt32 = 0x0200
    public static let cmdCtxDestroy: UInt32 = 0x0201
    public static let cmdCtxAttachResource: UInt32 = 0x0202
    public static let cmdCtxDetachResource: UInt32 = 0x0203
    public static let cmdResourceCreate3D: UInt32 = 0x0204
    public static let cmdTransferToHost3D: UInt32 = 0x0205
    public static let cmdTransferFromHost3D: UInt32 = 0x0206
    public static let cmdSubmit3D: UInt32 = 0x0207
    public static let cmdResourceUnref: UInt32 = 0x0102
    public static let cmdResourceAttachBacking: UInt32 = 0x0106
    public static let cmdResourceDetachBacking: UInt32 = 0x0107
    /// The one private compute command (M111, ADR 0053 D2): 0x0400 sits
    /// outside the standard virtio-gpu range (0x0100–0x0301) and outside
    /// `unsupportedTypes` — a stock device calls it unknownCommand, this
    /// one validates and runs it. The request is hdr + the 64-byte
    /// frozen kernel descriptor = 88 bytes.
    public static let cmdComputeSubmit: UInt32 = 0x0400
    public static let computeSubmitLen = hdrLen + kernelDescLen
    public static let kernelDescLen = 64

    // ---- The frozen 64-byte kernel descriptor (ADR 0053 D3) ------------------
    //   off  size  field
    //   0    4     kernel_id   1 GEMM, 2 SOFTMAX, 3 DEQUANT
    //   4    4     flags       per-kernel bits; undefined bits must be 0
    //   8    4     d0          dim 0 (GEMM M / SOFTMAX rows / DEQUANT n)
    //   12   4     d1          dim 1 (GEMM N / SOFTMAX cols / DEQUANT group_size)
    //   16   4     d2          dim 2 (GEMM K / else 0)
    //   20   4     aux         DEQUANT fmt in byte 0; else 0
    //   24   32    bufs[4]     {u32 res_id, u32 byte_off} — resource ids on
    //                          the wire (the guest broker translated its
    //                          handles already); slot 3 absent = {0,0}
    //   56   8     reserved    always 0
    public struct KernelDesc: Equatable {
        /// One buffer binding: res_id + byte_off; the all-zero pair means
        /// "slot absent" (the guest broker translated its handles into
        /// res_ids before encoding).
        public struct Buf: Equatable {
            public var buf: UInt32 = 0
            public var byteOff: UInt32 = 0
            public init(buf: UInt32 = 0, byteOff: UInt32 = 0) {
                self.buf = buf
                self.byteOff = byteOff
            }
        }
        public var kernelID: UInt32 = 0
        public var flags: UInt32 = 0
        public var d0: UInt32 = 0
        public var d1: UInt32 = 0
        public var d2: UInt32 = 0
        public var aux: UInt32 = 0
        public var bufs: [Buf] = [Buf(), Buf(), Buf(), Buf()]
        public var reserved: UInt64 = 0

        public init() {}
    }

    public static let kernelGEMM: UInt32 = 1
    public static let kernelSoftmax: UInt32 = 2
    public static let kernelDequant: UInt32 = 3
    /// GEMM flag bits.
    public static let gemmFlagBias: UInt32 = 1
    public static let gemmFlagBTransposed: UInt32 = 2
    /// SOFTMAX flag bit 0: the caller declared in == out.
    public static let softmaxFlagInPlace: UInt32 = 1
    /// DEQUANT `aux` byte 0: i8 symmetric (scales only) or u4 asymmetric
    /// (scales + zeros).
    public static let dequantFmtI8Sym: UInt32 = 1
    public static let dequantFmtU4Asym: UInt32 = 2
    public static let dequantGroupSizes: Set<UInt32> = [32, 64, 128]

    /// virtio-gpu commands that exist but sit outside this private
    /// profile — 2D scanout/resource, cursor, EDID, UUID and blob paths
    /// all refuse as unsupported, not unknown.
    public static let unsupportedTypes: Set<UInt32> = [
        0x0100, // GET_DISPLAY_INFO — the native 2D device owns scanouts
        0x0101, // RESOURCE_CREATE_2D
        0x0103, // SET_SCANOUT
        0x0104, // RESOURCE_FLUSH
        0x0105, // TRANSFER_TO_HOST_2D
        0x010a, // GET_EDID
        0x010b, // RESOURCE_ASSIGN_UUID
        0x010c, // RESOURCE_CREATE_BLOB (Venus machinery — not this profile)
        0x010d, // SET_SCANOUT_BLOB
        0x0208, // RESOURCE_MAP_BLOB
        0x0209, // RESOURCE_UNMAP_BLOB
        0x0300, // UPDATE_CURSOR
        0x0301, // MOVE_CURSOR
    ]

    // ---- Response types ----------------------------------------------------
    public static let respOkNoData: UInt32 = 0x1100
    public static let respOkCapsetInfo: UInt32 = 0x1102
    public static let respOkCapset: UInt32 = 0x1103
    public static let respErrUnspec: UInt32 = 0x1200
    public static let respErrOutOfMemory: UInt32 = 0x1201
    public static let respErrInvalidResourceID: UInt32 = 0x1203
    public static let respErrInvalidContextID: UInt32 = 0x1204
    public static let respErrInvalidParameter: UInt32 = 0x1205

    // ---- Little-endian cursor ---------------------------------------------
    /// Bounds-checked LE reader; every field access is explicit.
    struct Reader {
        let bytes: [UInt8]
        var pos = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func u8() -> UInt8? {
            guard pos + 1 <= bytes.count else { return nil }
            defer { pos += 1 }
            return bytes[pos]
        }

        mutating func u32() -> UInt32? {
            guard pos + 4 <= bytes.count else { return nil }
            defer { pos += 4 }
            return UInt32(bytes[pos])
                | UInt32(bytes[pos + 1]) << 8
                | UInt32(bytes[pos + 2]) << 16
                | UInt32(bytes[pos + 3]) << 24
        }

        mutating func u64() -> UInt64? {
            guard pos + 8 <= bytes.count else { return nil }
            defer { pos += 8 }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[pos + i]) << (8 * i) }
            return v
        }

        mutating func take(_ n: Int) -> [UInt8]? {
            guard pos + n <= bytes.count else { return nil }
            defer { pos += n }
            return Array(bytes[pos..<(pos + n)])
        }
    }

    static func pushU8(_ v: UInt8, into out: inout [UInt8]) { out.append(v) }

    static func pushU32(_ v: UInt32, into out: inout [UInt8]) {
        out.append(UInt8(v & 0xff))
        out.append(UInt8((v >> 8) & 0xff))
        out.append(UInt8((v >> 16) & 0xff))
        out.append(UInt8((v >> 24) & 0xff))
    }

    static func pushU64(_ v: UInt64, into out: inout [UInt8]) {
        for i in 0..<8 { out.append(UInt8((v >> (8 * i)) & 0xff)) }
    }

    /// Are bytes `range` of `bytes` all zero? Out-of-range reads fail.
    static func isZeroed(_ bytes: [UInt8], range: Range<Int>) -> Bool {
        guard range.upperBound <= bytes.count else { return false }
        for i in range where bytes[i] != 0 { return false }
        return true
    }

    // ---- Header -------------------------------------------------------------

    /// virtio_gpu_ctrl_hdr, decoded. `reservedOK` records the envelope
    /// hygiene bits (ring_idx/padding zero, only FENCE in flags) so the
    /// decoder can name the refusal.
    public struct Header: Equatable {
        public let type: UInt32
        public let flags: UInt32
        public let fenceID: UInt64
        public let ctxID: UInt32
        public let ringIdx: UInt8
        public var fenceRequested: Bool { flags & flagFence != 0 }
    }

    /// Decode just the 24-byte header. Ring index and the three padding
    /// bytes MUST be zero; FENCE is the only flag the profile carries.
    public static func decodeHeader(_ bytes: [UInt8]) -> Result<Header, GPU3DRefusal> {
        guard bytes.count >= hdrLen else { return .failure(.truncatedRequest) }
        var r = Reader(bytes)
        guard let type = r.u32(), let flags = r.u32(), let fence = r.u64(),
              let ctx = r.u32(), let ring = r.u8() else {
            return .failure(.truncatedRequest)
        }
        guard let pad = r.take(3) else { return .failure(.truncatedRequest) }
        guard flags & ~flagFence == 0, ring == 0, pad == [0, 0, 0] else {
            return .failure(.reservedBits)
        }
        return .success(Header(type: type, flags: flags, fenceID: fence,
                               ctxID: ctx, ringIdx: ring))
    }

    /// Lenient header read used ONLY to echo fields into an error
    /// response: raw field values without the reserved-bits checks, or
    /// nil when fewer than 24 bytes were received.
    public static func peekHeader(_ bytes: [UInt8]) -> Header? {
        guard bytes.count >= hdrLen else { return nil }
        var r = Reader(bytes)
        guard let type = r.u32(), let flags = r.u32(), let fence = r.u64(),
              let ctx = r.u32(), let ring = r.u8() else { return nil }
        return Header(type: type, flags: flags & flagFence,
                      fenceID: fence, ctxID: ctx, ringIdx: ring)
    }

    /// Encode a 24-byte header. `fenceRequested` echoes the guest's FENCE
    /// flag and fence_id; both are zero when no fence was requested.
    public static func encodeHeader(type: UInt32, fenceRequested: Bool,
                                    fenceID: UInt64, ctxID: UInt32) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(hdrLen)
        pushU32(type, into: &out)
        pushU32(fenceRequested ? flagFence : 0, into: &out)
        pushU64(fenceRequested ? fenceID : 0, into: &out)
        pushU32(ctxID, into: &out)
        pushU8(0, into: &out) // ring_idx
        out.append(contentsOf: [0, 0, 0]) // padding
        return out
    }

    /// A full response: echoed header fields plus an optional payload.
    /// The guest's fence ID and context ID always match the request
    /// (#2160 item 4).
    public static func encodeResponse(type: UInt32, request hdr: Header?,
                                      payload: [UInt8] = []) -> [UInt8] {
        var out = encodeHeader(type: type,
                               fenceRequested: hdr?.fenceRequested ?? false,
                               fenceID: hdr?.fenceID ?? 0,
                               ctxID: hdr?.ctxID ?? 0)
        out.append(contentsOf: payload)
        return out
    }

    /// The private capability payload: eight LE u32 words. `ready` is the
    /// only word that varies — it reports whether a renderer backend is
    /// attached (a nil backend always advertises ready=0).
    public static func capsetPayload(ready: Bool) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Int(capsetPayloadSize))
        for word in [capsetVersion, maxWidth, maxHeight,
                     UInt32(maxContexts), UInt32(maxResourcesPerContext),
                     maxSubmitBytes, shaderPair, ready ? 1 : 0] {
            pushU32(word, into: &out)
        }
        return out
    }

    /// The GET_CAPSET_INFO payload: capset id, max version, max size, pad.
    public static func capsetInfoPayload() -> [UInt8] {
        var out = [UInt8]()
        pushU32(capsetID, into: &out)
        pushU32(capsetVersion, into: &out)
        pushU32(capsetPayloadSize, into: &out)
        pushU32(0, into: &out)
        return out
    }

    // ---- Request payloads ----------------------------------------------------

    public struct CtxCreate: Equatable {
        public let name: String
        public let nlen: UInt32
    }

    public struct ResourceCreate: Equatable {
        public let resourceID: UInt32
        public let target: UInt32
        public let format: UInt32
        public let bind: UInt32
        public let width: UInt32
        public let height: UInt32
        public let depth: UInt32
        public let arraySize: UInt32
        public let lastLevel: UInt32
        public let nrSamples: UInt32
        public let flags: UInt32
    }

    /// virtio_gpu_box: x, y, z, w, h, d — six LE u32.
    public struct Box: Equatable {
        public let x, y, z, w, h, d: UInt32
    }

    public struct Transfer: Equatable {
        public let ctxID: UInt32
        public let resourceID: UInt32
        public let box: Box
        public let offset: UInt64
        public let level: UInt32
        public let stride: UInt32
        public let layerStride: UInt32
    }

    /// One ATTACH_BACKING entry: a guest physical address range.
    public struct BackingEntry: Equatable {
        public let address: UInt64
        public let length: UInt32
    }

    /// A fully validated command. The decoder produces these ONLY for
    /// well-formed envelopes; every malformed byte stream is a named
    /// GPU3DRefusal instead.
    public enum Command: Equatable {
        case getCapsetInfo(index: UInt32)
        case getCapset(id: UInt32, version: UInt32)
        case ctxCreate(CtxCreate)
        case ctxDestroy
        case ctxAttachResource(resourceID: UInt32)
        case ctxDetachResource(resourceID: UInt32)
        case resourceCreate3D(ResourceCreate)
        case resourceUnref(resourceID: UInt32)
        case resourceAttachBacking(resourceID: UInt32, entries: [BackingEntry])
        case resourceDetachBacking(resourceID: UInt32)
        case transferToHost3D(Transfer)
        case transferFromHost3D(Transfer)
        case submit3D(stream: [UInt8])
        /// The one compute command: hdr + the verbatim 64-byte kernel
        /// descriptor (semantic validation is the dispatcher's job — the
        /// same split the kernel broker uses).
        case computeSubmit(KernelDesc)
    }

    /// A decoded request: the (already validated) header plus command.
    public struct Request: Equatable {
        public let header: Header
        public let command: Command
    }

    // ---- Decoder ---------------------------------------------------------------
    /// Decode and fully validate one request element's read bytes. Returns
    /// the named refusal on the FIRST envelope violation; the device adds
    /// state-dependent refusals (live context, slots, backend) at dispatch.
    public static func decode(_ bytes: [UInt8]) -> Result<Request, GPU3DRefusal> {
        let hdr: Header
        switch decodeHeader(bytes) {
        case .failure(let why): return .failure(why)
        case .success(let h): hdr = h
        }

        /// Fixed-size commands: the element must carry exactly the envelope
        /// — a short read truncates, a long one is trailing garbage.
        func fixed(_ total: Int) -> Result<Void, GPU3DRefusal> {
            if bytes.count < total { return .failure(.truncatedRequest) }
            if bytes.count > total { return .failure(.trailingBytes) }
            return .success(())
        }
        func padWord(_ at: Int) -> Bool {
            isZeroed(bytes, range: at..<(at + 4))
        }

        var r = Reader(bytes)
        r.pos = hdrLen
        let cmd: Command
        switch hdr.type {
        case cmdGetCapsetInfo:
            if case .failure(let f) = fixed(getCapsetInfoLen) { return .failure(f) }
            guard let index = r.u32() else { return .failure(.truncatedRequest) }
            guard padWord(28) else { return .failure(.reservedBits) }
            cmd = .getCapsetInfo(index: index)

        case cmdGetCapset:
            if case .failure(let f) = fixed(getCapsetLen) { return .failure(f) }
            guard let id = r.u32(), let version = r.u32() else {
                return .failure(.truncatedRequest)
            }
            cmd = .getCapset(id: id, version: version)

        case cmdCtxCreate:
            if case .failure(let f) = fixed(ctxCreateLen) { return .failure(f) }
            guard let nlen = r.u32(), let contextInit = r.u32(),
                  let nameBytes = r.take(64) else {
                return .failure(.truncatedRequest)
            }
            // context_init is Venus-era machinery; the private profile
            // requires it zero. nlen must fit the fixed field and every
            // byte past the name is reserved-zero.
            guard contextInit == 0 else { return .failure(.reservedBits) }
            guard nlen <= 64 else { return .failure(.invalidParameter) }
            guard isZeroed(nameBytes, range: Int(nlen)..<64) else {
                return .failure(.reservedBits)
            }
            let name = String(bytes: nameBytes[0..<Int(nlen)], encoding: .utf8)
                ?? String(repeating: "?", count: Int(nlen))
            cmd = .ctxCreate(CtxCreate(name: name, nlen: nlen))

        case cmdCtxDestroy:
            if case .failure(let f) = fixed(ctxDestroyLen) { return .failure(f) }
            cmd = .ctxDestroy

        case cmdCtxAttachResource, cmdCtxDetachResource:
            if case .failure(let f) = fixed(ctxResourceLen) { return .failure(f) }
            guard let resourceID = r.u32() else { return .failure(.truncatedRequest) }
            guard resourceID != 0 else { return .failure(.invalidResource) }
            cmd = hdr.type == cmdCtxAttachResource
                ? .ctxAttachResource(resourceID: resourceID)
                : .ctxDetachResource(resourceID: resourceID)

        case cmdResourceCreate3D:
            if case .failure(let f) = fixed(resourceCreate3DLen) { return .failure(f) }
            guard let resourceID = r.u32(), let target = r.u32(),
                  let format = r.u32(), let bind = r.u32(),
                  let width = r.u32(), let height = r.u32(),
                  let depth = r.u32(), let arraySize = r.u32(),
                  let lastLevel = r.u32(), let nrSamples = r.u32(),
                  let flags = r.u32() else {
                return .failure(.truncatedRequest)
            }
            guard padWord(68) else { return .failure(.reservedBits) }
            guard resourceID != 0 else { return .failure(.invalidResource) }
            // The profile's pinned bounds: 1..256 × 1..192, one plane,
            // single sample, no mip tail, no create flags. M111 (ADR 0053
            // D4): a target_buffer resource is a flat 1-D byte range —
            // "width" is the byte size bounded by VIC1's 16 MiB; height
            // 1, one plane, no format/mip/sample semantics. bind is 16
            // (VIRTIO_GPU_BIND_VERTEX — the render path's VBO) or 0 (the
            // compute path's anonymous byte window).
            if target == 0 {
                guard width >= 1, width <= vic1MaxBufferBytes,
                      height == 1, depth == 1, arraySize == 1,
                      lastLevel == 0, nrSamples == 0,
                      format == 0, flags == 0,
                      bind == 0 || bind == 16 else {
                    return .failure(.invalidParameter)
                }
            } else {
                guard width >= 1, width <= maxWidth,
                      height >= 1, height <= maxHeight,
                      depth <= 1, arraySize <= 1, lastLevel <= 1,
                      nrSamples <= 1, flags == 0 else {
                    return .failure(.invalidParameter)
                }
            }
            cmd = .resourceCreate3D(ResourceCreate(
                resourceID: resourceID, target: target, format: format,
                bind: bind, width: width, height: height, depth: depth,
                arraySize: arraySize, lastLevel: lastLevel,
                nrSamples: nrSamples, flags: flags))

        case cmdResourceUnref, cmdResourceDetachBacking:
            if case .failure(let f) = fixed(unrefLen) { return .failure(f) }
            // The frozen 28B res-op is header + u32 resource_id — there
            // is no trailing pad word to check (bytes 24-27 ARE the id;
            // a pad check there would reject every nonzero resource).
            guard let resourceID = r.u32() else { return .failure(.truncatedRequest) }
            guard resourceID != 0 else { return .failure(.invalidResource) }
            cmd = hdr.type == cmdResourceUnref
                ? .resourceUnref(resourceID: resourceID)
                : .resourceDetachBacking(resourceID: resourceID)

        case cmdResourceAttachBacking:
            guard bytes.count >= attachBackingHdrLen else {
                return .failure(.truncatedRequest)
            }
            guard let resourceID = r.u32(), let nrEntries = r.u32() else {
                return .failure(.truncatedRequest)
            }
            guard resourceID != 0 else { return .failure(.invalidResource) }
            guard nrEntries >= 1, nrEntries <= maxBackingEntries else {
                return .failure(.invalidParameter)
            }
            let total = attachBackingHdrLen + Int(nrEntries) * backingEntryLen
            if bytes.count < total { return .failure(.truncatedRequest) }
            if bytes.count > total { return .failure(.trailingBytes) }
            var entries: [BackingEntry] = []
            for _ in 0..<nrEntries {
                guard let address = r.u64(), let length = r.u32(),
                      let pad = r.u32() else {
                    return .failure(.truncatedRequest)
                }
                guard pad == 0 else { return .failure(.reservedBits) }
                entries.append(BackingEntry(address: address, length: length))
            }
            cmd = .resourceAttachBacking(resourceID: resourceID, entries: entries)

        case cmdTransferToHost3D, cmdTransferFromHost3D:
            if case .failure(let f) = fixed(transfer3DLen) { return .failure(f) }
            guard let x = r.u32(), let y = r.u32(), let z = r.u32(),
                  let w = r.u32(), let h = r.u32(), let d = r.u32(),
                  let offset = r.u64(), let resourceID = r.u32(),
                  let level = r.u32(), let stride = r.u32(),
                  let layerStride = r.u32() else {
                return .failure(.truncatedRequest)
            }
            guard resourceID != 0 else { return .failure(.invalidResource) }
            guard w >= 1, h >= 1, d >= 1 else { return .failure(.invalidParameter) }
            let t = Transfer(ctxID: hdr.ctxID, resourceID: resourceID,
                             box: Box(x: x, y: y, z: z, w: w, h: h, d: d),
                             offset: offset, level: level, stride: stride,
                             layerStride: layerStride)
            cmd = hdr.type == cmdTransferToHost3D
                ? .transferToHost3D(t) : .transferFromHost3D(t)

        case cmdComputeSubmit:
            if case .failure(let f) = fixed(computeSubmitLen) { return .failure(f) }
            var kd = KernelDesc()
            guard let kID = r.u32(), let kflags = r.u32(),
                  let d0 = r.u32(), let d1 = r.u32(), let d2 = r.u32(),
                  let aux = r.u32() else {
                return .failure(.truncatedRequest)
            }
            for i in 0..<4 {
                guard let buf = r.u32(), let off = r.u32() else {
                    return .failure(.truncatedRequest)
                }
                kd.bufs[i] = .init(buf: buf, byteOff: off)
            }
            guard let reserved = r.u64() else { return .failure(.truncatedRequest) }
            guard reserved == 0 else { return .failure(.reservedBits) }
            kd.kernelID = kID
            kd.flags = kflags
            kd.d0 = d0
            kd.d1 = d1
            kd.d2 = d2
            kd.aux = aux
            cmd = .computeSubmit(kd)

        case cmdSubmit3D:
            guard bytes.count >= submit3DHdrLen else {
                return .failure(.truncatedRequest)
            }
            guard let size = r.u32() else { return .failure(.truncatedRequest) }
            guard padWord(28) else { return .failure(.reservedBits) }
            // A command stream is word-aligned and bounded (#2160 item 3).
            guard size >= 4, size <= maxSubmitBytes, size % 4 == 0 else {
                return .failure(.invalidParameter)
            }
            let total = submit3DHdrLen + Int(size)
            if bytes.count < total { return .failure(.truncatedRequest) }
            if bytes.count > total { return .failure(.trailingBytes) }
            cmd = .submit3D(stream: Array(bytes[submit3DHdrLen..<total]))

        default:
            if unsupportedTypes.contains(hdr.type) {
                return .failure(.unsupportedCommand(hdr.type))
            }
            return .failure(.unknownCommand(hdr.type))
        }

        return .success(Request(header: hdr, command: cmd))
    }
}
