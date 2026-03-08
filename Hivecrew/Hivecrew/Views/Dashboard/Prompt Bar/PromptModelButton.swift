//
//  PromptModelButton.swift
//  Hivecrew
//
//  Capsule-style model picker button with popover selection
//

import SwiftUI
import HivecrewLLM

/// A capsule-styled button for selecting the LLM model, similar to the Search button design
struct PromptModelButton: View {
    
    @Binding var selectedProviderId: String
    @Binding var selectedModelId: String
    @Binding var reasoningEnabled: Bool?
    @Binding var reasoningEffort: String?
    @Binding var serviceTier: LLMServiceTier?
    @Binding var copyCount: TaskCopyCount
    @Binding var useMultipleModels: Bool
    @Binding var multiModelSelections: [PromptModelSelection]
    let providers: [LLMProviderRecord]
    var isFocused: Bool = false
    
    @State private var showingPopover: Bool = false
    
    var selectedProvider: LLMProviderRecord? {
        providers.first(where: { $0.id == selectedProviderId })
    }

    var isCodexProvider: Bool {
        selectedProvider?.backendMode == .codexOAuth
    }
    
    var displayText: String {
        if useMultipleModels {
            if multiModelSelections.isEmpty {
                return "Select models"
            }
            if multiModelSelections.count == 1, let selection = multiModelSelections.first {
                return selection.modelId
            }
            let parts = multiModelSelections.map { selection in
                "\(selection.modelId)"
            }
            return parts.joined(separator: ", ")
        }
        
        if selectedModelId.isEmpty {
            return selectedProvider?.displayName ?? "Select Model"
        }
        return selectedModelId
    }
    
    var hasValidSelection: Bool {
        if useMultipleModels {
            return !multiModelSelections.isEmpty
        }
        return !selectedProviderId.isEmpty && !selectedModelId.isEmpty
    }

    var showsFastModeBadge: Bool {
        guard isCodexProvider else { return false }
        if useMultipleModels {
            let providerSelections = multiModelSelections.filter { $0.providerId == selectedProviderId }
            if !providerSelections.isEmpty {
                if providerSelections.allSatisfy({ $0.serviceTier == .priority }) {
                    return true
                }
            }
        }
        return serviceTier == .priority
    }
    
    /// Use accent color only when focused and has a valid selection
    var textColor: Color {
        if isFocused && hasValidSelection {
            return .accentColor
        }
        return (hasValidSelection ? Color.primary : Color.secondary).opacity(0.5)
    }
    
    var bubbleColor: Color {
        if isFocused && hasValidSelection {
            return Color.accentColor.opacity(0.3)
        }
        return .white.opacity(0.0001)
    }
    
    var bubbleBorderColor: Color {
        if isFocused && hasValidSelection {
            return bubbleColor
        }
        return .primary.opacity(0.3)
    }
    
    var body: some View {
        Button {
            showingPopover = true
        } label: {
            HStack(spacing: 4) {
                modelIcon
                Text(displayText)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                capsuleBackground
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            PromptModelPopover(
                selectedProviderId: $selectedProviderId,
                selectedModelId: $selectedModelId,
                reasoningEnabled: $reasoningEnabled,
                reasoningEffort: $reasoningEffort,
                serviceTier: $serviceTier,
                copyCount: $copyCount,
                useMultipleModels: $useMultipleModels,
                multiModelSelections: $multiModelSelections,
                providers: providers,
                isPresented: $showingPopover
            )
        }
    }
    
    private var capsuleBackground: some View {
        ZStack {
            Capsule()
                .fill(bubbleColor)
            Capsule()
                .stroke(style: StrokeStyle(lineWidth: 0.3))
                .fill(bubbleBorderColor)
        }
    }

    private var modelIcon: some View {
        ZStack {
            Image(systemName: "brain")
                .font(.caption)
                .opacity(showsFastModeBadge ? 0.6 : 1)

            if showsFastModeBadge {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7, weight: .bold))
                    .offset(x: 4, y: -4)
            }
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State private var providerId = "test"
        @State private var modelId = "moonshotai/kimi-k2.5"
        @State private var serviceTier: LLMServiceTier?
        @State private var copyCount: TaskCopyCount = .one
        @State private var useMultipleModels = false
        @State private var multiSelections: [PromptModelSelection] = []

        var body: some View {
            PromptModelButton(
                selectedProviderId: $providerId,
                selectedModelId: $modelId,
                reasoningEnabled: .constant(nil),
                reasoningEffort: .constant(nil),
                serviceTier: $serviceTier,
                copyCount: $copyCount,
                useMultipleModels: $useMultipleModels,
                multiModelSelections: $multiSelections,
                providers: []
            )
            .padding()
        }
    }

    return PreviewWrapper()
}
