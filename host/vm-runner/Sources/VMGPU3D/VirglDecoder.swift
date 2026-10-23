// VirglDecoder.swift — M102c2 (issue #2165): the independent Swift
// decoder for the frozen VirGL command stream the guest submits inside
// SUBMIT_3D. It validates the ENTIRE <= 4,096-byte stream BEFORE
// producing a frame plan — a malformed tail executes no prefix, and no
// allowlist violation ever reaches the renderer.
//
// This is an independent implementation of the shared contract pinned
// by c1's fixtures (test/fixtures/gpu3d/{triangle.words,vertex.tgsi,
// fragment.tgsi}, contract published on #2164): little-endian u32
// stream words, one header word per command packing
// cmd[7:0] | object[15:8] | payload_words[31:16] (the payload count
// EXCLUDES the header), a zero-payload NOP word as the ONLY sanctioned
// padding, and the two TGSI texts matched as complete byte strings —
// never a hash, name or token prefix.
//
// The allowlist is the frozen profile, not general VirGL: exactly the
// seven pinned object handles, the fixed state words, the two original
// shader texts, one optional CLEAR and at most one pinned non-indexed
// three-vertex TRIANGLES draw. Everything else — other commands, other
// object kinds, invented handles, mutated state words, foreign shader
// text, a second draw, leaked objects — is a named rejection.
//
// Pure Swift + Foundation: no Metal types here, so the decoder is
// pinned by `swift test` independently of GPU availability.

import Foundation

/// Why a stream was rejected. Every case names the byte offset of the
/// offending command so a rejection receipt is auditable.
public enum VirglStreamRejection: Error, Equatable {
    /// Byte count is not a multiple of 4.
    case misaligned(count: Int)
    /// Empty stream (no commands at all).
    case empty
    /// Stream exceeds the profile's 4,096-byte bound.
    case overCap(count: Int)
    /// A command's declared payload runs past the stream end.
    case truncatedCommand(offset: Int)
    /// A zero command word with a nonzero object or payload field —
    /// NOP padding is exactly 0x00000000.
    case malformedNOP(offset: Int)
    /// An opcode outside the allowlist.
    case unknownCommand(cmd: UInt32, offset: Int)
    /// An object kind outside the allowlist for create/bind/destroy.
    case unknownObject(obj: UInt32, offset: Int)
    /// A non-object command carried a nonzero object field.
    case objectFieldSet(cmd: UInt32, offset: Int)
    /// Declared payload words do not equal the pinned arity.
    case badArity(cmd: UInt32, obj: UInt32, declared: Int, expected: Int, offset: Int)
    /// A pinned field held a wrong value (word index within payload).
    case badField(cmd: UInt32, obj: UInt32, payloadWord: Int, offset: Int)
    /// The pinned handle for this object kind was not used, or the
    /// handle is already live.
    case badHandle(handle: UInt32, obj: UInt32, offset: Int)
    /// bind/destroy named a handle that is not live (never created or
    /// already destroyed).
    case deadHandle(handle: UInt32, offset: Int)
    /// A shader object's handle did not match its declared type
    /// (6 = vertex, 7 = fragment).
    case shaderHandleType(handle: UInt32, type: UInt32, offset: Int)
    /// offset/num_tokens did not equal the text dword count, or the
    /// text lacked its NUL terminator/padding.
    case shaderFraming(offset: Int)
    /// The shader text is not byte-identical to the pinned fixture for
    /// its type — complete-text match, no hashing or prefixes.
    case shaderText(offset: Int)
    /// A shader type outside vertex/fragment, or a resource id that
    /// names no live resource of the required kind.
    case badReference(offset: Int)
    /// A command whose preconditions were unmet (draw without bound
    /// state, second draw, draw/clear before framebuffer state).
    case unmetPrecondition(cmd: UInt32, offset: Int)
    /// The stream ended with live objects — the profile returns the
    /// object table to baseline every frame.
    case leakedObjects(count: Int)
}

/// The command opcodes the private profile carries (virgl_ccmd subset).
public enum VirglStreamCmd {
    public static let nop: UInt32 = 0
    public static let createObject: UInt32 = 1
    public static let bindObject: UInt32 = 2
    public static let destroyObject: UInt32 = 3
    public static let setViewportState: UInt32 = 4
    public static let setFramebufferState: UInt32 = 5
    public static let setVertexBuffers: UInt32 = 6
    public static let clear: UInt32 = 7
    public static let drawVbo: UInt32 = 8
    public static let bindShader: UInt32 = 30
}

/// The object kinds the private profile allows.
public enum VirglStreamObject {
    public static let blend: UInt32 = 1
    public static let rasterizer: UInt32 = 2
    public static let dsa: UInt32 = 3
    public static let shader: UInt32 = 4
    public static let vertexElements: UInt32 = 5
    public static let surface: UInt32 = 8
}

/// Wire constants shared with the frozen profile (virgl_hw numbering):
/// B8G8R8A8_UNORM, R32G32B32A32_FLOAT, pipe 2D/buffer targets, TRIANGLES,
/// PIPE_CLEAR_COLOR0 and the vertex/fragment stage ids.
public enum VirglStreamConst {
    public static let formatBGRA8: UInt32 = 1
    public static let formatRGBA32F: UInt32 = 31
    public static let targetBuffer: UInt32 = 0
    public static let target2D: UInt32 = 2
    public static let shaderVertex: UInt32 = 0
    public static let shaderFragment: UInt32 = 1
    public static let primTriangles: UInt32 = 4
    public static let clearColor0: UInt32 = 1
    public static let vertexStride: UInt32 = 32
    public static let vertexCount: UInt32 = 3
    public static let maxStreamBytes = 4096

