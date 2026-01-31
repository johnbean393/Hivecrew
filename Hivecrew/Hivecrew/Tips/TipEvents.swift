//
//  TipEvents.swift
//  Hivecrew
//
//  Events for tracking user actions to trigger contextual tips
//

import TipKit

/// Central event tracking for TipKit tips
/// Use these events to track user actions and trigger contextual tips
enum TipEvents {
    
    // MARK: - Task Events
    
    /// Fired when a task is created
    static let taskCreated = Tips.Event(id: "taskCreated")
    
    /// Fired when a task completes (success or failure)
    static let taskCompleted = Tips.Event(id: "taskCompleted")
    
    /// Fired when a task completes with deliverables
    static let deliverableReceived = Tips.Event(id: "deliverableReceived")
    
    /// Fired when user views a session trace
    static let sessionTraceViewed = Tips.Event(id: "sessionTraceViewed")
    
    // MARK: - Prompt Bar Events
    
    /// Fired when user types @ in the prompt bar
    static let atMentionTyped = Tips.Event(id: "atMentionTyped")
    
    /// Fired when user attaches a file
    static let fileAttached = Tips.Event(id: "fileAttached")
    
    // MARK: - Schedule Events
    
    /// Fired when a schedule is created
    static let scheduleCreated = Tips.Event(id: "scheduleCreated")
    
    /// Fired when user views the Scheduled tab
    static let scheduledTabViewed = Tips.Event(id: "scheduledTabViewed")
    
    // MARK: - Skills Events
    
    /// Fired when user opens the Skills window
    static let skillsWindowOpened = Tips.Event(id: "skillsWindowOpened")
    
    /// Fired when user imports a skill
    static let skillImported = Tips.Event(id: "skillImported")
    
    // MARK: - Environment Events
    
    /// Fired when user views the Environments tab with a running task
    static let environmentViewed = Tips.Event(id: "environmentViewed")
    
    /// Fired when an agent asks a question
    static let agentAskedQuestion = Tips.Event(id: "agentAskedQuestion")
    
    // MARK: - Settings Events
    
    /// Fired when user opens Credentials settings
    static let credentialsSettingsOpened = Tips.Event(id: "credentialsSettingsOpened")
    
    /// Fired when user opens API settings
    static let apiSettingsOpened = Tips.Event(id: "apiSettingsOpened")
    
    /// Fired when user opens Developer settings
    static let developerSettingsOpened = Tips.Event(id: "developerSettingsOpened")
}
