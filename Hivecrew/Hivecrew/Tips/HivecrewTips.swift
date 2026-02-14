//
//  HivecrewTips.swift
//  Hivecrew
//
//  TipKit tip definitions for onboarding and feature discovery
//

import TipKit
import Foundation

// MARK: - Intro Tips

/// These tips show in sequence after the user completes onboarding.
/// They introduce the core concepts of the app.

/// Tip 1: Create your first task
struct CreateFirstTaskTip: Tip {
    
    @Parameter
    static var hasCompletedOnboarding: Bool = false
    
    var id: String { "createFirstTask" }
    
    var title: Text {
        Text("Create Your First Task")
    }
    
    var message: Text? {
        Text("Type a task description in plain language, then press Return to dispatch an agent. Agents work autonomously in isolated VMs.")
    }
    
    var image: Image? {
        Image(systemName: "plus.circle")
    }
    
    var rules: [Rule] {
        #Rule(Self.$hasCompletedOnboarding) { $0 == true }
    }
}

/// Tip 2: Watch agents work
struct WatchAgentsWorkTip: Tip {
    
    @Parameter
    static var hasCreatedFirstTask: Bool = false
    
    var id: String { "watchAgentsWork" }
    
    var title: Text {
        Text("Watch Agents Work")
    }
    
    var message: Text? {
        Text("Switch to the Environments tab to watch agents in real-time. You'll see live screenshots and an activity stream as they work.")
    }
    
    var image: Image? {
        Image(systemName: "desktopcomputer")
    }
    
    var rules: [Rule] {
        #Rule(Self.$hasCreatedFirstTask) { $0 == true }
        #Rule(TipEvents.taskCreated) { $0.donations.count >= 1 }
    }
}

/// Tip 3: Review completed tasks
struct ReviewCompletedTasksTip: Tip {
    
    var id: String { "reviewCompletedTasks" }
    
    var title: Text {
        Text("Review Completed Tasks")
    }
    
    var message: Text? {
        Text("Click any completed task to view its session trace—a step-by-step log with synchronized screenshots.")
    }
    
    var image: Image? {
        Image(systemName: "doc.text.magnifyingglass")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.taskCompleted) { $0.donations.count >= 1 }
    }
}

/// Tip 4: Attach files to tasks
struct AttachFilesTip: Tip {
    
    @Parameter
    static var hasCreatedFirstTask: Bool = false
    
    var id: String { "attachFiles" }
    
    var title: Text {
        Text("Attach Files to Tasks")
    }
    
    var message: Text? {
        Text("Drag files onto the prompt bar, click the paperclip button, or type @ to attach files your agent can access.")
    }
    
    var image: Image? {
        Image(systemName: "paperclip")
    }
    
    var rules: [Rule] {
        #Rule(Self.$hasCreatedFirstTask) { $0 == true }
        #Rule(TipEvents.taskCreated) { $0.donations.count >= 2 }
    }
}

/// Tip: Attach from suggested ghost chips
struct GhostContextAttachmentsTip: Tip {
    var id: String { "ghostContextAttachments" }

    var title: Text {
        Text("Use Suggested Context")
    }

    var message: Text? {
        Text("Faded chips are suggested context. Click one to promote it into a real attachment before sending.")
    }

    var image: Image? {
        Image(systemName: "plus.circle.dashed")
    }

    var rules: [Rule] {
        #Rule(TipEvents.ghostContextSuggestionsShown) { $0.donations.count >= 1 }
    }
}

/// Tip 5: Configure LLM providers
struct ConfigureProvidersTip: Tip {
    
    @Parameter
    static var providerCount: Int = 0
    
    var id: String { "configureProviders" }
    
    var title: Text {
        Text("Configure LLM Providers")
    }
    
    var message: Text? {
        Text("Set up multiple AI providers in Settings → Providers. You can choose which provider and model to use for each task.")
    }
    
    var image: Image? {
        Image(systemName: "brain.head.profile")
    }
    
    var rules: [Rule] {
        // Show when user has only 1 provider configured
        #Rule(Self.$providerCount) { $0 == 1 }
    }
}

/// Tip 6: Run multiple copies
struct BatchExecutionTip: Tip {
    
    var id: String { "batchExecution" }
    
    var title: Text {
        Text("Run Multiple Copies")
    }
    
    var message: Text? {
        Text("Click the copy count button (1x) to run 2, 4, or 8 parallel agents on the same task—useful for testing or processing multiple inputs.")
    }
    
    var image: Image? {
        Image(systemName: "square.stack.3d.up")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.taskCreated) { $0.donations.count >= 3 }
    }
}

/// Tip: Plan mode for complex tasks
struct PlanModeTip: Tip {
    
    var id: String { "planMode" }
    
