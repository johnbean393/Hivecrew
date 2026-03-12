import Foundation

public struct CodexRateLimitWindowSnapshot: Codable, Equatable, Sendable {
    public let usedPercent: Int
    public let windowMinutes: Int
    public let resetAt: Date?

    public init(
        usedPercent: Int,
        windowMinutes: Int,
        resetAt: Date?
    ) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetAt = resetAt
    }

    public var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }

    public var compactLabel: String {
        if windowMinutes == 10_080 {
            return "Wk"
        }
        if windowMinutes % 1_440 == 0 {
            return "\(windowMinutes / 1_440)d"
        }
        if windowMinutes % 60 == 0 {
            return "\(windowMinutes / 60)h"
        }
        return "\(windowMinutes)m"
    }
}

public struct CodexCreditsSnapshot: Codable, Equatable, Sendable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: Double?

    public init(
        hasCredits: Bool?,
        unlimited: Bool?,
        balance: Double?
    ) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public struct CodexRateLimitSnapshot: Codable, Equatable, Sendable {
    public let planType: String?
    public let primary: CodexRateLimitWindowSnapshot?
    public let secondary: CodexRateLimitWindowSnapshot?
    public let credits: CodexCreditsSnapshot?
    public let updatedAt: Date

    public init(
        planType: String?,
        primary: CodexRateLimitWindowSnapshot?,
        secondary: CodexRateLimitWindowSnapshot?,
        credits: CodexCreditsSnapshot?,
        updatedAt: Date = Date()
    ) {
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.updatedAt = updatedAt
    }
}

public enum CodexRateLimitStore {
    public static let didChangeNotification = Notification.Name("HivecrewLLM.CodexRateLimitStore.didChange")
    public static let providerIdUserInfoKey = "providerId"

    private static let defaultsKeyPrefix = "hivecrew.codex.rate-limits."

    @discardableResult
    public static func store(providerId: String, snapshot: CodexRateLimitSnapshot) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else {
            return false
        }

        UserDefaults.standard.set(data, forKey: defaultsKey(providerId: providerId))
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: nil,
            userInfo: [providerIdUserInfoKey: providerId]
        )
        return true
    }

    public static func retrieve(providerId: String) -> CodexRateLimitSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(providerId: providerId)) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexRateLimitSnapshot.self, from: data)
    }

    @discardableResult
    public static func delete(providerId: String) -> Bool {
        UserDefaults.standard.removeObject(forKey: defaultsKey(providerId: providerId))
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: nil,
            userInfo: [providerIdUserInfoKey: providerId]
        )
        return true
    }

    private static func defaultsKey(providerId: String) -> String {
        defaultsKeyPrefix + providerId
    }
}

func parseCodexRateLimitSnapshot(from event: [String: Any]) -> CodexRateLimitSnapshot? {
    guard (event["type"] as? String) == "codex.rate_limits" else {
        return nil
    }

    let rateLimits = event["rate_limits"] as? [String: Any]
    let primary = parseCodexRateLimitWindow(from: rateLimits?["primary"])
    let secondary = parseCodexRateLimitWindow(from: rateLimits?["secondary"])
    let credits = parseCodexCreditsSnapshot(from: event["credits"])

    guard primary != nil || secondary != nil || credits != nil else {
        return nil
    }

    return CodexRateLimitSnapshot(
        planType: event["plan_type"] as? String,
        primary: primary,
        secondary: secondary,
        credits: credits
    )
}

private func parseCodexRateLimitWindow(from value: Any?) -> CodexRateLimitWindowSnapshot? {
    guard let payload = value as? [String: Any] else {
        return nil
    }

    guard let usedPercent = intValue(payload["used_percent"]),
          let windowMinutes = intValue(payload["window_minutes"]) else {
        return nil
    }

    let resetTimestamp = intValue(payload["reset_at"]) ?? intValue(payload["resets_at"])
    let resetAt = resetTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }

    return CodexRateLimitWindowSnapshot(
        usedPercent: usedPercent,
        windowMinutes: windowMinutes,
        resetAt: resetAt
    )
}

private func parseCodexCreditsSnapshot(from value: Any?) -> CodexCreditsSnapshot? {
    guard let payload = value as? [String: Any] else {
        return nil
    }

    let hasCredits = boolValue(payload["has_credits"])
    let unlimited = boolValue(payload["unlimited"])
    let balance = doubleValue(payload["balance"])

    if hasCredits == nil && unlimited == nil && balance == nil {
        return nil
    }

    return CodexCreditsSnapshot(
        hasCredits: hasCredits,
        unlimited: unlimited,
        balance: balance
    )
}

private func intValue(_ value: Any?) -> Int? {
    switch value {
    case let int as Int:
        return int
    case let number as NSNumber:
        return number.intValue
    case let string as String:
        return Int(string)
    default:
        return nil
    }
}

private func doubleValue(_ value: Any?) -> Double? {
    switch value {
    case let double as Double:
        return double
    case let number as NSNumber:
        return number.doubleValue
    case let string as String:
        return Double(string)
    default:
        return nil
    }
}

private func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let bool as Bool:
        return bool
    case let number as NSNumber:
        return number.boolValue
    case let string as String:
        return Bool(string)
    default:
        return nil
    }
}
