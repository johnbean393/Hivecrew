import TipKit
import Foundation

struct SkillsMentionTip: Tip {
    @Parameter static var hasSkillsAvailable: Bool = false
    var id: String { "skillsMention" }
    var title: Text { Text("Mention Skills with @") }
    var message: Text? { Text("Type @skill-name in your task to explicitly include a skill. Skills give agents specialized knowledge for specific tasks.") }
    var image: Image? { Image(systemName: "sparkles") }
    var rules: [Rule] {
        #Rule(Self.$hasSkillsAvailable) { $0 == true }
        #Rule(TipEvents.atMentionTyped) { $0.donations.count >= 2 }
    }
}

struct AutomaticSkillMatchingTip: Tip {
    var id: String { "automaticSkillMatching" }
    var title: Text { Text("Automatic Skill Matching") }
    var message: Text? { Text("Hivecrew can automatically match relevant skills to your tasks. Enable this in Settings → Tasks → Automatic Skill Matching.") }
    var image: Image? { Image(systemName: "wand.and.stars") }
    var rules: [Rule] { #Rule(TipEvents.skillsWindowOpened) { $0.donations.count >= 1 } }
}

struct ImportSkillsTip: Tip {
    var id: String { "importSkills" }
    var title: Text { Text("Import Skills from GitHub") }
    var message: Text? { Text("Click + to import skills from a GitHub URL or local directory. Skills enhance what agents can do without additional prompting.") }
    var image: Image? { Image(systemName: "arrow.down.circle") }
    var rules: [Rule] { #Rule(TipEvents.skillsWindowOpened) { $0.donations.count >= 1 } }
}

struct ExtractSkillTip: Tip {
    @Parameter static var hasCompletedSuccessfulTask: Bool = false
    var id: String { "extractSkill" }
    var title: Text { Text("Extract Skills from Tasks") }
    var message: Text? { Text("Successfully completed a task? Click \"Extract Skill\" to save it for reuse. The AI will capture the key instructions.") }
    var image: Image? { Image(systemName: "wand.and.stars") }
    var rules: [Rule] {
        #Rule(Self.$hasCompletedSuccessfulTask) { $0 == true }
        #Rule(TipEvents.sessionTraceViewed) { $0.donations.count >= 1 }
    }
}

struct ScheduleRecurringTip: Tip {
    var id: String { "scheduleRecurring" }
    var title: Text { Text("Schedule Recurring Tasks") }
    var message: Text? { Text("Automate workflows by scheduling tasks to run daily, weekly, or monthly. Click the + button to create a schedule.") }
    var image: Image? { Image(systemName: "calendar.badge.clock") }
    var rules: [Rule] { #Rule(TipEvents.scheduledTabViewed) { $0.donations.count >= 1 } }
}

struct ScheduleRunNowTip: Tip {
    @Parameter static var hasCreatedSchedule: Bool = false
    var id: String { "scheduleRunNow" }
    var title: Text { Text("Run Scheduled Tasks Immediately") }
    var message: Text? { Text("Right-click any scheduled task and select \"Run Now\" to trigger it immediately without waiting for the next scheduled time.") }
    var image: Image? { Image(systemName: "play.fill") }
    var rules: [Rule] {
        #Rule(Self.$hasCreatedSchedule) { $0 == true }
        #Rule(TipEvents.scheduleCreated) { $0.donations.count >= 1 }
    }
}

struct AgentQuestionsTip: Tip {
    var id: String { "agentQuestions" }
    var title: Text { Text("Answer Agent Questions") }
    var message: Text? { Text("Agents may ask questions when they need clarification. A dialog will appear—your response helps them proceed successfully.") }
    var image: Image? { Image(systemName: "questionmark.bubble") }
    var rules: [Rule] { #Rule(TipEvents.agentAskedQuestion) { $0.donations.count >= 1 } }
}

struct CredentialsTip: Tip {
    var id: String { "credentials" }
    var title: Text { Text("Store Credentials Securely") }
    var message: Text? { Text("Add login credentials here for agents to use. Credentials are stored in Keychain and never exposed to the AI—only secure tokens are used.") }
    var image: Image? { Image(systemName: "key.fill") }
    var rules: [Rule] { #Rule(TipEvents.credentialsSettingsOpened) { $0.donations.count >= 1 } }
}

struct APIIntegrationTip: Tip {
    var id: String { "apiIntegration" }
    var title: Text { Text("Automate with the API") }
    var message: Text? { Text("Enable the REST API to control Hivecrew programmatically. Use the Python SDK for workflow integration, or access the built-in Web UI.") }
    var image: Image? { Image(systemName: "network") }
    var rules: [Rule] { #Rule(TipEvents.apiSettingsOpened) { $0.donations.count >= 1 } }
}

struct WebUIRemoteAccessTip: Tip {
    var id: String { "webUIRemoteAccess" }
    var title: Text { Text("Control Hivecrew from Any Device") }
    var message: Text? { Text("Set up Remote Access to use the Web UI from your phone or any browser. Pair devices securely with a one-time code—no passwords needed.") }
    var image: Image? { Image(systemName: "antenna.radiowaves.left.and.right") }
    var rules: [Rule] {
        #Rule(TipEvents.taskCreated) { $0.donations.count >= 3 }
        #Rule(TipEvents.apiSettingsOpened) { $0.donations.count >= 1 }
    }
}

struct VideoExportTip: Tip {
    var id: String { "videoExport" }
    var title: Text { Text("Export Traces as Video") }
    var message: Text? { Text("Click the export button in a session trace to create a video recording—useful for documentation, debugging, or sharing.") }
    var image: Image? { Image(systemName: "film") }
    var rules: [Rule] { #Rule(TipEvents.sessionTraceViewed) { $0.donations.count >= 2 } }
}

struct DeliverablesMentionTip: Tip {
    @Parameter static var hasDeliverables: Bool = false
    var id: String { "deliverablesMention" }
    var title: Text { Text("Reference Previous Deliverables") }
    var message: Text? { Text("Type @ to see recent deliverables from completed tasks. Mention them to use output from one task as input to another.") }
    var image: Image? { Image(systemName: "doc.on.doc") }
    var rules: [Rule] {
        #Rule(Self.$hasDeliverables) { $0 == true }
        #Rule(TipEvents.atMentionTyped) { $0.donations.count >= 3 }
    }
}

struct DeveloperModeTip: Tip {
    var id: String { "developerMode" }
    var title: Text { Text("Developer Mode for Testing") }
    var message: Text? { Text("Enable Developer Mode to create persistent VMs that don't reset between tasks—useful for debugging workflows and testing changes.") }
    var image: Image? { Image(systemName: "hammer") }
    var rules: [Rule] { #Rule(TipEvents.developerSettingsOpened) { $0.donations.count >= 1 } }
}
