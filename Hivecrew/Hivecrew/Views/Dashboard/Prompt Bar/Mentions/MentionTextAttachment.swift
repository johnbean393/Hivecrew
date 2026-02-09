//
//  MentionTextAttachment.swift
//  Hivecrew
//
//  Custom text attachment that renders a mention as a styled tag
//

import AppKit

/// Type of mention represented by the attachment
enum MentionType {
    case file
    case skill
    case environmentVariable
    case injectedFile
}

/// Custom text attachment that renders a mention as a styled tag
class MentionTextAttachment: NSTextAttachment {
    
    let displayName: String
    let fileURL: URL?
    let skillName: String?
    let mentionType: MentionType
    
    /// The environment variable key (for .environmentVariable type)
    let envKey: String?
    /// The environment variable value (for .environmentVariable type)
    let envValue: String?
    /// The guest path for injected file (for .injectedFile type)
    let guestPath: String?
    
    /// Initialize with a file URL
    init(displayName: String, fileURL: URL) {
        self.displayName = displayName
        self.fileURL = fileURL
        self.skillName = nil
        self.mentionType = .file
        self.envKey = nil
        self.envValue = nil
        self.guestPath = nil
        super.init(data: nil, ofType: nil)
        
        // Render and set the image immediately
        self.image = renderTagImage()
    }
    
    /// Initialize with a skill name
    init(displayName: String, skillName: String) {
        self.displayName = displayName
        self.fileURL = nil
        self.skillName = skillName
        self.mentionType = .skill
        self.envKey = nil
        self.envValue = nil
        self.guestPath = nil
        super.init(data: nil, ofType: nil)
        
        // Render and set the image immediately
        self.image = renderTagImage()
    }
    
    /// Initialize with an environment variable
    init(displayName: String, envKey: String, envValue: String) {
        self.displayName = displayName
        self.fileURL = nil
        self.skillName = nil
        self.mentionType = .environmentVariable
        self.envKey = envKey
        self.envValue = envValue
        self.guestPath = nil
        super.init(data: nil, ofType: nil)
        
        self.image = renderTagImage()
    }
    
    /// Initialize with an injected file
    init(displayName: String, guestPath: String, assetFileURL: URL? = nil) {
        self.displayName = displayName
        self.fileURL = assetFileURL
        self.skillName = nil
        self.mentionType = .injectedFile
        self.envKey = nil
        self.envValue = nil
        self.guestPath = guestPath
        super.init(data: nil, ofType: nil)
        
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
            // Draw rounded rectangle background
            let bgColor: NSColor
            switch self.mentionType {
            case .file:
                bgColor = NSColor.systemBlue.withAlphaComponent(0.4)
            case .skill:
                bgColor = NSColor.systemPurple.withAlphaComponent(0.4)
            case .environmentVariable:
                bgColor = NSColor.systemGreen.withAlphaComponent(0.4)
            case .injectedFile:
                bgColor = NSColor.systemOrange.withAlphaComponent(0.4)
            }
            let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            bgColor.setFill()
            bgPath.fill()
            
            // Draw icon
            let iconRect = CGRect(
                x: horizontalPadding,
                y: (rect.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            
            let symbolName: String
            switch self.mentionType {
            case .file:
                // Get the actual file icon from the system
                if let url = self.fileURL {
                    let fileIcon = NSWorkspace.shared.icon(forFile: url.path)
                    fileIcon.draw(in: iconRect)
                }
                symbolName = ""
            case .skill:
                symbolName = "sparkles"
            case .environmentVariable:
                symbolName = "terminal"
            case .injectedFile:
                // Use the actual file icon if we have the asset file URL
                if let url = self.fileURL {
                    let fileIcon = NSWorkspace.shared.icon(forFile: url.path)
                    fileIcon.draw(in: iconRect)
                    symbolName = ""
                } else {
                    symbolName = "doc.on.doc"
                }
            }
            
            if !symbolName.isEmpty {
                let symbolConfig = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
                    .applying(
                        NSImage.SymbolConfiguration(
                            paletteColors: [NSColor.textColor]
                        )
                    )
                if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfig) {
                    symbolImage.draw(in: iconRect)
                }
            }
            
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
