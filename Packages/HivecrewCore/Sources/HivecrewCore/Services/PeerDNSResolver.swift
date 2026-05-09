//
//  PeerDNSResolver.swift
//  HivecrewCore
//
//  DNS-over-HTTPS resolver for peer tunnel hostnames. This is used only as a
//  fallback when the device's active resolver path has stale negative cache.
//

import Foundation

enum PeerDNSResolver {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }()

    static func aRecords(forHost host: String) async -> [String] {
        guard !host.isEmpty else { return [] }

        var components = URLComponents(string: "https://cloudflare-dns.com/dns-query")
        components?.queryItems = [
            URLQueryItem(name: "name", value: host),
            URLQueryItem(name: "type", value: "A")
        ]
        guard let requestURL = components?.url else { return [] }

        var request = URLRequest(url: requestURL)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return []
            }
            let result = try JSONDecoder().decode(PublicDNSLookupResponse.self, from: data)
            guard result.status == 0 else { return [] }
            return result.answer?
                .filter { $0.type == 1 }
                .map(\.data)
                .filter { !$0.isEmpty } ?? []
        } catch {
            return []
        }
    }

    static func resolves(host: String) async -> Bool {
        await !aRecords(forHost: host).isEmpty
    }
}

private struct PublicDNSLookupResponse: Decodable {
    let status: Int
    let answer: [PublicDNSAnswer]?

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case answer = "Answer"
    }
}

private struct PublicDNSAnswer: Decodable {
    let type: Int
    let data: String

    enum CodingKeys: String, CodingKey {
        case type = "type"
        case data = "data"
    }
}
