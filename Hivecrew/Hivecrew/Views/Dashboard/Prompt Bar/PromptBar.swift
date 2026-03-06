//
//  PromptBar.swift
//  Hivecrew
//
//  Main prompt bar component combining text editor, attachments, and model selection
//

import SwiftUI
import SwiftData
import TipKit
import UniformTypeIdentifiers
import QuickLook
import HivecrewLLM

struct ReasoningSelectionResolution {
    let enabled: Bool?
    let effort: String?
}

func resolveReasoningSelection(
    capability: LLMReasoningCapability,
    currentEnabled: Bool?,
    currentEffort: String?
) -> ReasoningSelectionResolution {
    switch capability.kind {
    case .none:
        return ReasoningSelectionResolution(enabled: nil, effort: nil)
    case .toggle:
        return ReasoningSelectionResolution(
            enabled: currentEnabled ?? capability.defaultEnabled,
            effort: nil
        )
    case .effort:
        let supportedEfforts = capability.supportedEfforts
        let fallbackEffort = capability.defaultEffort.flatMap { defaultEffort in
            supportedEfforts.contains(defaultEffort) ? defaultEffort : nil
        } ?? supportedEfforts.first
        let resolvedEffort = currentEffort.flatMap { effort in
            supportedEfforts.contains(effort) ? effort : nil
        } ?? fallbackEffort
        return ReasoningSelectionResolution(enabled: nil, effort: resolvedEffort)
    }
}

func reasoningEffortDisplayName(_ effort: String) -> String {
    let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch normalized {
    case "xhigh":
        return "Extra High"
    default:
        return normalized
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

/// Configuration for send key behavior
enum SendKeyMode: String, CaseIterable, Identifiable {
    case returnKey = "Return"
    case commandReturn = "⌘ + Return"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .returnKey:
            return "Press Return to send"
        case .commandReturn:
            return "Press ⌘ + Return to send"
        }
    }
}

/// Main prompt bar view combining all input components
struct PromptBar: View {
    
    @Environment(\.colorScheme) var colorScheme
    @Query private var providers: [LLMProviderRecord]
    
    // Text state
    @Binding var text: String
    @State private var insertionPoint: Int = 0
    
    // Attachments state
    @Binding var attachments: [PromptAttachment]
    var ghostSuggestions: [PromptContextSuggestion] = []
    var onRemoveAttachment: ((PromptAttachment) -> Void)? = nil
    var onPromoteGhostSuggestion: ((PromptContextSuggestion) -> Void)? = nil
    
    // Model selection state
    @Binding var selectedProviderId: String
    @Binding var selectedModelId: String
    @Binding var reasoningEnabled: Bool?
    @Binding var reasoningEffort: String?
    
    // Copy count selection state
    @Binding var copyCount: TaskCopyCount
    @Binding var useMultipleModels: Bool
    @Binding var multiModelSelections: [PromptModelSelection]
    
    // Mentioned skill names (populated on submit)
    @Binding var mentionedSkillNames: [String]
    
    // Send key configuration
    @AppStorage("useCommandReturn") private var useCommandReturn: Bool = true
    @AppStorage("workerModelProviderId") private var workerModelProviderId: String?
    @AppStorage("workerModelId") private var workerModelId: String?
    
    // Plan mode toggle
    @Binding var planFirstEnabled: Bool
    
    // Submit callback
    var onSubmit: () async -> Void
    
    // Focus state
    @FocusState private var isFocused: Bool
    @State private var keyEventMonitor: Any?
    
    // Loading state
    @Binding var isSubmitting: Bool
    
    // Mention suggestions state
    @StateObject private var mentionProvider = MentionSuggestionsProvider()
    @StateObject private var mentionPanelController = MentionSuggestionsPanelController()
    @StateObject private var mentionInsertionController = MentionInsertionController()
    @State private var mentionQuery: MentionQuery?
    @State private var mentionScreenPosition: CGPoint?
    @State private var quickLookURL: URL?
    @State private var quickLookURLSnapshot: [URL] = []
    @State private var isReasoningControlVisible: Bool = false
    
