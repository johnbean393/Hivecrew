//
//  UsernameRowView.swift
//  Hivecrew
//
//  Displays and copies non-obfuscated usernames
//

import SwiftUI

struct UsernameRow: View {
    let label: String
    let username: String
    
    @State private var copied = false
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            
            Text(username)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(username, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .accentColor)
            }
            .buttonStyle(.borderless)
            .help("Copy username")
        }
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
