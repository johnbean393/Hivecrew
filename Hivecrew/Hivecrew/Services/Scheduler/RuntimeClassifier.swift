//
//  RuntimeClassifier.swift
//  Hivecrew
//
//  Derives runtime assignment from task target + heuristics.
//

import Foundation
import HivecrewCore

enum RuntimeClassificationError: Error, LocalizedError {
    case appUnavailable(TaskSetupRequirement)
    case fastIncompatible(String)

    var errorDescription: String? {
        switch self {
        case .appUnavailable(let req):
            return req.userFacingMessage
        case .fastIncompatible(let reason):
            return "Fast Worker cannot run this task: \(reason)"
        }
    }
}

struct RuntimeClassifier {

    struct Decision {
        var assignedKind: AgentRuntimeKind
        var requirement: TaskRuntimeRequirement
    }

    /// Injectable status check for testability.
    /// Defaults to querying CuaDriverManager.shared.
    var appWorkerSetupCheck: () -> RuntimeSetupRequirement? = {
        CuaDriverManager.shared.currentSetupRequirement()
    }

    // MARK: - Classification

    func classify(_ task: TaskRecord) throws -> Decision {
        switch task.runtimeTarget {
        case .fast:
            return fastDecision()
        case .isolatedVM:
            return vmDecision()
        case .app:
            return try appDecision()
        case .automatic:
            return classifyAutomatic(task)
        }
    }

    // MARK: - App Decision

    private func appDecision() throws -> Decision {
        if let setupReason = appWorkerSetupCheck() {
            let requirement = AppWorkerSetupHelper.userFacingMessage(for: setupReason)
            throw RuntimeClassificationError.appUnavailable(TaskSetupRequirement(
                runtimeKind: .app,
                reason: setupReason,
                userFacingMessage: requirement
            ))
        }
        return Decision(
            assignedKind: .app,
            requirement: TaskRuntimeRequirement(
                preferredRuntime: .app,
                allowedRuntimes: [.app],
                requiredCapabilities: .app,
                requiresHostSpecificState: true,
                riskLevel: .trustedGUI
            )
        )
    }

    // MARK: - Heuristics

    private func classifyAutomatic(_ task: TaskRecord) -> Decision {
        let desc = task.taskDescription.lowercased()

        // TODO: Phase 4 — auto-route to App Worker for host-specific GUI tasks
        // (e.g. "use my Safari profile", "open my Mail app"). Currently,
        // automatic classification only routes between Fast and VM.

        if matchesGUISignals(desc) {
            return vmDecision()
        }
        if matchesIsolationSignals(desc) {
            return vmDecision()
        }
        return fastDecision()
    }

    private static let guiPattern: NSRegularExpression? = {
        let pattern = [
            "open my", "click", "browser", "safari", "mail app",
            "finder", "calendar", "figma", "preview", "notes app",
            "keynote", "screenshot", "window", "use my account",
            "use my app", "look at", "background gui",
        ].map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let isolationPattern: NSRegularExpression? = {
        let pattern = [
            "untrusted", "unknown installer", "sandbox", "\\bisolate\\b",
            "run this binary", "\\.dmg", "\\.pkg",
        ].joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private func matchesGUISignals(_ text: String) -> Bool {
        guard let regex = Self.guiPattern else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private func matchesIsolationSignals(_ text: String) -> Bool {
        guard let regex = Self.isolationPattern else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    // MARK: - Decision Builders

    private func fastDecision() -> Decision {
        Decision(
            assignedKind: .fast,
            requirement: TaskRuntimeRequirement(
                preferredRuntime: .fast,
                allowedRuntimes: [.fast],
                requiredCapabilities: .fast,
                riskLevel: .low
            )
        )
    }

    private func vmDecision() -> Decision {
        Decision(
            assignedKind: .isolatedVM,
            requirement: TaskRuntimeRequirement(
                preferredRuntime: .isolatedVM,
                allowedRuntimes: [.isolatedVM],
                requiredCapabilities: .vm,
                riskLevel: .trustedGUI
            )
        )
    }
}
