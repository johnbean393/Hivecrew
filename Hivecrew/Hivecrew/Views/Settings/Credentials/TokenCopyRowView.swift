//
//  TokenCopyRowView.swift
//  Hivecrew
//
//  Displays token or revealed credential values with copy action
//

import SwiftUI

struct TokenCopyRow: View {
    let label: String
    let token: String
    var revealedValue: String? = nil
    var isPassword: Bool = false
    
    @State private var copied = false
    
    /// The value to display - either the revealed value or the token
    private var displayValue: String {
        revealedValue ?? token
    }
    
    /// Whether we're showing the real value
    private var isRevealed: Bool {
        revealedValue != nil
    }
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            
            if isRevealed {
                Text(displayValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Text("(actual)")
                    .font(.caption2)
                    .foregroundStyle(.green.opacity(0.7))
            } else {
                Text(token)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(displayValue, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .accentColor)
            }
            .buttonStyle(.borderless)
            .help(isRevealed ? "Copy actual value" : "Copy token")
        }
        .padding(6)
        .background(isRevealed ? Color.green.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
