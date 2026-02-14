//
//  APIServerManager.swift
//  Hivecrew
//
//  Manages the lifecycle of the API server, including starting, stopping, and restarting
//

import Foundation
import SwiftData
import Security
import CryptoKit
import HivecrewAPI
import HivecrewShared

/// Manages the API server lifecycle
@MainActor
final class APIServerManager {
    
    /// Shared instance
    static let shared = APIServerManager()
    
    /// Current running task for the API server
    private var serverTask: Task<Void, Never>?
    
    /// Current server instance
    private var currentServer: HivecrewAPIServer?
    
    /// Whether the server was successfully started (passed initial startup)
    private var serverSuccessfullyStarted = false
    
    /// The port the server was started on
    private var startedPort: Int?
    
    /// Device session manager for the current server
    private var deviceSessionManager: DeviceSessionManager?
    
    /// Dependencies needed to create the server
    private var taskService: TaskService?
    private var modelContext: ModelContext?
    
    private init() {}
    
    /// Configure the manager with required dependencies
    func configure(taskService: TaskService, modelContext: ModelContext) {
        self.taskService = taskService
        self.modelContext = modelContext
    }
    
    /// Start the API server if enabled
    func startIfEnabled() {
        // Don't start if already running
        if serverSuccessfullyStarted {
            print("APIServerManager: startIfEnabled called but server already running - ignoring")
            return
        }
        
        var config = APIConfiguration.load()
        config.apiKey = APIKeyManager.retrieveAPIKey()
        
        guard config.isEnabled else {
            print("APIServerManager: API server is disabled")
            APIServerStatus.shared.serverStopped()
            return
        }
        
        print("APIServerManager: startIfEnabled - starting server on port \(config.port)")
        startServer(with: config)
    }
    
    /// Stop the API server
    func stop() {
        serverTask?.cancel()
        serverTask = nil
        currentServer = nil
        deviceSessionManager = nil
        serverSuccessfullyStarted = false
        startedPort = nil
        APIServerStatus.shared.serverStopped()
        DeviceAuthService.shared.unconfigure()
        print("APIServerManager: Server stopped")
    }
    
    /// Refresh the status display based on actual server state
    /// Call this when the Settings view appears to sync the UI
    func refreshStatus() {
        if serverSuccessfullyStarted, let port = startedPort {
            // Server was successfully started and should still be running
            APIServerStatus.shared.serverStarted(port: port)
        } else if serverTask != nil, !serverTask!.isCancelled {
            // Server task is actively running (starting up)
            // Only set to starting if not already in a failed state
            if case .failed = APIServerStatus.shared.state {
                // Keep the failed state - don't overwrite it
            } else {
                APIServerStatus.shared.serverStarting()
            }
        } else if !UserDefaults.standard.bool(forKey: "apiServerEnabled") {
            // Server is disabled
            APIServerStatus.shared.serverStopped()
        }
        // If enabled but not running and not starting, keep current state (could be failed)
    }
    