    /// The pinned object handles: one per kind, fixed by the profile.
    public static let handleSurface: UInt32 = 1
    public static let handleVertexElements: UInt32 = 2
    public static let handleBlend: UInt32 = 3
    public static let handleRasterizer: UInt32 = 4
    public static let handleDSA: UInt32 = 5
    public static let handleVertexShader: UInt32 = 6
    public static let handleFragmentShader: UInt32 = 7

    /// The two original TGSI texts the Metal backend recognizes —
    /// complete byte strings identical to the committed fixtures
    /// (LF-terminated lines, `END\n` final, no trailing NUL in the
    /// text itself; the wire appends the NUL + pad).
    public static let vertexShaderText =
        "VERT\n" +
        "DCL IN[0]\n" +
        "DCL IN[1]\n" +
        "DCL OUT[0], POSITION\n" +
        "DCL OUT[1], COLOR\n" +
        "MOV OUT[0], IN[0]\n" +
        "MOV OUT[1], IN[1]\n" +
        "END\n"
    public static let fragmentShaderText =
        "FRAG\n" +
        "DCL IN[0], COLOR\n" +
        "DCL OUT[0], COLOR\n" +
        "MOV OUT[0], IN[0]\n" +
        "END\n"

    /// Pinned fixed-state words: per-target blend word (blend disabled,
    /// src factor ONE, colormask RGBA) and rasterizer s0 (depth_clip +
    /// front_ccw, no cull).
    public static let blendRTWord: UInt32 = (1 << 4) | (1 << 17) | (0xf << 27)
    public static let rasterizerS0: UInt32 = (1 << 1) | (1 << 15)
}

/// A fully validated frame: the ONLY thing the renderer may act on.
/// Nothing is produced for a rejected stream — there is no partial
/// plan, so a malformed tail cannot execute a valid prefix.
public struct VirglDecodedFrame: Equatable {
    /// The image resource the framebuffer state selected.
    public let colorResourceID: UInt32
    /// The buffer resource the vertex-buffer state selected.
    public let vertexResourceID: UInt32
    /// Render extent implied by the pinned viewport (== the surface
    /// resource's created dims).
    public let width: UInt32
    public let height: UInt32
    /// The CLEAR color (RGBA) when the stream clears; nil otherwise.
    public let clearColor: SIMD4<Float>?
    /// Whether the stream carries the pinned draw (exactly one
    /// non-indexed three-vertex TRIANGLES draw or none).
    public let drawsTriangle: Bool
    /// How many commands the stream carried (NOP padding excluded).
    public let commandCount: Int
}

/// The validating decoder. `decode` performs two disjoint passes over
/// the stream: a structural walk that bounds every declared payload,
/// then a semantic replay against the allowlist — and only then emits
/// the frame plan. Validation never mutates renderer state; it either
/// returns a complete plan or a named rejection.
public enum VirglStreamDecoder {

    /// One structurally bounded command: header fields plus the byte
    /// range of its payload inside the stream.
    struct Command {
        let offset: Int
        let cmd: UInt32
        let obj: UInt32
        let payload: Range<Int> // byte range, word aligned
    }

    /// Pass 1 — structural walk. Every declared payload must lie inside
    /// the stream; NOP is exactly the zero word.
    static func walk(_ stream: [UInt8]) -> Result<[Command], VirglStreamRejection> {
        if stream.isEmpty { return .failure(.empty) }
        if stream.count % 4 != 0 { return .failure(.misaligned(count: stream.count)) }
        if stream.count > VirglStreamConst.maxStreamBytes {
            return .failure(.overCap(count: stream.count))
        }
        var out: [Command] = []
        var at = 0
        var tailStarted = false
        while at < stream.count {
            let h = u32(stream, at)
            let cmd = h & 0xff
            let obj = (h >> 8) & 0xff
            let len = Int(h >> 16)
            let start = at + 4
            guard start + len * 4 <= stream.count else {
                return .failure(.truncatedCommand(offset: at))
            }
            if cmd == VirglStreamCmd.nop {
                // NOP is exactly the zero word and only pads the tail —
                // a real command may never follow padding.
                guard obj == 0, len == 0 else {
                    return .failure(.malformedNOP(offset: at))
                }
                tailStarted = true
            } else {
                guard !tailStarted else {
                    return .failure(.malformedNOP(offset: at))
                }
                out.append(Command(offset: at, cmd: cmd, obj: obj,
                                   payload: start..<(start + len * 4)))
            }
            at = start + len * 4
        }
        return .success(out)
    }

    /// Semantic replay state: object table, bindings and armed state.
    private struct Replay {
        var live: [UInt32: UInt32] = [:]      // handle -> object kind
        var shaderType: [UInt32: UInt32] = [:] // handle -> stage
        var boundObjects: [UInt32: UInt32] = [:] // kind -> handle
        var boundShaders: [UInt32: UInt32] = [:] // stage -> handle
        var framebufferArmed = false
        var viewportArmed = false
        var vboArmed = false
        var colorResourceID: UInt32 = 0
        var vertexResourceID: UInt32 = 0
        var clearColor: SIMD4<Float>?
        var draws = 0
    }

