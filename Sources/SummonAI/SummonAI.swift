import Foundation

/// AI ladder + sidecars.
///
/// Removability: `SUMMON_AI_ENABLED=0` omits this target (handoff §8.4).
/// Production: capability-gated L1 plus consented, experimental local MLX L0.
/// L2/L3 remain roadmap targets and are absent from production rung preference.
public enum SummonAI {
    public static let status = "l1+l0-experimental-mlx"
    public static let versionNote =
        "Apple native AI when eligible; experimental user-managed MLX after explicit consent"
}
