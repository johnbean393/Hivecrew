//
//  WebpageExtractor.swift
//  Hivecrew
//
//  LLM-powered webpage information extraction
//

import Foundation
import HivecrewLLM

public class WebpageExtractor {
    private static let maxExcerptCharacters = 32_000
    private static let maxChunkCharacters = 1_600
    private static let maxKeywordChunks = 8
    private static let leadingExcerptCharacters = 2_500
    private static let trailingExcerptCharacters = 1_500
    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "did", "do", "does", "for", "from",
        "how", "if", "in", "is", "it", "its", "of", "on", "or", "say", "so", "that", "the",
        "their", "this", "to", "was", "were", "what", "when", "where", "which", "who", "will",
        "with", "year", "years"
    ]
    
    /// Extract specific information from a webpage using LLM
    /// - Parameters:
    ///   - url: The URL of the webpage
    ///   - question: The question to answer based on webpage content
    ///   - taskProviderId: The provider ID for the task's main model
    ///   - taskModelId: The model ID for the task's main model
    ///   - taskService: Task service to create worker LLM client
    /// - Returns: The answer to the question
    static func extractInfo(
        url: URL,
        question: String,
        taskProviderId: String,
        taskModelId: String,
        taskService: Any
    ) async throws -> String {
        // Fetch webpage content
        let content = try await WebpageReader.readWebpage(url: url)
        let excerpt = buildQuestionFocusedExcerpt(from: content, question: question)
        
        // Use the required worker model for extraction.
        // Cast taskService to access createWorkerLLMClient
        guard let service = taskService as? (any CreateWorkerClientProtocol) else {
            throw WebpageExtractorError.invalidTaskService
        }
        
        let client = try await service.createWorkerLLMClient(
            fallbackProviderId: taskProviderId,
            fallbackModelId: taskModelId
        )
        
        let prompt = """
        Based on the following webpage excerpt, answer this question concisely. Use the webpage excerpt ONLY. Do not use any other information. If the answer is not present in the excerpt, say not found.
        
        Question: \(question)
        
        Webpage excerpt:
        \(excerpt)
        
        Answer:
        """
        
        let messages = [LLMMessage.user(prompt)]
        let response = try await client.chat(messages: messages, tools: nil)
        
        return response.text ?? "Unable to extract information from webpage"
    }

    private static func buildQuestionFocusedExcerpt(from content: String, question: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxExcerptCharacters else {
            return trimmed
        }

        let keywords = questionKeywords(from: question)
        let chunks = contentChunks(from: trimmed)

        var sections: [String] = []
        var seen = Set<String>()

        func appendSection(_ title: String, _ body: String) {
            let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            guard seen.insert(normalized).inserted else { return }
            sections.append("[\(title)]\n\(normalized)")
        }

        appendSection("Document Start", String(trimmed.prefix(leadingExcerptCharacters)))

        if !keywords.isEmpty {
            let scoredChunks = chunks.enumerated()
                .map { (index, chunk) in
                    (index: index, score: keywordScore(chunk, keywords: keywords), chunk: chunk)
                }
                .filter { $0.score > 0 }
                .sorted {
                    if $0.score == $1.score {
                        return $0.index < $1.index
                    }
                    return $0.score > $1.score
                }

            for entry in scoredChunks.prefix(maxKeywordChunks) {
                appendSection("Relevant Excerpt", entry.chunk)
            }
        }

        appendSection("Document End", String(trimmed.suffix(trailingExcerptCharacters)))

        if sections.isEmpty {
            return String(trimmed.prefix(maxExcerptCharacters))
        }

        var result = ""
        for section in sections {
            let candidate = result.isEmpty ? section : result + "\n\n" + section
            if candidate.count > maxExcerptCharacters {
                break
            }
            result = candidate
        }

        if result.isEmpty {
            return String(trimmed.prefix(maxExcerptCharacters))
        }

        return result
    }

    private static func contentChunks(from content: String) -> [String] {
        let paragraphs = content
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paragraphs.isEmpty else {
            return splitLongChunk(content)
        }

        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            if paragraph.count > maxChunkCharacters {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: splitLongChunk(paragraph))
                continue
            }

            let candidate = current.isEmpty ? paragraph : current + "\n\n" + paragraph
            if candidate.count > maxChunkCharacters, !current.isEmpty {
                chunks.append(current)
                current = paragraph
            } else {
                current = candidate
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    private static func splitLongChunk(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChunkCharacters else {
            return trimmed.isEmpty ? [] : [trimmed]
        }

        var result: [String] = []
        var remainder = trimmed[...]

        while remainder.count > maxChunkCharacters {
            let splitIndex = remainder.index(remainder.startIndex, offsetBy: maxChunkCharacters)
            let chunk = String(remainder[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                result.append(chunk)
            }
            remainder = remainder[splitIndex...]
        }

        let tail = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            result.append(tail)
        }

        return result
    }

    private static func questionKeywords(from question: String) -> [String] {
        let normalized = question.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        let tokens = String(normalized)
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                token.count >= 3 && !stopWords.contains(token)
            }

        var seen = Set<String>()
        var keywords: [String] = []
        for token in tokens {
            if seen.insert(token).inserted {
                keywords.append(token)
            }
        }
        return keywords
    }

    private static func keywordScore(_ chunk: String, keywords: [String]) -> Int {
        let normalized = chunk.lowercased()
        return keywords.reduce(into: 0) { score, keyword in
            if normalized.contains(keyword) {
                score += 1
            }
        }
    }
    
    enum WebpageExtractorError: LocalizedError {
        case invalidTaskService
        
        var errorDescription: String? {
            switch self {
            case .invalidTaskService:
                return "Invalid task service provided"
            }
        }
    }
}

// Protocol for creating worker LLM clients
public protocol CreateWorkerClientProtocol: AnyObject {
    func createWorkerLLMClient(fallbackProviderId: String, fallbackModelId: String) async throws -> any LLMClientProtocol
}
