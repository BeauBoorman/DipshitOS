import AppKit

/// M114d (#2457, index #2447): the inspector drawer's VIEW — a pure
/// projection of HostInspector. Every control rides the model or the
/// bus: the filter field edits `model.filter`, the injector field arms
/// `model.inputLine` and its Send dispatches `send-serial`, and nothing
/// here owns state of its own (index theses 1–2: the bus is the seam;
/// the window surfaces what already exists).
///
/// Class-A tests construct the view directly and read `postmortemVisible`
/// / the rendered tail — the same "no synthesized clicks" discipline the
/// menu-bar tests use.
public final class HostInspectorView: NSView {
    public let model: HostInspector
    private weak var bus: HostCommandBus?

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

    /// The last strings actually rendered — reload() is called on every
    /// model change, so it diffs instead of clobbering the text view
    /// (and the operator's scroll position) twice a second.
    private var renderedTail = ""
    private var renderedCard = ""
    private var renderedAgent = ""

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

        filterField.placeholderString = "Filter serial tail…"
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterEdited(_:))
        filterField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filterField)

        countersLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        countersLabel.textColor = .secondaryLabelColor
        countersLabel.lineBreakMode = .byTruncatingMiddle
        countersLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countersLabel)

        inputField.placeholderString = "guest command — Enter or Send injects it"
        inputField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        inputField.target = self
        inputField.action = #selector(sendPressed(_:))
        inputField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputField)

        sendButton.title = "Send"
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendPressed(_:))
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sendButton)

        tailView.isEditable = false
        tailView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tailView.textContainerInset = NSSize(width: 6, height: 6)
        tailView.textContainer?.widthTracksTextView = true
        tailView.autoresizingMask = [.width]
        scroll.documentView = tailView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

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
        addSubview(agentBox)

        NSLayoutConstraint.activate([
            cardBox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            cardBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cardBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cardStack.topAnchor.constraint(equalTo: cardBox.contentView!.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: cardBox.contentView!.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: cardBox.contentView!.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: cardBox.contentView!.bottomAnchor),

            filterField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            filterField.widthAnchor.constraint(equalToConstant: 200),

            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            sendButton.widthAnchor.constraint(equalToConstant: 64),
            inputField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            inputField.widthAnchor.constraint(equalToConstant: 260),

            countersLabel.leadingAnchor.constraint(equalTo: filterField.trailingAnchor, constant: 12),
            countersLabel.trailingAnchor.constraint(lessThanOrEqualTo: inputField.leadingAnchor, constant: -12),

            sendButton.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            inputField.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),
            countersLabel.centerYAnchor.constraint(equalTo: filterField.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            agentBox.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 8),
            agentBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            agentBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            agentBox.widthAnchor.constraint(equalToConstant: 380),
            agentScroll.widthAnchor.constraint(equalTo: agentBox.widthAnchor),
        ])
        // The tail's trailing edge pins to the agent pane while it shows
        // and to the drawer's edge while it does not — one of the two is
        // always active.
        tailTrailingAgent = scroll.trailingAnchor.constraint(equalTo: agentBox.leadingAnchor, constant: -8)
        tailTrailingEdge = scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        // The header rows pin below the card while it shows and below the
        // drawer top while it does not — one of the two is always active.
        cardTop = filterField.topAnchor.constraint(equalTo: cardBox.bottomAnchor, constant: 8)
        collapsedTop = filterField.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The filter row's two top anchors — exactly one active at a time.
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

    @objc private func filterEdited(_ sender: NSSearchField) {
        model.filter = sender.stringValue
    }

    /// Send rides the bus — the field arms the model's input line and
    /// dispatches `send-serial`, the identical dispatch a
    /// `--host-cmd-after …:send-serial` trigger performs.
    @objc private func sendPressed(_ sender: NSControl) {
        model.inputLine = inputField.stringValue
        bus?.dispatch(.sendSerial)
    }
}
