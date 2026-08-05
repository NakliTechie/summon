import Foundation

/// Day-1 i18n seam: string catalog keys, English defaults.
/// Real .xcstrings catalogs land with the app bundle; this keeps code free of
/// hard-coded user-facing literals in core paths we control.
public enum L10n {
    public enum Key: String, Sendable {
        case searchPlaceholder = "search.placeholder"
        case emptyResults = "search.empty"
        case stagedProposal = "ai.staged"
        case degradedAI = "ai.degraded"
        case clipboardConcealed = "clipboard.concealed_skipped"
        case l0ConsentTitle = "ai.l0.consent_title"
    }

    private static let english: [Key: String] = [
        .searchPlaceholder: "Summon…",
        .emptyResults: "No results",
        .stagedProposal: "Staged for review — not executed",
        .degradedAI: "On-device model unavailable — search still works",
        .clipboardConcealed: "Clipboard item skipped (private)",
        .l0ConsentTitle: "Download on-device model?",
    ]

    public static func t(_ key: Key, locale: Locale = .current) -> String {
        // Future: Bundle.main localizedString. Day-1 English table.
        _ = locale
        return english[key] ?? key.rawValue
    }
}
