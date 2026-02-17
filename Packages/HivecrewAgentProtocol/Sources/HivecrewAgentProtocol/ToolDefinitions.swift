//
//  ToolDefinitions.swift
//  HivecrewAgentProtocol
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation

/// All available tool methods for the CUA (Computer Use Agent)
public enum AgentMethod: String, CaseIterable, Sendable {
    // Observation tools (guest-side only, not exposed to LLM)
    case screenshot = "screenshot"
    case healthCheck = "health_check"
    case traverseAccessibilityTree = "traverse_accessibility_tree"
    
    // App tools
    case openApp = "open_app"
    case openFile = "open_file"
    case openUrl = "open_url"
    
    // Input tools
    case mouseMove = "mouse_move"
    case mouseClick = "mouse_click"
    case mouseDrag = "mouse_drag"
    case keyboardType = "keyboard_type"
    case keyboardKey = "keyboard_key"
    case scroll = "scroll"
    
    // File tools
    case runShell = "run_shell"
    case readFile = "read_file"
    case moveFile = "move_file"
    
    // System tools
    case wait = "wait"
    
    // User interaction tools
    case askTextQuestion = "ask_text_question"
    case askMultipleChoice = "ask_multiple_choice"
    case requestUserIntervention = "request_user_intervention"
    
    // Authentication tools
    case getLoginCredentials = "get_login_credentials"
    
    // Host-side web tools
    case webSearch = "web_search"
    case readWebpageContent = "read_webpage_content"
    case extractInfoFromWebpage = "extract_info_from_webpage"
    case getLocation = "get_location"
    
    // Host-side todo management tools
    case createTodoList = "create_todo_list"
    case addTodoItem = "add_todo_item"
    case finishTodoItem = "finish_todo_item"
    
    // Host-side image generation tool
    case generateImage = "generate_image"
    
    // Host-side subagent management tools
    case spawnSubagent = "spawn_subagent"
    case getSubagentStatus = "get_subagent_status"
    case awaitSubagents = "await_subagents"
    case cancelSubagent = "cancel_subagent"
    case listSubagents = "list_subagents"
    
    // Host-side inter-agent messaging tool
    case sendMessage = "send_message"
    
    /// Returns true if this tool executes on the host (not in the guest VM)
    /// Host-side tools don't affect VM state, so screenshot capture can be skipped
    public var isHostSideTool: Bool {
        switch self {
        case .webSearch, .readWebpageContent, .extractInfoFromWebpage,
             .getLocation, .createTodoList, .addTodoItem, .finishTodoItem,
             .askTextQuestion, .askMultipleChoice, .requestUserIntervention,
             .getLoginCredentials, .generateImage,
             .spawnSubagent, .getSubagentStatus, .awaitSubagents, .cancelSubagent, .listSubagents,
             .sendMessage:
            return true
        default:
            return false
        }
    }

    /// Returns true when the tool fundamentally depends on visual perception.
    /// Non-vision models should not be offered these tools.
    public var isVisionDependentTool: Bool {
        switch self {
        case .screenshot,
             .traverseAccessibilityTree,
             .openApp, .openFile, .openUrl,
             .mouseMove, .mouseClick, .mouseDrag,
             .keyboardType, .keyboardKey, .scroll:
            return true
        default:
            return false
        }
    }
    
    /// Returns true if this tool should be excluded from the LLM tool list
    /// These are internal tools used by the host, not called by the LLM
    public var isInternalTool: Bool {
        switch self {
        case .screenshot, .healthCheck:
            return true
        default:
            return false
        }
    }
}

// MARK: - Tool Parameters

/// Result from screenshot tool
public struct ScreenshotResult: Codable, Sendable {
    public let imageBase64: String
    public let width: Int
    public let height: Int
    
    public init(imageBase64: String, width: Int, height: Int) {
        self.imageBase64 = imageBase64
        self.width = width
        self.height = height
    }
}

/// Parameters for open_app tool
public struct OpenAppParams: Codable, Sendable {
    public let bundleId: String?
    public let appName: String?
    
    public init(bundleId: String? = nil, appName: String? = nil) {
        self.bundleId = bundleId
        self.appName = appName
    }
}

/// Parameters for open_file tool
public struct OpenFileParams: Codable, Sendable {
    public let path: String
    public let withApp: String?
    
    public init(path: String, withApp: String? = nil) {
        self.path = path
        self.withApp = withApp
    }
}

