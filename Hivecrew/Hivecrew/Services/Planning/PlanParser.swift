//
//  PlanParser.swift
//  Hivecrew
//
//  Parses Markdown plans with checkbox todos
//

import Foundation

/// Parser for extracting and updating checkbox todos in Markdown plans
struct PlanParser {
    
    // MARK: - Regex Patterns
    
    /// Pattern for matching checkbox items: - [ ] or - [x]
    private static let checkboxPattern = #"^(\s*)-\s*\[([ xX])\]\s*(.+)$"#
    
    // MARK: - Parsing
    
    /// Parse todo items from a Markdown plan
    /// - Parameter markdown: The Markdown plan text
    /// - Returns: Array of PlanTodoItem extracted from the plan
    static func parseTodos(from markdown: String) -> [PlanTodoItem] {
        var items: [PlanTodoItem] = []
        let lines = markdown.components(separatedBy: .newlines)
        
        guard let regex = try? NSRegularExpression(pattern: checkboxPattern, options: .anchorsMatchLines) else {
            return items
        }
        
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range) {
                // Extract the checkbox state
                let checkboxRange = Range(match.range(at: 2), in: line)!
                let checkboxState = String(line[checkboxRange])
                let isCompleted = checkboxState.lowercased() == "x"
                
                // Extract the content
                let contentRange = Range(match.range(at: 3), in: line)!
                let content = String(line[contentRange]).trimmingCharacters(in: .whitespaces)
                
                let item = PlanTodoItem(
                    content: content,
                    isCompleted: isCompleted
                )
                items.append(item)
            }
        }
        
        return items
    }
    
    /// Update a specific todo item in the Markdown plan
    /// - Parameters:
    ///   - markdown: The original Markdown plan text
    ///   - item: The updated PlanTodoItem
    /// - Returns: The updated Markdown text
    static func updateMarkdown(_ markdown: String, updatingItem item: PlanTodoItem) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        
        guard let regex = try? NSRegularExpression(pattern: checkboxPattern, options: .anchorsMatchLines) else {
            return markdown
        }
        
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range) {
                // Extract the content to match against item
                let contentRange = Range(match.range(at: 3), in: line)!
                let content = String(line[contentRange]).trimmingCharacters(in: .whitespaces)
                
                if content == item.content {
                    // Extract the leading whitespace
                    let indentRange = Range(match.range(at: 1), in: line)!
                    let indent = String(line[indentRange])
                    
                    // Rebuild the line with updated checkbox state
                    let newCheckbox = item.isCompleted ? "x" : " "
                    lines[index] = "\(indent)- [\(newCheckbox)] \(item.content)"
                    break
                }
            }
        }
        
        return lines.joined(separator: "\n")
    }
    
    /// Toggle a todo item's completion state by its content
    /// - Parameters:
    ///   - markdown: The original Markdown plan text
    ///   - content: The content of the item to toggle
    /// - Returns: The updated Markdown text and whether the item is now completed
    static func toggleItem(in markdown: String, withContent content: String) -> (markdown: String, isCompleted: Bool) {
        var lines = markdown.components(separatedBy: .newlines)
        var isNowCompleted = false
        
        guard let regex = try? NSRegularExpression(pattern: checkboxPattern, options: .anchorsMatchLines) else {
            return (markdown, false)
        }
        
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range) {
                // Extract the content to match
                let contentRange = Range(match.range(at: 3), in: line)!
                let itemContent = String(line[contentRange]).trimmingCharacters(in: .whitespaces)
                
                if itemContent == content {
                    // Extract the checkbox state
                    let checkboxRange = Range(match.range(at: 2), in: line)!
                    let checkboxState = String(line[checkboxRange])
                    let wasCompleted = checkboxState.lowercased() == "x"
                    isNowCompleted = !wasCompleted
                    
                    // Extract the leading whitespace
                    let indentRange = Range(match.range(at: 1), in: line)!
                    let indent = String(line[indentRange])
                    
                    // Rebuild the line with toggled checkbox state
                    let newCheckbox = isNowCompleted ? "x" : " "
                    lines[index] = "\(indent)- [\(newCheckbox)] \(itemContent)"
                    break
                }
            }
        }
        
        return (lines.joined(separator: "\n"), isNowCompleted)
    }
    
    /// Mark a specific item as completed by its ID
    /// - Parameters:
    ///   - markdown: The original Markdown plan text
    ///   - items: The current list of PlanTodoItems (used to find the item by ID)
    ///   - itemId: The ID of the item to mark as completed
    /// - Returns: The updated Markdown text
    static func markItemCompleted(in markdown: String, items: [PlanTodoItem], itemId: String) -> String {
        guard let item = items.first(where: { $0.id == itemId }) else {
            return markdown
        }
        
        var updatedItem = item
        updatedItem.isCompleted = true
        return updateMarkdown(markdown, updatingItem: updatedItem)
    }
    
    /// Add a new todo item to the end of the plan
    /// - Parameters:
    ///   - markdown: The original Markdown plan text
    ///   - content: The content of the new item
    /// - Returns: The updated Markdown text
    static func addTodoItem(to markdown: String, content: String) -> String {
        let newLine = "- [ ] \(content)"
        
        if markdown.isEmpty {
            return newLine
        }
        
        // Add to end, ensuring there's a newline before
        if markdown.hasSuffix("\n") {
            return markdown + newLine
        } else {
            return markdown + "\n" + newLine
        }
    }
    
    /// Count completed and total items in the plan
    /// - Parameter markdown: The Markdown plan text
    /// - Returns: Tuple of (completed count, total count)
    static func countItems(in markdown: String) -> (completed: Int, total: Int) {
        let items = parseTodos(from: markdown)
        let completed = items.filter { $0.isCompleted }.count
        return (completed, items.count)
    }
    
    // MARK: - Plan Structure Extraction
    
    /// Pattern for matching level-1 headings (# Title)
    private static let titlePattern = #"^#\s+(.+)$"#
    
    /// Pattern for matching mermaid code blocks
    private static let mermaidPattern = #"```mermaid\s*\n([\s\S]*?)```"#
    
    /// Extract the title from a plan (first level-1 heading)
    /// - Parameter markdown: The Markdown plan text
    /// - Returns: The title text, or nil if not found
    static func extractTitle(from markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        
        guard let regex = try? NSRegularExpression(pattern: titlePattern, options: .anchorsMatchLines) else {
            return nil
        }
        
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let titleRange = Range(match.range(at: 1), in: line) {
                return String(line[titleRange]).trimmingCharacters(in: .whitespaces)
            }
        }
        
        return nil
    }
    
    /// Extract the overview paragraph from a plan (first non-empty paragraph after the title)
    /// - Parameter markdown: The Markdown plan text
    /// - Returns: The overview text, or nil if not found
    static func extractOverview(from markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        var foundTitle = false
        var overviewLines: [String] = []
        var inCodeBlock = false
        
        for line in lines {
            // Track code blocks
            if line.hasPrefix("```") {
                inCodeBlock = !inCodeBlock
                // If we were collecting overview and hit a code block, we're done
                if !overviewLines.isEmpty {
                    break
                }
                continue
            }
            
            // Skip content inside code blocks
            if inCodeBlock {
                continue
            }
            
            // Look for the title first
            if !foundTitle {
                if line.hasPrefix("# ") {
                    foundTitle = true
                }
                continue
            }
            
            // Skip empty lines before overview starts
            if overviewLines.isEmpty && line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            
            // Stop at headings or empty lines after collecting content
            if line.hasPrefix("#") || line.hasPrefix("-") || line.hasPrefix("*") {
                break
            }
            
            // Stop at empty line if we've collected some content
            if line.trimmingCharacters(in: .whitespaces).isEmpty && !overviewLines.isEmpty {
                break
            }
            
            // Collect overview content
            overviewLines.append(line)
        }
        
        let overview = overviewLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return overview.isEmpty ? nil : overview
    }
    
    /// Extract all mermaid diagram code blocks from the plan
    /// - Parameter markdown: The Markdown plan text
    /// - Returns: Array of mermaid diagram code strings
    static func extractMermaidBlocks(from markdown: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: mermaidPattern, options: []) else {
            return []
        }
        
        let range = NSRange(markdown.startIndex..., in: markdown)
        let matches = regex.matches(in: markdown, options: [], range: range)
        
        return matches.compactMap { match -> String? in
            guard let codeRange = Range(match.range(at: 1), in: markdown) else {
                return nil
            }
            return String(markdown[codeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    /// Check if a plan contains any mermaid diagrams
    /// - Parameter markdown: The Markdown plan text
    /// - Returns: True if the plan contains at least one mermaid diagram
    static func containsMermaid(in markdown: String) -> Bool {
        return markdown.contains("```mermaid")
    }
}
