import AppKit
import XCTest
import VMAppKit
import VMPostmortem

/// M114d (#2457): the inspector drawer's class-A surface — the ring
/// buffer, the incremental serial ingest, the search filter, the
/// send-serial injector, the HostInt observed counters, and the
/// postmortem card — plus the session window's pane binding, all
/// without a VM or a presented window (the HostCommandTests precedent:
/// the bus is the seam, never synthesized clicks).
final class HostInspectorTests: XCTestCase {
    // MARK: - the ring buffer

    func testRingKeepsNewestLinesAndCountsTheEvictions() {
        let model = HostInspector(capacity: 4)
        model.ingest(serialText: "l1\nl2\nl3\nl4\nl5\nl6\nl7\n")
        XCTAssertEqual(model.lines, ["l4", "l5", "l6", "l7"])
        XCTAssertEqual(model.ingestedCount, 7)
        XCTAssertEqual(model.droppedCount, 3)
    }

    // MARK: - incremental ingest

    /// The polls hand the model the WHOLE log each tick; only the new
    /// bytes may become lines, never the same line twice.
    func testGrowingSnapshotIngestsOnlyNewLines() {
        let model = HostInspector()
        model.ingest(serialText: "a\nb\n")
        model.ingest(serialText: "a\nb\n") // same tick's re-read
        model.ingest(serialText: "a\nb\nc\n")
        XCTAssertEqual(model.lines, ["a", "b", "c"])
        XCTAssertEqual(model.ingestedCount, 3)
    }

    /// A line is not a line until its newline lands — the trailing
    /// fragment waits for the next snapshot.
    func testPartialTailWaitsForItsNewline() {
        let model = HostInspector()
        model.ingest(serialText: "one\ntwo-part")
        XCTAssertEqual(model.lines, ["one"])
        model.ingest(serialText: "one\ntwo-partial\nthree\n")
        XCTAssertEqual(model.lines, ["one", "two-partial", "three"])
    }

    /// A shrinking log (rotation, rewrite) restarts the offset instead
    /// of straddling two different texts.
    func testShrinkingSnapshotRestartsIngest() {
        let model = HostInspector()
        model.ingest(serialText: "old1\nold2\nold3\n")
        model.ingest(serialText: "n1\n")
        XCTAssertTrue(model.lines.contains("n1"))
    }

    // MARK: - search/filter

    func testFilterIsACaseInsensitiveSubstring() {
        let model = HostInspector()
        model.ingest(serialText: "boot ok\nnet: rx-armed\nkernel panic\n")
        XCTAssertEqual(model.filteredLines.count, 3)
        model.filter = "NET"
        XCTAssertEqual(model.filteredLines, ["net: rx-armed"])
        model.filter = "panic"
        XCTAssertEqual(model.filteredLines, ["kernel panic"])
        model.filter = ""
        XCTAssertEqual(model.filteredLines.count, 3)
    }

    // MARK: - the injector (send-serial)

    func testInjectWritesTheArmedLineThroughTheSink() {
        let model = HostInspector()
        var writes: [String] = []
        model.serialSink = { writes.append($0); return true }
        model.inputLine = "echo inspector-ping"
        XCTAssertTrue(model.inject())
        XCTAssertEqual(writes, ["echo inspector-ping"]) // the sink appends the newline
        XCTAssertEqual(model.sentCount, 1)
        XCTAssertEqual(model.lastSent, "echo inspector-ping")
    }

    func testInjectWithoutASinkOrOnAWriteFailureIsFalse() {
        let model = HostInspector()
        model.inputLine = "x"
        XCTAssertFalse(model.inject()) // no sink — the verb receipts disabled
        model.serialSink = { _ in false }
        XCTAssertFalse(model.inject()) // the write failed — the verb receipts failed
        XCTAssertEqual(model.sentCount, 0)
        XCTAssertNil(model.lastSent)
    }

    /// The `saw=` receipt word: the guest's console echo wraps the
    /// injected line (`gosh: line echo …`), so containment is the honest
    /// "the drawer model saw it" test.
    func testSawLastSentWhenTheEchoLandsInTheTail() {
        let model = HostInspector()
        model.serialSink = { _ in true }
        model.inputLine = "echo inspector-ping"
        XCTAssertTrue(model.inject())
        XCTAssertFalse(model.sawLastSent)
        model.ingest(serialText: "gosh: line echo inspector-ping\ninspector-ping\n")
        XCTAssertTrue(model.sawLastSent)
    }

    // MARK: - HostInt observed counters

    func testHostIntCountersFromSerialMarkers() {
        let model = HostInspector()
        model.ingest(serialText: """
            gotabwm: hostint armed epoch=42
            gotabwm: hostint clip-in seq=1 len=19 sha=132b3de9 truncated=0
            gotabwm: hostint refuse lane=clip reason=stale_epoch
            gotabwm: hostint drop seq=4 name=D.QOI
            compose: paste refused rc=-7
            unrelated seq=999
            """)
        // seq high-water from hostint-shaped lines only — the
        // "unrelated seq=999" line is not a lane marker.
        XCTAssertEqual(model.hostIntSeq, 4)
        // One refusal: "refuse" on a shaped line. The compose line is
        // not hostint-shaped and is ignored.
        XCTAssertEqual(model.hostIntRefusals, 1)
    }

    func testHostIntCountersFromRunnerMarkersAndDirScan() {
        let model = HostInspector()
        model.noteHostMarker("host-clip: in seq=5 sha256=ab12cd34 len=10 truncated=0")
        model.noteHostMarker("host-int: refuse lane=drop reason=lane_disabled")
        model.noteHostMarker("host-notify: dropped reason=no_bundle seq=2 n=1")
        model.noteHostIntSeq(9)
        model.noteHostIntSeq(3) // high-water never regresses
        XCTAssertEqual(model.hostIntSeq, 9)
        XCTAssertEqual(model.hostIntRefusals, 2)
        XCTAssertEqual(model.hostIntSummary, "HostInt seq=9 refusals=2")
    }

