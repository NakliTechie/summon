import Foundation

/// Core AI ladder and task-attached AI capabilities.
///
/// The target is always built. Runtime capability detection degrades launcher
/// behavior when no model is available. Production includes Apple Foundation
/// Models, detected Ollama/LM Studio, and the experimental packaged-model seam.
public enum SummonAI {
    public static let status = "l1+l0-experimental-mlx"
    public static let versionNote =
        "Apple native AI when eligible; experimental user-managed MLX after explicit consent"
}
