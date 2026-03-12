//
//  MentionSuggestionsPanel.swift
//  Hivecrew
//
//  NSPanel-based overlay for displaying @mention suggestions near the text caret
//

import AppKit
import Combine
import SwiftUI

/// Controller for the floating mention suggestions panel
@MainActor
final class MentionSuggestionsPanelController: ObservableObject {
    
    private var panel: NSPanel?
    private var hostingView: NSHostingView<MentionSuggestionsPanelContent>?
    
    @Published var suggestions: [MentionSuggestion] = []
    @Published var selectedIndex: Int = 0
    
    /// The current query range - stored when panel is shown so it's available on selection
    var currentQueryRange: NSRange?
    
    /// Callback when a suggestion is selected, includes the range to replace
    var onSelect: ((MentionSuggestion, NSRange) -> Void)?
    
    /// Show the suggestions panel at the specified screen position
    func show(at screenPoint: CGPoint, in parentWindow: NSWindow?) {
        guard !suggestions.isEmpty else {
            hide()
            return
        }
        
        if panel == nil {
            createPanel()
        }
        
        guard let panel = panel else { return }
        
        // Update the content
        updateContent()
        
        // Calculate panel size based on content
        let itemHeight: CGFloat = 40
        let sectionHeaderHeight: CGFloat = 24
        let padding: CGFloat = 8
        let sectionCount = MentionSuggestion.displayOrder.filter { type in
            suggestions.contains { $0.type == type }
        }.count
        let contentHeight = CGFloat(suggestions.count) * itemHeight
            + CGFloat(sectionCount) * sectionHeaderHeight
            + padding
        let panelHeight = min(contentHeight, 420)
        let panelWidth: CGFloat = 340
        
        // Position panel below the caret
        let panelOrigin = CGPoint(
            x: screenPoint.x,
            y: screenPoint.y - panelHeight - 4
        )
        
        panel.setFrame(
            NSRect(origin: panelOrigin, size: CGSize(width: panelWidth, height: panelHeight)),
            display: true
        )
        
        // Keep the panel attached to the editor window, but avoid re-adding it on
        // every keystroke or accidentally making the panel its own parent.
        if let parentWindow, parentWindow !== panel {
            if panel.parent !== parentWindow {
                if let existingParent = panel.parent {
                    existingParent.removeChildWindow(panel)
                }
                parentWindow.addChildWindow(panel, ordered: .above)
            }
        }
        
        panel.orderFront(nil)
    }
    
    /// Hide the suggestions panel
    func hide() {
        guard let panel = panel else { return }
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        panel.orderOut(nil)
    }
    
    /// Update selection index
    func moveSelectionUp() {
        guard !suggestions.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + suggestions.count) % suggestions.count
        updateContent()
    }
    
    func moveSelectionDown() {
        guard !suggestions.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % suggestions.count
        updateContent()
    }
    
    func selectCurrent() {
        guard selectedIndex < suggestions.count,
              let range = currentQueryRange else { return }
        let suggestion = suggestions[selectedIndex]
        onSelect?(suggestion, range)
        hide()
    }
    
    func resetSelection() {
        selectedIndex = 0
        // Only update content if panel exists
        if panel != nil {
            updateContent()
        }
    }
    
    // MARK: - Private
    
    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        
        self.panel = panel
        
        // Create the hosting view immediately
        let content = MentionSuggestionsPanelContent(
            suggestions: suggestions,
            selectedIndex: selectedIndex,
            onSelect: { [weak self] suggestion in
                guard let self = self, let range = self.currentQueryRange else { return }
                self.onSelect?(suggestion, range)
                self.hide()
            },
            onHover: { [weak self] index in
                self?.selectedIndex = index
                self?.updateContent()
            }
        )
        let hostingView = NSHostingView(rootView: content)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        self.hostingView = hostingView
    }
    
    private func updateContent() {
        guard let hostingView = hostingView else { return }
        
        let content = MentionSuggestionsPanelContent(
            suggestions: suggestions,
            selectedIndex: selectedIndex,
            onSelect: { [weak self] suggestion in
                guard let self = self, let range = self.currentQueryRange else { return }
                self.onSelect?(suggestion, range)
                self.hide()
            },
            onHover: { [weak self] index in
                self?.selectedIndex = index
                self?.updateContent()
            }
        )
        
        hostingView.rootView = content
    }
}

/// SwiftUI content for the suggestions panel
struct MentionSuggestionsPanelContent: View {
    
