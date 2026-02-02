//
//  ImageDownscaler.swift
//  Hivecrew
//
//  Utility for downscaling base64 images to reduce LLM payload size
//

import Foundation
import AppKit

/// Utility for downscaling base64-encoded images
enum ImageDownscaler {
    
    /// Scale levels for progressive downscaling
    enum ScaleLevel: Int, CaseIterable, Comparable {
        case original = 0   // No scaling
        case medium = 1     // Max 1024px
        case small = 2      // Max 512px
        case tiny = 3       // Max 256px
        
        var maxDimension: CGFloat {
            switch self {
            case .original: return CGFloat.greatestFiniteMagnitude
            case .medium: return 1024
            case .small: return 512
            case .tiny: return 256
            }
        }
        
        var next: ScaleLevel? {
            ScaleLevel(rawValue: self.rawValue + 1)
        }
        
        static func < (lhs: ScaleLevel, rhs: ScaleLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
    
    /// Default scale level for non-screenshot images (read_file results)
    static let defaultNonScreenshotScale: ScaleLevel = .medium
    
    /// Downscale a base64-encoded image to the specified scale level
    /// - Parameters:
    ///   - base64Data: Base64-encoded image data
    ///   - mimeType: MIME type of the image (e.g., "image/png", "image/jpeg")
    ///   - scaleLevel: Target scale level
    /// - Returns: Tuple of (downscaled base64 data, output mime type), or nil if conversion fails
    static func downscale(
        base64Data: String,
        mimeType: String,
        to scaleLevel: ScaleLevel
    ) -> (data: String, mimeType: String)? {
        // If original, return as-is
        if scaleLevel == .original {
            return (base64Data, mimeType)
        }
        
        // Decode base64 to Data
        guard let imageData = Data(base64Encoded: base64Data) else {
            print("[ImageDownscaler] Failed to decode base64 data")
            return nil
        }
        
        // Create NSImage
        guard let image = NSImage(data: imageData) else {
            print("[ImageDownscaler] Failed to create image from data")
            return nil
        }
        
        // Get original size
        let originalSize = image.size
        let maxDim = scaleLevel.maxDimension
        
        // Check if downscaling is needed
        if originalSize.width <= maxDim && originalSize.height <= maxDim {
            // Already small enough, but re-encode as JPEG for consistency
            return encodeAsJPEG(image: image, quality: 0.8)
        }
        
        // Calculate new size maintaining aspect ratio
        let aspectRatio = originalSize.width / originalSize.height
        let newSize: NSSize
        
        if originalSize.width > originalSize.height {
            newSize = NSSize(width: maxDim, height: maxDim / aspectRatio)
        } else {
            newSize = NSSize(width: maxDim * aspectRatio, height: maxDim)
        }
        
        // Create resized image
        guard let resizedImage = resizeImage(image, to: newSize) else {
            print("[ImageDownscaler] Failed to resize image")
            return nil
        }
        
        return encodeAsJPEG(image: resizedImage, quality: 0.8)
    }
    
    /// Convert an image to JPEG format without resizing
    /// Used when the original format is not supported by image generation APIs (e.g., HEIC, WebP)
    /// - Parameters:
    ///   - base64Data: Base64-encoded image data
    ///   - mimeType: MIME type of the image
    /// - Returns: Tuple of (JPEG base64 data, mime type), or nil if conversion fails
    static func convertToJPEG(
        base64Data: String,
        mimeType: String
    ) -> (data: String, mimeType: String)? {
        // Already JPEG, return as-is
        if mimeType == "image/jpeg" {
            return (base64Data, mimeType)
        }
        
        guard let imageData = Data(base64Encoded: base64Data),
              let image = NSImage(data: imageData) else {
            print("[ImageDownscaler] Failed to decode image for JPEG conversion")
            return nil
        }
        
        return encodeAsJPEG(image: image, quality: 0.9)
    }
    
    /// Resize an NSImage to the specified size
    private static func resizeImage(_ image: NSImage, to newSize: NSSize) -> NSImage? {
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        
        NSGraphicsContext.current?.imageInterpolation = .high
        
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        
        newImage.unlockFocus()
        return newImage
    }
    
    /// Encode an NSImage as JPEG base64
    private static func encodeAsJPEG(image: NSImage, quality: CGFloat) -> (data: String, mimeType: String)? {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            return nil
        }
        
        return (jpegData.base64EncodedString(), "image/jpeg")
    }
    
    /// Get the approximate size of base64 data in bytes
    static func estimateSize(base64Data: String) -> Int {
        // Base64 encodes 3 bytes into 4 characters
        return (base64Data.count * 3) / 4
    }
    
    /// Check if the estimated payload size is too large
    /// - Parameter totalBase64Size: Total size of all base64 data in characters
    /// - Returns: True if the payload is likely too large for most LLM APIs
    static func isPayloadTooLarge(totalBase64Size: Int) -> Bool {
        // Most APIs have limits around 20MB, be conservative at 15MB
        let estimatedBytes = (totalBase64Size * 3) / 4
        return estimatedBytes > 15_000_000
    }
}
