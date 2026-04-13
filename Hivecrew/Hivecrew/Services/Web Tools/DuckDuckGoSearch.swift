//
//  DuckDuckGoSearch.swift
//  Hivecrew
//
//  DuckDuckGo web search implementation
//

import Foundation
import OSLog
#if canImport(WebKit)
import WebKit
import ObjectiveC
#endif

public class DuckDuckGoSearch {
    
    /// A `Logger` object for the `DuckDuckGoSearch` object
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: DuckDuckGoSearch.self)
    )
    
    /// Function to remove HTML tags using regex
    private static func removeHTMLTags(
        from html: String
    ) -> String {
        let pattern = "<[^>]+>"
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let range = NSRange(location: 0, length: html.utf16.count)
        return regex?.stringByReplacingMatches(
            in: html,
            options: [],
            range: range,
            withTemplate: ""
        ) ?? html
    }
    
    /// Function to decode common HTML entities and numeric codes
    private static func decodeHTMLEntities(
        _ string: String
    ) -> String {
        var result = string
        // Replace common entities
        let entities: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&lt;": "<",
            "&gt;": ">",
            "&#39;": "'",
            "&#x27;": "'",
            "&#x2F;": "/",
            "&rsquo;": "'",
            "&lsquo;": "'",
            "&rdquo;": "\"",
            "&ldquo;": "\""
        ]
        for (entity, value) in entities {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        // Numeric decimal entities: &#1234;
        let decimalPattern = "&#(\\d+);"
        let decimalRegex = try! NSRegularExpression(pattern: decimalPattern, options: [])
        let matches = decimalRegex.matches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count))
        for match in matches.reversed() {
            if let range = Range(match.range(at: 1), in: result),
               let code = Int(result[range]),
               let scalar = UnicodeScalar(code) {
                let char = String(scalar)
                let fullRange = match.range(at: 0)
                if let swiftRange = Range(fullRange, in: result) {
                    result.replaceSubrange(swiftRange, with: char)
                }
            }
        }
        // Numeric hex entities: &#x1F60A;
        let hexPattern = "&#x([0-9A-Fa-f]+);"
        let hexRegex = try! NSRegularExpression(pattern: hexPattern, options: [])
        let hexMatches = hexRegex.matches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count))
        for match in hexMatches.reversed() {
            if let range = Range(match.range(at: 1), in: result),
               let code = Int(result[range], radix: 16),
               let scalar = UnicodeScalar(code) {
                let char = String(scalar)
                let fullRange = match.range(at: 0)
                if let swiftRange = Range(fullRange, in: result) {
                    result.replaceSubrange(swiftRange, with: char)
                }
            }
        }
        return result
    }
    
    /// Function to search DuckDuckGo for sources
    public static func search(
        query: String,
        site: String? = nil,
        resultCount: Int,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async throws -> [SearchResult] {
        #if canImport(WebKit) && !os(watchOS)
        do {
            let webViewResults = try await fetchResultsWithWebView(
                query: query,
                site: site,
                resultCount: resultCount,
                startDate: startDate,
                endDate: endDate
            )
            if !webViewResults.isEmpty {
                return webViewResults
            }
        } catch {
            Self.logger.info("DuckDuckGo WebView fetch failed, falling back to HTML parsing: \(error.localizedDescription)")
        }
        #endif

        // Complete query
        var query: String = query
        if let site = site {
            query += " site:\(site)"
        }
        if let encodedQuery = query.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) {
            query = encodedQuery
        } else {
            return []
        }
        // Formulate parameters
        let maxCount = min(max(resultCount, 1), 20)
        var urlString = "https://html.duckduckgo.com/html/?q=\(query)"
        // Add date parameter to URL if needed
        if let startDate,
           let endDate {
            let startDateString = startDate.toString(dateFormat: "yyyy-MM-dd")
            let endDateString = endDate.toString(dateFormat: "yyyy-MM-dd")
            urlString += "&df=\(startDateString)..\(endDateString)"
        }
        // Formulate URL
        guard let url = URL(string: urlString) else { return [] }
        // Formulate request
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        // Make request
        let startTime: Date = .now
        let (data, _) = try await URLSession.shared.data(for: request)
        Self.logger.info(
            "DuckDuckGo returned results in \(Date.now.timeIntervalSince(startTime)) secs"
        )
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        return parseResults(from: html, limit: maxCount)
    }

    #if canImport(WebKit) && !os(watchOS)
    @MainActor
    private static func fetchResultsWithWebView(
        query: String,
        site: String? = nil,
        resultCount: Int,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async throws -> [SearchResult] {
        let maxCount = min(max(resultCount, 1), 20)
        let searchURL = buildSearchURL(
            query: query,
            site: site,
            resultCount: maxCount,
            startDate: startDate,
            endDate: endDate
        )

        let configuration = WKWebViewConfiguration()
        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = webpagePreferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let coordinator = DuckDuckGoSearchWebViewCoordinator(limit: maxCount)

        return try await withCheckedThrowingContinuation { continuation in
            coordinator.onComplete = { result in
                continuation.resume(with: result)
            }
            webView.navigationDelegate = coordinator
            objc_setAssociatedObject(webView, "duckduckgoCoordinator", coordinator, .OBJC_ASSOCIATION_RETAIN)
            objc_setAssociatedObject(coordinator, "duckduckgoWebView", webView, .OBJC_ASSOCIATION_RETAIN)

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if !coordinator.isCompleted {
                    coordinator.complete(with: .failure(DuckDuckGoSearchError.timeout))
                }
            }

            webView.load(URLRequest(url: searchURL))
        }
    }

    private static func buildSearchURL(
        query: String,
        site: String?,
        resultCount: Int,
        startDate: Date?,
        endDate: Date?
    ) -> URL {
        var searchQuery = query
        if let site, !site.isEmpty {
            searchQuery = "\(query) site:\(site)"
        }

        var components = URLComponents(string: "https://duckduckgo.com/")!
        var queryItems = [
            URLQueryItem(name: "q", value: searchQuery),
            URLQueryItem(name: "ia", value: "web")
        ]

        if let startDate, let endDate {
            let startDateString = startDate.toString(dateFormat: "yyyy-MM-dd")
            let endDateString = endDate.toString(dateFormat: "yyyy-MM-dd")
            queryItems.append(URLQueryItem(name: "df", value: "\(startDateString)..\(endDateString)"))
        }

        components.queryItems = queryItems
        return components.url!
    }
    #endif

    static func parseResults(from html: String, limit: Int) -> [SearchResult] {
        let pattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>.*?</a>.*?(?:<a[^>]*class="result__snippet"[^>]*>(.*?)</a>|<div[^>]*class="result__snippet"[^>]*>(.*?)</div>)"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        let nsrange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: nsrange)
        var results: [SearchResult] = []
        for match in matches {
            guard let hrefRange = Range(match.range(at: 1), in: html) else { continue }
            let duckURLStr = String(html[hrefRange])
            guard let components = URLComponents(string: duckURLStr),
                  let uddgValue = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
                  let decoded = uddgValue.removingPercentEncoding,
                  let resultURL = URL(string: decoded) else {
                continue
            }
            let snippetRange2 = match.range(at: 2)
            let snippetRange3 = match.range(at: 3)
            var snippet: String?
            if snippetRange2.location != NSNotFound, let range = Range(snippetRange2, in: html) {
                snippet = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if snippetRange3.location != NSNotFound, let range = Range(snippetRange3, in: html) {
                snippet = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let textWithHTML = snippet, !textWithHTML.isEmpty else { continue }
            let cleanText = Self.decodeHTMLEntities(
                Self.removeHTMLTags(from: textWithHTML)
            )
            guard !cleanText.isEmpty else { continue }
            
            // Extract title from the result
            let titlePattern = #"<a[^>]*class="result__a"[^>]*>(.*?)</a>"#
            let titleRegex = try! NSRegularExpression(pattern: titlePattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
            var title = "Untitled"
            if let titleMatch = titleRegex.firstMatch(in: html, options: [], range: match.range) {
                if let titleRange = Range(titleMatch.range(at: 1), in: html) {
                    let rawTitle = String(html[titleRange])
                    title = Self.decodeHTMLEntities(Self.removeHTMLTags(from: rawTitle))
                }
            }
            
            // Create search result
            let result = SearchResult(
                url: resultURL.absoluteString,
                title: title,
                snippet: cleanText
            )
            results.append(result)
            if results.count == limit { break }
        }
        return results
    }
    
    // Custom error for DuckDuckGo search
    enum DuckDuckGoSearchError: LocalizedError {
        case startDateAfterEndDate
        case timeout
        case invalidResponse
        var errorDescription: String? {
            switch self {
                case .startDateAfterEndDate:
                    return "The start date cannot be after the end date."
                case .timeout:
                    return "DuckDuckGo search timed out."
                case .invalidResponse:
                    return "DuckDuckGo returned an invalid response."
            }
        }
    }
    
}

#if canImport(WebKit) && !os(watchOS)
@MainActor
private final class DuckDuckGoSearchWebViewCoordinator: NSObject, WKNavigationDelegate {
    struct ResultPayload: Decodable {
        let title: String
        let url: String
        let snippet: String
    }

    let limit: Int
    var onComplete: ((Result<[SearchResult], Error>) -> Void)?
    var isCompleted = false
    private var extractionAttempts = 0

    init(limit: Int) {
        self.limit = limit
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        extractResults(from: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        complete(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        complete(with: .failure(error))
    }

    func complete(with result: Result<[SearchResult], Error>) {
        guard !isCompleted else { return }
        isCompleted = true
        onComplete?(result)
    }

    private func extractResults(from webView: WKWebView) {
        guard !isCompleted else { return }

        let script = """
        (() => JSON.stringify(
          Array.from(document.querySelectorAll("article[data-testid='result']:not([data-layout='ad'])"))
            .map(article => {
              const titleLink = article.querySelector("a[data-testid='result-title-a']");
              const snippetNode = article.querySelector("[data-result='snippet']");
              return {
                title: titleLink?.textContent?.trim() || "",
                url: titleLink?.href || "",
                snippet: snippetNode?.textContent?.trim() || ""
              };
            })
            .filter(item => item.title && item.url && item.snippet)
        ))();
        """

        webView.evaluateJavaScript(script) { value, error in
            if let error {
                self.complete(with: .failure(error))
                return
            }

            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let payloads = try? JSONDecoder().decode([ResultPayload].self, from: data) else {
                self.complete(with: .failure(DuckDuckGoSearch.DuckDuckGoSearchError.invalidResponse))
                return
            }

            if payloads.isEmpty, self.extractionAttempts < 4 {
                self.extractionAttempts += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.extractResults(from: webView)
                }
                return
            }

            let results = payloads.prefix(self.limit).map {
                SearchResult(url: $0.url, title: $0.title, snippet: $0.snippet)
            }
            self.complete(with: .success(results))
        }
    }
}
#endif
