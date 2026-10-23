import AppKit

/// M128a (#2605, index #2556): the machine settings panel's VIEW — a
/// pure projection of HostSettingsModel (the HostInspectorView rule:
/// nothing here owns state). Every control writes the model's draft and
/// Save/Revert ride `model.save()`/`model.revert()` — the same calls a
/// headless `--host-cmd-after …:settings` + model edit performs.
///
/// Each row carries its effect marker — "next boot" for every Config
/// field today (none hot-plug); the marker is per-row so a future live
/// field shows "live" without a shape change.
///
/// Class-A tests construct the view directly and read the field text /
/// marker labels / error line — the no-synthesized-clicks discipline.
public final class HostSettingsView: NSView {
    public let model: HostSettingsModel

    private let titleLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let grid = NSGridView()
    private let cpusField = NSTextField()
    private let memoryField = NSTextField()
    private let baseImageField = NSTextField()
    /// M183c (#3173): the host-preference minutes field — one of the
    /// `.live` host rows below the Config grid.
    private let idleMinutesField = NSTextField()
    /// key → (control, marker label) so tests and reload() index the
    /// rows without walking the grid.
    private var toggles: [String: NSButton] = [:]
    private var markers: [String: NSTextField] = [:]
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let revertButton = NSButton()
    private let saveButton = NSButton()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")

