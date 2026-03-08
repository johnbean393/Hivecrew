//
//  ToolSchemaBuilder+SchemaHelpers.swift
//  HivecrewLLM
//
//  JSON-schema helper builders for tool definitions
//

import Foundation

extension ToolSchemaBuilder {
    func emptyObjectSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [:] as [String: Any],
            "additionalProperties": false
        ]
    }

    func objectSchema(properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
    }

    func stringProperty(_ description: String) -> [String: Any] {
        [
            "type": "string",
            "description": description
        ]
    }

    func numberProperty(_ description: String) -> [String: Any] {
        [
            "type": "number",
            "description": description
        ]
    }

    func booleanProperty(_ description: String) -> [String: Any] {
        [
            "type": "boolean",
            "description": description
        ]
    }

    func enumProperty(_ description: String, _ values: [String]) -> [String: Any] {
        [
            "type": "string",
            "description": description,
            "enum": values
        ]
    }

    func arrayProperty(_ description: String, itemType: [String: Any]) -> [String: Any] {
        [
            "type": "array",
            "description": description,
            "items": itemType
        ]
    }
}
