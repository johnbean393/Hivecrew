//
//  PromptTextEditor.swift
//  Hivecrew
//
//  Multiline text editor with drag-and-drop support for attachments
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OSLog

/// A multiline text editor that supports drag-and-drop for files and images
struct PromptTextEditor: NSViewRepresentable {
    
    @Binding var text: String
    @Binding var insertionPoint: Int
    let placeholder: String
    var onFileDrop: ((URL) -> Void)?
    
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
        
        return scrollView
    }
    
    func updateNSView(_ nsView: PromptScrollView, context: Context) {
        guard let textView = nsView.documentView as? PromptTextView else { return }
        let coordinator = context.coordinator
        let isFirstResponder = textView.window?.firstResponder == textView
        let hasMarkedText = textView.hasMarkedText()
        
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
        
        // Only update if not editing (or not composing)
        if !isFirstResponder || !hasMarkedText {
            if textView.string != text {
                coordinator.isProgrammaticUpdate = true
                textView.string = text
            }
            if textView.selectedRange.location != insertionPoint {
                coordinator.isProgrammaticUpdate = true
                textView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
            }
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
        }
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