    var title: Text {
        Text("Plan Before Executing")
    }
    
    var message: Text? {
        Text("Switch to Plan mode for complex tasks. The agent will create a step-by-step plan you can review and approve before execution begins.")
    }
    
    var image: Image? {
        Image(systemName: "list.bullet.clipboard")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.taskCreated) { $0.donations.count >= 4 }
    }
}

/// Tip 7: Output directory
struct OutputDirectoryTip: Tip {
    
    var id: String { "outputDirectory" }
    
    var title: Text {
        Text("Collect Deliverables")
    }
    
    var message: Text? {
        Text("Files agents save to ~/Desktop/outbox/ are automatically delivered to your output directory when the task completes.")
    }
    
    var image: Image? {
        Image(systemName: "folder")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.taskCompleted) { $0.donations.count >= 1 }
    }
}

/// Tip: Show deliverables from completed tasks
struct ShowDeliverableTip: Tip {
    
    var id: String { "showDeliverable" }
    
    var title: Text {
        Text("View Your Deliverables")
    }
    
    var message: Text? {
        Text("Your agent produced files! Click the folder icon to open them in Finder.")
    }
    
    var image: Image? {
        Image(systemName: "folder.fill")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.deliverableReceived) { $0.donations.count >= 1 }
    }
}

/// Tip 8: Take control anytime
struct TakeControlTip: Tip {
    
    var id: String { "takeControl" }
    
    var title: Text {
        Text("Take Control Anytime")
    }
    
    var message: Text? {
        Text("You can pause an agent, use your mouse and keyboard directly in the VM, then resume—or cancel any task at any time.")
    }
    
    var image: Image? {
        Image(systemName: "hand.raised")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.environmentViewed) { $0.donations.count >= 1 }
    }
}

// MARK: - Usage Tips

/// These tips appear contextually as users explore features.

/// Tip 9: Mention skills with @
struct SkillsMentionTip: Tip {
    
    @Parameter
    static var hasSkillsAvailable: Bool = false
    
    var id: String { "skillsMention" }
    
    var title: Text {
        Text("Mention Skills with @")
    }
    
    var message: Text? {
        Text("Type @skill-name in your task to explicitly include a skill. Skills give agents specialized knowledge for specific tasks.")
    }
    
    var image: Image? {
        Image(systemName: "sparkles")
    }
    
    var rules: [Rule] {
        #Rule(Self.$hasSkillsAvailable) { $0 == true }
        #Rule(TipEvents.atMentionTyped) { $0.donations.count >= 2 }
    }
}

/// Tip 10: Automatic skill matching
struct AutomaticSkillMatchingTip: Tip {
    
    var id: String { "automaticSkillMatching" }
    
    var title: Text {
        Text("Automatic Skill Matching")
    }
    
    var message: Text? {
        Text("Hivecrew can automatically match relevant skills to your tasks. Enable this in Settings → Tasks → Automatic Skill Matching.")
    }
    
    var image: Image? {
        Image(systemName: "wand.and.stars")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.skillsWindowOpened) { $0.donations.count >= 1 }
    }
}

/// Tip 11: Import skills from GitHub
struct ImportSkillsTip: Tip {
    
    var id: String { "importSkills" }
    
    var title: Text {
        Text("Import Skills from GitHub")
    }
    
    var message: Text? {
        Text("Click + to import skills from a GitHub URL or local directory. Skills enhance what agents can do without additional prompting.")
    }
    
    var image: Image? {
        Image(systemName: "arrow.down.circle")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.skillsWindowOpened) { $0.donations.count >= 1 }
    }
}

/// Tip 12: Extract skills from tasks
struct ExtractSkillTip: Tip {
    
    @Parameter
    static var hasCompletedSuccessfulTask: Bool = false
    
    var id: String { "extractSkill" }
    
    var title: Text {
        Text("Extract Skills from Tasks")
    }
    
    var message: Text? {
        Text("Successfully completed a task? Click \"Extract Skill\" to save it for reuse. The AI will capture the key instructions.")
    }
    
    var image: Image? {
        Image(systemName: "wand.and.stars")
    }
    
    var rules: [Rule] {
        #Rule(Self.$hasCompletedSuccessfulTask) { $0 == true }
        #Rule(TipEvents.sessionTraceViewed) { $0.donations.count >= 1 }
    }
}

/// Tip 13: Schedule recurring tasks
struct ScheduleRecurringTip: Tip {
    
    var id: String { "scheduleRecurring" }
    
    var title: Text {
        Text("Schedule Recurring Tasks")
    }
    
    var message: Text? {
        Text("Automate workflows by scheduling tasks to run daily, weekly, or monthly. Click the + button to create a schedule.")
    }
    
