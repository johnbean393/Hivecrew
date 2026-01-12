//
//  VMManager.swift
//  HivecrewVMService
//
//  Created by Hivecrew on 1/10/26.
//

import Foundation
import Virtualization
import HivecrewShared

// MARK: - VM Status Enum (Local copy for XPC service)

enum VMStatus: Int, Codable {
    case stopped = 0
    case booting = 1
    case ready = 2
    case busy = 3
    case suspending = 4
    case error = 5
}

// MARK: - VM Instance

/// Represents a running or configured VM instance
class VMInstance {
    let id: String
    let bundlePath: URL
    var config: VMInstanceConfig
    var virtualMachine: VZVirtualMachine?
    var status: VMStatus = .stopped
    
    init(id: String, bundlePath: URL, config: VMInstanceConfig) {
        self.id = id
        self.bundlePath = bundlePath
        self.config = config
    }
}

// MARK: - VM Instance Configuration (Persisted)

struct VMInstanceConfig: Codable {
    let id: String
    var name: String
    var cpuCount: Int
    var memorySize: UInt64
    var diskSize: UInt64
    let createdAt: Date
    var lastUsedAt: Date?
    
    var displayName: String {
        name.isEmpty ? "VM \(id.prefix(8))" : name
    }
}

// MARK: - VM Manager

/// Manages the lifecycle of all virtual machines
class VMManager: NSObject {
    static let shared = VMManager()
    
    private var instances: [String: VMInstance] = [:]
    private let queue = DispatchQueue(label: "com.pattonium.VMManager", qos: .userInitiated)
    
    override init() {
        super.init()
        loadExistingVMs()
    }
    
    // MARK: - VM Discovery
    
    private func loadExistingVMs() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let fileManager = FileManager.default
            guard let contents = try? fileManager.contentsOfDirectory(at: AppPaths.vmDirectory, includingPropertiesForKeys: nil) else {
                return
            }
            
