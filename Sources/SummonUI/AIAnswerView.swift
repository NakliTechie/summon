import AppKit

/// Answer shape (answer-vs-action split): a read-only AI answer with copy/insert.
/// Neutral, not amber, and no Accept/Reject — a displayed answer executes
/// nothing. The card grows to fit its text (up to a cap, then scrolls), and any
/// URLs in the text (e.g. Sources) are clickable.
final class AIAnswerView: NSView {
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let insertButton = NSButton(title: "Insert", target: nil, action: nil)

    private let titleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView(frame: .zero)
    private let answerText = NSTextView(frame: .zero)
    private var attributed = NSAttributedString()
    private static let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    /// Plain text (attributes stripped) — for Copy/Insert.
    var answer: String { answerText.string }

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
        answerText.textContainer?.widthTracksTextView = true
        answerText.setAccessibilityLabel("AI answer")
        answerText.linkTextAttributes = [
            .foregroundColor: Tokens.System.accent,
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
        titleLabel.frame = NSRect(x: 8, y: titleY, width: width - 130, height: 20)
        insertButton.frame = NSRect(x: width - 118, y: titleY - 3, width: 56, height: 22)
        copyButton.frame = NSRect(x: width - 58, y: titleY - 3, width: 52, height: 22)
        scrollView.frame = NSRect(x: 8, y: 8, width: width - 16, height: max(20, titleY - 12))
    }

    func display(title: String, answer: String) {
        titleLabel.stringValue = title
        setAnswer(answer)
        isHidden = false
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

    func clear() {
        titleLabel.stringValue = ""
        setAnswer("")
        isHidden = true
    }

    func containsFirstResponder(_ responder: NSResponder?) -> Bool {
        responder === answerText
    }

    private func setAnswer(_ text: String) {
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
        attributed = string
        answerText.textStorage?.setAttributedString(string)
    }
}
