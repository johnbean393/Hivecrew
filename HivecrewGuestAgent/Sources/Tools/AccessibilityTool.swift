//
//  AccessibilityTool.swift
//  HivecrewGuestAgent
//
//  Accessibility tree traversal tool based on MacosUseSDK
//

import Foundation
import AppKit
@preconcurrency import ApplicationServices
import HivecrewAgentProtocol

/// Tool for traversing the accessibility tree of applications
final class AccessibilityTool {
    private let logger = AgentLogger.shared
    
    /// Traverse the accessibility tree for an application
    /// - Parameters:
    ///   - pid: Process ID of the target application. If nil, uses the frontmost app.
    ///   - onlyVisibleElements: If true, only collects elements with valid position and size.
    /// - Returns: AccessibilityTraversalResult containing elements and statistics
    func traverseAccessibilityTree(pid: Int32?, onlyVisibleElements: Bool) throws -> [String: Any] {
        let overallStartTime = Date()
        
        // Determine target PID
        let targetPID: Int32
        if let providedPID = pid {
            targetPID = providedPID
        } else {
            // Use frontmost app
            guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "No frontmost application found")
            }
            targetPID = frontmostApp.processIdentifier
        }
        
        logger.log("Starting accessibility traversal for PID \(targetPID) (onlyVisibleElements: \(onlyVisibleElements))")
        
        // Check accessibility permissions
        let checkOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(checkOptions)
        
        if !isTrusted {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Accessibility access is denied. Please grant permissions in System Settings > Privacy & Security > Accessibility.")
        }
        
        // Find the target application
        guard let runningApp = NSRunningApplication(processIdentifier: targetPID) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "No running application found with PID \(targetPID)")
        }
        
        let appName = runningApp.localizedName ?? "App (PID: \(targetPID))"
        let appElement = AXUIElementCreateApplication(targetPID)
        
        // Activate app if needed for better traversal results
        if runningApp.activationPolicy == .regular && !runningApp.isActive {
            runningApp.activate()
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        // Perform traversal
        let operation = AccessibilityTraversalOperation(
            appElement: appElement,
            appName: appName,
            onlyVisibleElements: onlyVisibleElements,
            logger: logger
        )
        
        let result = operation.execute()
        
        // Calculate processing time
        let processingTime = Date().timeIntervalSince(overallStartTime)
        let formattedTime = String(format: "%.2f", processingTime)
        
        logger.log("Traversal complete: \(result.elements.count) elements in \(formattedTime)s")
        
        // Build response dictionary
        return [
            "appName": appName,
            "elements": result.elements.map { element in
                var dict: [String: Any] = ["role": element.role]
                if let text = element.text { dict["text"] = text }
                if let x = element.x { dict["x"] = x }
                if let y = element.y { dict["y"] = y }
                if let width = element.width { dict["width"] = width }
                if let height = element.height { dict["height"] = height }
                return dict
            },
            "stats": [
                "count": result.stats.count,
                "excludedCount": result.stats.excludedCount,
                "excludedNonInteractable": result.stats.excludedNonInteractable,
                "excludedNoText": result.stats.excludedNoText,
                "withTextCount": result.stats.withTextCount,
                "withoutTextCount": result.stats.withoutTextCount,
                "visibleElementsCount": result.stats.visibleElementsCount,
                "roleCounts": result.stats.roleCounts
            ],
            "processingTimeSeconds": formattedTime
        ]
    }
}

// MARK: - Internal Traversal Operation

/// Encapsulates the state and logic of a single traversal operation
private class AccessibilityTraversalOperation {
    let appElement: AXUIElement
    let appName: String
    let onlyVisibleElements: Bool
    let logger: AgentLogger
    
    var visitedElements: Set<AXUIElement> = []
    var collectedElements: [AccessibilityElementData] = []
    var statistics = TraversalStats()
    
    let maxDepth = 100
    
    // Roles considered non-interactable by default
    let nonInteractableRoles: Set<String> = [
        "AXGroup", "AXStaticText", "AXUnknown", "AXSeparator",
        "AXHeading", "AXLayoutArea", "AXHelpTag", "AXGrowArea",
        "AXOutline", "AXScrollArea", "AXSplitGroup", "AXSplitter",
        "AXToolbar", "AXDisclosureTriangle",
    ]
    
