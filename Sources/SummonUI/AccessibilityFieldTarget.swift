import AppKit
import ApplicationServices
import Foundation
import SummonCore

/// Reads and writes a specific app's text fields through Accessibility, so smart
/// paste can enumerate where a value could go and place it on accept.
///
/// The target is a fixed pid — the app that was frontmost before a Summon surface
/// opened (`FrontmostAppRestorer`), never the live frontmost (which is Summon
/// itself while its panel is up). AX handles are live and main-thread-bound; this
/// type is not `Sendable` and its methods run on the main thread.
///
/// Field ids are ordinals ("field-0", "field-1", …) assigned by the most recent
/// `fields()` call, valid until the next one. Reuses the AX conventions proven in
/// `WindowApplicator` (trust gate, `AXUIElementIsAttributeSettable` preflight,
/// `unsafeBitCast` element bridging).
public final class AccessibilityFieldTarget: SmartPasteTarget {
    private let pid: pid_t
    private let appElement: AXUIElement
    private var elementsByID: [String: AXUIElement] = [:]

    /// Traversal bounds so a deep or pathological tree cannot stall a paste.
    private static let maxVisitedNodes = 4_000
    private static let maxDepth = 40

    public init(pid: pid_t) {
        self.pid = pid
        self.appElement = AXUIElementCreateApplication(pid)
    }

    public convenience init(app: NSRunningApplication) {
        self.init(pid: app.processIdentifier)
    }

    // MARK: - Read

    public func fields() throws -> [SmartPasteFieldDescriptor] {
        guard AXIsProcessTrusted() else {
            throw CoreError.io(
                "Accessibility permission is off; enable Summon in System Settings › Privacy & Security › Accessibility"
            )
        }
        var descriptors: [SmartPasteFieldDescriptor] = []
        var map: [String: AXUIElement] = [:]
        var visited = 0

        // Prefer the focused window; fall back to all windows if none is focused.
        let roots = focusedWindowRoots()
        for root in roots {
            traverse(root, depth: 0, visited: &visited) { element, role, subrole in
                guard descriptors.count < 256 else { return } // a form has tens of fields, not thousands
                let id = "field-\(descriptors.count)"
                let isSecure = subrole == (kAXSecureTextFieldSubrole as String)
                descriptors.append(
                    SmartPasteFieldDescriptor(
                        id: id,
                        label: label(of: element),
                        placeholder: string(element, kAXPlaceholderValueAttribute),
                        role: subrole ?? role,
                        isSecure: isSecure,
                        currentValue: string(element, kAXValueAttribute)
                    )
                )
                map[id] = element
            }
        }
        elementsByID = map
        return descriptors
    }

    // MARK: - Write

    public func apply(value: String, toFieldID id: String) throws -> Bool {
        guard AXIsProcessTrusted() else {
            throw CoreError.io("Accessibility permission is off")
        }
        guard let element = elementsByID[id] else {
            throw CoreError.io("The target field is no longer available; re-open smart paste")
        }
        // Acceptance happens in Summon's dialog, so by now the target app is not
        // frontmost and the field has lost focus. Bring the app back and refocus
        // the element before writing: a value write can be dropped by a field
        // that only accepts input while focused, and the keystroke fallback needs
        // the app frontmost to route keys to it at all. A short settle lets the
        // activation and focus land before we read them back.
        NSRunningApplication(processIdentifier: pid)?.activate()
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(120_000)

        if directWrite(value, to: element) { return true }
        // A view that ignores an Accessibility value write (many web/Electron
        // fields) — fall back to typing, only once focus on the target is
        // verified so no keystroke ever lands in the wrong place.
        return keystrokeWrite(value, to: element)
    }

    private func directWrite(_ value: String, to element: AXUIElement) -> Bool {
        // Attempt the set even when AXUIElementIsAttributeSettable reports false:
        // some fields (Contacts cards among them) report not-settable yet accept
        // the write, and the settable pre-gate was blocking it entirely. Trust the
        // set's own error, then confirm the value actually took.
        let setError = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, value as CFTypeRef
        )
        guard setError == .success else { return false }
        return string(element, kAXValueAttribute) == value
    }

    private func keystrokeWrite(_ value: String, to element: AXUIElement) -> Bool {
        guard elementIsFocused(element) else { return false }
        return typeUnicode(value)
    }

    /// Focus is confirmed if the element reports itself focused, or the app's
    /// focused element is this one. `CFEqual` alone was too strict for apps whose
    /// focused-element reference differs from the enumerated element reference.
    private func elementIsFocused(_ element: AXUIElement) -> Bool {
        var ownFocus: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &ownFocus) == .success,
           (ownFocus as? Bool) == true {
            return true
        }
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return false
        }
        return CFEqual(unsafeBitCast(focusedRef, to: AXUIElement.self), element)
    }

    /// Post the string as Unicode key events to the target pid. Guarded by a
    /// verified-focus check in `keystrokeWrite`; never called on its own.
    private func typeUnicode(_ value: String) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        let utf16 = Array(value.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }
        utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    // MARK: - Traversal

    private func focusedWindowRoots() -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &value
        )
        if error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return [unsafeBitCast(value, to: AXUIElement.self)]
        }
        // No focused window — try all windows.
        var windowsRef: CFTypeRef?
        let windowsError = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef
        )
        if windowsError == .success, let array = windowsRef as? [AXUIElement] {
            return array
        }
        return [appElement]
    }

    private func traverse(
        _ element: AXUIElement,
        depth: Int,
        visited: inout Int,
        collect: (AXUIElement, String?, String?) -> Void
    ) {
        guard depth <= Self.maxDepth, visited < Self.maxVisitedNodes else { return }
        visited += 1

        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        if let role, Self.editableRoles.contains(role) {
            collect(element, role, subrole)
        }

        var childrenRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef
        )
        guard error == .success, let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            traverse(child, depth: depth + 1, visited: &visited, collect: collect)
        }
    }

    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    // MARK: - Attribute helpers

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value else { return nil }
        if let s = value as? String { return s }
        return nil
    }

    /// A field's label: its AXTitle, else the value of its linked title element,
    /// else its AXDescription.
    private func label(of element: AXUIElement) -> String? {
        if let title = string(element, kAXTitleAttribute), !title.isEmpty { return title }
        // Prefer the field's own placeholder ("Email", "Phone") over a linked
        // title element, which on Contacts cards is the "home/work/mobile" popup
        // rather than the field's meaning.
        if let placeholder = string(element, kAXPlaceholderValueAttribute), !placeholder.isEmpty {
            return placeholder
        }
        var titleUIRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleUIElementAttribute as CFString, &titleUIRef) == .success,
           let titleUIRef, CFGetTypeID(titleUIRef) == AXUIElementGetTypeID() {
            let titleElement = unsafeBitCast(titleUIRef, to: AXUIElement.self)
            if let linked = string(titleElement, kAXValueAttribute) ?? string(titleElement, kAXTitleAttribute),
               !linked.isEmpty {
                return linked
            }
        }
        if let description = string(element, kAXDescriptionAttribute), !description.isEmpty {
            return description
        }
        return nil
    }
}
