// Claim #1278: class-A tests for the host half of the fault/state recorder.
//
// These run WITHOUT a VM (the module imports no Virtualization), which is the
// point: the recorder's job is to survive a dying boot, so the rules that
// decide what it says cannot be validated by a boot that passes. What a unit
// test here canNOT prove is that Virtualization actually calls the delegate —
// that half is witnessed by `#selector` resolution in main.swift plus the
// verdict suffix the runner now reports on every boot.

import XCTest

@testable import VMPostmortem

final class StopReasonTests: XCTestCase {
    // MARK: - the "nothing was reported" case

    /// A run whose VM is still alive, or stopped without VZ narrating it, must
    /// say so explicitly — an empty string here would read exactly like the
    /// pre-#1278 runner, which is the confusion this whole card is about.
    func testUnstoppedRecorderSaysNoneReported() {
        XCTAssertEqual(StopReasonRecorder().verdictSuffix(), " reason=<none reported by VZ>")
        XCTAssertNil(StopReasonRecorder().reason)
    }

    // MARK: - the error line

    func testErrorCarriesDomainCodeDescriptionAndNestedUserInfo() {
        let rec = StopReasonRecorder()
        rec.recordError(
            NSError(
                domain: "VZErrorDomain",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "internal error",
                    "Underlying": "vCPU 2 stalled",
                ]))

        let suffix = rec.verdictSuffix()
        XCTAssertTrue(suffix.hasPrefix(" reason=domain=VZErrorDomain code=3 desc=internal error"),
                      "unexpected shape: \(suffix)")
        XCTAssertTrue(suffix.contains("userInfo={"), "nesting dropped: \(suffix)")
        XCTAssertTrue(suffix.contains("Underlying=vCPU 2 stalled"),
                      "underlying error dropped: \(suffix)")
    }

    /// The userInfo order must not depend on dictionary iteration order, or the
    /// same failure would print a different line on every run and no gate could
    /// match it.
    func testUserInfoIsSortedSoTheLineIsStable() {
        let a = StopReasonRecorder.describe(
            NSError(domain: "D", code: 1, userInfo: ["z": 1, "a": 2, "m": 3]))
        let b = StopReasonRecorder.describe(
            NSError(domain: "D", code: 1, userInfo: ["m": 3, "a": 2, "z": 1]))
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.contains("userInfo={a=2 m=3 z=1}"), "unsorted: \(a)")
    }

    func testEmptyUserInfoAddsNoBraces() {
        let line = StopReasonRecorder.describe(NSError(domain: "D", code: 7))
        XCTAssertFalse(line.contains("userInfo"), "noise: \(line)")
    }

    // MARK: - ordering

    /// The ordering hazard the delegate actually faces: VZ can deliver the
    /// clean-stop callback and then a failure. A clean stop recorded first must
    /// not mask the error.
    func testErrorOutranksACleanStopRecordedFirst() {
        let rec = StopReasonRecorder()
        rec.recordGuestPoweredOff()
        XCTAssertEqual(rec.reason, StopReasonRecorder.cleanStop)

        rec.recordError(NSError(domain: "VZErrorDomain", code: 9,
                                userInfo: [NSLocalizedDescriptionKey: "late failure"]))
        XCTAssertTrue(rec.reason?.contains("code=9") ?? false,
                      "the clean stop masked the error: \(rec.reason ?? "nil")")
    }

    /// Conversely, a clean stop must not overwrite a recorded error.
    func testCleanStopDoesNotOverwriteAnError() {
        let rec = StopReasonRecorder()
        rec.recordError(NSError(domain: "VZErrorDomain", code: 4,
                                userInfo: [NSLocalizedDescriptionKey: "first"]))
        rec.recordGuestPoweredOff()
        XCTAssertTrue(rec.reason?.contains("code=4") ?? false,
                      "the clean stop overwrote the error: \(rec.reason ?? "nil")")
    }

    /// The earliest error is nearest the cause; later ones are consequences.
    func testFirstErrorWins() {
        let rec = StopReasonRecorder()
        rec.recordError(NSError(domain: "D", code: 1, userInfo: [NSLocalizedDescriptionKey: "cause"]))
        rec.recordError(NSError(domain: "D", code: 2, userInfo: [NSLocalizedDescriptionKey: "effect"]))
        XCTAssertTrue(rec.reason?.contains("code=1") ?? false, "\(rec.reason ?? "nil")")
    }

    func testCleanStopAloneIsRecorded() {
        let rec = StopReasonRecorder()
        rec.recordGuestPoweredOff()
        XCTAssertEqual(rec.verdictSuffix(), " reason=guest-powered-off")
    }

    // MARK: - M114d (#2457): the in-window card's content model

    /// The card's two endings are different headlines — "stopped" is a
    /// VZ-narrated shutdown, "crashed" is an error state or a start
    /// refusal — and the rows are the three facts in stable order.
    func testPostmortemCardVocabularyAndRowOrder() {
        let stopped = PostmortemCard(ending: .stopped, state: "3",
                                   reason: StopReasonRecorder.cleanStop, serialLines: 42)
        XCTAssertEqual(stopped.title, "VM stopped")
        XCTAssertEqual(stopped.rows,
                       ["state=3", "reason=guest-powered-off", "serial tail: 42 line(s)"])
        let crashed = PostmortemCard(ending: .crashed, state: "4",
                                   reason: "domain=VZErrorDomain code=1", serialLines: 0)
        XCTAssertEqual(crashed.title, "VM crashed")
        XCTAssertEqual(crashed.rows[0], "state=4")
        XCTAssertEqual(crashed.rows[1], "reason=domain=VZErrorDomain code=1")
    }

    // MARK: - the race the delegate queue creates

    /// VZ invokes the delegate on the VM's own queue while the runner's polls
    /// read the verdict from the main thread. Hammer both and assert the
    /// observable state never tears: the verdict must be exactly one of the
    /// lines that were recorded, never a half-written mix.
    func testConcurrentRecordsNeverTearTheLine() {
        for _ in 0..<50 {
            let rec = StopReasonRecorder()
            let powerOffs = 8
            let errors = 8
            DispatchQueue.concurrentPerform(iterations: powerOffs + errors) { i in
                if i < powerOffs {
                    rec.recordGuestPoweredOff()
                } else {
                    rec.recordError(NSError(
                        domain: "VZErrorDomain", code: Int(i),
                        userInfo: [NSLocalizedDescriptionKey: "err-\(i)"]))
                }
                _ = rec.verdictSuffix()
            }

            let reason = rec.reason
            XCTAssertNotNil(reason)
            if reason != StopReasonRecorder.cleanStop {
                // Whichever error won, it must be a whole line.
                let s = reason ?? ""
                XCTAssertTrue(s.hasPrefix("domain=VZErrorDomain code="), "torn: \(s)")
                XCTAssertTrue(s.contains(" desc=err-"), "torn: \(s)")
                XCTAssertTrue(s.contains(" userInfo={NSLocalizedDescription=err-"), "torn: \(s)")
            }
        }
    }
}
