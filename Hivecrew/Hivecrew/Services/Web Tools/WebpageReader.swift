//
//  WebpageReader.swift
//  Hivecrew
//
//  Webpage content reader using Jina AI with markdown.new and txtify.it fallbacks
//

import Foundation
import AppKit

public class WebpageReader {
    
    /// Read webpage content as Markdown using Jina AI, then fall back to markdown.new, txtify.it, and direct fetches.
    /// - Parameter url: The URL of the webpage to read
    /// - Returns: The webpage content in Markdown format (Jina) or extracted plain text
    static func readWebpage(url: URL) async throws -> String {
        do {
            return try await readWithJina(url: url)
        } catch let WebpageReaderError.httpError(statusCode) where shouldUseProxyFallback(statusCode: statusCode) {
            do {
                return try await readWithMarkdownNew(url: url)
            } catch let WebpageReaderError.httpError(markdownNewStatusCode) where shouldUseProxyFallback(statusCode: markdownNewStatusCode) {
                do {
                    return try await readWithTxtify(url: url)
                } catch let WebpageReaderError.httpError(txtifyStatusCode) where shouldUseProxyFallback(statusCode: txtifyStatusCode) {
                    return try await readDirectly(url: url)
                } catch {
                    return try await readDirectly(url: url)
                }
            } catch {
                do {
                    return try await readWithTxtify(url: url)
                } catch {
                    return try await readDirectly(url: url)
                }
            }
        }
    }

    static func shouldUseProxyFallback(statusCode: Int) -> Bool {
        statusCode == 429 || statusCode == 451
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
    
    // MARK: - markdown.new fallback

    private static func readWithMarkdownNew(url: URL) async throws -> String {
        guard let markdownNewURL = URL(string: "https://markdown.new/\(url.absoluteString)") else {
            throw WebpageReaderError.invalidURL
        }

        var request = URLRequest(url: markdownNewURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/markdown,text/plain;q=0.9,text/html;q=0.8,*/*;q=0.7", forHTTPHeaderField: "Accept")

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

    // MARK: - Direct fetch fallback

    private static func readDirectly(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,text/plain;q=0.9,application/xhtml+xml,application/xml;q=0.8,*/*;q=0.7", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebpageReaderError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebpageReaderError.httpError(statusCode: httpResponse.statusCode)
        }

        let mimeType = httpResponse.mimeType ?? response.mimeType
        return try readableText(from: data, mimeType: mimeType)
    }

    static func readableText(from data: Data, mimeType: String?) throws -> String {
        if let mimeType, mimeType.contains("html") || mimeType.contains("xml") {
            if let htmlText = try? htmlDocumentText(from: data), !htmlText.isEmpty {
                return htmlText
            }
        }

        if let text = decodeText(data), !text.isEmpty {
            return text
        }

        if let htmlText = try? htmlDocumentText(from: data), !htmlText.isEmpty {
            return htmlText
        }

        throw WebpageReaderError.decodingFailed
    }

    private static func decodeText(_ data: Data) -> String? {
        let encodings: [String.Encoding] = [.utf8, .unicode, .utf16, .isoLatin1, .windowsCP1252]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func htmlDocumentText(from data: Data) throws -> String {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        let attributed = try NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        )
        let text = attributed.string
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw WebpageReaderError.decodingFailed
        }
        return text
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