    // Tips
    private let attachFilesTip = AttachFilesTip()
    private let batchExecutionTip = BatchExecutionTip()
    private let skillsMentionTip = SkillsMentionTip()
    private let planModeTip = PlanModeTip()
    
    // Visual configuration
    private let cornerRadius: CGFloat = 16
    
    private var rect: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
    
    private var outlineColor: Color {
        isFocused ? .accentColor : .primary.opacity(0.3)
    }
    
    private var placeholderText: String {
        let sendKeyDescription = useCommandReturn
            ? String(localized: "Command + Return")
            : String(localized: "Return")
        return String(localized: "Enter a message. Press \(sendKeyDescription) to send.")
    }
    
    private var hasAttachmentPreviews: Bool {
        !attachments.isEmpty || !ghostSuggestions.isEmpty
    }
    
    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasWorkerModelConfigured: Bool {
        guard let workerModelProviderId,
              let workerModelId else { return false }
        return !workerModelProviderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !workerModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasExecutionTarget: Bool {
        if useMultipleModels {
            return !multiModelSelections.isEmpty
        }
        return !selectedProviderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var showMentionSuggestions: Bool {
        // Only show when there's a query with at least one character after @
        guard let query = mentionQuery, !query.query.isEmpty else { return false }
        return !mentionProvider.suggestions.isEmpty
    }
    
    /// Calculates the minimum height for the input container based on number of lines
    private var inputMinHeight: CGFloat {
        let lineCount = max(1, text.components(separatedBy: .newlines).count)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        // Use proper line height: ascender + descender + leading
        let lineHeight = font.ascender - font.descender + font.leading
        let effectiveLineCount = min(lineCount, 4)
        return CGFloat(effectiveLineCount) * lineHeight
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Main input container
            mainInputContainer
            // Attachment previews (shown above the input if there are attachments)
            if hasAttachmentPreviews {
                PromptAttachmentPreviewList(
                    attachments: $attachments,
                    ghostSuggestions: ghostSuggestions,
                    onRemoveAttachment: onRemoveAttachment,
                    onPromoteGhostSuggestion: onPromoteGhostSuggestion,
                    onOpenAttachment: { url in
                        openQuickLook(for: url)
                    }
                )
                .padding(.top, 6)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .animation(.easeInOut(duration: 0.2), value: hasAttachmentPreviews)
        .animation(.easeInOut(duration: 0.15), value: inputMinHeight)
        .quickLookPreview($quickLookURL, in: quickLookURLsForPresentation)
        .onAppear {
            setupKeyEventMonitor()
            setupMentionPanel()
            // Initialize mention provider with current attachments
            mentionProvider.updateAttachments(attachments)
        }
        .onDisappear {
            removeKeyEventMonitor()
            mentionPanelController.hide()
        }
        .onChange(of: mentionQuery) { _, newQuery in
            // Filter suggestions when query changes
            mentionPanelController.resetSelection()
            if let query = newQuery {
                mentionProvider.filter(query: query.query)
                // Track @ mention for tips
                TipStore.shared.donateAtMentionTyped()
            } else {
                mentionPanelController.hide()
            }
        }
        .onChange(of: mentionProvider.suggestions) { _, newSuggestions in
            // Update panel when suggestions change
            if !newSuggestions.isEmpty, mentionScreenPosition != nil, showMentionSuggestions, let query = mentionQuery {
                mentionPanelController.suggestions = newSuggestions
                mentionPanelController.currentQueryRange = query.range
                mentionPanelController.show(at: mentionScreenPosition!, in: NSApp.keyWindow ?? NSApp.mainWindow)
            } else {
                mentionPanelController.hide()
            }
        }
        .onChange(of: mentionScreenPosition) { _, newPosition in
            // Update panel position when caret moves
            if let position = newPosition, showMentionSuggestions, let query = mentionQuery {
                mentionPanelController.suggestions = mentionProvider.suggestions
                mentionPanelController.currentQueryRange = query.range
                mentionPanelController.show(at: position, in: NSApp.keyWindow ?? NSApp.mainWindow)
            }
        }
        .onChange(of: attachments) { _, newAttachments in
            // Update mention provider with current attachments
            mentionProvider.updateAttachments(newAttachments)
        }
    }
    
    // MARK: - Main Input Container
    
    private var mainInputContainer: some View {
        HStack(alignment: .center, spacing: 0) {
            // LEFT: Attachment button (vertically centered)
            PromptAttachmentButton { urls in
                for url in urls {
                    await addAttachment(url)
                    TipStore.shared.donateFileAttached()
                }
            }
            .frame(width: 24)
            .padding(.trailing, 4)
            .popoverTip(attachFilesTip, arrowEdge: .bottom)
            
            .padding(.leading, 8)
            // CENTER: Text field + model picker (leading aligned)
            VStack(
                alignment: .leading,
                spacing: 6.5
            ) {
                // Text editor
                PromptTextEditor(
                    text: $text,
                    insertionPoint: $insertionPoint,
                    placeholder: placeholderText,
                    onFileDrop: { url in
                        Task {
                            await addAttachment(url)
                            TipStore.shared.donateFileAttached()
                        }
                    },
                    onMentionQuery: { query, screenPosition in
                        mentionQuery = query
                        mentionScreenPosition = screenPosition
                    },
                    mentionInsertionController: mentionInsertionController
                )
                .frame(minHeight: inputMinHeight)
                .focused($isFocused)
                .padding(.vertical, 1)
                .popoverTip(skillsMentionTip, arrowEdge: .top)
                
                // Model picker, copy count selector, and plan toggle
                HStack(spacing: 8) {
                    PromptModelButton(
                        selectedProviderId: $selectedProviderId,
                        selectedModelId: $selectedModelId,
                        reasoningEnabled: $reasoningEnabled,
                        reasoningEffort: $reasoningEffort,
                        copyCount: $copyCount,
                        useMultipleModels: $useMultipleModels,
                        multiModelSelections: $multiModelSelections,
                        providers: Array(providers),
                        isFocused: isFocused
                    )
                    
                    if !useMultipleModels {
                        PromptReasoningButton(
                            selectedProviderId: $selectedProviderId,
                            selectedModelId: $selectedModelId,
                            reasoningEnabled: $reasoningEnabled,
                            reasoningEffort: $reasoningEffort,
                            isVisible: $isReasoningControlVisible,
                            providers: Array(providers),
                            isFocused: isFocused
                        )

                        PromptCopyCountButton(
                            copyCount: $copyCount,
                            isFocused: isFocused
                        )
                        .padding(.leading, isReasoningControlVisible ? 0 : -8)
                        .popoverTip(batchExecutionTip, arrowEdge: .bottom)
                    }
                    
                    // Plan First toggle (rightmost)
                    PlanFirstToggle(
                        isEnabled: $planFirstEnabled,
                        isFocused: isFocused
                    )
                    .popoverTip(planModeTip, arrowEdge: .bottom)
                }
            }
            .padding(.vertical, 7)
            .padding(.top, 1)
            .layoutPriority(1) // Ensure text field gets space priority
            
            Spacer(minLength: 8)
            
            // RIGHT: Send button (vertically centered)
            if hasText {
                sendButton
                    .padding(.trailing, 8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: hasText)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(rect)
        .overlay(
            rect
                .stroke(style: StrokeStyle(lineWidth: 1))
                .foregroundStyle(outlineColor)
        )
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
    }
    
    // MARK: - Send Button
    
    private var sendButton: some View {
        Button {
            Task { await submitIfValid() }
        } label: {
            Image(systemName: isSubmitting ? "hourglass" : "arrow.up.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(isSubmitting ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting || !hasExecutionTarget || !hasWorkerModelConfigured)
        .help(sendButtonHelpText)
    }
    
    // MARK: - Helpers
    
    private func addAttachment(_ url: URL) async {
        // Check if already attached
        guard !attachments.contains(where: { $0.url == url }) else { return }
        
        let attachment = PromptAttachment(url: url)
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.2)) {
                attachments.append(attachment)
            }
        }
    }
    
    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard error == nil,
                          let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        return
                    }
                    
                    Task {
                        await addAttachment(url)
                    }
                }
            }
        }
        
