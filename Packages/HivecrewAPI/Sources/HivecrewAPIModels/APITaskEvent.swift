//
//  APITaskEvent.swift
//  HivecrewAPI
//
//  Server-Sent Event models for real-time task progress streaming
//

import Foundation

// MARK: - Event Type

/// The type of task event being streamed
public enum APITaskEventType: String, Codable, Sendable {
    case screenshot
    case toolCallStart = "tool_call_start"
    case toolCallResult = "tool_call_result"
    case llmResponse = "llm_response"
    case statusChange = "status_change"
    case subagentUpdate = "subagent_update"
    case question
    case permissionRequest = "permission_request"
}

// MARK: - JSON Value (type-erased Codable)

/// A type-erased JSON value for flexible event payloads
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }
        // Bool must be checked before Int because Bool can decode as Int
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode JSONValue"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

// MARK: - JSONValue Literal Conformances

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - Task Event

/// Response for the polling-based activity endpoint
public struct APIActivityResponse: Codable, Sendable {
    /// Events returned in this batch
    public let events: [APITaskEvent]
    /// Total number of activity entries on the server (client sends this as `since` next time)
    public let total: Int

    public init(events: [APITaskEvent], total: Int) {
        self.events = events
        self.total = total
    }
}

/// A single Server-Sent Event representing real-time task progress
public struct APITaskEvent: Codable, Sendable {
    /// The category of this event
    public let type: APITaskEventType

    /// When the event occurred
    public let timestamp: Date

    /// Flexible payload containing event-specific data
    public let data: [String: JSONValue]

    public init(
        type: APITaskEventType,
        timestamp: Date = Date(),
        data: [String: JSONValue] = [:]
    ) {
        self.type = type
        self.timestamp = timestamp
        self.data = data
    }
}