    init(appElement: AXUIElement, appName: String, onlyVisibleElements: Bool, logger: AgentLogger) {
        self.appElement = appElement
        self.appName = appName
        self.onlyVisibleElements = onlyVisibleElements
        self.logger = logger
    }
    
    func execute() -> (elements: [AccessibilityElementData], stats: TraversalStats) {
        // Start traversal from app element
        walkElementTree(element: appElement, depth: 0)
        
        // Sort elements by position (top-to-bottom, left-to-right)
        let sortedElements = collectedElements.sorted {
            let y0 = $0.y ?? Double.greatestFiniteMagnitude
            let y1 = $1.y ?? Double.greatestFiniteMagnitude
            if y0 != y1 { return y0 < y1 }
            let x0 = $0.x ?? Double.greatestFiniteMagnitude
            let x1 = $1.x ?? Double.greatestFiniteMagnitude
            return x0 < x1
        }
        
        statistics.count = sortedElements.count
        
        return (sortedElements, statistics)
    }
    
    // MARK: - Tree Walking
    
    private func walkElementTree(element: AXUIElement, depth: Int) {
        // Check for cycles and depth limit
        if visitedElements.contains(element) || depth > maxDepth {
            return
        }
        visitedElements.insert(element)
        
        // Extract element attributes
        let (role, roleDesc, combinedText, position, size) = extractElementAttributes(element: element)
        let hasText = combinedText != nil && !combinedText!.isEmpty
        let isNonInteractable = nonInteractableRoles.contains(role)
        let roleWithoutAX = role.starts(with: "AX") ? String(role.dropFirst(2)) : role
        
        statistics.roleCounts[role, default: 0] += 1
        
        // Determine geometry
        var finalX: Double? = nil
        var finalY: Double? = nil
        var finalWidth: Double? = nil
        var finalHeight: Double? = nil
        
        if let p = position, let s = size, s.width > 0 || s.height > 0 {
            finalX = Double(p.x)
            finalY = Double(p.y)
            finalWidth = s.width > 0 ? Double(s.width) : nil
            finalHeight = s.height > 0 ? Double(s.height) : nil
        }
        
        let isGeometricallyVisible = finalX != nil && finalY != nil && finalWidth != nil && finalHeight != nil
        
        if isGeometricallyVisible {
            statistics.visibleElementsCount += 1
        }
        
        // Apply filtering logic
        var displayRole = role
        if let desc = roleDesc, !desc.isEmpty, !desc.elementsEqual(roleWithoutAX) {
            displayRole = "\(role) (\(desc))"
        }
        
        let passesOriginalFilter = !isNonInteractable || hasText
        let shouldCollectElement = passesOriginalFilter && (!onlyVisibleElements || isGeometricallyVisible)
        
        if shouldCollectElement {
            let elementData = AccessibilityElementData(
                role: displayRole,
                text: combinedText,
                x: finalX,
                y: finalY,
                width: finalWidth,
                height: finalHeight
            )
            
            // Check for duplicates using a simple comparison
            let isDuplicate = collectedElements.contains { existing in
                existing.role == elementData.role &&
                existing.text == elementData.text &&
                existing.x == elementData.x &&
                existing.y == elementData.y
            }
            
            if !isDuplicate {
                collectedElements.append(elementData)
                if hasText {
                    statistics.withTextCount += 1
                } else {
                    statistics.withoutTextCount += 1
                }
            }
        } else {
            statistics.excludedCount += 1
            if isNonInteractable {
                statistics.excludedNonInteractable += 1
            }
            if !hasText {
                statistics.excludedNoText += 1
            }
        }
        
        // Recursively traverse children
        traverseChildren(of: element, depth: depth)
    }
    
