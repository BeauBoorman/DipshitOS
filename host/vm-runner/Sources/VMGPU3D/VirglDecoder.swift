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
