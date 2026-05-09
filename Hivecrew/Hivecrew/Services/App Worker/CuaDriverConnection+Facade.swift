//
//  CuaDriverConnection+Facade.swift
//  Hivecrew
//
//  Stable Hivecrew-facing GUI facade tools for the App Worker runtime.
//  Uses CuaDriverCore in-process for all AX, window, and input operations.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import CuaDriverCore
import MCP

// MARK: - Tree-markdown element parser

/// Extracts indexed `AXElementSummary` entries from the tree-markdown
/// produced by `AppStateEngine.snapshot(…)` for element-cache population.
enum TreeMarkdownParser {
    private static let indexedLineRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\[(\d+)\]\s+(\S+)\s*(?:"([^"]*)")?"#,
            options: []
        )
    }()

    static func parseElements(_ markdown: String) -> [AXElementSummary] {
        guard let re = indexedLineRegex else { return [] }
        var results: [AXElementSummary] = []
        for line in markdown.components(separatedBy: .newlines) {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let m = re.firstMatch(in: line, range: range),
                  m.numberOfRanges > 2,
                  let rIdx = Range(m.range(at: 1), in: line),
                  let idx = Int(line[rIdx]),
                  let rRole = Range(m.range(at: 2), in: line) else { continue }
            let role = String(line[rRole])
            var label = ""
            if m.numberOfRanges > 3, m.range(at: 3).location != NSNotFound,
               let rLabel = Range(m.range(at: 3), in: line) {
                label = String(line[rLabel])
            }
            var value: String?
            if let eqRange = line.range(of: " = \"") {
                let afterEq = line[eqRange.upperBound...]
                if let closeQuote = afterEq.firstIndex(of: "\"") {
                    value = String(afterEq[..<closeQuote])
                }
            }
            results.append(AXElementSummary(index: idx, role: role, label: label, value: value))
        }
        return results
    }
}

extension CuaDriverConnection {

    // MARK: - List Apps

    func listApps() async throws -> [AppSummary] {
        let apps = AppEnumerator.apps()
        return apps.map { info in
            AppSummary(
                pid: Int(info.pid),
                name: info.name,
                bundleId: info.bundleId
            )
        }
    }

    // MARK: - List Windows

    func listWindows(forApp app: String?) async throws -> [WindowSummary] {
        let pid: Int
        if let appRef = app, !appRef.isEmpty {
            let apps = try await listApps()
            let withPid = apps.filter { $0.pid > 0 }
            let pool = withPid.isEmpty ? apps : withPid
            let match = pool.first(where: {
                $0.name.localizedCaseInsensitiveContains(appRef)
                    || ($0.bundleId?.localizedCaseInsensitiveContains(appRef) == true)
            })
            guard let match = match, match.pid > 0 else {
                throw CuaDriverError.toolCallFailed("App '\(appRef)' not found in running apps.")
            }
            pid = match.pid

            if currentApp == nil || currentApp?.pid != pid {
                let appKey = AppFocusManager.normalizedKey(
                    bundleId: match.bundleId, appName: match.name
                )
                await AppFocusManager.shared.acquire(appKey: appKey, connectionId: connectionId)
                lockedAppKeys.insert(appKey)
                currentApp = AppContext(
                    pid: pid, appName: match.name, bundleId: match.bundleId
                )
            }
        } else if let current = currentApp {
            pid = current.pid
        } else {
            throw CuaDriverError.noAppSelected
        }

        // Use allWindows() instead of visibleWindows() because the App Worker
        // operates in the background — target apps may have windows that are
        // off-screen, minimized, or on another Space.
        let allWindows = WindowEnumerator.allWindows()
        var windows = allWindows
            .filter { $0.pid == Int32(pid) && $0.bounds.width > 1 && $0.bounds.height > 1 }
            .sorted { $0.zIndex > $1.zIndex }
            .map { info in
                WindowSummary(
                    windowId: info.id,
                    title: info.name,
                    pid: Int(info.pid)
                )
            }

        if windows.isEmpty, let cached = cachedLaunchWindows, cached.pid == pid {
            windows = cached.windows
        }

        return windows
    }

