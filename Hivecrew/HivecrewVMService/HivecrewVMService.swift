//
//  HivecrewVMService.swift
//  HivecrewVMService
//
//  Created by John Bean on 1/10/26.
//

import Foundation

/// This object implements the protocol which we have defined. It provides the actual behavior for the service.
/// It is 'exported' by the service to make it available to the process hosting the service over an NSXPCConnection.
class HivecrewVMService: NSObject, HivecrewVMServiceProtocol {
    
    private let vmManager = VMManager.shared
    
    // MARK: - VM Lifecycle
    
    @objc func deleteVM(id vmId: String, reply: @escaping ([String: Any]) -> Void) {
        vmManager.deleteVM(id: vmId, completion: reply)
    }
    
    // MARK: - VM Info
    
    @objc func listVMs(reply: @escaping ([[String: Any]]) -> Void) {
        reply(vmManager.listVMs())
    }
    
    @objc func reloadVMs(reply: @escaping () -> Void) {
        vmManager.reloadVMs(completion: reply)
    }
    
    // MARK: - Template Management
    
    @objc func listTemplates(reply: @escaping ([[String: Any]]) -> Void) {
        reply(vmManager.listTemplates())
    }
    
    @objc func createVMFromTemplate(templateId: String, name: String, reply: @escaping ([String: Any]) -> Void) {
        vmManager.createVMFromTemplate(templateId: templateId, name: name, completion: reply)
    }
    
    @objc func deleteTemplate(templateId: String, reply: @escaping ([String: Any]) -> Void) {
        vmManager.deleteTemplate(templateId: templateId, completion: reply)
    }
}
