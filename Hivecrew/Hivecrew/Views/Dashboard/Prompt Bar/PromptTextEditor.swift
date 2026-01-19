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
import OSLog

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
    
    /// Get the text with mention attachments replaced by their file paths
    func getResolvedText() -> String {
        guard let textView = textView,
              let textStorage = textView.textStorage else {
            return textView?.string ?? ""
        }
        
        var resolvedText = ""
        let fullRange = NSRange(location: 0, length: textStorage.length)
        
        textStorage.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? MentionTextAttachment {
                // Replace attachment with quoted file path
                resolvedText += "\"\(attachment.fileURL.path)\""
            } else {
                // Regular text - extract from storage
                let substring = textStorage.attributedSubstring(from: range).string
                resolvedText += substring
            }
        }
        
        return resolvedText
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
        
        // Save current scroll position
        let currentScrollPosition = nsView.contentView.bounds.origin
        
        // Update the callback
        textView.onFileDrop = context.coordinator.onFileDrop
        
        // Enable scroll position preservation during programmatic updates
        textView.shouldPreserveScrollPosition = true
        
        // Only update if not editing - don't sync text back while editing to preserve attachments
        if !isFirstResponder {
            if textView.string != text {
                coordinator.isProgrammaticUpdate = true
                textView.string = text
            }
            if textView.selectedRange.location != insertionPoint {
                coordinator.isProgrammaticUpdate = true
                textView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
            }
        } else if hasMarkedText {
            // Don't interfere with IME composition
        } else {
            // When editing, only update cursor position if needed and it won't disrupt user input
            // Skip text sync to preserve attachments
        }
        
        textView.setPlaceholder(placeholder)
        textView.invalidateIntrinsicContentSize()
        nsView.invalidateIntrinsicContentSize()
        
        // Restore scroll position after layout update
        DispatchQueue.main.async {
            nsView.contentView.scroll(to: currentScrollPosition)
            textView.shouldPreserveScrollPosition = false
        }
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
            
            // Create the mention attachment
            let attachment = MentionTextAttachment(
                displayName: suggestion.displayName,
                fileURL: suggestion.url
            )
            
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

// MARK: - Mention Text Attachment

/// Custom text attachment that renders a mention as a styled tag
class MentionTextAttachment: NSTextAttachment {
    
    let displayName: String
    let fileURL: URL
    
    init(displayName: String, fileURL: URL) {
        self.displayName = displayName
        self.fileURL = fileURL
        super.init(data: nil, ofType: nil)
        
        // Render and set the image immediately
        self.image = renderTagImage()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        guard let image = self.image else { return .zero }
        let height = lineFrag.height - 2
        let aspectRatio = image.size.width / image.size.height
        let width = height * aspectRatio
        
        // Position lower in the line (negative yOffset moves it down in flipped coordinates)
        let yOffset = -3.0
        
        return CGRect(x: 0, y: yOffset, width: width, height: height)
    }
    
    private func renderTagImage() -> NSImage {
        // Configuration
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let iconSize: CGFloat = 14
        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 3
        let iconTextSpacing: CGFloat = 4
        let cornerRadius: CGFloat = 5
        
        // Calculate text size
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = displayName.size(withAttributes: textAttributes)
        
        // Calculate total size
        let totalWidth = horizontalPadding + iconSize + iconTextSpacing + textSize.width + horizontalPadding
        let totalHeight = max(textSize.height, iconSize) + verticalPadding * 2
        
        let size = CGSize(width: totalWidth, height: totalHeight)
        
        let image = NSImage(size: size, flipped: false) { rect in
            // Draw rounded rectangle background with transparent blue
            let bgColor = NSColor.systemBlue.withAlphaComponent(0.4)
            let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            bgColor.setFill()
            bgPath.fill()
            
            // Draw file icon from the file system
            let iconRect = CGRect(
                x: horizontalPadding,
                y: (rect.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            
            // Get the actual file icon from the system
            let fileIcon = NSWorkspace.shared.icon(forFile: self.fileURL.path)
            fileIcon.draw(in: iconRect)
            
            // Draw text
            let textRect = CGRect(
                x: horizontalPadding + iconSize + iconTextSpacing,
                y: (rect.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            self.displayName.draw(in: textRect, withAttributes: textAttributes)
            
            return true
        }
        
        return image
    }
}

// MARK: - Prompt Scroll View

class PromptScrollView: NSScrollView {
    
    /// Maximum height before scrolling kicks in (approximately 6 lines of text)
    private let maxHeightBeforeScrolling: CGFloat = 100
    
    override var intrinsicContentSize: NSSize {
        if let docView = self.documentView {
            var size = docView.intrinsicContentSize
            size.width = NSView.noIntrinsicMetric
            // Cap the height to enable scrolling for long text
            size.height = min(size.height, maxHeightBeforeScrolling)
            return size
        }
        return super.intrinsicContentSize
    }
}

// MARK: - Prompt Text View

class PromptTextView: NSTextView {
    
    private var placeholder: String = ""
    var onFileDrop: ((URL) -> Void)?
    var shouldPreserveScrollPosition: Bool = false
    
    private static let logger: Logger = .init(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: PromptTextView.self)
    )
    
    override var intrinsicContentSize: NSSize {
        guard let layoutManager = self.layoutManager, let textContainer = self.textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = font.ascender - font.descender + font.leading
        // Minimum height is just one line
        let neededHeight = max(lineHeight, usedRect.height)
        let width = self.enclosingScrollView?.frame.width ?? usedRect.width
        return NSSize(width: width, height: neededHeight)
    }
    
    override func scrollRangeToVisible(_ range: NSRange) {
        if !shouldPreserveScrollPosition {
            super.scrollRangeToVisible(range)
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ]
            // Draw placeholder at the same position as text would appear
            (placeholder as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: attrs)
        }
    }
    
    func setPlaceholder(_ placeholder: String) {
        DispatchQueue.main.async {
            self.placeholder = placeholder
        }
        needsDisplay = true
    }
    
    /// Force pasting as plain text
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        
        let fileURLClasses: [AnyClass] = [NSURL.self]
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let urls = pasteboard.readObjects(forClasses: fileURLClasses, options: options) as? [URL],
           !urls.isEmpty {
            Self.logger.info("Handling pasted file URLs")
            if handleFileURLs(urls) {
                return
            }
        }
        
        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            Self.logger.info("Handling pasted image data")
            if handleImageData(imageData, pasteboard: pasteboard) {
                return
            }
        }
        
        if let plainText = pasteboard.string(forType: .string) {
            self.insertText(plainText, replacementRange: self.selectedRange())
        } else {
            super.paste(sender)
        }
    }
    
