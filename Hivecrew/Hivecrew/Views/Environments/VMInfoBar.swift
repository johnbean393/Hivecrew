//
//  VMInfoBar.swift
//  Hivecrew
//
//  Created by Hivecrew on 1/10/26.
//

import SwiftUI

/// Bottom info bar showing VM status and configuration
struct VMInfoBar: View {
    let vm: VMInfo
    var isAgentRunning: Bool = false
    
    var body: some View {
        HStack(spacing: 20) {
            statusSection
            Divider().frame(height: 12)
            configurationSection
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Status Section
    
    private var statusSection: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
        }
    }
    
    private var statusText: String {
        // Show "In Use" when an agent is actively running on this VM
        if isAgentRunning && vm.status == .ready {
            return "In Use"
        }
        return vm.status.displayName
    }
    
    // MARK: - Configuration Section
    
    private var configurationSection: some View {
        HStack(spacing: 12) {
            configItem(icon: "cpu", text: "\(vm.configuration.cpuCount) CPU")
            configItem(icon: "memorychip", text: "\(vm.configuration.memoryGB) GB")
            configItem(icon: "internaldrive", text: "\(vm.configuration.diskGB) GB")
        }
    }
    
    private func configItem(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }
    
    // MARK: - Status Color
    
    private var statusColor: Color {
        // Show blue when agent is running (in use)
        if isAgentRunning && vm.status == .ready {
            return .blue
        }
        switch vm.status {
        case .stopped: return .secondary
        case .booting, .suspending: return .yellow
        case .ready: return .green
        case .busy: return .blue
        case .error: return .red
        }
    }
}

#Preview {
    let sampleVM = VMInfo(
        id: "test",
        name: "Test VM",
        status: .ready,
        createdAt: Date(),
        lastUsedAt: nil,
        bundlePath: "/tmp",
        configuration: VMConfiguration()
    )
    
    return VMInfoBar(vm: sampleVM)
}
