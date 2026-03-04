//
//  HivecrewAppDelegate.swift
//  Hivecrew
//
//  App delegate for Sparkle update integration and termination handling
//

import Cocoa
import Sparkle

class HivecrewAppDelegate: NSObject, NSApplicationDelegate {
    /// Sparkle updater controller - manages the update lifecycle
    let updaterController: SPUStandardUpdaterController
    private var didRunAutomaticUpdateCheck = false
    
    override init() {
        // Initialize Sparkle updater before app finishes launching
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        performAutomaticUpdateCheckWhenReady()
    }
    
    private func performAutomaticUpdateCheckWhenReady(remainingAttempts: Int = 10) {
        guard !didRunAutomaticUpdateCheck else { return }
        
        let updater = updaterController.updater
        guard updater.canCheckForUpdates else {
            guard remainingAttempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.performAutomaticUpdateCheckWhenReady(remainingAttempts: remainingAttempts - 1)
            }
            return
        }
        
        didRunAutomaticUpdateCheck = true
        updater.checkForUpdatesInBackground()
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            // Gracefully stop cloudflared tunnel before termination
            await RemoteAccessManager.shared.shutdown()
            
            if AppTerminationManager.shared.shouldTerminate() {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            // If false, the manager will show confirmation sheet and call reply later
        }
        
        // Return .terminateLater to defer the decision
        return .terminateLater
    }
}
