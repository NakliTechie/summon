import Foundation

/// AI ladder + sidecars.
///
/// Removability: `SUMMON_AI_ENABLED=0` omits this target (handoff §8.4).
/// Day-1: L1 Apple Foundation Models + FakeModelRung + staged completions.
/// L0/L2/L3 land at chunk 5 (D7/D8 probes).
public enum SummonAI {
    public static let status = "l1-day1"
    public static let versionNote =
        "Apple native AI (Foundation Models) from day 1 on capable hardware"
}
