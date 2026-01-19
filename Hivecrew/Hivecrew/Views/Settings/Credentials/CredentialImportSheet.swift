//
//  CredentialImportSheet.swift
//  Hivecrew
//
//  Import preview sheet for credential import from CSV
//

import SwiftUI

// MARK: - Import Preview Model

struct ImportPreviewCredential: Identifiable {
    let id = UUID()
    let displayName: String
    let username: String?
    let password: String
    var selected: Bool
}

// MARK: - Import Preview Sheet

struct ImportPreviewSheet: View {
    @Binding var credentials: [ImportPreviewCredential]
    let credentialManager: CredentialManager
    let onDismiss: () -> Void
    
    @State private var importing = false
    @State private var importResult: CredentialImportResult?
    
    var selectedCount: Int {
        credentials.filter { $0.selected }.count
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Import Credentials")
                .font(.headline)
            
            Text("Select credentials to import (\(selectedCount) selected)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            List {
                ForEach($credentials) { $credential in
                    HStack {
                        Toggle("", isOn: $credential.selected)
                            .labelsHidden()
                        
                        VStack(alignment: .leading) {
                            Text(credential.displayName)
                                .font(.body)
                            
                            if let username = credential.username {
                                Text(username)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        Spacer()
                    }
                }
            }
            .frame(height: 250)
            
            if let result = importResult {
                VStack(spacing: 4) {
                    Text("Imported \(result.imported) credentials")
                        .foregroundStyle(.green)
                    
                    if result.skipped > 0 {
                        Text("Skipped \(result.skipped) duplicates")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    if !result.errors.isEmpty {
                        Text("Errors: \(result.errors.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            
            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                
                if importResult != nil {
                    Button("Done") {
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Import") {
                        performImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCount == 0 || importing)
                }
            }
        }
        .padding(24)
        .frame(width: 400)
    }
    
    private func performImport() {
        importing = true
        
        var imported = 0
        var skipped = 0
        var errors: [String] = []
        
        for credential in credentials where credential.selected {
            do {
                try credentialManager.addCredential(
                    displayName: credential.displayName,
                    username: credential.username,
                    password: credential.password
                )
                imported += 1
            } catch CredentialManagerError.duplicateCredential {
                skipped += 1
            } catch {
                errors.append(credential.displayName)
            }
        }
        
        importResult = CredentialImportResult(imported: imported, skipped: skipped, errors: errors)
        importing = false
    }
}
