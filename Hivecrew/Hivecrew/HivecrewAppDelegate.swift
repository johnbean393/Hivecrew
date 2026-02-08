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
    
    override init() {
        // Initialize Sparkle updater before app finishes launching
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
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
