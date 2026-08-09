import Foundation

public extension WebSearchInstaller.Phase {
    /// Short, honest, user-facing status for the non-blocking progress chip.
    var statusText: String {
        switch self {
        case .detecting: return "Setting up web search…"
        case .installingRuntime: return "Installing the container runtime…"
        case .preparing: return "Downloading the search engine…"
        case .verifying: return "Almost ready…"
        case .enabled: return "Web search is ready."
        case .needsRuntime(let hint): return hint
        case .failed(let reason): return reason
        }
    }

    /// True while the flow is still working (drives an in-progress spinner).
    var isRunning: Bool {
        switch self {
        case .detecting, .installingRuntime, .preparing, .verifying: return true
        default: return false
        }
    }

    /// True for a terminal state the user must read (no runtime / a failure).
    var isError: Bool {
        switch self {
        case .needsRuntime, .failed: return true
        default: return false
        }
    }
}

/// One first-run intro screen — the drawn intro's copy, kept AppKit-free and
/// testable. The UI renders these; the `.setup` step also carries the toggles.
public struct OnboardingStep: Sendable, Equatable {
    public enum Visual: String, Sendable, Equatable {
        case launcher, answer, actions, setup
    }
    public let title: String
    public let subtitle: String
    public let visual: Visual

    public init(title: String, subtitle: String, visual: Visual) {
        self.title = title
        self.subtitle = subtitle
        self.visual = visual
    }
}

/// The first-run intro: four skippable screens, ending on optional setup toggles.
public enum OnboardingScript {
    /// Persisted once the intro has been shown (or skipped).
    public static let seenKey = "onboarding.intro.seen"

    public static let steps: [OnboardingStep] = [
        OnboardingStep(
            title: "Press ⌥Space anytime",
            subtitle: "That's the whole app. Summon the bar, then type to find apps, "
                + "files, math — anything on your Mac.",
            visual: .launcher
        ),
        OnboardingStep(
            title: "Ask anything",
            subtitle: "Answers compose on-device with Apple Foundation Models — or "
                + "search the web. Only your query ever leaves.",
            visual: .answer
        ),
        OnboardingStep(
            title: "Do things — safely",
            subtitle: "Tell it what to do in plain English. Safe actions run instantly; "
                + "destructive ones wait for one click.",
            visual: .actions
        ),
        OnboardingStep(
            title: "You're set",
            subtitle: "A couple of optional niceties. Change any of these later in Preferences.",
            visual: .setup
        ),
    ]
}
