import AppKit
import QuartzCore

/// Native loading orb (no WebView). Two moods:
/// - `.thinking` (local AI): a calm glowing sphere that breathes.
/// - `.searching` (web): the sphere with an accent dot orbiting it.
/// Core Animation only; theme-aware via the accent token.
final class OrbSpinnerView: NSView {
    enum Mode { case thinking, searching }

    private let core = CALayer()
    private let orbit = CALayer()
    private let dot = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        let accent = Tokens.System.accent

        core.backgroundColor = accent.cgColor
        core.shadowColor = accent.cgColor
        core.shadowRadius = 7
        core.shadowOpacity = 0.85
        core.shadowOffset = .zero
        layer?.addSublayer(core)

        dot.backgroundColor = accent.cgColor
        dot.shadowColor = accent.cgColor
        dot.shadowRadius = 3
        dot.shadowOpacity = 0.9
        dot.shadowOffset = .zero
        orbit.addSublayer(dot)
        orbit.isHidden = true
        layer?.addSublayer(orbit)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 40) }

    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        core.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
        core.position = center
        core.cornerRadius = 9

        orbit.frame = bounds
        dot.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
        dot.cornerRadius = 2.5
        dot.position = CGPoint(x: bounds.midX + 14, y: bounds.midY)
    }

    func start(_ mode: Mode) {
        stop()
        isHidden = false
        switch mode {
        case .thinking:
            orbit.isHidden = true
            core.add(pulse(from: 0.72, to: 1.0, duration: 0.95), forKey: "pulse")
            core.add(fade(from: 0.45, to: 1.0, duration: 0.95), forKey: "fade")
        case .searching:
            orbit.isHidden = false
            core.add(pulse(from: 0.88, to: 1.0, duration: 1.1), forKey: "pulse")
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = 1.15
            spin.repeatCount = .infinity
            orbit.add(spin, forKey: "spin")
        }
    }

    func stop() {
        core.removeAllAnimations()
        orbit.removeAllAnimations()
        isHidden = true
    }

    private func pulse(from: CGFloat, to: CGFloat, duration: CFTimeInterval) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return anim
    }

    private func fade(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return anim
    }
}
