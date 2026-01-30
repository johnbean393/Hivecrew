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
    
    /// Build CUA (Computer Use Agent) tools
    /// Note: Screenshot and healthCheck are NOT included because they are internal tools
    /// used by the agent loop, not called by the LLM.
    public func buildCUATools() -> [LLMToolDefinition] {
        AgentMethod.allCases
            .filter { !$0.isInternalTool }
            .map { buildToolDefinition(for: $0) }
    }
    
    /// Build CUA tools excluding specific methods
    /// - Parameter excluding: Methods to exclude from the tool list
    public func buildCUATools(excluding: Set<AgentMethod>) -> [LLMToolDefinition] {
        AgentMethod.allCases
            .filter { !$0.isInternalTool && !excluding.contains($0) }
            .map { buildToolDefinition(for: $0) }
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
            // Internal tools (should not be called by LLM)
            case .screenshot:
                return (
                    "Internal tool: Take a screenshot of the current screen.",
                    emptyObjectSchema()
                )
                
            case .healthCheck:
                return (
                    "Internal tool: Check the agent's health status.",
                    emptyObjectSchema()
                )
            
            // Observation tools
            case .traverseAccessibilityTree:
                return (
                    "Traverse the accessibility tree of an application to discover UI elements. Returns elements with their roles, text content, and screen positions. Useful for understanding the UI structure.",
                    objectSchema(
                        properties: [
                            "pid": numberProperty("Process ID of the target application. If not provided, uses the frontmost app."),
                            "onlyVisibleElements": booleanProperty("If true, only returns elements with valid position and size (visible on screen). Defaults to true.")
                        ],
                        required: []
                    )
                )
                
            // App tools
            case .openApp:
                return (
                    "Open an application by bundle ID or name. If the app is already running, it will be activated and brought to the foreground. At least one of bundleId or appName must be provided.",
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
                
            // Input tools
            case .mouseMove:
                return (
                    "Move the mouse cursor to the specified screen coordinates without clicking. Useful for hovering over elements to reveal tooltips or dropdown menus.",
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
                    "Scroll at the specified screen position. Values are in lines (not pixels). Use values like 3-5 to scroll a few lines, or 10-20 for larger scrolls.",
                    objectSchema(
                        properties: [
                            "x": numberProperty("X coordinate where to scroll"),
                            "y": numberProperty("Y coordinate where to scroll"),
                            "deltaX": numberProperty("Horizontal scroll amount in lines (positive = right, negative = left)"),
                            "deltaY": numberProperty("Vertical scroll amount in lines (positive = scroll down to see content below, negative = scroll up)")
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
                    "Read the contents of a file. Supports multiple formats: plain text (with encoding detection), PDF (text extraction), RTF, Office documents (.docx, .xlsx, .pptx), property lists (.plist), and images. For image files (PNG, JPEG, GIF, HEIC, etc.), the image is converted to PNG and displayed to you so you can analyze its visual content. Path can be relative to the shared folder or absolute.",
                    objectSchema(
                        properties: [
                            "path": stringProperty("The file path to read")
                        ],
                        required: ["path"]
                    )
                )
                
            case .moveFile:
                return (
                    "Move or rename a file from source to destination. Use this for file organization, renaming, or moving files to the outbox.",
                    objectSchema(
                        properties: [
                            "source": stringProperty("The source file path"),
                            "destination": stringProperty("The destination file path")
                        ],
                        required: ["source", "destination"]
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
                
            // User interaction tools
            case .askTextQuestion:
                return (
                    "Ask the user an open-ended text question when you need clarification or additional information to complete the task.",
                    objectSchema(
                        properties: [
                            "question": stringProperty("The question to ask the user")
                        ],
                        required: ["question"]
                    )
                )
                
            case .askMultipleChoice:
                return (
                    "Ask the user a multiple choice question when you need them to select from a set of predefined options.",
                    objectSchema(
                        properties: [
                            "question": stringProperty("The question to ask the user"),
                            "options": arrayProperty("The options for the user to choose from", itemType: ["type": "string"])
                        ],
                        required: ["question", "options"]
                    )
                )
                
            // Web tools
            case .webSearch:
                return (
                    "Search the web using Google or DuckDuckGo (configurable in settings). Returns a list of search results with URLs, titles, and snippets. Use this to find information, articles, documentation, or any web content.",
                    objectSchema(
                        properties: [
                            "query": stringProperty("The search query string"),
                            "site": stringProperty("Optional: Limit results to a specific site (e.g., 'github.com')"),
                            "resultCount": numberProperty("Optional: Number of results to return (default: 10, max: 20)"),
                            "startDate": stringProperty("Optional: Start date for results (format: YYYY-MM-DD)"),
                            "endDate": stringProperty("Optional: End date for results (format: YYYY-MM-DD)")
                        ],
                        required: ["query"]
                    )
                )
                
            case .readWebpageContent:
                return (
                    "Read and extract the full text content of a webpage in Markdown format. This uses Jina AI to parse the page and return clean, readable content without ads or navigation. Useful for reading articles, documentation, or any web content you need to analyze.",
                    objectSchema(
                        properties: [
                            "url": stringProperty("The URL of the webpage to read")
                        ],
                        required: ["url"]
                    )
                )
                
            case .extractInfoFromWebpage:
                return (
                    "Extract specific information from a webpage by asking a question. The webpage content is fetched and analyzed by an LLM to answer your question. More efficient than reading the entire page when you only need specific information.",
                    objectSchema(
                        properties: [
                            "url": stringProperty("The URL of the webpage to analyze"),
                            "question": stringProperty("The specific question to answer based on the webpage content")
                        ],
                        required: ["url", "question"]
                    )
                )
                
            case .getLocation:
                return (
                    "Get the current geographic location based on IP address. Returns city, region, and country. Useful for location-aware tasks like local weather, news, or services.",
                    emptyObjectSchema()
                )
                
            // Todo management tools
            case .createTodoList:
                return (
                    "Create a todo list to organize and track subtasks. This helps break down complex tasks into manageable steps. Only one todo list exists per agent session.",
                    objectSchema(
                        properties: [
                            "title": stringProperty("A descriptive title for the todo list"),
                            "items": arrayProperty("Optional: Initial list of todo items to add", itemType: ["type": "string"])
                        ],
                        required: ["title"]
                    )
                )

            case .addTodoItem:
                return (
                    "Add a new item to your todo list. The item will be added to the end of the list and assigned the next available number.",
                    objectSchema(
                        properties: [
                            "item": stringProperty("The todo item description")
                        ],
                        required: ["item"]
                    )
                )

            case .finishTodoItem:
                return (
                    "Mark a todo item as completed by its number. Use the item number shown in the todo list (e.g., 1, 2, 3).",
                    objectSchema(
                        properties: [
                            "index": numberProperty("The item number to mark as finished (1-based)")
                        ],
                        required: ["index"]
                    )
                )
                
            // User intervention tool
            case .requestUserIntervention:
                return (
                    "Request user intervention when you need the user to perform a manual action like signing in, completing 2FA, or solving a CAPTCHA. The agent will pause until the user confirms completion.",
                    objectSchema(
                        properties: [
                            "message": stringProperty("A message describing what action the user should take"),
                            "service": stringProperty("Optional: The name of the service (e.g., 'GitHub', 'Gmail')")
                        ],
                        required: ["message"]
                    )
                )
                
            // Authentication tools
            case .getLoginCredentials:
                return (
                    "Get stored login credentials for authentication. Returns UUID tokens that can be used with keyboard_type to enter usernames and passwords securely. The real credentials are never exposed - only tokens that are substituted at typing time.",
                    objectSchema(
                        properties: [
                            "service": stringProperty("Optional: Filter by service name (e.g., 'GitHub', 'Gmail'). If omitted, returns all available credentials.")
                        ],
                        required: []
                    )
                )
                
            // Image generation tool
            case .generateImage:
                return (
                    "Generate an image from a text prompt using AI. Optionally provide reference images for style or content guidance. The generated image will be saved to the images inbox folder and can be used in the task.",
                    objectSchema(
                        properties: [
                            "prompt": stringProperty("Detailed description of the image to generate. Be specific about style, composition, colors, and subject matter."),
                            "referenceImagePaths": arrayProperty(
                                "Optional paths to reference images for style or content guidance (relative to shared folder or absolute)",
                                itemType: ["type": "string"]
                            ),
                            "aspectRatio": enumProperty(
                                "Aspect ratio for the generated image",
                                ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3"]
                            )
                        ],
                        required: ["prompt"]
                    )
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
