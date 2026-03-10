//
//  ToolDefinitions+Input.swift
//  HivecrewAgentProtocol
//

import Foundation

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

public struct OpenAppParams: Codable, Sendable {
    public let bundleId: String?
    public let appName: String?

    public init(bundleId: String? = nil, appName: String? = nil) {
        self.bundleId = bundleId
        self.appName = appName
    }
}

public struct OpenFileParams: Codable, Sendable {
    public let path: String
    public let withApp: String?

    public init(path: String, withApp: String? = nil) {
        self.path = path
        self.withApp = withApp
    }
}

public struct OpenUrlParams: Codable, Sendable {
    public let url: String

    public init(url: String) {
        self.url = url
    }
}

public struct MouseMoveParams: Codable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

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

public struct KeyboardTypeParams: Codable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

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

public struct WaitParams: Codable, Sendable {
    public let seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }
}

public struct RunShellParams: Codable, Sendable {
    public let command: String
    public let timeout: Double?

    public init(command: String, timeout: Double? = nil) {
        self.command = command
        self.timeout = timeout
    }
}

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

public struct ReadFileParams: Codable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

public struct WriteFileParams: Codable, Sendable {
    public let path: String
    public let contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

public struct ListDirectoryParams: Codable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

public struct MoveFileParams: Codable, Sendable {
    public let source: String
    public let destination: String

    public init(source: String, destination: String) {
        self.source = source
        self.destination = destination
    }
}
