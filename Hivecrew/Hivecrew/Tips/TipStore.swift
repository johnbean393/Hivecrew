//
//  TipStore.swift
//  Hivecrew
//
//  Centralized tip state management
//

import Combine
import TipKit
import SwiftUI

/// Manages TipKit configuration and tip state updates
@MainActor
final class TipStore: ObservableObject {
    
    static let shared = TipStore()
    
    private init() {}
    
    // MARK: - Configuration
    
    /// Configure TipKit on app launch
    func configure() {
        do {
            try Tips.configure([
                // Display tips based on conditions, not frequency limiting
                .displayFrequency(.immediate),
                // Store tips data in the default location
                .datastoreLocation(.applicationDefault)
            ])
        } catch {
            print("TipKit configuration failed: \(error)")
        }
    }
    
    /// Reset all tips (useful for debugging)
    func resetAllTips() {
        do {
            try Tips.resetDatastore()
        } catch {
            print("Failed to reset tips: \(error)")
        }
    }
    
    // MARK: - Intro Tip State Updates
    
    /// Called when onboarding is completed
    func onboardingCompleted() {
        CreateFirstTaskTip.hasCompletedOnboarding = true
    }
    
    /// Called when the first task is created
    func firstTaskCreated() {
        WatchAgentsWorkTip.hasCreatedFirstTask = true
        AttachFilesTip.hasCreatedFirstTask = true
    }
    
    /// Updates the provider count for the configure providers tip
    func updateProviderCount(_ count: Int) {
        ConfigureProvidersTip.providerCount = count
    }
    
    // MARK: - Usage Tip State Updates
    
    /// Updates whether skills are available
    func updateSkillsAvailable(_ available: Bool) {
        SkillsMentionTip.hasSkillsAvailable = available
    }
    
    /// Called when a successful task completes
    func successfulTaskCompleted() {
        ExtractSkillTip.hasCompletedSuccessfulTask = true
    }
    
    /// Called when a schedule is created
    func scheduleCreated() {
        ScheduleRunNowTip.hasCreatedSchedule = true
    }
    
    /// Updates whether deliverables are available for mention
    func updateDeliverablesAvailable(_ available: Bool) {
        DeliverablesMentionTip.hasDeliverables = available
    }
    
    // MARK: - Event Donations
    
    /// Donate a task created event
    func donateTaskCreated() {
        Task {
            await TipEvents.taskCreated.donate()
        }
    }
    
    /// Donate a task completed event
    func donateTaskCompleted() {
        Task {
            await TipEvents.taskCompleted.donate()
        }
    }
    
    /// Donate a deliverable received event
    func donateDeliverableReceived() {
        Task {
            await TipEvents.deliverableReceived.donate()
        }
    }
    
    /// Donate a session trace viewed event
    func donateSessionTraceViewed() {
        Task {
            await TipEvents.sessionTraceViewed.donate()
        }
    }
    
    /// Donate an @ mention typed event
    func donateAtMentionTyped() {
        Task {
            await TipEvents.atMentionTyped.donate()
        }
    }
    
    /// Donate a file attached event
    func donateFileAttached() {
        Task {
            await TipEvents.fileAttached.donate()
        }
    }
    
    /// Donate a schedule created event
    func donateScheduleCreated() {
        Task {
            await TipEvents.scheduleCreated.donate()
        }
    }
    
    /// Donate a scheduled tab viewed event
    func donateScheduledTabViewed() {
        Task {
            await TipEvents.scheduledTabViewed.donate()
        }
    }
    
    /// Donate a skills window opened event
    func donateSkillsWindowOpened() {
        Task {
            await TipEvents.skillsWindowOpened.donate()
        }
    }
    
    /// Donate a skill imported event
    func donateSkillImported() {
        Task {
            await TipEvents.skillImported.donate()
        }
    }
    
    /// Donate an environment viewed event
    func donateEnvironmentViewed() {
        Task {
            await TipEvents.environmentViewed.donate()
        }
    }
    
    /// Donate an agent asked question event
    func donateAgentAskedQuestion() {
        Task {
            await TipEvents.agentAskedQuestion.donate()
        }
    }
    
    /// Donate a credentials settings opened event
    func donateCredentialsSettingsOpened() {
        Task {
            await TipEvents.credentialsSettingsOpened.donate()
        }
    }
    
    /// Donate an API settings opened event
    func donateAPISettingsOpened() {
        Task {
            await TipEvents.apiSettingsOpened.donate()
        }
    }
    
    /// Donate a developer settings opened event
    func donateDeveloperSettingsOpened() {
        Task {
            await TipEvents.developerSettingsOpened.donate()
        }
    }
}
