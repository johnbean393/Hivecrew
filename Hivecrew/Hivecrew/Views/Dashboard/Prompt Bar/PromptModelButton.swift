//
//  PromptModelButton.swift
//  Hivecrew
//
//  Capsule-style model picker button with popover selection
//

import SwiftUI

/// A capsule-styled button for selecting the LLM model, similar to the Search button design
struct PromptModelButton: View {
    
    @Binding var selectedProviderId: String
    @Binding var selectedModelId: String
    let providers: [LLMProviderRecord]
    var isFocused: Bool = false
    
    @State private var showingPopover: Bool = false
    
    var selectedProvider: LLMProviderRecord? {
        providers.first(where: { $0.id == selectedProviderId })
    }
    
    var displayText: String {
        if selectedModelId.isEmpty {
            return selectedProvider?.displayName ?? "Select Model"
        } else {
            return selectedModelId
        }
    }
    
    var hasValidSelection: Bool {
        !selectedProviderId.isEmpty && !selectedModelId.isEmpty
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
                Image(systemName: "brain")
                    .font(.caption)
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
}

// MARK: - Preview

#Preview {
    PromptModelButton(
        selectedProviderId: .constant("test"),
        selectedModelId: .constant("moonshotai/kimi-k2.5"),
        providers: []
    )
    .padding()
}
