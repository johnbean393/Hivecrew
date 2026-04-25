//
//  ToolExecutor+AppWorker.swift
//  Hivecrew
//
//  Dispatches app_* facade tool calls to CuaDriverConnection.
//  These tools are only registered in the schema when the runtime is App Worker;
//  RuntimeToolFiltering excludes them for Fast and VM.
//

import Foundation

extension ToolExecutor {

    func executeAppWorkerTool(name: String, args: [String: Any]) async throws -> InternalToolResult {
        guard let appConn = connection as? CuaDriverConnection else {
            throw ToolExecutorError.executionFailed("\(name) is only available in the App Worker runtime.")
        }

        switch name {
        case "app_list_apps":
            let apps = try await appConn.listApps()
            if apps.isEmpty {
                return .text("No running applications found.")
            }
            let lines = apps.enumerated().map { i, app in
                var line = "[\(i)] \(app.name)"
                if let bid = app.bundleId { line += " (\(bid))" }
                return line
            }
            return .text("Running applications:\n" + lines.joined(separator: "\n"))

        case "app_list_windows":
            let appFilter = args["app"] as? String
            let windows = try await appConn.listWindows(forApp: appFilter)
            if windows.isEmpty {
                return .text("No windows found for the specified app.")
            }
            let lines = windows.enumerated().map { i, win in
                "[\(i)] \(win.title)"
            }
            return .text("Windows:\n" + lines.joined(separator: "\n"))

        case "app_select_window":
            let windowIndex = args["windowIndex"] as? Int ?? 0
            let appFilter = args["app"] as? String
            let windows = try await appConn.listWindows(forApp: appFilter)
            guard windowIndex >= 0, windowIndex < windows.count else {
                throw ToolExecutorError.executionFailed("Window index \(windowIndex) is out of range (0..\(windows.count - 1)).")
            }
            try await appConn.selectWindow(windows[windowIndex])
            return .text("Selected window: \(windows[windowIndex].title)")

        case "app_get_window_state":
            let state = try await appConn.getWindowState()
            var lines: [String] = []
            for el in state.elements {
                var line = "[\(el.index)] \(el.role) \"\(el.label)\""
                if let v = el.value, !v.isEmpty { line += " value=\"\(v)\"" }
                lines.append(line)
            }
            if lines.isEmpty {
                return .text("No accessible elements found in the current window.")
            }
            return .text("Window elements:\n" + lines.joined(separator: "\n"))

        case "app_click_element":
            let elementIndex = args["elementIndex"] as? Int ?? 0
            let button = args["button"] as? String ?? "left"
            try await appConn.clickElement(elementIndex, button: button)
            let label = appConn.elementCache[elementIndex]?.label ?? "element"
            return .text("Clicked [\(elementIndex)] \(label) with \(button) button")

        case "app_set_value":
            let elementIndex = args["elementIndex"] as? Int ?? 0
            let value = args["value"] as? String ?? ""
            try await appConn.setValue(elementIndex: elementIndex, value: value)
            return .text("Set value on element [\(elementIndex)] to \"\(value.prefix(50))\(value.count > 50 ? "..." : "")\"")

        default:
            throw ToolExecutorError.unknownTool(name)
        }
    }
}
