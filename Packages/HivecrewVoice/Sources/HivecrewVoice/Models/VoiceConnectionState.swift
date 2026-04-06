//
//  VoiceConnectionState.swift
//  HivecrewVoice
//

import Foundation

public enum VoiceConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error(String)
}
