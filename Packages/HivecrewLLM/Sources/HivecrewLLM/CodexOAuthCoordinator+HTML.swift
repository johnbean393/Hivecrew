import Foundation

extension CodexOAuthCoordinator {
    nonisolated static func successPage(message: String) -> String {
        htmlPage(title: "Hivecrew OAuth Connected", message: message)
    }

    nonisolated static func failurePage(message: String) -> String {
        htmlPage(title: "Hivecrew OAuth Failed", message: message)
    }

    nonisolated static func htmlPage(title: String, message: String) -> String {
        let escapedTitle = escapeHTML(title)
        let escapedMessage = escapeHTML(message)
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>\(escapedTitle)</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 40px; color: #111; }
            h1 { margin-bottom: 12px; font-size: 20px; }
            p { margin-top: 0; line-height: 1.5; }
          </style>
        </head>
        <body>
          <h1>\(escapedTitle)</h1>
          <p>\(escapedMessage)</p>
        </body>
        </html>
        """
    }

    nonisolated static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
