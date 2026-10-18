// SoundInProbe — M118a (#2479): the `--sound-in` observation vehicle.
//
// A standalone minimal boot of the canonical guest disk that exists so the
// `--sound-in` flag can attach VZVirtioSoundDeviceInputStreamConfiguration +
// VZHostAudioInputStreamSource and the guest's PCM_INFO enumeration can be
// observed — WITHOUT editing VMRunner's main.swift, whose argument loop is a
// flat `arg ==` chain with no extension point and which other active claims
// hold (#2475 declared, #2476 editing). Flag parsing lives in
// SoundInFlags.swift; this file is boot + serial plumbing only, mirroring
// the VMRunner idioms (EFI loader + var store, read-only disk attachment,
// pipe-backed serial, script-after-marker forwarding, expect-exit).
//
// Exit 0 iff --script-expect's text was observed in the guest serial output
// within --timeout seconds; every other outcome is a named refusal on
// stderr + non-zero exit.

import Foundation
import Virtualization
import AVFoundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sound-in-probe: \(message)\n".utf8))
    exit(1)
}

guard let flags = SoundInFlags.parse(CommandLine.arguments) else { exit(2) }

#if !arch(arm64)
#error("SoundInProbe requires arm64 — Virtualization.framework guests match the host arch")
#endif

// ---------------------------------------------------------------------------
// EFI variable store + boot loader (VMRunner's shape, minus secure-boot).
// ---------------------------------------------------------------------------
let varsURL = URL(fileURLWithPath: flags.varsPath!)
try? FileManager.default.createDirectory(at: varsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let variableStore: VZEFIVariableStore
if FileManager.default.fileExists(atPath: varsURL.path) {
    variableStore = VZEFIVariableStore(url: varsURL)
} else {
    do {
        variableStore = try VZEFIVariableStore(creatingVariableStoreAt: varsURL, options: .allowOverwrite)
    } catch {
        fail("could not create EFI variable store at \(varsURL.path): \(error)")
    }
}
let bootLoader = VZEFIBootLoader()
bootLoader.variableStore = variableStore

// ---------------------------------------------------------------------------
// VM configuration: 256 MiB / 2 vCPUs default, read-only canonical disk
// (the gate's contract — the guest never writes the boot volume).
// ---------------------------------------------------------------------------
let config = VZVirtualMachineConfiguration()
config.bootLoader = bootLoader
config.memorySize = 256 * 1024 * 1024
config.cpuCount = flags.cpuCount

let diskURL = URL(fileURLWithPath: flags.diskPath!)
guard FileManager.default.fileExists(atPath: diskURL.path) else {
    fail("--disk \(diskURL.path) does not exist")
}
do {
    let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: true)
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
} catch {
    fail("could not attach --disk \(diskURL.path): \(error)")
}
config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

// Serial: duplex pipe pair, guest output teed to --serial + buffered for
// marker matching; --script bytes are forwarded into the input pipe once
// --script-after's marker appears (VMRunner's mechanism, reduced).
let serialURL = URL(fileURLWithPath: flags.serialPath!)
FileManager.default.createFile(atPath: serialURL.path, contents: nil)
let serialHandle: FileHandle
do {
    serialHandle = try FileHandle(forWritingTo: serialURL)
} catch {
    fail("could not open serial log \(serialURL.path): \(error)")
}
let inputPipe = Pipe()
let outputPipe = Pipe()
let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
serialConfig.attachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: inputPipe.fileHandleForReading,
    fileHandleForWriting: outputPipe.fileHandleForWriting
)
config.serialPorts = [serialConfig]

