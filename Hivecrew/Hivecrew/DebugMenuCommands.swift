//
//  DebugMenuCommands.swift
//  Hivecrew
//
//  Debug menu commands for SwiftData backup and restore
//

import SwiftUI
import AppKit
import HivecrewShared
import Sparkle

// MARK: - Check for Updates Command

/// Menu command for checking updates - placed in App menu after "About"
struct CheckForUpdatesCommand: Commands {
    let updater: SPUUpdater
    
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesView(updater: updater)
        }
    }
}

// MARK: - Skills Menu Command

/// Menu command for opening the Skills window - placed in View menu
struct SkillsMenuCommand: Commands {
    @Environment(\.openWindow) private var openWindow
    
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Skills") {
                openWindow(id: "skills-window")
            }
            .keyboardShortcut("k", modifiers: .command)
        }
    }
}

// MARK: - Retrieval Index Menu Command

/// Menu command for opening the Retrieval Index window - placed in View menu
struct RetrievalIndexMenuCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Retrieval Index") {
                openWindow(id: "retrieval-index-window")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Manage Devices Command

/// Menu command for opening Settings → Connect tab to manage devices
struct DevicesMenuCommand: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Manage Devices…") {
                // Open Settings window and navigate to the Connect tab
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                // Post notification to switch to the Connect tab
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NotificationCenter.default.post(name: .navigateToSettingsTab, object: SettingsView.SettingsTab.api)
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted to trigger showing the onboarding wizard from the debug menu
    static let showOnboardingWizard = Notification.Name("showOnboardingWizard")
    /// Posted to navigate to a specific settings tab
    static let navigateToSettingsTab = Notification.Name("navigateToSettingsTab")
}

/// Debug menu commands for Help → Debug submenu
struct DebugMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .help) {
            Menu("Debug") {
                Button("Show Onboarding Wizard…") {
                    showOnboardingWizard()
                }
                
                Divider()
                
                Button("Backup SwiftData") {
                    backupSwiftData()
                }
                
                Button("Restore SwiftData") {
                    restoreSwiftData()
                }
            }
        }
    }
    
    // MARK: - Onboarding
    
    private func showOnboardingWizard() {
        NotificationCenter.default.post(name: .showOnboardingWizard, object: nil)
    }
    
    // MARK: - SwiftData File Locations
    
    /// Gets the SwiftData store directory (default location)
    private var swiftDataDirectory: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
    }
    
    /// Backup directory for SwiftData
    private var backupDirectory: URL {
        let url = AppPaths.appSupportDirectory
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("SwiftData", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    
    /// The backup file path
    private var backupFilePath: URL {
        backupDirectory.appendingPathComponent("backup.zip")
    }
    
    /// SwiftData store files to backup (the main store and related files)
    private var swiftDataFiles: [String] {
        [
            "default.store",
            "default.store-shm",
            "default.store-wal"
        ]
    }
    
    // MARK: - Backup
    
    private func backupSwiftData() {
        guard let sourceDir = swiftDataDirectory else {
            showAlert(title: String(localized: "Backup Failed"), message: String(localized: "Could not locate SwiftData directory."))
            return
        }
        
        // Check if any SwiftData files exist
        let existingFiles = swiftDataFiles.filter { fileName in
            FileManager.default.fileExists(atPath: sourceDir.appendingPathComponent(fileName).path)
        }
        
        if existingFiles.isEmpty {
            showAlert(title: String(localized: "Backup Failed"), message: String(localized: "No SwiftData files found to backup."))
            return
        }
        
        Task {
            do {
                try await performBackup(from: sourceDir, to: backupFilePath, files: existingFiles)
                await MainActor.run {
                    showAlert(title: String(localized: "Backup Complete"), message: String(localized: "SwiftData backup saved successfully."))
                }
            } catch {
                await MainActor.run {
                    showAlert(title: String(localized: "Backup Failed"), message: error.localizedDescription)
                }
            }
        }
    }
    
    private func performBackup(from sourceDir: URL, to destinationURL: URL, files: [String]) async throws {
        // Create a temporary directory for staging
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Copy SwiftData files to temp directory
        for fileName in files {
            let sourceFile = sourceDir.appendingPathComponent(fileName)
            let destFile = tempDir.appendingPathComponent(fileName)
            
            if FileManager.default.fileExists(atPath: sourceFile.path) {
                try FileManager.default.copyItem(at: sourceFile, to: destFile)
            }
        }
        
        // Remove existing backup file if present
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        
        // Use ditto to create zip (reliable macOS command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", tempDir.path, destinationURL.path]
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw BackupError.compressionFailed
        }
    }
    
    // MARK: - Restore
    
    private func restoreSwiftData() {
        guard let destDir = swiftDataDirectory else {
            showAlert(title: String(localized: "Restore Failed"), message: String(localized: "Could not locate SwiftData directory."))
            return
        }
        
        // Check if backup exists
        guard FileManager.default.fileExists(atPath: backupFilePath.path) else {
            showAlert(title: String(localized: "Restore Failed"), message: String(localized: "No backup file found. Create a backup first."))
            return
        }
        
        // Confirm restore (destructive operation)
        let alert = NSAlert()
        alert.messageText = String(localized: "Restore SwiftData?")
        alert.informativeText = String(localized: "This will replace your current data with the backup. The app will quit after restoring. This action cannot be undone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return }
        
        Task {
            do {
                try await performRestore(from: backupFilePath, to: destDir)
                await MainActor.run {
                    let successAlert = NSAlert()
                    successAlert.messageText = String(localized: "Restore Complete")
                    successAlert.informativeText = String(localized: "SwiftData has been restored. The app will now quit. Please relaunch the app.")
                    successAlert.alertStyle = .informational
                    successAlert.addButton(withTitle: String(localized: "Quit"))
                    successAlert.runModal()
                    
                    // Quit the app to ensure clean reload of data
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    showAlert(title: String(localized: "Restore Failed"), message: error.localizedDescription)
                }
            }
        }
    }
    
    private func performRestore(from sourceURL: URL, to destDir: URL) async throws {
        // Create a temporary directory for extraction
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Extract zip archive
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", sourceURL.path, tempDir.path]
        
        try process.run()
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw BackupError.decompressionFailed
        }
        
        // Find the extracted folder (ditto creates a subfolder with the original name)
        let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        let extractedDir = contents.first ?? tempDir
        
        // Validate backup contents
        let extractedFiles = try FileManager.default.contentsOfDirectory(at: extractedDir, includingPropertiesForKeys: nil)
        let validFiles = extractedFiles.filter { swiftDataFiles.contains($0.lastPathComponent) }
        
        if validFiles.isEmpty {
            throw BackupError.invalidBackup
        }
        
        // Remove existing SwiftData files
        for fileName in swiftDataFiles {
            let destFile = destDir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destFile.path) {
                try FileManager.default.removeItem(at: destFile)
            }
        }
        
        // Copy restored files
        for file in validFiles {
            let destFile = destDir.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: destFile)
        }
    }
    
    // MARK: - Helpers
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = title.contains("Failed") ? .warning : .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}

// MARK: - Errors

enum BackupError: LocalizedError {
    case compressionFailed
    case decompressionFailed
    case invalidBackup
    
    var errorDescription: String? {
        switch self {
        case .compressionFailed:
            return String(localized: "Failed to create backup archive.")
        case .decompressionFailed:
            return String(localized: "Failed to extract backup archive.")
        case .invalidBackup:
            return String(localized: "The backup file does not contain valid SwiftData files.")
        }
    }
}