    /// Decode a whole stream against the context's live resources.
    /// `resources` maps each live resource id to its created shape —
    /// the only way a stream may name a color target or vertex buffer.
    public static func decode(
        _ stream: [UInt8],
        resources: [UInt32: GPU3DWire.ResourceCreate]
    ) -> Result<VirglDecodedFrame, VirglStreamRejection> {
        let commands: [Command]
        switch walk(stream) {
        case .failure(let why): return .failure(why)
        case .success(let list): commands = list
        }

        var r = Replay()
        var width: UInt32 = 0
        var height: UInt32 = 0

        func fail(_ why: VirglStreamRejection)
            -> Result<VirglDecodedFrame, VirglStreamRejection> { .failure(why) }
        func payloadWords(_ c: Command) -> [UInt32] {
            stride(from: c.payload.lowerBound, to: c.payload.upperBound, by: 4)
                .map { u32(stream, $0) }
        }
        func arity(_ c: Command, _ expected: Int) -> VirglStreamRejection? {
            let declared = c.payload.count / 4
            return declared == expected
                ? nil : .badArity(cmd: c.cmd, obj: c.obj, declared: declared,
                                  expected: expected, offset: c.offset)
        }

        for c in commands {
            let w = payloadWords(c)
            switch c.cmd {
            case VirglStreamCmd.createObject:
                switch c.obj {
                case VirglStreamObject.surface:
                    // handle, res, fmt=BGRA8, level 0, layer 0
                    if let e = arity(c, 5) { return fail(e) }
                    guard let res = resources[w[1]],
                          res.target == VirglStreamConst.target2D,
                          res.format == VirglStreamConst.formatBGRA8,
                          w[2] == VirglStreamConst.formatBGRA8,
                          w[3] == 0, w[4] == 0 else {
                        return fail(.badField(cmd: c.cmd, obj: c.obj,
                                              payloadWord: 1, offset: c.offset))
                    }
                    let iw = res.width, ih = res.height
                    guard w[0] == VirglStreamConst.handleSurface,
                          r.live[w[0]] == nil else {
                        return fail(.badHandle(handle: w[0], obj: c.obj, offset: c.offset))
                    }
                    r.live[w[0]] = c.obj
                    r.colorResourceID = w[1]
                    width = iw; height = ih

                case VirglStreamObject.vertexElements:
                    // handle, {src_offset, inst_div, vbo_idx, fmt} x2:
                    // position float4 @0, color float4 @16, buffer 0.
                    if let e = arity(c, 9) { return fail(e) }
                    guard w[0] == VirglStreamConst.handleVertexElements,
                          r.live[w[0]] == nil else {
                        return fail(.badHandle(handle: w[0], obj: c.obj, offset: c.offset))
                    }
                    guard w[1] == 0, w[2] == 0, w[3] == 0,
                          w[4] == VirglStreamConst.formatRGBA32F,
                          w[5] == 16, w[6] == 0, w[7] == 0,
                          w[8] == VirglStreamConst.formatRGBA32F else {
                        return fail(.badField(cmd: c.cmd, obj: c.obj,
                                              payloadWord: 1, offset: c.offset))
                    }
                    r.live[w[0]] = c.obj

                case VirglStreamObject.blend:
                    // handle, two zero words, eight pinned RT words.
                    if let e = arity(c, 11) { return fail(e) }
                    guard w[0] == VirglStreamConst.handleBlend,
                          r.live[w[0]] == nil else {
                        return fail(.badHandle(handle: w[0], obj: c.obj, offset: c.offset))
                    }
                    guard w[1] == 0, w[2] == 0,
                          w[3...10].allSatisfy({ $0 == VirglStreamConst.blendRTWord }) else {
                        return fail(.badField(cmd: c.cmd, obj: c.obj,
                                              payloadWord: 1, offset: c.offset))
                    }
                    r.live[w[0]] = c.obj

                case VirglStreamObject.rasterizer:
                    // handle, s0, then the pinned float field row.
                    if let e = arity(c, 9) { return fail(e) }
                    guard w[0] == VirglStreamConst.handleRasterizer,
                          r.live[w[0]] == nil else {
                        return fail(.badHandle(handle: w[0], obj: c.obj, offset: c.offset))
                    }
                    let one = Float(1).bitPattern
                    guard w[1] == VirglStreamConst.rasterizerS0,
                          w[2] == one, w[3] == 0, w[4] == 0,
                          w[5] == one, w[6] == 0, w[7] == 0, w[8] == 0 else {
                        return fail(.badField(cmd: c.cmd, obj: c.obj,
                                              payloadWord: 1, offset: c.offset))
                    }
                    r.live[w[0]] = c.obj

                case VirglStreamObject.dsa:
                    if let e = arity(c, 5) { return fail(e) }
                    guard w[0] == VirglStreamConst.handleDSA,
                          r.live[w[0]] == nil else {
                        return fail(.badHandle(handle: w[0], obj: c.obj, offset: c.offset))
                    }
                    guard w[1] == 0, w[2] == 0, w[3] == 0, w[4] == 0 else {
                        return fail(.badField(cmd: c.cmd, obj: c.obj,
                                              payloadWord: 1, offset: c.offset))
                    }
                    r.live[w[0]] = c.obj

                case VirglStreamObject.shader:
                    // handle, type, offset==text dwords, num_tokens==
                    // dwords, so_num_outputs 0, then text+NUL+pad.
                    guard w.count >= 5 else {
                        return fail(.badArity(cmd: c.cmd, obj: c.obj,
                                              declared: w.count, expected: 5,
                                              offset: c.offset))
                    }
                    let handle = w[0], type = w[1]
                    let wantHandle: UInt32
                    let wantText: String
                    switch type {
                    case VirglStreamConst.shaderVertex:
                        wantHandle = VirglStreamConst.handleVertexShader
                        wantText = VirglStreamConst.vertexShaderText
                    case VirglStreamConst.shaderFragment:
                        wantHandle = VirglStreamConst.handleFragmentShader
                        wantText = VirglStreamConst.fragmentShaderText
                    default:
                        return fail(.badField(cmd: c.cmd, obj: c.obj,
                                              payloadWord: 1, offset: c.offset))
                    }
                    guard handle == wantHandle, r.live[handle] == nil else {
                        return fail(.shaderHandleType(handle: handle, type: type,
                                                      offset: c.offset))
                    }
                    let textBytes = Array(wantText.utf8)
                    let textWords = (textBytes.count + 1 + 3) / 4
                    guard w[2] == textWords, w[3] == textWords, w[4] == 0,
                          w.count == 5 + textWords else {
                        return fail(.shaderFraming(offset: c.offset))
                    }
                    // Complete-text match: the carried bytes, a NUL
                    // terminator, and zero pad — nothing else.
                    var carried: [UInt8] = []
                    carried.reserveCapacity(textWords * 4)
                    for i in 5..<w.count {
                        let word = w[i]
                        carried.append(UInt8(word & 0xff))
                        carried.append(UInt8((word >> 8) & 0xff))
                        carried.append(UInt8((word >> 16) & 0xff))
                        carried.append(UInt8((word >> 24) & 0xff))
                    }
                    guard carried[0..<textBytes.count] == textBytes[...],
                          carried[textBytes.count] == 0,
                          carried[(textBytes.count + 1)...].allSatisfy({ $0 == 0 }) else {
                        return fail(.shaderText(offset: c.offset))
                    }
                    r.live[handle] = c.obj
                    r.shaderType[handle] = type

                default:
                    return fail(.unknownObject(obj: c.obj, offset: c.offset))
                }

            case VirglStreamCmd.bindShader:
                guard c.obj == 0 else {
                    return fail(.objectFieldSet(cmd: c.cmd, offset: c.offset))
                }
                if let e = arity(c, 2) { return fail(e) }
                guard r.live[w[0]] == VirglStreamObject.shader,
                      r.shaderType[w[0]] == w[1] else {
                    return fail(.deadHandle(handle: w[0], offset: c.offset))
                }
                r.boundShaders[w[1]] = w[0]

            case VirglStreamCmd.bindObject:
                if let e = arity(c, 1) { return fail(e) }
                guard r.live[w[0]] == c.obj else {
                    return fail(.deadHandle(handle: w[0], offset: c.offset))
                }
                r.boundObjects[c.obj] = w[0]

            case VirglStreamCmd.destroyObject:
                if let e = arity(c, 1) { return fail(e) }
                guard r.live[w[0]] == c.obj else {
                    return fail(.deadHandle(handle: w[0], offset: c.offset))
                }
                r.live.removeValue(forKey: w[0])
                r.shaderType.removeValue(forKey: w[0])
                if r.boundObjects[c.obj] == w[0] {
                    r.boundObjects.removeValue(forKey: c.obj)
                }
                for stage in r.boundShaders.filter({ $0.value == w[0] }).map({ $0.key }) {
                    r.boundShaders.removeValue(forKey: stage)
                }

            case VirglStreamCmd.setFramebufferState:
                guard c.obj == 0 else {
                    return fail(.objectFieldSet(cmd: c.cmd, offset: c.offset))
                }
                if let e = arity(c, 3) { return fail(e) }
                // one cbuf, no depth surface, the live surface handle.
                guard w[0] == 1, w[1] == 0,
                      r.live[w[2]] == VirglStreamObject.surface else {
                    return fail(.badField(cmd: c.cmd, obj: c.obj,
                                          payloadWord: 0, offset: c.offset))
                }
                r.framebufferArmed = true

            case VirglStreamCmd.setViewportState:
                guard c.obj == 0 else {
                    return fail(.objectFieldSet(cmd: c.cmd, offset: c.offset))
                }
                if let e = arity(c, 7) { return fail(e) }
                // start slot 0; scale {w/2, h/2, 1} translate {w/2, h/2, 0}
                // for the surface resource's created extent.
                guard r.framebufferArmed else {
                    return fail(.unmetPrecondition(cmd: c.cmd, offset: c.offset))
                }
                let w2 = (Float(width) / 2).bitPattern
                let h2 = (Float(height) / 2).bitPattern
                let one = Float(1).bitPattern
                guard w[0] == 0,
                      w[1] == w2, w[2] == h2, w[3] == one,
                      w[4] == w2, w[5] == h2, w[6] == 0 else {
                    return fail(.badField(cmd: c.cmd, obj: c.obj,
                                          payloadWord: 1, offset: c.offset))
                }
                r.viewportArmed = true

            case VirglStreamCmd.setVertexBuffers:
                guard c.obj == 0 else {
                    return fail(.objectFieldSet(cmd: c.cmd, offset: c.offset))
                }
                if let e = arity(c, 3) { return fail(e) }
                guard w[0] == VirglStreamConst.vertexStride, w[1] == 0,
                      resources[w[2]]?.target == VirglStreamConst.targetBuffer else {
                    return fail(.badReference(offset: c.offset))
                }
                r.vboArmed = true
                r.vertexResourceID = w[2]

            case VirglStreamCmd.clear:
                guard c.obj == 0 else {
                    return fail(.objectFieldSet(cmd: c.cmd, offset: c.offset))
                }
                if let e = arity(c, 8) { return fail(e) }
                guard r.framebufferArmed else {
                    return fail(.unmetPrecondition(cmd: c.cmd, offset: c.offset))
                }
                // buffers = COLOR0 only; depth f64 1.0 (LE word pair
                // 0x00000000, 0x3ff00000); stencil 0. The RGBA words
                // are the app's chosen clear color.
                guard w[0] == VirglStreamConst.clearColor0,
                      w[5] == 0, w[6] == 0x3ff0_0000, w[7] == 0 else {
                    return fail(.badField(cmd: c.cmd, obj: c.obj,
                                          payloadWord: 0, offset: c.offset))
                }
                r.clearColor = SIMD4(Float(bitPattern: w[1]), Float(bitPattern: w[2]),
                                     Float(bitPattern: w[3]), Float(bitPattern: w[4]))

            case VirglStreamCmd.drawVbo:
                guard c.obj == 0 else {
                    return fail(.objectFieldSet(cmd: c.cmd, offset: c.offset))
                }
                if let e = arity(c, 12) { return fail(e) }
                // The pinned non-indexed three-vertex triangle:
                // start 0, count 3, TRIANGLES, non-indexed, 1 instance,
                // bias/start-instance/restart 0, min 0 max 2, no so.
                let pinned: [UInt32] = [0, 3, VirglStreamConst.primTriangles,
                                        0, 1, 0, 0, 0, 0, 0, 2, 0]
                guard w == pinned else {
                    return fail(.badField(cmd: c.cmd, obj: c.obj,
                                          payloadWord: 0, offset: c.offset))
                }
                guard r.draws == 0 else {
                    return fail(.unmetPrecondition(cmd: c.cmd, offset: c.offset))
                }
                guard r.framebufferArmed, r.viewportArmed, r.vboArmed,
                      r.boundObjects[VirglStreamObject.blend] == VirglStreamConst.handleBlend,
                      r.boundObjects[VirglStreamObject.rasterizer] == VirglStreamConst.handleRasterizer,
                      r.boundObjects[VirglStreamObject.dsa] == VirglStreamConst.handleDSA,
                      r.boundObjects[VirglStreamObject.vertexElements] == VirglStreamConst.handleVertexElements,
                      r.boundShaders[VirglStreamConst.shaderVertex] == VirglStreamConst.handleVertexShader,
                      r.boundShaders[VirglStreamConst.shaderFragment] == VirglStreamConst.handleFragmentShader else {
                    return fail(.unmetPrecondition(cmd: c.cmd, offset: c.offset))
                }
                r.draws += 1

            default:
                return fail(.unknownCommand(cmd: c.cmd, offset: c.offset))
            }
        }

        // The profile returns the object table to baseline every frame.
        guard r.live.isEmpty else {
            return .failure(.leakedObjects(count: r.live.count))
        }

        return .success(VirglDecodedFrame(
            colorResourceID: r.colorResourceID,
            vertexResourceID: r.vertexResourceID,
            width: width, height: height,
            clearColor: r.clearColor,
            drawsTriangle: r.draws == 1,
            commandCount: commands.count))
    }

