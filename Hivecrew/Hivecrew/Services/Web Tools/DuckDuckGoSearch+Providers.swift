import Foundation
import GoogleSearch
import OSLog
import Security

enum SearchProviderKeychain {
    private static let unifiedService = "com.pattonium.hivecrew"
    private static let legacyServices = ["com.pattonium.web-search"]
    private static let searchAPIKeyAccount = "searchapi"
    private static let serpAPIKeyAccount = "serpapi"

    static func retrieveSearchAPIKey() -> String? { retrieve(account: searchAPIKeyAccount) }
    static func storeSearchAPIKey(_ key: String) { store(key, account: searchAPIKeyAccount) }
    static func deleteSearchAPIKey() { delete(account: searchAPIKeyAccount) }
    static func retrieveSerpAPIKey() -> String? { retrieve(account: serpAPIKeyAccount) }
    static func storeSerpAPIKey(_ key: String) { store(key, account: serpAPIKeyAccount) }
    static func deleteSerpAPIKey() { delete(account: serpAPIKeyAccount) }

    private static func store(_ value: String, account: String) {
        delete(account: account)
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: unifiedService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func retrieve(account: String) -> String? {
        if let value = retrieve(account: account, fromService: unifiedService) { return value }
        for legacyService in legacyServices {
            if let legacyValue = retrieve(account: account, fromService: legacyService) {
                store(legacyValue, account: account)
                return legacyValue
            }
        }
        return nil
    }

    private static func delete(account: String) {
        let services = [unifiedService] + legacyServices
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func retrieve(account: String, fromService service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }
}

enum SearchAPIClient {
    struct Response: Decodable { let organic_results: [OrganicResult]? }
    struct OrganicResult: Decodable { let link: String?; let title: String?; let snippet: String? }
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pattonium.hivecrew",
        category: "SearchAPIClient"
    )
    enum SearchAPIError: LocalizedError {
        case invalidResponse
        case httpError(Int, String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from SearchAPI."
            case .httpError(let status, let body):
                return "SearchAPI request failed (\(status)). \(body.isEmpty ? "No response body." : body)"
            }
        }
    }

    static func search(query: String, site: String? = nil, resultCount: Int, startDate: Date? = nil, endDate: Date? = nil, apiKey: String) async throws -> [SearchResult] {
        let startTime = Date()
        let maxCount = min(max(resultCount, 1), 100)
        var results: [SearchResult] = []
        var page = 1
        while results.count < maxCount {
            let data = try await requestData(query: query, site: site, startDate: startDate, endDate: endDate, apiKey: apiKey, page: page)
            let response = try JSONDecoder().decode(Response.self, from: data)
            let items = response.organic_results ?? []
            if items.isEmpty { break }
            for item in items {
                guard let link = item.link, !link.isEmpty else { continue }
                results.append(SearchResult(url: link, title: item.title ?? "Search Result", snippet: item.snippet ?? ""))
                if results.count == maxCount { break }
            }
            if items.count < 10 { break }
            page += 1
        }
        logger.info("SearchAPI returned \(results.count) result(s) in \(Date.now.timeIntervalSince(startTime)) secs")
        return results
    }

