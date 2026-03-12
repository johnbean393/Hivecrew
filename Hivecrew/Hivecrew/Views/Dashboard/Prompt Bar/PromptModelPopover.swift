//
//  PromptModelPopover.swift
//  Hivecrew
//
//  Popover UI and logic for provider/model selection.
//

import AppKit
import SwiftUI
import HivecrewLLM

/// Popover with searchable model list
struct PromptModelPopover: View {
    @Binding var selectedProviderId: String
    @Binding var selectedModelId: String
    @Binding var reasoningEnabled: Bool?
    @Binding var reasoningEffort: String?
    @Binding var serviceTier: LLMServiceTier?
    @Binding var copyCount: TaskCopyCount
    @Binding var useMultipleModels: Bool
    @Binding var multiModelSelections: [PromptModelSelection]
    let providers: [LLMProviderRecord]
    @Binding var isPresented: Bool
    
    @State private var searchText: String = ""
    @State private var availableModels: [LLMProviderModel] = []
    @State private var hoveredModelId: String?
    @State private var panelModelId: String?
    @State private var hoverOpenWorkItem: DispatchWorkItem?
    @State private var modelRowFrames: [String: CGRect] = [:]
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var modelListViewportHeight: CGFloat = 0
    @State private var codexRateLimitSnapshot: CodexRateLimitSnapshot?
    @StateObject private var hoverPanelController = ModelHoverInfoPanelController()
    
    private let hoverPanelOpenDelay: TimeInterval = 0.14
    
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    
    var selectedProvider: LLMProviderRecord? {
        providers.first(where: { $0.id == selectedProviderId })
    }
    
    var isOpenRouterProvider: Bool {
        guard let host = selectedProvider?.effectiveBaseURL.host?.lowercased() else {
            return false
        }
        return host.contains("openrouter.ai")
    }

    var isCodexProvider: Bool {
        selectedProvider?.backendMode == .codexOAuth
    }
    
    var popoverWidth: CGFloat {
        360
    }
    
    var isModelListScrollbarVisible: Bool {
        if modelListViewportHeight <= 1 {
            // Fallback before first layout pass.
            return filteredModels.count > 8
        }
        return estimatedModelListContentHeight > (modelListViewportHeight + 1)
    }
    
    var estimatedModelListContentHeight: CGFloat {
        let headerHeight: CGFloat = 30
        let listBottomPadding: CGFloat = 4
        let rowSpacing: CGFloat = 2
        
        let rowsHeight = filteredModels.reduce(CGFloat.zero) { partial, model in
            partial + estimatedRowHeight(for: model)
        }
        let spacingHeight = CGFloat(max(filteredModels.count - 1, 0)) * rowSpacing
        return headerHeight + rowsHeight + spacingHeight + listBottomPadding
    }
    
    var providerScopedModels: [LLMProviderModel] {
        return availableModels
    }
    
    var orderedProviderScopedModels: [LLMProviderModel] {
        let baseModels = LLMProviderModel.sortByVersionDescending(providerScopedModels)

        // Always bubble selected models to the top while preserving relative order.
        let selected = baseModels.filter { isModelPinnedToTop($0.id) }
        let unselected = baseModels.filter { !isModelPinnedToTop($0.id) }
        return selected + unselected
    }
    
    var filteredModels: [LLMProviderModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return orderedProviderScopedModels
        }
        
        return orderedProviderScopedModels.filter { model in
            model.id.localizedCaseInsensitiveContains(query)
            || model.displayName.localizedCaseInsensitiveContains(query)
            || (model.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Provider selector
            if providers.count > 1 {
                providerSection
                Divider()
            }
            
            // Search field
            searchField
            
            Divider()
            
            // Model list
            modelList

            Divider()

            if isCodexProvider {
                codexFastModeRow
                Divider()
            }

            multiModelToggleRow
        }
        .frame(width: popoverWidth, height: 480)
        .onAppear {
            loadModels()
            refreshCodexRateLimitSnapshot()
        }
        .onDisappear {
            resetHoverPanelState()
        }
        .onChange(of: selectedProviderId) { _, _ in
            resetHoverPanelState()
            loadModels()
            refreshCodexRateLimitSnapshot()
        }
        .onChange(of: searchText) { _, _ in
            resetHoverPanelState()
        }
        .onChange(of: useMultipleModels) { _, isEnabled in
            if isEnabled {
                // Avoid carrying a stale multi-selection into a new multi-model pass.
                multiModelSelections.removeAll()
            }
        }
        .onChange(of: filteredModels.map(\.id)) { _, updatedIDs in
            let hoveredStillVisible = hoveredModelId.map(updatedIDs.contains) ?? true
            let panelStillVisible = panelModelId.map(updatedIDs.contains) ?? true
            if !hoveredStillVisible || !panelStillVisible {
                resetHoverPanelState()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: CodexRateLimitStore.didChangeNotification)) { notification in
            guard let providerId = notification.userInfo?[CodexRateLimitStore.providerIdUserInfoKey] as? String,
                  providerId == selectedProviderId else {
                return
            }
            refreshCodexRateLimitSnapshot()
        }
    }

