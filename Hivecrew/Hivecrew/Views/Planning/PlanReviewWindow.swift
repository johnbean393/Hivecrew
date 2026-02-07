//
//  PlanReviewWindow.swift
//  Hivecrew
//
//  Split-pane window for reviewing and editing execution plans
//

import SwiftUI
import SwiftData
import MarkdownView

/// Wrapper view that handles the optional PlanningStatePublisher
struct PlanReviewWindow: View {
    let task: TaskRecord
    @ObservedObject var taskService: TaskService
    
    var body: some View {
        // Get the publisher if it exists
        let publisher = taskService.activePlanningPublishers[task.id]
        
        // Show streaming content only if actively generating
        if let publisher = publisher, publisher.isGenerating {
            // Use the streaming version when planning is active
            PlanReviewStreamingContent(
                task: task,
                taskService: taskService,
                planningPublisher: publisher
            )
        } else {
            // Use the static version when no active planning session or generation complete
            PlanReviewStaticContent(
                task: task,
                taskService: taskService
            )
        }
    }
}

// MARK: - Streaming Content (during plan generation)

/// Plan review content that observes the streaming publisher
struct PlanReviewStreamingContent: View {
    let task: TaskRecord
    @ObservedObject var taskService: TaskService
    @ObservedObject var planningPublisher: PlanningStatePublisher
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var viewMode: PlanViewMode = .checklist
    @State private var isReasoningExpanded: Bool = true
    
    enum PlanViewMode: String, CaseIterable {
        case raw = "Raw"
        case checklist = "Checklist"
        
