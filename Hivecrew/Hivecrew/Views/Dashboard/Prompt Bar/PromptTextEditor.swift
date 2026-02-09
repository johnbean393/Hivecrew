//
//  PromptTextEditor.swift
//  Hivecrew
//
//  Multiline text editor with drag-and-drop support for attachments
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Data needed to insert a mention
struct MentionInsertionRequest {
    let suggestion: MentionSuggestion
    let range: NSRange
}

/// Shared controller for mention insertion that can be accessed directly
@MainActor
final class MentionInsertionController: ObservableObject {
    weak var textView: NSTextView?
    weak var coordinator: PromptTextEditor.Coordinator?
    
    func insert(suggestion: MentionSuggestion, at range: NSRange) {
        guard let textView = textView, let coordinator = coordinator else { return }
        coordinator.insertMention(suggestion: suggestion, at: range, in: textView)
    }
    
    /// Clear the text view content directly
    func clearTextView() {
        guard let textView = textView, let coordinator = coordinator else { return }
        coordinator.isProgrammaticUpdate = true
        textView.string = ""
        textView.invalidateIntrinsicContentSize()
    }
    
    /// Insert a newline at the current cursor position
    func insertNewline() {
        guard let textView = textView else { return }
        textView.insertNewline(nil)
    }
    
    /// Get the text with mention attachments replaced
    /// - File mentions become VM inbox paths
    /// - Skill mentions become "{skill-name} skill" format
    func getResolvedText() -> String {
        guard let textView = textView,
              let textStorage = textView.textStorage else {
            return textView?.string ?? ""
        }
        
        var resolvedText = ""
        let fullRange = NSRange(location: 0, length: textStorage.length)
        
        textStorage.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? MentionTextAttachment {
                switch attachment.mentionType {
                case .file:
                    // Replace file attachment with VM inbox path
                    if let fileURL = attachment.fileURL {
                        let filename = fileURL.lastPathComponent
                        let vmPath = "/Users/hivecrew/Desktop/inbox/\(filename)"
                        resolvedText += "\"\(vmPath)\""
                    }
                case .skill:
                    // Replace skill mention with "{skill-name} skill" format
                    // Avoid duplicating "skill" if the name already ends with it
                    if let skillName = attachment.skillName {
                        if skillName.lowercased().hasSuffix("skill") || skillName.lowercased().hasSuffix("-skill") {
                            resolvedText += skillName
                        } else {
                            resolvedText += "\(skillName) skill"
                        }
                    }
                case .environmentVariable:
                    // Replace env var mention with $KEY reference
                    if let key = attachment.envKey {
                        resolvedText += "$\(key)"
                    }
                case .injectedFile:
                    // Replace injected file mention with the guest VM path
                    if let guestPath = attachment.guestPath, !guestPath.isEmpty {
                        let expandedPath = guestPath
                            .replacingOccurrences(of: "~/", with: "/Users/hivecrew/")
                            .replacingOccurrences(of: "$HOME/", with: "/Users/hivecrew/")
                        resolvedText += "\"\(expandedPath)\""
                    } else {
                        resolvedText += attachment.displayName
                    }
                }
            } else {
                // Regular text - extract from storage
                let substring = textStorage.attributedSubstring(from: range).string
                resolvedText += substring
            }
        }
        
        return resolvedText
    }
    
    /// Get the names of skills mentioned in the text
    func getMentionedSkillNames() -> [String] {
        guard let textView = textView,
              let textStorage = textView.textStorage else {
            return []
        }
        
        var skillNames: [String] = []
        let fullRange = NSRange(location: 0, length: textStorage.length)
        
        textStorage.enumerateAttributes(in: fullRange, options: []) { attributes, _, _ in
            if let attachment = attributes[.attachment] as? MentionTextAttachment,
               attachment.mentionType == .skill,
               let skillName = attachment.skillName {
                skillNames.append(skillName)
            }
        }
        
        return skillNames
    }
}

/// A multiline text editor that supports drag-and-drop for files and images
struct PromptTextEditor: NSViewRepresentable {
    
