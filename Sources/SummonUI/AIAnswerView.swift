import AppKit

/// Answer shape (answer-vs-action split): a read-only AI answer with copy/insert.
/// Neutral, not amber, and no Accept/Reject — a displayed answer executes
/// nothing. The card grows to fit its text (up to a cap, then scrolls), and any
/// URLs in the text (e.g. Sources) are clickable.
/// Text view whose source rows (`.summonSourceURL`) open on click, show a hand
/// cursor and carry the full URL as a tooltip, without link colouring.
final class AnswerTextView: NSTextView {
    static let sourceURL = NSAttributedString.Key("summonSourceURL")

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer else { return }
        storage.enumerateAttribute(Self.sourceURL, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let url = sourceURL(at: point) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    func sourceURL(at point: NSPoint) -> URL? {
        guard let storage = textStorage, let manager = layoutManager, let container = textContainer,
              storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let all = NSRange(location: 0, length: manager.numberOfGlyphs)
        guard manager.boundingRect(forGlyphRange: all, in: container).contains(local) else { return nil }
        let index = manager.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < storage.length,
              let text = storage.attribute(Self.sourceURL, at: index, effectiveRange: nil) as? String else { return nil }
        return URL(string: text)
    }
}

final class AIAnswerView: NSView {
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let insertButton = NSButton(title: "Insert", target: nil, action: nil)

    private let titleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView(frame: .zero)
    let answerText = AnswerTextView(frame: .zero)
    private var attributed = NSAttributedString()
    private static let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    /// Plain text for Copy/Insert: the answer, then its sources as "title — url" lines.
    private(set) var answer = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Tokens.System.separator.withAlphaComponent(0.6).cgColor

        titleLabel.font = Tokens.TypeScale.caption
        titleLabel.textColor = Tokens.System.secondaryLabel
        addSubview(titleLabel)

