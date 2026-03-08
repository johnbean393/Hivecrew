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

    func insertAtCurrentCursor(suggestion: MentionSuggestion) {
        guard let textView = textView, let coordinator = coordinator else { return }
        let selection = textView.selectedRange()
        let insertionRange: NSRange
        if selection.location != NSNotFound {
            insertionRange = selection
        } else {
            insertionRange = NSRange(location: textView.string.count, length: 0)
        }
        coordinator.insertMention(suggestion: suggestion, at: insertionRange, in: textView)
    }

    func focusTextView() {
        guard let textView = textView else { return }
        textView.window?.makeFirstResponder(textView)
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
                case .task:
                    resolvedText += "continue from previous task \"\(attachment.displayName)\""
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

    func getReferencedTaskIDs() -> [String] {
        guard let textView = textView,
              let textStorage = textView.textStorage else {
            return []
        }

        var taskIDs: [String] = []
        let fullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.enumerateAttributes(in: fullRange, options: []) { attributes, _, _ in
            guard let attachment = attributes[.attachment] as? MentionTextAttachment,
                  attachment.mentionType == .task,
                  let taskId = attachment.referencedTaskId,
                  !taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }

            if !taskIDs.contains(taskId) {
                taskIDs.append(taskId)
            }
        }

        return taskIDs
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
    
}
