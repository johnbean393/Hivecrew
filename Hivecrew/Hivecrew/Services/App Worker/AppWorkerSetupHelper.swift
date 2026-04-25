//
//  AppWorkerSetupHelper.swift
//  Hivecrew
//
//  Builds TaskSetupRequirement payloads from CuaDriverManager state
//  with consistent user-facing messages.
//

import Foundation
import HivecrewCore

enum AppWorkerSetupHelper {

    @MainActor
    static func buildSetupRequirement(deviceId: String? = nil) -> TaskSetupRequirement? {
        guard let reason = CuaDriverManager.shared.currentSetupRequirement() else {
            return nil
        }
        return TaskSetupRequirement(
            runtimeKind: .app,
            reason: reason,
            deviceId: deviceId,
            userFacingMessage: userFacingMessage(for: reason)
        )
    }

    static func userFacingMessage(for reason: RuntimeSetupRequirement) -> String {
        switch reason {
        case .cuaDriverMissing:
            return "The cua-driver binary was not found in the app bundle. Reinstall Hivecrew or add cua-driver to Resources/cua-driver/."
        case .appPermissionsMissing:
            return "Hivecrew needs Accessibility and Screen Recording permissions on this Mac to run App Worker tasks. Open Settings > App Worker to grant them."
        case .providerUnavailable:
            return "The cua-driver backend could not be started. Check Settings > App Worker for details."
        case .vmTemplateMissing, .noEligibleDevice:
            return "App Worker setup is incomplete."
        }
    }
}
