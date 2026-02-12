//
//  ContextBudget.swift
//  HivecrewLLM
//
//  Context-budget lookup and cache for provider/model combinations.
//

import Foundation

public enum ContextBudgetSource: String, Sendable, Codable {
    case models
    case modelDetail
    case errorLearned
    case unknown
}

public struct ContextBudget: Sendable, Codable, Equatable {
    public let maxInputTokens: Int?
    public let source: ContextBudgetSource
    public let observedAt: Date
    public let requestedTokens: Int?

    public init(
        maxInputTokens: Int?,
        source: ContextBudgetSource,
        observedAt: Date = Date(),
        requestedTokens: Int? = nil
    ) {
        self.maxInputTokens = maxInputTokens
        self.source = source
        self.observedAt = observedAt
        self.requestedTokens = requestedTokens
    }
}

public actor ContextBudgetResolver {
    private struct CacheKey: Hashable {
        let providerKey: String
        let modelKey: String
    }

    private struct CacheEntry {
        let budget: ContextBudget
        let expiresAt: Date
    }

    public static let shared = ContextBudgetResolver()

    private let cacheTTL: TimeInterval
    private let unknownCacheTTL: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [CacheKey: CacheEntry] = [:]

    public init(
        cacheTTL: TimeInterval = 60 * 60,
        unknownCacheTTL: TimeInterval = 5 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.cacheTTL = cacheTTL
        self.unknownCacheTTL = unknownCacheTTL
        self.now = now
    }

    public func resolve(
        using client: any LLMClientProtocol,
        modelId: String? = nil
    ) async -> ContextBudget {
        let resolvedModelId = modelId ?? client.configuration.model
        let key = cacheKey(
            providerBaseURL: client.configuration.baseURL,
            modelId: resolvedModelId
        )

        if let cached = cachedEntry(for: key) {
            return cached.budget
        }

        do {
            let models = try await client.listModelsDetailed()
            if let match = Self.matchModel(resolvedModelId, in: models),
               let contextLength = match.contextLength,
               contextLength > 0 {
                let budget = ContextBudget(
                    maxInputTokens: contextLength,
                    source: .models,
                    observedAt: now()
                )
                store(budget: budget, for: key, ttl: cacheTTL)
                return budget
            }
        } catch {
            // Resolve is best-effort: callers should continue with reactive fallback.
        }

        let unknown = ContextBudget(
            maxInputTokens: nil,
            source: .unknown,
            observedAt: now()
        )
        store(budget: unknown, for: key, ttl: unknownCacheTTL)
        return unknown
    }

    @discardableResult
    public func learnContextLimit(
        providerBaseURL: URL?,
        modelId: String,
        maxInputTokens: Int?,
        requestedTokens: Int?
    ) -> ContextBudget? {
        guard let learnedLimit = maxInputTokens, learnedLimit > 0 else {
            return nil
        }

        let key = cacheKey(providerBaseURL: providerBaseURL, modelId: modelId)
        var effectiveLimit = learnedLimit
        if let existing = cachedEntry(for: key)?.budget.maxInputTokens, existing > 0 {
            effectiveLimit = min(existing, learnedLimit)
        }

        let learnedBudget = ContextBudget(
            maxInputTokens: effectiveLimit,
            source: .errorLearned,
            observedAt: now(),
            requestedTokens: requestedTokens
        )
        store(budget: learnedBudget, for: key, ttl: cacheTTL)
        return learnedBudget
    }

    public func cachedBudget(
        providerBaseURL: URL?,
        modelId: String
    ) -> ContextBudget? {
        let key = cacheKey(providerBaseURL: providerBaseURL, modelId: modelId)
        return cachedEntry(for: key)?.budget
    }

    public func clearCache() {
        cache.removeAll()
    }

    private func cachedEntry(for key: CacheKey) -> CacheEntry? {
        guard let entry = cache[key] else {
            return nil
        }

        if entry.expiresAt <= now() {
            cache.removeValue(forKey: key)
            return nil
        }

        return entry
    }

    private func store(
        budget: ContextBudget,
        for key: CacheKey,
        ttl: TimeInterval
    ) {
        cache[key] = CacheEntry(
            budget: budget,
            expiresAt: now().addingTimeInterval(ttl)
        )
    }

    private func cacheKey(providerBaseURL: URL?, modelId: String) -> CacheKey {
        CacheKey(
            providerKey: Self.normalizedProviderKey(providerBaseURL),
            modelKey: Self.normalizeModelID(modelId)
        )
    }

    private static func matchModel(
        _ modelId: String,
        in models: [LLMProviderModel]
    ) -> LLMProviderModel? {
        let target = normalizeModelID(modelId)
        if let exact = models.first(where: { normalizeModelID($0.id) == target }) {
            return exact
        }

        let targetSuffix = modelSuffix(target)
        if let targetSuffix {
            if let suffixMatch = models.first(where: { modelSuffix(normalizeModelID($0.id)) == targetSuffix }) {
                return suffixMatch
            }
        }

        return nil
    }

    private static func normalizeModelID(_ modelId: String) -> String {
        modelId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func modelSuffix(_ modelId: String) -> String? {
        guard let slash = modelId.lastIndex(of: "/") else {
            return nil
        }
        let suffix = modelId[modelId.index(after: slash)...]
        return suffix.isEmpty ? nil : String(suffix)
    }

    private static func normalizedProviderKey(_ providerBaseURL: URL?) -> String {
        let sourceURL = providerBaseURL ?? defaultLLMProviderBaseURL
        guard var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
            return sourceURL.absoluteString.lowercased()
        }

        components.query = nil
        components.fragment = nil
        components.host = components.host?.lowercased()
        var normalizedPath = components.path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        components.path = normalizedPath

        if let value = components.string, !value.isEmpty {
            return value
        }
        return sourceURL.absoluteString.lowercased()
    }
}