    public init(model: HostSettingsModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 380))

        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathLabel)

        grid.columnSpacing = 10
        grid.rowSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        var gridRows: [[NSView]] = []
        for row in HostSettingsModel.rows + HostSettingsModel.hostRows {
            let label = NSTextField(labelWithString: row.title)
            label.alignment = .right
            let marker = NSTextField(labelWithString: Self.effectMarkerText(row.effect))
            marker.font = .systemFont(ofSize: 10)
            marker.textColor = row.effect == .live ? .systemGreen : .secondaryLabelColor
            markers[row.key] = marker
            let control: NSView
            switch row.key {
            case "cpus":
                cpusField.placeholderString = "1–8"
                cpusField.target = self
                cpusField.action = #selector(fieldCommitted(_:))
                control = cpusField
            case "memoryMiB":
                memoryField.placeholderString = "MiB"
                memoryField.target = self
                memoryField.action = #selector(fieldCommitted(_:))
                control = memoryField
            case "baseImage":
                baseImageField.placeholderString = "artifacts/disk.img"
                baseImageField.target = self
                baseImageField.action = #selector(fieldCommitted(_:))
                control = baseImageField
            case "idlePauseMinutes":
                idleMinutesField.placeholderString = "min"
                idleMinutesField.target = self
                idleMinutesField.action = #selector(fieldCommitted(_:))
                control = idleMinutesField
            default:
                let toggle = NSButton(checkboxWithTitle: "", target: self,
                                    action: #selector(toggleCommitted(_:)))
                toggles[row.key] = toggle
                control = toggle
            }
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
            gridRows.append([label, control, marker])
        }
        for r in gridRows { grid.addRow(with: r) }
        grid.column(at: 0).xPlacement = .trailing

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorLabel)

        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.stringValue = "Changes are written to the profile bundle and take effect on the next boot. Rows marked live are host preferences — they apply immediately and are never written to the bundle."
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noteLabel)

        revertButton.title = "Revert"
        revertButton.bezelStyle = .rounded
        revertButton.target = self
        revertButton.action = #selector(revertPressed(_:))
        revertButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(revertButton)

        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(savePressed(_:))
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(saveButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            pathLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            pathLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            grid.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 12),
            grid.centerXAnchor.constraint(equalTo: centerXAnchor),

            errorLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            noteLabel.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 6),
            noteLabel.leadingAnchor.constraint(equalTo: errorLabel.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: errorLabel.trailingAnchor),

            saveButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            revertButton.bottomAnchor.constraint(equalTo: saveButton.bottomAnchor),
            revertButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            revertButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            noteLabel.bottomAnchor.constraint(lessThanOrEqualTo: saveButton.topAnchor, constant: -10),
        ])

        // The owner drives reload() via model.onChange — one subscriber
        // (HostApplication) repaints every surface, the drawer precedent.
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The marker text a row carries — the restart-vs-live note.
    public static func effectMarkerText(_ effect: HostSettingsModel.Effect) -> String {
        switch effect {
        case .nextRestart: return "next boot"
        case .live: return "live"
        }
    }

    // MARK: Class-A seams — tests read the projection.

    public var titleText: String { titleLabel.stringValue }
    public var errorText: String { errorLabel.stringValue }
    public var saveEnabled: Bool { saveButton.isEnabled }
    public var revertEnabled: Bool { revertButton.isEnabled }
    public var cpusText: String {
        get { cpusField.stringValue }
        set { cpusField.stringValue = newValue }
    }
    public var memoryText: String {
        get { memoryField.stringValue }
        set { memoryField.stringValue = newValue }
    }
    public var baseImageText: String {
        get { baseImageField.stringValue }
        set { baseImageField.stringValue = newValue }
    }
    public func toggleState(_ key: String) -> Bool { toggles[key]?.state == .on }
    public func markerText(_ key: String) -> String { markers[key]?.stringValue ?? "" }

    /// Write every control's current value into the model's draft —
    /// called by each field's commit action and by Save, so a test can
    /// set `cpusText` then `commitFields()` and read the same draft a
    /// real edit produces.
    public func commitFields() {
        model.cpusText = cpusField.stringValue
        model.memoryText = memoryField.stringValue
        model.baseImageText = baseImageField.stringValue
        for (key, button) in toggles {
            setDevice(key, button.state == .on)
        }
        // M183c: the host-preference rows write through on commit —
        // `live` means the store takes the value now, not at save.
        model.idlePauseMinutesText = idleMinutesField.stringValue
        reload()
    }

    private func setDevice(_ key: String, _ on: Bool) {
        switch key {
        case "idlePause": model.idlePauseEnabled = on
        case "display": model.devices.display = on
        case "input": model.devices.input = on
        case "sound": model.devices.sound = on
        case "netNat": model.devices.netNat = on
        case "vsock": model.devices.vsock = on
        case "dataDisk": model.devices.dataDisk = on
        case "share": model.devices.share = on
        default: break
        }
    }

    /// Refresh every projection from the model — called from
    /// `model.onChange` (main queue).
    public func reload() {
        if let profile = model.profile {
            titleLabel.stringValue = "Machine Settings — \(profile.name)"
            pathLabel.stringValue = profile.url.path
        } else {
            titleLabel.stringValue = "Machine Settings"
            pathLabel.stringValue = model.loadError ?? ""
        }
        cpusField.stringValue = model.cpusText
        memoryField.stringValue = model.memoryText
        baseImageField.stringValue = model.baseImageText
        idleMinutesField.stringValue = model.idlePauseMinutesText
        for (key, button) in toggles {
            button.state = deviceValue(key) ? .on : .off
        }
        var problems = model.errors
        if let idleError = model.idlePauseMinutesError { problems.append(idleError) }
        if let loadError = model.loadError { problems.append(loadError) }
        if let lastSaveError = model.lastSaveError { problems.append(lastSaveError) }
        errorLabel.stringValue = problems.joined(separator: "\n")
        saveButton.isEnabled = model.canSave
        revertButton.isEnabled = model.dirty
    }

    private func deviceValue(_ key: String) -> Bool {
        if key == "idlePause" { return model.idlePauseEnabled }
        let d = model.devices
        switch key {
        case "display": return d.display
        case "input": return d.input
        case "sound": return d.sound
        case "netNat": return d.netNat
        case "vsock": return d.vsock
        case "dataDisk": return d.dataDisk
        case "share": return d.share
        default: return false
        }
    }

    @objc private func fieldCommitted(_ sender: NSTextField) { commitFields() }
    @objc private func toggleCommitted(_ sender: NSButton) { commitFields() }

    @objc private func revertPressed(_ sender: NSButton) {
        model.revert()
        reload()
    }

    @objc private func savePressed(_ sender: NSButton) {
        commitFields()
        _ = model.save()
        reload()
    }
}