    // MARK: - Select Window

    func selectWindow(_ window: WindowSummary) async throws {
        if currentApp == nil || currentApp?.pid != window.pid {
            let nameForKey = window.appName
                ?? (window.title.isEmpty ? "pid-\(window.pid)" : window.title)
            let appKey = AppFocusManager.normalizedKey(bundleId: nil, appName: nameForKey)
            await AppFocusManager.shared.acquire(appKey: appKey, connectionId: connectionId)
            lockedAppKeys.insert(appKey)
            currentApp = AppContext(
                pid: window.pid,
                appName: window.appName ?? (window.title.isEmpty ? "App" : window.title),
                bundleId: nil
            )
        }
        currentWindow = WindowContext(windowId: window.windowId, title: window.title, pid: window.pid)
        elementCache = [:]
        lastInteractedElementIndex = nil
        lastInteractedElement = nil
    }

    // MARK: - Get Window State

    func getWindowState() async throws -> WindowStateSnapshot {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }

        let snapshot = try await engine.snapshot(
            pid: Int32(window.pid),
            windowId: UInt32(window.windowId)
        )

        let elements = TreeMarkdownParser.parseElements(snapshot.treeMarkdown)
        elementCache = Dictionary(uniqueKeysWithValues: elements.map { ($0.index, $0) })

        var screenshotBase64: String?
        var screenWidth: Int?
        var screenHeight: Int?

        if let base64 = snapshot.screenshotPngBase64 {
            screenshotBase64 = base64
            screenWidth = snapshot.screenshotWidth
            screenHeight = snapshot.screenshotHeight
        } else {
            do {
                let shot = try await capture.captureWindow(
                    windowID: CGWindowID(window.windowId),
                    format: .png,
                    quality: 80
                )
                screenshotBase64 = shot.imageData.base64EncodedString()
                screenWidth = shot.width
                screenHeight = shot.height
            } catch {
                // Screenshot not critical — continue without it
            }
        }

        return WindowStateSnapshot(
            treeMarkdown: snapshot.treeMarkdown,
            elementCount: snapshot.elementCount,
            screenshotBase64: screenshotBase64,
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )
    }

    // MARK: - Click Element

    func clickElement(_ index: Int, button: String = "left") async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }

        if button == "right" {
            throw CuaDriverError.toolCallFailed(
                "Right-click (context menu) is not available in App Worker because "
                + "context menus require the app to be frontmost, which violates the "
                + "no-foreground contract. Instead, use app_get_window_state to inspect "
                + "the element tree and click specific menu bar items or controls directly."
            )
        }

        _ = try await callCuaTool("click", [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId),
            "element_index": .int(index),
            "action": .string("press"),
        ])
        lastInteractedElementIndex = index
        lastInteractedElement = await lookupLastInteractedElement(for: window)
    }

    // MARK: - Set Value

    func setValue(elementIndex: Int, value: String) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }

        _ = try await callCuaTool("set_value", [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId),
            "element_index": .int(elementIndex),
            "value": .string(value),
        ])

        lastInteractedElementIndex = elementIndex
        lastInteractedElement = await lookupLastInteractedElement(for: window)
    }

    // MARK: - Submit Element

    func submitElement(elementIndex: Int?) async throws {
        guard let window = currentWindow else { throw CuaDriverError.noWindowSelected }

        guard let resolvedIndex = elementIndex ?? lastInteractedElementIndex else {
            throw CuaDriverError.toolCallFailed(
                "No element to submit. Pass an elementIndex from app_get_window_state or call app_set_value/app_click_element first."
            )
        }

        _ = try await callCuaTool("press_key", [
            "pid": .int(window.pid),
            "window_id": .int(window.windowId),
            "element_index": .int(resolvedIndex),
            "key": .string("return"),
        ])
        lastInteractedElementIndex = resolvedIndex
        lastInteractedElement = await lookupLastInteractedElement(for: window)
    }
}
