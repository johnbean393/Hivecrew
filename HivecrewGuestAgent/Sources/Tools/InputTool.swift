//
//  InputTool.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation
import CoreGraphics
import HivecrewAgentProtocol

/// Tool for mouse and keyboard input automation
final class InputTool {
    private let logger = AgentLogger.shared
    private var lastMouseLocation: CGPoint?

    // MARK: - Mouse Operations

    /// Move the mouse to specified coordinates
    func mouseMove(x: Double, y: Double) throws {
        logger.log("Moving mouse to (\(x), \(y))")

        let point = CGPoint(x: x, y: y)
        let eventSource = CGEventSource(stateID: .hidSystemState)
        try animateMouseMotion(to: point, eventType: .mouseMoved, button: .left, eventSource: eventSource)
    }

    /// Click at specified coordinates
    func mouseClick(x: Double, y: Double, button: MouseButton, clickType: ClickType) throws {
        logger.log("Clicking at (\(x), \(y)) with \(button.rawValue) button, \(clickType.rawValue) click")

        let point = CGPoint(x: x, y: y)
        let cgButton: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType

        switch button {
        case .left:
            cgButton = .left
            downType = .leftMouseDown
            upType = .leftMouseUp
        case .right:
            cgButton = .right
            downType = .rightMouseDown
            upType = .rightMouseUp
        case .middle:
            cgButton = .center
            downType = .otherMouseDown
            upType = .otherMouseUp
        }

        let clickCount: Int64
        switch clickType {
        case .single:
            clickCount = 1
        case .double:
            clickCount = 2
        case .triple:
            clickCount = 3
        }

        let eventSource = CGEventSource(stateID: .hidSystemState)
        try animateMouseMotion(to: point, eventType: .mouseMoved, button: cgButton, eventSource: eventSource)

        for i in 1...clickCount {
            let downEvent = try makeMouseEvent(
                source: eventSource,
                type: downType,
                point: point,
                button: cgButton,
                errorMessage: "Failed to create mouse down event"
            )
            downEvent.setIntegerValueField(.mouseEventClickState, value: i)
            downEvent.post(tap: .cgSessionEventTap)

            updateOverlay { overlay in
                overlay.showClick(at: point, button: button)
            }

            Thread.sleep(forTimeInterval: 0.028)

            let upEvent = try makeMouseEvent(
                source: eventSource,
                type: upType,
                point: point,
                button: cgButton,
                errorMessage: "Failed to create mouse up event"
            )
            upEvent.setIntegerValueField(.mouseEventClickState, value: i)
            upEvent.post(tap: .cgSessionEventTap)

            if i < clickCount {
                Thread.sleep(forTimeInterval: 0.08)
            }
        }

        logger.log("Click completed at (\(x), \(y))")
    }

    /// Drag from one point to another
    func mouseDrag(fromX: Double, fromY: Double, toX: Double, toY: Double) throws {
        logger.log("Dragging from (\(fromX), \(fromY)) to (\(toX), \(toY))")

        let startPoint = CGPoint(x: fromX, y: fromY)
        let endPoint = CGPoint(x: toX, y: toY)
        let eventSource = CGEventSource(stateID: .hidSystemState)

        try animateMouseMotion(to: startPoint, eventType: .mouseMoved, button: .left, eventSource: eventSource)

        let downEvent = try makeMouseEvent(
            source: eventSource,
            type: .leftMouseDown,
            point: startPoint,
            button: .left,
            errorMessage: "Failed to create mouse down event"
        )
        downEvent.post(tap: .cgSessionEventTap)

        updateOverlay { overlay in
            overlay.showClick(at: startPoint, button: .left)
        }

        Thread.sleep(forTimeInterval: 0.03)

        try animateMouseMotion(to: endPoint, eventType: .leftMouseDragged, button: .left, eventSource: eventSource)

        let upEvent = try makeMouseEvent(
            source: eventSource,
            type: .leftMouseUp,
            point: endPoint,
            button: .left,
            errorMessage: "Failed to create mouse up event"
        )
        upEvent.post(tap: .cgSessionEventTap)
    }