    private static func requestData(query: String, site: String?, startDate: Date?, endDate: Date?, apiKey: String, page: Int) async throws -> Data {
        var fullQuery = query
        if let site, !site.isEmpty { fullQuery += " site:\(site)" }
        var components = URLComponents(string: "https://www.searchapi.io/api/v1/search")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "engine", value: "google"),
            URLQueryItem(name: "q", value: fullQuery),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "page", value: "\(page)")
        ]
        if let startDate { queryItems.append(URLQueryItem(name: "time_period_min", value: startDate.toString(dateFormat: "MM/dd/yyyy"))) }
        if let endDate { queryItems.append(URLQueryItem(name: "time_period_max", value: endDate.toString(dateFormat: "MM/dd/yyyy"))) }
        components.queryItems = queryItems
        guard let url = components.url else { throw SearchAPIError.invalidResponse }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else { throw SearchAPIError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SearchAPIError.httpError(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

enum SerpAPIClient {
    struct Response: Decodable { let organic_results: [OrganicResult]? }
    struct OrganicResult: Decodable { let link: String?; let title: String?; let snippet: String? }
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pattonium.hivecrew",
        category: "SerpAPIClient"
    )
    enum SerpAPIError: LocalizedError {
        case invalidResponse
        case httpError(Int, String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from SerpAPI."
            case .httpError(let status, let body):
                return "SerpAPI request failed (\(status)). \(body.isEmpty ? "No response body." : body)"
            }
        }
    }

    static func search(query: String, site: String? = nil, resultCount: Int, startDate: Date? = nil, endDate: Date? = nil, apiKey: String) async throws -> [SearchResult] {
        let startTime = Date()
        let maxCount = min(max(resultCount, 1), 100)
        var results: [SearchResult] = []
        var start = 0
        while results.count < maxCount {
            let data = try await requestData(query: query, site: site, startDate: startDate, endDate: endDate, apiKey: apiKey, start: start)
            let response = try JSONDecoder().decode(Response.self, from: data)
            let items = response.organic_results ?? []
            if items.isEmpty { break }
            for item in items {
                guard let link = item.link, !link.isEmpty else { continue }
                results.append(SearchResult(url: link, title: item.title ?? "Search Result", snippet: item.snippet ?? ""))
                if results.count == maxCount { break }
            }
            if items.count < 10 { break }
            start += 10
        }
        logger.info("SerpAPI returned \(results.count) result(s) in \(Date.now.timeIntervalSince(startTime)) secs")
        return results
    }

    private static func requestData(query: String, site: String?, startDate: Date?, endDate: Date?, apiKey: String, start: Int) async throws -> Data {
        var fullQuery = query
        if let site, !site.isEmpty { fullQuery += " site:\(site)" }
        var components = URLComponents(string: "https://serpapi.com/search.json")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "engine", value: "google"),
            URLQueryItem(name: "q", value: fullQuery),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "start", value: "\(start)"),
            URLQueryItem(name: "num", value: "10")
        ]
        if let startDate, let endDate {
            queryItems.append(URLQueryItem(name: "tbs", value: "cdr:1,cd_min:\(startDate.toString(dateFormat: "MM/dd/yyyy")),cd_max:\(endDate.toString(dateFormat: "MM/dd/yyyy"))"))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw SerpAPIError.invalidResponse }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else { throw SerpAPIError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SerpAPIError.httpError(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

enum GoogleSearchClient {
    struct ResultRecord: Sendable {
        let title: String
        let url: String
        let snippet: String
    }

    static func search(
        query: String,
        site: String? = nil,
        resultCount: Int,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) async throws -> [SearchResult] {
        let googleResults = try await GoogleSearch.search(
            query: query,
            site: site,
            resultCount: resultCount,
            startDate: startDate,
            endDate: endDate
        )
        return map(
            results: googleResults.map { result in
                ResultRecord(
                    title: result.source,
                    url: result.url,
                    snippet: result.text
                )
            }
        )
    }

    static func map(results: [ResultRecord]) -> [SearchResult] {
        results.map { result in
            SearchResult(
                url: result.url,
                title: result.title,
                snippet: result.snippet
            )
        }
    }
}

struct WebSearchExecution {
    let results: [SearchResult]
    let notes: [String]
}

enum WebSearchService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pattonium.hivecrew",
        category: "WebSearchService"
    )

    typealias SearchPerformer = @Sendable (
        _ engine: String,
        _ query: String,
        _ site: String?,
        _ resultCount: Int,
        _ startDate: Date?,
        _ endDate: Date?
    ) async throws -> [SearchResult]

    static func search(
        query: String,
        site: String? = nil,
        resultCount: Int,
        startDate: Date? = nil,
        endDate: Date? = nil,
        primaryEngine: String
    ) async -> WebSearchExecution {
        await search(
            query: query,
            site: site,
            resultCount: resultCount,
            startDate: startDate,
            endDate: endDate,
            primaryEngine: primaryEngine,
            performSearch: liveSearch
        )
    }

    static func search(
        query: String,
        site: String? = nil,
        resultCount: Int,
        startDate: Date? = nil,
        endDate: Date? = nil,
        primaryEngine: String,
        performSearch: SearchPerformer
    ) async -> WebSearchExecution {
        var results: [SearchResult] = []
        var notes: [String] = []
        var usedEngine = primaryEngine

        let simplifiedQuery = simplifyQuery(query)
        var queryVariants = [query]
        if !simplifiedQuery.isEmpty, simplifiedQuery != query {
            queryVariants.append(simplifiedQuery)
        }

        let candidateEngines = engineOrder(for: primaryEngine)
        logger.info("Starting web search with primary engine: \(primaryEngine, privacy: .public)")

        for variant in queryVariants {
            for engine in candidateEngines {
                do {
                    results = try await performSearch(
                        engine,
                        variant,
                        site,
                        resultCount,
                        startDate,
                        endDate
                    )
                    if !results.isEmpty {
                        usedEngine = engine
                        logger.info("Web search succeeded with engine: \(engine, privacy: .public)")
                        if engine != primaryEngine {
                            notes.append("Retried with \(engine).")
                        }
                        break
                    }
                    logger.info("Web search returned 0 results for engine: \(engine, privacy: .public)")
                } catch {
                    logger.error("Web search failed for engine \(engine, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    notes.append("Search (\(engine)) failed: \(error.localizedDescription)")
                }
            }

            if results.isEmpty, site != nil {
                let broadenedEngines = uniqueEngines([usedEngine] + candidateEngines)
                for engine in broadenedEngines {
                    do {
                        results = try await performSearch(
                            engine,
                            variant,
                            nil,
                            resultCount,
                            startDate,
                            endDate
                        )
                        if !results.isEmpty {
                            logger.info("Broadened web search succeeded with engine: \(engine, privacy: .public)")
                            if engine != usedEngine {
                                notes.append("Broadened search used \(engine).")
                            }
                            notes.append("No results with site filter; broadened search.")
                            break
                        }
                        logger.info("Broadened web search returned 0 results for engine: \(engine, privacy: .public)")
                    } catch {
                        logger.error("Broadened web search failed for engine \(engine, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        notes.append("Broadened search (\(engine)) failed: \(error.localizedDescription)")
                    }
                }
            }

            if !results.isEmpty {
                if variant != query {
                    notes.append("Used simplified query: \"\(variant)\".")
                }
                break
            }
        }

        return WebSearchExecution(results: results, notes: notes)
    }

    private static func liveSearch(
        engine: String,
        query: String,
        site: String?,
        resultCount: Int,
        startDate: Date?,
        endDate: Date?
    ) async throws -> [SearchResult] {
        switch engine {
        case "duckduckgo":
            return try await DuckDuckGoSearch.search(
                query: query,
                site: site,
                resultCount: resultCount,
                startDate: startDate,
                endDate: endDate
            )
        case "searchapi":
            guard let apiKey = SearchProviderKeychain.retrieveSearchAPIKey(), !apiKey.isEmpty else {
                throw WebSearchServiceError.missingAPIKey("SearchAPI")
            }
            return try await SearchAPIClient.search(
                query: query,
                site: site,
                resultCount: resultCount,
                startDate: startDate,
                endDate: endDate,
                apiKey: apiKey
            )
        case "serpapi":
            guard let apiKey = SearchProviderKeychain.retrieveSerpAPIKey(), !apiKey.isEmpty else {
                throw WebSearchServiceError.missingAPIKey("SerpAPI")
            }
            return try await SerpAPIClient.search(
                query: query,
                site: site,
                resultCount: resultCount,
                startDate: startDate,
                endDate: endDate,
                apiKey: apiKey
            )
        default:
            return try await GoogleSearchClient.search(
                query: query,
                site: site,
                resultCount: resultCount,
                startDate: startDate,
                endDate: endDate
            )
        }
    }

    private static func engineOrder(for primary: String) -> [String] {
        switch primary {
        case "duckduckgo":
            return ["duckduckgo", "google"]
        case "searchapi", "serpapi":
            return [primary, "duckduckgo", "google"]
        default:
            return [primary, "duckduckgo"]
        }
    }

    private static func simplifyQuery(_ query: String) -> String {
        var simplified = query
        let patterns = [
            "\\b(19|20)\\d{2}\\b",
            "\\b(as of|latest|current|recent)\\b",
            "\\b(release date|pricing|benchmark|benchmarks)\\b"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(simplified.startIndex..., in: simplified)
                simplified = regex.stringByReplacingMatches(
                    in: simplified,
                    options: [],
                    range: range,
                    withTemplate: ""
                )
            }
        }
        simplified = simplified.replacingOccurrences(of: "  ", with: " ")
        return simplified.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueEngines(_ engines: [String]) -> [String] {
        var seen: Set<String> = []
        return engines.filter { seen.insert($0).inserted }
    }
}

enum WebSearchServiceError: Error, LocalizedError {
    case missingAPIKey(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "\(provider) API key not configured."
        }
    }
}

extension Date {
    func toString(dateFormat format: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = format
        return dateFormatter.string(from: self)
    }
}
