import AppKit

/// M114d (#2457, index #2447): the inspector drawer's VIEW — a pure
/// projection of HostInspector. Every control rides the model or the
/// bus: the filter field edits `model.filter`, the injector field arms
/// `model.inputLine` and its Send dispatches `send-serial`, and nothing
/// here owns state of its own (index theses 1–2: the bus is the seam;
/// the window surfaces what already exists).
///
/// M157b (#2935, index #2909): the drawer is two tabs — SERIAL (the
/// original tail + injector + AGENTD pane) and TRACE (the tracer's
/// rows with pid/syscall filters, pause, resume and clear). The tab
/// control swaps which page shows; both pages project the same
/// HostInspector, so a verb receipt reads the model regardless of
/// which tab is up.
///
/// Class-A tests construct the view directly and read `postmortemVisible`
/// / the rendered tail / `renderedTraceText` — the same "no synthesized
/// clicks" discipline the menu-bar tests use; `selectTab` is the tab
/// seam, not a click on the segmented control.
public final class HostInspectorView: NSView {
    /// The drawer's two tabs.
    public enum Tab {
        case serial
        case trace
    }

    public let model: HostInspector
    private weak var bus: HostCommandBus?

    private let tabControl = NSSegmentedControl()
    private let serialPage = NSView()
    private let tracePage = NSView()

    private let filterField = NSSearchField()
    private let countersLabel = NSTextField(labelWithString: "")
    private let inputField = NSTextField()
    private let sendButton = NSButton()
    private let scroll = NSScrollView()
    private let tailView = NSTextView()
    private let cardBox = NSBox()
    private let cardTitle = NSTextField(labelWithString: "")
    private let cardBody = NSTextField(wrappingLabelWithString: "")
    /// M127e (#2603): the AGENTD sub-pane — the receipt lane's rows
    /// beside the serial tail, a pure projection of `bus.agent` (the
    /// same model the pill and the lane-agent verb read). Hidden when
    /// no companion is armed.
    private let agentBox = NSStackView()
    private let agentHeader = NSTextField(labelWithString: "")
    private let agentScroll = NSScrollView()
    private let agentView = NSTextView()

    /// The Trace tab's controls: the two filters edit the tracer's
    /// filter text live, Pause/Resume toggles `tracer.paused`, Clear
    /// empties the ring — all model operations, like Send.
    private let pidField = NSSearchField()
    private let sysField = NSSearchField()
    private let pauseButton = NSButton()
    private let clearButton = NSButton()
    private let traceStats = NSTextField(labelWithString: "")
    private let traceScroll = NSScrollView()
    private let traceView = NSTextView()

    /// The last strings actually rendered — reload() is called on every
    /// model change, so it diffs instead of clobbering the text view
    /// (and the operator's scroll position) twice a second.
    private var renderedTail = ""
    private var renderedCard = ""
    private var renderedAgent = ""
    private var renderedTrace = ""

    /// Which tab is on screen — the class-A seam; `selectTab` is the
    /// only mutator.
    public private(set) var selectedTab: Tab = .serial

