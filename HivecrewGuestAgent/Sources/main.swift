//
//  main.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import AppKit
import HivecrewAgentProtocol

// MARK: - Main Entry Point

/// HivecrewGuestAgent - A daemon that runs inside macOS VMs to provide automation capabilities
/// 
/// This daemon:
/// 1. Connects to the host via virtio-vsock
/// 2. Listens for JSON-RPC commands
/// 3. Executes automation tools (screenshot, click, type, etc.)
/// 4. Returns results to the host

// Set up NSApplication FIRST so the process properly services macOS system events.
// Without this, macOS marks the app as "Not Responding" in Activity Monitor because
// WindowServer events and Apple Events go unserviced. NSApplication is also required
// for permission dialogs (Photos, Contacts, etc.) to display properly.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Background app - no dock icon, no menu bar

let agent = AgentDaemon()

// Set up signal handlers for graceful shutdown
signal(SIGINT) { _ in
    AgentDaemon.shared?.shutdown()
}
signal(SIGTERM) { _ in
    AgentDaemon.shared?.shutdown()
}

// Start the agent on a background queue so the main thread stays free
// to run NSApplication's event loop. The vsock server retry loop and
// permission prompts all run without blocking the main thread.
DispatchQueue.global(qos: .userInitiated).async {
    agent.start()
}

// Run the NSApplication event loop on the main thread.
// This keeps the process alive and responsive to macOS system events.
app.run()
