//
//  AgentQuestion.swift
//  Hivecrew
//
//  Models for agent-to-user questions during task execution
//

import Foundation

/// A text-based open-ended question from the agent
struct AgentTextQuestion: Identifiable, Codable, Sendable {
    let id: String
    let taskId: String
    let question: String
    let createdAt: Date
    var answer: String?
    
    init(
        id: String = UUID().uuidString,
        taskId: String,
        question: String,
        createdAt: Date = Date(),
        answer: String? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.question = question
        self.createdAt = createdAt
        self.answer = answer
    }
}

/// A multiple choice question from the agent
struct AgentMultipleChoiceQuestion: Identifiable, Codable, Sendable {
    let id: String
    let taskId: String
    let question: String
    let options: [String]
    let createdAt: Date
    var selectedIndex: Int?
    
    init(
        id: String = UUID().uuidString,
        taskId: String,
        question: String,
        options: [String],
        createdAt: Date = Date(),
        selectedIndex: Int? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.question = question
        self.options = options
        self.createdAt = createdAt
        self.selectedIndex = selectedIndex
    }
}

/// A request for user intervention (e.g., manual login, 2FA, CAPTCHA)
struct AgentInterventionRequest: Identifiable, Codable, Sendable {
    let id: String
    let taskId: String
    let message: String
    let service: String?
    let createdAt: Date
    var completed: Bool?
    
    init(
        id: String = UUID().uuidString,
        taskId: String,
        message: String,
        service: String? = nil,
        createdAt: Date = Date(),
        completed: Bool? = nil
    ) {
        self.id = id
        self.taskId = taskId
        self.message = message
        self.service = service
        self.createdAt = createdAt
        self.completed = completed
    }
}

/// Wrapper for any type of agent question or intervention request
enum AgentQuestion: Identifiable, Sendable, Equatable {
    
    case text(AgentTextQuestion)
    case multipleChoice(AgentMultipleChoiceQuestion)
    case intervention(AgentInterventionRequest)
    
    var id: String {
        switch self {
        case .text(let q): return q.id
        case .multipleChoice(let q): return q.id
        case .intervention(let r): return r.id
        }
    }
    
    var question: String {
        switch self {
        case .text(let q): return q.question
        case .multipleChoice(let q): return q.question
        case .intervention(let r): return r.message
        }
    }
    
    /// Returns true if this is an intervention request (not a question)
    var isIntervention: Bool {
        if case .intervention = self { return true }
        return false
    }
    
    static func == (lhs: AgentQuestion, rhs: AgentQuestion) -> Bool {
        return lhs.id == rhs.id
    }
    
}
