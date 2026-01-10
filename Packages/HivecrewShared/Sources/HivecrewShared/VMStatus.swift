//
//  VMStatus.swift
//  HivecrewShared
//
//  Created by Hivecrew on 1/10/26.
//

import Foundation

/// Represents the current state of a virtual machine
@objc public enum VMStatus: Int, Codable, Sendable {
    case stopped = 0
    case booting = 1
    case ready = 2
    case busy = 3
    case suspending = 4
    case error = 5
    
    public var displayName: String {
        switch self {
        case .stopped: return "Stopped"
        case .booting: return "Booting"
        case .ready: return "Ready"
        case .busy: return "Busy"
        case .suspending: return "Suspending"
        case .error: return "Error"
        }
    }
    
    public var statusIcon: String {
        switch self {
        case .stopped: return "⚪"
        case .booting: return "🟡"
        case .ready: return "🟢"
        case .busy: return "🔵"
        case .suspending: return "🟡"
        case .error: return "🔴"
        }
    }
}
