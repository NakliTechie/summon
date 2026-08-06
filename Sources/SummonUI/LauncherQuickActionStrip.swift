import AppKit
import SummonCore

/// A quick-action destination shown as a circular chip in the launcher's
/// right-side strip (Macaw-style interaction mechanic).
struct LauncherQuickAction {
    let symbol: String
    let label: String
    let destination: AppDestination
}

/// Right-aligned row of circular icon chips revealed by → on an empty query
/// (Spotlight-bare box + Macaw-style quick chips). Navigable with ←/→, Enter,
/// or ⌘1–n; each activates an `AppDestination`.
final class LauncherQuickActionStrip: NSView {
    static let actions: [LauncherQuickAction] = [
        LauncherQuickAction(symbol: "list.clipboard", label: "Clipboard History", destination: .clipboard),
        LauncherQuickAction(symbol: "gearshape", label: "Preferences", destination: .preferencesGeneral),
        LauncherQuickAction(symbol: "questionmark.circle", label: "Help & Shortcuts", destination: .help),
    ]

    var onActivate: ((AppDestination) -> Void)?
    private(set) var selectedIndex = 0
    private var chips: [NSButton] = []
    private let chipSize: CGFloat = 30
    private let spacing: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (index, action) in Self.actions.enumerated() {
            let chip = NSButton()
            chip.bezelStyle = .regularSquare
            chip.isBordered = false
            chip.imagePosition = .imageOnly
            chip.wantsLayer = true
            chip.layer?.cornerRadius = chipSize / 2
            chip.layer?.borderWidth = 1
            if let image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.label) {
                chip.image = image.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                )
            }
            chip.toolTip = "\(action.label)  (⌘\(index + 1))"
            chip.setAccessibilityLabel(action.label)
            chip.tag = index
            chip.target = self
            chip.action = #selector(chipClicked(_:))
            addSubview(chip)
            chips.append(chip)
        }
        applySelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    var count: Int { chips.count }

    /// Width the strip needs so the caller can right-align it and shrink the field.
    var intrinsicWidth: CGFloat {
        CGFloat(chips.count) * chipSize + CGFloat(max(0, chips.count - 1)) * spacing
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let y = (bounds.height - chipSize) / 2
        for chip in chips {
            chip.frame = NSRect(x: x, y: y, width: chipSize, height: chipSize)
            x += chipSize + spacing
        }
    }

    func select(index: Int) {
        guard !chips.isEmpty else { return }
        selectedIndex = max(0, min(chips.count - 1, index))
        applySelection()
    }

    func move(by delta: Int) { select(index: selectedIndex + delta) }

    func activateSelected() { activate(index: selectedIndex) }

    func activate(index: Int) {
        guard index >= 0, index < Self.actions.count else { return }
        onActivate?(Self.actions[index].destination)
    }

    private func applySelection() {
        for (index, chip) in chips.enumerated() {
            let selected = index == selectedIndex
            chip.layer?.borderColor = (selected
                ? Tokens.System.accent
                : Tokens.System.separator.withAlphaComponent(0.5)).cgColor
            chip.layer?.backgroundColor = selected
                ? Tokens.System.accent.withAlphaComponent(0.18).cgColor
                : NSColor.clear.cgColor
            chip.contentTintColor = selected ? Tokens.System.accent : Tokens.System.secondaryLabel
        }
    }

    @objc private func chipClicked(_ sender: NSButton) {
        select(index: sender.tag)
        activate(index: sender.tag)
    }
}