        answerText.isEditable = false
        answerText.isSelectable = true
        answerText.drawsBackground = false
        answerText.textContainerInset = NSSize(width: 6, height: 5)
        answerText.isVerticallyResizable = true
        answerText.isHorizontallyResizable = false
        answerText.autoresizingMask = [.width]
        answerText.minSize = NSSize(width: 0, height: 0)
        answerText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        answerText.textContainer?.widthTracksTextView = true
        answerText.setAccessibilityLabel("AI answer")
        answerText.linkTextAttributes = [
            .foregroundColor: Tokens.System.accentText,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // Overlay scrollers don't reserve width and fade out — no persistent bar
        // (the card sizes to fit; scrolling only matters past the cap).
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = answerText
        addSubview(scrollView)

        for button in [copyButton, insertButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let titleY = bounds.height - 26
        titleLabel.frame = NSRect(x: 8, y: titleY, width: width - 150, height: 20)
        copyButton.frame = NSRect(x: width - 8 - 60, y: titleY - 3, width: 60, height: 22)
        insertButton.frame = NSRect(x: copyButton.frame.minX - 4 - 60, y: titleY - 3, width: 60, height: 22)
        scrollView.frame = NSRect(x: 8, y: 8, width: width - 16, height: max(20, titleY - 12))
        scrollView.fitDocumentTextViewToWidth()
    }

    /// `sources` are "title — url" strings. They show as quiet rows: the title in
    /// ink, the site dimmed, and a small accent › that says the row opens.
    func display(title: String, answer: String, sources: [String] = []) {
        titleLabel.stringValue = title
        let rows = sources.compactMap(Self.parse)
        self.answer = rows.isEmpty
            ? answer
            : answer + "\n\nSources:\n" + sources.map { "· \($0)" }.joined(separator: "\n")
        setAnswer(answer, sources: rows)
        isHidden = false
    }

    struct SourceRow { let title: String; let url: URL; let host: String }

    /// "Page title — https://host/path" → a row; nil when the URL part is not a link.
    static func parse(_ source: String) -> SourceRow? {
        guard let split = source.range(of: " — ", options: .backwards),
              let url = URL(string: String(source[split.upperBound...]).trimmingCharacters(in: .whitespaces)),
              let host = url.host else { return nil }
        let title = String(source[..<split.lowerBound]).trimmingCharacters(in: .whitespaces)
        return SourceRow(title: title.isEmpty ? host : title, url: url, host: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }

    /// Height the card needs to show the whole answer at `width` (before clamping).
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(40, width - 16 - 12) // band inset + text container inset
        let measured = attributed.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        // Generous buffer so short answers fully fit (no overflow → no scroller).
        return ceil(measured) + 22 /* text insets */ + 36 /* title row + padding */
    }

    /// What the card really draws, for the usage log: its geometry, the laid-out
    /// text against the visible area, the window's state, and how many sampled
    /// pixels differ from the card's background (0 means the text is not drawn).
    func drawnState() -> [String: String] {
        var state: [String: String] = [
            "card": NSStringFromRect(frame), "hidden": String(isHidden), "alpha": String(describing: alphaValue),
            "chars": String(answerText.textStorage?.length ?? -1),
            "scroll": NSStringFromRect(scrollView.frame), "scrollOffset": NSStringFromPoint(scrollView.contentView.bounds.origin),
            "textFrame": NSStringFromRect(answerText.frame), "visible": NSStringFromRect(answerText.visibleRect),
            "appearance": effectiveAppearance.name.rawValue, "textColor": String(describing: Tokens.System.label),
        ]
        if let manager = answerText.layoutManager, let container = answerText.textContainer {
            manager.ensureLayout(for: container)
            state["laidOut"] = NSStringFromRect(manager.usedRect(for: container))
        }
        if let window {
            state["windowVisible"] = String(window.isVisible)
            state["occluded"] = String(!window.occlusionState.contains(.visible))
            state["windowAlpha"] = String(describing: window.alphaValue)
        }
        state["inkedPixels"] = String(answerInkedPixels())
        return state
    }

    func answerInkedPixels() -> Int { scrollView.inkedPixels() }

    private func appendSources(_ rows: [SourceRow], to string: NSMutableAttributedString) {
        let heading: [NSAttributedString.Key: Any] = [
            .font: Tokens.TypeScale.footnote, .foregroundColor: Tokens.System.tertiaryLabel,
        ]
        string.append(NSAttributedString(string: "\n\nSOURCES", attributes: heading))
        for row in rows {
            let link: [NSAttributedString.Key: Any] = [AnswerTextView.sourceURL: row.url.absoluteString, .toolTip: row.url.absoluteString]
            string.append(NSAttributedString(string: "\n"))
            string.append(NSAttributedString(string: row.title, attributes: Self.bodyAttributes.merging(link) { $1 }))
            string.append(NSAttributedString(
                string: "  " + row.host,
                attributes: [.font: Tokens.TypeScale.caption, .foregroundColor: Tokens.System.secondaryLabel].merging(link) { $1 }
            ))
            string.append(NSAttributedString(
                string: " ›",
                attributes: [.font: Self.bodyFont, .foregroundColor: Tokens.System.accentText].merging(link) { $1 }
            ))
        }
    }

    private static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: Tokens.System.label]
    }

    func clear() {
        titleLabel.stringValue = ""
        answer = ""
        setAnswer("")
        isHidden = true
    }

    func containsFirstResponder(_ responder: NSResponder?) -> Bool {
        responder === answerText
    }

    private func setAnswer(_ text: String, sources: [SourceRow] = []) {
        let base: [NSAttributedString.Key: Any] = [
            .font: Self.bodyFont,
            .foregroundColor: Tokens.System.label,
        ]
        let string = NSMutableAttributedString(string: text, attributes: base)
        if !text.isEmpty,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let full = NSRange(location: 0, length: (text as NSString).length)
            for match in detector.matches(in: text, options: [], range: full) {
                if let url = match.url { string.addAttribute(.link, value: url, range: match.range) }
            }
        }
        if !sources.isEmpty { appendSources(sources, to: string) }
        attributed = string
        answerText.textStorage?.setAttributedString(string)
        answerText.window?.invalidateCursorRects(for: answerText)
        scrollView.fitDocumentTextViewToWidth()
    }
}
