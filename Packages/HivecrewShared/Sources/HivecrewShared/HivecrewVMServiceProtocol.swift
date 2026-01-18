//
//  HivecrewVMServiceProtocol.swift
//  HivecrewShared
//
//  Created by Hivecrew on 1/10/26.
//

import Foundation

/// XPC Service identifier
public let hivecrewVMServiceName = "com.pattonium.HivecrewVMService"

/// Protocol for the VM management XPC service
/// All methods use dictionaries for XPC compatibility since custom types require NSSecureCoding
@objc public protocol HivecrewVMServiceProtocol {
    
    /// Start a stopped VM
    /// - Parameters:
    ///   - vmId: The unique identifier of the VM
    ///   - reply: Callback with result dictionary containing "success" bool or "error" on failure
    func startVM(
        id vmId: String,
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// Stop a running VM
    /// - Parameters:
    ///   - vmId: The unique identifier of the VM
    ///   - force: If true, force stop immediately; if false, attempt graceful shutdown
    ///   - reply: Callback with result dictionary containing "success" bool or "error" on failure
    func stopVM(
        id vmId: String,
        force: Bool,
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// Delete a VM and all its associated files
    /// - Parameters:
    ///   - vmId: The unique identifier of the VM
    ///   - reply: Callback with result dictionary containing "success" bool or "error" on failure
    func deleteVM(
        id vmId: String,
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// List all VMs
    /// - Parameter reply: Callback with array of VMInfo dictionaries
    func listVMs(
        reply: @escaping ([[String: Any]]) -> Void
    )
    
    /// Reload VMs from disk (pick up VMs created externally)
    /// - Parameter reply: Callback when reload is complete
    func reloadVMs(
        reply: @escaping () -> Void
    )
    
    /// Get the current status of a VM
    /// - Parameters:
    ///   - vmId: The unique identifier of the VM
    ///   - reply: Callback with status raw value (Int) or -1 if not found
    func getVMStatus(
        id vmId: String,
        reply: @escaping (Int) -> Void
    )
    
    /// Get detailed info about a VM
    /// - Parameters:
    ///   - vmId: The unique identifier of the VM
    ///   - reply: Callback with VMInfo dictionary or empty dictionary if not found
    func getVMInfo(
        id vmId: String,
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// Get installation progress for a VM being created
    /// - Parameters:
    ///   - vmId: The unique identifier of the VM
    ///   - reply: Callback with progress (0.0 to 1.0) or -1 if not installing
    func getInstallProgress(
        id vmId: String,
        reply: @escaping (Double) -> Void
    )
    
    // MARK: - Template Management
    
    /// Save a VM as a template (golden image)
    /// - Parameters:
    ///   - vmId: The unique identifier of the VM to save as template
    ///   - name: Human-readable name for the template
    ///   - templateDescription: Optional description
    ///   - reply: Callback with result dictionary containing "templateId" on success or "error" on failure
    func saveAsTemplate(
        vmId: String,
        name: String,
        templateDescription: String,
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// List all available templates
    /// - Parameter reply: Callback with array of template dictionaries
    func listTemplates(
        reply: @escaping ([[String: Any]]) -> Void
    )
    
    /// Create a new VM from a template
    /// - Parameters:
    ///   - templateId: The unique identifier of the template
    ///   - name: Name for the new VM
    ///   - reply: Callback with result dictionary containing "vmId" on success or "error" on failure
    func createVMFromTemplate(
        templateId: String,
        name: String,
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// Delete a template
    /// - Parameters:
    ///   - templateId: The unique identifier of the template
    ///   - reply: Callback with result dictionary containing "success" bool or "error" on failure
    func deleteTemplate(
        templateId: String,
        reply: @escaping ([String: Any]) -> Void
    )
}
