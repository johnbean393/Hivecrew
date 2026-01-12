//
//  HivecrewVMServiceProtocol.swift
//  HivecrewVMService
//
//  Created by John Bean on 1/10/26.
//

import Foundation

/// XPC Service identifier
public let hivecrewVMServiceName = "com.pattonium.HivecrewVMService"

/// Protocol for the VM management XPC service
/// All methods use dictionaries for XPC compatibility since custom types require NSSecureCoding
@objc public protocol HivecrewVMServiceProtocol {
    
    /// Delete a VM and all its associated files
    func deleteVM(
        id vmId: String,
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// List all VMs
    func listVMs(
        reply: @escaping ([[String: Any]]) -> Void
    )
    
    /// Reload VMs from disk (pick up VMs created externally)
    func reloadVMs(
        reply: @escaping () -> Void
    )
    
    // MARK: - Template Management
    
    /// List all available templates
    func listTemplates(
        reply: @escaping ([[String: Any]]) -> Void
    )
    
    /// Create a new VM from a template
    func createVMFromTemplate(
        templateId: String,
        name: String,
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// Delete a template
    func deleteTemplate(
        templateId: String,
        reply: @escaping ([String: Any]) -> Void
    )
}