        var localizedName: String {
            switch self {
            case .raw: return String(localized: "Raw")
            case .checklist: return String(localized: "Checklist")
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Execution Plan")
                        .font(.headline)
                    Text(task.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                if planningPublisher.isGenerating {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        
                        Text(planningPublisher.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            
            Divider()
            
            // Main content
            HSplitView {
                // Left panel - Context
                leftPanel
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 400)
                
                // Right panel - Streaming plan
                streamingRightPanel
                    .frame(minWidth: 400)
            }
            
            Divider()
            
            // Footer
            HStack {
                Button("Cancel Task") {
                    Task {
                        await taskService.cancelPlanning(for: task)
                        dismiss()
                    }
                }
                .foregroundStyle(.red)
                
                Spacer()
                
                Button {
                    // Dismiss immediately, then start execution in background
                    dismiss()
                    Task {
                        await taskService.executePlan(for: task)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                        Text("Execute Plan")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(planningPublisher.isGenerating || planningPublisher.streamingPlanText.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 1040, minHeight: 750)
    }
    
    private var leftPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Task description
                GroupBox("Task Description") {
                    Text(task.taskDescription)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // Attached files
                if !task.attachedFilePaths.isEmpty {
                    GroupBox("Attached Files") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(task.attachedFilePaths, id: \.self) { path in
                                HStack(spacing: 4) {
                                    Image(systemName: "doc")
                                        .foregroundStyle(.secondary)
                                    Text(URL(fileURLWithPath: path).lastPathComponent)
                                        .font(.caption)
                                        .lineLimit(1)
                                    
                                    // Show if read by planning agent
                                    if planningPublisher.readFiles.contains(URL(fileURLWithPath: path).lastPathComponent) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.caption2)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                
                // Selected skills
                if !planningPublisher.selectedSkills.isEmpty {
                    GroupBox("Selected Skills") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(planningPublisher.selectedSkills, id: \.self) { name in
                                HStack(spacing: 4) {
                                    Image(systemName: "wand.and.stars")
                                        .foregroundStyle(.purple)
                                    Text(name)
                                        .font(.caption)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                
                // Provider/Model info
                GroupBox("Configuration") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Model:")
                                .foregroundStyle(.secondary)
                            Text(task.modelId)
                        }
                        .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var streamingRightPanel: some View {
        VStack(spacing: 0) {
            // Header with status
            HStack {
                Text("Plan")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                // Show streaming indicator when content is coming in
                if !planningPublisher.streamingPlanText.isEmpty && planningPublisher.isGenerating {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("Streaming...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            // Streaming plan content
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Show reasoning/thinking if available (collapsible when plan starts)
                        if !planningPublisher.streamingReasoningText.isEmpty {
                            DisclosureGroup(isExpanded: $isReasoningExpanded) {
                                Text(planningPublisher.streamingReasoningText)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "brain")
                                        .foregroundStyle(.purple)
                                    Text("Thinking")
                                        .font(.caption.bold())
                                        .foregroundStyle(.purple)
                                }
                            }
                            .padding(10)
                            .background(Color.purple.opacity(0.1))
                            .cornerRadius(8)
                        }
                        
                        // Show plan content or waiting message
                        if planningPublisher.streamingPlanText.isEmpty {
                            if planningPublisher.streamingReasoningText.isEmpty {
                                VStack(spacing: 8) {
                                    Text(planningPublisher.statusMessage)
                                        .foregroundStyle(.secondary)
                                        .italic()
                                }
                            }
                        } else {
                            // Use MarkdownView for better rendering of streaming content
                            MarkdownView(planningPublisher.streamingPlanText)
                                .textSelection(.enabled)
                        }
                        
                        // Scroll anchor
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .onChange(of: planningPublisher.streamingPlanText) { _, _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: planningPublisher.streamingReasoningText) { _, _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Static Content (after plan generation)

/// Plan review content for completed plans (editable)
struct PlanReviewStaticContent: View {
    let task: TaskRecord
    @ObservedObject var taskService: TaskService
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var editedPlan: String = ""
    @State private var viewMode: PlanViewMode = .preview
    @State private var revisionText: String = ""
    @State private var isRevising: Bool = false
    
    enum PlanViewMode: String, CaseIterable {
        case preview = "Preview"
        case edit = "Edit"
        case checklist = "Tasks"
        
        var localizedName: String {
            switch self {
            case .preview: return String(localized: "Preview")
            case .edit: return String(localized: "Edit")
            case .checklist: return String(localized: "Tasks")
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Execution Plan")
                        .font(.headline)
                    Text(task.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
            }
            .padding()
            
            Divider()
            
            // Main content
            HSplitView {
                // Left panel - Context
                leftPanel
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 400)
                
                // Right panel - Plan editor
                rightPanel
                    .frame(minWidth: 400)
            }
            
            Divider()
            
            // Footer
            footerView
        }
        .frame(minWidth: 1040, minHeight: 750)
        .onAppear {
            editedPlan = task.planMarkdown ?? ""
        }
    }
    
    private var leftPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Task description
                GroupBox("Task Description") {
                    Text(task.taskDescription)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // Attached files
                if !task.attachedFilePaths.isEmpty {
                    GroupBox("Attached Files") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(task.attachedFilePaths, id: \.self) { path in
                                HStack(spacing: 4) {
                                    Image(systemName: "doc")
                                        .foregroundStyle(.secondary)
                                    Text(URL(fileURLWithPath: path).lastPathComponent)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                
                // Selected skills
                if let skillNames = task.planSelectedSkillNames, !skillNames.isEmpty {
                    GroupBox("Selected Skills") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(skillNames, id: \.self) { name in
                                HStack(spacing: 4) {
                                    Image(systemName: "wand.and.stars")
                                        .foregroundStyle(.purple)
                                    Text(name)
                                        .font(.caption)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                
                // Provider/Model info
                GroupBox("Configuration") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Model:")
                                .foregroundStyle(.secondary)
                            Text(task.modelId)
                        }
                        .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var rightPanel: some View {
        VStack(spacing: 0) {
            // View mode picker
            HStack {
                Picker("View", selection: $viewMode) {
                    ForEach(PlanViewMode.allCases, id: \.self) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                
                Spacer()
                
                // Todo count and mermaid indicator
                HStack(spacing: 8) {
                    if PlanParser.containsMermaid(in: editedPlan) {
                        Label("Diagram", systemImage: "flowchart")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    
                    let counts = PlanParser.countItems(in: editedPlan)
                    Text("\(counts.completed)/\(counts.total) tasks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            // Plan content (disabled during revision)
            Group {
                switch viewMode {
                case .preview:
                    ScrollView {
                        RichPlanView(markdown: editedPlan)
                            .padding()
                    }
                    .opacity(isRevising ? 0.6 : 1.0)
                    
                case .edit:
                    TextEditor(text: $editedPlan)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .disabled(isRevising)
                        .opacity(isRevising ? 0.6 : 1.0)
                    
                case .checklist:
                    ScrollView {
                        PlanChecklistView(
                            planMarkdown: $editedPlan,
                            isDisabled: isRevising
                        )
                        .padding()
                    }
                    .opacity(isRevising ? 0.6 : 1.0)
                }
            }
            
            Divider()
            
            // Revision chat
            HStack(spacing: 8) {
                TextField("Ask for revisions...", text: $revisionText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isRevising)
                
                Button {
                    Task { await requestRevision() }
                } label: {
                    if isRevising {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                }
                .buttonStyle(.plain)
                .disabled(revisionText.isEmpty || isRevising)
            }
            .padding()
        }
    }
    
    private var footerView: some View {
        HStack {
            Button("Cancel Task") {
                Task {
                    await taskService.cancelPlanning(for: task)
                    dismiss()
                }
            }
            .foregroundStyle(.red)
            
            Spacer()
            
            Button {
                // Save any edits
                task.planMarkdown = editedPlan
                try? taskService.modelContext?.save()
                
                // Dismiss immediately, then start execution in background
                dismiss()
                Task {
                    await taskService.executePlan(for: task)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                    Text("Execute Plan")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(editedPlan.isEmpty)
        }
        .padding()
    }
    
    private func requestRevision() async {
        guard !revisionText.isEmpty else { return }
        
        isRevising = true
        defer { isRevising = false }
        
        do {
            let llmClient = try await taskService.createLLMClient(
                providerId: task.providerId,
                modelId: task.modelId
            )
            
            let planningAgent = PlanningAgent(llmClient: llmClient)
            let revisedPlan = try await planningAgent.revisePlan(
                currentPlan: editedPlan,
                revisionRequest: revisionText
            )
            
            editedPlan = revisedPlan
            task.planMarkdown = revisedPlan
            try? taskService.modelContext?.save()
            
            revisionText = ""
        } catch {
            print("Revision failed: \(error)")
        }
    }
}

// MARK: - Plan Checklist View

/// Interactive checklist view of plan items
struct PlanChecklistView: View {
    @Binding var planMarkdown: String
    var isDisabled: Bool = false
    
    private var items: [PlanTodoItem] {
        PlanParser.parseTodos(from: planMarkdown)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                        .foregroundStyle(item.isCompleted ? .green : .secondary)
                        .onTapGesture {
                            if !isDisabled {
                                toggleItem(item)
                            }
                        }
                    
                    Text(item.content)
                        .strikethrough(item.isCompleted)
                        .foregroundStyle(item.isCompleted ? .secondary : .primary)
                }
            }
            
            if items.isEmpty {
                Text("No todo items in plan")
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func toggleItem(_ item: PlanTodoItem) {
        let (newMarkdown, _) = PlanParser.toggleItem(in: planMarkdown, withContent: item.content)
        planMarkdown = newMarkdown
    }
}

#Preview {
    PlanReviewWindow(
        task: TaskRecord(
            title: "Create a presentation",
            taskDescription: "Create a PowerPoint presentation about AI trends",
            status: .planReview,
            providerId: "openai",
            modelId: "gpt-4",
            planFirstEnabled: true,
            planMarkdown: """
            # AI Trends Presentation
            
            Create a comprehensive 10-slide presentation covering the latest developments in artificial intelligence, with a focus on practical applications and industry impact.
            
            ```mermaid
            flowchart LR
                Research[Research Phase] --> Outline[Create Outline]
                Outline --> Content[Write Content]
                Content --> Design[Add Visuals]
                Design --> Review[Review & Polish]
                Review --> Export[Export PDF]
            ```
            
            ## Research Phase
            
            Start by gathering information from reliable sources about current AI trends and breakthroughs.
            
            - Search for recent developments in LLMs, computer vision, and robotics
            - Review industry reports from major research labs
            - Identify 3-5 key trends to highlight
            
            ## Content Creation
            
            Create the presentation slides in LibreOffice Impress with consistent styling.
            
            - Slide 1: Title and introduction
            - Slides 2-8: One trend per slide with examples
            - Slide 9: Industry impact summary
            - Slide 10: Conclusion and future outlook
            
            ## Tasks
            
            - [ ] Search for recent AI trends and breakthroughs
            - [ ] Read the attached research paper
            - [ ] Create outline for 10-slide presentation
            - [x] Design title slide
            - [ ] Add content to each slide
            - [ ] Add charts and visuals
            - [ ] Review and polish
            - [ ] Export to ~/Desktop/outbox/presentation.pdf
            """
        ),
        taskService: TaskService()
    )
}
