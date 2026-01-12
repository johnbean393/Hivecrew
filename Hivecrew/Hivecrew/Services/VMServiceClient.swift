//
//  VMServiceClient.swift
//  Hivecrew
//
//  Created by Hivecrew on 1/10/26.
//

import Foundation
import Combine

// MARK: - VM Types (App-side copies)

/// VM Status enum matching the XPC service
enum VMStatus: Int, Codable, CaseIterable {
    case stopped = 0
    case booting = 1
    case ready = 2
    case busy = 3
    case suspending = 4
    case error = 5
    
    var displayName: String {
        switch self {
        case .stopped: return "Stopped"
        case .booting: return "Booting"
        case .ready: return "Ready"
        case .busy: return "Busy"
        case .suspending: return "Suspending"
        case .error: return "Error"
        }
    }
    
}

/// VM Configuration
struct VMConfiguration: Codable {
    var cpuCount: Int
    var memorySize: UInt64
    var diskSize: UInt64
    var displayName: String?
    
    init(cpuCount: Int = 2, memorySize: UInt64 = 4 * 1024 * 1024 * 1024, diskSize: UInt64 = 64 * 1024 * 1024 * 1024, displayName: String? = nil) {
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.diskSize = diskSize
        self.displayName = displayName
    }
    
    var memoryGB: Int { Int(memorySize / (1024 * 1024 * 1024)) }
    var diskGB: Int { Int(diskSize / (1024 * 1024 * 1024)) }
}

/// VM Information
struct VMInfo: Identifiable, Codable {
    let id: String
    var name: String
    var status: VMStatus
    let createdAt: Date
    var lastUsedAt: Date?
    let bundlePath: String
    var configuration: VMConfiguration
    
    static func fromDictionary(_ dict: [String: Any]) -> VMInfo? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String,
              let statusRaw = dict["status"] as? Int,
              let status = VMStatus(rawValue: statusRaw),
              let createdAtInterval = dict["createdAt"] as? TimeInterval,
              let bundlePath = dict["bundlePath"] as? String,
              let configDict = dict["configuration"] as? [String: Any] else {
            return nil
        }
        
        let cpuCount = configDict["cpuCount"] as? Int ?? 2
        let memorySize = configDict["memorySize"] as? UInt64 ?? (4 * 1024 * 1024 * 1024)
        let diskSize = configDict["diskSize"] as? UInt64 ?? (32 * 1024 * 1024 * 1024)
        let displayName = configDict["displayName"] as? String
        
        let configuration = VMConfiguration(
            cpuCount: cpuCount,
            memorySize: memorySize,
            diskSize: diskSize,
            displayName: displayName
        )
        
        let lastUsedAt: Date?
        if let lastUsedInterval = dict["lastUsedAt"] as? TimeInterval {
            lastUsedAt = Date(timeIntervalSince1970: lastUsedInterval)
        } else {
            lastUsedAt = nil
        }
        
        return VMInfo(
            id: id,
            name: name,
            status: status,
            createdAt: Date(timeIntervalSince1970: createdAtInterval),
            lastUsedAt: lastUsedAt,
            bundlePath: bundlePath,
            configuration: configuration
        )
    }
}

// MARK: - XPC Protocol (App-side copy)

@objc protocol HivecrewVMServiceProtocol {
    func deleteVM(id vmId: String, reply: @escaping ([String: Any]) -> Void)
    func listVMs(reply: @escaping ([[String: Any]]) -> Void)
    func reloadVMs(reply: @escaping () -> Void)
    // Template management
    func listTemplates(reply: @escaping ([[String: Any]]) -> Void)
    func createVMFromTemplate(templateId: String, name: String, reply: @escaping ([String: Any]) -> Void)
    func deleteTemplate(templateId: String, reply: @escaping ([String: Any]) -> Void)
}

/// Template Info for display
struct TemplateInfo: Identifiable {
    let id: String
    let name: String
    let description: String
    let diskSizeFormatted: String
    let cpuCount: Int
    let memorySizeFormatted: String
    
    static func fromDictionary(_ dict: [String: Any]) -> TemplateInfo? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String else {
            return nil
        }
        
        let description = dict["description"] as? String ?? ""
        let diskSizeFormatted = dict["diskSizeFormatted"] as? String ?? ""
        let cpuCount = dict["cpuCount"] as? Int ?? 2
        let memorySizeFormatted = dict["memorySizeFormatted"] as? String ?? ""
        
        return TemplateInfo(
            id: id,
            name: name,
            description: description,
            diskSizeFormatted: diskSizeFormatted,
            cpuCount: cpuCount,
            memorySizeFormatted: memorySizeFormatted
        )
    }
}

// MARK: - VM Service Error

enum VMServiceError: Error, LocalizedError {
    case connectionFailed
    case serviceUnavailable
    case operationFailed(String)
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to VM service"
        case .serviceUnavailable:
            return "VM service is not available"
        case .operationFailed(let reason):
            return reason
        case .invalidResponse:
            return "Invalid response from VM service"
        }
    }
}

// MARK: - VM Service Client

/// Client for communicating with the HivecrewVMService XPC service
@MainActor
class VMServiceClient: ObservableObject {
    static let shared = VMServiceClient()
    
