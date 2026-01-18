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
    
    // MARK: - Mouse Operations
    
    /// Move the mouse to specified coordinates
    func mouseMove(x: Double, y: Double) throws {
        logger.log("Moving mouse to (\(x), \(y))")
        
        let point = CGPoint(x: x, y: y)
        let eventSource = CGEventSource(stateID: .hidSystemState)
        
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create mouse move event")
        }
        
        event.post(tap: .cgSessionEventTap)
    }
    
    /// Click at specified coordinates
    func mouseClick(x: Double, y: Double, button: MouseButton, clickType: ClickType) throws {
        logger.log("Clicking at (\(x), \(y)) with \(button.rawValue) button, \(clickType.rawValue) click")
        
        let point = CGPoint(x: x, y: y)
        let cgButton: CGMouseButton = button == .right ? .right : .left
        
        // Create an event source for more reliable event posting
        let eventSource = CGEventSource(stateID: .hidSystemState)
        
        let downType: CGEventType
        let upType: CGEventType
        
        switch button {
        case .left:
            downType = .leftMouseDown
            upType = .leftMouseUp
        case .right:
            downType = .rightMouseDown
            upType = .rightMouseUp
        case .middle:
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
        
        // First, move the cursor to the target position
        guard let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create mouse move event")
        }
        moveEvent.post(tap: .cgSessionEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        
        // Perform the click(s)
        for i in 1...clickCount {
            guard let downEvent = CGEvent(mouseEventSource: eventSource, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton) else {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create mouse down event")
            }
            downEvent.setIntegerValueField(.mouseEventClickState, value: i)
            downEvent.post(tap: .cgSessionEventTap)
            
            // Small delay between down and up
            Thread.sleep(forTimeInterval: 0.02)
            
            guard let upEvent = CGEvent(mouseEventSource: eventSource, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton) else {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create mouse up event")
            }
            upEvent.setIntegerValueField(.mouseEventClickState, value: i)
            upEvent.post(tap: .cgSessionEventTap)
            
            if i < clickCount {
                Thread.sleep(forTimeInterval: 0.1)
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
        
        // Move to start position
        guard let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: startPoint, mouseButton: .left) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create move event")
        }
        moveEvent.post(tap: .cgSessionEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        
        // Mouse down
        guard let downEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: startPoint, mouseButton: .left) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create mouse down event")
        }
        downEvent.post(tap: .cgSessionEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        
        // Drag to end position
        guard let dragEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: endPoint, mouseButton: .left) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create drag event")
        }
        dragEvent.post(tap: .cgSessionEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        
        // Mouse up
        guard let upEvent = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: endPoint, mouseButton: .left) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create mouse up event")
        }
        upEvent.post(tap: .cgSessionEventTap)
    }
    
    /// Scroll at specified coordinates
    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) throws {
        logger.log("Scrolling at (\(x), \(y)) with delta (\(deltaX), \(deltaY))")
        
        let eventSource = CGEventSource(stateID: .hidSystemState)
        let point = CGPoint(x: x, y: y)
        
        // First move mouse to position so scroll targets the right window
        guard let moveEvent = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create move event")
        }
        moveEvent.post(tap: .cgSessionEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        
        // Create scroll event using .line units for more intuitive scrolling
        // With .line units, values like 1-5 scroll a few lines at a time
        // Note: positive deltaY scrolls content UP (reveals content below), negative scrolls DOWN
        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: eventSource, units: .line, wheelCount: 2, wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create scroll event")
        }
        
        // Set the scroll event location explicitly
        scrollEvent.location = point
        
        // Post to HID event tap (like keyboard events) for more reliable delivery
        scrollEvent.post(tap: .cghidEventTap)
    }
    
    // MARK: - Keyboard Operations
    
    /// Type a string of text
    func keyboardType(text: String) throws {
        logger.log("Typing text: \(text.prefix(50))...")
        
        // Create an event source for reliable event posting (same as mouse events)
        let eventSource = CGEventSource(stateID: .hidSystemState)
        
        for character in text {
            let string = String(character)
            var unicodeChars = Array(string.utf16)
            
            // Use CGEventKeyboardSetUnicodeString for reliable text input
            guard let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) else {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create keyboard event")
            }
            
            downEvent.keyboardSetUnicodeString(stringLength: unicodeChars.count, unicodeString: &unicodeChars)
            downEvent.post(tap: .cgSessionEventTap)
            
            // Key up - also set unicode string for proper character completion
            guard let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create key up event")
            }
            upEvent.keyboardSetUnicodeString(stringLength: unicodeChars.count, unicodeString: &unicodeChars)
            upEvent.post(tap: .cgSessionEventTap)
            
            // Small delay between characters
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    
    /// Press a specific key with optional modifiers
    func keyboardKey(key: String, modifiers: [KeyModifier]) throws {
        logger.log("Pressing key: \(key) with modifiers: \(modifiers)")
        
        guard let keyCode = virtualKeyCode(for: key) else {
            throw AgentError(code: AgentError.invalidParams, message: "Unknown key: \(key)")
        }
        
        // Create an event source for reliable event posting
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
        
        // Key down with modifiers
        guard let downEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create key down event")
        }
        downEvent.flags = flags
        downEvent.post(tap: .cgSessionEventTap)
        
        Thread.sleep(forTimeInterval: 0.05)
        
        // Key up
        guard let upEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to create key up event")
        }
        upEvent.flags = flags
        upEvent.post(tap: .cgSessionEventTap)
    }
    
    // MARK: - Key Code Mapping
    
    private func virtualKeyCode(for key: String) -> CGKeyCode? {
        // Common key mappings
        let keyMap: [String: CGKeyCode] = [
            // Letters
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "`": 50,
            
            // Special keys
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
            
            // Function keys
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            
            // Arrow keys
            "left": 123, "leftarrow": 123,
            "right": 124, "rightarrow": 124,
            "down": 125, "downarrow": 125,
            "up": 126, "uparrow": 126,
            
            // Other
            "home": 115,
            "end": 119,
            "pageup": 116,
            "pagedown": 121,
            "forwarddelete": 117,
            "help": 114
        ]
        
        return keyMap[key.lowercased()]
    }
}
