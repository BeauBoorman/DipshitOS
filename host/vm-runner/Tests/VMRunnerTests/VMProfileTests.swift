// VMProfileTests — M115c (issue #2462): the .virelaivm bundle contract,
// pinned without a VM. Create, manifest-gated load (missing/corrupt/
// foreign/unsafe members refuse BY NAME), atomic save, round trip.
import XCTest
@testable import VMProfile

final class VMProfileTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmprofile-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A refusal test marks the bundle read-only; restore so cleanup works.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: tmpDir.path)
        for child in (try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path)) ?? [] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: tmpDir.appendingPathComponent(child).path)
        }
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func bundleURL(_ name: String = "test.virelaivm") -> URL {
        tmpDir.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: create

    /// Create lays down the whole skeleton: manifest + config parse, the
    /// share/ and saved-state/ dirs exist, and machine-id.bin is one uuid_t.
    func testCreateWritesBundleSkeleton() throws {
        let url = bundleURL()
        let p = try VMProfile.create(at: url)
        XCTAssertTrue(p.created)
        XCTAssertEqual(p.identity, "org.virelaios.vm.test")
        XCTAssertEqual(p.name, "test")

        XCTAssertTrue(FileManager.default.fileExists(atPath: p.manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.configURL.path))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.shareURL.path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.savedStateURL.path, isDirectory: &isDir) && isDir.boolValue)
        // The identifier's bytes are VZ's shape, not ours — minted by the
        // runner at first boot, so absent on a fresh bundle.
        XCTAssertNil(p.machineIdentifierData())

        // The manifest is self-describing: format tag + the member map.
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: p.manifestURL)) as? [String: Any]
        XCTAssertEqual(raw?["format"] as? String, VMProfile.formatID)
        let members = raw?["members"] as? [String: String]
        XCTAssertEqual(members?["config"], "config.json")
        XCTAssertEqual(members?["efiVars"], "efi-vars.bin")
        XCTAssertEqual(members?["overlay"], "overlay.asif")
        XCTAssertEqual(members?["vlfs"], "vlfs.img")
        XCTAssertEqual(members?["machineIdentifier"], "machine-id.bin")
        XCTAssertEqual(members?["savedState"], "saved-state")
        XCTAssertEqual(members?["share"], "share")
    }

    /// Create never adopts an existing path: a directory already there is
    /// refused by name, a regular file is refused as not-a-bundle.
    func testCreateRefusesExistingPath() throws {
        let url = bundleURL("occupied.virelaivm")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try VMProfile.create(at: url)) { error in
            guard case .missingManifest(let p) = error as? VMProfile.ProfileError else {
                return XCTFail("expected missingManifest, got \(error)")
            }
            XCTAssertEqual(p, url.path)
        }
        let file = bundleURL("afile.virelaivm")
        try Data().write(to: file)
        XCTAssertThrowsError(try VMProfile.create(at: file)) { error in
            guard case .notRegularFile(let p) = error as? VMProfile.ProfileError else {
                return XCTFail("expected notRegularFile, got \(error)")
            }
            XCTAssertEqual(p, file.path)
        }
    }

    // MARK: round trip

    /// A non-default config + identity survives save → load exactly, and the
    /// machine identifier minted at create is the SAME bytes after reload —
    /// the stable identity the bundle exists to pin.
    func testRoundTrip() throws {
        let url = bundleURL("workstation.virelaivm")
        var devices = VMProfile.Devices()
        devices.sound = true
        devices.display = true
        devices.input = true
        devices.netNat = true
        devices.vsock = true
        let config = VMProfile.Config(cpus: 4, memoryMiB: 512,
                                      baseImage: "/abs/path/disk.img", devices: devices)
        let minted = try VMProfile.create(at: url, name: "workstation",
                                          identity: "org.virelaios.vm.workstation",
                                          config: config)
        // The runner mints the identifier via VZ at first boot; persist a
        // blob here and require the SAME bytes after reload — the stable
        // identity the bundle exists to pin.
        let identifier = Data((0..<70).map { UInt8($0) })
        try minted.setMachineIdentifier(identifier)
        let loaded = try VMProfile.load(from: url)
        XCTAssertFalse(loaded.created)
        XCTAssertEqual(loaded.identity, "org.virelaios.vm.workstation")
        XCTAssertEqual(loaded.name, "workstation")
        XCTAssertEqual(loaded.config, config)
        XCTAssertEqual(loaded.members, minted.members)
        XCTAssertEqual(loaded.machineIdentifierData(), identifier,
                       "the machine identifier must not change across loads")
    }

    /// M129a (#2610): the schema's compiled memoryMiB default is 512 —
    /// a config.json that omits the field decodes to it, while a stored
    /// value (a bundle minted before the bump) keeps its own number.
    func testMemoryMiBDecodeDefault() throws {
        XCTAssertEqual(VMProfile.Config().memoryMiB, 512)
        let decoded = try JSONDecoder().decode(
            VMProfile.Config.self,
            from: Data(#"{"cpus": 2, "baseImage": "artifacts/disk.img"}"#.utf8))
        XCTAssertEqual(decoded.memoryMiB, 512)
        let pinned = try JSONDecoder().decode(
            VMProfile.Config.self,
            from: Data(#"{"cpus": 2, "memoryMiB": 256, "baseImage": "artifacts/disk.img"}"#.utf8))
        XCTAssertEqual(pinned.memoryMiB, 256)
    }

    /// Edits persist through save: a mutated config reloads identically.
    func testSavePersistsEdits() throws {
        let url = bundleURL()
        var p = try VMProfile.create(at: url)
        p.config.cpus = 8
        p.config.memoryMiB = 1024
        p.config.devices.vsock = true
        try p.save()
        let reloaded = try VMProfile.load(from: url)
        XCTAssertEqual(reloaded.config.cpus, 8)
        XCTAssertEqual(reloaded.config.memoryMiB, 1024)
        XCTAssertTrue(reloaded.config.devices.vsock)
    }

    // MARK: atomic save

    /// The save is write-tmp-then-rename: when the bundle directory is
    /// read-only the write leg fails and the PREVIOUS manifest survives
    /// byte-identical — never a truncated file — and no temp file leaks.
    func testAtomicSaveFailurePreservesManifest() throws {
        let url = bundleURL()
        var p = try VMProfile.create(at: url)
        let before = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        let manifestBefore = try Data(contentsOf: p.manifestURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: url.path)
        p.config.cpus = 7
        XCTAssertThrowsError(try p.save()) { error in
            guard case .couldNotSave = error as? VMProfile.ProfileError else {
                return XCTFail("expected couldNotSave, got \(error)")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)

        XCTAssertEqual(try Data(contentsOf: p.manifestURL), manifestBefore,
                       "a failed save must leave the old manifest intact")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.path).sorted(),
                       before, "a failed save must not leak a temp file into the bundle")
        // The bundle still loads — the refusal did not poison it.
        XCTAssertNoThrow(try VMProfile.load(from: url))
    }

    /// A successful save swaps the file wholesale: manifest and config are
    /// both re-written and still parse.
    func testSaveIsAtomicWholesale() throws {
        let url = bundleURL()
        var p = try VMProfile.create(at: url)
        p.name = "renamed"
        p.config.cpus = 1
        try p.save()
        let loaded = try VMProfile.load(from: url)
        XCTAssertEqual(loaded.name, "renamed")
        XCTAssertEqual(loaded.config.cpus, 1)
    }

    // MARK: manifest refusals

    /// A directory with no manifest refuses by NAME — the error carries the
    /// manifest path, not just "missing".
    func testMissingManifestRefusesByName() throws {
        let url = bundleURL("bare.virelaivm")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try VMProfile.load(from: url)) { error in
            guard case .missingManifest(let p) = error as? VMProfile.ProfileError else {
                return XCTFail("expected missingManifest, got \(error)")
            }
            XCTAssertEqual(p, url.appendingPathComponent("manifest.json").path)
        }
    }

    /// Undecodable manifest bytes refuse as corrupt, naming the file.
    func testCorruptManifestRefusesByName() throws {
        let url = bundleURL()
        _ = try VMProfile.create(at: url)
        let manifest = url.appendingPathComponent("manifest.json")
        try Data("not json {{{".utf8).write(to: manifest)
        XCTAssertThrowsError(try VMProfile.load(from: url)) { error in
            guard case .corruptManifest(let p) = error as? VMProfile.ProfileError else {
                return XCTFail("expected corruptManifest, got \(error)")
            }
            XCTAssertEqual(p, manifest.path)
        }
    }

    /// A well-formed manifest with a foreign format tag refuses by name —
    /// a future format is never silently misread.
    func testForeignFormatRefuses() throws {
        let url = bundleURL()
        _ = try VMProfile.create(at: url)
        let manifest = url.appendingPathComponent("manifest.json")
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        raw["format"] = "virelaivm/999"
        try JSONSerialization.data(withJSONObject: raw).write(to: manifest)
        XCTAssertThrowsError(try VMProfile.load(from: url)) { error in
            XCTAssertEqual(error as? VMProfile.ProfileError, .unsupportedFormat("virelaivm/999"))
        }
    }

    /// A member name that escapes the bundle is a corrupt manifest — load
    /// must never let a hand-edited manifest redirect vlfs.img to ../..
    func testUnsafeMemberRefuses() throws {
        let url = bundleURL()
        _ = try VMProfile.create(at: url)
        let manifest = url.appendingPathComponent("manifest.json")
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        var members = raw["members"] as! [String: String]
        members["vlfs"] = "../escape.img"
        raw["members"] = members
        try JSONSerialization.data(withJSONObject: raw).write(to: manifest)
        XCTAssertThrowsError(try VMProfile.load(from: url)) { error in
            guard case .corruptManifest(let p) = error as? VMProfile.ProfileError else {
                return XCTFail("expected corruptManifest, got \(error)")
            }
            XCTAssertEqual(p, manifest.path)
        }
    }

    /// A corrupt config member refuses by name too, and an out-of-shape
    /// value (cpus outside the runner's 1...8 bound) is the same refusal.
    func testCorruptConfigRefusesByName() throws {
        let url = bundleURL()
        _ = try VMProfile.create(at: url)
        let config = url.appendingPathComponent("config.json")
        try Data("[]".utf8).write(to: config)
        XCTAssertThrowsError(try VMProfile.load(from: url)) { error in
            guard case .corruptConfig(let p) = error as? VMProfile.ProfileError else {
                return XCTFail("expected corruptConfig, got \(error)")
            }
            XCTAssertEqual(p, config.path)
        }
        try Data(#"{"cpus": 99, "memoryMiB": 256, "baseImage": "artifacts/disk.img"}"#.utf8)
            .write(to: config)
        XCTAssertThrowsError(try VMProfile.load(from: url)) { error in
            guard case .corruptConfig = error as? VMProfile.ProfileError else {
                return XCTFail("expected corruptConfig, got \(error)")
            }
        }
    }

    // MARK: openOrCreate

    /// The runner's semantics: absent path mints, a minted bundle loads
    /// (and re-loading keeps the SAME identity + machine identifier), and
    /// an existing non-bundle directory refuses.
    func testOpenOrCreate() throws {
        let url = bundleURL()
        let first = try VMProfile.openOrCreate(at: url)
        XCTAssertTrue(first.created)
        try first.setMachineIdentifier(Data(repeating: 0xAB, count: 70))
        let second = try VMProfile.openOrCreate(at: url)
        XCTAssertFalse(second.created)
        XCTAssertEqual(second.identity, first.identity)
        XCTAssertEqual(second.machineIdentifierData(), Data(repeating: 0xAB, count: 70))

        let intruder = tmpDir.appendingPathComponent("not-a-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: intruder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: intruder.appendingPathComponent("README"))
        XCTAssertThrowsError(try VMProfile.openOrCreate(at: intruder)) { error in
            guard case .missingManifest = error as? VMProfile.ProfileError else {
                return XCTFail("expected missingManifest, got \(error)")
            }
        }
    }

    // MARK: M128b (#2606): clone + overlay reset

    /// The safety-net leg: clone mints a NEW bundle carrying config +
    /// share/ verbatim — and nothing else. Fresh identity, fresh dirs,
    /// no overlay.asif (re-minted over the base on first boot), no
    /// vlfs/efi-vars/machine-id — a clean test VM, not a disk fork.
    func testCloneCopiesConfigAndShareOnly() throws {
        let url = bundleURL("workstation.virelaivm")
        let src = try VMProfile.create(
            at: url, name: "workstation",
            config: VMProfile.Config(cpus: 4, memoryMiB: 512, baseImage: "/abs/disk.img"))
        try src.setMachineIdentifier(Data(repeating: 0xAB, count: 70))
        try Data("overlay-bytes".utf8).write(to: src.overlayURL)
        try Data("efi".utf8).write(to: src.efiVarsURL)
        try Data("vlfs".utf8).write(to: src.vlfsURL)
        try Data("notes".utf8).write(to: src.shareURL.appendingPathComponent("NOTES.TXT"))
        try FileManager.default.createDirectory(
            at: src.shareURL.appendingPathComponent("APPS"), withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: src.shareURL.appendingPathComponent("APPS/GO.ELF"))

        let cloneURL = bundleURL("workstation-copy.virelaivm")
        let clone = try src.clone(to: cloneURL)
        XCTAssertTrue(clone.created)
        XCTAssertEqual(clone.name, "workstation-copy")
        XCTAssertEqual(clone.config, src.config)
        XCTAssertNotEqual(clone.identity, src.identity)

        // share/ survives verbatim, recursively.
        XCTAssertEqual(try Data(contentsOf: clone.shareURL.appendingPathComponent("NOTES.TXT")),
                       Data("notes".utf8))
        XCTAssertEqual(try Data(contentsOf: clone.shareURL.appendingPathComponent("APPS/GO.ELF")),
                       Data("bin".utf8))
        // Nothing else rode over: fresh overlay/vars/vlfs/machine-id.
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.overlayURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.vlfsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clone.efiVarsURL.path))
        XCTAssertNil(clone.machineIdentifierData())
        // The clone loads as an ordinary bundle.
        XCTAssertEqual(try VMProfile.load(from: cloneURL).name, "workstation-copy")
        // And the source is untouched.
        XCTAssertEqual(src.machineIdentifierData(), Data(repeating: 0xAB, count: 70))
    }

    /// Clone refuses an occupied path by name — same contract as create.
    func testCloneRefusesExistingPath() throws {
        let src = try VMProfile.create(at: bundleURL())
        let occupied = bundleURL("occupied.virelaivm")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        XCTAssertThrowsError(try src.clone(to: occupied)) { error in
            guard case .missingManifest = error as? VMProfile.ProfileError else {
                return XCTFail("expected missingManifest, got \(error)")
            }
        }
    }

    /// Reset removes the persistent overlay so the attach point re-mints
    /// a fresh ASIF layer next boot; an absent overlay is already-reset.
    func testResetOverlayRemovesMember() throws {
        let p = try VMProfile.create(at: bundleURL())
        XCTAssertFalse(try p.resetOverlay()) // nothing yet — idempotent
        try Data("wedge".utf8).write(to: p.overlayURL)
        XCTAssertTrue(try p.resetOverlay())
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.overlayURL.path))
        // Only the overlay went — the bundle still loads and share/ lives.
        XCTAssertNoThrow(try VMProfile.load(from: p.url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.shareURL.path))
    }

    /// The identity key the session app stamps as CFBundleIdentifier:
    /// deterministic from the name, bundle-idish, and lowercase-safe.
    func testDefaultIdentityIsStableAndSafe() {
        XCTAssertEqual(VMProfile.defaultIdentity(for: "My VM"), "org.virelaios.vm.my-vm")
        XCTAssertEqual(VMProfile.defaultIdentity(for: " Weird__Name!! "),
                       "org.virelaios.vm.weird-name")
        XCTAssertEqual(VMProfile.defaultIdentity(for: "!!!"), "org.virelaios.vm.profile")
    }
    /// M157a (#2934): the close policy key — absent decodes to stop,
    /// "suspend" round-trips through the bundle, and a foreign word
    /// refuses the config load as corrupt (the manifest's own naming
    /// rule — never a silent default).
    func testCloseActionParsesDefaultsAndRefusesForeign() throws {
        XCTAssertEqual(VMProfile.Config().closeAction, .stop)
        let decoded = try JSONDecoder().decode(
            VMProfile.Config.self,
            from: Data(#"{"closeAction": "suspend"}"#.utf8))
        XCTAssertEqual(decoded.closeAction, .suspend)
        let url = bundleURL()
        var p = try VMProfile.create(at: url)
        XCTAssertEqual(p.config.closeAction, .stop)
        p.config.closeAction = .suspend
        try p.save()
        XCTAssertEqual(try VMProfile.load(from: url).config.closeAction, .suspend)
        try Data(#"{"cpus": 2, "memoryMiB": 256, "baseImage": "x", "closeAction": "hibernate"}"#.utf8)
            .write(to: url.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try VMProfile.load(from: url)) { error in
            guard case .corruptConfig = error as? VMProfile.ProfileError else {
                return XCTFail("expected corruptConfig, got \(error)")
            }
        }
    }
}
