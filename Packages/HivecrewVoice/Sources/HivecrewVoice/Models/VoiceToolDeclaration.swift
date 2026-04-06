//
//  VoiceToolDeclaration.swift
//  HivecrewVoice
//

import Foundation

public struct VoiceToolDeclaration: Sendable {
    public let name: String
    public let description: String
    public let parameters: VoiceToolParameters?

    public init(name: String, description: String, parameters: VoiceToolParameters? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct VoiceToolParameters: Sendable {
    public let type: String
    public let properties: [String: VoiceToolProperty]
    public let required: [String]?

    public init(type: String = "object", properties: [String: VoiceToolProperty], required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

public struct VoiceToolProperty: Sendable {
    public let type: String
    public let description: String
    public let enumValues: [String]?

    public init(type: String, description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }
}
