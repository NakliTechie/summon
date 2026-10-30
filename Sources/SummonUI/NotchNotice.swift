import AppKit

/// Where a transient notice sits. On a screen with a camera notch it drops down
/// from the notch, flush with the top edge, as an extension of the notch; on any
/// other screen it is a pill just below the menu bar (decided 2026-10-30: notch
/// pattern (a), with the floating-pill fallback from (d)). Pure geometry, so it is
/// tested without a display.
public enum NotchNoticeLayout {
    public enum Style: Equatable, Sendable { case notch, pill }

    public struct Placement: Equatable, Sendable {
        public let frame: CGRect
        public let style: Style
        /// Space above the content that the notch covers (0 for a pill).
        public let topInset: CGFloat
    }

    /// Extra width either side of the notch, so the notice reads as hanging from it.
    public static let shoulder: CGFloat = 28
    /// Gap between a pill and the menu bar.
    public static let pillGap: CGFloat = 8
    /// Clear space kept at the screen's sides; longer text truncates.
    public static let sideMargin: CGFloat = 16

    /// The notch rectangle, from the areas AppKit reports either side of it.
    public static func notchRect(
        frame: CGRect,
        safeAreaTop: CGFloat,
        topLeftArea: CGRect?,
        topRightArea: CGRect?
    ) -> CGRect? {
        guard safeAreaTop > 0, let left = topLeftArea, let right = topRightArea,
              right.minX > left.maxX else { return nil }
        return CGRect(x: left.maxX, y: frame.maxY - safeAreaTop, width: right.minX - left.maxX, height: safeAreaTop)
    }

    public static func placement(
        content: CGSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        notch: CGRect?
    ) -> Placement {
        if let notch {
            let width = min(max(content.width, notch.width + 2 * shoulder), screenFrame.width - 2 * sideMargin)
            let height = notch.height + content.height
            var x = notch.midX - width / 2
            x = min(max(x, screenFrame.minX + sideMargin), screenFrame.maxX - sideMargin - width)
            return Placement(
                frame: CGRect(x: x, y: screenFrame.maxY - height, width: width, height: height),
                style: .notch,
                topInset: notch.height
            )
        }
        let width = min(content.width, visibleFrame.width - 2 * sideMargin)
        let x = visibleFrame.midX - width / 2
        let y = visibleFrame.maxY - pillGap - content.height
        return Placement(
            frame: CGRect(x: x, y: y, width: width, height: content.height),
            style: .pill,
            topInset: 0
        )
    }
}

/// A transient, non-activating notice with an optional action button. It never
/// takes focus, auto-dismisses, and pauses the dismissal while the pointer is
/// over it so the action stays reachable. Shown on the screen under the pointer,
/// because Summon has no key window to anchor to.
@MainActor
public final class NotchNotice: NSObject {
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private var action: (() -> Void)?
    private var remaining: TimeInterval = 0

    override public init() { super.init() }

    public func show(
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        duration: TimeInterval = 5,
        on chosenScreen: NSScreen? = nil
    ) {
        dismiss()
        self.action = action
        guard let screen = chosenScreen ?? Self.screenUnderPointer() else { return }
        let notch = NotchNoticeLayout.notchRect(
            frame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            topLeftArea: screen.auxiliaryTopLeftArea,
            topRightArea: screen.auxiliaryTopRightArea
        )

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.textColor = notch == nil ? .labelColor : .white
        let stack = NSStackView(views: [label])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 18, bottom: 12, right: 18)
        if let actionTitle, action != nil {
            let button = NSButton(title: actionTitle, target: self, action: #selector(actionTapped))
            button.bezelStyle = .rounded
            button.controlSize = .small
            stack.addArrangedSubview(button)
        }
        let contentSize = stack.fittingSize
        let placement = NotchNoticeLayout.placement(
            content: contentSize,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            notch: notch
        )

        let background = HoverView(onEnter: { [weak self] in self?.pause() },
                                   onExit: { [weak self] in self?.resume() })
        background.wantsLayer = true
        switch placement.style {
        case .notch:
            // Black like the notch, square at the top so it joins it, round below.
            background.layer?.backgroundColor = NSColor.black.cgColor
            background.layer?.cornerRadius = 14
            background.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        case .pill:
            let effect = NSVisualEffectView(frame: .zero)
            effect.material = .hudWindow
            effect.state = .active
            effect.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(effect)
            NSLayoutConstraint.activate([
                effect.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                effect.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                effect.topAnchor.constraint(equalTo: background.topAnchor),
                effect.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            ])
            background.layer?.cornerRadius = placement.frame.height / 2
            background.layer?.masksToBounds = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: background.widthAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: placement.topInset),
        ])

        let panel = NSPanel(
            contentRect: placement.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above the menu bar, so a notch notice can sit flush with the top edge.
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = placement.style == .pill
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = background
        panel.setFrame(placement.frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        remaining = duration
        scheduleDismiss(after: duration)
    }

    public func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        action = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// The panel's frame and window number while a notice is up (for live checks).
    public var currentFrame: CGRect? { panel?.frame }
    public var currentWindowNumber: Int? { panel?.windowNumber }

    @objc private func actionTapped() {
        let action = self.action
        dismiss()
        action?()
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func pause() {
        dismissWork?.cancel()
        dismissWork = nil
    }

    private func resume() {
        guard panel != nil else { return }
        scheduleDismiss(after: min(max(remaining, 2), 3))
    }

    private static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }
}

/// Reports the pointer entering and leaving, to pause a notice's dismissal.
private final class HoverView: NSView {
    private let onEnter: () -> Void
    private let onExit: () -> Void

    init(onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onEnter = onEnter
        self.onExit = onExit
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
}
