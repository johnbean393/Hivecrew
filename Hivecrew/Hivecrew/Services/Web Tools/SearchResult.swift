//
//  SearchResult.swift
//  Hivecrew
//
//  Model for web search results
//

import Foundation

/// A single search result with URL, title, and snippet
public struct SearchResult: Codable, Sendable {
    public let url: String
    public let title: String
    public let snippet: String
    
    public init(url: String, title: String, snippet: String) {
        self.url = url
        self.title = title
        self.snippet = snippet
    }
}
