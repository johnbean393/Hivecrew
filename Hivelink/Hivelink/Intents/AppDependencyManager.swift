//
//  AppDependencyManager.swift
//  Hivelink
//
//  Singleton bridge exposing the app's live services to App Intents,
//  which cannot receive environment objects or @StateObject references.
//

import Foundation

@MainActor
final class AppDependencyManager {
    static let shared = AppDependencyManager()

    weak var taskService: HivelinkTaskService?
    weak var voiceOrchestrator: HivelinkVoiceOrchestrator?
    var setSelectedTab: ((Int) -> Void)?

    private init() {}
}
