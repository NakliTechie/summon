import Foundation
import SummonCore

/// AI ladder + sidecars placeholder — lands in chunk 5 (C3).
///
/// Removability gate: build with `SUMMON_AI_ENABLED=0` to omit this target
/// (handoff §8.4). Zero AI configured → every module remains functional.
public enum SummonAI {
    public static let status = "not-started"
}
