import Foundation

public struct RedactionService {
    public init() {}

    public func redact(_ text: String) -> String {
        var output = text
        let patterns = [
            "(?i)api[_-]?key\\s*[:=]\\s*[A-Za-z0-9_\\-]{16,}",
            "(?i)secret\\s*[:=]\\s*[A-Za-z0-9_\\-]{10,}",
            "(?i)password\\s*[:=]\\s*[^\\s]{6,}",
            "(?i)bearer\\s+[A-Za-z0-9_\\-.]{16,}"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(location: 0, length: output.utf16.count)
                output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "[REDACTED]")
            }
        }
        return output
    }
}
