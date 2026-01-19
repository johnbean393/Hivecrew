//
//  CredentialSheets.swift
//  Hivecrew
//
//  Sheet views for adding and editing credentials
//

import SwiftUI

// MARK: - Add Credential Sheet

struct AddCredentialSheet: View {
    let credentialManager: CredentialManager
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var displayName = ""
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Add Credential")
                .font(.headline)
            
            Form {
                TextField("Service Name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                
                TextField("Username (optional)", text: $username)
                    .textFieldStyle(.roundedBorder)
                
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                
                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .formStyle(.columns)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Button("Add") {
                    addCredential()
                }
                .buttonStyle(.borderedProminent)
                .disabled(displayName.isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 350)
    }
    
    private func addCredential() {
        do {
            try credentialManager.addCredential(
                displayName: displayName,
                username: username.isEmpty ? nil : username,
                password: password
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Edit Credential Sheet

struct EditCredentialSheet: View {
    let credential: StoredCredential
    let credentialManager: CredentialManager
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var displayName: String
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    
    init(credential: StoredCredential, credentialManager: CredentialManager) {
        self.credential = credential
        self.credentialManager = credentialManager
        self._displayName = State(initialValue: credential.displayName)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Credential")
                .font(.headline)
            
            Form {
                TextField("Service Name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                
                TextField("New Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                
                SecureField("New Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                
                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .formStyle(.columns)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Button("Save") {
                    saveCredential()
                }
                .buttonStyle(.borderedProminent)
                .disabled(displayName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 350)
    }
    
    private func saveCredential() {
        do {
            var updated = credential
            updated.displayName = displayName
            
            try credentialManager.updateCredential(
                updated,
                username: username.isEmpty ? nil : username,
                password: password.isEmpty ? nil : password
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