        return handled
    }
    
    private func submitIfValid() async {
        // Get the resolved text with file paths replacing mention attachments
        let resolvedText = mentionInsertionController.getResolvedText()
        let trimmed = resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard hasExecutionTarget else { return }
        guard hasWorkerModelConfigured else { return }
        
        // Get mentioned skill names before clearing
        mentionedSkillNames = mentionInsertionController.getMentionedSkillNames()
        
        // Update the text binding with resolved paths before submission
        text = resolvedText
        
        await onSubmit()
        
        // Clear the text view directly after submission
        mentionInsertionController.clearTextView()
    }

    private var sendButtonHelpText: String {
        if useMultipleModels && multiModelSelections.isEmpty {
            return "Select at least one model when Use Multiple Models is enabled"
        }
        if !hasWorkerModelConfigured {
            return "Configure worker provider + model in onboarding or Settings → Providers"
        }
        return "Send (\(useCommandReturn ? "⌘ + Return" : "Return"))"
    }

    private var quickLookPreviewURLs: [URL] {
        var ordered: [URL] = []
        var seenPaths = Set<String>()

        for attachment in attachments {
            let normalizedPath = attachment.url.path
            if seenPaths.insert(normalizedPath).inserted {
                ordered.append(attachment.url)
            }
        }

        for suggestion in ghostSuggestions {
            let path = suggestion.sourcePathOrHandle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/") else { continue }
            let url = URL(fileURLWithPath: path)
            if seenPaths.insert(url.path).inserted {
                ordered.append(url)
            }
        }

        return ordered
    }

    private var quickLookURLsForPresentation: [URL] {
        if quickLookURL != nil {
            return quickLookURLSnapshot.isEmpty ? quickLookPreviewURLs : quickLookURLSnapshot
        }
        return quickLookPreviewURLs
    }

    private func openQuickLook(for url: URL) {
        let currentURLs = quickLookPreviewURLs
        if currentURLs.contains(where: { $0.path == url.path }) {
            quickLookURLSnapshot = currentURLs
        } else {
            quickLookURLSnapshot = [url]
        }
        quickLookURL = url
    }
    
    // MARK: - Mention Panel
    
    private func setupMentionPanel() {
        mentionPanelController.onSelect = { [self] suggestion, range in
            // Insert the mention directly using the controller with the stored range
            mentionInsertionController.insert(suggestion: suggestion, at: range)
            
            // Add files as attachments (but not skills)
            if suggestion.type != .skill, let url = suggestion.url {
                Task {
                    await addAttachment(url)
                }
            }
            
            // Clear state
            mentionQuery = nil
            mentionScreenPosition = nil
        }
    }
    
    private func showMentionPanelIfNeeded() {
        guard let screenPosition = mentionScreenPosition,
              showMentionSuggestions else {
            mentionPanelController.hide()
            return
        }
        
        mentionPanelController.suggestions = mentionProvider.suggestions
        mentionPanelController.show(at: screenPosition, in: NSApp.keyWindow ?? NSApp.mainWindow)
    }
    
    // MARK: - Key Event Handling
    
    private func setupKeyEventMonitor() {
        removeKeyEventMonitor()
        
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if isFocused, event.window?.isMainWindow == true {
                if handleKeyDownEvent(event) {
                    return nil // Handled, suppress
                }
            }
            return event
        }
    }
    
    private func removeKeyEventMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }
    
    @discardableResult
    private func handleKeyDownEvent(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        
        // Handle mention suggestion navigation
        if showMentionSuggestions {
            let hasModifiers = !event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty
            
            switch keyCode {
            case 125: // Down arrow
                mentionPanelController.moveSelectionDown()
                return true
                
            case 126: // Up arrow
                mentionPanelController.moveSelectionUp()
                return true
                
            case 36: // Return - select current suggestion (only without modifiers)
                if !hasModifiers {
                    mentionPanelController.selectCurrent()
                    return true
                }
                // Let modified Return (Shift/Option) fall through to insert newline
                
            case 48: // Tab - select current suggestion
                mentionPanelController.selectCurrent()
                return true
                
            case 53: // Escape - dismiss suggestions
                mentionPanelController.hide()
                mentionQuery = nil
                mentionScreenPosition = nil
                return true
                
            default:
                break
            }
        }
        
        // Only interested in Return/Enter for sending
        let isReturnKeyDown = (keyCode == 36) || (keyCode == 76)
        guard isReturnKeyDown else { return false }
        
        let isCommandKeyDown = event.modifierFlags.contains(.command)
        let isShiftKeyDown = event.modifierFlags.contains(.shift)
        let isOptionKeyDown = event.modifierFlags.contains(.option)
        let noModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
        
        if isCommandKeyDown && useCommandReturn {
            // Send if command key is down and required
            Task { await submitIfValid() }
            return true
        } else if !useCommandReturn && noModifiers {
            // Send if command key is not required
            Task { await submitIfValid() }
            return true
        } else if isShiftKeyDown || isOptionKeyDown || (useCommandReturn && noModifiers) {
            // Insert newline at cursor directly in the text view
            mentionInsertionController.insertNewline()
            return true
        }
        
        return false
    }
}