// ---------------------------------------------------------------------------
// The sound device — the card under probe. `--sound-in` prepends an input
// stream so it occupies stream id 0: the guest's only PCM_INFO query is
// start_id=0/count=1 (kernel virtio_snd.snd_pcm_probe, no kernel changes
// on this card), so index 0 is where the INPUT row is observable.
// ---------------------------------------------------------------------------
var streams: [VZVirtioSoundDeviceStreamConfiguration] = []
if flags.soundIn {
    let input = VZVirtioSoundDeviceInputStreamConfiguration()
    input.source = VZHostAudioInputStreamSource()
    streams.append(input)
}
if flags.sound {
    let output = VZVirtioSoundDeviceOutputStreamConfiguration()
    output.sink = VZHostAudioOutputStreamSink()
    streams.append(output)
}
if streams.isEmpty {
    config.audioDevices = []
    print("SOUND-IN: flag off — config.audioDevices empty (default VM, byte-identical)")
} else {
    let sound = VZVirtioSoundDeviceConfiguration()
    sound.streams = streams
    config.audioDevices = [sound]
    let names = streams.map { $0 is VZVirtioSoundDeviceInputStreamConfiguration ? "input" : "output" }
    print("SOUND-IN: virtio-snd attached (\(names.joined(separator: "+")), host source+sink)")
}
// M118c (#2481): `--share <dir>` attaches the standard VirtioFS share (tag
// "virelaios" — the tag `--virtio-fs` uses on VMRunner, and the one the
// kernel's virtio_fs backend resolves). The guest's `exec` reads its apps
// from the share, so the go-selftest capture leg's headless GOSELF.ELF
// needs it. Off by default: the probe boots stay byte-identical without it.
if let sharePath = flags.sharePath {
    let shareURL = URL(fileURLWithPath: sharePath, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: shareURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        fail("--share requires an existing host directory, got '\(sharePath)'.")
    }
    let fileSystem = VZVirtioFileSystemDeviceConfiguration(tag: "virelaios")
    fileSystem.share = VZSingleDirectoryShare(
        directory: VZSharedDirectory(url: shareURL, readOnly: false)
    )
    config.directorySharingDevices = [fileSystem]
    print("SOUND-IN: share attached tag=virelaios share=\(shareURL.path)")
}

// The host mic-consent state, recorded BEFORE the VM starts: an ad-hoc
// signed CLI has no bundle/Info.plist, so this is the TCC answer the gate
// harness sees (AVAuthorizationStatus: 0 notDetermined, 1 restricted,
// 2 denied, 3 authorized).
print("SOUND-IN: mic authorizationStatus=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")

do {
    try config.validate()
} catch {
    fail("invalid VM configuration: \(error)")
}

// ---------------------------------------------------------------------------
// Boot + marker/script plumbing.
// ---------------------------------------------------------------------------
final class ProbeDelegate: NSObject, VZVirtualMachineDelegate {
    var stopError: String?
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {}
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        stopError = "\(error)"
    }
}

let queue = DispatchQueue(label: "virelaios.soundinprobe.vm")
let delegate = ProbeDelegate()
let vm = VZVirtualMachine(configuration: config, queue: queue)
vm.delegate = delegate

let serialLock = NSLock()
var serialBuf = Data()
outputPipe.fileHandleForReading.readabilityHandler = { fh in
    let chunk = fh.availableData
    guard !chunk.isEmpty else { return }
    serialLock.lock()
    serialBuf.append(chunk)
    serialLock.unlock()
    do { try serialHandle.write(contentsOf: chunk) } catch {}
}

var startError: String?
let started = DispatchSemaphore(value: 0)
queue.sync {
    vm.start { result in
        if case let .failure(error) = result { startError = "\(error)" }
        started.signal()
    }
}
started.wait()
if let startError { fail("VM start failed: \(startError)") }
print("SOUND-IN: VM started (timeout \(Int(flags.timeout))s)")

let scriptData: Data?
if let scriptPath = flags.scriptPath {
    do { scriptData = try Data(contentsOf: URL(fileURLWithPath: scriptPath)) }
    catch { fail("could not read --script \(scriptPath): \(error)") }
} else {
    scriptData = nil
}
let scriptAfter = flags.scriptAfter ?? "tasks user-el0 exited status=7"

let deadline = Date().addingTimeInterval(flags.timeout)
var scriptSent = false
var expectMatched = flags.scriptExpect == nil
var pollText = ""
while Date() < deadline {
    serialLock.lock()
    pollText = String(decoding: serialBuf, as: UTF8.self)
    serialLock.unlock()
    if !scriptSent, let data = scriptData, pollText.contains(scriptAfter) {
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
            print("SOUND-IN: forwarded \(data.count) script bytes after marker \"\(scriptAfter)\"")
        } catch {
            FileHandle.standardError.write(Data("sound-in-probe: script forward failed: \(error)\n".utf8))
        }
        scriptSent = true
    }
    if let expect = flags.scriptExpect, pollText.contains(expect) {
        expectMatched = true
        break
    }
    if let stopError = delegate.stopError { fail("VM stopped with error: \(stopError)") }
    Thread.sleep(forTimeInterval: 0.1)
}

// Settle so post-marker output lands in the serial log, then stop.
Thread.sleep(forTimeInterval: 1.5)
queue.sync {
    if vm.state == .running || vm.state == .paused {
        vm.stop { _ in }
    }
}
do { try serialHandle.close() } catch {}

if let expect = flags.scriptExpect, !expectMatched {
    FileHandle.standardError.write(Data("sound-in-probe: script-expect \"\(expect)\" not observed within \(Int(flags.timeout))s\n".utf8))
    exit(1)
}
print("SOUND-IN: done (expect matched=\(expectMatched))")
exit(0)
