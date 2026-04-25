//
//  CuaDriverConnection+Facade.swift
//  Hivecrew
//
//  Stable Hivecrew-facing GUI facade tools for the App Worker runtime.
//  Keeps raw pid/window_id/element_index hidden from the LLM.
//

import Foundation
import HivecrewMCP

extension CuaDriverConnection {

    // MARK: - List Apps

    func listApps() async throws -> [AppSummary] {
        let result = try await mcp.callTool(name: "list_apps", arguments: [:])
        if result.isError == true {
            throw CuaDriverError.toolCallFailed(result.textContent)
        }

        guard let text = result.content.first?.text,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return parseAppSummariesFromText(result.textContent)
        }

        return json.compactMap { dict in
            guard let pid = dict["pid"] as? Int,
                  let name = dict["name"] as? String else { return nil }
            return AppSummary(
                pid: pid,
                name: name,
                bundleId: dict["bundle_id"] as? String
            )
        }
    }

    private func parseAppSummariesFromText(_ text: String) -> [AppSummary] {
        var apps: [AppSummary] = []
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") {
                apps.append(AppSummary(pid: 0, name: trimmed, bundleId: nil))
            }
        }
        return apps
    }

    // MARK: - List Windows

    func listWindows(forApp app: String?) async throws -> [WindowSummary] {
        let pid: Int
        if let appRef = app {
            let apps = try await listApps()
            guard let match = apps.first(where: { $0.name.localizedCaseInsensitiveContains(appRef) }) else {
                throw CuaDriverError.toolCallFailed("App '\(appRef)' not found in running apps.")
            }
            pid = match.pid
        } else if let current = currentApp {
            pid = current.pid
        } else {
            throw CuaDriverError.noAppSelected
        }

        let result = try await mcp.callTool(name: "list_windows", arguments: [
            "pid": .int(pid)
        ])
        if result.isError == true {
            throw CuaDriverError.toolCallFailed(result.textContent)
        }

        guard let text = result.content.first?.text,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return json.compactMap { dict in
            guard let windowId = dict["window_id"] as? Int else { return nil }
            return WindowSummary(
                windowId: windowId,
                title: dict["title"] as? String ?? "Untitled",
                pid: pid
            )
        }
    }

    // MARK: - Select Window

    func selectWindow(_ window: WindowSummary) async throws {
        // Acquire per-app lock if switching to a different app
        if currentApp == nil || currentApp?.pid != window.pid {
            let appKey = AppFocusManager.normalizedKey(bundleId: nil, appName: window.title)
            await AppFocusManager.shared.acquire(appKey: appKey, connectionId: connectionId)
            lockedAppKeys.insert(appKey)
            currentApp = AppContext(pid: window.pid, appName: window.title, bundleId: nil)
        }
        currentWindow = WindowContext(windowId: window.windowId, title: window.title, pid: window.pid)
        elementCache = [:]
    }

    // MARK: - Get Window State

    func getWindowState() async throws -> WindowStateSnapshot {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }

        let result = try await mcp.callTool(name: "get_window_state", arguments: [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId)
        ])
        if result.isError == true {
            throw CuaDriverError.toolCallFailed(result.textContent)
        }

        var elements: [AXElementSummary] = []
        var screenshotBase64: String?
        var screenWidth: Int?
        var screenHeight: Int?

        for content in result.content {
            if content.type == "image", let data = content.data {
                screenshotBase64 = data
            }
            if content.type == "text", let text = content.text,
               let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                if let w = json["width"] as? Int { screenWidth = w }
                if let h = json["height"] as? Int { screenHeight = h }

                if let tree = json["elements"] as? [[String: Any]] {
                    elements = tree.enumerated().compactMap { index, dict in
                        AXElementSummary(
                            index: dict["index"] as? Int ?? index,
                            role: dict["role"] as? String ?? "Unknown",
                            label: dict["label"] as? String ?? "",
                            value: dict["value"] as? String
                        )
                    }
                }
            }
        }

        return WindowStateSnapshot(
            elements: elements,
            screenshotBase64: screenshotBase64,
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )
    }

    // MARK: - Click Element

    func clickElement(_ index: Int, button: String = "left") async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }

        var args: [String: AnyCodableValue] = [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId),
            "element_index": .int(index)
        ]
        if button != "left" { args["button"] = .string(button) }

        let result = try await mcp.callTool(name: "click", arguments: args)
        if result.isError == true {
            throw CuaDriverError.toolCallFailed(result.textContent)
        }
    }

    // MARK: - Set Value

    func setValue(elementIndex: Int, value: String) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }

        let result = try await mcp.callTool(name: "set_value", arguments: [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId),
            "element_index": .int(elementIndex),
            "value": .string(value)
        ])
        if result.isError == true {
            throw CuaDriverError.toolCallFailed(result.textContent)
        }
    }
}
