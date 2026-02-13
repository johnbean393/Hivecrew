//
//  ProviderRowView.swift
//  Hivecrew
//
//  Row for a configured LLM provider
//

import Combine
import SwiftUI

struct ProviderRow: View {
    let provider: LLMProviderRecord
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSetDefault: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: providerIcon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(provider.displayName)
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
                } else {
                    Text("OpenAI API")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                Image(systemName: provider.hasAPIKey ? "key.fill" : "key")
                    .foregroundStyle(provider.hasAPIKey ? .green : .orange)
                Text(provider.hasAPIKey ? "Configured" : "No Key")
                    .font(.caption)
                    .foregroundStyle(provider.hasAPIKey ? Color.secondary : Color.orange)
            }
            
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
    }
    
    private var providerIcon: String {
        if provider.baseURL?.contains("azure") == true {
            return "cloud.fill"
        } else if provider.baseURL?.contains("localhost") == true {
            return "desktopcomputer"
        } else if provider.baseURL != nil {
            return "server.rack"
        } else {
            return "cpu"
        }
    }
}
