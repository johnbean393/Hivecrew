//
//  HivecrewTipViewStyle.swift
//  Hivecrew
//
//  Custom tip view styling for consistent appearance
//

import SwiftUI
import TipKit

/// Custom tip view style matching Hivecrew's design language
struct HivecrewTipViewStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            configuration.image?
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            
            VStack(alignment: .leading, spacing: 4) {
                // Title
                configuration.title
                    .font(.headline)
                
                // Message
                configuration.message?
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                // Actions (if any)
                HStack(spacing: 8) {
                    ForEach(configuration.actions) { action in
                        Button(action: action.handler) {
                            action.label()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
            
            Spacer()
            
            // Close button
            Button {
                configuration.tip.invalidate(reason: .tipClosed)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        }
    }
}

/// Compact tip style for inline tips
struct CompactTipViewStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.image?
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            
            configuration.title
                .font(.caption)
            
            Spacer()
            
            Button {
                configuration.tip.invalidate(reason: .tipClosed)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(Color.accentColor.opacity(0.1))
        }
    }
}

/// Popover tip style for button tips
struct PopoverTipViewStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                configuration.image?
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                
                configuration.title
                    .font(.headline)
                
                Spacer()
                
                Button {
                    configuration.tip.invalidate(reason: .tipClosed)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            configuration.message?
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: 280)
    }
}
