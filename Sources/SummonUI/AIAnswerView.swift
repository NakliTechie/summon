import AppKit

/// Answer shape (answer-vs-action split): a read-only AI answer with copy/insert.
/// Deliberately NOT amber and has no Accept/Reject — a displayed answer executes
/// nothing, so it must not wear the staged-action chrome (`StagedReviewView`).
final class AIAnswerView: NSView {
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let insertButton = NSButton(title: "Insert", target: nil, action: nil)

    private let titleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView(frame: .zero)
    private let answerText = NSTextView(frame: .zero)

    var answer: String {
        get { answerText.string }
        set { answerText.string = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        // Neutral, not the staged amber — this is an answer, not an action.
        layer?.borderColor = Tokens.System.separator.withAlphaComponent(0.6).cgColor

        titleLabel.font = Tokens.TypeScale.caption
        titleLabel.textColor = Tokens.System.secondaryLabel
        addSubview(titleLabel)

        answerText.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        answerText.isEditable = false
        answerText.isSelectable = true
        answerText.isRichText = false
        answerText.drawsBackground = false
        answerText.textColor = Tokens.System.label
        answerText.textContainerInset = NSSize(width: 6, height: 5)
        answerText.isVerticallyResizable = true
        answerText.isHorizontallyResizable = false
        answerText.textContainer?.widthTracksTextView = true
        answerText.setAccessibilityLabel("AI answer")

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
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
        titleLabel.frame = NSRect(x: 8, y: 116, width: width - 130, height: 24)
        insertButton.frame = NSRect(x: width - 118, y: 116, width: 56, height: 22)
        copyButton.frame = NSRect(x: width - 58, y: 116, width: 52, height: 22)
        scrollView.frame = NSRect(x: 8, y: 8, width: width - 16, height: 104)
    }

    func display(title: String, answer: String) {
        titleLabel.stringValue = title
        self.answer = answer
        isHidden = false
    }

    func clear() {
        titleLabel.stringValue = ""
        answer = ""
        isHidden = true
    }

    func containsFirstResponder(_ responder: NSResponder?) -> Bool {
        responder === answerText
    }
}
