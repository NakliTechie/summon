import Foundation
#if canImport(IOKit)
import IOKit.ps
#endif

/// Read-only local system readers — the tool bodies, kept free of the
/// FoundationModels SDK so they are unit-testable on any host. Each returns a
/// short natural-language fact about *this* Mac. Zero egress: nothing here
/// leaves the machine, so a tool grounded on these keeps `egressSummary` empty.
///
/// These are the first entries of Summon's tool surface (Macaw-parity path).
/// Read-only tools execute during generation and feed the answer shape; a
/// mutating tool (a later batch) is propose-only and stages for Accept.
public enum SystemReaders {
    public static func datetime(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        let tz = TimeZone.current.identifier
        return "\(formatter.string(from: now)) (\(tz))"
    }

    public static func systemInfo(info: ProcessInfo = .processInfo) -> String {
        let memGB = Double(info.physicalMemory) / 1_073_741_824.0
        let thermal: String
        switch info.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let uptimeHours = info.systemUptime / 3600.0
        return [
            "macOS: \(info.operatingSystemVersionString)",
            "Host: \(info.hostName)",
            "Memory: \(String(format: "%.0f", memGB)) GB",
            "CPU cores: \(info.activeProcessorCount)",
            "Thermal state: \(thermal)",
            "Uptime: \(String(format: "%.1f", uptimeHours)) h",
        ].joined(separator: "\n")
    }

    public static func battery() -> String {
        #if canImport(IOKit)
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return "Battery status unavailable."
        }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let source = list.first,
              let desc = IOPSGetPowerSourceDescription(blob, source)?
                  .takeUnretainedValue() as? [String: Any]
        else {
            return "No internal battery detected — this Mac reports no battery power source "
                + "(likely a desktop, or running on AC only)."
        }
        let current = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0
        let maximum = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
        let percent = maximum > 0
            ? Int((Double(current) / Double(maximum) * 100).rounded())
            : current
        let charging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
        let onAC = (desc[kIOPSPowerSourceStateKey as String] as? String)
            == (kIOPSACPowerValue as String)
        let statusWord = charging ? "charging"
            : onAC ? "on AC power, not charging"
            : "on battery"
        return "Battery: \(percent)% (\(statusWord))."
        #else
        return "Battery status unavailable on this platform."
        #endif
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// The Apple FoundationModels `Tool` wrappers around the read-only readers.
/// The model may only *name* one of these; the body runs on-device and returns
/// text the model synthesizes into an answer. No arguments cross the boundary.
@available(macOS 26.0, *)
struct CurrentDateTimeTool: Tool {
    let name = "current_datetime"
    let description = "Get the current local date, day of week, and time on this Mac. "
        + "Use for any question about today's date, the current time, or what day it is."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        SystemReaders.datetime()
    }
}

@available(macOS 26.0, *)
struct BatteryStatusTool: Tool {
    let name = "battery_status"
    let description = "Report this Mac's current battery percentage and charging state. "
        + "Use for any question about battery level, charge, or power."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        SystemReaders.battery()
    }
}

@available(macOS 26.0, *)
struct SystemInfoTool: Tool {
    let name = "system_info"
    let description = "Report this Mac's live system facts: macOS version, host name, "
        + "installed memory, CPU core count, thermal state, and uptime."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        SystemReaders.systemInfo()
    }
}

/// The read-only tools Summon offers the on-device model. All are zero-egress.
@available(macOS 26.0, *)
enum SummonToolbox {
    static func systemTools() -> [any Tool] {
        [CurrentDateTimeTool(), BatteryStatusTool(), SystemInfoTool()]
    }
}
#endif
