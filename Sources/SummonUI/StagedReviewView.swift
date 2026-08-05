import AppKit

final class StagedReviewView: NSView {
    let acceptButton = NSButton(title: "Accept", target: nil, action: nil)
    let rejectButton = NSButton(title: "Reject", target: nil, action: nil)

    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let exactRunLabel = NSTextField(labelWithString: "Runs exactly this text")
    private let scrollView = NSScrollView(frame: .zero)
    private let editor = NSTextView(frame: .zero)

    var reviewedText: String {
        get { editor.string }
        set { editor.string = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 2
        layer?.borderColor = Tokens.System.staged.cgColor

        titleLabel.font = Tokens.TypeScale.caption
        titleLabel.textColor = Tokens.System.staged
        addSubview(titleLabel)

        exactRunLabel.font = Tokens.TypeScale.footnote
        exactRunLabel.textColor = Tokens.System.secondaryLabel
        exactRunLabel.setAccessibilityLabel("Runs exactly this staged text")
        addSubview(exactRunLabel)

        editor.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = true
        editor.backgroundColor = Tokens.System.windowBackground.withAlphaComponent(0.55)
        editor.textColor = Tokens.System.label
        editor.textContainerInset = NSSize(width: 6, height: 5)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Exact staged action")

        scrollView.borderType = .lineBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = editor
        addSubview(scrollView)

        for button in [acceptButton, rejectButton] {
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
        titleLabel.frame = NSRect(x: 8, y: 116, width: width - 140, height: 24)
        acceptButton.frame = NSRect(x: width - 110, y: 116, width: 52, height: 22)
        rejectButton.frame = NSRect(x: width - 54, y: 116, width: 48, height: 22)
        exactRunLabel.frame = NSRect(x: 8, y: 98, width: width - 16, height: 16)
        scrollView.frame = NSRect(x: 8, y: 8, width: width - 16, height: 86)
    }

    func display(title: String, reviewedText: String) {
        titleLabel.stringValue = title
        self.reviewedText = reviewedText
        isHidden = false
    }

    func clear() {
        titleLabel.stringValue = ""
        reviewedText = ""
        isHidden = true
    }

    func focusEditor(in window: NSWindow) -> Bool {
        window.makeFirstResponder(editor)
    }

    func containsFirstResponder(_ responder: NSResponder?) -> Bool {
        responder === editor
    }

    var editorHasMarkedText: Bool {
        editor.hasMarkedText()
    }
}