    public init(model: HostInspector, bus: HostCommandBus) {
        self.model = model
        self.bus = bus
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 260))

        cardBox.titlePosition = .noTitle
        cardBox.borderColor = .systemOrange
        cardBox.borderWidth = 1.5
        cardBox.cornerRadius = 6
        cardBox.contentViewMargins = NSSize(width: 10, height: 6)
        cardBox.translatesAutoresizingMaskIntoConstraints = false
        cardTitle.font = .systemFont(ofSize: 12, weight: .bold)
        cardTitle.textColor = .systemOrange
        cardBody.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cardBody.textColor = .secondaryLabelColor
        let cardStack = NSStackView(views: [cardTitle, cardBody])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 2
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        cardBox.addSubview(cardStack)
        addSubview(cardBox)
        cardBox.isHidden = true

        tabControl.segmentCount = 2
        tabControl.setLabel("Serial", forSegment: 0)
        tabControl.setLabel("Trace", forSegment: 1)
        tabControl.selectedSegment = 0
        tabControl.target = self
        tabControl.action = #selector(tabEdited(_:))
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabControl)

        serialPage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(serialPage)
        tracePage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tracePage)
        tracePage.isHidden = true

        filterField.placeholderString = "Filter serial tail…"
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterEdited(_:))
        filterField.translatesAutoresizingMaskIntoConstraints = false
        serialPage.addSubview(filterField)

        countersLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        countersLabel.textColor = .secondaryLabelColor
        countersLabel.lineBreakMode = .byTruncatingMiddle
        countersLabel.translatesAutoresizingMaskIntoConstraints = false
        serialPage.addSubview(countersLabel)

        inputField.placeholderString = "guest command — Enter or Send injects it"
        inputField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        inputField.target = self
        inputField.action = #selector(sendPressed(_:))
        inputField.translatesAutoresizingMaskIntoConstraints = false
        serialPage.addSubview(inputField)

        sendButton.title = "Send"
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendPressed(_:))
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        serialPage.addSubview(sendButton)

        tailView.isEditable = false
        tailView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tailView.textContainerInset = NSSize(width: 6, height: 6)
        tailView.textContainer?.widthTracksTextView = true
        tailView.autoresizingMask = [.width]
        scroll.documentView = tailView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        serialPage.addSubview(scroll)

        agentHeader.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        agentHeader.textColor = .secondaryLabelColor
        agentHeader.lineBreakMode = .byTruncatingTail
        agentView.isEditable = false
        agentView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        agentView.textContainerInset = NSSize(width: 6, height: 6)
        agentView.textContainer?.widthTracksTextView = true
        agentView.autoresizingMask = [.width]
        agentScroll.documentView = agentView
        agentScroll.hasVerticalScroller = true
        agentScroll.drawsBackground = false
        agentBox.orientation = .vertical
        agentBox.alignment = .leading
        agentBox.spacing = 4
        agentBox.addArrangedSubview(agentHeader)
        agentBox.addArrangedSubview(agentScroll)
        agentBox.translatesAutoresizingMaskIntoConstraints = false
        serialPage.addSubview(agentBox)

        pidField.placeholderString = "pid"
        pidField.sendsSearchStringImmediately = true
        pidField.target = self
        pidField.action = #selector(pidEdited(_:))
        pidField.translatesAutoresizingMaskIntoConstraints = false
        tracePage.addSubview(pidField)

        sysField.placeholderString = "syscall"
        sysField.sendsSearchStringImmediately = true
        sysField.target = self
        sysField.action = #selector(sysEdited(_:))
        sysField.translatesAutoresizingMaskIntoConstraints = false
        tracePage.addSubview(sysField)

        pauseButton.title = "Pause"
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(pausePressed(_:))
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        tracePage.addSubview(pauseButton)

        clearButton.title = "Clear"
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearPressed(_:))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        tracePage.addSubview(clearButton)

        traceStats.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        traceStats.textColor = .secondaryLabelColor
        traceStats.lineBreakMode = .byTruncatingMiddle
        traceStats.translatesAutoresizingMaskIntoConstraints = false
        tracePage.addSubview(traceStats)

        traceView.isEditable = false
        traceView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        traceView.textContainerInset = NSSize(width: 6, height: 6)
        traceView.textContainer?.widthTracksTextView = true
        traceView.autoresizingMask = [.width]
        traceScroll.documentView = traceView
        traceScroll.hasVerticalScroller = true
        traceScroll.drawsBackground = false
        traceScroll.translatesAutoresizingMaskIntoConstraints = false
        tracePage.addSubview(traceScroll)

        NSLayoutConstraint.activate([
            cardBox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            cardBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cardBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cardStack.topAnchor.constraint(equalTo: cardBox.contentView!.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: cardBox.contentView!.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: cardBox.contentView!.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: cardBox.contentView!.bottomAnchor),

            tabControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),

            serialPage.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 8),
            serialPage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            serialPage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            serialPage.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            tracePage.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 8),
            tracePage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            tracePage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            tracePage.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            filterField.topAnchor.constraint(equalTo: serialPage.topAnchor),
            filterField.leadingAnchor.constraint(equalTo: serialPage.leadingAnchor),
            filterField.widthAnchor.constraint(equalToConstant: 200),

            sendButton.trailingAnchor.constraint(equalTo: serialPage.trailingAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 64),
            inputField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            inputField.widthAnchor.constraint(equalToConstant: 260),

            countersLabel.leadingAnchor.constraint(equalTo: filterField.trailingAnchor, constant: 12),
            countersLabel.trailingAnchor.constraint(lessThanOrEqualTo: inputField.leadingAnchor, constant: -12),

            sendButton.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            inputField.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            countersLabel.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: serialPage.leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: serialPage.bottomAnchor),

            agentBox.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 8),
            agentBox.trailingAnchor.constraint(equalTo: serialPage.trailingAnchor),
            agentBox.bottomAnchor.constraint(equalTo: serialPage.bottomAnchor),
            agentBox.widthAnchor.constraint(equalToConstant: 380),
            agentScroll.widthAnchor.constraint(equalTo: agentBox.widthAnchor),

            pidField.topAnchor.constraint(equalTo: tracePage.topAnchor),
            pidField.leadingAnchor.constraint(equalTo: tracePage.leadingAnchor),
            pidField.widthAnchor.constraint(equalToConstant: 90),

            sysField.leadingAnchor.constraint(equalTo: pidField.trailingAnchor, constant: 8),
            sysField.widthAnchor.constraint(equalToConstant: 180),
            sysField.centerYAnchor.constraint(equalTo: pidField.centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: tracePage.trailingAnchor),
            clearButton.centerYAnchor.constraint(equalTo: pidField.centerYAnchor),
            pauseButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),
            pauseButton.centerYAnchor.constraint(equalTo: pidField.centerYAnchor),

            traceStats.leadingAnchor.constraint(equalTo: sysField.trailingAnchor, constant: 12),
            traceStats.trailingAnchor.constraint(lessThanOrEqualTo: pauseButton.leadingAnchor, constant: -12),
            traceStats.centerYAnchor.constraint(equalTo: pidField.centerYAnchor),

            traceScroll.topAnchor.constraint(equalTo: pidField.bottomAnchor, constant: 8),
            traceScroll.leadingAnchor.constraint(equalTo: tracePage.leadingAnchor),
            traceScroll.trailingAnchor.constraint(equalTo: tracePage.trailingAnchor),
            traceScroll.bottomAnchor.constraint(equalTo: tracePage.bottomAnchor),
        ])
        // The tail's trailing edge pins to the agent pane while it shows
        // and to the page's edge while it does not — one of the two is
        // always active.
        tailTrailingAgent = scroll.trailingAnchor.constraint(equalTo: agentBox.leadingAnchor, constant: -8)
        tailTrailingEdge = scroll.trailingAnchor.constraint(equalTo: serialPage.trailingAnchor)
        // The tab row pins below the card while it shows and below the
        // drawer top while it does not — one of the two is always active.
        cardTop = tabControl.topAnchor.constraint(equalTo: cardBox.bottomAnchor, constant: 8)
        collapsedTop = tabControl.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The tab row's two top anchors — exactly one active at a time.
    private var cardTop: NSLayoutConstraint!
    private var collapsedTop: NSLayoutConstraint!
    /// The tail's two trailing anchors — the agent pane takes the right
    /// side when a companion is armed.
    private var tailTrailingAgent: NSLayoutConstraint!
    private var tailTrailingEdge: NSLayoutConstraint!

    /// Whether the postmortem card is on screen — the class-A seam.
    public var postmortemVisible: Bool { !cardBox.isHidden }

    /// The tail text the view is currently rendering — tests read the
    /// projection rather than the raw model.
    public var renderedTailText: String { renderedTail }

    /// The agent sub-pane's seams — whether the pane is on screen, the
    /// summary it renders, and its receipt text. Tests read the
    /// projection rather than the raw model.
    public var agentSubpaneVisible: Bool { !agentBox.isHidden }
    public var agentSummaryText: String { agentHeader.stringValue }
    public var renderedAgentText: String { renderedAgent }

    /// The Trace tab's seams — the rows projection, the counter row,
    /// and the Pause button's live title. Tests read the projection
    /// rather than the raw model.
    public var renderedTraceText: String { renderedTrace }
    public var traceStatsText: String { traceStats.stringValue }
    public var tracePausedTitle: String { pauseButton.title }

    /// The tab seam — what the segmented control's action calls. The
    /// hidden page stays a live projection (reload still diffs it), so
    /// swapping tabs is a visibility flip, never a rebuild.
    public func selectTab(_ tab: Tab) {
        selectedTab = tab
        tabControl.selectedSegment = tab == .trace ? 1 : 0
        serialPage.isHidden = tab != .serial
        tracePage.isHidden = tab != .trace
        reload()
    }

    /// Refresh every projection from the model. Called from
    /// `model.onChange` (main queue, the polls' cadence).
    public func reload() {
        let tail = model.filteredLines.joined(separator: "\n")
        if tail != renderedTail {
            renderedTail = tail
            tailView.string = tail
            tailView.scrollToEndOfDocument(nil)
        }
        countersLabel.stringValue = model.hostIntSummary
        // The agent sub-pane: armed companions project their summary +
        // flagged receipt rows; a shareless/agentless run hides it.
        let agent = bus?.agent
        let armed = agent?.companionArmed ?? false
        agentBox.isHidden = !armed
        tailTrailingAgent.isActive = armed
        tailTrailingEdge.isActive = !armed
        if armed, let agent {
            agentHeader.stringValue = "AGENTD — \(agent.agentSummary)"
            let rows = agent.receiptRows.joined(separator: "\n")
            if rows != renderedAgent {
                renderedAgent = rows
                agentView.string = rows
                agentView.scrollToEndOfDocument(nil)
            }
        }
        // The trace projection: filteredRows is the tab's truth —
        // `#<seq>` names the row's place in the feed, then the line
        // re-renders in the serial envelope it arrived in.
        let trace = model.tracer.filteredRows.map { row in
            var text = "#\(row.sequence) [strace \(row.pid)] \(row.syscall)(\(row.arguments))"
            if !row.result.isEmpty { text += " = \(row.result)" }
            return text
        }.joined(separator: "\n")
        if trace != renderedTrace {
            renderedTrace = trace
            traceView.string = trace
            traceView.scrollToEndOfDocument(nil)
        }
        traceStats.stringValue = model.tracer.statsSummary
            + (model.tracer.paused ? " PAUSED" : "")
        pauseButton.title = model.tracer.paused ? "Resume" : "Pause"
        let card = model.postmortem
        cardBox.isHidden = card == nil
        cardTop.isActive = card != nil
        collapsedTop.isActive = card == nil
        if let card {
            let body = card.rows.joined(separator: "\n")
            let stamp = "\(card.title)\n\(body)"
            if stamp != renderedCard {
                renderedCard = stamp
                cardTitle.stringValue = card.title
                cardBody.stringValue = body
            }
        }
    }

    @objc private func tabEdited(_ sender: NSSegmentedControl) {
        selectTab(sender.selectedSegment == 1 ? .trace : .serial)
    }

    @objc private func filterEdited(_ sender: NSSearchField) {
        model.filter = sender.stringValue
    }

    @objc private func pidEdited(_ sender: NSSearchField) {
        model.tracer.pidFilterText = sender.stringValue
    }

    @objc private func sysEdited(_ sender: NSSearchField) {
        model.tracer.syscallFilter = sender.stringValue
    }

    @objc private func pausePressed(_ sender: NSButton) {
        model.tracer.paused.toggle()
    }

    @objc private func clearPressed(_ sender: NSButton) {
        model.tracer.clear()
    }

    /// Send rides the bus — the field arms the model's input line and
    /// dispatches `send-serial`, the identical dispatch a
    /// `--host-cmd-after …:send-serial` trigger performs.
    @objc private func sendPressed(_ sender: NSControl) {
        model.inputLine = inputField.stringValue
        bus?.dispatch(.sendSerial)
    }
}