    @Binding var text: String
    @Binding var insertionPoint: Int
    let placeholder: String
    var onFileDrop: ((URL) -> Void)?
    /// Callback when an @mention query is detected or updated, includes screen position for popup
    var onMentionQuery: ((MentionQuery?, CGPoint?) -> Void)?
    /// Controller for directly inserting mentions
    var mentionInsertionController: MentionInsertionController?
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> PromptScrollView {
        let scrollView = PromptScrollView()
        let textView = PromptTextView()
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.delegate = context.coordinator
        textView.setPlaceholder(placeholder)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        // Use lineFragmentPadding of 0 for precise text positioning
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.textColor = .labelColor
        textView.typingAttributes[.foregroundColor] = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        
        // Set min and max size for proper scrolling
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = font.ascender - font.descender + font.leading
        textView.minSize = NSSize(width: 0, height: lineHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.onFileDrop = context.coordinator.onFileDrop
        
        // Register for drag types
        textView.registerForDraggedTypes([
            .fileURL,
            .png,
            .tiff,
            .URL
        ])
        
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        
        // Store reference to text view
        context.coordinator.textView = textView
        
        // Set up mention insertion controller
        mentionInsertionController?.textView = textView
        mentionInsertionController?.coordinator = context.coordinator
        
        return scrollView
    }
    
    func updateNSView(_ nsView: PromptScrollView, context: Context) {
        guard let textView = nsView.documentView as? PromptTextView else { return }
        let coordinator = context.coordinator
        let isFirstResponder = textView.window?.firstResponder == textView
        let hasMarkedText = textView.hasMarkedText()
        
        // Update mention insertion controller references
        mentionInsertionController?.textView = textView
        mentionInsertionController?.coordinator = coordinator
        
        let desiredTextColor: NSColor = .labelColor
        let desiredInsertionColor: NSColor = .controlAccentColor
        
        if textView.textColor != desiredTextColor {
            textView.textColor = desiredTextColor
        }
        if textView.insertionPointColor != desiredInsertionColor {
            textView.insertionPointColor = desiredInsertionColor
        }
        if (textView.typingAttributes[.foregroundColor] as? NSColor) != desiredTextColor {
            var attributes = textView.typingAttributes
            attributes[.foregroundColor] = desiredTextColor
            textView.typingAttributes = attributes
        }
        
        // Update the callback
        textView.onFileDrop = context.coordinator.onFileDrop
        
        // Only update if not editing - don't sync text back while editing to preserve attachments
        if !isFirstResponder {
            // Save current scroll position for programmatic updates
            let currentScrollPosition = nsView.contentView.bounds.origin
            
            // Enable scroll position preservation during programmatic updates
            textView.shouldPreserveScrollPosition = true
            
            if textView.string != text {
                coordinator.isProgrammaticUpdate = true
                textView.string = text
            }
            if textView.selectedRange.location != insertionPoint {
                coordinator.isProgrammaticUpdate = true
                textView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
            }
            
            // Restore scroll position after layout update
            DispatchQueue.main.async {
                nsView.contentView.scroll(to: currentScrollPosition)
                textView.shouldPreserveScrollPosition = false
            }
        } else if hasMarkedText {
            // Don't interfere with IME composition
        } else {
            // When editing, let the text view handle scrolling naturally
        }
        
        textView.setPlaceholder(placeholder)
        textView.invalidateIntrinsicContentSize()
        nsView.invalidateIntrinsicContentSize()
    }
    
    // MARK: - Coordinator
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextEditor
        var isProgrammaticUpdate = false
        weak var textView: NSTextView?
        
        /// Current mention range for replacement
        var currentMentionRange: NSRange?
        
        init(_ parent: PromptTextEditor) {
            self.parent = parent
        }
        
        var onFileDrop: ((URL) -> Void)? {
            return parent.onFileDrop
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Don't update during IME composition
            if textView.hasMarkedText() { return }
            // Prevent feedback loop
            if isProgrammaticUpdate {
                isProgrammaticUpdate = false
                return
            }
            let newString = textView.string
            let cursor = textView.selectedRange.location
            withAnimation(.linear) {
                parent.text = newString
                parent.insertionPoint = cursor
            }
            textView.invalidateIntrinsicContentSize()
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
            
            // Check for @mention query
            checkForMentionQuery(in: textView)
        }
        
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if isProgrammaticUpdate {
                isProgrammaticUpdate = false
                return
            }
            let cursor = textView.selectedRange.location
            if parent.insertionPoint != cursor {
                parent.insertionPoint = cursor
            }
            
            // Check for @mention query on selection change
            checkForMentionQuery(in: textView)
        }
        
