//
//  AppTool.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation
import AppKit
import HivecrewAgentProtocol

/// Tool for application management and launching
final class AppTool {
    private let logger = AgentLogger.shared
    
    /// Open an application by bundle ID or name
    func openApp(bundleId: String?, appName: String?) throws {
        if let bundleId = bundleId {
            logger.log("Opening app with bundle ID: \(bundleId)")
            
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "App not found: \(bundleId)")
            }
            
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            
            let semaphore = DispatchSemaphore(value: 0)
            var launchError: (any Error)?
            
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                launchError = error
                semaphore.signal()
            }
            
            semaphore.wait()
            
            if let error = launchError {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to launch app: \(error.localizedDescription)")
            }
        } else if let appName = appName {
            logger.log("Opening app with name: \(appName)")
            
            // Find the app URL using multiple strategies
            guard let url = findAppURL(for: appName) else {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "App not found: \(appName)")
            }
            
            logger.log("Found app at: \(url.path)")
            
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            
            let semaphore = DispatchSemaphore(value: 0)
            var launchError: (any Error)?
            
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                launchError = error
                semaphore.signal()
            }
            
            semaphore.wait()
            
            if let error = launchError {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to launch app: \(error.localizedDescription)")
            }
        } else {
            throw AgentError(code: AgentError.invalidParams, message: "Either bundleId or appName must be provided")
        }
    }
    
    /// Open a file with the default or specified application
    func openFile(path: String, withApp: String?) throws {
        logger.log("Opening file: \(path)")
        
        let resolvedPath = resolvePath(path)
        let fileURL = URL(fileURLWithPath: resolvedPath)
        
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "File not found: \(path)")
        }
        
        if let appBundleId = withApp {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleId) else {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "App not found: \(appBundleId)")
            }
            
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            
            let semaphore = DispatchSemaphore(value: 0)
            var openError: (any Error)?
            
            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config) { _, error in
                openError = error
                semaphore.signal()
            }
            
            semaphore.wait()
            
            if let error = openError {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to open file: \(error.localizedDescription)")
            }
        } else {
            // Use shell `open` command - NSWorkspace.shared.open() doesn't work reliably in daemon context
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [resolvedPath]
            
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to run open command: \(error.localizedDescription)")
            }
            
            if process.terminationStatus != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to open file: \(stderr)")
            }
        }
    }
    
    /// Open a URL
    func openUrl(_ urlString: String) throws {
        logger.log("Opening URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            throw AgentError(code: AgentError.invalidParams, message: "Invalid URL: \(urlString)")
        }
        
        let success = NSWorkspace.shared.open(url)
        if !success {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to open URL: \(urlString)")
        }
    }
    
    /// Activate (bring to front) an application by bundle ID
    func activateApp(bundleId: String) throws {
        logger.log("Activating app: \(bundleId)")
        
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard let app = apps.first else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "App not running: \(bundleId)")
        }
        
        let success = app.activate()
        if !success {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to activate app: \(bundleId)")
        }
    }
    
    /// Get information about the frontmost application
    func getFrontmostApp() throws -> [String: Any] {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "No frontmost application")
        }
        
        var result: [String: Any] = [:]
        result["bundleId"] = app.bundleIdentifier
        result["appName"] = app.localizedName
        
        // Try to get the window title using accessibility APIs
        if let windowTitle = getActiveWindowTitle(for: app) {
            result["windowTitle"] = windowTitle
        }
        
        return result
    }
    
    /// List all running applications
    func listRunningApps() throws -> [[String: Any]] {
        let apps = NSWorkspace.shared.runningApplications
        
        return apps.filter { $0.activationPolicy == .regular }.map { app in
            var info: [String: Any] = [:]
            info["bundleId"] = app.bundleIdentifier
            info["appName"] = app.localizedName ?? "Unknown"
            info["pid"] = app.processIdentifier
            return info
        }
    }
    
    private func getActiveWindowTitle(for app: NSRunningApplication) -> String? {
        // Use accessibility API to get window title
        let pid = app.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)
        
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        
        guard result == .success, let window = focusedWindow else {
            return nil
        }
        
        var title: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        
        guard titleResult == .success, let titleString = title as? String else {
            return nil
        }
        
        return titleString
    }
    
    // MARK: - App Lookup Helpers
    
    /// Find an app URL by name using multiple strategies
    private func findAppURL(for appName: String) -> URL? {
        // Normalize the app name (remove .app suffix if present)
        let normalizedName = appName.hasSuffix(".app")
            ? String(appName.dropLast(4))
            : appName
        
        // Strategy 1: Check common paths with exact name
        if let url = findAppInCommonPaths(name: normalizedName) {
            return url
        }
        
        // Strategy 2: Case-insensitive search in common paths
        if let url = findAppInCommonPathsCaseInsensitive(name: normalizedName) {
            return url
        }
        
        // Strategy 3: Use Spotlight (mdfind) to find by name
        if let url = findAppWithSpotlight(name: normalizedName) {
            return url
        }
        
        // Strategy 4: Check running apps and try to find a match
        if let url = findAppInRunningApps(name: normalizedName) {
            return url
        }
        
        return nil
    }
    
    /// Check common application paths for an exact match
    private func findAppInCommonPaths(name: String) -> URL? {
        let appPaths = [
            "/Applications/\(name).app",
            "/System/Applications/\(name).app",
            "/Applications/Utilities/\(name).app",
            "/System/Applications/Utilities/\(name).app",
            "\(NSHomeDirectory())/Applications/\(name).app"
        ]
        
        for path in appPaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        
        return nil
    }
    
    /// Case-insensitive search in common application directories
    private func findAppInCommonPathsCaseInsensitive(name: String) -> URL? {
        let searchDirs = [
            "/Applications",
            "/System/Applications",
            "/Applications/Utilities",
            "/System/Applications/Utilities",
            "\(NSHomeDirectory())/Applications"
        ]
        
        let lowercaseName = name.lowercased()
        
        for dir in searchDirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                continue
            }
            
            for item in contents where item.hasSuffix(".app") {
                let appBaseName = String(item.dropLast(4))
                if appBaseName.lowercased() == lowercaseName {
                    return URL(fileURLWithPath: "\(dir)/\(item)")
                }
            }
        }
        
        return nil
    }
    
    /// Use Spotlight to find an app by name
    private func findAppWithSpotlight(name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [
            "kMDItemKind == 'Application' && (kMDItemDisplayName == '\(name)' || kMDItemFSName == '\(name).app'ci)"
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let paths = output.components(separatedBy: .newlines)
                    .filter { !$0.isEmpty && $0.hasSuffix(".app") }
                
                // Prefer apps in /Applications or /System/Applications
                for path in paths {
                    if path.hasPrefix("/Applications") || path.hasPrefix("/System/Applications") {
                        return URL(fileURLWithPath: path)
                    }
                }
                
                // Fall back to first result
                if let firstPath = paths.first {
                    return URL(fileURLWithPath: firstPath)
                }
            }
        } catch {
            logger.warning("Spotlight search failed: \(error)")
        }
        
        return nil
    }
    
    /// Check running apps for a matching name and get their URL
    private func findAppInRunningApps(name: String) -> URL? {
        let lowercaseName = name.lowercased()
        
        for app in NSWorkspace.shared.runningApplications {
            guard let localizedName = app.localizedName,
                  let bundleId = app.bundleIdentifier else {
                continue
            }
            
            if localizedName.lowercased() == lowercaseName {
                return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            }
        }
        
        return nil
    }
    
    /// Resolve a path, handling tilde expansion and relative paths within the shared folder
    private func resolvePath(_ path: String) -> String {
        // Handle tilde expansion (e.g., ~/Desktop/file.txt)
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        
        // Absolute paths are used as-is
        if path.hasPrefix("/") {
            return path
        }
        
        // Relative paths are resolved against the shared folder
        return (AgentProtocol.sharedFolderMountPath as NSString).appendingPathComponent(path)
    }
}
