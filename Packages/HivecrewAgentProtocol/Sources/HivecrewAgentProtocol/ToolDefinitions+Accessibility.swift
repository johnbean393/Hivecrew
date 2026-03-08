//
//  ToolDefinitions+Accessibility.swift
//  HivecrewAgentProtocol
//

import Foundation

public struct TraverseAccessibilityTreeParams: Codable, Sendable {
    public let pid: Int32?
    public let onlyVisibleElements: Bool?

    public init(pid: Int32? = nil, onlyVisibleElements: Bool? = nil) {
        self.pid = pid
        self.onlyVisibleElements = onlyVisibleElements
    }
}

public struct AccessibilityElementData: Codable, Sendable, Hashable {
    public let role: String
    public let text: String?
    public let x: Double?
    public let y: Double?
    public let width: Double?
    public let height: Double?

    public init(role: String, text: String?, x: Double?, y: Double?, width: Double?, height: Double?) {
        self.role = role
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct AccessibilityTraversalStats: Codable, Sendable {
    public let count: Int
    public let excludedCount: Int
    public let excludedNonInteractable: Int
    public let excludedNoText: Int
    public let withTextCount: Int
    public let withoutTextCount: Int
    public let visibleElementsCount: Int
    public let roleCounts: [String: Int]

    public init(
        count: Int,
        excludedCount: Int,
        excludedNonInteractable: Int,
        excludedNoText: Int,
        withTextCount: Int,
        withoutTextCount: Int,
        visibleElementsCount: Int,
        roleCounts: [String: Int]
    ) {
        self.count = count
        self.excludedCount = excludedCount
        self.excludedNonInteractable = excludedNonInteractable
        self.excludedNoText = excludedNoText
        self.withTextCount = withTextCount
        self.withoutTextCount = withoutTextCount
        self.visibleElementsCount = visibleElementsCount
        self.roleCounts = roleCounts
    }
}

public struct AccessibilityTraversalResult: Codable, Sendable {
    public let appName: String
    public let elements: [AccessibilityElementData]
    public let stats: AccessibilityTraversalStats
    public let processingTimeSeconds: String

    public init(
        appName: String,
        elements: [AccessibilityElementData],
        stats: AccessibilityTraversalStats,
        processingTimeSeconds: String
    ) {
        self.appName = appName
        self.elements = elements
        self.stats = stats
        self.processingTimeSeconds = processingTimeSeconds
    }
}