    @Published private(set) var isConnected = false
    @Published private(set) var vms: [VMInfo] = []
    
    private var connection: NSXPCConnection?
    private var refreshTimer: Timer?
    private var runtimeCancellable: AnyCancellable?
    
    /// Reference to the app's VM runtime for merging actual running state
    private var vmRuntime: AppVMRuntime { AppVMRuntime.shared }
    
    private init() {
        setupConnection()
        observeRuntimeChanges()
    }
    
    /// Observe changes to AppVMRuntime to immediately update status when VMs start/stop
    private func observeRuntimeChanges() {
        runtimeCancellable = vmRuntime.$runningVMs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshVMs()
                }
            }
    }
    
    // MARK: - Connection Management
    
    private func setupConnection() {
        let connection = NSXPCConnection(serviceName: "com.pattonium.HivecrewVMService")
        connection.remoteObjectInterface = NSXPCInterface(with: HivecrewVMServiceProtocol.self)
        
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.isConnected = false
                print("VMServiceClient: Connection interrupted")
            }
        }
        
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.isConnected = false
                print("VMServiceClient: Connection invalidated")
                // Attempt reconnection after a delay
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.reconnect()
                }
            }
        }
        
        connection.resume()
        self.connection = connection
        self.isConnected = true
        
        // Start periodic refresh
        startRefreshTimer()
    }
    
    private func reconnect() {
        connection?.invalidate()
        connection = nil
        setupConnection()
    }
    
    private func getProxy() throws -> HivecrewVMServiceProtocol {
        guard let connection = connection else {
            throw VMServiceError.connectionFailed
        }
        
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            print("VMServiceClient: Remote object error: \(error)")
        }) as? HivecrewVMServiceProtocol else {
            throw VMServiceError.serviceUnavailable
        }
        
        return proxy
    }
    
    // MARK: - Refresh Timer
    
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshVMs()
            }
        }
    }
    
    func refreshVMs() async {
        do {
            // First, tell the service to reload VMs from disk (picks up externally created VMs)
            reloadVMsFromDisk()
            
            // Give the service a moment to process the reload
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            
            var fetchedVMs = try await listVMs()

            // Merge actual running state from AppVMRuntime
            // The XPC service doesn't know about VMs running in the app process
            for i in fetchedVMs.indices {
                let vmId = fetchedVMs[i].id
                if vmRuntime.getVM(id: vmId) != nil {
                    // VM is actually running in the app process
                    fetchedVMs[i].status = .ready
                }
            }
            
            // Sort VMs by creation date (newest first)
            fetchedVMs.sort { $0.createdAt > $1.createdAt }

            vms = fetchedVMs
        } catch {
            print("VMServiceClient: Failed to refresh VMs: \(error)")
        }
    }
    
    /// Tell the XPC service to reload VMs from disk (fire-and-forget, non-blocking)
    private func reloadVMsFromDisk() {
        guard let proxy = try? getProxy() else {
            print("VMServiceClient: reloadVMs skipped - no XPC connection")
            return
        }
        
        // Fire-and-forget - don't wait for completion
        // This avoids continuation leaks when XPC fails
        proxy.reloadVMs { }
    }
    
    // MARK: - VM Operations
    
    func deleteVM(id: String) async throws {
        let proxy = try getProxy()
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.deleteVM(id: id) { result in
                if result["success"] as? Bool == true {
                    continuation.resume()
                } else if let error = result["error"] as? String {
                    continuation.resume(throwing: VMServiceError.operationFailed(error))
                } else {
                    continuation.resume(throwing: VMServiceError.invalidResponse)
                }
            }
        }
    }
    
    func listVMs() async throws -> [VMInfo] {
        let proxy = try getProxy()
        
        return try await withCheckedThrowingContinuation { continuation in
            proxy.listVMs { results in
                let vms = results.compactMap { VMInfo.fromDictionary($0) }
                continuation.resume(returning: vms)
            }
        }
    }
    
    // MARK: - Template Management
    
    func listTemplates() async throws -> [TemplateInfo] {
        let proxy = try getProxy()
        
        return try await withCheckedThrowingContinuation { continuation in
            proxy.listTemplates { results in
                let templates = results.compactMap { TemplateInfo.fromDictionary($0) }
                continuation.resume(returning: templates)
            }
        }
    }
    
    func createVMFromTemplate(templateId: String, name: String) async throws -> String {
        let proxy = try getProxy()
        
        return try await withCheckedThrowingContinuation { continuation in
            proxy.createVMFromTemplate(templateId: templateId, name: name) { result in
                if let vmId = result["vmId"] as? String {
                    continuation.resume(returning: vmId)
                } else if let error = result["error"] as? String {
                    continuation.resume(throwing: VMServiceError.operationFailed(error))
                } else {
                    continuation.resume(throwing: VMServiceError.invalidResponse)
                }
            }
        }
    }
    
    func deleteTemplate(templateId: String) async throws {
        let proxy = try getProxy()
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            proxy.deleteTemplate(templateId: templateId) { result in
                if result["success"] as? Bool == true {
                    continuation.resume()
                } else if let error = result["error"] as? String {
                    continuation.resume(throwing: VMServiceError.operationFailed(error))
                } else {
                    continuation.resume(throwing: VMServiceError.invalidResponse)
                }
            }
        }
    }
}