    private var selectedModelMetadata: LLMProviderModel? {
        providerScopedModels.first(where: { $0.id == selectedModelId })
    }

    // MARK: - Provider Section
    
    private var providerSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(providers, id: \.id) { provider in
                    providerChip(provider)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
    
    private func providerChip(_ provider: LLMProviderRecord) -> some View {
        let isSelected = provider.id == selectedProviderId
        
        return Button(action: {
            selectedProviderId = provider.id
            selectedModelId = UserDefaults.standard.persistedModelId(for: provider.id) ?? ""
        }) {
            Text(provider.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Search Field
    
    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.body)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding([.horizontal, .top], 12)
        .padding(.bottom, 8)
    }

    private var multiModelToggleRow: some View {
        HStack(spacing: 0) {
            Toggle("Use Multiple Models", isOn: $useMultipleModels)
                .font(.caption)
                .fontWeight(.medium)
                .toggleStyle(.switch)
                .controlSize(.small)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var codexFastModeRow: some View {
        HStack(spacing: 8) {
            Text("Fast Mode")
                .font(.caption)
                .fontWeight(.medium)
            Spacer(minLength: 0)
            if let summary = codexRateLimitSummaryText {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(codexRateLimitSummaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Toggle("Fast Mode", isOn: codexFastModeBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var codexRateLimitSummaryText: String? {
        guard isCodexProvider,
              let primary = codexRateLimitSnapshot?.primary,
              let secondary = codexRateLimitSnapshot?.secondary else {
            return nil
        }

        return "\(primary.compactLabel) \(primary.remainingPercent)% • \(secondary.compactLabel) \(secondary.remainingPercent)%"
    }

    private var codexRateLimitSummaryColor: Color {
        guard let snapshot = codexRateLimitSnapshot else {
            return .secondary
        }

        let minimumRemaining = [snapshot.primary?.remainingPercent, snapshot.secondary?.remainingPercent]
            .compactMap { $0 }
            .min() ?? 100

        if minimumRemaining <= 10 {
            return .red
        }
        if minimumRemaining <= 25 {
            return .orange
        }
        return .secondary
    }
    
    // MARK: - Model List
    
    private var modelList: some View {
        Group {
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if filteredModels.isEmpty {
                emptyView
            } else {
                modelListContent
            }
        }
    }
    
    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading models...")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
        }
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Failed to load models")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") {
                loadModels()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
    }
    
    private var emptyView: some View {
        VStack {
            Spacer()
            Text(searchText.isEmpty ? "No models available" : "No matching models")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var modelListContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader
                
                LazyVStack(spacing: 2) {
                    ForEach(filteredModels) { model in
                        modelRow(model)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ModelListViewportHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        )
        .onPreferenceChange(ModelListViewportHeightPreferenceKey.self) { height in
            modelListViewportHeight = height
        }
    }
    
    private func openRouterDetailsPane(for model: LLMProviderModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.displayName)
                .font(.title2)
                .fontWeight(.semibold)
                .lineLimit(1)
            
            Text(model.id)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            
            if let renderedDescription = renderedMarkdownDescription(model.description) {
                Text(renderedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(10)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tint(.accentColor)
            }
            
            Divider()
            
            detailIconRow(
                systemImage: "textformat.123",
                title: "Context length",
                value: model.contextLength.map { "\(formattedTokenCount($0)) tokens" } ?? "N/A"
            )
            detailIconRow(
                systemImage: "calendar",
                title: "Release date",
                value: model.createdAt.map { Self.fullDateFormatter.string(from: $0) } ?? "N/A"
            )
            
            if !inputModalityItems(model).isEmpty {
                modalityIconRow(
                    title: "Input modalities",
                    symbol: "arrow.down.circle",
                    accentColor: .secondary,
                    items: inputModalityItems(model)
                )
            }
            if !outputModalityItems(model).isEmpty {
                modalityIconRow(
                    title: "Output modalities",
                    symbol: "arrow.up.circle",
                    accentColor: .secondary,
                    items: outputModalityItems(model)
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
    
    private func detailIconRow(systemImage: String, title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text("\(title):")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
        }
    }
    
    private func modalityIconRow(title: String, symbol: String, accentColor: Color, items: [ModalityItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(accentColor)
                    .frame(width: 14)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(accentColor)
            }
            
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Label(item.label, systemImage: item.systemImage)
                        .font(.caption2)
                        .foregroundStyle(item.foregroundColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(item.backgroundColor)
                        .clipShape(Capsule())
                }
            }
        }
    }
    
    private var sectionHeader: some View {
        Text("Models (\(filteredModels.count))")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private func modelRow(_ model: LLMProviderModel) -> some View {
        let isSelected = isModelSelected(model.id)
        let isHovered = model.id == hoveredModelId

        VStack(alignment: .leading, spacing: isSelected && useMultipleModels ? 8 : 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryRowTitle(model))
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    
                    if let secondaryText = secondaryRowText(model) {
                        Text(secondaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                
                Spacer(minLength: 8)
                
                if isOpenRouterProvider && model.isVisionCapable {
                    Image(systemName: "eye")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                
                if useMultipleModels {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.body)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    
                    if isSelected {
                        modelCopyCountMenu(modelId: model.id)
                    }
                } else if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
            }

            if useMultipleModels, isSelected, model.reasoningCapability.kind != .none {
                rowReasoningControl(for: model)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                    ? Color.accentColor.opacity(0.2)
                    : (isHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            handleModelSelectionTap(model)
        }
        .background(
            ScreenFrameReader { screenFrame in
                modelRowFrames[model.id] = screenFrame
                if panelModelId == model.id, isOpenRouterProvider {
                    showHoverPanel(for: model)
                }
            }
        )
        .onHover { hovering in
            guard isOpenRouterProvider else { return }
            
            if hovering {
                hoveredModelId = model.id
                hoverPanelController.setRowHovered(true)
                scheduleHoverPanelOpen(for: model)
            } else {
                if hoveredModelId == model.id {
                    hoveredModelId = nil
                    panelModelId = nil
                    cancelScheduledHoverPanelOpen()
                }
                hoverPanelController.setRowHovered(hoveredModelId != nil)
            }
        }
    }

    private func modelCopyCountMenu(modelId: String) -> some View {
        let selectedCount = selectedCopyCount(for: modelId)

        return Menu {
            ForEach(TaskCopyCount.allCases) { option in
                Button(option.description) {
                    updateSelectionCount(for: modelId, to: option)
                }
            }
        } label: {
            Text(selectedCount.description)
                .font(.caption2)
                .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rowReasoningControl(for model: LLMProviderModel) -> some View {
        switch model.reasoningCapability.kind {
        case .none:
            EmptyView()
        case .toggle:
            HStack(spacing: 8) {
                Text("Reasoning")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Toggle("Reasoning", isOn: reasoningToggleBinding(for: model))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        case .effort:
            HStack(spacing: 8) {
                Text("Reasoning")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Picker("Reasoning", selection: reasoningEffortBinding(for: model)) {
                    ForEach(model.reasoningCapability.supportedEfforts, id: \.self) { effort in
                        Text(reasoningEffortDisplayName(effort)).tag(Optional(effort))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
        }
    }

    private func selectionIndex(for modelId: String) -> Int? {
        multiModelSelections.firstIndex(where: { selection in
            selection.providerId == selectedProviderId && selection.modelId == modelId
        })
    }

    private func isModelPinnedToTop(_ modelId: String) -> Bool {
        if useMultipleModels {
            return selectionIndex(for: modelId) != nil
        }
        return modelId == selectedModelId
    }

    private func isModelSelected(_ modelId: String) -> Bool {
        if useMultipleModels {
            return selectionIndex(for: modelId) != nil
        }
        return modelId == selectedModelId
    }

    private func selectedCopyCount(for modelId: String) -> TaskCopyCount {
        guard let index = selectionIndex(for: modelId) else {
            return .one
        }
        return multiModelSelections[index].copyCount
    }

    private func updateSelectionCount(for modelId: String, to copyCount: TaskCopyCount) {
        guard let index = selectionIndex(for: modelId) else { return }
        multiModelSelections[index].copyCount = copyCount
    }

    private var codexFastModeBinding: Binding<Bool> {
        Binding(
            get: {
                currentServiceTierForSelectedProvider() == .priority
            },
            set: { isEnabled in
                let updatedTier: LLMServiceTier? = isEnabled ? .priority : nil
                serviceTier = updatedTier

                guard useMultipleModels else { return }
                for index in multiModelSelections.indices where multiModelSelections[index].providerId == selectedProviderId {
                    multiModelSelections[index].serviceTier = updatedTier
                }
            }
        )
    }

    private func refreshCodexRateLimitSnapshot() {
        guard isCodexProvider else {
            codexRateLimitSnapshot = nil
            return
        }

        codexRateLimitSnapshot = CodexRateLimitStore.retrieve(providerId: selectedProviderId)
    }

    private func reasoningToggleBinding(for model: LLMProviderModel) -> Binding<Bool> {
        Binding(
            get: {
                currentReasoningSelection(for: model).enabled ?? model.reasoningCapability.defaultEnabled
            },
            set: { newValue in
                setReasoningSelection(for: model, enabled: newValue, effort: nil)
            }
        )
    }

    private func reasoningEffortBinding(for model: LLMProviderModel) -> Binding<String?> {
        Binding(
            get: {
                currentReasoningSelection(for: model).effort
            },
            set: { newValue in
                setReasoningSelection(for: model, enabled: nil, effort: newValue)
            }
        )
    }

    private func currentReasoningSelection() -> ReasoningSelectionResolution {
        guard let selectedModelMetadata else {
            return ReasoningSelectionResolution(enabled: reasoningEnabled, effort: reasoningEffort)
        }
        return currentReasoningSelection(for: selectedModelMetadata)
    }

    private func currentReasoningSelection(for model: LLMProviderModel) -> ReasoningSelectionResolution {
        if useMultipleModels, let index = selectionIndex(for: model.id) {
            return resolveReasoningSelection(
                capability: model.reasoningCapability,
                currentEnabled: multiModelSelections[index].reasoningEnabled,
                currentEffort: multiModelSelections[index].reasoningEffort
            )
        }
        return resolveReasoningSelection(
            capability: model.reasoningCapability,
            currentEnabled: reasoningEnabled,
            currentEffort: reasoningEffort
        )
    }

    private func setReasoningSelection(enabled: Bool?, effort: String?) {
        guard let selectedModelMetadata else { return }
        setReasoningSelection(for: selectedModelMetadata, enabled: enabled, effort: effort)
    }

    private func setReasoningSelection(for model: LLMProviderModel, enabled: Bool?, effort: String?) {
        let resolved = resolveReasoningSelection(
            capability: model.reasoningCapability,
            currentEnabled: enabled,
            currentEffort: effort
        )

        if useMultipleModels, let index = selectionIndex(for: model.id) {
            multiModelSelections[index].reasoningEnabled = resolved.enabled
            multiModelSelections[index].reasoningEffort = resolved.effort
            return
        }

        reasoningEnabled = resolved.enabled
        reasoningEffort = resolved.effort
    }

    private func synchronizeReasoningSelectionForCurrentModel() {
        let resolved = currentReasoningSelection()
        if useMultipleModels, let index = selectionIndex(for: selectedModelId) {
            multiModelSelections[index].reasoningEnabled = resolved.enabled
            multiModelSelections[index].reasoningEffort = resolved.effort
            multiModelSelections[index].serviceTier = currentServiceTierForSelectedProvider()
        } else {
            reasoningEnabled = resolved.enabled
            reasoningEffort = resolved.effort
        }
    }

    private func synchronizeReasoningSelectionsForVisibleModels() {
        if useMultipleModels {
            for index in multiModelSelections.indices {
                guard multiModelSelections[index].providerId == selectedProviderId,
                      let model = providerScopedModels.first(where: { $0.id == multiModelSelections[index].modelId }) else {
                    continue
                }
                let resolved = resolveReasoningSelection(
                    capability: model.reasoningCapability,
                    currentEnabled: multiModelSelections[index].reasoningEnabled,
                    currentEffort: multiModelSelections[index].reasoningEffort
                )
                multiModelSelections[index].reasoningEnabled = resolved.enabled
                multiModelSelections[index].reasoningEffort = resolved.effort
            }
        } else {
            synchronizeReasoningSelectionForCurrentModel()
        }
    }

    private func handleModelSelectionTap(_ model: LLMProviderModel) {
        resetHoverPanelState()

        if useMultipleModels {
            if let index = selectionIndex(for: model.id) {
                multiModelSelections.remove(at: index)
            } else {
                multiModelSelections.append(
                    PromptModelSelection(
                        providerId: selectedProviderId,
                        modelId: model.id,
                        copyCount: copyCount,
                        serviceTier: isCodexProvider ? currentServiceTierForSelectedProvider() : nil
                    )
                )
            }
            selectedModelId = model.id
            UserDefaults.standard.setPersistedModelId(model.id, for: selectedProviderId)
            synchronizeReasoningSelectionForCurrentModel()
            return
        }

        selectedModelId = model.id
        UserDefaults.standard.setPersistedModelId(model.id, for: selectedProviderId)
        synchronizeReasoningSelectionForCurrentModel()

        // Dismiss after a small delay to ensure the binding propagates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isPresented = false
        }
    }

    private func currentServiceTierForSelectedProvider() -> LLMServiceTier? {
        guard isCodexProvider else { return nil }
        if useMultipleModels {
            let providerSelections = multiModelSelections.filter { $0.providerId == selectedProviderId }
            if !providerSelections.isEmpty {
                if providerSelections.allSatisfy({ $0.serviceTier == .priority }) {
                    return .priority
                }
            }
        }
        return serviceTier
    }

    private func scheduleHoverPanelOpen(for model: LLMProviderModel) {
        cancelScheduledHoverPanelOpen()
        let targetModelID = model.id
        
        let task = DispatchWorkItem { [targetModelID] in
            guard hoveredModelId == targetModelID else { return }
            panelModelId = targetModelID
            showHoverPanel(for: model)
        }
        
        hoverOpenWorkItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverPanelOpenDelay, execute: task)
    }
    
    private func cancelScheduledHoverPanelOpen() {
        hoverOpenWorkItem?.cancel()
        hoverOpenWorkItem = nil
    }
    
    private func resetHoverPanelState() {
        hoveredModelId = nil
        panelModelId = nil
        cancelScheduledHoverPanelOpen()
        hoverPanelController.hide()
    }
    
    private func showHoverPanel(for model: LLMProviderModel) {
        guard isOpenRouterProvider else { return }
        guard panelModelId == model.id else { return }
        guard let rowFrame = modelRowFrames[model.id] else { return }
        let horizontalOffset: CGFloat = isModelListScrollbarVisible ? 14 : 0
        
        hoverPanelController.show(
            content: AnyView(
                openRouterDetailsPane(for: model)
                    .frame(width: 430)
                    .onHover { hovering in
                        hoverPanelController.setPanelHovered(hovering)
                    }
            ),
            anchorRowFrame: rowFrame,
            horizontalOffset: horizontalOffset
        )
    }
    
    // MARK: - Load Models
    
    private func loadModels() {
        guard let provider = selectedProvider else {
            availableModels = []
            selectedModelId = ""
            resetHoverPanelState()
            return
        }
        
        let apiKey: String
        if provider.authMode == .apiKey {
            guard let stored = provider.retrieveAPIKey() else {
                errorMessage = "No API key configured"
                availableModels = []
                resetHoverPanelState()
                return
            }
            apiKey = stored
        } else {
            apiKey = ""
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let config = provider.makeLLMConfiguration(
                    model: provider.backendMode == .codexOAuth ? "gpt-5-codex" : "model-listing-placeholder",
                    apiKey: apiKey
                )
                
                let client = LLMService.shared.createClient(from: config)
                let models = try await client.listModelsDetailed()
                
                await MainActor.run {
                    self.availableModels = models
                    self.isLoading = false
                    synchronizeSelectionWithVisibleModels()
                    synchronizeReasoningSelectionsForVisibleModels()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    
                    // Fallback to hardcoded models on error
                    self.availableModels = [LLMProviderModel(id: "moonshotai/kimi-k2.5")]
                    synchronizeReasoningSelectionsForVisibleModels()
                }
            }
        }
    }
    
    private func synchronizeSelectionWithVisibleModels() {
        guard !orderedProviderScopedModels.isEmpty else {
            if selectedProvider == nil {
                selectedModelId = ""
            }
            resetHoverPanelState()
            return
        }
        
        let selectedIsVisible = orderedProviderScopedModels.contains { $0.id == selectedModelId }
        if !selectedIsVisible, let firstVisibleModel = orderedProviderScopedModels.first {
            selectedModelId = firstVisibleModel.id
            UserDefaults.standard.setPersistedModelId(firstVisibleModel.id, for: selectedProviderId)
        }
        synchronizeReasoningSelectionForCurrentModel()
    }
    
    private func primaryRowTitle(_ model: LLMProviderModel) -> String {
        isOpenRouterProvider ? model.displayName : model.id
    }
    
    private func estimatedRowHeight(for model: LLMProviderModel) -> CGFloat {
        // OpenRouter rows can include two text lines (title + model ID).
        if isOpenRouterProvider && secondaryRowText(model) != nil {
            return 40
        }
        return 30
    }
    
    private func secondaryRowText(_ model: LLMProviderModel) -> String? {
        guard isOpenRouterProvider else { return nil }
        let displayName = model.displayName
        if displayName.caseInsensitiveCompare(model.id) == .orderedSame {
            return nil
        }
        return model.id
    }
    
    private func trimmedDescription(_ description: String?) -> String? {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
    
    private func renderedMarkdownDescription(_ description: String?) -> AttributedString? {
        guard let plainText = trimmedDescription(description) else { return nil }
        let markdownWithPreservedLineBreaks = plainText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "  \n")
        
        if let parsed = try? AttributedString(
            markdown: markdownWithPreservedLineBreaks,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            return parsed
        }
        
        return AttributedString(plainText)
    }
    
    private struct ModalityItem: Identifiable {
        let normalizedName: String
        let label: String
        let systemImage: String
        let foregroundColor: Color
        let backgroundColor: Color
        
        var id: String { normalizedName }
    }
    
    private func inputModalityItems(_ model: LLMProviderModel) -> [ModalityItem] {
        modalityItems(from: model.inputModalities)
    }
    
    private func outputModalityItems(_ model: LLMProviderModel) -> [ModalityItem] {
        modalityItems(from: model.outputModalities)
    }
    
    private func modalityItems(from modalities: [String]?) -> [ModalityItem] {
        guard let modalities else { return [] }

        var seen: Set<String> = []
        var results: [ModalityItem] = []
        
        for modality in modalities {
            let normalized = modality.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            
            let display = modalityDisplay(for: normalized)
            results.append(
                ModalityItem(
                    normalizedName: normalized,
                    label: display.label,
                    systemImage: display.icon,
                    foregroundColor: display.foregroundColor,
                    backgroundColor: display.backgroundColor
                )
            )
        }
        
        return results
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
    
    private func modalityDisplay(
        for normalizedName: String
    ) -> (label: String, icon: String, foregroundColor: Color, backgroundColor: Color) {
        switch normalizedName {
        case "text":
            return ("Text", "text.alignleft", .blue, Color.blue.opacity(0.18))
        case "image", "vision":
            return ("Image", "photo", .purple, Color.purple.opacity(0.18))
        case "audio", "speech", "voice":
            return ("Audio", "waveform", .orange, Color.orange.opacity(0.18))
        case "video":
            return ("Video", "video", .red, Color.red.opacity(0.18))
        case "file", "document":
            return ("File", "doc", .teal, Color.teal.opacity(0.2))
        case "code":
            return ("Code", "chevron.left.forwardslash.chevron.right", .indigo, Color.indigo.opacity(0.2))
        default:
            return (
                normalizedName.replacingOccurrences(of: "_", with: " ").capitalized,
                "circle.grid.2x2",
                .secondary,
                Color.primary.opacity(0.1)
            )
        }
    }
    
    private func formattedTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 100_000 {
            return String(format: "%.0fK", Double(value) / 1_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
