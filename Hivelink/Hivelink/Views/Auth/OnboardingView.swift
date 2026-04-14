//
//  OnboardingView.swift
//  Hivelink
//

import HivecrewCore
import SwiftUI

private enum AuthRoute: Hashable {
    case otp
}

struct OnboardingView: View {
    @EnvironmentObject private var authManager: RemoteAccessAuthManager
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 32) {
                    brandingHeader
                    EmailEntryView {
                        path.append(AuthRoute.otp)
                    }
                }
                .padding()
            }
            .navigationTitle("Hivelink")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: AuthRoute.self) { _ in
                OTPVerificationView()
            }
        }
    }

    private var brandingHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("Hivelink")
                .font(.largeTitle.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

#Preview {
    OnboardingView()
        .environmentObject(RemoteAccessAuthManager())
}
