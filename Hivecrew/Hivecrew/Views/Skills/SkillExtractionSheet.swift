//
//  SkillExtractionSheet.swift
//  Hivecrew
//
//  Sheet for extracting a skill from a completed task
//

import SwiftUI
import HivecrewShared
import HivecrewLLM

/// Sheet for extracting a skill from a completed task
struct SkillExtractionSheet: View {
    let task: TaskRecord
    let taskService: TaskService
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var extractionState: ExtractionState = .idle
    @State private var extractedData: ExtractedSkillData?
    @State private var editedName: String = ""
    @State private var editedDescription: String = ""
    @State private var error: String?
    
    enum ExtractionState {
        case idle
        case extracting
        case previewing
        case saving
        case saved
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            Divider()
            
            // Content
            content
            
            Divider()
            
            // Footer
            footer
        }
        .frame(width: 600, height: 500)
        .onAppear {
            startExtraction()
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Extract Skill")
                    .font(.headline)
                Text("Create a reusable skill from this task")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
    
    // MARK: - Content
    
    private var content: some View {
        Group {
            switch extractionState {
            case .idle, .extracting:
                extractingView
            case .previewing:
                previewView
            case .saving:
                savingView
            case .saved:
                savedView
            }
        }
    }
    
    private var extractingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            
            Text("Analyzing task execution...")
                .font(.headline)
            
            Text("Using skill-creator to extract reusable patterns")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if let error = error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var previewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Name
                VStack(alignment: .leading, spacing: 4) {
                    Text("Skill Name")
                        .font(.headline)
                    TextField("skill-name", text: $editedName)
                        .textFieldStyle(.roundedBorder)
                    if !Skill.isValidName(editedName) && !editedName.isEmpty {
                        Text("Name must be lowercase with hyphens only, 1-64 characters")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                
                // Description
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description")
                        .font(.headline)
                    TextEditor(text: $editedDescription)
                        .frame(height: 80)
                        .font(.body)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    Text("\(editedDescription.count)/1024 characters")
                        .font(.caption)
                        .foregroundStyle(editedDescription.count > 1024 ? .red : .secondary)
                }
                
                // Instructions preview
                if let data = extractedData {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Instructions Preview")
                            .font(.headline)
                        
                        ScrollView {
                            Text(data.instructions)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 200)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    }
                }
                
                if let error = error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding()
        }
    }
    
    private var savingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Saving skill...")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var savedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            
            Text("Skill Saved!")
                .font(.headline)
            
            Text("'\(editedName)' is now available for matching")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Footer
    
    private var footer: some View {
        HStack {
            if extractionState == .previewing {
                Button("Re-extract") {
                    startExtraction()
                }
            }
            
            Spacer()
            
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            
            if extractionState == .previewing {
                Button("Save Skill") {
                    saveSkill()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValidForSave)
            } else if extractionState == .saved {
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
    
    // MARK: - Validation
    
    private var isValidForSave: Bool {
        Skill.isValidName(editedName) &&
        !editedDescription.isEmpty &&
        editedDescription.count <= 1024 &&
        extractedData != nil
    }
    
    // MARK: - Actions
    
    private func startExtraction() {
        guard let sessionId = task.sessionId else {
            error = "No session data available for this task"
            return
        }
        
        extractionState = .extracting
        error = nil
        
        Task {
            do {
                // Get trace path
                let tracePath = AppPaths.sessionDirectory(id: sessionId).appendingPathComponent("trace.jsonl")
                
                guard FileManager.default.fileExists(atPath: tracePath.path) else {
                    await MainActor.run {
                        error = "Trace file not found"
                        extractionState = .idle
                    }
                    return
                }
                
                // Create LLM client for extraction
                let llmClient = try await taskService.createLLMClient(
                    providerId: task.providerId,
                    modelId: task.modelId
                )
                
                // Create extractor
                let extractor = SkillExtractor(
                    skillManager: taskService.skillManager,
                    llmClient: llmClient
                )
                
                // Extract skill
                let data = try await extractor.previewExtraction(
                    taskDescription: task.taskDescription,
                    tracePath: tracePath
                )
                
                await MainActor.run {
                    extractedData = data
                    editedName = data.name
                    editedDescription = data.description
                    extractionState = .previewing
                }
                
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    extractionState = .idle
                }
            }
        }
    }
    
    private func saveSkill() {
        guard let data = extractedData else { return }
        
        extractionState = .saving
        
        Task {
            do {
                let skill = Skill(
                    name: editedName,
                    description: editedDescription,
                    license: nil,
                    compatibility: nil,
                    metadata: [
                        "extracted-from-task": task.taskDescription.prefix(100).description,
                        "extracted-at": ISO8601DateFormatter().string(from: Date())
                    ],
                    allowedTools: data.allowedTools,
                    instructions: data.instructions,
                    isImported: false,
                    sourceTaskId: task.id,
                    createdAt: Date(),
                    isEnabled: true
                )
                
                try taskService.skillManager.saveSkill(skill)
                
                await MainActor.run {
                    extractionState = .saved
                }
                
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    extractionState = .previewing
                }
            }
        }
    }
}

#Preview {
    SkillExtractionSheet(
        task: TaskRecord(
            title: "Test Task",
            taskDescription: "A test task description",
            status: .completed,
            providerId: "test",
            modelId: "test"
        ),
        taskService: TaskService()
    )
}
