import Foundation
import SummonCore

final class StagedProposalRefreshMonitor {
    private let interval: TimeInterval
    private let onChange: () -> Void
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    init(interval: TimeInterval = 0.5, onChange: @escaping () -> Void) {
        self.interval = interval
        self.onChange = onChange
        observer = NotificationCenter.default.addObserver(
            forName: .summonStagedProposalDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onChange()
        }
    }

    deinit {
        stopPolling()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.onChange()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
