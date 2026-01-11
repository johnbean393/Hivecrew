//
//  ToolSchemaBuilder.swift
//  HivecrewLLM
//
//  Converts AgentMethod definitions to OpenAI function calling format
//

import Foundation
import HivecrewAgentProtocol

/// Builds OpenAI-compatible tool definitions from AgentMethod enum
public final class ToolSchemaBuilder: Sendable {
    
    public init() {}
    
    /// Build tool definitions for all available agent methods
    public func buildAllTools() -> [LLMToolDefinition] {
        AgentMethod.allCases.map { buildToolDefinition(for: $0) }
    }
    
    /// Build tool definitions for a subset of methods
    public func buildTools(for methods: [AgentMethod]) -> [LLMToolDefinition] {
        methods.map { buildToolDefinition(for: $0) }
    }
    
    /// Build a single tool definition
    public func buildToolDefinition(for method: AgentMethod) -> LLMToolDefinition {
        let (description, parameters) = getSchemaInfo(for: method)
        
        return LLMToolDefinition.function(
            name: method.rawValue,
            description: description,
            parameters: parameters
        )
    }
    
    // MARK: - Schema Definitions
    
    private func getSchemaInfo(for method: AgentMethod) -> (description: String, parameters: [String: Any]) {
        switch method {
        // Observation tools
        case .screenshot:
            return (
                "Take a screenshot of the current screen. Returns base64-encoded PNG image data.",
                emptyObjectSchema()
            )
            
        case .getFrontmostApp:
            return (
                "Get information about the currently active (frontmost) application including bundle ID, app name, and window title.",
                emptyObjectSchema()
            )
            
        case .listRunningApps:
            return (
                "List all currently running applications with their bundle IDs, names, and process IDs.",
                emptyObjectSchema()
            )
            
        // App tools
        case .openApp:
            return (
                "Open an application by bundle ID or name. At least one of bundleId or appName must be provided.",
                objectSchema(
                    properties: [
                        "bundleId": stringProperty("The bundle identifier of the app (e.g., 'com.apple.Safari')"),
                        "appName": stringProperty("The name of the app (e.g., 'Safari')")
                    ],
                    required: []
                )
            )
            
        case .openFile:
            return (
                "Open a file at the specified path, optionally with a specific application.",
                objectSchema(
                    properties: [
                        "path": stringProperty("The file path to open (relative to shared folder or absolute)"),
                        "withApp": stringProperty("Optional bundle ID or name of app to open the file with")
                    ],
                    required: ["path"]
                )
            )
            
        case .openUrl:
            return (
                "Open a URL in the default browser or appropriate application.",
                objectSchema(
                    properties: [
                        "url": stringProperty("The URL to open")
                    ],
                    required: ["url"]
                )
            )
            
        case .activateApp:
            return (
                "Bring an already-running application to the foreground.",
                objectSchema(
                    properties: [
                        "bundleId": stringProperty("The bundle identifier of the app to activate")
                    ],
                    required: ["bundleId"]
                )
            )
            
        // Input tools
        case .mouseMove:
            return (
                "Move the mouse cursor to the specified screen coordinates.",
                objectSchema(
                    properties: [
                        "x": numberProperty("X coordinate on screen"),
                        "y": numberProperty("Y coordinate on screen")
                    ],
                    required: ["x", "y"]
                )
            )
            
        case .mouseClick:
            return (
                "Click the mouse at the specified screen coordinates.",
                objectSchema(
                    properties: [
                        "x": numberProperty("X coordinate on screen"),
                        "y": numberProperty("Y coordinate on screen"),
                        "button": enumProperty("Mouse button to click", ["left", "right", "middle"]),
                        "clickType": enumProperty("Type of click", ["single", "double", "triple"])
                    ],
                    required: ["x", "y"]
                )
            )
            
        case .mouseDrag:
            return (
                "Drag the mouse from one position to another.",
                objectSchema(
                    properties: [
                        "fromX": numberProperty("Starting X coordinate"),
                        "fromY": numberProperty("Starting Y coordinate"),
                        "toX": numberProperty("Ending X coordinate"),
                        "toY": numberProperty("Ending Y coordinate")
                    ],
                    required: ["fromX", "fromY", "toX", "toY"]
                )
            )
            
        case .keyboardType:
            return (
                "Type text using the keyboard. This simulates typing each character.",
                objectSchema(
                    properties: [
                        "text": stringProperty("The text to type")
                    ],
                    required: ["text"]
                )
            )
            
        case .keyboardKey:
            return (
                "Press a single key, optionally with modifier keys.",
                objectSchema(
                    properties: [
                        "key": stringProperty("The key to press (e.g., 'return', 'escape', 'tab', 'a', 'F1')"),
                        "modifiers": arrayProperty(
                            "Modifier keys to hold",
                            itemType: enumProperty("Modifier key", ["command", "control", "option", "shift", "function"])
                        )
                    ],
                    required: ["key"]
                )
            )
            
        case .scroll:
            return (
                "Scroll at the specified screen position.",
                objectSchema(
                    properties: [
                        "x": numberProperty("X coordinate where to scroll"),
                        "y": numberProperty("Y coordinate where to scroll"),
                        "deltaX": numberProperty("Horizontal scroll amount (positive = right)"),
                        "deltaY": numberProperty("Vertical scroll amount (positive = down)")
                    ],
                    required: ["x", "y", "deltaX", "deltaY"]
                )
            )
            
        // File tools
        case .runShell:
            return (
                "Execute a shell command and return its output. Use with caution.",
                objectSchema(
                    properties: [
                        "command": stringProperty("The shell command to execute"),
                        "timeout": numberProperty("Optional timeout in seconds")
                    ],
                    required: ["command"]
                )
            )
            
        case .readFile:
            return (
                "Read the contents of a file. Path should be relative to the shared folder.",
                objectSchema(
                    properties: [
                        "path": stringProperty("The file path to read")
                    ],
                    required: ["path"]
                )
            )
            
        case .writeFile:
            return (
                "Write content to a file. Path should be relative to the shared folder.",
                objectSchema(
                    properties: [
                        "path": stringProperty("The file path to write to"),
                        "contents": stringProperty("The content to write")
                    ],
                    required: ["path", "contents"]
                )
            )
            
        case .listDirectory:
            return (
                "List files and directories at the specified path.",
                objectSchema(
                    properties: [
                        "path": stringProperty("The directory path to list")
                    ],
                    required: ["path"]
                )
            )
            
        case .moveFile:
            return (
                "Move or rename a file from source to destination.",
                objectSchema(
                    properties: [
                        "source": stringProperty("The source file path"),
                        "destination": stringProperty("The destination file path")
                    ],
                    required: ["source", "destination"]
                )
            )
            
        case .clipboardRead:
            return (
                "Read the current text content from the system clipboard.",
                emptyObjectSchema()
            )
            
        case .clipboardWrite:
            return (
                "Write text to the system clipboard.",
                objectSchema(
                    properties: [
                        "text": stringProperty("The text to write to clipboard")
                    ],
                    required: ["text"]
                )
            )
            
        // System tools
        case .wait:
            return (
                "Wait for the specified number of seconds before continuing.",
                objectSchema(
                    properties: [
                        "seconds": numberProperty("Number of seconds to wait")
                    ],
                    required: ["seconds"]
                )
            )
            
        case .healthCheck:
            return (
                "Check the agent's health status including permissions and shared folder mount.",
                emptyObjectSchema()
            )
            
        case .shutdown:
            return (
                "Initiate a graceful shutdown of the virtual machine.",
                emptyObjectSchema()
            )
        }
    }
    
    // MARK: - Schema Helpers
    
    private func emptyObjectSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [:] as [String: Any],
            "additionalProperties": false
        ]
    }
    
    private func objectSchema(properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
    }
    
    private func stringProperty(_ description: String) -> [String: Any] {
        [
            "type": "string",
            "description": description
        ]
    }
    
    private func numberProperty(_ description: String) -> [String: Any] {
        [
            "type": "number",
            "description": description
        ]
    }
    
    private func booleanProperty(_ description: String) -> [String: Any] {
        [
            "type": "boolean",
            "description": description
        ]
    }
    
    private func enumProperty(_ description: String, _ values: [String]) -> [String: Any] {
        [
            "type": "string",
            "description": description,
            "enum": values
        ]
    }
    
    private func arrayProperty(_ description: String, itemType: [String: Any]) -> [String: Any] {
        [
            "type": "array",
            "description": description,
            "items": itemType
        ]
    }
}
