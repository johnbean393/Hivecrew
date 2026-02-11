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
        if isOpenRouterProvider {
            return providerScopedModels.sorted { lhs, rhs in
                let lhsProvider = providerSlug(from: lhs.id)
                let rhsProvider = providerSlug(from: rhs.id)
                
                if lhsProvider != rhsProvider {
                    return lhsProvider.localizedStandardCompare(rhsProvider) == .orderedAscending
                }
                
                let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }
                
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
        }
        return providerScopedModels
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
        }
        .frame(width: popoverWidth, height: 480)
        .onAppear {
            loadModels()
        }
        .onDisappear {
            resetHoverPanelState()
        }
        .onChange(of: selectedProviderId) { _, _ in
            resetHoverPanelState()
            loadModels()
        }
        .onChange(of: searchText) { _, _ in
            resetHoverPanelState()
        }
        .onChange(of: filteredModels.map(\.id)) { _, updatedIDs in
            let hoveredStillVisible = hoveredModelId.map(updatedIDs.contains) ?? true
            let panelStillVisible = panelModelId.map(updatedIDs.contains) ?? true
            if !hoveredStillVisible || !panelStillVisible {
                resetHoverPanelState()
            }
        }
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
            
            // Force UserDefaults to synchronize immediately
            UserDefaults.standard.set(provider.id, forKey: "lastSelectedProviderId")
            UserDefaults.standard.synchronize()
            
            // Clear the model selection when switching providers
            selectedModelId = ""
            UserDefaults.standard.set("", forKey: "lastSelectedModelId")
            UserDefaults.standard.synchronize()
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
        let isSelected = model.id == selectedModelId
        let isHovered = model.id == hoveredModelId
        
        Button(action: {
            resetHoverPanelState()
            selectedModelId = model.id
            
            // Force UserDefaults to synchronize immediately
            UserDefaults.standard.set(model.id, forKey: "lastSelectedModelId")
            UserDefaults.standard.synchronize()
            
            // Dismiss after a small delay to ensure the binding propagates
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isPresented = false
            }
        }) {
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
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
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
        }
        .buttonStyle(.plain)
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
        
        // Get API key
        guard let apiKey = provider.retrieveAPIKey() else {
            errorMessage = "No API key configured"
            availableModels = []
            selectedModelId = ""
            resetHoverPanelState()
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let config = LLMConfiguration(
                    displayName: provider.displayName,
                    baseURL: provider.parsedBaseURL,
                    apiKey: apiKey,
                    model: "moonshotai/kimi-k2.5", // Placeholder, not used for listing
                    organizationId: provider.organizationId,
                    timeoutInterval: provider.timeoutInterval
                )
                
                let client = LLMService.shared.createClient(from: config)
                let models = try await client.listModelsDetailed()
                
                await MainActor.run {
                    self.availableModels = models
                    self.isLoading = false
                    synchronizeSelectionWithVisibleModels()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    
                    // Fallback to hardcoded models on error
                    self.availableModels = [LLMProviderModel(id: "moonshotai/kimi-k2.5")]
                    synchronizeSelectionWithVisibleModels()
                }
            }
        }
    }
    
    private func synchronizeSelectionWithVisibleModels() {
        guard !orderedProviderScopedModels.isEmpty else {
            selectedModelId = ""
            UserDefaults.standard.set("", forKey: "lastSelectedModelId")
            UserDefaults.standard.synchronize()
            resetHoverPanelState()
            return
        }
        
        let selectedIsVisible = orderedProviderScopedModels.contains { $0.id == selectedModelId }
        if !selectedIsVisible, let firstVisibleModel = orderedProviderScopedModels.first {
            selectedModelId = firstVisibleModel.id
            UserDefaults.standard.set(firstVisibleModel.id, forKey: "lastSelectedModelId")
            UserDefaults.standard.synchronize()
        }
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
    
    private func providerSlug(from modelID: String) -> String {
        guard let slashIndex = modelID.firstIndex(of: "/") else {
            return ""
        }
        return String(modelID[..<slashIndex]).lowercased()
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