        /// Detects if the cursor is within an @mention and extracts the query
        private func checkForMentionQuery(in textView: NSTextView) {
            let text = textView.string
            let cursorLocation = textView.selectedRange.location
            
            // Find the @ symbol before the cursor
            guard cursorLocation > 0, cursorLocation <= text.count else {
                currentMentionRange = nil
                parent.onMentionQuery?(nil, nil)
                return
            }
            
            let textBeforeCursor = String(text.prefix(cursorLocation))
            
            // Look for @ that starts a mention (after whitespace/newline or at start)
            guard let atIndex = textBeforeCursor.lastIndex(of: "@") else {
                currentMentionRange = nil
                parent.onMentionQuery?(nil, nil)
                return
            }
            
            let atPosition = textBeforeCursor.distance(from: textBeforeCursor.startIndex, to: atIndex)
            
            // Check if @ is at start or preceded by whitespace/newline
            if atPosition > 0 {
                let charBeforeAt = textBeforeCursor[textBeforeCursor.index(before: atIndex)]
                if !charBeforeAt.isWhitespace && !charBeforeAt.isNewline {
                    currentMentionRange = nil
                    parent.onMentionQuery?(nil, nil)
                    return
                }
            }
            
            // Extract the query text after @
            let queryStartIndex = textBeforeCursor.index(after: atIndex)
            let queryText = String(textBeforeCursor[queryStartIndex...])
            
            // Query should not contain spaces (would end the mention)
            if queryText.contains(" ") || queryText.contains("\n") {
                currentMentionRange = nil
                parent.onMentionQuery?(nil, nil)
                return
            }
            
            // Store the mention range for later replacement
            let mentionRange = NSRange(location: atPosition, length: queryText.count + 1)
            currentMentionRange = mentionRange
            
            // Get the screen position for the popup
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let window = textView.window else {
                parent.onMentionQuery?(nil, nil)
                return
            }
            
            let nsRange = NSRange(location: cursorLocation, length: 0)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
            var boundingRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            
            // Adjust for text container inset
            boundingRect.origin.x += textView.textContainerInset.width
            boundingRect.origin.y += textView.textContainerInset.height
            
            // Convert to screen coordinates
            let pointInTextView = CGPoint(x: boundingRect.origin.x, y: boundingRect.origin.y + boundingRect.height)
            let pointInWindow = textView.convert(pointInTextView, to: nil)
            let screenPoint = window.convertPoint(toScreen: pointInWindow)
            
            let mentionQuery = MentionQuery(
                query: queryText,
                range: mentionRange,
                position: pointInTextView
            )
            
            parent.onMentionQuery?(mentionQuery, screenPoint)
        }
        
        /// Insert a mention suggestion at the given range
        func insertMention(suggestion: MentionSuggestion, at range: NSRange, in textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            
            isProgrammaticUpdate = true
            
            // Create the mention attachment based on type
            let attachment: MentionTextAttachment
            switch suggestion.type {
            case .skill:
                attachment = MentionTextAttachment(
                    displayName: suggestion.displayName,
                    skillName: suggestion.skillName ?? suggestion.displayName
                )
            case .attachment, .deliverable:
                guard let url = suggestion.url else { return }
                attachment = MentionTextAttachment(
                    displayName: suggestion.displayName,
                    fileURL: url
                )
            case .environmentVariable:
                attachment = MentionTextAttachment(
                    displayName: suggestion.displayName,
                    envKey: suggestion.displayName,
                    envValue: suggestion.detail ?? ""
                )
            case .injectedFile:
                attachment = MentionTextAttachment(
                    displayName: suggestion.displayName,
                    guestPath: suggestion.detail ?? "",
                    assetFileURL: suggestion.url
                )
            }
            
            // Create attributed string with the attachment
            let attachmentString = NSAttributedString(attachment: attachment)
            
            // Add a space after the attachment for easier editing
            let spaceString = NSAttributedString(string: " ", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
            ])
            
            let combinedString = NSMutableAttributedString()
            combinedString.append(attachmentString)
            combinedString.append(spaceString)
            
            // Replace the @query range with the attachment
            textStorage.replaceCharacters(in: range, with: combinedString)
            
            // Move cursor to after the attachment and space
            let newCursorPosition = range.location + combinedString.length
            textView.setSelectedRange(NSRange(location: newCursorPosition, length: 0))
            
            // Reset typing attributes to normal
            var typingAttrs = textView.typingAttributes
            typingAttrs[.foregroundColor] = NSColor.labelColor
            typingAttrs.removeValue(forKey: .attachment)
            textView.typingAttributes = typingAttrs
            
            // Update parent state
            parent.text = textView.string
            parent.insertionPoint = newCursorPosition
            currentMentionRange = nil
            parent.onMentionQuery?(nil, nil)
            
            textView.invalidateIntrinsicContentSize()
        }
    }
}