/// Parameters for open_url tool
public struct OpenUrlParams: Codable, Sendable {
    public let url: String
    
    public init(url: String) {
        self.url = url
    }
}

/// Parameters for mouse_move tool
public struct MouseMoveParams: Codable, Sendable {
    public let x: Double
    public let y: Double
    
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Parameters for mouse_click tool
public struct MouseClickParams: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let button: MouseButton?
    public let clickType: ClickType?
    
    public init(x: Double, y: Double, button: MouseButton? = nil, clickType: ClickType? = nil) {
        self.x = x
        self.y = y
        self.button = button
        self.clickType = clickType
    }
}

public enum MouseButton: String, Codable, Sendable {
    case left
    case right
    case middle
}

public enum ClickType: String, Codable, Sendable {
    case single
    case double
    case triple
}

/// Parameters for mouse_drag tool
public struct MouseDragParams: Codable, Sendable {
    public let fromX: Double
    public let fromY: Double
    public let toX: Double
    public let toY: Double
    
    public init(fromX: Double, fromY: Double, toX: Double, toY: Double) {
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
    }
}

/// Parameters for keyboard_type tool
public struct KeyboardTypeParams: Codable, Sendable {
    public let text: String
    
    public init(text: String) {
        self.text = text
    }
}

/// Parameters for keyboard_key tool
public struct KeyboardKeyParams: Codable, Sendable {
    public let key: String
    public let modifiers: [KeyModifier]?
    
    public init(key: String, modifiers: [KeyModifier]? = nil) {
        self.key = key
        self.modifiers = modifiers
    }
}

public enum KeyModifier: String, Codable, Sendable {
    case command
    case control
    case option
    case shift
    case function
}

/// Parameters for scroll tool
public struct ScrollParams: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let deltaX: Double
    public let deltaY: Double
    
    public init(x: Double, y: Double, deltaX: Double, deltaY: Double) {
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
    }
}

/// Parameters for wait tool
public struct WaitParams: Codable, Sendable {
    public let seconds: Double
    
    public init(seconds: Double) {
        self.seconds = seconds
    }
}

/// Parameters for run_shell tool
public struct RunShellParams: Codable, Sendable {
    public let command: String
    public let timeout: Double?
    
    public init(command: String, timeout: Double? = nil) {
        self.command = command
        self.timeout = timeout
    }
}

/// Result from run_shell tool
public struct RunShellResult: Codable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    
    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Parameters for read_file tool
public struct ReadFileParams: Codable, Sendable {
    public let path: String
    
    public init(path: String) {
        self.path = path
    }
}

/// Parameters for move_file tool
public struct MoveFileParams: Codable, Sendable {
    public let source: String
    public let destination: String
    
    public init(source: String, destination: String) {
        self.source = source
        self.destination = destination
    }
}

// MARK: - Accessibility Traversal

/// Parameters for traverse_accessibility_tree tool
public struct TraverseAccessibilityTreeParams: Codable, Sendable {
    /// Process ID of the target application. If nil, uses the frontmost app.
    public let pid: Int32?
    /// If true, only returns elements with valid position and size (visible on screen)
    public let onlyVisibleElements: Bool?
    
    public init(pid: Int32? = nil, onlyVisibleElements: Bool? = nil) {
        self.pid = pid
        self.onlyVisibleElements = onlyVisibleElements
    }
}

/// Represents a single UI element from the accessibility tree
public struct AccessibilityElementData: Codable, Sendable, Hashable {
    /// The accessibility role (e.g., "AXButton", "AXTextField")
    public let role: String
    /// Combined text content from value, title, description, label attributes
    public let text: String?
    /// X coordinate of the element's position
    public let x: Double?
    /// Y coordinate of the element's position
    public let y: Double?
    /// Width of the element
    public let width: Double?
    /// Height of the element
    public let height: Double?
    
