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

/// Tip: Explain ChatGPT OAuth subscription requirements during onboarding.
struct ChatGPTSignInSubscriptionTip: Tip {

    var id: String { "chatGPTSignInSubscription" }

    var title: Text {
        Text("Sign in with ChatGPT")
    }

    var message: Text? {
        Text("This only works with a ChatGPT Plus or Pro subscription. Free and Go plans are not supported.")
    }

    var image: Image? {
        Image("OpenAILogo")
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