    // MARK: - Drag and Drop Support
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if canHandleDrag(sender) {
            return .copy
        }
        return []
    }
    
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if canHandleDrag(sender) {
            return .copy
        }
        return []
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.logger.info("performDragOperation called")
        let pasteboard = sender.draggingPasteboard
        
        Self.logger.info("Pasteboard types: \(pasteboard.types?.map { $0.rawValue } ?? [], privacy: .public)")
        
        // Try to handle image data first (for screenshots)
        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            Self.logger.info("Found image data, handling...")
            return handleImageData(imageData, pasteboard: pasteboard)
        }
        
        // Try to handle file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            return handleFileURLs(urls)
        }
        
        Self.logger.warning("No valid data found in drop")
        return false
    }
    
    private func canHandleDrag(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        
        // Check for image data (screenshots)
        if pasteboard.data(forType: .png) != nil ||
            pasteboard.data(forType: .tiff) != nil {
            return true
        }
        
        // Check for file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return true
        }
        
        return false
    }
    
    private func handleImageData(_ imageData: Data, pasteboard: NSPasteboard) -> Bool {
        Self.logger.info("handleImageData called with data size: \(imageData.count, privacy: .public)")
        
        guard let image = NSImage(data: imageData) else {
            Self.logger.error("Failed to create NSImage from dropped data")
            return false
        }
        
        Self.logger.info("Created NSImage with size: \(image.size.width, privacy: .public)x\(image.size.height, privacy: .public)")
        
        // Determine the file extension based on the data type
        let fileExtension: String = "png"
        
        // Create a temporary file to save the image
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileName = "Screenshot-\(UUID().uuidString).\(fileExtension)"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
        Self.logger.info("Will save to: \(fileURL.path, privacy: .public)")
        
        // Convert image to appropriate format and save
        guard let tiffData = image.tiffRepresentation else {
            Self.logger.error("Failed to get TIFF representation of image")
            return false
        }
        
        let bitmapImageRep = NSBitmapImageRep(data: tiffData)
        let imageDataToSave = bitmapImageRep?.representation(using: .png, properties: [:])
        
        guard let finalImageData = imageDataToSave else {
            Self.logger.error("Failed to convert image to \(fileExtension, privacy: .public)")
            return false
        }
        
        do {
            try finalImageData.write(to: fileURL)
            Self.logger.info("Successfully saved dropped image to: \(fileURL.path, privacy: .public)")
            
            // Call the callback on the main thread
            DispatchQueue.main.async { [weak self] in
                Self.logger.info("Calling onFileDrop callback")
                self?.onFileDrop?(fileURL)
            }
            return true
        } catch {
            Self.logger.error("Failed to save image: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    
    private func handleFileURLs(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else {
            Self.logger.warning("No file URLs provided to handleFileURLs")
            return false
        }
        
        Self.logger.info("Handling \(urls.count, privacy: .public) file URLs")
        
        for url in urls {
            Self.logger.info("Processing file URL: \(url.path, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.onFileDrop?(url)
            }
        }
        
        return true
    }
}
