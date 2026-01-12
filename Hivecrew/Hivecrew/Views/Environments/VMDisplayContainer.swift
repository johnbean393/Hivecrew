//
//  VMDisplayContainer.swift
//  Hivecrew
//
//  Created by Hivecrew on 1/10/26.
//

import SwiftUI

/// Container that shows appropriate content based on VM state
struct VMDisplayContainer: View {
    let vmId: String
    @EnvironmentObject var vmService: VMServiceClient
    @ObservedObject var vmRuntime = AppVMRuntime.shared
    
    private var isVMRunning: Bool {
        vmRuntime.getVM(id: vmId) != nil
    }
    
    var body: some View {
        Group {
            if let vm = vmService.vms.first(where: { $0.id == vmId }) {
                contentForStatus(vm.status)
            } else {
                VMPlaceholderView(
                    icon: "questionmark.circle",
                    title: "VM Not Found",
                    subtitle: "This VM may have been deleted"
                )
            }
        }
    }
    
    // MARK: - Status Content
    
    @ViewBuilder
    private func contentForStatus(_ status: VMStatus) -> some View {
        if isVMRunning {
            VMDisplayView(vmId: vmId, vmRuntime: vmRuntime)
        } else {
            switch status {
            case .stopped:
                stoppedView
            case .booting:
                bootingView
            case .ready, .busy:
                // Fallback if VM should be running but isn't in runtime yet
                VMDisplayView(vmId: vmId, vmRuntime: vmRuntime)
            case .suspending:
                suspendingView
            case .error:
                errorView
            }
        }
    }
    
    private var stoppedView: some View {
        VMPlaceholderView(
            icon: "desktopcomputer",
            title: "VM Stopped",
            subtitle: "Start the VM to see its display"
        )
    }
    
    private var bootingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Booting VM...")
                .font(.headline)
                .foregroundStyle(.white)
        }
    }
    
    private var suspendingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Stopping VM...")
                .font(.headline)
                .foregroundStyle(.white)
        }
    }
    
    private var errorView: some View {
        VMPlaceholderView(
            icon: "exclamationmark.triangle.fill",
            title: "VM Error",
            subtitle: "The VM encountered an error"
        )
    }
}

#Preview {
    VMDisplayContainer(vmId: "test")
        .environmentObject(VMServiceClient.shared)
        .background(Color.black)
}
