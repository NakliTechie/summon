#if canImport(AppKit)
import AppKit
import SummonCore

/// First-run intro: four skippable native screens. The launcher stays usable the
/// whole time; this never installs or downloads anything on its own — the only
/// heavy action (full web search) is an explicit, opt-in checkbox on the last
/// screen that kicks off the background installer. Content comes from
/// `OnboardingScript`; visuals are drawn natively from `Tokens`.
@MainActor
public final class OnboardingWindowController {
    public struct Actions {
        public var setLoginItem: (Bool) -> Void
        public var requestAccessibility: () -> Void
        public var enableWebSearch: (@escaping @MainActor (WebSearchInstaller.Phase) -> Void) -> Void
        public var onFinish: () -> Void
        public init(
            setLoginItem: @escaping (Bool) -> Void,
            requestAccessibility: @escaping () -> Void,
            enableWebSearch: @escaping (@escaping @MainActor (WebSearchInstaller.Phase) -> Void) -> Void,
            onFinish: @escaping () -> Void
        ) {
            self.setLoginItem = setLoginItem
            self.requestAccessibility = requestAccessibility
            self.enableWebSearch = enableWebSearch
            self.onFinish = onFinish
        }
    }

    private let steps = OnboardingScript.steps
    private let actions: Actions
    private var index: Int
    private var finished = false
    private var window: NSWindow?

    // Reused controls.
    private let headline = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let visualBox = NSView()
    private let webStatus = NSTextField(labelWithString: "")
    private let skipButton = NSButton()
    private let nextButton = NSButton()
    private var dots: [NSView] = []

    // Slide-4 opt-in state.
    private var wantLogin = true
    private var wantAccessibility = true

    public init(actions: Actions, startIndex: Int = 0) {
        self.actions = actions
        self.index = max(0, min(startIndex, OnboardingScript.steps.count - 1))
    }

