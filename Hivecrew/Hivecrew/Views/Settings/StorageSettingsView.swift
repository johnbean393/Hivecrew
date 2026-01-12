//
//  StorageSettingsView.swift
//  Hivecrew
//
//  Created by Hivecrew on 1/10/26.
//

import SwiftUI
import HivecrewShared

/// Storage settings tab
struct StorageSettingsView: View {
    var body: some View {
        Form {
            locationsSection
            actionsSection
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Locations Section
    
    private var locationsSection: some View {
        Section("Storage Locations") {
            vmStorageRow
            sessionStorageRow
        }
    }
    
    private var vmStorageRow: some View {
        LabeledContent("VM Storage") {
            Text(AppPaths.vmDirectoryDisplayPath)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
    
    private var sessionStorageRow: some View {
        LabeledContent("Session Traces") {
            Text(AppPaths.sessionsDirectoryDisplayPath)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
    
    // MARK: - Actions Section
    
    private var actionsSection: some View {
        Section {
            openFolderButton
        }
    }
    
    private var openFolderButton: some View {
        Button("Open VM Folder in Finder") {
            NSWorkspace.shared.open(AppPaths.vmDirectory)
        }
    }
}

#Preview {
    StorageSettingsView()
}
