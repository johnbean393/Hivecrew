//
//  DeveloperVMRowView.swift
//  Hivecrew
//
//  Sidebar row for running developer VMs
//

import SwiftUI

/// Row displaying a running developer VM in the sidebar
struct DeveloperVMRow: View {
    let vm: VMInfo
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.blue)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name)
                    .font(.headline)
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Image(systemName: "hammer")
                        .font(.caption2)
                    Text("Developer VM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
