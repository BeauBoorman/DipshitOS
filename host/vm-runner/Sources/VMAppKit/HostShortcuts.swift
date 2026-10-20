import AppKit

/// M122d (#2573, index #2550): the ⌘/ cheat sheet's MODEL — the
/// companion the bus self-registers `shortcuts` on (the recorder/agent/
/// settings precedent), so a bare `HostCommandBus()` in a scripted
/// `--host-cmd-after` run dispatches the identical seam the Help menu's
/// chord does and receipts `performed open=N chords=N`.
///
/// The rows are GENERATED from HostMenuBar's command table — the menu
/// and the sheet are two projections of the one list, so the sheet can
/// never advertise a chord the menus do not know (index thesis 3:
/// discoverability means the cheat sheet is the honest map of every
/// host chord, not a hand-kept picture of some of them).
///
/// All access is main-queue (the bus and the window both are), so the
/// model takes no lock — the HostCommandBus precedent.
public final class HostShortcutsModel {
    /// One row the sheet renders: the chord's glyphs, the leaf's title,
    /// and the verb it dispatches (kept so a surface can say what a row
    /// DOES, not only what it is called).
    public struct Row {
        public let chord: String
        public let title: String
        public let command: HostCommand
    }

    /// Open/closed — the `shortcuts` verb toggles it in every mode: the
    /// session window mirrors it with the panel; headless it is still
    /// honest model state the receipt reports (the inspector's isOpen
    /// precedent).
    public var isOpen = false { didSet { changed() } }

    /// Model → view notification (main queue, the HostInspector rule).
    public var onChange: (() -> Void)?

    public init() {}

    /// The sheet's rows — every menu leaf carrying a chord, in menu
    /// order. Recomputed on read so the projection is always the live
    /// table's.
    public var rows: [Row] {
        HostMenuBar.chords.map {
            Row(chord: $0.chordDisplay, title: $0.title, command: $0.command)
        }
    }

    /// The `shortcuts` receipt tail — the post-action truth a gate
    /// reads: `open=N chords=N` (the `capture=on|off` precedent).
    public var receiptDetail: String {
        "open=\(isOpen ? 1 : 0) chords=\(rows.count)"
    }

    /// The verb's action — flip the sheet, report the post-action truth.
    @discardableResult
    public func toggle() -> HostCommandBus.Outcome {
        isOpen.toggle()
        return .performed
    }

    private func changed() { onChange?() }
}

/// M122d (#2573): the cheat sheet's VIEW — a pure projection of
/// HostShortcutsModel (the HostInspectorView rule: nothing here owns
/// state). One grid row per model row: action title on the left, the
/// chord's glyphs on the right. Class-A tests read the row labels
/// rather than poking AppKit.
public final class HostShortcutsView: NSView {
    public let model: HostShortcutsModel

    private let titleLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let grid = NSGridView()
    private var chordLabels: [NSTextField] = []
    private var titleLabels: [NSTextField] = []

    public init(model: HostShortcutsModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 320))

        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        grid.columnSpacing = 18
        grid.rowSpacing = 7
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noteLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            grid.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            grid.centerXAnchor.constraint(equalTo: centerXAnchor),

            noteLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            noteLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            noteLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            noteLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Class-A seams — tests read the projection.

    public var titleText: String { titleLabel.stringValue }
    public var rowCount: Int { titleLabels.count }
    public func rowTitle(_ i: Int) -> String { titleLabels[i].stringValue }
    public func rowChord(_ i: Int) -> String { chordLabels[i].stringValue }

    /// Rebuild the grid from the model's rows — the table is static
    /// today, but the projection is the model's rows, not a copy made
    /// at init (the HostSettingsView.reload precedent).
    public func reload() {
        titleLabel.stringValue = "Keyboard Shortcuts"
        noteLabel.stringValue = "Every host chord, generated from the same command table the menus are."
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        chordLabels = []
        titleLabels = []
        for row in model.rows {
            let title = NSTextField(labelWithString: row.title)
            let chord = NSTextField(labelWithString: row.chord)
            chord.font = .systemFont(ofSize: 12, weight: .semibold)
            chord.alignment = .right
            titleLabels.append(title)
            chordLabels.append(chord)
            grid.addRow(with: [title, chord])
        }
        if grid.numberOfColumns > 1 { grid.column(at: 1).xPlacement = .trailing }
    }
}
