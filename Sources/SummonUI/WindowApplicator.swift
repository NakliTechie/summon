import AppKit
import ApplicationServices
import Foundation
import SummonCore

/// Public macOS APIs expose the focused window on the active Space, but do not
/// expose moving windows between Spaces. Summon therefore scopes window actions
/// to that focused window instead of presenting cross-Space controls.
public enum WindowSpaceBehavior: String, Sendable, Equatable {
    case focusedWindowOnActiveSpace
}

/// Pure AX/Cocoa conversion and display-selection helpers.
///
/// The largest-intersection display policy follows Rectangle's MIT-licensed
/// `ScreenDetection` behavior (Copyright 2019-2026 Ryan Hanson):
/// https://github.com/rxhanson/Rectangle/blob/main/Rectangle/ScreenDetection.swift
enum WindowCoordinateSpace {
    static func axFrame(fromCocoaFrame frame: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func cocoaFrame(fromAXFrame frame: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func screenIndex(
        containingCocoaFrame windowFrame: CGRect,
        screenFrames: [CGRect],
        fallbackIndex: Int = 0
    ) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        if let containing = screenFrames.firstIndex(where: { $0.contains(windowFrame) }) {
            return containing
        }

        var selectedIndex: Int?
        var largestIntersection: CGFloat = 0
        for (index, screenFrame) in screenFrames.enumerated() {
            let intersection = windowFrame.intersection(screenFrame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > largestIntersection {
                largestIntersection = area
                selectedIndex = index
            }
        }
        if let selectedIndex { return selectedIndex }
        return min(max(0, fallbackIndex), screenFrames.count - 1)
    }
}

enum WindowFrameAttribute: String, Sendable, Equatable {
    case position
    case size
}

/// Applies `WindowGeometry` frames to the frontmost focused window via Accessibility.
public enum WindowApplicator {
    public static let spaceBehavior = WindowSpaceBehavior.focusedWindowOnActiveSpace

    public static func apply(layout: WindowLayout, gap: CGFloat = 8) throws {
        guard AXIsProcessTrusted() else {
            throw CoreError.io(
                "Accessibility permission is off; enable Summon in System Settings › Privacy & Security › Accessibility"
            )
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw CoreError.io("No frontmost application has a window to arrange")
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let focusedWindow = try copyFocusedWindow(from: appElement)
        let currentAXFrame = try copyFrame(from: focusedWindow)
        let screens = NSScreen.screens
        guard let primaryScreen = screens.first else {
            throw CoreError.io("No display is available for window arrangement")
        }

        let currentCocoaFrame = WindowCoordinateSpace.cocoaFrame(
            fromAXFrame: currentAXFrame,
            primaryFrame: primaryScreen.frame
        )
        guard let screenIndex = WindowCoordinateSpace.screenIndex(
            containingCocoaFrame: currentCocoaFrame,
            screenFrames: screens.map(\.frame)
        ) else {
            throw CoreError.io("The focused window is not associated with an available display")
        }

        let targetCocoaFrame = WindowGeometry.frame(
            layout: layout,
            screen: screens[screenIndex].visibleFrame,
            gap: gap
        )
        let targetAXFrame = WindowCoordinateSpace.axFrame(
            fromCocoaFrame: targetCocoaFrame,
            primaryFrame: primaryScreen.frame
        )
        try set(frame: targetAXFrame, restoring: currentAXFrame, on: focusedWindow)
    }

    static func axErrorMessage(operation: String, error: AXError) -> String {
        let detail: String
        switch error {
        case .apiDisabled:
            detail = "Accessibility permission is off"
        case .cannotComplete:
            detail = "the target application did not answer"
        case .attributeUnsupported:
            detail = "the focused window does not support this attribute"
        case .invalidUIElement:
            detail = "the focused window is no longer available"
        case .noValue:
            detail = "the focused window did not provide a value"
        default:
            detail = "Accessibility returned error \(error.rawValue)"
        }
        return "\(operation) failed: \(detail)"
    }

    private static func copyFocusedWindow(from appElement: AXUIElement) throws -> AXUIElement {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard error == .success else {
            throw CoreError.io(axErrorMessage(operation: "Focused-window lookup", error: error))
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw CoreError.io("Focused-window lookup failed: no focused window is available on the active Space")
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copyFrame(from window: AXUIElement) throws -> CGRect {
        var positionValue: CFTypeRef?
        let positionError = AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionValue
        )
        guard positionError == .success else {
            throw CoreError.io(axErrorMessage(operation: "Focused-window position lookup", error: positionError))
        }

        var sizeValue: CFTypeRef?
        let sizeError = AXUIElementCopyAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            &sizeValue
        )
        guard sizeError == .success else {
            throw CoreError.io(axErrorMessage(operation: "Focused-window size lookup", error: sizeError))
        }

        guard let positionValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue,
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw CoreError.io("Focused-window frame lookup failed: Accessibility returned an invalid value")
        }

        let axPosition = unsafeBitCast(positionValue, to: AXValue.self)
        let axSize = unsafeBitCast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(axPosition) == .cgPoint,
              AXValueGetValue(axPosition, .cgPoint, &position),
              AXValueGetType(axSize) == .cgSize,
              AXValueGetValue(axSize, .cgSize, &size) else {
            throw CoreError.io("Focused-window frame lookup failed: Accessibility returned an invalid frame")
        }
        return CGRect(origin: position, size: size)
    }

    static func applyFrameTransaction(
        frame: CGRect,
        originalFrame: CGRect,
        writer: (WindowFrameAttribute, CGRect) throws -> AXError
    ) throws {
        let sizeError = try writer(.size, frame)
        guard sizeError == .success else {
            throw CoreError.io(axErrorMessage(operation: "Window sizing", error: sizeError))
        }

        let positionError = try writer(.position, frame)
        guard positionError == .success else {
            var restorationFailures: [String] = []
            for attribute in [WindowFrameAttribute.size, .position] {
                do {
                    let error = try writer(attribute, originalFrame)
                    if error != .success {
                        restorationFailures.append(
                            axErrorMessage(operation: "Original window (attribute.rawValue) restoration", error: error)
                        )
                    }
                } catch {
                    restorationFailures.append(
                        "Original window (attribute.rawValue) restoration failed: (error.localizedDescription)"
                    )
                }
            }

            let positioningFailure = axErrorMessage(operation: "Window positioning", error: positionError)
            if restorationFailures.isEmpty {
                throw CoreError.io("(positioningFailure); the original frame was restored")
            }
            throw CoreError.io(
                "\(positioningFailure); restoring the original frame also failed: "
                    + restorationFailures.joined(separator: "; ")
            )
        }
    }

    private static func set(frame: CGRect, restoring originalFrame: CGRect, on window: AXUIElement) throws {
        try requireSettable(.size, on: window)
        try requireSettable(.position, on: window)
        try applyFrameTransaction(frame: frame, originalFrame: originalFrame) { attribute, valueFrame in
            try write(attribute, frame: valueFrame, on: window)
        }
    }

    private static func requireSettable(_ attribute: WindowFrameAttribute, on window: AXUIElement) throws {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(window, axAttribute(attribute), &settable)
        let operation = attribute == .size ? "Window sizing preflight" : "Window positioning preflight"
        guard error == .success else {
            throw CoreError.io(axErrorMessage(operation: operation, error: error))
        }
        guard settable.boolValue else {
            throw CoreError.io("(operation) failed: the focused window does not allow this change")
        }
    }

    private static func write(
        _ attribute: WindowFrameAttribute,
        frame: CGRect,
        on window: AXUIElement
    ) throws -> AXError {
        switch attribute {
        case .position:
            var position = frame.origin
            guard let value = AXValueCreate(.cgPoint, &position) else {
                throw CoreError.io("Window arrangement failed: unable to create an Accessibility position")
            }
            return AXUIElementSetAttributeValue(window, axAttribute(attribute), value)
        case .size:
            var size = frame.size
            guard let value = AXValueCreate(.cgSize, &size) else {
                throw CoreError.io("Window arrangement failed: unable to create an Accessibility size")
            }
            return AXUIElementSetAttributeValue(window, axAttribute(attribute), value)
        }
    }

    private static func axAttribute(_ attribute: WindowFrameAttribute) -> CFString {
        switch attribute {
        case .position:
            return kAXPositionAttribute as CFString
        case .size:
            return kAXSizeAttribute as CFString
        }
    }
}
