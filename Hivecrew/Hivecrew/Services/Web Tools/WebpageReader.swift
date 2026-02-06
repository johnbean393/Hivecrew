//
//  WebpageReader.swift
//  Hivecrew
//
//  Webpage content reader using Jina AI with txtify.it fallback
//

import Foundation

public class WebpageReader {
    
    /// Read webpage content as Markdown using Jina AI, falling back to txtify.it on rate limiting
    /// - Parameter url: The URL of the webpage to read
    /// - Returns: The webpage content in Markdown format (Jina) or plain text (txtify)
    static func readWebpage(url: URL) async throws -> String {
        do {
            return try await readWithJina(url: url)
        } catch WebpageReaderError.httpError(let statusCode) where statusCode == 429 {
            // Jina rate-limited — fall back to txtify.it
            return try await readWithTxtify(url: url)
        }
    }
    
    // MARK: - Jina AI
    
    private static func readWithJina(url: URL) async throws -> String {
        let jinaURLString = "https://r.jina.ai/\(url.absoluteString)"
        guard let jinaURL = URL(string: jinaURLString) else {
            throw WebpageReaderError.invalidURL
        }
        
        var request = URLRequest(url: jinaURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebpageReaderError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw WebpageReaderError.httpError(statusCode: httpResponse.statusCode)
        }
        
        guard let content = String(data: data, encoding: .utf8) else {
            throw WebpageReaderError.decodingFailed
        }
        
        return content
    }
    
    // MARK: - txtify.it fallback
    
    private static func readWithTxtify(url: URL) async throws -> String {
        // txtify.it expects the raw target URL appended directly after the base path
        guard let txtifyURL = URL(string: "https://txtify.it/\(url.absoluteString)") else {
            throw WebpageReaderError.invalidURL
        }
        
        var request = URLRequest(url: txtifyURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,text/plain;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebpageReaderError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw WebpageReaderError.httpError(statusCode: httpResponse.statusCode)
        }
        
        guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
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