    /// Restart the server with current configuration
    func restart() {
        stop()
        
        // Brief delay before restarting
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                startIfEnabled()
            }
        }
    }
    
    /// Start the server with the given configuration
    private func startServer(with config: APIConfiguration) {
        // Don't start if already running
        if serverSuccessfullyStarted {
            print("APIServerManager: Server already running, skipping start")
            return
        }
        
        // Cancel any existing server task before starting a new one
        if serverTask != nil {
            print("APIServerManager: Cancelling existing server task")
            serverTask?.cancel()
            serverTask = nil
        }
        
        guard let taskService = taskService, let modelContext = modelContext else {
            print("APIServerManager: Not configured - call configure() first")
            APIServerStatus.shared.serverFailed(error: "Server not configured")
            return
        }
        
        // Reset startup flags
        serverSuccessfullyStarted = false
        startedPort = nil
        
        // Update status to starting
        APIServerStatus.shared.serverStarting()
        
        // Create file storage
        let fileStorage = TaskFileStorage()
        
        // Create service provider
        let serviceProvider = APIServiceProviderBridge(
            taskService: taskService,
            schedulerService: SchedulerService.shared,
            vmServiceClient: VMServiceClient.shared,
            modelContext: modelContext,
            fileStorage: fileStorage
        )
        
        // Create device session manager for pairing-based auth
        // Load or generate signing key from Keychain
        let signingKeyData = DeviceAuthKeychain.loadSigningKey() ?? {
            // Generate a fresh 256-bit signing key and persist to Keychain
            let newKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            DeviceAuthKeychain.saveSigningKey(newKey)
            return newKey
        }()
        
        let sessionManager = DeviceSessionManager(
            signingKeyData: signingKeyData,
            sessionMaxAgeDays: config.sessionMaxAgeDays
        )
        self.deviceSessionManager = sessionManager
        
        // Configure the device auth service and set as delegate
        let deviceAuthService = DeviceAuthService.shared
        deviceAuthService.configure(with: sessionManager)
        
        // Start the session manager and set delegate (must be done from a Task since it's an actor)
        Task {
            await sessionManager.start()
            await sessionManager.setDelegate(deviceAuthService)
        }
        
        // Create the server
        let server = HivecrewAPIServer(
            configuration: config,
            serviceProvider: serviceProvider,
            fileStorage: fileStorage,
            deviceSessionManager: sessionManager
        )
        
        self.currentServer = server
        let port = config.port
        
        serverTask = Task {
            do {
                // Brief delay to allow error detection
                try await Task.sleep(for: .milliseconds(100))
                
                // Start the server (this will throw if port is in use)
                try await server.start()
                
                // If start() returns normally, the server has shut down gracefully
                if !Task.isCancelled {
                    print("APIServerManager: Server shut down gracefully")
                    await MainActor.run {
                        self.serverTask = nil
                        self.currentServer = nil
                        self.serverSuccessfullyStarted = false
                        self.startedPort = nil
                        APIServerStatus.shared.serverStopped()
                    }
                }
            } catch {
                if !Task.isCancelled {
                    let errorString = String(describing: error)
                    print("APIServerManager: Server error: \(error)")
                    
                    // Check if this is a startup error (port in use) vs runtime error
                    let isStartupError = errorString.contains("bind") || 
                                         errorString.contains("address already in use") ||
                                         errorString.contains("EADDRINUSE")
                    
                    await MainActor.run {
                        if !self.serverSuccessfullyStarted {
                            // Failed during startup - report the error
                            self.serverTask = nil
                            self.currentServer = nil
                            let errorMessage = self.parseServerError(error)
                            APIServerStatus.shared.serverFailed(error: errorMessage)
                        } else if isStartupError {
                            // This shouldn't happen if server was running - ignore
                            // (might be a duplicate start attempt)
                            print("APIServerManager: Ignoring startup error for already-running server")
                        } else {
                            // Runtime error - server has stopped
                            self.serverTask = nil
                            self.currentServer = nil
                            self.serverSuccessfullyStarted = false
                            self.startedPort = nil
                            APIServerStatus.shared.serverStopped()
                        }
                    }
                }
            }
        }
        
        // Mark as running after a brief delay (if no error occurred)
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                // Only mark as running if still in starting state (no error occurred)
                if case .starting = APIServerStatus.shared.state {
                    self.serverSuccessfullyStarted = true
                    self.startedPort = port
                    APIServerStatus.shared.serverStarted(port: port)
                }
            }
        }
        
        print("APIServerManager: Server starting on port \(port)")
    }
    
    /// Parse server error to get a user-friendly message
    private func parseServerError(_ error: Error) -> String {
        let errorString = String(describing: error)
        if errorString.contains("address already in use") || errorString.contains("EADDRINUSE") {
            return "Port already in use"
        }
        if errorString.contains("permission denied") {
            return "Permission denied"
        }
        return error.localizedDescription
    }
}

// MARK: - Device Auth Signing Key Keychain Helper

/// Manages the HMAC signing key for device session tokens in the Keychain
enum DeviceAuthKeychain {
    
    private static let service = "com.pattonium.device-auth"
    private static let account = "signing-key"
    