    let suggestions: [MentionSuggestion]
    let selectedIndex: Int
    let onSelect: (MentionSuggestion) -> Void
    let onHover: (Int) -> Void
    
    private let itemHeight: CGFloat = 40
    private let sectionHeaderHeight: CGFloat = 24
    private let cornerRadius: CGFloat = 10
    
    /// Separate suggestions by type
    private var attachments: [MentionSuggestion] {
        suggestions.filter { $0.type == .attachment }
    }
    
    private var deliverables: [MentionSuggestion] {
        suggestions.filter { $0.type == .deliverable }
    }

    private var tasks: [MentionSuggestion] {
        suggestions.filter { $0.type == .task }
    }
    
    private var skills: [MentionSuggestion] {
        suggestions.filter { $0.type == .skill }
    }
    
    private var environmentVariables: [MentionSuggestion] {
        suggestions.filter { $0.type == .environmentVariable }
    }
    
    private var injectedFiles: [MentionSuggestion] {
        suggestions.filter { $0.type == .injectedFile }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Current Attachments section
                if !attachments.isEmpty {
                    SectionHeader(title: "Attachments")
                        .frame(height: sectionHeaderHeight)
                    
                    ForEach(Array(attachments.enumerated()), id: \.element.id) { index, suggestion in
                        let globalIndex = index
                        suggestionRow(suggestion, globalIndex: globalIndex)
                    }
                }
                
                // Recent Deliverables section
                if !deliverables.isEmpty {
                    SectionHeader(title: "Recent Deliverables")
                        .frame(height: sectionHeaderHeight)
                    
                    ForEach(Array(deliverables.enumerated()), id: \.element.id) { index, suggestion in
                        let globalIndex = attachments.count + index
                        suggestionRow(suggestion, globalIndex: globalIndex)
                    }
                }

                if !tasks.isEmpty {
                    SectionHeader(title: "Tasks")
                        .frame(height: sectionHeaderHeight)

                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, suggestion in
                        let globalIndex = attachments.count + deliverables.count + index
                        suggestionRow(suggestion, globalIndex: globalIndex)
                    }
                }
                
                // Skills section
                if !skills.isEmpty {
                    SectionHeader(title: "Skills")
                        .frame(height: sectionHeaderHeight)
                    
                    ForEach(Array(skills.enumerated()), id: \.element.id) { index, suggestion in
                        let globalIndex = attachments.count + deliverables.count + tasks.count + index
                        suggestionRow(suggestion, globalIndex: globalIndex)
                    }
                }
                
                // Environment Variables section
                if !environmentVariables.isEmpty {
                    SectionHeader(title: "Environment Variables")
                        .frame(height: sectionHeaderHeight)
                    
                    ForEach(Array(environmentVariables.enumerated()), id: \.element.id) { index, suggestion in
                        let globalIndex = attachments.count + deliverables.count + tasks.count + skills.count + index
                        suggestionRow(suggestion, globalIndex: globalIndex)
                    }
                }
                
                // Injected Files section
                if !injectedFiles.isEmpty {
                    SectionHeader(title: "Injected Files")
                        .frame(height: sectionHeaderHeight)
                    
                    ForEach(Array(injectedFiles.enumerated()), id: \.element.id) { index, suggestion in
                        let globalIndex = attachments.count + deliverables.count + tasks.count + skills.count + environmentVariables.count + index
                        suggestionRow(suggestion, globalIndex: globalIndex)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: MentionSuggestion, globalIndex: Int) -> some View {
        MentionSuggestionPanelRow(
            suggestion: suggestion,
            isSelected: globalIndex == selectedIndex
        )
        .frame(height: itemHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(suggestion)
        }
        .onHover { isHovering in
            if isHovering {
                onHover(globalIndex)
            }
        }
    }
}

/// Section header for suggestion groups
private struct SectionHeader: View {
    let title: String
    
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

/// Individual suggestion row for the panel
struct MentionSuggestionPanelRow: View {
    
    let suggestion: MentionSuggestion
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 10) {
            // Icon based on type
            switch suggestion.type {
            case .task:
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.blue)
            case .skill:
                Image(systemName: "sparkles")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.purple)
            case .environmentVariable:
                Image(systemName: "terminal")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.green)
            case .injectedFile:
                if let icon = suggestion.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.orange)
                }
            case .attachment, .deliverable:
                if let icon = suggestion.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: "doc")
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Name and detail
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                if let detail = suggestion.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            if let url = suggestion.url {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }) {
                    Text("Show in Finder")
                }
            }
        }
    }
    
}

/// NSVisualEffectView wrapper for SwiftUI
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
