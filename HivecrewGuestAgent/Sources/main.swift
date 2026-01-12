//
//  main.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation
import HivecrewAgentProtocol

// MARK: - Main Entry Point

/// HivecrewGuestAgent - A daemon that runs inside macOS VMs to provide automation capabilities
/// 
/// This daemon:
/// 1. Connects to the host via virtio-vsock
/// 2. Listens for JSON-RPC commands
/// 3. Executes automation tools (screenshot, click, type, etc.)
/// 4. Returns results to the host

let agent = AgentDaemon()

// Set up signal handlers for graceful shutdown
signal(SIGINT) { _ in
    AgentDaemon.shared?.shutdown()
}
signal(SIGTERM) { _ in
    AgentDaemon.shared?.shutdown()
}

// Start the agent
agent.run()
