//
//  VideoSource.swift
//  HivecrewVoice
//

import Foundation

public enum VideoSource: Equatable, Sendable {
    case none
    case screen(displayID: UInt32)
    case camera(deviceID: String)
}
