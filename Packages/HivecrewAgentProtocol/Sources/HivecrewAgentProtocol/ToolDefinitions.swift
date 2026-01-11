//
//  ToolDefinitions.swift
//  HivecrewAgentProtocol
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation

/// All available tool methods
public enum AgentMethod: String, CaseIterable, Sendable {
    // Observation tools
    case screenshot = "screenshot"
    case getFrontmostApp = "get_frontmost_app"
    case listRunningApps = "list_running_apps"
    
    // Native automation tools
    case openApp = "open_app"
    case openFile = "open_file"
    case openUrl = "open_url"
    case activateApp = "activate_app"
    case runShell = "run_shell"
    case readFile = "read_file"
    case writeFile = "write_file"
    case listDirectory = "list_directory"
    case moveFile = "move_file"
    case clipboardRead = "clipboard_read"
    case clipboardWrite = "clipboard_write"
    
    // CUA tools (Computer Use Agent)
    case mouseMove = "mouse_move"
    case mouseClick = "mouse_click"
    case mouseDrag = "mouse_drag"
    case keyboardType = "keyboard_type"
    case keyboardKey = "keyboard_key"
    case scroll = "scroll"
    
    // System tools
    case wait = "wait"
    case healthCheck = "health_check"
    case shutdown = "shutdown"
    
    // User interaction tools
    case askTextQuestion = "ask_text_question"
    case askMultipleChoice = "ask_multiple_choice"
}

// MARK: - Tool Parameters

/// Parameters for screenshot tool
public struct ScreenshotParams: Codable, Sendable {
    public init() {}
}

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

/// Parameters for write_file tool
public struct WriteFileParams: Codable, Sendable {
    public let path: String
    public let contents: String
    
    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

/// Parameters for list_directory tool
public struct ListDirectoryParams: Codable, Sendable {
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

/// Parameters for clipboard_write tool
public struct ClipboardWriteParams: Codable, Sendable {
    public let text: String
    
    public init(text: String) {
        self.text = text
    }
}

/// Result from health_check tool
public struct HealthCheckResult: Codable, Sendable {
    public let status: String
    public let accessibilityPermission: Bool
    public let screenRecordingPermission: Bool
    public let sharedFolderMounted: Bool
    public let sharedFolderPath: String?
    public let agentVersion: String
    
    public init(
        status: String,
        accessibilityPermission: Bool,
        screenRecordingPermission: Bool,
        sharedFolderMounted: Bool,
        sharedFolderPath: String?,
        agentVersion: String
    ) {
        self.status = status
        self.accessibilityPermission = accessibilityPermission
        self.screenRecordingPermission = screenRecordingPermission
        self.sharedFolderMounted = sharedFolderMounted
        self.sharedFolderPath = sharedFolderPath
        self.agentVersion = agentVersion
    }
}

/// Result from get_frontmost_app tool
public struct FrontmostAppResult: Codable, Sendable {
    public let bundleId: String?
    public let appName: String?
    public let windowTitle: String?
    
    public init(bundleId: String?, appName: String?, windowTitle: String?) {
        self.bundleId = bundleId
        self.appName = appName
        self.windowTitle = windowTitle
    }
}

/// App info for list_running_apps
public struct RunningAppInfo: Codable, Sendable {
    public let bundleId: String?
    public let appName: String
    public let pid: Int32
    
    public init(bundleId: String?, appName: String, pid: Int32) {
        self.bundleId = bundleId
        self.appName = appName
        self.pid = pid
    }
}
