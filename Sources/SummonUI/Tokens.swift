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
        /// `#14151A` — glass background
        public static let bgGlass = RGBA(r: 0x14, g: 0x15, b: 0x1A)
        /// `#1C1E26`
        public static let surface = RGBA(r: 0x1C, g: 0x1E, b: 0x26)
        /// `#24262F`
        public static let surfaceRaised = RGBA(r: 0x24, g: 0x26, b: 0x2F)
        /// `#E8E6DF`
        public static let text = RGBA(r: 0xE8, g: 0xE6, b: 0xDF)
        /// `#9A98A0`
        public static let textDim = RGBA(r: 0x9A, g: 0x98, b: 0xA0)
        /// `#7C6FE8` — sigil violet
        public static let accent = RGBA(r: 0x7C, g: 0x6F, b: 0xE8)
        /// `#E5A54B` — propose-don't-dispose only; never decorative
        public static let staged = RGBA(r: 0xE5, g: 0xA5, b: 0x4B)
        /// `#5FB37A`
        public static let ok = RGBA(r: 0x5F, g: 0xB3, b: 0x7A)
        /// `#E06C5F`
        public static let danger = RGBA(r: 0xE0, g: 0x6C, b: 0x5F)
        /// `#33353F`
        public static let hairline = RGBA(r: 0x33, g: 0x35, b: 0x3F)
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
        public static var accent: NSColor {
            adaptive(dark: Color.accent.nsColor, light: .controlAccentColor)
        }
        public static var danger: NSColor { .systemRed }
        public static var ok: NSColor { .systemGreen }
        /// Propose-don't-dispose only (not decorative).
        public static var staged: NSColor {
            adaptive(dark: Color.staged.nsColor, light: .systemOrange)
        }
        public static var controlBackground: NSColor { .controlBackgroundColor }
        public static var windowBackground: NSColor { .windowBackgroundColor }

        private static func adaptive(dark: NSColor, light: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                let match = appearance.bestMatch(from: [.darkAqua, .aqua])
                return match == .darkAqua ? dark : light
            }
        }
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
