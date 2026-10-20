import AppKit
import XCTest
@testable import VMAppKit
@testable import VMRunner
import VMProfile

/// M139a (#2779): the multi-VM seams class-A can pin without a VM — the
/// session registry's id mint + `profile_in_use` dedup, the `vm=<n>`
/// word in host-ui receipts, and the `vm<k>:`/`@arg` trigger grammar.
final class MultiVMTests: XCTestCase {
    private final class Sink {
        var lines: [String] = []
    }

    override func setUp() {
        super.setUp()
        VMSessionRegistry.shared.resetForTesting()
    }

    override func tearDown() {
        VMSessionRegistry.shared.resetForTesting()
        super.tearDown()
    }

    private func profileURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name).virelaivm", isDirectory: true)
    }

    // MARK: Registry — ids mint in order, dedup is by bundle path.

    func testRegistryMintsSequentialIDs() {
        let registry = VMSessionRegistry.shared
        let s1 = registry.mint()
        let s2 = registry.mint()
        XCTAssertEqual(s1.id, 1)
        XCTAssertEqual(s2.id, 2)
        XCTAssertEqual(registry.primary?.id, 1)
        XCTAssertEqual(registry.session(id: 2)?.id, 2)
        XCTAssertEqual(registry.live.count, 2)
    }

    func testSessionLookupByProfileAndWindow() throws {
        let registry = VMSessionRegistry.shared
        let s = registry.mint()
        // Dedup keys on the profile object — mint a real bundle so
        // profileURL is what a loaded session would carry.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("multivm-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = dir.appendingPathComponent("ws2.virelaivm", isDirectory: true)
        let profile = try VMProfile.create(at: bundle)
        s.profile = profile
        XCTAssertTrue(registry.session(profileURL: bundle) === s)
        // A non-canonical spelling of the same path still hits.
        let variant = dir.appendingPathComponent("./ws2.virelaivm", isDirectory: true)
        XCTAssertTrue(registry.session(profileURL: variant) === s)
        XCTAssertNil(registry.session(profileURL: profileURL("other")))
        // A stopped session is out of the dedup set.
        s.markStopped()
        XCTAssertNil(registry.session(profileURL: bundle))
    }

    func testDuplicateOpenRefusesByName() {
        let registry = VMSessionRegistry.shared
        let s = registry.mint()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("multivm-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = dir.appendingPathComponent("ws2.virelaivm", isDirectory: true)
        s.profile = try? VMProfile.create(at: bundle)
        XCTAssertEqual(registry.canOpen(bundle), .profileInUse)
        guard case .failure(let dup) = registry.openSession(at: bundle) else {
            return XCTFail("duplicate open was not refused")
        }
        XCTAssertEqual(dup, .profileInUse)
        // An unminted path names a different refusal.
        let missing = dir.appendingPathComponent("missing.virelaivm", isDirectory: true)
        guard case .failure(let invalid) = registry.openSession(at: missing) else {
            return XCTFail("missing bundle was not refused")
        }
        XCTAssertEqual(invalid, .invalidProfile)
    }

    // MARK: Receipts — the vm=<n> word between cmd= and state=.

    func testSessionBoundBusReceiptCarriesVMWord() {
        let sink = Sink()
        let bus = HostCommandBus { sink.lines.append($0) }
        bus.sessionID = 2
        XCTAssertEqual(bus.dispatch(.fullscreen), .unavailable)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=fullscreen vm=2 state=unavailable"])
    }

    func testSessionlessBusKeepsTheM114aForm() {
        let sink = Sink()
        let bus = HostCommandBus { sink.lines.append($0) }
        XCTAssertEqual(bus.dispatch(.fullscreen), .unavailable)
        XCTAssertEqual(sink.lines, ["host-ui: cmd=fullscreen state=unavailable"])
    }

    // MARK: Triggers — vm<k>: binding and the @ operand.

    func testTriggerSessionBindingAndArgument() throws {
        let bound = try XCTUnwrap(HostCommandTrigger("vm2:virelai> :suspend"))
        XCTAssertEqual(bound.session, 2)
        XCTAssertEqual(bound.marker, "virelai> ")
        XCTAssertEqual(bound.command, .suspend)
        XCTAssertNil(bound.argument)

        let arg = try XCTUnwrap(HostCommandTrigger("boot:new-window@/tmp/ws2.virelaivm"))
        XCTAssertNil(arg.session)
        XCTAssertEqual(arg.marker, "boot")
        XCTAssertEqual(arg.command, .newWindow)
        XCTAssertEqual(arg.argument, "/tmp/ws2.virelaivm")

        // Both qualifiers at once; a marker that merely starts with "vm"
        // stays whole.
        let both = try XCTUnwrap(HostCommandTrigger("vm1:ready:quit"))
        XCTAssertEqual(both.session, 1)
        XCTAssertEqual(both.marker, "ready")
        let notBound = try XCTUnwrap(HostCommandTrigger("vmx:ready:quit"))
        XCTAssertNil(notBound.session)
        XCTAssertEqual(notBound.marker, "vmx:ready")
    }

    // MARK: The shared fire — bound triggers pick their session's bus.

    func testFireDispatchesOnBoundSessionOnly() {
        let sink = Sink()
        let bus1 = HostCommandBus { sink.lines.append("b1: \($0)") }
        let bus2 = HostCommandBus { sink.lines.append("b2: \($0)") }
        var t1 = [HostCommandTrigger("m:quit")!]
        var t2 = [HostCommandTrigger("vm2:m:quit")!]
        // The unbound trigger on vm 1's scan fires on bus 1; the vm2-bound
        // one does not.
        fireHostCmdTriggers(&t1, on: bus1, session: 1, text: "x m y")
        fireHostCmdTriggers(&t2, on: bus1, session: 1, text: "x m y")
        fireHostCmdTriggers(&t2, on: bus2, session: 2, text: "x m y")
        XCTAssertEqual(sink.lines, [
            "b1: host-ui: cmd=quit state=unavailable",
            "b2: host-ui: cmd=quit state=unavailable",
        ])
        XCTAssertTrue(t2[0].fired)
    }

    func testNewWindowTriggerStagesTheTarget() {
        let sink = Sink()
        let registry = VMSessionRegistry.shared
        let s = registry.mint()
        let bus = s.commandBus
        bus.emit = { sink.lines.append($0) }
        registry.installNewWindowVerb(on: bus, session: s)
        var triggers = [HostCommandTrigger("boot:new-window@/tmp/does-not-exist.virelaivm")!]
        fireHostCmdTriggers(&triggers, on: bus, session: 1, text: "boot")
        // An unloadable bundle → the named refusal, on the vm=1 receipt.
        XCTAssertTrue(bus.profiles.newWindowTarget == nil)
        XCTAssertTrue(sink.lines.contains { line in
            line.hasPrefix("host-ui: cmd=new-window vm=1 state=disabled reason=profile_invalid")
        }, "\(sink.lines)")
    }
}
