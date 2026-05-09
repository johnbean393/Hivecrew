//
//  RuntimeClassifier.swift
//  Hivecrew
//
//  Derives runtime assignment from task target + inline override + worker LLM.
//

import Foundation
import HivecrewCore
import HivecrewLLM

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

    /// Result of parsing inline runtime tokens out of a prompt.
    struct InlineOverride {
        /// The runtime target the user typed inline. `.automatic` means the user
        /// explicitly asked us to fall back to LLM-driven routing.
        var runtimeTarget: TaskRuntimeTarget
        /// The original description with the inline token removed.
        var cleanedDescription: String
    }

    /// Injectable status check for testability.
    /// Defaults to querying CuaDriverManager.shared.
    var appWorkerSetupCheck: () -> RuntimeSetupRequirement? = {
        CuaDriverManager.shared.currentSetupRequirement()
    }

    /// Optional provider for the worker LLM client used by `classifyAsync`.
    /// When nil (e.g. unit tests), automatic classification falls back to the
    /// regex-based heuristic.
    var workerClientProvider: (@Sendable () async throws -> any LLMClientProtocol)? = nil

    /// Optional probe for App Worker availability used during automatic
    /// classification: when the user hasn't picked a runtime explicitly, we
    /// avoid routing to App if its setup is missing.
    var appWorkerAvailable: () -> Bool = {
        CuaDriverManager.shared.currentSetupRequirement() == nil
    }

    // MARK: - Synchronous Classification (fast path / pre-checks)

    /// Synchronous classification. Used for queue drainers and the immediate-
    /// start gate where we cannot await a network call. Falls back to the
    /// regex heuristic for `.automatic`.
    func classify(_ task: TaskRecord) throws -> Decision {
        switch task.runtimeTarget {
        case .fast:
            return fastDecision()
        case .isolatedVM:
            return vmDecision()
        case .app:
            return try appDecision()
        case .automatic:
            return classifyAutomaticHeuristic(task)
        }
    }

    // MARK: - Async Classification (final routing)

    /// Final routing decision. For `.automatic` targets, asks the worker LLM
    /// to choose between Fast / App / VM. Falls back to the synchronous
    /// regex heuristic on any failure (no worker model configured, network
    /// error, malformed JSON, etc.).
    func classifyAsync(_ task: TaskRecord) async throws -> Decision {
        switch task.runtimeTarget {
        case .fast:
            return fastDecision()
        case .isolatedVM:
            return vmDecision()
        case .app:
            return try appDecision()
        case .automatic:
            return await classifyAutomaticUsingWorker(task)
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

    // MARK: - Worker-LLM Automatic Classification

    private func classifyAutomaticUsingWorker(_ task: TaskRecord) async -> Decision {
        guard let provider = workerClientProvider else {
            return classifyAutomaticHeuristic(task)
        }

        let appAvail = await probeAppWorkerAvailable()

        do {
            let client = try await provider()
            let kind = try await Self.askWorkerForRuntime(
                description: task.taskDescription,
                appAvailable: appAvail,
                client: client
            )
            return await decision(for: kind, appAvailable: appAvail)
        } catch {
            print("RuntimeClassifier: worker-model classification failed (\(error.localizedDescription)); falling back to heuristic")
            return classifyAutomaticHeuristic(task)
        }
    }

    /// Hops to the main actor to probe App Worker availability, since the
    /// underlying CuaDriverManager is `@MainActor`-isolated.
    private func probeAppWorkerAvailable() async -> Bool {
        let probe = appWorkerAvailable
        return await MainActor.run { probe() }
    }

    private func decision(for kind: AgentRuntimeKind, appAvailable: Bool) async -> Decision {
        switch kind {
        case .fast: return fastDecision()
        case .app:
            // If the LLM picked App but the binary/permissions are missing,
            // gracefully degrade to VM rather than failing the task outright.
            if appAvailable {
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
            return vmDecision()
        case .isolatedVM: return vmDecision()
        }
    }

    /// Asks the worker LLM which runtime should execute the task.
    /// Returns the selected `AgentRuntimeKind`. Throws on transport / parse
    /// errors so the caller can fall back to the regex heuristic.
    static func askWorkerForRuntime(
        description: String,
        appAvailable: Bool,
        client: any LLMClientProtocol
    ) async throws -> AgentRuntimeKind {
        let appLine = appAvailable
            ? "- \"app\": Use the user's REAL macOS apps on their host, including browsers, Electron apps, Finder, Mail, Notes, and local app/account state. CuaDriver can operate windows in the background."
            : "- \"app\": NOT AVAILABLE on this host. Do not pick this option."

        let prompt = """
        You are routing a task to one of three execution runtimes. Reply with strict JSON only.

        Runtimes:
        - "fast": Headless sandbox (shell, filesystem, network). No GUI, no screenshots, no mouse/keyboard. Best for code, scripts, file processing, web requests, data transformation, document generation.
        \(appLine)
        - "vm": Disposable isolated macOS VM with full GUI. Best for untrusted binaries (.dmg/.pkg), tasks needing a clean desktop, or workflows that must not touch the user's real apps/profiles.

        Selection rules:
        1. Prefer "fast" by default — it is the cheapest and quickest.
        2. Choose "app" for interactive host GUI work when App is available: browser automation, URL navigation, Chrome/Safari browsing, browser games, Electron apps, and the user's local macOS apps.
        3. Choose "vm" when isolation is the point: untrusted installers/binaries, clean-room testing, or avoiding the user's real browser/profile/apps.
        4. If the task is ambiguous, prefer "fast".

        Task:
        \"\"\"
        \(description)
        \"\"\"

        Respond with ONLY one JSON object on a single line:
        {"runtime": "fast" | "app" | "vm", "reason": "<≤15 words>"}
        """

        let messages: [LLMMessage] = [
            .system("You are a runtime router. Reply with one JSON object only — no markdown, no prose."),
            .user(prompt)
        ]

        let response = try await client.chat(messages: messages, tools: nil)
        guard let text = response.text else {
            throw NSError(domain: "RuntimeClassifier", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty worker model response"])
        }

        let json = Self.extractJSON(from: text)
        struct Payload: Decodable { let runtime: String; let reason: String? }
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw NSError(domain: "RuntimeClassifier", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not parse worker model response: \(text)"])
        }

        switch payload.runtime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fast":
            return .fast
        case "app":
            return appAvailable ? .app : .isolatedVM
        case "vm", "isolated", "isolatedvm", "isolated_vm", "isolated-vm":
            return .isolatedVM
        default:
            throw NSError(domain: "RuntimeClassifier", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unknown runtime in response: \(payload.runtime)"])
        }
    }

    private static func extractJSON(from text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```json") { t = String(t.dropFirst(7)) }
        else if t.hasPrefix("```") { t = String(t.dropFirst(3)) }
        if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = t.firstIndex(of: "{"), let e = t.lastIndex(of: "}") {
            t = String(t[s...e])
        }
        return t
    }

    // MARK: - Inline Override Parsing

    /// Recognised inline tokens, mapped to a runtime target. Matched
    /// case-insensitively at word boundaries (e.g. " @fast ", "@vm.", "@app,").
    private static let inlineTokens: [(token: String, target: TaskRuntimeTarget)] = [
        ("fast", .fast),
        ("fastworker", .fast),
        ("fast-worker", .fast),
        ("app", .app),
        ("appworker", .app),
        ("app-worker", .app),
        ("vm", .isolatedVM),
        ("isolated", .isolatedVM),
        ("isolatedvm", .isolatedVM),
        ("isolated-vm", .isolatedVM),
        ("auto", .automatic),
        ("automatic", .automatic),
    ]

    /// Parses a single `@token` override out of `description`. Returns nil
    /// when no recognised token is present. The first recognised token wins;
    /// subsequent occurrences are left in place.
    static func parseInlineOverride(in description: String) -> InlineOverride? {
        // Anchor the match: the token must follow whitespace or start-of-string
        // and be terminated by whitespace, end-of-string, or a small set of
        // punctuation. This avoids gobbling things like "@fast-rendering" or
        // an email address.
        let pattern = "(?:^|(?<=\\s))@([A-Za-z][A-Za-z0-9-]*)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let nsRange = NSRange(description.startIndex..., in: description)
        let matches = regex.matches(in: description, range: nsRange)

        for match in matches {
            guard match.numberOfRanges >= 2,
                  let captureRange = Range(match.range(at: 1), in: description),
                  let fullRange = Range(match.range, in: description) else {
                continue
            }
            let raw = String(description[captureRange]).lowercased()
            guard let mapping = inlineTokens.first(where: { $0.token == raw }) else {
                continue
            }

            var cleaned = description
            // Replace the matched "@token" with a single space, then collapse
            // any runs of whitespace it produced (e.g. "module @fast please"
            // would otherwise leave a double space behind).
            cleaned.replaceSubrange(fullRange, with: " ")
            if let collapse = try? NSRegularExpression(pattern: "[ \\t]{2,}") {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = collapse.stringByReplacingMatches(in: cleaned, range: range, withTemplate: " ")
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

            return InlineOverride(runtimeTarget: mapping.target, cleanedDescription: cleaned)
        }
        return nil
    }

    // MARK: - Regex Heuristic Fallback

    private func classifyAutomaticHeuristic(_ task: TaskRecord) -> Decision {
        let desc = task.taskDescription.lowercased()

        if matchesIsolationSignals(desc) {
            return vmDecision()
        }
        if Self.matchesWebInteractionSignals(desc) || matchesGUISignals(desc) {
            return automaticAppOrVMDecision()
        }
        return fastDecision()
    }

    private func automaticAppOrVMDecision() -> Decision {
        guard appWorkerAvailable() else {
            return vmDecision()
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

    private static let webInteractionPattern: NSRegularExpression? = {
        let pattern = [
            "\\bhttps?://",
            "\\bwww\\.",
            "\\bwebsite\\b",
            "\\bweb site\\b",
            "\\bwebpage\\b",
            "\\bweb page\\b",
            "\\bbrowser\\b",
            "\\bchrome\\b",
            "\\bchromium\\b",
            "\\bsafari\\b",
            "\\bfirefox\\b",
            "\\bedge\\b",
            "\\bopen\\b.*\\b(google|reddit|youtube|website|webpage|web page|site|url)\\b",
            "\\bgo to\\b.*\\b(google|reddit|youtube|website|webpage|web page|site|url)\\b",
            "\\bnavigate\\b",
            "\\burl\\b",
            "\\bclick\\b.*\\b(web|site|page|link|button)\\b",
            "\\bplay\\b.*\\b(game|tic tac toe|tictactoe|browser)\\b",
            "\\bform\\b",
            "\\blog in\\b",
            "\\bsign in\\b",
        ].joined(separator: "|")
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

    private static func matchesWebInteractionSignals(_ text: String) -> Bool {
        guard let regex = webInteractionPattern else { return false }
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
