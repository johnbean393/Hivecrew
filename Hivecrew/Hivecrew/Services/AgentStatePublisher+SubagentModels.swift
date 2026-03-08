import Foundation

enum SubagentStatus: String, Sendable {
    case running
    case completed
    case failed
    case cancelled
}

enum SubagentProgressLineType: String, Sendable {
    case info
    case toolCall
    case toolResult
    case llmResponse
    case error
}

struct SubagentProgressLine: Identifiable, Sendable, Equatable {
    let id: String
    let timestamp: Date
    let type: SubagentProgressLineType
    let summary: String
    let details: String?

    init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        type: SubagentProgressLineType,
        summary: String,
        details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.summary = summary
        self.details = details
    }
}

struct SubagentBoxState: Identifiable, Sendable, Equatable {
    let id: String
    let goal: String
    let purpose: String?
    let domain: String
    var status: SubagentStatus
    var currentAction: String
    var lines: [SubagentProgressLine]
}
