// VZ machine-state round trips; see docs/hardware-contract.md for what was
// observed. Three modes (M70g G3, #1459, extends the #1370 probe):
//   * .sameProcess — the #1370 probe: boot, store a RAM-only clipboard marker,
//     pause → saveMachineStateTo → stop → restoreMachineStateFrom → resume in
//     THIS process, then a fresh serial query past serialOffset must recover
//     the marker. Saved state is removed on success.
//   * .save(dir)   — boot, store the marker, pause → save into
//     dir/state.vzsave, write dir/marker.txt, stop, EXIT 0. The disk overlay
//     was placed in dir by main.swift and is left there for the load process.
//   * .load(dir)   — never boots: restoreMachineStateFrom(dir/state.vzsave)
//     into a fresh VZVirtualMachine built by a NEW process, resume, and the
//     fresh serial query must recover the marker the OTHER process stored.
//     The whole dir is removed on success.
// The RAM clipboard is set only before save; after restore only a fresh
// serial query can pass. No framebuffer or reboot fallback. Failures leave the
// state beside the serial log for diagnosis, subject to the enclosing gate's
// temporary-directory cleanup.
import Darwin
import Foundation
import Virtualization

// ADR 0059 (M131b #2639): a warm leg's restore refusal must be
// machine-distinguishable — one stdout line naming the VZErrorDomain code
// plus this dedicated exit status, so the harness degrades ONCE to a cold
// boot (D8) and never confuses a refusal with an assert failure. 75 is
// sysexits EX_TEMPFAIL: a status no ordinary runner exit produces.
let vzRestoreRefusedStatus: Int32 = 75

final class VZRestoreProbe {
    enum Mode {
        case sameProcess
        case save(URL)
        case load(URL)
    }

    private let vm: VZVirtualMachine
    private let queue: DispatchQueue
    private let serialURL: URL
    private let input: FileHandle
    private let deadline: Date
    private let mode: Mode
    private let witnessLine: String?
    private let verifyCommand: String?
    private let verifyOutput: String?
    private let marker: String
    private let stateURL: URL
    private let stateDir: URL?
    // ADR 0059 D4: when set on .save, the boot is a checkpoint BASE BOOT —
    // it runs no leg workload. The probe waits for this boot-settle marker,
    // writes "\n" to provoke a fresh `virelai> ` prompt, and only then
    // pauses → saves → stops, so the bundle pins a quiescent guest.
    private let settleAfter: String?
    private var settleMark = 0
    // ADR 0059 D5/D6: when set on .load, this is a scripted warm leg — no
    // marker.txt is required, the post-restore handshake (serial-epoch mark
    // → "\n" → fresh prompt inside the epoch) replaces the clipboard-marker
    // query, and `onSeated` hands the seated VM to the script machinery.
    private let warm: Bool
    private let onSeated: (() -> Void)?
    private var phase = "boot"
    private var serialOffset = 0