    /// Scroll at specified coordinates
    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) throws {
        logger.log("Scrolling at (\(x), \(y)) with delta (\(deltaX), \(deltaY))")

        let eventSource = CGEventSource(stateID: .hidSystemState)
        let point = CGPoint(x: x, y: y)

        try animateMouseMotion(to: point, eventType: .mouseMoved, button: .left, eventSource: eventSource)

        updateOverlay { overlay in
            overlay.showScroll(at: point, deltaX: deltaX, deltaY: deltaY)
        }

        // Post a single scroll event. Splitting into many tiny events triggers
        // macOS scroll momentum, which causes runaway scrolling to the top or
        // bottom of the view — and with small sleeps between events the loop
        // would run long enough to exhaust the tool's timeout.
        // Note: positive deltaY reveals content below (scrolls up), negative reveals content above.
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .line,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create scroll event")
        }
        scrollEvent.post(tap: .cgSessionEventTap)
    }

    // MARK: - Keyboard Operations

    /// Type a string of text
    func keyboardType(text: String) throws {
        logger.log("Typing text: \(text.prefix(50))...")

        let eventSource = CGEventSource(stateID: .hidSystemState)

        for character in text {
            let string = String(character)
            var unicodeChars = Array(string.utf16)

            guard let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) else {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create keyboard event")
            }

            downEvent.keyboardSetUnicodeString(stringLength: unicodeChars.count, unicodeString: &unicodeChars)
            downEvent.post(tap: .cgSessionEventTap)

            guard let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create key up event")
            }
            upEvent.keyboardSetUnicodeString(stringLength: unicodeChars.count, unicodeString: &unicodeChars)
            upEvent.post(tap: .cgSessionEventTap)

            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Press a specific key with optional modifiers
    func keyboardKey(key: String, modifiers: [KeyModifier]) throws {
        logger.log("Pressing key: \(key) with modifiers: \(modifiers)")

        guard let keyCode = virtualKeyCode(for: key) else {
            throw AgentError(code: AgentError.invalidParams, message: "Unknown key: \(key)")
        }

        let eventSource = CGEventSource(stateID: .hidSystemState)

        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case .command:
                flags.insert(.maskCommand)
            case .control:
                flags.insert(.maskControl)
            case .option:
                flags.insert(.maskAlternate)
            case .shift:
                flags.insert(.maskShift)
            case .function:
                flags.insert(.maskSecondaryFn)
            }
        }

        guard let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create key down event")
        }
        downEvent.flags = flags
        downEvent.post(tap: .cgSessionEventTap)

        Thread.sleep(forTimeInterval: 0.05)

        guard let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create key up event")
        }
        upEvent.flags = flags
        upEvent.post(tap: .cgSessionEventTap)
    }

    // MARK: - Key Code Mapping

    private func virtualKeyCode(for key: String) -> CGKeyCode? {
        let keyMap: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "`": 50,
            "return": 36, "enter": 36,
            "tab": 48,
            "space": 49,
            "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53,
            "command": 55, "cmd": 55,
            "shift": 56,
            "capslock": 57,
            "option": 58, "alt": 58,
            "control": 59, "ctrl": 59,
            "rightshift": 60,
            "rightoption": 61, "rightalt": 61,
            "rightcontrol": 62, "rightctrl": 62,
            "function": 63, "fn": 63,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "left": 123, "leftarrow": 123,
            "right": 124, "rightarrow": 124,
            "down": 125, "downarrow": 125,
            "up": 126, "uparrow": 126,
            "home": 115,
            "end": 119,
            "pageup": 116,
            "pagedown": 121,
            "forwarddelete": 117,
            "help": 114
        ]

        return keyMap[key.lowercased()]
    }

    // MARK: - Motion Helpers

    private func animateMouseMotion(
        to destination: CGPoint,
        eventType: CGEventType,
        button: CGMouseButton,
        eventSource: CGEventSource?
    ) throws {
        let start = currentMouseLocation()
        let samples = motionSamples(from: start, to: destination)
        let stepDuration = motionStepDuration(for: start, destination: destination, sampleCount: samples.count)

        for (index, point) in samples.enumerated() {
            let event = try makeMouseEvent(
                source: eventSource,
                type: eventType,
                point: point,
                button: button,
                errorMessage: "Failed to create mouse motion event"
            )
            event.post(tap: .cgSessionEventTap)
            lastMouseLocation = point

            updateOverlay { overlay in
                overlay.movePointer(to: point)
            }

            if index < samples.count - 1 {
                Thread.sleep(forTimeInterval: stepDuration)
            }
        }
    }

    private func currentMouseLocation() -> CGPoint {
        if let lastMouseLocation {
            return lastMouseLocation
        }

        let point = CGEvent(source: nil)?.location ?? .zero
        lastMouseLocation = point
        return point
    }

    private func motionSamples(from start: CGPoint, to destination: CGPoint) -> [CGPoint] {
        let distance = hypot(destination.x - start.x, destination.y - start.y)
        guard distance > 1 else { return [destination] }

        let unit = CGPoint(
            x: (destination.x - start.x) / distance,
            y: (destination.y - start.y) / distance
        )
        let perpendicular = CGPoint(x: -unit.y, y: unit.x)

        let lateralOffset = min(54.0, max(8.0, distance * 0.11))
        let controlSkew = Double.random(in: -0.7...0.7)
        let secondSkew = (-controlSkew * 0.55) + Double.random(in: -0.16...0.16)

        let control1 = CGPoint(
            x: start.x + (unit.x * distance * 0.26) + (perpendicular.x * lateralOffset * controlSkew),
            y: start.y + (unit.y * distance * 0.26) + (perpendicular.y * lateralOffset * controlSkew)
        )
        let control2 = CGPoint(
            x: start.x + (unit.x * distance * 0.78) + (perpendicular.x * lateralOffset * secondSkew),
            y: start.y + (unit.y * distance * 0.78) + (perpendicular.y * lateralOffset * secondSkew)
        )

        let overshootDistance = distance > 280 ? min(20.0, distance * 0.04) : 0
        let overshootTarget = CGPoint(
            x: destination.x + (unit.x * overshootDistance),
            y: destination.y + (unit.y * overshootDistance)
        )

        let baseDuration = min(0.62, max(0.16, 0.11 + (distance / 1450)))
        let stepCount = max(10, Int(baseDuration * 90))
        var samples: [CGPoint] = []
        samples.reserveCapacity(stepCount + 6)

        for step in 1...stepCount {
            let t = Double(step) / Double(stepCount)
            let eased = minimumJerk(t)
            samples.append(cubicBezier(start: start, c1: control1, c2: control2, end: overshootTarget, t: eased))
        }

        if overshootDistance > 0 {
            let settleStart = samples.last ?? overshootTarget
            for step in 1...6 {
                let t = Double(step) / 6.0
                let eased = 1 - pow(1 - t, 2.4)
                samples.append(interpolate(from: settleStart, to: destination, t: eased))
            }
        } else if !samples.isEmpty {
            samples[samples.count - 1] = destination
        }

        return samples
    }

    private func motionStepDuration(for start: CGPoint, destination: CGPoint, sampleCount: Int) -> TimeInterval {
        let distance = hypot(destination.x - start.x, destination.y - start.y)
        let duration = min(0.62, max(0.16, 0.11 + (distance / 1450)))
        return duration / Double(max(sampleCount, 1))
    }

    private func minimumJerk(_ t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        let t4 = t3 * t
        let t5 = t4 * t
        return (10 * t3) - (15 * t4) + (6 * t5)
    }

    private func cubicBezier(start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint, t: Double) -> CGPoint {
        let mt = 1 - t
        let mt2 = mt * mt
        let t2 = t * t

        let x =
            (mt2 * mt * start.x) +
            (3 * mt2 * t * c1.x) +
            (3 * mt * t2 * c2.x) +
            (t2 * t * end.x)

        let y =
            (mt2 * mt * start.y) +
            (3 * mt2 * t * c1.y) +
            (3 * mt * t2 * c2.y) +
            (t2 * t * end.y)

        return CGPoint(x: x, y: y)
    }

    private func interpolate(from start: CGPoint, to end: CGPoint, t: Double) -> CGPoint {
        CGPoint(
            x: start.x + ((end.x - start.x) * t),
            y: start.y + ((end.y - start.y) * t)
        )
    }

    private func makeMouseEvent(
        source: CGEventSource?,
        type: CGEventType,
        point: CGPoint,
        button: CGMouseButton,
        errorMessage: String
    ) throws -> CGEvent {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: errorMessage)
        }

        return event
    }

    private func updateOverlay(_ action: @escaping @MainActor (InputPointerOverlayController) -> Void) {
        Task { @MainActor in
            action(InputPointerOverlayController.shared)
        }
    }
}
