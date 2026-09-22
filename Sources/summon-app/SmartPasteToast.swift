import AppKit

/// A small, non-activating toast for smart paste: it discloses what was filled
/// and offers Undo, without stealing focus or blocking (the launcher's speed is
/// the point — see the 2026-09-22 decision). Auto-dismisses; clicking Undo runs
/// the supplied closure and dismisses immediately.
@MainActor
final class SmartPasteToast {
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private var undoAction: (() -> Void)?

    func show(message: String, undo: (() -> Void)?, duration: TimeInterval = 5) {
        dismiss()
        undoAction = undo

        let hasUndo = undo != nil
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor

        let stack = NSStackView(views: [label])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        if hasUndo {
            let button = NSButton(title: "Undo", target: self, action: #selector(undoTapped))
            button.bezelStyle = .rounded
            button.controlSize = .small
            stack.addArrangedSubview(button)
        }

        let content = NSVisualEffectView()
        content.material = .hudWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = content
        panel.layoutIfNeeded()

        // Bottom-centre of the main screen, above the Dock.
        if let screen = NSScreen.main {
            let size = content.fittingSize
            panel.setContentSize(size)
            let frame = screen.visibleFrame
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY + 48
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    @objc private func undoTapped() {
        let action = undoAction
        dismiss()
        action?()
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        undoAction = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