struct PromptReasoningButton: View {
    @Binding var selectedProviderId: String
    @Binding var selectedModelId: String
    @Binding var reasoningEnabled: Bool?
    @Binding var reasoningEffort: String?
    @Binding var isVisible: Bool
    let providers: [LLMProviderRecord]
    var isFocused: Bool = false

    @State private var availableModels: [LLMProviderModel] = []
    @State private var anchorView: NSView?

    private var selectedProvider: LLMProviderRecord? {
        providers.first(where: { $0.id == selectedProviderId })
    }

    private var selectedModel: LLMProviderModel? {
        availableModels.first(where: { $0.id == selectedModelId })
    }

    private var capability: LLMReasoningCapability {
        selectedModel?.reasoningCapability ?? .none
    }

    private var isActive: Bool {
        switch capability.kind {
        case .none:
            return false
        case .toggle:
            return reasoningEnabled ?? capability.defaultEnabled
        case .effort:
            return true
        }
    }

    private var selectedTextColor: Color {
        if isFocused {
            return .accentColor
        }
        return .primary.opacity(0.5)
    }

    private var selectedBackgroundColor: Color {
        if isFocused {
            return Color.accentColor.opacity(0.3)
        }
        return .white.opacity(0.0001)
    }

    private var unselectedTextColor: Color {
        .secondary.opacity(0.8)
    }