    private func traverseChildren(of element: AXUIElement, depth: Int) {
        // Windows
        if let windowsValue = copyAttributeValue(element: element, attribute: kAXWindowsAttribute as String) {
            if let windowsArray = windowsValue as? [AXUIElement] {
                for windowElement in windowsArray where !visitedElements.contains(windowElement) {
                    walkElementTree(element: windowElement, depth: depth + 1)
                }
            }
        }
        
        // Main window
        if let mainWindowValue = copyAttributeValue(element: element, attribute: kAXMainWindowAttribute as String) {
            if CFGetTypeID(mainWindowValue) == AXUIElementGetTypeID() {
                let mainWindowElement = mainWindowValue as! AXUIElement
                if !visitedElements.contains(mainWindowElement) {
                    walkElementTree(element: mainWindowElement, depth: depth + 1)
                }
            }
        }
        
        // Regular children
        if let childrenValue = copyAttributeValue(element: element, attribute: kAXChildrenAttribute as String) {
            if let childrenArray = childrenValue as? [AXUIElement] {
                for childElement in childrenArray where !visitedElements.contains(childElement) {
                    walkElementTree(element: childElement, depth: depth + 1)
                }
            }
        }
    }
    
    // MARK: - Attribute Extraction
    
    private func extractElementAttributes(element: AXUIElement) -> (role: String, roleDesc: String?, text: String?, position: CGPoint?, size: CGSize?) {
        var role = "AXUnknown"
        var roleDesc: String? = nil
        var textParts: [String] = []
        var position: CGPoint? = nil
        var size: CGSize? = nil
        
        // Role
        if let roleValue = copyAttributeValue(element: element, attribute: kAXRoleAttribute as String) {
            role = getStringValue(roleValue) ?? "AXUnknown"
        }
        
        // Role description
        if let roleDescValue = copyAttributeValue(element: element, attribute: kAXRoleDescriptionAttribute as String) {
            roleDesc = getStringValue(roleDescValue)
        }
        
        // Text from various attributes
        let textAttributes = [
            kAXValueAttribute as String,
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            "AXLabel",
            "AXHelp"
        ]
        
        for attr in textAttributes {
            if let attrValue = copyAttributeValue(element: element, attribute: attr),
               let text = getStringValue(attrValue),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textParts.append(text)
            }
        }
        
        let combinedText = textParts.isEmpty ? nil : textParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Position
        if let posValue = copyAttributeValue(element: element, attribute: kAXPositionAttribute as String) {
            position = getCGPointValue(posValue)
        }
        
        // Size
        if let sizeValue = copyAttributeValue(element: element, attribute: kAXSizeAttribute as String) {
            size = getCGSizeValue(sizeValue)
        }
        
        return (role, roleDesc, combinedText, position, size)
    }
    
    // MARK: - Helpers
    
    private func copyAttributeValue(element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }
    
    private func getStringValue(_ value: CFTypeRef?) -> String? {
        guard let value = value else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() {
            return value as! CFString as String
        }
        return nil
    }
    
    private func getCGPointValue(_ value: CFTypeRef?) -> CGPoint? {
        guard let value = value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var pointValue = CGPoint.zero
        if AXValueGetValue(axValue, .cgPoint, &pointValue) {
            return pointValue
        }
        return nil
    }
    
    private func getCGSizeValue(_ value: CFTypeRef?) -> CGSize? {
        guard let value = value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var sizeValue = CGSize.zero
        if AXValueGetValue(axValue, .cgSize, &sizeValue) {
            return sizeValue
        }
        return nil
    }
}

// MARK: - Statistics

private struct TraversalStats {
    var count: Int = 0
    var excludedCount: Int = 0
    var excludedNonInteractable: Int = 0
    var excludedNoText: Int = 0
    var withTextCount: Int = 0
    var withoutTextCount: Int = 0
    var visibleElementsCount: Int = 0
    var roleCounts: [String: Int] = [:]
}

// MARK: - AXUIElement Hashable Conformance

extension AXUIElement: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        // Use the pointer value as the hash
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        hasher.combine(ptr)
    }
}

extension AXUIElement: @retroactive Equatable {
    public static func == (lhs: AXUIElement, rhs: AXUIElement) -> Bool {
        return CFEqual(lhs, rhs)
    }
}
