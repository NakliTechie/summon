import Foundation
import ServiceManagement
import SummonCore

/// Open-at-login via `SMAppService` (macOS 13+; Summon floor is 14).
public enum LoginItemService {
    public enum ChoiceApplication: Sendable, Equatable {
        case applied(observedEnabled: Bool)
        case failed
    }

    public static let settingsKey = "launchAtLogin"

    /// Register or unregister the main app as a login item.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    return true
                }
                try SMAppService.mainApp.register()
            } else {
                if SMAppService.mainApp.status == .notRegistered {
                    return true
                }
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            fputs("LoginItemService: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func applyChoice(_ enabled: Bool) -> ChoiceApplication {
        applyChoice(
            enabled,
            setter: setEnabled,
            observer: { isEnabled }
        )
    }

    static func applyChoice(
        _ enabled: Bool,
        setter: (Bool) -> Bool,
        observer: () -> Bool
    ) -> ChoiceApplication {
        guard setter(enabled) else { return .failed }
        return .applied(observedEnabled: observer())
    }

    /// Reconcile a previously chosen preference with authoritative system state.
    /// A missing preference remains missing until the first-run choice or Preferences changes it.
    public static func reconcileIfConfigured(core: SummonCore) {
        let raw = try? core.settings.get(settingsKey)
        guard case .bool = raw else { return }
        let observed = isEnabled
        if raw != .bool(observed) {
            _ = try? core.dispatch(
                action: .settingsSet(key: settingsKey, value: .bool(observed)),
                actor: .system
            )
        }
    }
}