    private static func u32(_ stream: [UInt8], _ at: Int) -> UInt32 {
        UInt32(stream[at])
            | UInt32(stream[at + 1]) << 8
            | UInt32(stream[at + 2]) << 16
            | UInt32(stream[at + 3]) << 24
    }
}

extension VirglStreamRejection {
    /// The stable case name — the coverage matrix's verdict column and
    /// the gate leg's printed report both key on it, so renaming a case
    /// is a deliberate contract edit, not drift.
    public var name: String {
        switch self {
        case .misaligned: return "misaligned"
        case .empty: return "empty"
        case .overCap: return "overCap"
        case .truncatedCommand: return "truncatedCommand"
        case .malformedNOP: return "malformedNOP"
        case .unknownCommand: return "unknownCommand"
        case .unknownObject: return "unknownObject"
        case .objectFieldSet: return "objectFieldSet"
        case .badArity: return "badArity"
        case .badField: return "badField"
        case .badHandle: return "badHandle"
        case .deadHandle: return "deadHandle"
        case .shaderHandleType: return "shaderHandleType"
        case .shaderFraming: return "shaderFraming"
        case .shaderText: return "shaderText"
        case .badReference: return "badReference"
        case .unmetPrecondition: return "unmetPrecondition"
        case .leakedObjects: return "leakedObjects"
        }
    }
}

