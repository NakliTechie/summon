import Foundation

/// Latency budget helpers (SP-02, SP-03, SU-11).
public struct LatencySample: Sendable, Equatable {
    public let label: String
    public let milliseconds: Double
    public let iterations: Int

    public init(label: String, milliseconds: Double, iterations: Int) {
        self.label = label
        self.milliseconds = milliseconds
        self.iterations = iterations
    }
}

public enum LatencyProbe {
    /// Gate budgets from vision/handoff (p95 targets).
    public static let invokeVisibleMs: Double = 50
    public static let keystrokeResultsMs: Double = 16

    public static func measure(label: String, iterations: Int = 100, body: () throws -> Void) rethrows -> LatencySample {
        // Warmup
        try body()
        var times: [Double] = []
        times.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            times.append(Double(end - start) / 1_000_000.0)
        }
        times.sort()
        // p95 = value at 1-based rank ceil(0.95 * n)
        let n = times.count
        let rank = max(1, Int((0.95 * Double(n)).rounded(.up)))
        let idx = min(n - 1, rank - 1)
        let p95 = times[idx]
        return LatencySample(label: label, milliseconds: p95, iterations: iterations)
    }

    public static func p95Passes(sample: LatencySample, budgetMs: Double) -> Bool {
        sample.milliseconds <= budgetMs
    }
}