    init(vm: VZVirtualMachine, queue: DispatchQueue, serialURL: URL, input: FileHandle, timeout: TimeInterval,
         witnessLine: String? = nil,
         verifyCommand: String? = nil, verifyOutput: String? = nil,
         mode: Mode = .sameProcess,
         settleAfter: String? = nil, warm: Bool = false,
         onSeated: (() -> Void)? = nil) {
        self.vm = vm
        self.queue = queue
        self.serialURL = serialURL
        self.input = input
        self.mode = mode
        self.witnessLine = witnessLine
        self.verifyCommand = verifyCommand
        self.verifyOutput = verifyOutput
        self.settleAfter = settleAfter
        self.warm = warm
        self.onSeated = onSeated
        deadline = Date().addingTimeInterval(timeout)
        switch mode {
        case .sameProcess:
            marker = "VZSR-" + UUID().uuidString
            stateURL = serialURL.deletingLastPathComponent().appendingPathComponent("vz-state-\(UUID().uuidString).vzsave")
            stateDir = nil
        case .save(let dir):
            marker = "VZSR-" + UUID().uuidString
            stateURL = dir.appendingPathComponent("state.vzsave")
            stateDir = dir
        case .load(let dir):
            if warm {
                // A scripted warm leg knows the checkpoint only through its
                // bundle; there is no clipboard marker to recover.
                marker = ""
            } else {
                // The marker the SAVE process stored in guest RAM: the only thing
                // this process may know about the world it is about to resume.
                let markerURL = dir.appendingPathComponent("marker.txt")
                guard let raw = FileManager.default.contents(atPath: markerURL.path) else {
                    FileHandle.standardError.write(Data("ERROR: VZ-RESTORE: load: no marker.txt in \(dir.path) (run --vz-restore-save first).\n".utf8))
                    exit(1)
                }
                marker = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            stateURL = dir.appendingPathComponent("state.vzsave")
            stateDir = dir
        }
    }

    /// Entry for the modes that BOOT (same-process and save). The load mode
    /// never boots; main.swift calls `startFromSavedState()` instead of
    /// `vm.start`, and `start()` simply routes there if asked.
    func start() {
        switch mode {
        case .sameProcess:
            print("VZ-RESTORE: standalone RAM clipboard probe; state file \(stateURL.path)")
        case .save:
            if let settle = settleAfter {
                print("VZ-RESTORE: SAVE (base boot, pid \(getpid())) — settles on '\(settle)' then a fresh prompt; state file \(stateURL.path)")
            } else {
                print("VZ-RESTORE: SAVE half of the cross-process probe (pid \(getpid())); state file \(stateURL.path)")
            }
        case .load:
            startFromSavedState()
            return
        }
        poll()
    }

    /// M70g G3: the load process's entry — restore the other process's saved
    /// state into this fresh (stopped) VM, resume it, and query the marker.
    /// A warm leg (ADR 0059) takes the same restore seam but refuses with the
    /// dedicated status + one stdout line, then runs the D5 handshake.
    func startFromSavedState() {
#if arch(arm64)
        if warm {
            print("VZ-RESTORE: WARM leg (pid \(getpid())) restoring checkpoint \(stateURL.path)")
        } else {
            print("VZ-RESTORE: LOAD half of the cross-process probe (pid \(getpid())); restoring \(stateURL.path) marker=\(marker)")
        }
        guard FileManager.default.fileExists(atPath: stateURL.path) else { abort("no \(stateURL.path)") }
        guard vm.state == .stopped else { abort("fresh VM should be stopped, state=\(vm.state.rawValue)") }
        phase = "restore"
        vm.restoreMachineStateFrom(url: stateURL) { error in
            if let error {
                if self.warm {
                    FileHandle.standardOutput.write(Data("VZ-RESTORE: refused code=\((error as NSError).code)\n".utf8))
                    exit(vzRestoreRefusedStatus)
                }
                self.checked(error, "restoreMachineStateFrom", state: .paused)
                return
            }
            self.checked(nil, "restoreMachineStateFrom", state: .paused)
            self.resumeAndQuery()
        }
#else
        abort("arm64 required")
#endif
    }

    /// Shared post-restore tail: mark the serial boundary, resume, and ask
    /// the guest for the marker with a fresh query.
    private func resumeAndQuery() {
        do { serialOffset = try Data(contentsOf: serialURL).count }
        catch { abort("post-restore serial boundary: \(error)") }
        phase = "resume"
        vm.resume { result in
            if case .failure(let error) = result { self.abort("resume: \(error as NSError)") }
            self.checked(nil, "resume", state: .running)
            if self.warm {
                // ADR 0059 D5: the epoch boundary was marked at serialOffset;
                // a bare newline provokes a fresh `virelai> ` prompt, and
                // only its arrival inside the epoch proves the restored
                // shell idle enough to arm the leg's --script.
                self.phase = "handshake"
                self.send("\n")
                self.queue.asyncAfter(deadline: .now() + 0.5) { self.warmPoll() }
                return
            }
            self.phase = "after-restore"
            var commands = "clip\n"
            if let verifyCommand = self.verifyCommand {
                commands += verifyCommand + "\n"
            }
            self.send(commands)
            self.queue.asyncAfter(deadline: .now() + 0.5) { self.poll() }
        }
    }

    /// ADR 0059 D5: the warm leg's arming handshake — wait for a fresh
    /// `virelai> ` prompt strictly inside the post-restore serial epoch,
    /// then hand off to the script machinery via `onSeated`. A guest that
    /// never re-prompts is a runner error, never a keystroke into a busy
    /// console.
    private func warmPoll() {
        guard Date() < deadline else {
            abort("warm handshake: no fresh 'virelai> ' prompt inside the post-restore epoch before the deadline")
        }
        guard vm.state == .running else { abort("warm handshake: unexpected VM state=\(vm.state.rawValue)") }
        let data: Data
        do { data = try Data(contentsOf: serialURL) }
        catch { abort("serial read: \(error)") }
        guard data.count >= serialOffset else { abort("serial log shrank") }
        let text = String(decoding: data.dropFirst(serialOffset), as: UTF8.self)
        if text.contains("virelai> ") {
            print("VZ-RESTORE: warm handshake complete — fresh 'virelai> ' inside the epoch at serial-offset=\(serialOffset)")
            phase = "seated"
            onSeated?()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.5) { self.warmPoll() }
    }

    /// Shared pause → saveMachineStateTo → stop; `then` runs with the VM
    /// stopped and the state file written.
    private func pauseSaveStop(then: @escaping () -> Void) {
#if arch(arm64)
        phase = "pause"
        vm.pause { result in
            if case .failure(let error) = result { self.abort("pause: \(error as NSError)") }
            self.checked(nil, "pause", state: .paused)
            self.phase = "save"
            self.vm.saveMachineStateTo(url: self.stateURL) { error in
                self.checked(error, "saveMachineStateTo", state: .paused)
                self.phase = "stop"
                self.vm.stop { error in
                    self.checked(error, "stop", state: .stopped)
                    then()
                }
            }
        }
#else
        abort("arm64 required")
#endif
    }

    private func abort(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ERROR: VZ-RESTORE: \(phase): \(message); no snapshot or reboot fallback.\n".utf8))
        exit(1)
    }

    private func checked(_ error: Error?, _ operation: String, state: VZVirtualMachine.State) {
        if let error { abort("\(operation): \(error as NSError)") }
        guard vm.state == state else { abort("\(operation): unexpected state=\(vm.state.rawValue)") }
        print("VZ-RESTORE: \(operation) completed state=\(vm.state.rawValue)")
    }

    private func send(_ commands: String) {
        do { try input.write(contentsOf: Data(commands.utf8)) }
        catch { abort("serial input: \(error)") }
    }

    private func poll() {
        guard Date() < deadline else { abort("deadline exceeded") }
        guard vm.state == .running else { abort("unexpected VM state=\(vm.state.rawValue)") }
        let data: Data
        do { data = try Data(contentsOf: serialURL) }
        catch { abort("serial read: \(error)") }
        guard data.count >= serialOffset else { abort("serial log shrank") }
        let text = String(decoding: data.dropFirst(serialOffset), as: UTF8.self)
        let markerLine = "clip: \(marker)"
        let hasMarker = text.components(separatedBy: "\n").contains(markerLine)
        let hasWitness = witnessLine.map { text.components(separatedBy: "\n").contains($0) } ?? true
        let hasVerifyOutput = verifyOutput.map { text.contains($0) } ?? true
        if let settle = settleAfter {
            // ADR 0059 D4: the checkpoint base boot — wait for the boot-settle
            // marker, then a FRESH `virelai> ` provoked by a bare newline, so
            // the bundle pins a quiescent idle guest rather than a mid-print
            // one.
            if phase == "boot", text.contains(settle) {
                print("VZ-RESTORE: settle marker '\(settle)' observed (serial \(data.count) bytes) — provoking a fresh prompt")
                phase = "settle-prompt"
                settleMark = data.count
                send("\n")
            } else if phase == "settle-prompt" {
                let post = String(decoding: data.dropFirst(settleMark), as: UTF8.self)
                if post.contains("virelai> ") {
                    print("VZ-RESTORE: settle prompt 'virelai> ' emitted post-marker — guest quiescent; taking the checkpoint")
                    saveAndExit()
                    return
                }
            }
            queue.asyncAfter(deadline: .now() + 0.5) { self.poll() }
            return
        }
        if phase == "boot", text.contains("kernel terminal state") {
            phase = "before-save"
            send("clip \(marker)\nclip\n")
        } else if phase == "before-save", hasMarker, hasWitness {
            print("VZ-RESTORE: before-save guest marker=\(marker)")
            if let witnessLine {
                print("VZ-RESTORE: before-save guest witness=\(witnessLine)")
            }
            if case .save = mode { saveAndExit() } else { saveAndRestore() }
            return
        } else if phase == "after-restore", hasMarker, hasWitness, hasVerifyOutput {
            print("VZ-RESTORE: after-restore guest marker=\(marker) serial-offset=\(serialOffset)")
            if let witnessLine {
                print("VZ-RESTORE: after-restore guest witness=\(witnessLine)")
            }
            if let verifyOutput {
                print("VZ-RESTORE: after-restore guest verify=\(verifyOutput)")
            }
            phase = "final-stop"
            vm.stop { error in
                self.checked(error, "final stop", state: .stopped)
                switch self.mode {
                case .sameProcess:
                    do { try FileManager.default.removeItem(at: self.stateURL) }
                    catch { self.abort("saved-state cleanup: \(error)") }
                    print("VZ-RESTORE: PASS CPU/memory/device restore; fresh serial query recovered RAM marker")
                case .load(let dir):
                    do { try FileManager.default.removeItem(at: dir) }
                    catch { self.abort("saved-state cleanup: \(error)") }
                    print("VZ-RESTORE: CROSS-PROCESS PASS restored in pid \(getpid()) from another process's saved state; fresh serial query recovered RAM marker \(self.marker)")
                case .save:
                    self.abort("save mode never reaches after-restore")
                }
                exit(0)
            }
            return
        }
        queue.asyncAfter(deadline: .now() + 0.5) { self.poll() }
    }

    /// M70g G3: the save process's tail — pause, save, persist the marker,
    /// stop, exit. The overlay is already in the state dir (main.swift).
    private func saveAndExit() {
#if arch(arm64)
        guard let dir = stateDir else { abort("save mode without a state dir") }
        pauseSaveStop {
            do {
                if let settle = self.settleAfter {
                    try Data((settle + "\n").utf8).write(to: dir.appendingPathComponent("settle.txt"))
                    print("VZ-RESTORE: SAVE PASS pid \(getpid()) settled at '\(settle)'; state+overlay persisted into \(dir.path) — the checkpoint bundle for warm legs")
                } else {
                    try Data((self.marker + "\n").utf8).write(to: dir.appendingPathComponent("marker.txt"))
                    print("VZ-RESTORE: SAVE PASS pid \(getpid()) saved state+overlay+marker \(self.marker) into \(dir.path); exiting so another process can restore")
                }
            } catch { self.abort("marker persist: \(error)") }
            exit(0)
        }
#else
        abort("arm64 required")
#endif
    }

    private func saveAndRestore() {
#if arch(arm64)
        pauseSaveStop {
            self.phase = "restore"
            self.vm.restoreMachineStateFrom(url: self.stateURL) { error in
                self.checked(error, "restoreMachineStateFrom", state: .paused)
                self.resumeAndQuery()
            }
        }
#else
        abort("arm64 required")
#endif
    }
}