    // MARK: - the postmortem card

    func testNoteStopSetsTheCardAndOpensTheDrawer() {
        let model = HostInspector()
        model.emit = { _ in }
        let card = PostmortemCard(ending: .crashed, state: "4",
                                reason: "domain=VZErrorDomain code=1", serialLines: 17)
        model.noteStop(card)
        XCTAssertEqual(model.postmortem, card)
        XCTAssertTrue(model.isOpen, "a stop/crash opens the drawer itself")
    }

    /// M120e (#2562): the note emits the postmortem receipt a live leg
    /// greps — and only ONCE: the polls' repeated observation of a
    /// still-dead VM must not re-emit or re-open a closed drawer.
    func testNoteStopEmitsThePostmortemReceiptOnce() {
        let model = HostInspector()
        var lines: [String] = []
        model.emit = { lines.append($0) }
        let card = PostmortemCard(ending: .stopped, state: "0",
                                reason: "guest-powered-off", serialLines: 3)
        model.noteStop(card)
        model.isOpen = false // the operator closed the drawer
        model.noteStop(card) // the next poll tick re-observes the same end
        XCTAssertEqual(lines, ["host-inspector: postmortem ending=stopped state=0 open=1"])
        XCTAssertFalse(model.isOpen, "a repeat note does not re-open the drawer")
        XCTAssertEqual(model.postmortem, card)
    }

    /// M120e (#2562): the session window's drawer really un-hides on a
    /// postmortem — the auto-open the card promises, read off the actual
    /// split pane, not just the model flag.
    func testPostmortemOpensTheSessionDrawer() {
        let model = HostInspector()
        model.emit = { _ in }
        let host = HostApplication(serialLog: "/fixture/serial.log", inspector: model, presentWindow: false)
        XCTAssertFalse(host.drawerVisible)
        // A non-presented window still owns real bounds — lay the split
        // out so the drawer's un-hide resolves against them.
        host.window.contentView?.layoutSubtreeIfNeeded()
        model.noteStop(PostmortemCard(ending: .crashed, state: "4",
                                    reason: "domain=VZErrorDomain code=1", serialLines: 9))
        XCTAssertTrue(host.inspectorVisible)
        XCTAssertTrue(host.drawerVisible)
    }

    // MARK: - the verb receipts

    func testReceiptDetailCarriesTheModelState() {
        let model = HostInspector()
        XCTAssertEqual(model.receiptDetail, "open=0 tail=0 saw=0")
        model.isOpen = true
        model.ingest(serialText: "x\n")
        XCTAssertEqual(model.receiptDetail, "open=1 tail=1 saw=0")
    }

    // MARK: - the session window binding

    func testInspectorVerbSlidesTheDrawerViaTheBus() {
        let model = HostInspector()
        let host = HostApplication(serialLog: "/fixture/serial.log", inspector: model, presentWindow: false)
        XCTAssertFalse(host.inspectorVisible)
        XCTAssertEqual(host.commandBus.dispatch(.inspector), .performed)
        XCTAssertTrue(model.isOpen)
        XCTAssertTrue(host.inspectorVisible)
        // And the menu item mirrors the open state as a checkmark.
        let bar = HostMenuBar.build(bus: host.commandBus)
        let item = bar.items.first { $0.submenu?.title == "Debug" }?.submenu?.items.first { $0.title == "Inspector" }
        XCTAssertNotNil(item)
        XCTAssertTrue(host.commandBus.validateMenuItem(item!))
        XCTAssertEqual(item?.state, .on)
        XCTAssertEqual(host.commandBus.dispatch(.inspector), .performed)
        XCTAssertFalse(model.isOpen)
        XCTAssertFalse(host.inspectorVisible)
    }

    func testSendSerialVerbInjectsThroughTheSharedModel() {
        let model = HostInspector()
        var writes: [String] = []
        model.serialSink = { writes.append($0); return true }
        let host = HostApplication(serialLog: "/fixture/serial.log", inspector: model, presentWindow: false)
        // The runner registers send-serial on the bus the session shares;
        // here the equivalent registration proves the seam reaches the
        // same model the drawer edits.
        host.commandBus.register(.sendSerial, HostCommandBus.Registration(
            isEnabled: { model.serialSink != nil },
            receiptDetail: { "sent=\(model.sentCount)" }
        ) { model.inject() ? .performed : .failed })
        model.inputLine = "uname -a"
        XCTAssertEqual(host.commandBus.dispatch(.sendSerial), .performed)
        XCTAssertEqual(writes, ["uname -a"])
        XCTAssertEqual(model.sentCount, 1)
    }

    /// The view projects the model: the tail text renders, the
    /// postmortem card appears on noteStop, the filter narrows it.
    func testDrawerViewProjectsTheModel() {
        let model = HostInspector()
        let bus = HostCommandBus { _ in }
        let view = HostInspectorView(model: model, bus: bus)
        XCTAssertFalse(view.postmortemVisible)
        model.ingest(serialText: "l1\nl2\n")
        view.reload()
        XCTAssertEqual(view.renderedTailText, "l1\nl2")
        model.filter = "l2"
        view.reload()
        XCTAssertEqual(view.renderedTailText, "l2")
        model.noteStop(PostmortemCard(ending: .stopped, state: "3",
                                      reason: "guest-powered-off", serialLines: 2))
        view.reload()
        XCTAssertTrue(view.postmortemVisible)
    }
}
