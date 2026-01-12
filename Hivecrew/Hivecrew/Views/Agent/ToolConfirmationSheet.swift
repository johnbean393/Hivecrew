//
//  ToolConfirmationSheet.swift
//  Hivecrew
//
//  Modal for approving dangerous tool executions
//

import SwiftUI

/// A confirmation dialog for dangerous tool operations
struct ToolConfirmationSheet: View {
    let toolName: String
    let details: String
    let onApprove: () -> Void
    let onDeny: () -> Void
    
    @State private var countdown: Int = 5
    @State private var canApprove = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Warning icon
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            
            // Title
            Text("Confirm \(toolName)")
                .font(.title2)
                .fontWeight(.semibold)
            
            // Description
            Text("The agent wants to execute the following action:")
                .font(.callout)
                .foregroundStyle(.secondary)
            
            // Details box
            VStack(alignment: .leading, spacing: 8) {
                Text(toolName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                
                ScrollView {
                    Text(details)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            
            // Warning text
            Text("Review this action carefully before approving.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            // Buttons
            HStack(spacing: 16) {
                Button("Deny") {
                    onDeny()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button {
                    onApprove()
                } label: {
                    if canApprove {
                        Text("Approve")
                    } else {
                        Text("Approve (\(countdown))")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApprove)
            }
        }
        .padding(24)
        .frame(width: 450)
        .onAppear {
            startCountdown()
        }
    }
    
    private func startCountdown() {
        // Safety countdown before allowing approval
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            countdown -= 1
            if countdown <= 0 {
                timer.invalidate()
                canApprove = true
            }
        }
    }
}

#Preview {
    ToolConfirmationSheet(
        toolName: "Shell Command",
        details: "rm -rf ~/Documents/important_files",
        onApprove: {},
        onDeny: {}
    )
}
