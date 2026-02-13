//
//  CredentialRowView.swift
//  Hivecrew
//
//  Row components for displaying credentials in settings
//

import SwiftUI
import LocalAuthentication

// MARK: - Credential Row

struct CredentialRow: View {
    let credential: StoredCredential
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    @State private var showingTokens = false
    @State private var showingRealValues = false
    @State private var realUsername: String?
    @State private var realPassword: String?
    @State private var authError: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(credential.displayName)
                    .font(.headline)
                
                Spacer()
                
                Button {
                    showingTokens.toggle()
                    if !showingTokens {
                        // Hide real values when collapsing
                        showingRealValues = false
                        realUsername = nil
                        realPassword = nil
                    }
                } label: {
                    Image(systemName: showingTokens ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
            
            if showingTokens {
                VStack(alignment: .leading, spacing: 6) {
                    // Username is shown directly (not obfuscated) since it's not sensitive
                    if let username = CredentialManager.shared.resolveToken(credential.usernameToken.uuidString) {
                        UsernameRow(label: "Username", username: username)
                    }
                    TokenCopyRow(
                        label: "Password",
                        token: credential.passwordToken.uuidString,
                        revealedValue: showingRealValues ? realPassword : nil,
                        isPassword: true
                    )
                    
                    // Reveal / Hide button for password only
                    HStack {
                        Spacer()
                        
                        Button {
                            if showingRealValues {
                                hideRealValues()
                            } else {
                                authenticateAndReveal()
                            }
                        } label: {
                            Label(
                                showingRealValues ? "Hide Password" : "Reveal Password",
                                systemImage: showingRealValues ? "eye.slash" : "eye"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                    
                    if let error = authError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func authenticateAndReveal() {
        let context = LAContext()
        var error: NSError?
        
        // Check if biometric authentication is available
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to reveal credential values"
            ) { success, authenticationError in
                DispatchQueue.main.async {
                    if success {
                        // Fetch and display real values
                        if let values = CredentialManager.shared.getRealValues(for: credential.id) {
                            realUsername = values.username
                            realPassword = values.password
                            showingRealValues = true
                            authError = nil
                        }
                    } else {
                        authError = authenticationError?.localizedDescription ?? "Authentication failed"
                    }
                }
            }
        } else {
            authError = error?.localizedDescription ?? "Authentication not available"
        }
    }
    
    private func hideRealValues() {
        showingRealValues = false
        realUsername = nil
        realPassword = nil
        authError = nil
    }
}

