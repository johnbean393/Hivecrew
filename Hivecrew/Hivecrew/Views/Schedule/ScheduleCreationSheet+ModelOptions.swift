import SwiftUI
import SwiftData
import TipKit
import HivecrewShared
import HivecrewLLM

extension ScheduleCreationSheet {
    func restorePersistedModelForSelectedProvider() {
        let restoredModelId = UserDefaults.standard.persistedModelId(for: selectedProviderId) ?? ""
        if selectedModelId != restoredModelId {
            selectedModelId = restoredModelId
        }
    }

    func toggleSkill(_ skillName: String) {
        if mentionedSkillNames.contains(skillName) {
            mentionedSkillNames.removeAll { $0 == skillName }
        } else {
            mentionedSkillNames.append(skillName)
        }
    }

    var schedulePreviewText: String {
        buildRecurrenceRule().displayDescription
    }

    // MARK: - Model Options

    var modelOptionsSection: some View {
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
                        TextField("", text: $selectedModelId)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if selectedReasoningCapability.kind != .none {
                    reasoningControlSection
                }
            }
            .padding(.top, 8)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    var providerPicker: some View {
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

    var selectedProviderName: String {
        if selectedProviderId.isEmpty {
            return "Select..."
        }
        return providers.first(where: { $0.id == selectedProviderId })?.displayName ?? "Select..."
    }

    @ViewBuilder
    var reasoningControlSection: some View {
        switch selectedReasoningCapability.kind {
        case .none:
            EmptyView()
        case .toggle:
            Toggle("Reasoning", isOn: Binding(
                get: { reasoningEnabled ?? selectedReasoningCapability.defaultEnabled },
                set: { newValue in
                    reasoningEnabled = newValue
                    reasoningEffort = nil
                }
            ))
            .toggleStyle(.switch)
        case .effort:
            VStack(alignment: .leading, spacing: 4) {
                Text("Reasoning")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Reasoning", selection: Binding(
                    get: {
                        reasoningEffort
                            ?? preferredReasoningEffortDefault(for: selectedReasoningCapability)
                            ?? ""
                    },
                    set: { newValue in
                        reasoningEnabled = nil
                        reasoningEffort = newValue
                    }
                )) {
                    ForEach(selectedReasoningCapability.supportedEfforts, id: \.self) { effort in
                        Text(reasoningEffortDisplayName(effort)).tag(effort)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - Footer

    var footer: some View {
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

    func setupDefaults() {
        if selectedProviderId.isEmpty {
            let lastProviderId = UserDefaults.standard.string(forKey: "lastSelectedProviderId") ?? ""
            if !lastProviderId.isEmpty && providers.contains(where: { $0.id == lastProviderId }) {
                selectedProviderId = lastProviderId
            } else if let defaultProvider = providers.first(where: { $0.isDefault }) ?? providers.first {
                selectedProviderId = defaultProvider.id
            }
        }

        if selectedModelId.isEmpty {
            selectedModelId = UserDefaults.standard.persistedModelId(for: selectedProviderId) ?? "moonshotai/kimi-k2.5"
        }
        synchronizeReasoningSelection()
    }

    func generateTitle(from description: String) -> String {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 50 {
            return trimmed
        }
        return String(trimmed.prefix(47)) + "..."
    }

    func buildRecurrenceRule() -> RecurrenceRule {
        switch recurrenceFrequency {
        case .daily:
            return .daily(at: scheduleHour, minute: scheduleMinute)
        case .weekly:
            return .weekly(on: selectedDaysOfWeek, at: scheduleHour, minute: scheduleMinute)
        case .monthly:
            return .monthly(on: dayOfMonth, at: scheduleHour, minute: scheduleMinute)
        }
    }

    func loadAvailableModels() {
        guard let provider = providers.first(where: { $0.id == selectedProviderId }) else {
            availableModels = []
            synchronizeReasoningSelection()
            return
        }

        let apiKey: String
        if provider.authMode == .apiKey {
            guard let stored = provider.retrieveAPIKey() else {
                availableModels = []
                synchronizeReasoningSelection()
                return
            }
            apiKey = stored
        } else {
            apiKey = ""
        }

        let requestProviderId = provider.id
        Task {
            do {
                let config = provider.makeLLMConfiguration(
                    model: provider.backendMode == .codexOAuth ? "gpt-5-codex" : "model-listing-placeholder",
                    apiKey: apiKey
                )
                let client = LLMService.shared.createClient(from: config)
                let models = try await client.listModelsDetailed()
                await MainActor.run {
                    guard requestProviderId == selectedProviderId else { return }
                    availableModels = models
                    synchronizeReasoningSelection()
                }
            } catch {
                await MainActor.run {
                    guard requestProviderId == selectedProviderId else { return }
                    availableModels = []
                    synchronizeReasoningSelection()
                }
            }
        }
    }

    func synchronizeReasoningSelection() {
        let resolved = resolveReasoningSelection(
            capability: selectedReasoningCapability,
            currentEnabled: reasoningEnabled,
            currentEffort: reasoningEffort
        )
        reasoningEnabled = resolved.enabled
        reasoningEffort = resolved.effort
    }

    func saveSchedule() async {
        isSaving = true
        errorMessage = nil

        defer { isSaving = false }

        let effectiveTitle = generateTitle(from: taskDescription)

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
                    reasoningEnabled: reasoningEnabled,
                    reasoningEffort: reasoningEffort,
                    shouldUpdateReasoning: true,
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
                    reasoningEnabled: reasoningEnabled,
                    reasoningEffort: reasoningEffort,
                    attachedFilePaths: attachedFilePaths,
                    mentionedSkillNames: mentionedSkillNames.isEmpty ? nil : mentionedSkillNames,
                    scheduleType: scheduleType,
                    scheduledDate: scheduleType == .oneTime ? effectiveScheduledDate : nil,
                    recurrenceRule: scheduleType == .recurring ? buildRecurrenceRule() : nil
                )

                TipStore.shared.donateScheduleCreated()
                TipStore.shared.scheduleCreated()
            }

            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