    private var unselectedBorderColor: Color {
        return .primary.opacity(0.3)
    }

    private var menuLabelColor: NSColor {
        isFocused ? .controlAccentColor : NSColor(Color.primary.opacity(0.5))
    }

    private var selectedEffortLabel: String {
        let resolved = resolveReasoningSelection(
            capability: capability,
            currentEnabled: reasoningEnabled,
            currentEffort: reasoningEffort
        )
        guard let effort = resolved.effort else {
            return "Reason"
        }
        return reasoningEffortDisplayName(effort)
    }

    private var loadToken: String {
        let providerToken = providers.map(\.id).joined(separator: "|")
        return "\(selectedProviderId)::\(providerToken)"
    }

    var body: some View {
        ZStack {
            switch capability.kind {
            case .none:
                EmptyView()
            case .toggle:
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        reasoningEnabled = !(reasoningEnabled ?? capability.defaultEnabled)
                    }
                } label: {
                    capsuleLabel(
                        systemImage: "brain.head.profile",
                        title: "Reason"
                    )
                }
                .buttonStyle(.plain)
            case .effort:
                effortMenuButton
            }
        }
        .task(id: loadToken) {
            loadModels()
        }
        .onChange(of: selectedModelId) { _, _ in
            synchronizeSelection()
        }
        .onChange(of: availableModels.map(\.id)) { _, _ in
            synchronizeSelection()
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isActive)
    }

    private var effortMenuButton: some View {
        HStack(spacing: 0) {
            CopyCountAnchorRepresentable(view: $anchorView)
                .frame(width: 0.1, height: 0.1)

            HStack(spacing: 4) {
                Image(systemName: "brain.head.profile")
                    .font(.caption)
                Text(selectedEffortLabel)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(selectedTextColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            Rectangle()
                .fill(isFocused ? selectedBackgroundColor : unselectedBorderColor)
                .frame(width: 0.5, height: 18)

            CopyCountMenuIcon(
                iconName: "chevron.down",
                color: menuLabelColor,
                menu: NSMenu.fromReasoningEffortOptions(options: capability.supportedEfforts) { effort in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        reasoningEffort = effort
                    }
                },
                anchorViewProvider: {
                    anchorView
                }
            )
            .frame(width: 18, height: 18)
            .padding(.trailing, 2)
        }
        .background {
            ZStack {
                Capsule()
                    .fill(selectedBackgroundColor)
                Capsule()
                    .stroke(style: StrokeStyle(lineWidth: 0.3))
                    .fill(isFocused ? selectedBackgroundColor : unselectedBorderColor)
            }
        }
    }

    @ViewBuilder
    private func capsuleLabel(systemImage: String, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption)
            Text(title)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(isActive ? selectedTextColor : unselectedTextColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            if isActive {
                ZStack {
                    Capsule()
                        .fill(selectedBackgroundColor)
                    Capsule()
                        .stroke(style: StrokeStyle(lineWidth: 0.3))
                        .fill(isFocused ? selectedBackgroundColor : unselectedBorderColor)
                }
            } else {
                Capsule()
                    .stroke(unselectedBorderColor, lineWidth: 0.5)
            }
        }
    }

    private func loadModels() {
        guard let provider = selectedProvider else {
            availableModels = []
            synchronizeSelection()
            return
        }

        let apiKey: String
        if provider.authMode == .apiKey {
            guard let stored = provider.retrieveAPIKey() else {
                availableModels = []
                synchronizeSelection()
                return
            }
            apiKey = stored
        } else {
            apiKey = ""
        }

        Task {
            do {
                let config = provider.makeLLMConfiguration(
                    model: provider.backendMode == .codexOAuth ? "gpt-5-codex" : "model-listing-placeholder",
                    apiKey: apiKey
                )
                let client = LLMService.shared.createClient(from: config)
                let models = try await client.listModelsDetailed()
                await MainActor.run {
                    availableModels = models
                    synchronizeSelection()
                }
            } catch {
                await MainActor.run {
                    availableModels = []
                    synchronizeSelection()
                }
            }
        }
    }

    private func synchronizeSelection() {
        isVisible = capability.kind != .none
        let resolution = resolveReasoningSelection(
            capability: capability,
            currentEnabled: reasoningEnabled,
            currentEffort: reasoningEffort
        )
        reasoningEnabled = resolution.enabled
        reasoningEffort = resolution.effort
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State var text = ""
        @State var attachments: [PromptAttachment] = []
        @State var providerId = ""
        @State var modelId = ""
        @State var copyCount: TaskCopyCount = .one
        @State var useMultipleModels = false
        @State var multiModelSelections: [PromptModelSelection] = []
        @State var isSubmitting = false
        @State var mentionedSkills: [String] = []
        @State var planFirst = false
        
        var body: some View {
            VStack {
                Spacer()
                
                PromptBar(
                    text: $text,
                    attachments: $attachments,
                    ghostSuggestions: [],
                    selectedProviderId: $providerId,
                    selectedModelId: $modelId,
                    reasoningEnabled: .constant(nil),
                    reasoningEffort: .constant(nil),
                    copyCount: $copyCount,
                    useMultipleModels: $useMultipleModels,
                    multiModelSelections: $multiModelSelections,
                    mentionedSkillNames: $mentionedSkills,
                    planFirstEnabled: $planFirst,
                    onSubmit: {
                        isSubmitting = true
                        try? await Task.sleep(for: .seconds(1))
                        isSubmitting = false
                        text = ""
                        attachments = []
                    },
                    isSubmitting: $isSubmitting
                )
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
            }
            .frame(width: 600, height: 300)
            .background(Color(nsColor: .windowBackgroundColor))
            .environmentObject(SchedulerService.shared)
            .modelContainer(for: [LLMProviderRecord.self, ScheduledTask.self], inMemory: true)
        }
    }
    
    return PreviewWrapper()
}