    public init(role: String, text: String?, x: Double?, y: Double?, width: Double?, height: Double?) {
        self.role = role
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Statistics about the accessibility traversal
public struct AccessibilityTraversalStats: Codable, Sendable {
    public let count: Int
    public let excludedCount: Int
    public let excludedNonInteractable: Int
    public let excludedNoText: Int
    public let withTextCount: Int
    public let withoutTextCount: Int
    public let visibleElementsCount: Int
    public let roleCounts: [String: Int]
    
    public init(
        count: Int,
        excludedCount: Int,
        excludedNonInteractable: Int,
        excludedNoText: Int,
        withTextCount: Int,
        withoutTextCount: Int,
        visibleElementsCount: Int,
        roleCounts: [String: Int]
    ) {
        self.count = count
        self.excludedCount = excludedCount
        self.excludedNonInteractable = excludedNonInteractable
        self.excludedNoText = excludedNoText
        self.withTextCount = withTextCount
        self.withoutTextCount = withoutTextCount
        self.visibleElementsCount = visibleElementsCount
        self.roleCounts = roleCounts
    }
}

/// Result from traverse_accessibility_tree tool
public struct AccessibilityTraversalResult: Codable, Sendable {
    /// Name of the traversed application
    public let appName: String
    /// List of discovered UI elements
    public let elements: [AccessibilityElementData]
    /// Statistics about the traversal
    public let stats: AccessibilityTraversalStats
    /// Time taken to perform the traversal
    public let processingTimeSeconds: String
    
    public init(
        appName: String,
        elements: [AccessibilityElementData],
        stats: AccessibilityTraversalStats,
        processingTimeSeconds: String
    ) {
        self.appName = appName
        self.elements = elements
        self.stats = stats
        self.processingTimeSeconds = processingTimeSeconds
    }
}

// MARK: - Web Tools

/// Parameters for web_search tool
public struct WebSearchParams: Codable, Sendable {
    public let query: String
    public let site: String?
    public let resultCount: Int?
    public let startDate: String?
    public let endDate: String?
    
    public init(query: String, site: String? = nil, resultCount: Int? = nil, startDate: String? = nil, endDate: String? = nil) {
        self.query = query
        self.site = site
        self.resultCount = resultCount
        self.startDate = startDate
        self.endDate = endDate
    }
}

/// A single search result
public struct SearchResultItem: Codable, Sendable {
    public let url: String
    public let title: String
    public let snippet: String
    
    public init(url: String, title: String, snippet: String) {
        self.url = url
        self.title = title
        self.snippet = snippet
    }
}

/// Parameters for read_webpage_content tool
public struct ReadWebpageContentParams: Codable, Sendable {
    public let url: String
    
    public init(url: String) {
        self.url = url
    }
}

/// Parameters for extract_info_from_webpage tool
public struct ExtractInfoFromWebpageParams: Codable, Sendable {
    public let url: String
    public let question: String
    
    public init(url: String, question: String) {
        self.url = url
        self.question = question
    }
}

/// Result from get_location tool
public struct LocationResult: Codable, Sendable {
    public let location: String
    
    public init(location: String) {
        self.location = location
    }
}

// MARK: - Todo Management Tools

/// Parameters for create_todo_list tool
public struct CreateTodoListParams: Codable, Sendable {
    public let title: String
    public let items: [String]?
    
    public init(title: String, items: [String]? = nil) {
        self.title = title
        self.items = items
    }
}

/// Parameters for add_todo_item tool
public struct AddTodoItemParams: Codable, Sendable {
    public let item: String
    
    public init(item: String) {
        self.item = item
    }
}

/// Parameters for finish_todo_item tool
public struct FinishTodoItemParams: Codable, Sendable {
    public let index: Int
    
    public init(index: Int) {
        self.index = index
    }
}

// MARK: - User Intervention Tools

/// Parameters for request_user_intervention tool
public struct RequestUserInterventionParams: Codable, Sendable {
    public let message: String
    public let service: String?
    
    public init(message: String, service: String? = nil) {
        self.message = message
        self.service = service
    }
}

// MARK: - Authentication Tools

/// Parameters for get_login_credentials tool
public struct GetLoginCredentialsParams: Codable, Sendable {
    public let service: String?
    
    public init(service: String? = nil) {
        self.service = service
    }
}

// MARK: - Image Generation Tools

/// Parameters for generate_image tool
public struct GenerateImageParams: Codable, Sendable {
    /// Detailed description of the image to generate
    public let prompt: String
    /// Optional paths to reference images for style or content guidance.
    /// Image editing supports PNG, JPEG, and JPG inputs.
    public let referenceImagePaths: [String]?
    /// Aspect ratio for the generated image.
    /// Supported values: "1:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9"
    /// Defaults to "1:1" if not specified.
    public let aspectRatio: String?
    
    public init(prompt: String, referenceImagePaths: [String]? = nil, aspectRatio: String? = nil) {
        self.prompt = prompt
        self.referenceImagePaths = referenceImagePaths
        self.aspectRatio = aspectRatio
    }
}
