// SoundInFlags — the M118a (#2479) probe's flag surface.
//
// `--sound-in` attaches a VZVirtioSoundDeviceInputStreamConfiguration with a
// VZHostAudioInputStreamSource to the probe's virtio-snd device. `--sound`
// attaches the same single output stream VMRunner's flag of the same name
// does, so the probe can present input-only, output-only, or input+output
// topologies without any VMRunner change.
//
// Why a separate executable (recorded on #2479): main.swift's argument loop
// is a flat `arg ==` chain with no extension point — a flag cannot exist on
// VMRunner without editing it, and the file is held by other active claims
// (#2475 declared, #2476 editing). The probe executable carries the real
// flag for the observation runs; the canonical VMRunner splice is a later
// change once the file is unclaimed.

import Foundation

struct SoundInFlags {
    var diskPath: String?
    var varsPath: String?
    var serialPath: String?
    var scriptPath: String?
    var scriptAfter: String?
    var scriptExpect: String?
    var timeout: Double = 90
    var cpuCount = 2
    var sound = false
    var soundIn = false
    var sharePath: String?

    /// Parse CommandLine.arguments. Returns nil + writes the named refusal
    /// to stderr on any malformed or unknown argument — a probe that cannot
    /// name its arguments must refuse loudly, never guess.
    static func parse(_ arguments: [String]) -> SoundInFlags? {
        var f = SoundInFlags()
        func fail(_ message: String) -> SoundInFlags? {
            FileHandle.standardError.write(Data("sound-in-probe: \(message)\n".utf8))
            return nil
        }
        var idx = 1
        while idx < arguments.count {
            let arg = arguments[idx]
            func value() -> String? {
                guard idx + 1 < arguments.count else {
                    _ = fail("\(arg) requires a value")
                    return nil
                }
                idx += 1
                return arguments[idx]
            }
            switch arg {
            case "--disk":
                guard let v = value() else { return nil }
                f.diskPath = v
            case "--vars":
                guard let v = value() else { return nil }
                f.varsPath = v
            case "--serial":
                guard let v = value() else { return nil }
                f.serialPath = v
            case "--script":
                guard let v = value() else { return nil }
                f.scriptPath = v
            case "--script-after":
                guard let v = value() else { return nil }
                f.scriptAfter = v
            case "--script-expect":
                guard let v = value() else { return nil }
                f.scriptExpect = v
            case "--timeout":
                guard let v = value(), let d = Double(v), d > 0 else {
                    return fail("--timeout requires a positive number of seconds")
                }
                f.timeout = d
            case "--cpus":
                guard let v = value(), let n = Int(v), n >= 1, n <= 8 else {
                    return fail("--cpus requires an integer 1...8")
                }
                f.cpuCount = n
            case "--sound":
                f.sound = true
            case "--sound-in":
                f.soundIn = true
            case "--share":
                guard let v = value() else { return nil }
                f.sharePath = v
            default:
                return fail("unknown argument '\(arg)'")
            }
            idx += 1
        }
        if f.diskPath == nil { return fail("--disk <path> is required") }
        if f.varsPath == nil { return fail("--vars <path> is required") }
        if f.serialPath == nil { return fail("--serial <path> is required") }
        return f
    }
}
