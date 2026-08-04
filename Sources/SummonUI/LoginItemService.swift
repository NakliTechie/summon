import Foundation
import ServiceManagement
import SummonCore

/// Open-at-login via `SMAppService` (macOS 13+; Summon floor is 14).
public enum LoginItemService {
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

    /// Default ON (CB-2). Applies setting + OS login item when missing.
    public static func applyDefaultIfNeeded(settings: SettingsStore) {
        let raw = try? settings.get(settingsKey)
        let want: Bool
        if case .bool(let b) = raw {
            want = b
        } else {
            want = true
            try? settings.set(settingsKey, value: .bool(true))
        }
        _ = setEnabled(want)
    }
}
