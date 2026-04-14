//
//  OTPVerificationView.swift
//  Hivelink
//

import HivecrewCore
import SwiftUI

struct OTPVerificationView: View {
    @EnvironmentObject private var authManager: RemoteAccessAuthManager

    @State private var code = ""
    @FocusState private var isCodeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let email = authManager.email {
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Enter the 6-digit code sent to your email")
                .font(.title3)
                .foregroundStyle(.secondary)

            TextField("Code", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .font(.title2.monospacedDigit())
                .multilineTextAlignment(.center)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .focused($isCodeFocused)

            if let message = authManager.errorMessage, !message.isEmpty {
                errorBanner(message)
            }

            Button {
                Task {
                    await authManager.requestOTP(email: authManager.email ?? "")
                }
            } label: {
                if authManager.status == .connecting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Resend code")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(authManager.status == .connecting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .navigationTitle("Verify")
        .navigationBarTitleDisplayMode(.large)
        .overlay {
            if authManager.status == .verifyingOTP {
                ProgressView("Verifying…")
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear {
            isCodeFocused = true
        }
        .onChange(of: code) { _, newValue in
            let digits = newValue.filter(\.isNumber)
            let limited = String(digits.prefix(6))
            if limited != newValue {
                code = limited
                return
            }
            if limited.count == 6, authManager.status != .verifyingOTP {
                let email = authManager.email ?? ""
                Task {
                    await authManager.verifyOTP(email: email, code: limited)
                }
            }
        }
        .onChange(of: authManager.errorMessage) { _, newValue in
            if newValue != nil {
                code = ""
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    NavigationStack {
        OTPVerificationView()
    }
    .environmentObject(RemoteAccessAuthManager())
}
