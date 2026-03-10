//
//  ScheduleCreationSheet.swift
//  Hivecrew
//
//  Sheet for creating and editing scheduled tasks
//

import SwiftUI
import SwiftData
import HivecrewLLM

/// Sheet for creating or editing a scheduled task
struct ScheduleCreationSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var schedulerService: SchedulerService
    @StateObject var skillManager = SkillManager()
    @Query var providers: [LLMProviderRecord]
    
    // Task configuration
    @State var taskDescription: String
    @State var selectedProviderId: String
    @State var selectedModelId: String
    @State var reasoningEnabled: Bool?
    @State var reasoningEffort: String?
    @State var attachedFilePaths: [String]
    @State var mentionedSkillNames: [String]
    @State var availableModels: [LLMProviderModel] = []
    
    // Schedule configuration
    @State var scheduleType: ScheduleType = .recurring
    @State var scheduledDate: Date = Date().addingTimeInterval(3600)
    @State var recurrenceFrequency: RecurrenceFrequency = .weekly
    @State var selectedDaysOfWeek: Set<Int> = [2] // Monday
    @State var dayOfMonth: Int = 1
    @State var scheduleHour: Int = 9
    @State var scheduleMinute: Int = 0
    
    // UI state
    @State var isSaving: Bool = false
    @State var errorMessage: String?
    @State var showModelOptions: Bool = false
    @State var showDatePicker: Bool = false
    @State var showFilePicker: Bool = false
    @State var showSkillPicker: Bool = false
    
    // Edit mode
    let existingSchedule: ScheduledTask?
    
    /// Initialize for creating a new scheduled task
    init(
        taskDescription: String = "",
        providerId: String = "",
        modelId: String = "",
        attachedFilePaths: [String] = [],
        mentionedSkillNames: [String] = []
    ) {
        self.existingSchedule = nil
        self._taskDescription = State(initialValue: taskDescription)
        self._selectedProviderId = State(initialValue: providerId)
        self._selectedModelId = State(initialValue: modelId)
        self._reasoningEnabled = State(initialValue: nil)
        self._reasoningEffort = State(initialValue: nil)
        self._attachedFilePaths = State(initialValue: attachedFilePaths)
        self._mentionedSkillNames = State(initialValue: mentionedSkillNames)
    }
    
    /// Initialize for editing an existing scheduled task
    init(editing schedule: ScheduledTask) {
        self.existingSchedule = schedule
        self._taskDescription = State(initialValue: schedule.taskDescription)
        self._selectedProviderId = State(initialValue: schedule.providerId)
        self._selectedModelId = State(initialValue: schedule.modelId)
        self._reasoningEnabled = State(initialValue: schedule.reasoningEnabled)
        self._reasoningEffort = State(initialValue: schedule.reasoningEffort)
        self._attachedFilePaths = State(initialValue: schedule.attachedFilePaths)
        self._mentionedSkillNames = State(initialValue: schedule.mentionedSkillNames ?? [])
        self._scheduleType = State(initialValue: schedule.scheduleType)
        
        if let date = schedule.scheduledDate {
            self._scheduledDate = State(initialValue: date)
        }
        
        if let rule = schedule.recurrenceRule {
            self._recurrenceFrequency = State(initialValue: rule.frequency)
            self._selectedDaysOfWeek = State(initialValue: rule.daysOfWeek ?? [2])
            self._dayOfMonth = State(initialValue: rule.dayOfMonth ?? 1)
            self._scheduleHour = State(initialValue: rule.hour)
            self._scheduleMinute = State(initialValue: rule.minute)
        }
    }
    
    var isEditing: Bool {
        existingSchedule != nil
    }
    
    var canSave: Bool {
        !taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !selectedProviderId.isEmpty &&
        !selectedModelId.isEmpty
    }

    var selectedModelMetadata: LLMProviderModel? {
        availableModels.first(where: { $0.id == selectedModelId })
    }

    var selectedReasoningCapability: LLMReasoningCapability {
        selectedModelMetadata?.reasoningCapability ?? .none
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            
            Divider()
            
            // Content
            VStack(alignment: .leading, spacing: 20) {
                // Prompt input
                promptSection
                
                // File attachments
                fileAttachmentSection
                
                // Skills section
                skillsSection
                
                // Schedule selection
                scheduleSection
                
                // Model options (collapsible)
                modelOptionsSection
            }
            .padding(20)
            
            Spacer(minLength: 0)
            
            Divider()
            
            // Footer
            footer
        }
        .frame(width: 440)
        .frame(minHeight: 550)
        .onAppear {
            setupDefaults()
            loadAvailableModels()
        }
        .onChange(of: selectedProviderId) { _, _ in
            restorePersistedModelForSelectedProvider()
            loadAvailableModels()
        }
        .onChange(of: selectedModelId) { _, _ in
            UserDefaults.standard.setPersistedModelId(selectedModelId, for: selectedProviderId)
            synchronizeReasoningSelection()
        }
    }
}
