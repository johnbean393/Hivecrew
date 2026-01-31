//
//  PlanTodoItem.swift
//  Hivecrew
//
//  Models for tracking execution plan progress
//

import Foundation

/// A single todo item from the execution plan
struct PlanTodoItem: Codable, Identifiable, Sendable {
    /// Unique identifier for this item
    let id: String
    
    /// The todo item content/description
    var content: String
    
    /// Whether this item has been completed
    var isCompleted: Bool
    
    /// When this item was completed (nil if not completed)
    var completedAt: Date?
    
    /// Whether this item was skipped during execution
    var wasSkipped: Bool
    
    /// Reason for deviation if the agent deviated from this step
    var deviationReason: String?
    
    /// Whether this item was added during execution (not in original plan)
    var addedDuringExecution: Bool
    
    init(
        id: String = UUID().uuidString,
        content: String,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        wasSkipped: Bool = false,
        deviationReason: String? = nil,
        addedDuringExecution: Bool = false
    ) {
        self.id = id
        self.content = content
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.wasSkipped = wasSkipped
        self.deviationReason = deviationReason
        self.addedDuringExecution = addedDuringExecution
    }
}

/// State of the execution plan during/after agent execution
struct PlanState: Codable, Sendable {
    /// All todo items from the plan
    var items: [PlanTodoItem]
    
    /// Deviations from the plan that occurred during execution
    var deviations: [PlanDeviation]
    
    /// Calculated completion percentage (0.0 to 1.0)
    var completionPercentage: Double {
        guard !items.isEmpty else { return 0.0 }
        let completedCount = items.filter { $0.isCompleted }.count
        return Double(completedCount) / Double(items.count)
    }
    
    /// Number of completed items
    var completedCount: Int {
        items.filter { $0.isCompleted }.count
    }
    
    /// Number of skipped items
    var skippedCount: Int {
        items.filter { $0.wasSkipped }.count
    }
    
    /// Number of items added during execution
    var addedCount: Int {
        items.filter { $0.addedDuringExecution }.count
    }
    
    /// Number of original plan items (not added during execution)
    var originalItemCount: Int {
        items.filter { !$0.addedDuringExecution }.count
    }
    
    init(items: [PlanTodoItem] = [], deviations: [PlanDeviation] = []) {
        self.items = items
        self.deviations = deviations
    }
    
    /// Mark an item as completed by its ID
    mutating func completeItem(id: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isCompleted = true
            items[index].completedAt = Date()
        }
    }
    
    /// Mark an item as skipped with optional reason
    mutating func skipItem(id: String, reason: String? = nil) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].wasSkipped = true
            items[index].deviationReason = reason
        }
    }
    
    /// Add a new item during execution
    mutating func addItem(content: String) -> PlanTodoItem {
        let item = PlanTodoItem(
            content: content,
            addedDuringExecution: true
        )
        items.append(item)
        return item
    }
    
    /// Record a deviation from the plan
    mutating func recordDeviation(description: String, reasoning: String) {
        let deviation = PlanDeviation(
            description: description,
            reasoning: reasoning
        )
        deviations.append(deviation)
    }
}

/// A deviation from the execution plan
struct PlanDeviation: Codable, Identifiable, Sendable {
    /// Unique identifier for this deviation
    let id: String
    
    /// When the deviation occurred
    let timestamp: Date
    
    /// Description of what deviated from the plan
    let description: String
    
    /// Agent's reasoning for the deviation
    let reasoning: String
    
    init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        description: String,
        reasoning: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.description = description
        self.reasoning = reasoning
    }
}
