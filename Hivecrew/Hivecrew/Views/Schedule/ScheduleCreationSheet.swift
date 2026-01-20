//
//  ScheduleCreationSheet.swift
//  Hivecrew
//
//  Sheet for creating and editing scheduled tasks
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Sheet for creating or editing a scheduled task
struct ScheduleCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var schedulerService: SchedulerService
    @Query private var providers: [LLMProviderRecord]
    
    // Task configuration
    @State private var taskDescription: String
    @State private var selectedProviderId: String
    @State private var selectedModelId: String
    @State private var attachedFilePaths: [String]
    @State private var mentionedSkillNames: [String]
    
    // Schedule configuration
    @State private var scheduleType: ScheduleType = .recurring
    @State private var scheduledDate: Date = Date().addingTimeInterval(3600)
    @State private var recurrenceFrequency: RecurrenceFrequency = .weekly
    @State private var selectedDaysOfWeek: Set<Int> = [2] // Monday
    @State private var dayOfMonth: Int = 1
    @State private var scheduleHour: Int = 9
    @State private var scheduleMinute: Int = 0
    
    // UI state
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @State private var showModelOptions: Bool = false
    @State private var showDatePicker: Bool = false
    @State private var showFilePicker: Bool = false
    
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
        self._attachedFilePaths = State(initialValue: attachedFilePaths)
        self._mentionedSkillNames = State(initialValue: mentionedSkillNames)
    }
    
    /// Initialize for editing an existing scheduled task
    init(editing schedule: ScheduledTask) {
        self.existingSchedule = schedule
        self._taskDescription = State(initialValue: schedule.taskDescription)
        self._selectedProviderId = State(initialValue: schedule.providerId)
        self._selectedModelId = State(initialValue: schedule.modelId)
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
    
    private var isEditing: Bool {
        existingSchedule != nil
    }
    
    private var canSave: Bool {
        !taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !selectedProviderId.isEmpty &&
        !selectedModelId.isEmpty
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
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            Text(isEditing ? "Edit Schedule" : "Schedule Task")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }
    
    // MARK: - Prompt Section
    
    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What should the agent do?")
                .font(.subheadline)
                .fontWeight(.medium)
            
            TextEditor(text: $taskDescription)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 80)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }
    
    // MARK: - File Attachment Section
    
    private var fileAttachmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Attachments")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Spacer()
                
                Button {
                    showFilePicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                            .font(.caption)
                        Text("Add Files")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            
            if attachedFilePaths.isEmpty {
                Text("No files attached. Files will be available in the agent's inbox when the task runs.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedFilePaths, id: \.self) { filePath in
                            ScheduleAttachmentItem(
                                filePath: filePath,
                                onRemove: {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        attachedFilePaths.removeAll { $0 == filePath }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls {
                    let path = url.path
                    if !attachedFilePaths.contains(path) {
                        attachedFilePaths.append(path)
                    }
                }
            }
        }
    }
    
    // MARK: - Schedule Section
    
    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("When should it run?")
                .font(.subheadline)
                .fontWeight(.medium)
            
            // Schedule type tabs
            Picker("", selection: $scheduleType) {
                Text("Recurring").tag(ScheduleType.recurring)
                Text("One-time").tag(ScheduleType.oneTime)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            
            if scheduleType == .oneTime {
                oneTimeConfig
            } else {
                recurringConfig
            }
        }
    }
    
    // MARK: - One-Time Configuration
    
    private var oneTimeConfig: some View {
        HStack(spacing: 12) {
            datePickerButton
            
            Text("at")
                .foregroundStyle(.secondary)
            
            timePickerView
        }
        .padding(.top, 4)
    }
    
    // MARK: - Date Picker Button
    
    private var datePickerButton: some View {
        Button {
            showDatePicker.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption)
                Text(formattedDate)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDatePicker, arrowEdge: .bottom) {
            DatePicker("", selection: $scheduledDate, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding()
        }
    }
    
    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: scheduledDate)
    }
    
    // MARK: - Recurring Configuration
    
    private var recurringConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Frequency row
            HStack(spacing: 12) {
                Picker("", selection: $recurrenceFrequency) {
                    Text("Daily").tag(RecurrenceFrequency.daily)
                    Text("Weekly").tag(RecurrenceFrequency.weekly)
                    Text("Monthly").tag(RecurrenceFrequency.monthly)
                }
                .labelsHidden()
                .fixedSize()
                
                if recurrenceFrequency == .monthly {
                    Text("on the")
                        .foregroundStyle(.secondary)
                    
                    Picker("", selection: $dayOfMonth) {
                        ForEach(1...31, id: \.self) { day in
                            Text(ordinal(day)).tag(day)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                
                Text("at")
                    .foregroundStyle(.secondary)
                
                timePickerView
            }
            
            // Weekday picker for weekly
            if recurrenceFrequency == .weekly {
                weekdayPicker
            }
            
            // Preview
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption)
                Text(schedulePreviewText)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
    
    private func ordinal(_ day: Int) -> String {
        let suffix: String
        switch day {
        case 1, 21, 31: suffix = "st"
        case 2, 22: suffix = "nd"
        case 3, 23: suffix = "rd"
        default: suffix = "th"
        }
        return "\(day)\(suffix)"
    }
    
    // MARK: - Time Picker
    
    private var timePickerView: some View {
        HStack(spacing: 4) {
            // Hour picker
            Picker("", selection: $scheduleHour) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%d", hour)).tag(hour)
                }
            }
            .labelsHidden()
            .fixedSize()
            
            Text(":")
                .foregroundStyle(.primary)
                .fontWeight(.medium)
            
            // Minute picker
            Picker("", selection: $scheduleMinute) {
                ForEach(0..<60, id: \.self) { minute in
                    Text(String(format: "%02d", minute)).tag(minute)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
    
    // MARK: - Weekday Picker
    
    private var weekdayPicker: some View {
        HStack(spacing: 6) {
            ForEach(Array(zip(1...7, ["S", "M", "T", "W", "T", "F", "S"])), id: \.0) { day, label in
                Button {
                    toggleDay(day)
                } label: {
                    Text(label)
                        .font(.caption)
                        .fontWeight(.medium)
                        .frame(width: 28, height: 28)
                        .background(selectedDaysOfWeek.contains(day) ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        .foregroundColor(selectedDaysOfWeek.contains(day) ? .white : .primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private func toggleDay(_ day: Int) {
        if selectedDaysOfWeek.contains(day) {
            if selectedDaysOfWeek.count > 1 {
                selectedDaysOfWeek.remove(day)
            }
        } else {
            selectedDaysOfWeek.insert(day)
        }
    }
    
    private var schedulePreviewText: String {
        buildRecurrenceRule().displayDescription
    }
    
    // MARK: - Model Options Section
    
    private var modelOptionsSection: some View {
        DisclosureGroup("Model Options", isExpanded: $showModelOptions) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Provider")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        providerPicker
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Model ID", text: $selectedModelId)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .padding(.top, 8)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    
    // MARK: - Provider Picker
    
    private var providerPicker: some View {
        Menu {
            ForEach(0..<providers.count, id: \.self) { index in
                Button(providers[index].displayName) {
                    selectedProviderId = providers[index].id
                }
            }
        } label: {
            HStack {
                Text(selectedProviderName)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
    }
    
    private var selectedProviderName: String {
        if selectedProviderId.isEmpty {
            return "Select..."
        }
        return providers.first(where: { $0.id == selectedProviderId })?.displayName ?? "Select..."
    }
    
    // MARK: - Footer
    
    private var footer: some View {
        HStack {
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            
            Spacer()
            
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.escape)
            
            Button(isEditing ? "Save" : "Schedule") {
                Task {
                    await saveSchedule()
                }
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
            .disabled(!canSave || isSaving)
        }
        .padding(16)
    }
    
    // MARK: - Actions
    
    private func setupDefaults() {
        // Set default provider from last used
        if selectedProviderId.isEmpty {
            let lastProviderId = UserDefaults.standard.string(forKey: "lastSelectedProviderId") ?? ""
            if !lastProviderId.isEmpty && providers.contains(where: { $0.id == lastProviderId }) {
                selectedProviderId = lastProviderId
            } else if let defaultProvider = providers.first(where: { $0.isDefault }) ?? providers.first {
                selectedProviderId = defaultProvider.id
            }
        }
        
        // Set default model from last used
        if selectedModelId.isEmpty {
            selectedModelId = UserDefaults.standard.string(forKey: "lastSelectedModelId") ?? "gpt-4o"
        }
    }
    
    private func generateTitle(from description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 50 {
            return trimmed
        }
        return String(trimmed.prefix(47)) + "..."
    }
    
    private func buildRecurrenceRule() -> RecurrenceRule {
        switch recurrenceFrequency {
        case .daily:
            return .daily(at: scheduleHour, minute: scheduleMinute)
        case .weekly:
            return .weekly(on: selectedDaysOfWeek, at: scheduleHour, minute: scheduleMinute)
        case .monthly:
            return .monthly(on: dayOfMonth, at: scheduleHour, minute: scheduleMinute)
        }
    }
    
    private func saveSchedule() async {
        isSaving = true
        errorMessage = nil
        
        defer { isSaving = false }
        
        let effectiveTitle = generateTitle(from: taskDescription)
        
        // For one-time, update the scheduledDate with the selected time
        var effectiveScheduledDate = scheduledDate
        if scheduleType == .oneTime {
            var components = Calendar.current.dateComponents([.year, .month, .day], from: scheduledDate)
            components.hour = scheduleHour
            components.minute = scheduleMinute
            effectiveScheduledDate = Calendar.current.date(from: components) ?? scheduledDate
        }
        
        do {
            if let existing = existingSchedule {
                try schedulerService.updateScheduledTask(
                    existing,
                    title: effectiveTitle,
                    taskDescription: taskDescription,
                    providerId: selectedProviderId,
                    modelId: selectedModelId,
                    attachedFilePaths: attachedFilePaths,
                    mentionedSkillNames: mentionedSkillNames.isEmpty ? nil : mentionedSkillNames,
                    scheduleType: scheduleType,
                    scheduledDate: scheduleType == .oneTime ? effectiveScheduledDate : nil,
                    recurrenceRule: scheduleType == .recurring ? buildRecurrenceRule() : nil
                )
            } else {
                _ = try schedulerService.createScheduledTask(
                    title: effectiveTitle,
                    taskDescription: taskDescription,
                    providerId: selectedProviderId,
                    modelId: selectedModelId,
                    attachedFilePaths: attachedFilePaths,
                    mentionedSkillNames: mentionedSkillNames.isEmpty ? nil : mentionedSkillNames,
                    scheduleType: scheduleType,
                    scheduledDate: scheduleType == .oneTime ? effectiveScheduledDate : nil,
                    recurrenceRule: scheduleType == .recurring ? buildRecurrenceRule() : nil
                )
            }
            
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Schedule Attachment Item

/// Individual file attachment preview for scheduled tasks
private struct ScheduleAttachmentItem: View {
    let filePath: String
    var onRemove: () -> Void
    
    @State private var isHovering: Bool = false
    
    private var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
    
    private var fileIcon: String {
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        guard let uti = UTType(filenameExtension: ext) else { return "doc" }
        
        if uti.conforms(to: .image) {
            return "photo"
        } else if uti.conforms(to: .pdf) {
            return "doc.richtext"
        } else if uti.conforms(to: .plainText) || uti.conforms(to: .sourceCode) {
            return "doc.text"
        } else if uti.conforms(to: .archive) {
            return "doc.zipper"
        } else if uti.conforms(to: .spreadsheet) {
            return "tablecells"
        } else if uti.conforms(to: .presentation) {
            return "slider.horizontal.below.rectangle"
        } else {
            return "doc"
        }
    }
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Image(systemName: fileIcon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                
                Text(fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 100, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            
            // Remove button
            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ScheduleCreationSheet(taskDescription: "Research the latest AI developments")
        .environmentObject(SchedulerService.shared)
        .modelContainer(for: [LLMProviderRecord.self, ScheduledTask.self], inMemory: true)
}