    /// Load the signing key from Keychain
    static func loadSigningKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        
        return data
    }
    
    /// Save the signing key to Keychain
    @discardableResult
    static func saveSigningKey(_ keyData: Data) -> Bool {
        // Delete any existing key first
        deleteSigningKey()
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Delete the signing key from Keychain
    @discardableResult
    static func deleteSigningKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - Retrieval Daemon Lifecycle

/// Installs and supervises the standalone retrieval daemon.
struct RetrievalAllowlistRoot: Identifiable, Hashable {
    let path: String
    let isDefault: Bool

    var id: String { path }
}

final class RetrievalDaemonManager {
    static let shared = RetrievalDaemonManager()

    private struct DaemonInstallResult {
        let expectedVersion: String
        let binaryWasUpdated: Bool
    }

    private let launchAgentLabel = "com.hivecrew.retrievald"
    private let daemonPort = 46299
    private let daemonHost = "127.0.0.1"
    private let configFileName = "retrieval-daemon.json"
    private let binaryName = "hivecrew-retrieval-daemon"
    private let plistFileName = "com.hivecrew.retrievald.plist"
    private let tokenDefaultsKey = "retrievalDaemonAuthToken"
    private let launchAgentPathDefaultsKey = "retrievalDaemonLaunchAgentPath"
    private let expectedVersionDefaultsKey = "retrievalDaemonExpectedVersion"
    private let sourceMarkerDefaultsKey = "retrievalDaemonSourceMarker"
    private let enabledDefaultsKey = "retrievalDaemonEnabled"
    private let allowlistRootsDefaultsKey = "retrievalAllowlistRoots"
    private let healthCheckTimeout: TimeInterval = 0.7
    private let launchctlTimeoutSeconds: TimeInterval = 4.0
    private let deferredUpdateDelaySeconds: TimeInterval = 6.0
    private let lifecycleStateQueue = DispatchQueue(label: "com.hivecrew.retrievald.lifecycle-state")
    private var startupTask: Task<Void, Never>?
    private var deferredUpdateTask: Task<Void, Never>?

    private init() {}

    func startIfEnabled() {
        if !UserDefaults.standard.bool(forKey: enabledDefaultsKey) && UserDefaults.standard.object(forKey: enabledDefaultsKey) != nil {
            return
        }

        let startedTask = lifecycleStateQueue.sync { () -> Task<Void, Never>? in
            guard startupTask == nil else {
                return nil
            }

            let task = Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                defer {
                    self.lifecycleStateQueue.async {
                        self.startupTask = nil
                    }
                }

                do {
                    let uid = getuid()
                    let serviceTarget = "gui/\(uid)/\(self.launchAgentLabel)"
                    // Keep launch responsive: when daemon is already running, defer
                    // any update/restart work to a delayed background maintenance pass.
                    if self.isLaunchAgentLoaded(serviceTarget: serviceTarget) {
                        self.scheduleDeferredUpdateCheckIfNeeded()
                        return
                    }
                    let install = try self.installOrUpdate()
                    if install.binaryWasUpdated {
                        try self.unloadLaunchAgentIfPresent()
                    }
                    try self.loadLaunchAgent()
                    // Never probe daemon health on app launch path.
                    // Startup should stay responsive even if daemon takes time to come up.
                    UserDefaults.standard.set(install.expectedVersion, forKey: self.expectedVersionDefaultsKey)
                } catch {
                    print("RetrievalDaemonManager: Failed to start retrieval daemon: \(error)")
                }
            }

            startupTask = task
            return task
        }

        guard startedTask != nil else {
            return
        }
    }

    private func scheduleDeferredUpdateCheckIfNeeded() {
        let scheduledTask = lifecycleStateQueue.sync { () -> Task<Void, Never>? in
            guard deferredUpdateTask == nil else {
                return nil
            }

            let task = Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                defer {
                    self.lifecycleStateQueue.async {
                        self.deferredUpdateTask = nil
                    }
                }

                try? await Task.sleep(for: .milliseconds(Int(self.deferredUpdateDelaySeconds * 1_000)))
                guard !Task.isCancelled else { return }
                guard self.isDaemonEnabledInDefaults() else { return }

                do {
                    let install = try self.installOrUpdate()
                    UserDefaults.standard.set(install.expectedVersion, forKey: self.expectedVersionDefaultsKey)
                    guard install.binaryWasUpdated else { return }

                    try self.unloadLaunchAgentIfPresent()
                    try self.loadLaunchAgent()
                    _ = await self.waitForHealthyState(maxAttempts: 8)
                    try await self.ensureExpectedDaemonVersion(install.expectedVersion)
                } catch {
                    print("RetrievalDaemonManager: Deferred update check failed: \(error)")
                }
            }

            deferredUpdateTask = task
            return task
        }

        guard scheduledTask != nil else {
            return
        }
    }

    private func isDaemonEnabledInDefaults() -> Bool {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: enabledDefaultsKey),
           defaults.object(forKey: enabledDefaultsKey) != nil {
            return false
        }
        return true
    }

    private func cancelLifecycleTasks() {
        lifecycleStateQueue.sync {
            startupTask?.cancel()
            startupTask = nil
            deferredUpdateTask?.cancel()
            deferredUpdateTask = nil
        }
    }

    func restart() {
        cancelLifecycleTasks()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let install = try installOrUpdate()
                try unloadLaunchAgentIfPresent()
                try loadLaunchAgent()
                _ = await waitForHealthyState(maxAttempts: 8)
                try await ensureExpectedDaemonVersion(install.expectedVersion)
            } catch {
                print("RetrievalDaemonManager: Failed to restart retrieval daemon: \(error)")
            }
        }
    }

    func stop() {
        cancelLifecycleTasks()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try unloadLaunchAgentIfPresent()
            } catch {
                print("RetrievalDaemonManager: Failed to unload launch agent: \(error)")
            }
        }
    }

    func daemonBaseURL() -> URL {
        URL(string: "http://\(daemonHost):\(daemonPort)")!
    }

    func allowlistRootsForDisplay() -> [RetrievalAllowlistRoot] {
        let defaults = defaultAllowlistRoots()
        let defaultSet = Set(defaults.map(canonicalizedDirectoryPath(_:)))
        return retrievalAllowlistRoots().map { path in
            RetrievalAllowlistRoot(
                path: path,
                isDefault: defaultSet.contains(canonicalizedDirectoryPath(path))
            )
        }
    }

    @discardableResult
    func addAllowlistRoot(_ rawPath: String) -> Bool {
        let normalized = canonicalizedDirectoryPath(rawPath)
        guard !normalized.isEmpty else { return false }

        var current = retrievalAllowlistRoots()
        let existing = Set(current.map(canonicalizedDirectoryPath(_:)))
        guard !existing.contains(normalized) else { return false }

        current.append(normalized)
        persistAllowlistRoots(current)
        return true
    }

    @discardableResult
    func removeAllowlistRoot(_ rawPath: String) -> Bool {
        let normalized = canonicalizedDirectoryPath(rawPath)
        guard !normalized.isEmpty else { return false }

        let defaultSet = Set(defaultAllowlistRoots().map(canonicalizedDirectoryPath(_:)))
        // Keep Desktop/Documents/Downloads always enabled by default.
        guard !defaultSet.contains(normalized) else { return false }

        let current = retrievalAllowlistRoots()
        let filtered = current.filter { canonicalizedDirectoryPath($0) != normalized }
        guard filtered.count != current.count else { return false }

        persistAllowlistRoots(filtered)
        return true
    }

    /// Push current allowlist roots into the running daemon without restarting it.
    /// This applies new scopes immediately and optionally schedules a backfill pass.
    func applyAllowlistRootsToRunningDaemon(triggerBackfill: Bool = true) async {
        let roots = retrievalAllowlistRoots()
        updateDaemonConfigAllowlistRootsIfPresent(roots)
        do {
            let token = try daemonAuthToken()
            let configurePayload: [String: Any] = [
                "scopes": [[
                    "sourceType": "file",
                    "includePathsOrHandles": roots,
                    "excludePathsOrHandles": [],
                    "enabled": true,
                ]]
            ]
            let configureBody = try JSONSerialization.data(withJSONObject: configurePayload, options: [])

            var configureRequest = URLRequest(url: daemonBaseURL().appending(path: "/api/v1/retrieval/scopes"))
            configureRequest.httpMethod = "POST"
            configureRequest.setValue(token, forHTTPHeaderField: "X-Retrieval-Token")
            configureRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            configureRequest.httpBody = configureBody
            _ = try await performDaemonRequest(configureRequest)

            if triggerBackfill {
                var triggerRequest = URLRequest(url: daemonBaseURL().appending(path: "/api/v1/retrieval/backfill/trigger"))
                triggerRequest.httpMethod = "POST"
                triggerRequest.setValue(token, forHTTPHeaderField: "X-Retrieval-Token")
                triggerRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                triggerRequest.httpBody = Data("{}".utf8)
                _ = try await performDaemonRequest(triggerRequest)
            }
        } catch {
            // Best effort: roots are persisted and daemon config is updated.
            // Live application may fail if daemon is still booting or unavailable.
            print("RetrievalDaemonManager: Failed to apply allowlist roots live: \(error)")
        }
    }

    func daemonAuthToken() throws -> String {
        let token = UserDefaults.standard.string(forKey: tokenDefaultsKey)
        if let token, !token.isEmpty {
            return token
        }
        let configURL = daemonConfigURL()
        guard
            let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["authToken"] as? String,
            !token.isEmpty
        else {
            throw NSError(domain: "RetrievalDaemonManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing retrieval daemon auth token"])
        }
        UserDefaults.standard.set(token, forKey: tokenDefaultsKey)
        return token
    }

    private func installOrUpdate() throws -> DaemonInstallResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: daemonDirectory(), withIntermediateDirectories: true)

        let sourceBinary = try resolveSourceBinary()
        let destinationBinary = daemonBinaryURL()
        let sourceBinaryVersion = try daemonBinaryVersion(at: sourceBinary)
        // Use the actual source binary digest as the install marker.
        // A source-tree hash can drift ahead of the bundled binary and trigger
        // stale daemon rollbacks when the app binary was not rebuilt yet.
        let sourceMarker = sourceBinaryVersion
        let previousSourceMarker = persistedDaemonSourceMarker()
        let binaryWasUpdated = previousSourceMarker != sourceMarker || !fileManager.fileExists(atPath: destinationBinary.path)

        if binaryWasUpdated {
            try replaceDaemonBinaryAtomically(
                from: sourceBinary,
                to: destinationBinary,
                fileManager: fileManager
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationBinary.path)
        let expectedVersion = (try? daemonBinaryVersion(at: destinationBinary))
            ?? UserDefaults.standard.string(forKey: expectedVersionDefaultsKey)
            ?? sourceBinaryVersion

        let token = UserDefaults.standard.string(forKey: tokenDefaultsKey) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(token, forKey: tokenDefaultsKey)

        let config: [String: Any] = [
            "host": daemonHost,
            "port": daemonPort,
            "authToken": token,
            "daemonVersion": expectedVersion,
            "sourceMarker": sourceMarker,
            "indexingProfile": UserDefaults.standard.string(forKey: "retrievalIndexingProfile") ?? "balanced",
            "startupAllowlistRoots": retrievalAllowlistRoots(),
            "queueBatchSize": 24,
        ]
        let configData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        try configData.write(to: daemonConfigURL(), options: .atomic)

        let launchPlist = launchAgentPlistContents(binaryPath: destinationBinary.path, configPath: daemonConfigURL().path)
        let launchAgentPlistURL = try writeLaunchAgentPlist(launchPlist)
        UserDefaults.standard.set(launchAgentPlistURL.path, forKey: launchAgentPathDefaultsKey)
        UserDefaults.standard.set(sourceMarker, forKey: sourceMarkerDefaultsKey)
        UserDefaults.standard.set(expectedVersion, forKey: expectedVersionDefaultsKey)
        return DaemonInstallResult(expectedVersion: expectedVersion, binaryWasUpdated: binaryWasUpdated)
    }

    private func replaceDaemonBinaryAtomically(
        from sourceBinary: URL,
        to destinationBinary: URL,
        fileManager: FileManager
    ) throws {
        let stagedURL = destinationBinary
            .deletingLastPathComponent()
            .appendingPathComponent("\(binaryName).staged-\(ProcessInfo.processInfo.globallyUniqueString)")

        defer {
            try? fileManager.removeItem(at: stagedURL)
        }

        try fileManager.copyItem(at: sourceBinary, to: stagedURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedURL.path)

        if fileManager.fileExists(atPath: destinationBinary.path) {
            _ = try fileManager.replaceItemAt(destinationBinary, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationBinary)
        }
    }

    private func persistedDaemonSourceMarker() -> String? {
        if let marker = UserDefaults.standard.string(forKey: sourceMarkerDefaultsKey), !marker.isEmpty {
            return marker
        }
        let configURL = daemonConfigURL()
        guard
            let data = try? Data(contentsOf: configURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let marker = json["sourceMarker"] as? String,
            !marker.isEmpty
        else {
            return nil
        }
        return marker
    }

    private func loadLaunchAgent() throws {
        let uid = getuid()
        let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"

        // If the service is already loaded, keep it running as-is.
        // Repeated startIfEnabled() calls can happen when app windows re-appear;
        // forcing kickstart here resets in-memory daemon indexing state.
        if isLaunchAgentLoaded(serviceTarget: serviceTarget) {
            return
        }

        do {
            try runLaunchctl(["bootstrap", "gui/\(uid)", resolvedLaunchAgentURL().path], allowAlreadyLoaded: true)
        } catch {
            // launchctl can report EIO for bootstrap while the service is already present.
            if isLaunchAgentLoaded(serviceTarget: serviceTarget) {
                return
            }
            throw error
        }
        try runLaunchctl(["kickstart", "-k", serviceTarget], allowAlreadyLoaded: true)
    }

    private func unloadLaunchAgentIfPresent() throws {
        let uid = getuid()
        try runLaunchctl(["bootout", "gui/\(uid)", resolvedLaunchAgentURL().path], allowAlreadyLoaded: true)
        // Try by label as a fallback in case the plist path changed.
        try runLaunchctl(["bootout", "gui/\(uid)/\(launchAgentLabel)"], allowAlreadyLoaded: true)
    }

    private func runLaunchctl(_ arguments: [String], allowAlreadyLoaded: Bool) throws {
        let result = try runLaunchctlProcess(
            arguments,
            captureStdout: false,
            captureStderr: true
        )

        guard result.terminationStatus == 0 else {
            let errorOutput = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if allowAlreadyLoaded && isIgnorableLaunchctlErrorOutput(errorOutput) {
                return
            }
            throw NSError(
                domain: "RetrievalDaemonManager",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorOutput.isEmpty ? "launchctl command failed: \(arguments.joined(separator: " "))" : errorOutput]
            )
        }
    }

    private func isLaunchAgentLoaded(serviceTarget: String) -> Bool {
        do {
            let result = try runLaunchctlProcess(
                ["print", serviceTarget],
                captureStdout: false,
                captureStderr: false
            )
            return result.terminationStatus == 0
        } catch {
            return false
        }
    }

    private struct LaunchctlProcessResult {
        let terminationStatus: Int32
        let standardOutput: String
        let standardError: String
    }

    private func runLaunchctlProcess(
        _ arguments: [String],
        captureStdout: Bool,
        captureStderr: Bool
    ) throws -> LaunchctlProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        var stdoutURL: URL?
        var stderrURL: URL?
        var stdoutHandle: FileHandle?
        var stderrHandle: FileHandle?
        var nullStdoutHandle: FileHandle?
        var nullStderrHandle: FileHandle?

        if captureStdout {
            let url = temporaryCaptureURL(prefix: "hivecrew-launchctl-stdout")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            stdoutURL = url
            stdoutHandle = try FileHandle(forWritingTo: url)
            process.standardOutput = stdoutHandle
        } else if let devNull = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null")) {
            nullStdoutHandle = devNull
            process.standardOutput = devNull
        }

        if captureStderr {
            let url = temporaryCaptureURL(prefix: "hivecrew-launchctl-stderr")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            stderrURL = url
            stderrHandle = try FileHandle(forWritingTo: url)
            process.standardError = stderrHandle
        } else if let devNull = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null")) {
            nullStderrHandle = devNull
            process.standardError = devNull
        }

        defer {
            try? stdoutHandle?.close()
            try? stderrHandle?.close()
            try? nullStdoutHandle?.close()
            try? nullStderrHandle?.close()
            if let stdoutURL {
                try? FileManager.default.removeItem(at: stdoutURL)
            }
            if let stderrURL {
                try? FileManager.default.removeItem(at: stderrURL)
            }
        }

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }
        try process.run()

        let timeout = DispatchTime.now() + launchctlTimeoutSeconds
        guard completion.wait(timeout: timeout) == .success else {
            process.terminate()
            throw NSError(
                domain: "RetrievalDaemonManager",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "launchctl command timed out: \(arguments.joined(separator: " "))"]
            )
        }
        process.terminationHandler = nil

        try? stdoutHandle?.close()
        stdoutHandle = nil
        try? stderrHandle?.close()
        stderrHandle = nil

        let standardOutput = stdoutURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let standardError = stderrURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return LaunchctlProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }

    private func temporaryCaptureURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(ProcessInfo.processInfo.globallyUniqueString)")
    }

    private func isIgnorableLaunchctlErrorOutput(_ errorOutput: String) -> Bool {
        guard !errorOutput.isEmpty else { return false }
        let normalized = errorOutput.lowercased()
        return normalized.contains("already")
            || normalized.contains("not loaded")
            || normalized.contains("could not find service")
            || normalized.contains("service not found")
            || normalized.contains("no such process")
    }

    private func waitForHealthyState(maxAttempts: Int) async -> Bool {
        for attempt in 0..<maxAttempts {
            if await isHealthy() { return true }
            let delayMs = min(1200, 150 * (attempt + 1))
            try? await Task.sleep(for: .milliseconds(delayMs))
        }
        return false
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: daemonBaseURL().appending(path: "/health"))
        request.timeoutInterval = healthCheckTimeout
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func runningDaemonVersion() async -> String? {
        struct HealthPayload: Decodable {
            let daemonVersion: String
        }

        var request = URLRequest(url: daemonBaseURL().appending(path: "/health"))
        request.timeoutInterval = healthCheckTimeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let payload = try JSONDecoder().decode(HealthPayload.self, from: data)
            return payload.daemonVersion
        } catch {
            return nil
        }
    }

    private func ensureExpectedDaemonVersion(_ expectedVersion: String) async throws {
        guard !expectedVersion.isEmpty else { return }
        guard let runningVersion = await runningDaemonVersion() else { return }
        guard runningVersion != expectedVersion else { return }
        if shouldTreatLegacyHealthVersionAsCurrent(runningVersion: runningVersion, expectedVersion: expectedVersion) {
            return
        }

        print("RetrievalDaemonManager: Detected daemon version mismatch (running \(runningVersion), expected \(expectedVersion)). Restarting daemon.")
        _ = try installOrUpdate()
        try await forceRestartLaunchAgent()
        if let refreshed = await runningDaemonVersion(), refreshed == expectedVersion {
            return
        }
        if let refreshed = await runningDaemonVersion(),
           shouldTreatLegacyHealthVersionAsCurrent(runningVersion: refreshed, expectedVersion: expectedVersion) {
            return
        }

        print("RetrievalDaemonManager: Daemon still on old version after hard restart, retrying once.")
        _ = try installOrUpdate()
        try await forceRestartLaunchAgent()
        if let refreshed = await runningDaemonVersion(), refreshed == expectedVersion {
            return
        }
        if let refreshed = await runningDaemonVersion(),
           shouldTreatLegacyHealthVersionAsCurrent(runningVersion: refreshed, expectedVersion: expectedVersion) {
            return
        }

        throw NSError(
            domain: "RetrievalDaemonManager",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Daemon version mismatch after restart."]
        )
    }

    private func forceRestartLaunchAgent() async throws {
        let uid = getuid()
        let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"

        // Aggressively tear down any existing daemon instance first.
        try runLaunchctl(["kill", "SIGKILL", serviceTarget], allowAlreadyLoaded: true)
        do {
            try runLaunchctl(["bootout", serviceTarget], allowAlreadyLoaded: true)
        } catch {
            if !isIgnorableBootoutFailure(error, serviceTarget: serviceTarget) {
                throw error
            }
            print("RetrievalDaemonManager: Ignoring label bootout failure: \(error.localizedDescription)")
        }
        do {
            try runLaunchctl(["bootout", "gui/\(uid)", resolvedLaunchAgentURL().path], allowAlreadyLoaded: true)
        } catch {
            if !isIgnorableBootoutFailure(error, serviceTarget: serviceTarget) {
                throw error
            }
            print("RetrievalDaemonManager: Ignoring path bootout failure: \(error.localizedDescription)")
        }
        try? await Task.sleep(for: .milliseconds(250))

        // If launchd still thinks the service is loaded, kickstart in-place. Otherwise bootstrap it.
        if isLaunchAgentLoaded(serviceTarget: serviceTarget) {
            try runLaunchctl(["kickstart", "-k", serviceTarget], allowAlreadyLoaded: true)
        } else {
            try loadLaunchAgent()
        }
        _ = await waitForHealthyState(maxAttempts: 8)
    }

    private func isIgnorableBootoutFailure(_ error: Error, serviceTarget: String) -> Bool {
        let message = (error as NSError).localizedDescription.lowercased()
        if message.contains("input/output error") || message.contains("boot-out failed: 5") {
            // launchctl can emit EIO during transitional states; proceed to kickstart/load path.
            return true
        }
        // If launchd no longer reports the service, the bootout failure is effectively harmless.
        return !isLaunchAgentLoaded(serviceTarget: serviceTarget)
    }

    private func shouldTreatLegacyHealthVersionAsCurrent(runningVersion: String, expectedVersion: String) -> Bool {
        guard !isHashVersion(runningVersion) else { return false }
        guard let binaryVersion = runningDaemonBinaryVersion(), binaryVersion == expectedVersion else { return false }
        print(
            "RetrievalDaemonManager: Health reported legacy daemon version '\(runningVersion)', " +
            "but running binary hash matches expected '\(expectedVersion)'."
        )
        return true
    }

    private func runningDaemonBinaryVersion() -> String? {
        let uid = getuid()
        let serviceTarget = "gui/\(uid)/\(launchAgentLabel)"
        let programPath = launchAgentProgramPath(serviceTarget: serviceTarget) ?? daemonBinaryURL().path
        let url = URL(fileURLWithPath: programPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? daemonBinaryVersion(at: url)
    }

    private func launchAgentProgramPath(serviceTarget: String) -> String? {
        do {
            let result = try runLaunchctlProcess(
                ["print", serviceTarget],
                captureStdout: true,
                captureStderr: false
            )
            guard result.terminationStatus == 0 else { return nil }
            let text = result.standardOutput
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("program = ") {
                    return String(trimmed.dropFirst("program = ".count))
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func isHashVersion(_ value: String) -> Bool {
        let regex = try? NSRegularExpression(pattern: "^[0-9a-f]{16}$")
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex?.firstMatch(in: value, options: [], range: range) != nil
    }

    private func retrievalAllowlistRoots() -> [String] {
        let defaults = defaultAllowlistRoots()
        let stored = (UserDefaults.standard.array(forKey: allowlistRootsDefaultsKey) as? [String]) ?? []
        let merged = deduplicatedCanonicalPaths(defaults + stored)
        if merged.isEmpty {
            return defaults
        }
        return merged
    }

    private func persistAllowlistRoots(_ roots: [String]) {
        let normalized = deduplicatedCanonicalPaths(roots)
        UserDefaults.standard.set(normalized, forKey: allowlistRootsDefaultsKey)
        updateDaemonConfigAllowlistRootsIfPresent(normalized)
    }

    private func updateDaemonConfigAllowlistRootsIfPresent(_ roots: [String]) {
        let configURL = daemonConfigURL()
        guard let data = try? Data(contentsOf: configURL) else { return }
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        json["startupAllowlistRoots"] = roots
        guard let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return }
        try? updated.write(to: configURL, options: .atomic)
    }

    private func performDaemonRequest(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "RetrievalDaemonManager",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Daemon request failed for \(request.url?.absoluteString ?? "unknown URL")"]
            )
        }
        return data
    }

    private func defaultAllowlistRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return deduplicatedCanonicalPaths([
            home.appendingPathComponent("Desktop").path,
            home.appendingPathComponent("Documents").path,
            home.appendingPathComponent("Downloads").path,
        ])
    }

    private func deduplicatedCanonicalPaths(_ roots: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for root in roots {
            let normalized = canonicalizedDirectoryPath(root)
            guard !normalized.isEmpty else { continue }
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            output.append(normalized)
        }
        return output
    }

    private func canonicalizedDirectoryPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func deterministicDaemonSourceMarker() -> String? {
        guard let repositoryRoot = resolveRepositoryRootFromSourcePath() else {
            return nil
        }
        let sourceRoots = [
            "Packages/HivecrewRetrievalSystem/Sources/HivecrewRetrievalDaemon",
            "Packages/HivecrewRetrievalSystem/Sources/HivecrewRetrievalCore",
            "Packages/HivecrewRetrievalSystem/Sources/HivecrewRetrievalProtocol",
        ]
        let fileManager = FileManager.default
        var manifestLines: [String] = []

        for relativeRoot in sourceRoots {
            let rootURL = repositoryRoot.appendingPathComponent(relativeRoot, isDirectory: true)
            guard fileManager.fileExists(atPath: rootURL.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "swift" else { continue }
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { continue }
                let relativePath = fileURL.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
                let fileDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                manifestLines.append("\(relativePath)|\(fileDigest)")
            }
        }

        guard !manifestLines.isEmpty else {
            return nil
        }
        let manifest = manifestLines.sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(digest.prefix(16))
    }

    private func resolveRepositoryRootFromSourcePath() -> URL? {
        let fileURL = URL(fileURLWithPath: #filePath)
        var candidate = fileURL.deletingLastPathComponent()
        for _ in 0..<12 {
            let marker = candidate
                .appendingPathComponent("Packages", isDirectory: true)
                .appendingPathComponent("HivecrewRetrievalSystem", isDirectory: true)
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("HivecrewRetrievalDaemon", isDirectory: true)
            if FileManager.default.fileExists(atPath: marker.path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }
        return nil
    }

    private func launchAgentPlistContents(binaryPath: String, configPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>--config</string>
                <string>\(configPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>WorkingDirectory</key>
            <string>\(daemonDirectory().path)</string>
            <key>StandardOutPath</key>
            <string>\(AppPaths.retrievalLogsDirectory.appendingPathComponent("daemon.stdout.log").path)</string>
            <key>StandardErrorPath</key>
            <string>\(AppPaths.retrievalLogsDirectory.appendingPathComponent("daemon.stderr.log").path)</string>
        </dict>
        </plist>
        """
    }

    private func daemonDirectory() -> URL {
        AppPaths.retrievalDaemonDirectory
    }

    private func daemonBinaryURL() -> URL {
        daemonDirectory().appendingPathComponent(binaryName)
    }

    private func daemonConfigURL() -> URL {
        daemonDirectory().appendingPathComponent(configFileName)
    }

    private func resolvedLaunchAgentURL() -> URL {
        let defaults = UserDefaults.standard
        if let savedPath = defaults.string(forKey: launchAgentPathDefaultsKey), !savedPath.isEmpty {
            return URL(fileURLWithPath: savedPath)
        }
        let homeAgentURL = launchAgentURLInHomeLibrary()
        if FileManager.default.fileExists(atPath: homeAgentURL.path) {
            return homeAgentURL
        }
        return launchAgentURLInDaemonDirectory()
    }

    private func launchAgentURLInHomeLibrary() -> URL {
        AppPaths.realHomeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(plistFileName)
    }

    private func launchAgentURLInDaemonDirectory() -> URL {
        daemonDirectory().appendingPathComponent(plistFileName)
    }

    private func writeLaunchAgentPlist(_ contents: String) throws -> URL {
        let fileManager = FileManager.default
        let candidateURLs = [
            launchAgentURLInHomeLibrary(),
            launchAgentURLInDaemonDirectory(),
        ]

        var lastPermissionError: Error?
        for candidateURL in candidateURLs {
            do {
                try fileManager.createDirectory(
                    at: candidateURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try contents.write(to: candidateURL, atomically: true, encoding: .utf8)
                return candidateURL
            } catch {
                if isPermissionDenied(error) {
                    lastPermissionError = error
                    continue
                }
                throw error
            }
        }

        if let lastPermissionError {
            throw lastPermissionError
        }
        throw NSError(
            domain: "RetrievalDaemonManager",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Could not write retrieval launch agent plist to any supported location."]
        )
    }

    private func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EACCES) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSCocoaErrorDomain && underlying.code == NSFileWriteNoPermissionError {
                return true
            }
            if underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EACCES) {
                return true
            }
        }
        return false
    }

    private func resolveSourceBinary() throws -> URL {
        if let overridePath = ProcessInfo.processInfo.environment["HIVECREW_RETRIEVAL_DAEMON_PATH"] {
            let url = URL(fileURLWithPath: overridePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: binaryName) {
            return auxiliary
        }
        if let bundled = Bundle.main.url(forResource: binaryName, withExtension: nil) {
            return bundled
        }
        throw NSError(
            domain: "RetrievalDaemonManager",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate bundled retrieval daemon binary."]
        )
    }

    private func daemonBinaryVersion(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}
