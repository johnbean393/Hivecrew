//
//  AppStoreRegionPolicy.swift
//  Hivelink
//

import Combine
import Foundation
import StoreKit

@MainActor
final class AppStoreRegionPolicy: ObservableObject {
    static let shared = AppStoreRegionPolicy()

    private static let installStorefrontCountryCodeKey = "hivelink.installStorefrontCountryCode"
    private static let chinaMainlandCountryCode = "CHN"

    @Published private(set) var installStorefrontCountryCode: String?
    @Published private(set) var hasResolvedInstallStorefront: Bool

    var isCallKitAllowed: Bool {
        guard let installStorefrontCountryCode else { return false }
        return installStorefrontCountryCode.uppercased() != Self.chinaMainlandCountryCode
    }

    var callbackDeliveryMode: String {
        isCallKitAllowed ? "callkit_voip" : "standard_notifications"
    }

    private init(defaults: UserDefaults = .standard) {
        let storedCode = defaults.string(forKey: Self.installStorefrontCountryCodeKey)
        installStorefrontCountryCode = storedCode
        hasResolvedInstallStorefront = storedCode != nil
    }

    func resolveInstallStorefrontIfNeeded() async {
        if installStorefrontCountryCode != nil {
            hasResolvedInstallStorefront = true
            return
        }

        guard let storefront = await Storefront.current else {
            hasResolvedInstallStorefront = false
            VoIPDiagnosticsLog.log("[AppStoreRegionPolicy] App Store storefront unavailable; CallKit remains disabled")
            return
        }

        let countryCode = storefront.countryCode.uppercased()
        installStorefrontCountryCode = countryCode
        hasResolvedInstallStorefront = true
        UserDefaults.standard.set(countryCode, forKey: Self.installStorefrontCountryCodeKey)
        VoIPDiagnosticsLog.log("[AppStoreRegionPolicy] Resolved install storefront=\(countryCode) callKitAllowed=\(isCallKitAllowed)")
    }
}
