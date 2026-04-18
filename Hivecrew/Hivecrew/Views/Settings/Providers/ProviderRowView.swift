//
//  ProviderRowView.swift
//  Hivecrew
//
//  Row for a configured LLM provider
//

import Combine
import HivecrewLLM
import SwiftUI

struct ProviderRow: View {
    let provider: LLMProviderRecord
    var showsDragHandle: Bool = false
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSetDefault: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }

            Image(systemName: providerIcon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(provider.displayLabel)
                        .fontWeight(.medium)
                    
                    if provider.isDefault {
                        Text("Default")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
                
                if let baseURL = provider.baseURL {
                    Text(baseURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if provider.isOAuthProvider {
                    Text(
                        provider.isOAuthAuthenticated
                            ? String(localized: "\(provider.displayLabel) • Connected")
                            : String(localized: "\(provider.displayLabel) • Not connected")
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("OpenAI API")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            Menu {
                Button("Edit") {
                    onEdit()
                }
                
                if !provider.isDefault {
                    Button("Set as Default") {
                        onSetDefault()
                    }
                }
                
                Divider()
                
                Button("Delete", role: .destructive) {
                    onDelete()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
    
    private var providerIcon: String {
        if provider.isOAuthProvider {
            return provider.isOAuthAuthenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark"
        }

        let normalizedBaseURL = provider.baseURL?.lowercased() ?? ""
        if normalizedBaseURL.contains("localhost") || normalizedBaseURL.contains("127.0.0.1") {
            return "desktopcomputer"
        }

        return "server.rack"
    }
}