    var image: Image? {
        Image(systemName: "calendar.badge.clock")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.scheduledTabViewed) { $0.donations.count >= 1 }
    }
}

/// Tip 14: Run scheduled tasks now
struct ScheduleRunNowTip: Tip {
    
    @Parameter
    static var hasCreatedSchedule: Bool = false
    
    var id: String { "scheduleRunNow" }
    
    var title: Text {
        Text("Run Scheduled Tasks Immediately")
    }
    
    var message: Text? {
        Text("Right-click any scheduled task and select \"Run Now\" to trigger it immediately without waiting for the next scheduled time.")
    }
    
    var image: Image? {
        Image(systemName: "play.fill")
    }
    
    var rules: [Rule] {
        #Rule(Self.$hasCreatedSchedule) { $0 == true }
        #Rule(TipEvents.scheduleCreated) { $0.donations.count >= 1 }
    }
}

/// Tip 15: Answer agent questions
struct AgentQuestionsTip: Tip {
    
    var id: String { "agentQuestions" }
    
    var title: Text {
        Text("Answer Agent Questions")
    }
    
    var message: Text? {
        Text("Agents may ask questions when they need clarification. A dialog will appear—your response helps them proceed successfully.")
    }
    
    var image: Image? {
        Image(systemName: "questionmark.bubble")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.agentAskedQuestion) { $0.donations.count >= 1 }
    }
}

/// Tip 16: Store credentials securely
struct CredentialsTip: Tip {
    
    var id: String { "credentials" }
    
    var title: Text {
        Text("Store Credentials Securely")
    }
    
    var message: Text? {
        Text("Add login credentials here for agents to use. Credentials are stored in Keychain and never exposed to the AI—only secure tokens are used.")
    }
    
    var image: Image? {
        Image(systemName: "key.fill")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.credentialsSettingsOpened) { $0.donations.count >= 1 }
    }
}

/// Tip 17: API integration
struct APIIntegrationTip: Tip {
    
    var id: String { "apiIntegration" }
    
    var title: Text {
        Text("Automate with the API")
    }
    
    var message: Text? {
        Text("Enable the REST API to control Hivecrew programmatically. Use the Python SDK for workflow integration, or access the built-in Web UI.")
    }
    
    var image: Image? {
        Image(systemName: "network")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.apiSettingsOpened) { $0.donations.count >= 1 }
    }
}

/// Tip 18: Web UI & Remote Access
struct WebUIRemoteAccessTip: Tip {
    
    var id: String { "webUIRemoteAccess" }
    
    var title: Text {
        Text("Control Hivecrew from Any Device")
    }
    
    var message: Text? {
        Text("Set up Remote Access to use the Web UI from your phone or any browser. Pair devices securely with a one-time code—no passwords needed.")
    }
    
    var image: Image? {
        Image(systemName: "antenna.radiowaves.left.and.right")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.taskCreated) { $0.donations.count >= 3 }
        #Rule(TipEvents.apiSettingsOpened) { $0.donations.count >= 1 }
    }
}

/// Tip 20: Export traces as video
struct VideoExportTip: Tip {
    
    var id: String { "videoExport" }
    
    var title: Text {
        Text("Export Traces as Video")
    }
    
    var message: Text? {
        Text("Click the export button in a session trace to create a video recording—useful for documentation, debugging, or sharing.")
    }
    
    var image: Image? {
        Image(systemName: "film")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.sessionTraceViewed) { $0.donations.count >= 2 }
    }
}

/// Tip 21: Reference previous deliverables
struct DeliverablesMentionTip: Tip {
    
    @Parameter
    static var hasDeliverables: Bool = false
    
    var id: String { "deliverablesMention" }
    
    var title: Text {
        Text("Reference Previous Deliverables")
    }
    
    var message: Text? {
        Text("Type @ to see recent deliverables from completed tasks. Mention them to use output from one task as input to another.")
    }
    
    var image: Image? {
        Image(systemName: "doc.on.doc")
    }
    
    var rules: [Rule] {
        #Rule(Self.$hasDeliverables) { $0 == true }
        #Rule(TipEvents.atMentionTyped) { $0.donations.count >= 3 }
    }
}

/// Tip 22: Developer mode
struct DeveloperModeTip: Tip {
    
    var id: String { "developerMode" }
    
    var title: Text {
        Text("Developer Mode for Testing")
    }
    
    var message: Text? {
        Text("Enable Developer Mode to create persistent VMs that don't reset between tasks—useful for debugging workflows and testing changes.")
    }
    
    var image: Image? {
        Image(systemName: "hammer")
    }
    
    var rules: [Rule] {
        #Rule(TipEvents.developerSettingsOpened) { $0.donations.count >= 1 }
    }
}
