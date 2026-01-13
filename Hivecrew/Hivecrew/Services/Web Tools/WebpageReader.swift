//
//  WebpageReader.swift
//  Hivecrew
//
//  Webpage content reader using Jina AI
//

import Foundation

public class WebpageReader {
    
    /// Read webpage content as Markdown using Jina AI
    /// - Parameter url: The URL of the webpage to read
    /// - Returns: The webpage content in Markdown format
    static func readWebpage(url: URL) async throws -> String {
        // Construct Jina AI URL
        let jinaURLString = "https://r.jina.ai/\(url.absoluteString)"
        guard let jinaURL = URL(string: jinaURLString) else {
            throw WebpageReaderError.invalidURL
        }
        
        // Make request
        var request = URLRequest(url: jinaURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebpageReaderError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw WebpageReaderError.httpError(statusCode: httpResponse.statusCode)
        }
        
        // Decode content
        guard let content = String(data: data, encoding: .utf8) else {
            throw WebpageReaderError.decodingFailed
        }
        
        return content
    }
    
    enum WebpageReaderError: LocalizedError {
        case invalidURL
        case invalidResponse
        case httpError(statusCode: Int)
        case decodingFailed
        
        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid URL provided"
            case .invalidResponse:
                return "Invalid response from server"
            case .httpError(let statusCode):
                return "HTTP error: \(statusCode)"
            case .decodingFailed:
                return "Failed to decode webpage content"
            }
        }
    }
}
