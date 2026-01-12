//
//  TerminationConfirmationSheet.swift
//  Hivecrew
//
//  Confirmation dialog shown before app termination when work is in progress
//

import SwiftUI

/// Sheet shown when user tries to quit with active work
struct TerminationConfirmationSheet: View {
    @ObservedObject var terminationManager: AppTerminationManager
    
    var body: some View {
        VStack(spacing: 20) {
            // Warning icon and title
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)
                
                Text("Quit Hivecrew?")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            
            // Active work summary
            VStack(alignment: .leading, spacing: 12) {
                Text("The following work is in progress:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 8) {
                    if terminationManager.activeWorkDetails.runningAgentCount > 0 {
                        ActiveWorkRow(
                            icon: "play.circle.fill",
                            iconColor: .green,
                            title: "Running Tasks",
                            count: terminationManager.activeWorkDetails.runningAgentCount,
                            items: terminationManager.activeWorkDetails.runningTaskTitles
                        )
                    }
                    
                    if terminationManager.activeWorkDetails.queuedTaskCount > 0 {
                        ActiveWorkRow(
                            icon: "clock.fill",
                            iconColor: .yellow,
                            title: "Queued Tasks",
                            count: terminationManager.activeWorkDetails.queuedTaskCount,
                            items: terminationManager.activeWorkDetails.queuedTaskTitles
                        )
                    }
                    
                    if terminationManager.activeWorkDetails.totalRunningVMCount > 0 {
                        ActiveWorkRow(
                            icon: "desktopcomputer",
                            iconColor: .blue,
                            title: "Running VMs",
                            count: terminationManager.activeWorkDetails.totalRunningVMCount,
                            items: []
                        )
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Explanation of what will happen
            VStack(alignment: .leading, spacing: 6) {
                Text("If you quit:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                VStack(alignment: .leading, spacing: 4) {
                    BulletPoint("Running tasks will be stopped and re-added to the queue")
                    BulletPoint("Queued tasks will remain in the queue")
                    BulletPoint("Running VMs will be stopped")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            
            // Action buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    terminationManager.cancelTermination()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button("Quit") {
                    Task {
                        await terminationManager.confirmTermination()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

// MARK: - Supporting Views

private struct ActiveWorkRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let count: Int
    let items: [String]
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) \(title)")
                    .fontWeight(.medium)
                
                if !items.isEmpty {
                    ForEach(items.prefix(3), id: \.self) { item in
                        Text("• \(item)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    if items.count > 3 {
                        Text("• and \(items.count - 3) more...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
    }
}

private struct BulletPoint: View {
    let text: String
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
        }
    }
}

#Preview {
    TerminationConfirmationSheet(terminationManager: AppTerminationManager.shared)
}
