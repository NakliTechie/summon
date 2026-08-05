import AppKit

final class LauncherResultCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("launcher-result-cell")

    let resultIconView = NSImageView(frame: .zero)
    let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        resultIconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        titleLabel.drawsBackground = false
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(resultIconView)
        addSubview(titleLabel)
        imageView = resultIconView
        textField = titleLabel
        updateFrames(width: frameRect.width)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resultIconView.image = nil
        resultIconView.isHidden = false
        resultIconView.contentTintColor = nil
        titleLabel.stringValue = ""
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        titleLabel.textColor = Tokens.System.label
    }

    func updateFrames(width: CGFloat, emoji: Bool = false) {
        frame.size = NSSize(width: width, height: 40)
        resultIconView.frame = NSRect(x: 12, y: 6, width: 28, height: 28)
        titleLabel.frame = emoji
            ? NSRect(x: 14, y: 10, width: max(40, width - 28), height: 20)
            : NSRect(x: 48, y: 11, width: max(40, width - 60), height: 18)
    }
}
