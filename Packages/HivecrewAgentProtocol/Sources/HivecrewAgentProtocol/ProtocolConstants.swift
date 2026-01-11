//
//  ProtocolConstants.swift
//  HivecrewAgentProtocol
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation

/// Protocol constants shared between host and guest
public enum AgentProtocol {
    /// The vsock port the guest agent listens on
    public static let vsockPort: UInt32 = 3748
    
    /// The VirtioFS tag for the shared folder
    public static let sharedFolderTag = "shared"
    
    /// Expected mount path in guest
    public static let sharedFolderMountPath = "/Volumes/Shared"
    
    /// Current protocol version
    public static let protocolVersion = "1.0"
    
    /// Agent version
    public static let agentVersion = "0.1.0"
    
    /// Heartbeat interval in seconds
    public static let heartbeatInterval: TimeInterval = 5.0
    
    /// Connection timeout in seconds
    public static let connectionTimeout: TimeInterval = 10.0
    
    /// Maximum message size (16 MB)
    public static let maxMessageSize = 16 * 1024 * 1024
}