// MARK: - The coverage matrix (M185a, issue #3176)
//
// The virgl subset the host accepts, as executable data. `probes`
// re-encodes the pinned canonical stream and crafts one hostile stream
// per named refusal; `run` feeds every probe through the REAL
// `VirglStreamDecoder.decode` (the same call `GPU3DMetalRenderer` makes
// inside `gpu3dSubmit`) and `report` renders the observed verdicts.
// Every matrix row in docs/hardware-contract.md is one of these
// observations — never a row read out of the virgl spec. The runner
// prints the report at every --gpu3d-metal attach, the live-gpu3d
// matrix leg asserts the names, and `GPU3DRendererTests` pins the same
// battery class-A: a decoder that starts accepting a refused command,
// or names a refusal differently, drops the line the leg asserts.
public enum VirglCoverage {

    /// One boundary probe: a crafted stream and the verdict the decoder
    /// must produce for it. `expected` nil means the stream must decode
    /// (an accepted row of the matrix).
    public struct Probe {
        public let label: String
        public let stream: [UInt8]
        public let expected: VirglStreamRejection?
    }

    /// One probe's run: the pinned expectation beside the OBSERVED
    /// decode result.
    public struct Outcome {
        public let label: String
        public let expected: VirglStreamRejection?
        public let observed: Result<VirglDecodedFrame, VirglStreamRejection>
        /// The row holds when the observed verdict IS the expected one.
        public var pinned: Bool {
            switch (expected, observed) {
            case (nil, .success): return true
            case let (e?, .failure(o)): return e == o
            default: return false
            }
        }
        /// The rendered verdict: `accepted` or `refused:<caseName>`.
        public var verdict: String {
            switch observed {
            case .success: return "accepted"
            case .failure(let r): return "refused:" + r.name
            }
        }
    }

