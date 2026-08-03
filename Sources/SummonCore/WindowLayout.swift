import Foundation
import CoreGraphics

/// Window snap layouts (Rectangle-inspired math). Pure geometry — no Accessibility yet.
public enum WindowLayout: String, Sendable, Hashable, Codable, CaseIterable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case maximize
    case center
    case leftThird
    case centerThird
    case rightThird
}

public enum WindowGeometry {
    /// Compute target frame inside `screen` with optional gap (points).
    public static func frame(
        layout: WindowLayout,
        screen: CGRect,
        gap: CGFloat = 0
    ) -> CGRect {
        let g = gap
        let w = screen.width
        let h = screen.height
        let x = screen.minX
        let y = screen.minY
        let halfW = (w - g) / 2
        let halfH = (h - g) / 2
        let thirdW = (w - 2 * g) / 3

        switch layout {
        case .leftHalf:
            return CGRect(x: x, y: y, width: halfW, height: h)
        case .rightHalf:
            return CGRect(x: x + halfW + g, y: y, width: halfW, height: h)
        case .topHalf:
            return CGRect(x: x, y: y + halfH + g, width: w, height: halfH)
        case .bottomHalf:
            return CGRect(x: x, y: y, width: w, height: halfH)
        case .topLeft:
            return CGRect(x: x, y: y + halfH + g, width: halfW, height: halfH)
        case .topRight:
            return CGRect(x: x + halfW + g, y: y + halfH + g, width: halfW, height: halfH)
        case .bottomLeft:
            return CGRect(x: x, y: y, width: halfW, height: halfH)
        case .bottomRight:
            return CGRect(x: x + halfW + g, y: y, width: halfW, height: halfH)
        case .maximize:
            return screen.insetBy(dx: g, dy: g)
        case .center:
            let cw = w * 0.7
            let ch = h * 0.7
            return CGRect(
                x: x + (w - cw) / 2,
                y: y + (h - ch) / 2,
                width: cw,
                height: ch
            )
        case .leftThird:
            return CGRect(x: x, y: y, width: thirdW, height: h)
        case .centerThird:
            return CGRect(x: x + thirdW + g, y: y, width: thirdW, height: h)
        case .rightThird:
            return CGRect(x: x + 2 * (thirdW + g), y: y, width: thirdW, height: h)
        }
    }
}