    public func show() {
        buildWindowIfNeeded()
        render()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Window

    private func buildWindowIfNeeded() {
        guard window == nil else { return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor = Tokens.Color.bgGlass.nsColor
        win.contentView = buildContent()
        window = win
    }

    private func buildContent() -> NSView {
        let root = NSView()

        let mark = NSImageView()
        mark.image = NSApp.applicationIconImage
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 44).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 44).isActive = true

        headline.font = .systemFont(ofSize: 23, weight: .bold)
        headline.textColor = Tokens.System.label
        subtitle.font = .systemFont(ofSize: 14, weight: .regular)
        subtitle.textColor = Tokens.System.secondaryLabel
        subtitle.preferredMaxLayoutWidth = 480

        visualBox.translatesAutoresizingMaskIntoConstraints = false
        visualBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        let dotsRow = NSStackView()
        dotsRow.spacing = 7
        dots = steps.indices.map { _ in
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            dotsRow.addArrangedSubview(dot)
            return dot
        }

        skipButton.isBordered = false
        skipButton.bezelStyle = .inline
        skipButton.contentTintColor = Tokens.System.secondaryLabel
        skipButton.target = self
        skipButton.action = #selector(skipTapped)

        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.target = self
        nextButton.action = #selector(nextTapped)

        let footer = NSStackView(views: [skipButton, spacer(), dotsRow, spacer(), nextButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let column = NSStackView(views: [mark, headline, subtitle, visualBox, footer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 16
        column.setCustomSpacing(8, after: headline)
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 34),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -34),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
            footer.widthAnchor.constraint(equalTo: column.widthAnchor),
            visualBox.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        return root
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    // MARK: - Rendering

    private func render() {
        let step = steps[index]
        headline.stringValue = step.title
        subtitle.stringValue = step.subtitle
        for (i, dot) in dots.enumerated() {
            dot.layer?.backgroundColor = (i == index ? Tokens.System.accent : Tokens.Color.hairline.nsColor).cgColor
        }
        skipButton.title = index == 0 ? "Skip" : "Back"
        nextButton.title = index == steps.count - 1 ? "Get started" : "Next"
        visualBox.subviews.forEach { $0.removeFromSuperview() }
        let visual = makeVisual(for: step.visual)
        visual.translatesAutoresizingMaskIntoConstraints = false
        visualBox.addSubview(visual)
        NSLayoutConstraint.activate([
            visual.leadingAnchor.constraint(equalTo: visualBox.leadingAnchor),
            visual.trailingAnchor.constraint(equalTo: visualBox.trailingAnchor),
            visual.topAnchor.constraint(equalTo: visualBox.topAnchor),
            visual.bottomAnchor.constraint(lessThanOrEqualTo: visualBox.bottomAnchor),
        ])
    }

    private func makeVisual(for visual: OnboardingStep.Visual) -> NSView {
        switch visual {
        case .launcher:
            return card(query: "arrange windows", rows: [
                ("◫  Arrange Windows: Left / Right", Tokens.System.secondaryLabel),
                ("≡  notes.md", Tokens.System.secondaryLabel),
                ("=  2 + 2  →  4", Tokens.System.secondaryLabel),
            ])
        case .answer:
            return card(query: "capital of australia", rows: [
                ("Answer · on-device · only the query left", Tokens.System.accent),
                ("Canberra — a compromise capital, chosen in 1908.", Tokens.System.label),
            ])
        case .actions:
            return card(query: "set the volume to 30", rows: [
                ("✓  Done — Volume set to 30%.", Tokens.System.ok),
                ("“empty the trash” waits for one click →", Tokens.System.staged),
            ])
        case .setup:
            return setupCard()
        }
    }

    private func card(query: String, rows: [(String, NSColor)]) -> NSView {
        let box = roundedBox()
        let queryLabel = NSTextField(labelWithString: "◆  " + query)
        queryLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        queryLabel.textColor = Tokens.System.label
        var views: [NSView] = [queryLabel, hairline()]
        for (text, color) in rows {
            let row = NSTextField(wrappingLabelWithString: text)
            row.font = .systemFont(ofSize: 13, weight: .regular)
            row.textColor = color
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 15, bottom: 14, right: 15)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        pin(stack, in: box)
        return box
    }

    private func setupCard() -> NSView {
        let login = checkbox("Keep Summon ready at login", on: wantLogin, action: #selector(toggleLogin))
        let web = checkbox("Turn on full web search (downloads in the background)", on: false, action: #selector(toggleWeb))
        let ax = checkbox("Accessibility — for window snapping", on: wantAccessibility, action: #selector(toggleAccessibility))
        webStatus.font = .systemFont(ofSize: 12, weight: .regular)
        webStatus.textColor = Tokens.System.secondaryLabel
        webStatus.stringValue = ""
        let stack = NSStackView(views: [login, web, webStatus, ax])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func checkbox(_ title: String, on: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = on ? .on : .off
        button.contentTintColor = Tokens.System.accent
        return button
    }

    private func roundedBox() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = Tokens.Color.surface.nsColor.cgColor
        box.layer?.borderColor = Tokens.Color.hairline.nsColor.cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 12
        return box
    }

    private func hairline() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func pin(_ view: NSView, in container: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func nextTapped() {
        if index < steps.count - 1 {
            index += 1
            render()
        } else {
            finish()
        }
    }

    @objc private func skipTapped() {
        if index == 0 { finish() } else { index -= 1; render() }
    }

    @objc private func toggleLogin(_ sender: NSButton) { wantLogin = sender.state == .on }
    @objc private func toggleAccessibility(_ sender: NSButton) { wantAccessibility = sender.state == .on }

    @objc private func toggleWeb(_ sender: NSButton) {
        guard sender.state == .on else { webStatus.stringValue = ""; return }
        webStatus.stringValue = WebSearchInstaller.Phase.detecting.statusText
        webStatus.textColor = Tokens.System.secondaryLabel
        actions.enableWebSearch { [weak self] phase in
            guard let self else { return }
            self.webStatus.stringValue = phase.statusText
            self.webStatus.textColor = phase.isError ? Tokens.System.danger : Tokens.System.secondaryLabel
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        actions.setLoginItem(wantLogin)
        if wantAccessibility { actions.requestAccessibility() }
        actions.onFinish()
        window?.orderOut(nil)
    }
}
#endif
