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
    
    // Model selection state
    @Binding var selectedProviderId: String
    @Binding var selectedModelId: String
    
    // Copy count selection state
    @Binding var copyCount: TaskCopyCount
    
    // Mentioned skill names (populated on submit)
    @Binding var mentionedSkillNames: [String]
    
    // Send key configuration
    @AppStorage("useCommandReturn") private var useCommandReturn: Bool = true
    
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
        let sendKeyDescription = useCommandReturn ? "Command + Return" : "Return"
        return "Enter a message. Press \(sendKeyDescription) to send."
    }
    
    private var hasAttachments: Bool {
        !attachments.isEmpty
    }
    
    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var showMentionSuggestions: Bool {
        // Only show when there's a query with at least one character after @
        guard let query = mentionQuery, !query.query.isEmpty else { return false }
        return !mentionProvider.suggestions.isEmpty
    }
    
    /// Calculates the minimum height for the input container based on number of lines
    private var inputMinHeight: CGFloat {
        let lineCount = max(1, text.components(separatedBy: .newlines).count)
        let lineHeight = NSFont.systemFont(
            ofSize: NSFont.systemFontSize
        ).capHeight
        if lineCount >= 4 {
            return lineHeight * 4
        }
        return CGFloat(lineCount) * lineHeight
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Main input container
            mainInputContainer
            // Attachment previews (shown above the input if there are attachments)
            if hasAttachments {
                PromptAttachmentPreviewList(attachments: $attachments)
                    .padding(.top, 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .animation(.easeInOut(duration: 0.2), value: hasAttachments)
        .animation(.easeInOut(duration: 0.15), value: inputMinHeight)
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
                        providers: Array(providers),
                        isFocused: isFocused
                    )
                    
                    PromptCopyCountButton(
                        copyCount: $copyCount,
                        isFocused: isFocused
                    )
                    .popoverTip(batchExecutionTip, arrowEdge: .bottom)
                    
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
        .disabled(isSubmitting || selectedProviderId.isEmpty)
        .help("Send (\(useCommandReturn ? "⌘ + Return" : "Return"))")
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
        guard !selectedProviderId.isEmpty else { return }
        
        // Get mentioned skill names before clearing
        mentionedSkillNames = mentionInsertionController.getMentionedSkillNames()
        
        // Update the text binding with resolved paths before submission
        text = resolvedText
        
        await onSubmit()
        
        // Clear the text view directly after submission
        mentionInsertionController.clearTextView()
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

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State var text = ""
        @State var attachments: [PromptAttachment] = []
        @State var providerId = ""
        @State var modelId = ""
        @State var copyCount: TaskCopyCount = .one
        @State var isSubmitting = false
        @State var mentionedSkills: [String] = []
        @State var planFirst = false
        
        var body: some View {
            VStack {
                Spacer()
                
                PromptBar(
                    text: $text,
                    attachments: $attachments,
                    selectedProviderId: $providerId,
                    selectedModelId: $modelId,
                    copyCount: $copyCount,
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