    /// The fixed resource table every probe decodes against — exactly
    /// the pair the canonical stream names: res 1 the 256x192 BGRA8
    /// target-2D surface, res 2 the 96-byte vertex buffer.
    public static var probeResources: [UInt32: GPU3DWire.ResourceCreate] {
        [
            1: GPU3DWire.ResourceCreate(
                resourceID: 1, target: VirglStreamConst.target2D,
                format: VirglStreamConst.formatBGRA8, bind: 2,
                width: 256, height: 192, depth: 1, arraySize: 1,
                lastLevel: 0, nrSamples: 0, flags: 0),
            2: GPU3DWire.ResourceCreate(
                resourceID: 2, target: VirglStreamConst.targetBuffer,
                format: 0, bind: 16,
                width: 96, height: 1, depth: 1, arraySize: 1,
                lastLevel: 0, nrSamples: 0, flags: 0),
        ]
    }

    // ---- Stream construction ------------------------------------------

    private static func hdr(_ cmd: UInt32, _ obj: UInt32, _ len: UInt32) -> UInt32 {
        cmd | (obj << 8) | (len << 16)
    }

    private static func bytes(_ words: [UInt32]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(words.count * 4)
        for v in words {
            out.append(UInt8(v & 0xff))
            out.append(UInt8((v >> 8) & 0xff))
            out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 24) & 0xff))
        }
        return out
    }

    /// Re-encode the pinned canonical frame stream (word list): the same
    /// bytes kernel/src/gpu3d_stream.zig's encode_frame produces for
    /// ctx 1 at the full 256x192 extent — the triangle.words fixture pins
    /// them byte-for-byte and the test suite compares, so this builder
    /// can never drift away from the guest's real stream. Every hostile
    /// probe below is this stream with one field broken.
    public static func canonicalWords(
        resColor: UInt32 = 1, resVBO: UInt32 = 2,
        width: UInt32 = 256, height: UInt32 = 192,
        clear: SIMD4<Float> = .init(0, 0, 0, 1)
    ) -> [UInt32] {
        var w: [UInt32] = []
        func emit(_ cmd: UInt32, _ obj: UInt32, _ payload: [UInt32]) {
            w.append(hdr(cmd, obj, UInt32(payload.count)))
            w.append(contentsOf: payload)
        }
        func shader(_ handle: UInt32, _ type: UInt32, _ text: String) {
            let text = Array(text.utf8)
            let words = (text.count + 1 + 3) / 4
            var payload: [UInt32] = [handle, type, UInt32(words), UInt32(words), 0]
            for i in 0..<words {
                var v: UInt32 = 0
                for j in 0..<4 where i * 4 + j < text.count {
                    v |= UInt32(text[i * 4 + j]) << (8 * j)
                }
                payload.append(v)
            }
            emit(VirglStreamCmd.createObject, VirglStreamObject.shader, payload)
        }
        let one = Float(1).bitPattern
        let w2 = (Float(width) / 2).bitPattern
        let h2 = (Float(height) / 2).bitPattern
        let C = VirglStreamCmd.self
        let O = VirglStreamObject.self
        let K = VirglStreamConst.self
        emit(C.createObject, O.surface,
             [K.handleSurface, resColor, K.formatBGRA8, 0, 0])
        emit(C.createObject, O.vertexElements,
             [K.handleVertexElements, 0, 0, 0, K.formatRGBA32F,
              16, 0, 0, K.formatRGBA32F])
        emit(C.createObject, O.blend,
             [K.handleBlend, 0, 0]
             + [UInt32](repeating: K.blendRTWord, count: 8))
        emit(C.createObject, O.rasterizer,
             [K.handleRasterizer, K.rasterizerS0, one, 0, 0, one, 0, 0, 0])
        emit(C.createObject, O.dsa, [K.handleDSA, 0, 0, 0, 0])
        shader(K.handleVertexShader, K.shaderVertex, K.vertexShaderText)
        shader(K.handleFragmentShader, K.shaderFragment, K.fragmentShaderText)
        emit(C.bindShader, 0, [K.handleVertexShader, K.shaderVertex])
        emit(C.bindShader, 0, [K.handleFragmentShader, K.shaderFragment])
        emit(C.bindObject, O.blend, [K.handleBlend])
        emit(C.bindObject, O.rasterizer, [K.handleRasterizer])
        emit(C.bindObject, O.dsa, [K.handleDSA])
        emit(C.bindObject, O.vertexElements, [K.handleVertexElements])
        emit(C.setFramebufferState, 0, [1, 0, K.handleSurface])
        emit(C.setViewportState, 0, [0, w2, h2, one, w2, h2, 0])
        emit(C.setVertexBuffers, 0, [K.vertexStride, 0, resVBO])
        emit(C.clear, 0, [K.clearColor0, clear.x.bitPattern, clear.y.bitPattern,
                          clear.z.bitPattern, clear.w.bitPattern,
                          0, 0x3ff0_0000, 0])
        emit(C.drawVbo, 0, [0, K.vertexCount, K.primTriangles,
                            0, 1, 0, 0, 0, 0, 0, 2, 0])
        emit(C.destroyObject, O.shader, [K.handleFragmentShader])
        emit(C.destroyObject, O.shader, [K.handleVertexShader])
        emit(C.destroyObject, O.dsa, [K.handleDSA])
        emit(C.destroyObject, O.rasterizer, [K.handleRasterizer])
        emit(C.destroyObject, O.blend, [K.handleBlend])
        emit(C.destroyObject, O.vertexElements, [K.handleVertexElements])
        emit(C.destroyObject, O.surface, [K.handleSurface])
        return w
    }

    /// The canonical stream as wire bytes (660 B for the default spec).
    public static func canonicalStream() -> [UInt8] { bytes(canonicalWords()) }

    // ---- The probe battery --------------------------------------------

    /// Every coverage row, in matrix order: the accepted rows first,
    /// then one probe per named refusal the decoder can produce. The
    /// expected values pin the FULL rejection (associated offsets
    /// included) — the streams are fixed, so every field is stable.
    public static var probes: [Probe] {
        let canon = canonicalWords()
        var out: [Probe] = []
        func accept(_ label: String, _ words: [UInt32]) {
            out.append(Probe(label: label, stream: bytes(words), expected: nil))
        }
        func refuse(_ label: String, _ stream: [UInt8], _ why: VirglStreamRejection) {
            out.append(Probe(label: label, stream: stream, expected: why))
        }
        func refuseWords(_ label: String, _ words: [UInt32], _ why: VirglStreamRejection) {
            refuse(label, self.bytes(words), why)
        }
        // --- accepted rows ---
        accept("canonical", canon)
        accept("nop-tail-4096", canon + [UInt32](repeating: 0, count: 1024 - canon.count))
        accept("nop-only", [0])
        // --- stream hygiene ---
        refuse("empty", [], .empty)
        refuse("misaligned", [0xAA, 0xAA, 0xAA], .misaligned(count: 3))
        refuse("over-cap",
               bytes(canon + [UInt32](repeating: 0, count: 1025 - canon.count)),
               .overCap(count: 4100))
        refuseWords("truncated", [hdr(VirglStreamCmd.createObject,
                                      VirglStreamObject.surface, 5)],
                    .truncatedCommand(offset: 0))
        refuseWords("nop-nonzero", [hdr(VirglStreamCmd.nop, 0, 1), 0],
                    .malformedNOP(offset: 0))
        refuseWords("nop-midstream", [0, hdr(VirglStreamCmd.createObject,
                                             VirglStreamObject.surface, 0)],
                    .malformedNOP(offset: 4))
        // --- namespace rows ---
        refuseWords("unknown-cmd", [hdr(9, 0, 0)], .unknownCommand(cmd: 9, offset: 0))
        refuseWords("unknown-obj", [hdr(VirglStreamCmd.createObject, 9, 0)],
                    .unknownObject(obj: 9, offset: 0))
        refuseWords("dead-handle", [hdr(VirglStreamCmd.bindObject,
                                        VirglStreamObject.blend, 1), 9],
                    .deadHandle(handle: 9, offset: 0))
        refuseWords("bad-arity",
                    [hdr(VirglStreamCmd.createObject, VirglStreamObject.surface, 4),
                     1, 1, 1, 0],
                    .badArity(cmd: VirglStreamCmd.createObject,
                              obj: VirglStreamObject.surface,
                              declared: 4, expected: 5, offset: 0))
        refuseWords("bad-reference",
                    [hdr(VirglStreamCmd.setVertexBuffers, 0, 3),
                     VirglStreamConst.vertexStride, 0, 99],
                    .badReference(offset: 0))
        // --- precondition rows (single commands, nothing armed) ---
        refuseWords("unarmed-clear",
                    [hdr(VirglStreamCmd.clear, 0, 8),
                     VirglStreamConst.clearColor0, 0, 0, 0, Float(1).bitPattern,
                     0, 0x3ff0_0000, 0],
                    .unmetPrecondition(cmd: VirglStreamCmd.clear, offset: 0))
        refuseWords("unarmed-draw",
                    [hdr(VirglStreamCmd.drawVbo, 0, 12),
                     0, VirglStreamConst.vertexCount, VirglStreamConst.primTriangles,
                     0, 1, 0, 0, 0, 0, 0, 2, 0],
                    .unmetPrecondition(cmd: VirglStreamCmd.drawVbo, offset: 0))
        // --- canonical mutations (field/ordering rows) ---
        var m = canon
        m[1] = 9 // surface create: invented handle
        refuseWords("bad-handle", m, .badHandle(handle: 9,
                                                obj: VirglStreamObject.surface,
                                                offset: 0))
        m = canon
        m[30] = 0 // rasterizer s0
        refuseWords("bad-field", m, .badField(cmd: VirglStreamCmd.createObject,
                                              obj: VirglStreamObject.rasterizer,
                                              payloadWord: 1, offset: 112))
        m = canon
        m[45] = VirglStreamConst.handleFragmentShader // vertex shader's handle
        refuseWords("shader-handle-type", m,
                    .shaderHandleType(handle: VirglStreamConst.handleFragmentShader,
                                      type: VirglStreamConst.shaderVertex,
                                      offset: 176))
        m = canon
        m[47] = 26 // vertex shader offset word (wants 27)
        refuseWords("shader-framing", m, .shaderFraming(offset: 176))
        m = canon
        m[50] ^= 0xff // first vertex-shader text byte
        refuseWords("shader-text", m, .shaderText(offset: 176))
        m = canon
        m[138] |= 1 << 8 // DRAW_VBO carrying an object field
        refuseWords("object-field-set", m,
                    .objectFieldSet(cmd: VirglStreamCmd.drawVbo, offset: 552))
        m = Array(canon[0..<151]) + Array(canon[138..<151]) + Array(canon[151...])
        refuseWords("second-draw", m,
                    .unmetPrecondition(cmd: VirglStreamCmd.drawVbo, offset: 604))
        m = Array(canon[0..<163]) + [0, 0] // surface destroy dropped, tail-padded
        refuseWords("leaked-object", m, .leakedObjects(count: 1))
        return out
    }

    /// Run the whole battery against `resources` — every row is the
    /// decoder's actual verdict on a real stream.
    public static func run(
        resources: [UInt32: GPU3DWire.ResourceCreate] = probeResources
    ) -> [Outcome] {
        probes.map { p in
            Outcome(label: p.label, expected: p.expected,
                    observed: VirglStreamDecoder.decode(p.stream,
                                                        resources: resources))
        }
    }

    // ---- Field-space sweeps --------------------------------------------

    /// Feed one zero-payload command header for every opcode value
    /// (the field is 8 bits — this is the whole space). Any verdict but
    /// `unknownCommand` means the opcode carries a decode case, so the
    /// returned list IS the complete accepted-command set.
    public static func cmdSweep(
        resources: [UInt32: GPU3DWire.ResourceCreate] = probeResources
    ) -> [UInt32] {
        (0...255).filter { cmd in
            let s = bytes([hdr(UInt32(cmd), 0, 0)])
            if case .failure(let r) = VirglStreamDecoder.decode(s, resources: resources),
               case .unknownCommand = r {
                return false
            }
            return true
        }
    }

    /// Feed CREATE_OBJECT for every object-kind value (payload len 0 —
    /// an allowed kind lands on its arity check, proving the kind has a
    /// decode case). The returned list IS the complete accepted-object
    /// set; every other kind refuses `unknownObject`.
    public static func objSweep(
        resources: [UInt32: GPU3DWire.ResourceCreate] = probeResources
    ) -> [UInt32] {
        (0...255).filter { obj in
            let s = bytes([hdr(VirglStreamCmd.createObject, UInt32(obj), 0)])
            if case .failure(let r) = VirglStreamDecoder.decode(s, resources: resources),
               case .unknownObject = r {
                return false
            }
            return true
        }
    }

    // ---- The report the runner prints ---------------------------------

    /// The battery as output lines — `gpu3d-matrix:` prefixed so the
    /// gate leg greps them. A probe whose observed verdict is not the
    /// pinned one prints `DRIFT` with both verdicts instead of the row
    /// line, so a regression fails the leg's asserts loudly.
    public static func report(
        resources: [UInt32: GPU3DWire.ResourceCreate] = probeResources
    ) -> [String] {
        var lines: [String] = []
        var pinned = 0
        let results = run(resources: resources)
        for r in results {
            if r.pinned {
                pinned += 1
                lines.append("gpu3d-matrix: \(r.label): \(r.verdict)")
            } else {
                let want = r.expected.map { "refused:" + $0.name } ?? "accepted"
                lines.append("gpu3d-matrix: DRIFT \(r.label): want \(want), got \(r.verdict)")
            }
        }
        let cmds = cmdSweep(resources: resources)
        let objs = objSweep(resources: resources)
        lines.append("gpu3d-matrix: cmd-space handled=\(cmds.map(String.init).joined(separator: ",")) refused-unknownCommand=\(256 - cmds.count)")
        lines.append("gpu3d-matrix: obj-space handled=\(objs.map(String.init).joined(separator: ",")) refused-unknownObject=\(256 - objs.count)")
        lines.append("gpu3d-matrix: pinned \(pinned)/\(results.count) probes")
        return lines
    }

    /// Print the report — the attach path's evidence line set.
    public static func printReport(
        resources: [UInt32: GPU3DWire.ResourceCreate] = probeResources
    ) {
        for line in report(resources: resources) { print(line) }
    }
}