            for vmPath in contents where vmPath.hasDirectoryPath {
                let configPath = vmPath.appendingPathComponent("config.json")
                if let data = try? Data(contentsOf: configPath),
                   let config = try? JSONDecoder().decode(VMInstanceConfig.self, from: data) {
                    let instance = VMInstance(id: config.id, bundlePath: vmPath, config: config)
                    self.instances[config.id] = instance
                    NSLog("VMManager: Loaded VM \(config.id) from disk")
                }
            }
        }
    }
    
    // MARK: - VM Lifecycle
    
    func deleteVM(id vmId: String, completion: @escaping ([String: Any]) -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion(["error": "Manager not available"])
                return
            }
            
            let fileManager = FileManager.default
            
            // Determine the bundle path to delete
            let bundlePathToDelete: URL
            if let instance = self.instances[vmId] {
                // Stop VM if running
                if instance.virtualMachine != nil {
                    try? instance.virtualMachine?.requestStop()
                    instance.virtualMachine = nil
                }
                bundlePathToDelete = instance.bundlePath
            } else {
                // VM not in instances, but still try to delete the directory using AppPaths
                bundlePathToDelete = AppPaths.vmBundlePath(id: vmId)
            }
            
            // Delete files
            var deleteError: Error?
            if fileManager.fileExists(atPath: bundlePathToDelete.path) {
                do {
                    try fileManager.removeItem(at: bundlePathToDelete)
                    NSLog("VMManager: VM directory \(vmId) deleted at \(bundlePathToDelete.path)")
                } catch {
                    deleteError = error
                }
            }
            
            // Remove from instances dictionary
            self.instances.removeValue(forKey: vmId)
            
            if let error = deleteError {
                completion(["error": "Failed to delete VM files: \(error.localizedDescription)"])
            } else {
                NSLog("VMManager: VM \(vmId) deleted")
                completion(["success": true])
            }
        }
    }
    
    // MARK: - VM Info
    
    func listVMs() -> [[String: Any]] {
        return instances.values.map { vmInfoDict(for: $0) }
    }
    
    /// Reload VMs from disk (picks up VMs created externally)
    func reloadVMs(completion: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self = self else {
                completion()
                return
            }
            
            let fileManager = FileManager.default
            guard let contents = try? fileManager.contentsOfDirectory(at: AppPaths.vmDirectory, includingPropertiesForKeys: nil) else {
                completion()
                return
            }
            
            for vmPath in contents where vmPath.hasDirectoryPath {
                let vmId = vmPath.lastPathComponent
                
                // Skip if already loaded
                if self.instances[vmId] != nil {
                    continue
                }
                
                let configPath = vmPath.appendingPathComponent("config.json")
                if let data = try? Data(contentsOf: configPath),
                   let config = try? JSONDecoder().decode(VMInstanceConfig.self, from: data) {
                    let instance = VMInstance(id: config.id, bundlePath: vmPath, config: config)
                    self.instances[config.id] = instance
                    NSLog("VMManager: Loaded new VM \(config.id) from disk")
                }
            }
            
            completion()
        }
    }
    
    func getVMStatus(id vmId: String) -> Int {
        guard let instance = instances[vmId] else { return -1 }
        return instance.status.rawValue
    }
    
    func getVMInfo(id vmId: String) -> [String: Any] {
        guard let instance = instances[vmId] else { return [:] }
        return vmInfoDict(for: instance)
    }
    
    private func vmInfoDict(for instance: VMInstance) -> [String: Any] {
        var dict: [String: Any] = [
            "id": instance.id,
            "name": instance.config.displayName,
            "status": instance.status.rawValue,
            "createdAt": instance.config.createdAt.timeIntervalSince1970,
            "bundlePath": instance.bundlePath.path,
            "configuration": [
                "cpuCount": instance.config.cpuCount,
                "memorySize": instance.config.memorySize,
                "diskSize": instance.config.diskSize,
                "displayName": instance.config.name
            ]
        ]
        if let lastUsed = instance.config.lastUsedAt {
            dict["lastUsedAt"] = lastUsed.timeIntervalSince1970
        }
        return dict
    }
    
    // MARK: - Persistence
    
    private func saveVMConfig(_ instance: VMInstance) {
        let configPath = instance.bundlePath.appendingPathComponent("config.json")
        do {
            let data = try JSONEncoder().encode(instance.config)
            try data.write(to: configPath)
        } catch {
            NSLog("VMManager: Failed to save VM config: \(error)")
        }
    }
    
    // MARK: - Public Access to VMs (for display attachment)
    
    func getVirtualMachine(id vmId: String) -> VZVirtualMachine? {
        return instances[vmId]?.virtualMachine
    }
    
    // MARK: - Template Management (Golden Images)
    
    /// List all available templates
    func listTemplates() -> [[String: Any]] {
        let templatesDir = AppPaths.templatesDirectory
        
        guard let contents = try? FileManager.default.contentsOfDirectory(at: templatesDir, includingPropertiesForKeys: nil) else {
            return []
        }
        
        var templates: [[String: Any]] = []
        
        for templateDir in contents where templateDir.hasDirectoryPath {
            let configPath = templateDir.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: configPath),
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            
            let id = config["id"] as? String ?? templateDir.lastPathComponent
            let name = config["name"] as? String ?? "Unknown"
            let desc = config["description"] as? String ?? ""
            let createdAt = config["createdAt"] as? String ?? ""
            let diskSize = config["diskSize"] as? UInt64 ?? 0
            let cpuCount = config["cpuCount"] as? Int ?? 2
            let memorySize = config["memorySize"] as? UInt64 ?? 0
            
            templates.append([
                "id": id,
                "name": name,
                "description": desc,
                "createdAt": createdAt,
                "diskSize": diskSize,
                "diskSizeFormatted": ByteCountFormatter.string(fromByteCount: Int64(diskSize), countStyle: .file),
                "cpuCount": cpuCount,
                "memorySize": memorySize,
                "memorySizeFormatted": ByteCountFormatter.string(fromByteCount: Int64(memorySize), countStyle: .memory)
            ])
        }
        
        return templates
    }
    
    /// Find a template directory by its config ID
    /// Templates may have directory names that don't match their config ID
    private func findTemplateDirectory(byId templateId: String) -> (url: URL, config: [String: Any])? {
        let templatesDir = AppPaths.templatesDirectory
        
        guard let contents = try? FileManager.default.contentsOfDirectory(at: templatesDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        
        for templateDir in contents where templateDir.hasDirectoryPath {
            let configPath = templateDir.appendingPathComponent("config.json")
            guard let data = try? Data(contentsOf: configPath),
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            
            // Check if this template's ID matches (from config or directory name)
            let configId = config["id"] as? String ?? templateDir.lastPathComponent
            if configId == templateId {
                return (templateDir, config)
            }
        }
        
        return nil
    }
    
    /// Create a new VM from a template
    func createVMFromTemplate(templateId: String, name: String, completion: @escaping ([String: Any]) -> Void) {
        let capturedTemplateId = templateId
        let capturedName = name
        self.performCreateFromTemplate(templateId: capturedTemplateId, name: capturedName, completion: completion)
    }
    
    private func performCreateFromTemplate(templateId: String, name: String, completion: @escaping ([String: Any]) -> Void) {
        queue.async(execute: {
            // Find template by searching all template directories
            guard let (templateDir, templateConfig) = self.findTemplateDirectory(byId: templateId) else {
                completion(["success": false, "error": "Template not found: \(templateId)"])
                return
            }
            
            NSLog("VMManager: Found template at \(templateDir.path)")
            
            // Extract template properties
            let templateName = templateConfig["name"] as? String ?? "Unknown"
            let cpuCount = templateConfig["cpuCount"] as? Int ?? 2
            let memorySize = templateConfig["memorySize"] as? UInt64 ?? (4 * 1024 * 1024 * 1024)
            let diskSize = templateConfig["diskSize"] as? UInt64 ?? (64 * 1024 * 1024 * 1024)
            
            let vmId = UUID().uuidString
            let vmDir = AppPaths.vmBundlePath(id: vmId)
            
            do {
                // Create VM directory
                try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
                
                // Copy disk image
                let diskSource = templateDir.appendingPathComponent("disk.img")
                let diskDest = vmDir.appendingPathComponent("disk.img")
                print("VMManager: Cloning disk from template...")
                try FileManager.default.copyItem(at: diskSource, to: diskDest)
                
                // Copy auxiliary storage (REQUIRED for VM to boot)
                let auxSource = templateDir.appendingPathComponent("auxiliary")
                let auxDest = vmDir.appendingPathComponent("auxiliary")
                guard FileManager.default.fileExists(atPath: auxSource.path) else {
                    throw NSError(domain: "VMManager", code: 201, userInfo: [
                        NSLocalizedDescriptionKey: "Template is missing auxiliary storage (NVRAM). VMs created from this template will not boot. Please recreate the template from a fully installed VM."
                    ])
                }
                try FileManager.default.copyItem(at: auxSource, to: auxDest)
                print("VMManager: Copied auxiliary storage from template")
                
                // Copy hardware model
                let hwSource = templateDir.appendingPathComponent("HardwareModel.bin")
                let hwDest = vmDir.appendingPathComponent("HardwareModel.bin")
                if FileManager.default.fileExists(atPath: hwSource.path) {
                    try FileManager.default.copyItem(at: hwSource, to: hwDest)
                }
                
                // Generate NEW machine identifier (must be unique per VM)
                let machineId = VZMacMachineIdentifier()
                let machineIdPath = vmDir.appendingPathComponent("MachineIdentifier.bin")
                try machineId.dataRepresentation.write(to: machineIdPath)
                
                // Create shared folder
                let sharedDir = vmDir.appendingPathComponent("shared", isDirectory: true)
                try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
                
                // Create VM config and instance
                let vmInstanceConfig = VMInstanceConfig(
                    id: vmId,
                    name: name,
                    cpuCount: cpuCount,
                    memorySize: memorySize,
                    diskSize: diskSize,
                    createdAt: Date(),
                    lastUsedAt: nil
                )
                let instance = VMInstance(
                    id: vmId,
                    bundlePath: vmDir,
                    config: vmInstanceConfig
                )
                
                // Save VM config
                let vmConfigPath = vmDir.appendingPathComponent("config.json")
                let vmConfig: [String: Any] = [
                    "id": vmId,
                    "name": name,
                    "cpuCount": cpuCount,
                    "memorySize": memorySize,
                    "diskSize": diskSize,
                    "createdFromTemplate": templateId,
                    "createdAt": ISO8601DateFormatter().string(from: Date())
                ]
                let vmConfigData = try JSONSerialization.data(withJSONObject: vmConfig, options: .prettyPrinted)
                try vmConfigData.write(to: vmConfigPath)
                
                // Register the VM
                self.instances[vmId] = instance
                
                print("VMManager: Created VM \(vmId) from template \(templateId)")
                
                completion([
                    "success": true,
                    "vmId": vmId,
                    "name": name,
                    "fromTemplate": templateName
                ])
                
            } catch {
                // Cleanup on failure
                try? FileManager.default.removeItem(at: vmDir)
                completion(["success": false, "error": "Failed to create VM from template: \(error.localizedDescription)"])
            }
        })
    }
    
    /// Delete a template
    func deleteTemplate(templateId: String, completion: @escaping ([String: Any]) -> Void) {
        queue.async(execute: {
            // Find template by searching all template directories
            guard let (templateDir, _) = self.findTemplateDirectory(byId: templateId) else {
                completion(["success": false, "error": "Template not found: \(templateId)"])
                return
            }
            
            do {
                try FileManager.default.removeItem(at: templateDir)
                print("TemplateManager: Deleted template: \(templateId)")
                completion(["success": true])
            } catch {
                completion(["success": false, "error": "Failed to delete template: \(error.localizedDescription)"])
            }
        })
    }
}
