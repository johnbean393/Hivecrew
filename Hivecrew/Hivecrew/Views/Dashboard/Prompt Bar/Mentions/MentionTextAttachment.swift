//
//  MentionTextAttachment.swift
//  Hivecrew
//
//  Custom text attachment that renders a mention as a styled tag
//

import AppKit

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
        
        // Use natural image size to match prompt bar text size
        let width = image.size.width
        let height = image.size.height
        
        // Center vertically in the line
        let yOffset = (lineFrag.height - height) / 2 - 3
        
        return CGRect(x: 0, y: yOffset, width: width, height: height)
    }
    
    private func renderTagImage() -> NSImage {
        // Configuration - match prompt bar text size
        let fontSize = NSFont.systemFontSize - 3
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let iconSize: CGFloat = fontSize - 2
        let horizontalPadding: CGFloat = 4
        let verticalPadding: CGFloat = 2
        let iconTextSpacing: CGFloat = 4
        let cornerRadius: CGFloat = 5
        
        // Calculate text size
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
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
