//
//  ToolSchemaBuilder+AgentMethods.swift
//  HivecrewLLM
//
//  Tool schema definitions for AgentMethod cases
//

import Foundation
import HivecrewAgentProtocol

extension ToolSchemaBuilder {
    func getSchemaInfo(for method: AgentMethod) -> (description: String, parameters: [String: Any]) {
        if let management = getManagementSchemaInfo(for: method) {
            return management
        }

        switch method {
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

        case .mouseMove:
            return (
                "Move the mouse cursor to the specified screen coordinates without clicking. Useful for hovering over elements to reveal tooltips or dropdown menus. COORDINATE SYSTEM: Origin (0,0) is at the TOP-LEFT corner of the screen. X increases to the right, Y increases DOWNWARD (not upward). For example, a point near the top of the screen has a small Y value, while a point near the bottom has a large Y value.",
                objectSchema(
                    properties: [
                        "x": numberProperty("X coordinate on screen (0 = left edge, increases rightward)"),
                        "y": numberProperty("Y coordinate on screen (0 = top edge, increases DOWNWARD)")
                    ],
                    required: ["x", "y"]
                )
            )

        case .mouseClick:
            return (
                "Click the mouse at the specified screen coordinates. COORDINATE SYSTEM: Origin (0,0) is at the TOP-LEFT corner of the screen. X increases to the right, Y increases DOWNWARD (not upward). For example, a point near the top of the screen has a small Y value, while a point near the bottom has a large Y value.",
                objectSchema(
                    properties: [
                        "x": numberProperty("X coordinate on screen (0 = left edge, increases rightward)"),
                        "y": numberProperty("Y coordinate on screen (0 = top edge, increases DOWNWARD)"),
                        "button": enumProperty("Mouse button to click", ["left", "right", "middle"]),
                        "clickType": enumProperty("Type of click", ["single", "double", "triple"])
                    ],
                    required: ["x", "y"]
                )
            )

        case .mouseDrag:
            return (
                "Drag the mouse from one position to another. COORDINATE SYSTEM: Origin (0,0) is at the TOP-LEFT corner of the screen. X increases to the right, Y increases DOWNWARD (not upward).",
                objectSchema(
                    properties: [
                        "fromX": numberProperty("Starting X coordinate (0 = left edge, increases rightward)"),
                        "fromY": numberProperty("Starting Y coordinate (0 = top edge, increases DOWNWARD)"),
                        "toX": numberProperty("Ending X coordinate (0 = left edge, increases rightward)"),
                        "toY": numberProperty("Ending Y coordinate (0 = top edge, increases DOWNWARD)")
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
                "Scroll at the specified screen position. Values are in lines (not pixels). Use values like 3-5 to scroll a few lines, or 10-20 for larger scrolls. COORDINATE SYSTEM: Origin (0,0) is at the TOP-LEFT corner of the screen. X increases to the right, Y increases DOWNWARD (not upward).",
                objectSchema(
                    properties: [
                        "x": numberProperty("X coordinate where to scroll (0 = left edge, increases rightward)"),
                        "y": numberProperty("Y coordinate where to scroll (0 = top edge, increases DOWNWARD)"),
                        "deltaX": numberProperty("Horizontal scroll amount in lines (positive = right, negative = left)"),
                        "deltaY": numberProperty("Vertical scroll amount in lines (positive = scroll down to see content below, negative = scroll up)")
                    ],
                    required: ["x", "y", "deltaX", "deltaY"]
                )
            )

        case .runShell:
            return (
                "Execute a shell command and return its output. Use with caution.",
                objectSchema(
                    properties: [
                        "command": stringProperty("The shell command to execute")
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

        case .writeFile:
            return (
                "Write UTF-8 text contents to a file inside the VM. Prefer this over shell redirection when you need deterministic text or code edits.",
                objectSchema(
                    properties: [
                        "path": stringProperty("The file path to write"),
                        "contents": stringProperty("The full file contents to write")
                    ],
                    required: ["path", "contents"]
                )
            )

        case .listDirectory:
            return (
                "List the contents of a directory inside the VM, including file names, sizes, and whether each entry is a directory.",
                objectSchema(
                    properties: [
                        "path": stringProperty("The directory path to inspect")
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

        case .createTodoList, .addTodoItem, .finishTodoItem, .requestUserIntervention,
             .getLoginCredentials, .generateImage, .listLocalEntries, .importLocalFile,
             .stageWritebackCopy, .stageWritebackMove,
             .stageAttachedFileUpdate, .listWritebackTargets,
             .spawnSubagent, .getSubagentStatus, .awaitSubagents, .cancelSubagent, .listSubagents, .sendMessage:
            fatalError("Management schema cases should be handled before the main switch")
        }
    }
}
