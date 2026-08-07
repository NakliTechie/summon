import Foundation

#if canImport(AppKit)
import AppKit

final class AppearanceAwareView: NSView {
    var appearanceDidChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceDidChange?()
    }
}
#endif

/// Semantic design tokens from the UX reference (handoff §3).
///
/// Single source of named colors; asset catalog may mirror these later.
/// `staged` is reserved exclusively for propose-don't-dispose states.
public enum Tokens {
    public enum Color {
        /// `#F3EFE6` — dull cream background
        public static let bgGlass = RGBA(r: 0xF3, g: 0xEF, b: 0xE6)
        /// `#FBF8F1` — near-white surface
        public static let surface = RGBA(r: 0xFB, g: 0xF8, b: 0xF1)
        /// `#E7E1D3` — warm selection
        public static let surfaceRaised = RGBA(r: 0xE7, g: 0xE1, b: 0xD3)
        /// `#1D2430` — dark-slate ink
        public static let text = RGBA(r: 0x1D, g: 0x24, b: 0x30)
        /// `#4E5766`
        public static let textDim = RGBA(r: 0x4E, g: 0x57, b: 0x66)
        /// `#1F5FA6` — corporate blue
        public static let accent = RGBA(r: 0x1F, g: 0x5F, b: 0xA6)
        /// `#B9770C` — propose-don't-dispose only; never decorative
        public static let staged = RGBA(r: 0xB9, g: 0x77, b: 0x0C)
        /// `#2F8F4E`
        public static let ok = RGBA(r: 0x2F, g: 0x8F, b: 0x4E)
        /// `#C0392B`
        public static let danger = RGBA(r: 0xC0, g: 0x39, b: 0x2B)
        /// `#E2DDD0` — warm hairline
        public static let hairline = RGBA(r: 0xE2, g: 0xDD, b: 0xD0)
    }

    public struct RGBA: Sendable, Equatable {
        public let r: UInt8
        public let g: UInt8
        public let b: UInt8
        public let a: UInt8

        public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }

        /// WCAG relative luminance (sRGB).
        public var relativeLuminance: Double {
            func channel(_ c: UInt8) -> Double {
                let s = Double(c) / 255.0
                return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            let R = channel(r)
            let G = channel(g)
            let B = channel(b)
            return 0.2126 * R + 0.7152 * G + 0.0722 * B
        }

        /// Contrast ratio against another color (WCAG).
        public func contrastRatio(against other: RGBA) -> Double {
            let l1 = relativeLuminance
            let l2 = other.relativeLuminance
            let lighter = max(l1, l2)
            let darker = min(l1, l2)
            return (lighter + 0.05) / (darker + 0.05)
        }

        #if canImport(AppKit)
        public var nsColor: NSColor {
            NSColor(
                srgbRed: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: CGFloat(a) / 255.0
            )
        }
        #endif
    }

    #if canImport(AppKit)
    /// Appearance-adaptive colors (Apple HIG). Prefer these in AppKit UI over fixed RGB.
    public enum System {
        public static var label: NSColor { .labelColor }
        public static var secondaryLabel: NSColor { .secondaryLabelColor }
        public static var tertiaryLabel: NSColor { .tertiaryLabelColor }
        public static var separator: NSColor { .separatorColor }
        /// Corporate blue is the brand accent in every appearance.
        public static var accent: NSColor { Color.accent.nsColor }
        public static var danger: NSColor { .systemRed }
        public static var ok: NSColor { .systemGreen }
        /// Propose-don't-dispose only (not decorative). Amber in every appearance.
        public static var staged: NSColor { Color.staged.nsColor }
        public static var controlBackground: NSColor { .controlBackgroundColor }
        public static var windowBackground: NSColor { .windowBackgroundColor }
    }

    public enum TypeScale {
        public static var search: NSFont { .systemFont(ofSize: 17, weight: .regular) }
        public static var rowTitle: NSFont { .systemFont(ofSize: 13, weight: .medium) }
        public static var rowSubtitle: NSFont { .systemFont(ofSize: 11, weight: .regular) }
        public static var caption: NSFont { .systemFont(ofSize: 11, weight: .regular) }
        public static var footnote: NSFont { .systemFont(ofSize: 10, weight: .regular) }
    }

    public enum Metrics {
        public static let panelCornerRadius: CGFloat = 12
        public static let rowCornerRadius: CGFloat = 6
        public static let contentInset: CGFloat = 12
        public static let rowHeight: CGFloat = 44
        public static let iconSize: CGFloat = 28
    }
    #endif
}
